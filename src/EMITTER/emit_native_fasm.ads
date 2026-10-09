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

with ALB_Types; use ALB_Types;
with Opcodes;   use Opcodes;
with Numerus_Magnus; use Numerus_Magnus;

package Emit_Native_FASM is

   type Buffer_Target is (Buffer_Global, Buffer_Main);

   type FASM_Output_Format is
     (Format_PE64_Console,
      Format_PE64_GUI,
      Format_PE64_DLL);

   FASM_Emitter_Ready : Boolean := False;
   Indent_Level       : Natural := 0;
   In_Global_Scope    : Boolean := True;
   Current_Buffer     : Buffer_Target := Buffer_Global;
   Current_Format     : FASM_Output_Format := Format_PE64_Console;
   -- --embed-blackbox: VEH + heap-free crash dump path
   FASM_Blackbox_Requested : Boolean := False;

   procedure Init_Emitter (Success : out Boolean)
   with
     Global  => (In_Out => FASM_Emitter_Ready),
     Depends =>
       (FASM_Emitter_Ready => FASM_Emitter_Ready,
        Success            => FASM_Emitter_Ready),
     Post    => (if Success then FASM_Emitter_Ready = True);

   procedure Flush_To_File (File_Path : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Set_Active_Buffer (Target : Buffer_Target)
   with Global => (In_Out => Current_Buffer);

   procedure Set_Output_Format
     (Format : FASM_Output_Format)
   with Global => (In_Out => Current_Format);

   procedure Set_Blackbox_Mode (Enabled : Boolean)
   with Global => (In_Out => FASM_Blackbox_Requested);

   procedure Emit_Program_Start (Program_Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Program_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Raw (Text : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   
   procedure Emit_Native_ASM_Block
     (Block_Text : String;
      Success    : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Native_ASM_Expression
     (Block_Text : String;
      Success    : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   
   
   -- =========================================================================
   -- BIJECTIVE ENGINE / REVERSIBLE STATE FORGE
   -- =========================================================================
   procedure Emit_Reversible_Block_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Reversible_Block_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   with Pre => FASM_Emitter_Ready = True;


   
   procedure Emit_Newline (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Indent (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Increase_Indent
   with Global => (In_Out => Indent_Level);
   procedure Decrease_Indent
   with Pre => Indent_Level > 0, Global => (In_Out => Indent_Level);

   procedure Emit_Type_Definition (Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Pure_Struct_Def (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Struct_Field
     (Field_Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Forward_Declaration
     (Func_Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Var_Decl
     (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Strict_Array_Decl
     (Name : String; Size_Bytes : Natural; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Slide_Array_Decl
     (Name : String; Max_Bytes : Natural; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   
   -- =========================================================================
   -- TEMPORAL STATE SYSTEM
   -- =========================================================================
   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   
   procedure Emit_Struct_Var_Decl
     (Struct_Name : String; Var_Name : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Function_Decl_Start
     (Name : String; Return_Tag : ALB_Type_Tag; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   

   procedure Emit_Let_Assign_Start (Type_Hint : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Variable_Ref (Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Array_Index_Open (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Array_Index_Close (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_AddressOf (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Boolean_Cast_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Literal_U64 (Value : U64; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_String_Literal (Text : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Expression_Open (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Expression_Close (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_BinOp (Op : ALB_Opcode; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Branchless_Condition_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Branchless_Mask_Op (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_If_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Then (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Else (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True; -- DA NEW ROUTE!
   procedure Emit_If_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_While_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_While_Loop_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Plain_Loop_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Exit_When (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_DotDot (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Loop_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Loop_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Case_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Is (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_When (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Arrow (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_When_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Case_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Procedure_Decl_Start (Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Procedure_End (Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Return_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Call_Start (Func_Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Call_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Comma (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Statement_End (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   
   procedure Emit_Assign_Prefix (Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Print_Start (Tag : ALB_Type_Tag; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Print_End (Tag : ALB_Type_Tag; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Assert_Call (Pred, Arg : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Retract_Call (Pred, Arg : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_OS_Load
     (File_Path : String; Target_Buffer : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_OS_Flush
     (Source_Buffer : String; File_Path : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Prolog_Fact_Registration
     (Pred : String; Arg : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Prolog_Query_Call
     (Pred : String; Arg : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   
   procedure Emit_FindAll_Call
     (Pred : String; Out_Array : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   
   procedure Emit_Update_Call
     (Pred, Old_Arg, New_Arg : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;
   
   procedure Emit_Foreach_Start
     (Iterator_Name : String; Array_Name : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Try_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Try_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Throw_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Throw_End (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;

   
   procedure Emit_Global_Var_Decl (Name : String; Tag : ALB_Type_Tag; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Slide_Vault_Left (Vault_Name : String; Shift_Amount : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Slide_Vault_Right (Vault_Name : String; Shift_Amount : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_String_Concat (Dest, Src, Max_Len : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_String_Copy (Dest, Src, Max_Len : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_String_Length (Src : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Square_Root (Value : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Sine (Value : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Cosine (Value : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Absolute (Value : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Key_State (Key_Code : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Mouse_Position (X_Var, Y_Var : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Mouse_Click (Button : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Put_Pixel (X, Y, Color : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Play_Sound (Vault_Name : String; Success : out Boolean) with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Print_Function_Start (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Window_Creation
     (Title : String; Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Set_Fullscreen (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Set_Resizable (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Set_Stretchy (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
   procedure Emit_Message_Loop (Success : out Boolean)
   with Pre => FASM_Emitter_Ready = True;
    procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean)
      with Pre => FASM_Emitter_Ready = True;

    procedure Emit_FITS_Runtime (Success : out Boolean)
      with Pre => FASM_Emitter_Ready = True;

    -- Task A5a: dedicated INI parser/buffer emitter. Buffer lands in the
    -- data section (Buffer_Global) instead of the .text section so the
    -- 64 KiB scratch no longer inflates the executable.
    procedure Emit_INI_Runtime (Success : out Boolean)
      with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Input_Prompt_Start (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Input_Prompt_End (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Input_Read_End (Tag : ALB_Type_Tag; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Readline_Start (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Readline_End (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Require_Start (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Ensure_Start (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Contract_End (Name : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Runtime_Assert_Start (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Runtime_Assert_End (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   -- SPAWN is synchronous on FASM (same-core call). SYNC/ATOMIC are mfence.
   procedure Emit_Spawn_Start (Func_Name : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Spawn_End (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Sync (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Atomic_Start (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Atomic_End (Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Claim (Var_Name : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Drop (Var_Name : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Sweep (Chunk_Expr : String; Success : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

   procedure Emit_Bind
     (Parent_Var  : String;
      Child1_Expr : String;
      Child2_Expr : String;
      Success     : out Boolean)
     with Pre => FASM_Emitter_Ready = True;

end Emit_Native_FASM;
