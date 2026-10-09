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

pragma SPARK_Mode (Off);

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with Parser;         use Parser;
with AST;            use AST;
with Emit_Native_Godot;


procedure ALBGD is

   Max_Path_Len   : constant Natural := 512;
   Max_Includes   : constant Natural := 256;
   Max_Input_Size : constant Natural := Input_Buffer'Length;

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

   Quiet_Mode   : Boolean := False;
   Walker_Mode  : Boolean := False;
   Metrics_Mode : Boolean := False;
   Build_Mode   : Boolean := False;

   Source_File  : String (1 .. Max_Path_Len) := (others => ' ');
   Source_Len   : Natural := 0;
   Out_Dir      : String (1 .. Max_Path_Len) := (others => ' ');
   Out_Dir_Len  : Natural := 0;
   Class_Name   : String (1 .. Max_Path_Len) := (others => ' ');
   Class_Len    : Natural := 0;
   Base_Class   : String (1 .. 64) := (others => ' ');
   Base_Len     : Natural := 0;
   Res_Base     : String (1 .. Max_Path_Len) := (others => ' ');
   Res_Base_Len : Natural := 0;

   Emit_Diag    : Emitter_Diagnostic_Log;

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

   procedure Log (Msg : String) is
   begin
      if not Quiet_Mode then
         Put_Line (Msg);
      end if;
   end Log;

   procedure Print_Emitter_Diagnostics is
      function Trim_Message
        (Buffer : Diagnostic_Message_Buffer;
         Length : Natural) return String
      is
      begin
         if Length = 0 then
            return "";
         end if;
         return String (Buffer (1 .. Length));
      end Trim_Message;
   begin
      if not Emit_Diag.Had_Warnings and then not Emit_Diag.Had_Fatal_Error then
         return;
      end if;

      for I in 1 .. Emit_Diag.Stored_Count loop
         if Emit_Diag.Entries (I).Active then
            Put_Line
              ("ALBGD EMITTER [" &
               Emitter_Diagnostic_Category'Image (Emit_Diag.Entries (I).Category) &
               "] line " &
               Trim_Image (Integer (Emit_Diag.Entries (I).Line)) &
               ", col " &
               Trim_Image (Integer (Emit_Diag.Entries (I).Column)) &
               " -> " &
               Trim_Message
                 (Emit_Diag.Entries (I).Message,
                  Emit_Diag.Entries (I).Message_Len));
         end if;
      end loop;
   end Print_Emitter_Diagnostics;

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
         return "albgd_output";
      end if;
      declare
         Raw : constant String := Ada.Directories.Base_Name (Path);
         Dot : Natural := 0;
      begin
         for I in reverse Raw'Range loop
            exit when Raw (I) = '\' or else Raw (I) = '/';
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
      when others =>
         return "albgd_output";
   end Base_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "godot_" & Base_Name (Input);
   end Default_Out_Dir;

   function Default_Class_Name (Input : String) return String is
   begin
      return Base_Name (Input);
   end Default_Class_Name;

   procedure Print_Help is
   begin
      Put_Line ("ALBGD: AdaLogic BASIC Godot compiler");
      Put_Line ("Usage: albgd [options] <input.alb>");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  --outdir <dir>     Output directory (default: godot_<input>)");
      Put_Line ("  --class <name>     Generated Godot class name");
      Put_Line ("  --extends <type>   Generated Godot base class (Node2D, Control, Node)");
      Put_Line ("  --gdext-res-base   Resource root for emitted .gdextension libraries");
      Put_Line ("  --build, -b        Generate build-oriented project layout");
      Put_Line ("  --quiet, -q        Suppress informational messages");
      Put_Line ("  --walker, -w       Show AST root info");
      Put_Line ("  --metrics, -m      Show token and source size metrics");
      Put_Line ("  --help, -h         Show this help");
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

   procedure Parse_Include_Line
     (Line_Text : String;
      Line_Len  : Natural;
      Match     : out Boolean;
      File_Name : out String;
      File_Len  : out Natural)
   is
      P       : Natural := 1;
      Start   : Natural := 0;
      Stop    : Natural := 0;
      Keyword : constant String := "INCLUDE";
   begin
      Match := False;
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

      if P > Line_Len or else Line_Text (P) /= '"' then
         return;
      end if;

      Start := P + 1;
      Stop := Start;
      while Stop <= Line_Len and then Line_Text (Stop) /= '"' loop
         Stop := Stop + 1;
      end loop;

      if Stop <= Line_Len and then Stop > Start then
         File_Len := Stop - Start;
         if File_Len <= File_Name'Length then
            File_Name (File_Name'First .. File_Name'First + File_Len - 1) :=
              Line_Text (Start .. Stop - 1);
            Match := True;
         end if;
      end if;
   end Parse_Include_Line;

   function Path_Exists (Path : String) return Boolean is
   begin
      return Path'Length > 0 and then Ada.Directories.Exists (Path);
   exception
      when others =>
         return False;
   end Path_Exists;

   function Resolve_Local_Path
     (Raw_Path : String;
      Base_Dir : String) return String
   is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);
      function Join_Base (Dir : String; Leaf : String) return String is
      begin
         if Leaf'Length = 0 then
            return Dir;
         elsif Dir'Length = 0 then
            return Leaf;
         elsif Leaf (Leaf'First) = '\' or else Leaf (Leaf'First) = '/' then
            return Leaf;
         elsif Leaf'Length >= 2
           and then Leaf (Leaf'First) = '.'
           and then (Leaf (Leaf'First + 1) = '\' or else Leaf (Leaf'First + 1) = '/')
         then
            if Leaf'Length = 2 then
               return Dir;
            elsif Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf (Leaf'First + 2 .. Leaf'Last);
            else
               return Dir & "\" & Leaf (Leaf'First + 2 .. Leaf'Last);
            end if;
         else
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
         end if;
      end Join_Base;
   begin
      if Trimmed'Length = 0 then
         return "";
      elsif Path_Exists (Trimmed) then
         return Trimmed;
      elsif Base_Dir'Length > 0 then
         declare
            Candidate : constant String := Join_Base (Base_Dir, Trimmed);
         begin
            if Path_Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end if;
      return "";
   end Resolve_Local_Path;

   procedure Weave_File
     (File_Name : String;
      Success   : in out Boolean)
   is
      File        : Ada.Streams.Stream_IO.File_Type;
      Stream_Ptr  : Ada.Streams.Stream_IO.Stream_Access;
      Ch          : Character;
      Line_Buffer : String (1 .. 2048) := (others => ' ');
      Line_Len    : Natural := 0;
      File_Dir    : constant String := Parent_Directory (File_Name);

      procedure Flush_Line is
         Include_Match : Boolean := False;
         Include_Name  : String (1 .. Max_Path_Len) := (others => ' ');
         Include_Len   : Natural := 0;
      begin
         Parse_Include_Line
           (Line_Buffer,
            Line_Len,
            Include_Match,
            Include_Name,
            Include_Len);

         if Include_Match then
            declare
               Raw_Include : constant String := Include_Name (1 .. Include_Len);
               Resolved    : constant String := Resolve_Local_Path (Raw_Include, File_Dir);
            begin
               if Resolved'Length = 0 then
                  Put_Line ("ALBGD: include not found: " & Raw_Include & " (from " & File_Name & ")");
                  Success := False;
               else
                  Weave_File (Resolved, Success);
               end if;
            end;
         else
            if Line_Len > 0 then
               Append_Source (Line_Buffer (1 .. Line_Len), Success);
            end if;
            Append_Source (ASCII.LF & "", Success);
         end if;

         Line_Len := 0;
      end Flush_Line;
   begin
      if not Success or else Is_Already_Included (File_Name) then
         return;
      end if;

      Register_Include (File_Name, Success);
      if not Success then
         return;
      end if;

      Log ("  weaving: " & File_Name);

      begin
         Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, File_Name);
         Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);
      exception
         when E : others =>
            Put_Line ("ALBGD: could not open source file: " & File_Name & " - " &
              Ada.Exceptions.Exception_Message (E));
            Success := False;
            return;
      end;

      while not Ada.Streams.Stream_IO.End_Of_File (File) loop
         Character'Read (Stream_Ptr, Ch);
         if Ch = ASCII.CR then
            null;
         elsif Ch = ASCII.LF then
            Flush_Line;
            exit when not Success;
         else
            if Line_Len < Line_Buffer'Length then
               Line_Len := Line_Len + 1;
               Line_Buffer (Line_Len) := Ch;
            else
               Success := False;
               exit;
            end if;
         end if;
      end loop;

      if Success and then Line_Len > 0 then
         Flush_Line;
      end if;

      Ada.Streams.Stream_IO.Close (File);
   exception
      when E : others =>
         Put_Line ("ALBGD: weave failure in " & File_Name & " - " &
           Ada.Exceptions.Exception_Message (E));
         Success := False;
         begin
            Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               null;
         end;
   end Weave_File;

   procedure Parse_Args is
      I : Natural := 1;
   begin
      while I <= Ada.Command_Line.Argument_Count loop
         declare
            Arg : constant String := Ada.Command_Line.Argument (I);
         begin
         if Arg = "--help" or else Arg = "-h" then
            Print_Help;
            raise Program_Error;
         elsif Arg = "--quiet" or else Arg = "-q" then
            Quiet_Mode := True;
         elsif Arg = "--walker" or else Arg = "-w" then
            Walker_Mode := True;
         elsif Arg = "--metrics" or else Arg = "-m" then
            Metrics_Mode := True;
         elsif Arg = "--build" or else Arg = "-b" then
            Build_Mode := True;
         elsif Arg = "--outdir" and then I < Ada.Command_Line.Argument_Count then
            I := I + 1;
            declare
               V : constant String := Ada.Command_Line.Argument (I);
            begin
               Out_Dir_Len := Natural'Min (V'Length, Max_Path_Len);
               Out_Dir := (others => ' ');
               Out_Dir (1 .. Out_Dir_Len) := V (V'First .. V'First + Out_Dir_Len - 1);
            end;
         elsif Arg = "--class" and then I < Ada.Command_Line.Argument_Count then
            I := I + 1;
            declare
               V : constant String := Ada.Command_Line.Argument (I);
            begin
               Class_Len := Natural'Min (V'Length, Max_Path_Len);
               Class_Name := (others => ' ');
               Class_Name (1 .. Class_Len) := V (V'First .. V'First + Class_Len - 1);
            end;
         elsif Arg = "--extends" and then I < Ada.Command_Line.Argument_Count then
            I := I + 1;
            declare
               V : constant String := Ada.Command_Line.Argument (I);
            begin
               Base_Len := Natural'Min (V'Length, Base_Class'Length);
               Base_Class := (others => ' ');
               Base_Class (1 .. Base_Len) := V (V'First .. V'First + Base_Len - 1);
            end;
         elsif Arg = "--gdext-res-base" and then I < Ada.Command_Line.Argument_Count then
            I := I + 1;
            declare
               V : constant String := Ada.Command_Line.Argument (I);
            begin
               Res_Base_Len := Natural'Min (V'Length, Res_Base'Length);
               Res_Base := (others => ' ');
               Res_Base (1 .. Res_Base_Len) := V (V'First .. V'First + Res_Base_Len - 1);
            end;
         elsif Source_Len = 0 then
            Source_Len := Natural'Min (Arg'Length, Max_Path_Len);
            Source_File (1 .. Source_Len) := Arg (Arg'First .. Arg'First + Source_Len - 1);
         else
            Put_Line ("ALBGD: unexpected argument: " & Arg);
            Print_Help;
            raise Program_Error;
         end if;
         end;
         I := I + 1;
      end loop;
   end Parse_Args;

