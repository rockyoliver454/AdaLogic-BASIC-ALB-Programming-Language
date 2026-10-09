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

package Emit_Native_Java is

   type Buffer_Target is
     (Buffer_Global,
      Buffer_Boot,
      Buffer_Key,
      Buffer_Tick,
      Buffer_Paint,
      Buffer_Main);

   type Java_Profile is
     (Profile_FlatJVM);

   Java_Emitter_Ready : Boolean := False;
   Indent_Level       : Natural := 1;
   Current_Buffer     : Buffer_Target := Buffer_Global;
   Current_Profile    : Java_Profile := Profile_FlatJVM;

   procedure Init_Emitter
     (Success : out Boolean);

   procedure Flush_To_File
     (File_Path : String;
      Success   : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Set_Active_Buffer
     (Target : Buffer_Target);

   procedure Emit_Program_Start
     (Program_Name : String;
      Success      : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Program_End
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Raw
     (Text    : String;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Newline
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Indent
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Increase_Indent
   ;

   procedure Decrease_Indent
   with Pre => Indent_Level > 0;

   procedure Emit_Unsupported
     (Feature_Name : String;
      Success      : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Var_Decl
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Global_Var_Decl
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Strict_Array_Decl
     (Name       : String;
      Size_Bytes : Natural;
      Success    : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Slide_Array_Decl
     (Name      : String;
      Max_Bytes : Natural;
      Success   : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Let_Assign_Start
     (Type_Hint : String;
      Success   : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Variable_Ref
     (Name    : String;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Literal_U64
     (Value   : U64;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_String_Literal
     (Text    : String;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Expression_Open
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Expression_Close
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_BinOp
     (Op      : ALB_Opcode;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Procedure_Decl_Start
     (Name    : String;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Function_Decl_Start
     (Func_Name  : String;
      Return_Tag : ALB_Type_Tag;
      Success    : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Procedure_End
     (Name    : String;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Return_Start
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Call_Start
     (Func_Name : String;
      Success   : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Call_End
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Comma
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Statement_End
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Assign_Prefix
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Print_Start
     (Tag     : ALB_Type_Tag;
      Piped   : Boolean;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Print_End
     (Tag     : ALB_Type_Tag;
      Piped   : Boolean;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Window_Creation
     (Title   : String;
      Width   : Natural;
      Height  : Natural;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Message_Loop
     (Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

   procedure Emit_Clear_Color
     (Color   : String;
      Success : out Boolean)
   with Pre => Java_Emitter_Ready = True;

end Emit_Native_Java;
