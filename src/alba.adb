-- ============================================================
--     _      _      ____
--    / \    | |    | __ )
--   / _ \   | |    |  _ \
--  / ___ \  | |___ | |_) |
-- /_/   \_\ |_____||____/
--
--  AdaLogic BASIC (ALB)
--  Copyright 2014-2026 Rocky L. Oliver d/b/a Oliver Softworks
--
--  Licensed under the Apache License, Version 2.0 (the "License");
--  you may not use this file except in compliance with the License.
--  You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
--  Unless required by applicable law or agreed to in writing, software
--  distributed under the License is distributed on an "AS IS" BASIS,
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--  See the License for the specific language governing permissions and
--  limitations under the License.
--
--  Contact: contact@alb-lang.org
--  https://alb-lang.org | https://alb-lang.com | https://alb-lang.dev
-- ============================================================

with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with GNAT.OS_Lib;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with Parser;         use Parser;
with AST;            use AST;
with ALB_Oracle;     use ALB_Oracle;
with ALBA_Spawn;
with Emit_Native_Ada;
with ALB_System_Includes;

-- =============================================================================
-- ALBA — AdaLogic BASIC to native Ada driver
-- Purpose: weave includes, parse ALB, emit Ada via Emit_Native_Ada, optional build.
-- Safety role: toolchain front-end; bounded buffers; fail-safe diagnostics.
-- Assumptions: Max_Includes/Max_Path_Len cap all filesystem and include work.
-- Dependencies: Compiler_State, Parser, Emit_Native_Ada, GNAT.OS_Lib.
-- Boundedness: include stack depth <= Max_Includes; no recursion in Weave_File.
-- =============================================================================


