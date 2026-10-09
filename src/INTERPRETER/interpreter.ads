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

with Tokenizer;  use Tokenizer;
with AST;        use AST;
with Range_Spec; use Range_Spec;
with ALB_Types;  use ALB_Types;
with Atom_Types; use Atom_Types;
with ALB_Oracle; use ALB_Oracle;

-- THIS IS ONLY TO BE USED WITH THE ALB_PLAYER.ADB
-- NOTHING ELSE NO COMPILERS, THIS IS AN INTERPRETER SPECIFIC
-- FEATURE AND SPEC/BODY SET ANYTHING INSIDE THE INTERPRETER FOLDER
-- IS SPECIFIC TO THE INTERPRETER


package Interpreter is

   Max_Name_Length : constant := 32;
   subtype Var_Name is String (1 .. Max_Name_Length);

   Max_Vars : constant := 512;
   type Var_Record is record
      Active : Boolean := False;
      Name   : Var_Name := (others => ' ');
      Value  : ALB_Value := (Tag => Type_None);
   end record;
   type Memory_Bank_Array is array (1 .. Max_Vars) of Var_Record;

   Max_Dimensions  : constant := 4;
   Max_Arrays      : constant := 128;
   Max_Array_Cells : constant := 32768;

   type Dim_Array is array (1 .. Max_Dimensions) of Natural;

   type Array_Record is record
      Active        : Boolean := False;
      Name          : Var_Name := (others => ' ');
      Element_Tag   : ALB_Type_Tag := Type_None;
      Sliding       : Boolean := False;
      Dim_Count     : Natural := 0;
      Dims          : Dim_Array := (others => 0);
      Length        : Natural := 0;
      Active_Length : Natural := 0;
      Base          : Natural := 0;
      Bounds        : RS_Interval := (Lower => 0.0, Upper => 0.0);
   end record;

   type Array_Bank_Array    is array (1 .. Max_Arrays) of Array_Record;
   type Array_Storage_Array is array (1 .. Max_Array_Cells) of ALB_Value;

   Max_Named_Types : constant := 128;
   type Named_Type_Record is record
      Active   : Boolean := False;
      Name     : Var_Name := (others => ' ');
      Base_Tag : ALB_Type_Tag := Type_None;
   end record;
   type Named_Type_Array is array (1 .. Max_Named_Types) of Named_Type_Record;

   Max_Structs       : constant := 64;
   Max_Struct_Fields : constant := 64;

   type Struct_Field_Record is record
      Active : Boolean := False;
      Name   : Var_Name := (others => ' ');
      Tag    : ALB_Type_Tag := Type_None;
      Offset : Natural := 0;
      Size   : Natural := 0;
   end record;
   type Struct_Field_Array is array (1 .. Max_Struct_Fields) of Struct_Field_Record;

   type Struct_Record is record
      Active      : Boolean := False;
      Name        : Var_Name := (others => ' ');
      Field_Count : Natural := 0;
      Size_Bytes  : Natural := 0;
      Fields      : Struct_Field_Array := (others => <>);
   end record;
   type Struct_Array is array (1 .. Max_Structs) of Struct_Record;

   Max_Parallel_Groups : constant := 64;
   Max_Parallel_Fields : constant := 32;

   type Parallel_Field_Record is record
      Active     : Boolean := False;
      Field_Name : Var_Name := (others => ' ');
      Array_Name : Var_Name := (others => ' ');
   end record;
   type Parallel_Field_Array is array (1 .. Max_Parallel_Fields) of Parallel_Field_Record;

   type Parallel_Record is record
      Active      : Boolean := False;
      Name        : Var_Name := (others => ' ');
      Capacity    : Natural := 0;
      Field_Count : Natural := 0;
      Fields      : Parallel_Field_Array := (others => <>);
   end record;
   type Parallel_Array is array (1 .. Max_Parallel_Groups) of Parallel_Record;

   Max_Binary_Slots  : constant := 512;
   Max_Binary_Length : constant := 512;
   subtype Binary_Text is String (1 .. Max_Binary_Length);

   type Binary_Record is record
      Active : Boolean := False;
      Length : Natural := 0;
      Data   : Binary_Text := (others => ' ');
   end record;
   type Binary_Bank_Array is array (1 .. Max_Binary_Slots) of Binary_Record;

   Max_Open_Files       : constant := 32;
   Max_File_Path_Length : constant := 512;
   subtype File_Path_Text is String (1 .. Max_File_Path_Length);

   type Runtime_File_Mode is (File_Mode_Read, File_Mode_Write, File_Mode_Append);

   type Runtime_File_Record is record
      Active      : Boolean := False;
      Path_Length : Natural := 0;
      Path        : File_Path_Text := (others => ' ');
      Mode        : Runtime_File_Mode := File_Mode_Read;
      Position    : Natural := 0;
   end record;

   type Runtime_File_Array is array (1 .. Max_Open_Files) of Runtime_File_Record;

   Max_Temporal_Vars      : constant := 64;
   Max_Temporal_History   : constant := 32;
   Max_Temporal_Snapshots : constant := 4;

   type Temporal_Value_Array is array (1 .. Max_Temporal_History) of ALB_Value;

   type Temporal_Record is record
      Active        : Boolean := False;
      Name          : Var_Name := (others => ' ');
      History_Limit : Natural := 0;
      Length        : Natural := 0;
      Cursor        : Natural := 1;
      Values        : Temporal_Value_Array := (others => (Tag => Type_None));
   end record;

   type Temporal_Array is array (1 .. Max_Temporal_Vars) of Temporal_Record;

   type Temporal_Snapshot_Record is record
      Active    : Boolean := False;
      Temporals : Temporal_Array := (others => <>);
   end record;

   type Temporal_Snapshot_Array is array (1 .. Max_Temporal_Snapshots) of Temporal_Snapshot_Record;

   Max_Clauses : constant := 512;
   Max_Logic_Args : constant := 32;

   type Logic_Arg is record
      Is_Var : Boolean := False;
      Name   : Var_Name := (others => ' ');
   end record;
   type Logic_Arg_Array is array (1 .. Max_Logic_Args) of Logic_Arg;

   type Clause_Record is record
      Active    : Boolean := False;
      Head_Name : Var_Name := (others => ' ');
      Args      : Logic_Arg_Array :=
        (others => (Is_Var => False, Name => (others => ' ')));
      Arg_Count : Natural := 0;
   end record;
   type Clause_Array is array (1 .. Max_Clauses) of Clause_Record;

   Max_Procs : constant := 128;

   type Proc_Record is record
      Active     : Boolean := False;
      Name       : Var_Name := (others => ' ');
      Params_Node : Node_Index := 0;
      Body_Node  : Node_Index := 0;
      Return_Tag : ALB_Type_Tag := Type_None;
   end record;
   type Proc_Bank_Array is array (1 .. Max_Procs) of Proc_Record;

   Max_Call_Depth : constant := 32;

   type Call_Scope_Save_Record is record
      Active     : Boolean := False;
      Name       : Var_Name := (others => ' ');
      Slot       : Natural := 0;
      Was_Active : Boolean := False;
      Old_Name   : Var_Name := (others => ' ');
      Old_Value  : ALB_Value := (Tag => Type_None);
   end record;

   type Call_Scope_Save_Array is array (1 .. Max_Vars) of Call_Scope_Save_Record;

   type Call_Scope_Record is record
      Save_Count : Natural := 0;
      Saves      : Call_Scope_Save_Array := (others => <>);
   end record;

   type Call_Scope_Array is array (1 .. Max_Call_Depth) of Call_Scope_Record;

   type Engine_State is record
      Bank        : Memory_Bank_Array :=
        (others => (Active => False, Name => (others => ' '), Value => (Tag => Type_None)));
      Count       : Natural := 0;

      Arrays      : Array_Bank_Array :=
        (others =>
           (Active        => False,
            Name          => (others => ' '),
            Element_Tag   => Type_None,
            Sliding       => False,
            Dim_Count     => 0,
            Dims          => (others => 0),
            Length        => 0,
            Active_Length => 0,
            Base          => 0,
            Bounds        => (Lower => 0.0, Upper => 0.0)));
      Array_Cells : Array_Storage_Array := (others => (Tag => Type_None));
      Array_Count : Natural := 0;
      Next_Cell   : Natural := 1;

      Named_Types : Named_Type_Array := (others => <>);
      Structs     : Struct_Array := (others => <>);
      Parallels   : Parallel_Array := (others => <>);
      Binary_Bank : Binary_Bank_Array := (others => <>);
      Binary_Count : Natural := 0;
      Files       : Runtime_File_Array := (others => <>);
      Temporals   : Temporal_Array := (others => <>);
      Temporal_Count      : Natural := 0;
      Temporal_Snapshots  : Temporal_Snapshot_Array := (others => <>);
      Temporal_Save_Depth : Natural := 0;

      Lexicon      : Lexicon_Vault;
      Clauses      : Clause_Array :=
        (others =>
           (Active    => False,
            Head_Name => (others => ' '),
            Args      => (others => (Is_Var => False, Name => (others => ' '))),
            Arg_Count => 0));
      Clause_Count : Natural := 0;

      Procs      : Proc_Bank_Array :=
        (others =>
           (Active      => False,
            Name        => (others => ' '),
            Params_Node => 0,
            Body_Node   => 0,
            Return_Tag  => Type_None));
      Proc_Count : Natural := 0;
      Call_Depth : Natural := 0;
      Call_Scopes : Call_Scope_Array := (others => <>);

      Random_Seed    : Natural := 1;
      Window_Width   : Natural := 320;
      Window_Height  : Natural := 200;
      Tick_Length_Ms : Natural := 0;

      On_Tick_Node  : Node_Index := 0;
      On_Paint_Node : Node_Index := 0;
      On_Key_Node   : Node_Index := 0;
      Stop_Listen   : Boolean := False;
      Current_Module   : Var_Name := (others => ' ');
      Return_Pending   : Boolean := False;
      Return_Value     : ALB_Value := (Tag => Type_None);
      Break_Pending    : Boolean := False;
      Continue_Pending : Boolean := False;
   end record;

   procedure Clear_Last_Failure;
   procedure Get_Last_Failure (Code : out Oracle_Code; Node : out Node_Index);

   procedure Execute (Source  : in String;
                      Tokens  : in Token_Array;
                      Tree    : in Node_Array;
                      Root    : in Node_Index;
                      State   : in out Engine_State;
                      Success : out Boolean;
                      Mask    : in Long_Float);

end Interpreter;
