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

with Ada.Unchecked_Deallocation;
with Ada.Calendar;
with Ada.Characters.Latin_1;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with ALB_Oracle;
with AST;               use AST;
with Code_Information;
with Compiler_State;    use Compiler_State;
with Emit_Native_C64;
with GNAT.OS_Lib;
with Parser;
with Tokenizer;


procedure Alb_65 is
   use type Ada.Calendar.Time;
   use type Ada.Directories.File_Size;
   use type Ada.Directories.File_Kind;
   use type Parser.Error_Severity;

   Max_Path_Length   : constant Natural := 256;
   Max_Source_Files  : constant Natural := 128;
   Max_AST_Stack     : constant Natural := 16_384;
   LF                : constant Character := Ada.Characters.Latin_1.LF;

   Max_Includes         : constant := 16384;
   Max_Absolute_Lines   : constant := 131072;
   subtype Include_Path is String (1 .. Max_Path_Length);
   Include_Vault : array (1 .. Max_Includes) of Include_Path :=
     (others => (others => ' '));
   Include_Lens  : array (1 .. Max_Includes) of Natural := (others => 0);
   Include_Count : Natural := 0;

   type Source_Map_Record is record
      File_ID  : Natural := 1;
      Rel_Line : Positive := 1;
   end record;
   Source_Map : array (1 .. Max_Absolute_Lines) of Source_Map_Record :=
     (others => (File_ID => 1, Rel_Line => 1));
   Abs_Line_Count : Natural := 1;

   type File_Buffer_Ptr is access String;
   procedure Free_File_Buffer is new Ada.Unchecked_Deallocation (String, File_Buffer_Ptr);

   subtype Path_Buffer is String (1 .. Max_Path_Length);
   subtype Source_Index is Natural range 0 .. Max_Source_Files;

   type Assembler_Mode is (Assembler_Auto, Assembler_32, Assembler_64);

   type Compiler_Options is record
      Input_File         : Path_Buffer := (others => ' ');
      Input_Len          : Natural range 0 .. Max_Path_Length := 0;
      Output_Asm         : Path_Buffer := (others => ' ');
      Output_Asm_Len     : Natural range 0 .. Max_Path_Length := 0;
      Output_Prg         : Path_Buffer := (others => ' ');
      Output_Prg_Len     : Natural range 0 .. Max_Path_Length := 0;
      Quiet_Mode         : Boolean := False;
      Metrics_Requested  : Boolean := False;
      Workspace_Metrics  : Boolean := False;
      Timing_Requested   : Boolean := False;
      Dump_Tokens        : Boolean := False;
      Ast_Summary        : Boolean := False;
      Parse_Only         : Boolean := False;
      Lex_Only           : Boolean := False;
      No_Assemble        : Boolean := False;
      Select_Mode        : Boolean := False;
      List_Sources_Only  : Boolean := False;
      Show_Banner        : Boolean := True;
      Show_Config        : Boolean := False;
      Help_Only          : Boolean := False;
      Version_Only       : Boolean := False;
      Positional_Only    : Boolean := False;
      Assembler          : Assembler_Mode := Assembler_Auto;
      Out_Dir            : Path_Buffer := (others => ' ');
      Out_Dir_Len        : Natural range 0 .. Max_Path_Length := 0;
      Build_Mode         : Boolean := False;
      Asm_Output_Set     : Boolean := False;
      Prg_Output_Set     : Boolean := False;
   end record;

   type Source_File_Record is record
      Name : Path_Buffer := (others => ' ');
      Len  : Natural range 0 .. Max_Path_Length := 0;
   end record;

   type Source_File_Array is
     array (Positive range 1 .. Max_Source_Files) of Source_File_Record;

   type AST_Metrics_Record is record
      Node_Count       : Natural := 0;
      Statement_Count  : Natural := 0;
      Expression_Count : Natural := 0;
      Loop_Count       : Natural := 0;
      Branch_Count     : Natural := 0;
      Max_Depth        : Natural := 0;
   end record;

   Options          : Compiler_Options := (others => <>);
   Input_Len        : Natural := 0;
   Token_Count      : Natural := 0;
   Root             : Node_Index := 0;
   Lex_Diag         : Tokenizer.Lexer_Diagnostic;
   Parse_Success    : Boolean := False;
   Parse_Diag       : Parser.Parser_Diagnostic;
   Emit_Success     : Boolean := False;
   Assemble_Success : Boolean := False;
   Load_Success     : Boolean := False;
   AST_Metrics      : AST_Metrics_Record := (others => 0);
   AST_Metrics_Ready : Boolean := False;
   Start_Time       : Ada.Calendar.Time := Ada.Calendar.Clock;
   End_Time         : Ada.Calendar.Time := Ada.Calendar.Clock;

   procedure Store_Text
     (Buffer  : out Path_Buffer;
      Length  : out Natural;
      Value   : String;
      Success : out Boolean)
   is
   begin
      Buffer := (others => ' ');
      Length := 0;
      Success := False;

      if Value'Length = 0 or else Value'Length > Max_Path_Length then
         return;
      end if;

      Buffer (1 .. Value'Length) := Value;
      Length := Value'Length;
      Success := True;
   end Store_Text;

   function Slice (Buffer : Path_Buffer; Length : Natural) return String is
   begin
      if Length = 0 then
         return "";
      else
         return Buffer (1 .. Length);
      end if;
   end Slice;

   function Upper_Char (Ch : Character) return Character is
   begin
      if Ch >= 'a' and then Ch <= 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      else
         return Ch;
      end if;
   end Upper_Char;

   function Upper_ASCII (Text : String) return String is
      Result : String (1 .. Text'Length);
      Offset : Natural := 1;
   begin
      for Ch of Text loop
         Result (Offset) := Upper_Char (Ch);
         Offset := Offset + 1;
      end loop;
      return Result;
   end Upper_ASCII;

   function Ends_With (Text : String; Suffix : String) return Boolean is
   begin
      if Suffix'Length > Text'Length then
         return False;
      else
         return Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix;
      end if;
   end Ends_With;

   function Decimal_Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Decimal_Image;

   function Duration_Image (Value : Duration) return String is
      Milliseconds : Natural := 0;
   begin
      if Value > 0.0 then
         Milliseconds := Natural (Value * 1000.0);
      end if;
      return Decimal_Image (Milliseconds) & " ms";
   end Duration_Image;

   procedure Put_Status (Message : String; Always : Boolean := False) is
   begin
      if Always or else not Options.Quiet_Mode then
         Ada.Text_IO.Put_Line (Message);
      end if;
   end Put_Status;

   procedure Fail_And_Stop (Message : String) is
   begin
      Ada.Text_IO.Put_Line ("ALB-65: " & Message);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Fail_And_Stop;

   procedure Print_Banner is
   begin
      if Options.Show_Banner and then not Options.Quiet_Mode then
         Ada.Text_IO.Put_Line ("ALB-65 C64 Compiler");
         Ada.Text_IO.Put_Line ("Shared ALB front-end -> asm6f-compatible Commodore 64 backend");
         Ada.Text_IO.Put_Line ("Tip: try --select, --metrics, --emit-only, or --help");
         Ada.Text_IO.New_Line;
      end if;
   end Print_Banner;

   procedure Print_Version is
   begin
      Ada.Text_IO.Put_Line ("ALB-65 C64 Compiler Driver");
      Ada.Text_IO.Put_Line ("Backend: shared parser/tokenizer + asm6f C64 emitter");
   end Print_Version;

   procedure Print_Help is
   begin
      Ada.Text_IO.Put_Line ("Usage:");
      Ada.Text_IO.Put_Line ("  alb_65 [options] [source.alb]");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Core options:");
      Ada.Text_IO.Put_Line ("  --help, -h             Show this help");
      Ada.Text_IO.Put_Line ("  --version              Show the driver version");
      Ada.Text_IO.Put_Line ("  --quiet, -q            Suppress friendly progress chatter");
      Ada.Text_IO.Put_Line ("  --select               Choose a source file interactively");
      Ada.Text_IO.Put_Line ("  --list-sources         List .alb files in the current directory");
      Ada.Text_IO.Put_Line ("  --input, -i <file>     Compile a specific source file");
      Ada.Text_IO.Put_Line ("  --show-config          Print the resolved compilation settings");
      Ada.Text_IO.Put_Line ("  --no-banner            Skip the startup banner");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Outputs:");
      Ada.Text_IO.Put_Line ("  --asm <file>           Write emitted assembly to this file");
      Ada.Text_IO.Put_Line ("  --prg <file>           Write assembled PRG to this file");
      Ada.Text_IO.Put_Line ("  --output-base <name>   Set both outputs to <name>.asm/.prg");
      Ada.Text_IO.Put_Line ("  --outdir <dir>         Place <stem>.asm/.prg in this directory");
      Ada.Text_IO.Put_Line ("  --build, -b            Emit + assemble into --outdir (or cwd)");
      Ada.Text_IO.Put_Line ("  --emit-only            Stop after writing the .asm file");
      Ada.Text_IO.Put_Line ("  --no-assemble          Alias for --emit-only");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Pipeline control:");
      Ada.Text_IO.Put_Line ("  --lex-only             Stop after tokenization");
      Ada.Text_IO.Put_Line ("  --parse-only           Stop after parsing");
      Ada.Text_IO.Put_Line ("  --tokens, --dump-tokens");
      Ada.Text_IO.Put_Line ("                         Print the token stream after lexing");
      Ada.Text_IO.Put_Line ("  --ast-summary          Print a compact AST summary");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Metrics and diagnostics:");
      Ada.Text_IO.Put_Line ("  --metrics, -m          Show source + compiler metrics for the input file");
      Ada.Text_IO.Put_Line ("  --workspace-metrics    Show metrics for the current workspace tree");
      Ada.Text_IO.Put_Line ("  --timing               Show total elapsed compile time");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Assembler selection:");
      Ada.Text_IO.Put_Line ("  --asm6f-auto           Probe 64-bit, 32-bit, and bundled asm6f");
      Ada.Text_IO.Put_Line ("  --asm6f-64            Force the 64-bit asm6f executable first");
      Ada.Text_IO.Put_Line ("  --asm6f-32            Force the 32-bit asm6f executable first");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Examples:");
      Ada.Text_IO.Put_Line ("  alb_65 everything-65.alb --metrics --ast-summary");
      Ada.Text_IO.Put_Line ("  alb_65 --select --output-base demo");
      Ada.Text_IO.Put_Line ("  alb_65 -i demo.alb --emit-only --asm demo.asm");
      Ada.Text_IO.Put_Line ("  alb_65 demo.alb --build --outdir artifacts/demo/c64");
   end Print_Help;

   function Base_Name (Input : String) return String is
      Start : Natural := Input'First;
      Stop  : Natural := Input'Last;
      Dot   : Natural := 0;
   begin
      for I in reverse Input'Range loop
         if Input (I) = '\' or else Input (I) = '/' then
            Start := I + 1;
            exit;
         end if;
      end loop;

      for I in reverse Start .. Stop loop
         if Input (I) = '.' then
            Dot := I;
            exit;
         end if;
      end loop;

      if Dot >= Start then
         Stop := Dot - 1;
      end if;

      if Stop < Start then
         return "";
      end if;

      return Input (Start .. Stop);
   end Base_Name;

   procedure Ensure_Directory (Dir : String)
     with SPARK_Mode => Off
   is
   begin
      if Dir'Length = 0 then
         return;
      end if;

      if not Ada.Directories.Exists (Dir) then
         Ada.Directories.Create_Directory (Dir);
      end if;
   exception
      when others =>
         null;
   end Ensure_Directory;

   procedure Resolve_Output_Paths
     with SPARK_Mode => Off
   is
      Stem : constant String := Base_Name (Slice (Options.Input_File, Options.Input_Len));
      Dir  : String (1 .. Max_Path_Length) := (others => ' ');
      Dir_Len : Natural := 0;
      OK   : Boolean := False;
   begin
      if Options.Input_Len = 0 or else Stem'Length = 0 then
         return;
      end if;

      if Options.Build_Mode and then Options.Out_Dir_Len = 0
        and then not Options.Asm_Output_Set
        and then not Options.Prg_Output_Set
      then
         Store_Text
           (Options.Out_Dir,
            Options.Out_Dir_Len,
            "c64_" & Stem,
            OK);
      end if;

      if Options.Out_Dir_Len > 0
        and then not Options.Asm_Output_Set
        and then not Options.Prg_Output_Set
      then
         if Options.Out_Dir_Len + 1 + Stem'Length + 4 > Max_Path_Length then
            return;
         end if;

         Dir_Len := Options.Out_Dir_Len;
         Dir (1 .. Dir_Len) := Options.Out_Dir (1 .. Dir_Len);

         Store_Text
           (Options.Output_Asm,
            Options.Output_Asm_Len,
            Ada.Directories.Compose (Dir (1 .. Dir_Len), Stem & ".asm"),
            OK);
         if not OK then
            return;
         end if;

         Store_Text
           (Options.Output_Prg,
            Options.Output_Prg_Len,
            Ada.Directories.Compose (Dir (1 .. Dir_Len), Stem & ".prg"),
            OK);
      end if;

      if Options.Build_Mode and then Options.Out_Dir_Len > 0 then
         Ensure_Directory (Slice (Options.Out_Dir, Options.Out_Dir_Len));
      end if;
   end Resolve_Output_Paths;

   function File_Exists (Path : String) return Boolean
     with SPARK_Mode => Off
   is
   begin
      return Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File;
   exception
      when others =>
         return False;
   end File_Exists;

   procedure Set_Default_Output_Names is
      OK : Boolean := False;
   begin
      Store_Text (Options.Output_Asm, Options.Output_Asm_Len, "output.asm", OK);
      if not OK then
         return;
      end if;

      Store_Text (Options.Output_Prg, Options.Output_Prg_Len, "output.prg", OK);
   end Set_Default_Output_Names;

   procedure Set_Output_Base
     (Base    : String;
      Success : out Boolean)
   is
      OK : Boolean := False;
   begin
      Success := False;

      if Base'Length = 0 or else Base'Length + 4 > Max_Path_Length then
         return;
      end if;

      Store_Text
        (Options.Output_Asm,
         Options.Output_Asm_Len,
         Base & ".asm",
         OK);
      if not OK then
         return;
      end if;

      Store_Text
        (Options.Output_Prg,
         Options.Output_Prg_Len,
         Base & ".prg",
         OK);
      Options.Asm_Output_Set := OK;
      Options.Prg_Output_Set := OK;
      Success := OK;
   end Set_Output_Base;

   procedure Gather_Source_Files
     (Files : out Source_File_Array;
      Count : out Source_Index)
     with SPARK_Mode => Off
   is
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;

      procedure Add_File (Name : String) is
         Already_Present : Boolean := False;
      begin
         if Name'Length = 0 or else Name'Length > Max_Path_Length then
            return;
         end if;

         for I in 1 .. Count loop
            if Files (I).Len = Name'Length
              and then Files (I).Name (1 .. Name'Length) = Name
            then
               Already_Present := True;
               exit;
            end if;
         end loop;

         if not Already_Present and then Count < Max_Source_Files then
            Count := Count + 1;
            Files (Count).Name := (others => ' ');
            Files (Count).Name (1 .. Name'Length) := Name;
            Files (Count).Len := Name'Length;
         end if;
      end Add_File;

      procedure Bubble_Sort is
         Temp : Source_File_Record := (others => <>);
      begin
         if Count < 2 then
            return;
         end if;

         for Pass in 1 .. Count - 1 loop
            for I in 1 .. Count - Pass loop
               declare
                  Left  : constant String := Upper_ASCII (Slice (Files (I).Name, Files (I).Len));
                  Right : constant String := Upper_ASCII (Slice (Files (I + 1).Name, Files (I + 1).Len));
               begin
                  if Left > Right then
                     Temp := Files (I);
                     Files (I) := Files (I + 1);
                     Files (I + 1) := Temp;
                  end if;
               end;
            end loop;
         end loop;
      end Bubble_Sort;

   begin
      Files := (others => (others => <>));
      Count := 0;

      begin
         Ada.Directories.Start_Search (Search, ".", "*.alb");
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
            if Ada.Directories.Kind (Dir_Entry) = Ada.Directories.Ordinary_File then
               Add_File (Ada.Directories.Simple_Name (Dir_Entry));
            end if;
         end loop;
         Ada.Directories.End_Search (Search);
      exception
         when others =>
            null;
      end;

      begin
         Ada.Directories.Start_Search (Search, ".", "*.ALB");
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
            if Ada.Directories.Kind (Dir_Entry) = Ada.Directories.Ordinary_File then
               Add_File (Ada.Directories.Simple_Name (Dir_Entry));
            end if;
         end loop;
         Ada.Directories.End_Search (Search);
      exception
         when others =>
            null;
      end;

      Bubble_Sort;
   end Gather_Source_Files;

   procedure Print_Source_List
     (Files : Source_File_Array;
      Count : Source_Index)
   is
   begin
      if Count = 0 then
         Ada.Text_IO.Put_Line ("No .alb sources found in the current directory.");
         return;
      end if;

      Ada.Text_IO.Put_Line ("Available ALB sources:");
      for I in 1 .. Count loop
         Ada.Text_IO.Put_Line
           ("  "
            & Decimal_Image (I)
            & ". "
            & Slice (Files (I).Name, Files (I).Len));
      end loop;
   end Print_Source_List;

   procedure Resolve_Input_File (Success : out Boolean)
     with SPARK_Mode => Off
   is
      Files         : Source_File_Array := (others => (others => <>));
      Count         : Source_Index := 0;
      Prompt_Buffer : String (1 .. 32) := (others => ' ');
      Prompt_Len    : Natural := 0;
      Choice        : Natural := 0;
      Default_Index : Natural := 1;
      OK            : Boolean := False;
   begin
      Success := False;

      if Options.Input_Len > 0 then
         Success := True;
         return;
      end if;

      Gather_Source_Files (Files, Count);

      if Options.List_Sources_Only then
         Print_Source_List (Files, Count);
         return;
      end if;

      if File_Exists ("everything-65.alb") and then not Options.Select_Mode then
         Store_Text
           (Options.Input_File,
            Options.Input_Len,
            "everything-65.alb",
            OK);
         Success := OK;
         return;
      end if;

      if Count = 0 then
         return;
      elsif Count = 1 and then not Options.Select_Mode then
         Store_Text
           (Options.Input_File,
            Options.Input_Len,
            Slice (Files (1).Name, Files (1).Len),
            OK);
         Success := OK;
         return;
      end if;

      for I in 1 .. Count loop
         if Upper_ASCII (Slice (Files (I).Name, Files (I).Len)) = "EVERYTHING-65.ALB" then
            Default_Index := I;
            exit;
         end if;
      end loop;

      Print_Source_List (Files, Count);
      Ada.Text_IO.Put
        ("Select source ["
         & Decimal_Image (Default_Index)
         & "]: ");

      begin
         declare
            Raw : constant String := Ada.Text_IO.Get_Line;
         begin
            Prompt_Len := Natural'Min (Raw'Length, Prompt_Buffer'Length);
            if Prompt_Len > 0 then
               Prompt_Buffer (1 .. Prompt_Len) := Raw (Raw'First .. Raw'First + Prompt_Len - 1);
            end if;
         end;
      exception
         when others =>
            Prompt_Len := 0;
      end;

      if Prompt_Len = 0 then
         Choice := Default_Index;
      else
         begin
            Choice := Natural'Value (Prompt_Buffer (1 .. Prompt_Len));
         exception
            when others =>
               Choice := 0;
         end;
      end if;

      if Choice in 1 .. Count then
         Store_Text
           (Options.Input_File,
            Options.Input_Len,
            Slice (Files (Choice).Name, Files (Choice).Len),
            OK);
         Success := OK;
      end if;
   end Resolve_Input_File;

   procedure Print_Config is
      Assembler_Name : constant String :=
        (case Options.Assembler is
            when Assembler_Auto => "auto",
            when Assembler_32   => "asm6f_32",
            when Assembler_64   => "asm6f_64");
   begin
      Ada.Text_IO.Put_Line ("Configuration:");
      Ada.Text_IO.Put_Line ("  source:        " & Slice (Options.Input_File, Options.Input_Len));
      Ada.Text_IO.Put_Line ("  asm output:    " & Slice (Options.Output_Asm, Options.Output_Asm_Len));
      Ada.Text_IO.Put_Line ("  prg output:    " & Slice (Options.Output_Prg, Options.Output_Prg_Len));
      Ada.Text_IO.Put_Line ("  assembler:     " & Assembler_Name);
      Ada.Text_IO.Put_Line ("  assemble:      " & (if Options.No_Assemble then "no" else "yes"));
      Ada.Text_IO.Put_Line ("  lex only:      " & (if Options.Lex_Only then "yes" else "no"));
      Ada.Text_IO.Put_Line ("  parse only:    " & (if Options.Parse_Only then "yes" else "no"));
      Ada.Text_IO.Put_Line ("  dump tokens:   " & (if Options.Dump_Tokens then "yes" else "no"));
      Ada.Text_IO.Put_Line ("  ast summary:   " & (if Options.Ast_Summary then "yes" else "no"));
      Ada.Text_IO.Put_Line ("  metrics:       " & (if Options.Metrics_Requested then "yes" else "no"));
      Ada.Text_IO.Put_Line ("  workspace met: " & (if Options.Workspace_Metrics then "yes" else "no"));
      Ada.Text_IO.Put_Line ("  timing:        " & (if Options.Timing_Requested then "yes" else "no"));
      Ada.Text_IO.New_Line;
   end Print_Config;

   procedure Parse_Options (Success : out Boolean)
     with SPARK_Mode => Off
   is
      OK  : Boolean := False;
      I   : Positive := 1;
   begin
      Success := True;
      Set_Default_Output_Names;

      while I <= Ada.Command_Line.Argument_Count loop
         declare
            Arg : constant String := Ada.Command_Line.Argument (I);
         begin

            if not Options.Positional_Only and then Arg = "--" then
               Options.Positional_Only := True;

            elsif not Options.Positional_Only and then (Arg = "--help" or else Arg = "-h") then
               Options.Help_Only := True;

            elsif not Options.Positional_Only and then Arg = "--version" then
               Options.Version_Only := True;

            elsif not Options.Positional_Only and then (Arg = "--quiet" or else Arg = "-q") then
               Options.Quiet_Mode := True;

            elsif not Options.Positional_Only and then (Arg = "--metrics" or else Arg = "-m") then
               Options.Metrics_Requested := True;

            elsif not Options.Positional_Only and then Arg = "--workspace-metrics" then
               Options.Workspace_Metrics := True;

            elsif not Options.Positional_Only and then Arg = "--timing" then
               Options.Timing_Requested := True;

            elsif not Options.Positional_Only and then (Arg = "--tokens" or else Arg = "--dump-tokens") then
               Options.Dump_Tokens := True;

            elsif not Options.Positional_Only and then Arg = "--ast-summary" then
               Options.Ast_Summary := True;

            elsif not Options.Positional_Only and then Arg = "--parse-only" then
               Options.Parse_Only := True;
               Options.No_Assemble := True;

            elsif not Options.Positional_Only and then Arg = "--lex-only" then
               Options.Lex_Only := True;
               Options.Parse_Only := True;
               Options.No_Assemble := True;

            elsif not Options.Positional_Only
              and then (Arg = "--emit-only" or else Arg = "--no-assemble")
            then
               Options.No_Assemble := True;

            elsif not Options.Positional_Only and then Arg = "--select" then
               Options.Select_Mode := True;

            elsif not Options.Positional_Only and then Arg = "--list-sources" then
               Options.List_Sources_Only := True;

            elsif not Options.Positional_Only and then Arg = "--show-config" then
               Options.Show_Config := True;

            elsif not Options.Positional_Only and then Arg = "--no-banner" then
               Options.Show_Banner := False;

            elsif not Options.Positional_Only and then Arg = "--asm6f-auto" then
               Options.Assembler := Assembler_Auto;

            elsif not Options.Positional_Only and then Arg = "--asm6f-32" then
               Options.Assembler := Assembler_32;

            elsif not Options.Positional_Only and then Arg = "--asm6f-64" then
               Options.Assembler := Assembler_64;

            elsif not Options.Positional_Only and then (Arg = "--input" or else Arg = "-i") then
               if I = Ada.Command_Line.Argument_Count then
                  Success := False;
                  Fail_And_Stop ("--input requires a file name.");
                  return;
               end if;

               I := I + 1;
               Store_Text
                 (Options.Input_File,
                  Options.Input_Len,
                  Ada.Command_Line.Argument (I),
                  OK);
               if not OK then
                  Success := False;
                  Fail_And_Stop ("input file path is empty or too long.");
                  return;
               end if;

            elsif not Options.Positional_Only and then Arg = "--asm" then
               if I = Ada.Command_Line.Argument_Count then
                  Success := False;
                  Fail_And_Stop ("--asm requires a file name.");
                  return;
               end if;

               I := I + 1;
               Store_Text
                 (Options.Output_Asm,
                  Options.Output_Asm_Len,
                  Ada.Command_Line.Argument (I),
                  OK);
               if not OK then
                  Success := False;
                  Fail_And_Stop ("assembly output path is empty or too long.");
                  return;
               end if;
               Options.Asm_Output_Set := True;

            elsif not Options.Positional_Only and then Arg = "--prg" then
               if I = Ada.Command_Line.Argument_Count then
                  Success := False;
                  Fail_And_Stop ("--prg requires a file name.");
                  return;
               end if;

               I := I + 1;
               Store_Text
                 (Options.Output_Prg,
                  Options.Output_Prg_Len,
                  Ada.Command_Line.Argument (I),
                  OK);
               if not OK then
                  Success := False;
                  Fail_And_Stop ("PRG output path is empty or too long.");
                  return;
               end if;
               Options.Prg_Output_Set := True;

            elsif not Options.Positional_Only and then Arg = "--outdir" then
               if I = Ada.Command_Line.Argument_Count then
                  Success := False;
                  Fail_And_Stop ("--outdir requires a directory.");
                  return;
               end if;

               I := I + 1;
               Store_Text
                 (Options.Out_Dir,
                  Options.Out_Dir_Len,
                  Ada.Command_Line.Argument (I),
                  OK);
               if not OK then
                  Success := False;
                  Fail_And_Stop ("output directory path is empty or too long.");
                  return;
               end if;

            elsif not Options.Positional_Only
              and then (Arg = "--build" or else Arg = "-b")
            then
               Options.Build_Mode := True;
               Options.No_Assemble := False;

            elsif not Options.Positional_Only and then Arg = "--output-base" then
               if I = Ada.Command_Line.Argument_Count then
                  Success := False;
                  Fail_And_Stop ("--output-base requires a base name.");
                  return;
               end if;

               I := I + 1;
               Set_Output_Base (Ada.Command_Line.Argument (I), OK);
               if not OK then
                  Success := False;
                  Fail_And_Stop ("output base is empty or too long.");
                  return;
               end if;

            elsif Arg'Length > 0 and then Arg (Arg'First) = '-' and then not Options.Positional_Only then
               Success := False;
               Fail_And_Stop ("unknown option: " & Arg);
               return;

            else
               if Options.Input_Len = 0 then
                  Store_Text (Options.Input_File, Options.Input_Len, Arg, OK);
                  if not OK then
                     Success := False;
                     Fail_And_Stop ("input file path is empty or too long.");
                     return;
                  end if;
               else
                  Success := False;
                  Fail_And_Stop ("multiple input files are not supported by alb_65 yet.");
                  return;
               end if;
            end if;
         end;

         I := I + 1;
      end loop;
   end Parse_Options;

   function Parent_Directory (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '\' or else Path (I) = '/' then
            return Path (Path'First .. I - 1);
         end if;
      end loop;
      return "";
   end Parent_Directory;

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

   function Is_Already_Included (File_Name : String) return Boolean is
      Check_Len : Natural := File_Name'Length;
   begin
      for I in 1 .. Include_Count loop
         if Include_Lens (I) = Check_Len
           and then Include_Vault (I) (1 .. Check_Len) = File_Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Already_Included;

   procedure Register_Include
     (File_Name : String;
      Success   : in out Boolean;
      ID        : out Natural)
   is
   begin
      if Include_Count < Max_Includes then
         Include_Count := Include_Count + 1;
         Include_Lens (Include_Count) := File_Name'Length;
         Include_Vault (Include_Count) (1 .. File_Name'Length) := File_Name;
         ID := Include_Count;
      else
         Ada.Text_IO.Put_Line ("ALB-65: maximum include limit reached.");
         Success := False;
         ID := 0;
      end if;
   end Register_Include;

   function Diagnostic_File_Name (Abs_Line : Positive) return String is
      Rec : Source_Map_Record := Source_Map (Natural (Abs_Line));
   begin
      if Rec.File_ID in 1 .. Include_Count then
         return Include_Vault (Rec.File_ID) (1 .. Include_Lens (Rec.File_ID));
      end if;
      return Slice (Options.Input_File, Options.Input_Len);
   end Diagnostic_File_Name;

   function Diagnostic_Rel_Line (Abs_Line : Positive) return Positive is
   begin
      return Source_Map (Natural (Abs_Line)).Rel_Line;
   end Diagnostic_Rel_Line;

   procedure Load_Source_File
     (File_Name : String;
      Success   : out Boolean)
     with SPARK_Mode => Off
   is
      procedure Process_File_Weave (F_Name : String; Ok : in out Boolean) is
         Local_Buffer : File_Buffer_Ptr := new String (1 .. 524288);
         Local_Len    : Natural := 0;
         File         : Ada.Streams.Stream_IO.File_Type;
         Stream_Ptr   : Ada.Streams.Stream_IO.Stream_Access;
         Char         : Character;
         File_Dir     : constant String := Parent_Directory (F_Name);

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

            for J in Leaf'Range loop
               if Leaf (J) = '\' or else Leaf (J) = '/' then
                  if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
                     return Dir & Leaf;
                  else
                     return Dir & "\" & Leaf;
                  end if;
               end if;
            end loop;

            return Ada.Directories.Compose (Dir, Leaf);
         end Compose_Include_Path;

         function At_Directive_Start (Pos : Natural) return Boolean is
            J : Natural := Pos;
         begin
            if Pos = 1 then
               return True;
            end if;
            J := Pos - 1;
            loop
               if Local_Buffer (J) = LF then
                  return True;
               elsif Local_Buffer (J) /= ' '
                 and then Local_Buffer (J) /= ASCII.HT
                 and then Local_Buffer (J) /= ASCII.CR
               then
                  return False;
               end if;
               exit when J = 1;
               J := J - 1;
            end loop;
            return True;
         end At_Directive_Start;

         My_File_ID : Natural := 0;
         Rel_Line   : Positive := 1;
         I          : Natural := 1;
         Inc_Start  : Natural;
         Inc_End    : Natural;
         Inc_File   : String (1 .. Max_Path_Length) := (others => ' ');
         Inc_Flen   : Natural;
      begin
         if Is_Already_Included (F_Name) then
            Free_File_Buffer (Local_Buffer);
            return;
         end if;

         Register_Include (F_Name, Ok, My_File_ID);
         if not Ok then
            Free_File_Buffer (Local_Buffer);
            return;
         end if;

         Source_Map (Abs_Line_Count) := (File_ID => My_File_ID, Rel_Line => Rel_Line);

         begin
            Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, F_Name);
            Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);
            while not Ada.Streams.Stream_IO.End_Of_File (File) loop
               Character'Read (Stream_Ptr, Char);
               if Local_Len < Local_Buffer'Length then
                  Local_Len := Local_Len + 1;
                  Local_Buffer (Local_Len) := Char;
               else
                  Ada.Text_IO.Put_Line ("ALB-65: file exceeds 512KB weave buffer: " & F_Name);
                  Ok := False;
                  Ada.Streams.Stream_IO.Close (File);
                  Free_File_Buffer (Local_Buffer);
                  return;
               end if;
            end loop;
            Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               Ada.Text_IO.Put_Line ("ALB-65: could not read file: " & F_Name);
               Ok := False;
               Free_File_Buffer (Local_Buffer);
               return;
         end;

         while I <= Local_Len loop
            declare
               Match_Include : Boolean := False;
            begin
               if I + 6 <= Local_Len
                 and then (Local_Buffer (I .. I + 6) = "INCLUDE"
                           or else Local_Buffer (I .. I + 6) = "include")
               then
                  if At_Directive_Start (I)
                    and then I + 7 <= Local_Len
                    and then (Local_Buffer (I + 7) = ' ' or else Local_Buffer (I + 7) = '"')
                  then
                     Match_Include := True;
                  end if;
               end if;

               if Match_Include then
                  I := I + 7;
                  while I <= Local_Len and then Local_Buffer (I) = ' ' loop
                     I := I + 1;
                  end loop;

                  if I <= Local_Len and then Local_Buffer (I) = '"' then
                     I := I + 1;
                     Inc_Start := I;
                     while I <= Local_Len and then Local_Buffer (I) /= '"' loop
                        I := I + 1;
                     end loop;
                     Inc_End := I - 1;

                     if Inc_End >= Inc_Start then
                        Inc_Flen := Inc_End - Inc_Start + 1;
                        Inc_File (1 .. Inc_Flen) := Local_Buffer (Inc_Start .. Inc_End);
                        declare
                           Resolved_Include : constant String :=
                             (if Is_Absolute_Path (Inc_File (1 .. Inc_Flen))
                                 or else File_Dir'Length = 0
                              then Inc_File (1 .. Inc_Flen)
                              else Compose_Include_Path (File_Dir, Inc_File (1 .. Inc_Flen)));
                        begin
                           Process_File_Weave (Resolved_Include, Ok);
                        end;
                        if not Ok then
                           Free_File_Buffer (Local_Buffer);
                           return;
                        end if;
                        Source_Map (Abs_Line_Count) :=
                          (File_ID => My_File_ID, Rel_Line => Rel_Line);
                     end if;
                     I := I + 1;
                     while I <= Local_Len and then Local_Buffer (I) /= LF loop
                        I := I + 1;
                     end loop;
                  end if;
               else
                  if Input_Len < Input_Buffer'Length then
                     Input_Len := Input_Len + 1;
                     Input_Buffer (Input_Len) := Local_Buffer (I);
                     if Local_Buffer (I) = LF then
                        if Abs_Line_Count < Max_Absolute_Lines then
                           Abs_Line_Count := Abs_Line_Count + 1;
                        end if;
                        Rel_Line := Rel_Line + 1;
                        Source_Map (Abs_Line_Count) :=
                          (File_ID => My_File_ID, Rel_Line => Rel_Line);
                     end if;
                  else
                     Ada.Text_IO.Put_Line ("ALB-65: script exceeds 4MB static buffer limit.");
                     Ok := False;
                     Free_File_Buffer (Local_Buffer);
                     return;
                  end if;
                  I := I + 1;
               end if;
            end;
         end loop;

         if Input_Len > 0 and then Input_Buffer (Input_Len) /= LF then
            if Input_Len < Input_Buffer'Length then
               Input_Len := Input_Len + 1;
               Input_Buffer (Input_Len) := LF;
               if Abs_Line_Count < Max_Absolute_Lines then
                  Abs_Line_Count := Abs_Line_Count + 1;
               end if;
               Rel_Line := Rel_Line + 1;
               Source_Map (Abs_Line_Count) :=
                 (File_ID => My_File_ID, Rel_Line => Rel_Line);
            end if;
         end if;
         Free_File_Buffer (Local_Buffer);
      end Process_File_Weave;
   begin
      Success := True;
      Input_Len := 0;
      Include_Count := 0;
      Abs_Line_Count := 1;
      Process_File_Weave (File_Name, Success);
   end Load_Source_File;

   procedure Dump_Token_Stream
     with SPARK_Mode => Off
   is
      Lexeme : String (1 .. 48) := (others => ' ');
      Length : Natural := 0;
      Ch     : Character := ' ';
   begin
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Token Stream:");
      Ada.Text_IO.Put_Line ("------------------------------------------------------------");
      for I in 1 .. Token_Count loop
         Length := Natural'Min (Tokens (I).Length, Lexeme'Length);
         if Length > 0 then
            for J in 0 .. Length - 1 loop
               Ch := Input_Buffer (Tokens (I).Start + J);
               if Ch = Ada.Characters.Latin_1.CR or else Ch = Ada.Characters.Latin_1.LF then
                  Lexeme (J + 1) := ' ';
               else
                  Lexeme (J + 1) := Ch;
               end if;
            end loop;
         end if;

         Ada.Text_IO.Put_Line
           ("  "
            & Decimal_Image (Tokens (I).Line)
            & ":"
            & Decimal_Image (Tokens (I).Column)
            & "  "
            & Tokenizer.Token_Kind'Image (Tokens (I).Kind)
            & "  "
            & Lexeme (1 .. Length));
      end loop;
      Ada.Text_IO.Put_Line ("------------------------------------------------------------");
      Ada.Text_IO.New_Line;
   end Dump_Token_Stream;

   procedure Compute_AST_Metrics
     (Root_Node : Node_Index;
      Metrics   : out AST_Metrics_Record)
     with SPARK_Mode => Off
   is
      subtype Stack_Index is Natural range 0 .. Max_AST_Stack;
      type Node_Stack_Array is array (Positive range 1 .. Max_AST_Stack) of Node_Index;
      type Depth_Stack_Array is array (Positive range 1 .. Max_AST_Stack) of Natural;

      Node_Stack  : Node_Stack_Array := (others => 0);
      Depth_Stack : Depth_Stack_Array := (others => 0);
      Top         : Stack_Index := 0;

      procedure Push (Node : Node_Index; Depth : Natural) is
      begin
         if Node = 0 then
            return;
         end if;

         if Top < Max_AST_Stack then
            Top := Top + 1;
            Node_Stack (Top) := Node;
            Depth_Stack (Top) := Depth;
         end if;
      end Push;

      function Is_Statement_Kind (Kind : Node_Kind) return Boolean is
         Image : constant String := Node_Kind'Image (Kind);
      begin
         return Ends_With (Image, "_STMT")
           or else Ends_With (Image, "_DECL")
           or else Kind = AST_Block_Stmt
           or else Kind = AST_Version
           or else Kind = AST_Text;
      end Is_Statement_Kind;

      function Is_Expression_Kind (Kind : Node_Kind) return Boolean is
         Image : constant String := Node_Kind'Image (Kind);
      begin
         return Ends_With (Image, "_EXPR")
           or else Kind = AST_True
           or else Kind = AST_False
           or else Kind = AST_Func_Call
           or else Kind = AST_Constructor;
      end Is_Expression_Kind;

      Curr_Node  : Node_Index := 0;
      Curr_Depth : Natural := 0;
   begin
      Metrics := (others => 0);
      Push (Root_Node, 1);

      while Top > 0 loop
         Curr_Node := Node_Stack (Top);
         Curr_Depth := Depth_Stack (Top);
         Top := Top - 1;

         Metrics.Node_Count := Metrics.Node_Count + 1;
         if Curr_Depth > Metrics.Max_Depth then
            Metrics.Max_Depth := Curr_Depth;
         end if;

         if Is_Statement_Kind (Tree (Curr_Node).Kind) then
            Metrics.Statement_Count := Metrics.Statement_Count + 1;
         end if;

         if Is_Expression_Kind (Tree (Curr_Node).Kind) then
            Metrics.Expression_Count := Metrics.Expression_Count + 1;
         end if;

         case Tree (Curr_Node).Kind is
            when AST_For_Stmt | AST_While_Stmt | AST_Repeat_Stmt | AST_Foreach_Stmt =>
               Metrics.Loop_Count := Metrics.Loop_Count + 1;

            when AST_If_Stmt | AST_Match_Stmt | AST_Select_Stmt | AST_Case_Stmt =>
               Metrics.Branch_Count := Metrics.Branch_Count + 1;

            when others =>
               null;
         end case;

         Push (Tree (Curr_Node).Next_Sibling, Curr_Depth);
         Push (Tree (Curr_Node).Right_Child, Curr_Depth + 1);
         Push (Tree (Curr_Node).Left_Child, Curr_Depth + 1);
      end loop;
   end Compute_AST_Metrics;

   function Source_Line_Count return Natural is
      Count : Natural := 0;
   begin
      for I in 1 .. Input_Len loop
         if Input_Buffer (I) = LF then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Source_Line_Count;

   function File_Size_Text (Path : String) return String
     with SPARK_Mode => Off
   is
      Size : Ada.Directories.File_Size := 0;
   begin
      if File_Exists (Path) then
         Size := Ada.Directories.Size (Path);
         return Ada.Directories.File_Size'Image (Size);
      else
         return " n/a";
      end if;
   exception
      when others =>
         return " n/a";
   end File_Size_Text;

   procedure Print_Source_Metrics is
   begin
      if not Options.Metrics_Requested then
         return;
      end if;

      Code_Information.Reset_Metrics;
      Code_Information.Scan_Target (Slice (Options.Input_File, Options.Input_Len));
      Code_Information.Print_Metrics;
   end Print_Source_Metrics;

   procedure Print_Workspace_Metrics is
   begin
      if not Options.Workspace_Metrics then
         return;
      end if;

      Code_Information.Reset_Metrics;
      Code_Information.Scan_Target (".");
      Code_Information.Print_Metrics;
   end Print_Workspace_Metrics;

   procedure Print_Compiler_Metrics is
   begin
      if not Options.Metrics_Requested then
         return;
      end if;

      Ada.Text_IO.Put_Line ("ALB-65 Compiler Metrics");
      Ada.Text_IO.Put_Line ("------------------------------------------------------------");
      Ada.Text_IO.Put_Line ("  Source file:      " & Slice (Options.Input_File, Options.Input_Len));
      Ada.Text_IO.Put_Line ("  Source bytes:     " & Decimal_Image (Input_Len));
      Ada.Text_IO.Put_Line ("  Source lines:     " & Decimal_Image (Source_Line_Count));
      Ada.Text_IO.Put_Line ("  Tokens:           " & Decimal_Image (Token_Count));

      if AST_Metrics_Ready then
         Ada.Text_IO.Put_Line ("  AST nodes:        " & Decimal_Image (AST_Metrics.Node_Count));
         Ada.Text_IO.Put_Line ("  Statements/Decls: " & Decimal_Image (AST_Metrics.Statement_Count));
         Ada.Text_IO.Put_Line ("  Expressions:      " & Decimal_Image (AST_Metrics.Expression_Count));
         Ada.Text_IO.Put_Line ("  Loops:            " & Decimal_Image (AST_Metrics.Loop_Count));
         Ada.Text_IO.Put_Line ("  Branches:         " & Decimal_Image (AST_Metrics.Branch_Count));
         Ada.Text_IO.Put_Line ("  Max AST depth:    " & Decimal_Image (AST_Metrics.Max_Depth));
      end if;

      Ada.Text_IO.Put_Line
        ("  ASM file size:    "
         & File_Size_Text (Slice (Options.Output_Asm, Options.Output_Asm_Len)));
      Ada.Text_IO.Put_Line
        ("  PRG file size:    "
         & File_Size_Text (Slice (Options.Output_Prg, Options.Output_Prg_Len)));
      Ada.Text_IO.Put_Line ("------------------------------------------------------------");
      Ada.Text_IO.New_Line;
   end Print_Compiler_Metrics;

   procedure Print_AST_Summary is
   begin
      if not Options.Ast_Summary then
         return;
      end if;

      Ada.Text_IO.Put_Line ("AST Summary");
      Ada.Text_IO.Put_Line ("------------------------------------------------------------");
      Ada.Text_IO.Put_Line ("  Root kind:        " & Node_Kind'Image (Tree (Root).Kind));
      Ada.Text_IO.Put_Line ("  Reachable nodes:  " & Decimal_Image (AST_Metrics.Node_Count));
      Ada.Text_IO.Put_Line ("  Statements/Decls: " & Decimal_Image (AST_Metrics.Statement_Count));
      Ada.Text_IO.Put_Line ("  Expressions:      " & Decimal_Image (AST_Metrics.Expression_Count));
      Ada.Text_IO.Put_Line ("  Loops:            " & Decimal_Image (AST_Metrics.Loop_Count));
      Ada.Text_IO.Put_Line ("  Branches:         " & Decimal_Image (AST_Metrics.Branch_Count));
      Ada.Text_IO.Put_Line ("  Max depth:        " & Decimal_Image (AST_Metrics.Max_Depth));
      Ada.Text_IO.Put_Line ("------------------------------------------------------------");
      Ada.Text_IO.New_Line;
   end Print_AST_Summary;

   procedure Try_Assembler
     (Executable : String;
      Success    : out Boolean)
     with SPARK_Mode => Off
   is
      use GNAT.OS_Lib;

      Output_Asm : aliased String := Slice (Options.Output_Asm, Options.Output_Asm_Len);
      Output_Prg : aliased String := Slice (Options.Output_Prg, Options.Output_Prg_Len);
      Args       : Argument_List (1 .. 2) :=
        (1 => Output_Asm'Unchecked_Access,
         2 => Output_Prg'Unchecked_Access);
   begin
      Success := False;
      Spawn (Executable, Args, Success);
   end Try_Assembler;

   procedure Assemble_Output (Success : out Boolean)
     with SPARK_Mode => Off
   is
      Attempts : Natural := 0;

      procedure Try (Executable : String) is
      begin
         if not Success then
            Attempts := Attempts + 1;
            Try_Assembler (Executable, Success);
         end if;
      end Try;
   begin
      Success := False;

      case Options.Assembler is
         when Assembler_64 =>
            Try ("asm6f_64.exe");
            Try ("THIRD_PARTY\asm6f_64.exe");
            Try ("third_party\asm6f_64.exe");
            Try ("..\THIRD_PARTY\asm6f\asm6f_64.exe");
            Try ("..\third_party\asm6f\asm6f_64.exe");

         when Assembler_32 =>
            Try ("asm6f_32.exe");
            Try ("THIRD_PARTY\asm6f_32.exe");
            Try ("third_party\asm6f_32.exe");
            Try ("..\THIRD_PARTY\asm6f\asm6f_32.exe");
            Try ("..\third_party\asm6f\asm6f_32.exe");

         when Assembler_Auto =>
            Try ("asm6f_64.exe");
            Try ("asm6f_32.exe");
            Try ("THIRD_PARTY\asm6f_64.exe");
            Try ("THIRD_PARTY\asm6f_32.exe");
            Try ("third_party\asm6f_64.exe");
            Try ("third_party\asm6f_32.exe");
            Try ("..\THIRD_PARTY\asm6f\asm6f_64.exe");
            Try ("..\THIRD_PARTY\asm6f\asm6f_32.exe");
            Try ("..\third_party\asm6f\asm6f_64.exe");
            Try ("..\third_party\asm6f\asm6f_32.exe");
      end case;
   end Assemble_Output;

   procedure Report_Status is
   begin
      if Options.Lex_Only then
         Put_Status
           ("Tokenized "
            & Slice (Options.Input_File, Options.Input_Len)
            & " successfully.",
            Always => not Options.Quiet_Mode);
      elsif Options.Parse_Only then
         Put_Status
           ("Parsed "
            & Slice (Options.Input_File, Options.Input_Len)
            & " successfully.",
            Always => not Options.Quiet_Mode);
      elsif Emit_Success and then Assemble_Success then
         Put_Status
           ("Compiled "
            & Slice (Options.Input_File, Options.Input_Len)
            & " into "
            & Slice (Options.Output_Asm, Options.Output_Asm_Len)
            & " and "
            & Slice (Options.Output_Prg, Options.Output_Prg_Len)
            & ".",
            Always => not Options.Quiet_Mode);
      elsif Emit_Success and then Options.No_Assemble then
         Put_Status
           ("Emitted "
            & Slice (Options.Output_Asm, Options.Output_Asm_Len)
            & " from "
            & Slice (Options.Input_File, Options.Input_Len)
            & ".",
            Always => not Options.Quiet_Mode);
      elsif Emit_Success then
         Put_Status
           ("Emitted "
            & Slice (Options.Output_Asm, Options.Output_Asm_Len)
            & ", but asm6f did not run successfully.",
            Always => True);
      end if;
   end Report_Status;

   procedure Print_Final_Reports is
   begin
      if Options.Ast_Summary and then AST_Metrics_Ready then
         Print_AST_Summary;
      end if;

      Print_Source_Metrics;
      Print_Compiler_Metrics;
      Print_Workspace_Metrics;

      if Options.Timing_Requested then
         Ada.Text_IO.Put_Line
           ("Elapsed: " & Duration_Image (End_Time - Start_Time));
      end if;
   end Print_Final_Reports;

begin
   Parse_Options (Load_Success);
   if not Load_Success then
      return;
   end if;

   if Options.Help_Only then
      Print_Help;
      return;
   end if;

   if Options.Version_Only then
      Print_Version;
      return;
   end if;

   if Options.List_Sources_Only then
      Resolve_Input_File (Load_Success);
      return;
   end if;

   Resolve_Input_File (Load_Success);
   if not Load_Success then
      Fail_And_Stop ("no source file selected. Use --select or pass a .alb path.");
      return;
   end if;

   if not File_Exists (Slice (Options.Input_File, Options.Input_Len)) then
      Fail_And_Stop ("could not load source file: " & Slice (Options.Input_File, Options.Input_Len));
      return;
   end if;

   Resolve_Output_Paths;

   Print_Banner;
   if Options.Show_Config then
      Print_Config;
   end if;

   Start_Time := Ada.Calendar.Clock;
   Put_Status ("Loading " & Slice (Options.Input_File, Options.Input_Len) & "...");
   Load_Source_File (Slice (Options.Input_File, Options.Input_Len), Load_Success);
   if not Load_Success then
      Fail_And_Stop ("could not load source file: " & Slice (Options.Input_File, Options.Input_Len));
      return;
   end if;

   Put_Status ("Tokenizing...");
   Tokenizer.Tokenize
     (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, Lex_Diag);
   if Options.Dump_Tokens and then Lex_Diag.Success then
      Dump_Token_Stream;
   end if;

   if not Lex_Diag.Success then
      ALB_Oracle.Render_Consultation
        (Input_Buffer (1 .. Input_Len),
         Lex_Diag.Error_Line,
         Diagnostic_Rel_Line (Lex_Diag.Error_Line),
         Lex_Diag.Error_Col,
         Diagnostic_File_Name (Lex_Diag.Error_Line),
         Lex_Diag.Code);
      End_Time := Ada.Calendar.Clock;
      Print_Source_Metrics;
      Print_Workspace_Metrics;
      if Options.Timing_Requested then
         Ada.Text_IO.Put_Line ("Elapsed: " & Duration_Image (End_Time - Start_Time));
      end if;
      return;
   end if;

   if Options.Lex_Only then
      End_Time := Ada.Calendar.Clock;
      Report_Status;
      Print_Source_Metrics;
      Print_Workspace_Metrics;
      if Options.Timing_Requested then
         Ada.Text_IO.Put_Line ("Elapsed: " & Duration_Image (End_Time - Start_Time));
      end if;
      return;
   end if;

   Put_Status ("Parsing...");
   Parser.Parse (Tokens, Token_Count, Tree, Root, Parse_Success, Parse_Diag);
   if not Parse_Success or else Parse_Diag.Error_Count > 0 then
      declare
         Err_Index : Positive := 1;
         Arg_Text  : String (1 .. 64) := (others => ' ');
         Arg_Len   : Natural := 0;
      begin
         for I in 1 .. Parse_Diag.Error_Count loop
            if Parse_Diag.Errors (I).Severity = Parser.Fatal then
               Err_Index := I;
               exit;
            end if;
         end loop;

         for I in 1 .. Token_Count loop
            if Tokens (I).Line = Parse_Diag.Errors (Err_Index).Line
              and then Tokens (I).Column = Parse_Diag.Errors (Err_Index).Col
            then
               Arg_Len := Natural'Min (Tokens (I).Length, Arg_Text'Length);
               if Arg_Len > 0 then
                  Arg_Text (1 .. Arg_Len) :=
                    Input_Buffer (Tokens (I).Start .. Tokens (I).Start + Arg_Len - 1);
               end if;
               exit;
            end if;
         end loop;

         ALB_Oracle.Render_Consultation
           (Input_Buffer (1 .. Input_Len),
            Parse_Diag.Errors (Err_Index).Line,
            Diagnostic_Rel_Line (Parse_Diag.Errors (Err_Index).Line),
            Parse_Diag.Errors (Err_Index).Col,
            Diagnostic_File_Name (Parse_Diag.Errors (Err_Index).Line),
            Parse_Diag.Errors (Err_Index).Code,
            Arg_Text (1 .. Arg_Len));
      end;

      End_Time := Ada.Calendar.Clock;
      Print_Source_Metrics;
      Print_Workspace_Metrics;
      if Options.Timing_Requested then
         Ada.Text_IO.Put_Line ("Elapsed: " & Duration_Image (End_Time - Start_Time));
      end if;
      return;
   end if;

   Compute_AST_Metrics (Root, AST_Metrics);
   AST_Metrics_Ready := True;

   if Options.Parse_Only then
      End_Time := Ada.Calendar.Clock;
      Report_Status;
      Print_Final_Reports;
      return;
   end if;

   Put_Status ("Emitting " & Slice (Options.Output_Asm, Options.Output_Asm_Len) & "...");
   Emit_Native_C64.Emit_Program
     (Root,
      Slice (Options.Output_Asm, Options.Output_Asm_Len),
      Emit_Success);
   if not Emit_Success then
      End_Time := Ada.Calendar.Clock;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      Print_Final_Reports;
      return;
   end if;

   if not Options.No_Assemble then
      Put_Status ("Assembling " & Slice (Options.Output_Prg, Options.Output_Prg_Len) & "...");
      Assemble_Output (Assemble_Success);
   end if;

   End_Time := Ada.Calendar.Clock;
   Report_Status;
   Print_Final_Reports;
end Alb_65;