procedure ALBA is

   Max_Path_Len            : constant := 512;
   Max_Includes            : constant := 2048;
   Max_Include_Line_Length : constant := 2048;
   Max_Input_Size          : constant := Input_Buffer'Length;

   subtype Path_Buffer is String (1 .. Max_Path_Len);
   subtype Include_Line_Buffer is String (1 .. Max_Include_Line_Length);

   Input_Len     : Natural := 0;
   Token_Count   : Natural := 0;
   Root          : Node_Index := 0;
   Parse_Success : Boolean := False;

   Lex_Diag   : Lexer_Diagnostic;
   Parse_Diag : Parser_Diagnostic;

   Include_Vault : array (1 .. Max_Includes) of String (1 .. Max_Path_Len) :=
     (others => (others => ' '));
   Include_Lens  : array (1 .. Max_Includes) of Natural := (others => 0);
   Include_Count : Natural := 0;

   Source_File   : String (1 .. Max_Path_Len) := (others => ' ');
   Output_File   : String (1 .. Max_Path_Len) := (others => ' ');
   Out_Dir       : String (1 .. Max_Path_Len) := (others => ' ');
   Final_Dir     : String (1 .. Max_Path_Len) := (others => ' ');
   Source_Len    : Natural := 0;
   Output_Len    : Natural := 0;
   Out_Dir_Len   : Natural := 0;
   Final_Dir_Len : Natural := 0;
   Build_Mode    : Boolean := False;
   Use_Gprbuild_Mode : Boolean := True;
   Arg_Error     : Boolean := False;

   type Include_Frame is record
      File        : Ada.Streams.Stream_IO.File_Type;
      Stream_Ptr  : Ada.Streams.Stream_IO.Stream_Access := null;
      File_Dir    : Path_Buffer := (others => ' ');
      File_Dir_Len : Natural := 0;
      Line_Buffer : Include_Line_Buffer := (others => ' ');
      Line_Len    : Natural := 0;
      Total_Bytes : Ada.Streams.Stream_IO.Count := 0;
      Bytes_Read  : Ada.Streams.Stream_IO.Count := 0;
      Reached_Eof : Boolean := False;
   end record;

   function To_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      end if;
      return Ch;
   end To_Upper;

   function Trim_Image (N : Integer) return String is
      S : constant String := Integer'Image (N);
      F : Positive := S'First;
   begin
      while F < S'Last and then S (F) = ' ' loop
         F := F + 1;
      end loop;
      return S (F .. S'Last);
   end Trim_Image;

   function Prefix
     (Buffer : String;
      Length : Natural) return String is
   begin
      if Length = 0 then
         return "";
      end if;

      return Buffer (Buffer'First .. Buffer'First + Length - 1);
   end Prefix;

   function Last_Path_Separator (Path : String) return Natural is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '\' or else Path (I) = '/' then
            return I;
         end if;
      end loop;

      return 0;
   end Last_Path_Separator;

   function Is_Already_Included (File_Name : String) return Boolean is
   begin
      for I in 1 .. Include_Count loop
         if Include_Lens (I) = File_Name'Length
           and then Include_Vault (I) (1 .. File_Name'Length) = File_Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Already_Included;

   procedure Register_Include
     (File_Name : String;
      Success   : in out Boolean) is
   begin
      if Include_Count >= Max_Includes or else File_Name'Length > Max_Path_Len then
         Success := False;
         return;
      end if;

      Include_Count := Include_Count + 1;
      Include_Lens (Include_Count) := File_Name'Length;
      Include_Vault (Include_Count) := (others => ' ');
      Include_Vault (Include_Count) (1 .. File_Name'Length) := File_Name;
   end Register_Include;

   procedure Append_Source
     (Text    : String;
      Success : in out Boolean) is
   begin
      if not Success then
         return;
      end if;

      if Input_Len + Text'Length > Max_Input_Size then
         Success := False;
         return;
      end if;

      Input_Buffer (Input_Len + 1 .. Input_Len + Text'Length) := Text;
      Input_Len := Input_Len + Text'Length;
   end Append_Source;

   function Get_Alba_Root return String is
      use GNAT.OS_Lib;
      Exec_Name : constant String := Ada.Command_Line.Command_Name;
      Exec_Path : String_Access := Locate_Exec_On_Path (Exec_Name);
   begin
      if Exec_Path /= null then
         declare
            -- Gets the folder containing alba.exe (e.g., C:\...\AdaLogic_BASIC\src)
            Root_Dir : constant String :=
              Ada.Directories.Containing_Directory (Exec_Path.all);
         begin
            Free (Exec_Path);
            return Root_Dir;
         end;
      end if;

      -- Fallback just in case it can't find itself on the PATH
      return Ada.Directories.Current_Directory;
   end Get_Alba_Root;

   function Is_Absolute_Path (Path : String) return Boolean;
   function Safe_Containing_Directory (Path : String) return String;
   function Compose_Include_Path
     (Dir  : String;
      Leaf : String) return String;

   procedure Parse_Include_Line
     (Line_Text : String;
      Line_Len  : Natural;
      Match     : out Boolean;
      Is_System : out Boolean;
      File_Name : out String;
      File_Len  : out Natural)
   is
      P       : Natural := 1;
      Start   : Natural := 0;
      Stop    : Natural := 0;
      Keyword : constant String := "INCLUDE";
   begin
      Match := False;
      Is_System := False;
      File_Len := 0;
      File_Name := (others => ' ');

      while P <= Line_Len and then
        (Line_Text (P) = ' ' or else Line_Text (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P + Keyword'Length - 1 > Line_Len then
         return;
      end if;

      for I in Keyword'Range loop
         if To_Upper (Line_Text (P + (I - Keyword'First))) /= Keyword (I) then
            return;
         end if;
      end loop;

      P := P + Keyword'Length;
      while P <= Line_Len and then
        (Line_Text (P) = ' ' or else Line_Text (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P > Line_Len then
         return;
      end if;

      if Line_Text (P) = '"' then
         Is_System := False;
         Start := P + 1;
         Stop := Start;
         while Stop <= Line_Len and then Line_Text (Stop) /= '"' loop
            Stop := Stop + 1;
         end loop;

         if Stop <= Line_Len and then Stop > Start then
            File_Len := Stop - Start;
            if File_Len <= File_Name'Length then
               File_Name
                 (File_Name'First .. File_Name'First + File_Len - 1) :=
                   Line_Text (Start .. Stop - 1);
               Match := True;
            end if;
         end if;
      elsif Line_Text (P) = '<' then
         Is_System := True;
         Start := P + 1;
         Stop := Start;
         while Stop <= Line_Len and then Line_Text (Stop) /= '>' loop
            Stop := Stop + 1;
         end loop;

         if Stop <= Line_Len and then Stop > Start then
            File_Len := Stop - Start;
            if File_Len <= File_Name'Length then
               File_Name
                 (File_Name'First .. File_Name'First + File_Len - 1) :=
                   Line_Text (Start .. Stop - 1);
               Match := True;
            end if;
         end if;
      end if;
   end Parse_Include_Line;

   function Compose_Include_Path
     (Dir  : String;
      Leaf : String) return String
   is
   begin
      if Dir'Length = 0 then
         return Leaf;
      elsif Leaf'Length = 0 then
         return Dir;
      elsif Is_Absolute_Path (Leaf) then
         return Leaf;
      end if;

      for I in Leaf'Range loop
         if Leaf (I) = '\' or else Leaf (I) = '/' then
            if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf;
            else
               return Dir & "\" & Leaf;
            end if;
         end if;
      end loop;

      return Ada.Directories.Compose (Dir, Leaf);
   end Compose_Include_Path;

   procedure Weave_File
     (File_Name : String;
      Success   : in out Boolean)
   is
      use type Ada.Streams.Stream_IO.Count;

      type Include_Frame_Array is array (Positive range <>) of Include_Frame;
      Frames : Include_Frame_Array (1 .. Max_Includes);
      Depth  : Natural := 0;

      procedure Close_Frame (Index : Positive) is
      begin
         if Ada.Streams.Stream_IO.Is_Open (Frames (Index).File) then
            Ada.Streams.Stream_IO.Close (Frames (Index).File);
         end if;
      exception
         when Ada.IO_Exceptions.Status_Error |
              Ada.IO_Exceptions.Use_Error |
              Ada.IO_Exceptions.Device_Error =>
            null;
      end Close_Frame;

      procedure Pop_Frame is
      begin
         if Depth = 0 then
            return;
         end if;

         Close_Frame (Depth);
         Frames (Depth).Stream_Ptr := null;
         Frames (Depth).File_Dir := (others => ' ');
         Frames (Depth).File_Dir_Len := 0;
         Frames (Depth).Line_Buffer := (others => ' ');
         Frames (Depth).Line_Len := 0;
         Frames (Depth).Total_Bytes := 0;
         Frames (Depth).Bytes_Read := 0;
         Frames (Depth).Reached_Eof := False;
         Depth := Depth - 1;
      end Pop_Frame;

      procedure Push_File (Path : String) is
         File_Dir : constant String := Safe_Containing_Directory (Path);
      begin
         if not Success or else Is_Already_Included (Path) then
            return;
         end if;

         if Depth >= Max_Includes
           or else Path'Length > Max_Path_Len
           or else File_Dir'Length > Max_Path_Len
         then
            Success := False;
            return;
         end if;

         pragma Assert (Depth < Max_Includes);
         Depth := Depth + 1;
         pragma Assert (Depth <= Max_Includes);
         Frames (Depth).File_Dir := (others => ' ');
         Frames (Depth).File_Dir_Len := File_Dir'Length;
         if File_Dir'Length > 0 then
            Frames (Depth).File_Dir (1 .. File_Dir'Length) := File_Dir;
         end if;
         Frames (Depth).Line_Buffer := (others => ' ');
         Frames (Depth).Line_Len := 0;
         Frames (Depth).Total_Bytes := 0;
         Frames (Depth).Bytes_Read := 0;
         Frames (Depth).Reached_Eof := False;

         begin
            Ada.Streams.Stream_IO.Open
              (Frames (Depth).File,
               Ada.Streams.Stream_IO.In_File,
               Path);
            Frames (Depth).Stream_Ptr :=
              Ada.Streams.Stream_IO.Stream (Frames (Depth).File);
            Frames (Depth).Total_Bytes :=
              Ada.Streams.Stream_IO.Size (Frames (Depth).File);
            Register_Include (Path, Success);
            if not Success then
               Pop_Frame;
            end if;
         exception
            when Ada.IO_Exceptions.Name_Error |
                 Ada.IO_Exceptions.Use_Error |
                 Ada.IO_Exceptions.Status_Error |
                 Ada.IO_Exceptions.Device_Error =>
               Success := False;
               Pop_Frame;
         end;
      end Push_File;

      procedure Flush_Line (Frame_Index : Positive) is
         Include_Match  : Boolean := False;
         Include_System : Boolean := False;
         Include_Name   : String (1 .. Max_Path_Len) := (others => ' ');
         Include_Len    : Natural := 0;
      begin
         Parse_Include_Line
           (Frames (Frame_Index).Line_Buffer,
            Frames (Frame_Index).Line_Len,
            Include_Match,
            Include_System,
            Include_Name,
            Include_Len);

         if Include_Match then
            declare
               Resolved_Include : String (1 .. Max_Path_Len) := (others => ' ');
               Resolved_Len     : Natural := 0;
            begin
               if Include_System then
                  declare
                     Leaf : constant String := Include_Name (1 .. Include_Len);
                     Sys  : constant String :=
                       ALB_System_Includes.Resolve_System_Include (Leaf);
                  begin
                     if not Ada.Directories.Exists (Sys) then
                        Put_Line
                          ("ALBA: FATAL: System include not found: <"
                           & Leaf & "> (searched under "
                           & ALB_System_Includes.Vendor_Root & ")");
                        Success := False;
                     elsif Sys'Length <= Max_Path_Len then
                        Resolved_Len := Sys'Length;
                        Resolved_Include (1 .. Resolved_Len) := Sys;
                     else
                        Success := False;
                     end if;
                  end;
               else
                  declare
                     Rel : constant String :=
                       (if Is_Absolute_Path (Include_Name (1 .. Include_Len))
                           or else Frames (Frame_Index).File_Dir_Len = 0
                        then Include_Name (1 .. Include_Len)
                        else Compose_Include_Path
                          (Prefix
                             (Frames (Frame_Index).File_Dir,
                              Frames (Frame_Index).File_Dir_Len),
                           Include_Name (1 .. Include_Len)));
                  begin
                     if Rel'Length <= Max_Path_Len then
                        Resolved_Len := Rel'Length;
                        Resolved_Include (1 .. Resolved_Len) := Rel;
                     else
                        Success := False;
                     end if;
                  end;
               end if;

               Frames (Frame_Index).Line_Len := 0;
               if Success and then Resolved_Len > 0 then
                  Push_File (Resolved_Include (1 .. Resolved_Len));
               end if;
            end;
         else
            if Frames (Frame_Index).Line_Len > 0 then
               Append_Source
                 (Frames (Frame_Index).Line_Buffer
                    (1 .. Frames (Frame_Index).Line_Len),
                  Success);
            end if;
            Append_Source (ASCII.LF & "", Success);
            Frames (Frame_Index).Line_Len := 0;
         end if;
      end Flush_Line;

      Ch : Character;
   begin
      if not Success then
         return;
      end if;

      Push_File (File_Name);

      while Success and then Depth > 0 loop
         declare
            Current_Frame : constant Positive := Depth;
         begin
            if Frames (Current_Frame).Bytes_Read < Frames (Current_Frame).Total_Bytes then
               Character'Read (Frames (Current_Frame).Stream_Ptr, Ch);
               Frames (Current_Frame).Bytes_Read :=
                 Frames (Current_Frame).Bytes_Read +
                 Ada.Streams.Stream_IO.Count (1);

               if Ch = ASCII.CR then
                  null;
               elsif Ch = ASCII.LF then
                  Flush_Line (Current_Frame);
               elsif Frames (Current_Frame).Line_Len <
                 Frames (Current_Frame).Line_Buffer'Length
               then
                  Frames (Current_Frame).Line_Len :=
                    Frames (Current_Frame).Line_Len + 1;
                  Frames (Current_Frame).Line_Buffer
                    (Frames (Current_Frame).Line_Len) := Ch;
               else
                  Success := False;
               end if;
            elsif not Frames (Current_Frame).Reached_Eof then
               Frames (Current_Frame).Reached_Eof := True;
               if Frames (Current_Frame).Line_Len > 0 then
                  Flush_Line (Current_Frame);
               end if;
            else
               Pop_Frame;
            end if;
         end;
      end loop;

      while Depth > 0 loop
         Pop_Frame;
      end loop;
   end Weave_File;

   function Strip_Extension (File_Name : String) return String is
      Dot_Pos : Natural := 0;
   begin
      for I in reverse File_Name'Range loop
         if File_Name (I) = '.' then
            Dot_Pos := I;
            exit;
         end if;
      end loop;

      if Dot_Pos > File_Name'First then
         return File_Name (File_Name'First .. Dot_Pos - 1);
      end if;

      return File_Name;
   end Strip_Extension;

   function Safe_Simple_Name (Path : String) return String is
      Sep : constant Natural := Last_Path_Separator (Path);
   begin
      if Path'Length = 0 then
         return "";
      elsif Sep = 0 then
         return Path;
      elsif Sep < Path'Last then
         return Path (Sep + 1 .. Path'Last);
      else
         return "";
      end if;
   end Safe_Simple_Name;

   function Simple_Base_Name (Path : String) return String is
      Name : constant String := Safe_Simple_Name (Path);
      Base : constant String := Strip_Extension (Name);
   begin
      if Base'Length = 0 then
         return "alba_main";
      end if;

      return Base;
   end Simple_Base_Name;

   function Safe_Ada_Identifier (Text : String) return String is
      Temp : String (1 .. 128) := (others => '_');
      Len  : Natural := 0;
      Ch   : Character;
   begin
      for I in Text'Range loop
         Ch := Text (I);
         if (Ch in 'A' .. 'Z') or else (Ch in 'a' .. 'z') or else
           (Ch in '0' .. '9') or else Ch = '_'
         then
            if Len < Temp'Length then
               Len := Len + 1;
               Temp (Len) := Ch;
            end if;
         else
            if Len < Temp'Length then
               Len := Len + 1;
               Temp (Len) := '_';
            end if;
         end if;
      end loop;

      if Len = 0 then
         return "ALBA_Main";
      end if;

      if not (Temp (1) in 'A' .. 'Z' or else Temp (1) in 'a' .. 'z') then
         if Len < Temp'Length then
            for I in reverse 1 .. Len loop
               Temp (I + 1) := Temp (I);
            end loop;
            Temp (1) := 'A';
            Len := Len + 1;
         else
            Temp (1) := 'A';
         end if;
      end if;

      return Temp (1 .. Len);
   end Safe_Ada_Identifier;

   function Safe_Containing_Directory (Path : String) return String is
      Sep : constant Natural := Last_Path_Separator (Path);
   begin
      if Path'Length = 0 or else Sep = 0 then
         return "";
      elsif Sep = Path'First then
         return Path (Path'First .. Sep);
      elsif Sep > Path'First and then Path (Sep - 1) = ':' then
         return Path (Path'First .. Sep);
      else
         return Path (Path'First .. Sep - 1);
      end if;
   end Safe_Containing_Directory;

   function Is_Absolute_Path (Path : String) return Boolean is
   begin
      if Path'Length = 0 then
         return False;
      end if;

      if Path (Path'First) = '\' or else Path (Path'First) = '/' then
         return True;
      end if;

      return Path'Length >= 2 and then Path (Path'First + 1) = ':';
   end Is_Absolute_Path;

   function Default_Output_Name (Input : String) return String is
   begin
      return Safe_Ada_Identifier (Simple_Base_Name (Input)) & ".adb";
   end Default_Output_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "ada_" & Simple_Base_Name (Input);
   end Default_Out_Dir;

   function Ensure_Path_Exists
     (Path  : String;
      Label : String) return Boolean
   is
   begin
      if Path'Length = 0 or else Ada.Directories.Exists (Path) then
         return True;
      end if;

      Ada.Directories.Create_Path (Path);
      return True;
   exception
      when E : Ada.IO_Exceptions.Name_Error |
               Ada.IO_Exceptions.Use_Error |
               Ada.IO_Exceptions.Device_Error =>
         Put_Line
           ("ALBA: could not create " &
            Label &
            ": " &
            Ada.Exceptions.Exception_Message (E));
         return False;
   end Ensure_Path_Exists;

   procedure Print_Help is
   begin
      Put_Line ("ALBA: AdaLogic BASIC for Ada");
      Put_Line ("Usage: alba [options] <input.alb> [output.adb]");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  -o <file>             Output .adb file");
      Put_Line ("  --outdir <dir>        Output directory");
      Put_Line ("  --build, -b           Package output in a deterministic Ada build directory");
      Put_Line ("  --gprbuild            Use gprbuild for Ada builds (default)");
      Put_Line ("  --gnatmake            Use gnatmake for Ada builds");
      Put_Line ("  --help, -h            Show this help");
      New_Line;
      Put_Line ("Legacy forms are still accepted:");
      Put_Line ("  alba compile <input.alb> [--gprbuild | --gnatmake]");
   end Print_Help;

   procedure Store_Path
     (Text   : String;
      Buffer : out String;
      Length : out Natural;
      Label  : String)
   is
   begin
      Buffer := (others => ' ');
      if Text'Length > Buffer'Length then
         Put_Line ("ALBA: " & Label & " path is too long: " & Text);
         Length := 0;
         Arg_Error := True;
      else
         Length := Text'Length;
         Buffer (Buffer'First .. Buffer'First + Length - 1) := Text;
      end if;
   end Store_Path;

   function Find_Alba_Library_Dir return String is
      Exec_Dir : constant String := Get_Alba_Root;
      Project_Dir : constant String :=
        (if Exec_Dir'Length > 0
         then Safe_Containing_Directory (Exec_Dir)
         else "");
      Working_ALBA : constant String :=
        Ada.Directories.Compose (Ada.Directories.Current_Directory, "ALBA");
      Exec_ALBA : constant String :=
        (if Exec_Dir'Length > 0
         then Ada.Directories.Compose (Exec_Dir, "ALBA")
         else "");
      Project_ALBA : constant String :=
        (if Project_Dir'Length > 0
         then Ada.Directories.Compose
           (Ada.Directories.Compose (Project_Dir, "src"),
            "ALBA")
         else "");
      Working_Legacy : constant String :=
        Ada.Directories.Compose (Ada.Directories.Current_Directory, "alba_lib");
      Exec_Legacy : constant String :=
        (if Exec_Dir'Length > 0
         then Ada.Directories.Compose (Exec_Dir, "alba_lib")
         else "");
      function Has_Runtime_Siblings (Library_Dir : String) return Boolean is
         Root_Dir : constant String :=
           (if Library_Dir'Length > 0
            then Safe_Containing_Directory (Library_Dir)
            else "");
      begin
         return Root_Dir'Length > 0
           and then Ada.Directories.Exists
             (Ada.Directories.Compose (Root_Dir, "TYPES"))
           and then Ada.Directories.Exists
             (Ada.Directories.Compose (Root_Dir, "CORE"));
      end Has_Runtime_Siblings;
   begin
      if Ada.Directories.Exists (Working_ALBA)
        and then Has_Runtime_Siblings (Working_ALBA)
      then
         return Working_ALBA;
      elsif Exec_ALBA'Length > 0
        and then Ada.Directories.Exists (Exec_ALBA)
        and then Has_Runtime_Siblings (Exec_ALBA)
      then
         return Exec_ALBA;
      elsif Project_ALBA'Length > 0
        and then Ada.Directories.Exists (Project_ALBA)
        and then Has_Runtime_Siblings (Project_ALBA)
      then
         return Project_ALBA;
      elsif Ada.Directories.Exists (Working_Legacy)
        and then Has_Runtime_Siblings (Working_Legacy)
      then
         return Working_Legacy;
      elsif Exec_Legacy'Length > 0
        and then Ada.Directories.Exists (Exec_Legacy)
        and then Has_Runtime_Siblings (Exec_Legacy)
      then
         return Exec_Legacy;
      elsif Project_ALBA'Length > 0 and then Ada.Directories.Exists (Project_ALBA) then
         return Project_ALBA;
      elsif Ada.Directories.Exists (Working_ALBA) then
         return Working_ALBA;
      elsif Exec_ALBA'Length > 0 and then Ada.Directories.Exists (Exec_ALBA) then
         return Exec_ALBA;
      elsif Ada.Directories.Exists (Working_Legacy) then
         return Working_Legacy;
      elsif Exec_Legacy'Length > 0 and then Ada.Directories.Exists (Exec_Legacy) then
         return Exec_Legacy;
      else
         return "";
      end if;
   end Find_Alba_Library_Dir;

   function Prepare_Source
     (Input_Path : String) return Boolean is
      Success : Boolean := True;
   begin
      Input_Len := 0;
      Include_Count := 0;
      Token_Count := 0;
      Root := 0;
      Parse_Success := False;

      Weave_File (Input_Path, Success);
      if not Success or else Input_Len = 0 then
         Put_Line ("ALBA: failed to read or weave source " & Input_Path);
         return False;
      end if;

      Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, Lex_Diag);
      if not Lex_Diag.Success then
         Put_Line
           ("ALBA: lexer failure at line" &
            Trim_Image (Lex_Diag.Error_Line) &
            ":" &
            Trim_Image (Lex_Diag.Error_Col));
         Put_Line ("ALBA: oracle code " & Oracle_Code'Image (Lex_Diag.Code));
         return False;
      end if;

      Parse (Tokens, Token_Count, Tree, Root, Parse_Success, Parse_Diag);
      if not Parse_Success then
         Put_Line
           ("ALBA: parser failure at line" &
            Trim_Image (Parse_Diag.Error_Line) &
            ":" &
            Trim_Image (Parse_Diag.Error_Col));
         Put_Line ("ALBA: oracle code " & Oracle_Code'Image (Parse_Diag.Code));
         return False;
      end if;

      return True;
   end Prepare_Source;

   procedure Parse_Args is
      Skip_Next   : Boolean := False;
      Start_Index : Positive := 1;
   begin
      if Ada.Command_Line.Argument_Count >= 1
        and then Ada.Command_Line.Argument (1) = "compile"
      then
         Build_Mode := True;
         Start_Index := 2;
      end if;

      for I in Start_Index .. Ada.Command_Line.Argument_Count loop
         if Skip_Next then
            Skip_Next := False;
         else
            declare
               Arg     : constant String := Ada.Command_Line.Argument (I);
               Gfx_Err : Boolean;
               Gfx_Skip : Boolean;
            begin
               if ALB_System_Includes.Try_Parse_Gfx_Arg
                 (Arg,
                  (if I < Ada.Command_Line.Argument_Count
                   then Ada.Command_Line.Argument (I + 1)
                   else ""),
                  I < Ada.Command_Line.Argument_Count,
                  Gfx_Skip,
                  Gfx_Err)
               then
                  if Gfx_Err then
                     Put_Line
                       ("ALBA: FATAL: Unknown --gfx backend (use opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12).");
                     Arg_Error := True;
                  end if;
                  if Gfx_Skip then
                     Skip_Next := True;
                  end if;
               elsif Arg = "-o" then
                  if I < Ada.Command_Line.Argument_Count then
                     Store_Path
                       (Ada.Command_Line.Argument (I + 1),
                        Output_File,
                        Output_Len,
                        "output");
                     Skip_Next := True;
                  else
                     Put_Line ("ALBA: '-o' requires a filename.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--outdir" then
                  if I < Ada.Command_Line.Argument_Count then
                     Store_Path
                       (Ada.Command_Line.Argument (I + 1),
                        Out_Dir,
                        Out_Dir_Len,
                        "output directory");
                     Skip_Next := True;
                  else
                     Put_Line ("ALBA: '--outdir' requires a directory.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--build" or else Arg = "-b" then
                  Build_Mode := True;
               elsif Arg = "--gnatmake" then
                  Use_Gprbuild_Mode := False;
               elsif Arg = "--gprbuild" then
                  Use_Gprbuild_Mode := True;
               elsif Arg = "--help" or else Arg = "-h" then
                  Print_Help;
                  Arg_Error := True;
               elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
                  Put_Line ("ALBA: unknown option " & Arg);
                  Arg_Error := True;
               else
                  if Source_Len = 0 then
                     Store_Path (Arg, Source_File, Source_Len, "input");
                  elsif Output_Len = 0 then
                     Store_Path (Arg, Output_File, Output_Len, "output");
                  else
                     Put_Line ("ALBA: unexpected extra argument " & Arg);
                     Arg_Error := True;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Parse_Args;

   procedure Resolve_Output_Paths is
   begin
      if Build_Mode and then Out_Dir_Len = 0 and then Output_Len = 0 then
         Store_Path
           (Default_Out_Dir (Source_File (1 .. Source_Len)),
            Out_Dir,
            Out_Dir_Len,
            "output directory");
      end if;

      if Build_Mode then
         if Out_Dir_Len > 0 then
            Store_Path
              (Out_Dir (1 .. Out_Dir_Len),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         elsif Output_Len > 0
           and then Safe_Containing_Directory (Output_File (1 .. Output_Len))'Length > 0
         then
            Store_Path
              (Safe_Containing_Directory (Output_File (1 .. Output_Len)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         else
            Store_Path
              (Default_Out_Dir (Source_File (1 .. Source_Len)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;

         if Output_Len = 0 then
            Store_Path
              (Ada.Directories.Compose
                 (Final_Dir (1 .. Final_Dir_Len),
                  Default_Output_Name (Source_File (1 .. Source_Len))),
               Output_File,
               Output_Len,
               "output");
         elsif Safe_Containing_Directory (Output_File (1 .. Output_Len)) = "" then
            Store_Path
              (Ada.Directories.Compose
                 (Final_Dir (1 .. Final_Dir_Len),
                  Output_File (1 .. Output_Len)),
               Output_File,
               Output_Len,
               "output");
         else
            Store_Path
              (Safe_Containing_Directory (Output_File (1 .. Output_Len)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;
      else
         if Output_Len = 0 then
            if Out_Dir_Len > 0 then
               Store_Path
                 (Ada.Directories.Compose
                    (Out_Dir (1 .. Out_Dir_Len),
                     Default_Output_Name (Source_File (1 .. Source_Len))),
                  Output_File,
                  Output_Len,
                  "output");
               Store_Path
                 (Out_Dir (1 .. Out_Dir_Len),
                  Final_Dir,
                  Final_Dir_Len,
                  "output directory");
            else
               Store_Path
                 (Default_Output_Name (Source_File (1 .. Source_Len)),
                  Output_File,
                  Output_Len,
                  "output");
            end if;
         elsif Out_Dir_Len > 0
           and then not Is_Absolute_Path (Output_File (1 .. Output_Len))
           and then Safe_Containing_Directory (Output_File (1 .. Output_Len)) = ""
         then
            Store_Path
              (Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Output_File (1 .. Output_Len)),
               Output_File,
               Output_Len,
               "output");
            Store_Path
              (Out_Dir (1 .. Out_Dir_Len),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;

         if Final_Dir_Len = 0
           and then Output_Len > 0
           and then Safe_Containing_Directory (Output_File (1 .. Output_Len))'Length > 0
         then
            Store_Path
              (Safe_Containing_Directory (Output_File (1 .. Output_Len)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;
      end if;
   end Resolve_Output_Paths;

   procedure Emit_Ada_Source
     (Input_Path  : String;
      Output_Path : String;
      Success     : out Boolean) is
      Main_Name : constant String :=
        Safe_Ada_Identifier (Simple_Base_Name (Input_Path));
   begin
      Success := False;

      if not Prepare_Source (Input_Path) then
         return;
      end if;

      begin
         Emit_Native_Ada.Emit_Program
           (Source       => Input_Buffer (1 .. Input_Len),
            Tokens       => Tokens,
            Token_Count  => Token_Count,
            Tree         => Tree,
            Root         => Root,
            Program_Name => Main_Name,
            Output_Path  => Output_Path,
            Success      => Success);
      exception
         when E : others =>
            Success := False;
            Put_Line
              ("ALBA: emit exception " &
               Ada.Exceptions.Exception_Name (E) &
               ": " &
               Ada.Exceptions.Exception_Message (E));
      end;
   end Emit_Ada_Source;

   function Write_Build_Project
     (Project_File : String;
      Project_Name : String;
      Main_Source  : String;
      Support_Dir  : String;
      Runtime_Root : String;
      Types_Dir    : String;
      Core_Dir     : String) return Boolean
   is
      Max_DLL_Libraries : constant := 256;
      subtype Library_Path is String (1 .. Max_Path_Len);
      Library_Paths : array (1 .. Max_DLL_Libraries) of Library_Path :=
        (others => (others => ' '));
      Library_Lens : array (1 .. Max_DLL_Libraries) of Natural := (others => 0);
      Library_Count : Natural := 0;
      File_Handle : Ada.Text_IO.File_Type;

      function Import_Library_Name (Path_Node : Node_Index) return String is
         Raw : Ada.Strings.Unbounded.Unbounded_String;
      begin
         if Path_Node > 0 and then Tree (Path_Node).Token_Index > 0 then
            declare
               Tok : constant Token := Tokens (Tree (Path_Node).Token_Index);
            begin
               Raw := Ada.Strings.Unbounded.To_Unbounded_String
                 (Input_Buffer (Tok.Start .. Tok.Start + Tok.Length - 1));
            end;
         else
            Raw := Ada.Strings.Unbounded.To_Unbounded_String ("");
         end if;

         declare
            Text : constant String := Ada.Strings.Unbounded.To_String (Raw);
         begin
            if Text'Length >= 2
              and then ((Text (Text'First) = '"' and then Text (Text'Last) = '"')
                        or else (Text (Text'First) = '`' and then Text (Text'Last) = '`'))
            then
               return Text (Text'First + 1 .. Text'Last - 1);
            end if;
            return Text;
         end;
      end Import_Library_Name;

      procedure Add_Library (Path : String) is
         Upper_Path : constant String := Ada.Characters.Handling.To_Upper (Path);
      begin
         if Path'Length = 0 or else Path'Length > Max_Path_Len then
            return;
         end if;

         for I in 1 .. Library_Count loop
            if Library_Lens (I) = Path'Length
              and then Ada.Characters.Handling.To_Upper
                (Library_Paths (I) (1 .. Library_Lens (I))) = Upper_Path
            then
               return;
            end if;
         end loop;

         if Library_Count < Max_DLL_Libraries then
            Library_Count := Library_Count + 1;
            Library_Paths (Library_Count) := (others => ' ');
            Library_Paths (Library_Count) (1 .. Path'Length) := Path;
            Library_Lens (Library_Count) := Path'Length;
         end if;
      end Add_Library;

      procedure Collect_Imports (Idx : Node_Index) is
      begin
         if Idx = 0 then
            return;
         end if;

         if Tree (Idx).Kind = AST_Import_DLL then
            Add_Library (Import_Library_Name (Tree (Idx).Right_Child));
         end if;

         Collect_Imports (Tree (Idx).Left_Child);
         Collect_Imports (Tree (Idx).Right_Child);
         Collect_Imports (Tree (Idx).Next_Sibling);
      end Collect_Imports;
   begin
      Collect_Imports (Root);
      Ada.Text_IO.Create (File_Handle, Ada.Text_IO.Out_File, Project_File);
      Ada.Text_IO.Put_Line (File_Handle, "project " & Project_Name & " is");
      Ada.Text_IO.Put_Line (File_Handle, "   for Languages use (""Ada"");");
      Ada.Text_IO.Put_Line
        (File_Handle,
         "   for Source_Dirs use (""."", """ &
         Support_Dir &
         """, """ &
         Runtime_Root &
         """, """ &
         Types_Dir &
         """, """ &
         Core_Dir &
         """);");
      Ada.Text_IO.Put_Line (File_Handle, "   package Compiler is");
      Ada.Text_IO.Put_Line
        (File_Handle,
         "      for Default_Switches (""Ada"") use (""-I."", ""-I" &
         Support_Dir &
         """, ""-I" &
         Runtime_Root &
         """, ""-I" &
         Types_Dir &
         """, ""-I" &
         Core_Dir &
         """, ""-gnata"", ""-gnataf"");");
      Ada.Text_IO.Put_Line (File_Handle, "   end Compiler;");
      Ada.Text_IO.Put_Line (File_Handle, "   for Object_Dir use ""obj"";");
      Ada.Text_IO.Put_Line (File_Handle, "   for Exec_Dir use ""."";");
      Ada.Text_IO.Put_Line
        (File_Handle,
         "   for Main use (""" & Main_Source & """);");
      if Library_Count > 0 then
         Ada.Text_IO.Put_Line (File_Handle, "   package Linker is");
         Ada.Text_IO.Put (File_Handle, "      for Default_Switches (""Ada"") use (""-L.""");
         for I in 1 .. Library_Count loop
            Ada.Text_IO.Put
              (File_Handle,
               ", ""-l:" & Library_Paths (I) (1 .. Library_Lens (I)) & """");
         end loop;
         Ada.Text_IO.Put_Line (File_Handle, ");");
         Ada.Text_IO.Put_Line (File_Handle, "   end Linker;");
      end if;
      Ada.Text_IO.Put_Line (File_Handle, "end " & Project_Name & ";");
      Ada.Text_IO.Close (File_Handle);
      return True;
   exception
      when E : Ada.IO_Exceptions.Name_Error |
               Ada.IO_Exceptions.Use_Error |
               Ada.IO_Exceptions.Status_Error |
               Ada.IO_Exceptions.Device_Error =>
         if Ada.Text_IO.Is_Open (File_Handle) then
            Ada.Text_IO.Close (File_Handle);
         end if;

         Put_Line
           ("ALBA: could not write build project: " &
            Ada.Exceptions.Exception_Message (E));
         return False;
   end Write_Build_Project;

   procedure Run_Compile_Pipeline
     (Input_Path    : String;
      Output_Path   : String;
      Output_Exe    : String;
      Working_Dir   : String;
      Use_Gprbuild  : Boolean := True)
   is
      Builder_Cmd  : constant String :=
        (if Use_Gprbuild then "gprbuild" else "gnatmake");
      Support_Dir  : constant String := Find_Alba_Library_Dir;
      Runtime_Root : constant String :=
        (if Support_Dir'Length > 0
         then Safe_Containing_Directory (Support_Dir)
         else "");
      Types_Dir    : constant String :=
        (if Runtime_Root'Length > 0
         then Ada.Directories.Compose (Runtime_Root, "TYPES")
         else "");
      Core_Dir     : constant String :=
        (if Runtime_Root'Length > 0
         then Ada.Directories.Compose (Runtime_Root, "CORE")
         else "");
      Source_Dir   : constant String :=
        (if Safe_Containing_Directory (Input_Path)'Length > 0
         then Safe_Containing_Directory (Input_Path)
         else Ada.Directories.Current_Directory);
      Main_Source  : constant String :=
        Safe_Simple_Name (Output_Path);
      Project_Name : constant String :=
        Safe_Ada_Identifier (Simple_Base_Name (Output_Path)) & "_build";
      Project_File : constant String :=
        Ada.Directories.Compose (Working_Dir, Project_Name & ".gpr");
      Success      : Boolean := False;
   begin
      if Support_Dir'Length = 0 then
         Put_Line ("ALBA: could not locate the ALBA runtime support directory.");
         return;
      end if;

      if not Ensure_Path_Exists (Working_Dir, "output directory") then
         return;
      end if;

      Emit_Ada_Source (Input_Path, Output_Path, Success);
      if not Success then
         Put_Line ("ALBA: failed to emit Ada source.");
         return;
      end if;

      if Use_Gprbuild then
         Success :=
           Write_Build_Project
             (Project_File,
              Project_Name,
              Main_Source,
              Support_Dir,
              Runtime_Root,
              Types_Dir,
              Core_Dir);
         if not Success then
            return;
         end if;

         Put_Line ("ALBA: compiling " & Output_Path & " with " & Builder_Cmd);
         Success :=
           ALBA_Spawn.Run_Gprbuild
             (Working_Dir,
              Builder_Cmd,
              Ada.Directories.Full_Name (Project_File));
      else
         Put_Line ("ALBA: compiling " & Output_Path & " with " & Builder_Cmd);
         Success :=
           ALBA_Spawn.Run_Gnatmake
             (Working_Dir,
              Builder_Cmd,
              Source_Dir,
              Support_Dir,
              Runtime_Root,
              Types_Dir,
              Core_Dir,
              Main_Source,
              Output_Exe);
      end if;

      if not Success then
         Put_Line
           ("ALBA: " & Builder_Cmd &
            " failed or was not found. Ensure the Ada toolchain is on your PATH.");
      else
         Put_Line ("ALBA: built " & Output_Exe);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      end if;
   end Run_Compile_Pipeline;

begin
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);

   if Ada.Command_Line.Argument_Count < 1 then
      Print_Help;
      return;
   end if;

   Parse_Args;
   if Arg_Error then
      return;
   end if;

   if Source_Len = 0 then
      Put_Line ("ALBA: no input file provided.");
      Print_Help;
      return;
   end if;

   Resolve_Output_Paths;
   if Arg_Error or else Output_Len = 0 then
      return;
   end if;

   if Final_Dir_Len > 0
     and then not Ensure_Path_Exists
       (Final_Dir (1 .. Final_Dir_Len), "output directory")
   then
      return;
   end if;

   if Build_Mode then
      declare
         Exe_Path : constant String :=
           Ada.Directories.Compose
             ((if Final_Dir_Len > 0
               then Final_Dir (1 .. Final_Dir_Len)
               else Ada.Directories.Current_Directory),
              Safe_Ada_Identifier (Simple_Base_Name (Source_File (1 .. Source_Len))) &
              ".exe");
      begin
         Run_Compile_Pipeline
           (Source_File (1 .. Source_Len),
            Output_File (1 .. Output_Len),
            Exe_Path,
            (if Final_Dir_Len > 0
             then Final_Dir (1 .. Final_Dir_Len)
             else Ada.Directories.Current_Directory),
            Use_Gprbuild_Mode);
      end;
   else
      declare
         Success : Boolean := False;
      begin
         Emit_Ada_Source
           (Source_File (1 .. Source_Len),
            Output_File (1 .. Output_Len),
            Success);

         if not Success then
            Put_Line ("ALBA: failed to emit Ada source.");
         else
            Put_Line ("ALBA: emitted " & Output_File (1 .. Output_Len));
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
         end if;
      end;
   end if;
end ALBA;
