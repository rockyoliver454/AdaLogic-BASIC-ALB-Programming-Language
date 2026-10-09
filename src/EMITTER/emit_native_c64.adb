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

with Ada.Characters.Latin_1;
with Ada.Text_IO;
with Interfaces;

with AST;            use AST;
with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;

package body Emit_Native_C64 is

   Max_Output_Size     : constant Natural := 524_288;
   Max_Symbols         : constant Natural := 384;
   Max_Name_Length     : constant Natural := 96;
   Max_Loop_Depth      : constant Natural := 16;
   Max_String_Literals : constant Natural := 64;
   Max_String_Length   : constant Natural := 96;
   Max_Consts          : constant Natural := 128;
   Max_Procedures      : constant Natural := 128;
   Max_Procedure_Params : constant Natural := 8;
   Max_Array_Dimensions : constant Natural := 2;
   Max_Range_Types     : constant Natural := 32;
   Max_Structs         : constant Natural := 16;
   Max_Struct_Fields   : constant Natural := 16;
   Max_Parallel_Groups : constant Natural := 16;
   Max_Parallel_Fields : constant Natural := 16;
   Max_Temporal_Vars   : constant Natural := 32;
   Max_Logic_Predicates : constant Natural := 96;
   Max_Logic_Atoms      : constant Natural := 128;
   Max_Logic_Rules      : constant Natural := 64;
   Max_Logic_Rule_Terms : constant Natural := 192;
   Max_Logic_Rule_Vars  : constant Natural := 16;
   Max_Logic_Hooks      : constant Natural := 32;
   Max_Logic_Facts      : constant Natural := 96;
   Max_Logic_Depth      : constant Natural := 8;
   Max_Logic_Results    : constant Natural := 96;
   Max_Rev_Journal      : constant Natural := 192;
   Max_Rev_Block_Depth  : constant Natural := 32;
   Pointer_Register_Count : constant Natural := 2;
   LF                  : constant String := (1 => Ada.Characters.Latin_1.LF);

   subtype Output_Buffer is String (1 .. Max_Output_Size);
   subtype Symbol_Index is Natural range 0 .. Max_Symbols;

   type Symbol_Kind is
     (Symbol_U8,
      Symbol_HW8,
      Symbol_U16,
      Symbol_Pointer16,
      Symbol_HW16,
      Symbol_String,
      Symbol_Struct_Instance,
      Symbol_Parallel_Group,
      Symbol_Strict_U8_Array,
      Symbol_Strict_U16_Array,
      Symbol_Slide_U8_Array,
      Symbol_Slide_U16_Array);
   type Address_Source_Kind is (Address_Absolute, Address_Pointer);
   type Byte_Source_Kind is
     (Source_Literal,
      Source_Variable,
      Source_Peek_Absolute,
      Source_Peek_Pointer,
      Source_Array_Element);

   type Array_Bounds is
     array (Positive range 1 .. Max_Array_Dimensions) of Natural range 0 .. 255;

   type Array_Access is record
      Symbol  : Symbol_Index := 0;
      Index_1 : Node_Index := 0;
      Index_2 : Node_Index := 0;
   end record;

   type Address_Source is record
      Kind           : Address_Source_Kind := Address_Absolute;
      Absolute_Value : Natural range 0 .. 65_535 := 0;
      Pointer        : Symbol_Index := 0;
   end record;

   type Symbol_Record is record
      Active            : Boolean := False;
      Name              : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len          : Natural range 0 .. Max_Name_Length := 0;
      Kind              : Symbol_Kind := Symbol_U8;
      Range_Id          : Natural range 0 .. Max_Range_Types := 0;
      Struct_Id         : Natural range 0 .. Max_Structs := 0;
      Parallel_Id       : Natural range 0 .. Max_Parallel_Groups := 0;
      Dim_Count         : Natural range 0 .. Max_Array_Dimensions := 0;
      Bounds            : Array_Bounds := (others => 0);
      Active_Bound      : Natural range 0 .. 255 := 0;
      Zero_Page_Register : Natural range 0 .. Pointer_Register_Count - 1 := 0;
   end record;

   type Symbol_Array is array (Positive range 1 .. Max_Symbols) of Symbol_Record;

   type Const_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len : Natural range 0 .. Max_Name_Length := 0;
      Value    : Integer := 0;
   end record;

   type Const_Array is array (Positive range 1 .. Max_Consts) of Const_Record;

   type Param_Symbol_Array is
     array (Positive range 1 .. Max_Procedure_Params) of Symbol_Index;
   type Param_Mode_Array is
     array (Positive range 1 .. Max_Procedure_Params) of Boolean;

   type Range_Type_Record is record
      Active    : Boolean := False;
      Name      : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len  : Natural range 0 .. Max_Name_Length := 0;
      Base_Kind : Symbol_Kind := Symbol_U8;
      Low_Value : Integer := 0;
      High_Value : Integer := 0;
   end record;

   type Range_Type_Array is
     array (Positive range 1 .. Max_Range_Types) of Range_Type_Record;

   type Struct_Field_Record is record
      Active    : Boolean := False;
      Name      : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len  : Natural range 0 .. Max_Name_Length := 0;
      Kind      : Symbol_Kind := Symbol_U8;
      Range_Id  : Natural range 0 .. Max_Range_Types := 0;
   end record;

   type Struct_Field_Array is
     array (Positive range 1 .. Max_Struct_Fields) of Struct_Field_Record;

   type Struct_Record is record
      Active      : Boolean := False;
      Name        : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len    : Natural range 0 .. Max_Name_Length := 0;
      Field_Count : Natural range 0 .. Max_Struct_Fields := 0;
      Fields      : Struct_Field_Array := (others => (others => <>));
   end record;

   type Struct_Array is
     array (Positive range 1 .. Max_Structs) of Struct_Record;

   type Parallel_Field_Record is record
      Active         : Boolean := False;
      Name           : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len       : Natural range 0 .. Max_Name_Length := 0;
      Kind           : Symbol_Kind := Symbol_U8;
      Range_Id       : Natural range 0 .. Max_Range_Types := 0;
      Backing_Symbol : Symbol_Index := 0;
   end record;

   type Parallel_Field_Array is
     array (Positive range 1 .. Max_Parallel_Fields) of Parallel_Field_Record;

   type Parallel_Group_Record is record
      Active      : Boolean := False;
      Name        : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len    : Natural range 0 .. Max_Name_Length := 0;
      Capacity    : Natural range 0 .. 255 := 0;
      Field_Count : Natural range 0 .. Max_Parallel_Fields := 0;
      Fields      : Parallel_Field_Array := (others => (others => <>));
   end record;

   type Parallel_Group_Array is
     array (Positive range 1 .. Max_Parallel_Groups) of Parallel_Group_Record;

   type Procedure_Record is record
      Active        : Boolean := False;
      Name          : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len      : Natural range 0 .. Max_Name_Length := 0;
      Body_Node     : Node_Index := 0;
      Param_Count   : Natural range 0 .. Max_Procedure_Params := 0;
      Param_Symbols : Param_Symbol_Array := (others => 0);
      Param_Is_Out  : Param_Mode_Array := (others => False);
      Is_Function   : Boolean := False;
      Return_Void   : Boolean := True;
      Return_Kind   : Symbol_Kind := Symbol_U8;
      Return_Range_Id : Natural range 0 .. Max_Range_Types := 0;
      Return_Symbol : Symbol_Index := 0;
   end record;

   type Procedure_Array is
     array (Positive range 1 .. Max_Procedures) of Procedure_Record;

   type String_Literal_Record is record
      Active   : Boolean := False;
      Text     : String (1 .. Max_String_Length) := (others => ' ');
      Text_Len : Natural range 0 .. Max_String_Length := 0;
   end record;

   type String_Literal_Array is
     array (Positive range 1 .. Max_String_Literals) of String_Literal_Record;

   type Byte_Source is record
      Kind          : Byte_Source_Kind := Source_Literal;
      Literal_Value : Natural range 0 .. 255 := 0;
      Variable      : Symbol_Index := 0;
      Address       : Address_Source := (others => <>);
      Element       : Array_Access := (others => <>);
   end record;

   type Loop_Plan is record
      Use_Poke      : Boolean := False;
      Poke_Target   : Symbol_Index := 0;
      Poke_Source   : Byte_Source := (others => <>);
      Use_Increment : Boolean := False;
      Increment_Var : Symbol_Index := 0;
   end record;

   type Loop_Context is record
      Label_Id     : Natural := 0;
      Index_Symbol : Symbol_Index := 0;
   end record;

   type Loop_Context_Array is
     array (Positive range 1 .. Max_Loop_Depth) of Loop_Context;

   type Temporal_Record is record
      Active        : Boolean := False;
      Name          : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len      : Natural range 0 .. Max_Name_Length := 0;
      Kind          : Symbol_Kind := Symbol_U8;
      Current       : Symbol_Index := 0;
      Past          : Symbol_Index := 0;
      Saved         : Symbol_Index := 0;
      Timeline      : Symbol_Index := 0;
      History_Size  : Natural range 0 .. 255 := 2;
      Element_Bytes : Natural range 1 .. 2 := 1;
   end record;

   type Temporal_Array is
     array (Positive range 1 .. Max_Temporal_Vars) of Temporal_Record;

   type Logic_Predicate_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. Max_Name_Length) := (others => ' ');
      Name_Len : Natural range 0 .. Max_Name_Length := 0;
      Id       : Natural range 0 .. 65_535 := 0;
   end record;

   type Logic_Predicate_Array is
     array (Positive range 1 .. Max_Logic_Predicates) of Logic_Predicate_Record;

   type Logic_Atom_Record is record
      Active   : Boolean := False;
      Text     : String (1 .. Max_String_Length) := (others => ' ');
      Text_Len : Natural range 0 .. Max_String_Length := 0;
      Id       : Natural range 0 .. 65_535 := 0;
   end record;

   type Logic_Atom_Array is
     array (Positive range 1 .. Max_Logic_Atoms) of Logic_Atom_Record;

   type Logic_Rule_Term_Record is record
      Active    : Boolean := False;
      Pred_Id   : Natural range 0 .. 65_535 := 0;
      Arg_Mode  : Natural range 0 .. 2 := 0;
      Arg_Value : Integer := 0;
   end record;

   type Logic_Rule_Term_Array is
     array (Positive range 1 .. Max_Logic_Rule_Terms) of Logic_Rule_Term_Record;

   type Logic_Rule_Record is record
      Active       : Boolean := False;
      Head_Pred_Id : Natural range 0 .. 65_535 := 0;
      Head_Mode    : Natural range 0 .. 2 := 0;
      Head_Value   : Integer := 0;
      Var_Count    : Natural range 0 .. Max_Logic_Rule_Vars := 0;
      Body_Start   : Natural range 0 .. Max_Logic_Rule_Terms := 0;
      Body_Count   : Natural range 0 .. Max_Logic_Rule_Terms := 0;
   end record;

   type Logic_Rule_Array is
     array (Positive range 1 .. Max_Logic_Rules) of Logic_Rule_Record;

   type Logic_Hook_Record is record
      Active      : Boolean := False;
      Pred_Id     : Natural range 0 .. 65_535 := 0;
      Arg_Symbol  : Symbol_Index := 0;
      Block_Node  : Node_Index := 0;
      Label_Id    : Natural := 0;
   end record;

   type Logic_Hook_Array is
     array (Positive range 1 .. Max_Logic_Hooks) of Logic_Hook_Record;

   type Native_ASM_Family is
     (ASM_Family_Generic,
      ASM_Family_X64,
      ASM_Family_8086,
      ASM_Family_6502,
      ASM_Family_Unknown);

   type Native_ASM_Mode is
     (ASM_Mode_Off,
      ASM_Mode_Active,
      ASM_Mode_Ignored);

   type Emitter_State is record
      Buffer             : Output_Buffer := (others => ' ');
      Length             : Natural range 0 .. Max_Output_Size := 0;
      Symbols            : Symbol_Array := (others => (others => <>));
      Symbol_Count       : Natural range 0 .. Max_Symbols := 0;
      Consts             : Const_Array := (others => (others => <>));
      Const_Count        : Natural range 0 .. Max_Consts := 0;
      Range_Types        : Range_Type_Array := (others => (others => <>));
      Range_Type_Count   : Natural range 0 .. Max_Range_Types := 0;
      Structs            : Struct_Array := (others => (others => <>));
      Struct_Count       : Natural range 0 .. Max_Structs := 0;
      Parallel_Groups    : Parallel_Group_Array := (others => (others => <>));
      Parallel_Count     : Natural range 0 .. Max_Parallel_Groups := 0;
      Procedures         : Procedure_Array := (others => (others => <>));
      Procedure_Count    : Natural range 0 .. Max_Procedures := 0;
      String_Literals    : String_Literal_Array := (others => (others => <>));
      String_Count       : Natural range 0 .. Max_String_Literals := 0;
      Next_Pointer_ZP    : Natural range 0 .. Pointer_Register_Count := 0;
      Loop_Label_Counter : Natural := 0;
      Loop_Depth         : Natural range 0 .. Max_Loop_Depth := 0;
      Loop_Stack         : Loop_Context_Array := (others => (others => <>));
      Temporals          : Temporal_Array := (others => (others => <>));
      Temporal_Count     : Natural range 0 .. Max_Temporal_Vars := 0;
      Logic_Predicates   : Logic_Predicate_Array := (others => (others => <>));
      Logic_Predicate_Count : Natural range 0 .. Max_Logic_Predicates := 0;
      Logic_Atoms        : Logic_Atom_Array := (others => (others => <>));
      Logic_Atom_Count   : Natural range 0 .. Max_Logic_Atoms := 0;
      Logic_Rules        : Logic_Rule_Array := (others => (others => <>));
      Logic_Rule_Count   : Natural range 0 .. Max_Logic_Rules := 0;
      Logic_Rule_Terms   : Logic_Rule_Term_Array := (others => (others => <>));
      Logic_Rule_Term_Count : Natural range 0 .. Max_Logic_Rule_Terms := 0;
      Logic_Hooks        : Logic_Hook_Array := (others => (others => <>));
      Logic_Hook_Count   : Natural range 0 .. Max_Logic_Hooks := 0;
      On_Tick_Node       : Node_Index := 0;
      On_Paint_Node      : Node_Index := 0;
      On_Key_Node        : Node_Index := 0;
      On_Knows_Node      : Node_Index := 0;
      Current_Procedure  : Natural range 0 .. Max_Procedures := 0;
      Reversible_Depth   : Natural range 0 .. Max_Rev_Block_Depth := 0;
      Native_ASM_State   : Native_ASM_Mode := ASM_Mode_Off;
      Success            : Boolean := True;
   end record;

   procedure Reserve_Label_Id
     (State : in out Emitter_State;
      Id    : out Natural);

   function Loop_Top_Label (Id : Natural) return String;
   function Loop_Continue_Label (Id : Natural) return String;
   function Loop_Check_Lo_Label (Id : Natural) return String;
   function Loop_Continue_Skip_Hi_Label (Id : Natural) return String;
   function Loop_End_Label (Id : Natural) return String;
   function Procedure_Label
     (State : Emitter_State;
      Id    : Natural) return String;
   function Temporal_Head_Label (Id : Natural) return String;
   function Temporal_Count_Label (Id : Natural) return String;
   function Temporal_Save_Head_Label (Id : Natural) return String;
   function Temporal_Save_Count_Label (Id : Natural) return String;
   function Symbol_Snapshot_Label (Id : Natural) return String;
   function Rev_Runtime_Label (Suffix : String) return String;

   procedure Push_Loop_Context
     (State        : in out Emitter_State;
      Label_Id     : Natural;
      Index_Symbol : Symbol_Index);

   procedure Pop_Loop_Context (State : in out Emitter_State);
   function Current_Index_Symbol (State : Emitter_State) return Symbol_Index;
   function Current_Loop_Label_Id (State : Emitter_State) return Natural;
   procedure Emit_Index_Y_Load (State : in out Emitter_State);
   procedure Emit_Temporal_Advance
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Temporal_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Save_Load_State
     (State    : in out Emitter_State;
      Is_Load  : Boolean;
      Node     : Node_Index);
   procedure Emit_Event_Definitions
     (State : in out Emitter_State);
   procedure Emit_Foreach_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_SwapPop_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);

   procedure Emit_Node_Chain
     (State : in out Emitter_State;
      First : Node_Index);

   procedure Collect_Declarations
     (State : in out Emitter_State;
      Node  : Node_Index;
      Procedure_Id : Natural := 0);
   procedure Append_Line (State : in out Emitter_State; Text : String);
   procedure Fail
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Message : String);
   procedure Register_Symbol
     (State      : in out Emitter_State;
      Node       : Node_Index;
      Name       : String;
      Kind       : Symbol_Kind;
      Symbol_Out : out Symbol_Index);
   function Evaluate_Static_Expr
     (State     : Emitter_State;
     Expr_Node : Node_Index;
      Value     : out Integer) return Boolean;
   procedure Emit_Copy_Label_Bytes
     (State       : in out Emitter_State;
      Source_Label : String;
      Target_Label : String;
      Byte_Count   : Natural);
   procedure Emit_Copy_Symbol_To_Label
     (State         : in out Emitter_State;
      Source_Symbol : Symbol_Index;
      Target_Label  : String);
   procedure Emit_Copy_Label_To_Symbol
     (State        : in out Emitter_State;
      Source_Label : String;
      Target_Symbol : Symbol_Index);
   procedure Emit_Clear_Label_Bytes
     (State      : in out Emitter_State;
      Target_Label : String;
      Byte_Count   : Natural);
   procedure Emit_Load_Temporal_Byte
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Load_Temporal_Word
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Load_Temporal_String
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Assignable_Address
     (State            : in out Emitter_State;
      Target_Node      : Node_Index;
      Low_Label        : String;
      High_Label       : String;
      Width_Bytes_Out  : out Natural;
      Target_Kind_Out  : out Symbol_Kind);
   procedure Emit_Reversible_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);

   function Logic_Query_Is_Find (Idx : Node_Index) return Boolean;
   function Predicate_Name_Of (Idx : Node_Index) return String;
   function Predicate_Arg_Node (Idx : Node_Index) return Node_Index;
   function Find_Logic_Predicate
     (State : Emitter_State;
      Name  : String) return Natural;
   procedure Register_Logic_Predicate
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Name    : String;
      Pred_Id : out Natural);
   function Find_Logic_Atom
     (State : Emitter_State;
      Text  : String) return Natural;
   procedure Register_Logic_Atom
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Text    : String;
      Atom_Id : out Natural);
   procedure Collect_Logic_Rule_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Collect_Logic_Hook
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Logic_Value_To_Storage
     (State       : in out Emitter_State;
      Node        : Node_Index;
      Low_Target  : String;
      High_Target : String);
   procedure Emit_Logic_Query
     (State       : in out Emitter_State;
      Node        : Node_Index;
      Store_Value : Boolean := False;
      Bool_Only   : Boolean := False);

   type Member_Access_Kind is
     (Member_Invalid,
      Member_Struct_Field,
      Member_Parallel_Field);

   type Member_Access_Record is record
      Kind        : Member_Access_Kind := Member_Invalid;
      Symbol      : Symbol_Index := 0;
      Element     : Array_Access := (others => <>);
      Field_Range : Natural range 0 .. Max_Range_Types := 0;
   end record;

   type Type_Info is record
      Found      : Boolean := False;
      Is_Void    : Boolean := False;
      Is_Struct  : Boolean := False;
      Struct_Id  : Natural range 0 .. Max_Structs := 0;
      Kind       : Symbol_Kind := Symbol_U8;
      Range_Id   : Natural range 0 .. Max_Range_Types := 0;
   end record;

   procedure Register_String_Literal
     (State : in out Emitter_State;
      Node  : Node_Index;
      Index : out Natural);

   function Is_Pointer_Symbol (Kind : Symbol_Kind) return Boolean;
   function Is_Array_Symbol (Kind : Symbol_Kind) return Boolean;
   function Is_Byte_Scalar_Symbol (Kind : Symbol_Kind) return Boolean;
   function Is_Word_Scalar_Symbol (Kind : Symbol_Kind) return Boolean;
   function Is_String_Symbol (Kind : Symbol_Kind) return Boolean;
   function Is_U8_Array_Symbol (Kind : Symbol_Kind) return Boolean;
   function Is_U16_Array_Symbol (Kind : Symbol_Kind) return Boolean;
   function Array_Element_Bytes (Kind : Symbol_Kind) return Natural;
   function Array_Visible_Length (Symbol : Symbol_Record) return Natural;
   function Array_Total_Bytes (Symbol : Symbol_Record) return Natural;
   function Normalize_Byte (Value : Integer) return Natural;
   function Normalize_Word (Value : Integer) return Natural;
   function Symbol_Stored_Name
     (State  : Emitter_State;
      Symbol : Symbol_Index) return String;
   function Temporal_Index
     (State : Emitter_State;
      Name  : String) return Natural;
   function Qualify_Member_Name
     (Base_Name  : String;
      Field_Name : String) return String;
   function Expr_Is_Word
     (State : Emitter_State;
      Node  : Node_Index) return Boolean;
   function Expr_Is_String
     (State : Emitter_State;
      Node  : Node_Index) return Boolean;
   function ASM_Block_Body (Node : Node_Index) return String;
   function Nth_Arg
     (List_Node : Node_Index;
      Position  : Positive) return Node_Index;
   function Find_Const
     (State : Emitter_State;
     Name  : String) return Natural;
   function Lookup_Const
     (State   : Emitter_State;
      Name    : String;
      Value   : out Integer) return Boolean;
   procedure Register_Const
     (State : in out Emitter_State;
      Node  : Node_Index;
      Name  : String;
      Value : Integer);
   function Find_Procedure
     (State : Emitter_State;
      Name  : String) return Natural;
   function Find_Range_Type
     (State : Emitter_State;
      Name  : String) return Natural;
   function Find_Struct_Type
     (State : Emitter_State;
      Name  : String) return Natural;
   function Find_Parallel_Group
     (State : Emitter_State;
      Name  : String) return Natural;
   procedure Register_Procedure
     (State         : in out Emitter_State;
      Node          : Node_Index;
      Name          : String;
      Body_Node     : Node_Index;
      Is_Function   : Boolean := False;
      Procedure_Out : out Natural);
   procedure Register_Range_Type
     (State     : in out Emitter_State;
      Node      : Node_Index;
      Name      : String;
      Base_Kind : Symbol_Kind;
      Low_Value : Integer;
      High_Value : Integer;
      Range_Id  : out Natural);
   procedure Register_Struct_Type
     (State     : in out Emitter_State;
      Node      : Node_Index;
      Name      : String;
      Struct_Id : out Natural);
   procedure Add_Struct_Field
     (State     : in out Emitter_State;
      Node      : Node_Index;
      Struct_Id : Natural;
      Name      : String;
      Kind      : Symbol_Kind;
      Range_Id  : Natural := 0);
   procedure Register_Parallel_Group
     (State     : in out Emitter_State;
      Node      : Node_Index;
      Name      : String;
      Capacity  : Natural;
      Group_Id  : out Natural);
   procedure Add_Parallel_Field
     (State          : in out Emitter_State;
      Node           : Node_Index;
      Group_Id       : Natural;
      Stored_Group   : String;
      Name           : String;
      Element_Kind   : Symbol_Kind;
      Range_Id       : Natural := 0);
   procedure Register_Temporal
     (State      : in out Emitter_State;
      Node       : Node_Index;
      Name       : String;
      Kind       : Symbol_Kind;
      History_Size : Natural;
      Temporal_Id : out Natural);
   function Scoped_Name
     (State          : Emitter_State;
      Procedure_Id   : Natural;
      Raw_Name       : String) return String;
   function Find_Visible_Symbol
     (State : Emitter_State;
      Name  : String) return Symbol_Index;
   function Is_Void_Type_Lexeme (Type_Lex : String) return Boolean;
   procedure Resolve_Type_Info
     (State          : Emitter_State;
      Type_Lex       : String;
      U16_As_Pointer : Boolean;
      Allow_Void     : Boolean;
      Allow_Struct   : Boolean;
      Info           : out Type_Info);
   function Find_Struct_Field
     (State     : Emitter_State;
      Struct_Id : Natural;
      Name      : String) return Natural;
   function Find_Parallel_Field
     (State    : Emitter_State;
      Group_Id : Natural;
      Name     : String) return Natural;
   procedure Analyze_Member_Access
     (State  : in out Emitter_State;
      Node   : Node_Index;
      Result : out Member_Access_Record);
   procedure Analyze_Array_Access
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Element : out Array_Access);
   procedure Emit_String_Address
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Byte_Expr
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Word_Expr
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Condition_False_Branch
     (State       : in out Emitter_State;
      Condition   : Node_Index;
      False_Label : String);
   procedure Emit_U8_Assignment
     (State         : in out Emitter_State;
      Target_Symbol : Symbol_Index;
      RHS_Node      : Node_Index;
      Origin_Node   : Node_Index);
   procedure Emit_Array_Assignment
     (State       : in out Emitter_State;
      Target_Node : Node_Index;
      RHS_Node    : Node_Index);
   procedure Emit_Pointer_Assignment
     (State         : in out Emitter_State;
      Target_Symbol : Symbol_Index;
      RHS_Node      : Node_Index);
   procedure Emit_Word_Expr_To_Cell_Store
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Target  : String;
      Min_One : Boolean := False);
   procedure Emit_Color_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Clear_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Create_Window_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Draw_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Plot_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Listen_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Cease_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Delay_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_File_Write_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_File_Close_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Load_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Play_Sound_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Copy_Symbol_To_Target
     (State         : in out Emitter_State;
      Source_Symbol : Symbol_Index;
      Target_Node   : Node_Index);
   procedure Emit_Clear_Target
     (State       : in out Emitter_State;
      Target_Node : Node_Index);
   procedure Emit_Return_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index);
   procedure Emit_Routine_Call
     (State        : in out Emitter_State;
      Target_Node  : Node_Index;
      Call_Node    : Node_Index;
      Routine_Id   : out Natural;
      Expect_Value : Boolean;
      Success_Out  : out Boolean);
   function Return_Label
     (State : Emitter_State;
      Id    : Natural) return String;
   procedure Emit_Procedure_Definitions
     (State : in out Emitter_State;
      First : Node_Index);

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

   function Decimal_Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Decimal_Image;

   function Hex_Digit (Value : Natural) return Character is
      Hex_Table : constant String := "0123456789ABCDEF";
   begin
      return Hex_Table (Value + 1);
   end Hex_Digit;

   function Byte_Hex (Value : Natural) return String is
      V : constant Natural := Value mod 256;
   begin
      return "$" & Hex_Digit (V / 16) & Hex_Digit (V mod 16);
   end Byte_Hex;

   function Low_Byte (Value : Natural) return Natural is
   begin
      return Value mod 256;
   end Low_Byte;

   function High_Byte (Value : Natural) return Natural is
   begin
      return (Value / 256) mod 256;
   end High_Byte;

   function Zero_Page_Base (Register : Natural) return Natural is
   begin
      case Register is
         when 0 =>
            return 16#FB#;
         when others =>
            return 16#FD#;
      end case;
   end Zero_Page_Base;

   function Token_Lexeme (Tok_Idx : Natural) return String is
      Tok : constant Token := Tokens (Tok_Idx);
   begin
      return Input_Buffer (Tok.Start .. Tok.Start + Tok.Length - 1);
   end Token_Lexeme;

   function Node_Lexeme (Idx : Node_Index) return String is
   begin
      return Token_Lexeme (Tree (Idx).Token_Index);
   end Node_Lexeme;

   function Starts_With (Text : String; Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Native_ASM_Family_From_Lexeme
     (Lexeme : String) return Native_ASM_Family
   is
      Upper_Lexeme : constant String := Upper_ASCII (Lexeme);
   begin
      if Upper_Lexeme = "ENABLEASM" then
         return ASM_Family_Generic;
      elsif Upper_Lexeme = "ENABLEASM_X64"
        or else Upper_Lexeme = "ENABLEASM_X86_64"
        or else Upper_Lexeme = "ENABLEASM_AMD64"
      then
         return ASM_Family_X64;
      elsif Upper_Lexeme = "ENABLEASM_8086" then
         return ASM_Family_8086;
      elsif Upper_Lexeme = "ENABLEASM_6502" then
         return ASM_Family_6502;
      elsif Starts_With (Upper_Lexeme, "ENABLEASM_") then
         return ASM_Family_Unknown;
      else
         return ASM_Family_Unknown;
      end if;
   end Native_ASM_Family_From_Lexeme;

   function Native_ASM_Family_Is_Active
     (Family : Native_ASM_Family) return Boolean
   is
   begin
      return Family = ASM_Family_6502;
   end Native_ASM_Family_Is_Active;

   function Normalize_Name (Raw_Name : String) return String is
      Upper_Name : constant String := Upper_ASCII (Raw_Name);
      Result     : String (1 .. Upper_Name'Length);
      Offset     : Natural := 1;
      Ch         : Character;
   begin
      for I in Upper_Name'Range loop
         Ch := Upper_Name (I);
         if (Ch >= 'A' and then Ch <= 'Z')
           or else (Ch >= '0' and then Ch <= '9')
           or else Ch = '_'
         then
            Result (Offset) := Ch;
         else
            Result (Offset) := '_';
         end if;
         Offset := Offset + 1;
      end loop;
      return Result;
   end Normalize_Name;

   function Decode_String_Node (Idx : Node_Index) return String is
      Raw      : constant String := Node_Lexeme (Idx);
      Start_At : Natural := 0;
      End_At   : Natural := 0;
   begin
      if Raw'Length >= 2
        and then ((Raw (Raw'First) = '"' and then Raw (Raw'Last) = '"')
          or else (Raw (Raw'First) = '`' and then Raw (Raw'Last) = '`'))
      then
         Start_At := Raw'First + 1;
         End_At := Raw'Last - 1;
         if End_At + 1 < Start_At then
            return "";
         end if;
         return Raw (Start_At .. End_At);
      end if;

      return Raw;
   end Decode_String_Node;

   function Logic_Query_Is_Find (Idx : Node_Index) return Boolean is
   begin
      return
        Idx /= 0
        and then Tree (Idx).Kind = AST_Find_Query
        and then Tree (Idx).Token_Index > 0
        and then Tokens (Tree (Idx).Token_Index).Kind = TOK_FIND;
   end Logic_Query_Is_Find;

   function Predicate_Name_Of (Idx : Node_Index) return String is
      Name_Node : Node_Index := 0;
   begin
      if Idx = 0 then
         return "";
      end if;

      case Tree (Idx).Kind is
         when AST_Predicate | AST_Assert_Stmt | AST_Retract_Stmt =>
            if Tree (Idx).Token_Index > 0 then
               return Upper_ASCII (Node_Lexeme (Idx));
            end if;

         when AST_Update_Stmt | AST_Findall_Query | AST_Query | AST_Knows_Query |
              AST_Rule_Decl | AST_Constraint_Decl =>
            return Predicate_Name_Of (Tree (Idx).Left_Child);

         when AST_Knows_Change =>
            return Predicate_Name_Of (Tree (Idx).Right_Child);

         when AST_Find_Query =>
            if Logic_Query_Is_Find (Idx) then
               return Predicate_Name_Of (Tree (Idx).Left_Child);
            elsif Tree (Idx).Token_Index > 0 then
               return Upper_ASCII (Node_Lexeme (Idx));
            end if;

         when AST_Func_Call =>
            Name_Node := Tree (Idx).Left_Child;
            if Name_Node /= 0 then
               return Predicate_Name_Of (Name_Node);
            end if;

         when AST_Member_Expr =>
            if Tree (Idx).Right_Child /= 0 then
               return Predicate_Name_Of (Tree (Idx).Right_Child);
            end if;

         when AST_Atom | AST_Var_Expr | AST_Logic_Var =>
            if Tree (Idx).Token_Index > 0 then
               return Upper_ASCII (Node_Lexeme (Idx));
            end if;

         when others =>
            if Tree (Idx).Token_Index > 0 then
               return Upper_ASCII (Node_Lexeme (Idx));
            end if;
      end case;

      return "";
   end Predicate_Name_Of;

   function Predicate_Arg_Node (Idx : Node_Index) return Node_Index is
      Name_Node : Node_Index := 0;
   begin
      if Idx = 0 then
         return 0;
      end if;

      if Tree (Idx).Kind = AST_Predicate and then Tree (Idx).Left_Child /= 0 then
         return Tree (Idx).Left_Child;
      elsif Tree (Idx).Kind in AST_Update_Stmt | AST_Findall_Query | AST_Query |
        AST_Knows_Query | AST_Rule_Decl | AST_Constraint_Decl
      then
         return Predicate_Arg_Node (Tree (Idx).Left_Child);
      elsif Tree (Idx).Kind = AST_Knows_Change and then Tree (Idx).Right_Child /= 0 then
         return Predicate_Arg_Node (Tree (Idx).Right_Child);
      elsif Tree (Idx).Kind = AST_Find_Query then
         if Logic_Query_Is_Find (Idx) then
            return Predicate_Arg_Node (Tree (Idx).Left_Child);
         else
            return Tree (Idx).Left_Child;
         end if;
      elsif Tree (Idx).Kind in AST_Assert_Stmt | AST_Retract_Stmt then
         return Tree (Idx).Left_Child;
      elsif Tree (Idx).Kind = AST_Func_Call then
         if Tree (Idx).Right_Child /= 0 and then Tree (Tree (Idx).Right_Child).Kind = AST_Arg_List then
            return Tree (Tree (Idx).Right_Child).Left_Child;
         else
            return Tree (Idx).Right_Child;
         end if;
      elsif Tree (Idx).Kind = AST_Member_Expr then
         Name_Node := Tree (Idx).Right_Child;
         if Name_Node /= 0 then
            return Predicate_Arg_Node (Name_Node);
         end if;
      end if;

      return 0;
   end Predicate_Arg_Node;

   function Find_Logic_Predicate
     (State : Emitter_State;
      Name  : String) return Natural
   is
      Wanted : constant String := Upper_ASCII (Name);
   begin
      for I in 1 .. State.Logic_Predicate_Count loop
         if State.Logic_Predicates (I).Active
           and then State.Logic_Predicates (I).Name_Len = Wanted'Length
           and then State.Logic_Predicates (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Logic_Predicate;

   procedure Register_Logic_Predicate
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Name    : String;
      Pred_Id : out Natural)
   is
      Wanted : constant String := Upper_ASCII (Name);
      Found  : constant Natural := Find_Logic_Predicate (State, Wanted);
   begin
      Pred_Id := 0;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "logic predicate name is empty or too long");
         return;
      end if;

      if Found /= 0 then
         Pred_Id := State.Logic_Predicates (Found).Id;
         return;
      end if;

      if State.Logic_Predicate_Count >= Max_Logic_Predicates then
         Fail (State, Node, "logic predicate table exhausted");
         return;
      end if;

      State.Logic_Predicate_Count := State.Logic_Predicate_Count + 1;
      Pred_Id := State.Logic_Predicate_Count;
      State.Logic_Predicates (Pred_Id).Active := True;
      State.Logic_Predicates (Pred_Id).Name_Len := Wanted'Length;
      State.Logic_Predicates (Pred_Id).Name (1 .. Wanted'Length) := Wanted;
      State.Logic_Predicates (Pred_Id).Id := Pred_Id;
   end Register_Logic_Predicate;

   function Find_Logic_Atom
     (State : Emitter_State;
      Text  : String) return Natural
   is
   begin
      for I in 1 .. State.Logic_Atom_Count loop
         if State.Logic_Atoms (I).Active
           and then State.Logic_Atoms (I).Text_Len = Text'Length
           and then State.Logic_Atoms (I).Text (1 .. Text'Length) = Text
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Logic_Atom;

   procedure Register_Logic_Atom
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Text    : String;
      Atom_Id : out Natural)
   is
      Found : constant Natural := Find_Logic_Atom (State, Text);
   begin
      Atom_Id := 0;

      if Text'Length = 0 or else Text'Length > Max_String_Length then
         Fail (State, Node, "logic atom text is empty or too long");
         return;
      end if;

      if Found /= 0 then
         Atom_Id := State.Logic_Atoms (Found).Id;
         return;
      end if;

      if State.Logic_Atom_Count >= Max_Logic_Atoms then
         Fail (State, Node, "logic atom table exhausted");
         return;
      end if;

      State.Logic_Atom_Count := State.Logic_Atom_Count + 1;
      Atom_Id := State.Logic_Atom_Count;
      State.Logic_Atoms (Atom_Id).Active := True;
      State.Logic_Atoms (Atom_Id).Text_Len := Text'Length;
      State.Logic_Atoms (Atom_Id).Text (1 .. Text'Length) := Text;
      State.Logic_Atoms (Atom_Id).Id := Atom_Id;
   end Register_Logic_Atom;

   procedure Collect_Logic_Rule_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      type Var_Name_Array is
        array (Positive range 1 .. Max_Logic_Rule_Vars)
          of String (1 .. Max_Name_Length);
      type Var_Len_Array is
        array (Positive range 1 .. Max_Logic_Rule_Vars)
          of Natural range 0 .. Max_Name_Length;

      Rule_Id    : Natural := 0;
      Head_Node  : constant Node_Index := Tree (Node).Left_Child;
      Body_Node  : constant Node_Index := Tree (Node).Right_Child;
      Curr_Body  : Node_Index := (if Body_Node /= 0 then Tree (Body_Node).Left_Child else 0);
      Var_Names  : Var_Name_Array := (others => (others => ' '));
      Var_Lens   : Var_Len_Array := (others => 0);
      Var_Count  : Natural range 0 .. Max_Logic_Rule_Vars := 0;

      function Ensure_Var_Index (Arg_Node : Node_Index) return Natural is
         Wanted : constant String := Upper_ASCII (Node_Lexeme (Arg_Node));
      begin
         for I in 1 .. Var_Count loop
            if Var_Lens (I) = Wanted'Length
              and then Var_Names (I) (1 .. Wanted'Length) = Wanted
            then
               return I;
            end if;
         end loop;

         if Var_Count >= Max_Logic_Rule_Vars then
            Fail (State, Arg_Node, "logic rule variable budget exhausted");
            return 0;
         elsif Var_Count >= 1 then
            Fail (State, Arg_Node, "ALB-65 rules currently support one distinct logic variable");
            return 0;
         end if;

         Var_Count := Var_Count + 1;
         Var_Lens (Var_Count) := Wanted'Length;
         Var_Names (Var_Count) (1 .. Wanted'Length) := Wanted;
         return Var_Count;
      end Ensure_Var_Index;

      procedure Collect_Arg
        (Arg_Node : Node_Index;
         Mode     : out Natural;
         Value    : out Integer)
      is
         Static_Value : Integer := 0;
         Atom_Id      : Natural := 0;
      begin
         Mode := 0;
         Value := 0;

         if Arg_Node = 0 then
            return;
         elsif Tree (Arg_Node).Kind = AST_Logic_Var
           or else (Tree (Arg_Node).Kind = AST_Var_Expr
             and then Tree (Arg_Node).Token_Index > 0
             and then Tokens (Tree (Arg_Node).Token_Index).Kind = TOK_LOGIC_VAR)
         then
            Value := Integer (Ensure_Var_Index (Arg_Node));
            if not State.Success then
               return;
            end if;
            Mode := 2;
         elsif Evaluate_Static_Expr (State, Arg_Node, Static_Value) then
            Mode := 1;
            Value := Integer (Normalize_Word (Static_Value));
         elsif Tree (Arg_Node).Kind = AST_Atom then
            Register_Logic_Atom (State, Arg_Node, Upper_ASCII (Node_Lexeme (Arg_Node)), Atom_Id);
            if not State.Success then
               return;
            end if;
            Mode := 1;
            Value := Integer (Atom_Id);
         elsif Tree (Arg_Node).Kind = AST_String_Expr then
            Register_Logic_Atom (State, Arg_Node, Decode_String_Node (Arg_Node), Atom_Id);
            if not State.Success then
               return;
            end if;
            Mode := 1;
            Value := Integer (Atom_Id);
         else
            Fail (State, Arg_Node, "logic rules require static atoms, numbers, or a single logic variable");
         end if;
      end Collect_Arg;

      Head_Pred_Id : Natural := 0;
      Head_Mode    : Natural := 0;
      Head_Value   : Integer := 0;
      Term_Pred_Id : Natural := 0;
      Term_Mode    : Natural := 0;
      Term_Value   : Integer := 0;
   begin
      if Head_Node = 0 then
         Fail (State, Node, "logic rule is missing its head predicate");
         return;
      end if;

      if State.Logic_Rule_Count >= Max_Logic_Rules then
         Fail (State, Node, "logic rule table exhausted");
         return;
      end if;

      Register_Logic_Predicate (State, Head_Node, Predicate_Name_Of (Head_Node), Head_Pred_Id);
      if not State.Success then
         return;
      end if;

      Collect_Arg (Predicate_Arg_Node (Head_Node), Head_Mode, Head_Value);
      if not State.Success then
         return;
      end if;

      State.Logic_Rule_Count := State.Logic_Rule_Count + 1;
      Rule_Id := State.Logic_Rule_Count;
      State.Logic_Rules (Rule_Id).Active := True;
      State.Logic_Rules (Rule_Id).Head_Pred_Id := Head_Pred_Id;
      State.Logic_Rules (Rule_Id).Head_Mode := Head_Mode;
      State.Logic_Rules (Rule_Id).Head_Value := Head_Value;
      State.Logic_Rules (Rule_Id).Body_Start := State.Logic_Rule_Term_Count;
      State.Logic_Rules (Rule_Id).Body_Count := 0;

      while Curr_Body /= 0 and then State.Success loop
         if State.Logic_Rule_Term_Count >= Max_Logic_Rule_Terms then
            Fail (State, Curr_Body, "logic rule term table exhausted");
            return;
         end if;

         Register_Logic_Predicate
           (State, Curr_Body, Predicate_Name_Of (Curr_Body), Term_Pred_Id);
         if not State.Success then
            return;
         end if;

         Collect_Arg (Predicate_Arg_Node (Curr_Body), Term_Mode, Term_Value);
         if not State.Success then
            return;
         end if;

         State.Logic_Rule_Term_Count := State.Logic_Rule_Term_Count + 1;
         State.Logic_Rule_Terms (State.Logic_Rule_Term_Count).Active := True;
         State.Logic_Rule_Terms (State.Logic_Rule_Term_Count).Pred_Id := Term_Pred_Id;
         State.Logic_Rule_Terms (State.Logic_Rule_Term_Count).Arg_Mode := Term_Mode;
         State.Logic_Rule_Terms (State.Logic_Rule_Term_Count).Arg_Value := Term_Value;
         State.Logic_Rules (Rule_Id).Body_Count :=
           State.Logic_Rules (Rule_Id).Body_Count + 1;
         Curr_Body := Tree (Curr_Body).Next_Sibling;
      end loop;

      State.Logic_Rules (Rule_Id).Var_Count := Var_Count;
   end Collect_Logic_Rule_Declaration;

   procedure Collect_Logic_Hook
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Pred_Node  : constant Node_Index := Tree (Node).Right_Child;
      Arg_Node   : constant Node_Index := Predicate_Arg_Node (Pred_Node);
      Hook_Id    : Natural := 0;
      Pred_Id    : Natural := 0;
      Hook_Symbol : Symbol_Index := 0;
      Label_Id   : Natural := 0;
   begin
      if Pred_Node = 0 then
         Fail (State, Node, "ON KNOWS_CHANGE requires a predicate target");
         return;
      end if;

      if State.Logic_Hook_Count >= Max_Logic_Hooks then
         Fail (State, Node, "logic hook table exhausted");
         return;
      end if;

      Register_Logic_Predicate (State, Pred_Node, Predicate_Name_Of (Pred_Node), Pred_Id);
      if not State.Success then
         return;
      end if;

      if Arg_Node /= 0 and then Tree (Arg_Node).Kind = AST_Logic_Var then
         Register_Symbol (State, Arg_Node, Node_Lexeme (Arg_Node), Symbol_U16, Hook_Symbol);
         if not State.Success then
            return;
         end if;
      end if;

      Reserve_Label_Id (State, Label_Id);
      State.Logic_Hook_Count := State.Logic_Hook_Count + 1;
      Hook_Id := State.Logic_Hook_Count;
      State.Logic_Hooks (Hook_Id).Active := True;
      State.Logic_Hooks (Hook_Id).Pred_Id := Pred_Id;
      State.Logic_Hooks (Hook_Id).Arg_Symbol := Hook_Symbol;
      State.Logic_Hooks (Hook_Id).Block_Node := Tree (Node).Left_Child;
      State.Logic_Hooks (Hook_Id).Label_Id := Label_Id;

      if Tree (Node).Left_Child /= 0 then
         Collect_Declarations (State, Tree (Node).Left_Child, 0);
      end if;
   end Collect_Logic_Hook;

   procedure Emit_Logic_Value_To_Storage
     (State       : in out Emitter_State;
      Node        : Node_Index;
      Low_Target  : String;
      High_Target : String)
   is
      Atom_Id : Natural := 0;
   begin
      if Node = 0 then
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA " & Low_Target);
         Append_Line (State, "    STA " & High_Target);
         return;
      elsif Tree (Node).Kind = AST_Atom then
         Register_Logic_Atom (State, Node, Upper_ASCII (Node_Lexeme (Node)), Atom_Id);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Atom_Id)));
         Append_Line (State, "    STA " & Low_Target);
         Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Atom_Id)));
         Append_Line (State, "    STA " & High_Target);
         return;
      elsif Tree (Node).Kind = AST_String_Expr then
         Register_Logic_Atom (State, Node, Decode_String_Node (Node), Atom_Id);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Atom_Id)));
         Append_Line (State, "    STA " & Low_Target);
         Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Atom_Id)));
         Append_Line (State, "    STA " & High_Target);
         return;
      end if;

      Emit_Word_Expr (State, Node);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA " & Low_Target);
      Append_Line (State, "    STX " & High_Target);
   end Emit_Logic_Value_To_Storage;

   procedure Emit_Logic_Query
     (State       : in out Emitter_State;
      Node        : Node_Index;
      Store_Value : Boolean := False;
      Bool_Only   : Boolean := False)
   is
      Pred_Id   : Natural := 0;
      Arg_Node  : constant Node_Index := Predicate_Arg_Node (Node);
      Pred_Name : constant String := Predicate_Name_Of (Node);
      Is_Find   : constant Boolean := Logic_Query_Is_Find (Node) and then not Bool_Only;
      pragma Unreferenced (Store_Value);
   begin
      Register_Logic_Predicate (State, Node, Pred_Name, Pred_Id);
      if not State.Success then
         return;
      end if;

      Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Pred_Id)));
      Append_Line (State, "    STA alb_logic_query_pred_lo");
      Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Pred_Id)));
      Append_Line (State, "    STA alb_logic_query_pred_hi");

      if Arg_Node = 0 then
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA alb_logic_query_mode");
         Append_Line (State, "    STA alb_logic_query_val_lo");
         Append_Line (State, "    STA alb_logic_query_val_hi");
      elsif Tree (Arg_Node).Kind = AST_Logic_Var then
         Append_Line (State, "    LDA #$02");
         Append_Line (State, "    STA alb_logic_query_mode");
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA alb_logic_query_val_lo");
         Append_Line (State, "    STA alb_logic_query_val_hi");
      else
         Append_Line (State, "    LDA #$01");
         Append_Line (State, "    STA alb_logic_query_mode");
         Emit_Logic_Value_To_Storage
           (State, Arg_Node, "alb_logic_query_val_lo", "alb_logic_query_val_hi");
         if not State.Success then
            return;
         end if;
      end if;

      if Is_Find then
         Append_Line (State, "    JSR alb_logic_find_first");
      else
         Append_Line (State, "    JSR alb_logic_prove");
      end if;
   end Emit_Logic_Query;

   procedure Append (State : in out Emitter_State; Text : String) is
   begin
      if not State.Success then
         return;
      end if;

      if State.Length + Text'Length > Max_Output_Size then
         State.Success := False;
         return;
      end if;

      State.Buffer (State.Length + 1 .. State.Length + Text'Length) := Text;
      State.Length := State.Length + Text'Length;
   end Append;

   procedure Append_Line (State : in out Emitter_State; Text : String) is
   begin
      Append (State, Text);
      Append (State, LF);
   end Append_Line;

   procedure Fail
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Message : String)
   is
      Tok_Idx : Natural := 0;
   begin
      if not State.Success then
         return;
      end if;

      State.Success := False;

      if Node > 0 then
         Tok_Idx := Tree (Node).Token_Index;
      end if;

      if Tok_Idx > 0 then
         Ada.Text_IO.Put_Line
           ("ALB-65 C64 emitter error at line "
            & Decimal_Image (Tokens (Tok_Idx).Line)
            & ", col "
            & Decimal_Image (Tokens (Tok_Idx).Column)
            & ": "
            & Message);
      else
         Ada.Text_IO.Put_Line ("ALB-65 C64 emitter error: " & Message);
      end if;
   end Fail;

   function Find_Symbol
     (State : Emitter_State;
      Name  : String) return Symbol_Index
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      for I in 1 .. State.Symbol_Count loop
         if State.Symbols (I).Active
           and then State.Symbols (I).Name_Len = Wanted'Length
           and then State.Symbols (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Symbol;

   procedure Register_Symbol
     (State      : in out Emitter_State;
      Node       : Node_Index;
      Name       : String;
      Kind       : Symbol_Kind;
      Symbol_Out : out Symbol_Index)
   is
      Wanted : constant String := Normalize_Name (Name);
      Found  : Symbol_Index := 0;
   begin
      Symbol_Out := 0;
      Found := Find_Symbol (State, Name);

      if Found /= 0 then
         if State.Symbols (Found).Kind /= Kind then
            Fail (State, Node, "symbol redeclared with incompatible C64 storage width");
            return;
         end if;

         Symbol_Out := Found;
         return;
      end if;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "symbol name is empty or too long for the C64 backend");
         return;
      end if;

      if State.Symbol_Count >= Max_Symbols then
         Fail (State, Node, "C64 backend symbol table exhausted");
         return;
      end if;

      if Is_Pointer_Symbol (Kind)
        and then State.Next_Pointer_ZP >= Pointer_Register_Count
      then
         Fail (State, Node, "zero-page pointer register budget exhausted");
         return;
      end if;

      State.Symbol_Count := State.Symbol_Count + 1;
      Symbol_Out := State.Symbol_Count;
      State.Symbols (Symbol_Out).Active := True;
      State.Symbols (Symbol_Out).Name_Len := Wanted'Length;
      State.Symbols (Symbol_Out).Name (1 .. Wanted'Length) := Wanted;
      State.Symbols (Symbol_Out).Kind := Kind;

      if Is_Pointer_Symbol (Kind) then
         State.Symbols (Symbol_Out).Zero_Page_Register := State.Next_Pointer_ZP;
         State.Next_Pointer_ZP := State.Next_Pointer_ZP + 1;
      end if;
   end Register_Symbol;

   function Symbol_Name
     (State  : Emitter_State;
      Symbol : Symbol_Index) return String
   is
      Base : constant String :=
        State.Symbols (Symbol).Name (1 .. State.Symbols (Symbol).Name_Len);
   begin
      case State.Symbols (Symbol).Kind is
         when Symbol_Pointer16 =>
            return "alb_ptr_" & Base;

         when Symbol_String =>
            return "alb_strptr_" & Base;

         when Symbol_Strict_U8_Array
            | Symbol_Strict_U16_Array
            | Symbol_Slide_U8_Array
            | Symbol_Slide_U16_Array =>
            return "alb_arr_" & Base;

         when Symbol_Struct_Instance =>
            return "alb_struct_" & Base;

         when Symbol_Parallel_Group =>
            return "alb_group_" & Base;

         when others =>
            return "alb_var_" & Base;
      end case;
   end Symbol_Name;

   function Symbol_Stored_Name
     (State  : Emitter_State;
      Symbol : Symbol_Index) return String
   is
   begin
      return State.Symbols (Symbol).Name (1 .. State.Symbols (Symbol).Name_Len);
   end Symbol_Stored_Name;

   procedure Emit_Copy_Label_Bytes
     (State        : in out Emitter_State;
      Source_Label : String;
      Target_Label : String;
      Byte_Count   : Natural)
   is
      Loop_Id : Natural := 0;
   begin
      if Byte_Count = 0 then
         return;
      elsif Byte_Count = 1 then
         Append_Line (State, "    LDA " & Source_Label);
         Append_Line (State, "    STA " & Target_Label);
         return;
      elsif Byte_Count = 2 then
         Append_Line (State, "    LDA " & Source_Label);
         Append_Line (State, "    STA " & Target_Label);
         Append_Line (State, "    LDA " & Source_Label & "+1");
         Append_Line (State, "    STA " & Target_Label & "+1");
         return;
      end if;

      Reserve_Label_Id (State, Loop_Id);
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "alb_copy_bytes_" & Decimal_Image (Loop_Id) & ":");
      Append_Line (State, "    LDA " & Source_Label & ",Y");
      Append_Line (State, "    STA " & Target_Label & ",Y");
      Append_Line (State, "    INY");
      if Byte_Count = 256 then
         Append_Line (State, "    BNE alb_copy_bytes_" & Decimal_Image (Loop_Id));
      else
         Append_Line (State, "    CPY #" & Byte_Hex (Byte_Count));
         Append_Line (State, "    BNE alb_copy_bytes_" & Decimal_Image (Loop_Id));
      end if;
   end Emit_Copy_Label_Bytes;

   procedure Emit_Copy_Symbol_To_Label
     (State         : in out Emitter_State;
      Source_Symbol : Symbol_Index;
      Target_Label  : String)
   is
      Byte_Count : Natural := 0;
   begin
      if Is_Byte_Scalar_Symbol (State.Symbols (Source_Symbol).Kind) then
         Byte_Count := 1;
      elsif Is_Array_Symbol (State.Symbols (Source_Symbol).Kind) then
         Byte_Count := Array_Total_Bytes (State.Symbols (Source_Symbol));
      else
         Byte_Count := 2;
      end if;

      Emit_Copy_Label_Bytes
        (State,
         Symbol_Name (State, Source_Symbol),
         Target_Label,
         Byte_Count);
   end Emit_Copy_Symbol_To_Label;

   procedure Emit_Copy_Label_To_Symbol
     (State         : in out Emitter_State;
      Source_Label  : String;
      Target_Symbol : Symbol_Index)
   is
      Byte_Count : Natural := 0;
   begin
      if Is_Byte_Scalar_Symbol (State.Symbols (Target_Symbol).Kind) then
         Byte_Count := 1;
      elsif Is_Array_Symbol (State.Symbols (Target_Symbol).Kind) then
         Byte_Count := Array_Total_Bytes (State.Symbols (Target_Symbol));
      else
         Byte_Count := 2;
      end if;

      Emit_Copy_Label_Bytes
        (State,
         Source_Label,
         Symbol_Name (State, Target_Symbol),
         Byte_Count);
   end Emit_Copy_Label_To_Symbol;

   procedure Emit_Clear_Label_Bytes
     (State        : in out Emitter_State;
      Target_Label : String;
      Byte_Count   : Natural)
   is
      Loop_Id : Natural := 0;
   begin
      if Byte_Count = 0 then
         return;
      elsif Byte_Count = 1 then
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA " & Target_Label);
         return;
      elsif Byte_Count = 2 then
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA " & Target_Label);
         Append_Line (State, "    STA " & Target_Label & "+1");
         return;
      end if;

      Reserve_Label_Id (State, Loop_Id);
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "alb_clear_bytes_" & Decimal_Image (Loop_Id) & ":");
      Append_Line (State, "    STA " & Target_Label & ",Y");
      Append_Line (State, "    INY");
      if Byte_Count = 256 then
         Append_Line (State, "    BNE alb_clear_bytes_" & Decimal_Image (Loop_Id));
      else
         Append_Line (State, "    CPY #" & Byte_Hex (Byte_Count));
         Append_Line (State, "    BNE alb_clear_bytes_" & Decimal_Image (Loop_Id));
      end if;
   end Emit_Clear_Label_Bytes;

   function Temporal_Index
     (State : Emitter_State;
      Name  : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      for I in 1 .. State.Temporal_Count loop
         if State.Temporals (I).Active
           and then State.Temporals (I).Name_Len = Wanted'Length
           and then State.Temporals (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;

      return 0;
   end Temporal_Index;

   function Qualify_Member_Name
     (Base_Name  : String;
      Field_Name : String) return String
   is
   begin
      return Normalize_Name (Base_Name) & "__" & Normalize_Name (Field_Name);
   end Qualify_Member_Name;

   function ASM_Block_Body (Node : Node_Index) return String is
      Raw   : constant String := Node_Lexeme (Node);
      Start : Natural := Raw'First;
      Stop  : Natural := Raw'Last;
      Tail_Start : Natural := Raw'First;
      Trim_Stop  : Natural := Raw'Last;
   begin
      while Start <= Raw'Last and then Raw (Start) /= Ada.Characters.Latin_1.LF loop
         Start := Start + 1;
      end loop;

      if Start <= Raw'Last then
         Start := Start + 1;
      end if;

      while Stop >= Raw'First and then Raw (Stop) /= Ada.Characters.Latin_1.LF loop
         Stop := Stop - 1;
      end loop;

      if Stop < Start then
         return "";
      end if;

      Trim_Stop := Stop;
      while Trim_Stop >= Start
        and then (Raw (Trim_Stop) = Ada.Characters.Latin_1.CR
          or else Raw (Trim_Stop) = Ada.Characters.Latin_1.LF
          or else Raw (Trim_Stop) = ' ')
      loop
         Trim_Stop := Trim_Stop - 1;
      end loop;

      if Trim_Stop < Start then
         return "";
      end if;

      Tail_Start := Trim_Stop;
      while Tail_Start > Start
        and then Raw (Tail_Start - 1) /= Ada.Characters.Latin_1.LF
      loop
         Tail_Start := Tail_Start - 1;
      end loop;

      declare
         Tail : constant String := Upper_ASCII (Raw (Tail_Start .. Trim_Stop));
      begin
         if Tail = "END ASM" or else Tail = "END ENABLE" then
            Stop := Tail_Start - 1;
            while Stop >= Start
              and then (Raw (Stop) = Ada.Characters.Latin_1.CR
                or else Raw (Stop) = Ada.Characters.Latin_1.LF)
            loop
               Stop := Stop - 1;
            end loop;
         else
            Stop := Trim_Stop;
         end if;
      end;

      if Stop < Start then
         return "";
      else
         return Raw (Start .. Stop);
      end if;
   end ASM_Block_Body;

   function Nth_Arg
     (List_Node : Node_Index;
      Position  : Positive) return Node_Index
   is
      Curr  : Node_Index := 0;
      Count : Positive := 1;
   begin
      if List_Node = 0 then
         return 0;
      elsif Tree (List_Node).Kind = AST_Arg_List then
         Curr := Tree (List_Node).Left_Child;
      else
         Curr := List_Node;
      end if;

      while Curr /= 0 loop
         if Count = Position then
            return Curr;
         end if;

         Curr := Tree (Curr).Next_Sibling;
         Count := Count + 1;
      end loop;

      return 0;
   end Nth_Arg;

   function Is_Pointer_Symbol (Kind : Symbol_Kind) return Boolean is
   begin
      return Kind = Symbol_Pointer16;
   end Is_Pointer_Symbol;

   function Is_Array_Symbol (Kind : Symbol_Kind) return Boolean is
   begin
      return Kind in Symbol_Strict_U8_Array
        | Symbol_Strict_U16_Array
        | Symbol_Slide_U8_Array
        | Symbol_Slide_U16_Array;
   end Is_Array_Symbol;

   function Is_Byte_Scalar_Symbol (Kind : Symbol_Kind) return Boolean is
   begin
      return Kind in Symbol_U8 | Symbol_HW8;
   end Is_Byte_Scalar_Symbol;

   function Is_Word_Scalar_Symbol (Kind : Symbol_Kind) return Boolean is
   begin
      return Kind in Symbol_U16 | Symbol_Pointer16 | Symbol_HW16;
   end Is_Word_Scalar_Symbol;

   function Is_String_Symbol (Kind : Symbol_Kind) return Boolean is
   begin
      return Kind = Symbol_String;
   end Is_String_Symbol;

   function Is_U8_Array_Symbol (Kind : Symbol_Kind) return Boolean is
   begin
      return Kind in Symbol_Strict_U8_Array | Symbol_Slide_U8_Array;
   end Is_U8_Array_Symbol;

   function Is_U16_Array_Symbol (Kind : Symbol_Kind) return Boolean is
   begin
      return Kind in Symbol_Strict_U16_Array | Symbol_Slide_U16_Array;
   end Is_U16_Array_Symbol;

   function Array_Element_Bytes (Kind : Symbol_Kind) return Natural is
   begin
      if Is_U16_Array_Symbol (Kind) then
         return 2;
      else
         return 1;
      end if;
   end Array_Element_Bytes;

   function Array_Visible_Length (Symbol : Symbol_Record) return Natural is
   begin
      if Symbol.Kind in Symbol_Slide_U8_Array | Symbol_Slide_U16_Array then
         return Symbol.Active_Bound;
      else
         return Symbol.Bounds (1);
      end if;
   end Array_Visible_Length;

   function Array_Total_Bytes (Symbol : Symbol_Record) return Natural is
      Element_Bytes : constant Natural := Array_Element_Bytes (Symbol.Kind);
   begin
      if Symbol.Kind in Symbol_Slide_U8_Array | Symbol_Slide_U16_Array then
         return Symbol.Bounds (1) * Element_Bytes;
      elsif Symbol.Dim_Count = 2 then
         return Symbol.Bounds (1) * Symbol.Bounds (2) * Element_Bytes;
      else
         return Symbol.Bounds (1) * Element_Bytes;
      end if;
   end Array_Total_Bytes;

   function Normalize_Byte (Value : Integer) return Natural is
      Result : Integer := Value mod 256;
   begin
      if Result < 0 then
         Result := Result + 256;
      end if;
      return Natural (Result);
   end Normalize_Byte;

   function Normalize_Word (Value : Integer) return Natural is
      Result : Integer := Value mod 65_536;
   begin
      if Result < 0 then
         Result := Result + 65_536;
      end if;
      return Natural (Result);
   end Normalize_Word;

   function Bitwise_Or
     (Left  : Integer;
      Right : Integer) return Integer
   is
      use type Interfaces.Unsigned_16;

      Left_Bits  : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Normalize_Word (Left));
      Right_Bits : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Normalize_Word (Right));
   begin
      return Integer (Left_Bits or Right_Bits);
   end Bitwise_Or;

   function Bitwise_And
     (Left  : Integer;
      Right : Integer) return Integer
   is
      use type Interfaces.Unsigned_16;

      Left_Bits  : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Normalize_Word (Left));
      Right_Bits : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Normalize_Word (Right));
   begin
      return Integer (Left_Bits and Right_Bits);
   end Bitwise_And;

   function Bitwise_Xor
     (Left  : Integer;
      Right : Integer) return Integer
   is
      use type Interfaces.Unsigned_16;

      Left_Bits  : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Normalize_Word (Left));
      Right_Bits : constant Interfaces.Unsigned_16 :=
        Interfaces.Unsigned_16 (Normalize_Word (Right));
   begin
      return Integer (Left_Bits xor Right_Bits);
   end Bitwise_Xor;

   function Find_Const
     (State : Emitter_State;
      Name  : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      for I in 1 .. State.Const_Count loop
         if State.Consts (I).Active
           and then State.Consts (I).Name_Len = Wanted'Length
           and then State.Consts (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Const;

   function Lookup_Const
     (State   : Emitter_State;
      Name    : String;
      Value   : out Integer) return Boolean
   is
      Found : constant Natural := Find_Const (State, Name);
   begin
      Value := 0;
      if Found = 0 then
         return False;
      else
         Value := State.Consts (Found).Value;
         return True;
      end if;
   end Lookup_Const;

   procedure Register_Const
     (State : in out Emitter_State;
      Node  : Node_Index;
      Name  : String;
      Value : Integer)
   is
      Wanted : constant String := Normalize_Name (Name);
      Found  : constant Natural := Find_Const (State, Name);
   begin
      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "compile-time constant name is empty or too long");
         return;
      end if;

      if Found /= 0 then
         State.Consts (Found).Value := Value;
         return;
      end if;

      if State.Const_Count >= Max_Consts then
         Fail (State, Node, "compile-time constant table exhausted");
         return;
      end if;

      State.Const_Count := State.Const_Count + 1;
      State.Consts (State.Const_Count).Active := True;
      State.Consts (State.Const_Count).Name_Len := Wanted'Length;
      State.Consts (State.Const_Count).Name (1 .. Wanted'Length) := Wanted;
      State.Consts (State.Const_Count).Value := Value;
   end Register_Const;

   function Find_Range_Type
     (State : Emitter_State;
      Name  : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      for I in 1 .. State.Range_Type_Count loop
         if State.Range_Types (I).Active
           and then State.Range_Types (I).Name_Len = Wanted'Length
           and then State.Range_Types (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Range_Type;

   function Find_Struct_Type
     (State : Emitter_State;
      Name  : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      for I in 1 .. State.Struct_Count loop
         if State.Structs (I).Active
           and then State.Structs (I).Name_Len = Wanted'Length
           and then State.Structs (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Struct_Type;

   function Find_Parallel_Group
     (State : Emitter_State;
      Name  : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      for I in 1 .. State.Parallel_Count loop
         if State.Parallel_Groups (I).Active
           and then State.Parallel_Groups (I).Name_Len = Wanted'Length
           and then State.Parallel_Groups (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Parallel_Group;

   procedure Register_Range_Type
     (State      : in out Emitter_State;
      Node       : Node_Index;
      Name       : String;
      Base_Kind  : Symbol_Kind;
      Low_Value  : Integer;
      High_Value : Integer;
      Range_Id   : out Natural)
   is
      Wanted : constant String := Normalize_Name (Name);
      Found  : constant Natural := Find_Range_Type (State, Name);
   begin
      Range_Id := 0;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "range type name is empty or too long");
         return;
      end if;

      if Low_Value > High_Value then
         Fail (State, Node, "range type lower bound exceeds upper bound");
         return;
      end if;

      if Found /= 0 then
         State.Range_Types (Found).Base_Kind := Base_Kind;
         State.Range_Types (Found).Low_Value := Low_Value;
         State.Range_Types (Found).High_Value := High_Value;
         Range_Id := Found;
         return;
      end if;

      if State.Range_Type_Count >= Max_Range_Types then
         Fail (State, Node, "range type table exhausted");
         return;
      end if;

      State.Range_Type_Count := State.Range_Type_Count + 1;
      Range_Id := State.Range_Type_Count;
      State.Range_Types (Range_Id).Active := True;
      State.Range_Types (Range_Id).Name_Len := Wanted'Length;
      State.Range_Types (Range_Id).Name (1 .. Wanted'Length) := Wanted;
      State.Range_Types (Range_Id).Base_Kind := Base_Kind;
      State.Range_Types (Range_Id).Low_Value := Low_Value;
      State.Range_Types (Range_Id).High_Value := High_Value;
   end Register_Range_Type;

   procedure Register_Struct_Type
     (State     : in out Emitter_State;
      Node      : Node_Index;
      Name      : String;
      Struct_Id : out Natural)
   is
      Wanted : constant String := Normalize_Name (Name);
      Found  : constant Natural := Find_Struct_Type (State, Name);
   begin
      Struct_Id := 0;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "struct name is empty or too long");
         return;
      end if;

      if Found /= 0 then
         Struct_Id := Found;
         return;
      end if;

      if State.Struct_Count >= Max_Structs then
         Fail (State, Node, "struct table exhausted");
         return;
      end if;

      State.Struct_Count := State.Struct_Count + 1;
      Struct_Id := State.Struct_Count;
      State.Structs (Struct_Id).Active := True;
      State.Structs (Struct_Id).Name_Len := Wanted'Length;
      State.Structs (Struct_Id).Name (1 .. Wanted'Length) := Wanted;
   end Register_Struct_Type;

   function Find_Struct_Field
     (State     : Emitter_State;
      Struct_Id : Natural;
      Name      : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      if Struct_Id = 0 or else Struct_Id > State.Struct_Count then
         return 0;
      end if;

      for I in 1 .. State.Structs (Struct_Id).Field_Count loop
         if State.Structs (Struct_Id).Fields (I).Active
           and then State.Structs (Struct_Id).Fields (I).Name_Len = Wanted'Length
           and then State.Structs (Struct_Id).Fields (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Struct_Field;

   procedure Add_Struct_Field
     (State     : in out Emitter_State;
      Node      : Node_Index;
      Struct_Id : Natural;
      Name      : String;
      Kind      : Symbol_Kind;
      Range_Id  : Natural := 0)
   is
      Wanted : constant String := Normalize_Name (Name);
      Field  : Natural := 0;
   begin
      if Struct_Id = 0 or else Struct_Id > State.Struct_Count then
         Fail (State, Node, "struct field registration target is invalid");
         return;
      end if;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "struct field name is empty or too long");
         return;
      end if;

      Field := Find_Struct_Field (State, Struct_Id, Name);
      if Field /= 0 then
         State.Structs (Struct_Id).Fields (Field).Kind := Kind;
         State.Structs (Struct_Id).Fields (Field).Range_Id := Range_Id;
         return;
      end if;

      if State.Structs (Struct_Id).Field_Count >= Max_Struct_Fields then
         Fail (State, Node, "struct field budget exhausted");
         return;
      end if;

      State.Structs (Struct_Id).Field_Count := State.Structs (Struct_Id).Field_Count + 1;
      Field := State.Structs (Struct_Id).Field_Count;
      State.Structs (Struct_Id).Fields (Field).Active := True;
      State.Structs (Struct_Id).Fields (Field).Name_Len := Wanted'Length;
      State.Structs (Struct_Id).Fields (Field).Name (1 .. Wanted'Length) := Wanted;
      State.Structs (Struct_Id).Fields (Field).Kind := Kind;
      State.Structs (Struct_Id).Fields (Field).Range_Id := Range_Id;
   end Add_Struct_Field;

   procedure Register_Parallel_Group
     (State     : in out Emitter_State;
      Node      : Node_Index;
      Name      : String;
      Capacity  : Natural;
      Group_Id  : out Natural)
   is
      Wanted : constant String := Normalize_Name (Name);
      Found  : constant Natural := Find_Parallel_Group (State, Name);
   begin
      Group_Id := 0;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "parallel group name is empty or too long");
         return;
      end if;

      if Capacity = 0 or else Capacity > 255 then
         Fail (State, Node, "parallel group capacity must stay within 1..255");
         return;
      end if;

      if Found /= 0 then
         State.Parallel_Groups (Found).Capacity := Capacity;
         Group_Id := Found;
         return;
      end if;

      if State.Parallel_Count >= Max_Parallel_Groups then
         Fail (State, Node, "parallel group table exhausted");
         return;
      end if;

      State.Parallel_Count := State.Parallel_Count + 1;
      Group_Id := State.Parallel_Count;
      State.Parallel_Groups (Group_Id).Active := True;
      State.Parallel_Groups (Group_Id).Name_Len := Wanted'Length;
      State.Parallel_Groups (Group_Id).Name (1 .. Wanted'Length) := Wanted;
      State.Parallel_Groups (Group_Id).Capacity := Capacity;
   end Register_Parallel_Group;

   function Find_Parallel_Field
     (State    : Emitter_State;
      Group_Id : Natural;
      Name     : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      if Group_Id = 0 or else Group_Id > State.Parallel_Count then
         return 0;
      end if;

      for I in 1 .. State.Parallel_Groups (Group_Id).Field_Count loop
         if State.Parallel_Groups (Group_Id).Fields (I).Active
           and then State.Parallel_Groups (Group_Id).Fields (I).Name_Len = Wanted'Length
           and then State.Parallel_Groups (Group_Id).Fields (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Parallel_Field;

   procedure Add_Parallel_Field
     (State          : in out Emitter_State;
      Node           : Node_Index;
      Group_Id       : Natural;
      Stored_Group   : String;
      Name           : String;
      Element_Kind   : Symbol_Kind;
      Range_Id       : Natural := 0)
   is
      Wanted       : constant String := Normalize_Name (Name);
      Field        : Natural := 0;
      Array_Kind   : Symbol_Kind := Symbol_Strict_U8_Array;
      Backing_Name : constant String := Stored_Group & "__" & Wanted;
      Backing_Sym  : Symbol_Index := 0;
   begin
      if Group_Id = 0 or else Group_Id > State.Parallel_Count then
         Fail (State, Node, "parallel field registration target is invalid");
         return;
      end if;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "parallel field name is empty or too long");
         return;
      end if;

      if Is_Byte_Scalar_Symbol (Element_Kind) then
         Array_Kind := Symbol_Strict_U8_Array;
      else
         Array_Kind := Symbol_Strict_U16_Array;
      end if;

      Register_Symbol (State, Node, Backing_Name, Array_Kind, Backing_Sym);
      if not State.Success then
         return;
      end if;

      State.Symbols (Backing_Sym).Range_Id := Range_Id;
      State.Symbols (Backing_Sym).Dim_Count := 1;
      State.Symbols (Backing_Sym).Bounds (1) := State.Parallel_Groups (Group_Id).Capacity;

      Field := Find_Parallel_Field (State, Group_Id, Name);
      if Field = 0 then
         if State.Parallel_Groups (Group_Id).Field_Count >= Max_Parallel_Fields then
            Fail (State, Node, "parallel field budget exhausted");
            return;
         end if;

         State.Parallel_Groups (Group_Id).Field_Count := State.Parallel_Groups (Group_Id).Field_Count + 1;
         Field := State.Parallel_Groups (Group_Id).Field_Count;
      end if;

      State.Parallel_Groups (Group_Id).Fields (Field).Active := True;
      State.Parallel_Groups (Group_Id).Fields (Field).Name_Len := Wanted'Length;
      State.Parallel_Groups (Group_Id).Fields (Field).Name (1 .. Wanted'Length) := Wanted;
      State.Parallel_Groups (Group_Id).Fields (Field).Kind := Element_Kind;
      State.Parallel_Groups (Group_Id).Fields (Field).Range_Id := Range_Id;
      State.Parallel_Groups (Group_Id).Fields (Field).Backing_Symbol := Backing_Sym;
   end Add_Parallel_Field;

   procedure Register_Temporal
     (State       : in out Emitter_State;
      Node        : Node_Index;
      Name        : String;
      Kind        : Symbol_Kind;
      History_Size : Natural;
      Temporal_Id : out Natural)
   is
      Wanted        : constant String := Normalize_Name (Name);
      Found         : constant Natural := Temporal_Index (State, Name);
      Base_Sym      : Symbol_Index := 0;
      Past_Sym      : Symbol_Index := 0;
      Save_Sym      : Symbol_Index := 0;
      Time_Sym      : Symbol_Index := 0;
      Time_Kind     : Symbol_Kind := Symbol_Strict_U8_Array;
      Stored_History : Natural := History_Size;
      Element_Bytes : Natural := 1;
   begin
      Temporal_Id := 0;

      if Found /= 0 then
         Temporal_Id := Found;
         return;
      end if;

      if State.Temporal_Count >= Max_Temporal_Vars then
         Fail (State, Node, "temporal variable budget exhausted");
         return;
      end if;

      if Stored_History = 0 then
         Stored_History := 1;
      elsif Stored_History > 255 then
         Fail (State, Node, "temporal HISTORY exceeds the backend limit of 255 entries");
         return;
      end if;

      Register_Symbol (State, Node, Name, Kind, Base_Sym);
      if not State.Success then
         return;
      end if;

      Register_Symbol (State, Node, Wanted & "__PAST", Kind, Past_Sym);
      if not State.Success then
         return;
      end if;

      Register_Symbol (State, Node, Wanted & "__SAVE", Kind, Save_Sym);
      if not State.Success then
         return;
      end if;

      if Is_Word_Scalar_Symbol (Kind) or else Is_String_Symbol (Kind) then
         Time_Kind := Symbol_Strict_U16_Array;
         Element_Bytes := 2;
      end if;

      Register_Symbol (State, Node, Wanted & "__TIMELINE", Time_Kind, Time_Sym);
      if not State.Success then
         return;
      end if;
      State.Symbols (Time_Sym).Dim_Count := 1;
      State.Symbols (Time_Sym).Bounds (1) := Stored_History;

      if Array_Total_Bytes (State.Symbols (Time_Sym)) > 255 then
         Fail (State, Node, "temporal HISTORY exceeds the backend's 8-bit indexed C64 limit");
         return;
      end if;

      State.Temporal_Count := State.Temporal_Count + 1;
      Temporal_Id := State.Temporal_Count;
      State.Temporals (Temporal_Id).Active := True;
      State.Temporals (Temporal_Id).Name_Len := Wanted'Length;
      State.Temporals (Temporal_Id).Name (1 .. Wanted'Length) := Wanted;
      State.Temporals (Temporal_Id).Kind := Kind;
      State.Temporals (Temporal_Id).Current := Base_Sym;
      State.Temporals (Temporal_Id).Past := Past_Sym;
      State.Temporals (Temporal_Id).Saved := Save_Sym;
      State.Temporals (Temporal_Id).Timeline := Time_Sym;
      State.Temporals (Temporal_Id).History_Size := Stored_History;
      State.Temporals (Temporal_Id).Element_Bytes := Element_Bytes;
   end Register_Temporal;

   function Find_Procedure
     (State : Emitter_State;
      Name  : String) return Natural
   is
      Wanted : constant String := Normalize_Name (Name);
   begin
      for I in 1 .. State.Procedure_Count loop
         if State.Procedures (I).Active
           and then State.Procedures (I).Name_Len = Wanted'Length
           and then State.Procedures (I).Name (1 .. Wanted'Length) = Wanted
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Procedure;

   procedure Register_Procedure
     (State         : in out Emitter_State;
      Node          : Node_Index;
      Name          : String;
      Body_Node     : Node_Index;
      Is_Function   : Boolean := False;
      Procedure_Out : out Natural)
   is
      Wanted : constant String := Normalize_Name (Name);
      Found  : constant Natural := Find_Procedure (State, Name);
   begin
      Procedure_Out := 0;

      if Wanted'Length = 0 or else Wanted'Length > Max_Name_Length then
         Fail (State, Node, "procedure name is empty or too long for the C64 backend");
         return;
      end if;

      if Found /= 0 then
         State.Procedures (Found).Body_Node := Body_Node;
         State.Procedures (Found).Is_Function := Is_Function;
         Procedure_Out := Found;
         return;
      end if;

      if State.Procedure_Count >= Max_Procedures then
         Fail (State, Node, "procedure table exhausted");
         return;
      end if;

      State.Procedure_Count := State.Procedure_Count + 1;
      Procedure_Out := State.Procedure_Count;
      State.Procedures (Procedure_Out).Active := True;
      State.Procedures (Procedure_Out).Name_Len := Wanted'Length;
      State.Procedures (Procedure_Out).Name (1 .. Wanted'Length) := Wanted;
      State.Procedures (Procedure_Out).Body_Node := Body_Node;
      State.Procedures (Procedure_Out).Is_Function := Is_Function;
   end Register_Procedure;

   function Scoped_Name
     (State          : Emitter_State;
      Procedure_Id   : Natural;
      Raw_Name       : String) return String
   is
      Proc_Name : constant String :=
        State.Procedures (Procedure_Id).Name (1 .. State.Procedures (Procedure_Id).Name_Len);
   begin
      return Proc_Name & "__" & Normalize_Name (Raw_Name);
   end Scoped_Name;

   function Find_Visible_Symbol
     (State : Emitter_State;
      Name  : String) return Symbol_Index
   is
      Scoped_Symbol : Symbol_Index := 0;
   begin
      if State.Current_Procedure /= 0 then
         Scoped_Symbol := Find_Symbol (State, Scoped_Name (State, State.Current_Procedure, Name));
         if Scoped_Symbol /= 0 then
            return Scoped_Symbol;
         end if;
      end if;

      return Find_Symbol (State, Name);
   end Find_Visible_Symbol;

   function Is_Void_Type_Lexeme (Type_Lex : String) return Boolean is
      Upper : constant String := Upper_ASCII (Type_Lex);
   begin
      return Upper = "U0" or else Upper = "NONE";
   end Is_Void_Type_Lexeme;

   function Is_Wide_Type_Lexeme (Upper : String) return Boolean is
   begin
      return Upper = "U32" or else Upper = "U64" or else Upper = "U128"
        or else Upper = "S32" or else Upper = "I32"
        or else Upper = "I64" or else Upper = "S64"
        or else Upper = "F64" or else Upper = "REAL"
        or else Upper = "PURE" or else Upper = "RATIONAL"
        or else Upper = "FLOAT2" or else Upper = "FLOAT4"
        or else Upper = "MAT2" or else Upper = "MAT3" or else Upper = "MAT4"
        or else Upper = "HW32";
   end Is_Wide_Type_Lexeme;

   procedure Resolve_Type_Info
     (State          : Emitter_State;
      Type_Lex       : String;
      U16_As_Pointer : Boolean;
      Allow_Void     : Boolean;
      Allow_Struct   : Boolean;
      Info           : out Type_Info)
   is
      Upper    : constant String := Upper_ASCII (Type_Lex);
      Range_Id : constant Natural := Find_Range_Type (State, Type_Lex);
      Struct_Id : constant Natural := Find_Struct_Type (State, Type_Lex);
   begin
      Info := (others => <>);

      if Is_Wide_Type_Lexeme (Upper) then
         return;
      end if;

      if Allow_Void and then Is_Void_Type_Lexeme (Upper) then
         Info.Found := True;
         Info.Is_Void := True;
         return;
      elsif Upper = "U8" or else Upper = "BOOL" or else Upper = "BOOLEAN" then
         Info.Found := True;
         Info.Kind := Symbol_U8;
         return;
      elsif Upper = "HW8" then
         Info.Found := True;
         Info.Kind := Symbol_HW8;
         return;
      elsif Upper = "I8" or else Upper = "S8" then
         Info.Found := True;
         Info.Kind := Symbol_U8;
         return;
      elsif Upper = "U16" then
         Info.Found := True;
         Info.Kind := (if U16_As_Pointer then Symbol_Pointer16 else Symbol_U16);
         return;
      elsif Upper = "HW16" then
         Info.Found := True;
         Info.Kind := Symbol_HW16;
         return;
      elsif Upper = "I16" or else Upper = "S16" then
         Info.Found := True;
         Info.Kind := Symbol_U16;
         return;
      elsif Upper = "STRING" or else Upper = "BINARY" then
         Info.Found := True;
         Info.Kind := Symbol_String;
         return;
      elsif Range_Id /= 0 then
         Info.Found := True;
         Info.Kind := State.Range_Types (Range_Id).Base_Kind;
         Info.Range_Id := Range_Id;
         return;
      elsif Allow_Struct and then Struct_Id /= 0 then
         Info.Found := True;
         Info.Is_Struct := True;
         Info.Struct_Id := Struct_Id;
         return;
      end if;
   end Resolve_Type_Info;

   function Parse_Integer_Lexeme
     (Lexeme : String;
      Value  : out Integer) return Boolean
     with SPARK_Mode => Off
   is
      Upper : constant String := Upper_ASCII (Lexeme);
      Acc      : Integer := 0;
      Digit    : Integer := 0;
      Start    : Natural := 0;
      Base     : Positive := 10;
      Negative : Boolean := False;
   begin
      Value := 0;

      if Upper = "TRUE" then
         Value := 1;
         return True;
      elsif Upper = "FALSE" then
         Value := 0;
         return True;
      elsif Upper'Length = 0 then
         return False;
      end if;

      Start := Upper'First;
      if Upper (Start) = '-' then
         Negative := True;
         Start := Start + 1;
      elsif Upper (Start) = '+' then
         Start := Start + 1;
      end if;

      if Start > Upper'Last then
         return False;
      end if;

      if Upper (Start) = '$' then
         Base := 16;
         Start := Start + 1;
      elsif Upper (Start) = '%' then
         Base := 2;
         Start := Start + 1;
      elsif Upper (Start) = '&'
        and then Start < Upper'Last
        and then Upper (Start + 1) = 'O'
      then
         Base := 8;
         Start := Start + 2;
      else
         Base := 10;
      end if;

      if Start > Upper'Last then
         return False;
      end if;

      for I in Start .. Upper'Last loop
         if Upper (I) = '_' then
            null;
         else
            case Base is
               when 16 =>
                  if Upper (I) in '0' .. '9' then
                     Digit := Character'Pos (Upper (I)) - Character'Pos ('0');
                  elsif Upper (I) in 'A' .. 'F' then
                     Digit := 10 + Character'Pos (Upper (I)) - Character'Pos ('A');
                  else
                     return False;
                  end if;

               when 10 =>
                  if Upper (I) not in '0' .. '9' then
                     return False;
                  end if;
                  Digit := Character'Pos (Upper (I)) - Character'Pos ('0');

               when 8 =>
                  if Upper (I) not in '0' .. '7' then
                     return False;
                  end if;
                  Digit := Character'Pos (Upper (I)) - Character'Pos ('0');

               when others =>
                  if Upper (I) = '0' then
                     Digit := 0;
                  elsif Upper (I) = '1' then
                     Digit := 1;
                  else
                     return False;
                  end if;
            end case;

            Acc := (Acc * Base) + Digit;
         end if;
      end loop;

      if Negative then
         Value := -Acc;
      else
         Value := Acc;
      end if;
      return True;
   end Parse_Integer_Lexeme;

   function Evaluate_Static_Expr
     (State     : Emitter_State;
      Expr_Node : Node_Index;
      Value     : out Integer) return Boolean
     with SPARK_Mode => Off
   is
      Left_Value  : Integer := 0;
      Right_Value : Integer := 0;
      Literal_Value : Integer := 0;
      Tok_Kind    : Token_Kind := TOK_ERROR;
   begin
      Value := 0;

      if Expr_Node = 0 then
         return False;
      end if;

        case Tree (Expr_Node).Kind is
           when AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
            if Parse_Integer_Lexeme (Node_Lexeme (Expr_Node), Literal_Value) then
               Value := Literal_Value;
               return True;
            else
               return False;
            end if;

         when AST_True =>
            Value := 1;
            return True;

         when AST_False =>
            Value := 0;
            return True;

         when AST_Const_Ref =>
            return Lookup_Const (State, Node_Lexeme (Expr_Node), Value);

         when AST_Var_Expr =>
            if Tree (Expr_Node).Left_Child /= 0 then
               return False;
            else
               return Lookup_Const (State, Node_Lexeme (Expr_Node), Value);
            end if;

         when AST_Unary_Minus =>
            if Evaluate_Static_Expr (State, Tree (Expr_Node).Left_Child, Left_Value) then
               Value := -Left_Value;
               return True;
            else
               return False;
            end if;

         when AST_BinOp =>
            if Tree (Expr_Node).Token_Index = 0 then
               return False;
            end if;

            Tok_Kind := Tokens (Tree (Expr_Node).Token_Index).Kind;
            if not Evaluate_Static_Expr (State, Tree (Expr_Node).Left_Child, Left_Value)
              or else not Evaluate_Static_Expr (State, Tree (Expr_Node).Right_Child, Right_Value)
            then
               return False;
            end if;

            case Tok_Kind is
               when TOK_PLUS =>
                  Value := Left_Value + Right_Value;
                  return True;

               when TOK_MINUS =>
                  Value := Left_Value - Right_Value;
                  return True;

               when TOK_MUL =>
                  Value := Left_Value * Right_Value;
                  return True;

               when TOK_DIV =>
                  if Right_Value = 0 then
                     return False;
                  else
                     Value := Left_Value / Right_Value;
                     return True;
                  end if;

               when TOK_MOD =>
                  if Right_Value = 0 then
                     return False;
                  else
                     Value := Left_Value mod Right_Value;
                     return True;
                  end if;

               when TOK_OR =>
                  Value := Bitwise_Or (Left_Value, Right_Value);
                  return True;

               when TOK_XOR =>
                  Value := Bitwise_Xor (Left_Value, Right_Value);
                  return True;

               when TOK_AND =>
                  Value := Bitwise_And (Left_Value, Right_Value);
                  return True;

               when others =>
                  return False;
            end case;

         when others =>
            return False;
      end case;
   end Evaluate_Static_Expr;

   function Parse_Integer_Expr
     (State     : Emitter_State;
      Expr_Node : Node_Index;
      Value     : out Natural) return Boolean
     with SPARK_Mode => Off
   is
      Signed_Value : Integer := 0;
   begin
      if Evaluate_Static_Expr (State, Expr_Node, Signed_Value)
        and then Signed_Value >= 0
      then
         Value := Natural (Signed_Value);
         return True;
      else
         Value := 0;
         return False;
      end if;
   end Parse_Integer_Expr;

   function Type_Kind_From_Lexeme
     (Type_Lex : String;
      Found    : out Boolean) return Symbol_Kind
   is
      Upper : constant String := Upper_ASCII (Type_Lex);
   begin
      Found := True;

      if Upper = "U8"
        or else Upper = "BOOL" or else Upper = "BOOLEAN"
      then
         return Symbol_U8;
      elsif Upper = "HW8" then
         return Symbol_HW8;
      elsif Upper = "I8" or else Upper = "S8" then
         return Symbol_U8;
      elsif Upper = "U16" then
         return Symbol_U16;
      elsif Upper = "HW16" then
         return Symbol_HW16;
      elsif Upper = "I16" or else Upper = "S16" then
         return Symbol_U16;
      elsif Upper = "STRING" or else Upper = "BINARY" then
         return Symbol_String;
      else
         Found := False;
         return Symbol_U8;
      end if;
   end Type_Kind_From_Lexeme;

   function Type_Kind_From_Let
     (Let_Node : Node_Index;
      Found    : out Boolean) return Symbol_Kind
     with SPARK_Mode => Off
   is
   begin
      if Tree (Let_Node).Token_Index > 0 then
         return Type_Kind_From_Lexeme
           (Token_Lexeme (Tree (Let_Node).Token_Index), Found);
      else
         Found := False;
         return Symbol_U8;
      end if;
   end Type_Kind_From_Let;

   function Is_Var_Node (Node : Node_Index) return Boolean is
   begin
      return Node > 0 and then Tree (Node).Kind = AST_Var_Expr;
   end Is_Var_Node;

   function Is_Indexed_Var_Node (Node : Node_Index) return Boolean is
   begin
      return Is_Var_Node (Node) and then Tree (Node).Left_Child /= 0;
   end Is_Indexed_Var_Node;

   function Expr_Is_String
     (State : Emitter_State;
      Node  : Node_Index) return Boolean
   is
      Symbol     : Symbol_Index := 0;
      Member     : Member_Access_Record := (others => <>);
      Temporal_Id : Natural := 0;
      Probe_State : Emitter_State := State;
   begin
      if Node = 0 then
         return False;
      end if;

      case Tree (Node).Kind is
         when AST_String_Expr =>
            return True;

         when AST_Var_Expr =>
            if Tree (Node).Left_Child /= 0 then
               return False;
            end if;

            Temporal_Id := Temporal_Index (State, Node_Lexeme (Node));
            if Temporal_Id /= 0 then
               return Is_String_Symbol (State.Temporals (Temporal_Id).Kind);
            end if;

            Symbol := Find_Visible_Symbol (State, Node_Lexeme (Node));
            return Symbol /= 0 and then Is_String_Symbol (State.Symbols (Symbol).Kind);

         when AST_Temporal_Ref =>
            if Tree (Node).Left_Child /= 0 and then Is_Var_Node (Tree (Node).Left_Child) then
               Temporal_Id := Temporal_Index (State, Node_Lexeme (Tree (Node).Left_Child));
               return Temporal_Id /= 0
                 and then Is_String_Symbol (State.Temporals (Temporal_Id).Kind);
            end if;
            return False;

         when AST_Member_Expr =>
            Analyze_Member_Access (Probe_State, Node, Member);
            return Probe_State.Success
              and then Member.Kind = Member_Struct_Field
              and then Member.Symbol /= 0
              and then Is_String_Symbol (Probe_State.Symbols (Member.Symbol).Kind);

         when AST_File_Read | AST_Readline_Stmt | AST_Str_Left | AST_Str_Right |
              AST_Str_Mid | AST_Str_Concat | AST_TypeOf_Expr =>
            return True;

         when AST_Func_Call =>
            declare
               Routine_Id  : Natural := 0;
               Member_Name : Node_Index := 0;
               Module_Name : Node_Index := 0;
            begin
               if Tree (Node).Left_Child /= 0
                 and then Tree (Tree (Node).Left_Child).Kind = AST_Member_Expr
               then
                  Member_Name := Tree (Tree (Node).Left_Child).Right_Child;
                  Module_Name := Tree (Tree (Node).Left_Child).Left_Child;
                  if Member_Name /= 0 and then Is_Var_Node (Member_Name) then
                     Routine_Id := Find_Procedure (State, Node_Lexeme (Member_Name));
                  end if;

                  if Routine_Id = 0 and then Member_Name /= 0 and then Module_Name /= 0 then
                     Routine_Id :=
                       Find_Procedure
                         (State,
                          Qualify_Member_Name
                            (Node_Lexeme (Module_Name),
                             Node_Lexeme (Member_Name)));
                  end if;
               elsif Tree (Node).Left_Child /= 0 then
                  Routine_Id := Find_Procedure (State, Node_Lexeme (Tree (Node).Left_Child));
               end if;

               return Routine_Id /= 0
                  and then Is_String_Symbol (State.Procedures (Routine_Id).Return_Kind);
            end;

         when others =>
            return False;
      end case;
   end Expr_Is_String;

   function Expr_Is_Word
     (State : Emitter_State;
      Node  : Node_Index) return Boolean
   is
      Symbol      : Symbol_Index := 0;
      Member      : Member_Access_Record := (others => <>);
      Temporal_Id : Natural := 0;
      Value       : Natural := 0;
      Routine_Id  : Natural := 0;
      Type_Found  : Boolean := False;
      Probe_State : Emitter_State := State;
   begin
      if Node = 0 or else Expr_Is_String (State, Node) then
         return False;
      end if;

      if Parse_Integer_Expr (State, Node, Value) then
         return Value > 255;
      end if;

      case Tree (Node).Kind is
         when AST_Peek_Expr | AST_Deref_Expr | AST_AddressOf =>
            return True;

         when AST_Var_Expr =>
            if Tree (Node).Left_Child /= 0 then
               Analyze_Array_Access (Probe_State, Node, Member.Element);
               return Probe_State.Success
                  and then Member.Element.Symbol /= 0
                  and then Is_U16_Array_Symbol (Probe_State.Symbols (Member.Element.Symbol).Kind);
            end if;

            Temporal_Id := Temporal_Index (State, Node_Lexeme (Node));
            if Temporal_Id /= 0 then
               return Is_Word_Scalar_Symbol (State.Temporals (Temporal_Id).Kind);
            end if;

            Symbol := Find_Visible_Symbol (State, Node_Lexeme (Node));
            return Symbol /= 0 and then Is_Word_Scalar_Symbol (State.Symbols (Symbol).Kind);

         when AST_Member_Expr =>
            Analyze_Member_Access (Probe_State, Node, Member);
            return Probe_State.Success
              and then ((Member.Kind = Member_Struct_Field
                  and then Member.Symbol /= 0
                  and then Is_Word_Scalar_Symbol (Probe_State.Symbols (Member.Symbol).Kind))
                or else (Member.Kind = Member_Parallel_Field
                  and then Member.Element.Symbol /= 0
                  and then Is_U16_Array_Symbol (Probe_State.Symbols (Member.Element.Symbol).Kind)));

         when AST_Func_Call =>
            if Tree (Node).Left_Child /= 0
              and then Tree (Tree (Node).Left_Child).Kind = AST_Member_Expr
            then
               declare
                  Member_Name : constant Node_Index := Tree (Tree (Node).Left_Child).Right_Child;
                  Module_Name : constant Node_Index := Tree (Tree (Node).Left_Child).Left_Child;
               begin
                  if Member_Name /= 0 and then Is_Var_Node (Member_Name) then
                     Routine_Id := Find_Procedure (State, Node_Lexeme (Member_Name));
                  end if;

                  if Routine_Id = 0 and then Member_Name /= 0 and then Module_Name /= 0 then
                     Routine_Id :=
                       Find_Procedure
                         (State,
                          Qualify_Member_Name
                            (Node_Lexeme (Module_Name),
                             Node_Lexeme (Member_Name)));
                  end if;
               end;
            elsif Tree (Node).Left_Child /= 0 then
               Routine_Id := Find_Procedure (State, Node_Lexeme (Tree (Node).Left_Child));
            end if;

            return Routine_Id /= 0
              and then Is_Word_Scalar_Symbol (State.Procedures (Routine_Id).Return_Kind);

         when AST_Cast_Expr =>
            if Tree (Node).Token_Index > 0 then
               declare
                  Cast_Kind : constant Symbol_Kind :=
                    Type_Kind_From_Lexeme (Token_Lexeme (Tree (Node).Token_Index), Type_Found);
               begin
                  return Type_Found and then Is_Word_Scalar_Symbol (Cast_Kind);
               end;
            end if;
            return False;

         when AST_Find_Query =>
            return Logic_Query_Is_Find (Node);

         when AST_BinOp =>
            if Tree (Node).Token_Index = 0 then
               return False;
            elsif Tokens (Tree (Node).Token_Index).Kind in
              TOK_PLUS | TOK_MINUS | TOK_OR | TOK_XOR | TOK_AND | TOK_MUL | TOK_DIV
            then
               return Expr_Is_Word (State, Tree (Node).Left_Child)
                 or else Expr_Is_Word (State, Tree (Node).Right_Child);
            else
               return False;
            end if;

         when AST_Temporal_Ref =>
            if Tree (Node).Left_Child /= 0 and then Is_Var_Node (Tree (Node).Left_Child) then
               Temporal_Id := Temporal_Index (State, Node_Lexeme (Tree (Node).Left_Child));
               return Temporal_Id /= 0
                 and then Is_Word_Scalar_Symbol (State.Temporals (Temporal_Id).Kind);
            end if;
            return False;

         when others =>
            return False;
      end case;
   end Expr_Is_Word;

   procedure Analyze_Array_Access
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Element : out Array_Access)
   is
      Symbol      : Symbol_Index := 0;
      Index_1_Val : Natural := 0;
      Index_2_Val : Natural := 0;
      Visible_Max : Natural := 0;
   begin
      Element := (others => <>);

      if not Is_Indexed_Var_Node (Node) then
         Fail (State, Node, "indexed array access expected");
         return;
      end if;

      Symbol := Find_Visible_Symbol (State, Node_Lexeme (Node));
      if Symbol = 0 then
         Fail (State, Node, "array target is not declared");
         return;
      end if;

      if not Is_Array_Symbol (State.Symbols (Symbol).Kind) then
         Fail (State, Node, "indexed access requires a STRICT or SLIDE array");
         return;
      end if;

      Element.Symbol := Symbol;
      Element.Index_1 := Tree (Node).Left_Child;

      if Element.Index_1 /= 0 then
         Element.Index_2 := Tree (Element.Index_1).Next_Sibling;
      end if;

      if Element.Index_2 /= 0 and then Tree (Element.Index_2).Next_Sibling /= 0 then
         Fail (State, Node, "C64 backend supports at most two STRICT indexes");
         return;
      end if;

      if State.Symbols (Symbol).Kind in Symbol_Slide_U8_Array | Symbol_Slide_U16_Array then
         if Element.Index_1 = 0 or else Element.Index_2 /= 0 then
            Fail (State, Node, "SLIDE arrays use exactly one index");
            return;
         end if;

         Visible_Max := Array_Visible_Length (State.Symbols (Symbol));
      if Parse_Integer_Expr (State, Element.Index_1, Index_1_Val) then
            if Index_1_Val < 1 or else Index_1_Val > Visible_Max then
               Fail (State, Node, "SLIDE index is outside the active C64 window");
               return;
            end if;
         end if;
      elsif State.Symbols (Symbol).Dim_Count = 1 then
         if Element.Index_1 = 0 or else Element.Index_2 /= 0 then
            Fail (State, Node, "STRICT array rank does not match index count");
            return;
         end if;

         if Parse_Integer_Expr (State, Element.Index_1, Index_1_Val) then
            if Index_1_Val < 1 or else Index_1_Val > State.Symbols (Symbol).Bounds (1) then
               Fail (State, Node, "STRICT array index is outside the declared bound");
               return;
            end if;
         end if;
      elsif State.Symbols (Symbol).Dim_Count = 2 then
         if Element.Index_1 = 0 or else Element.Index_2 = 0 then
            Fail (State, Node, "two-dimensional STRICT arrays require two indexes");
            return;
         end if;

         if Parse_Integer_Expr (State, Element.Index_1, Index_1_Val) then
            if Index_1_Val < 1 or else Index_1_Val > State.Symbols (Symbol).Bounds (1) then
               Fail (State, Node, "STRICT row index is outside the declared bound");
               return;
            end if;
         end if;

         if Parse_Integer_Expr (State, Element.Index_2, Index_2_Val) then
            if Index_2_Val < 1 or else Index_2_Val > State.Symbols (Symbol).Bounds (2) then
               Fail (State, Node, "STRICT column index is outside the declared bound");
               return;
            end if;
         end if;
      else
         Fail (State, Node, "unsupported STRICT/SLIDE array shape");
         return;
      end if;
   end Analyze_Array_Access;

   procedure Analyze_Member_Access
     (State  : in out Emitter_State;
      Node   : Node_Index;
      Result : out Member_Access_Record)
   is
      Base_Node     : constant Node_Index := Tree (Node).Left_Child;
      Field_Node    : constant Node_Index := Tree (Node).Right_Child;
      Base_Symbol   : Symbol_Index := 0;
      Struct_Field  : Natural := 0;
      Parallel_Field : Natural := 0;
      Field_Symbol  : Symbol_Index := 0;
      Stored_Name   : String (1 .. (Max_Name_Length * 2) + 2) := (others => ' ');
      Stored_Len    : Natural := 0;
   begin
      Result := (others => <>);

      if Node = 0 or else Tree (Node).Kind /= AST_Member_Expr then
         Fail (State, Node, "member access expected");
         return;
      end if;

      if not Is_Var_Node (Field_Node) or else Is_Indexed_Var_Node (Field_Node) then
         Fail (State, Node, "member access requires a simple field name");
         return;
      end if;

      if not Is_Var_Node (Base_Node) then
         Fail (State, Node, "member access base must be a declared variable or parallel slot");
         return;
      end if;

      Base_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Base_Node));
      if Base_Symbol = 0 then
         Fail (State, Node, "member access base is not declared");
         return;
      end if;

      if State.Symbols (Base_Symbol).Kind = Symbol_Struct_Instance then
         Struct_Field := Find_Struct_Field (State, State.Symbols (Base_Symbol).Struct_Id, Node_Lexeme (Field_Node));
         if Struct_Field = 0 then
            Fail (State, Node, "struct field is not declared");
            return;
         end if;

         declare
            Base_Name : constant String := Symbol_Stored_Name (State, Base_Symbol);
            Field_Name : constant String := Normalize_Name (Node_Lexeme (Field_Node));
         begin
            Stored_Len := Base_Name'Length + 2 + Field_Name'Length;
            Stored_Name (1 .. Base_Name'Length) := Base_Name;
            Stored_Name (Base_Name'Length + 1 .. Base_Name'Length + 2) := "__";
            Stored_Name (Base_Name'Length + 3 .. Stored_Len) := Field_Name;
         end;

         Field_Symbol := Find_Symbol (State, Stored_Name (1 .. Stored_Len));
         if Field_Symbol = 0 then
            Fail (State, Node, "struct field storage was not registered");
            return;
         end if;

         Result.Kind := Member_Struct_Field;
         Result.Symbol := Field_Symbol;
         Result.Field_Range := State.Symbols (Field_Symbol).Range_Id;
         return;
      elsif State.Symbols (Base_Symbol).Kind = Symbol_Parallel_Group then
         if not Is_Indexed_Var_Node (Base_Node) then
            Fail (State, Node, "parallel field access requires group[index].field");
            return;
         end if;

         if Tree (Tree (Base_Node).Left_Child).Next_Sibling /= 0 then
            Fail (State, Node, "parallel field access currently supports one index");
            return;
         end if;

         Parallel_Field := Find_Parallel_Field (State, State.Symbols (Base_Symbol).Parallel_Id, Node_Lexeme (Field_Node));
         if Parallel_Field = 0 then
            Fail (State, Node, "parallel field is not declared");
            return;
         end if;

         Result.Kind := Member_Parallel_Field;
         Result.Element.Symbol :=
           State.Parallel_Groups (State.Symbols (Base_Symbol).Parallel_Id).Fields (Parallel_Field).Backing_Symbol;
         Result.Element.Index_1 := Tree (Base_Node).Left_Child;
         Result.Field_Range := State.Parallel_Groups (State.Symbols (Base_Symbol).Parallel_Id).Fields (Parallel_Field).Range_Id;
         return;
      end if;

      Fail (State, Node, "member access currently supports struct variables and parallel groups only");
   end Analyze_Member_Access;

   procedure Analyze_Address_Source
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Address : out Address_Source)
   is
      Value  : Natural := 0;
      Symbol : Symbol_Index := 0;
   begin
      Address := (others => <>);

      if Parse_Integer_Expr (State, Node, Value) then
         if Value > 65_535 then
            Fail (State, Node, "address expression exceeds 16-bit address space");
            return;
         end if;

         Address.Kind := Address_Absolute;
         Address.Absolute_Value := Value;
         return;
      end if;

      if Is_Var_Node (Node) then
         Symbol := Find_Visible_Symbol (State, Node_Lexeme (Node));
         if Symbol = 0 then
            Fail (State, Node, "address source variable is not declared");
            return;
         end if;

         if not Is_Word_Scalar_Symbol (State.Symbols (Symbol).Kind)
           and then not Is_String_Symbol (State.Symbols (Symbol).Kind)
         then
            Fail (State, Node, "address source variable must be a 16-bit scalar or string/binary pointer");
            return;
         end if;

         Address.Kind := Address_Pointer;
         Address.Pointer := Symbol;
         return;
      end if;

      Fail (State, Node, "unsupported C64 address expression");
   end Analyze_Address_Source;

   procedure Analyze_Byte_Source
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Source  : out Byte_Source)
   is
      Value       : Natural := 0;
      Const_Value : Integer := 0;
      Symbol      : Symbol_Index := 0;
      Member      : Member_Access_Record := (others => <>);
   begin
      Source := (others => <>);

      if Parse_Integer_Expr (State, Node, Value) then
         if Value > 255 then
            Fail (State, Node, "8-bit source value exceeds 255");
            return;
         end if;

         Source.Kind := Source_Literal;
         Source.Literal_Value := Value;
         return;
      end if;

      if Is_Var_Node (Node) then
         if Is_Indexed_Var_Node (Node) then
            Analyze_Array_Access (State, Node, Source.Element);
            if not State.Success then
               return;
            end if;

            if not Is_U8_Array_Symbol (State.Symbols (Source.Element.Symbol).Kind) then
               Fail (State, Node, "only U8/BOOL STRICT or SLIDE array elements fit in an 8-bit expression");
               return;
            end if;

            Source.Kind := Source_Array_Element;
            return;
         end if;

         Symbol := Find_Visible_Symbol (State, Node_Lexeme (Node));
         if Symbol = 0 then
            if Lookup_Const (State, Node_Lexeme (Node), Const_Value) then
               Source.Kind := Source_Literal;
               Source.Literal_Value := Normalize_Byte (Const_Value);
               return;
            else
               Fail (State, Node, "byte source variable is not declared");
               return;
            end if;
         end if;

         if not Is_Byte_Scalar_Symbol (State.Symbols (Symbol).Kind) then
            Fail (State, Node, "byte source variable is not an 8-bit scalar");
            return;
         end if;

         Source.Kind := Source_Variable;
         Source.Variable := Symbol;
         return;
      end if;

      if Tree (Node).Kind = AST_Member_Expr then
         Analyze_Member_Access (State, Node, Member);
         if not State.Success then
            return;
         end if;

         case Member.Kind is
            when Member_Struct_Field =>
               if not Is_Byte_Scalar_Symbol (State.Symbols (Member.Symbol).Kind) then
                  Fail (State, Node, "member field does not fit in an 8-bit expression");
                  return;
               end if;
               Source.Kind := Source_Variable;
               Source.Variable := Member.Symbol;
               return;

            when Member_Parallel_Field =>
               if not Is_U8_Array_Symbol (State.Symbols (Member.Element.Symbol).Kind) then
                  Fail (State, Node, "parallel field does not fit in an 8-bit expression");
                  return;
               end if;
               Source.Kind := Source_Array_Element;
               Source.Element := Member.Element;
               return;

            when others =>
               null;
         end case;
      end if;

      if Tree (Node).Kind = AST_Peek_Expr or else Tree (Node).Kind = AST_Deref_Expr then
         Analyze_Address_Source (State, Tree (Node).Left_Child, Source.Address);
         if not State.Success then
            return;
         end if;

         if Source.Address.Kind = Address_Absolute then
            Source.Kind := Source_Peek_Absolute;
         else
            Source.Kind := Source_Peek_Pointer;
         end if;
         return;
      end if;

      Fail
        (State,
         Node,
         "unsupported C64 byte expression: " & Node_Kind'Image (Tree (Node).Kind));
   end Analyze_Byte_Source;

   procedure Emit_Header (State : in out Emitter_State) is
   begin
      Append_Line (State, "ORG $07FF");
      Append_Line (State, "");
      Append_Line (State, "KERNAL_CHROUT = $FFD2");
      Append_Line (State, "KERNAL_PLOT = $FFF0");
      Append_Line (State, "KERNAL_SCNKEY = $FF9F");
      Append_Line (State, "KERNAL_GETIN = $FFE4");
      Append_Line (State, "C64_CIA1_PORTA = $DC00");
      Append_Line (State, "C64_CIA1_PORTB = $DC01");
      Append_Line (State, "C64_CIA1_DDRA = $DC02");
      Append_Line (State, "C64_CIA1_DDRB = $DC03");
      Append_Line (State, "C64_CIA2_PORTA = $DD00");
      Append_Line (State, "C64_SCREEN_RAM = $8C00");
      Append_Line (State, "C64_COLOR_RAM = $D800");
      Append_Line (State, "C64_TEXT_COLOR = $0286");
      Append_Line (State, "C64_BORDER = $D020");
      Append_Line (State, "C64_BACKGROUND = $D021");
      Append_Line (State, "C64_RASTER = $D012");
      Append_Line (State, "C64_VIC_CTRL1 = $D011");
      Append_Line (State, "C64_VIC_CTRL2 = $D016");
      Append_Line (State, "C64_VIC_MEMORY = $D018");
      Append_Line (State, "C64_VIC_IRQ_STATUS = $D019");
      Append_Line (State, "C64_VIC_IRQ_ENABLE = $D01A");
      Append_Line (State, "C64_SPRITE_X_MSB = $D010");
      Append_Line (State, "C64_SPRITE_ENABLE = $D015");
      Append_Line (State, "C64_SPRITE_Y_EXPAND = $D017");
      Append_Line (State, "C64_SPRITE_PRIORITY = $D01B");
      Append_Line (State, "C64_SPRITE_MULTICOLOR = $D01C");
      Append_Line (State, "C64_SPRITE_X_EXPAND = $D01D");
      Append_Line (State, "C64_SPRITE_SPRITE_COLLIDE = $D01E");
      Append_Line (State, "C64_SPRITE_BG_COLLIDE = $D01F");
      Append_Line (State, "C64_SPRITE_MC0 = $D025");
      Append_Line (State, "C64_SPRITE_MC1 = $D026");
      Append_Line (State, "C64_SPRITE_COLOR0 = $D027");
      Append_Line (State, "C64_IRQ_VECTOR = $0314");
      Append_Line (State, "C64_SPRITE_PTR_BASE = C64_SCREEN_RAM+$03F8");
      Append_Line (State, "C64_SPRITE_DATA = $A000");
      Append_Line (State, "ZP_IO_PTR = $F7");
      Append_Line (State, "ZP_PTR0 = $FB");
      Append_Line (State, "ZP_PTR1 = $FD");
      Append_Line (State, "");
      Append_Line (State, "DW $0801");
      Append_Line (State, "DW alb_basic_end");
      Append_Line (State, "DW 10");
      Append_Line (State, "DB $9E");
      Append_Line (State, "DB ""2061"",0");
      Append_Line (State, "alb_basic_end:");
      Append_Line (State, "DW 0");
      Append_Line (State, "");
   end Emit_Header;

   procedure Emit_Zero_Page_Aliases (State : in out Emitter_State) is
   begin
      for I in 1 .. State.Symbol_Count loop
         if State.Symbols (I).Active
           and then Is_Pointer_Symbol (State.Symbols (I).Kind)
         then
            Append_Line
              (State,
               Symbol_Name (State, I)
               & " = "
               & Byte_Hex
                   (Zero_Page_Base (State.Symbols (I).Zero_Page_Register)));
         end if;
      end loop;
      Append_Line (State, "");
   end Emit_Zero_Page_Aliases;

   function Address_Hex (Value : Natural) return String;

   procedure Emit_Array_Index_Y_Load
     (State   : in out Emitter_State;
      Element : Array_Access)
   is
      Symbol        : constant Symbol_Record := State.Symbols (Element.Symbol);
      Element_Bytes : constant Natural := Array_Element_Bytes (Symbol.Kind);
      Value_1       : Natural := 0;
      Value_2       : Natural := 0;
      Offset        : Natural := 0;
      Index_Symbol  : Symbol_Index := 0;
   begin
      if Symbol.Dim_Count = 2 then
         if not Parse_Integer_Expr (State, Element.Index_1, Value_1)
           or else not Parse_Integer_Expr (State, Element.Index_2, Value_2)
         then
            Fail
              (State,
               Element.Index_1,
               "two-dimensional STRICT arrays currently require literal indexes on C64");
            return;
         end if;

         Offset :=
           (((Value_1 - 1) * Symbol.Bounds (2)) + (Value_2 - 1)) * Element_Bytes;

         if Offset > 255 then
            Fail (State, Element.Index_1, "STRICT array byte offset exceeds 8-bit indexed reach");
            return;
         end if;

         Append_Line (State, "    LDY #" & Byte_Hex (Offset));
         return;
      end if;

      if Parse_Integer_Expr (State, Element.Index_1, Value_1) then
         Offset := (Value_1 - 1) * Element_Bytes;
         if Offset > 255 then
            Fail (State, Element.Index_1, "array byte offset exceeds 8-bit indexed reach");
            return;
         end if;

         Append_Line (State, "    LDY #" & Byte_Hex (Offset));
         return;
      end if;

      if not Is_Var_Node (Element.Index_1) or else Is_Indexed_Var_Node (Element.Index_1) then
         Fail (State, Element.Index_1, "array indexes must be literal or an 8-bit scalar variable");
         return;
      end if;

      Index_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Element.Index_1));
      if Index_Symbol = 0 then
         Fail (State, Element.Index_1, "array index variable must be a declared scalar");
         return;
      elsif Is_Byte_Scalar_Symbol (State.Symbols (Index_Symbol).Kind) then
         Append_Line (State, "    LDY " & Symbol_Name (State, Index_Symbol));
         Append_Line (State, "    DEY");

         if Element_Bytes = 2 then
            Append_Line (State, "    TYA");
            Append_Line (State, "    ASL A");
            Append_Line (State, "    TAY");
         end if;
         return;
      elsif Is_Word_Scalar_Symbol (State.Symbols (Index_Symbol).Kind) then
         Append_Line (State, "    LDA " & Symbol_Name (State, Index_Symbol));
         Append_Line (State, "    SEC");
         Append_Line (State, "    SBC #$01");
         if Element_Bytes = 2 then
            Append_Line (State, "    ASL A");
         end if;
         Append_Line (State, "    TAY");
         return;
      else
         Fail (State, Element.Index_1, "array index variable must be an 8-bit or 16-bit scalar");
         return;
      end if;
   end Emit_Array_Index_Y_Load;

   procedure Emit_U8_Load
     (State  : in out Emitter_State;
      Source : Byte_Source)
   is
      Ptr_Name : constant String := "ZP_IO_PTR";
   begin
      case Source.Kind is
         when Source_Literal =>
            Append_Line (State, "    LDA #" & Byte_Hex (Source.Literal_Value));

         when Source_Variable =>
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, Source.Variable));

         when Source_Peek_Absolute =>
            Append_Line
              (State,
               "    LDA " & Address_Hex (Source.Address.Absolute_Value));

         when Source_Peek_Pointer =>
            Emit_Index_Y_Load (State);
            if State.Symbols (Source.Address.Pointer).Kind = Symbol_Pointer16 then
               Append_Line
                 (State,
                  "    LDA (" & Symbol_Name (State, Source.Address.Pointer) & "),Y");
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Source.Address.Pointer));
               Append_Line (State, "    STA " & Ptr_Name);
               Append_Line (State, "    LDA " & Symbol_Name (State, Source.Address.Pointer) & "+1");
               Append_Line (State, "    STA " & Ptr_Name & "+1");
               Append_Line (State, "    LDA (" & Ptr_Name & "),Y");
            end if;

         when Source_Array_Element =>
            Emit_Array_Index_Y_Load (State, Source.Element);
            if not State.Success then
               return;
            end if;
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, Source.Element.Symbol) & ",Y");
      end case;
   end Emit_U8_Load;

   function Address_Hex (Value : Natural) return String is
      V : constant Natural := Value mod 65_536;
   begin
      return
        "$"
        & Hex_Digit ((V / 4_096) mod 16)
        & Hex_Digit ((V / 256) mod 16)
        & Hex_Digit ((V / 16) mod 16)
        & Hex_Digit (V mod 16);
   end Address_Hex;

   procedure Emit_Poke_Store
     (State   : in out Emitter_State;
      Address : Address_Source)
   is
      Ptr_Name : constant String := "ZP_IO_PTR";
   begin
      case Address.Kind is
         when Address_Absolute =>
            Append_Line
              (State,
               "    STA " & Address_Hex (Address.Absolute_Value));

         when Address_Pointer =>
            Emit_Index_Y_Load (State);
            if State.Symbols (Address.Pointer).Kind = Symbol_Pointer16 then
               Append_Line
                 (State,
                  "    STA (" & Symbol_Name (State, Address.Pointer) & "),Y");
            else
               Append_Line (State, "    PHA");
               Append_Line (State, "    LDA " & Symbol_Name (State, Address.Pointer));
               Append_Line (State, "    STA " & Ptr_Name);
               Append_Line (State, "    LDA " & Symbol_Name (State, Address.Pointer) & "+1");
               Append_Line (State, "    STA " & Ptr_Name & "+1");
               Append_Line (State, "    PLA");
               Append_Line (State, "    STA (" & Ptr_Name & "),Y");
            end if;
      end case;
   end Emit_Poke_Store;

   procedure Emit_Compare_With_Source
     (State  : in out Emitter_State;
      Source : Byte_Source)
   is
      Ptr_Name : constant String := "ZP_IO_PTR";
   begin
      case Source.Kind is
         when Source_Literal =>
            Append_Line (State, "    CMP #" & Byte_Hex (Source.Literal_Value));

         when Source_Variable =>
            Append_Line
              (State,
               "    CMP " & Symbol_Name (State, Source.Variable));

         when Source_Peek_Absolute =>
            Append_Line
              (State,
               "    CMP " & Address_Hex (Source.Address.Absolute_Value));

         when Source_Peek_Pointer =>
            Emit_Index_Y_Load (State);
            if State.Symbols (Source.Address.Pointer).Kind = Symbol_Pointer16 then
               Append_Line
                 (State,
                  "    CMP (" & Symbol_Name (State, Source.Address.Pointer) & "),Y");
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Source.Address.Pointer));
               Append_Line (State, "    STA " & Ptr_Name);
               Append_Line (State, "    LDA " & Symbol_Name (State, Source.Address.Pointer) & "+1");
               Append_Line (State, "    STA " & Ptr_Name & "+1");
               Append_Line (State, "    CMP (" & Ptr_Name & "),Y");
            end if;

         when Source_Array_Element =>
            Emit_Array_Index_Y_Load (State, Source.Element);
            if not State.Success then
               return;
            end if;
            Append_Line
              (State,
               "    CMP " & Symbol_Name (State, Source.Element.Symbol) & ",Y");
      end case;
   end Emit_Compare_With_Source;

   procedure Emit_Add_Sub_With_Source
     (State        : in out Emitter_State;
      Source       : Byte_Source;
      Is_Subtract  : Boolean)
   is
      Op_Name : constant String := (if Is_Subtract then "SBC " else "ADC ");
      Ptr_Name : constant String := "ZP_IO_PTR";
   begin
      case Source.Kind is
         when Source_Literal =>
            Append_Line (State, "    " & Op_Name & "#" & Byte_Hex (Source.Literal_Value));

         when Source_Variable =>
            Append_Line
              (State,
               "    " & Op_Name & Symbol_Name (State, Source.Variable));

         when Source_Peek_Absolute =>
            Append_Line
              (State,
               "    " & Op_Name & Address_Hex (Source.Address.Absolute_Value));

         when Source_Peek_Pointer =>
            Emit_Index_Y_Load (State);
            if State.Symbols (Source.Address.Pointer).Kind = Symbol_Pointer16 then
               Append_Line
                 (State,
                  "    " & Op_Name & "(" & Symbol_Name (State, Source.Address.Pointer) & "),Y");
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Source.Address.Pointer));
               Append_Line (State, "    STA " & Ptr_Name);
               Append_Line (State, "    LDA " & Symbol_Name (State, Source.Address.Pointer) & "+1");
               Append_Line (State, "    STA " & Ptr_Name & "+1");
               Append_Line (State, "    " & Op_Name & "(" & Ptr_Name & "),Y");
            end if;

         when Source_Array_Element =>
            Emit_Array_Index_Y_Load (State, Source.Element);
            if not State.Success then
               return;
            end if;
            Append_Line
              (State,
               "    " & Op_Name & Symbol_Name (State, Source.Element.Symbol) & ",Y");
      end case;
   end Emit_Add_Sub_With_Source;

   procedure Emit_Routine_Call
     (State        : in out Emitter_State;
      Target_Node  : Node_Index;
      Call_Node    : Node_Index;
      Routine_Id   : out Natural;
      Expect_Value : Boolean;
      Success_Out  : out Boolean)
   is
      type Node_List is array (Positive range 1 .. Max_Procedure_Params) of Node_Index;

      Name_Node    : Node_Index := 0;
      Arg_Node     : Node_Index := 0;
      Param_Symbol : Symbol_Index := 0;
      Actual_Args  : Node_List := (others => 0);
   begin
      Routine_Id := 0;
      Success_Out := False;

      if Target_Node = 0 then
         Fail (State, Call_Node, "routine call requires a target");
         return;
      end if;

      if Tree (Target_Node).Kind = AST_Func_Call then
         Name_Node := Tree (Target_Node).Left_Child;
         Arg_Node := Tree (Target_Node).Right_Child;
         if Arg_Node /= 0 and then Tree (Arg_Node).Kind = AST_Arg_List then
            Arg_Node := Tree (Arg_Node).Left_Child;
         end if;
      else
         Name_Node := Target_Node;
      end if;

      if Tree (Name_Node).Kind = AST_Member_Expr then
         if Tree (Name_Node).Right_Child = 0
           or else not Is_Var_Node (Tree (Name_Node).Right_Child)
         then
            Fail (State, Call_Node, "qualified routine call is malformed");
            return;
         end if;

         Routine_Id := Find_Procedure (State, Node_Lexeme (Tree (Name_Node).Right_Child));
         if Routine_Id = 0 then
            Routine_Id :=
              Find_Procedure
                (State,
                 Qualify_Member_Name
                   (Node_Lexeme (Tree (Name_Node).Left_Child),
                    Node_Lexeme (Tree (Name_Node).Right_Child)));
         end if;
      elsif Is_Var_Node (Name_Node) and then not Is_Indexed_Var_Node (Name_Node) then
         Routine_Id := Find_Procedure (State, Node_Lexeme (Name_Node));
      else
         Fail (State, Call_Node, "C64 routine calls currently support only direct or module-qualified names");
         return;
      end if;

      if Routine_Id = 0 then
         Fail (State, Call_Node, "called routine is not declared");
         return;
      end if;

      if Expect_Value and then State.Procedures (Routine_Id).Return_Void then
         Fail (State, Call_Node, "void routine cannot be used as an expression");
         return;
      end if;

      for I in 1 .. State.Procedures (Routine_Id).Param_Count loop
         if Arg_Node = 0 then
            Fail (State, Call_Node, "routine call is missing one or more arguments");
            return;
         end if;

         Actual_Args (I) := Arg_Node;
         Param_Symbol := State.Procedures (Routine_Id).Param_Symbols (I);
         if State.Procedures (Routine_Id).Param_Is_Out (I) then
            if not Is_Var_Node (Arg_Node) and then Tree (Arg_Node).Kind /= AST_Member_Expr then
               Fail (State, Arg_Node, "OUT parameters require an assignable target");
               return;
            end if;

            if Is_Byte_Scalar_Symbol (State.Symbols (Param_Symbol).Kind) then
               Append_Line (State, "    LDA #$00");
               Append_Line (State, "    STA " & Symbol_Name (State, Param_Symbol));
            else
               Append_Line (State, "    LDA #$00");
               Append_Line (State, "    STA " & Symbol_Name (State, Param_Symbol));
               Append_Line (State, "    STA " & Symbol_Name (State, Param_Symbol) & "+1");
            end if;
         elsif Is_Byte_Scalar_Symbol (State.Symbols (Param_Symbol).Kind) then
            Emit_Byte_Expr (State, Arg_Node);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA " & Symbol_Name (State, Param_Symbol));
         elsif Is_String_Symbol (State.Symbols (Param_Symbol).Kind) then
            Emit_String_Address (State, Arg_Node);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA " & Symbol_Name (State, Param_Symbol));
            Append_Line (State, "    STX " & Symbol_Name (State, Param_Symbol) & "+1");
         else
            Emit_Pointer_Assignment (State, Param_Symbol, Arg_Node);
            if not State.Success then
               return;
            end if;
         end if;

         Arg_Node := Tree (Arg_Node).Next_Sibling;
      end loop;

      if Arg_Node /= 0 then
         Fail (State, Call_Node, "routine call provides more arguments than declared");
         return;
      end if;

      Append_Line (State, "    JSR " & Procedure_Label (State, Routine_Id));
      for I in 1 .. State.Procedures (Routine_Id).Param_Count loop
         if State.Procedures (Routine_Id).Param_Is_Out (I) then
            Emit_Copy_Symbol_To_Target
              (State,
               State.Procedures (Routine_Id).Param_Symbols (I),
               Actual_Args (I));
            if not State.Success then
               return;
            end if;
         end if;
      end loop;
      Success_Out := State.Success;
   end Emit_Routine_Call;

   procedure Emit_Load_Temporal_Byte
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Temporal_Id    : Natural := 0;
      Selector       : Token_Kind := TOK_ERROR;
      Use_Current_Id : Natural := 0;
      Done_Id        : Natural := 0;
   begin
      if Tree (Node).Left_Child = 0 or else not Is_Var_Node (Tree (Node).Left_Child) then
         Fail (State, Node, "temporal reference requires a declared base variable");
         return;
      end if;

      Temporal_Id := Temporal_Index (State, Node_Lexeme (Tree (Node).Left_Child));
      if Temporal_Id = 0 then
         Fail (State, Node, "temporal variable is not declared");
         return;
      end if;

      if Tree (Node).Token_Index > 0 then
         Selector := Tokens (Tree (Node).Token_Index).Kind;
      end if;

      case Selector is
         when Tok_Past =>
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Past));

         when Tok_Timeline =>
            Append_Line
              (State,
               "    LDA #<" & Symbol_Name (State, State.Temporals (Temporal_Id).Timeline));

         when Tok_Future =>
            Reserve_Label_Id (State, Use_Current_Id);
            Reserve_Label_Id (State, Done_Id);
            Append_Line (State, "    LDA " & Temporal_Count_Label (Temporal_Id));
            Append_Line
              (State,
               "    CMP #" & Byte_Hex (State.Temporals (Temporal_Id).History_Size));
            Append_Line
              (State,
               "    BCC alb_temporal_future_now_" & Decimal_Image (Use_Current_Id));
            Append_Line (State, "    LDY " & Temporal_Head_Label (Temporal_Id));
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Timeline) & ",Y");
            Append_Line
              (State,
               "    JMP alb_temporal_future_done_" & Decimal_Image (Done_Id));
            Append_Line
              (State,
               "alb_temporal_future_now_" & Decimal_Image (Use_Current_Id) & ":");
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Current));
            Append_Line
              (State,
               "alb_temporal_future_done_" & Decimal_Image (Done_Id) & ":");

         when others =>
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Current));
      end case;
   end Emit_Load_Temporal_Byte;

   procedure Emit_Load_Temporal_Word
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Temporal_Id    : Natural := 0;
      Selector       : Token_Kind := TOK_ERROR;
      Use_Current_Id : Natural := 0;
      Done_Id        : Natural := 0;
   begin
      if Tree (Node).Left_Child = 0 or else not Is_Var_Node (Tree (Node).Left_Child) then
         Fail (State, Node, "temporal reference requires a declared base variable");
         return;
      end if;

      Temporal_Id := Temporal_Index (State, Node_Lexeme (Tree (Node).Left_Child));
      if Temporal_Id = 0 then
         Fail (State, Node, "temporal variable is not declared");
         return;
      end if;

      if Tree (Node).Token_Index > 0 then
         Selector := Tokens (Tree (Node).Token_Index).Kind;
      end if;

      case Selector is
         when Tok_Past =>
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Past));
            Append_Line
              (State,
               "    LDX " & Symbol_Name (State, State.Temporals (Temporal_Id).Past) & "+1");

         when Tok_Timeline =>
            Append_Line
              (State,
               "    LDA #<" & Symbol_Name (State, State.Temporals (Temporal_Id).Timeline));
            Append_Line
              (State,
               "    LDX #>" & Symbol_Name (State, State.Temporals (Temporal_Id).Timeline));

         when Tok_Future =>
            Reserve_Label_Id (State, Use_Current_Id);
            Reserve_Label_Id (State, Done_Id);
            Append_Line (State, "    LDA " & Temporal_Count_Label (Temporal_Id));
            Append_Line
              (State,
               "    CMP #" & Byte_Hex (State.Temporals (Temporal_Id).History_Size));
            Append_Line
              (State,
               "    BCC alb_temporal_future_word_now_" & Decimal_Image (Use_Current_Id));
            Append_Line (State, "    LDY " & Temporal_Head_Label (Temporal_Id));
            Append_Line (State, "    TYA");
            Append_Line (State, "    ASL A");
            Append_Line (State, "    TAY");
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Timeline) & ",Y");
            Append_Line (State, "    PHA");
            Append_Line (State, "    INY");
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Timeline) & ",Y");
            Append_Line (State, "    TAX");
            Append_Line (State, "    PLA");
            Append_Line
              (State,
               "    JMP alb_temporal_future_word_done_" & Decimal_Image (Done_Id));
            Append_Line
              (State,
               "alb_temporal_future_word_now_" & Decimal_Image (Use_Current_Id) & ":");
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Current));
            Append_Line
              (State,
               "    LDX " & Symbol_Name (State, State.Temporals (Temporal_Id).Current) & "+1");
            Append_Line
              (State,
               "alb_temporal_future_word_done_" & Decimal_Image (Done_Id) & ":");

         when others =>
            Append_Line
              (State,
               "    LDA " & Symbol_Name (State, State.Temporals (Temporal_Id).Current));
            Append_Line
              (State,
               "    LDX " & Symbol_Name (State, State.Temporals (Temporal_Id).Current) & "+1");
      end case;
   end Emit_Load_Temporal_Word;

   procedure Emit_Load_Temporal_String
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      Emit_Load_Temporal_Word (State, Node);
   end Emit_Load_Temporal_String;

   procedure Emit_Word_Expr
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Static_Val : Integer := 0;
      Static_RHS : Integer := 0;
      Symbol     : Symbol_Index := 0;
      Element    : Array_Access := (others => <>);
      Member     : Member_Access_Record := (others => <>);
      Routine_Id : Natural := 0;
      Call_Ok    : Boolean := False;
      Selector   : Token_Kind := TOK_ERROR;
      Type_Found : Boolean := False;
   begin
      if Evaluate_Static_Expr (State, Node, Static_Val) then
         Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Normalize_Word (Static_Val))));
         Append_Line (State, "    LDX #" & Byte_Hex (High_Byte (Normalize_Word (Static_Val))));
         return;
      end if;

      if Tree (Node).Kind = AST_Inline_Asm_Expr then
         if State.Native_ASM_State /= ASM_Mode_Active then
            Fail (State, Node, "INLINE ASM requires an active ENABLEASM family block");
         else
            Append_Line (State, ASM_Block_Body (Node));
         end if;
         return;
      end if;

      if Tree (Node).Kind = AST_Temporal_Ref then
         Emit_Load_Temporal_Word (State, Node);
         return;
      end if;

      if Tree (Node).Kind = AST_Cast_Expr then
         if Tree (Node).Token_Index > 0
           and then Is_Word_Scalar_Symbol
                (Type_Kind_From_Lexeme
                   (Token_Lexeme (Tree (Node).Token_Index), Type_Found))
         then
            Emit_Word_Expr (State, Tree (Node).Left_Child);
         else
            Emit_Byte_Expr (State, Tree (Node).Left_Child);
            if State.Success then
               Append_Line (State, "    LDX #$00");
            end if;
         end if;
         return;
      end if;

      if Tree (Node).Kind = AST_BinOp and then Tree (Node).Token_Index > 0 then
         case Tokens (Tree (Node).Token_Index).Kind is
            when TOK_PLUS | TOK_MINUS | TOK_OR | TOK_XOR | TOK_AND =>
               Emit_Word_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_tmp_u16_lo");
               Append_Line (State, "    STX alb_tmp_u16_hi");
               Emit_Word_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_expr_tmp0");
               Append_Line (State, "    STX alb_expr_tmp1");

               case Tokens (Tree (Node).Token_Index).Kind is
                  when TOK_PLUS =>
                     Append_Line (State, "    LDA alb_tmp_u16_lo");
                     Append_Line (State, "    CLC");
                     Append_Line (State, "    ADC alb_expr_tmp0");
                     Append_Line (State, "    PHA");
                     Append_Line (State, "    LDA alb_tmp_u16_hi");
                     Append_Line (State, "    ADC alb_expr_tmp1");
                     Append_Line (State, "    TAX");
                     Append_Line (State, "    PLA");
                     return;

                  when TOK_MINUS =>
                     Append_Line (State, "    LDA alb_tmp_u16_lo");
                     Append_Line (State, "    SEC");
                     Append_Line (State, "    SBC alb_expr_tmp0");
                     Append_Line (State, "    PHA");
                     Append_Line (State, "    LDA alb_tmp_u16_hi");
                     Append_Line (State, "    SBC alb_expr_tmp1");
                     Append_Line (State, "    TAX");
                     Append_Line (State, "    PLA");
                     return;

                  when TOK_OR =>
                     Append_Line (State, "    LDA alb_tmp_u16_lo");
                     Append_Line (State, "    ORA alb_expr_tmp0");
                     Append_Line (State, "    PHA");
                     Append_Line (State, "    LDA alb_tmp_u16_hi");
                     Append_Line (State, "    ORA alb_expr_tmp1");
                     Append_Line (State, "    TAX");
                     Append_Line (State, "    PLA");
                     return;

                  when TOK_XOR =>
                     Append_Line (State, "    LDA alb_tmp_u16_lo");
                     Append_Line (State, "    EOR alb_expr_tmp0");
                     Append_Line (State, "    PHA");
                     Append_Line (State, "    LDA alb_tmp_u16_hi");
                     Append_Line (State, "    EOR alb_expr_tmp1");
                     Append_Line (State, "    TAX");
                     Append_Line (State, "    PLA");
                     return;

                  when TOK_AND =>
                     Append_Line (State, "    LDA alb_tmp_u16_lo");
                     Append_Line (State, "    AND alb_expr_tmp0");
                     Append_Line (State, "    PHA");
                     Append_Line (State, "    LDA alb_tmp_u16_hi");
                     Append_Line (State, "    AND alb_expr_tmp1");
                     Append_Line (State, "    TAX");
                     Append_Line (State, "    PLA");
                     return;

                  when others =>
                     null;
               end case;

            when TOK_MUL | TOK_DIV | TOK_MOD =>
               if Evaluate_Static_Expr (State, Tree (Node).Right_Child, Static_RHS) then
                  declare
                     Norm_RHS    : Natural := Natural (Normalize_Word (Static_RHS));
                     Reduced_RHS : Natural := Norm_RHS;
                     Shift_Count : Natural := 0;
                     Low_Mask    : Natural := 0;
                     High_Mask   : Natural := 0;
                  begin
                     while Reduced_RHS > 1 and then Reduced_RHS mod 2 = 0 loop
                        Reduced_RHS := Reduced_RHS / 2;
                        Shift_Count := Shift_Count + 1;
                     end loop;

                     if Norm_RHS = 0 then
                        Append_Line (State, "    LDA #$00");
                        Append_Line (State, "    LDX #$00");
                        return;
                     elsif Norm_RHS = 1 then
                        if Tokens (Tree (Node).Token_Index).Kind = TOK_MOD then
                           Append_Line (State, "    LDA #$00");
                           Append_Line (State, "    LDX #$00");
                        else
                           Emit_Word_Expr (State, Tree (Node).Left_Child);
                        end if;
                        return;
                     elsif Reduced_RHS = 1 then
                        Emit_Word_Expr (State, Tree (Node).Left_Child);
                        if not State.Success then
                           return;
                        end if;

                        case Tokens (Tree (Node).Token_Index).Kind is
                           when TOK_MUL =>
                              Append_Line (State, "    STA alb_tmp_u16_lo");
                              Append_Line (State, "    STX alb_tmp_u16_hi");
                              for I in 1 .. Shift_Count loop
                                 Append_Line (State, "    ASL alb_tmp_u16_lo");
                                 Append_Line (State, "    ROL alb_tmp_u16_hi");
                              end loop;
                              Append_Line (State, "    LDA alb_tmp_u16_lo");
                              Append_Line (State, "    LDX alb_tmp_u16_hi");
                              return;

                           when TOK_DIV =>
                              Append_Line (State, "    STA alb_tmp_u16_lo");
                              Append_Line (State, "    STX alb_tmp_u16_hi");
                              for I in 1 .. Shift_Count loop
                                 Append_Line (State, "    LSR alb_tmp_u16_hi");
                                 Append_Line (State, "    ROR alb_tmp_u16_lo");
                              end loop;
                              Append_Line (State, "    LDA alb_tmp_u16_lo");
                              Append_Line (State, "    LDX alb_tmp_u16_hi");
                              return;

                           when others =>
                              Low_Mask := (Norm_RHS - 1) mod 256;
                              High_Mask := (Norm_RHS - 1) / 256;
                              Append_Line (State, "    AND #" & Byte_Hex (Low_Mask));
                              Append_Line (State, "    PHA");
                              Append_Line (State, "    TXA");
                              Append_Line (State, "    AND #" & Byte_Hex (High_Mask));
                              Append_Line (State, "    TAX");
                              Append_Line (State, "    PLA");
                              return;
                        end case;
                     end if;
                  end;
               end if;

               Emit_Word_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_math_w_lhs");
               Append_Line (State, "    STX alb_math_w_lhs+1");
               Emit_Word_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_math_w_rhs");
               Append_Line (State, "    STX alb_math_w_rhs+1");
               case Tokens (Tree (Node).Token_Index).Kind is
                  when TOK_MUL =>
                     Append_Line (State, "    JSR alb_mul_u16");
                  when TOK_DIV =>
                     Append_Line (State, "    JSR alb_div_u16");
                  when others =>
                     Append_Line (State, "    JSR alb_mod_u16");
               end case;
               return;

            when others =>
               null;
         end case;
      end if;

      case Tree (Node).Kind is
         when AST_SCREEN_WIDTH | AST_VIRTUAL_WIDTH =>
            Append_Line (State, "    LDA alb_screen_width");
            Append_Line (State, "    LDX alb_screen_width+1");
            return;

         when AST_SCREEN_HEIGHT | AST_VIRTUAL_HEIGHT =>
            Append_Line (State, "    LDA alb_screen_height");
            Append_Line (State, "    LDX alb_screen_height+1");
            return;

         when AST_File_Open =>
            Emit_String_Address (State, Tree (Node).Left_Child);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA ZP_IO_PTR");
            Append_Line (State, "    STX ZP_IO_PTR+1");
            Emit_String_Address (State, Tree (Node).Right_Child);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA alb_file_mode_ptr");
            Append_Line (State, "    STX alb_file_mode_ptr+1");
            Append_Line (State, "    JSR alb_file_open");
            Append_Line (State, "    LDX #$00");
            return;

         when AST_File_Len | AST_File_Seek =>
            Append_Line (State, "    LDA #$00");
            Append_Line (State, "    LDX #$00");
            return;

         when AST_Key_State | AST_READ_PIXEL =>
            Emit_Byte_Expr (State, Node);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    LDX #$00");
            return;

         when AST_Mouse_X | AST_Mouse_Y | AST_Mouse_Wheel |
              AST_Mouse_Click | AST_VMouse_X | AST_VMouse_y |
              AST_SYS_RENDERER =>
            Append_Line (State, "    LDA #$00");
            Append_Line (State, "    LDX #$00");
            return;

         when others =>
            null;
      end case;

      if Tree (Node).Kind = AST_Find_Query and then Logic_Query_Is_Find (Node) then
         Emit_Logic_Query (State, Node, Store_Value => True);
         return;
      end if;

      if Tree (Node).Kind = AST_Func_Call then
         Emit_Routine_Call (State, Node, Node, Routine_Id, True, Call_Ok);
         if not State.Success or else not Call_Ok then
            return;
         end if;

         if Is_Byte_Scalar_Symbol (State.Procedures (Routine_Id).Return_Kind) then
            Append_Line (State, "    LDA " & Symbol_Name (State, State.Procedures (Routine_Id).Return_Symbol));
            Append_Line (State, "    LDX #$00");
         else
            Append_Line (State, "    LDA " & Symbol_Name (State, State.Procedures (Routine_Id).Return_Symbol));
            Append_Line (State, "    LDX " & Symbol_Name (State, State.Procedures (Routine_Id).Return_Symbol) & "+1");
         end if;
         return;
      end if;

      if Tree (Node).Kind = AST_Member_Expr then
         Analyze_Member_Access (State, Node, Member);
         if not State.Success then
            return;
         end if;

         if Member.Kind = Member_Struct_Field then
            if Is_Byte_Scalar_Symbol (State.Symbols (Member.Symbol).Kind) then
               Append_Line (State, "    LDA " & Symbol_Name (State, Member.Symbol));
               Append_Line (State, "    LDX #$00");
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Member.Symbol));
               Append_Line (State, "    LDX " & Symbol_Name (State, Member.Symbol) & "+1");
            end if;
            return;
         elsif Member.Kind = Member_Parallel_Field then
            Emit_Array_Index_Y_Load (State, Member.Element);
            if not State.Success then
               return;
            end if;

            if Is_U8_Array_Symbol (State.Symbols (Member.Element.Symbol).Kind) then
               Append_Line (State, "    LDA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
               Append_Line (State, "    LDX #$00");
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
               Append_Line (State, "    INY");
               Append_Line (State, "    LDX " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
            end if;
            return;
         end if;
      end if;

      if Is_Var_Node (Node) then
         if Is_Indexed_Var_Node (Node) then
            Analyze_Array_Access (State, Node, Element);
            if not State.Success then
               return;
            end if;

            Emit_Array_Index_Y_Load (State, Element);
            if not State.Success then
               return;
            end if;

            if Is_U8_Array_Symbol (State.Symbols (Element.Symbol).Kind) then
               Append_Line (State, "    LDA " & Symbol_Name (State, Element.Symbol) & ",Y");
               Append_Line (State, "    LDX #$00");
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Element.Symbol) & ",Y");
               Append_Line (State, "    INY");
               Append_Line (State, "    LDX " & Symbol_Name (State, Element.Symbol) & ",Y");
            end if;
            return;
         end if;

         Symbol := Find_Visible_Symbol (State, Node_Lexeme (Node));
         if Symbol = 0 then
            Fail (State, Node, "word source variable is not declared");
            return;
         end if;

         if Is_Byte_Scalar_Symbol (State.Symbols (Symbol).Kind) then
            Append_Line (State, "    LDA " & Symbol_Name (State, Symbol));
            Append_Line (State, "    LDX #$00");
         elsif Is_Word_Scalar_Symbol (State.Symbols (Symbol).Kind) then
            Append_Line (State, "    LDA " & Symbol_Name (State, Symbol));
            Append_Line (State, "    LDX " & Symbol_Name (State, Symbol) & "+1");
         else
            Fail (State, Node, "word expression requires a scalar, array element, member, or function call");
         end if;
         return;
      end if;

      Emit_Byte_Expr (State, Node);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    LDX #$00");
   end Emit_Word_Expr;

   procedure Emit_Byte_Expr
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Source      : Byte_Source := (others => <>);
      Static_Val  : Integer := 0;
      Op_Token    : Natural := 0;
      Op_Kind     : Token_Kind := TOK_ERROR;
      Routine_Id  : Natural := 0;
      Call_Ok     : Boolean := False;
      False_Id    : Natural := 0;
      Done_Id     : Natural := 0;
   begin
      if Evaluate_Static_Expr (State, Node, Static_Val) then
         Append_Line (State, "    LDA #" & Byte_Hex (Normalize_Byte (Static_Val)));
         return;
      end if;

      if Tree (Node).Kind = AST_Inline_Asm_Expr then
         if State.Native_ASM_State /= ASM_Mode_Active then
            Fail (State, Node, "INLINE ASM requires an active ENABLEASM family block");
         else
            Append_Line (State, ASM_Block_Body (Node));
         end if;
         return;
      end if;

      if Tree (Node).Kind = AST_Temporal_Ref then
         Emit_Load_Temporal_Byte (State, Node);
         return;
      end if;

      if Tree (Node).Kind = AST_Cast_Expr then
         Emit_Word_Expr (State, Tree (Node).Left_Child);
         return;
      end if;

      case Tree (Node).Kind is
         when AST_Find_Query | AST_Query | AST_Knows_Query =>
            Emit_Logic_Query (State, Node, Bool_Only => True);
            return;

         when AST_Key_State =>
            if Tree (Node).Left_Child = 0 then
               Append_Line (State, "    LDA #$00");
               return;
            end if;

            Emit_Byte_Expr (State, Tree (Node).Left_Child);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    TAX");
            Append_Line (State, "    LDA alb_key_state,X");
            Append_Line (State, "    ORA alb_key_latch,X");
            return;

         when AST_READ_PIXEL =>
            if Tree (Node).Left_Child = 0 then
               Append_Line (State, "    LDA #$00");
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store
              (State, Nth_Arg (Tree (Node).Left_Child, 1), "alb_graphics_x");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store
              (State, Nth_Arg (Tree (Node).Left_Child, 2), "alb_graphics_y");
            if not State.Success then
               return;
            end if;

            Append_Line (State, "    JSR alb_read_cell_color");
            return;

         when AST_SCREEN_WIDTH | AST_VIRTUAL_WIDTH =>
            Append_Line (State, "    LDA alb_screen_width");
            return;

         when AST_SCREEN_HEIGHT | AST_VIRTUAL_HEIGHT =>
            Append_Line (State, "    LDA alb_screen_height");
            return;

         when AST_Mouse_X | AST_Mouse_Y | AST_Mouse_Wheel | AST_Mouse_Click |
              AST_VMouse_X | AST_VMouse_y |
              AST_File_Open | AST_File_Len | AST_File_Seek | AST_SYS_RENDERER =>
            Append_Line (State, "    LDA #$00");
            return;

         when others =>
            null;
      end case;

      if Tree (Node).Kind = AST_Func_Call then
         Emit_Routine_Call (State, Node, Node, Routine_Id, True, Call_Ok);
         if not State.Success or else not Call_Ok then
            return;
         end if;

         if not Is_Byte_Scalar_Symbol (State.Procedures (Routine_Id).Return_Kind) then
            Fail (State, Node, "word-returning function cannot be used in an 8-bit expression");
            return;
         end if;

         Append_Line
           (State,
            "    LDA " & Symbol_Name (State, State.Procedures (Routine_Id).Return_Symbol));
         return;
      end if;

      if Tree (Node).Kind = AST_Unary_Minus then
         Emit_Byte_Expr (State, Tree (Node).Left_Child);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    EOR #$FF");
         Append_Line (State, "    CLC");
         Append_Line (State, "    ADC #$01");
         return;
      end if;

      if Tree (Node).Kind = AST_BinOp then
         Op_Token := Tree (Node).Token_Index;
         if Op_Token > 0 then
            Op_Kind := Tokens (Op_Token).Kind;
         end if;

         if Op_Kind in TOK_EQUAL | TOK_ASSIGN | TOK_NOT_EQUAL |
                       TOK_LESS | TOK_GREATER_EQUAL | TOK_GREATER |
                       TOK_LESS_EQUAL | TOK_AND | TOK_OR
         then
            Reserve_Label_Id (State, False_Id);
            Reserve_Label_Id (State, Done_Id);
            Emit_Condition_False_Branch
              (State,
               Node,
               "alb_bool_false_" & Decimal_Image (False_Id));
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    LDA #$01");
            Append_Line (State, "    JMP alb_bool_done_" & Decimal_Image (Done_Id));
            Append_Line (State, "alb_bool_false_" & Decimal_Image (False_Id) & ":");
            Append_Line (State, "    LDA #$00");
            Append_Line (State, "alb_bool_done_" & Decimal_Image (Done_Id) & ":");
            return;
         end if;

         case Op_Kind is
            when TOK_PLUS =>
               Emit_Byte_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_expr_tmp0");
               Emit_Byte_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    CLC");
               Append_Line (State, "    ADC alb_expr_tmp0");
               return;

            when TOK_MINUS =>
               Emit_Byte_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_expr_tmp0");
               Emit_Byte_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_expr_tmp1");
               Append_Line (State, "    LDA alb_expr_tmp0");
               Append_Line (State, "    SEC");
               Append_Line (State, "    SBC alb_expr_tmp1");
               return;

            when TOK_OR =>
               Emit_Byte_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_expr_tmp0");
               Emit_Byte_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    ORA alb_expr_tmp0");
               return;

            when TOK_XOR =>
               Emit_Byte_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_expr_tmp0");
               Emit_Byte_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    EOR alb_expr_tmp0");
               return;

            when TOK_AND =>
               Emit_Byte_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_expr_tmp0");
               Emit_Byte_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    AND alb_expr_tmp0");
               return;

            when TOK_MUL | TOK_DIV | TOK_MOD =>
               Emit_Byte_Expr (State, Tree (Node).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_math_lhs");
               Emit_Byte_Expr (State, Tree (Node).Right_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_math_rhs");
               case Op_Kind is
                  when TOK_MUL =>
                     Append_Line (State, "    JSR alb_mul_u8");
                  when TOK_DIV =>
                     Append_Line (State, "    JSR alb_div_u8");
                  when others =>
                     Append_Line (State, "    JSR alb_mod_u8");
               end case;
               return;

            when others =>
               null;
         end case;
      end if;

      Analyze_Byte_Source (State, Node, Source);
      if not State.Success then
         return;
      end if;
      Emit_U8_Load (State, Source);
   end Emit_Byte_Expr;

   function Matches_Increment_Assignment
     (State : Emitter_State;
      Node  : Node_Index;
      Symbol : out Symbol_Index) return Boolean
     with SPARK_Mode => Off
   is
      Target_Node : constant Node_Index := Tree (Node).Left_Child;
      RHS_Node    : constant Node_Index := Tree (Node).Right_Child;
      Left_Node   : Node_Index := 0;
      Right_Node  : Node_Index := 0;
      Value       : Natural := 0;
      Op_Token    : Natural := 0;
   begin
      Symbol := 0;

      if not Is_Var_Node (Target_Node) or else RHS_Node = 0 then
         return False;
      end if;

      Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
      if Symbol = 0 or else not Is_Byte_Scalar_Symbol (State.Symbols (Symbol).Kind) then
         return False;
      end if;

      if Tree (RHS_Node).Kind /= AST_BinOp then
         return False;
      end if;

      Left_Node := Tree (RHS_Node).Left_Child;
      Right_Node := Tree (RHS_Node).Right_Child;
      Op_Token := Tree (RHS_Node).Token_Index;

      return
        Op_Token > 0
        and then Tokens (Op_Token).Kind = TOK_PLUS
        and then Is_Var_Node (Left_Node)
        and then Normalize_Name (Node_Lexeme (Left_Node)) =
                 Normalize_Name (Node_Lexeme (Target_Node))
        and then Parse_Integer_Expr (State, Right_Node, Value)
        and then Value = 1;
   end Matches_Increment_Assignment;

   procedure Emit_Poke_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Address_Node : constant Node_Index := Tree (Node).Left_Child;
      Value_Node   : constant Node_Index := Tree (Node).Right_Child;
      Address      : Address_Source := (others => <>);
   begin
      Analyze_Address_Source (State, Address_Node, Address);
      if not State.Success then
         return;
      end if;

      Emit_Byte_Expr (State, Value_Node);
      if not State.Success then
         return;
      end if;
      Emit_Poke_Store (State, Address);
   end Emit_Poke_Stmt;

   procedure Emit_U8_Assignment
     (State         : in out Emitter_State;
      Target_Symbol : Symbol_Index;
      RHS_Node      : Node_Index;
      Origin_Node   : Node_Index)
   is
      Increment_Symbol : Symbol_Index := 0;
   begin
      if Matches_Increment_Assignment (State, Origin_Node, Increment_Symbol) then
         Append_Line
           (State,
            "    INC " & Symbol_Name (State, Increment_Symbol));
         return;
      end if;

      Emit_Byte_Expr (State, RHS_Node);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol));
   end Emit_U8_Assignment;

   procedure Emit_Array_Assignment
     (State      : in out Emitter_State;
      Target_Node : Node_Index;
      RHS_Node    : Node_Index)
   is
      Target      : Array_Access := (others => <>);
      Target_Symbol : Symbol_Index := 0;
      Target_Name : String (1 .. Max_Name_Length + 8) := (others => ' ');
      Target_Len  : Natural := 0;
   begin
      Analyze_Array_Access (State, Target_Node, Target);
      if not State.Success then
         return;
      end if;

      Target_Symbol := Target.Symbol;
      declare
         Name : constant String := Symbol_Name (State, Target_Symbol);
      begin
         Target_Len := Name'Length;
         Target_Name (1 .. Target_Len) := Name;
      end;

      if Is_U8_Array_Symbol (State.Symbols (Target_Symbol).Kind) then
         Emit_Byte_Expr (State, RHS_Node);
         if not State.Success then
            return;
         end if;

         Emit_Array_Index_Y_Load (State, Target);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    STA " & Target_Name (1 .. Target_Len) & ",Y");
         return;
      end if;

      Emit_Word_Expr (State, RHS_Node);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA alb_tmp_u16_lo");
      Append_Line (State, "    STX alb_tmp_u16_hi");
      Emit_Array_Index_Y_Load (State, Target);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    LDA alb_tmp_u16_lo");
      Append_Line (State, "    STA " & Target_Name (1 .. Target_Len) & ",Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA alb_tmp_u16_hi");
      Append_Line (State, "    STA " & Target_Name (1 .. Target_Len) & ",Y");
   end Emit_Array_Assignment;

   procedure Emit_Pointer_Assignment
     (State         : in out Emitter_State;
      Target_Symbol : Symbol_Index;
      RHS_Node      : Node_Index)
   is
   begin
      if Expr_Is_String (State, RHS_Node) then
         Emit_String_Address (State, RHS_Node);
      else
         Emit_Word_Expr (State, RHS_Node);
      end if;
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol));
      Append_Line (State, "    STX " & Symbol_Name (State, Target_Symbol) & "+1");
   end Emit_Pointer_Assignment;

   procedure Emit_Copy_Symbol_To_Target
     (State         : in out Emitter_State;
      Source_Symbol : Symbol_Index;
      Target_Node   : Node_Index)
   is
      Target_Symbol : Symbol_Index := 0;
      Member        : Member_Access_Record := (others => <>);
      Element       : Array_Access := (others => <>);
   begin
      if Target_Node = 0 then
         Fail (State, Target_Node, "assignment target is missing");
         return;
      end if;

      if Tree (Target_Node).Kind = AST_Member_Expr then
         Analyze_Member_Access (State, Target_Node, Member);
         if not State.Success then
            return;
         end if;

         if Member.Kind = Member_Struct_Field then
            if Is_Byte_Scalar_Symbol (State.Symbols (Source_Symbol).Kind) then
               Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol));
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol));
               Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol) & "+1");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol) & "+1");
            end if;
         elsif Member.Kind = Member_Parallel_Field then
            if Is_Byte_Scalar_Symbol (State.Symbols (Source_Symbol).Kind) then
               Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
               Emit_Array_Index_Y_Load (State, Member.Element);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
            else
               Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
               Append_Line (State, "    STA alb_tmp_u16_lo");
               Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol) & "+1");
               Append_Line (State, "    STA alb_tmp_u16_hi");
               Emit_Array_Index_Y_Load (State, Member.Element);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    LDA alb_tmp_u16_lo");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
               Append_Line (State, "    INY");
               Append_Line (State, "    LDA alb_tmp_u16_hi");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
            end if;
            return;
         else
            Fail (State, Target_Node, "unsupported member assignment target");
         end if;
         return;
      elsif Is_Var_Node (Target_Node) and then Is_Indexed_Var_Node (Target_Node) then
         Analyze_Array_Access (State, Target_Node, Element);
         if not State.Success then
            return;
         end if;

         if Is_Byte_Scalar_Symbol (State.Symbols (Source_Symbol).Kind) then
            Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
            Emit_Array_Index_Y_Load (State, Element);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA " & Symbol_Name (State, Element.Symbol) & ",Y");
         else
            Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
            Append_Line (State, "    STA alb_tmp_u16_lo");
            Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol) & "+1");
            Append_Line (State, "    STA alb_tmp_u16_hi");
            Emit_Array_Index_Y_Load (State, Element);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    LDA alb_tmp_u16_lo");
            Append_Line (State, "    STA " & Symbol_Name (State, Element.Symbol) & ",Y");
            Append_Line (State, "    INY");
            Append_Line (State, "    LDA alb_tmp_u16_hi");
            Append_Line (State, "    STA " & Symbol_Name (State, Element.Symbol) & ",Y");
         end if;
         return;
      elsif not Is_Var_Node (Target_Node) then
         Fail (State, Target_Node, "OUT parameter target must be a variable, array element, or member");
         return;
      end if;

      Target_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
      if Target_Symbol = 0 then
         Fail (State, Target_Node, "assignment target is not declared");
         return;
      end if;

      if Is_Byte_Scalar_Symbol (State.Symbols (Source_Symbol).Kind) then
         Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol));
      else
         Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol));
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol));
         Append_Line (State, "    LDA " & Symbol_Name (State, Source_Symbol) & "+1");
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & "+1");
      end if;
   end Emit_Copy_Symbol_To_Target;

   procedure Emit_Clear_Target
     (State       : in out Emitter_State;
      Target_Node : Node_Index)
   is
      Target_Symbol : Symbol_Index := 0;
      Member        : Member_Access_Record := (others => <>);
      Element       : Array_Access := (others => <>);
   begin
      if Tree (Target_Node).Kind = AST_Member_Expr then
         Analyze_Member_Access (State, Target_Node, Member);
         if not State.Success then
            return;
         end if;

         if Member.Kind = Member_Struct_Field then
            if Is_Byte_Scalar_Symbol (State.Symbols (Member.Symbol).Kind) then
               Append_Line (State, "    LDA #$00");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol));
            elsif Is_String_Symbol (State.Symbols (Member.Symbol).Kind) then
               Append_Line (State, "    LDA #<alb_empty_string");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol));
               Append_Line (State, "    LDA #>alb_empty_string");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol) & "+1");
            else
               Append_Line (State, "    LDA #$00");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol));
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Symbol) & "+1");
            end if;
         elsif Member.Kind = Member_Parallel_Field then
            Emit_Array_Index_Y_Load (State, Member.Element);
            if not State.Success then
               return;
            end if;
            if Is_U8_Array_Symbol (State.Symbols (Member.Element.Symbol).Kind) then
               Append_Line (State, "    LDA #$00");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
            else
               Append_Line (State, "    LDA #$00");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
               Append_Line (State, "    INY");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
            end if;
         end if;
         return;
      elsif Is_Var_Node (Target_Node) and then Is_Indexed_Var_Node (Target_Node) then
         Analyze_Array_Access (State, Target_Node, Element);
         if not State.Success then
            return;
         end if;
         Emit_Array_Index_Y_Load (State, Element);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA " & Symbol_Name (State, Element.Symbol) & ",Y");
         if Is_U16_Array_Symbol (State.Symbols (Element.Symbol).Kind) then
            Append_Line (State, "    INY");
            Append_Line (State, "    STA " & Symbol_Name (State, Element.Symbol) & ",Y");
         end if;
         return;
      elsif not Is_Var_Node (Target_Node) then
         Fail (State, Target_Node, "target is not assignable");
         return;
      end if;

      Target_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
      if Target_Symbol = 0 then
         Fail (State, Target_Node, "target is not declared");
         return;
      elsif Is_Byte_Scalar_Symbol (State.Symbols (Target_Symbol).Kind) then
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol));
      elsif Is_String_Symbol (State.Symbols (Target_Symbol).Kind) then
         Append_Line (State, "    LDA #<alb_empty_string");
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol));
         Append_Line (State, "    LDA #>alb_empty_string");
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & "+1");
      else
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol));
         Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & "+1");
      end if;
   end Emit_Clear_Target;

   procedure Emit_Let_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Target_Node : constant Node_Index := Tree (Node).Left_Child;
      RHS_Node    : constant Node_Index := Tree (Node).Right_Child;
      Symbol      : Symbol_Index := 0;
      Existing    : Symbol_Index := 0;
      Info        : Type_Info := (others => <>);
      Member      : Member_Access_Record := (others => <>);
   begin
      if Tree (Target_Node).Kind = AST_Member_Expr then
         if Tree (Node).Token_Index > 0 then
            Fail (State, Node, "typed member declarations are not supported");
            return;
         end if;

         if RHS_Node = 0 then
            Fail (State, Node, "member assignment requires a right-hand side");
            return;
         end if;

         Analyze_Member_Access (State, Target_Node, Member);
         if not State.Success then
            return;
         end if;

         if Member.Kind = Member_Struct_Field then
            if Is_Byte_Scalar_Symbol (State.Symbols (Member.Symbol).Kind) then
               Emit_U8_Assignment (State, Member.Symbol, RHS_Node, Node);
            else
               Emit_Pointer_Assignment (State, Member.Symbol, RHS_Node);
            end if;
            return;
         elsif Member.Kind = Member_Parallel_Field then
            if Is_U8_Array_Symbol (State.Symbols (Member.Element.Symbol).Kind) then
               Emit_Byte_Expr (State, RHS_Node);
               if not State.Success then
                  return;
               end if;
               Emit_Array_Index_Y_Load (State, Member.Element);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
            else
               if Expr_Is_String (State, RHS_Node) then
                  Emit_String_Address (State, RHS_Node);
               else
                  Emit_Word_Expr (State, RHS_Node);
               end if;
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STA alb_tmp_u16_lo");
               Append_Line (State, "    STX alb_tmp_u16_hi");
               Emit_Array_Index_Y_Load (State, Member.Element);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    LDA alb_tmp_u16_lo");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
               Append_Line (State, "    INY");
               Append_Line (State, "    LDA alb_tmp_u16_hi");
               Append_Line (State, "    STA " & Symbol_Name (State, Member.Element.Symbol) & ",Y");
            end if;
            return;
         end if;

         Fail (State, Node, "unsupported member assignment target");
         return;
      end if;

      if not Is_Var_Node (Target_Node) then
         Fail (State, Node, "C64 backend only supports scalar, indexed array, or member LET targets");
         return;
      end if;

      if Is_Indexed_Var_Node (Target_Node) then
         if Tree (Node).Token_Index > 0 then
            Fail (State, Node, "STRICT and SLIDE storage must be declared separately from indexed assignment");
            return;
         end if;

         if RHS_Node = 0 then
            Fail (State, Node, "indexed array assignment requires a right-hand side");
            return;
         end if;

         Emit_Array_Assignment (State, Target_Node, RHS_Node);
         return;
      end if;

      Existing := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));

      if Tree (Node).Token_Index > 0 then
         Resolve_Type_Info
           (State,
            Token_Lexeme (Tree (Node).Token_Index),
            True,
            False,
            True,
            Info);
         if not Info.Found then
            Fail (State, Node, "C64 backend only supports byte/word scalars, range aliases, and struct declarations");
            return;
         end if;

         if Info.Is_Struct then
            if Existing = 0 then
               Fail (State, Node, "struct declaration was not pre-registered");
               return;
            end if;
            Symbol := Existing;
         elsif Existing /= 0 then
            Symbol := Existing;
         else
            declare
               Stored_Name : constant String :=
                 (if State.Current_Procedure = 0
                  then Node_Lexeme (Target_Node)
                  else Scoped_Name (State, State.Current_Procedure, Node_Lexeme (Target_Node)));
            begin
               Register_Symbol (State, Node, Stored_Name, Info.Kind, Symbol);
            end;
            if not State.Success then
               return;
            end if;
            State.Symbols (Symbol).Range_Id := Info.Range_Id;
         end if;
      else
         if Existing = 0 then
            Fail (State, Node, "assignment target must be declared before use");
            return;
         end if;

         Symbol := Existing;
      end if;

      if RHS_Node = 0 then
         return;
      end if;

      if State.Symbols (Symbol).Kind = Symbol_Struct_Instance then
         Fail (State, Node, "whole-struct assignment is not supported yet");
         return;
      elsif State.Symbols (Symbol).Kind = Symbol_Parallel_Group then
         Fail (State, Node, "parallel groups are assigned through group[index].field");
         return;
      end if;

      if Is_Byte_Scalar_Symbol (State.Symbols (Symbol).Kind) then
         Emit_U8_Assignment (State, Symbol, RHS_Node, Node);
      else
         Emit_Pointer_Assignment (State, Symbol, RHS_Node);
      end if;
   end Emit_Let_Stmt;

   procedure Analyze_Increment_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index;
      Plan  : in out Loop_Plan)
   is
      Target_Node : constant Node_Index := Tree (Node).Left_Child;
      RHS_Node    : constant Node_Index := Tree (Node).Right_Child;
      Left_Node   : Node_Index := 0;
      Right_Node  : Node_Index := 0;
      Value       : Natural := 0;
      Symbol      : Symbol_Index := 0;
      Op_Token    : Natural := 0;
   begin
      if not Is_Var_Node (Target_Node) then
         Fail (State, Node, "loop assignment target must be a scalar variable");
         return;
      end if;

      if RHS_Node = 0 or else Tree (RHS_Node).Kind /= AST_BinOp then
         Fail (State, Node, "loop assignment currently supports only VAR = VAR + 1");
         return;
      end if;

      Left_Node := Tree (RHS_Node).Left_Child;
      Right_Node := Tree (RHS_Node).Right_Child;
      Op_Token := Tree (RHS_Node).Token_Index;

      if Op_Token = 0 or else Tokens (Op_Token).Kind /= TOK_PLUS then
         Fail (State, Node, "loop assignment currently supports only +1 increments");
         return;
      end if;

      if not Is_Var_Node (Left_Node)
        or else Normalize_Name (Node_Lexeme (Left_Node)) /=
                Normalize_Name (Node_Lexeme (Target_Node))
      then
         Fail (State, Node, "loop increment must use the same variable on both sides");
         return;
      end if;

      if not Parse_Integer_Expr (State, Right_Node, Value) or else Value /= 1 then
         Fail (State, Node, "loop increment must use a literal increment of 1");
         return;
      end if;

      Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
      if Symbol = 0 then
         Fail (State, Node, "loop increment target is not declared");
         return;
      end if;

      if not Is_Byte_Scalar_Symbol (State.Symbols (Symbol).Kind) then
         Fail (State, Node, "loop increment target must be an 8-bit scalar");
         return;
      end if;

      if Plan.Use_Increment then
         Fail (State, Node, "only one increment pattern is supported inside a C64 FOR loop");
         return;
      end if;

      Plan.Use_Increment := True;
      Plan.Increment_Var := Symbol;
   end Analyze_Increment_Stmt;

   procedure Analyze_Poke_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index;
      Plan  : in out Loop_Plan)
   is
      Address_Node : constant Node_Index := Tree (Node).Left_Child;
      Value_Node   : constant Node_Index := Tree (Node).Right_Child;
      Symbol       : Symbol_Index := 0;
   begin
      if not Is_Var_Node (Address_Node) then
         Fail (State, Node, "C64 FOR-loop POKE currently requires a pointer variable target");
         return;
      end if;

      Symbol := Find_Visible_Symbol (State, Node_Lexeme (Address_Node));
      if Symbol = 0 then
         Fail (State, Node, "POKE target pointer is not declared");
         return;
      end if;

      if State.Symbols (Symbol).Kind /= Symbol_Pointer16 then
         Fail (State, Node, "POKE target must be a 16-bit pointer variable");
         return;
      end if;

      if Plan.Use_Poke then
         Fail (State, Node, "only one POKE is supported inside a single C64 FOR loop");
         return;
      end if;

      Plan.Use_Poke := True;
      Plan.Poke_Target := Symbol;
      Analyze_Byte_Source (State, Value_Node, Plan.Poke_Source);
   end Analyze_Poke_Stmt;

   procedure Analyze_Loop_Body
     (State : in out Emitter_State;
      Body_Node : Node_Index;
      Plan  : in out Loop_Plan)
   is
      Curr : Node_Index := 0;
   begin
      if Body_Node = 0 then
         return;
      end if;

      if Tree (Body_Node).Kind = AST_Block_Stmt then
         Curr := Tree (Body_Node).Left_Child;
      else
         Curr := Body_Node;
      end if;

      while Curr /= 0 and then State.Success loop
         case Tree (Curr).Kind is
            when AST_Poke_Stmt =>
               Analyze_Poke_Stmt (State, Curr, Plan);

            when AST_Let_Stmt =>
               Analyze_Increment_Stmt (State, Curr, Plan);

            when others =>
               Fail (State, Curr, "unsupported statement inside C64 FOR loop body");
         end case;

         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Analyze_Loop_Body;

   procedure Emit_For_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Dummy_Node : constant Node_Index := Tree (Node).Left_Child;
      Body_Node  : constant Node_Index := Tree (Node).Right_Child;
      Start_Node : Node_Index := 0;
      End_Node   : Node_Index := 0;
      Step_Node  : Node_Index := 0;
      Loop_Symbol : Symbol_Index := 0;
      Start_Val  : Natural := 0;
      End_Val    : Natural := 0;
      Step_Val   : Natural := 1;
      Loop_Id    : Natural := 0;
      Ok_Id      : Natural := 0;
      Word_Loop  : Boolean := False;
   begin
      if Dummy_Node = 0 or else Tree (Dummy_Node).Kind /= AST_Null then
         Fail (State, Node, "malformed FOR loop header");
         return;
      end if;

      Start_Node := Tree (Dummy_Node).Left_Child;
      End_Node := Tree (Dummy_Node).Right_Child;

      if Start_Node = 0 or else End_Node = 0 then
         Fail (State, Node, "FOR loop is missing start or end bounds");
         return;
      end if;

      if Tree (End_Node).Kind = AST_Arg_List then
         End_Node := Tree (End_Node).Left_Child;
         if End_Node /= 0 then
            Step_Node := Tree (End_Node).Next_Sibling;
         end if;
      end if;

      if not Parse_Integer_Expr (State, Start_Node, Start_Val) then
         Fail (State, Start_Node, "FOR start bound must be a compile-time integer");
         return;
      end if;

      if not Parse_Integer_Expr (State, End_Node, End_Val) then
         Fail (State, End_Node, "FOR end bound must be a compile-time integer");
         return;
      end if;

      if Step_Node /= 0 then
         if not Parse_Integer_Expr (State, Step_Node, Step_Val) or else Step_Val /= 1 then
            Fail (State, Step_Node, "C64 FOR loops currently support only STEP 1");
            return;
         end if;
      end if;

      if End_Val < Start_Val then
         Fail (State, Node, "FOR bounds must count upward");
         return;
      end if;

      Loop_Symbol := Find_Visible_Symbol (State, Token_Lexeme (Tree (Node).Token_Index));
      if Loop_Symbol = 0 then
         if End_Val > 255 or else Start_Val > 255 then
            Register_Symbol
              (State,
               Node,
               Token_Lexeme (Tree (Node).Token_Index),
               Symbol_U16,
               Loop_Symbol);
         else
            Register_Symbol
              (State,
               Node,
               Token_Lexeme (Tree (Node).Token_Index),
               Symbol_U8,
               Loop_Symbol);
         end if;
         if not State.Success then
            return;
         end if;
      elsif Is_Word_Scalar_Symbol (State.Symbols (Loop_Symbol).Kind) then
         Word_Loop := True;
      elsif not Is_Byte_Scalar_Symbol (State.Symbols (Loop_Symbol).Kind) then
         Fail (State, Node, "FOR loop variable must be an 8-bit or 16-bit scalar");
         return;
      end if;

      if Word_Loop then
         if Start_Val > 65_535 or else End_Val > 65_535 then
            Fail (State, Node, "C64 FOR bounds must stay within 0..65535");
            return;
         end if;
      elsif Start_Val > 255 or else End_Val > 255 then
         Fail (State, Node, "C64 8-bit FOR bounds must stay within 0..255");
         return;
      end if;

      Reserve_Label_Id (State, Loop_Id);
      Reserve_Label_Id (State, Ok_Id);

      if Word_Loop then
         Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Start_Val)));
         Append_Line (State, "    STA " & Symbol_Name (State, Loop_Symbol));
         Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Start_Val)));
         Append_Line (State, "    STA " & Symbol_Name (State, Loop_Symbol) & "+1");
         Append_Line (State, Loop_Top_Label (Loop_Id) & ":");
         Append_Line (State, "    LDA " & Symbol_Name (State, Loop_Symbol) & "+1");
         Append_Line (State, "    CMP #" & Byte_Hex (High_Byte (End_Val)));
         Append_Line (State, "    BCC alb_loop_body_" & Decimal_Image (Ok_Id));
         Append_Line (State, "    BEQ " & Loop_Check_Lo_Label (Loop_Id));
         Append_Line (State, "    JMP " & Loop_End_Label (Loop_Id));
         Append_Line (State, Loop_Check_Lo_Label (Loop_Id) & ":");
         Append_Line (State, "    LDA " & Symbol_Name (State, Loop_Symbol));
         Append_Line (State, "    CMP #" & Byte_Hex (Low_Byte (End_Val)));
         Append_Line (State, "    BCC alb_loop_body_" & Decimal_Image (Ok_Id));
         Append_Line (State, "    BEQ alb_loop_body_" & Decimal_Image (Ok_Id));
         Append_Line (State, "    JMP " & Loop_End_Label (Loop_Id));
      else
         Append_Line (State, "    LDA #" & Byte_Hex (Start_Val));
         Append_Line (State, "    STA " & Symbol_Name (State, Loop_Symbol));
         Append_Line (State, Loop_Top_Label (Loop_Id) & ":");
         Append_Line (State, "    LDA " & Symbol_Name (State, Loop_Symbol));
         Append_Line (State, "    CMP #" & Byte_Hex (End_Val));
         Append_Line (State, "    BCC alb_loop_body_" & Decimal_Image (Ok_Id));
         Append_Line (State, "    BEQ alb_loop_body_" & Decimal_Image (Ok_Id));
         Append_Line (State, "    JMP " & Loop_End_Label (Loop_Id));
      end if;

      Append_Line (State, "alb_loop_body_" & Decimal_Image (Ok_Id) & ":");

      Push_Loop_Context (State, Loop_Id, Loop_Symbol);
      if not State.Success then
         return;
      end if;
      Emit_Node_Chain (State, Body_Node);
      Pop_Loop_Context (State);
      if not State.Success then
         return;
      end if;

         Append_Line (State, Loop_Continue_Label (Loop_Id) & ":");
      if Word_Loop then
         Append_Line (State, "    INC " & Symbol_Name (State, Loop_Symbol));
         Append_Line (State, "    BNE " & Loop_Continue_Skip_Hi_Label (Loop_Id));
         Append_Line (State, "    INC " & Symbol_Name (State, Loop_Symbol) & "+1");
         Append_Line (State, Loop_Continue_Skip_Hi_Label (Loop_Id) & ":");
         Append_Line (State, "    JMP " & Loop_Top_Label (Loop_Id));
      else
         Append_Line (State, "    INC " & Symbol_Name (State, Loop_Symbol));
         Append_Line (State, "    JMP " & Loop_Top_Label (Loop_Id));
      end if;
      Append_Line (State, Loop_End_Label (Loop_Id) & ":");
   end Emit_For_Stmt;

   procedure Reserve_Label_Id
     (State : in out Emitter_State;
      Id    : out Natural)
   is
   begin
      State.Loop_Label_Counter := State.Loop_Label_Counter + 1;
      Id := State.Loop_Label_Counter;
   end Reserve_Label_Id;

   function Loop_Top_Label (Id : Natural) return String is
   begin
      return "alb_loop_top_" & Decimal_Image (Id);
   end Loop_Top_Label;

   function Loop_Continue_Label (Id : Natural) return String is
   begin
      return "alb_loop_continue_" & Decimal_Image (Id);
   end Loop_Continue_Label;

   function Loop_Check_Lo_Label (Id : Natural) return String is
   begin
      return "alb_loop_check_lo_" & Decimal_Image (Id);
   end Loop_Check_Lo_Label;

   function Loop_Continue_Skip_Hi_Label (Id : Natural) return String is
   begin
      return "alb_loop_skip_hi_" & Decimal_Image (Id);
   end Loop_Continue_Skip_Hi_Label;

   function Loop_End_Label (Id : Natural) return String is
   begin
      return "alb_loop_end_" & Decimal_Image (Id);
   end Loop_End_Label;

   function Procedure_Label
     (State : Emitter_State;
      Id    : Natural) return String
   is
   begin
      return
        "alb_proc_"
        & State.Procedures (Id).Name (1 .. State.Procedures (Id).Name_Len);
   end Procedure_Label;

   function Temporal_Head_Label (Id : Natural) return String is
   begin
      return "alb_temporal_head_" & Decimal_Image (Id);
   end Temporal_Head_Label;

   function Temporal_Count_Label (Id : Natural) return String is
   begin
      return "alb_temporal_count_" & Decimal_Image (Id);
   end Temporal_Count_Label;

   function Temporal_Save_Head_Label (Id : Natural) return String is
   begin
      return "alb_temporal_save_head_" & Decimal_Image (Id);
   end Temporal_Save_Head_Label;

   function Temporal_Save_Count_Label (Id : Natural) return String is
   begin
      return "alb_temporal_save_count_" & Decimal_Image (Id);
   end Temporal_Save_Count_Label;

   function Symbol_Snapshot_Label (Id : Natural) return String is
   begin
      return "alb_state_save_sym_" & Decimal_Image (Id);
   end Symbol_Snapshot_Label;

   function Rev_Runtime_Label (Suffix : String) return String is
   begin
      return "alb_rev_" & Suffix;
   end Rev_Runtime_Label;

   function Return_Label
     (State : Emitter_State;
      Id    : Natural) return String
   is
   begin
      return Procedure_Label (State, Id) & "_return";
   end Return_Label;

   procedure Push_Loop_Context
     (State        : in out Emitter_State;
      Label_Id     : Natural;
      Index_Symbol : Symbol_Index)
   is
   begin
      if State.Loop_Depth >= Max_Loop_Depth then
         State.Success := False;
         Ada.Text_IO.Put_Line ("ALB-65 C64 emitter error: loop nesting exceeded fixed backend limit.");
         return;
      end if;

      State.Loop_Depth := State.Loop_Depth + 1;
      State.Loop_Stack (State.Loop_Depth) :=
        (Label_Id => Label_Id, Index_Symbol => Index_Symbol);
   end Push_Loop_Context;

   procedure Pop_Loop_Context (State : in out Emitter_State) is
   begin
      if State.Loop_Depth > 0 then
         State.Loop_Depth := State.Loop_Depth - 1;
      end if;
   end Pop_Loop_Context;

   function Current_Index_Symbol (State : Emitter_State) return Symbol_Index is
   begin
      for I in reverse 1 .. State.Loop_Depth loop
         if State.Loop_Stack (I).Index_Symbol /= 0 then
            return State.Loop_Stack (I).Index_Symbol;
         end if;
      end loop;

      return 0;
   end Current_Index_Symbol;

   function Current_Loop_Label_Id (State : Emitter_State) return Natural is
   begin
      if State.Loop_Depth = 0 then
         return 0;
      else
         return State.Loop_Stack (State.Loop_Depth).Label_Id;
      end if;
   end Current_Loop_Label_Id;

   procedure Emit_Index_Y_Load (State : in out Emitter_State) is
      Index_Symbol : constant Symbol_Index := Current_Index_Symbol (State);
   begin
      if Index_Symbol = 0 then
         Append_Line (State, "    LDY #$00");
      else
         Append_Line (State, "    LDY " & Symbol_Name (State, Index_Symbol));
      end if;
   end Emit_Index_Y_Load;

   procedure Register_String_Literal
     (State : in out Emitter_State;
      Node  : Node_Index;
      Index : out Natural)
   is
      Raw      : constant String := Node_Lexeme (Node);
      Start_At : Natural := 0;
      End_At   : Natural := 0;
      Text_Len : Natural := 0;
      Ch       : Character := ' ';
   begin
      Index := 0;

      if Raw'Length < 2 then
         Fail (State, Node, "string literal is too short for C64 emission");
         return;
      end if;

      if Raw (Raw'First) = '"' and then Raw (Raw'Last) = '"' then
         Start_At := Raw'First + 1;
         End_At := Raw'Last - 1;
      elsif Raw (Raw'First) = '`' and then Raw (Raw'Last) = '`' then
         Start_At := Raw'First + 1;
         End_At := Raw'Last - 1;
      else
         Fail (State, Node, "unsupported string literal delimiter for the C64 backend");
         return;
      end if;

      if End_At + 1 < Start_At then
         Start_At := Raw'First;
         End_At := Raw'First - 1;
      end if;

      Text_Len := Natural'Max (0, End_At + 1 - Start_At);

      for I in 1 .. State.String_Count loop
         if State.String_Literals (I).Active
           and then State.String_Literals (I).Text_Len = Text_Len
         then
            declare
               Matches : Boolean := True;
            begin
               if Text_Len > 0 then
                  for J in 0 .. Text_Len - 1 loop
                     if State.String_Literals (I).Text (J + 1) /= Raw (Start_At + J) then
                        Matches := False;
                        exit;
                     end if;
                  end loop;
               end if;
               if Matches then
                  Index := I;
                  return;
               end if;
            end;
         end if;
      end loop;

      if State.String_Count >= Max_String_Literals then
         Fail (State, Node, "string literal table exhausted");
         return;
      end if;

      if Text_Len > Max_String_Length then
         Fail (State, Node, "string literal is too long for the fixed C64 backend table");
         return;
      end if;

      State.String_Count := State.String_Count + 1;
      Index := State.String_Count;
      State.String_Literals (Index).Active := True;
      State.String_Literals (Index).Text_Len := Text_Len;

      for J in 1 .. Text_Len loop
         Ch := Raw (Start_At + J - 1);
         if Ch = '"' then
            Fail (State, Node, "double quotes inside C64 string literals are not supported yet");
            return;
         end if;
         State.String_Literals (Index).Text (J) := Ch;
      end loop;
   end Register_String_Literal;

   function String_Label (Index : Natural) return String is
   begin
      return "alb_str_" & Decimal_Image (Index);
   end String_Label;

   procedure Emit_BEQ_Far
     (State  : in out Emitter_State;
      Target : String)
   is
      Skip_Id : Natural := 0;
   begin
      Reserve_Label_Id (State, Skip_Id);
      Append_Line (State, "    BNE alb_beq_far_" & Decimal_Image (Skip_Id));
      Append_Line (State, "    JMP " & Target);
      Append_Line (State, "alb_beq_far_" & Decimal_Image (Skip_Id) & ":");
   end Emit_BEQ_Far;

   procedure Emit_BNE_Far
     (State  : in out Emitter_State;
      Target : String)
   is
      Skip_Id : Natural := 0;
   begin
      Reserve_Label_Id (State, Skip_Id);
      Append_Line (State, "    BEQ alb_bne_far_" & Decimal_Image (Skip_Id));
      Append_Line (State, "    JMP " & Target);
      Append_Line (State, "alb_bne_far_" & Decimal_Image (Skip_Id) & ":");
   end Emit_BNE_Far;

   procedure Emit_BCC_Far
     (State  : in out Emitter_State;
      Target : String)
   is
      Skip_Id : Natural := 0;
   begin
      Reserve_Label_Id (State, Skip_Id);
      Append_Line (State, "    BCS alb_bcc_far_" & Decimal_Image (Skip_Id));
      Append_Line (State, "    JMP " & Target);
      Append_Line (State, "alb_bcc_far_" & Decimal_Image (Skip_Id) & ":");
   end Emit_BCC_Far;

   procedure Emit_BCS_Far
     (State  : in out Emitter_State;
      Target : String)
   is
      Skip_Id : Natural := 0;
   begin
      Reserve_Label_Id (State, Skip_Id);
      Append_Line (State, "    BCC alb_bcs_far_" & Decimal_Image (Skip_Id));
      Append_Line (State, "    JMP " & Target);
      Append_Line (State, "alb_bcs_far_" & Decimal_Image (Skip_Id) & ":");
   end Emit_BCS_Far;

   procedure Emit_Condition_False_Branch
     (State       : in out Emitter_State;
      Condition   : Node_Index;
      False_Label : String)
   is
      Source      : Byte_Source := (others => <>);
      Left_Source : Byte_Source := (others => <>);
      Right_Source : Byte_Source := (others => <>);
      Symbol      : Symbol_Index := 0;
      Op_Token    : Natural := 0;
      Temp_Id     : Natural := 0;
      Eval_Right_Id : Natural := 0;
   begin
      if Condition = 0 then
         Fail (State, Condition, "missing condition expression");
         return;
      end if;

      case Tree (Condition).Kind is
         when AST_True =>
            null;

         when AST_False =>
            Append_Line (State, "    JMP " & False_Label);

         when AST_Var_Expr =>
            if Is_Indexed_Var_Node (Condition) then
               if Expr_Is_Word (State, Condition) then
                  Emit_Word_Expr (State, Condition);
                  if not State.Success then
                     return;
                  end if;
                  Append_Line (State, "    STX alb_expr_tmp1");
                  Append_Line (State, "    ORA alb_expr_tmp1");
                  Emit_BEQ_Far (State, False_Label);
               else
                  Analyze_Byte_Source (State, Condition, Source);
                  if not State.Success then
                     return;
                  end if;

                  Emit_U8_Load (State, Source);
                  Emit_BEQ_Far (State, False_Label);
               end if;
            else
               Symbol := Find_Visible_Symbol (State, Node_Lexeme (Condition));
               if Symbol = 0 then
                  Fail (State, Condition, "condition variable must be declared");
                  return;
               elsif Is_Byte_Scalar_Symbol (State.Symbols (Symbol).Kind) then
                  Append_Line (State, "    LDA " & Symbol_Name (State, Symbol));
                  Emit_BEQ_Far (State, False_Label);
               else
                  Append_Line (State, "    LDA " & Symbol_Name (State, Symbol));
                  Append_Line (State, "    ORA " & Symbol_Name (State, Symbol) & "+1");
                  Emit_BEQ_Far (State, False_Label);
               end if;
            end if;

         when AST_Peek_Expr | AST_Deref_Expr |
              AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr |
              AST_Unary_Minus | AST_Const_Ref | AST_Member_Expr | AST_Func_Call |
              AST_Find_Query | AST_Query | AST_Knows_Query =>
            if Expr_Is_Word (State, Condition) then
               Emit_Word_Expr (State, Condition);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    STX alb_expr_tmp1");
               Append_Line (State, "    ORA alb_expr_tmp1");
               Emit_BEQ_Far (State, False_Label);
            else
               Emit_Byte_Expr (State, Condition);
               if not State.Success then
                  return;
               end if;
               Emit_BEQ_Far (State, False_Label);
            end if;

         when AST_BinOp =>
            Op_Token := Tree (Condition).Token_Index;
            if Op_Token = 0 then
               Fail (State, Condition, "condition operator is missing");
               return;
            end if;

            if Tokens (Op_Token).Kind = TOK_AND then
               Emit_Condition_False_Branch (State, Tree (Condition).Left_Child, False_Label);
               if not State.Success then
                  return;
               end if;
               Emit_Condition_False_Branch (State, Tree (Condition).Right_Child, False_Label);
               return;
            elsif Tokens (Op_Token).Kind = TOK_OR then
               Reserve_Label_Id (State, Eval_Right_Id);
               Reserve_Label_Id (State, Temp_Id);
               declare
                  Eval_Right_Label : constant String :=
                    "alb_cond_or_rhs_" & Decimal_Image (Eval_Right_Id);
                  Continue_Label   : constant String :=
                    "alb_cond_or_done_" & Decimal_Image (Temp_Id);
               begin
                  Emit_Condition_False_Branch
                    (State,
                     Tree (Condition).Left_Child,
                     Eval_Right_Label);
                  if not State.Success then
                     return;
                  end if;
                  Append_Line (State, "    JMP " & Continue_Label);
                  Append_Line (State, Eval_Right_Label & ":");
                  Emit_Condition_False_Branch
                    (State,
                     Tree (Condition).Right_Child,
                     False_Label);
                  if not State.Success then
                     return;
                  end if;
                  Append_Line (State, Continue_Label & ":");
               end;
               return;
             elsif Tokens (Op_Token).Kind not in
               TOK_EQUAL | TOK_ASSIGN | TOK_NOT_EQUAL |
               TOK_LESS | TOK_GREATER_EQUAL | TOK_GREATER | TOK_LESS_EQUAL
             then
               if Expr_Is_Word (State, Condition) then
                  Emit_Word_Expr (State, Condition);
                  if not State.Success then
                     return;
                  end if;
                  Append_Line (State, "    STX alb_expr_tmp1");
                  Append_Line (State, "    ORA alb_expr_tmp1");
                  Emit_BEQ_Far (State, False_Label);
               else
                  Emit_Byte_Expr (State, Condition);
                  if not State.Success then
                     return;
                  end if;
                  Emit_BEQ_Far (State, False_Label);
               end if;
               return;
             end if;

             if Expr_Is_Word (State, Tree (Condition).Left_Child)
               or else Expr_Is_Word (State, Tree (Condition).Right_Child)
             then
                Emit_Word_Expr (State, Tree (Condition).Left_Child);
                if not State.Success then
                   return;
                end if;
                Append_Line (State, "    STA alb_tmp_u16_lo");
                Append_Line (State, "    STX alb_tmp_u16_hi");
                Emit_Word_Expr (State, Tree (Condition).Right_Child);
                if not State.Success then
                   return;
                end if;
                Append_Line (State, "    STA alb_expr_tmp0");
                Append_Line (State, "    STX alb_expr_tmp1");

                case Tokens (Op_Token).Kind is
                   when TOK_EQUAL | TOK_ASSIGN =>
                      Append_Line (State, "    LDA alb_tmp_u16_hi");
                      Append_Line (State, "    CMP alb_expr_tmp1");
                      Emit_BNE_Far (State, False_Label);
                      Append_Line (State, "    LDA alb_tmp_u16_lo");
                      Append_Line (State, "    CMP alb_expr_tmp0");
                      Emit_BNE_Far (State, False_Label);

                   when TOK_NOT_EQUAL =>
                      Reserve_Label_Id (State, Temp_Id);
                      declare
                         Continue_Label : constant String :=
                           "alb_word_ne_ok_" & Decimal_Image (Temp_Id);
                      begin
                         Append_Line (State, "    LDA alb_tmp_u16_hi");
                         Append_Line (State, "    CMP alb_expr_tmp1");
                         Append_Line (State, "    BNE " & Continue_Label);
                         Append_Line (State, "    LDA alb_tmp_u16_lo");
                         Append_Line (State, "    CMP alb_expr_tmp0");
                         Emit_BEQ_Far (State, False_Label);
                         Append_Line (State, Continue_Label & ":");
                      end;

                   when TOK_LESS =>
                      Append_Line (State, "    LDA alb_tmp_u16_hi");
                      Append_Line (State, "    CMP alb_expr_tmp1");
                      Reserve_Label_Id (State, Temp_Id);
                      declare
                         Continue_Label : constant String :=
                           "alb_word_lt_lo_" & Decimal_Image (Temp_Id);
                      begin
                         Append_Line (State, "    BCC " & Continue_Label);
                         Emit_BNE_Far (State, False_Label);
                         Append_Line (State, "    LDA alb_tmp_u16_lo");
                         Append_Line (State, "    CMP alb_expr_tmp0");
                         Emit_BCS_Far (State, False_Label);
                         Append_Line (State, Continue_Label & ":");
                      end;

                   when TOK_GREATER_EQUAL =>
                      Append_Line (State, "    LDA alb_tmp_u16_hi");
                      Append_Line (State, "    CMP alb_expr_tmp1");
                      Reserve_Label_Id (State, Temp_Id);
                      declare
                         Continue_Label : constant String :=
                           "alb_word_ge_ok_" & Decimal_Image (Temp_Id);
                      begin
                         Emit_BCC_Far (State, False_Label);
                         Append_Line (State, "    BNE " & Continue_Label);
                         Append_Line (State, "    LDA alb_tmp_u16_lo");
                         Append_Line (State, "    CMP alb_expr_tmp0");
                         Emit_BCC_Far (State, False_Label);
                         Append_Line (State, Continue_Label & ":");
                      end;

                   when TOK_GREATER =>
                      Append_Line (State, "    LDA alb_tmp_u16_hi");
                      Append_Line (State, "    CMP alb_expr_tmp1");
                      Reserve_Label_Id (State, Temp_Id);
                      declare
                         Continue_Label : constant String :=
                           "alb_word_gt_lo_" & Decimal_Image (Temp_Id);
                      begin
                         Emit_BCC_Far (State, False_Label);
                         Append_Line (State, "    BNE " & Continue_Label);
                         Append_Line (State, "    LDA alb_tmp_u16_lo");
                         Append_Line (State, "    CMP alb_expr_tmp0");
                         Emit_BCC_Far (State, False_Label);
                         Emit_BEQ_Far (State, False_Label);
                         Append_Line (State, Continue_Label & ":");
                      end;

                   when TOK_LESS_EQUAL =>
                      Append_Line (State, "    LDA alb_tmp_u16_hi");
                      Append_Line (State, "    CMP alb_expr_tmp1");
                      Reserve_Label_Id (State, Temp_Id);
                      declare
                         Continue_Label : constant String :=
                           "alb_word_le_ok_" & Decimal_Image (Temp_Id);
                      begin
                         Append_Line (State, "    BCC " & Continue_Label);
                         Emit_BNE_Far (State, False_Label);
                         Append_Line (State, "    LDA alb_tmp_u16_lo");
                         Append_Line (State, "    CMP alb_expr_tmp0");
                         Append_Line (State, "    BCC " & Continue_Label);
                         Append_Line (State, "    BEQ " & Continue_Label);
                         Append_Line (State, "    JMP " & False_Label);
                         Append_Line (State, Continue_Label & ":");
                      end;

                   when others =>
                      Fail (State, Condition, "unsupported operator in C64 word condition");
                end case;
                return;
             end if;

             Emit_Byte_Expr (State, Tree (Condition).Left_Child);
             if not State.Success then
                return;
             end if;
             Append_Line (State, "    STA alb_expr_tmp0");
             Emit_Byte_Expr (State, Tree (Condition).Right_Child);
             if not State.Success then
                return;
             end if;
             Append_Line (State, "    STA alb_expr_tmp1");
             Append_Line (State, "    LDA alb_expr_tmp0");
             Append_Line (State, "    CMP alb_expr_tmp1");

            case Tokens (Op_Token).Kind is
               when TOK_EQUAL | TOK_ASSIGN =>
                         Emit_BNE_Far (State, False_Label);

               when TOK_NOT_EQUAL =>
                  Emit_BEQ_Far (State, False_Label);

               when TOK_LESS =>
                  Emit_BCS_Far (State, False_Label);

               when TOK_GREATER_EQUAL =>
                  Emit_BCC_Far (State, False_Label);

               when TOK_GREATER =>
                  Emit_BCC_Far (State, False_Label);
                  Emit_BEQ_Far (State, False_Label);

               when TOK_LESS_EQUAL =>
                  Reserve_Label_Id (State, Temp_Id);
                  declare
                     Continue_Label : constant String :=
                       "alb_cmp_ok_" & Decimal_Image (Temp_Id);
                  begin
                     Append_Line (State, "    BCC " & Continue_Label);
                     Append_Line (State, "    BEQ " & Continue_Label);
                     Append_Line (State, "    JMP " & False_Label);
                     Append_Line (State, Continue_Label & ":");
                  end;

               when others =>
                  Fail (State, Condition, "unsupported operator in C64 condition");
            end case;

         when others =>
            Fail (State, Condition, "unsupported condition expression for the C64 backend");
      end case;
   end Emit_Condition_False_Branch;

   procedure Emit_Advance_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Target_Node : constant Node_Index := Tree (Node).Left_Child;
      Symbol      : Symbol_Index := 0;
      Tok_Kind    : Token_Kind := TOK_ERROR;
   begin
      if Tree (Node).Token_Index > 0 then
         Tok_Kind := Tokens (Tree (Node).Token_Index).Kind;
      end if;

      if Tok_Kind /= TOK_PLUS and then Tok_Kind /= TOK_MINUS then
         Emit_Temporal_Advance (State, Node);
         return;
      elsif Target_Node = 0 or else not Is_Var_Node (Target_Node) then
         Fail (State, Node, "postfix ++/-- target must be a declared scalar");
         return;
      end if;

      Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
      if Symbol = 0 or else not Is_Byte_Scalar_Symbol (State.Symbols (Symbol).Kind) then
         Fail (State, Node, "postfix ++/-- target must be a declared 8-bit scalar");
         return;
      end if;

      case Tok_Kind is
         when TOK_PLUS =>
            Append_Line (State, "    INC " & Symbol_Name (State, Symbol));

         when TOK_MINUS =>
            Append_Line (State, "    DEC " & Symbol_Name (State, Symbol));

         when others =>
            Emit_Temporal_Advance (State, Node);
      end case;
   end Emit_Advance_Stmt;

   procedure Emit_Break_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Label_Id : constant Natural := Current_Loop_Label_Id (State);
   begin
      if Label_Id = 0 then
         Fail (State, Node, "BREAK is only valid inside a loop");
         return;
      end if;

      Append_Line (State, "    JMP " & Loop_End_Label (Label_Id));
   end Emit_Break_Stmt;

   procedure Emit_Continue_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Label_Id : constant Natural := Current_Loop_Label_Id (State);
   begin
      if Label_Id = 0 then
         Fail (State, Node, "CONTINUE is only valid inside a loop");
         return;
      end if;

      Append_Line (State, "    JMP " & Loop_Continue_Label (Label_Id));
   end Emit_Continue_Stmt;

   procedure Emit_Match_Select_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Target_Node  : constant Node_Index := Tree (Node).Left_Child;
      Curr_Case    : Node_Index := Tree (Node).Right_Child;
      End_Id       : Natural := 0;
      Next_Id      : Natural := 0;
   begin
      Emit_Byte_Expr (State, Target_Node);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA alb_expr_tmp0");

      Reserve_Label_Id (State, End_Id);

      while Curr_Case /= 0 and then State.Success loop
         if Tree (Curr_Case).Left_Child = 0 then
            Emit_Node_Chain (State, Tree (Curr_Case).Right_Child);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    JMP alb_case_end_" & Decimal_Image (End_Id));
         else
            Reserve_Label_Id (State, Next_Id);
            Emit_Byte_Expr (State, Tree (Curr_Case).Left_Child);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA alb_expr_tmp1");
            Append_Line (State, "    LDA alb_expr_tmp0");
            Append_Line (State, "    CMP alb_expr_tmp1");
            Append_Line (State, "    BNE alb_case_next_" & Decimal_Image (Next_Id));
            Emit_Node_Chain (State, Tree (Curr_Case).Right_Child);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    JMP alb_case_end_" & Decimal_Image (End_Id));
            Append_Line (State, "alb_case_next_" & Decimal_Image (Next_Id) & ":");
         end if;

         Curr_Case := Tree (Curr_Case).Next_Sibling;
      end loop;

      Append_Line (State, "alb_case_end_" & Decimal_Image (End_Id) & ":");
   end Emit_Match_Select_Stmt;

   procedure Emit_Call_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Target_Node : constant Node_Index := Tree (Node).Left_Child;
      Proc_Id     : Natural := 0;
      Call_Ok     : Boolean := False;
   begin
      if Target_Node = 0 then
         Fail (State, Node, "CALL requires a procedure target");
         return;
      end if;

      Emit_Routine_Call (State, Target_Node, Node, Proc_Id, False, Call_Ok);
      if not State.Success or else not Call_Ok then
         return;
      end if;
   end Emit_Call_Stmt;

   procedure Emit_Return_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Routine_Id : constant Natural := State.Current_Procedure;
   begin
      if Routine_Id = 0 then
         Fail (State, Node, "RETURN is only valid inside a procedure or function");
         return;
      end if;

      if State.Procedures (Routine_Id).Return_Void then
         if Tree (Node).Left_Child /= 0 then
            Fail (State, Node, "void routine RETURN cannot provide a value");
            return;
         end if;
      else
         if Tree (Node).Left_Child = 0 then
            Fail (State, Node, "function RETURN requires a value");
            return;
         elsif Is_Byte_Scalar_Symbol (State.Procedures (Routine_Id).Return_Kind) then
            Emit_Byte_Expr (State, Tree (Node).Left_Child);
            if not State.Success then
               return;
            end if;
            Append_Line
              (State,
               "    STA " & Symbol_Name (State, State.Procedures (Routine_Id).Return_Symbol));
         else
            Emit_Pointer_Assignment
              (State,
               State.Procedures (Routine_Id).Return_Symbol,
               Tree (Node).Left_Child);
            if not State.Success then
               return;
            end if;
         end if;
      end if;

      Append_Line (State, "    JMP " & Return_Label (State, Routine_Id));
   end Emit_Return_Stmt;

   procedure Emit_Cursor_Position
     (State  : in out Emitter_State;
      X_Node : Node_Index;
      Y_Node : Node_Index;
      Origin : Node_Index)
   is
      X_Value  : Natural := 0;
      Y_Value  : Natural := 0;
      X_Symbol : Symbol_Index := 0;
      Y_Symbol : Symbol_Index := 0;
   begin
      if Parse_Integer_Expr (State, Y_Node, Y_Value) then
         if Y_Value < 1 or else Y_Value > 25 then
            Fail (State, Origin, "C64 text row must stay within 1..25");
            return;
         end if;

         Append_Line (State, "    LDX #" & Byte_Hex (Y_Value - 1));
      elsif Is_Var_Node (Y_Node) and then not Is_Indexed_Var_Node (Y_Node) then
         Y_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Y_Node));
         if Y_Symbol = 0 or else not Is_Byte_Scalar_Symbol (State.Symbols (Y_Symbol).Kind) then
            Fail (State, Y_Node, "C64 text row must be a literal or declared 8-bit scalar");
            return;
         end if;

         Append_Line (State, "    LDX " & Symbol_Name (State, Y_Symbol));
         Append_Line (State, "    DEX");
      else
         Fail (State, Y_Node, "C64 text row must be a literal or declared 8-bit scalar");
         return;
      end if;

      if Parse_Integer_Expr (State, X_Node, X_Value) then
         if X_Value < 1 or else X_Value > 40 then
            Fail (State, Origin, "C64 text column must stay within 1..40");
            return;
         end if;

         Append_Line (State, "    LDY #" & Byte_Hex (X_Value - 1));
      elsif Is_Var_Node (X_Node) and then not Is_Indexed_Var_Node (X_Node) then
         X_Symbol := Find_Visible_Symbol (State, Node_Lexeme (X_Node));
         if X_Symbol = 0 or else not Is_Byte_Scalar_Symbol (State.Symbols (X_Symbol).Kind) then
            Fail (State, X_Node, "C64 text column must be a literal or declared 8-bit scalar");
            return;
         end if;

         Append_Line (State, "    LDY " & Symbol_Name (State, X_Symbol));
         Append_Line (State, "    DEY");
      else
         Fail (State, X_Node, "C64 text column must be a literal or declared 8-bit scalar");
         return;
      end if;

      Append_Line (State, "    CLC");
      Append_Line (State, "    JSR KERNAL_PLOT");
   end Emit_Cursor_Position;

   procedure Emit_Text_Buffer_Position
     (State  : in out Emitter_State;
      X_Node : Node_Index;
      Y_Node : Node_Index;
      Origin : Node_Index)
   is
      X_Value      : Natural := 0;
      Y_Value      : Natural := 0;
      X_Symbol     : Symbol_Index := 0;
      Y_Symbol     : Symbol_Index := 0;
      X_Adjust_Id  : Natural := 0;
      Y_Adjust_Id  : Natural := 0;
   begin
      if Parse_Integer_Expr (State, Y_Node, Y_Value) then
         if Y_Value < 1 or else Y_Value > 25 then
            Fail (State, Origin, "C64 text row must stay within 1..25");
            return;
         end if;

         Append_Line (State, "    LDA #" & Byte_Hex (Y_Value - 1));
      elsif Is_Var_Node (Y_Node) and then not Is_Indexed_Var_Node (Y_Node) then
         Y_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Y_Node));
         if Y_Symbol = 0 or else not Is_Byte_Scalar_Symbol (State.Symbols (Y_Symbol).Kind) then
            Fail (State, Y_Node, "C64 text row must be a literal or declared 8-bit scalar");
            return;
         end if;

         Reserve_Label_Id (State, Y_Adjust_Id);
         Append_Line (State, "    LDA " & Symbol_Name (State, Y_Symbol));
         Append_Line (State, "    BEQ alb_text_row_zero_" & Decimal_Image (Y_Adjust_Id));
         Append_Line (State, "    SEC");
         Append_Line (State, "    SBC #$01");
         Append_Line (State, "alb_text_row_zero_" & Decimal_Image (Y_Adjust_Id) & ":");
      else
         Fail (State, Y_Node, "C64 text row must be a literal or declared 8-bit scalar");
         return;
      end if;

      Append_Line (State, "    STA alb_text_y");

      if Parse_Integer_Expr (State, X_Node, X_Value) then
         if X_Value < 1 or else X_Value > 40 then
            Fail (State, Origin, "C64 text column must stay within 1..40");
            return;
         end if;

         Append_Line (State, "    LDA #" & Byte_Hex (X_Value - 1));
      elsif Is_Var_Node (X_Node) and then not Is_Indexed_Var_Node (X_Node) then
         X_Symbol := Find_Visible_Symbol (State, Node_Lexeme (X_Node));
         if X_Symbol = 0 or else not Is_Byte_Scalar_Symbol (State.Symbols (X_Symbol).Kind) then
            Fail (State, X_Node, "C64 text column must be a literal or declared 8-bit scalar");
            return;
         end if;

         Reserve_Label_Id (State, X_Adjust_Id);
         Append_Line (State, "    LDA " & Symbol_Name (State, X_Symbol));
         Append_Line (State, "    BEQ alb_text_col_zero_" & Decimal_Image (X_Adjust_Id));
         Append_Line (State, "    SEC");
         Append_Line (State, "    SBC #$01");
         Append_Line (State, "alb_text_col_zero_" & Decimal_Image (X_Adjust_Id) & ":");
      else
         Fail (State, X_Node, "C64 text column must be a literal or declared 8-bit scalar");
         return;
      end if;

      Append_Line (State, "    STA alb_text_x");
   end Emit_Text_Buffer_Position;

   procedure Emit_Text_Expr
     (State     : in out Emitter_State;
      Expr_Node : Node_Index)
   is
      Str_Index : Natural := 0;
      Tok_Kind  : Token_Kind := TOK_ERROR;
   begin
      if Expr_Node = 0 then
         Fail (State, Expr_Node, "text output is missing an expression");
         return;
      end if;

      if Tree (Expr_Node).Kind = AST_BinOp and then Tree (Expr_Node).Token_Index > 0 then
         Tok_Kind := Tokens (Tree (Expr_Node).Token_Index).Kind;
         if Tok_Kind = TOK_PIPE then
            Emit_Text_Expr (State, Tree (Expr_Node).Left_Child);
            if not State.Success then
               return;
            end if;
            Emit_Text_Expr (State, Tree (Expr_Node).Right_Child);
            return;
         end if;
      end if;

      if Tree (Expr_Node).Kind = AST_String_Expr then
         Register_String_Literal (State, Expr_Node, Str_Index);
         if not State.Success then
            return;
         end if;

         Append_Line (State, "    LDX #<" & String_Label (Str_Index));
         Append_Line (State, "    LDY #>" & String_Label (Str_Index));
         Append_Line (State, "    JSR alb_print_string");
         return;
      elsif Expr_Is_String (State, Expr_Node) then
         Emit_String_Address (State, Expr_Node);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    STX ZP_IO_PTR+1");
         Append_Line (State, "    STA ZP_IO_PTR");
         Append_Line (State, "    LDX ZP_IO_PTR");
         Append_Line (State, "    LDY ZP_IO_PTR+1");
         Append_Line (State, "    JSR alb_print_string");
         return;
      end if;

      if Expr_Is_Word (State, Expr_Node) then
         Emit_Word_Expr (State, Expr_Node);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    JSR alb_print_u16");
         return;
      end if;

      Emit_Byte_Expr (State, Expr_Node);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    JSR alb_print_u8");
   end Emit_Text_Expr;

   procedure Emit_Buffered_Text_Expr
     (State     : in out Emitter_State;
      Expr_Node : Node_Index)
   is
      Str_Index : Natural := 0;
      Tok_Kind  : Token_Kind := TOK_ERROR;
   begin
      if Expr_Node = 0 then
         Fail (State, Expr_Node, "text output is missing an expression");
         return;
      end if;

      if Tree (Expr_Node).Kind = AST_BinOp and then Tree (Expr_Node).Token_Index > 0 then
         Tok_Kind := Tokens (Tree (Expr_Node).Token_Index).Kind;
         if Tok_Kind = TOK_PIPE then
            Emit_Buffered_Text_Expr (State, Tree (Expr_Node).Left_Child);
            if not State.Success then
               return;
            end if;
            Emit_Buffered_Text_Expr (State, Tree (Expr_Node).Right_Child);
            return;
         end if;
      end if;

      if Tree (Expr_Node).Kind = AST_String_Expr then
         Register_String_Literal (State, Expr_Node, Str_Index);
         if not State.Success then
            return;
         end if;

         Append_Line (State, "    LDX #<" & String_Label (Str_Index));
         Append_Line (State, "    LDY #>" & String_Label (Str_Index));
         Append_Line (State, "    JSR alb_text_string");
         return;
      elsif Expr_Is_String (State, Expr_Node) then
         Emit_String_Address (State, Expr_Node);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    STX ZP_IO_PTR+1");
         Append_Line (State, "    STA ZP_IO_PTR");
         Append_Line (State, "    LDX ZP_IO_PTR");
         Append_Line (State, "    LDY ZP_IO_PTR+1");
         Append_Line (State, "    JSR alb_text_string");
         return;
      end if;

      if Expr_Is_Word (State, Expr_Node) then
         Emit_Word_Expr (State, Expr_Node);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    JSR alb_text_u16");
         return;
      end if;

      Emit_Byte_Expr (State, Expr_Node);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    JSR alb_text_u8");
   end Emit_Buffered_Text_Expr;

   procedure Emit_Locate_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      if Tree (Node).Left_Child = 0 or else Tree (Node).Right_Child = 0 then
         Fail (State, Node, "LOCATE requires column and row expressions");
         return;
      end if;

      Emit_Cursor_Position
        (State,
         Tree (Node).Left_Child,
         Tree (Node).Right_Child,
         Node);
   end Emit_Locate_Stmt;

   procedure Emit_Text_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Arg_List : constant Node_Index := Tree (Node).Left_Child;
      X_Node   : Node_Index := 0;
      Y_Node   : Node_Index := 0;
      Text_Node : Node_Index := 0;
   begin
      if Arg_List = 0 or else Tree (Arg_List).Kind /= AST_Arg_List then
         Fail (State, Node, "TEXT requires x, y, and a text expression");
         return;
      end if;

      X_Node := Tree (Arg_List).Left_Child;
      if X_Node /= 0 then
         Y_Node := Tree (X_Node).Next_Sibling;
      end if;
      if Y_Node /= 0 then
         Text_Node := Tree (Y_Node).Next_Sibling;
      end if;

      if X_Node = 0 or else Y_Node = 0 or else Text_Node = 0 then
         Fail (State, Node, "TEXT requires x, y, and a text expression");
         return;
      end if;

      if Tree (Text_Node).Next_Sibling /= 0 then
         Fail (State, Node, "C64 TEXT currently supports exactly three arguments");
         return;
      end if;

      Emit_Text_Buffer_Position (State, X_Node, Y_Node, Node);
      if not State.Success then
         return;
      end if;

      Emit_Buffered_Text_Expr (State, Text_Node);
   end Emit_Text_Stmt;

   procedure Emit_Print_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Curr : Node_Index := Node;
   begin
      while Curr /= 0 and then State.Success loop
         Emit_Text_Expr (State, Tree (Curr).Left_Child);
         Curr := Tree (Curr).Right_Child;
      end loop;

      if State.Success and then Tree (Node).Kind = AST_Print_Stmt then
         Append_Line (State, "    JSR alb_print_newline");
      end if;
   end Emit_Print_Stmt;

   procedure Emit_String_Address
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Str_Index   : Natural := 0;
      Symbol      : Symbol_Index := 0;
      Member      : Member_Access_Record := (others => <>);
      Routine_Id  : Natural := 0;
      Call_Ok     : Boolean := False;
      Temporal_Id : Natural := 0;
      Selector    : Token_Kind := TOK_ERROR;
   begin
      if Node = 0 then
         Fail (State, Node, "string expression is missing");
         return;
      end if;

      if Tree (Node).Kind = AST_String_Expr then
         Register_String_Literal (State, Node, Str_Index);
         if not State.Success then
            return;
         end if;

         Append_Line (State, "    LDA #<" & String_Label (Str_Index));
         Append_Line (State, "    LDX #>" & String_Label (Str_Index));
         return;
      elsif Tree (Node).Kind = AST_Temporal_Ref then
         Emit_Load_Temporal_String (State, Node);
         return;
      elsif Tree (Node).Kind = AST_Func_Call then
         Emit_Routine_Call (State, Node, Node, Routine_Id, True, Call_Ok);
         if not State.Success or else not Call_Ok then
            return;
         end if;

         if not Is_String_Symbol (State.Procedures (Routine_Id).Return_Kind) then
            Fail (State, Node, "function does not return STRING/BINARY data");
            return;
         end if;

         Append_Line
           (State,
            "    LDA " & Symbol_Name (State, State.Procedures (Routine_Id).Return_Symbol));
         Append_Line
           (State,
            "    LDX " & Symbol_Name (State, State.Procedures (Routine_Id).Return_Symbol) & "+1");
         return;
      elsif Tree (Node).Kind = AST_Member_Expr then
         Analyze_Member_Access (State, Node, Member);
         if not State.Success then
            return;
         end if;

         if Member.Kind /= Member_Struct_Field
           or else Member.Symbol = 0
           or else not Is_String_Symbol (State.Symbols (Member.Symbol).Kind)
         then
            Fail (State, Node, "member expression is not backed by STRING/BINARY storage");
            return;
         end if;

         Append_Line (State, "    LDA " & Symbol_Name (State, Member.Symbol));
         Append_Line (State, "    LDX " & Symbol_Name (State, Member.Symbol) & "+1");
         return;
      elsif Is_Var_Node (Node) and then not Is_Indexed_Var_Node (Node) then
         Temporal_Id := Temporal_Index (State, Node_Lexeme (Node));
         if Temporal_Id /= 0 then
            Symbol := State.Temporals (Temporal_Id).Current;
         else
            Symbol := Find_Visible_Symbol (State, Node_Lexeme (Node));
         end if;

         if Symbol = 0 then
            Fail (State, Node, "string variable is not declared");
            return;
         elsif not Is_String_Symbol (State.Symbols (Symbol).Kind) then
            Fail (State, Node, "expression does not resolve to STRING/BINARY storage");
            return;
         end if;

         Append_Line (State, "    LDA " & Symbol_Name (State, Symbol));
         Append_Line (State, "    LDX " & Symbol_Name (State, Symbol) & "+1");
         return;
      elsif Tree (Node).Kind in AST_File_Read | AST_Readline_Stmt | AST_Str_Left |
                               AST_Str_Right | AST_Str_Mid | AST_Str_Concat |
                               AST_TypeOf_Expr
      then
         Append_Line (State, "    LDA #<alb_empty_string");
         Append_Line (State, "    LDX #>alb_empty_string");
         return;
      end if;

      Fail (State, Node, "unsupported STRING/BINARY expression for the C64 backend");
   end Emit_String_Address;

   procedure Emit_Word_Expr_To_Cell_Store
     (State   : in out Emitter_State;
      Node    : Node_Index;
      Target  : String;
      Min_One : Boolean := False)
   is
      Adjust_Id   : Natural := 0;
      Done_Id     : Natural := 0;
      Pixel_Value : Natural := 0;
      Cell_Value  : Natural := 0;
   begin
      if Node = 0 then
         Fail (State, Node, "graphics operation is missing a coordinate expression");
         return;
      end if;

      if Parse_Integer_Expr (State, Node, Pixel_Value) then
         if Min_One then
            Cell_Value := (Pixel_Value + 7) / 8;
         else
            Cell_Value := (Pixel_Value + 4) / 8;
         end if;
         if Pixel_Value > 319 then
            Cell_Value := 39;
         end if;
         if Min_One and then Cell_Value = 0 then
            Cell_Value := 1;
         end if;
         Append_Line (State, "    LDA #" & Byte_Hex (Cell_Value));
         Append_Line (State, "    STA " & Target);
         return;
      end if;

      Emit_Word_Expr (State, Node);
      if not State.Success then
         return;
      end if;

      Append_Line (State, "    STA alb_tmp_u16_lo");
      Append_Line (State, "    STX alb_tmp_u16_hi");
      if Min_One then
         Append_Line (State, "    CLC");
         Append_Line (State, "    LDA alb_tmp_u16_lo");
         Append_Line (State, "    ADC #$07");
         Append_Line (State, "    STA alb_tmp_u16_lo");
         Append_Line (State, "    LDA alb_tmp_u16_hi");
         Append_Line (State, "    ADC #$00");
         Append_Line (State, "    STA alb_tmp_u16_hi");
      else
         Append_Line (State, "    CLC");
         Append_Line (State, "    LDA alb_tmp_u16_lo");
         Append_Line (State, "    ADC #$04");
         Append_Line (State, "    STA alb_tmp_u16_lo");
         Append_Line (State, "    LDA alb_tmp_u16_hi");
         Append_Line (State, "    ADC #$00");
         Append_Line (State, "    STA alb_tmp_u16_hi");
      end if;
      for I in 1 .. 3 loop
         Append_Line (State, "    LSR alb_tmp_u16_hi");
         Append_Line (State, "    ROR alb_tmp_u16_lo");
      end loop;

      Reserve_Label_Id (State, Done_Id);
      Append_Line (State, "    LDA alb_tmp_u16_hi");
      Append_Line (State, "    BEQ alb_cell_low_" & Decimal_Image (Done_Id));
      Append_Line (State, "    LDA #$FF");
      Append_Line (State, "    JMP alb_cell_done_" & Decimal_Image (Done_Id));
      Append_Line (State, "alb_cell_low_" & Decimal_Image (Done_Id) & ":");
      Append_Line (State, "    LDA alb_tmp_u16_lo");
      Append_Line (State, "alb_cell_done_" & Decimal_Image (Done_Id) & ":");

      if Min_One then
         Reserve_Label_Id (State, Adjust_Id);
         Append_Line (State, "    BNE alb_cell_keep_" & Decimal_Image (Adjust_Id));
         Append_Line (State, "    LDA #$01");
         Append_Line (State, "alb_cell_keep_" & Decimal_Image (Adjust_Id) & ":");
      end if;

      Append_Line (State, "    STA " & Target);
   end Emit_Word_Expr_To_Cell_Store;

   procedure Emit_Color_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      if Tree (Node).Left_Child = 0 then
         Fail (State, Node, "COLOR requires a color expression");
         return;
      end if;

      Emit_Byte_Expr (State, Tree (Node).Left_Child);
      if not State.Success then
         return;
      end if;

      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA alb_draw_color");
      Append_Line (State, "    STA C64_TEXT_COLOR");
   end Emit_Color_Stmt;

   procedure Emit_Clear_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      if Tree (Node).Left_Child = 0 then
         Fail (State, Node, "CLEAR requires a color expression");
         return;
      end if;

      Emit_Byte_Expr (State, Tree (Node).Left_Child);
      if not State.Success then
         return;
      end if;

      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA alb_clear_color");
      Append_Line (State, "    JSR alb_clear_screen");
   end Emit_Clear_Stmt;

   procedure Emit_Create_Window_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Args_Node   : constant Node_Index := Tree (Node).Right_Child;
      Width_Node  : Node_Index := 0;
      Height_Node : Node_Index := 0;
   begin
      if Args_Node /= 0 then
         if Tree (Args_Node).Left_Child /= 0 then
            Width_Node := Tree (Args_Node).Left_Child;
         else
            Width_Node := Args_Node;
         end if;

         if Tree (Args_Node).Right_Child /= 0 then
            Height_Node := Tree (Args_Node).Right_Child;
         elsif Width_Node /= 0 then
            Height_Node := Tree (Width_Node).Next_Sibling;
         end if;
      end if;

      if Tree (Node).Left_Child /= 0 and then Expr_Is_String (State, Tree (Node).Left_Child) then
         Emit_String_Address (State, Tree (Node).Left_Child);
         if not State.Success then
            return;
         end if;
      end if;

      if Width_Node /= 0 then
         Emit_Word_Expr (State, Width_Node);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    STA alb_screen_width");
         Append_Line (State, "    STX alb_screen_width+1");
      end if;

      if Height_Node /= 0 then
         Emit_Word_Expr (State, Height_Node);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    STA alb_screen_height");
         Append_Line (State, "    STX alb_screen_height+1");
      end if;

      Append_Line (State, "    JSR alb_init_graphics");
   end Emit_Create_Window_Stmt;

   procedure Emit_Draw_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Shape_Kind : Token_Kind := TOK_ERROR;
      Arg_List   : constant Node_Index := Tree (Node).Left_Child;
      Arg_1      : constant Node_Index := Nth_Arg (Arg_List, 1);
      Arg_2      : constant Node_Index := Nth_Arg (Arg_List, 2);
      Arg_3      : constant Node_Index := Nth_Arg (Arg_List, 3);
      Arg_4      : constant Node_Index := Nth_Arg (Arg_List, 4);
      Arg_5      : constant Node_Index := Nth_Arg (Arg_List, 5);
      Arg_6      : constant Node_Index := Nth_Arg (Arg_List, 6);
   begin
      if Tree (Node).Token_Index > 0 then
         Shape_Kind := Tokens (Tree (Node).Token_Index).Kind;
      end if;

      case Shape_Kind is
         when Tok_Rect =>
            if Arg_1 = 0 or else Arg_2 = 0 or else Arg_3 = 0 or else Arg_4 = 0 then
               Fail (State, Node, "RECT requires x, y, width, and height");
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_1, "alb_rect_x");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_2, "alb_rect_y");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_3, "alb_rect_w", Min_One => True);
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_4, "alb_rect_h", Min_One => True);
            if not State.Success then
               return;
            end if;

            if Tree (Node).Kind = AST_FILL then
               Append_Line (State, "    JSR alb_fill_rect");
            else
               Append_Line (State, "    JSR alb_draw_rect");
            end if;

         when Tok_Line =>
            if Arg_1 = 0 or else Arg_2 = 0 or else Arg_3 = 0 or else Arg_4 = 0 then
               Fail (State, Node, "LINE requires x1, y1, x2, and y2");
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_1, "alb_graphics_x");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_2, "alb_graphics_y");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_3, "alb_graphics_x1");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_4, "alb_graphics_y1");
            if not State.Success then
               return;
            end if;

            Append_Line (State, "    JSR alb_draw_line");

         when Tok_Circle =>
            if Arg_1 = 0 or else Arg_2 = 0 or else Arg_3 = 0 then
               Fail (State, Node, "CIRCLE requires x, y, and radius");
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_1, "alb_graphics_x");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_2, "alb_graphics_y");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_3, "alb_circle_r", Min_One => True);
            if not State.Success then
               return;
            end if;

            if Tree (Node).Kind = AST_FILL then
               Append_Line (State, "    JSR alb_fill_circle");
            else
               Append_Line (State, "    JSR alb_draw_circle");
            end if;

         when Tok_Triangle =>
            if Arg_1 = 0 or else Arg_2 = 0 or else Arg_3 = 0
              or else Arg_4 = 0 or else Arg_5 = 0 or else Arg_6 = 0
            then
               Fail (State, Node, "TRIANGLE requires six coordinate expressions");
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_1, "alb_graphics_x");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_2, "alb_graphics_y");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_3, "alb_graphics_x1");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_4, "alb_graphics_y1");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_5, "alb_tri_x2");
            if not State.Success then
               return;
            end if;

            Emit_Word_Expr_To_Cell_Store (State, Arg_6, "alb_tri_y2");
            if not State.Success then
               return;
            end if;

            if Tree (Node).Kind = AST_FILL then
               Append_Line (State, "    JSR alb_fill_triangle");
            else
               Append_Line (State, "    JSR alb_draw_triangle");
            end if;

         when others =>
            Append_Line
              (State,
               "    ; ALB-65 graphics stub: " & Node_Kind'Image (Tree (Node).Kind));
      end case;
   end Emit_Draw_Stmt;

   procedure Emit_Plot_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Arg_List : constant Node_Index := Tree (Node).Left_Child;
      X_Node   : constant Node_Index := Nth_Arg (Arg_List, 1);
      Y_Node   : constant Node_Index := Nth_Arg (Arg_List, 2);
   begin
      if X_Node = 0 or else Y_Node = 0 then
         Fail (State, Node, "PLOT requires x and y coordinates");
         return;
      end if;

      Emit_Word_Expr_To_Cell_Store (State, X_Node, "alb_graphics_x");
      if not State.Success then
         return;
      end if;

      Emit_Word_Expr_To_Cell_Store (State, Y_Node, "alb_graphics_y");
      if not State.Success then
         return;
      end if;

      Append_Line (State, "    JSR alb_plot_cell");
   end Emit_Plot_Stmt;

   procedure Emit_Listen_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      pragma Unreferenced (Node);
   begin
      Append_Line (State, "    JSR alb_listen_loop");
   end Emit_Listen_Stmt;

   procedure Emit_Cease_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      pragma Unreferenced (Node);
   begin
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_cease_flag");
   end Emit_Cease_Stmt;

   procedure Emit_Delay_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      if Tree (Node).Left_Child = 0 then
         Fail (State, Node, "DELAY requires a frame count expression");
         return;
      end if;

      Emit_Byte_Expr (State, Tree (Node).Left_Child);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    JSR alb_delay");
   end Emit_Delay_Stmt;

   procedure Emit_File_Write_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      Emit_Byte_Expr (State, Tree (Node).Left_Child);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA alb_file_handle");
      Emit_String_Address (State, Tree (Node).Right_Child);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA ZP_IO_PTR");
      Append_Line (State, "    STX ZP_IO_PTR+1");
      Append_Line (State, "    JSR alb_file_write");
   end Emit_File_Write_Stmt;

   procedure Emit_File_Close_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      Emit_Byte_Expr (State, Tree (Node).Left_Child);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA alb_file_handle");
      Append_Line (State, "    JSR alb_file_close");
   end Emit_File_Close_Stmt;

   procedure Emit_Load_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Target_Node : constant Node_Index := Tree (Node).Right_Child;
      Symbol      : Symbol_Index := 0;
   begin
      if Tree (Node).Left_Child /= 0 then
         Emit_String_Address (State, Tree (Node).Left_Child);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "    STA ZP_IO_PTR");
         Append_Line (State, "    STX ZP_IO_PTR+1");
         Append_Line (State, "    JSR alb_file_load");
      end if;

      if not Is_Var_Node (Target_Node) then
         Fail (State, Node, "LOAD target must be a declared variable");
         return;
      end if;

      Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
      if Symbol = 0 then
         Fail (State, Node, "LOAD target is not declared");
         return;
      elsif not Is_String_Symbol (State.Symbols (Symbol).Kind) then
         Fail (State, Node, "LOAD target must be STRING or BINARY");
         return;
      end if;

      Append_Line (State, "    LDA #<alb_file_buf");
      Append_Line (State, "    STA " & Symbol_Name (State, Symbol));
      Append_Line (State, "    LDA #>alb_file_buf");
      Append_Line (State, "    STA " & Symbol_Name (State, Symbol) & "+1");
   end Emit_Load_Stmt;

   procedure Emit_Play_Sound_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
   begin
      if Tree (Node).Left_Child = 0 then
         Fail (State, Node, "PLAY SOUND requires a path expression");
         return;
      end if;

      Emit_String_Address (State, Tree (Node).Left_Child);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA ZP_IO_PTR");
      Append_Line (State, "    STX ZP_IO_PTR+1");
      Append_Line (State, "    JSR alb_play_sound");
   end Emit_Play_Sound_Stmt;

   procedure Emit_Temporal_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Target_Node  : constant Node_Index := Tree (Node).Left_Child;
      History_Node : constant Node_Index := Tree (Node).Right_Child;
      Init_Node    : constant Node_Index :=
        (if History_Node /= 0 then Tree (History_Node).Next_Sibling else 0);
      Temporal_Id  : Natural := 0;
      Current_Sym  : Symbol_Index := 0;
   begin
      if not Is_Var_Node (Target_Node) then
         Fail (State, Node, "temporal declaration requires a scalar target");
         return;
      end if;

      Temporal_Id := Temporal_Index (State, Node_Lexeme (Target_Node));
      if Temporal_Id = 0 then
         Fail (State, Node, "temporal declaration was not registered");
         return;
      end if;

      Current_Sym := State.Temporals (Temporal_Id).Current;

      if Init_Node = 0 then
         Emit_Clear_Target (State, Target_Node);
      elsif Is_Byte_Scalar_Symbol (State.Temporals (Temporal_Id).Kind) then
         Emit_U8_Assignment (State, Current_Sym, Init_Node, Node);
      else
         Emit_Pointer_Assignment (State, Current_Sym, Init_Node);
      end if;
      if not State.Success then
         return;
      end if;

      Emit_Copy_Label_Bytes
        (State,
         Symbol_Name (State, Current_Sym),
         Symbol_Name (State, State.Temporals (Temporal_Id).Past),
         State.Temporals (Temporal_Id).Element_Bytes);
      Emit_Copy_Label_Bytes
        (State,
         Symbol_Name (State, Current_Sym),
         Symbol_Name (State, State.Temporals (Temporal_Id).Saved),
         State.Temporals (Temporal_Id).Element_Bytes);
      Emit_Clear_Label_Bytes
        (State,
         Symbol_Name (State, State.Temporals (Temporal_Id).Timeline),
         Array_Total_Bytes (State.Symbols (State.Temporals (Temporal_Id).Timeline)));
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA " & Temporal_Head_Label (Temporal_Id));
      Append_Line (State, "    STA " & Temporal_Count_Label (Temporal_Id));
      Append_Line (State, "    STA " & Temporal_Save_Head_Label (Temporal_Id));
      Append_Line (State, "    STA " & Temporal_Save_Count_Label (Temporal_Id));
   end Emit_Temporal_Declaration;

   procedure Emit_Temporal_Advance
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Advance_Count : Natural := 1;
   begin
      if Tree (Node).Left_Child /= 0
        and then not Parse_Integer_Expr (State, Tree (Node).Left_Child, Advance_Count)
      then
         Fail (State, Node, "ADVANCE count must be a static non-negative integer on C64");
         return;
      end if;

      if Advance_Count = 0 then
         return;
      end if;

      for Step in 1 .. Advance_Count loop
         for I in 1 .. State.Temporal_Count loop
            if State.Temporals (I).Active then
               declare
                  Wrap_Id       : Natural := 0;
                  Count_Done_Id : Natural := 0;
                  Current_Name  : constant String :=
                    Symbol_Name (State, State.Temporals (I).Current);
                  Past_Name     : constant String :=
                    Symbol_Name (State, State.Temporals (I).Past);
                  Timeline_Name : constant String :=
                    Symbol_Name (State, State.Temporals (I).Timeline);
               begin
                  Reserve_Label_Id (State, Wrap_Id);
                  Reserve_Label_Id (State, Count_Done_Id);

                  Emit_Copy_Label_Bytes
                    (State,
                     Current_Name,
                     Past_Name,
                     State.Temporals (I).Element_Bytes);

                  Append_Line (State, "    LDY " & Temporal_Head_Label (I));
                  if State.Temporals (I).Element_Bytes = 2 then
                     Append_Line (State, "    TYA");
                     Append_Line (State, "    ASL A");
                     Append_Line (State, "    TAY");
                  end if;

                  Append_Line (State, "    LDA " & Current_Name);
                  Append_Line (State, "    STA " & Timeline_Name & ",Y");
                  if State.Temporals (I).Element_Bytes = 2 then
                     Append_Line (State, "    INY");
                     Append_Line (State, "    LDA " & Current_Name & "+1");
                     Append_Line (State, "    STA " & Timeline_Name & ",Y");
                  end if;

                  Append_Line (State, "    LDA " & Temporal_Head_Label (I));
                  Append_Line (State, "    CLC");
                  Append_Line (State, "    ADC #$01");
                  Append_Line
                    (State,
                     "    CMP #" & Byte_Hex (State.Temporals (I).History_Size));
                  Append_Line
                    (State,
                     "    BCC alb_temporal_head_ok_" & Decimal_Image (Wrap_Id));
                  Append_Line (State, "    LDA #$00");
                  Append_Line
                    (State,
                     "alb_temporal_head_ok_" & Decimal_Image (Wrap_Id) & ":");
                  Append_Line (State, "    STA " & Temporal_Head_Label (I));

                  Append_Line (State, "    LDA " & Temporal_Count_Label (I));
                  Append_Line
                    (State,
                     "    CMP #" & Byte_Hex (State.Temporals (I).History_Size));
                  Append_Line
                    (State,
                     "    BCS alb_temporal_count_done_" & Decimal_Image (Count_Done_Id));
                  Append_Line (State, "    CLC");
                  Append_Line (State, "    ADC #$01");
                  Append_Line (State, "    STA " & Temporal_Count_Label (I));
                  Append_Line
                    (State,
                     "alb_temporal_count_done_" & Decimal_Image (Count_Done_Id) & ":");
               end;
            end if;
         end loop;
      end loop;
   end Emit_Temporal_Advance;

   procedure Emit_Save_Load_State
     (State    : in out Emitter_State;
      Is_Load  : Boolean;
      Node     : Node_Index)
   is
      pragma Unreferenced (Node);
   begin
      for I in 1 .. State.Symbol_Count loop
         if State.Symbols (I).Active
           and then State.Symbols (I).Kind /= Symbol_Struct_Instance
           and then State.Symbols (I).Kind /= Symbol_Parallel_Group
         then
            if Is_Load then
               Emit_Copy_Label_To_Symbol
                 (State,
                  Symbol_Snapshot_Label (I),
                  I);
            else
               Emit_Copy_Symbol_To_Label
                 (State,
                  I,
                  Symbol_Snapshot_Label (I));
            end if;
         end if;
      end loop;

      for I in 1 .. State.Temporal_Count loop
         if State.Temporals (I).Active then
            if Is_Load then
               Emit_Copy_Label_Bytes
                 (State,
                  Temporal_Save_Head_Label (I),
                  Temporal_Head_Label (I),
                  1);
               Emit_Copy_Label_Bytes
                 (State,
                  Temporal_Save_Count_Label (I),
                  Temporal_Count_Label (I),
                  1);
            else
               Emit_Copy_Label_Bytes
                 (State,
                  Temporal_Head_Label (I),
                  Temporal_Save_Head_Label (I),
                  1);
               Emit_Copy_Label_Bytes
                 (State,
                  Temporal_Count_Label (I),
                  Temporal_Save_Count_Label (I),
                  1);
            end if;
         end if;
      end loop;

      if Is_Load then
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_active", "alb_logic_fact_active", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_pred_lo", "alb_logic_fact_pred_lo", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_pred_hi", "alb_logic_fact_pred_hi", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_arity", "alb_logic_fact_arity", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_arg_lo", "alb_logic_fact_arg_lo", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_arg_hi", "alb_logic_fact_arg_hi", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_value_lo", "alb_logic_fact_value_lo", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_save_fact_value_hi", "alb_logic_fact_value_hi", Max_Logic_Facts);

         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_count"), Rev_Runtime_Label ("journal_count"), 1);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_block_depth"), Rev_Runtime_Label ("block_depth"), 1);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_opcode"), Rev_Runtime_Label ("journal_opcode"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_width"), Rev_Runtime_Label ("journal_width"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_target_lo"), Rev_Runtime_Label ("journal_target_lo"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_target_hi"), Rev_Runtime_Label ("journal_target_hi"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_old_lo"), Rev_Runtime_Label ("journal_old_lo"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_old_hi"), Rev_Runtime_Label ("journal_old_hi"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_aux_lo"), Rev_Runtime_Label ("journal_aux_lo"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_journal_aux_hi"), Rev_Runtime_Label ("journal_aux_hi"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("save_block_marks"), Rev_Runtime_Label ("block_marks"), Max_Rev_Block_Depth);
      else
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_active", "alb_logic_save_fact_active", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_pred_lo", "alb_logic_save_fact_pred_lo", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_pred_hi", "alb_logic_save_fact_pred_hi", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_arity", "alb_logic_save_fact_arity", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_arg_lo", "alb_logic_save_fact_arg_lo", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_arg_hi", "alb_logic_save_fact_arg_hi", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_value_lo", "alb_logic_save_fact_value_lo", Max_Logic_Facts);
         Emit_Copy_Label_Bytes (State, "alb_logic_fact_value_hi", "alb_logic_save_fact_value_hi", Max_Logic_Facts);

         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_count"), Rev_Runtime_Label ("save_journal_count"), 1);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("block_depth"), Rev_Runtime_Label ("save_block_depth"), 1);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_opcode"), Rev_Runtime_Label ("save_journal_opcode"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_width"), Rev_Runtime_Label ("save_journal_width"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_target_lo"), Rev_Runtime_Label ("save_journal_target_lo"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_target_hi"), Rev_Runtime_Label ("save_journal_target_hi"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_old_lo"), Rev_Runtime_Label ("save_journal_old_lo"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_old_hi"), Rev_Runtime_Label ("save_journal_old_hi"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_aux_lo"), Rev_Runtime_Label ("save_journal_aux_lo"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("journal_aux_hi"), Rev_Runtime_Label ("save_journal_aux_hi"), Max_Rev_Journal);
         Emit_Copy_Label_Bytes (State, Rev_Runtime_Label ("block_marks"), Rev_Runtime_Label ("save_block_marks"), Max_Rev_Block_Depth);
      end if;
   end Emit_Save_Load_State;

   procedure Emit_Assignable_Address
     (State            : in out Emitter_State;
      Target_Node      : Node_Index;
      Low_Label        : String;
      High_Label       : String;
      Width_Bytes_Out  : out Natural;
      Target_Kind_Out  : out Symbol_Kind)
   is
      Target_Symbol : Symbol_Index := 0;
      Member        : Member_Access_Record := (others => <>);
      Element       : Array_Access := (others => <>);
      Base_Buffer   : String (1 .. Max_Name_Length * 2) := (others => ' ');
      Base_Len      : Natural := 0;
   begin
      Width_Bytes_Out := 0;
      Target_Kind_Out := Symbol_U8;

      if Target_Node = 0 then
         Fail (State, Target_Node, "reversible target is missing");
         return;
      end if;

      if Tree (Target_Node).Kind = AST_Member_Expr then
         Analyze_Member_Access (State, Target_Node, Member);
         if not State.Success then
            return;
         end if;

         if Member.Kind = Member_Struct_Field then
            Target_Kind_Out := State.Symbols (Member.Symbol).Kind;
            Width_Bytes_Out :=
              (if Is_Byte_Scalar_Symbol (Target_Kind_Out) then 1 else 2);
            Append_Line (State, "    LDA #<" & Symbol_Name (State, Member.Symbol));
            Append_Line (State, "    STA " & Low_Label);
            Append_Line (State, "    LDA #>" & Symbol_Name (State, Member.Symbol));
            Append_Line (State, "    STA " & High_Label);
            return;
         elsif Member.Kind = Member_Parallel_Field then
            Target_Kind_Out := State.Symbols (Member.Element.Symbol).Kind;
            Width_Bytes_Out :=
              (if Is_U8_Array_Symbol (Target_Kind_Out) then 1 else 2);
            declare
               Name_Value : constant String := Symbol_Name (State, Member.Element.Symbol);
            begin
               Base_Len := Name_Value'Length;
               Base_Buffer (1 .. Base_Len) := Name_Value;
            end;
            Emit_Array_Index_Y_Load (State, Member.Element);
            if not State.Success then
               return;
            end if;
         else
            Fail (State, Target_Node, "unsupported reversible member target");
            return;
         end if;
      elsif Is_Var_Node (Target_Node) and then Is_Indexed_Var_Node (Target_Node) then
         Analyze_Array_Access (State, Target_Node, Element);
         if not State.Success then
            return;
         end if;
         Target_Kind_Out := State.Symbols (Element.Symbol).Kind;
         Width_Bytes_Out :=
           (if Is_U8_Array_Symbol (Target_Kind_Out) then 1 else 2);
         declare
            Name_Value : constant String := Symbol_Name (State, Element.Symbol);
         begin
            Base_Len := Name_Value'Length;
            Base_Buffer (1 .. Base_Len) := Name_Value;
         end;
         Emit_Array_Index_Y_Load (State, Element);
         if not State.Success then
            return;
         end if;
      elsif Is_Var_Node (Target_Node) then
         Target_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
         if Target_Symbol = 0 then
            Fail (State, Target_Node, "reversible target is not declared");
            return;
         end if;
         Target_Kind_Out := State.Symbols (Target_Symbol).Kind;
         Width_Bytes_Out :=
           (if Is_Byte_Scalar_Symbol (Target_Kind_Out) then 1 else 2);
         Append_Line (State, "    LDA #<" & Symbol_Name (State, Target_Symbol));
         Append_Line (State, "    STA " & Low_Label);
         Append_Line (State, "    LDA #>" & Symbol_Name (State, Target_Symbol));
         Append_Line (State, "    STA " & High_Label);
         return;
      else
         Fail (State, Target_Node, "reversible target must be a variable, array element, or member");
         return;
      end if;

      Append_Line (State, "    TYA");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #<" & Base_Buffer (1 .. Base_Len));
      Append_Line (State, "    STA " & Low_Label);
      Append_Line (State, "    LDA #>" & Base_Buffer (1 .. Base_Len));
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA " & High_Label);
   end Emit_Assignable_Address;

   procedure Emit_Reversible_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Left_Width  : Natural := 0;
      Right_Width : Natural := 0;
      Left_Kind   : Symbol_Kind := Symbol_U8;
      Right_Kind  : Symbol_Kind := Symbol_U8;

      procedure Set_Opcode_And_Width
        (Opcode      : Natural;
         Width_Bytes : Natural)
      is
      begin
         Append_Line (State, "    LDA #" & Byte_Hex (Opcode));
         Append_Line (State, "    STA " & Rev_Runtime_Label ("opcode"));
         Append_Line (State, "    LDA #" & Byte_Hex (Width_Bytes));
         Append_Line (State, "    STA " & Rev_Runtime_Label ("width"));
      end Set_Opcode_And_Width;

      procedure Emit_Operand
        (Expr_Node    : Node_Index;
         Width_Bytes  : Natural;
         Rotate_Only  : Boolean := False)
      is
      begin
         if Width_Bytes = 1 or else Rotate_Only then
            Emit_Byte_Expr (State, Expr_Node);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA " & Rev_Runtime_Label ("operand_lo"));
            Append_Line (State, "    LDA #$00");
            Append_Line (State, "    STA " & Rev_Runtime_Label ("operand_hi"));
         else
            Emit_Word_Expr (State, Expr_Node);
            if not State.Success then
               return;
            end if;
            Append_Line (State, "    STA " & Rev_Runtime_Label ("operand_lo"));
            Append_Line (State, "    STX " & Rev_Runtime_Label ("operand_hi"));
         end if;
      end Emit_Operand;
   begin
      if State.Reversible_Depth = 0 then
         Fail (State, Node, "REV operation requires REVERSIBLE block");
         return;
      end if;

      Emit_Assignable_Address
        (State,
         Tree (Node).Left_Child,
         Rev_Runtime_Label ("target_lo"),
         Rev_Runtime_Label ("target_hi"),
         Left_Width,
         Left_Kind);
      if not State.Success then
         return;
      end if;

      if Left_Kind = Symbol_String then
         Fail (State, Node, "REV operations do not support STRING/BINARY targets on ALB-65");
         return;
      end if;

      case Tree (Node).Kind is
         when AST_Rev_Add_Stmt =>
            Emit_Operand (Tree (Node).Right_Child, Left_Width);
            if not State.Success then
               return;
            end if;
            Set_Opcode_And_Width (1, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_add"));

         when AST_Rev_Sub_Stmt =>
            Emit_Operand (Tree (Node).Right_Child, Left_Width);
            if not State.Success then
               return;
            end if;
            Set_Opcode_And_Width (2, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_sub"));

         when AST_Rev_Xor_Stmt =>
            Emit_Operand (Tree (Node).Right_Child, Left_Width);
            if not State.Success then
               return;
            end if;
            Set_Opcode_And_Width (3, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_xor"));

         when AST_Rev_Rol_Stmt =>
            Emit_Operand (Tree (Node).Right_Child, Left_Width, Rotate_Only => True);
            if not State.Success then
               return;
            end if;
            Set_Opcode_And_Width (4, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_rol"));

         when AST_Rev_Ror_Stmt =>
            Emit_Operand (Tree (Node).Right_Child, Left_Width, Rotate_Only => True);
            if not State.Success then
               return;
            end if;
            Set_Opcode_And_Width (5, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_ror"));

         when AST_Rev_Not_Stmt =>
            Set_Opcode_And_Width (6, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_not"));

         when AST_Rev_Neg_Stmt =>
            Set_Opcode_And_Width (7, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_neg"));

         when AST_Rev_Swap_Stmt =>
            Emit_Assignable_Address
              (State,
               Tree (Node).Right_Child,
               Rev_Runtime_Label ("other_lo"),
               Rev_Runtime_Label ("other_hi"),
               Right_Width,
               Right_Kind);
            if not State.Success then
               return;
            end if;
            if Right_Kind = Symbol_String then
               Fail (State, Node, "REVSWAP does not support STRING/BINARY targets on ALB-65");
               return;
            elsif Left_Width /= Right_Width then
               Fail (State, Node, "REVSWAP requires both targets to use the same width");
               return;
            end if;
            Set_Opcode_And_Width (8, Left_Width);
            Append_Line (State, "    JSR " & Rev_Runtime_Label ("apply_swap"));

         when others =>
            Fail (State, Node, "unsupported REV statement for ALB-65");
      end case;
   end Emit_Reversible_Stmt;

   procedure Emit_Event_Definitions
     (State : in out Emitter_State)
   is
      Saved_Procedure : constant Natural := State.Current_Procedure;
   begin
      Append_Line (State, "");
      Append_Line (State, "alb_on_tick:");
      if State.On_Tick_Node /= 0 then
         State.Current_Procedure := 0;
         Emit_Node_Chain (State, State.On_Tick_Node);
         if not State.Success then
            return;
         end if;
      end if;
      Append_Line (State, "    RTS");

      Append_Line (State, "");
      Append_Line (State, "alb_on_paint:");
      if State.On_Paint_Node /= 0 then
         State.Current_Procedure := 0;
         Emit_Node_Chain (State, State.On_Paint_Node);
         if not State.Success then
            return;
         end if;
      end if;
      Append_Line (State, "    RTS");

      Append_Line (State, "");
      Append_Line (State, "alb_on_key:");
      if State.On_Key_Node /= 0 then
         State.Current_Procedure := 0;
         Emit_Node_Chain (State, State.On_Key_Node);
         if not State.Success then
            return;
         end if;
      end if;
      Append_Line (State, "    RTS");

      Append_Line (State, "");
      Append_Line (State, "alb_on_knows_change:");
      for I in 1 .. State.Logic_Hook_Count loop
         if State.Logic_Hooks (I).Active then
            Append_Line
              (State,
               "    LDA alb_logic_notify_pred_lo");
            Append_Line
              (State,
               "    CMP #" & Byte_Hex (Low_Byte (State.Logic_Hooks (I).Pred_Id)));
            Append_Line
              (State,
               "    BNE alb_logic_hook_next_" & Decimal_Image (State.Logic_Hooks (I).Label_Id));
            Append_Line
              (State,
               "    LDA alb_logic_notify_pred_hi");
            Append_Line
              (State,
               "    CMP #" & Byte_Hex (High_Byte (State.Logic_Hooks (I).Pred_Id)));
            Append_Line
              (State,
               "    BNE alb_logic_hook_next_" & Decimal_Image (State.Logic_Hooks (I).Label_Id));
            Append_Line
              (State,
               "    JSR alb_logic_hook_" & Decimal_Image (State.Logic_Hooks (I).Label_Id));
            Append_Line
              (State,
               "alb_logic_hook_next_" & Decimal_Image (State.Logic_Hooks (I).Label_Id) & ":");
         end if;
      end loop;
      Append_Line (State, "    RTS");

      for I in 1 .. State.Logic_Hook_Count loop
         if State.Logic_Hooks (I).Active then
            Append_Line (State, "");
            Append_Line
              (State,
               "alb_logic_hook_" & Decimal_Image (State.Logic_Hooks (I).Label_Id) & ":");
            if State.Logic_Hooks (I).Arg_Symbol /= 0 then
               Append_Line (State, "    LDA alb_logic_notify_arg_lo");
               Append_Line
                 (State,
                  "    STA " & Symbol_Name (State, State.Logic_Hooks (I).Arg_Symbol));
               Append_Line (State, "    LDA alb_logic_notify_arg_hi");
               Append_Line
                 (State,
                  "    STA " & Symbol_Name (State, State.Logic_Hooks (I).Arg_Symbol) & "+1");
            end if;
            if State.Logic_Hooks (I).Block_Node /= 0 then
               State.Current_Procedure := 0;
               Emit_Node_Chain (State, State.Logic_Hooks (I).Block_Node);
               if not State.Success then
                  return;
               end if;
            end if;
            Append_Line (State, "    RTS");
         end if;
      end loop;

      State.Current_Procedure := Saved_Procedure;
   end Emit_Event_Definitions;

   procedure Emit_Foreach_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Iter_Symbol   : Symbol_Index := 0;
      Collection    : Symbol_Index := 0;
      Loop_Id       : Natural := 0;
      Bound         : Natural := 0;
   begin
      if Tree (Node).Token_Index = 0 then
         Fail (State, Node, "FOREACH iterator is missing");
         return;
      end if;

      Iter_Symbol := Find_Visible_Symbol (State, Token_Lexeme (Tree (Node).Token_Index));
      if Iter_Symbol = 0 then
         Fail (State, Node, "FOREACH iterator was not registered");
         return;
      end if;

      if not Is_Var_Node (Tree (Node).Left_Child)
        or else Is_Indexed_Var_Node (Tree (Node).Left_Child)
      then
         Fail (State, Node, "FOREACH currently supports only declared array variables");
         return;
      end if;

      Collection := Find_Visible_Symbol (State, Node_Lexeme (Tree (Node).Left_Child));
      if Collection = 0 or else not Is_Array_Symbol (State.Symbols (Collection).Kind) then
         Fail (State, Node, "FOREACH currently supports only STRICT/SLIDE arrays");
         return;
      end if;

      Bound := Array_Visible_Length (State.Symbols (Collection));
      Reserve_Label_Id (State, Loop_Id);
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_foreach_index");
      Append_Line (State, Loop_Top_Label (Loop_Id) & ":");
      Append_Line (State, "    LDA alb_foreach_index");
      Append_Line (State, "    CMP #" & Byte_Hex (Bound + 1));
      Append_Line (State, "    BCS " & Loop_End_Label (Loop_Id));

      if Is_U8_Array_Symbol (State.Symbols (Collection).Kind) then
         Append_Line (State, "    LDY alb_foreach_index");
         Append_Line (State, "    DEY");
         Append_Line (State, "    LDA " & Symbol_Name (State, Collection) & ",Y");
         Append_Line (State, "    STA " & Symbol_Name (State, Iter_Symbol));
      else
         Append_Line (State, "    LDA alb_foreach_index");
         Append_Line (State, "    SEC");
         Append_Line (State, "    SBC #$01");
         Append_Line (State, "    ASL A");
         Append_Line (State, "    TAY");
         Append_Line (State, "    LDA " & Symbol_Name (State, Collection) & ",Y");
         Append_Line (State, "    STA " & Symbol_Name (State, Iter_Symbol));
         Append_Line (State, "    INY");
         Append_Line (State, "    LDA " & Symbol_Name (State, Collection) & ",Y");
         Append_Line (State, "    STA " & Symbol_Name (State, Iter_Symbol) & "+1");
      end if;

      Push_Loop_Context (State, Loop_Id, 0);
      if not State.Success then
         return;
      end if;
      Emit_Node_Chain (State, Tree (Node).Right_Child);
      Pop_Loop_Context (State);
      if not State.Success then
         return;
      end if;

      Append_Line (State, Loop_Continue_Label (Loop_Id) & ":");
      Append_Line (State, "    INC alb_foreach_index");
      Append_Line (State, "    JMP " & Loop_Top_Label (Loop_Id));
      Append_Line (State, Loop_End_Label (Loop_Id) & ":");
   end Emit_Foreach_Stmt;

   procedure Emit_SwapPop_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Target_Node   : constant Node_Index := Tree (Node).Left_Child;
      Count_Node    : constant Node_Index := Tree (Node).Right_Child;
      Group_Symbol  : Symbol_Index := 0;
      Group_Id      : Natural := 0;
      Count_Symbol  : Symbol_Index := 0;
      Skip_Copy_Id  : Natural := 0;
      Done_Id       : Natural := 0;
      Field_Symbol  : Symbol_Index := 0;
   begin
      if not Is_Var_Node (Target_Node) or else not Is_Indexed_Var_Node (Target_Node) then
         Fail (State, Node, "SWAPPOP requires a parallel slot target like group[idx]");
         return;
      end if;

      Group_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
      if Group_Symbol = 0 or else State.Symbols (Group_Symbol).Kind /= Symbol_Parallel_Group then
         Fail (State, Node, "SWAPPOP target must be a declared PARALLEL group");
         return;
      end if;

      if Tree (Tree (Target_Node).Left_Child).Next_Sibling /= 0 then
         Fail (State, Node, "SWAPPOP currently supports one-dimensional parallel groups");
         return;
      end if;

      if not Is_Var_Node (Count_Node) or else Is_Indexed_Var_Node (Count_Node) then
         Fail (State, Node, "SWAPPOP live-count must be a scalar variable");
         return;
      end if;

      Count_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Count_Node));
      if Count_Symbol = 0 then
         Fail (State, Node, "SWAPPOP live-count is not declared");
         return;
      end if;

      Group_Id := State.Symbols (Group_Symbol).Parallel_Id;
      Reserve_Label_Id (State, Done_Id);
      Reserve_Label_Id (State, Skip_Copy_Id);
      Append_Line (State, "    LDA " & Symbol_Name (State, Count_Symbol));
      Append_Line (State, "    BEQ alb_swappop_done_" & Decimal_Image (Done_Id));
      Append_Line (State, "    STA alb_swappop_count");

      Emit_Byte_Expr (State, Tree (Target_Node).Left_Child);
      if not State.Success then
         return;
      end if;
      Append_Line (State, "    STA alb_swappop_index");
      Append_Line (State, "    CMP alb_swappop_count");
      Append_Line (State, "    BEQ alb_swappop_skip_" & Decimal_Image (Skip_Copy_Id));

      for I in 1 .. State.Parallel_Groups (Group_Id).Field_Count loop
         Field_Symbol := State.Parallel_Groups (Group_Id).Fields (I).Backing_Symbol;

         Append_Line (State, "    LDY alb_swappop_count");
         Append_Line (State, "    DEY");
         if Is_U16_Array_Symbol (State.Symbols (Field_Symbol).Kind) then
            Append_Line (State, "    TYA");
            Append_Line (State, "    ASL A");
            Append_Line (State, "    TAY");
         end if;
         Append_Line (State, "    LDA " & Symbol_Name (State, Field_Symbol) & ",Y");
         Append_Line (State, "    STA alb_tmp_u16_lo");
         if Is_U16_Array_Symbol (State.Symbols (Field_Symbol).Kind) then
            Append_Line (State, "    INY");
            Append_Line (State, "    LDA " & Symbol_Name (State, Field_Symbol) & ",Y");
            Append_Line (State, "    STA alb_tmp_u16_hi");
         end if;

         Append_Line (State, "    LDY alb_swappop_index");
         Append_Line (State, "    DEY");
         if Is_U16_Array_Symbol (State.Symbols (Field_Symbol).Kind) then
            Append_Line (State, "    TYA");
            Append_Line (State, "    ASL A");
            Append_Line (State, "    TAY");
         end if;
         Append_Line (State, "    LDA alb_tmp_u16_lo");
         Append_Line (State, "    STA " & Symbol_Name (State, Field_Symbol) & ",Y");
         if Is_U16_Array_Symbol (State.Symbols (Field_Symbol).Kind) then
            Append_Line (State, "    INY");
            Append_Line (State, "    LDA alb_tmp_u16_hi");
            Append_Line (State, "    STA " & Symbol_Name (State, Field_Symbol) & ",Y");
         end if;
      end loop;

      Append_Line (State, "alb_swappop_skip_" & Decimal_Image (Skip_Copy_Id) & ":");
      Append_Line (State, "    DEC " & Symbol_Name (State, Count_Symbol));
      Append_Line (State, "alb_swappop_done_" & Decimal_Image (Done_Id) & ":");
   end Emit_SwapPop_Stmt;

   procedure Emit_Runtime_Support (State : in out Emitter_State) is
      type Key_Shift_Mode is (Shift_Any, Shift_None, Shift_Required);

      type Key_Map_Record is record
         Code       : Natural range 0 .. 255;
         Column     : Natural range 0 .. 7;
         Row        : Natural range 0 .. 7;
         Shift_Mode : Key_Shift_Mode := Shift_Any;
      end record;

      type Key_Map_Array is array (Positive range <>) of Key_Map_Record;

      C64_Key_Maps : constant Key_Map_Array :=
        ((Code => 4,   Column => 1, Row => 2, Shift_Mode => Shift_Any),
         (Code => 5,   Column => 3, Row => 4, Shift_Mode => Shift_Any),
         (Code => 6,   Column => 2, Row => 4, Shift_Mode => Shift_Any),
         (Code => 7,   Column => 2, Row => 2, Shift_Mode => Shift_Any),
         (Code => 8,   Column => 1, Row => 6, Shift_Mode => Shift_Any),
         (Code => 9,   Column => 2, Row => 5, Shift_Mode => Shift_Any),
         (Code => 10,  Column => 3, Row => 2, Shift_Mode => Shift_Any),
         (Code => 11,  Column => 3, Row => 5, Shift_Mode => Shift_Any),
         (Code => 12,  Column => 4, Row => 1, Shift_Mode => Shift_Any),
         (Code => 13,  Column => 4, Row => 2, Shift_Mode => Shift_Any),
         (Code => 14,  Column => 4, Row => 5, Shift_Mode => Shift_Any),
         (Code => 15,  Column => 5, Row => 2, Shift_Mode => Shift_Any),
         (Code => 16,  Column => 4, Row => 4, Shift_Mode => Shift_Any),
         (Code => 17,  Column => 4, Row => 7, Shift_Mode => Shift_Any),
         (Code => 18,  Column => 4, Row => 6, Shift_Mode => Shift_Any),
         (Code => 19,  Column => 5, Row => 1, Shift_Mode => Shift_Any),
         (Code => 20,  Column => 7, Row => 6, Shift_Mode => Shift_Any),
         (Code => 21,  Column => 2, Row => 1, Shift_Mode => Shift_Any),
         (Code => 22,  Column => 1, Row => 5, Shift_Mode => Shift_Any),
         (Code => 23,  Column => 2, Row => 6, Shift_Mode => Shift_Any),
         (Code => 24,  Column => 3, Row => 6, Shift_Mode => Shift_Any),
         (Code => 25,  Column => 3, Row => 7, Shift_Mode => Shift_Any),
         (Code => 26,  Column => 1, Row => 1, Shift_Mode => Shift_Any),
         (Code => 27,  Column => 2, Row => 7, Shift_Mode => Shift_Any),
         (Code => 28,  Column => 3, Row => 1, Shift_Mode => Shift_Any),
         (Code => 29,  Column => 1, Row => 4, Shift_Mode => Shift_Any),
         (Code => 30,  Column => 7, Row => 0, Shift_Mode => Shift_Any),
         (Code => 31,  Column => 7, Row => 3, Shift_Mode => Shift_Any),
         (Code => 32,  Column => 1, Row => 0, Shift_Mode => Shift_Any),
         (Code => 33,  Column => 1, Row => 3, Shift_Mode => Shift_Any),
         (Code => 34,  Column => 2, Row => 0, Shift_Mode => Shift_Any),
         (Code => 35,  Column => 2, Row => 3, Shift_Mode => Shift_Any),
         (Code => 36,  Column => 3, Row => 0, Shift_Mode => Shift_Any),
         (Code => 37,  Column => 3, Row => 3, Shift_Mode => Shift_Any),
         (Code => 38,  Column => 4, Row => 0, Shift_Mode => Shift_Any),
         (Code => 39,  Column => 4, Row => 3, Shift_Mode => Shift_Any),
         (Code => 40,  Column => 0, Row => 1, Shift_Mode => Shift_Any),
         (Code => 41,  Column => 7, Row => 7, Shift_Mode => Shift_Any),
         (Code => 44,  Column => 7, Row => 4, Shift_Mode => Shift_Any),
         (Code => 79,  Column => 0, Row => 2, Shift_Mode => Shift_None),
         (Code => 80,  Column => 0, Row => 2, Shift_Mode => Shift_Required),
         (Code => 81,  Column => 0, Row => 7, Shift_Mode => Shift_None),
         (Code => 82,  Column => 0, Row => 7, Shift_Mode => Shift_Required),
         (Code => 224, Column => 7, Row => 2, Shift_Mode => Shift_Any),
         (Code => 225, Column => 1, Row => 7, Shift_Mode => Shift_Any),
         (Code => 226, Column => 7, Row => 5, Shift_Mode => Shift_Any),
         (Code => 228, Column => 7, Row => 2, Shift_Mode => Shift_Any),
         (Code => 229, Column => 6, Row => 4, Shift_Mode => Shift_Any),
         (Code => 230, Column => 7, Row => 5, Shift_Mode => Shift_Any));

      function Column_Select_Mask (Column : Natural) return Natural is
      begin
         case Column is
            when 0 => return 16#FE#;
            when 1 => return 16#FD#;
            when 2 => return 16#FB#;
            when 3 => return 16#F7#;
            when 4 => return 16#EF#;
            when 5 => return 16#DF#;
            when 6 => return 16#BF#;
            when 7 => return 16#7F#;
            when others => return 16#FF#;
         end case;
      end Column_Select_Mask;

      function Row_Bit_Mask (Row : Natural) return Natural is
      begin
         case Row is
            when 0 => return 16#01#;
            when 1 => return 16#02#;
            when 2 => return 16#04#;
            when 3 => return 16#08#;
            when 4 => return 16#10#;
            when 5 => return 16#20#;
            when 6 => return 16#40#;
            when 7 => return 16#80#;
            when others => return 16#00#;
         end case;
      end Row_Bit_Mask;

      procedure Append_Key_State_Update
        (Map   : Key_Map_Record;
         Index : Positive)
      is
         Base_Label : constant String := "alb_poll_key_" & Decimal_Image (Index);
         Down_Label : constant String := Base_Label & "_down";
         Up_Label   : constant String := Base_Label & "_up";
         Done_Label : constant String := Base_Label & "_done";
         State_Ref  : constant String :=
           "alb_key_state+" & Decimal_Image (Map.Code);
         Prev_Ref   : constant String :=
           "alb_prev_key_state+" & Decimal_Image (Map.Code);
      begin
         Append_Line
           (State,
            "    LDA alb_key_matrix_" & Decimal_Image (Map.Column));
         Append_Line
           (State,
            "    AND #" & Byte_Hex (Row_Bit_Mask (Map.Row)));
         Append_Line (State, "    BNE " & Up_Label);

         case Map.Shift_Mode is
            when Shift_None =>
               Append_Line (State, "    LDA alb_shift_state");
               Append_Line (State, "    BNE " & Up_Label);
            when Shift_Required =>
               Append_Line (State, "    LDA alb_shift_state");
               Append_Line (State, "    BEQ " & Up_Label);
            when others =>
               null;
         end case;

         Append_Line (State, Down_Label & ":");
         Append_Line (State, "    LDA #$01");
         Append_Line (State, "    STA " & State_Ref);
         Append_Line (State, "    LDA " & Prev_Ref);
         Append_Line (State, "    BNE " & Done_Label);
         Append_Line (State, "    LDA #" & Byte_Hex (Map.Code));
         Append_Line (State, "    JSR alb_latch_key");
         Append_Line (State, "    JMP " & Done_Label);
         Append_Line (State, Up_Label & ":");
         Append_Line (State, "    LDA #$00");
         Append_Line (State, "    STA " & State_Ref);
         Append_Line (State, Done_Label & ":");
      end Append_Key_State_Update;
   begin
      Append_Line (State, "");
      Append_Line (State, "alb_print_newline:");
      Append_Line (State, "    LDA #$0D");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_print_string:");
      Append_Line (State, "    STX ZP_IO_PTR");
      Append_Line (State, "    STY ZP_IO_PTR+1");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "alb_print_string_loop:");
      Append_Line (State, "    LDA (ZP_IO_PTR),Y");
      Append_Line (State, "    BEQ alb_print_string_done");
      Append_Line (State, "    TYA");
      Append_Line (State, "    PHA");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    PLA");
      Append_Line (State, "    TAY");
      Append_Line (State, "    INY");
      Append_Line (State, "    BNE alb_print_string_loop");
      Append_Line (State, "    INC ZP_IO_PTR+1");
      Append_Line (State, "    JMP alb_print_string_loop");
      Append_Line (State, "alb_print_string_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_print_u8:");
      Append_Line (State, "    STA alb_print_value");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_print_hundreds");
      Append_Line (State, "    STA alb_print_tens");
      Append_Line (State, "alb_print_u8_hundreds:");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CMP #100");
      Append_Line (State, "    BCC alb_print_u8_tens");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #100");
      Append_Line (State, "    STA alb_print_value");
      Append_Line (State, "    INC alb_print_hundreds");
      Append_Line (State, "    JMP alb_print_u8_hundreds");
      Append_Line (State, "alb_print_u8_tens:");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CMP #10");
      Append_Line (State, "    BCC alb_print_u8_units");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #10");
      Append_Line (State, "    STA alb_print_value");
      Append_Line (State, "    INC alb_print_tens");
      Append_Line (State, "    JMP alb_print_u8_tens");
      Append_Line (State, "alb_print_u8_units:");
      Append_Line (State, "    LDA alb_print_hundreds");
      Append_Line (State, "    BEQ alb_print_u8_maybe_tens");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    LDA alb_print_tens");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_print_u8_maybe_tens:");
      Append_Line (State, "    LDA alb_print_tens");
      Append_Line (State, "    BEQ alb_print_u8_ones");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "alb_print_u8_ones:");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_print_u16:");
      Append_Line (State, "    STA alb_tmp_u16_lo");
      Append_Line (State, "    STX alb_tmp_u16_hi");
      Append_Line (State, "    LDA alb_tmp_u16_hi");
      Append_Line (State, "    BNE alb_print_u16_full");
      Append_Line (State, "    LDA alb_tmp_u16_lo");
      Append_Line (State, "    JMP alb_print_u8");
      Append_Line (State, "alb_print_u16_full:");
      Append_Line (State, "    LDX #$05");
      Append_Line (State, "alb_print_u16_digits:");
      Append_Line (State, "    LDA alb_tmp_u16_lo");
      Append_Line (State, "    STA alb_math_w_lhs");
      Append_Line (State, "    LDA alb_tmp_u16_hi");
      Append_Line (State, "    STA alb_math_w_lhs+1");
      Append_Line (State, "    LDA #$0A");
      Append_Line (State, "    STA alb_math_w_rhs");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_math_w_rhs+1");
      Append_Line (State, "    JSR alb_div_u16");
      Append_Line (State, "    PHA");
      Append_Line (State, "    LDA alb_math_w_lhs");
      Append_Line (State, "    STA alb_tmp_u16_lo");
      Append_Line (State, "    LDA alb_math_w_lhs+1");
      Append_Line (State, "    STA alb_tmp_u16_hi");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_print_u16_digits");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_print_hundreds");
      Append_Line (State, "    LDY #$05");
      Append_Line (State, "alb_print_u16_out:");
      Append_Line (State, "    PLA");
      Append_Line (State, "    LDA alb_print_hundreds");
      Append_Line (State, "    BNE alb_print_u16_emit");
      Append_Line (State, "    CMP #$00");
      Append_Line (State, "    BNE alb_print_u16_emit");
      Append_Line (State, "    DEY");
      Append_Line (State, "    BNE alb_print_u16_out");
      Append_Line (State, "    LDA #'0'");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_print_u16_emit:");
      Append_Line (State, "    INC alb_print_hundreds");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR KERNAL_CHROUT");
      Append_Line (State, "    DEY");
      Append_Line (State, "    BNE alb_print_u16_out");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_text_u16:");
      Append_Line (State, "    JSR alb_print_u16");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_ascii_to_screen:");
      Append_Line (State, "    CMP #$61");
      Append_Line (State, "    BCC alb_ascii_upper");
      Append_Line (State, "    CMP #$7B");
      Append_Line (State, "    BCS alb_ascii_upper");
      Append_Line (State, "    AND #$DF");
      Append_Line (State, "alb_ascii_upper:");
      Append_Line (State, "    CMP #$41");
      Append_Line (State, "    BCC alb_ascii_done");
      Append_Line (State, "    CMP #$5B");
      Append_Line (State, "    BCS alb_ascii_done");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #$40");
      Append_Line (State, "alb_ascii_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_text_putc:");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDX alb_text_y");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDY alb_text_x");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    JSR alb_ascii_to_screen");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_draw_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INC alb_text_x");
      Append_Line (State, "    LDA alb_text_x");
      Append_Line (State, "    CMP #40");
      Append_Line (State, "    BCC alb_text_putc_done");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_text_x");
      Append_Line (State, "    INC alb_text_y");
      Append_Line (State, "    LDA alb_text_y");
      Append_Line (State, "    CMP #25");
      Append_Line (State, "    BCC alb_text_putc_done");
      Append_Line (State, "    LDA #24");
      Append_Line (State, "    STA alb_text_y");
      Append_Line (State, "alb_text_putc_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_text_string:");
      Append_Line (State, "    STX ZP_IO_PTR");
      Append_Line (State, "    STY ZP_IO_PTR+1");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "alb_text_string_loop:");
      Append_Line (State, "    LDA (ZP_IO_PTR),Y");
      Append_Line (State, "    BEQ alb_text_string_done");
      Append_Line (State, "    TYA");
      Append_Line (State, "    PHA");
      Append_Line (State, "    LDA (ZP_IO_PTR),Y");
      Append_Line (State, "    JSR alb_text_putc");
      Append_Line (State, "    PLA");
      Append_Line (State, "    TAY");
      Append_Line (State, "    INY");
      Append_Line (State, "    BNE alb_text_string_loop");
      Append_Line (State, "    INC ZP_IO_PTR+1");
      Append_Line (State, "    JMP alb_text_string_loop");
      Append_Line (State, "alb_text_string_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_text_u8:");
      Append_Line (State, "    STA alb_print_value");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_print_hundreds");
      Append_Line (State, "    STA alb_print_tens");
      Append_Line (State, "alb_text_u8_hundreds:");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CMP #100");
      Append_Line (State, "    BCC alb_text_u8_tens");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #100");
      Append_Line (State, "    STA alb_print_value");
      Append_Line (State, "    INC alb_print_hundreds");
      Append_Line (State, "    JMP alb_text_u8_hundreds");
      Append_Line (State, "alb_text_u8_tens:");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CMP #10");
      Append_Line (State, "    BCC alb_text_u8_units");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #10");
      Append_Line (State, "    STA alb_print_value");
      Append_Line (State, "    INC alb_print_tens");
      Append_Line (State, "    JMP alb_text_u8_tens");
      Append_Line (State, "alb_text_u8_units:");
      Append_Line (State, "    LDA alb_print_hundreds");
      Append_Line (State, "    BEQ alb_text_u8_maybe_tens");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR alb_text_putc");
      Append_Line (State, "    LDA alb_print_tens");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR alb_text_putc");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR alb_text_putc");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_text_u8_maybe_tens:");
      Append_Line (State, "    LDA alb_print_tens");
      Append_Line (State, "    BEQ alb_text_u8_ones");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR alb_text_putc");
      Append_Line (State, "alb_text_u8_ones:");
      Append_Line (State, "    LDA alb_print_value");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$30");
      Append_Line (State, "    JSR alb_text_putc");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_mul_u8:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    LDX #$08");
      Append_Line (State, "alb_mul_u8_loop:");
      Append_Line (State, "    LSR alb_math_rhs");
      Append_Line (State, "    BCC alb_mul_u8_skip");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_math_lhs");
      Append_Line (State, "alb_mul_u8_skip:");
      Append_Line (State, "    ASL alb_math_lhs");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_mul_u8_loop");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_div_u8:");
      Append_Line (State, "    LDA alb_math_rhs");
      Append_Line (State, "    BNE alb_div_u8_nonzero");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_div_u8_nonzero:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_math_w_acc");
      Append_Line (State, "    STA alb_math_w_acc+1");
      Append_Line (State, "    STA alb_math_rem");
      Append_Line (State, "    LDX #$08");
      Append_Line (State, "alb_div_u8_loop:");
      Append_Line (State, "    ASL alb_math_lhs");
      Append_Line (State, "    ROL alb_math_rem");
      Append_Line (State, "    ASL alb_math_w_acc");
      Append_Line (State, "    LDA alb_math_rem");
      Append_Line (State, "    CMP alb_math_rhs");
      Append_Line (State, "    BCC alb_div_u8_next");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_math_rhs");
      Append_Line (State, "    STA alb_math_rem");
      Append_Line (State, "    LDA alb_math_w_acc");
      Append_Line (State, "    ORA #$01");
      Append_Line (State, "    STA alb_math_w_acc");
      Append_Line (State, "alb_div_u8_next:");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_div_u8_loop");
      Append_Line (State, "alb_div_u8_done:");
      Append_Line (State, "    LDA alb_math_rem");
      Append_Line (State, "    STA alb_math_lhs");
      Append_Line (State, "    LDA alb_math_w_acc");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_mod_u8:");
      Append_Line (State, "    JSR alb_div_u8");
      Append_Line (State, "    LDA alb_math_lhs");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_mul_u16:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_math_w_acc");
      Append_Line (State, "    STA alb_math_w_acc+1");
      Append_Line (State, "    LDX #$10");
      Append_Line (State, "alb_mul_u16_loop:");
      Append_Line (State, "    LSR alb_math_w_rhs+1");
      Append_Line (State, "    ROR alb_math_w_rhs");
      Append_Line (State, "    BCC alb_mul_u16_skip");
      Append_Line (State, "    LDA alb_math_w_lhs");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_math_w_acc");
      Append_Line (State, "    STA alb_math_w_acc");
      Append_Line (State, "    LDA alb_math_w_lhs+1");
      Append_Line (State, "    ADC alb_math_w_acc+1");
      Append_Line (State, "    STA alb_math_w_acc+1");
      Append_Line (State, "alb_mul_u16_skip:");
      Append_Line (State, "    ASL alb_math_w_lhs");
      Append_Line (State, "    ROL alb_math_w_lhs+1");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_mul_u16_loop");
      Append_Line (State, "alb_mul_u16_done:");
      Append_Line (State, "    LDA alb_math_w_acc");
      Append_Line (State, "    LDX alb_math_w_acc+1");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_div_u16:");
      Append_Line (State, "    LDA alb_math_w_rhs");
      Append_Line (State, "    ORA alb_math_w_rhs+1");
      Append_Line (State, "    BNE alb_div_u16_nonzero");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_div_u16_nonzero:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_math_w_acc");
      Append_Line (State, "    STA alb_math_w_acc+1");
      Append_Line (State, "    STA alb_math_w_rem");
      Append_Line (State, "    STA alb_math_w_rem+1");
      Append_Line (State, "    LDX #$10");
      Append_Line (State, "alb_div_u16_loop:");
      Append_Line (State, "    ASL alb_math_w_lhs");
      Append_Line (State, "    ROL alb_math_w_lhs+1");
      Append_Line (State, "    ROL alb_math_w_rem");
      Append_Line (State, "    ROL alb_math_w_rem+1");
      Append_Line (State, "    ASL alb_math_w_acc");
      Append_Line (State, "    ROL alb_math_w_acc+1");
      Append_Line (State, "    LDA alb_math_w_rem+1");
      Append_Line (State, "    CMP alb_math_w_rhs+1");
      Append_Line (State, "    BCC alb_div_u16_next");
      Append_Line (State, "    BNE alb_div_u16_ge");
      Append_Line (State, "    LDA alb_math_w_rem");
      Append_Line (State, "    CMP alb_math_w_rhs");
      Append_Line (State, "    BCC alb_div_u16_next");
      Append_Line (State, "alb_div_u16_ge:");
      Append_Line (State, "    LDA alb_math_w_rem");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_math_w_rhs");
      Append_Line (State, "    STA alb_math_w_rem");
      Append_Line (State, "    LDA alb_math_w_rem+1");
      Append_Line (State, "    SBC alb_math_w_rhs+1");
      Append_Line (State, "    STA alb_math_w_rem+1");
      Append_Line (State, "    LDA alb_math_w_acc");
      Append_Line (State, "    ORA #$01");
      Append_Line (State, "    STA alb_math_w_acc");
      Append_Line (State, "alb_div_u16_next:");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_div_u16_loop");
      Append_Line (State, "alb_div_u16_done:");
      Append_Line (State, "    LDA alb_math_w_rem");
      Append_Line (State, "    STA alb_math_w_lhs");
      Append_Line (State, "    LDA alb_math_w_rem+1");
      Append_Line (State, "    STA alb_math_w_lhs+1");
      Append_Line (State, "    LDA alb_math_w_acc");
      Append_Line (State, "    LDX alb_math_w_acc+1");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_mod_u16:");
      Append_Line (State, "    JSR alb_div_u16");
      Append_Line (State, "    LDA alb_math_w_lhs");
      Append_Line (State, "    LDX alb_math_w_lhs+1");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_file_open:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_file_len");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (alb_file_mode_ptr),Y");
      Append_Line (State, "    CMP #$77");
      Append_Line (State, "    BEQ alb_file_open_reset");
      Append_Line (State, "    CMP #$57");
      Append_Line (State, "    BEQ alb_file_open_reset");
      Append_Line (State, "    CMP #$61");
      Append_Line (State, "    BEQ alb_file_open_done");
      Append_Line (State, "    CMP #$41");
      Append_Line (State, "    BNE alb_file_open_done");
      Append_Line (State, "alb_file_open_reset:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_file_buf");
      Append_Line (State, "alb_file_open_done:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_file_write:");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "alb_file_write_loop:");
      Append_Line (State, "    LDA (ZP_IO_PTR),Y");
      Append_Line (State, "    BEQ alb_file_write_done");
      Append_Line (State, "    LDX alb_file_len");
      Append_Line (State, "    CPX #$FE");
      Append_Line (State, "    BCS alb_file_write_done");
      Append_Line (State, "    STA alb_file_buf,X");
      Append_Line (State, "    INX");
      Append_Line (State, "    STX alb_file_len");
      Append_Line (State, "    INY");
      Append_Line (State, "    BNE alb_file_write_loop");
      Append_Line (State, "alb_file_write_done:");
      Append_Line (State, "    LDX alb_file_len");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_file_buf,X");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_file_close:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_file_load:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_play_sound:");
      Append_Line (State, "    LDA #$0F");
      Append_Line (State, "    STA $D418");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA $D404");
      Append_Line (State, "    LDA #$80");
      Append_Line (State, "    STA $D401");
      Append_Line (State, "    LDA #$34");
      Append_Line (State, "    STA $D400");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA $D404");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_delay:");
      Append_Line (State, "    STA alb_delay_frames");
      Append_Line (State, "alb_delay_loop:");
      Append_Line (State, "    LDA alb_delay_frames");
      Append_Line (State, "    BEQ alb_delay_done");
      Append_Line (State, "    DEC alb_delay_frames");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "alb_delay_spin:");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_delay_spin");
      Append_Line (State, "    JMP alb_delay_loop");
      Append_Line (State, "alb_delay_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_rnd_u8:");
      Append_Line (State, "    STA alb_math_rhs");
      Append_Line (State, "    LDA alb_tick_counter");
      Append_Line (State, "    EOR alb_math_rhs");
      Append_Line (State, "    STA alb_math_lhs");
      Append_Line (State, "    LDA alb_tick_counter+1");
      Append_Line (State, "    ADC #$37");
      Append_Line (State, "    STA alb_tick_counter+1");
      Append_Line (State, "    LDA alb_math_lhs");
      Append_Line (State, "    STA alb_tick_counter");
      Append_Line (State, "    CMP alb_math_rhs");
      Append_Line (State, "    BCC alb_rnd_done");
      Append_Line (State, "    SBC alb_math_rhs");
      Append_Line (State, "alb_rnd_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_strlen:");
      Append_Line (State, "    STA ZP_IO_PTR");
      Append_Line (State, "    STX ZP_IO_PTR+1");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "alb_strlen_loop:");
      Append_Line (State, "    LDA (ZP_IO_PTR),Y");
      Append_Line (State, "    BEQ alb_strlen_done");
      Append_Line (State, "    INY");
      Append_Line (State, "    BNE alb_strlen_loop");
      Append_Line (State, "alb_strlen_done:");
      Append_Line (State, "    TYA");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("bind_target") & ":");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("target_lo"));
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("target_hi"));
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("bind_other") & ":");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("other_lo"));
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("other_hi"));
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("capture_target") & ":");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    STA " & Rev_Runtime_Label ("old_lo"));
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA " & Rev_Runtime_Label ("old_hi"));
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("capture_target_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    STA " & Rev_Runtime_Label ("old_hi"));
      Append_Line (State, Rev_Runtime_Label ("capture_target_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("capture_other") & ":");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (ZP_PTR1),Y");
      Append_Line (State, "    STA " & Rev_Runtime_Label ("other_old_lo"));
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA " & Rev_Runtime_Label ("other_old_hi"));
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("capture_other_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR1),Y");
      Append_Line (State, "    STA " & Rev_Runtime_Label ("other_old_hi"));
      Append_Line (State, Rev_Runtime_Label ("capture_other_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("record_entry") & ":");
      Append_Line (State, "    LDX " & Rev_Runtime_Label ("journal_count"));
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Rev_Journal));
      Append_Line (State, "    BCS " & Rev_Runtime_Label ("record_done"));
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("opcode"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_opcode") & ",X");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_width") & ",X");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("target_lo"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_target_lo") & ",X");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("target_hi"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_target_hi") & ",X");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("old_lo"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_old_lo") & ",X");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("old_hi"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_old_hi") & ",X");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("operand_lo"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_aux_lo") & ",X");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("operand_hi"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("journal_aux_hi") & ",X");
      Append_Line (State, "    INC " & Rev_Runtime_Label ("journal_count"));
      Append_Line (State, Rev_Runtime_Label ("record_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("begin_block") & ":");
      Append_Line (State, "    LDX " & Rev_Runtime_Label ("block_depth"));
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Rev_Block_Depth));
      Append_Line (State, "    BCS " & Rev_Runtime_Label ("begin_block_done"));
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("journal_count"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("block_marks") & ",X");
      Append_Line (State, "    INC " & Rev_Runtime_Label ("block_depth"));
      Append_Line (State, Rev_Runtime_Label ("begin_block_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("end_block") & ":");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("block_depth"));
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("end_block_done"));
      Append_Line (State, "    DEC " & Rev_Runtime_Label ("block_depth"));
      Append_Line (State, Rev_Runtime_Label ("end_block_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_add") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC " & Rev_Runtime_Label ("operand_lo"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_add_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    ADC " & Rev_Runtime_Label ("operand_hi"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_add_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_sub") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC " & Rev_Runtime_Label ("operand_lo"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_sub_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    SBC " & Rev_Runtime_Label ("operand_hi"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_sub_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_xor") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    EOR " & Rev_Runtime_Label ("operand_lo"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_xor_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    EOR " & Rev_Runtime_Label ("operand_hi"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_xor_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_not") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_not_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_not_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_neg") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_neg_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_neg_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_rol") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDX " & Rev_Runtime_Label ("operand_lo"));
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_rol_done"));
      Append_Line (State, Rev_Runtime_Label ("apply_rol_loop") & ":");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_rol_word"));
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    AND #$80");
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_rol_byte_clc"));
      Append_Line (State, "    SEC");
      Append_Line (State, "    BCS " & Rev_Runtime_Label ("apply_rol_byte_go"));
      Append_Line (State, Rev_Runtime_Label ("apply_rol_byte_clc") & ":");
      Append_Line (State, "    CLC");
      Append_Line (State, Rev_Runtime_Label ("apply_rol_byte_go") & ":");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    ROL A");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    JMP " & Rev_Runtime_Label ("apply_rol_next"));
      Append_Line (State, Rev_Runtime_Label ("apply_rol_word") & ":");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    AND #$80");
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_rol_word_clc"));
      Append_Line (State, "    SEC");
      Append_Line (State, "    BCS " & Rev_Runtime_Label ("apply_rol_word_go"));
      Append_Line (State, Rev_Runtime_Label ("apply_rol_word_clc") & ":");
      Append_Line (State, "    CLC");
      Append_Line (State, Rev_Runtime_Label ("apply_rol_word_go") & ":");
      Append_Line (State, "    DEY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    ROL A");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    ROL A");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_rol_next") & ":");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_rol_loop"));
      Append_Line (State, Rev_Runtime_Label ("apply_rol_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_ror") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDX " & Rev_Runtime_Label ("operand_lo"));
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_ror_done"));
      Append_Line (State, Rev_Runtime_Label ("apply_ror_loop") & ":");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_ror_word"));
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    AND #$01");
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_ror_byte_clc"));
      Append_Line (State, "    SEC");
      Append_Line (State, "    BCS " & Rev_Runtime_Label ("apply_ror_byte_go"));
      Append_Line (State, Rev_Runtime_Label ("apply_ror_byte_clc") & ":");
      Append_Line (State, "    CLC");
      Append_Line (State, Rev_Runtime_Label ("apply_ror_byte_go") & ":");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    ROR A");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    JMP " & Rev_Runtime_Label ("apply_ror_next"));
      Append_Line (State, Rev_Runtime_Label ("apply_ror_word") & ":");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    AND #$01");
      Append_Line (State, "    BEQ " & Rev_Runtime_Label ("apply_ror_word_clc"));
      Append_Line (State, "    SEC");
      Append_Line (State, "    BCS " & Rev_Runtime_Label ("apply_ror_word_go"));
      Append_Line (State, Rev_Runtime_Label ("apply_ror_word_clc") & ":");
      Append_Line (State, "    CLC");
      Append_Line (State, Rev_Runtime_Label ("apply_ror_word_go") & ":");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    ROR A");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    DEY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    ROR A");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_ror_next") & ":");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_ror_loop"));
      Append_Line (State, Rev_Runtime_Label ("apply_ror_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, Rev_Runtime_Label ("apply_swap") & ":");
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("bind_other"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_target"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("capture_other"));
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("other_lo"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("operand_lo"));
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("other_hi"));
      Append_Line (State, "    STA " & Rev_Runtime_Label ("operand_hi"));
      Append_Line (State, "    JSR " & Rev_Runtime_Label ("record_entry"));
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("other_old_lo"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("old_lo"));
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("width"));
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE " & Rev_Runtime_Label ("apply_swap_done"));
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("other_old_hi"));
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA " & Rev_Runtime_Label ("old_hi"));
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, Rev_Runtime_Label ("apply_swap_done") & ":");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_latch_key:");
      Append_Line (State, "    BEQ alb_latch_key_done");
      Append_Line (State, "    TAX");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_key_latch,X");
      Append_Line (State, "    LDA alb_last_key");
      Append_Line (State, "    BNE alb_latch_key_done");
      Append_Line (State, "    TXA");
      Append_Line (State, "    STA alb_last_key");
      Append_Line (State, "alb_latch_key_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_begin_input_frame:");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "alb_begin_input_loop:");
      Append_Line (State, "    STA alb_key_latch,X");
      Append_Line (State, "    INX");
      Append_Line (State, "    BNE alb_begin_input_loop");
      Append_Line (State, "    STA alb_last_key");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_reset_input:");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "alb_reset_input_loop:");
      Append_Line (State, "    STA alb_key_state,X");
      Append_Line (State, "    STA alb_prev_key_state,X");
      Append_Line (State, "    STA alb_key_latch,X");
      Append_Line (State, "    INX");
      Append_Line (State, "    BNE alb_reset_input_loop");
      Append_Line (State, "    STA alb_last_key");
      Append_Line (State, "    STA alb_shift_state");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_translate_getin_key:");
      Append_Line (State, "    CMP #$0D");
      Append_Line (State, "    BNE alb_getin_not_return");
      Append_Line (State, "    LDA #$28");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_not_return:");
      Append_Line (State, "    CMP #$20");
      Append_Line (State, "    BNE alb_getin_not_space");
      Append_Line (State, "    LDA #$2C");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_not_space:");
      Append_Line (State, "    CMP #$1D");
      Append_Line (State, "    BNE alb_getin_not_right");
      Append_Line (State, "    LDA #$4F");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_not_right:");
      Append_Line (State, "    CMP #$9D");
      Append_Line (State, "    BNE alb_getin_not_left");
      Append_Line (State, "    LDA #$50");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_not_left:");
      Append_Line (State, "    CMP #$11");
      Append_Line (State, "    BNE alb_getin_not_down");
      Append_Line (State, "    LDA #$51");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_not_down:");
      Append_Line (State, "    CMP #$91");
      Append_Line (State, "    BNE alb_getin_not_up");
      Append_Line (State, "    LDA #$52");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_not_up:");
      Append_Line (State, "    CMP #$30");
      Append_Line (State, "    BNE alb_getin_not_zero");
      Append_Line (State, "    LDA #$27");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_not_zero:");
      Append_Line (State, "    CMP #$31");
      Append_Line (State, "    BCC alb_getin_upper");
      Append_Line (State, "    CMP #$3A");
      Append_Line (State, "    BCS alb_getin_upper");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #$13");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_upper:");
      Append_Line (State, "    CMP #$41");
      Append_Line (State, "    BCC alb_getin_lower");
      Append_Line (State, "    CMP #$5B");
      Append_Line (State, "    BCS alb_getin_lower");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #$3D");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_lower:");
      Append_Line (State, "    CMP #$61");
      Append_Line (State, "    BCC alb_getin_none");
      Append_Line (State, "    CMP #$7B");
      Append_Line (State, "    BCS alb_getin_none");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #$5D");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_getin_none:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_poll_key_buffer:");
      Append_Line (State, "alb_poll_key_buffer_loop:");
      Append_Line (State, "    JSR KERNAL_GETIN");
      Append_Line (State, "    BEQ alb_poll_key_buffer_done");
      Append_Line (State, "    JSR alb_translate_getin_key");
      Append_Line (State, "    JSR alb_latch_key");
      Append_Line (State, "    JMP alb_poll_key_buffer_loop");
      Append_Line (State, "alb_poll_key_buffer_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_poll_input:");
      Append_Line (State, "    LDA #$FF");
      Append_Line (State, "    STA C64_CIA1_DDRA");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA C64_CIA1_DDRB");
      for Column in 0 .. 7 loop
         Append_Line
           (State,
            "    LDA #" & Byte_Hex (Column_Select_Mask (Column)));
         Append_Line (State, "    STA C64_CIA1_PORTA");
         Append_Line (State, "    LDA C64_CIA1_PORTB");
         Append_Line
           (State,
            "    STA alb_key_matrix_" & Decimal_Image (Column));
      end loop;
      Append_Line (State, "    LDA #$FF");
      Append_Line (State, "    STA C64_CIA1_PORTA");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_shift_state");
      Append_Line (State, "    LDA alb_key_matrix_7");
      Append_Line (State, "    AND #$02");
      Append_Line (State, "    BEQ alb_poll_shift_down");
      Append_Line (State, "    LDA alb_key_matrix_4");
      Append_Line (State, "    AND #$40");
      Append_Line (State, "    BNE alb_poll_shift_done");
      Append_Line (State, "alb_poll_shift_down:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_shift_state");
      Append_Line (State, "alb_poll_shift_done:");
      for I in C64_Key_Maps'Range loop
         Append_Key_State_Update (C64_Key_Maps (I), I);
      end loop;
      for I in C64_Key_Maps'Range loop
         Append_Line
           (State,
            "    LDA alb_key_state+" & Decimal_Image (C64_Key_Maps (I).Code));
         Append_Line
           (State,
            "    STA alb_prev_key_state+" & Decimal_Image (C64_Key_Maps (I).Code));
      end loop;
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_copy_builtin_sprites:");
      Append_Line (State, "    LDA #<alb_c64_builtin_sprites");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA #>alb_c64_builtin_sprites");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA #<C64_SPRITE_DATA");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA #>C64_SPRITE_DATA");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDX #$03");
      Append_Line (State, "alb_c64_copy_builtin_sprite_block:");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "alb_c64_copy_builtin_sprite_byte:");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    CPY #64");
      Append_Line (State, "    BNE alb_c64_copy_builtin_sprite_byte");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR0");
      Append_Line (State, "    ADC #64");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA ZP_PTR0+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR1");
      Append_Line (State, "    ADC #64");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA ZP_PTR1+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_c64_copy_builtin_sprite_block");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_reset_sprites:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA C64_SPRITE_ENABLE");
      Append_Line (State, "    STA C64_SPRITE_X_EXPAND");
      Append_Line (State, "    STA C64_SPRITE_Y_EXPAND");
      Append_Line (State, "    STA C64_SPRITE_MULTICOLOR");
      Append_Line (State, "    STA C64_SPRITE_PRIORITY");
      Append_Line (State, "    STA C64_SPRITE_X_MSB");
      Append_Line (State, "    STA C64_SPRITE_MC0");
      Append_Line (State, "    STA C64_SPRITE_MC1");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "    LDA #$80");
      Append_Line (State, "alb_c64_reset_sprite_ptrs:");
      Append_Line (State, "    STA C64_SPRITE_PTR_BASE,X");
      Append_Line (State, "    INX");
      Append_Line (State, "    CPX #8");
      Append_Line (State, "    BNE alb_c64_reset_sprite_ptrs");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "alb_c64_reset_sprite_colors:");
      Append_Line (State, "    STA C64_SPRITE_COLOR0,X");
      Append_Line (State, "    INX");
      Append_Line (State, "    CPX #8");
      Append_Line (State, "    BNE alb_c64_reset_sprite_colors");
      Append_Line (State, "    LDA C64_SPRITE_SPRITE_COLLIDE");
      Append_Line (State, "    LDA C64_SPRITE_BG_COLLIDE");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_init_vic:");
      Append_Line (State, "    SEI");
      Append_Line (State, "    LDA C64_CIA2_PORTA");
      Append_Line (State, "    AND #$FC");
      Append_Line (State, "    ORA #$01");
      Append_Line (State, "    STA C64_CIA2_PORTA");
      Append_Line (State, "    LDA #$1B");
      Append_Line (State, "    STA C64_VIC_CTRL1");
      Append_Line (State, "    LDA #$08");
      Append_Line (State, "    STA C64_VIC_CTRL2");
      Append_Line (State, "    LDA #$34");
      Append_Line (State, "    STA C64_VIC_MEMORY");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_frame_counter_lo");
      Append_Line (State, "    STA alb_frame_counter_hi");
      Append_Line (State, "    LDA #<alb_raster_irq");
      Append_Line (State, "    STA C64_IRQ_VECTOR");
      Append_Line (State, "    LDA #>alb_raster_irq");
      Append_Line (State, "    STA C64_IRQ_VECTOR+1");
      Append_Line (State, "    LDA #$F8");
      Append_Line (State, "    STA C64_RASTER");
      Append_Line (State, "    LDA C64_VIC_CTRL1");
      Append_Line (State, "    AND #$7F");
      Append_Line (State, "    STA C64_VIC_CTRL1");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA C64_VIC_IRQ_STATUS");
      Append_Line (State, "    STA C64_VIC_IRQ_ENABLE");
      Append_Line (State, "    CLI");
      Append_Line (State, "    JSR alb_c64_copy_builtin_sprites");
      Append_Line (State, "    JSR alb_c64_reset_sprites");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_sprite_set_shape:");
      Append_Line (State, "    LDX alb_c64_sprite_slot");
      Append_Line (State, "    LDA alb_c64_sprite_shape");
      Append_Line (State, "    TAY");
      Append_Line (State, "    LDA alb_c64_sprite_ptr_values,Y");
      Append_Line (State, "    STA C64_SPRITE_PTR_BASE,X");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_sprite_set_color:");
      Append_Line (State, "    LDX alb_c64_sprite_slot");
      Append_Line (State, "    LDA alb_c64_sprite_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA C64_SPRITE_COLOR0,X");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_sprite_set_enable:");
      Append_Line (State, "    LDX alb_c64_sprite_slot");
      Append_Line (State, "    LDA alb_c64_sprite_masks,X");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA C64_SPRITE_ENABLE");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "    LDA alb_c64_sprite_value");
      Append_Line (State, "    BEQ alb_c64_sprite_disable_bit");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    ORA alb_expr_tmp0");
      Append_Line (State, "    STA C64_SPRITE_ENABLE");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_c64_sprite_disable_bit:");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    AND alb_expr_tmp1");
      Append_Line (State, "    STA C64_SPRITE_ENABLE");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_sprite_set_expand_x:");
      Append_Line (State, "    LDX alb_c64_sprite_slot");
      Append_Line (State, "    LDA alb_c64_sprite_masks,X");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA C64_SPRITE_X_EXPAND");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "    LDA alb_c64_sprite_value");
      Append_Line (State, "    BEQ alb_c64_sprite_expand_x_clear");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    ORA alb_expr_tmp0");
      Append_Line (State, "    STA C64_SPRITE_X_EXPAND");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_c64_sprite_expand_x_clear:");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    AND alb_expr_tmp1");
      Append_Line (State, "    STA C64_SPRITE_X_EXPAND");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_sprite_set_expand_y:");
      Append_Line (State, "    LDX alb_c64_sprite_slot");
      Append_Line (State, "    LDA alb_c64_sprite_masks,X");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA C64_SPRITE_Y_EXPAND");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "    LDA alb_c64_sprite_value");
      Append_Line (State, "    BEQ alb_c64_sprite_expand_y_clear");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    ORA alb_expr_tmp0");
      Append_Line (State, "    STA C64_SPRITE_Y_EXPAND");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_c64_sprite_expand_y_clear:");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    AND alb_expr_tmp1");
      Append_Line (State, "    STA C64_SPRITE_Y_EXPAND");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_c64_sprite_set_pos:");
      Append_Line (State, "    LDX alb_c64_sprite_slot");
      Append_Line (State, "    LDA alb_c64_sprite_masks,X");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA C64_SPRITE_X_MSB");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "    LDA alb_c64_sprite_x_hi");
      Append_Line (State, "    BEQ alb_c64_sprite_pos_clear_hi");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    ORA alb_expr_tmp0");
      Append_Line (State, "    STA C64_SPRITE_X_MSB");
      Append_Line (State, "    JMP alb_c64_sprite_pos_store");
      Append_Line (State, "alb_c64_sprite_pos_clear_hi:");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    AND alb_expr_tmp1");
      Append_Line (State, "    STA C64_SPRITE_X_MSB");
      Append_Line (State, "alb_c64_sprite_pos_store:");
      Append_Line (State, "    LDX alb_c64_sprite_slot");
      Append_Line (State, "    TXA");
      Append_Line (State, "    ASL A");
      Append_Line (State, "    TAX");
      Append_Line (State, "    LDA alb_c64_sprite_x_lo");
      Append_Line (State, "    STA $D000,X");
      Append_Line (State, "    LDA alb_c64_sprite_y");
      Append_Line (State, "    STA $D001,X");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_raster_irq:");
      Append_Line (State, "    PHA");
      Append_Line (State, "    TXA");
      Append_Line (State, "    PHA");
      Append_Line (State, "    TYA");
      Append_Line (State, "    PHA");
      Append_Line (State, "    LDA C64_VIC_IRQ_STATUS");
      Append_Line (State, "    AND #$01");
      Append_Line (State, "    BEQ alb_raster_irq_chain");
      Append_Line (State, "    INC alb_frame_counter_lo");
      Append_Line (State, "    BNE alb_raster_irq_ack");
      Append_Line (State, "    INC alb_frame_counter_hi");
      Append_Line (State, "alb_raster_irq_ack:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA C64_VIC_IRQ_STATUS");
      Append_Line (State, "alb_raster_irq_chain:");
      Append_Line (State, "    PLA");
      Append_Line (State, "    TAY");
      Append_Line (State, "    PLA");
      Append_Line (State, "    TAX");
      Append_Line (State, "    PLA");
      Append_Line (State, "    JMP $EA31");
      Append_Line (State, "");
      Append_Line (State, "alb_init_graphics:");
      Append_Line (State, "    JSR alb_c64_init_vic");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_cease_flag");
      Append_Line (State, "    STA alb_last_key");
      Append_Line (State, "    JSR alb_reset_input");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_draw_color");
      Append_Line (State, "    STA C64_TEXT_COLOR");
      Append_Line (State, "    LDA #$A0");
      Append_Line (State, "    STA alb_plot_char");
      Append_Line (State, "    JSR alb_clear_screen");
      Append_Line (State, "    JSR alb_capture_static_frame");
      Append_Line (State, "    JSR alb_present_frame");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_wait_frame:");
      Append_Line (State, "    LDA alb_frame_counter_lo");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA alb_frame_counter_hi");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "alb_wait_frame_loop:");
      Append_Line (State, "    LDA alb_frame_counter_lo");
      Append_Line (State, "    CMP alb_expr_tmp0");
      Append_Line (State, "    BNE alb_wait_frame_done");
      Append_Line (State, "    LDA alb_frame_counter_hi");
      Append_Line (State, "    CMP alb_expr_tmp1");
      Append_Line (State, "    BEQ alb_wait_frame_loop");
      Append_Line (State, "alb_wait_frame_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_listen_loop:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_cease_flag");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_auto_restore_paint");
      Append_Line (State, "    JSR alb_reset_input");
      Append_Line (State, "alb_listen_loop_top:");
      Append_Line (State, "    JSR alb_poll_input");
      Append_Line (State, "    JSR alb_poll_key_buffer");
      Append_Line (State, "    LDA alb_last_key");
      Append_Line (State, "    BEQ alb_listen_no_key");
      Append_Line (State, "    JSR alb_on_key");
      Append_Line (State, "alb_listen_no_key:");
      Append_Line (State, "    JSR alb_on_tick");
      Append_Line (State, "    JSR alb_begin_paint_frame");
      Append_Line (State, "    JSR alb_on_paint");
      Append_Line (State, "    JSR alb_present_frame");
      Append_Line (State, "    JSR alb_begin_input_frame");
      Append_Line (State, "    LDA alb_cease_flag");
      Append_Line (State, "    BNE alb_listen_loop_done");
      Append_Line (State, "    JSR alb_wait_frame");
      Append_Line (State, "    JMP alb_listen_loop_top");
      Append_Line (State, "alb_listen_loop_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_clear_screen:");
      Append_Line (State, "    LDA alb_clear_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA alb_clear_color");
      Append_Line (State, "    STA C64_BACKGROUND");
      Append_Line (State, "    STA C64_BORDER");
      Append_Line (State, "    LDA #<alb_back_screen");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA #>alb_back_screen");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA #<alb_back_color");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA #>alb_back_color");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDX #25");
      Append_Line (State, "alb_clear_screen_row:");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "    LDA #$20");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA alb_clear_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "alb_clear_screen_col:");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    CPY #40");
      Append_Line (State, "    BNE alb_clear_screen_col");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR0");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA ZP_PTR0+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR1");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA ZP_PTR1+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_clear_screen_row");
      Append_Line (State, "    JSR alb_mark_all_rows_dirty");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_capture_static_frame:");
      Append_Line (State, "    LDA #<alb_back_screen");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA #>alb_back_screen");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA #<alb_static_screen");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA #>alb_static_screen");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDX #25");
      Append_Line (State, "alb_capture_static_chars_row:");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR0");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA ZP_PTR0+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR1");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA ZP_PTR1+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_capture_static_chars_row");
      Append_Line (State, "    LDA #<alb_back_color");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA #>alb_back_color");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA #<alb_static_color");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA #>alb_static_color");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDX #25");
      Append_Line (State, "alb_capture_static_color_row:");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR0");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA ZP_PTR0+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR1");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA ZP_PTR1+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_capture_static_color_row");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_static_ready");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_begin_paint_frame:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_restore_static_frame:");
      Append_Line (State, "    LDA #<alb_static_screen");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA #>alb_static_screen");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA #<alb_back_screen");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA #>alb_back_screen");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDX #25");
      Append_Line (State, "alb_restore_static_chars_row:");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR0");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA ZP_PTR0+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR1");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA ZP_PTR1+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_restore_static_chars_row");
      Append_Line (State, "    LDA #<alb_static_color");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA #>alb_static_color");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA #<alb_back_color");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA #>alb_back_color");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDX #25");
      Append_Line (State, "alb_restore_static_color_row:");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR0");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA ZP_PTR0+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    CLC");
      Append_Line (State, "    LDA ZP_PTR1");
      Append_Line (State, "    ADC #40");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA ZP_PTR1+1");
      Append_Line (State, "    ADC #$00");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    DEX");
      Append_Line (State, "    BNE alb_restore_static_color_row");
      Append_Line (State, "    JSR alb_mark_all_rows_dirty");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_blit_row40:");
      Append_Line (State, "    LDY #$00");
      Append_Line (State, "alb_blit_row40_loop:");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    LDA (ZP_PTR0),Y");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    CPY #40");
      Append_Line (State, "    BNE alb_blit_row40_loop");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_mark_all_rows_dirty:");
      Append_Line (State, "    LDX #25");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "alb_mark_all_rows_dirty_loop:");
      Append_Line (State, "    DEX");
      Append_Line (State, "    STA alb_dirty_rows,X");
      Append_Line (State, "    BNE alb_mark_all_rows_dirty_loop");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_present_frame:");
      Append_Line (State, "    LDA alb_clear_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA C64_BACKGROUND");
      Append_Line (State, "    STA C64_BORDER");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "alb_present_dirty_row:");
      Append_Line (State, "    LDA alb_dirty_rows,X");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    ORA alb_live_dirty_rows,X");
      Append_Line (State, "    BEQ alb_present_next_row");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_live_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_live_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_live_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_live_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_live_dirty_rows,X");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    BEQ alb_present_clear_dirty");
      Append_Line (State, "    LDA alb_auto_restore_paint");
      Append_Line (State, "    BEQ alb_present_clear_dirty");
      Append_Line (State, "    LDA alb_static_ready");
      Append_Line (State, "    BEQ alb_present_clear_dirty");
      Append_Line (State, "    LDA alb_static_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_static_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    LDA alb_static_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_static_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    JSR alb_blit_row40");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_live_dirty_rows,X");
      Append_Line (State, "alb_present_clear_dirty:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_dirty_rows,X");
      Append_Line (State, "alb_present_next_row:");
      Append_Line (State, "    INX");
      Append_Line (State, "    CPX #25");
      Append_Line (State, "    BEQ alb_present_done");
      Append_Line (State, "    JMP alb_present_dirty_row");
      Append_Line (State, "alb_present_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_clamp_plot_point:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP #40");
      Append_Line (State, "    BCC alb_clamp_y");
      Append_Line (State, "    LDA #39");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "alb_clamp_y:");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP #25");
      Append_Line (State, "    BCC alb_clamp_done");
      Append_Line (State, "    LDA #24");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "alb_clamp_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_compute_cell_ptrs:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP #40");
      Append_Line (State, "    BCC alb_compute_ptr_x_ok");
      Append_Line (State, "    LDA #39");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "alb_compute_ptr_x_ok:");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP #25");
      Append_Line (State, "    BCC alb_compute_ptr_y_ok");
      Append_Line (State, "    LDA #24");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "alb_compute_ptr_y_ok:");
      Append_Line (State, "    LDX alb_graphics_y");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_dirty_rows,X");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDY alb_graphics_x");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_plot_cell:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP #40");
      Append_Line (State, "    BCC alb_plot_x_ok");
      Append_Line (State, "    LDA #39");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "alb_plot_x_ok:");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP #25");
      Append_Line (State, "    BCC alb_plot_y_ok");
      Append_Line (State, "    LDA #24");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "alb_plot_y_ok:");
      Append_Line (State, "    LDX alb_graphics_y");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_dirty_rows,X");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDY alb_graphics_x");
      Append_Line (State, "    LDA alb_plot_char");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_draw_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_read_cell_color:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP #40");
      Append_Line (State, "    BCC alb_read_x_ok");
      Append_Line (State, "    LDA #39");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "alb_read_x_ok:");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP #25");
      Append_Line (State, "    BCC alb_read_y_ok");
      Append_Line (State, "    LDA #24");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "alb_read_y_ok:");
      Append_Line (State, "    LDX alb_graphics_y");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDY alb_graphics_x");
      Append_Line (State, "    LDA (ZP_PTR1),Y");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_draw_span:");
      Append_Line (State, "    LDA alb_graphics_steps");
      Append_Line (State, "    BEQ alb_draw_span_done");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP #40");
      Append_Line (State, "    BCC alb_draw_span_x_ok");
      Append_Line (State, "    LDA #39");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "alb_draw_span_x_ok:");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP #25");
      Append_Line (State, "    BCC alb_draw_span_y_ok");
      Append_Line (State, "    LDA #24");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "alb_draw_span_y_ok:");
      Append_Line (State, "    LDX alb_graphics_y");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_dirty_rows,X");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDY alb_graphics_x");
      Append_Line (State, "    LDA #40");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_x");
      Append_Line (State, "    CMP alb_graphics_steps");
      Append_Line (State, "    BCS alb_draw_span_use_steps");
      Append_Line (State, "    STA alb_graphics_counter");
      Append_Line (State, "    JMP alb_draw_span_counter_ready");
      Append_Line (State, "alb_draw_span_use_steps:");
      Append_Line (State, "    LDA alb_graphics_steps");
      Append_Line (State, "    STA alb_graphics_counter");
      Append_Line (State, "alb_draw_span_counter_ready:");
      Append_Line (State, "    BEQ alb_draw_span_done");
      Append_Line (State, "    LDA alb_plot_char");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA alb_draw_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "alb_draw_span_loop:");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    DEC alb_graphics_counter");
      Append_Line (State, "    BNE alb_draw_span_loop");
      Append_Line (State, "alb_draw_span_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_draw_vspan:");
      Append_Line (State, "    LDA alb_graphics_steps");
      Append_Line (State, "    BEQ alb_draw_vspan_done");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP #40");
      Append_Line (State, "    BCC alb_draw_vspan_x_ok");
      Append_Line (State, "    LDA #39");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "alb_draw_vspan_x_ok:");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP #25");
      Append_Line (State, "    BCC alb_draw_vspan_y_ok");
      Append_Line (State, "    LDA #24");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "alb_draw_vspan_y_ok:");
      Append_Line (State, "    LDA #25");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_y");
      Append_Line (State, "    CMP alb_graphics_steps");
      Append_Line (State, "    BCS alb_draw_vspan_use_steps");
      Append_Line (State, "    STA alb_graphics_counter");
      Append_Line (State, "    JMP alb_draw_vspan_counter_ready");
      Append_Line (State, "alb_draw_vspan_use_steps:");
      Append_Line (State, "    LDA alb_graphics_steps");
      Append_Line (State, "    STA alb_graphics_counter");
      Append_Line (State, "alb_draw_vspan_counter_ready:");
      Append_Line (State, "    BEQ alb_draw_vspan_done");
      Append_Line (State, "    LDA alb_plot_char");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA alb_draw_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "    LDX alb_graphics_y");
      Append_Line (State, "alb_draw_vspan_loop:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_dirty_rows,X");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDY alb_graphics_x");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INX");
      Append_Line (State, "    DEC alb_graphics_counter");
      Append_Line (State, "    BNE alb_draw_vspan_loop");
      Append_Line (State, "alb_draw_vspan_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_draw_line:");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP alb_graphics_y1");
      Append_Line (State, "    BNE alb_draw_line_check_vertical");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP alb_graphics_x1");
      Append_Line (State, "    BCC alb_draw_line_horizontal_ready");
      Append_Line (State, "    BEQ alb_draw_line_horizontal_ready");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA alb_graphics_x1");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA alb_graphics_x1");
      Append_Line (State, "alb_draw_line_horizontal_ready:");
      Append_Line (State, "    LDA alb_graphics_x1");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_x");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_steps");
      Append_Line (State, "    JSR alb_draw_span");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_draw_line_check_vertical:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    CMP alb_graphics_x1");
      Append_Line (State, "    BNE alb_draw_line_general");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    CMP alb_graphics_y1");
      Append_Line (State, "    BCC alb_draw_line_vertical_ready");
      Append_Line (State, "    BEQ alb_draw_line_vertical_ready");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA alb_graphics_y1");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA alb_graphics_y1");
      Append_Line (State, "alb_draw_line_vertical_ready:");
      Append_Line (State, "    LDA alb_graphics_y1");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_y");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_steps");
      Append_Line (State, "    JSR alb_draw_vspan");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_draw_line_general:");
      Append_Line (State, "    LDA alb_graphics_x1");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_x");
      Append_Line (State, "    BCS alb_draw_line_dx_pos");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_dx");
      Append_Line (State, "    LDA #$FF");
      Append_Line (State, "    STA alb_graphics_sx");
      Append_Line (State, "    JMP alb_draw_line_dx_done");
      Append_Line (State, "alb_draw_line_dx_pos:");
      Append_Line (State, "    STA alb_graphics_dx");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_graphics_sx");
      Append_Line (State, "alb_draw_line_dx_done:");
      Append_Line (State, "    LDA alb_graphics_y1");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_y");
      Append_Line (State, "    BCS alb_draw_line_dy_pos");
      Append_Line (State, "    EOR #$FF");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_dy");
      Append_Line (State, "    LDA #$FF");
      Append_Line (State, "    STA alb_graphics_sy");
      Append_Line (State, "    JMP alb_draw_line_dy_done");
      Append_Line (State, "alb_draw_line_dy_pos:");
      Append_Line (State, "    STA alb_graphics_dy");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_graphics_sy");
      Append_Line (State, "alb_draw_line_dy_done:");
      Append_Line (State, "    LDA alb_graphics_dx");
      Append_Line (State, "    CMP alb_graphics_dy");
      Append_Line (State, "    BCS alb_draw_line_use_dx");
      Append_Line (State, "    LDA alb_graphics_dy");
      Append_Line (State, "alb_draw_line_use_dx:");
      Append_Line (State, "    STA alb_graphics_steps");
      Append_Line (State, "    BEQ alb_draw_line_single");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_counter");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_graphics_acc_x");
      Append_Line (State, "    STA alb_graphics_acc_y");
      Append_Line (State, "alb_draw_line_loop:");
      Append_Line (State, "    JSR alb_plot_cell");
      Append_Line (State, "    DEC alb_graphics_counter");
      Append_Line (State, "    BEQ alb_draw_line_done");
      Append_Line (State, "    LDA alb_graphics_acc_x");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_graphics_dx");
      Append_Line (State, "    STA alb_graphics_acc_x");
      Append_Line (State, "    CMP alb_graphics_steps");
      Append_Line (State, "    BCC alb_draw_line_skip_x");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_steps");
      Append_Line (State, "    STA alb_graphics_acc_x");
      Append_Line (State, "    LDA alb_graphics_dx");
      Append_Line (State, "    BEQ alb_draw_line_skip_x");
      Append_Line (State, "    LDA alb_graphics_sx");
      Append_Line (State, "    BMI alb_draw_line_dec_x");
      Append_Line (State, "    INC alb_graphics_x");
      Append_Line (State, "    JMP alb_draw_line_skip_x");
      Append_Line (State, "alb_draw_line_dec_x:");
      Append_Line (State, "    DEC alb_graphics_x");
      Append_Line (State, "alb_draw_line_skip_x:");
      Append_Line (State, "    LDA alb_graphics_acc_y");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_graphics_dy");
      Append_Line (State, "    STA alb_graphics_acc_y");
      Append_Line (State, "    CMP alb_graphics_steps");
      Append_Line (State, "    BCC alb_draw_line_skip_y");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_steps");
      Append_Line (State, "    STA alb_graphics_acc_y");
      Append_Line (State, "    LDA alb_graphics_dy");
      Append_Line (State, "    BEQ alb_draw_line_skip_y");
      Append_Line (State, "    LDA alb_graphics_sy");
      Append_Line (State, "    BMI alb_draw_line_dec_y");
      Append_Line (State, "    INC alb_graphics_y");
      Append_Line (State, "    JMP alb_draw_line_skip_y");
      Append_Line (State, "alb_draw_line_dec_y:");
      Append_Line (State, "    DEC alb_graphics_y");
      Append_Line (State, "alb_draw_line_skip_y:");
      Append_Line (State, "    JMP alb_draw_line_loop");
      Append_Line (State, "alb_draw_line_single:");
      Append_Line (State, "    JSR alb_plot_cell");
      Append_Line (State, "alb_draw_line_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_fill_rect:");
      Append_Line (State, "    LDA alb_rect_h");
      Append_Line (State, "    BEQ alb_fill_rect_done");
      Append_Line (State, "    STA alb_graphics_rows");
      Append_Line (State, "    LDA alb_plot_char");
      Append_Line (State, "    STA alb_expr_tmp0");
      Append_Line (State, "    LDA alb_draw_color");
      Append_Line (State, "    AND #$0F");
      Append_Line (State, "    STA alb_expr_tmp1");
      Append_Line (State, "alb_fill_rect_row:");
      Append_Line (State, "    LDX alb_rect_y");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_dirty_rows,X");
      Append_Line (State, "    LDA alb_back_screen_row_lo,X");
      Append_Line (State, "    STA ZP_PTR0");
      Append_Line (State, "    LDA alb_back_screen_row_hi,X");
      Append_Line (State, "    STA ZP_PTR0+1");
      Append_Line (State, "    LDA alb_back_color_row_lo,X");
      Append_Line (State, "    STA ZP_PTR1");
      Append_Line (State, "    LDA alb_back_color_row_hi,X");
      Append_Line (State, "    STA ZP_PTR1+1");
      Append_Line (State, "    LDY alb_rect_x");
      Append_Line (State, "    LDA alb_rect_w");
      Append_Line (State, "    STA alb_graphics_counter");
      Append_Line (State, "alb_fill_rect_span:");
      Append_Line (State, "    LDA alb_expr_tmp0");
      Append_Line (State, "    STA (ZP_PTR0),Y");
      Append_Line (State, "    LDA alb_expr_tmp1");
      Append_Line (State, "    STA (ZP_PTR1),Y");
      Append_Line (State, "    INY");
      Append_Line (State, "    DEC alb_graphics_counter");
      Append_Line (State, "    BNE alb_fill_rect_span");
      Append_Line (State, "    INC alb_rect_y");
      Append_Line (State, "    DEC alb_graphics_rows");
      Append_Line (State, "    BNE alb_fill_rect_row");
      Append_Line (State, "alb_fill_rect_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_draw_rect:");
      Append_Line (State, "    LDA alb_rect_w");
      Append_Line (State, "    BNE alb_draw_rect_have_w");
      Append_Line (State, "    JMP alb_draw_rect_done");
      Append_Line (State, "alb_draw_rect_have_w:");
      Append_Line (State, "    LDA alb_rect_h");
      Append_Line (State, "    BNE alb_draw_rect_have_h");
      Append_Line (State, "    JMP alb_draw_rect_done");
      Append_Line (State, "alb_draw_rect_have_h:");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_w");
      Append_Line (State, "    STA alb_graphics_steps");
      Append_Line (State, "    JSR alb_draw_span");
      Append_Line (State, "    LDA alb_rect_h");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_draw_rect_done");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_rect_h");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #$01");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_w");
      Append_Line (State, "    STA alb_graphics_steps");
      Append_Line (State, "    JSR alb_draw_span");
      Append_Line (State, "    LDA alb_rect_h");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #$02");
      Append_Line (State, "    BEQ alb_draw_rect_done");
      Append_Line (State, "    BCC alb_draw_rect_done");
      Append_Line (State, "    STA alb_graphics_steps");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_draw_vspan");
      Append_Line (State, "    LDA alb_rect_w");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_draw_rect_done");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_rect_w");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC #$01");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_draw_vspan");
      Append_Line (State, "alb_draw_rect_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_draw_circle:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    STA alb_rect_x");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    STA alb_rect_y");
      Append_Line (State, "    LDA alb_circle_r");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_counter");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_graphics_dx");
      Append_Line (State, "alb_draw_circle_loop:");
      Append_Line (State, "    LDA alb_circle_r");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dx");
      Append_Line (State, "    STA alb_graphics_dy");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dx");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dy");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_plot_cell");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_graphics_dy");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_plot_cell");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_graphics_dx");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dy");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_plot_cell");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_graphics_dy");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_plot_cell");
      Append_Line (State, "    DEC alb_graphics_counter");
      Append_Line (State, "    BEQ alb_draw_circle_done");
      Append_Line (State, "    INC alb_graphics_dx");
      Append_Line (State, "    JMP alb_draw_circle_loop");
      Append_Line (State, "alb_draw_circle_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_fill_circle:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    STA alb_rect_x");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    STA alb_rect_y");
      Append_Line (State, "    LDA alb_circle_r");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_rows");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_graphics_dx");
      Append_Line (State, "alb_fill_circle_loop:");
      Append_Line (State, "    LDA alb_circle_r");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dx");
      Append_Line (State, "    STA alb_graphics_dy");
      Append_Line (State, "    ASL A");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC #$01");
      Append_Line (State, "    STA alb_graphics_steps");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dx");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dy");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_draw_span");
      Append_Line (State, "    LDA alb_graphics_dx");
      Append_Line (State, "    BEQ alb_fill_circle_skip_bottom");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_graphics_dx");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    SEC");
      Append_Line (State, "    SBC alb_graphics_dy");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    JSR alb_draw_span");
      Append_Line (State, "alb_fill_circle_skip_bottom:");
      Append_Line (State, "    DEC alb_graphics_rows");
      Append_Line (State, "    BEQ alb_fill_circle_done");
      Append_Line (State, "    INC alb_graphics_dx");
      Append_Line (State, "    JMP alb_fill_circle_loop");
      Append_Line (State, "alb_fill_circle_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_draw_triangle:");
      Append_Line (State, "    LDA alb_graphics_x");
      Append_Line (State, "    STA alb_rect_x");
      Append_Line (State, "    LDA alb_graphics_y");
      Append_Line (State, "    STA alb_rect_y");
      Append_Line (State, "    LDA alb_graphics_x1");
      Append_Line (State, "    STA alb_rect_w");
      Append_Line (State, "    LDA alb_graphics_y1");
      Append_Line (State, "    STA alb_rect_h");
      Append_Line (State, "    JSR alb_draw_line");
      Append_Line (State, "    LDA alb_rect_w");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    LDA alb_rect_h");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_tri_x2");
      Append_Line (State, "    STA alb_graphics_x1");
      Append_Line (State, "    LDA alb_tri_y2");
      Append_Line (State, "    STA alb_graphics_y1");
      Append_Line (State, "    JSR alb_draw_line");
      Append_Line (State, "    LDA alb_tri_x2");
      Append_Line (State, "    STA alb_graphics_x");
      Append_Line (State, "    LDA alb_tri_y2");
      Append_Line (State, "    STA alb_graphics_y");
      Append_Line (State, "    LDA alb_rect_x");
      Append_Line (State, "    STA alb_graphics_x1");
      Append_Line (State, "    LDA alb_rect_y");
      Append_Line (State, "    STA alb_graphics_y1");
      Append_Line (State, "    JSR alb_draw_line");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_fill_triangle:");
      Append_Line (State, "    JSR alb_draw_triangle");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_push_context:");
      Append_Line (State, "    LDX alb_logic_depth");
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Logic_Depth));
      Append_Line (State, "    BCC alb_logic_push_store");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_push_store:");
      Append_Line (State, "    LDA alb_logic_query_pred_lo");
      Append_Line (State, "    STA alb_logic_stack_pred_lo,X");
      Append_Line (State, "    LDA alb_logic_query_pred_hi");
      Append_Line (State, "    STA alb_logic_stack_pred_hi,X");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    STA alb_logic_stack_mode,X");
      Append_Line (State, "    LDA alb_logic_query_val_lo");
      Append_Line (State, "    STA alb_logic_stack_val_lo,X");
      Append_Line (State, "    LDA alb_logic_query_val_hi");
      Append_Line (State, "    STA alb_logic_stack_val_hi,X");
      Append_Line (State, "    LDA alb_logic_rule_var_bound");
      Append_Line (State, "    STA alb_logic_stack_var_bound,X");
      Append_Line (State, "    LDA alb_logic_rule_var_lo");
      Append_Line (State, "    STA alb_logic_stack_var_lo,X");
      Append_Line (State, "    LDA alb_logic_rule_var_hi");
      Append_Line (State, "    STA alb_logic_stack_var_hi,X");
      Append_Line (State, "    INC alb_logic_depth");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_pop_context:");
      Append_Line (State, "    LDA alb_logic_depth");
      Append_Line (State, "    BEQ alb_logic_pop_done");
      Append_Line (State, "    DEC alb_logic_depth");
      Append_Line (State, "    LDX alb_logic_depth");
      Append_Line (State, "    LDA alb_logic_stack_pred_lo,X");
      Append_Line (State, "    STA alb_logic_query_pred_lo");
      Append_Line (State, "    LDA alb_logic_stack_pred_hi,X");
      Append_Line (State, "    STA alb_logic_query_pred_hi");
      Append_Line (State, "    LDA alb_logic_stack_mode,X");
      Append_Line (State, "    STA alb_logic_query_mode");
      Append_Line (State, "    LDA alb_logic_stack_val_lo,X");
      Append_Line (State, "    STA alb_logic_query_val_lo");
      Append_Line (State, "    LDA alb_logic_stack_val_hi,X");
      Append_Line (State, "    STA alb_logic_query_val_hi");
      Append_Line (State, "    LDA alb_logic_stack_var_bound,X");
      Append_Line (State, "    STA alb_logic_rule_var_bound");
      Append_Line (State, "    LDA alb_logic_stack_var_lo,X");
      Append_Line (State, "    STA alb_logic_rule_var_lo");
      Append_Line (State, "    LDA alb_logic_stack_var_hi,X");
      Append_Line (State, "    STA alb_logic_rule_var_hi");
      Append_Line (State, "alb_logic_pop_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_fact_matches_query:");
      Append_Line (State, "    LDA alb_logic_fact_active,X");
      Append_Line (State, "    BNE alb_logic_fact_match_pred");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_fact_match_pred:");
      Append_Line (State, "    LDA alb_logic_fact_pred_lo,X");
      Append_Line (State, "    CMP alb_logic_query_pred_lo");
      Append_Line (State, "    BNE alb_logic_fact_no");
      Append_Line (State, "    LDA alb_logic_fact_pred_hi,X");
      Append_Line (State, "    CMP alb_logic_query_pred_hi");
      Append_Line (State, "    BNE alb_logic_fact_no");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    BEQ alb_logic_fact_need_arity0");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_logic_fact_need_const");
      Append_Line (State, "    LDA alb_logic_fact_arity,X");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BNE alb_logic_fact_no");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_fact_need_const:");
      Append_Line (State, "    LDA alb_logic_fact_arity,X");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BNE alb_logic_fact_no");
      Append_Line (State, "    LDA alb_logic_fact_arg_lo,X");
      Append_Line (State, "    CMP alb_logic_query_val_lo");
      Append_Line (State, "    BNE alb_logic_fact_no");
      Append_Line (State, "    LDA alb_logic_fact_arg_hi,X");
      Append_Line (State, "    CMP alb_logic_query_val_hi");
      Append_Line (State, "    BNE alb_logic_fact_no");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_fact_need_arity0:");
      Append_Line (State, "    LDA alb_logic_fact_arity,X");
      Append_Line (State, "    BEQ alb_logic_fact_yes");
      Append_Line (State, "alb_logic_fact_no:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_fact_yes:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_set_fact:");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "alb_logic_set_search:");
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Logic_Facts));
      Append_Line (State, "    BCS alb_logic_set_find_free");
      Append_Line (State, "    JSR alb_logic_fact_matches_query");
      Append_Line (State, "    BNE alb_logic_set_write");
      Append_Line (State, "    INX");
      Append_Line (State, "    JMP alb_logic_set_search");
      Append_Line (State, "alb_logic_set_find_free:");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "alb_logic_set_free_loop:");
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Logic_Facts));
      Append_Line (State, "    BCS alb_logic_set_done");
      Append_Line (State, "    LDA alb_logic_fact_active,X");
      Append_Line (State, "    BEQ alb_logic_set_new_slot");
      Append_Line (State, "    INX");
      Append_Line (State, "    JMP alb_logic_set_free_loop");
      Append_Line (State, "alb_logic_set_new_slot:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_fact_active,X");
      Append_Line (State, "    LDA alb_logic_query_pred_lo");
      Append_Line (State, "    STA alb_logic_fact_pred_lo,X");
      Append_Line (State, "    LDA alb_logic_query_pred_hi");
      Append_Line (State, "    STA alb_logic_fact_pred_hi,X");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    BEQ alb_logic_set_arity0");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_fact_arity,X");
      Append_Line (State, "    LDA alb_logic_query_val_lo");
      Append_Line (State, "    STA alb_logic_fact_arg_lo,X");
      Append_Line (State, "    LDA alb_logic_query_val_hi");
      Append_Line (State, "    STA alb_logic_fact_arg_hi,X");
      Append_Line (State, "    JMP alb_logic_set_write_value");
      Append_Line (State, "alb_logic_set_arity0:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_fact_arity,X");
      Append_Line (State, "    STA alb_logic_fact_arg_lo,X");
      Append_Line (State, "    STA alb_logic_fact_arg_hi,X");
      Append_Line (State, "    JMP alb_logic_set_write_value");
      Append_Line (State, "alb_logic_set_write:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_fact_active,X");
      Append_Line (State, "alb_logic_set_write_value:");
      Append_Line (State, "    LDA alb_logic_update_val_lo");
      Append_Line (State, "    STA alb_logic_fact_value_lo,X");
      Append_Line (State, "    LDA alb_logic_update_val_hi");
      Append_Line (State, "    STA alb_logic_fact_value_hi,X");
      Append_Line (State, "alb_logic_set_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_retract_fact:");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "alb_logic_retract_loop:");
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Logic_Facts));
      Append_Line (State, "    BCS alb_logic_retract_done");
      Append_Line (State, "    JSR alb_logic_fact_matches_query");
      Append_Line (State, "    BNE alb_logic_retract_hit");
      Append_Line (State, "    INX");
      Append_Line (State, "    JMP alb_logic_retract_loop");
      Append_Line (State, "alb_logic_retract_hit:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_fact_active,X");
      Append_Line (State, "alb_logic_retract_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_try_rule:");
      Append_Line (State, "    LDX alb_logic_rule_index");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_found_flag");
      Append_Line (State, "    STA alb_logic_rule_var_bound");
      Append_Line (State, "    STA alb_logic_rule_var_lo");
      Append_Line (State, "    STA alb_logic_rule_var_hi");
      Append_Line (State, "    LDA alb_logic_rule_head_mode,X");
      Append_Line (State, "    BEQ alb_logic_rule_head_none");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_logic_rule_head_const");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_logic_rule_seed_from_query");
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BEQ alb_logic_rule_begin_body");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_seed_from_query:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_rule_var_bound");
      Append_Line (State, "    LDA alb_logic_query_val_lo");
      Append_Line (State, "    STA alb_logic_rule_var_lo");
      Append_Line (State, "    LDA alb_logic_query_val_hi");
      Append_Line (State, "    STA alb_logic_rule_var_hi");
      Append_Line (State, "    JMP alb_logic_rule_begin_body");
      Append_Line (State, "alb_logic_rule_head_const:");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    BNE alb_logic_rule_head_const_check");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_head_const_check:");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BNE alb_logic_rule_begin_body");
      Append_Line (State, "    LDA alb_logic_rule_head_val_lo,X");
      Append_Line (State, "    CMP alb_logic_query_val_lo");
      Append_Line (State, "    BEQ alb_logic_rule_head_const_hi");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_head_const_hi:");
      Append_Line (State, "    LDA alb_logic_rule_head_val_hi,X");
      Append_Line (State, "    CMP alb_logic_query_val_hi");
      Append_Line (State, "    BEQ alb_logic_rule_head_const_ok");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_head_const_ok:");
      Append_Line (State, "    JMP alb_logic_rule_begin_body");
      Append_Line (State, "alb_logic_rule_head_none:");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    BEQ alb_logic_rule_begin_body");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_begin_body:");
      Append_Line (State, "    LDX alb_logic_rule_index");
      Append_Line (State, "    LDA alb_logic_rule_body_start,X");
      Append_Line (State, "    STA alb_logic_term_index");
      Append_Line (State, "    CLC");
      Append_Line (State, "    ADC alb_logic_rule_body_count,X");
      Append_Line (State, "    STA alb_logic_term_limit");
      Append_Line (State, "alb_logic_rule_body_loop:");
      Append_Line (State, "    LDA alb_logic_term_index");
      Append_Line (State, "    CMP alb_logic_term_limit");
      Append_Line (State, "    BCC alb_logic_rule_body_continue");
      Append_Line (State, "    JMP alb_logic_rule_success");
      Append_Line (State, "alb_logic_rule_body_continue:");
      Append_Line (State, "    LDX alb_logic_term_index");
      Append_Line (State, "    LDA alb_logic_rule_var_bound");
      Append_Line (State, "    STA alb_logic_tmp2");
      Append_Line (State, "    JSR alb_logic_push_context");
      Append_Line (State, "    BNE alb_logic_rule_term_ready");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_term_ready:");
      Append_Line (State, "    LDA alb_logic_rule_term_pred_lo,X");
      Append_Line (State, "    STA alb_logic_query_pred_lo");
      Append_Line (State, "    LDA alb_logic_rule_term_pred_hi,X");
      Append_Line (State, "    STA alb_logic_query_pred_hi");
      Append_Line (State, "    LDA alb_logic_rule_term_mode,X");
      Append_Line (State, "    BEQ alb_logic_rule_term_none");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_logic_rule_term_const");
      Append_Line (State, "    LDA alb_logic_tmp2");
      Append_Line (State, "    BEQ alb_logic_rule_term_var_query");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_query_mode");
      Append_Line (State, "    LDA alb_logic_rule_var_lo");
      Append_Line (State, "    STA alb_logic_query_val_lo");
      Append_Line (State, "    LDA alb_logic_rule_var_hi");
      Append_Line (State, "    STA alb_logic_query_val_hi");
      Append_Line (State, "    JMP alb_logic_rule_term_do");
      Append_Line (State, "alb_logic_rule_term_var_query:");
      Append_Line (State, "    LDA #$02");
      Append_Line (State, "    STA alb_logic_query_mode");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_query_val_lo");
      Append_Line (State, "    STA alb_logic_query_val_hi");
      Append_Line (State, "    JMP alb_logic_rule_term_do");
      Append_Line (State, "alb_logic_rule_term_const:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_query_mode");
      Append_Line (State, "    LDA alb_logic_rule_term_val_lo,X");
      Append_Line (State, "    STA alb_logic_query_val_lo");
      Append_Line (State, "    LDA alb_logic_rule_term_val_hi,X");
      Append_Line (State, "    STA alb_logic_query_val_hi");
      Append_Line (State, "    JMP alb_logic_rule_term_do");
      Append_Line (State, "alb_logic_rule_term_none:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_query_mode");
      Append_Line (State, "    STA alb_logic_query_val_lo");
      Append_Line (State, "    STA alb_logic_query_val_hi");
      Append_Line (State, "alb_logic_rule_term_do:");
      Append_Line (State, "    JSR alb_logic_prove");
      Append_Line (State, "    LDA alb_logic_found_flag");
      Append_Line (State, "    STA alb_logic_tmp3");
      Append_Line (State, "    LDA alb_logic_result_lo");
      Append_Line (State, "    STA alb_logic_tmp0");
      Append_Line (State, "    LDA alb_logic_result_hi");
      Append_Line (State, "    STA alb_logic_tmp1");
      Append_Line (State, "    JSR alb_logic_pop_context");
      Append_Line (State, "    LDA alb_logic_tmp3");
      Append_Line (State, "    BNE alb_logic_rule_term_matched");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_term_matched:");
      Append_Line (State, "    LDX alb_logic_term_index");
      Append_Line (State, "    LDA alb_logic_rule_term_mode,X");
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE alb_logic_rule_next_term");
      Append_Line (State, "    LDA alb_logic_tmp2");
      Append_Line (State, "    BNE alb_logic_rule_next_term");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_rule_var_bound");
      Append_Line (State, "    LDA alb_logic_tmp0");
      Append_Line (State, "    STA alb_logic_rule_var_lo");
      Append_Line (State, "    LDA alb_logic_tmp1");
      Append_Line (State, "    STA alb_logic_rule_var_hi");
      Append_Line (State, "alb_logic_rule_next_term:");
      Append_Line (State, "    INC alb_logic_term_index");
      Append_Line (State, "    JMP alb_logic_rule_body_loop");
      Append_Line (State, "alb_logic_rule_success:");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_found_flag");
      Append_Line (State, "    LDX alb_logic_rule_index");
      Append_Line (State, "    LDA alb_logic_rule_head_mode,X");
      Append_Line (State, "    BEQ alb_logic_rule_result_from_query");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_logic_rule_result_const");
      Append_Line (State, "    LDA alb_logic_rule_var_bound");
      Append_Line (State, "    BNE alb_logic_rule_result_var");
      Append_Line (State, "    JMP alb_logic_rule_fail");
      Append_Line (State, "alb_logic_rule_result_var:");
      Append_Line (State, "    LDA alb_logic_rule_var_lo");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    LDA alb_logic_rule_var_hi");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_rule_result_const:");
      Append_Line (State, "    LDA alb_logic_rule_head_val_lo,X");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    LDA alb_logic_rule_head_val_hi,X");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_rule_result_from_query:");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BNE alb_logic_rule_result_zero");
      Append_Line (State, "    LDA alb_logic_query_val_lo");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    LDA alb_logic_query_val_hi");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_rule_result_zero:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_rule_fail:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_found_flag");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_prove:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_found_flag");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "alb_logic_prove_fact_loop:");
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Logic_Facts));
      Append_Line (State, "    BCS alb_logic_prove_rules");
      Append_Line (State, "    JSR alb_logic_fact_matches_query");
      Append_Line (State, "    BEQ alb_logic_prove_fact_next");
      Append_Line (State, "    LDA #$01");
      Append_Line (State, "    STA alb_logic_found_flag");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    BEQ alb_logic_prove_yes");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BEQ alb_logic_prove_copy_query");
      Append_Line (State, "    LDA alb_logic_fact_arg_lo,X");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    LDA alb_logic_fact_arg_hi,X");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    JMP alb_logic_prove_yes");
      Append_Line (State, "alb_logic_prove_copy_query:");
      Append_Line (State, "    LDA alb_logic_query_val_lo");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    LDA alb_logic_query_val_hi");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    JMP alb_logic_prove_yes");
      Append_Line (State, "alb_logic_prove_fact_next:");
      Append_Line (State, "    INX");
      Append_Line (State, "    JMP alb_logic_prove_fact_loop");
      Append_Line (State, "alb_logic_prove_rules:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_rule_index");
      Append_Line (State, "alb_logic_prove_rule_loop:");
      Append_Line (State, "    LDA alb_logic_rule_index");
      Append_Line (State, "    CMP #" & Byte_Hex (State.Logic_Rule_Count));
      Append_Line (State, "    BCS alb_logic_prove_no");
      Append_Line (State, "    TAX");
      Append_Line (State, "    LDA alb_logic_rule_head_pred_lo,X");
      Append_Line (State, "    CMP alb_logic_query_pred_lo");
      Append_Line (State, "    BNE alb_logic_prove_rule_next");
      Append_Line (State, "    LDA alb_logic_rule_head_pred_hi,X");
      Append_Line (State, "    CMP alb_logic_query_pred_hi");
      Append_Line (State, "    BNE alb_logic_prove_rule_next");
      Append_Line (State, "    JSR alb_logic_try_rule");
      Append_Line (State, "    LDA alb_logic_found_flag");
      Append_Line (State, "    BNE alb_logic_prove_yes");
      Append_Line (State, "alb_logic_prove_rule_next:");
      Append_Line (State, "    INC alb_logic_rule_index");
      Append_Line (State, "    JMP alb_logic_prove_rule_loop");
      Append_Line (State, "alb_logic_prove_no:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_found_flag");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_prove_yes:");
      Append_Line (State, "    LDA alb_logic_found_flag");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_find_first:");
      Append_Line (State, "    JSR alb_logic_prove");
      Append_Line (State, "    LDA alb_logic_found_flag");
      Append_Line (State, "    BNE alb_logic_find_have");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_result_lo");
      Append_Line (State, "    STA alb_logic_result_hi");
      Append_Line (State, "    TAX");
      Append_Line (State, "    RTS");
      Append_Line (State, "alb_logic_find_have:");
      Append_Line (State, "    LDA alb_logic_result_lo");
      Append_Line (State, "    LDX alb_logic_result_hi");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_append_result:");
      Append_Line (State, "    LDY alb_logic_result_count");
      Append_Line (State, "    CPY #" & Byte_Hex (Max_Logic_Results));
      Append_Line (State, "    BCS alb_logic_append_done");
      Append_Line (State, "    STA alb_logic_results_lo,Y");
      Append_Line (State, "    TXA");
      Append_Line (State, "    STA alb_logic_results_hi,Y");
      Append_Line (State, "    INC alb_logic_result_count");
      Append_Line (State, "alb_logic_append_done:");
      Append_Line (State, "    RTS");
      Append_Line (State, "");
      Append_Line (State, "alb_logic_findall:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_result_count");
      Append_Line (State, "    LDX #$00");
      Append_Line (State, "alb_logic_findall_fact_loop:");
      Append_Line (State, "    CPX #" & Byte_Hex (Max_Logic_Facts));
      Append_Line (State, "    BCS alb_logic_findall_rules");
      Append_Line (State, "    JSR alb_logic_fact_matches_query");
      Append_Line (State, "    BEQ alb_logic_findall_fact_next");
      Append_Line (State, "    STX alb_logic_term_index");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    CMP #$02");
      Append_Line (State, "    BNE alb_logic_findall_query_const");
      Append_Line (State, "    LDX alb_logic_term_index");
      Append_Line (State, "    LDA alb_logic_fact_arg_lo,X");
      Append_Line (State, "    STA alb_logic_tmp0");
      Append_Line (State, "    LDA alb_logic_fact_arg_hi,X");
      Append_Line (State, "    TAX");
      Append_Line (State, "    LDA alb_logic_tmp0");
      Append_Line (State, "    JSR alb_logic_append_result");
      Append_Line (State, "    LDX alb_logic_term_index");
      Append_Line (State, "    JMP alb_logic_findall_fact_next");
      Append_Line (State, "alb_logic_findall_query_const:");
      Append_Line (State, "    CMP #$01");
      Append_Line (State, "    BNE alb_logic_findall_fact_next");
      Append_Line (State, "    LDA alb_logic_query_val_lo");
      Append_Line (State, "    LDX alb_logic_query_val_hi");
      Append_Line (State, "    JSR alb_logic_append_result");
      Append_Line (State, "    LDX alb_logic_term_index");
      Append_Line (State, "alb_logic_findall_fact_next:");
      Append_Line (State, "    INX");
      Append_Line (State, "    JMP alb_logic_findall_fact_loop");
      Append_Line (State, "alb_logic_findall_rules:");
      Append_Line (State, "    LDA #$00");
      Append_Line (State, "    STA alb_logic_rule_index");
      Append_Line (State, "alb_logic_findall_rule_loop:");
      Append_Line (State, "    LDA alb_logic_rule_index");
      Append_Line (State, "    CMP #" & Byte_Hex (State.Logic_Rule_Count));
      Append_Line (State, "    BCS alb_logic_findall_done");
      Append_Line (State, "    TAX");
      Append_Line (State, "    LDA alb_logic_rule_head_pred_lo,X");
      Append_Line (State, "    CMP alb_logic_query_pred_lo");
      Append_Line (State, "    BNE alb_logic_findall_rule_next");
      Append_Line (State, "    LDA alb_logic_rule_head_pred_hi,X");
      Append_Line (State, "    CMP alb_logic_query_pred_hi");
      Append_Line (State, "    BNE alb_logic_findall_rule_next");
      Append_Line (State, "    JSR alb_logic_try_rule");
      Append_Line (State, "    LDA alb_logic_found_flag");
      Append_Line (State, "    BEQ alb_logic_findall_rule_next");
      Append_Line (State, "    LDA alb_logic_query_mode");
      Append_Line (State, "    BEQ alb_logic_findall_rule_next");
      Append_Line (State, "    LDA alb_logic_result_lo");
      Append_Line (State, "    LDX alb_logic_result_hi");
      Append_Line (State, "    JSR alb_logic_append_result");
      Append_Line (State, "alb_logic_findall_rule_next:");
      Append_Line (State, "    INC alb_logic_rule_index");
      Append_Line (State, "    JMP alb_logic_findall_rule_loop");
      Append_Line (State, "alb_logic_findall_done:");
      Append_Line (State, "    RTS");
   end Emit_Runtime_Support;

   procedure Emit_If_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Then_Block : constant Node_Index := Tree (Node).Right_Child;
      Else_Block : constant Node_Index :=
        (if Then_Block /= 0 then Tree (Then_Block).Next_Sibling else 0);
      False_Id   : Natural := 0;
      End_Id     : Natural := 0;
   begin
      Reserve_Label_Id (State, False_Id);
      Emit_Condition_False_Branch
        (State,
         Tree (Node).Left_Child,
         "alb_if_false_" & Decimal_Image (False_Id));
      if not State.Success then
         return;
      end if;

      Emit_Node_Chain (State, Then_Block);
      if not State.Success then
         return;
      end if;

      if Else_Block /= 0 then
         Reserve_Label_Id (State, End_Id);
         Append_Line (State, "    JMP alb_if_end_" & Decimal_Image (End_Id));
      end if;

      Append_Line (State, "alb_if_false_" & Decimal_Image (False_Id) & ":");

      if Else_Block /= 0 then
         Emit_Node_Chain (State, Else_Block);
         if not State.Success then
            return;
         end if;
         Append_Line (State, "alb_if_end_" & Decimal_Image (End_Id) & ":");
      end if;
   end Emit_If_Stmt;

   procedure Emit_While_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Loop_Id : Natural := 0;
   begin
      Reserve_Label_Id (State, Loop_Id);
      Append_Line (State, Loop_Continue_Label (Loop_Id) & ":");
      Emit_Condition_False_Branch
        (State,
         Tree (Node).Left_Child,
         Loop_End_Label (Loop_Id));
      if not State.Success then
         return;
      end if;

      Push_Loop_Context (State, Loop_Id, 0);
      if not State.Success then
         return;
      end if;
      Emit_Node_Chain (State, Tree (Node).Right_Child);
      Pop_Loop_Context (State);
      if not State.Success then
         return;
      end if;

      Append_Line (State, "    JMP " & Loop_Continue_Label (Loop_Id));
      Append_Line (State, Loop_End_Label (Loop_Id) & ":");
   end Emit_While_Stmt;

   procedure Emit_Repeat_Stmt
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Loop_Id : Natural := 0;
   begin
      Reserve_Label_Id (State, Loop_Id);
      Append_Line (State, Loop_Top_Label (Loop_Id) & ":");
      Push_Loop_Context (State, Loop_Id, 0);
      if not State.Success then
         return;
      end if;
      Emit_Node_Chain (State, Tree (Node).Left_Child);
      Pop_Loop_Context (State);
      if not State.Success then
         return;
      end if;

      Append_Line (State, Loop_Continue_Label (Loop_Id) & ":");
      Emit_Condition_False_Branch
        (State,
         Tree (Node).Right_Child,
         Loop_Top_Label (Loop_Id));
      if not State.Success then
         return;
      end if;

      Append_Line (State, Loop_End_Label (Loop_Id) & ":");
   end Emit_Repeat_Stmt;

   procedure Emit_Data_Section (State : in out Emitter_State) is
   begin
      Append_Line (State, "");
      for I in 1 .. State.Symbol_Count loop
         if State.Symbols (I).Active
            and then Is_Byte_Scalar_Symbol (State.Symbols (I).Kind)
          then
            Append_Line (State, Symbol_Name (State, I) & ":");
            Append_Line (State, "    DB $00");
         elsif State.Symbols (I).Active
            and then (State.Symbols (I).Kind = Symbol_U16
              or else State.Symbols (I).Kind = Symbol_HW16
              or else State.Symbols (I).Kind = Symbol_String)
          then
            Append_Line (State, Symbol_Name (State, I) & ":");
            if State.Symbols (I).Kind = Symbol_String then
               Append_Line (State, "    DB <alb_empty_string");
               Append_Line (State, "    DB >alb_empty_string");
            else
               Append_Line (State, "    DB $00");
               Append_Line (State, "    DB $00");
            end if;
         elsif State.Symbols (I).Active
            and then Is_Array_Symbol (State.Symbols (I).Kind)
          then
            Append_Line (State, Symbol_Name (State, I) & ":");
            for J in 1 .. Array_Total_Bytes (State.Symbols (I)) loop
               Append_Line (State, "    DB $00");
            end loop;
         end if;
      end loop;

      for I in 1 .. State.Symbol_Count loop
         if State.Symbols (I).Active
            and then Is_Byte_Scalar_Symbol (State.Symbols (I).Kind)
         then
            Append_Line (State, Symbol_Snapshot_Label (I) & ":");
            Append_Line (State, "    DB $00");
         elsif State.Symbols (I).Active
            and then (State.Symbols (I).Kind = Symbol_U16
              or else State.Symbols (I).Kind = Symbol_Pointer16
              or else State.Symbols (I).Kind = Symbol_HW16
              or else State.Symbols (I).Kind = Symbol_String)
         then
            Append_Line (State, Symbol_Snapshot_Label (I) & ":");
            if State.Symbols (I).Kind = Symbol_String then
               Append_Line (State, "    DB <alb_empty_string");
               Append_Line (State, "    DB >alb_empty_string");
            else
               Append_Line (State, "    DB $00");
               Append_Line (State, "    DB $00");
            end if;
         elsif State.Symbols (I).Active
            and then Is_Array_Symbol (State.Symbols (I).Kind)
         then
            Append_Line (State, Symbol_Snapshot_Label (I) & ":");
            for J in 1 .. Array_Total_Bytes (State.Symbols (I)) loop
               Append_Line (State, "    DB $00");
            end loop;
         end if;
      end loop;

      for I in 1 .. State.Temporal_Count loop
         if State.Temporals (I).Active then
            Append_Line (State, Temporal_Head_Label (I) & ":");
            Append_Line (State, "    DB $00");
            Append_Line (State, Temporal_Count_Label (I) & ":");
            Append_Line (State, "    DB $00");
            Append_Line (State, Temporal_Save_Head_Label (I) & ":");
            Append_Line (State, "    DB $00");
            Append_Line (State, Temporal_Save_Count_Label (I) & ":");
            Append_Line (State, "    DB $00");
         end if;
      end loop;

      for I in 1 .. State.String_Count loop
         if State.String_Literals (I).Active then
            Append_Line (State, String_Label (I) & ":");
            Append_Line
              (State,
               "    DB """
               & State.String_Literals (I).Text (1 .. State.String_Literals (I).Text_Len)
               & """,0");
         end if;
      end loop;

      Append_Line (State, "alb_empty_string:");
      Append_Line (State, "    DB 0");

      Append_Line (State, "alb_print_value:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_print_hundreds:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_print_tens:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_expr_tmp0:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_expr_tmp1:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_math_lhs:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_math_rhs:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_math_rem:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_math_w_lhs:");
      Append_Line (State, "    DW $0000");
      Append_Line (State, "alb_math_w_rhs:");
      Append_Line (State, "    DW $0000");
      Append_Line (State, "alb_math_w_acc:");
      Append_Line (State, "    DW $0000");
      Append_Line (State, "alb_math_w_rem:");
      Append_Line (State, "    DW $0000");
      Append_Line (State, "alb_delay_frames:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_tick_counter:");
      Append_Line (State, "    DW $0000");
      Append_Line (State, "alb_screen_width:");
      Append_Line (State, "    DW $0140");
      Append_Line (State, "alb_screen_height:");
      Append_Line (State, "    DW $00C8");
      Append_Line (State, "alb_file_handle:");
      Append_Line (State, "    DB $01");
      Append_Line (State, "alb_file_len:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_file_mode_ptr:");
      Append_Line (State, "    DW $0000");
      Append_Line (State, "alb_file_buf:");
      for I in 1 .. 256 loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_tmp_u16_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_tmp_u16_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_foreach_index:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_swappop_count:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_swappop_index:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_draw_color:");
      Append_Line (State, "    DB $01");
      Append_Line (State, "alb_clear_color:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_last_key:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_shift_state:");
      Append_Line (State, "    DB $00");
      for I in 0 .. 7 loop
         Append_Line
           (State,
            "alb_key_matrix_" & Decimal_Image (I) & ":");
         Append_Line (State, "    DB $FF");
      end loop;
      Append_Line (State, "alb_key_state:");
      for I in 0 .. 255 loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_prev_key_state:");
      for I in 0 .. 255 loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_key_latch:");
      for I in 0 .. 255 loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_latched_count:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_latched_keys:");
      for I in 1 .. 64 loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_dirty_rows:");
      for I in 0 .. 24 loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_live_dirty_rows:");
      for I in 0 .. 24 loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_frame_counter_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_frame_counter_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_cease_flag:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_static_ready:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_auto_restore_paint:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_c64_sprite_slot:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_c64_sprite_shape:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_c64_sprite_color:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_c64_sprite_value:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_c64_sprite_x_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_c64_sprite_x_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_c64_sprite_y:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_plot_char:");
      Append_Line (State, "    DB $A0");
      Append_Line (State, "alb_text_x:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_text_y:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_x:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_y:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_x1:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_y1:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_dx:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_dy:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_steps:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_acc_x:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_acc_y:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_sx:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_sy:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_counter:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_graphics_rows:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_rect_x:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_rect_y:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_rect_w:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_rect_h:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_circle_r:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_tri_x2:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_tri_y2:");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("target_lo") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("target_hi") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("other_lo") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("other_hi") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("operand_lo") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("operand_hi") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("old_lo") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("old_hi") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("other_old_lo") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("other_old_hi") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("opcode") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("width") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("journal_count") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("block_depth") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_query_pred_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_query_pred_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_query_mode:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_query_val_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_query_val_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_update_val_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_update_val_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_result_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_result_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_found_flag:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_depth:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_rule_var_bound:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_rule_var_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_rule_var_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_rule_index:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_term_index:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_term_limit:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_tmp0:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_tmp1:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_tmp2:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_tmp3:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_notify_pred_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_notify_pred_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_notify_arg_lo:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_notify_arg_hi:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_result_count:");
      Append_Line (State, "    DB $00");
      Append_Line (State, "alb_logic_stack_pred_lo:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_stack_pred_hi:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_stack_mode:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_stack_val_lo:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_stack_val_hi:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_stack_var_bound:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_stack_var_lo:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_stack_var_hi:");
      for I in 1 .. Max_Logic_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_active:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_pred_lo:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_pred_hi:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_arity:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_arg_lo:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_arg_hi:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_value_lo:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_fact_value_hi:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_active:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_pred_lo:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_pred_hi:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_arity:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_arg_lo:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_arg_hi:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_value_lo:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_save_fact_value_hi:");
      for I in 1 .. Max_Logic_Facts loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_results_lo:");
      for I in 1 .. Max_Logic_Results loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_results_hi:");
      for I in 1 .. Max_Logic_Results loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_logic_rule_head_pred_lo:");
      if State.Logic_Rule_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (Low_Byte (State.Logic_Rules (I).Head_Pred_Id)));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_head_pred_hi:");
      if State.Logic_Rule_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (High_Byte (State.Logic_Rules (I).Head_Pred_Id)));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_head_mode:");
      if State.Logic_Rule_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (State.Logic_Rules (I).Head_Mode));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_head_val_lo:");
      if State.Logic_Rule_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (Low_Byte (Normalize_Word (State.Logic_Rules (I).Head_Value))));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_head_val_hi:");
      if State.Logic_Rule_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (High_Byte (Normalize_Word (State.Logic_Rules (I).Head_Value))));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_body_start:");
      if State.Logic_Rule_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (State.Logic_Rules (I).Body_Start));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_body_count:");
      if State.Logic_Rule_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (State.Logic_Rules (I).Body_Count));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_term_pred_lo:");
      if State.Logic_Rule_Term_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Term_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (Low_Byte (State.Logic_Rule_Terms (I).Pred_Id)));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_term_pred_hi:");
      if State.Logic_Rule_Term_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Term_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (High_Byte (State.Logic_Rule_Terms (I).Pred_Id)));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_term_mode:");
      if State.Logic_Rule_Term_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Term_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (State.Logic_Rule_Terms (I).Arg_Mode));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_term_val_lo:");
      if State.Logic_Rule_Term_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Term_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (Low_Byte (Normalize_Word (State.Logic_Rule_Terms (I).Arg_Value))));
         end loop;
      end if;
      Append_Line (State, "alb_logic_rule_term_val_hi:");
      if State.Logic_Rule_Term_Count = 0 then
         Append_Line (State, "    DB $00");
      else
         for I in 1 .. State.Logic_Rule_Term_Count loop
            Append_Line
              (State,
               "    DB " & Byte_Hex (High_Byte (Normalize_Word (State.Logic_Rule_Terms (I).Arg_Value))));
         end loop;
      end if;
      Append_Line (State, Rev_Runtime_Label ("journal_opcode") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("journal_width") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("journal_target_lo") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("journal_target_hi") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("journal_old_lo") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("journal_old_hi") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("journal_aux_lo") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("journal_aux_hi") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("block_marks") & ":");
      for I in 1 .. Max_Rev_Block_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_count") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("save_block_depth") & ":");
      Append_Line (State, "    DB $00");
      Append_Line (State, Rev_Runtime_Label ("save_journal_opcode") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_width") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_target_lo") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_target_hi") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_old_lo") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_old_hi") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_aux_lo") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_journal_aux_hi") & ":");
      for I in 1 .. Max_Rev_Journal loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, Rev_Runtime_Label ("save_block_marks") & ":");
      for I in 1 .. Max_Rev_Block_Depth loop
         Append_Line (State, "    DB $00");
      end loop;
      Append_Line (State, "alb_back_screen_row_lo:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB <(alb_back_screen+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_back_screen_row_hi:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB >(alb_back_screen+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_back_color_row_lo:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB <(alb_back_color+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_back_color_row_hi:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB >(alb_back_color+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_static_screen_row_lo:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB <(alb_static_screen+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_static_screen_row_hi:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB >(alb_static_screen+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_static_color_row_lo:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB <(alb_static_color+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_static_color_row_hi:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB >(alb_static_color+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_live_screen_row_lo:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB <(C64_SCREEN_RAM+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_live_screen_row_hi:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB >(C64_SCREEN_RAM+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_live_color_row_lo:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB <(C64_COLOR_RAM+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_live_color_row_hi:");
      for I in 0 .. 24 loop
         Append_Line
           (State,
            "    DB >(C64_COLOR_RAM+" & Decimal_Image (I * 40) & ")");
      end loop;
      Append_Line (State, "alb_back_screen:");
      for I in 1 .. 1_000 loop
         Append_Line (State, "    DB $20");
      end loop;
      Append_Line (State, "alb_back_color:");
      for I in 1 .. 1_000 loop
         Append_Line (State, "    DB $01");
      end loop;
      Append_Line (State, "alb_static_screen:");
      for I in 1 .. 1_000 loop
         Append_Line (State, "    DB $20");
      end loop;
      Append_Line (State, "alb_static_color:");
      for I in 1 .. 1_000 loop
         Append_Line (State, "    DB $01");
      end loop;
      Append_Line (State, "alb_c64_sprite_masks:");
      for I in 0 .. 7 loop
         Append_Line (State, "    DB " & Byte_Hex (2 ** I));
      end loop;
      Append_Line (State, "alb_c64_sprite_ptr_values:");
      Append_Line (State, "    DB $80");
      Append_Line (State, "    DB $81");
      Append_Line (State, "    DB $82");
      Append_Line (State, "alb_c64_builtin_sprites:");
      for I in 1 .. 64 loop
         Append_Line (State, "    DB $00");
      end loop;
      for Row in 0 .. 20 loop
         if Row in 8 .. 12 then
            Append_Line (State, "    DB $FF");
            Append_Line (State, "    DB $FF");
            Append_Line (State, "    DB $FF");
         else
            Append_Line (State, "    DB $00");
            Append_Line (State, "    DB $00");
            Append_Line (State, "    DB $00");
         end if;
      end loop;
      Append_Line (State, "    DB $00");
      for Row in 0 .. 20 loop
         if Row in 6 .. 13 then
            Append_Line (State, "    DB $00");
            Append_Line (State, "    DB $FF");
            Append_Line (State, "    DB $00");
         else
            Append_Line (State, "    DB $00");
            Append_Line (State, "    DB $00");
            Append_Line (State, "    DB $00");
         end if;
      end loop;
      Append_Line (State, "    DB $00");
   end Emit_Data_Section;

   procedure Emit_Node_Chain
     (State : in out Emitter_State;
      First : Node_Index)
   is
      Curr : Node_Index := First;
   begin
      if Curr /= 0 and then Tree (Curr).Kind = AST_Block_Stmt then
         Curr := Tree (Curr).Left_Child;
      end if;

      while Curr /= 0 and then State.Success loop
         if State.Native_ASM_State = ASM_Mode_Ignored
           and then Tree (Curr).Kind /= AST_Disable_Asm
         then
            null;
         else
         case Tree (Curr).Kind is
            when AST_Version =>
               null;

            when AST_Const_Decl | AST_Enum_Decl | AST_Procedure_Decl |
                 AST_Function_Decl | AST_Range_Type_Decl |
                 AST_Struct_Decl | AST_Parallel_Decl |
                 AST_Module | AST_DeclareModule |
                 AST_Import | AST_Import_C | AST_On_Block | AST_Knows_Change |
                 AST_Predicate_Decl | AST_Rule_Decl | AST_Constraint_Decl =>
               null;

            when AST_Let_Stmt =>
               Emit_Let_Stmt (State, Curr);

            when AST_Temporal_Decl =>
               Emit_Temporal_Declaration (State, Curr);

            when AST_Strict_Stmt | AST_Slide_Stmt =>
               null;

            when AST_Poke_Stmt =>
               Emit_Poke_Stmt (State, Curr);

            when AST_For_Stmt =>
               Emit_For_Stmt (State, Curr);

            when AST_Foreach_Stmt =>
               Emit_Foreach_Stmt (State, Curr);

            when AST_If_Stmt =>
               Emit_If_Stmt (State, Curr);

            when AST_While_Stmt =>
               Emit_While_Stmt (State, Curr);

            when AST_Repeat_Stmt =>
               Emit_Repeat_Stmt (State, Curr);

            when AST_Advance_Stmt =>
               Emit_Advance_Stmt (State, Curr);

            when AST_Save_State =>
               Emit_Save_Load_State (State, False, Curr);

            when AST_Load_State =>
               Emit_Save_Load_State (State, True, Curr);

            when AST_Break_Stmt =>
               Emit_Break_Stmt (State, Curr);

            when AST_Continue_Stmt =>
               Emit_Continue_Stmt (State, Curr);

            when AST_Match_Stmt | AST_Select_Stmt =>
               Emit_Match_Select_Stmt (State, Curr);

            when AST_Call_Stmt =>
               Emit_Call_Stmt (State, Curr);

            when AST_SwapPop_Stmt =>
               Emit_SwapPop_Stmt (State, Curr);

            when AST_Locate_Stmt =>
               Emit_Locate_Stmt (State, Curr);

            when AST_Text =>
               Emit_Text_Stmt (State, Curr);

            when AST_Print_Stmt | AST_Print_Str_Stmt =>
               Emit_Print_Stmt (State, Curr);

            when AST_Return_Stmt =>
               Emit_Return_Stmt (State, Curr);

            when AST_Knows_Fact =>
               declare
                  Pred_Id   : Natural := 0;
                  Pred_Name : constant String := Predicate_Name_Of (Tree (Curr).Left_Child);
               begin
                  Register_Logic_Predicate (State, Curr, Pred_Name, Pred_Id);
                  if not State.Success then
                     return;
                  end if;

                  Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Pred_Id)));
                  Append_Line (State, "    STA alb_logic_query_pred_lo");
                  Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Pred_Id)));
                  Append_Line (State, "    STA alb_logic_query_pred_hi");
                  Append_Line (State, "    LDA #$00");
                  Append_Line (State, "    STA alb_logic_query_mode");
                  Append_Line (State, "    STA alb_logic_query_val_lo");
                  Append_Line (State, "    STA alb_logic_query_val_hi");
                  Emit_Logic_Value_To_Storage
                    (State,
                     Tree (Curr).Right_Child,
                     "alb_logic_update_val_lo",
                     "alb_logic_update_val_hi");
                  if not State.Success then
                     return;
                  end if;
                  Append_Line (State, "    JSR alb_logic_set_fact");
               end;

            when AST_Assert_Stmt | AST_Retract_Stmt =>
               declare
                  Pred_Id : Natural := 0;
                  Arg_Node : constant Node_Index := Tree (Curr).Left_Child;
               begin
                  Register_Logic_Predicate (State, Curr, Predicate_Name_Of (Curr), Pred_Id);
                  if not State.Success then
                     return;
                  end if;

                  Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Pred_Id)));
                  Append_Line (State, "    STA alb_logic_query_pred_lo");
                  Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Pred_Id)));
                  Append_Line (State, "    STA alb_logic_query_pred_hi");

                  if Arg_Node = 0 then
                     Append_Line (State, "    LDA #$00");
                     Append_Line (State, "    STA alb_logic_query_mode");
                     Append_Line (State, "    STA alb_logic_query_val_lo");
                     Append_Line (State, "    STA alb_logic_query_val_hi");
                     Append_Line (State, "    STA alb_logic_notify_arg_lo");
                     Append_Line (State, "    STA alb_logic_notify_arg_hi");
                  else
                     Append_Line (State, "    LDA #$01");
                     Append_Line (State, "    STA alb_logic_query_mode");
                     Emit_Logic_Value_To_Storage
                       (State,
                        Arg_Node,
                        "alb_logic_query_val_lo",
                        "alb_logic_query_val_hi");
                     if not State.Success then
                        return;
                     end if;
                     Append_Line (State, "    LDA alb_logic_query_val_lo");
                     Append_Line (State, "    STA alb_logic_notify_arg_lo");
                     Append_Line (State, "    LDA alb_logic_query_val_hi");
                     Append_Line (State, "    STA alb_logic_notify_arg_hi");
                  end if;

                  Append_Line (State, "    LDA #$01");
                  Append_Line (State, "    STA alb_logic_update_val_lo");
                  Append_Line (State, "    LDA #$00");
                  Append_Line (State, "    STA alb_logic_update_val_hi");

                  if Tree (Curr).Kind = AST_Assert_Stmt then
                     Append_Line (State, "    JSR alb_logic_set_fact");
                  else
                     Append_Line (State, "    JSR alb_logic_retract_fact");
                  end if;

                  Append_Line (State, "    LDA alb_logic_query_pred_lo");
                  Append_Line (State, "    STA alb_logic_notify_pred_lo");
                  Append_Line (State, "    LDA alb_logic_query_pred_hi");
                  Append_Line (State, "    STA alb_logic_notify_pred_hi");
                  Append_Line (State, "    JSR alb_on_knows_change");
               end;

            when AST_Update_Stmt =>
               declare
                  Pred_Node : constant Node_Index := Tree (Curr).Left_Child;
                  Pred_Id   : Natural := 0;
                  Arg_Node  : constant Node_Index := Predicate_Arg_Node (Pred_Node);
               begin
                  Register_Logic_Predicate (State, Curr, Predicate_Name_Of (Pred_Node), Pred_Id);
                  if not State.Success then
                     return;
                  end if;

                  Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Pred_Id)));
                  Append_Line (State, "    STA alb_logic_query_pred_lo");
                  Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Pred_Id)));
                  Append_Line (State, "    STA alb_logic_query_pred_hi");
                  if Arg_Node = 0 then
                     Append_Line (State, "    LDA #$00");
                     Append_Line (State, "    STA alb_logic_query_mode");
                     Append_Line (State, "    STA alb_logic_query_val_lo");
                     Append_Line (State, "    STA alb_logic_query_val_hi");
                  else
                     Append_Line (State, "    LDA #$01");
                     Append_Line (State, "    STA alb_logic_query_mode");
                     Emit_Logic_Value_To_Storage
                       (State,
                        Arg_Node,
                        "alb_logic_query_val_lo",
                        "alb_logic_query_val_hi");
                     if not State.Success then
                        return;
                     end if;
                  end if;

                  Emit_Logic_Value_To_Storage
                    (State,
                     Tree (Curr).Right_Child,
                     "alb_logic_update_val_lo",
                     "alb_logic_update_val_hi");
                  if not State.Success then
                     return;
                  end if;
                  Append_Line (State, "    JSR alb_logic_set_fact");
                  Append_Line (State, "    LDA alb_logic_query_pred_lo");
                  Append_Line (State, "    STA alb_logic_notify_pred_lo");
                  Append_Line (State, "    LDA alb_logic_query_pred_hi");
                  Append_Line (State, "    STA alb_logic_notify_pred_hi");
                  Append_Line (State, "    LDA alb_logic_update_val_lo");
                  Append_Line (State, "    STA alb_logic_notify_arg_lo");
                  Append_Line (State, "    LDA alb_logic_update_val_hi");
                  Append_Line (State, "    STA alb_logic_notify_arg_hi");
                  Append_Line (State, "    JSR alb_on_knows_change");
               end;

            when AST_Findall_Query =>
               declare
                  Pred_Node     : constant Node_Index := Tree (Curr).Left_Child;
                  Target_Node   : constant Node_Index := Tree (Curr).Right_Child;
                  Target_Symbol : Symbol_Index := 0;
                  Limit         : Natural := 0;
                  Copy_Id       : Natural := 0;
                  Done_Id       : Natural := 0;
               begin
                  if not Is_Var_Node (Target_Node) then
                     Fail (State, Curr, "FINDALL requires an array target");
                     return;
                  end if;

                  Target_Symbol := Find_Visible_Symbol (State, Node_Lexeme (Target_Node));
                  if Target_Symbol = 0 or else not Is_Array_Symbol (State.Symbols (Target_Symbol).Kind) then
                     Fail (State, Curr, "FINDALL target must be a declared STRICT or SLIDE array");
                     return;
                  end if;

                  declare
                     Pred_Id  : Natural := 0;
                     Arg_Node : constant Node_Index := Predicate_Arg_Node (Pred_Node);
                  begin
                     Register_Logic_Predicate
                       (State, Pred_Node, Predicate_Name_Of (Pred_Node), Pred_Id);
                     if not State.Success then
                        return;
                     end if;

                     Append_Line (State, "    LDA #" & Byte_Hex (Low_Byte (Pred_Id)));
                     Append_Line (State, "    STA alb_logic_query_pred_lo");
                     Append_Line (State, "    LDA #" & Byte_Hex (High_Byte (Pred_Id)));
                     Append_Line (State, "    STA alb_logic_query_pred_hi");

                     if Arg_Node = 0 then
                        Append_Line (State, "    LDA #$00");
                        Append_Line (State, "    STA alb_logic_query_mode");
                        Append_Line (State, "    STA alb_logic_query_val_lo");
                        Append_Line (State, "    STA alb_logic_query_val_hi");
                     elsif Tree (Arg_Node).Kind = AST_Logic_Var then
                        Append_Line (State, "    LDA #$02");
                        Append_Line (State, "    STA alb_logic_query_mode");
                        Append_Line (State, "    LDA #$00");
                        Append_Line (State, "    STA alb_logic_query_val_lo");
                        Append_Line (State, "    STA alb_logic_query_val_hi");
                     else
                        Append_Line (State, "    LDA #$01");
                        Append_Line (State, "    STA alb_logic_query_mode");
                        Emit_Logic_Value_To_Storage
                          (State,
                           Arg_Node,
                           "alb_logic_query_val_lo",
                           "alb_logic_query_val_hi");
                        if not State.Success then
                           return;
                        end if;
                     end if;
                  end;

                  Append_Line (State, "    JSR alb_logic_findall");

                  Limit := Array_Visible_Length (State.Symbols (Target_Symbol));
                  Reserve_Label_Id (State, Copy_Id);
                  Reserve_Label_Id (State, Done_Id);

                  Append_Line (State, "    LDY #$00");
                  Append_Line (State, "alb_logic_findall_clear_" & Decimal_Image (Copy_Id) & ":");
                  Append_Line (State, "    LDA #$00");
                  Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & ",Y");
                  if Is_U16_Array_Symbol (State.Symbols (Target_Symbol).Kind) then
                     Append_Line (State, "    INY");
                     Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & ",Y");
                  end if;
                  Append_Line
                    (State,
                     "    CPY #" & Byte_Hex (Array_Total_Bytes (State.Symbols (Target_Symbol)) - 1));
                  Append_Line
                    (State,
                     "    BEQ alb_logic_findall_copy_" & Decimal_Image (Copy_Id));
                  Append_Line (State, "    INY");
                  Append_Line
                    (State,
                     "    JMP alb_logic_findall_clear_" & Decimal_Image (Copy_Id));

                  Append_Line (State, "alb_logic_findall_copy_" & Decimal_Image (Copy_Id) & ":");
                  Append_Line (State, "    LDY #$00");
                  Append_Line (State, "alb_logic_findall_copy_loop_" & Decimal_Image (Copy_Id) & ":");
                  Append_Line (State, "    CPY alb_logic_result_count");
                  Append_Line
                    (State,
                     "    BCS alb_logic_findall_done_" & Decimal_Image (Done_Id));
                  Append_Line
                    (State,
                     "    CPY #" & Byte_Hex (Limit));
                  Append_Line
                    (State,
                     "    BCS alb_logic_findall_done_" & Decimal_Image (Done_Id));
                  if Is_U16_Array_Symbol (State.Symbols (Target_Symbol).Kind) then
                     Append_Line (State, "    LDA alb_logic_results_lo,Y");
                     Append_Line (State, "    STA alb_tmp_u16_lo");
                     Append_Line (State, "    LDA alb_logic_results_hi,Y");
                     Append_Line (State, "    STA alb_tmp_u16_hi");
                     Append_Line (State, "    TYA");
                     Append_Line (State, "    ASL A");
                     Append_Line (State, "    TAY");
                     Append_Line (State, "    LDA alb_tmp_u16_lo");
                     Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & ",Y");
                     Append_Line (State, "    INY");
                     Append_Line (State, "    LDA alb_tmp_u16_hi");
                     Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & ",Y");
                     Append_Line (State, "    TYA");
                     Append_Line (State, "    LSR A");
                     Append_Line (State, "    TAY");
                  else
                     Append_Line (State, "    LDA alb_logic_results_lo,Y");
                     Append_Line (State, "    STA " & Symbol_Name (State, Target_Symbol) & ",Y");
                  end if;
                  Append_Line (State, "    INY");
                  Append_Line
                    (State,
                     "    JMP alb_logic_findall_copy_loop_" & Decimal_Image (Copy_Id));
                  Append_Line
                    (State,
                     "alb_logic_findall_done_" & Decimal_Image (Done_Id) & ":");
               end;

            when AST_Find_Query | AST_Query | AST_Knows_Query =>
               if Expr_Is_Word (State, Curr) then
                  Emit_Word_Expr (State, Curr);
               else
                  Emit_Byte_Expr (State, Curr);
               end if;

            when AST_Temporal_Block | AST_Atomic_Block =>
               Emit_Node_Chain (State, Tree (Curr).Left_Child);

            when AST_Reversible_Block =>
               if State.Reversible_Depth >= Max_Rev_Block_Depth then
                  Fail (State, Curr, "REVERSIBLE nesting exceeded the backend limit");
                  return;
               end if;
               State.Reversible_Depth := State.Reversible_Depth + 1;
               Append_Line (State, "    JSR " & Rev_Runtime_Label ("begin_block"));
               Emit_Node_Chain (State, Tree (Curr).Left_Child);
               if not State.Success then
                  return;
               end if;
               Append_Line (State, "    JSR " & Rev_Runtime_Label ("end_block"));
               State.Reversible_Depth := State.Reversible_Depth - 1;

            when AST_Try_Stmt =>
               Emit_Node_Chain (State, Tree (Curr).Left_Child);

            when AST_Enable_Asm =>
               declare
                  Gate_Lexeme : constant String := Node_Lexeme (Curr);
                  Family      : constant Native_ASM_Family :=
                    Native_ASM_Family_From_Lexeme (Gate_Lexeme);
               begin
                  if Native_ASM_Family_Is_Active (Family) then
                     State.Native_ASM_State := ASM_Mode_Active;
                     Append_Line
                       (State,
                        "    ; ALB native ASM enabled: "
                        & Upper_ASCII (Gate_Lexeme));
                  else
                     State.Native_ASM_State := ASM_Mode_Ignored;
                     Append_Line
                       (State,
                        "    ; ALB native ASM ignored: "
                        & Upper_ASCII (Gate_Lexeme));
                  end if;
               end;

            when AST_Disable_Asm =>
               if State.Native_ASM_State /= ASM_Mode_Off then
                  Append_Line (State, "    ; ALB native ASM disabled");
               end if;
               State.Native_ASM_State := ASM_Mode_Off;

            when AST_Asm_Block =>
               if State.Native_ASM_State /= ASM_Mode_Active then
                  Fail
                    (State,
                     Curr,
                     "ASM blocks require an active ENABLEASM family block");
               else
                  Append_Line (State, ASM_Block_Body (Curr));
               end if;

            when AST_Input_Stmt =>
               if Tree (Curr).Right_Child /= 0 then
                  Emit_Clear_Target (State, Tree (Curr).Right_Child);
               end if;

            when AST_Readline_Stmt =>
               if Tree (Curr).Left_Child /= 0 then
                  Emit_Clear_Target (State, Tree (Curr).Left_Child);
               end if;

            when AST_Create_Window =>
               Emit_Create_Window_Stmt (State, Curr);

            when AST_Set_Fullscreen | AST_Set_Resizable | AST_Set_Stretchy =>
               if Tree (Curr).Left_Child /= 0 then
                  Emit_Byte_Expr (State, Tree (Curr).Left_Child);
               end if;

            when AST_Color =>
               Emit_Color_Stmt (State, Curr);

            when AST_Clear =>
               Emit_Clear_Stmt (State, Curr);

            when AST_Draw | AST_FILL =>
               Emit_Draw_Stmt (State, Curr);

            when AST_Plot =>
               Emit_Plot_Stmt (State, Curr);

            when AST_Cease =>
               Emit_Cease_Stmt (State, Curr);

            when AST_Delay_Stmt =>
               Emit_Delay_Stmt (State, Curr);

            when AST_File_Write =>
               Emit_File_Write_Stmt (State, Curr);

            when AST_File_Close =>
               Emit_File_Close_Stmt (State, Curr);

            when AST_Load_Stmt =>
               Emit_Load_Stmt (State, Curr);

            when AST_Play_Sound =>
               Emit_Play_Sound_Stmt (State, Curr);

            when AST_Flush_Stmt =>
               null;

            when AST_Tick | AST_Msg_Box |
                 AST_Spawn_Stmt | AST_Sync_Stmt |
                 AST_Throw_Stmt |
                 AST_Claim_Stmt | AST_Bind_Stmt | AST_Drop_Stmt |
                 AST_Sweep_Stmt =>
               Append_Line
                 (State,
                  "    ; ALB-65 stub: " & Node_Kind'Image (Tree (Curr).Kind));

            when AST_Rev_Add_Stmt | AST_Rev_Sub_Stmt | AST_Rev_Xor_Stmt |
                 AST_Rev_Rol_Stmt | AST_Rev_Ror_Stmt | AST_Rev_Swap_Stmt |
                 AST_Rev_Not_Stmt | AST_Rev_Neg_Stmt =>
               Emit_Reversible_Stmt (State, Curr);

            when AST_Listen =>
               Emit_Listen_Stmt (State, Curr);

            when AST_Block_Stmt =>
               Emit_Node_Chain (State, Curr);

            when others =>
               Fail
                 (State,
                  Curr,
                  "unsupported statement for the current C64 backend: "
                  & Node_Kind'Image (Tree (Curr).Kind));
         end case;
         end if;

         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Node_Chain;

   procedure Emit_Procedure_Definitions
     (State : in out Emitter_State;
      First : Node_Index)
   is
      Curr            : Node_Index := First;
      Name_Node       : Node_Index := 0;
      Proc_Id         : Natural := 0;
      Saved_Procedure : constant Natural := State.Current_Procedure;
   begin
      if Curr /= 0 and then Tree (Curr).Kind = AST_Block_Stmt then
         Curr := Tree (Curr).Left_Child;
      end if;

      while Curr /= 0 and then State.Success loop
         if Tree (Curr).Kind = AST_Procedure_Decl
           or else Tree (Curr).Kind = AST_Function_Decl
         then
            Name_Node := Tree (Curr).Left_Child;
            if not Is_Var_Node (Name_Node) then
               Fail (State, Curr, "procedure declaration is missing a valid name");
               return;
            end if;

            Proc_Id := Find_Procedure (State, Node_Lexeme (Name_Node));
            if Proc_Id = 0 then
               Fail (State, Curr, "procedure declaration was not registered");
               return;
            end if;

            Append_Line (State, "");
            Append_Line (State, Procedure_Label (State, Proc_Id) & ":");
            State.Current_Procedure := Proc_Id;
            Emit_Node_Chain (State, Tree (Curr).Right_Child);
            State.Current_Procedure := Saved_Procedure;
            if not State.Success then
               return;
            end if;
            Append_Line (State, Return_Label (State, Proc_Id) & ":");
            Append_Line (State, "    RTS");
         elsif Tree (Curr).Kind = AST_Import_C then
            if Tree (Curr).Left_Child /= 0
              and then Tree (Tree (Curr).Left_Child).Kind in AST_Procedure_Decl | AST_Function_Decl
            then
               Name_Node := Tree (Tree (Curr).Left_Child).Left_Child;
               if Is_Var_Node (Name_Node) then
                  Proc_Id := Find_Procedure (State, Node_Lexeme (Name_Node));
                  if Proc_Id /= 0 then
                     Append_Line (State, "");
                     Append_Line (State, Procedure_Label (State, Proc_Id) & ":");
                     Append_Line (State, "    RTS");
                  end if;
               end if;
            end if;
         elsif Tree (Curr).Kind = AST_Block_Stmt then
            Emit_Procedure_Definitions (State, Tree (Curr).Left_Child);
            if not State.Success then
               return;
            end if;
         elsif Tree (Curr).Kind in AST_Module | AST_DeclareModule then
            Emit_Procedure_Definitions (State, Tree (Curr).Right_Child);
            if not State.Success then
               return;
            end if;
         end if;

         Curr := Tree (Curr).Next_Sibling;
      end loop;

      State.Current_Procedure := Saved_Procedure;
   end Emit_Procedure_Definitions;

   procedure Register_Struct_Instance
     (State       : in out Emitter_State;
      Node        : Node_Index;
      Stored_Name : String;
      Struct_Id   : Natural;
      Symbol_Out  : out Symbol_Index)
   is
      Field_Symbol : Symbol_Index := 0;
   begin
      Register_Symbol (State, Node, Stored_Name, Symbol_Struct_Instance, Symbol_Out);
      if not State.Success then
         return;
      end if;
      State.Symbols (Symbol_Out).Struct_Id := Struct_Id;

      for I in 1 .. State.Structs (Struct_Id).Field_Count loop
         Register_Symbol
           (State,
            Node,
            Stored_Name & "__"
            & State.Structs (Struct_Id).Fields (I).Name
                (1 .. State.Structs (Struct_Id).Fields (I).Name_Len),
            State.Structs (Struct_Id).Fields (I).Kind,
            Field_Symbol);
         if not State.Success then
            return;
         end if;
         State.Symbols (Field_Symbol).Range_Id :=
           State.Structs (Struct_Id).Fields (I).Range_Id;
      end loop;
   end Register_Struct_Instance;

   procedure Collect_Range_Type_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Name_Node  : constant Node_Index := Tree (Node).Left_Child;
      Base_Node  : constant Node_Index := Tree (Node).Right_Child;
      Low_Node   : constant Node_Index := (if Base_Node /= 0 then Tree (Base_Node).Left_Child else 0);
      High_Node  : constant Node_Index := (if Low_Node /= 0 then Tree (Low_Node).Next_Sibling else 0);
      Info       : Type_Info := (others => <>);
      Low_Value  : Integer := 0;
      High_Value : Integer := 0;
      Range_Id   : Natural := 0;
   begin
      if not Is_Var_Node (Name_Node) or else not Is_Var_Node (Base_Node) then
         Fail (State, Node, "range type declaration is malformed");
         return;
      end if;

      Resolve_Type_Info (State, Node_Lexeme (Base_Node), False, False, False, Info);
      if not Info.Found or else Info.Is_Void or else Info.Is_Struct then
         Fail (State, Node, "range types currently support byte/word scalar bases only");
         return;
      end if;

      if not Evaluate_Static_Expr (State, Low_Node, Low_Value)
        or else not Evaluate_Static_Expr (State, High_Node, High_Value)
      then
         Fail (State, Node, "range type bounds must be static expressions");
         return;
      end if;

      Register_Range_Type
        (State,
         Node,
         Node_Lexeme (Name_Node),
         Info.Kind,
         Low_Value,
         High_Value,
         Range_Id);
   end Collect_Range_Type_Declaration;

   procedure Collect_Struct_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Name_Node  : constant Node_Index := Tree (Node).Left_Child;
      Body_Node  : constant Node_Index := Tree (Node).Right_Child;
      Curr_Field : Node_Index := (if Body_Node /= 0 and then Tree (Body_Node).Kind = AST_Block_Stmt
                                  then Tree (Body_Node).Left_Child
                                  else Body_Node);
      Struct_Id  : Natural := 0;
      Field_Name : Node_Index := 0;
      Type_Node  : Node_Index := 0;
      Info       : Type_Info := (others => <>);
   begin
      if not Is_Var_Node (Name_Node) then
         Fail (State, Node, "struct declaration is missing a valid name");
         return;
      end if;

      Register_Struct_Type (State, Node, Node_Lexeme (Name_Node), Struct_Id);
      if not State.Success then
         return;
      end if;

      while Curr_Field /= 0 and then State.Success loop
         if Tree (Curr_Field).Kind = AST_Bitfield_Decl then
            Fail (State, Curr_Field, "C64 struct bitfields are not supported yet");
            return;
         end if;

         Field_Name := Tree (Curr_Field).Left_Child;
         if not Is_Var_Node (Field_Name) then
            Fail (State, Curr_Field, "struct field is malformed");
            return;
         end if;

         if Tree (Curr_Field).Token_Index > 0 then
            Resolve_Type_Info
              (State,
               Token_Lexeme (Tree (Curr_Field).Token_Index),
               False,
               False,
               False,
               Info);
         else
            Type_Node := Tree (Field_Name).Right_Child;
            if Type_Node /= 0 then
               Resolve_Type_Info (State, Node_Lexeme (Type_Node), False, False, False, Info);
            else
               Info := (Found => True, Kind => Symbol_U8, others => <>);
            end if;
         end if;

         if not Info.Found or else Info.Is_Void or else Info.Is_Struct then
            Fail (State, Curr_Field, "struct fields currently support only byte/word scalars and range aliases");
            return;
         end if;

         Add_Struct_Field
           (State,
            Curr_Field,
            Struct_Id,
            Node_Lexeme (Field_Name),
            Info.Kind,
            Info.Range_Id);

         Curr_Field := Tree (Curr_Field).Next_Sibling;
      end loop;
   end Collect_Struct_Declaration;

   procedure Collect_Parallel_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index;
      Procedure_Id : Natural := 0)
   is
      Group_Node   : constant Node_Index := Tree (Node).Left_Child;
      Bound_Node   : constant Node_Index := (if Group_Node /= 0 then Tree (Group_Node).Left_Child else 0);
      Field_Node   : Node_Index := Tree (Node).Right_Child;
      Capacity     : Natural := 0;
      Group_Id     : Natural := 0;
      Group_Symbol : Symbol_Index := 0;
      Stored_Name  : constant String :=
        (if Procedure_Id = 0
         then Node_Lexeme (Group_Node)
         else Scoped_Name (State, Procedure_Id, Node_Lexeme (Group_Node)));
      Type_Node    : Node_Index := 0;
      Field_Name   : Node_Index := 0;
      Info         : Type_Info := (others => <>);
   begin
      if not Is_Var_Node (Group_Node) then
         Fail (State, Node, "parallel declaration is missing a group name");
         return;
      end if;

      if Bound_Node = 0 or else Tree (Bound_Node).Next_Sibling /= 0 then
         Fail (State, Node, "C64 parallel groups currently require exactly one static capacity");
         return;
      end if;

      if not Parse_Integer_Expr (State, Bound_Node, Capacity)
        or else Capacity = 0 or else Capacity > 255
      then
         Fail (State, Node, "parallel group capacity must be a literal within 1..255");
         return;
      end if;

      Register_Parallel_Group (State, Node, Stored_Name, Capacity, Group_Id);
      if not State.Success then
         return;
      end if;

      Register_Symbol (State, Node, Stored_Name, Symbol_Parallel_Group, Group_Symbol);
      if not State.Success then
         return;
      end if;
      State.Symbols (Group_Symbol).Parallel_Id := Group_Id;

      while Field_Node /= 0 and then State.Success loop
         if Tree (Field_Node).Kind /= AST_Parallel_Field then
            Fail (State, Field_Node, "parallel field declaration is malformed");
            return;
         end if;

         Field_Name := Tree (Field_Node).Left_Child;
         if not Is_Var_Node (Field_Name) then
            Fail (State, Field_Node, "parallel field is missing its name");
            return;
         end if;

         Type_Node := Tree (Field_Name).Right_Child;
         if Type_Node /= 0 then
            Resolve_Type_Info (State, Node_Lexeme (Type_Node), False, False, False, Info);
         else
            Info := (Found => True, Kind => Symbol_U8, others => <>);
         end if;

         if not Info.Found or else Info.Is_Void or else Info.Is_Struct then
            Fail (State, Field_Node, "parallel fields currently support only byte/word scalars and range aliases");
            return;
         end if;

         Add_Parallel_Field
           (State,
            Field_Node,
            Group_Id,
            Stored_Name,
            Node_Lexeme (Field_Name),
            Info.Kind,
            Info.Range_Id);
         Field_Node := Tree (Field_Node).Next_Sibling;
      end loop;
   end Collect_Parallel_Declaration;

   procedure Collect_Temporal_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index;
      Procedure_Id : Natural := 0)
   is
      Target_Node  : constant Node_Index := Tree (Node).Left_Child;
      History_Node : constant Node_Index := Tree (Node).Right_Child;
      Kind         : Symbol_Kind := Symbol_U8;
      Type_Found   : Boolean := False;
      Temporal_Id  : Natural := 0;
      History_Size : Natural := 2;
      Stored_Name  : String (1 .. Max_Name_Length * 2) := (others => ' ');
      Stored_Len   : Natural := 0;
   begin
      if not Is_Var_Node (Target_Node) then
         Fail (State, Node, "temporal declaration requires a scalar target");
         return;
      end if;

      if Tree (Node).Token_Index > 0 then
         Kind := Type_Kind_From_Lexeme (Token_Lexeme (Tree (Node).Token_Index), Type_Found);
         if not Type_Found or else not (Is_Byte_Scalar_Symbol (Kind) or else Is_Word_Scalar_Symbol (Kind) or else Is_String_Symbol (Kind)) then
            Fail (State, Node, "temporal declarations currently support byte/word and string/binary scalars");
            return;
         end if;
      else
         Kind := Symbol_U8;
      end if;

      if History_Node /= 0 then
         if not Parse_Integer_Expr (State, History_Node, History_Size)
           or else History_Size = 0
         then
            Fail (State, Node, "temporal HISTORY must be a static positive integer on C64");
            return;
         end if;
      end if;

      declare
         Name_Value : constant String :=
           (if Procedure_Id = 0
            then Node_Lexeme (Target_Node)
            else Scoped_Name (State, Procedure_Id, Node_Lexeme (Target_Node)));
      begin
         Stored_Len := Name_Value'Length;
         Stored_Name (1 .. Stored_Len) := Name_Value;
      end;

      Register_Temporal
        (State,
         Node,
         Stored_Name (1 .. Stored_Len),
         Kind,
         History_Size,
         Temporal_Id);
   end Collect_Temporal_Declaration;

   procedure Collect_Let_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index;
      Procedure_Id : Natural := 0)
   is
      Target_Node : constant Node_Index := Tree (Node).Left_Child;
      Symbol      : Symbol_Index := 0;
      Info        : Type_Info := (others => <>);
      Temporal_Id : Natural := 0;
   begin
      if Tree (Node).Token_Index = 0 then
         return;
      end if;

      if not Is_Var_Node (Target_Node) then
         Fail (State, Node, "C64 backend only supports scalar LET targets");
         return;
      end if;

      Resolve_Type_Info
        (State,
         Token_Lexeme (Tree (Node).Token_Index),
         False,
         False,
         True,
         Info);
      if Is_Wide_Type_Lexeme (Upper_ASCII (Token_Lexeme (Tree (Node).Token_Index))) then
         Fail (State, Node, "C64 backend rejects types wider than 16 bits (U32/U64 and friends)");
         return;
      elsif not Info.Found or else Info.Is_Void then
         Fail (State, Node, "C64 backend only supports byte/word, string/binary, range, and struct declarations");
         return;
      end if;

      declare
         Stored_Name : constant String :=
           (if Procedure_Id = 0
            then Node_Lexeme (Target_Node)
            else Scoped_Name (State, Procedure_Id, Node_Lexeme (Target_Node)));
      begin
         if Info.Is_Struct then
            Register_Struct_Instance (State, Node, Stored_Name, Info.Struct_Id, Symbol);
         else
            Register_Symbol (State, Node, Stored_Name, Info.Kind, Symbol);
         end if;
      end;

      if State.Success and then Symbol /= 0 then
         State.Symbols (Symbol).Range_Id := Info.Range_Id;
      end if;

      if Tree (Node).Kind = AST_Temporal_Decl then
         Register_Temporal
           (State,
            Node,
            (if Procedure_Id = 0
             then Node_Lexeme (Target_Node)
             else Scoped_Name (State, Procedure_Id, Node_Lexeme (Target_Node))),
            Info.Kind,
            2,
            Temporal_Id);
      end if;
   end Collect_Let_Declaration;

   procedure Collect_Array_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index;
      Procedure_Id : Natural := 0)
   is
      Var_Node     : constant Node_Index := Tree (Node).Left_Child;
      Type_Node    : constant Node_Index :=
        (if Var_Node /= 0 then Tree (Var_Node).Right_Child else 0);
      First_Bound  : constant Node_Index := Tree (Node).Right_Child;
      Second_Bound : constant Node_Index :=
        (if First_Bound /= 0 then Tree (First_Bound).Next_Sibling else 0);
      Third_Bound  : constant Node_Index :=
        (if Second_Bound /= 0 then Tree (Second_Bound).Next_Sibling else 0);
      Bound_1      : Natural := 0;
      Bound_2      : Natural := 0;
      Type_Found   : Boolean := False;
      Base_Kind    : Symbol_Kind := Symbol_U8;
      Array_Kind   : Symbol_Kind := Symbol_Strict_U8_Array;
      Symbol       : Symbol_Index := 0;
   begin
      if not Is_Var_Node (Var_Node) then
         Fail (State, Node, "STRICT/SLIDE declaration is missing an array name");
         return;
      end if;

      if Type_Node /= 0 then
         Base_Kind := Type_Kind_From_Lexeme (Node_Lexeme (Type_Node), Type_Found);
         if not Type_Found then
            Fail (State, Node, "C64 STRICT/SLIDE arrays only support U8, BOOL, U16, and HW16 elements");
            return;
         end if;
      else
         Base_Kind := Symbol_U8;
      end if;

      if Tree (Node).Kind = AST_Strict_Stmt then
         if First_Bound = 0 or else not Parse_Integer_Expr (State, First_Bound, Bound_1) then
            Fail (State, Node, "STRICT arrays require a literal first bound");
            return;
         end if;

         if Bound_1 = 0 or else Bound_1 > 255 then
            Fail (State, Node, "STRICT first bound must stay within 1..255");
            return;
         end if;

         if Second_Bound /= 0 then
            if not Parse_Integer_Expr (State, Second_Bound, Bound_2) then
               Fail (State, Node, "two-dimensional STRICT arrays require literal bounds on C64");
               return;
            end if;

            if Bound_2 = 0 or else Bound_2 > 255 then
               Fail (State, Node, "STRICT second bound must stay within 1..255");
               return;
            end if;
         end if;

         if Third_Bound /= 0 then
            Fail (State, Node, "C64 STRICT arrays support at most two dimensions");
            return;
         end if;

         if Base_Kind in Symbol_U16 | Symbol_Pointer16 | Symbol_HW16 then
            Array_Kind := Symbol_Strict_U16_Array;
         else
            Array_Kind := Symbol_Strict_U8_Array;
         end if;
      else
         if First_Bound = 0 or else Second_Bound = 0 then
            Fail (State, Node, "SLIDE arrays require literal capacity and active bounds");
            return;
         end if;

         if not Parse_Integer_Expr (State, First_Bound, Bound_1)
           or else not Parse_Integer_Expr (State, Second_Bound, Bound_2)
         then
            Fail (State, Node, "SLIDE capacity and active bounds must be literals on C64");
            return;
         end if;

         if Bound_1 = 0 or else Bound_1 > 255 or else Bound_2 = 0 or else Bound_2 > Bound_1 then
            Fail (State, Node, "SLIDE bounds must satisfy 1 <= active <= capacity <= 255");
            return;
         end if;

         if Third_Bound /= 0 then
            Fail (State, Node, "C64 SLIDE arrays use exactly one active window");
            return;
         end if;

         if Base_Kind in Symbol_U16 | Symbol_Pointer16 | Symbol_HW16 then
            Array_Kind := Symbol_Slide_U16_Array;
         else
            Array_Kind := Symbol_Slide_U8_Array;
         end if;
      end if;

      declare
         Stored_Name : constant String :=
           (if Procedure_Id = 0
            then Node_Lexeme (Var_Node)
            else Scoped_Name (State, Procedure_Id, Node_Lexeme (Var_Node)));
      begin
         Register_Symbol (State, Node, Stored_Name, Array_Kind, Symbol);
      end;
      if not State.Success then
         return;
      end if;

      State.Symbols (Symbol).Dim_Count :=
        (if Tree (Node).Kind = AST_Strict_Stmt and then Second_Bound /= 0 then 2 else 1);
      State.Symbols (Symbol).Bounds (1) := Bound_1;
      State.Symbols (Symbol).Bounds (2) := Bound_2;
      if Tree (Node).Kind = AST_Slide_Stmt then
         State.Symbols (Symbol).Active_Bound := Bound_2;
      end if;

      if Array_Total_Bytes (State.Symbols (Symbol)) > 256 then
         Fail (State, Node, "STRICT/SLIDE storage exceeds the backend's 8-bit indexed C64 limit");
      end if;
   end Collect_Array_Declaration;

   procedure Collect_Const_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Ref_Node : constant Node_Index := Tree (Node).Left_Child;
      Value    : Integer := 0;
   begin
      if Ref_Node = 0 then
         Fail (State, Node, "compile-time constant is missing its identifier");
         return;
      end if;

      if not Evaluate_Static_Expr (State, Tree (Node).Right_Child, Value) then
         Fail (State, Node, "C64 compile-time constants require a static expression");
         return;
      end if;

      Register_Const (State, Node, Node_Lexeme (Ref_Node), Value);
   end Collect_Const_Declaration;

   procedure Collect_Enum_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Curr  : Node_Index := Tree (Node).Left_Child;
      Value : Integer := 0;
   begin
      while Curr /= 0 and then State.Success loop
         Register_Const (State, Curr, Node_Lexeme (Curr), Value);
         Value := Value + 1;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Collect_Enum_Declaration;

   procedure Collect_Procedure_Declaration
     (State : in out Emitter_State;
      Node  : Node_Index)
   is
      Name_Node    : constant Node_Index := Tree (Node).Left_Child;
      Body_Node    : constant Node_Index := Tree (Node).Right_Child;
      Anchor_Node  : constant Node_Index :=
        (if Name_Node /= 0 then Tree (Name_Node).Right_Child else 0);
      Param_Node   : Node_Index :=
        (if Anchor_Node /= 0 and then Tree (Anchor_Node).Kind = AST_Arg_List
         then Tree (Anchor_Node).Left_Child
         else 0);
      Proc_Id      : Natural := 0;
      Param_Symbol : Symbol_Index := 0;
      Param_Kind   : Symbol_Kind := Symbol_U8;
      Type_Info_Value : Type_Info := (Found => True, Kind => Symbol_U8, others => <>);
      Saved_Procedure : constant Natural := State.Current_Procedure;
      Return_Name  : String (1 .. Max_Name_Length + 8) := (others => ' ');
      Return_Len   : Natural := 0;
   begin
      if not Is_Var_Node (Name_Node) then
         Fail (State, Node, "procedure declaration is missing a valid name");
         return;
      end if;

      Register_Procedure
        (State,
         Node,
         Node_Lexeme (Name_Node),
         Body_Node,
         Tree (Node).Kind = AST_Function_Decl,
         Proc_Id);
      if not State.Success then
         return;
      end if;

      if Tree (Node).Kind = AST_Function_Decl then
         if Tree (Node).Token_Index > 0 then
            Resolve_Type_Info
              (State,
               Token_Lexeme (Tree (Node).Token_Index),
               False,
               False,
               False,
               Type_Info_Value);
         else
            Type_Info_Value := (Found => True, Kind => Symbol_U8, others => <>);
         end if;

         if not Type_Info_Value.Found or else Type_Info_Value.Is_Void or else Type_Info_Value.Is_Struct then
            Fail (State, Node, "function return types currently support byte/word, string/binary, and range aliases");
            return;
         end if;

         State.Procedures (Proc_Id).Return_Void := False;
         State.Procedures (Proc_Id).Return_Kind := Type_Info_Value.Kind;
         State.Procedures (Proc_Id).Return_Range_Id := Type_Info_Value.Range_Id;

         declare
            Proc_Name : constant String :=
              State.Procedures (Proc_Id).Name (1 .. State.Procedures (Proc_Id).Name_Len);
            Ret_Name  : constant String := Proc_Name & "__RETURN";
         begin
            Return_Len := Ret_Name'Length;
            Return_Name (1 .. Return_Len) := Ret_Name;
         end;

         Register_Symbol
           (State,
            Node,
            Return_Name (1 .. Return_Len),
            Type_Info_Value.Kind,
            State.Procedures (Proc_Id).Return_Symbol);
         if not State.Success then
            return;
         end if;
         State.Symbols (State.Procedures (Proc_Id).Return_Symbol).Range_Id := Type_Info_Value.Range_Id;
      else
         State.Procedures (Proc_Id).Return_Void := True;
      end if;

      while Param_Node /= 0 and then State.Success loop
         if Tree (Param_Node).Kind = AST_Param_Decl then
            if State.Procedures (Proc_Id).Param_Count >= Max_Procedure_Params then
               Fail (State, Param_Node, "procedure parameter budget exhausted for the C64 backend");
               return;
            end if;

            Type_Info_Value := (Found => True, Kind => Symbol_U8, others => <>);

            if Tree (Param_Node).Right_Child /= 0 then
               Resolve_Type_Info
                 (State,
                  Node_Lexeme (Tree (Param_Node).Right_Child),
                 False,
                 False,
                 False,
                  Type_Info_Value);
               if not Type_Info_Value.Found or else Type_Info_Value.Is_Void or else Type_Info_Value.Is_Struct then
                  Fail (State, Param_Node, "procedure parameters currently support byte/word, string/binary, and range aliases");
                  return;
               end if;
               Param_Kind := Type_Info_Value.Kind;
            else
               Param_Kind := Symbol_U8;
            end if;

            Register_Symbol
              (State,
               Param_Node,
               Scoped_Name (State, Proc_Id, Node_Lexeme (Tree (Param_Node).Left_Child)),
               Param_Kind,
               Param_Symbol);
            if not State.Success then
               return;
            end if;

            State.Procedures (Proc_Id).Param_Count :=
              State.Procedures (Proc_Id).Param_Count + 1;
            State.Procedures (Proc_Id).Param_Symbols (State.Procedures (Proc_Id).Param_Count) :=
              Param_Symbol;
            State.Procedures (Proc_Id).Param_Is_Out (State.Procedures (Proc_Id).Param_Count) :=
              Tree (Param_Node).Token_Index > 0
                and then Tokens (Tree (Param_Node).Token_Index).Kind = TOK_OUT;
            State.Symbols (Param_Symbol).Range_Id := Type_Info_Value.Range_Id;
         end if;

         Param_Node := Tree (Param_Node).Next_Sibling;
      end loop;

      State.Current_Procedure := Proc_Id;
      Collect_Declarations (State, Body_Node, Proc_Id);
      State.Current_Procedure := Saved_Procedure;
   end Collect_Procedure_Declaration;

   procedure Collect_Declarations
     (State : in out Emitter_State;
      Node  : Node_Index;
      Procedure_Id : Natural := 0)
   is
      Curr : Node_Index := Node;
   begin
      if Curr = 0 or else not State.Success then
         return;
      end if;

      if Tree (Curr).Kind = AST_Block_Stmt then
         Curr := Tree (Curr).Left_Child;
      end if;

      while Curr /= 0 and then State.Success loop
         case Tree (Curr).Kind is
            when AST_Version =>
               null;

            when AST_Const_Decl =>
               Collect_Const_Declaration (State, Curr);

            when AST_Enum_Decl =>
               Collect_Enum_Declaration (State, Curr);

            when AST_Let_Stmt =>
               Collect_Let_Declaration (State, Curr, Procedure_Id);

            when AST_Temporal_Decl =>
               Collect_Temporal_Declaration (State, Curr, Procedure_Id);

            when AST_Strict_Stmt | AST_Slide_Stmt =>
               Collect_Array_Declaration (State, Curr, Procedure_Id);

            when AST_Range_Type_Decl =>
               Collect_Range_Type_Declaration (State, Curr);

            when AST_Struct_Decl =>
               Collect_Struct_Declaration (State, Curr);

            when AST_Parallel_Decl =>
               Collect_Parallel_Declaration (State, Curr, Procedure_Id);

            when AST_Procedure_Decl | AST_Function_Decl =>
               if Procedure_Id /= 0 then
                  Fail (State, Curr, "nested procedures are not supported by the current C64 backend");
               else
                  Collect_Procedure_Declaration (State, Curr);
               end if;

            when AST_Module | AST_DeclareModule =>
               if Tree (Curr).Right_Child /= 0 then
                  Collect_Declarations (State, Tree (Curr).Right_Child, Procedure_Id);
               end if;

            when AST_Import =>
               null;

            when AST_Import_C =>
               if Tree (Curr).Left_Child /= 0
                 and then Tree (Curr).Left_Child in 1 .. Max_Nodes
                 and then Tree (Tree (Curr).Left_Child).Kind in AST_Procedure_Decl | AST_Function_Decl
               then
                  Collect_Procedure_Declaration (State, Tree (Curr).Left_Child);
               end if;

            when AST_On_Block =>
               if Tree (Curr).Token_Index > 0 then
                  case Tokens (Tree (Curr).Token_Index).Kind is
                     when TOK_TICK =>
                        State.On_Tick_Node := Tree (Curr).Left_Child;

                     when TOK_PAINT =>
                        State.On_Paint_Node := Tree (Curr).Left_Child;

                     when TOK_KEY =>
                        State.On_Key_Node := Tree (Curr).Left_Child;

                     when others =>
                        null;
                  end case;
               end if;

            when AST_Predicate_Decl =>
               declare
                  Pred_Id : Natural := 0;
               begin
                  if Tree (Curr).Left_Child /= 0 then
                     Register_Logic_Predicate
                       (State, Tree (Curr).Left_Child, Predicate_Name_Of (Tree (Curr).Left_Child), Pred_Id);
                  end if;
               end;

            when AST_Rule_Decl | AST_Constraint_Decl =>
               Collect_Logic_Rule_Declaration (State, Curr);

            when AST_Knows_Change =>
               Collect_Logic_Hook (State, Curr);

            when AST_For_Stmt | AST_While_Stmt =>
               if Tree (Curr).Kind = AST_For_Stmt then
                  declare
                     Loop_Symbol : Symbol_Index := 0;
                  begin
                     if Tree (Curr).Token_Index > 0 then
                        Loop_Symbol := Find_Visible_Symbol (State, Token_Lexeme (Tree (Curr).Token_Index));
                        if Loop_Symbol = 0 then
                           Register_Symbol
                             (State,
                              Curr,
                              (if Procedure_Id = 0
                              then Token_Lexeme (Tree (Curr).Token_Index)
                               else Scoped_Name (State, Procedure_Id, Token_Lexeme (Tree (Curr).Token_Index))),
                              Symbol_U8,
                              Loop_Symbol);
                        elsif not Is_Byte_Scalar_Symbol (State.Symbols (Loop_Symbol).Kind)
                          and then not Is_Word_Scalar_Symbol (State.Symbols (Loop_Symbol).Kind)
                        then
                           Fail (State, Curr, "FOR loop variable must be an 8-bit or 16-bit scalar");
                        end if;
                     end if;
                  end;
               end if;
               Collect_Declarations (State, Tree (Curr).Right_Child, Procedure_Id);

            when AST_Foreach_Stmt =>
               declare
                  Iter_Symbol : Symbol_Index := 0;
                  Array_Sym   : Symbol_Index := 0;
                  Iter_Kind   : Symbol_Kind := Symbol_U8;
                  Iter_Name   : constant String :=
                    (if Procedure_Id = 0
                     then Token_Lexeme (Tree (Curr).Token_Index)
                     else Scoped_Name (State, Procedure_Id, Token_Lexeme (Tree (Curr).Token_Index)));
               begin
                  if Is_Var_Node (Tree (Curr).Left_Child) then
                     Array_Sym := Find_Visible_Symbol (State, Node_Lexeme (Tree (Curr).Left_Child));
                     if Array_Sym /= 0 and then Is_U16_Array_Symbol (State.Symbols (Array_Sym).Kind) then
                        Iter_Kind := Symbol_U16;
                     end if;
                  end if;
                  Register_Symbol (State, Curr, Iter_Name, Iter_Kind, Iter_Symbol);
                  Collect_Declarations (State, Tree (Curr).Right_Child, Procedure_Id);
               end;

            when AST_If_Stmt =>
               Collect_Declarations (State, Tree (Curr).Right_Child, Procedure_Id);
               if Tree (Curr).Right_Child /= 0 then
                  Collect_Declarations
                    (State,
                     Tree (Tree (Curr).Right_Child).Next_Sibling,
                     Procedure_Id);
               end if;

            when AST_Repeat_Stmt =>
               Collect_Declarations (State, Tree (Curr).Left_Child, Procedure_Id);

            when AST_Match_Stmt | AST_Select_Stmt =>
               declare
                  Case_Node : Node_Index := Tree (Curr).Right_Child;
               begin
                  while Case_Node /= 0 and then State.Success loop
                     Collect_Declarations (State, Tree (Case_Node).Right_Child, Procedure_Id);
                     Case_Node := Tree (Case_Node).Next_Sibling;
                  end loop;
               end;

            when AST_Block_Stmt =>
               Collect_Declarations (State, Curr, Procedure_Id);

            when AST_Temporal_Block | AST_Atomic_Block | AST_Reversible_Block =>
               Collect_Declarations (State, Tree (Curr).Left_Child, Procedure_Id);

            when AST_Try_Stmt =>
               Collect_Declarations (State, Tree (Curr).Left_Child, Procedure_Id);
               if Tree (Curr).Right_Child /= 0 then
                  Collect_Declarations (State, Tree (Curr).Right_Child, Procedure_Id);
               end if;

            when others =>
               null;
         end case;

         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Collect_Declarations;

   procedure Write_Buffer_To_File
     (State            : Emitter_State;
      Output_File_Name : String;
      Success          : out Boolean)
   is
      File : Ada.Text_IO.File_Type;
   begin
      Success := True;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Output_File_Name);
         if State.Length > 0 then
            Ada.Text_IO.Put (File, State.Buffer (1 .. State.Length));
         end if;
         Ada.Text_IO.Close (File);
      exception
         when others =>
            Success := False;
      end;
   end Write_Buffer_To_File;

   procedure Emit_Program
     (Root             : AST.Node_Index;
      Output_File_Name : String;
      Success          : out Boolean)
     with SPARK_Mode => Off
   is
      State : Emitter_State := (others => <>);
      First : Node_Index := Root;
   begin
      if Root = 0 then
         Ada.Text_IO.Put_Line ("ALB-65 C64 emitter error: parser produced an empty AST.");
         Success := False;
         return;
      end if;

      if Tree (Root).Kind = AST_Block_Stmt then
         First := Tree (Root).Left_Child;
      end if;

      Collect_Declarations (State, First);
      if not State.Success then
         Success := False;
         return;
      end if;

      Emit_Header (State);
      Emit_Zero_Page_Aliases (State);
      Append_Line (State, "alb_entry:");
      Emit_Node_Chain (State, First);
      if not State.Success then
         Success := False;
         return;
      end if;

      Append_Line (State, "    RTS");
      Emit_Procedure_Definitions (State, First);
      if not State.Success then
         Success := False;
         return;
      end if;
      Emit_Event_Definitions (State);
      if not State.Success then
         Success := False;
         return;
      end if;
      Emit_Runtime_Support (State);
      Emit_Data_Section (State);
      Write_Buffer_To_File (State, Output_File_Name, Success);
   end Emit_Program;

end Emit_Native_C64;
