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

pragma SPARK_Mode (On);

with Ada.Command_Line;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Text_IO; use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with Parser;         use Parser;
with AST;            use AST;
with ALB_Oracle;     use ALB_Oracle;
with Code_Information;
with Emit_Native_DotNet;
with ALB_System_Includes;


procedure ALBN is

   type Target_Backend is (Backend_DotNet);
   Target : constant Target_Backend := Backend_DotNet;
   pragma Unreferenced (Target);

   Max_Path_Len   : constant Natural := 512;
   Max_Line_Len   : constant Natural := 8192;
   Max_Includes   : constant Natural := 2048;
   Max_Input_Size : constant Natural := Input_Buffer'Length;

   Input_Len     : Natural := 0;
   Token_Count   : Natural := 0;
   Root          : Node_Index := 0;
   Parse_Success : Boolean := False;

   Lex_Diag   : Lexer_Diagnostic;
   Parse_Diag : Parser_Diagnostic;

   Source_File : String (1 .. Max_Path_Len) := (others => ' ');
   Source_Len  : Natural := 0;
   Output_File : String (1 .. Max_Path_Len) := (others => ' ');
   Output_Len  : Natural := 0;

   Out_Dir     : String (1 .. Max_Path_Len) := (others => ' ');
   Out_Dir_Len : Natural := 0;

   Final_Dir     : String (1 .. Max_Path_Len) := (others => ' ');
   Final_Dir_Len : Natural := 0;
   CS_Path       : String (1 .. Max_Path_Len) := (others => ' ');
   CS_Len        : Natural := 0;
   Project_Name  : String (1 .. Max_Path_Len) := (others => ' ');
   Project_Len   : Natural := 0;

   Framework     : String (1 .. 32) := (others => ' ');
   Framework_Len : Natural := 0;
   Lang_Version     : String (1 .. 32) := (others => ' ');
   Lang_Version_Len : Natural := 0;
   Nullable_Mode     : String (1 .. 16) := (others => ' ');
   Nullable_Mode_Len : Natural := 0;

   Quiet_Mode   : Boolean := False;
   Metrics_Mode : Boolean := False;
   Walker_Mode  : Boolean := False;
   Build_Mode   : Boolean := False;
   Unsafe_Mode  : Boolean := False;
   Arg_Error    : Boolean := False;

   Include_Vault : array (1 .. Max_Includes) of String (1 .. Max_Path_Len) :=
     (others => (others => ' '));
   Include_Lens  : array (1 .. Max_Includes) of Natural := (others => 0);
   Include_Count : Natural := 0;
   Project_Write_Succeeded : Boolean := True;
   Weave_Diag    : Weaver_Diagnostic_Log;
   Emit_Diag     : Emitter_Diagnostic_Log;

   function To_Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
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

   procedure Log (Msg : String) is
   begin
      if not Quiet_Mode then
         Put_Line (Msg);
      end if;
   end Log;

   procedure Store_Path_Text
     (Text   : in String;
      Buffer : out Diagnostic_Path_Buffer;
      Length : out Natural)
   is
      Copy_Len : constant Natural :=
        (if Text'Length > Max_Diagnostic_Path_Len
         then Max_Diagnostic_Path_Len
         else Text'Length);
   begin
      Buffer := (others => ' ');
      Length := Copy_Len;
      for I in 1 .. Copy_Len loop
         Buffer (I) := Text (Text'First + I - 1);
      end loop;
   end Store_Path_Text;

   procedure Store_Message_Text
     (Text   : in String;
      Buffer : out Diagnostic_Message_Buffer;
      Length : out Natural)
   is
      Copy_Len : constant Natural :=
        (if Text'Length > Max_Diagnostic_Message_Len
         then Max_Diagnostic_Message_Len
         else Text'Length);
   begin
      Buffer := (others => ' ');
      Length := Copy_Len;
      for I in 1 .. Copy_Len loop
         Buffer (I) := Text (Text'First + I - 1);
      end loop;
   end Store_Message_Text;

   procedure Add_Weave_Warning
     (File_Name : in String;
      Line_No   : in Natural;
      Category  : in Weaver_Diagnostic_Category;
      Message   : in String) is
      Prefix : constant String :=
        (if Line_No > 0
         then File_Name & ":" & Trim_Image (Integer (Line_No))
         else File_Name);
      Slot : Natural := 0;
   begin
      Weave_Diag.Had_Warnings := True;
      Weave_Diag.Warning_Count := Weave_Diag.Warning_Count + 1;
      Compilation_Had_Warnings := True;

      if Weave_Diag.Stored_Count < Max_Weaver_Diagnostics then
         Weave_Diag.Stored_Count := Weave_Diag.Stored_Count + 1;
         Slot := Weave_Diag.Stored_Count;
         Weave_Diag.Entries (Slot).Active := True;
         Store_Path_Text
           (File_Name,
            Weave_Diag.Entries (Slot).File_Path,
            Weave_Diag.Entries (Slot).File_Len);
         Weave_Diag.Entries (Slot).Line := Line_No;
         Weave_Diag.Entries (Slot).Category := Category;
         Store_Message_Text
           (Message,
            Weave_Diag.Entries (Slot).Message,
            Weave_Diag.Entries (Slot).Message_Len);
      end if;

      Put_Line ("ALBN WARNING [weave]: " & Prefix & " -> " & Message);
   end Add_Weave_Warning;

   procedure Print_Warning_Summary is
   begin
      if not Weave_Diag.Had_Warnings and then not Emit_Diag.Had_Warnings then
         return;
      end if;

      Put_Line
        ("ALBN: compilation finished with " &
         Trim_Image (Integer (Weave_Diag.Warning_Count)) &
         " weave warning(s) and " &
         Trim_Image (Integer (Emit_Diag.Warning_Count)) &
         " emitter warning(s).");
   end Print_Warning_Summary;

   function Parent_Directory (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '\' or else Path (I) = '/' then
            return Path (Path'First .. I);
         end if;
      end loop;
      return "";
   end Parent_Directory;

   function Base_Name (Path : String) return String is
   begin
      if Path'Length = 0 then
         Add_Weave_Warning
           ("<output>",
            0,
            Weaver_Path_Parse_Failure,
            "empty path encountered during output name resolution; using UNRESOLVED_NAME");
         return "UNRESOLVED_NAME";
      end if;

      declare
         Raw : constant String := Ada.Directories.Base_Name (Path);
         Dot : Natural := 0;
      begin
         for I in reverse Raw'Range loop
            if Raw (I) = '.' then
               Dot := I;
               exit;
            end if;
         end loop;

         if Dot > Raw'First then
            return Raw (Raw'First .. Dot - 1);
         end if;
         return Raw;
      end;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         Add_Weave_Warning
           (Path,
            0,
            Weaver_Path_Parse_Failure,
            "path could not be parsed; using UNRESOLVED_NAME");
         return "UNRESOLVED_NAME";
   end Base_Name;

   function File_Name_With_Extension (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '\' or else Path (I) = '/' then
            if I < Path'Last then
               return Path (I + 1 .. Path'Last);
            else
               return "output.cs";
            end if;
         end if;
      end loop;
      return Path;
   end File_Name_With_Extension;

   function Safe_Project_Name (Name : String) return String is
      Result : String (1 .. Name'Length) := Name;
   begin
      for I in Result'Range loop
         if not
           ((Result (I) in 'a' .. 'z') or else
            (Result (I) in 'A' .. 'Z') or else
            (Result (I) in '0' .. '9') or else
            Result (I) = '_')
         then
            Result (I) := '_';
         end if;
      end loop;
      return Result;
   end Safe_Project_Name;

   function Default_Output_Name (Input : String) return String is
   begin
      return Base_Name (Input) & ".cs";
   end Default_Output_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "dotnet_" & Base_Name (Input);
   end Default_Out_Dir;

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

   procedure Print_Help is
   begin
      Put_Line ("ALBN: AdaLogic BASIC for .NET/C#");
      Put_Line ("Usage: albn [options] <input.alb> [output.cs]");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  -o <file>             Output .cs file");
      Put_Line ("  --outdir <dir>        Output directory");
      Put_Line ("  --build, -b           Package output in a deterministic C# project directory");
      Put_Line ("  --framework <tfm>     C# project target framework (default: net8.0)");
      Put_Line ("  --langversion <ver>   C# language version in generated project (default: latest)");
      Put_Line ("  --nullable <mode>     C# nullable setting in generated project (default: disable)");
      Put_Line ("  --unsafe              Enable unsafe blocks in generated project metadata");
      Put_Line ("  --metrics, -m         Show source metrics after compilation");
      Put_Line ("  --walker, -w          Show AST root and token information");
      Put_Line ("  --quiet, -q           Suppress informational messages");
      Put_Line ("  --help, -h            Show this help");
   end Print_Help;

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

   function Try_Register_Include
     (File_Name : String;
      Line_No   : Natural) return Boolean
   is
   begin
      if Include_Count >= Max_Includes then
         Add_Weave_Warning
           (File_Name,
            Line_No,
            Weaver_Include_Limit_Reached,
            "include table is full; skipping file");
         return False;
      end if;

      if File_Name'Length > Max_Path_Len then
         Add_Weave_Warning
           (File_Name,
            Line_No,
            Weaver_Path_Too_Long,
            "include path is too long; skipping file");
         return False;
      end if;

      Include_Count := Include_Count + 1;
      Include_Lens (Include_Count) := File_Name'Length;
      Include_Vault (Include_Count) := (others => ' ');
      Include_Vault (Include_Count) (1 .. File_Name'Length) := File_Name;
      return True;
   end Try_Register_Include;

   procedure Append_Source
     (Text      : in String;
      File_Name : in String;
      Line_No   : in Natural;
      Success   : in out Boolean) is
   begin
      if not Success then
         return;
      end if;

      if Input_Len + Text'Length > Max_Input_Size then
         Add_Weave_Warning
           (File_Name,
            Line_No,
            Weaver_Buffer_Overflow,
            "input buffer overflow while weaving source");
         Weave_Diag.Had_Fatal_Error := True;
         Success := False;
         return;
      end if;

      Input_Buffer (Input_Len + 1 .. Input_Len + Text'Length) := Text;
      Input_Len := Input_Len + Text'Length;
   end Append_Source;

   procedure Parse_Include_Line
     (Line_Text : in String;
      Line_Len  : in Natural;
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

   procedure Weave_File
     (File_Name    : in String;
      Success      : in out Boolean;
      Include_Line : in Natural := 0;
      Is_Include   : in Boolean := False)
   is
      File       : Ada.Text_IO.File_Type;
      Line       : String (1 .. Max_Line_Len) := (others => ' ');
      Last       : Natural := 0;
      Line_No    : Natural := 0;
      File_Dir   : constant String := Parent_Directory (File_Name);
      Inc_Name    : String (1 .. Max_Path_Len) := (others => ' ');
      Inc_Len     : Natural := 0;
      Inc_Match   : Boolean := False;
      Inc_System  : Boolean := False;
      Resolved   : String (1 .. Max_Path_Len) := (others => ' ');
      Res_Len    : Natural := 0;
   begin
      if not Success or else Is_Already_Included (File_Name) then
         return;
      end if;

      Log ("  weaving: " & File_Name);

      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, File_Name);
      exception
         when Ada.IO_Exceptions.Name_Error =>
            Add_Weave_Warning
              (File_Name,
               Include_Line,
               (if Is_Include then Weaver_Missing_Include else Weaver_File_Open_Failure),
               "file was not found while weaving");
            if not Is_Include then
               Weave_Diag.Had_Fatal_Error := True;
               Success := False;
            end if;
            return;

         when Ada.IO_Exceptions.Use_Error |
              Ada.IO_Exceptions.Status_Error |
              Ada.IO_Exceptions.Device_Error =>
            Add_Weave_Warning
              (File_Name,
               Include_Line,
               Weaver_File_Open_Failure,
               "file could not be opened while weaving");
            if not Is_Include then
               Weave_Diag.Had_Fatal_Error := True;
               Success := False;
            end if;
            return;
      end;

      if not Try_Register_Include (File_Name, Include_Line) then
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return;
      end if;

      while not Ada.Text_IO.End_Of_File (File) loop
         begin
            Ada.Text_IO.Get_Line (File, Line, Last);
            Line_No := Line_No + 1;
         exception
            when Ada.IO_Exceptions.End_Error =>
               exit;

            when Ada.IO_Exceptions.Data_Error |
                 Ada.IO_Exceptions.Use_Error |
                 Ada.IO_Exceptions.Status_Error |
                 Ada.IO_Exceptions.Device_Error =>
               Add_Weave_Warning
                 (File_Name,
                  (if Line_No = 0 then Include_Line else Line_No),
                  Weaver_File_Read_Failure,
                  "file read failed while weaving");
               if Is_Include then
                  exit;
               end if;
               Weave_Diag.Had_Fatal_Error := True;
               Success := False;
               exit;
         end;

         Parse_Include_Line
           (Line, Last, Inc_Match, Inc_System, Inc_Name, Inc_Len);

         if Inc_Match then
            Res_Len := 0;
            if Inc_System then
               declare
                  Leaf : constant String := Inc_Name (1 .. Inc_Len);
                  Sys  : constant String :=
                    ALB_System_Includes.Resolve_System_Include (Leaf);
               begin
                  if not Ada.Directories.Exists (Sys) then
                     Put_Line
                       ("ALBN: FATAL: System include not found: <"
                        & Leaf & "> (searched under "
                        & ALB_System_Includes.Vendor_Root & ")");
                     Weave_Diag.Had_Fatal_Error := True;
                     Success := False;
                  elsif Sys'Length <= Max_Path_Len then
                     Res_Len := Sys'Length;
                     Resolved (1 .. Res_Len) := Sys;
                  else
                     Add_Weave_Warning
                       (File_Name,
                        Line_No,
                        Weaver_Path_Too_Long,
                        "resolved system include path is too long");
                  end if;
               end;
            elsif Is_Absolute_Path (Inc_Name (1 .. Inc_Len)) then
               Res_Len := Inc_Len;
               Resolved (1 .. Res_Len) := Inc_Name (1 .. Inc_Len);
            else
               Res_Len := File_Dir'Length + Inc_Len;
               if Res_Len <= Max_Path_Len then
                  Resolved (1 .. File_Dir'Length) := File_Dir;
                  Resolved (File_Dir'Length + 1 .. Res_Len) :=
                    Inc_Name (1 .. Inc_Len);
               else
                  Add_Weave_Warning
                    (File_Name,
                     Line_No,
                     Weaver_Path_Too_Long,
                     "resolved include path is too long; skipping include");
                  Res_Len := 0;
                end if;
            end if;
            if Res_Len > 0 then
               Weave_File (Resolved (1 .. Res_Len), Success, Line_No, True);
            end if;
         else
            if Last > 0 then
               Append_Source (Line (1 .. Last), File_Name, Line_No, Success);
            end if;
            Append_Source (ASCII.LF & "", File_Name, Line_No, Success);
         end if;

         exit when not Success;
      end loop;

      if Ada.Text_IO.Is_Open (File) then
         begin
            Ada.Text_IO.Close (File);
         exception
            when Ada.IO_Exceptions.Status_Error | Ada.IO_Exceptions.Use_Error =>
               Add_Weave_Warning
                 (File_Name,
                  (if Line_No = 0 then Include_Line else Line_No),
                  Weaver_File_Read_Failure,
                  "file close reported an error after weaving");
         end;
      end if;
   end Weave_File;

   procedure Print_Walker_Info is
   begin
      New_Line;
      Put_Line ("=== ALBN Walker ===");
      Put_Line ("Token count  : " & Trim_Image (Integer (Token_Count)));
      Put_Line ("Source size  : " & Trim_Image (Integer (Input_Len)) & " bytes");
      Put_Line ("Include count: " & Trim_Image (Integer (Include_Count)));
      New_Line;

      for I in 1 .. Include_Count loop
         Put_Line ("  included: " & Include_Vault (I) (1 .. Include_Lens (I)));
      end loop;

      New_Line;
      Put_Line ("=== AST Root ===");
      if Root > 0 then
         Put_Line ("  Kind   : " & Node_Kind'Image (Tree (Root).Kind));
         Put_Line ("  Token  : " & Trim_Image (Integer (Tree (Root).Token_Index)));
         Put_Line ("  Left   : " & Trim_Image (Integer (Tree (Root).Left_Child)));
         Put_Line ("  Right  : " & Trim_Image (Integer (Tree (Root).Right_Child)));
         Put_Line ("  Sibling: " & Trim_Image (Integer (Tree (Root).Next_Sibling)));
      else
         Put_Line ("  (null)");
      end if;
      New_Line;
   end Print_Walker_Info;

   procedure Write_Csproj
     (Dir          : in String;
      CS_Name      : in String;
      Project_Base : in String)
   is
      Project_Path : constant String :=
        Ada.Directories.Compose (Dir, Project_Base & ".csproj");
      File : Ada.Text_IO.File_Type;

      function SDL3_Source_Path return String is
         Exe_Name : constant String := Ada.Command_Line.Command_Name;
         Exe_Dir : constant String :=
           (if Exe_Name'Length > 0
            then Ada.Directories.Containing_Directory (Exe_Name)
            else "");
         Candidate : constant String :=
           (if Exe_Dir'Length > 0
            then Ada.Directories.Compose (Exe_Dir, "SDL3.dll")
            else "SDL3.dll");
      begin
         if Ada.Directories.Exists (Candidate) then
            return Candidate;
         end if;
         if Ada.Directories.Exists ("..\..\obj\SDL3.dll") then
            return "..\..\obj\SDL3.dll";
         end if;
         return Candidate;
      end SDL3_Source_Path;

      function Xml_Path (Path : String) return String is
         Result : String (1 .. Path'Length) := (others => ' ');
      begin
         for I in Path'Range loop
            if Path (I) = '\' then
               Result (I) := '/';
            else
               Result (I) := Path (I);
            end if;
         end loop;
         return Result (1 .. Path'Length);
      end Xml_Path;

      SDL3_Path : constant String := SDL3_Source_Path;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Project_Path);
      Ada.Text_IO.Put_Line (File, "<Project Sdk=""Microsoft.NET.Sdk"">");
      Ada.Text_IO.Put_Line (File, "  <PropertyGroup>");
      Ada.Text_IO.Put_Line (File, "    <OutputType>Exe</OutputType>");
      if Framework_Len = 0 then
         Ada.Text_IO.Put_Line (File, "    <TargetFramework>net8.0</TargetFramework>");
      else
         Ada.Text_IO.Put_Line
           (File,
            "    <TargetFramework>" &
            Framework (1 .. Framework_Len) &
            "</TargetFramework>");
      end if;
      Ada.Text_IO.Put_Line (File, "    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>");
      Ada.Text_IO.Put_Line (File, "    <ImplicitUsings>disable</ImplicitUsings>");
      if Nullable_Mode_Len = 0 then
         Ada.Text_IO.Put_Line (File, "    <Nullable>disable</Nullable>");
      else
         Ada.Text_IO.Put_Line
           (File,
            "    <Nullable>" &
            Nullable_Mode (1 .. Nullable_Mode_Len) &
            "</Nullable>");
      end if;
      if Lang_Version_Len = 0 then
         Ada.Text_IO.Put_Line (File, "    <LangVersion>latest</LangVersion>");
      else
         Ada.Text_IO.Put_Line
           (File,
            "    <LangVersion>" &
            Lang_Version (1 .. Lang_Version_Len) &
            "</LangVersion>");
      end if;
      Ada.Text_IO.Put_Line (File, "    <AllowUnsafeBlocks>" &
        (if Unsafe_Mode then "true" else "false") &
        "</AllowUnsafeBlocks>");
      Ada.Text_IO.Put_Line (File, "    <Deterministic>true</Deterministic>");
      Ada.Text_IO.Put_Line (File, "    <Optimize>true</Optimize>");
      Ada.Text_IO.Put_Line (File, "  </PropertyGroup>");
      Ada.Text_IO.Put_Line (File, "  <ItemGroup>");
      Ada.Text_IO.Put_Line (File, "    <Compile Include=""" & CS_Name & """ />");
      if Ada.Directories.Exists (SDL3_Path) then
         Ada.Text_IO.Put_Line
           (File,
            "    <None Include=""" &
            Xml_Path (SDL3_Path) &
            """ Link=""SDL3.dll"" CopyToOutputDirectory=""PreserveNewest"" />");
      end if;
      Ada.Text_IO.Put_Line (File, "  </ItemGroup>");
      Ada.Text_IO.Put_Line (File, "</Project>");
      Ada.Text_IO.Close (File);
   exception
      when Ada.IO_Exceptions.Name_Error |
           Ada.IO_Exceptions.Use_Error |
           Ada.IO_Exceptions.Status_Error |
           Ada.IO_Exceptions.Device_Error =>
         Project_Write_Succeeded := False;
         Add_Weave_Warning
           (Project_Path,
            0,
            Weaver_Output_Path_Failure,
            "could not write generated C# project file");
         begin
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
         exception
            when Ada.IO_Exceptions.Status_Error | Ada.IO_Exceptions.Use_Error =>
               null;
         end;
   end Write_Csproj;

   procedure Parse_Args is
      Skip_Next : Boolean := False;
   begin
      for I in 1 .. Ada.Command_Line.Argument_Count loop
         if Skip_Next then
            Skip_Next := False;
         else
            declare
               Arg      : constant String := Ada.Command_Line.Argument (I);
               Gfx_Err  : Boolean;
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
                       ("ALBN: FATAL: Unknown --gfx backend (use opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12).");
                     Arg_Error := True;
                  end if;
                  if Gfx_Skip then
                     Skip_Next := True;
                  end if;
               elsif Arg = "-o" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Output_Len := N'Length;
                        if Output_Len <= Max_Path_Len then
                           Output_File (1 .. Output_Len) := N;
                        else
                           Arg_Error := True;
                        end if;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBN: '-o' requires a filename.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--outdir" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Out_Dir_Len := N'Length;
                        if Out_Dir_Len <= Max_Path_Len then
                           Out_Dir (1 .. Out_Dir_Len) := N;
                        else
                           Arg_Error := True;
                        end if;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBN: '--outdir' requires a directory.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--framework" or else Arg = "--target" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Framework_Len := N'Length;
                        if Framework_Len <= Framework'Length then
                           Framework (1 .. Framework_Len) := N;
                        else
                           Arg_Error := True;
                        end if;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBN: '--framework' requires a target framework.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--langversion" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Lang_Version_Len := N'Length;
                        if Lang_Version_Len <= Lang_Version'Length then
                           Lang_Version (1 .. Lang_Version_Len) := N;
                        else
                           Arg_Error := True;
                        end if;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBN: '--langversion' requires a value.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--nullable" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Nullable_Mode_Len := N'Length;
                        if Nullable_Mode_Len <= Nullable_Mode'Length then
                           Nullable_Mode (1 .. Nullable_Mode_Len) := N;
                        else
                           Arg_Error := True;
                        end if;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBN: '--nullable' requires a value.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--unsafe" then
                  Unsafe_Mode := True;
               elsif Arg = "--build" or else Arg = "-b" then
                  Build_Mode := True;
               elsif Arg = "--metrics" or else Arg = "-m" then
                  Metrics_Mode := True;
               elsif Arg = "--walker" or else Arg = "-w" then
                  Walker_Mode := True;
               elsif Arg = "--quiet" or else Arg = "-q" then
                  Quiet_Mode := True;
               elsif Arg = "--help" or else Arg = "-h" then
                  Print_Help;
                  Arg_Error := True;
               elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
                  Put_Line ("ALBN: unknown option " & Arg);
                  Arg_Error := True;
               else
                  if Source_Len = 0 then
                     Source_Len := Arg'Length;
                     if Source_Len <= Max_Path_Len then
                        Source_File (1 .. Source_Len) := Arg;
                     else
                        Arg_Error := True;
                     end if;
                  elsif Output_Len = 0 then
                     Output_Len := Arg'Length;
                     if Output_Len <= Max_Path_Len then
                        Output_File (1 .. Output_Len) := Arg;
                     else
                        Arg_Error := True;
                     end if;
                  else
                     Put_Line ("ALBN: unexpected extra argument " & Arg);
                     Arg_Error := True;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Parse_Args;

   procedure Resolve_Output_Paths is
   begin
      declare
         B : constant String := Safe_Project_Name (Base_Name (Source_File (1 .. Source_Len)));
      begin
         Project_Len := B'Length;
         Project_Name (1 .. Project_Len) := B;
      end;

      if Build_Mode then
         if Out_Dir_Len = 0 then
            declare
               D : constant String := Default_Out_Dir (Source_File (1 .. Source_Len));
            begin
               Out_Dir_Len := D'Length;
               Out_Dir (1 .. Out_Dir_Len) := D;
            end;
         end if;

         Final_Dir_Len := Out_Dir_Len;
         Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);

         if Output_Len = 0 then
            declare
               N : constant String :=
                 Ada.Directories.Compose
                   (Final_Dir (1 .. Final_Dir_Len),
                    Default_Output_Name (Source_File (1 .. Source_Len)));
            begin
               CS_Len := N'Length;
               CS_Path (1 .. CS_Len) := N;
            end;
         elsif Parent_Directory (Output_File (1 .. Output_Len)) = "" then
            declare
               N : constant String :=
                 Ada.Directories.Compose
                   (Final_Dir (1 .. Final_Dir_Len),
                    Output_File (1 .. Output_Len));
            begin
               CS_Len := N'Length;
               CS_Path (1 .. CS_Len) := N;
            end;
         else
            CS_Len := Output_Len;
            CS_Path (1 .. CS_Len) := Output_File (1 .. Output_Len);
         end if;
      else
         if Output_Len = 0 then
            if Out_Dir_Len > 0 then
               declare
                  N : constant String :=
                    Ada.Directories.Compose
                      (Out_Dir (1 .. Out_Dir_Len),
                       Default_Output_Name (Source_File (1 .. Source_Len)));
               begin
                  CS_Len := N'Length;
                  CS_Path (1 .. CS_Len) := N;
                  Final_Dir_Len := Out_Dir_Len;
                  Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
               end;
            else
               declare
                  N : constant String := Default_Output_Name (Source_File (1 .. Source_Len));
               begin
                  CS_Len := N'Length;
                  CS_Path (1 .. CS_Len) := N;
               end;
            end if;
         elsif Out_Dir_Len > 0 and then Parent_Directory (Output_File (1 .. Output_Len)) = "" then
            declare
               N : constant String :=
                 Ada.Directories.Compose
                   (Out_Dir (1 .. Out_Dir_Len),
                    Output_File (1 .. Output_Len));
            begin
               CS_Len := N'Length;
               CS_Path (1 .. CS_Len) := N;
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end;
         else
            CS_Len := Output_Len;
            CS_Path (1 .. CS_Len) := Output_File (1 .. Output_Len);
         end if;
      end if;
   end Resolve_Output_Paths;

   Success : Boolean := True;

begin
   Parse_Args;

   if Arg_Error then
      return;
   end if;

   if Source_Len = 0 then
      Put_Line ("ALBN: no input file specified.");
      Print_Help;
      return;
   end if;

   Compilation_Had_Warnings := False;

   Resolve_Output_Paths;

   if Final_Dir_Len > 0 then
      begin
         Ada.Directories.Create_Path (Final_Dir (1 .. Final_Dir_Len));
      exception
         when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
            Add_Weave_Warning
              (Final_Dir (1 .. Final_Dir_Len),
               0,
               Weaver_Output_Path_Failure,
               "could not create output directory");
            Weave_Diag.Had_Fatal_Error := True;
            Print_Warning_Summary;
            return;
      end;
   end if;

      if Build_Mode then
      declare
         CS_Base : constant String := File_Name_With_Extension (CS_Path (1 .. CS_Len));
      begin
         Project_Write_Succeeded := True;
         Write_Csproj
           (Final_Dir (1 .. Final_Dir_Len),
            CS_Base,
            Project_Name (1 .. Project_Len));
      end;
   end if;

   Log ("ALBN: transpiling " & Source_File (1 .. Source_Len));

   Input_Buffer := (others => ' ');
   Temp_Buffer := (others => ' ');
   Tokens := (others => (Kind => Tok_Error, Start => 1, Length => 0, Line => 1, Column => 1));
   Tree := (others => (Kind => AST_Null, Token_Index => 0, Left_Child => 0, Right_Child => 0, Next_Sibling => 0));

   Log ("Step 1: Tokenizing");
   Weave_File (Source_File (1 .. Source_Len), Success);
   if not Success or else Input_Len = 0 then
      Put_Line ("ALBN: failed to read or weave source file.");
      Print_Warning_Summary;
      return;
   end if;

   Tokenizer.Tokenize
     (Input_Buffer (1 .. Input_Len),
      Tokens,
      Token_Count,
      Lex_Diag);

   if not Lex_Diag.Success then
      Put_Line
        ("Lexer failure at line" &
         Positive'Image (Lex_Diag.Error_Line) &
         ", col" &
         Positive'Image (Lex_Diag.Error_Col) &
         " -> " &
         Oracle_Code'Image (Lex_Diag.Code));
      Print_Warning_Summary;
      return;
   end if;

   Log ("Step 2: Parsing");
   Parser.Parse
     (Tokens,
      Token_Count,
      Tree,
      Root,
      Parse_Success,
      Parse_Diag);

   if not Parse_Success or else not Parse_Diag.Success or else Root = 0 then
      Put_Line
        ("Parser failure at line" &
         Positive'Image (Parse_Diag.Error_Line) &
         ", col" &
         Positive'Image (Parse_Diag.Error_Col) &
         " -> " &
         Oracle_Code'Image (Parse_Diag.Code));
      Print_Warning_Summary;
      return;
   end if;

   if Walker_Mode then
      Print_Walker_Info;
   end if;

   Log ("Step 3: Emitting C#");
   Emit_Native_DotNet.Initialize_Output
     (CS_Path (1 .. CS_Len),
      Emit_Diag);

   if Emit_Diag.Had_Fatal_Error then
      Put_Line ("FATAL: C# emitter could not initialize output.");
      Print_Warning_Summary;
      return;
   end if;

   Emit_Native_DotNet.Emit_Program
     (Tokens,
      Tree,
      Root,
      Emit_Diag);

   if Emit_Diag.Had_Fatal_Error then
      Put_Line ("FATAL: C# emission failed.");
      Print_Warning_Summary;
      return;
   end if;

   Log ("ALBN: emitted " & CS_Path (1 .. CS_Len));

   if Metrics_Mode then
      Code_Information.Reset_Metrics;
      for I in 1 .. Include_Count loop
         Code_Information.Scan_Target (Include_Vault (I) (1 .. Include_Lens (I)));
      end loop;
      Code_Information.Print_Metrics;
   end if;

   if Build_Mode and then Project_Write_Succeeded then
      Log
        ("ALBN: wrote " &
         Ada.Directories.Compose
           (Final_Dir (1 .. Final_Dir_Len),
            Project_Name (1 .. Project_Len) & ".csproj"));
   end if;

   Print_Warning_Summary;
   if Compilation_Had_Warnings then
      Log ("ALBN: done with warnings.");
   else
      Log ("ALBN: done.");
   end if;
end ALBN;
