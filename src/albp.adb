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
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with Parser;         use Parser;
with AST;            use AST;
with Emit_Native_Python;
with Code_Information;
with GNAT.OS_Lib;    use GNAT.OS_Lib;
with ALB_System_Includes;

procedure ALBP is

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
   Run_Mode     : Boolean := False;

   Source_File : String (1 .. Max_Path_Len) := (others => ' ');
   Source_Len  : Natural := 0;
   Output_File : String (1 .. Max_Path_Len) := (others => ' ');
   Output_Len  : Natural := 0;
   Out_Dir     : String (1 .. Max_Path_Len) := (others => ' ');
   Out_Dir_Len : Natural := 0;

   function To_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      end if;
      return Ch;
   end To_Upper;

   function Trim_Image (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return Ada.Strings.Fixed.Trim (S, Ada.Strings.Both);
   end Trim_Image;

   procedure Log (Msg : String) is
   begin
      if not Quiet_Mode then
         Put_Line (Msg);
      end if;
   end Log;

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
         return "output";
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
         return "output";
   end Base_Name;

   function Is_Absolute_Path (Path : String) return Boolean is
   begin
      if Path'Length = 0 then
         return False;
      end if;

      if Path (Path'First) = '/' or else Path (Path'First) = '\' then
         return True;
      end if;

      return Path'Length >= 2 and then Path (Path'First + 1) = ':';
   end Is_Absolute_Path;

   function Default_Output_Name (Input : String) return String is
   begin
      if Build_Mode then
         return "main.py";
      end if;
      return Base_Name (Input) & ".py";
   end Default_Output_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "python_" & Base_Name (Input);
   end Default_Out_Dir;

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
               File_Name (File_Name'First .. File_Name'First + File_Len - 1) :=
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
               File_Name (File_Name'First .. File_Name'First + File_Len - 1) :=
                 Line_Text (Start .. Stop - 1);
               Match := True;
            end if;
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
         function Has_Separator (Text : String) return Boolean is
         begin
            for I in Text'Range loop
               if Text (I) = '\' or else Text (I) = '/' then
                  return True;
               end if;
            end loop;
            return False;
         end Has_Separator;
      begin
         if Leaf'Length = 0 then
            return Dir;
         elsif Dir'Length = 0 then
            return Leaf;
         elsif Leaf (Leaf'First) = '\' or else Leaf (Leaf'First) = '/' then
            return Leaf;
         elsif Leaf'Length >= 3
           and then Leaf (Leaf'First) = '.'
           and then Leaf (Leaf'First + 1) = '.'
           and then (Leaf (Leaf'First + 2) = '\' or else Leaf (Leaf'First + 2) = '/')
         then
            if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf;
            else
               return Dir & "\" & Leaf;
            end if;
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
         elsif Has_Separator (Leaf) then
            if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf;
            else
               return Dir & "\" & Leaf;
            end if;
         else
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
         Include_Match  : Boolean := False;
         Include_System : Boolean := False;
         Include_Name   : String (1 .. Max_Path_Len) := (others => ' ');
         Include_Len    : Natural := 0;
      begin
         Parse_Include_Line
           (Line_Buffer,
            Line_Len,
            Include_Match,
            Include_System,
            Include_Name,
            Include_Len);

         if Include_Match then
            declare
               Raw_Include : constant String := Include_Name (1 .. Include_Len);
               Resolved    : String (1 .. Max_Path_Len) := (others => ' ');
               Resolved_Len : Natural := 0;
            begin
               if Include_System then
                  declare
                     Sys : constant String :=
                       ALB_System_Includes.Resolve_System_Include (Raw_Include);
                  begin
                     if not Ada.Directories.Exists (Sys) then
                        Put_Line
                          ("ALBP: FATAL: System include not found: <"
                           & Raw_Include & "> (searched under "
                           & ALB_System_Includes.Vendor_Root & ")");
                        Success := False;
                     elsif Sys'Length <= Max_Path_Len then
                        Resolved_Len := Sys'Length;
                        Resolved (1 .. Resolved_Len) := Sys;
                     else
                        Success := False;
                     end if;
                  end;
               else
                  declare
                     Local : constant String :=
                       Resolve_Local_Path (Raw_Include, File_Dir);
                  begin
                     if Local'Length = 0 then
                        Put_Line
                          ("ALBP: include not found: " & Raw_Include & " (from "
                           & File_Name & ")");
                        Success := False;
                     elsif Local'Length <= Max_Path_Len then
                        Resolved_Len := Local'Length;
                        Resolved (1 .. Resolved_Len) := Local;
                     else
                        Success := False;
                     end if;
                  end;
               end if;

               if Success and then Resolved_Len > 0 then
                  Weave_File (Resolved (1 .. Resolved_Len), Success);
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
            Put_Line ("ALBP: could not open source file: " & File_Name & " - " &
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
         Put_Line ("ALBP: weave failure in " & File_Name & " - " &
           Ada.Exceptions.Exception_Message (E));
         Success := False;
         begin
            Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               null;
         end;
   end Weave_File;

   procedure Print_Help is
   begin
      Put_Line ("ALBP: AdaLogic BASIC for Python");
      Put_Line ("Usage: albp [options] <input.alb> [output.py]");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  -o <file>        Output .py file (default: derived from input name)");
      Put_Line ("  --outdir <dir>   Output directory (default: current dir, or python_<name> with --build)");
      Put_Line ("  --build, -b      Stage a runnable Python project folder");
      Put_Line ("  --run            Transpile then run via 'py -3'");
      Put_Line ("  --metrics, -m    Show code metrics after compilation");
      Put_Line ("  --walker, -w     Show AST structure and token information");
      Put_Line ("  --quiet, -q      Suppress informational messages");
      Put_Line ("  --help, -h       Show this help");
   end Print_Help;

   procedure Print_Walker_Info is
   begin
      New_Line;
      Put_Line ("=== ALBP Walker ===");
      Put_Line ("Token count : " & Trim_Image (Integer (Token_Count)));
      Put_Line ("Source size : " & Trim_Image (Integer (Input_Len)) & " bytes");
      Put_Line ("Include count: " & Trim_Image (Integer (Include_Count)));
      Put_Line ("Root kind   : " & Node_Kind'Image (Tree (Root).Kind));
      New_Line;
   end Print_Walker_Info;

   procedure Parse_Args is
      I : Natural := 1;
   begin
      while I <= Ada.Command_Line.Argument_Count loop
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
                    ("ALBP: FATAL: Unknown --gfx backend (use opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12).");
                  raise Program_Error;
               end if;
               if Gfx_Skip then
                  I := I + 1;
               end if;
            elsif Arg = "--help" or else Arg = "-h" then
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
            elsif Arg = "--run" then
               Run_Mode := True;
            elsif Arg = "-o" and then I < Ada.Command_Line.Argument_Count then
               I := I + 1;
               declare
                  V : constant String := Ada.Command_Line.Argument (I);
               begin
                  Output_Len := Natural'Min (V'Length, Max_Path_Len);
                  Output_File := (others => ' ');
                  Output_File (1 .. Output_Len) := V (V'First .. V'First + Output_Len - 1);
               end;
            elsif Arg = "--outdir" and then I < Ada.Command_Line.Argument_Count then
               I := I + 1;
               declare
                  V : constant String := Ada.Command_Line.Argument (I);
               begin
                  Out_Dir_Len := Natural'Min (V'Length, Max_Path_Len);
                  Out_Dir := (others => ' ');
                  Out_Dir (1 .. Out_Dir_Len) := V (V'First .. V'First + Out_Dir_Len - 1);
               end;
            elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
               Put_Line ("ALBP: unknown option " & Arg);
               Print_Help;
               raise Program_Error;
            else
               if Source_Len = 0 then
                  Source_Len := Natural'Min (Arg'Length, Max_Path_Len);
                  Source_File := (others => ' ');
                  Source_File (1 .. Source_Len) := Arg (Arg'First .. Arg'First + Source_Len - 1);
               elsif Output_Len = 0 then
                  Output_Len := Natural'Min (Arg'Length, Max_Path_Len);
                  Output_File := (others => ' ');
                  Output_File (1 .. Output_Len) := Arg (Arg'First .. Arg'First + Output_Len - 1);
               else
                  Put_Line ("ALBP: unexpected argument: " & Arg);
                  Print_Help;
                  raise Program_Error;
               end if;
            end if;
         end;
         I := I + 1;
      end loop;
   end Parse_Args;

   function Spawn_And_Check
     (Program : String;
      Args    : GNAT.OS_Lib.Argument_List_Access) return Boolean
   is
      Exit_Code : Integer := -1;
   begin
      Exit_Code := GNAT.OS_Lib.Spawn (Program, Args.all);
      return Exit_Code = 0;
   exception
      when others =>
         return False;
   end Spawn_And_Check;

