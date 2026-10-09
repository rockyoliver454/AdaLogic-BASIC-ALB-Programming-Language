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

with ALB_Types;       use ALB_Types;
with Numerus_Magnus;  use Numerus_Magnus;
with Opcodes;         use Opcodes;

-- =====================================================================
-- Emit_Native_FASM16
-- ---------------------------------------------------------------------
-- 16-bit x86 FASM emitter seed.
--   * 8086/use16 assembly
--   * U16-native mindset
-- =====================================================================

package Emit_Native_FASM16 is

   type Buffer_Target is
     (Buffer_Global,
      Buffer_Main);

   type FASM16_Output_Format is
     (Format_COM,
      Format_MZ_EXE,
      Format_Boot);

   type FASM16_Profile is
     (Profile_Tiny16);

   FASM16_Emitter_Ready : Boolean := False;
   Indent_Level         : Natural := 0;
   In_Global_Scope      : Boolean := True;

   Current_Buffer  : Buffer_Target := Buffer_Global;
   Current_Format  : FASM16_Output_Format := Format_COM;
   Current_Profile : FASM16_Profile := Profile_Tiny16;

   procedure Init_Emitter
     (Success : out Boolean);

   procedure Flush_To_File
     (File_Path : String;
      Success   : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Set_Active_Buffer
     (Target : Buffer_Target);

   procedure Set_Output_Format
     (Format : FASM16_Output_Format);

   procedure Emit_Program_Start
     (Program_Name : String;
      Success      : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Program_End
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Raw
     (Text    : String;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Native_ASM_Block
     (Block_Text : String;
      Success    : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Native_ASM_Expression
     (Block_Text : String;
      Success    : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Reversible_Block_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Reversible_Block_End
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Newline
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Indent
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Increase_Indent;

   procedure Decrease_Indent;

   procedure Emit_Profile_Banner
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Unsupported
     (Feature_Name : String;
      Success      : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Literal_U64
     (Value   : U64;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Var_Decl
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Global_Var_Decl
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Print_Start
     (Tag     : ALB_Type_Tag;
      Piped   : Boolean;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Print_End
     (Tag     : ALB_Type_Tag;
      Piped   : Boolean;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;
   
      procedure Emit_String_Literal
     (Text    : String;
      Success : out Boolean)
     with Pre => FASM16_Emitter_Ready = True;
   
   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Foreach_Start (Iterator_Name : String; Array_Name : String; Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_DotDot (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Loop_Step_Mid (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Loop_Step_End (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Loop_Start (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Loop_End (Success : out Boolean)
     with Pre => FASM16_Emitter_Ready = True;
   
   -- FUNCTIONS/PROCEDURES
   procedure Emit_Forward_Declaration
     (Func_Name : String;
      Success   : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Procedure_Decl_Start
     (Name    : String;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Function_Decl_Start
     (Func_Name  : String;
      Return_Tag : ALB_Type_Tag;
      Success    : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Procedure_End
     (Name    : String;
      Success : out Boolean)
     with Pre => FASM16_Emitter_Ready = True;
   
   procedure Emit_Statement_End
     (Success : out Boolean)
     with Pre => FASM16_Emitter_Ready = True;
   
   -- Dumptruck / GC runtime is emitted internally by Emit_Program_Start
   -- and Emit_Program_End, mirroring the full FASM backend style.
   
   
   procedure Emit_Type_Definition
     (Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Pure_Struct_Def
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Struct_Start
     (Struct_Name : String;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Struct_Field
     (Field_Name : String;
      Tag        : ALB_Type_Tag;
      Success    : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Struct_End
     (Struct_Name : String;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Struct_Var_Decl
     (Struct_Name : String;
      Var_Name    : String;
      Success     : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Let_Assign_Start
     (Type_Hint : String;
      Success   : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Variable_Ref
     (Name    : String;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Array_Index_Open
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Array_Index_Close
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_AddressOf
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Boolean_Cast_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Expression_Open
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Expression_Close
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_BinOp
     (Op      : ALB_Opcode;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_If_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Then
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Else
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_If_End
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_While_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_While_Loop_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Plain_Loop_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Exit_When
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Case_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Is
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_When
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Arrow
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_When_End
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Case_End
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Try_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Catch_Start
     (Err_Var : String;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Try_End
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Throw_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Throw_End
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Return_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Comma
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Window_Creation
     (Title   : String;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Message_Loop
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Require_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Ensure_Start
     (Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

   procedure Emit_Contract_End
     (Name    : String;
      Success : out Boolean)
   with Pre => FASM16_Emitter_Ready = True;

end Emit_Native_FASM16;
