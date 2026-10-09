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

pragma Warnings (On);

with Ada.Command_Line;      use Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;        use Ada.Exceptions;
with Ada.Strings;           use Ada.Strings;
with Ada.Strings.Fixed;     use Ada.Strings.Fixed;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;           use Ada.Text_IO;

with Tokenizer;             use Tokenizer;
with Parser;                use Parser;
with AST;                   use AST;
with ALB_Oracle;            use ALB_Oracle;
with Compiler_State;        use Compiler_State;
with Interpreter;           use Interpreter;
with Memory_Allocator;      use Memory_Allocator;

procedure ALB_Player is

   Max_Path_Len       : constant := 512;
   Max_Includes       : constant := 64;
   Max_Absolute_Lines : constant := 131072;
   Max_Line_Length    : constant := 16384;

   type Load_Failure_Reason is
     (Load_None,
      Load_Path_Invalid,
      Load_File_Open_Failed,
      Load_Buffer_Overflow);

   subtype Include_Path is String (1 .. Max_Path_Len);

   type Source_Map_Record is record
      File_ID   : Natural := 1;
      Rel_Line  : Positive := 1;
   end record;

   Include_Vault : array (1 .. Max_Includes) of Include_Path := (others => (others => ' '));
   Include_Lens  : array (1 .. Max_Includes) of Natural := (others => 0);
   Include_Count : Natural := 0;
   Last_Load_Failure : Load_Failure_Reason := Load_None;
   Failed_Load_Path  : Include_Path := (others => ' ');
   Failed_Load_Len   : Natural := 0;

   Source_Map : array (1 .. Max_Absolute_Lines) of Source_Map_Record :=
     (others => (File_ID => 1, Rel_Line => 1));
   Abs_Line_Count : Positive := 1;

   Input_File  : Include_Path := (others => ' ');
   Input_Flen  : Natural := 0;
   Input_Len   : Natural := 0;
   Token_Count : Natural := 0;
   Root        : Node_Index := 0;

   Lex_Diag      : Lexer_Diagnostic;
   Parse_Diag    : Parser_Diagnostic;
   Parse_Success : Boolean := False;
   Exec_Success  : Boolean := False;
   Arena_Ok      : Boolean := False;
   Load_Ok       : Boolean := False;
   State         : Engine_State;

   Max_Audit_Name     : constant := 128;
   Max_Audit_Routines : constant := 512;
   Max_Audit_Calls    : constant := 2048;

   subtype Audit_Name is String (1 .. Max_Audit_Name);

   type Run_Mode is (Mode_Run, Mode_Check, Mode_Audit);
   type Routine_Kind is (Routine_Procedure, Routine_Function);
   type Runtime_Phase is
     (Phase_None,
      Phase_Top_Level,
      Phase_On_Tick,
      Phase_On_Paint,
      Phase_On_Key,
      Phase_Procedure,
      Phase_Function);

   subtype Player_Exit_Code is Natural range 0 .. 8;
   Exit_Ok            : constant Player_Exit_Code := 0;
   Exit_Cli_Failure   : constant Player_Exit_Code := 2;
   Exit_Load_Failure  : constant Player_Exit_Code := 3;
   Exit_Lex_Failure   : constant Player_Exit_Code := 4;
   Exit_Parse_Failure : constant Player_Exit_Code := 5;
   Exit_Audit_Failure : constant Player_Exit_Code := 6;
   Exit_Run_Failure   : constant Player_Exit_Code := 7;
   Exit_Internal_Fault : constant Player_Exit_Code := 8;

   type Audit_Routine_Record is record
      Active    : Boolean := False;
      Name      : Audit_Name := (others => ' ');
      Name_Len  : Natural := 0;
      Decl_Node : Node_Index := 0;
      Body_Node : Node_Index := 0;
      Kind      : Routine_Kind := Routine_Procedure;
      File_ID   : Natural := 1;
      Rel_Line  : Positive := 1;
   end record;

   type Audit_Routine_Array is array (1 .. Max_Audit_Routines) of Audit_Routine_Record;

   type Audit_Call_Record is record
      Active         : Boolean := False;
      Name           : Audit_Name := (others => ' ');
      Name_Len       : Natural := 0;
      Call_Node      : Node_Index := 0;
      File_ID        : Natural := 1;
      Rel_Line       : Positive := 1;
      Is_Constructor : Boolean := False;
   end record;

   type Audit_Call_Array is array (1 .. Max_Audit_Calls) of Audit_Call_Record;

   Mode                : Run_Mode := Mode_Run;
   Show_Includes       : Boolean := False;
   Show_Limits         : Boolean := False;
   Trace_Calls         : Boolean := False;
   Script_Provided     : Boolean := False;
   Current_Top_Level   : Node_Index := 0;

   Audit_Routines      : Audit_Routine_Array := (others => <>);
   Audit_Calls         : Audit_Call_Array := (others => <>);
   Audit_Routine_Count : Natural := 0;
   Audit_Procedure_Count : Natural := 0;
   Audit_Function_Count : Natural := 0;
   Audit_Call_Count    : Natural := 0;
   Audit_Create_Window_Count : Natural := 0;
   Audit_Listen_Count  : Natural := 0;
   Audit_Import_C_Count : Natural := 0;
   Audit_On_Tick_Count : Natural := 0;
   Audit_On_Paint_Count : Natural := 0;
   Audit_On_Key_Count  : Natural := 0;
   Audit_On_Tick_Node  : Node_Index := 0;
   Audit_On_Paint_Node : Node_Index := 0;
   Audit_On_Key_Node   : Node_Index := 0;
   Audit_Unique_Routine_Count : Natural := 0;
   Audit_Duplicate_Routine_Count : Natural := 0;
   Audit_Routine_Overflow : Boolean := False;
   Audit_Call_Overflow : Boolean := False;

   function To_Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
   end To_Upper;

   function Canonical_Path (Path : String) return String is
   begin
      if Ada.Directories.Exists (Path) then
         return Ada.Directories.Full_Name (Path);
      end if;
      return Path;
   exception
      when others =>
         return Path;
   end Canonical_Path;

   function Token_Text (Tok : Token) return String is
      Last : constant Natural := Tok.Start + Tok.Length - 1;
   begin
      if Tok.Length = 0 or else Tok.Start not in Input_Buffer'Range or else Last not in Input_Buffer'Range then
         return "";
      end if;
      return Input_Buffer (Tok.Start .. Last);
   end Token_Text;

   function Clean_Image (Text : String) return String is
   begin
      return Trim (Text, Both);
   end Clean_Image;

   function Has_Valid_Token (Tok_Idx : Natural) return Boolean is
   begin
      return Tok_Idx in 1 .. Token_Count;
   end Has_Valid_Token;

   function Node_Kind_Text (Node : Node_Index) return String is
   begin
      if Node in Tree'Range then
         return Clean_Image (Node_Kind'Image (Tree (Node).Kind));
      end if;
      return "AST_Null";
   end Node_Kind_Text;

   function Node_Label (Node : Node_Index) return String is
   begin
      if Node in Tree'Range then
         return Clean_Image (Node_Index'Image (Node)) & " (" & Node_Kind_Text (Node) & ")";
      end if;
      return Clean_Image (Node_Index'Image (Node));
   end Node_Label;

   function Find_Runtime_Anchor_List
     (Node   : Node_Index;
      Budget : in out Natural) return Node_Index
   is
      Curr  : Node_Index := Node;
      Found : Node_Index := 0;
   begin
      while Curr /= 0 and then Budget > 0 loop
         exit when Curr not in Tree'Range;
         Budget := Budget - 1;

         if Has_Valid_Token (Tree (Curr).Token_Index) then
            return Curr;
         end if;

         Found := Find_Runtime_Anchor_List (Tree (Curr).Left_Child, Budget);
         if Found /= 0 then
            return Found;
         end if;

         Found := Find_Runtime_Anchor_List (Tree (Curr).Right_Child, Budget);
         if Found /= 0 then
            return Found;
         end if;

         Curr := Tree (Curr).Next_Sibling;
      end loop;

      return 0;
   end Find_Runtime_Anchor_List;

   function Runtime_Culprit
     (Fail_Node   : Node_Index;
      Anchor_Node : Node_Index) return String
   is
      Culprit_Text : constant String :=
        (if Anchor_Node in Tree'Range and then Has_Valid_Token (Tree (Anchor_Node).Token_Index)
         then Token_Text (Tokens (Tree (Anchor_Node).Token_Index))
         else "");
   begin
      if Culprit_Text'Length = 0 then
         return Node_Kind_Text (Fail_Node);
      elsif Anchor_Node = Fail_Node then
         return Culprit_Text;
      else
         return Culprit_Text & " @ " & Node_Kind_Text (Fail_Node);
      end if;
   end Runtime_Culprit;

   function Is_Already_Included (Path : String) return Boolean is
      Check : constant String := Canonical_Path (Path);
   begin
      for I in 1 .. Include_Count loop
         if Include_Lens (I) = Check'Length
           and then Include_Vault (I) (1 .. Check'Length) = Check
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Already_Included;

   procedure Remember_Load_Failure
     (Path   : in String;
      Reason : in Load_Failure_Reason)
   is
      Use_Len : constant Natural := Natural'Min (Path'Length, Max_Path_Len);
   begin
      if Last_Load_Failure = Load_None then
         Last_Load_Failure := Reason;
         Failed_Load_Path := (others => ' ');
         Failed_Load_Len := Use_Len;
         if Use_Len > 0 then
            Failed_Load_Path (1 .. Use_Len) := Path (Path'First .. Path'First + Use_Len - 1);
         end if;
      end if;
   end Remember_Load_Failure;

   function Failed_Path_Text return String is
   begin
      if Failed_Load_Len = 0 then
         return "<unknown>";
      else
         return Failed_Load_Path (1 .. Failed_Load_Len);
      end if;
   end Failed_Path_Text;

   procedure Register_Include
     (Path    : in String;
      Success : out Boolean;
      ID      : out Natural)
   is
      Canon : constant String := Canonical_Path (Path);
      Len   : Natural := Canon'Length;
   begin
      if Len = 0 or else Len > Max_Path_Len or else Include_Count = Max_Includes then
         Success := False;
         ID := 0;
         return;
      end if;

      Include_Count := Include_Count + 1;
      Include_Lens (Include_Count) := Len;
      Include_Vault (Include_Count) (1 .. Len) := Canon;
      ID := Include_Count;
      Success := True;
   end Register_Include;

   function Resolve_Include_Path
     (Parent_File  : String;
      Include_Name : String) return String
   is
      Parent_Dir : constant String := Ada.Directories.Containing_Directory (Parent_File);
      Direct     : constant String := Canonical_Path (Include_Name);
      Joined     : constant String :=
        (if Parent_Dir'Length = 0 then Include_Name else Parent_Dir & "\" & Include_Name);
   begin
      if Ada.Directories.Exists (Direct) then
         return Direct;
      elsif Ada.Directories.Exists (Joined) then
         return Canonical_Path (Joined);
      else
         return Joined;
      end if;
   exception
      when others =>
         return Include_Name;
   end Resolve_Include_Path;

   procedure Append_Line
     (Line    : in String;
      File_ID : in Natural;
      Rel     : in Positive;
      Success : out Boolean)
   is
   begin
      if Abs_Line_Count > Max_Absolute_Lines
        or else Input_Len + Line'Length + 1 > Input_Buffer'Last
      then
         Success := False;
         return;
      end if;

      Source_Map (Abs_Line_Count) := (File_ID => File_ID, Rel_Line => Rel);

      if Line'Length > 0 then
         Input_Buffer (Input_Len + 1 .. Input_Len + Line'Length) := Line;
         Input_Len := Input_Len + Line'Length;
      end if;

      Input_Len := Input_Len + 1;
      Input_Buffer (Input_Len) := ASCII.LF;
      Abs_Line_Count := Abs_Line_Count + 1;
      Success := True;
   end Append_Line;

   procedure Parse_Include_Directive
     (Line      : in String;
      Found     : out Boolean;
      Path_Buf  : out Include_Path;
      Path_Len  : out Natural)
   is
      Start_Idx : Natural := 0;
      Pos       : Natural := 0;
   begin
      Found := False;
      Path_Buf := (others => ' ');
      Path_Len := 0;

      if Line'Length = 0 then
         return;
      end if;

      for I in Line'Range loop
         if Line (I) /= ' ' and then Line (I) /= ASCII.HT then
            Start_Idx := I;
            exit;
         end if;
      end loop;

      if Start_Idx = 0 or else Start_Idx + 6 > Line'Last then
         return;
      end if;

      if To_Upper (Line (Start_Idx)) /= 'I'
        or else To_Upper (Line (Start_Idx + 1)) /= 'N'
        or else To_Upper (Line (Start_Idx + 2)) /= 'C'
        or else To_Upper (Line (Start_Idx + 3)) /= 'L'
        or else To_Upper (Line (Start_Idx + 4)) /= 'U'
        or else To_Upper (Line (Start_Idx + 5)) /= 'D'
        or else To_Upper (Line (Start_Idx + 6)) /= 'E'
      then
         return;
      end if;

      Pos := Start_Idx + 7;
      while Pos <= Line'Last and then (Line (Pos) = ' ' or else Line (Pos) = ASCII.HT) loop
         Pos := Pos + 1;
      end loop;

      if Pos > Line'Last or else Line (Pos) /= '"' then
         return;
      end if;
      Pos := Pos + 1;

      while Pos <= Line'Last and then Line (Pos) /= '"' loop
         if Path_Len = Max_Path_Len then
            Found := False;
            Path_Len := 0;
            Path_Buf := (others => ' ');
            return;
         end if;
         Path_Len := Path_Len + 1;
         Path_Buf (Path_Len) := Line (Pos);
         Pos := Pos + 1;
      end loop;

      if Pos <= Line'Last and then Line (Pos) = '"' and then Path_Len > 0 then
         Found := True;
      end if;
   end Parse_Include_Directive;

   procedure Reset_Load_State is
   begin
      Include_Vault := (others => (others => ' '));
      Include_Lens  := (others => 0);
      Include_Count := 0;
      Last_Load_Failure := Load_None;
      Failed_Load_Path := (others => ' ');
      Failed_Load_Len := 0;
      Source_Map    := (others => (File_ID => 1, Rel_Line => 1));
      Abs_Line_Count := 1;
      Input_Buffer := (others => ' ');
      Temp_Buffer  := (others => ' ');
      Input_Len := 0;
      Tokens := (others => (Kind => Tok_Error, Start => 1, Length => 0, Line => 1, Column => 1));
      Tree := (others => (Kind => AST_Null, Token_Index => 0, Left_Child => 0, Right_Child => 0, Next_Sibling => 0));
   end Reset_Load_State;

   procedure Reset_Audit_State is
   begin
      Audit_Routines := (others => <>);
      Audit_Calls := (others => <>);
      Audit_Routine_Count := 0;
      Audit_Procedure_Count := 0;
      Audit_Function_Count := 0;
      Audit_Call_Count := 0;
      Audit_Create_Window_Count := 0;
      Audit_Listen_Count := 0;
      Audit_Import_C_Count := 0;
      Audit_On_Tick_Count := 0;
      Audit_On_Paint_Count := 0;
      Audit_On_Key_Count := 0;
      Audit_On_Tick_Node := 0;
      Audit_On_Paint_Node := 0;
      Audit_On_Key_Node := 0;
      Audit_Unique_Routine_Count := 0;
      Audit_Duplicate_Routine_Count := 0;
      Audit_Routine_Overflow := False;
      Audit_Call_Overflow := False;
   end Reset_Audit_State;

   procedure Set_Player_Exit (Code : in Player_Exit_Code) is
   begin
      Set_Exit_Status (Exit_Status (Code));
   end Set_Player_Exit;

   function Natural_Text (Value : Natural) return String is
   begin
      return Clean_Image (Natural'Image (Value));
   end Natural_Text;

   function Stored_Audit_Name
     (Name : Audit_Name;
      Len  : Natural) return String
   is
   begin
      if Len = 0 then
         return "";
      else
         return Name (1 .. Len);
      end if;
   end Stored_Audit_Name;

   procedure Set_Audit_Name
     (Target : out Audit_Name;
      Len    : out Natural;
      Text   : in String)
   is
      Use_Len : constant Natural := Natural'Min (Text'Length, Max_Audit_Name);
   begin
      Target := (others => ' ');
      Len := Use_Len;
      if Use_Len > 0 then
         Target (1 .. Use_Len) := Text (Text'First .. Text'First + Use_Len - 1);
      end if;
   end Set_Audit_Name;

   function Equal_No_Case (Left : String; Right : String) return Boolean is
      J : Integer := Right'First;
   begin
      if Left'Length /= Right'Length then
         return False;
      end if;

      for I in Left'Range loop
         if To_Upper (Left (I)) /= To_Upper (Right (J)) then
            return False;
         end if;
         J := J + 1;
      end loop;

      return True;
   end Equal_No_Case;

   function Source_File_Text (File_ID : Natural) return String is
   begin
      if File_ID in 1 .. Include_Count and then Include_Lens (File_ID) > 0 then
         return Include_Vault (File_ID) (1 .. Include_Lens (File_ID));
      elsif Input_Flen > 0 then
         return Input_File (1 .. Input_Flen);
      else
         return "<script>";
      end if;
   end Source_File_Text;

   function Node_Token_Text (Node : Node_Index) return String is
   begin
      if Node in Tree'Range and then Has_Valid_Token (Tree (Node).Token_Index) then
         return Token_Text (Tokens (Tree (Node).Token_Index));
      end if;
      return "";
   end Node_Token_Text;

   procedure Resolve_Node_Source
     (Node     : in Node_Index;
      File_ID  : out Natural;
      Rel_Line : out Positive)
   is
      Anchor : Node_Index := Node;
      Budget : Natural := 4096;
      Tok_Idx : Natural := 0;
   begin
      File_ID := 1;
      Rel_Line := 1;

      if Anchor not in Tree'Range or else not Has_Valid_Token (Tree (Anchor).Token_Index) then
         Anchor := Find_Runtime_Anchor_List (Node, Budget);
      end if;

      if Anchor in Tree'Range and then Has_Valid_Token (Tree (Anchor).Token_Index) then
         Tok_Idx := Tree (Anchor).Token_Index;
         if Tokens (Tok_Idx).Line <= Max_Absolute_Lines then
            File_ID := Source_Map (Tokens (Tok_Idx).Line).File_ID;
            Rel_Line := Source_Map (Tokens (Tok_Idx).Line).Rel_Line;
         end if;
      end if;
   end Resolve_Node_Source;

   function Call_Target_Name (Node : Node_Index) return String is
      Left_Name  : constant String :=
        (if Node in Tree'Range and then Tree (Node).Left_Child /= 0
         then Call_Target_Name (Tree (Node).Left_Child)
         else "");
      Right_Name : constant String :=
        (if Node in Tree'Range and then Tree (Node).Right_Child /= 0
         then Call_Target_Name (Tree (Node).Right_Child)
         else "");
      Token_Name : constant String := Node_Token_Text (Node);
   begin
      if Node = 0 or else Node not in Tree'Range then
         return "";
      end if;

      case Tree (Node).Kind is
         when AST_Var_Expr | AST_Logic_Var =>
            return Token_Name;
         when AST_Member_Expr =>
            if Left_Name'Length > 0 and then Right_Name'Length > 0 then
               return Left_Name & "." & Right_Name;
            elsif Left_Name'Length > 0 then
               return Left_Name;
            else
               return Right_Name;
            end if;
         when AST_Func_Call =>
            return Left_Name;
         when AST_Constructor =>
            return Token_Name;
         when others =>
            if Token_Name'Length > 0 then
               return Token_Name;
            elsif Left_Name'Length > 0 then
               return Left_Name;
            else
               return Right_Name;
            end if;
      end case;
   end Call_Target_Name;

   function Routine_Name_From_Decl (Decl_Node : Node_Index) return String is
   begin
      if Decl_Node in Tree'Range and then Tree (Decl_Node).Left_Child /= 0 then
         return Call_Target_Name (Tree (Decl_Node).Left_Child);
      end if;
      return Node_Token_Text (Decl_Node);
   end Routine_Name_From_Decl;

   function Find_Audit_Routine_Index (Name : String) return Natural is
   begin
      if Name'Length = 0 then
         return 0;
      end if;

      for I in 1 .. Audit_Routine_Count loop
         if Audit_Routines (I).Active
           and then Equal_No_Case
             (Stored_Audit_Name (Audit_Routines (I).Name, Audit_Routines (I).Name_Len),
              Name)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Audit_Routine_Index;

   procedure Register_Audit_Routine
     (Decl_Node : in Node_Index;
      Kind      : in Routine_Kind)
   is
      Name_Text : constant String := Routine_Name_From_Decl (Decl_Node);
      Existing  : constant Natural := Find_Audit_Routine_Index (Name_Text);
      File_ID   : Natural := 1;
      Rel_Line  : Positive := 1;
   begin
      if Kind = Routine_Procedure then
         Audit_Procedure_Count := Audit_Procedure_Count + 1;
      else
         Audit_Function_Count := Audit_Function_Count + 1;
      end if;

      if Existing = 0 then
         Audit_Unique_Routine_Count := Audit_Unique_Routine_Count + 1;
      else
         Audit_Duplicate_Routine_Count := Audit_Duplicate_Routine_Count + 1;
      end if;

      if Audit_Routine_Count = Max_Audit_Routines then
         Audit_Routine_Overflow := True;
         return;
      end if;

      if Decl_Node in Tree'Range and then Tree (Decl_Node).Left_Child /= 0 then
         Resolve_Node_Source (Tree (Decl_Node).Left_Child, File_ID, Rel_Line);
      else
         Resolve_Node_Source (Decl_Node, File_ID, Rel_Line);
      end if;

      Audit_Routine_Count := Audit_Routine_Count + 1;
      Audit_Routines (Audit_Routine_Count).Active := True;
      Set_Audit_Name
        (Audit_Routines (Audit_Routine_Count).Name,
         Audit_Routines (Audit_Routine_Count).Name_Len,
         Name_Text);
      Audit_Routines (Audit_Routine_Count).Decl_Node := Decl_Node;
      Audit_Routines (Audit_Routine_Count).Body_Node :=
        (if Decl_Node in Tree'Range then Tree (Decl_Node).Right_Child else 0);
      Audit_Routines (Audit_Routine_Count).Kind := Kind;
      Audit_Routines (Audit_Routine_Count).File_ID := File_ID;
      Audit_Routines (Audit_Routine_Count).Rel_Line := Rel_Line;
   end Register_Audit_Routine;

   procedure Register_Audit_Call
     (Call_Node       : in Node_Index;
      Target_Node     : in Node_Index;
      Is_Constructor  : in Boolean)
   is
      Name_Text : constant String := Call_Target_Name (Target_Node);
      File_ID   : Natural := 1;
      Rel_Line  : Positive := 1;
   begin
      if Audit_Call_Count = Max_Audit_Calls then
         Audit_Call_Overflow := True;
         return;
      end if;

      Resolve_Node_Source (Call_Node, File_ID, Rel_Line);

      Audit_Call_Count := Audit_Call_Count + 1;
      Audit_Calls (Audit_Call_Count).Active := True;
      Set_Audit_Name
        (Audit_Calls (Audit_Call_Count).Name,
         Audit_Calls (Audit_Call_Count).Name_Len,
         Name_Text);
      Audit_Calls (Audit_Call_Count).Call_Node := Call_Node;
      Audit_Calls (Audit_Call_Count).File_ID := File_ID;
      Audit_Calls (Audit_Call_Count).Rel_Line := Rel_Line;
      Audit_Calls (Audit_Call_Count).Is_Constructor := Is_Constructor;
   end Register_Audit_Call;

   procedure Walk_Audit_Subtree
     (Node            : in Node_Index;
      Include_Siblings : in Boolean := True)
   is
      Curr : Node_Index := Node;
   begin
      while Curr /= 0 loop
         exit when Curr not in Tree'Range;

         case Tree (Curr).Kind is
            when AST_Procedure_Decl =>
               Register_Audit_Routine (Curr, Routine_Procedure);
            when AST_Function_Decl =>
               Register_Audit_Routine (Curr, Routine_Function);
            when AST_Import_C =>
               Audit_Import_C_Count := Audit_Import_C_Count + 1;
            when AST_Call_Stmt =>
               if Tree (Curr).Left_Child /= 0 then
                  Register_Audit_Call
                    (Curr,
                     Tree (Curr).Left_Child,
                     Tree (Tree (Curr).Left_Child).Kind = AST_Constructor);
               end if;
            when AST_Func_Call =>
               if Tree (Curr).Left_Child /= 0 then
                  Register_Audit_Call (Curr, Tree (Curr).Left_Child, False);
               end if;
            when AST_Create_Window =>
               Audit_Create_Window_Count := Audit_Create_Window_Count + 1;
            when AST_Listen =>
               Audit_Listen_Count := Audit_Listen_Count + 1;
            when AST_On_Block =>
               if Has_Valid_Token (Tree (Curr).Token_Index) then
                  case Tokens (Tree (Curr).Token_Index).Kind is
                     when Tok_Tick =>
                        Audit_On_Tick_Count := Audit_On_Tick_Count + 1;
                        if Audit_On_Tick_Node = 0 then
                           Audit_On_Tick_Node := Curr;
                        end if;
                     when Tok_Paint =>
                        Audit_On_Paint_Count := Audit_On_Paint_Count + 1;
                        if Audit_On_Paint_Node = 0 then
                           Audit_On_Paint_Node := Curr;
                        end if;
                     when Tok_Key =>
                        Audit_On_Key_Count := Audit_On_Key_Count + 1;
                        if Audit_On_Key_Node = 0 then
                           Audit_On_Key_Node := Curr;
                        end if;
                     when others =>
                        null;
                  end case;
               end if;
            when others =>
               null;
         end case;

         Walk_Audit_Subtree (Tree (Curr).Left_Child, True);
         Walk_Audit_Subtree (Tree (Curr).Right_Child, True);

         exit when not Include_Siblings;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Walk_Audit_Subtree;

   procedure Build_Audit_Manifest is
   begin
      Reset_Audit_State;
      Walk_Audit_Subtree (Root, True);
   end Build_Audit_Manifest;

   function Node_In_Subtree
     (Root_Node        : Node_Index;
      Target_Node      : Node_Index;
      Include_Siblings : Boolean := True) return Boolean
   is
      Curr : Node_Index := Root_Node;
   begin
      while Curr /= 0 loop
         exit when Curr not in Tree'Range;

         if Curr = Target_Node then
            return True;
         end if;

         if Node_In_Subtree (Tree (Curr).Left_Child, Target_Node, True) then
            return True;
         end if;

         if Node_In_Subtree (Tree (Curr).Right_Child, Target_Node, True) then
            return True;
         end if;

         exit when not Include_Siblings;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      return False;
   end Node_In_Subtree;

   function Find_Containing_Routine (Target_Node : Node_Index) return Natural is
   begin
      for I in 1 .. Audit_Routine_Count loop
         if Audit_Routines (I).Active then
            if Audit_Routines (I).Decl_Node = Target_Node then
               return I;
            end if;

            if Audit_Routines (I).Body_Node /= 0
              and then Node_In_Subtree (Audit_Routines (I).Body_Node, Target_Node, True)
            then
               return I;
            end if;
         end if;
      end loop;

      return 0;
   end Find_Containing_Routine;

   function Count_Active_Runtime_Procs return Natural is
      Count : Natural := 0;
   begin
      for I in State.Procs'Range loop
         if State.Procs (I).Active then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Count_Active_Runtime_Procs;

   procedure Detect_Runtime_Context
     (Fail_Node      : in Node_Index;
      Phase          : out Runtime_Phase;
      Routine_Index  : out Natural)
   is
   begin
      Routine_Index := Find_Containing_Routine (Fail_Node);

      if State.On_Tick_Node /= 0
        and then Node_In_Subtree (State.On_Tick_Node, Fail_Node, True)
      then
         Phase := Phase_On_Tick;
      elsif State.On_Paint_Node /= 0
        and then Node_In_Subtree (State.On_Paint_Node, Fail_Node, True)
      then
         Phase := Phase_On_Paint;
      elsif State.On_Key_Node /= 0
        and then Node_In_Subtree (State.On_Key_Node, Fail_Node, True)
      then
         Phase := Phase_On_Key;
      elsif Routine_Index /= 0 then
         if Audit_Routines (Routine_Index).Kind = Routine_Procedure then
            Phase := Phase_Procedure;
         else
            Phase := Phase_Function;
         end if;
      elsif Current_Top_Level /= 0 then
         Phase := Phase_Top_Level;
      else
         Phase := Phase_None;
      end if;
   end Detect_Runtime_Context;

   function Phase_Text (Phase : Runtime_Phase) return String is
   begin
      case Phase is
         when Phase_None =>
            return "unknown";
         when Phase_Top_Level =>
            return "top-level execution";
         when Phase_On_Tick =>
            return "ON TICK";
         when Phase_On_Paint =>
            return "ON PAINT";
         when Phase_On_Key =>
            return "ON KEY";
         when Phase_Procedure =>
            return "PROCEDURE";
         when Phase_Function =>
            return "FUNCTION";
      end case;
   end Phase_Text;

   function Routine_Kind_Text (Kind : Routine_Kind) return String is
   begin
      case Kind is
         when Routine_Procedure =>
            return "PROCEDURE";
         when Routine_Function =>
            return "FUNCTION";
      end case;
   end Routine_Kind_Text;

   function Routine_Name_Text (Index : Natural) return String is
   begin
      if Index in 1 .. Audit_Routine_Count and then Audit_Routines (Index).Active then
         return Stored_Audit_Name
           (Audit_Routines (Index).Name, Audit_Routines (Index).Name_Len);
      end if;
      return "";
   end Routine_Name_Text;

   function Call_Name_Text (Index : Natural) return String is
   begin
      if Index in 1 .. Audit_Call_Count and then Audit_Calls (Index).Active then
         return Stored_Audit_Name (Audit_Calls (Index).Name, Audit_Calls (Index).Name_Len);
      end if;
      return "";
   end Call_Name_Text;

   function Call_Target_Name_From_Node (Node : Node_Index) return String is
   begin
      if Node not in Tree'Range then
         return "";
      end if;

      case Tree (Node).Kind is
         when AST_Call_Stmt =>
            return Call_Target_Name (Tree (Node).Left_Child);
         when AST_Func_Call =>
            return Call_Target_Name (Tree (Node).Left_Child);
         when AST_Constructor =>
            return Node_Token_Text (Node);
         when others =>
            return Call_Target_Name (Node);
      end case;
   end Call_Target_Name_From_Node;

   function Has_Hard_Audit_Failure return Boolean is
   begin
      return Audit_Unique_Routine_Count > Max_Procs;
   end Has_Hard_Audit_Failure;

   procedure Print_Usage is
   begin
      Put_Line ("=== AdaLogic BASIC Player ===");
      Put_Line ("Usage: alb_player [options] <script.alb>");
      Put_Line ("Modes:");
      Put_Line ("  --check          Parse and preflight the script without running it.");
      Put_Line ("  --audit          Print a fuller source manifest and player-compatibility report.");
      Put_Line ("Options:");
      Put_Line ("  --show-includes  Print the woven include manifest.");
      Put_Line ("  --show-limits    Print the player's baked-in loader and runtime limits.");
      Put_Line ("  --trace-calls    Trace top-level execution and print the preflight call manifest summary.");
      Put_Line ("  --help, -h       Show this help text.");
      Put_Line ("Notes:");
      Put_Line ("  - INCLUDE paths are resolved relative tae the current script.");
      Put_Line ("  - Runtime diagnostics map back tae the woven source file and line.");
      Put_Line ("  - Preflight audits can catch player-only pressure points before LISTEN begins.");
   end Print_Usage;

   procedure Print_Limits is
   begin
      Put_Line ("ALB-LIMITS> Loader bounds:");
      Put_Line ("ALB-LIMITS>   includes=" & Natural_Text (Max_Includes));
      Put_Line ("ALB-LIMITS>   woven_lines=" & Natural_Text (Max_Absolute_Lines));
      Put_Line ("ALB-LIMITS>   line_length=" & Natural_Text (Max_Line_Length));
      Put_Line ("ALB-LIMITS> Runtime bounds:");
      Put_Line ("ALB-LIMITS>   vars=" & Natural_Text (Max_Vars));
      Put_Line ("ALB-LIMITS>   arrays=" & Natural_Text (Max_Arrays));
      Put_Line ("ALB-LIMITS>   array_cells=" & Natural_Text (Max_Array_Cells));
      Put_Line ("ALB-LIMITS>   named_types=" & Natural_Text (Max_Named_Types));
      Put_Line ("ALB-LIMITS>   structs=" & Natural_Text (Max_Structs));
      Put_Line ("ALB-LIMITS>   parallels=" & Natural_Text (Max_Parallel_Groups));
      Put_Line ("ALB-LIMITS>   binaries=" & Natural_Text (Max_Binary_Slots));
      Put_Line ("ALB-LIMITS>   files=" & Natural_Text (Max_Open_Files));
      Put_Line ("ALB-LIMITS>   temporals=" & Natural_Text (Max_Temporal_Vars));
      Put_Line ("ALB-LIMITS>   clauses=" & Natural_Text (Max_Clauses));
      Put_Line ("ALB-LIMITS>   procs=" & Natural_Text (Max_Procs));
      Put_Line ("ALB-LIMITS>   call_depth=" & Natural_Text (Max_Call_Depth));
   end Print_Limits;

   procedure Print_Include_Manifest is
   begin
      Put_Line ("ALB-INCLUDES> Woven include manifest (" & Natural_Text (Include_Count) & " file(s)):");
      for I in 1 .. Include_Count loop
         Put_Line ("ALB-INCLUDES>   [" & Natural_Text (I) & "] " & Source_File_Text (I));
      end loop;
   end Print_Include_Manifest;

   procedure Print_Audit_Report (Verbose : in Boolean) is
      Max_Call_Report : constant Natural := 64;
   begin
      Put_Line ("ALB-AUDIT> Source manifest summary:");
      Put_Line
        ("ALB-AUDIT>   routines="
         & Natural_Text (Audit_Routine_Count)
         & " declarations / "
         & Natural_Text (Audit_Unique_Routine_Count)
         & " unique names");
      Put_Line
        ("ALB-AUDIT>   procedures="
         & Natural_Text (Audit_Procedure_Count)
         & ", functions="
         & Natural_Text (Audit_Function_Count)
         & ", import_c="
         & Natural_Text (Audit_Import_C_Count));
      Put_Line
        ("ALB-AUDIT>   calls="
         & Natural_Text (Audit_Call_Count)
         & ", create_window="
         & Natural_Text (Audit_Create_Window_Count)
         & ", listen="
         & Natural_Text (Audit_Listen_Count));
      Put_Line
        ("ALB-AUDIT>   handlers: tick="
         & Natural_Text (Audit_On_Tick_Count)
         & ", paint="
         & Natural_Text (Audit_On_Paint_Count)
         & ", key="
         & Natural_Text (Audit_On_Key_Count));

      if Audit_Duplicate_Routine_Count > 0 then
         Put_Line
           ("ALB-AUDIT> Warning: duplicate routine names found: "
            & Natural_Text (Audit_Duplicate_Routine_Count)
            & ".");
      end if;

      if Audit_Unique_Routine_Count > Max_Procs then
         Put_Line
           ("ALB-AUDIT> Hard breach: source declares "
            & Natural_Text (Audit_Unique_Routine_Count)
            & " unique routines, but the runtime proc bank tops out at "
            & Natural_Text (Max_Procs)
            & ".");
      end if;

      if Audit_On_Tick_Count > 1 then
         Put_Line ("ALB-AUDIT> Warning: multiple ON TICK blocks were found.");
      end if;

      if Audit_On_Paint_Count > 1 then
         Put_Line ("ALB-AUDIT> Warning: multiple ON PAINT blocks were found.");
      end if;

      if Audit_On_Key_Count > 1 then
         Put_Line ("ALB-AUDIT> Warning: multiple ON KEY blocks were found.");
      end if;

      if Audit_Create_Window_Count > 0 and then Audit_Listen_Count = 0 then
         Put_Line ("ALB-AUDIT> Warning: CREATE_WINDOW appears without LISTEN.");
      end if;

      if Audit_Listen_Count > 0 and then Audit_Create_Window_Count = 0 then
         Put_Line ("ALB-AUDIT> Warning: LISTEN appears without CREATE_WINDOW.");
      end if;

      if (Audit_On_Tick_Count + Audit_On_Paint_Count + Audit_On_Key_Count) > 0
        and then Audit_Listen_Count = 0
      then
         Put_Line ("ALB-AUDIT> Warning: event handlers are declared, but LISTEN is absent.");
      end if;

      if Audit_Routine_Overflow then
         Put_Line
           ("ALB-AUDIT> Note: routine manifest storage capped at "
            & Natural_Text (Max_Audit_Routines)
            & " entries.");
      end if;

      if Audit_Call_Overflow then
         Put_Line
           ("ALB-AUDIT> Note: call manifest storage capped at "
            & Natural_Text (Max_Audit_Calls)
            & " entries.");
      end if;

      if Verbose then
         Put_Line ("ALB-AUDIT> Routine registry:");
         for I in 1 .. Audit_Routine_Count loop
            if Audit_Routines (I).Active then
               Put_Line
                 ("ALB-AUDIT>   "
                  & Routine_Kind_Text (Audit_Routines (I).Kind)
                  & " "
                  & (if Routine_Name_Text (I)'Length > 0 then Routine_Name_Text (I) else "<anonymous>")
                  & " @ "
                  & Source_File_Text (Audit_Routines (I).File_ID)
                  & ":"
                  & Natural_Text (Audit_Routines (I).Rel_Line));
            end if;
         end loop;

         Put_Line ("ALB-AUDIT> Call manifest:");
         for I in 1 .. Natural'Min (Audit_Call_Count, Max_Call_Report) loop
            if Audit_Calls (I).Active then
               Put_Line
                 ("ALB-AUDIT>   "
                  & (if Call_Name_Text (I)'Length > 0 then Call_Name_Text (I) else "<dynamic>")
                  & " @ "
                  & Source_File_Text (Audit_Calls (I).File_ID)
                  & ":"
                  & Natural_Text (Audit_Calls (I).Rel_Line)
                  & (if Audit_Calls (I).Is_Constructor then " [constructor]" else ""));
            end if;
         end loop;

         if Audit_Call_Count > Max_Call_Report then
            Put_Line
              ("ALB-AUDIT>   ... "
               & Natural_Text (Audit_Call_Count - Max_Call_Report)
               & " more call site(s) not shown.");
         end if;
      end if;
   end Print_Audit_Report;

   procedure Weave_File (Path : in String; Success : in out Boolean) is
      Canon      : constant String := Canonical_Path (Path);
      File_ID    : Natural := 0;
      File       : Ada.Streams.Stream_IO.File_Type;
      Stream_Ptr : Ada.Streams.Stream_IO.Stream_Access;
      Ch         : Character;
      Line_Buf   : String (1 .. Max_Line_Length) := (others => ' ');
      Line_Len   : Natural := 0;
      Rel_Line   : Positive := 1;

      procedure Flush_Line is
         Found    : Boolean := False;
         Inc_Buf  : Include_Path := (others => ' ');
         Inc_Len  : Natural := 0;
         Step_Ok  : Boolean := False;
         Current_Line : constant String :=
           (if Line_Len = 0 then "" else Line_Buf (1 .. Line_Len));
      begin
         Parse_Include_Directive (Current_Line, Found, Inc_Buf, Inc_Len);
         if Found then
            Weave_File (Resolve_Include_Path (Canon, Inc_Buf (1 .. Inc_Len)), Success);
            if not Success then
               return;
            end if;
         else
            Append_Line (Current_Line, File_ID, Rel_Line, Step_Ok);
            if not Step_Ok then
               Remember_Load_Failure (Canon, Load_Buffer_Overflow);
               Success := False;
               return;
            end if;
         end if;

         Line_Len := 0;
         Rel_Line := Rel_Line + 1;
      end Flush_Line;
   begin
      if not Success or else Is_Already_Included (Canon) then
         return;
      end if;

      Register_Include (Canon, Success, File_ID);
      if not Success then
         Remember_Load_Failure (Canon, Load_Path_Invalid);
         return;
      end if;

      begin
         Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Canon);
         Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);
      exception
         when others =>
            Remember_Load_Failure (Canon, Load_File_Open_Failed);
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
            if Line_Len = Max_Line_Length then
               Remember_Load_Failure (Canon, Load_Buffer_Overflow);
               Success := False;
               exit;
            end if;
            Line_Len := Line_Len + 1;
            Line_Buf (Line_Len) := Ch;
         end if;
      end loop;

      if Success and then Line_Len > 0 then
         Flush_Line;
      end if;

      if Ada.Streams.Stream_IO.Is_Open (File) then
         Ada.Streams.Stream_IO.Close (File);
      end if;
   exception
         when others =>
            Remember_Load_Failure (Canon, Load_File_Open_Failed);
            Success := False;
            if Ada.Streams.Stream_IO.Is_Open (File) then
               Ada.Streams.Stream_IO.Close (File);
            end if;
   end Weave_File;

   procedure Render_Lexer_Diagnostic is
      Map_Rec : constant Source_Map_Record := Source_Map (Lex_Diag.Error_Line);
      FName   : constant String := Source_File_Text (Map_Rec.File_ID);
   begin
      Render_Consultation
        (Input_Buffer (1 .. Input_Len),
         Lex_Diag.Error_Line,
         Map_Rec.Rel_Line,
         Lex_Diag.Error_Col,
         FName,
         Lex_Diag.Code);
   end Render_Lexer_Diagnostic;

   procedure Render_Parser_Diagnostic is
      Target_Idx : Natural := 0;
   begin
      for I in 1 .. Parse_Diag.Error_Count loop
         if Parse_Diag.Errors (I).Severity = Fatal then
            Target_Idx := I;
            exit;
         end if;
      end loop;

      if Target_Idx = 0 then
         Target_Idx := 1;
      end if;

      declare
         Err     : constant Error_Record := Parse_Diag.Errors (Target_Idx);
         Map_Rec : constant Source_Map_Record := Source_Map (Err.Line);
         FName   : constant String := Source_File_Text (Map_Rec.File_ID);
      begin
         Render_Consultation
           (Input_Buffer (1 .. Input_Len),
            Err.Line,
            Map_Rec.Rel_Line,
            Err.Col,
            FName,
            Err.Code);
      end;
   end Render_Parser_Diagnostic;

   procedure Render_Runtime_Diagnostic is
      Code          : Oracle_Code := Err_None;
      Node          : Node_Index := 0;
      Anchor_Node   : Node_Index := 0;
      Tok_Idx       : Natural := 0;
      Tok           : Token;
      Map_Rec       : Source_Map_Record := (File_ID => 1, Rel_Line => 1);
      Search_Budget : Natural := 4096;
      Phase         : Runtime_Phase := Phase_None;
      Routine_Index : Natural := 0;
   begin
      Get_Last_Failure (Code, Node);
      if Node = 0 or else Node not in Tree'Range then
         Put_Line ("ALB-RUNTIME> Execution failed.");
         if Code /= Err_None then
            Put_Line ("ALB-RUNTIME> Failure code: " & Clean_Image (Oracle_Code'Image (Code)) & ".");
         end if;
         return;
      end if;

      Anchor_Node := Node;
      if not Has_Valid_Token (Tree (Anchor_Node).Token_Index) then
         Anchor_Node := Find_Runtime_Anchor_List (Tree (Node).Left_Child, Search_Budget);
         if Anchor_Node = 0 then
            Anchor_Node := Find_Runtime_Anchor_List (Tree (Node).Right_Child, Search_Budget);
         end if;
      end if;

      Put_Line
        ("ALB-RUNTIME> Failure code "
         & Clean_Image (Oracle_Code'Image (Code))
         & " at AST node "
         & Node_Label (Node)
         & ".");

      Detect_Runtime_Context (Node, Phase, Routine_Index);

      if Current_Top_Level in Tree'Range then
         Put_Line
           ("ALB-RUNTIME> Active top-level statement: AST node "
            & Node_Label (Current_Top_Level)
            & ".");
      end if;

      if Phase /= Phase_None then
         Put_Line ("ALB-RUNTIME> Runtime phase: " & Phase_Text (Phase) & ".");
      end if;

      if Routine_Index /= 0 then
         Put_Line
           ("ALB-RUNTIME> Containing routine: "
            & Routine_Kind_Text (Audit_Routines (Routine_Index).Kind)
            & " "
            & (if Routine_Name_Text (Routine_Index)'Length > 0
               then Routine_Name_Text (Routine_Index)
               else "<anonymous>")
            & " @ "
            & Source_File_Text (Audit_Routines (Routine_Index).File_ID)
            & ":"
            & Natural_Text (Audit_Routines (Routine_Index).Rel_Line)
            & ".");
      end if;

      Put_Line
        ("ALB-RUNTIME> Runtime proc bank: "
         & Natural_Text (Count_Active_Runtime_Procs)
         & "/"
         & Natural_Text (Max_Procs)
         & " active, high-water mark "
         & Natural_Text (State.Proc_Count)
         & ".");

      if Anchor_Node /= 0 and then Anchor_Node /= Node then
         Put_Line ("ALB-RUNTIME> Nearest source anchor: AST node " & Node_Label (Anchor_Node) & ".");
      end if;

      if Code = Err_Proc_Not_Found then
         declare
            Missing_Name  : constant String := Call_Target_Name_From_Node (Node);
            Manifest_Hit  : constant Natural := Find_Audit_Routine_Index (Missing_Name);
         begin
            if Missing_Name'Length > 0 then
               Put_Line ("ALB-RUNTIME> Missing call target: " & Missing_Name & ".");
               if Manifest_Hit /= 0 then
                  Put_Line
                    ("ALB-RUNTIME> Source manifest declares this routine, so registration or dispatch likely failed before the call.");
               else
                  Put_Line
                    ("ALB-RUNTIME> Source manifest does not declare this routine name. Check spelling, INCLUDE coverage, or builtin expectations.");
               end if;
            end if;
         end;
      end if;

      if Anchor_Node = 0 or else not Has_Valid_Token (Tree (Anchor_Node).Token_Index) then
         Put_Line ("ALB-RUNTIME> Source mapping unavailable for the failing runtime subtree.");
         return;
      end if;

      Tok_Idx := Tree (Anchor_Node).Token_Index;
      Tok := Tokens (Tok_Idx);
      if Tok.Line <= Max_Absolute_Lines then
         Map_Rec := Source_Map (Tok.Line);
      end if;

      declare
         FName : constant String :=
           (if Map_Rec.File_ID in 1 .. Include_Count and then Include_Lens (Map_Rec.File_ID) > 0
            then Include_Vault (Map_Rec.File_ID) (1 .. Include_Lens (Map_Rec.File_ID))
            else Input_File (1 .. Input_Flen));
         Culprit : constant String := Runtime_Culprit (Node, Anchor_Node);
      begin
         Render_Consultation
           (Input_Buffer (1 .. Input_Len),
            Tok.Line,
            Map_Rec.Rel_Line,
            Tok.Column,
            FName,
            Code,
            Culprit);
      end;
   end Render_Runtime_Diagnostic;

begin
   Set_Player_Exit (Exit_Ok);

   if Argument_Count < 1 then
      Print_Usage;
      Set_Player_Exit (Exit_Cli_Failure);
      return;
   end if;

   for I in 1 .. Argument_Count loop
      declare
         Arg : constant String := Argument (I);
      begin
         if Arg = "--help" or else Arg = "-h" then
            Print_Usage;
            return;
         elsif Arg = "--check" then
            Mode := Mode_Check;
         elsif Arg = "--audit" then
            Mode := Mode_Audit;
         elsif Arg = "--show-includes" then
            Show_Includes := True;
         elsif Arg = "--show-limits" then
            Show_Limits := True;
         elsif Arg = "--trace-calls" then
            Trace_Calls := True;
         elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
            Put_Line ("ALB-FATAL> Unknown option: " & Arg);
            Set_Player_Exit (Exit_Cli_Failure);
            return;
         else
            if Script_Provided then
               Put_Line ("ALB-FATAL> Multiple script paths given. Pass one script at a time.");
               Set_Player_Exit (Exit_Cli_Failure);
               return;
            end if;

            if Arg'Length = 0 or else Arg'Length > Max_Path_Len then
               Put_Line ("ALB-FATAL> Invalid script path.");
               Set_Player_Exit (Exit_Cli_Failure);
               return;
            end if;

            Input_File := (others => ' ');
            Input_Flen := Arg'Length;
            Input_File (1 .. Input_Flen) := Arg;
            Script_Provided := True;
         end if;
      end;
   end loop;

   if not Script_Provided then
      Print_Usage;
      Set_Player_Exit (Exit_Cli_Failure);
      return;
   end if;

   if not Ada.Directories.Exists (Input_File (1 .. Input_Flen)) then
      Put_Line ("ALB-FATAL> Script file not found: " & Input_File (1 .. Input_Flen));
      Set_Player_Exit (Exit_Load_Failure);
      return;
   end if;

   Reset_Load_State;
   Load_Ok := True;
   Weave_File (Input_File (1 .. Input_Flen), Load_Ok);
   if not Load_Ok or else Input_Len = 0 then
      case Last_Load_Failure is
         when Load_File_Open_Failed =>
            Put_Line
              ("ALB-FATAL> Failed tae open script or include: "
               & Failed_Path_Text);
         when Load_Buffer_Overflow =>
            Put_Line
              ("ALB-FATAL> Script image exceeded the player's bounded loader limits near: "
               & Failed_Path_Text);
         when Load_Path_Invalid =>
            Put_Line
              ("ALB-FATAL> Invalid include or path while weaving: "
               & Failed_Path_Text);
         when others =>
            Put_Line ("ALB-FATAL> Failed tae load script image.");
      end case;
      Set_Player_Exit (Exit_Load_Failure);
      return;
   end if;

   if Show_Includes then
      Print_Include_Manifest;
   end if;

   Alloc_Static_Pool (Pool_Index (1073741824), Arena_Ok);
   if not Arena_Ok then
      Put_Line ("ALB-FATAL> Memory arena bootstrap failed.");
      Set_Player_Exit (Exit_Internal_Fault);
      return;
   end if;

   Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, Lex_Diag);
   if not Lex_Diag.Success then
      Render_Lexer_Diagnostic;
      Set_Player_Exit (Exit_Lex_Failure);
      return;
   end if;

   Parse (Tokens, Token_Count, Tree, Root, Parse_Success, Parse_Diag);
   if not Parse_Success then
      Render_Parser_Diagnostic;
      Set_Player_Exit (Exit_Parse_Failure);
      return;
   end if;

   Build_Audit_Manifest;

   if Show_Limits then
      Print_Limits;
   end if;

   if Mode = Mode_Check then
      Print_Audit_Report (False);
      if Has_Hard_Audit_Failure then
         Set_Player_Exit (Exit_Audit_Failure);
      else
         Put_Line ("ALB-CHECK> Script parsed and passed alb_player preflight.");
      end if;
      return;
   elsif Mode = Mode_Audit then
      Print_Audit_Report (True);
      if Has_Hard_Audit_Failure then
         Set_Player_Exit (Exit_Audit_Failure);
      end if;
      return;
   end if;

   if Has_Hard_Audit_Failure then
      Print_Audit_Report (False);
      Set_Player_Exit (Exit_Audit_Failure);
      return;
   end if;

   if Trace_Calls then
      Print_Audit_Report (False);
   end if;

   if Root = 0 then
      Put_Line ("ALB-PLAYER> Script parsed cleanly, but there was naethin' tae execute.");
      return;
   end if;

   Clear_Last_Failure;
   Current_Top_Level := 0;

   declare
      Curr : Node_Index := Root;
   begin
      while Curr /= 0 loop
         Current_Top_Level := Curr;
         if Trace_Calls then
            Put_Line ("ALB-TRACE> Executing top-level AST node " & Node_Label (Curr) & ".");
         end if;

         Clear_Last_Failure;
         Execute (Input_Buffer (1 .. Input_Len), Tokens, Tree, Curr, State, Exec_Success, 1.0);
         if not Exec_Success then
            Render_Runtime_Diagnostic;
            Set_Player_Exit (Exit_Run_Failure);
            return;
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end;

   Current_Top_Level := 0;

exception
   when E : others =>
      declare
         Code : Oracle_Code := Err_None;
         Node : Node_Index := 0;
      begin
         Get_Last_Failure (Code, Node);
         if Code /= Err_None or else Node /= 0 then
            Render_Runtime_Diagnostic;
            Set_Player_Exit (Exit_Run_Failure);
         else
            Put_Line ("ALB-INTERNAL> alb_player raised an unhandled Ada exception.");
            Put_Line (Exception_Information (E));
            Set_Player_Exit (Exit_Internal_Fault);
         end if;
      end;
end ALB_Player;
