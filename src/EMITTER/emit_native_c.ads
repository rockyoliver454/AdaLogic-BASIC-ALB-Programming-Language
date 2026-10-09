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

package Emit_Native_C is

   type Buffer_Target is (Buffer_Global, Buffer_Main);

   C_Emitter_Ready : Boolean := False;
   Indent_Level    : Natural := 0;
   In_Global_Scope : Boolean := True;
   Current_Buffer  : Buffer_Target := Buffer_Global;

   procedure Init_Emitter (Success : out Boolean)
     with Global  => (In_Out => C_Emitter_Ready),
          Depends => (C_Emitter_Ready => C_Emitter_Ready, Success => C_Emitter_Ready),
          Post    => (if Success then C_Emitter_Ready = True);

   procedure Flush_To_File (File_Path : String; Success : out Boolean)
     with Pre => C_Emitter_Ready = True;
   procedure Set_Active_Buffer (Target : Buffer_Target)
     with Global => (In_Out => Current_Buffer);

   procedure Emit_Program_Start (Program_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Program_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Raw (Text : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Native_C_Block
     (Block_Text : String;
      Success    : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Native_C_Expression
     (Block_Text : String;
      Success    : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Newline (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Indent (Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Increase_Indent with Global => (In_Out => Indent_Level);
   procedure Decrease_Indent with Pre => Indent_Level > 0, Global => (In_Out => Indent_Level);
   
   -- =========================================================================
   -- DA NATIVE INPUT FORGE
   -- =========================================================================
   procedure Emit_Input_Prompt_Start (Success : out Boolean)
     with Pre => C_Emitter_Ready = True;

   procedure Emit_Input_Prompt_End (Success : out Boolean)
     with Pre => C_Emitter_Ready = True;

   procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean)
     with Pre => C_Emitter_Ready = True;

   procedure Emit_Input_Read_End (Tag : ALB_Type_Tag; Success : out Boolean)
     with Pre => C_Emitter_Ready = True;
     
   procedure Emit_Type_Definition (Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Pure_Struct_Def (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   -- Buffer Routing removed from preconditions (handled internally)
   procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Struct_Field (Field_Name : String; Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Forward_Declaration
     (Func_Name   : String;
      Return_Tag : ALB_Type_Tag;
      Param_Count : Natural;
      Success    : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Var_Decl (Name : String; Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Global_Var_Decl (Name : String; Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Struct_Var_Decl (Struct_Name : String; Var_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Strict_Array_Decl (Name : String; Size_Bytes : Natural; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Slide_Array_Decl (Name : String; Max_Bytes : Natural; Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Slide_Vault_Left (Vault_Name : String; Shift_Amount : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Slide_Vault_Right (Vault_Name : String; Shift_Amount : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Let_Assign_Start (Type_Hint : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Variable_Ref (Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Array_Index_Open (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Array_Index_Close (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_String_Concat (Dest, Src, Max_Len : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_String_Copy (Dest, Src, Max_Len : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_String_Length (Src : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_AddressOf (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Boolean_Cast_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Literal_U64 (Value : U64; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Float_Literal (Text : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_String_Literal (Text : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Expression_Open (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Expression_Close (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_BinOp (Op : ALB_Opcode; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Square_Root (Value : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Sine (Value : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Cosine (Value : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Absolute (Value : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Branchless_Condition_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Branchless_Mask_Op (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_If_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Then (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Else (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_If_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Require_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Ensure_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Contract_End (Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_FFI_Header_Include (Library_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_FFI_Loader_Prelude (Success : out Boolean) with Pre => C_Emitter_Ready = True;

   
   -- =========================================================================
   -- DA NEW COMPILE-TIME ORACLES & GUARDS
   -- =========================================================================
   procedure Emit_SizeOf_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_OffsetOf_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Runtime_Assert_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Runtime_Assert_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   -- DA NEW TEXT & LOGIC SEVERS
   procedure Emit_Readline_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Readline_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Cut_Operator (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   -- DA NEW MULTI-CORE DISPATCH FORGE
   procedure Emit_Spawn_Start (Func_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Spawn_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Sync (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Atomic_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Atomic_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Reversible_Block_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Reversible_Block_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Add (Target_Name : String; Target_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Sub (Target_Name : String; Target_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Xor (Target_Name : String; Target_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Rol (Target_Name : String; Target_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Ror (Target_Name : String; Target_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Not (Target_Name : String; Target_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Rev_Neg (Target_Name : String; Target_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Claim (Var_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Drop (Var_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Sweep (Chunk_Expr : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Bind (Parent_Var : String; Child1_Expr : String; Child2_Expr : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   -- DA NEW STEP LOOP HOOKS
   procedure Emit_Loop_Step_Mid (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Loop_Step_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_While_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_While_Loop_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Plain_Loop_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Exit_When (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_DotDot (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Loop_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Foreach_Start (Iterator_Name : String; Array_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Loop_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Case_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Is (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_When (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Arrow (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_When_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Case_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;

   -- Buffer Routing removed from preconditions (handled internally)
   procedure Emit_Procedure_Decl_Start (Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Function_Decl_Start (Name : String; Return_Tag : ALB_Type_Tag; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Procedure_End (Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Return_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   --procedure Emit_Native_Call_Start (Func_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Call_Start (Func_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Call_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Comma (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Statement_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Assign_Prefix (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Print_Start (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean);
   procedure Emit_Print_End (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean);

   procedure Emit_File_Open_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Open_Mid (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Read_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Read_Mid (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Write_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Write_Mid (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Close_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Len_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Seek_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_File_Seek_Mid (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Try_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Try_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Throw_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Throw_End (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_OS_Load (File_Path : String; Target_Buffer : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   -- DA BARE-METAL MEMORY FORGE
   procedure Emit_Poke_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Poke_Mid (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Peek_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Deref_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_OS_Flush (Source_Buffer : String; File_Path : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Prolog_Fact_Registration (Pred : String; Arg : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Prolog_Query_Call (Pred : String; Arg : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;

   procedure Emit_Key_State (Key_Code : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Mouse_Position (X_Var, Y_Var : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Mouse_Click (Button : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Put_Pixel (X, Y, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Draw_Line (X1, Y1, X2, Y2, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Draw_Rect (X, Y, W, H, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Draw_Circle (X, Y, R, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Draw_Triangle (X1, Y1, X2, Y2, X3, Y3, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Fill_Circle (X, Y, R, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Fill_Triangle (X1, Y1, X2, Y2, X3, Y3, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Fill_Rect (X, Y, W, H, Color : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Blit_Image (Source_Vault, X, Y : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Load_Sound (File_Path, Target_Vault : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Play_Sound (Vault_Name : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;
   
   procedure Emit_Print_Function_Start (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Window_Creation
     (Title   : String;
      Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Set_Fullscreen (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Set_Resizable (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Set_Stretchy (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Message_Loop (Success : out Boolean) with Pre => C_Emitter_Ready = True;
   procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean) with Pre => C_Emitter_Ready = True;

   
   procedure Emit_Clear_Color (Color : String; Success : out Boolean);
   
end Emit_Native_C;
