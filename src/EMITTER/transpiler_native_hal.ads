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

with Numerus_Magnus; use Numerus_Magnus;
with ALB_Types;      use ALB_Types;
with Opcodes;        use Opcodes;

package Transpiler_Native_HAL is

   type Target_Profile is
     (Profile_Default,
      Profile_Tiny16,
      Profile_FlatJVM);

   type Target_Environment is record
      Register_Bits               : Positive := 64;
      Pointer_Bits                : Positive := 64;
      Address_Bits                : Positive := 64;
      Array_Index_Bits            : Positive := 32;
      Char_Bits                   : Positive := 8;
      Boolean_Bits                : Positive := 8;
      Pure_Lane_Bits              : Positive := 64;
      Pure_Lane_Count             : Positive := 2;
      Uses_Flat_Static_Arrays     : Boolean := False;
      Supports_Native_Pointers    : Boolean := True;
      Supports_Unsigned_Primitives: Boolean := True;
      Uses_Garbage_Collector      : Boolean := False;
   end record;

   type Target_Backend is
     (Backend_C,
      Backend_Ada,
      Backend_Java,
      Backend_WASM,
      Backend_FASM,
      Backend_Brainfuck,
      Backend_FASM16,
      Backend_Rust,
      Backend_Zig,
      Backend_PureBasic,
      Backend_AGK,
      Backend_GLBasic,
      Backend_Hollywood,
      Backend_CSharp,
      Backend_6502,
      Backend_Z80,
      Backend_8086,
      Backend_COBOL,
      Backend_StructuredText,
      Backend_Verilog,
      Backend_ComputeShaders,
      Backend_Forth,
      Backend_Factor,
      Backend_Raptor);

   Active_Target : Target_Backend := Backend_C;
   Active_Profile : Target_Profile := Profile_Default;
   Active_Environment : Target_Environment :=
     (Register_Bits                => 64,
      Pointer_Bits                 => 64,
      Address_Bits                 => 64,
      Array_Index_Bits             => 32,
      Char_Bits                    => 8,
      Boolean_Bits                 => 8,
      Pure_Lane_Bits               => 64,
      Pure_Lane_Count              => 2,
      Uses_Flat_Static_Arrays      => False,
      Supports_Native_Pointers     => True,
      Supports_Unsigned_Primitives => True,
      Uses_Garbage_Collector       => False);
   HAL_Ready     : Boolean := False;

   function Default_Profile_For
     (Target : Target_Backend) return Target_Profile;

   function Environment_For
     (Target  : Target_Backend;
      Profile : Target_Profile) return Target_Environment;

   procedure Configure_Target_Profile
     (Target  : Target_Backend;
      Profile : Target_Profile;
      Success : out Boolean);

   -- =========================================================================
   -- INITIALIZATION & LIFECYCLE
   -- =========================================================================
   procedure Init_HAL (Target : Target_Backend; Success : out Boolean)
   with
     Global  =>
       (Output => (Active_Target, Active_Profile, Active_Environment),
        In_Out => HAL_Ready),
     Depends =>
       (Active_Target => Target,
        Active_Profile => Target,
        Active_Environment => Target,
        HAL_Ready     => (Target, HAL_Ready),
        Success       => (Target, HAL_Ready)),
     Post    => (if Success then HAL_Ready = True);

   procedure Flush_To_File (File_Path : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, File_Path));
   
   procedure Emit_Program_Start (Program_Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Program_Name));
   
   procedure Emit_Program_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   -- =========================================================================
   -- RAW TEXT FORMATTING
   -- =========================================================================
   procedure Increase_Indent;
   procedure Decrease_Indent;
   
   procedure Set_Global_Buffer_Mode (Is_Global : Boolean);
   
   procedure Emit_Raw (Text : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Text));
   
   procedure Emit_Native_ASM_Block
     (Block_Text : String;
      Success    : out Boolean)
   with
     Pre     => HAL_Ready = True,
     Global  => (Input => Active_Target),
     Depends => (Success => (Active_Target, Block_Text));

   procedure Emit_Native_ASM_Expression
     (Block_Text : String;
      Success    : out Boolean)
   with
     Pre     => HAL_Ready = True,
     Global  => (Input => Active_Target),
       Depends => (Success => (Active_Target, Block_Text));

   procedure Emit_Native_C_Block
     (Block_Text : String;
      Success    : out Boolean)
   with
     Pre     => HAL_Ready = True,
     Global  => (Input => Active_Target),
     Depends => (Success => (Active_Target, Block_Text));

   procedure Emit_Native_C_Expression
     (Block_Text : String;
      Success    : out Boolean)
   with
     Pre     => HAL_Ready = True,
     Global  => (Input => Active_Target),
     Depends => (Success => (Active_Target, Block_Text));
   
   -- =========================================================================
   -- BIJECTIVE ENGINE / REVERSIBLE STATE FORGE
   -- =========================================================================
   procedure Emit_Reversible_Block_Start (Success : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => Active_Target);

   procedure Emit_Reversible_Block_End (Success : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => Active_Target);

   -- RHS value/count must already be in the backend's native result
   -- convention (RAX for FASM, DX:AX for FASM16).
   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Target_Name, Target_Tag));

   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Target_Name, Target_Tag));

   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Target_Name, Target_Tag));

   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Target_Name, Target_Tag));

   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Target_Name, Target_Tag));

   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Left_Name, Left_Tag, Right_Name, Right_Tag));

   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Target_Name, Target_Tag));

   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Target_Name, Target_Tag));


   
   procedure Emit_Newline (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Indent (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_FFI_Header_Include (Library_Name : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Library_Name));

   procedure Emit_FFI_Loader_Prelude (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   -- =========================================================================
   -- DA NATIVE INPUT FORGE
   -- =========================================================================
   procedure Emit_Input_Prompt_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Input_Prompt_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Tag));
   
   procedure Emit_Input_Read_End (Tag : ALB_Type_Tag; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Tag));
   
   
   procedure Emit_Require_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Ensure_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Contract_End (Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name));
   
   

   -- =========================================================================
   -- USER-DEFINED STRUCTS & TYPE MAPPING
   -- =========================================================================
   procedure Emit_Type_Definition (Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Tag));
   
   procedure Emit_Pure_Struct_Def (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Struct_Name));
   
   procedure Emit_Struct_Field
     (Field_Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Field_Name, Tag));
   
   procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Struct_Name));

   -- =========================================================================
   -- VARIABLE ALLOCATION & STATIC MEMORY VAULTS
   -- =========================================================================
   procedure Emit_Forward_Declaration
     (Func_Name   : String;
      Return_Tag : ALB_Type_Tag;
      Param_Count : Natural;
      Success    : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Func_Name, Return_Tag, Param_Count));
   
   procedure Emit_Var_Decl (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name, Tag));
   
   -- DA NEW STRUCT DECLARATION ROUTE
   procedure Emit_Struct_Var_Decl (Struct_Name : String; Var_Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Struct_Name, Var_Name));
   
   procedure Emit_Global_Var_Decl
     (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name, Tag));
   
   procedure Emit_Strict_Array_Decl (Name : String; Size_Bytes : Natural; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name, Size_Bytes));
   
   procedure Emit_Slide_Array_Decl (Name : String; Max_Bytes : Natural; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name, Max_Bytes));
   
   -- =========================================================================
   -- TEMPORAL STATE SYSTEM
   -- =========================================================================
   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Name, Tag, History_Depth));

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Name, Tag, History_Depth));

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Name, Tag));

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Name, Tag, History_Depth));

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   with Pre => HAL_Ready = True,
        Global => (Input => Active_Target),
        Depends => (Success => (Active_Target, Name));

   
   
   procedure Emit_Slide_Vault_Left (Vault_Name : String; Shift_Amount : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Vault_Name, Shift_Amount));
   
   procedure Emit_Slide_Vault_Right (Vault_Name : String; Shift_Amount : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Vault_Name, Shift_Amount));
   
   procedure Emit_Let_Assign_Start (Type_Hint : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Type_Hint));
   
   procedure Emit_Variable_Ref (Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name));
   
   procedure Emit_Array_Index_Open (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Array_Index_Close (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   -- =========================================================================
   -- BOUNDED STRING MANIPULATION
   -- =========================================================================
   procedure Emit_String_Concat (Dest, Src, Max_Len : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Dest, Src, Max_Len));
   
   procedure Emit_String_Copy (Dest, Src, Max_Len : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Dest, Src, Max_Len));
   
   procedure Emit_String_Length (Src : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Src));

   -- =========================================================================
   -- OPERATORS, LITERALS & ADVANCED MATH
   -- =========================================================================
   procedure Emit_AddressOf (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Boolean_Cast_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Literal_U64 (Value : U64; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Value));
   
   procedure Emit_String_Literal (Text : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Text));
   
   procedure Emit_Expression_Open (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Expression_Close (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_BinOp (Op : ALB_Opcode; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Op));
   
   procedure Emit_Square_Root (Value : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Value));
   
   procedure Emit_Sine (Value : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Value));
   
   procedure Emit_Cosine (Value : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Value));
   
   procedure Emit_Absolute (Value : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Value));

   -- =========================================================================
   -- DA BRANCHLESS LOGIC VAULT
   -- =========================================================================
   procedure Emit_Branchless_Condition_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Branchless_Mask_Op (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_If_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Then (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Else (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_If_End (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   -- =========================================================================
   -- DA NEW COMPILE-TIME ORACLES & GUARDS
   -- =========================================================================
   procedure Emit_SizeOf_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_OffsetOf_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Runtime_Assert_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Runtime_Assert_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Readline_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Readline_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Cut_Operator (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Loop_Step_Mid (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Loop_Step_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   -- =========================================================================
   -- FIXED-BOUND LOOPS
   -- =========================================================================
   procedure Emit_While_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_While_Loop_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Plain_Loop_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Exit_When (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Iterator_Name));
   
   procedure Emit_Foreach_Start (Iterator_Name : String; Array_Name : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Iterator_Name, Array_Name));
   
   procedure Emit_DotDot (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Loop_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Loop_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Case_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Is (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_When (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Arrow (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_When_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Case_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   -- =========================================================================
   -- PROCEDURES
   -- =========================================================================
   procedure Emit_Procedure_Decl_Start (Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name));
   
   procedure Emit_Function_Decl_Start (Func_Name : String; Return_Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Func_Name, Return_Tag));
   
   procedure Emit_Procedure_End (Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Name));
   
   procedure Emit_Return_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Call_Start (Func_Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Func_Name));
   
   procedure Emit_Call_End (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Comma (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Statement_End (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Assign_Prefix (Success : out Boolean);
   procedure Emit_Print_Start (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean);
   procedure Emit_Print_End (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean);
   
   procedure Emit_File_Open_Start (Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_File_Open_Mid (Success : out Boolean) with Pre => HAL_Ready = True;
   
   procedure Emit_File_Read_Start (Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_File_Read_Mid (Success : out Boolean) with Pre => HAL_Ready = True;
   
   procedure Emit_File_Write_Start (Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_File_Write_Mid (Success : out Boolean) with Pre => HAL_Ready = True;
   
   procedure Emit_File_Close_Start (Success : out Boolean) with Pre => HAL_Ready = True;

   procedure Emit_File_Len_Start (Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_File_Seek_Start (Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_File_Seek_Mid (Success : out Boolean) with Pre => HAL_Ready = True;
   
   procedure Emit_Try_Start (Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_Try_End (Success : out Boolean) with Pre => HAL_Ready = True;
   
   procedure Emit_Throw_Start (Success : out Boolean) with Pre => HAL_Ready = True;
   procedure Emit_Throw_End (Success : out Boolean) with Pre => HAL_Ready = True;

   -- =========================================================================
   -- OS FILE VAULTS & KNOWLEDGE
   -- =========================================================================
   procedure Emit_OS_Load
     (File_Path : String; Target_Buffer : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, File_Path, Target_Buffer));

   -- =========================================================================
   -- DA BARE-METAL MEMORY FORGE
   -- =========================================================================
   procedure Emit_Poke_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   procedure Emit_Poke_Mid (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   procedure Emit_Peek_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);

   procedure Emit_Deref_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   
   procedure Emit_OS_Flush
     (Source_Buffer : String; File_Path : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Source_Buffer, File_Path));

   procedure Emit_Prolog_Fact_Registration
     (Pred : String; Arg : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Pred, Arg));
   
   procedure Emit_Assert_Call (Pred, Arg : String; Success : out Boolean) with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Pred, Arg));
   procedure Emit_Retract_Call (Pred, Arg : String; Success : out Boolean) with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Pred, Arg));

   procedure Emit_Prolog_Query_Call
     (Pred : String; Arg : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Pred, Arg));

   
   procedure Emit_Update_Call (Pred, Old_Arg, New_Arg : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Pred, Old_Arg, New_Arg));

   procedure Emit_FindAll_Call (Pred, Out_Array : String; Success : out Boolean) 
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Pred, Out_Array));
   
   -- =========================================================================
   -- DA NATIVE FORGE: INPUT, GRAPHICS & AUDIO BINDINGS
   -- =========================================================================
   procedure Emit_Key_State (Key_Code : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Key_Code));
   
   procedure Emit_Mouse_Position (X_Var, Y_Var : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, X_Var, Y_Var));
   
   procedure Emit_Mouse_Click (Button : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Button));
   
   procedure Emit_Put_Pixel (X, Y, Color : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, X, Y, Color));
   
   procedure Emit_Draw_Line
     (X1, Y1, X2, Y2, Color : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, X1, Y1, X2, Y2, Color));
   
   procedure Emit_Draw_Rect (X, Y, W, H, Color : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, X, Y, W, H, Color));
   
   procedure Emit_Fill_Rect (X, Y, W, H, Color : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, X, Y, W, H, Color));
   
   procedure Emit_Blit_Image
     (Source_Vault, X, Y : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Source_Vault, X, Y));
   
   procedure Emit_Load_Sound
     (File_Path, Target_Vault : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, File_Path, Target_Vault));
   
   procedure Emit_Play_Sound (Vault_Name : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Vault_Name));
   
   procedure Emit_Print_Function_Start (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Window_Creation (Title : String; Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Set_Fullscreen (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Set_Resizable (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Set_Stretchy (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Message_Loop (Success : out Boolean)
   with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Color_Hex));
   
   procedure Emit_Clear_Color (Color : String; Success : out Boolean) with Pre => HAL_Ready = True;
   
   -- DA NEW MULTI-CORE DISPATCH FORGE
   procedure Emit_Spawn_Start (Func_Name : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => (Active_Target, Func_Name));
   procedure Emit_Spawn_End (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Sync (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Atomic_Start (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Atomic_End (Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   
   procedure Emit_Claim (Var_Name : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Drop (Var_Name : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Sweep (Chunk_Expr : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
   procedure Emit_Bind (Parent_Var : String; Child1_Expr : String; Child2_Expr : String; Success : out Boolean)
     with Pre => HAL_Ready = True, Global => (Input => Active_Target), Depends => (Success => Active_Target);
     
end Transpiler_Native_HAL;
