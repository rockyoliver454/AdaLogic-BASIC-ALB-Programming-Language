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

with Emit_Native_C;
with Emit_Native_FASM;
with Emit_Native_FASM16;
with Emit_Native_Java;
with Emit_Native_Brainfuck;

package body Transpiler_Native_HAL is

   function Default_Profile_For
     (Target : Target_Backend) return Target_Profile is
   begin
      case Target is
         when Backend_FASM16 | Backend_8086 =>
            return Profile_Tiny16;

         when Backend_Java =>
            return Profile_FlatJVM;

         when others =>
            return Profile_Default;
      end case;
   end Default_Profile_For;

   function Environment_For
     (Target  : Target_Backend;
      Profile : Target_Profile) return Target_Environment is
      pragma Unreferenced (Target);
   begin
      case Profile is
         when Profile_Tiny16 =>
            return
              (Register_Bits                => 16,
               Pointer_Bits                 => 16,
               Address_Bits                 => 20,
               Array_Index_Bits             => 16,
               Char_Bits                    => 8,
               Boolean_Bits                 => 8,
               Pure_Lane_Bits               => 64,
               Pure_Lane_Count              => 2,
               Uses_Flat_Static_Arrays      => False,
               Supports_Native_Pointers     => True,
               Supports_Unsigned_Primitives => True,
               Uses_Garbage_Collector       => False);

         when Profile_FlatJVM =>
            return
              (Register_Bits                => 64,
               Pointer_Bits                 => 64,
               Address_Bits                 => 64,
               Array_Index_Bits             => 32,
               Char_Bits                    => 16,
               Boolean_Bits                 => 8,
               Pure_Lane_Bits               => 64,
               Pure_Lane_Count              => 2,
               Uses_Flat_Static_Arrays      => True,
               Supports_Native_Pointers     => False,
               Supports_Unsigned_Primitives => False,
               Uses_Garbage_Collector       => False);

         when others =>
            return
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
      end case;
   end Environment_For;

   procedure Configure_Target_Profile
     (Target  : Target_Backend;
      Profile : Target_Profile;
      Success : out Boolean) is
   begin
      Active_Target := Target;
      Active_Profile := Profile;
      Active_Environment := Environment_For (Target, Profile);
      Success := True;
   end Configure_Target_Profile;

   procedure Init_HAL (Target : Target_Backend; Success : out Boolean) is
      Profile_Success : Boolean := True;
   begin
      HAL_Ready := False;
      Configure_Target_Profile
        (Target,
         Default_Profile_For (Target),
         Profile_Success);

      if not Profile_Success then
         Success := False;
         return;
      end if;

      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Init_Emitter (Success);
            
         when Backend_FASM =>
            Emit_Native_FASM.Init_Emitter (Success);
            
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Init_Emitter (Success);
            
         when Backend_FASM16 =>
            Emit_Native_FASM16.Init_Emitter (Success);

         when Backend_Java =>
            Emit_Native_Java.Init_Emitter (Success);

         when others =>
            Success := False;
      end case;

      pragma Assert (Success = True or Success = False);
      if Success then
         HAL_Ready := True;
      end if;
   end Init_HAL;

   procedure Flush_To_File (File_Path : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Flush_To_File (File_Path, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Flush_To_File (File_Path, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Flush_To_File (File_Path, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Flush_To_File (File_Path, Success);
         when Backend_Java =>
            Emit_Native_Java.Flush_To_File (File_Path, Success);

         when others =>
            Success := False;
      end case;
   end Flush_To_File;

   procedure Emit_Program_Start (Program_Name : String; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Program_Start (Program_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Program_Start (Program_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Program_Start (Program_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Program_Start (Program_Name, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Program_Start (Program_Name, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Program_Start;

   procedure Emit_Program_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Program_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Program_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Program_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Program_End (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Program_End (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Program_End;

   procedure Emit_Raw (Text : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Raw (Text, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Raw (Text, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Raw (Text, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Raw (Text, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Raw (Text, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Raw;
   
   procedure Emit_Native_ASM_Block
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Native_ASM_Block (Block_Text, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Native_ASM_Block (Block_Text, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Native_ASM_Block (Block_Text, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Native_ASM_Block;


   procedure Emit_Native_ASM_Expression
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Native_ASM_Expression (Block_Text, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Native_ASM_Expression (Block_Text, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Native_ASM_Expression (Block_Text, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Native_ASM_Expression;

   procedure Emit_Native_C_Block
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Native_C_Block (Block_Text, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Native_C_Block;

   procedure Emit_Native_C_Expression
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Native_C_Expression (Block_Text, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Native_C_Expression;
   
   -- =========================================================================
   -- BIJECTIVE ENGINE / REVERSIBLE STATE FORGE
   -- =========================================================================
   procedure Emit_Reversible_Block_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Reversible_Block_Start (Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Reversible_Block_Start (Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Reversible_Block_Start (Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Reversible_Block_Start (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Reversible_Block_Start;


   procedure Emit_Reversible_Block_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Reversible_Block_End (Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Reversible_Block_End (Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Reversible_Block_End (Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Reversible_Block_End (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Reversible_Block_End;


   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Add (Target_Name, Target_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Add (Target_Name, Target_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Add (Target_Name, Target_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Add (Target_Name, Target_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Add;


   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Sub (Target_Name, Target_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Sub (Target_Name, Target_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Sub (Target_Name, Target_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Sub (Target_Name, Target_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Sub;


   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Xor (Target_Name, Target_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Xor (Target_Name, Target_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Xor (Target_Name, Target_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Xor (Target_Name, Target_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Xor;


   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Rol (Target_Name, Target_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Rol (Target_Name, Target_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Rol (Target_Name, Target_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Rol (Target_Name, Target_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Rol;


   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Ror (Target_Name, Target_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Ror (Target_Name, Target_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Ror (Target_Name, Target_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Ror (Target_Name, Target_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Ror;


   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Swap
              (Left_Name, Left_Tag, Right_Name, Right_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Swap
              (Left_Name, Left_Tag, Right_Name, Right_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Swap
              (Left_Name, Left_Tag, Right_Name, Right_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Swap
              (Left_Name, Left_Tag, Right_Name, Right_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Swap;


   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Not (Target_Name, Target_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Not (Target_Name, Target_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Not (Target_Name, Target_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Not (Target_Name, Target_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Not;


   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Rev_Neg (Target_Name, Target_Tag, Success);

         when Backend_FASM =>
            Emit_Native_FASM.Emit_Rev_Neg (Target_Name, Target_Tag, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Rev_Neg (Target_Name, Target_Tag, Success);

         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Rev_Neg (Target_Name, Target_Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Rev_Neg;


   
   procedure Increase_Indent is
   begin
      case Active_Target is
         when Backend_C    => Emit_Native_C.Increase_Indent;
         when Backend_FASM => Emit_Native_FASM.Increase_Indent;
         when Backend_Brainfuck => Emit_Native_Brainfuck.Increase_Indent;
         when Backend_FASM16 => Emit_Native_FASM16.Increase_Indent;
         when Backend_Java => Emit_Native_Java.Increase_Indent;
         when others       => null;
      end case;
   end Increase_Indent;

   procedure Decrease_Indent is
   begin
      case Active_Target is
         when Backend_C    => Emit_Native_C.Decrease_Indent;
         when Backend_FASM => Emit_Native_FASM.Decrease_Indent;
         when Backend_Brainfuck => Emit_Native_Brainfuck.Decrease_Indent;
         when Backend_FASM16 => Emit_Native_FASM16.Decrease_Indent;
         when Backend_Java => Emit_Native_Java.Decrease_Indent;
         when others       => null;
      end case;
   end Decrease_Indent;
   
   procedure Emit_FFI_Header_Include (Library_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_FFI_Header_Include (Library_Name, Success);
         when others =>
            Success := False;
      end case;
   end Emit_FFI_Header_Include;

   procedure Emit_FFI_Loader_Prelude (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_FFI_Loader_Prelude (Success);
         when others =>
            Success := False;
      end case;
   end Emit_FFI_Loader_Prelude;

   
   --  procedure Set_Global_Buffer_Mode (Is_Global : Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C =>
   --           if Is_Global then
   --              Emit_Native_C.Set_Active_Buffer (Emit_Native_C.Buffer_Global);
   --           else
   --              Emit_Native_C.Set_Active_Buffer (Emit_Native_C.Buffer_Main);
   --           end if;
   --        when others =>
   --           null;
   --     end case;
   --  end Set_Global_Buffer_Mode;
   
   procedure Set_Global_Buffer_Mode (Is_Global : Boolean) is
begin
   case Active_Target is
      when Backend_C =>
         if Is_Global then
            Emit_Native_C.Set_Active_Buffer (Emit_Native_C.Buffer_Global);
         else
            Emit_Native_C.Set_Active_Buffer (Emit_Native_C.Buffer_Main);
         end if;

      when Backend_FASM =>
         if Is_Global then
            Emit_Native_FASM.Set_Active_Buffer (Emit_Native_FASM.Buffer_Global);
         else
            Emit_Native_FASM.Set_Active_Buffer (Emit_Native_FASM.Buffer_Main);
         end if;
         
      when Backend_Brainfuck =>
         if Is_Global then
            Emit_Native_Brainfuck.Set_Active_Buffer (Emit_Native_Brainfuck.Buffer_Global);
         else
            Emit_Native_Brainfuck.Set_Active_Buffer (Emit_Native_Brainfuck.Buffer_Main);
         end if;
         
      when Backend_FASM16 =>
            if Is_Global then
               Emit_Native_FASM16.Set_Active_Buffer (Emit_Native_FASM16.Buffer_Global);
            else
               Emit_Native_FASM16.Set_Active_Buffer (Emit_Native_FASM16.Buffer_Main);
            end if;

      when Backend_Java =>
         if Is_Global then
            Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Global);
         else
            Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Boot);
         end if;

      when others =>
         null;
   end case;
end Set_Global_Buffer_Mode;


   procedure Emit_Newline (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Newline (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Newline (Success);
            
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Newline (Success);
            
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Newline (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Newline (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Newline;

   procedure Emit_Indent (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Indent (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Indent (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Indent (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Indent (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Indent (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Indent;
   
   procedure Emit_Input_Prompt_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Input_Prompt_Start (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Input_Prompt_Start (Success);
         when others => Success := False;
      end case;
   end Emit_Input_Prompt_Start;

   procedure Emit_Input_Prompt_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Input_Prompt_End (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Input_Prompt_End (Success);
         when others => Success := False;
      end case;
   end Emit_Input_Prompt_End;

   procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Input_Read_Start (Tag, Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Input_Read_Start (Tag, Success);
         when others => Success := False;
      end case;
   end Emit_Input_Read_Start;

   procedure Emit_Input_Read_End (Tag : ALB_Type_Tag; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Input_Read_End (Tag, Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Input_Read_End (Tag, Success);
         when others => Success := False;
      end case;
   end Emit_Input_Read_End;

   procedure Emit_Type_Definition (Tag : ALB_Type_Tag; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Type_Definition (Tag, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Type_Definition (Tag, Success);
            
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Type_Definition (Tag, Success);
            
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Type_Definition (Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Type_Definition;
   
   procedure Emit_Require_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Require_Start (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Require_Start (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Require_Start (Success);
         when Backend_FASM16 => Emit_Native_FASM16.Emit_Require_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_Require_Start;

   procedure Emit_Ensure_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Ensure_Start (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Ensure_Start (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Ensure_Start (Success);
         when Backend_FASM16 => Emit_Native_FASM16.Emit_Ensure_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_Ensure_Start;

   procedure Emit_Contract_End (Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Contract_End (Name, Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Contract_End (Name, Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Contract_End (Name, Success);
         when Backend_FASM16 => Emit_Native_FASM16.Emit_Contract_End (Name, Success);
         when others    => Success := False;
      end case;
   end Emit_Contract_End;

   procedure Emit_Pure_Struct_Def (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Pure_Struct_Def (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Pure_Struct_Def (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Pure_Struct_Def (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Pure_Struct_Def (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Pure_Struct_Def;

   procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Struct_Start (Struct_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Struct_Start (Struct_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Struct_Start (Struct_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Struct_Start (Struct_Name, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Struct_Start;

   procedure Emit_Struct_Field
     (Field_Name : String; Tag : ALB_Type_Tag; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Struct_Field (Field_Name, Tag, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Struct_Field (Field_Name, Tag, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Struct_Field (Field_Name, Tag, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Struct_Field (Field_Name, Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Struct_Field;

   procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Struct_End (Struct_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Struct_End (Struct_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Struct_End (Struct_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Struct_End (Struct_Name, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Struct_End;

   procedure Emit_Forward_Declaration
     (Func_Name   : String;
      Return_Tag : ALB_Type_Tag;
      Param_Count : Natural;
      Success    : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Forward_Declaration (Func_Name, Return_Tag, Param_Count, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Forward_Declaration (Func_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Forward_Declaration (Func_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_FOrward_Declaration (Func_Name, Success);
         when Backend_Java =>
            Success := True;

         when others =>
            Success := False;
      end case;
   end Emit_Forward_Declaration;

   procedure Emit_Var_Decl
     (Name : String; Tag : ALB_Type_Tag; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Var_Decl (Name, Tag, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Var_Decl (Name, Tag, Success);
            
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Var_Decl (Name, Tag, Success);
            
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Var_Decl (Name, Tag, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Var_Decl (Name, Tag, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Var_Decl;
   
    procedure Emit_Struct_Var_Decl
     (Struct_Name : String; Var_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Struct_Var_Decl (Struct_Name, Var_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Struct_Var_Decl (Struct_Name, Var_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Struct_Var_Decl (Struct_Name, Var_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Struct_Var_Decl (Struct_Name, Var_Name, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Struct_Var_Decl;
   
   procedure Emit_Global_Var_Decl (Name : String; Tag : ALB_Type_Tag; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Global_Var_Decl (Name, Tag, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Global_Var_Decl (Name, Tag, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Global_Var_Decl (Name, Tag, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Global_Var_Decl (Name, Tag, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Global_Var_Decl (Name, Tag, Success);
         when others    => Emit_Var_Decl (Name, Tag, Success); -- Safe Fallback
      end case;
   end Emit_Global_Var_Decl;

   procedure Emit_Strict_Array_Decl
     (Name : String; Size_Bytes : Natural; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Strict_Array_Decl (Name, Size_Bytes, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Strict_Array_Decl (Name, Size_Bytes, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Strict_Array_Decl (Name, Size_Bytes, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Strict_Array_Decl (Name, Size_Bytes, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Strict_Array_Decl;

   procedure Emit_Slide_Array_Decl
     (Name : String; Max_Bytes : Natural; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Slide_Array_Decl (Name, Max_Bytes, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Slide_Array_Decl (Name, Max_Bytes, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Slide_Array_Decl (Name, Max_Bytes, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Slide_Array_Decl (Name, Max_Bytes, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Slide_Array_Decl;
   
   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Temporal_Var_Decl
              (Name, Tag, History_Depth, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Temporal_Var_Decl
              (Name, Tag, History_Depth, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Temporal_Var_Decl
              (Name, Tag, History_Depth, Success);
         when Backend_C =>
            Emit_Native_C.Emit_Temporal_Var_Decl
              (Name, Tag, History_Depth, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Temporal_Var_Decl;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Temporal_Record_Current
              (Name, Tag, History_Depth, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Temporal_Record_Current
              (Name, Tag, History_Depth, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Temporal_Record_Current
              (Name, Tag, History_Depth, Success);
         when Backend_C =>
            Emit_Native_C.Emit_Temporal_Record_Current
              (Name, Tag, History_Depth, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Temporal_Record_Current;

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Temporal_Load_Now (Name, Tag, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Temporal_Load_Now (Name, Tag, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Temporal_Load_Now (Name, Tag, Success);
         when Backend_C =>
            Emit_Native_C.Emit_Temporal_Load_Now (Name, Tag, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Temporal_Load_Now;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Temporal_Load_Past
              (Name, Tag, History_Depth, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Temporal_Load_Past
              (Name, Tag, History_Depth, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Temporal_Load_Past
              (Name, Tag, History_Depth, Success);
         when Backend_C =>
            Emit_Native_C.Emit_Temporal_Load_Past
              (Name, Tag, History_Depth, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Temporal_Load_Past;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Temporal_Load_Timeline (Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Temporal_Load_Timeline (Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Temporal_Load_Timeline (Name, Success);
         when Backend_C =>
            Emit_Native_C.Emit_Temporal_Load_Timeline (Name, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Temporal_Load_Timeline;


   procedure Emit_Slide_Vault_Left
     (Vault_Name : String; Shift_Amount : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Slide_Vault_Left (Vault_Name, Shift_Amount, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Slide_Vault_Left (Vault_Name, Shift_Amount, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Slide_Vault_Left (Vault_Name, Shift_Amount, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Slide_Vault_Left;

   procedure Emit_Slide_Vault_Right
     (Vault_Name : String; Shift_Amount : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Slide_Vault_Right (Vault_Name, Shift_Amount, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Slide_Vault_Right (Vault_Name, Shift_Amount, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Slide_Vault_Right (Vault_Name, Shift_Amount, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Slide_Vault_Right;

   procedure Emit_Let_Assign_Start (Type_Hint : String; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Let_Assign_Start (Type_Hint, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Let_Assign_Start (Type_Hint, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Let_Assign_Start (Type_Hint, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Let_Assign_Start (Type_Hint, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Let_Assign_Start (Type_Hint, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Let_Assign_Start;

   procedure Emit_Variable_Ref (Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Variable_Ref (Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Variable_Ref (Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Variable_Ref (Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Variable_Ref (Name, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Variable_Ref (Name, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Variable_Ref;

   procedure Emit_Array_Index_Open (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Array_Index_Open (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Array_Index_Open (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Array_Index_Open (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Array_Index_Open (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Array_Index_Open;

   procedure Emit_Array_Index_Close (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Array_Index_Close (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Array_Index_Close (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Array_Index_Close (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Array_Index_Close (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Array_Index_Close;

   procedure Emit_String_Concat
     (Dest, Src, Max_Len : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_String_Concat (Dest, Src, Max_Len, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_String_Concat (Dest, Src, Max_Len, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_String_Concat (Dest, Src, Max_Len, Success);

         when others =>
            Success := False;
      end case;
   end Emit_String_Concat;

   procedure Emit_String_Copy
     (Dest, Src, Max_Len : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_String_Copy (Dest, Src, Max_Len, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_String_Copy (Dest, Src, Max_Len, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_String_Copy (Dest, Src, Max_Len, Success);

         when others =>
            Success := False;
      end case;
   end Emit_String_Copy;

   procedure Emit_String_Length (Src : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_String_Length (Src, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_String_Length (Src, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_String_Length (Src, Success);

         when others =>
            Success := False;
      end case;
   end Emit_String_Length;

   procedure Emit_AddressOf (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_AddressOf (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_AddressOf (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_AddressOf (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_AddressOf (Success);

         when others =>
            Success := False;
      end case;
   end Emit_AddressOf;

   procedure Emit_Boolean_Cast_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Boolean_Cast_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Boolean_Cast_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Boolean_Cast_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Boolean_Cast_Start (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Boolean_Cast_Start;

   procedure Emit_Literal_U64 (Value : U64; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Literal_U64 (Value, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Literal_U64 (Value, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Literal_U64 (Value, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Literal_U64 (Value, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Literal_U64 (Value, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Literal_U64;

   procedure Emit_String_Literal (Text : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_String_Literal (Text, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_String_Literal (Text, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_String_Literal (Text, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_String_Literal (Text, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_String_Literal (Text, Success);

         when others =>
            Success := False;
      end case;
   end Emit_String_Literal;

   procedure Emit_Expression_Open (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Expression_Open (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Expression_Open (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Expression_Open (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Expression_Open (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Expression_Open (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Expression_Open;

   procedure Emit_Expression_Close (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Expression_Close (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Expression_Close (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Expression_Close (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Expression_Close (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Expression_Close (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Expression_Close;

   procedure Emit_BinOp (Op : ALB_Opcode; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_BinOp (Op, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_BinOp (Op, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_BinOp (Op, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_BinOp (Op, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_BinOp (Op, Success);

         when others =>
            Success := False;
      end case;
   end Emit_BinOp;

   procedure Emit_Square_Root (Value : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Square_Root (Value, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Square_Root (Value, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Square_Root (Value, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Square_Root;

   procedure Emit_Sine (Value : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Sine (Value, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Sine (Value, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Sine (Value, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Sine;

   procedure Emit_Cosine (Value : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Cosine (Value, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Cosine (Value, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Cosine (Value, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Cosine;

   procedure Emit_Absolute (Value : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Absolute (Value, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Absolute (Value, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Absolute (Value, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Absolute;

   procedure Emit_Branchless_Condition_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Branchless_Condition_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Branchless_Condition_Start (Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Branchless_Condition_Start (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Branchless_Condition_Start;

   procedure Emit_Branchless_Mask_Op (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Branchless_Mask_Op (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Branchless_Mask_Op (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Branchless_Mask_Op (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Branchless_Mask_Op;

   procedure Emit_If_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_If_Start (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_If_Start (Success); -- DA ROUTE!
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_If_Start (Success); -- DA ROUTE!
         when Backend_FASM16 => Emit_Native_FASM16.Emit_If_Start (Success); -- DA ROUTE!
         when others    => Success := False;
      end case;
   end Emit_If_Start;

   procedure Emit_Then (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Then (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Then (Success); -- DA ROUTE!
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Then (Success); -- DA ROUTE!
         when Backend_FASM16 => Emit_Native_FASM16.Emit_Then (Success);
         when others    => Success := False;
      end case;
   end Emit_Then;
   
   procedure Emit_Else (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Else (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Else (Success); -- DA ROUTE!
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Else (Success); -- DA ROUTE!
         when Backend_FASM16 => Emit_Native_FASM16.Emit_Else (Success);
         when others    => Success := False;
      end case;
   end Emit_Else;

   procedure Emit_If_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_If_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_If_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_If_End (Success);
         when Backend_FASM16 => Emit_Native_FASM16.Emit_If_End (Success);
            
         when others =>
            Success := False;
      end case;
   end Emit_If_End;
   
   procedure Emit_SizeOf_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_SizeOf_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_SizeOf_Start;

   procedure Emit_OffsetOf_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_OffsetOf_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_OffsetOf_Start;

   procedure Emit_Runtime_Assert_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Runtime_Assert_Start (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Runtime_Assert_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_Runtime_Assert_Start;

   procedure Emit_Runtime_Assert_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Runtime_Assert_End (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Runtime_Assert_End (Success);
         when others    => Success := False;
      end case;
   end Emit_Runtime_Assert_End;
   
   procedure Emit_Readline_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Readline_Start (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Readline_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_Readline_Start;

   procedure Emit_Readline_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Readline_End (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Readline_End (Success);
         when others    => Success := False;
      end case;
   end Emit_Readline_End;

   procedure Emit_Cut_Operator (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Cut_Operator (Success);
         when others    => Success := False;
      end case;
   end Emit_Cut_Operator;

   --  procedure Emit_Loop_Step_Mid (Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C => Emit_Native_C.Emit_Loop_Step_Mid (Success);
   --        when others    => Success := False;
   --     end case;
   --  end Emit_Loop_Step_Mid;
   --  
   --  procedure Emit_Loop_Step_End (Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C => Emit_Native_C.Emit_Loop_Step_End (Success);
   --        when others    => Success := False;
   --     end case;
   --  end Emit_Loop_Step_End;
   
   procedure Emit_Loop_Step_Mid (Success : out Boolean) is
   begin
      case Active_Target is
      when Backend_C =>
         Emit_Native_C.Emit_Loop_Step_Mid (Success);
      when Backend_FASM16 =>
         Emit_Native_FASM16.Emit_Loop_Step_Mid (Success);
      when others =>
         Success := False;
      end case;
   end Emit_Loop_Step_Mid;

   procedure Emit_Loop_Step_End (Success : out Boolean) is
   begin
      case Active_Target is
      when Backend_C =>
         Emit_Native_C.Emit_Loop_Step_End (Success);
      when Backend_FASM16 =>
         Emit_Native_FASM16.Emit_Loop_Step_End (Success);
      when others =>
         Success := False;
      end case;
   end Emit_Loop_Step_End;
   

   procedure Emit_While_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_While_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_While_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_While_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_While_Start (Success);
         when others =>
            Success := False;
      end case;
   end Emit_While_Start;

   procedure Emit_While_Loop_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_While_Loop_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_While_Loop_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_While_Loop_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_While_Loop_Start (Success);
         when others =>
            Success := False;
      end case;
   end Emit_While_Loop_Start;

   procedure Emit_Plain_Loop_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Plain_Loop_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Plain_Loop_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Plain_Loop_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Plain_Loop_Start (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Plain_Loop_Start;

   procedure Emit_Exit_When (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Exit_When (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Exit_When (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Exit_When (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Exit_When (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Exit_When;

   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_For_Start (Iterator_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_For_Start (Iterator_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_For_Start (Iterator_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_For_Start (Iterator_Name, Success);
         when others =>
            Success := False;
      end case;
   end Emit_For_Start;
   
   --  procedure Emit_Foreach_Start (Iterator_Name : String; Array_Name : String; Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C =>
   --           Emit_Native_C.Emit_Foreach_Start (Iterator_Name, Array_Name, Success);
   --        when Backend_FASM =>
   --           -- Shield FASM safely until we build an assembly array scanner!
   --           Emit_Native_FASM.Emit_Raw ("  ; FOREACH NOT IMPL IN FASM YET", Success);
   --           Emit_Native_FASM.Emit_Newline (Success);
   --        when others =>
   --           Success := False;
   --     end case;
   --  end Emit_Foreach_Start;
   
   procedure Emit_Foreach_Start (Iterator_Name : String; Array_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Foreach_Start (Iterator_Name, Array_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Foreach_Start (Iterator_Name, Array_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Foreach_Start (Iterator_Name, Array_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Foreach_Start (Iterator_Name, Array_Name, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Foreach_Start;


   procedure Emit_DotDot (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_DotDot (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_DotDot (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_DotDot (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_DotDot (Success);
         when others =>
            Success := False;
      end case;
   end Emit_DotDot;

   procedure Emit_Loop_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Loop_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Loop_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Loop_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Loop_Start (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Loop_Start;

   procedure Emit_Loop_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Loop_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Loop_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Loop_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Loop_End (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Loop_End;

   procedure Emit_Case_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Case_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Case_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Case_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Case_Start (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Case_Start;

   procedure Emit_Is (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Is (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Is (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Is (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Is (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Is;

   procedure Emit_When (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_When (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_When (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_When (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_When (Success);
         when others =>
            Success := False;
      end case;
   end Emit_When;

   procedure Emit_Arrow (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Arrow (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Arrow (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Arrow (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Arrow (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Arrow;

   procedure Emit_When_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_When_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_When_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_When_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_When_End (Success);

         when others =>
            Success := False;
      end case;
   end Emit_When_End;

   procedure Emit_Case_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Case_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Case_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Case_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Case_End (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Case_End;
   
   procedure Emit_Procedure_Decl_Start (Name : String; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Procedure_Decl_Start (Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Procedure_Decl_Start (Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Procedure_Decl_Start (Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Procedure_Decl_Start (Name, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Procedure_Decl_Start (Name, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Procedure_Decl_Start;
   
   procedure Emit_Function_Decl_Start
     (Func_Name : String; Return_Tag : ALB_Type_Tag; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Function_Decl_Start (Func_Name, Return_Tag, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Function_Decl_Start (Func_Name, Return_Tag, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Function_Decl_Start (Func_Name, Return_Tag, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Function_Decl_Start (Func_Name, Return_Tag, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Function_Decl_Start (Func_Name, Return_Tag, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Function_Decl_Start;

   procedure Emit_Procedure_End (Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Procedure_End (Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Procedure_End (Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Procedure_End (Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Procedure_End (Name, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Procedure_End (Name, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Procedure_End;

   procedure Emit_Return_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Return_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Return_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Return_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Return_Start (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Return_Start (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Return_Start;

   --  procedure Emit_Call_Start (Func_Name : String; Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C =>
   --           Emit_Native_C.Emit_Call_Start (Func_Name, Success);
   --        when Backend_FASM =>
   --           Emit_Native_FASM.Emit_Call_Start (Func_Name, Success);
   --  
   --        when others =>
   --           Success := False;
   --     end case;
   --  end Emit_Call_Start;
   procedure Emit_Call_Start (Func_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Call_Start (Func_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Call_Start (Func_Name, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Call_Start (Func_Name, Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Call_Start (Func_Name, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Call_Start;

   procedure Emit_Call_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Call_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Call_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Call_End (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Call_End (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Call_End;

   procedure Emit_Comma (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Comma (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Comma (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Comma (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Comma (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Comma (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Comma;

   procedure Emit_Statement_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Statement_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Statement_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Statement_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Statement_End (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Statement_End (Success);

         when others =>
            Success := False;
      end case;
   end Emit_Statement_End;
   
   procedure Emit_Assign_Prefix (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Assign_Prefix (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Assign_Prefix (Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Assign_Prefix (Success);
         when Backend_Java => Emit_Native_Java.Emit_Assign_Prefix (Success);
         when others => Success := False;
      end case;
   end Emit_Assign_Prefix;

   procedure Emit_Print_Start (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => 
            -- DA FIX: Pass the pipe flag doon tae the C Forge!
            Emit_Native_C.Emit_Print_Start (Tag, Piped, Success);
         when Backend_FASM => 
            -- Safely shield FASM frae the pipe flag until we upgrade it later!
            Emit_Native_FASM.Emit_Print_Start (Tag, Success);
         when Backend_Brainfuck =>
            -- Safely shield FASM frae the pipe flag until we upgrade it later!
            Emit_Native_Brainfuck.Emit_Print_Start (Tag, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Print_Start (Tag, Piped, Success);   
         when Backend_Java =>
            Emit_Native_Java.Emit_Print_Start (Tag, Piped, Success);
         
         when others => 
            Success := False;
      end case;
   end Emit_Print_Start;

   procedure Emit_Print_End (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => 
            -- DA FIX: Pass the pipe flag doon tae the C Forge!
            Emit_Native_C.Emit_Print_End (Tag, Piped, Success);
         when Backend_FASM => 
            -- Safely shield FASM frae the pipe flag!
            Emit_Native_FASM.Emit_Print_End (Tag, Success);
         when Backend_Brainfuck =>
            -- Safely shield FASM frae the pipe flag!
            Emit_Native_Brainfuck.Emit_Print_End (Tag, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Print_End (Tag, Piped, Success);   
         when Backend_Java =>
            Emit_Native_Java.Emit_Print_End (Tag, Piped, Success);
         
         when others => 
            Success := False;
      end case;
   end Emit_Print_End;
   
   procedure Emit_File_Open_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Open_Start (Success);
         when others => Success := False;
      end case;
   end Emit_File_Open_Start;

   procedure Emit_File_Open_Mid (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Open_Mid (Success);
         when others => Success := False;
      end case;
   end Emit_File_Open_Mid;

   procedure Emit_File_Read_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Read_Start (Success);
         when others => Success := False;
      end case;
   end Emit_File_Read_Start;

   procedure Emit_File_Read_Mid (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Read_Mid (Success);
         when others => Success := False;
      end case;
   end Emit_File_Read_Mid;

   procedure Emit_File_Write_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Write_Start (Success);
         when others => Success := False;
      end case;
   end Emit_File_Write_Start;

   procedure Emit_File_Write_Mid (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Write_Mid (Success);
         when others => Success := False;
      end case;
   end Emit_File_Write_Mid;

   procedure Emit_File_Close_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Close_Start (Success);
         when others => Success := False;
      end case;
   end Emit_File_Close_Start;

   procedure Emit_File_Len_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Len_Start (Success);
         when others => Success := False;
      end case;
   end Emit_File_Len_Start;

   procedure Emit_File_Seek_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Seek_Start (Success);
         when others => Success := False;
      end case;
   end Emit_File_Seek_Start;

   procedure Emit_File_Seek_Mid (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_File_Seek_Mid (Success);
         when others => Success := False;
      end case;
   end Emit_File_Seek_Mid;
   
   --  procedure Emit_Try_Start (Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C => Emit_Native_C.Emit_Try_Start (Success);
   --        when others => Success := False;
   --     end case;
   --  end Emit_Try_Start;
   --  
   --  procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C => Emit_Native_C.Emit_Catch_Start (Err_Var, Success);
   --        when others => Success := False;
   --     end case;
   --  end Emit_Catch_Start;
   --  
   --  procedure Emit_Try_End (Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C => Emit_Native_C.Emit_Try_End (Success);
   --        when others => Success := False;
   --     end case;
   --  end Emit_Try_End;
   --  
   --  procedure Emit_Throw_Start (Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C => Emit_Native_C.Emit_Throw_Start (Success);
   --        when others => Success := False;
   --     end case;
   --  end Emit_Throw_Start;
   --  
   --  procedure Emit_Throw_End (Success : out Boolean) is
   --  begin
   --     case Active_Target is
   --        when Backend_C => Emit_Native_C.Emit_Throw_End (Success);
   --        when others => Success := False;
   --     end case;
   --  end Emit_Throw_End;
   
   procedure Emit_Try_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Try_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Try_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Try_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Try_Start (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Try_Start;

   procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Catch_Start (Err_Var, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Catch_Start (Err_Var, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Catch_Start (Err_Var, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Catch_Start (Err_Var, Success);
         when others =>
            Success := False;
      end case;
   end Emit_Catch_Start;

   procedure Emit_Try_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Try_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Try_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Try_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Try_End (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Try_End;

   procedure Emit_Throw_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Throw_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Throw_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Throw_Start (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Throw_Start (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Throw_Start;

   procedure Emit_Throw_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Throw_End (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Throw_End (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Throw_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Throw_End (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Throw_End;


   procedure Emit_OS_Load
     (File_Path : String; Target_Buffer : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_OS_Load (File_Path, Target_Buffer, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_OS_Load (File_Path, Target_Buffer, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_OS_Load (File_Path, Target_Buffer, Success);
         when others =>
            Success := False;
      end case;
   end Emit_OS_Load;
   
   procedure Emit_Poke_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Poke_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_Poke_Start;

   procedure Emit_Poke_Mid (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Poke_Mid (Success);
         when others    => Success := False;
      end case;
   end Emit_Poke_Mid;

   procedure Emit_Peek_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Peek_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_Peek_Start;

   procedure Emit_Deref_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Deref_Start (Success);
         when others    => Success := False;
      end case;
   end Emit_Deref_Start;

   procedure Emit_OS_Flush
     (Source_Buffer : String; File_Path : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_OS_Flush (Source_Buffer, File_Path, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_OS_Flush (Source_Buffer, File_Path, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_OS_Flush (Source_Buffer, File_Path, Success);

         when others =>
            Success := False;
      end case;
   end Emit_OS_Flush;

   procedure Emit_Prolog_Fact_Registration
     (Pred : String; Arg : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Prolog_Fact_Registration (Pred, Arg, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Prolog_Fact_Registration (Pred, Arg, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Prolog_Fact_Registration (Pred, Arg, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Prolog_Fact_Registration;
   
   procedure Emit_Assert_Call (Pred, Arg : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => 
            Emit_Native_C.Emit_Raw ("ALB_Assert(""" & Pred & """, " & Arg & ", 0ULL);", Success);
            Emit_Native_C.Emit_Newline (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Assert_Call (Pred, Arg, Success); -- DA FIX!
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Assert_Call (Pred, Arg, Success); -- DA FIX!
         when others => Success := False;
      end case;
   end Emit_Assert_Call;

   procedure Emit_Retract_Call (Pred, Arg : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => 
            Emit_Native_C.Emit_Raw ("ALB_Retract(""" & Pred & """, " & Arg & ");", Success);
            Emit_Native_C.Emit_Newline (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Retract_Call (Pred, Arg, Success); -- DA FIX!
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Retract_Call (Pred, Arg, Success); -- DA FIX!
         when others => Success := False;
      end case;
   end Emit_Retract_Call;

   procedure Emit_Prolog_Query_Call
     (Pred : String; Arg : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Prolog_Query_Call (Pred, Arg, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Prolog_Query_Call (Pred, Arg, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Prolog_Query_Call (Pred, Arg, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Prolog_Query_Call;
   
   procedure Emit_Update_Call (Pred, Old_Arg, New_Arg : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => 
            Emit_Native_C.Emit_Raw ("ALB_Update(""" & Pred & """, " & Old_Arg & "ULL, " & New_Arg & "ULL);", Success);
            Emit_Native_C.Emit_Newline (Success);
         when Backend_FASM => 
            Emit_Native_FASM.Emit_Update_Call (Pred, Old_Arg, New_Arg, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Update_Call (Pred, Old_Arg, New_Arg, Success);
         when others => Success := False;
      end case;
   end Emit_Update_Call;

   procedure Emit_FindAll_Call (Pred, Out_Array : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => 
            Emit_Native_C.Emit_Raw ("ALB_FindAll(""" & Pred & """, " & Out_Array & ");", Success);
            Emit_Native_C.Emit_Newline (Success);
         when Backend_FASM => 
            Emit_Native_FASM.Emit_FindAll_Call (Pred, Out_Array, Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_FindAll_Call (Pred, Out_Array, Success);
         when others => Success := False;
      end case;
   end Emit_FindAll_Call;

   procedure Emit_Key_State (Key_Code : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Key_State (Key_Code, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Key_State (Key_Code, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Key_State (Key_Code, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Key_State;

   procedure Emit_Mouse_Position (X_Var, Y_Var : String; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Mouse_Position (X_Var, Y_Var, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Mouse_Position (X_Var, Y_Var, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Mouse_Position (X_Var, Y_Var, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Mouse_Position;

   procedure Emit_Mouse_Click (Button : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Mouse_Click (Button, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Mouse_Click (Button, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Mouse_Click (Button, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Mouse_Click;

   procedure Emit_Put_Pixel (X, Y, Color : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Put_Pixel (X, Y, Color, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Put_Pixel (X, Y, Color, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Put_Pixel (X, Y, Color, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Put_Pixel;

   procedure Emit_Draw_Line
     (X1, Y1, X2, Y2, Color : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Draw_Line (X1, Y1, X2, Y2, Color, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Draw_Line;

   procedure Emit_Draw_Rect (X, Y, W, H, Color : String; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Draw_Rect (X, Y, W, H, Color, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Draw_Rect;

   procedure Emit_Fill_Rect (X, Y, W, H, Color : String; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Fill_Rect (X, Y, W, H, Color, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Fill_Rect;

   procedure Emit_Blit_Image
     (Source_Vault, X, Y : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Blit_Image (Source_Vault, X, Y, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Blit_Image;

   procedure Emit_Load_Sound
     (File_Path, Target_Vault : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Load_Sound (File_Path, Target_Vault, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Load_Sound;

   procedure Emit_Play_Sound (Vault_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Play_Sound (Vault_Name, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Play_Sound (Vault_Name, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Play_Sound (Vault_Name, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Play_Sound;

   procedure Emit_Print_Function_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Print_Function_Start (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Print_Function_Start (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Print_Function_Start (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Print_Function_Start;

   procedure Emit_Window_Creation (Title : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_FASM => Emit_Native_FASM.Emit_Window_Creation (Title, Success);
         when Backend_Brainfuck => Emit_Native_Brainfuck.Emit_Window_Creation (Title, Success);
         when Backend_FASM16 => Emit_Native_FASM16.Emit_Window_Creation (Title, Success);
         when Backend_C => Emit_Native_C.Emit_Window_Creation (Title, Success);
         when others => Success := False;
      end case;
   end Emit_Window_Creation;

   procedure Emit_Set_Fullscreen (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Set_Fullscreen (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Set_Fullscreen (Success);
         when Backend_C =>
            Emit_Native_C.Emit_Set_Fullscreen (Success);
         when Backend_FASM16 =>
            Success := True;
         when others =>
            Success := True;
      end case;
   end Emit_Set_Fullscreen;

   procedure Emit_Set_Resizable (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Set_Resizable (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Set_Resizable (Success);
         when Backend_C =>
            Emit_Native_C.Emit_Set_Resizable (Success);
         when Backend_FASM16 =>
            Success := True;
         when others =>
            Success := True;
      end case;
   end Emit_Set_Resizable;

   procedure Emit_Set_Stretchy (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Set_Stretchy (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Set_Stretchy (Success);
         when Backend_C =>
            Emit_Native_C.Emit_Set_Stretchy (Success);
         when Backend_FASM16 =>
            Success := True;
         when others =>
            Success := True;
      end case;
   end Emit_Set_Stretchy;

   procedure Emit_Message_Loop (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Message_Loop (Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Message_Loop (Success);
         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Message_Loop (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Message_Loop (Success);
         when Backend_Java =>
            Emit_Native_Java.Emit_Message_Loop (Success);
         when others =>
            Success := False;
      end case;
   end Emit_Message_Loop;

   procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean)
   is
   begin
      case Active_Target is
         when Backend_C =>
            Emit_Native_C.Emit_Win32_Color_BGR (Color_Hex, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Win32_Color_BGR (Color_Hex, Success);

         when Backend_Brainfuck =>
            Emit_Native_Brainfuck.Emit_Win32_Color_BGR (Color_Hex, Success);

         when others =>
            Success := False;
      end case;
   end Emit_Win32_Color_BGR;
   
   procedure Emit_Clear_Color (Color : String; Success : out Boolean) is
   begin
      if Active_Target = Backend_C then
         Emit_Native_C.Emit_Clear_Color (Color, Success);
      elsif Active_Target = Backend_Java then
         Emit_Native_Java.Emit_Clear_Color (Color, Success);
      elsif Active_Target = Backend_FASM then
         Emit_Native_FASM.Emit_Raw ("  mov rcx, " & Color, Success);
         Emit_Native_FASM.Emit_Newline (Success);
         Emit_Native_FASM.Emit_Raw ("  call ALB_Set_Clear_Color", Success);
         Emit_Native_FASM.Emit_Newline (Success);
      elsif Active_Target = Backend_FASM16 then
         Emit_Native_FASM16.Emit_Raw ("  mov ax, " & Color, Success);
         Emit_Native_FASM16.Emit_Newline (Success);
         Emit_Native_FASM16.Emit_Raw ("  xor dx, dx", Success);
         Emit_Native_FASM16.Emit_Newline (Success);
         Emit_Native_FASM16.Emit_Raw ("  call ALB_Set_Clear_Color", Success);
         Emit_Native_FASM16.Emit_Newline (Success);
      else
         Success := False;
      end if;
   end Emit_Clear_Color;
   
   -- =========================================================================
   -- DA MULTI-CORE DISPATCH FORGE ROUTING
   -- =========================================================================
   procedure Emit_Spawn_Start (Func_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Spawn_Start (Func_Name, Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Spawn_Start (Func_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Raw ("  ; SPAWN (sync DOS)", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  call " & Func_Name, Success);
            Emit_Native_FASM16.Emit_Newline (Success);
         when others    => Success := False;
      end case;
   end Emit_Spawn_Start;

   procedure Emit_Spawn_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Spawn_End (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Spawn_End (Success);
         when Backend_FASM16 => Success := True;
         when others    => Success := False;
      end case;
   end Emit_Spawn_End;

   procedure Emit_Sync (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Sync (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Sync (Success);
         when Backend_FASM16 =>
            -- Single-threaded DOS: SYNC is intentionally a no-op.
            Success := True;
         when others    => Success := False;
      end case;
   end Emit_Sync;

   procedure Emit_Atomic_Start (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Atomic_Start (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Atomic_Start (Success);
         when Backend_FASM16 =>
            -- Mask IRQs for the ATOMIC block (lean DOS critical section).
            Emit_Native_FASM16.Emit_Raw ("  cli", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
         when others    => Success := False;
      end case;
   end Emit_Atomic_Start;

   procedure Emit_Atomic_End (Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Atomic_End (Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Atomic_End (Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Raw ("  sti", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
         when others    => Success := False;
      end case;
   end Emit_Atomic_End;
   
   
   -- =========================================================================
   -- DA DUMPTRUCK HAL ROUTERS
   -- =========================================================================
   procedure Emit_Claim (Var_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Claim (Var_Name, Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Claim (Var_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Raw ("  call ALB16_GC_Claim", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  mov word [" & Var_Name & "], ax", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
         when others    => Success := False;
      end case;
   end Emit_Claim;

   procedure Emit_Drop (Var_Name : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Drop (Var_Name, Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Drop (Var_Name, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Raw ("  mov ax, word [" & Var_Name & "]", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  xor dx, dx", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  call ALB16_GC_Drop", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
         when others    => Success := False;
      end case;
   end Emit_Drop;

   procedure Emit_Sweep (Chunk_Expr : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Sweep (Chunk_Expr, Success);
         when Backend_FASM => Emit_Native_FASM.Emit_Sweep (Chunk_Expr, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Raw ("  mov ax, " & Chunk_Expr, Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  xor dx, dx", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  call ALB16_GC_Sweep", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
         when others    => Success := False;
      end case;
   end Emit_Sweep;

   procedure Emit_Bind (Parent_Var : String; Child1_Expr : String; Child2_Expr : String; Success : out Boolean) is
   begin
      case Active_Target is
         when Backend_C => Emit_Native_C.Emit_Bind (Parent_Var, Child1_Expr, Child2_Expr, Success);
         when Backend_FASM =>
            Emit_Native_FASM.Emit_Bind (Parent_Var, Child1_Expr, Child2_Expr, Success);
         when Backend_FASM16 =>
            Emit_Native_FASM16.Emit_Raw ("  mov ax, word [" & Parent_Var & "]", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  mov bx, " & Child1_Expr, Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  mov dx, " & Child2_Expr, Success);
            Emit_Native_FASM16.Emit_Newline (Success);
            Emit_Native_FASM16.Emit_Raw ("  call ALB16_GC_Bind", Success);
            Emit_Native_FASM16.Emit_Newline (Success);
         when others    => Success := False;
      end case;
   end Emit_Bind;

end Transpiler_Native_HAL;