begin
   Parse_Args;

   if Source_Len = 0 then
      Print_Help;
      return;
   end if;

   if Out_Dir_Len = 0 then
      declare
         D : constant String := Default_Out_Dir (Source_File (1 .. Source_Len));
      begin
         Out_Dir_Len := D'Length;
         Out_Dir (1 .. Out_Dir_Len) := D;
      end;
   end if;

   if Class_Len = 0 then
      declare
         C : constant String := Default_Class_Name (Source_File (1 .. Source_Len));
      begin
         Class_Len := Natural'Min (C'Length, Max_Path_Len);
         Class_Name (1 .. Class_Len) := C (C'First .. C'First + Class_Len - 1);
      end;
   end if;

   if Base_Len = 0 then
      Base_Len := 6;
      Base_Class (1 .. Base_Len) := "Node2D";
   end if;

   declare
      Success : Boolean := True;
   begin
      Input_Len := 0;
      Weave_File (Source_File (1 .. Source_Len), Success);
      if not Success then
         Set_Exit_Status (Failure);
         return;
      end if;
   end;

   Log ("Step 1: Tokenizing");
   Tokenizer.Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, Lex_Diag);
   if not Lex_Diag.Success then
      Put_Line
        ("ALBGD lexer failure at line " &
         Trim_Image (Integer (Lex_Diag.Error_Line)) &
         ", col " &
         Trim_Image (Integer (Lex_Diag.Error_Col)));
      Set_Exit_Status (Failure);
      return;
   end if;

   Log ("Step 2: Parsing");
   Parser.Parse (Tokens, Token_Count, Tree, Root, Parse_Success, Parse_Diag);
   if not Parse_Success or else not Parse_Diag.Success or else Root = 0 then
      Put_Line
        ("ALBGD parser failure at line " &
         Trim_Image (Integer (Parse_Diag.Error_Line)) &
         ", col " &
         Trim_Image (Integer (Parse_Diag.Error_Col)));
      Set_Exit_Status (Failure);
      return;
   end if;

   if Walker_Mode then
      New_Line;
      Put_Line ("=== ALBGD Walker ===");
      Put_Line ("Token count : " & Trim_Image (Integer (Token_Count)));
      Put_Line ("Source size : " & Trim_Image (Integer (Input_Len)) & " bytes");
      Put_Line ("Include count: " & Trim_Image (Integer (Include_Count)));
      Put_Line ("Root kind   : " & Node_Kind'Image (Tree (Root).Kind));
      New_Line;
   end if;

   if Metrics_Mode then
      Put_Line
        ("ALBGD metrics: tokens=" & Trim_Image (Integer (Token_Count)) &
         " source_bytes=" & Trim_Image (Integer (Input_Len)));
   end if;

   Log ("Step 3: Emitting Godot project");
   Emit_Native_Godot.Initialize_Output
     (Output_Directory => Out_Dir (1 .. Out_Dir_Len),
      Source_Name      => Source_File (1 .. Source_Len),
      Class_Name       => Class_Name (1 .. Class_Len),
      Base_Class       => Base_Class (1 .. Base_Len),
      Resource_Base    =>
        (if Res_Base_Len = 0 then "res://" else Res_Base (1 .. Res_Base_Len)),
      API_Target       => Emit_Native_Godot.Godot_46,
      Build_Mode       => Build_Mode,
      Diagnostic       => Emit_Diag);

   Emit_Native_Godot.Emit_Program
     (Tokens      => Tokens,
      Tree        => Tree,
      Root        => Root,
      Diagnostic  => Emit_Diag);

   if Emit_Diag.Had_Fatal_Error then
      Print_Emitter_Diagnostics;
      Put_Line ("ALBGD: emitter reported fatal issues.");
      Set_Exit_Status (Failure);
      return;
   end if;

   if Emit_Diag.Had_Warnings then
      Print_Emitter_Diagnostics;
      Put_Line
        ("ALBGD: emitted with " &
         Trim_Image (Integer (Emit_Diag.Warning_Count)) &
         " warning(s).");
   end if;

   Log ("ALBGD output written to " & Out_Dir (1 .. Out_Dir_Len));
exception
   when Program_Error =>
      null;
   when E : others =>
      Put_Line ("ALBGD failure: " & Ada.Exceptions.Exception_Message (E));
      Set_Exit_Status (Failure);
end ALBGD;