begin
   Parse_Args;

   if Source_Len = 0 then
      Print_Help;
      return;
   end if;

   if Build_Mode and then Out_Dir_Len = 0 then
      declare
         D : constant String := Default_Out_Dir (Source_File (1 .. Source_Len));
      begin
         Out_Dir_Len := Natural'Min (D'Length, Max_Path_Len);
         Out_Dir (1 .. Out_Dir_Len) := D;
      end;
   end if;

   declare
      Success : Boolean := True;
   begin
      Weave_File (Source_File (1 .. Source_Len), Success);
      if not Success then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
   end;

   Log ("Step 1: Tokenizing");
   Tokenizer.Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, Lex_Diag);
   if not Lex_Diag.Success then
      Put_Line
        ("ALBP lexer failure at line " &
         Trim_Image (Integer (Lex_Diag.Error_Line)) &
         ", col " &
         Trim_Image (Integer (Lex_Diag.Error_Col)));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Log ("Step 2: Parsing");
   Parser.Parse (Tokens, Token_Count, Tree, Root, Parse_Success, Parse_Diag);
   if not Parse_Success or else not Parse_Diag.Success or else Root = 0 then
      Put_Line
        ("ALBP parser failure at line " &
         Trim_Image (Integer (Parse_Diag.Error_Line)) &
         ", col " &
         Trim_Image (Integer (Parse_Diag.Error_Col)));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   if Walker_Mode then
      Print_Walker_Info;
   end if;

   declare
      Final_Out_Dir : constant String :=
        (if Out_Dir_Len > 0 then Out_Dir (1 .. Out_Dir_Len) else "");
      Final_Output : constant String :=
        (if Output_Len > 0 then
           (if Final_Out_Dir'Length > 0
              and then not Is_Absolute_Path (Output_File (1 .. Output_Len))
            then Ada.Directories.Compose (Final_Out_Dir, Output_File (1 .. Output_Len))
            else Output_File (1 .. Output_Len))
         elsif Final_Out_Dir'Length > 0 then Ada.Directories.Compose (Final_Out_Dir, Default_Output_Name (Source_File (1 .. Source_Len)))
         else Default_Output_Name (Source_File (1 .. Source_Len)));
   begin
      if Final_Out_Dir'Length > 0 then
         Ada.Directories.Create_Path (Final_Out_Dir);
      end if;

      Log ("Step 3: Emitting Python");
      Emit_Native_Python.Compile_To_File (Tree (Root), Final_Output);
      Log ("ALBP: emitted " & Final_Output);

      if Build_Mode then
         declare
            Run_Path  : constant String := Ada.Directories.Compose (Final_Out_Dir, "run.ps1");
            Run_File  : Ada.Text_IO.File_Type;
         begin
            Ada.Text_IO.Create (Run_File, Ada.Text_IO.Out_File, Run_Path);
            Ada.Text_IO.Put_Line (Run_File, "$ErrorActionPreference = 'Stop'");
            Ada.Text_IO.Put_Line (Run_File, "& py -3 .\" & Ada.Directories.Base_Name (Final_Output));
            Ada.Text_IO.Close (Run_File);
         end;
      end if;

      if Metrics_Mode then
         Code_Information.Reset_Metrics;
         for I in 1 .. Include_Count loop
            Code_Information.Scan_Target (Include_Vault (I) (1 .. Include_Lens (I)));
         end loop;
         Code_Information.Print_Metrics;
      end if;

      if Run_Mode then
         declare
            Args : GNAT.OS_Lib.Argument_List_Access :=
              new GNAT.OS_Lib.Argument_List'
                (1 => new String'("-3"),
                 2 => new String'(Final_Output));
         begin
            if not Spawn_And_Check ("py", Args) then
               Put_Line ("ALBP: failed to run generated script via 'py -3'.");
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            end if;
            Free (Args);
         end;
      end if;
   end;

exception
   when E : Program_Error =>
      Put_Line ("ALBP: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   when E : others =>
      Put_Line ("ALBP: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end ALBP;
