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

with Ada.Text_IO;
with ALB_Types;       use ALB_Types;
with Numerus_Magnus;  use Numerus_Magnus;
with Opcodes;         use Opcodes;

package body Emit_Native_FASM16 is

   --  Match FASM64 vault (GameDeck-ALB weaves exceed 1 MiB).
   Max_Buffer_Size : constant Natural := 8_388_608;

   Global_Buffer : String (1 .. Max_Buffer_Size);
   Global_Len    : Natural := 0;

   Main_Buffer : String (1 .. Max_Buffer_Size);
   Main_Len    : Natural := 0;
   String_Counter : Natural := 0;

   Current_Struct_Name   : String (1 .. 128) := (others => ' ');
   Current_Struct_Len    : Natural := 0;
   Current_Struct_Offset : Natural := 0;
   Native_Label_Counter  : Natural := 0;
   Contract_Check_Counter : Natural := 0;
   Max_Call_Pointers     : constant Natural := 512;

   type Call_Pointer_Record is record
      Active     : Boolean := False;
      Target_Len : Natural := 0;
      Target     : String (1 .. 128) := (others => ' ');
      Label_Len  : Natural := 0;
      Label      : String (1 .. 160) := (others => ' ');
   end record;

   Call_Pointers : array (1 .. Max_Call_Pointers) of Call_Pointer_Record :=
     (others =>
        (Active     => False,
         Target_Len => 0,
         Target     => (others => ' '),
         Label_Len  => 0,
         Label      => (others => ' ')));
   Call_Pointer_Count : Natural := 0;

   Max_Try_Depth : constant Natural := 64;
   Try_Counter   : Natural := 0;
   Try_Depth     : Natural := 0;
   Try_Stack     : array (1 .. Max_Try_Depth) of Natural := (others => 0);
   
   procedure Append (Text : String; Success : out Boolean);
   procedure Line (Text : String; Success : out Boolean);

   function Field_Size_Bytes (Tag : ALB_Type_Tag) return Natural is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
            return 1;

         when Type_U16 | Type_S16 | Type_HW16 | Type_Binary | Type_Reference =>
            return 2;

         when others =>
            return 4;
      end case;
   end Field_Size_Bytes;

   -- ---------------------------------------------------------------
   -- Small formatting helper.
   -- Ada 'Image attributes include a leading space for positive
   -- numeric values. Assembly should not inherit that.
   -- ---------------------------------------------------------------
   function Trim_Image (Text : String) return String is
      First : Natural := Text'First;
   begin
      while First <= Text'Last and then Text (First) = ' ' loop
         First := First + 1;
      end loop;

      if First > Text'Last then
         return "0";
      end if;

      return Text (First .. Text'Last);
   end Trim_Image;

   function Fresh_Label_ID return String is
   begin
      Native_Label_Counter := Native_Label_Counter + 1;
      return Trim_Image (Natural'Image (Native_Label_Counter));
   end Fresh_Label_ID;

   procedure Emit_Long_Trap_Jcc
     (Cond    : String;
      Trap    : String;
      Success : out Boolean)
   is
      OK         : Boolean := True;
      Skip_Label : constant String := ".alb16_trap_skip_" & Fresh_Label_ID;
   begin
      if Cond = "jb" then
         Line ("  jae " & Skip_Label, OK);
      elsif Cond = "ja" then
         Line ("  jbe " & Skip_Label, OK);
      elsif Cond = "jc" then
         Line ("  jnc " & Skip_Label, OK);
      elsif Cond = "je" or else Cond = "jz" then
         Line ("  jne " & Skip_Label, OK);
      elsif Cond = "jne" or else Cond = "jnz" then
         Line ("  je " & Skip_Label, OK);
      else
         OK := False;
      end if;

      if OK then Line ("  mov bx, " & Trap, OK); end if;
      if OK then Line ("  jmp bx", OK); end if;
      if OK then Line (Skip_Label & ":", OK); end if;
      Success := OK;
   end Emit_Long_Trap_Jcc;

   procedure Emit_Runtime_Trap_Handlers
     (Success : out Boolean)
   is
      Saved_Buffer : constant Buffer_Target := Current_Buffer;
      OK           : Boolean := True;
   begin
      Current_Buffer := Buffer_Global;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Runtime_DivZero", OK); end if;
      if OK then Line ("ALB16_Runtime_DivZero:", OK); end if;
      if OK then Line ("  mov dx, ALB16_DivZero", OK); end if;
      if OK then Line ("  mov ah, 09h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  mov ax, 4C01h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Runtime_Bounds", OK); end if;
      if OK then Line ("ALB16_Runtime_Bounds:", OK); end if;
      if OK then Line ("  mov dx, ALB16_Bounds", OK); end if;
      if OK then Line ("  mov ah, 09h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  mov ax, 4C01h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Runtime_Range", OK); end if;
      if OK then Line ("ALB16_Runtime_Range:", OK); end if;
      if OK then Line ("  mov dx, ALB16_Range", OK); end if;
      if OK then Line ("  mov ah, 09h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  mov ax, 4C01h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("end if", OK); end if;

      Current_Buffer := Saved_Buffer;
      Success := OK;
   end Emit_Runtime_Trap_Handlers;

   function Ensure_Absolute_Call_Pointer
     (Target : String) return String
   is
      Saved_Buffer : constant Buffer_Target := Current_Buffer;
      OK           : Boolean := True;
      Label_Name   : constant String := "ALB16_NEARPTR_" & Fresh_Label_ID;
   begin
      for I in 1 .. Call_Pointer_Count loop
         if Call_Pointers (I).Active
           and then Call_Pointers (I).Target_Len = Target'Length
           and then
             Call_Pointers (I).Target (1 .. Call_Pointers (I).Target_Len) =
             Target
         then
            return
              Call_Pointers (I).Label (1 .. Call_Pointers (I).Label_Len);
         end if;
      end loop;

      if Call_Pointer_Count >= Max_Call_Pointers then
         return Target;
      end if;

      Call_Pointer_Count := Call_Pointer_Count + 1;
      Call_Pointers (Call_Pointer_Count).Active := True;
      Call_Pointers (Call_Pointer_Count).Target_Len := Target'Length;
      Call_Pointers (Call_Pointer_Count).Target (1 .. Target'Length) := Target;
      Call_Pointers (Call_Pointer_Count).Label_Len := Label_Name'Length;
      Call_Pointers (Call_Pointer_Count).Label (1 .. Label_Name'Length) :=
        Label_Name;

      Current_Buffer := Buffer_Global;
      Line (Label_Name & " dw " & Target, OK);
      Current_Buffer := Saved_Buffer;

      if not OK then
         return Target;
      end if;

      return Label_Name;
   end Ensure_Absolute_Call_Pointer;

   function Normalize_FASM16_Tag
     (Tag : ALB_Type_Tag) return ALB_Type_Tag
   is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
            return Tag;

         when Type_U16 | Type_S16 | Type_HW16 | Type_Binary | Type_Reference =>
            return Tag;

         when Type_S32 | Type_S64 | Type_S128 =>
            return Type_S32;

         when Type_HW32 | Type_HW64 =>
            return Type_HW32;

         when Type_U32 =>
            return Type_U32;

         when Type_U64 | Type_U128 =>
            return Type_U32;

         when Type_Pure =>
            return Type_Pure;

         when others =>
            return Type_U32;
      end case;
   end Normalize_FASM16_Tag;

   function FASM16_Tag_Supported
     (Tag : ALB_Type_Tag) return Boolean
   is
   begin
      return Tag /= Type_None;
   end FASM16_Tag_Supported;

   procedure Emit_Load_Cell_To_DXAX
     (Cell    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Tag);
   begin
      case MTag is
         when Type_S8 =>
            if OK then Line ("  mov al, byte [" & Cell & "]", OK); end if;
            if OK then Line ("  cbw", OK); end if;
            if OK then Line ("  cwd", OK); end if;

         when Type_U8 | Type_HW8 | Type_Boolean | Type_Char =>
            if OK then Line ("  xor ax, ax", OK); end if;
            if OK then Line ("  xor dx, dx", OK); end if;
            if OK then Line ("  mov al, byte [" & Cell & "]", OK); end if;

         when Type_U32 | Type_S32 | Type_HW32 | Type_Pure =>
            if OK then Line ("  mov ax, word [" & Cell & "]", OK); end if;
            if OK then Line ("  mov dx, word [" & Cell & "+2]", OK); end if;

         when Type_Binary | Type_Reference =>
            if OK then Line ("  mov ax, word [" & Cell & "]", OK); end if;
            if OK then Line ("  mov dx, ax", OK); end if;

         when Type_S16 =>
            if OK then Line ("  mov ax, word [" & Cell & "]", OK); end if;
            if OK then Line ("  cwd", OK); end if;

         when others =>
            if OK then Line ("  mov ax, word [" & Cell & "]", OK); end if;
            if OK then Line ("  xor dx, dx", OK); end if;
      end case;

      Success := OK;
   end Emit_Load_Cell_To_DXAX;

   procedure Emit_Store_DXAX_To_Cell
     (Cell    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Tag);
   begin
      case MTag is
         when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
            if OK then Line ("  mov byte [" & Cell & "], al", OK); end if;

         when Type_U32 | Type_S32 | Type_HW32 | Type_Pure =>
            if OK then Line ("  mov word [" & Cell & "], ax", OK); end if;
            if OK then Line ("  mov word [" & Cell & "+2], dx", OK); end if;

         when others =>
            if OK then Line ("  mov word [" & Cell & "], ax", OK); end if;
      end case;

      Success := OK;
   end Emit_Store_DXAX_To_Cell;

   procedure Emit_Load_Indexed_Base_To_DXAX
     (Base    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Tag);
   begin
      case MTag is
         when Type_S8 =>
            if OK then Line ("  mov al, byte [" & Base & " + bx]", OK); end if;
            if OK then Line ("  cbw", OK); end if;
            if OK then Line ("  cwd", OK); end if;

         when Type_U8 | Type_HW8 | Type_Boolean | Type_Char =>
            if OK then Line ("  xor ax, ax", OK); end if;
            if OK then Line ("  xor dx, dx", OK); end if;
            if OK then Line ("  mov al, byte [" & Base & " + bx]", OK); end if;

         when Type_U32 | Type_S32 | Type_HW32 | Type_Pure =>
            if OK then Line ("  mov ax, word [" & Base & " + bx]", OK); end if;
            if OK then Line ("  mov dx, word [" & Base & " + bx + 2]", OK); end if;

         when Type_Binary | Type_Reference =>
            if OK then Line ("  mov ax, word [" & Base & " + bx]", OK); end if;
            if OK then Line ("  mov dx, ax", OK); end if;

         when Type_S16 =>
            if OK then Line ("  mov ax, word [" & Base & " + bx]", OK); end if;
            if OK then Line ("  cwd", OK); end if;

         when others =>
            if OK then Line ("  mov ax, word [" & Base & " + bx]", OK); end if;
            if OK then Line ("  xor dx, dx", OK); end if;
      end case;

      Success := OK;
   end Emit_Load_Indexed_Base_To_DXAX;

   procedure Emit_Store_DXAX_To_Indexed_Base
     (Base    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Tag);
   begin
      case MTag is
         when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
            if OK then Line ("  mov byte [" & Base & " + bx], al", OK); end if;

         when Type_U32 | Type_S32 | Type_HW32 | Type_Pure =>
            if OK then Line ("  mov word [" & Base & " + bx], ax", OK); end if;
            if OK then Line ("  mov word [" & Base & " + bx + 2], dx", OK); end if;

         when others =>
            if OK then Line ("  mov word [" & Base & " + bx], ax", OK); end if;
      end case;

      Success := OK;
   end Emit_Store_DXAX_To_Indexed_Base;

   procedure Emit_Scale_BX_For_Size
     (Elem_Bytes : Natural;
      Success    : out Boolean)
   is
      OK : Boolean := True;
   begin
      if Elem_Bytes = 2 then
         if OK then Line ("  shl bx, 1", OK); end if;
      elsif Elem_Bytes = 4 then
         if OK then Line ("  shl bx, 1", OK); end if;
         if OK then Line ("  shl bx, 1", OK); end if;
      end if;

      Success := OK;
   end Emit_Scale_BX_For_Size;

   -- ---------------------------------------------------------------
   -- Buffered append.
   -- The 16-bit backend keeps the same two-buffer shape as FASM:
   -- globals first, executable body second.
   -- ---------------------------------------------------------------
   procedure Append
     (Text    : String;
      Success : out Boolean)
   is
      Target_Len : Natural;
   begin
      if Current_Buffer = Buffer_Global then
         Target_Len := Global_Len;
      else
         Target_Len := Main_Len;
      end if;

      if Target_Len + Text'Length > Max_Buffer_Size then
         Success := False;
         return;
      end if;

      if Current_Buffer = Buffer_Global then
         Global_Buffer (Global_Len + 1 .. Global_Len + Text'Length) := Text;
         Global_Len := Global_Len + Text'Length;
      else
         Main_Buffer (Main_Len + 1 .. Main_Len + Text'Length) := Text;
         Main_Len := Main_Len + Text'Length;
      end if;

      Success := True;
   end Append;

   procedure Line
     (Text    : String;
      Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      Append (Text, OK);

      if OK then
         Append ((1 => Character'Val (10)), OK);
      end if;

      Success := OK;
   end Line;
   
   function FASM16_Call_Target (Text : String) return String is
      Prefix : constant String := "  call ";
   begin
      if Text'Length <= Prefix'Length then
         return "";
      end if;

      if Text (Text'First .. Text'First + Prefix'Length - 1) /= Prefix then
         return "";
      end if;

      declare
         Target : constant String :=
           Text (Text'First + Prefix'Length .. Text'Last);
      begin
         if Target = "ax" or else Target = "bx"
           or else Target = "cx" or else Target = "dx"
           or else Target = "si" or else Target = "di"
           or else Target = "bp" or else Target = "sp"
         then
            return "";
         end if;

         for I in Target'Range loop
            if Target (I) = ' '
              or else Target (I) = '['
              or else Target (I) = ']'
              or else Target (I) = ','
            then
               return "";
            end if;
         end loop;

         return Target;
      end;
   end FASM16_Call_Target;

   procedure Emit_Absolute_Near_Call
     (Target  : String;
      Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      if OK then Line ("  call " & Target, OK); end if;
      Success := OK;
   end Emit_Absolute_Near_Call;


   procedure Init_Emitter
     (Success : out Boolean)
   is
   begin
      Global_Len := 0;
      Main_Len   := 0;
      String_Counter  := 0;
      Native_Label_Counter := 0;
      Contract_Check_Counter := 0;
      Call_Pointer_Count := 0;
      Try_Counter := 0;
      Try_Depth := 0;

      Indent_Level    := 0;
      In_Global_Scope := True;

      Current_Buffer  := Buffer_Global;
      Current_Format  := Format_COM;
      Current_Profile := Profile_Tiny16;

      FASM16_Emitter_Ready := True;
      Success := True;
   end Init_Emitter;

   procedure Flush_To_File
     (File_Path : String;
      Success   : out Boolean)
   is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, File_Path);

      if Global_Len > 0 then
         Ada.Text_IO.Put (File, Global_Buffer (1 .. Global_Len));
      end if;

      if Main_Len > 0 then
         Ada.Text_IO.Put (File, Main_Buffer (1 .. Main_Len));
      end if;

      Ada.Text_IO.Close (File);
      Success := True;
   exception
      when others =>
         Success := False;
   end Flush_To_File;

   procedure Set_Active_Buffer
     (Target : Buffer_Target)
   is
   begin
      Current_Buffer := Target;

      if Target = Buffer_Global then
         In_Global_Scope := True;
      else
         In_Global_Scope := False;
      end if;
   end Set_Active_Buffer;

   procedure Set_Output_Format
     (Format : FASM16_Output_Format)
   is
   begin
      Current_Format := Format;
   end Set_Output_Format;

   procedure Emit_Program_Start
     (Program_Name : String;
      Success      : out Boolean)
   is
      OK : Boolean := True;
   begin
      Current_Buffer := Buffer_Global;

      Line ("; ==========================================================", OK);
      if OK then Line ("; GENERATED BY ADALOGIC BASIC (ALB) TRANSPILER", OK); end if;
      if OK then Line ("; TARGET: x86 16-bit FASM seed backend", OK); end if;
      if OK then Line ("; PROGRAM: " & Program_Name, OK); end if;
      if OK then Line ("; ----------------------------------------------------------", OK); end if;
      if OK then Line ("; NOTE:", OK); end if;
      if OK then Line (";   FASM remains the full ALB native profile.", OK); end if;
      if OK then Line (";   But this is subject to change over time and become a full backend.", OK); end if;
      if OK then Line (";   FASM16 starts as a tiny 8086 profile.", OK); end if;
      if OK then Line ("; ==========================================================", OK); end if;
      if OK then Line ("", OK); end if;

      case Current_Format is
         when Format_COM =>
            if OK then Line ("format binary", OK); end if;
            if OK then Line ("org 100h", OK); end if;
            if OK then Line ("use16", OK); end if;

         when Format_MZ_EXE =>
            if OK then Line ("format MZ", OK); end if;
            if OK then Line ("entry main:start", OK); end if;
            if OK then Line ("stack 100h", OK); end if;
            if OK then Line ("segment main", OK); end if;
            if OK then Line ("use16", OK); end if;

         when Format_Boot =>
            if OK then Line ("format binary", OK); end if;
            if OK then Line ("org 7C00h", OK); end if;
            if OK then Line ("use16", OK); end if;
      end case;

      if OK then Line ("", OK); end if;

      -- .COM programs begin executing at offset 100h. Static storage lives
      -- before the body, so binary-style formats jump over it explicitly.
      if Current_Format /= Format_MZ_EXE then
         if OK then Line ("jmp start", OK); end if;
         if OK then Line ("", OK); end if;
      end if;

      if OK then Line ("; --- Static storage follows ---", OK); end if;
      if OK then Line ("if used ALB16_Newline", OK); end if;
      if OK then Line ("ALB16_Newline db 13, 10, '$'", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_DivZero", OK); end if;
      if OK then Line ("ALB16_DivZero db 'ALB16 RUNTIME ERROR: divide or MOD by zero', 13, 10, '$'", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Bounds", OK); end if;
      if OK then Line ("ALB16_Bounds db 'ALB16 RUNTIME ERROR: array index out of bounds', 13, 10, '$'", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Range", OK); end if;
      if OK then Line ("ALB16_Range db 'ALB16 RUNTIME ERROR: value outside declared range', 13, 10, '$'", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("ALB16_Call_Target dw 0", OK); end if;
      
      if OK then Line ("ALB16_GC_Node_Alive  equ 0", OK); end if;
      if OK then Line ("ALB16_GC_Node_Refs   equ 1", OK); end if;
      if OK then Line ("ALB16_GC_Node_Child1 equ 2", OK); end if;
      if OK then Line ("ALB16_GC_Node_Child2 equ 4", OK); end if;
      if OK then Line ("ALB16_GC_Node_Size   equ 6", OK); end if;
      if OK then Line ("if used ALB16_GC_Grid", OK); end if;
      if OK then Line ("ALB16_GC_Grid rb ALB16_GC_Node_Size * 1025", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_GC_Cursor", OK); end if;
      if OK then Line ("ALB16_GC_Cursor dw 1", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("ALB16_Fact_HashLo equ 0", OK); end if;
      if OK then Line ("ALB16_Fact_HashHi equ 2", OK); end if;
      if OK then Line ("ALB16_Fact_ArgLo  equ 4", OK); end if;
      if OK then Line ("ALB16_Fact_ArgHi  equ 6", OK); end if;
      if OK then Line ("ALB16_Fact_ValLo  equ 8", OK); end if;
      if OK then Line ("ALB16_Fact_ValHi  equ 10", OK); end if;
      if OK then Line ("ALB16_Fact_Active equ 12", OK); end if;
      if OK then Line ("ALB16_Fact_Size   equ 13", OK); end if;
      if OK then Line ("if used ALB16_KB", OK); end if;
      if OK then Line ("ALB16_KB rb ALB16_Fact_Size * 1024", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Hash_OldLo", OK); end if;
      if OK then Line ("ALB16_Hash_OldLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Hash_OldHi", OK); end if;
      if OK then Line ("ALB16_Hash_OldHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_HashLo", OK); end if;
      if OK then Line ("ALB16_KB_HashLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_HashHi", OK); end if;
      if OK then Line ("ALB16_KB_HashHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_ArgLo", OK); end if;
      if OK then Line ("ALB16_KB_ArgLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_ArgHi", OK); end if;
      if OK then Line ("ALB16_KB_ArgHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_ValLo", OK); end if;
      if OK then Line ("ALB16_KB_ValLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_ValHi", OK); end if;
      if OK then Line ("ALB16_KB_ValHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_OutPtr", OK); end if;
      if OK then Line ("ALB16_KB_OutPtr dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_KB_Count", OK); end if;
      if OK then Line ("ALB16_KB_Count dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("if used ALB16_U32_DividendLo", OK); end if;
      if OK then Line ("ALB16_U32_DividendLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_U32_DividendHi", OK); end if;
      if OK then Line ("ALB16_U32_DividendHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_U32_DivisorLo", OK); end if;
      if OK then Line ("ALB16_U32_DivisorLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_U32_DivisorHi", OK); end if;
      if OK then Line ("ALB16_U32_DivisorHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_U32_QuotLo", OK); end if;
      if OK then Line ("ALB16_U32_QuotLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_U32_QuotHi", OK); end if;
      if OK then Line ("ALB16_U32_QuotHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_U32_RemLo", OK); end if;
      if OK then Line ("ALB16_U32_RemLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_U32_RemHi", OK); end if;
      if OK then Line ("ALB16_U32_RemHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Rnd_SeedLo", OK); end if;
      if OK then Line ("ALB16_Rnd_SeedLo dw 1", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Rnd_SeedHi", OK); end if;
      if OK then Line ("ALB16_Rnd_SeedHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("if used ALB16_Input_Buffer", OK); end if;
      if OK then Line ("ALB16_Input_Buffer db 126, 0, 127 dup (0)", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Line_Buffer", OK); end if;
      if OK then Line ("ALB16_Line_Buffer db 126, 0, 127 dup (0)", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("ALB16_Str_Max equ 4096", OK); end if;
      if OK then Line ("ALB16_Str_Safe_Limit equ 3840", OK); end if;
      if OK then Line ("ALB16_Str_Result_Max equ 255", OK); end if;
      if OK then Line ("if used ALB16_Str_Pool", OK); end if;
      if OK then Line ("ALB16_Str_Pool rb ALB16_Str_Max", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Str_Ptr", OK); end if;
      if OK then Line ("ALB16_Str_Ptr dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Str_Start", OK); end if;
      if OK then Line ("ALB16_Str_Start dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Str_Count", OK); end if;
      if OK then Line ("ALB16_Str_Count dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("ALB16_File_Buffer_Max equ 512", OK); end if;
      if OK then Line ("if used ALB16_File_Buffer", OK); end if;
      if OK then Line ("ALB16_File_Buffer rb ALB16_File_Buffer_Max", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_File_Byte", OK); end if;
      if OK then Line ("ALB16_File_Byte db 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_File_Handle", OK); end if;
      if OK then Line ("ALB16_File_Handle dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_File_Count", OK); end if;
      if OK then Line ("ALB16_File_Count dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Input_ValueLo", OK); end if;
      if OK then Line ("ALB16_Input_ValueLo dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Input_ValueHi", OK); end if;
      if OK then Line ("ALB16_Input_ValueHi dw 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Input_Digit", OK); end if;
      if OK then Line ("ALB16_Input_Digit db 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Input_Neg", OK); end if;
      if OK then Line ("ALB16_Input_Neg db 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Input_Seen", OK); end if;
      if OK then Line ("ALB16_Input_Seen db 0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Contract_REQUIRE", OK); end if;
      if OK then Line ("ALB16_Contract_REQUIRE db 'REQUIRE contract violation',0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("if used ALB16_Contract_ENSURE", OK); end if;
      if OK then Line ("ALB16_Contract_ENSURE db 'ENSURE contract violation',0", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("ALB16_TEMP_Future_Suppress_IO db 0", OK); end if;
      if OK then Line ("ALB16_GFX_Mode_Active db 0", OK); end if;
      if OK then Line ("ALB16_GFX_Current_Color db 15", OK); end if;
      if OK then Line ("ALB16_GFX_Clear_Color db 0", OK); end if;
      if OK then Line ("ALB_Screen_Width dw 320", OK); end if;
      if OK then Line ("ALB_Screen_Height dw 200", OK); end if;
      if OK then Line ("ALB_Virtual_Width dw 320", OK); end if;
      if OK then Line ("ALB_Virtual_Height dw 200", OK); end if;
      if OK then Line ("ALB16_PSP_Segment dw 0", OK); end if;
      if OK then Line ("ALB16_GFX_Framebuffer_Seg dw 0", OK); end if;
      if OK then Line ("ALB16_GFX_Speed_Mode db 0", OK); end if;
      if OK then Line ("ALB16_GFX_Double_Buffer db 1", OK); end if;
      if OK then Line ("ALB16_GFX_Alpha_Mode db 0", OK); end if;
      if OK then Line ("ALB16_GFX_Alpha_Value db 255", OK); end if;
      if OK then Line ("ALB16_GFX_Present_Wait db 1", OK); end if;
      if OK then Line ("ALB16_GFX_Frame_Dirty db 0", OK); end if;
      if OK then Line ("ALB16_Key_Down rb 128", OK); end if;
      if OK then Line ("ALB16_Key_Old_Off dw 0", OK); end if;
      if OK then Line ("ALB16_Key_Old_Seg dw 0", OK); end if;
      if OK then Line ("ALB16_Mouse_Present db 0", OK); end if;
      if OK then Line ("ALB16_Mouse_Buttons dw 0", OK); end if;
      if OK then Line ("ALB16_Mouse_Cursor_Shown db 0", OK); end if;
      if OK then Line ("ALB16_Mouse_Cursor_Points db 0,0, 0,1,1,1, 0,2,1,2,2,2, 0,3,1,3,2,3,3,3, 0,4,1,4,2,4, 0,5,2,5, 0,6,3,6, 255,255", OK); end if;
      if OK then Line ("ALB_Mouse_X dw 0", OK); end if;
      if OK then Line ("ALB_Mouse_Y dw 0", OK); end if;
      if OK then Line ("ALB_Mouse_Wheel dw 0", OK); end if;
      if OK then Line ("ALB_VMouse_X dw 0", OK); end if;
      if OK then Line ("ALB_VMouse_Y dw 0", OK); end if;
      if OK then Line ("ALB16_Font_Off dw 0", OK); end if;
      if OK then Line ("ALB16_Font_Seg dw 0", OK); end if;
      if OK then Line ("ALB16_Font_Height dw 8", OK); end if;
      if OK then Line ("ALB16_SDL_Letter_To_Set1 db 1Eh,30h,2Eh,20h,12h,21h,22h,23h,17h,24h,25h,26h,32h,31h,18h,19h,10h,13h,1Fh,14h,16h,2Fh,11h,2Dh,15h,2Ch", OK); end if;
      if OK then Line ("ALB16_Font5x7_Question db 0Eh,11h,01h,02h,04h,00h,04h", OK); end if;
      if OK then Line ("ALB16_Font5x7_Colon db 00h,04h,04h,00h,04h,04h,00h", OK); end if;
      if OK then Line ("ALB16_Font5x7_Dash db 00h,00h,00h,1Fh,00h,00h,00h", OK); end if;
      if OK then Line ("ALB16_Font5x7_Plus db 00h,04h,04h,1Fh,04h,04h,00h", OK); end if;
      if OK then Line ("ALB16_Font5x7_Star db 00h,11h,0Ah,04h,0Ah,11h,00h", OK); end if;
      if OK then Line ("ALB16_Font5x7_Slash db 01h,02h,04h,08h,10h,00h,00h", OK); end if;
      if OK then Line ("ALB16_Font5x7_Equals db 00h,1Fh,00h,1Fh,00h,00h,00h", OK); end if;
      if OK then Line ("ALB16_Font5x7_Digits:", OK); end if;
      if OK then Line ("  db 0Eh,11h,13h,15h,19h,11h,0Eh", OK); end if;
      if OK then Line ("  db 04h,0Ch,04h,04h,04h,04h,0Eh", OK); end if;
      if OK then Line ("  db 0Eh,11h,01h,02h,04h,08h,1Fh", OK); end if;
      if OK then Line ("  db 0Eh,11h,01h,06h,01h,11h,0Eh", OK); end if;
      if OK then Line ("  db 02h,06h,0Ah,12h,1Fh,02h,02h", OK); end if;
      if OK then Line ("  db 1Fh,10h,1Eh,01h,01h,11h,0Eh", OK); end if;
      if OK then Line ("  db 06h,08h,10h,1Eh,11h,11h,0Eh", OK); end if;
      if OK then Line ("  db 1Fh,01h,02h,04h,08h,08h,08h", OK); end if;
      if OK then Line ("  db 0Eh,11h,11h,0Eh,11h,11h,0Eh", OK); end if;
      if OK then Line ("  db 0Eh,11h,11h,0Fh,01h,02h,0Ch", OK); end if;
      if OK then Line ("ALB16_Font5x7_Letters:", OK); end if;
      if OK then Line ("  db 0Eh,11h,11h,1Fh,11h,11h,11h", OK); end if; -- A
      if OK then Line ("  db 1Eh,11h,11h,1Eh,11h,11h,1Eh", OK); end if; -- B
      if OK then Line ("  db 0Eh,11h,10h,10h,10h,11h,0Eh", OK); end if; -- C
      if OK then Line ("  db 1Ch,12h,11h,11h,11h,12h,1Ch", OK); end if; -- D
      if OK then Line ("  db 1Fh,10h,10h,1Eh,10h,10h,1Fh", OK); end if; -- E
      if OK then Line ("  db 1Fh,10h,10h,1Eh,10h,10h,10h", OK); end if; -- F
      if OK then Line ("  db 0Eh,11h,10h,10h,13h,11h,0Eh", OK); end if; -- G
      if OK then Line ("  db 11h,11h,11h,1Fh,11h,11h,11h", OK); end if; -- H
      if OK then Line ("  db 0Eh,04h,04h,04h,04h,04h,0Eh", OK); end if; -- I
      if OK then Line ("  db 01h,01h,01h,01h,11h,11h,0Eh", OK); end if; -- J
      if OK then Line ("  db 11h,12h,14h,18h,14h,12h,11h", OK); end if; -- K
      if OK then Line ("  db 10h,10h,10h,10h,10h,10h,1Fh", OK); end if; -- L
      if OK then Line ("  db 11h,1Bh,15h,15h,11h,11h,11h", OK); end if; -- M
      if OK then Line ("  db 11h,19h,15h,13h,11h,11h,11h", OK); end if; -- N
      if OK then Line ("  db 0Eh,11h,11h,11h,11h,11h,0Eh", OK); end if; -- O
      if OK then Line ("  db 1Eh,11h,11h,1Eh,10h,10h,10h", OK); end if; -- P
      if OK then Line ("  db 0Eh,11h,11h,11h,15h,12h,0Dh", OK); end if; -- Q
      if OK then Line ("  db 1Eh,11h,11h,1Eh,14h,12h,11h", OK); end if; -- R
      if OK then Line ("  db 0Fh,10h,10h,0Eh,01h,01h,1Eh", OK); end if; -- S
      if OK then Line ("  db 1Fh,04h,04h,04h,04h,04h,04h", OK); end if; -- T
      if OK then Line ("  db 11h,11h,11h,11h,11h,11h,0Eh", OK); end if; -- U
      if OK then Line ("  db 11h,11h,11h,11h,11h,0Ah,04h", OK); end if; -- V
      if OK then Line ("  db 11h,11h,11h,15h,15h,15h,0Ah", OK); end if; -- W
      if OK then Line ("  db 11h,11h,0Ah,04h,0Ah,11h,11h", OK); end if; -- X
      if OK then Line ("  db 11h,11h,0Ah,04h,04h,04h,04h", OK); end if; -- Y
      if OK then Line ("  db 1Fh,01h,02h,04h,08h,10h,1Fh", OK); end if; -- Z

      if OK then Line ("", OK); end if;
      if OK then Emit_Runtime_Trap_Handlers (OK); end if;
      if OK then Line ("", OK); end if;

      Current_Buffer := Buffer_Main;

      if OK then Line ("; --- Program body ---", OK); end if;
      if OK then Line ("start:", OK); end if;
     -- if Current_Format = Format_MZ_EXE then
     --    if OK then Line ("  push cs", OK); end if;
     ---    if OK then Line ("  pop ds", OK); end if;
     --- end if;
      if Current_Format = Format_MZ_EXE then
         if OK then Line ("  mov ax, ds", OK); end if;
         if OK then Line ("  push cs", OK); end if;
         if OK then Line ("  pop ds", OK); end if;
         if OK then Line ("  mov [ALB16_PSP_Segment], ax", OK); end if;
      end if;

      Indent_Level := 1;
      Success := OK;
   end Emit_Program_Start;

   procedure Emit_Program_End
     (Success : out Boolean)
   is
      OK : Boolean := True;
      
        
      --  procedure RL (Text : String) is
      --  begin
      --     if OK then
      --        Line (Text, OK);
      --     end if;
      --  end RL;
      procedure RL (Text : String) is
      begin
         if OK then
            Line (Text, OK);
         end if;
      end RL;

      procedure Trap_Jcc (Cond : String; Trap : String) is
      begin
         if OK then
            Emit_Long_Trap_Jcc (Cond, Trap, OK);
         end if;
      end Trap_Jcc;
      
      
   begin
      Current_Buffer := Buffer_Main;

      Line ("", OK);
      if OK then Line ("; --- FASM16 program exit ---", OK); end if;

      case Current_Format is
         when Format_COM | Format_MZ_EXE =>
            if OK then Line ("  jmp ALB16_Exit_Program", OK); end if;

         when Format_Boot =>
            if OK then Line (".hang:", OK); end if;
            if OK then Line ("  jmp .hang", OK); end if;
            if OK then Line ("times 510-($-$$) db 0", OK); end if;
            if OK then Line ("dw 0AA55h", OK); end if;
      end case;

      if OK then Line ("", OK); end if;
      Current_Buffer := Buffer_Global;
      if OK then Line ("; --- FASM16 tiny DOS runtime ---", OK); end if;
      if OK then Line ("ALB16_Exit_Program:", OK); end if;
      if OK then Line ("  call ALB16_GFX_Shutdown", OK); end if;
      case Current_Format is
         when Format_COM | Format_MZ_EXE =>
            if OK then Line ("  mov ax, 4C00h", OK); end if;
            if OK then Line ("  int 21h", OK); end if;

         when Format_Boot =>
            if OK then Line (".hang:", OK); end if;
            if OK then Line ("  jmp .hang", OK); end if;
      end case;
      if OK then Line ("", OK); end if;

      -- Prints the shared CR/LF DOS string.
      if OK then Line ("if used ALB16_Print_Newline", OK); end if;
      if OK then Line ("ALB16_Print_Newline:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  mov dx, ALB16_Newline", OK); end if;
      if OK then Line ("  mov ah, 09h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB_CEASE", OK); end if;
      if OK then Line ("ALB_CEASE:", OK); end if;
      if OK then Line ("  cmp byte [ALB16_TEMP_Future_Suppress_IO], 0", OK); end if;
      if OK then Line ("  jne .done", OK); end if;
      if OK then Line ("  jmp ALB16_Exit_Program", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      -- Prints a normal ALB NUL-terminated string, including literal '$'.
      if OK then Line ("if used ALB16_Print_C_Str", OK); end if;
      if OK then Line ("ALB16_Print_C_Str:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  mov si, dx", OK); end if;
      if OK then Line (".alb16_print_c_str_loop:", OK); end if;
      if OK then Line ("  cmp si, 0", OK); end if;
      if OK then Line ("  je .alb16_print_c_str_done", OK); end if;
      if OK then Line ("  mov dl, byte [si]", OK); end if;
      if OK then Line ("  cmp dl, 0", OK); end if;
      if OK then Line ("  je .alb16_print_c_str_done", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  inc si", OK); end if;
      if OK then Line ("  jmp .alb16_print_c_str_loop", OK); end if;
      if OK then Line (".alb16_print_c_str_done:", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Copy_Bytes", OK); end if;
      if OK then Line ("ALB16_Copy_Bytes:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  test cx, cx", OK); end if;
      if OK then Line ("  jz .alb16_copy_done", OK); end if;
      if OK then Line (".alb16_copy_loop:", OK); end if;
      if OK then Line ("  mov al, byte [si]", OK); end if;
      if OK then Line ("  mov byte [di], al", OK); end if;
      if OK then Line ("  inc si", OK); end if;
      if OK then Line ("  inc di", OK); end if;
      if OK then Line ("  dec cx", OK); end if;
      if OK then Line ("  jnz .alb16_copy_loop", OK); end if;
      if OK then Line (".alb16_copy_done:", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Delay", OK); end if;
      if OK then Line ("ALB16_Delay:", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  cmp ax, 0", OK); end if;
      if OK then Line ("  jne .alb16_delay_have_time", OK); end if;
      if OK then Line ("  cmp dx, 0", OK); end if;
      if OK then Line ("  je .alb16_delay_done", OK); end if;
      if OK then Line (".alb16_delay_have_time:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  mov bx, 1000", OK); end if;
      if OK then Line ("  xor cx, cx", OK); end if;
      if OK then Line ("  call ALB16_U32_Mul", OK); end if;
      if OK then Line ("  mov cx, dx", OK); end if;
      if OK then Line ("  mov dx, ax", OK); end if;
      if OK then Line ("  mov ax, 8600h", OK); end if;
      if OK then Line ("  int 15h", OK); end if;
      if OK then Line ("  jnc .alb16_delay_int15_done", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  mov bx, 55", OK); end if;
      if OK then Line ("  xor cx, cx", OK); end if;
      if OK then Line ("  call ALB16_U32_DivCore", OK); end if;
      if OK then Line ("  mov si, word [ALB16_U32_QuotLo]", OK); end if;
      if OK then Line ("  mov di, word [ALB16_U32_QuotHi]", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_RemLo]", OK); end if;
      if OK then Line ("  or ax, word [ALB16_U32_RemHi]", OK); end if;
      if OK then Line ("  jz .alb16_delay_ticks_ready", OK); end if;
      if OK then Line ("  inc si", OK); end if;
      if OK then Line ("  jnz .alb16_delay_ticks_ready", OK); end if;
      if OK then Line ("  inc di", OK); end if;
      if OK then Line (".alb16_delay_ticks_ready:", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  or ax, di", OK); end if;
      if OK then Line ("  jnz .alb16_delay_ticks_nonzero", OK); end if;
      if OK then Line ("  mov si, 1", OK); end if;
      if OK then Line (".alb16_delay_ticks_nonzero:", OK); end if;
      if OK then Line ("  push ds", OK); end if;
      if OK then Line ("  mov bx, 40h", OK); end if;
      if OK then Line ("  mov ds, bx", OK); end if;
      if OK then Line ("  mov bx, word [006Ch]", OK); end if;
      if OK then Line ("  mov cx, word [006Eh]", OK); end if;
      if OK then Line ("  pop ds", OK); end if;
      if OK then Line (".alb16_delay_wait:", OK); end if;
      if OK then Line ("  push ds", OK); end if;
      if OK then Line ("  mov ax, 40h", OK); end if;
      if OK then Line ("  mov ds, ax", OK); end if;
      if OK then Line ("  mov ax, word [006Ch]", OK); end if;
      if OK then Line ("  mov dx, word [006Eh]", OK); end if;
      if OK then Line ("  pop ds", OK); end if;
      if OK then Line ("  sub ax, bx", OK); end if;
      if OK then Line ("  sbb dx, cx", OK); end if;
      if OK then Line ("  cmp dx, di", OK); end if;
      if OK then Line ("  ja .alb16_delay_done", OK); end if;
      if OK then Line ("  jb .alb16_delay_wait", OK); end if;
      if OK then Line ("  cmp ax, si", OK); end if;
      if OK then Line ("  jb .alb16_delay_wait", OK); end if;
      if OK then Line ("  jmp .alb16_delay_done", OK); end if;
      if OK then Line (".alb16_delay_int15_done:", OK); end if;
      if OK then Line ("  add sp, 4", OK); end if;
      if OK then Line (".alb16_delay_done:", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      -- Lean PC-speaker beep for PLAY SOUND (path unused; FASM16 has no WAV).
      if OK then Line ("if used ALB16_Play_Sound", OK); end if;
      if OK then Line ("ALB16_Play_Sound:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  mov al, 0B6h", OK); end if;
      if OK then Line ("  out 43h, al", OK); end if;
      if OK then Line ("  mov ax, 0A9Eh", OK); end if;  -- ~440 Hz divisor
      if OK then Line ("  out 42h, al", OK); end if;
      if OK then Line ("  mov al, ah", OK); end if;
      if OK then Line ("  out 42h, al", OK); end if;
      if OK then Line ("  in al, 61h", OK); end if;
      if OK then Line ("  or al, 3", OK); end if;
      if OK then Line ("  out 61h, al", OK); end if;
      if OK then Line ("  mov ax, 2", OK); end if;       -- ~2 timer ticks
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  call ALB16_Delay", OK); end if;
      if OK then Line ("  in al, 61h", OK); end if;
      if OK then Line ("  and al, 0FCh", OK); end if;
      if OK then Line ("  out 61h, al", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Play_Music_Score", OK); end if;
      if OK then Line ("ALB16_Play_Music_Score:", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  jcxz .alb16_music_finish", OK); end if;
      if OK then Line (".alb16_music_loop:", OK); end if;
      if OK then Line ("  mov bx, word [si]", OK); end if;
      if OK then Line ("  mov ax, word [si + 2]", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  or bx, bx", OK); end if;
      if OK then Line ("  jz .alb16_music_rest", OK); end if;
      if OK then Line ("  mov al, 0B6h", OK); end if;
      if OK then Line ("  out 43h, al", OK); end if;
      if OK then Line ("  mov ax, bx", OK); end if;
      if OK then Line ("  out 42h, al", OK); end if;
      if OK then Line ("  mov al, ah", OK); end if;
      if OK then Line ("  out 42h, al", OK); end if;
      if OK then Line ("  in al, 61h", OK); end if;
      if OK then Line ("  or al, 3", OK); end if;
      if OK then Line ("  out 61h, al", OK); end if;
      if OK then Line ("  jmp .alb16_music_hold", OK); end if;
      if OK then Line (".alb16_music_rest:", OK); end if;
      if OK then Line ("  in al, 61h", OK); end if;
      if OK then Line ("  and al, 0FCh", OK); end if;
      if OK then Line ("  out 61h, al", OK); end if;
      if OK then Line (".alb16_music_hold:", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  add ax, 54", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  mov bx, 55", OK); end if;
      if OK then Line ("  div bx", OK); end if;
      if OK then Line ("  or ax, ax", OK); end if;
      if OK then Line ("  jnz .alb16_music_ticks_ready", OK); end if;
      if OK then Line ("  mov ax, 1", OK); end if;
      if OK then Line (".alb16_music_ticks_ready:", OK); end if;
      if OK then Line ("  mov bx, ax", OK); end if;
      if OK then Line ("  push ds", OK); end if;
      if OK then Line ("  mov ax, 40h", OK); end if;
      if OK then Line ("  mov ds, ax", OK); end if;
      if OK then Line ("  mov dx, word [006Ch]", OK); end if;
      if OK then Line (".alb16_music_wait:", OK); end if;
      if OK then Line ("  mov ax, word [006Ch]", OK); end if;
      if OK then Line ("  sub ax, dx", OK); end if;
      if OK then Line ("  cmp ax, bx", OK); end if;
      if OK then Line ("  jb .alb16_music_wait", OK); end if;
      if OK then Line ("  pop ds", OK); end if;
      if OK then Line (".alb16_music_next:", OK); end if;
      if OK then Line ("  add si, 4", OK); end if;
      if OK then Line ("  loop .alb16_music_loop", OK); end if;
      if OK then Line (".alb16_music_finish:", OK); end if;
      if OK then Line ("  in al, 61h", OK); end if;
      if OK then Line ("  and al, 0FCh", OK); end if;
      if OK then Line ("  out 61h, al", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Sqrt_U32", OK); end if;
      if OK then Line ("ALB16_Sqrt_U32:", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov di, dx", OK); end if;
      if OK then Line ("  xor bx, bx", OK); end if;
      if OK then Line (".alb16_sqrt_try:", OK); end if;
      if OK then Line ("  mov cx, bx", OK); end if;
      if OK then Line ("  inc cx", OK); end if;
      if OK then Line ("  mov ax, cx", OK); end if;
      if OK then Line ("  mul cx", OK); end if;
      if OK then Line ("  cmp dx, di", OK); end if;
      if OK then Line ("  ja .alb16_sqrt_done", OK); end if;
      if OK then Line ("  jb .alb16_sqrt_accept", OK); end if;
      if OK then Line ("  cmp ax, si", OK); end if;
      if OK then Line ("  ja .alb16_sqrt_done", OK); end if;
      if OK then Line (".alb16_sqrt_accept:", OK); end if;
      if OK then Line ("  inc bx", OK); end if;
      if OK then Line ("  jmp .alb16_sqrt_try", OK); end if;
      if OK then Line (".alb16_sqrt_done:", OK); end if;
      if OK then Line ("  mov ax, bx", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Rnd", OK); end if;
      if OK then Line ("ALB16_Rnd:", OK); end if;
      if OK then Line ("  push bp", OK); end if;
      if OK then Line ("  mov bp, sp", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  mov bx, [bp+4]", OK); end if;
      if OK then Line ("  mov cx, [bp+6]", OK); end if;
      if OK then Line ("  or bx, cx", OK); end if;
      if OK then Line ("  jne .alb16_rnd_have_max", OK); end if;
      if OK then Line ("  xor ax, ax", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  jmp .alb16_rnd_done", OK); end if;
      if OK then Line (".alb16_rnd_have_max:", OK); end if;
      if OK then Line ("  push ds", OK); end if;
      if OK then Line ("  mov si, 40h", OK); end if;
      if OK then Line ("  mov ds, si", OK); end if;
      if OK then Line ("  mov ax, word [006Ch]", OK); end if;
      if OK then Line ("  mov dx, word [006Eh]", OK); end if;
      if OK then Line ("  pop ds", OK); end if;
      if OK then Line ("  add ax, word [ALB16_Rnd_SeedLo]", OK); end if;
      if OK then Line ("  adc dx, word [ALB16_Rnd_SeedHi]", OK); end if;
      if OK then Line ("  add ax, 0A361h", OK); end if;
      if OK then Line ("  adc dx, 03C6Eh", OK); end if;
      if OK then Line ("  mov word [ALB16_Rnd_SeedLo], ax", OK); end if;
      if OK then Line ("  mov word [ALB16_Rnd_SeedHi], dx", OK); end if;
      if OK then Line ("  call ALB16_U32_DivCore", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_RemLo]", OK); end if;
      if OK then Line ("  mov dx, word [ALB16_U32_RemHi]", OK); end if;
      if OK then Line (".alb16_rnd_done:", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  mov sp, bp", OK); end if;
      if OK then Line ("  pop bp", OK); end if;
      if OK then Line ("  ret 4", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB_Locate", OK); end if;
      if OK then Line ("ALB_Locate:", OK); end if;
      if OK then Line ("  push bp", OK); end if;
      if OK then Line ("  mov bp, sp", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  mov dl, byte [bp+4]", OK); end if;
      if OK then Line ("  mov dh, byte [bp+6]", OK); end if;
      if OK then Line ("  cmp dl, 0", OK); end if;
      if OK then Line ("  je .alb16_locate_col_ready", OK); end if;
      if OK then Line ("  dec dl", OK); end if;
      if OK then Line (".alb16_locate_col_ready:", OK); end if;
      if OK then Line ("  cmp dh, 0", OK); end if;
      if OK then Line ("  je .alb16_locate_row_ready", OK); end if;
      if OK then Line ("  dec dh", OK); end if;
      if OK then Line (".alb16_locate_row_ready:", OK); end if;
      if OK then Line ("  xor bx, bx", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 10h", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  mov sp, bp", OK); end if;
      if OK then Line ("  pop bp", OK); end if;
      if OK then Line ("  ret 4", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      RL ("ALB16_Int09_Handler:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push ds");
      RL ("  push cs");
      RL ("  pop ds");
      RL ("  in al, 60h");
      RL ("  xor bx, bx");
      RL ("  mov bl, al");
      RL ("  cmp al, 0E0h");
      RL ("  je .ack");
      RL ("  cmp al, 0E1h");
      RL ("  je .ack");
      RL ("  and bl, 7Fh");
      RL ("  cmp bl, 80h");
      RL ("  jae .ack");
      RL ("  test al, 80h");
      RL ("  jnz .release");
      RL ("  mov byte [ALB16_Key_Down+bx], 1");
      RL ("  jmp .ack");
      RL (".release:");
      RL ("  mov byte [ALB16_Key_Down+bx], 0");
      RL (".ack:");
      RL ("  in al, 61h");
      RL ("  mov ah, al");
      RL ("  or al, 80h");
      RL ("  out 61h, al");
      RL ("  mov al, ah");
      RL ("  out 61h, al");
      RL ("  mov al, 20h");
      RL ("  out 20h, al");
      RL ("  pop ds");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  iret");
      RL ("");

      RL ("ALB16_Input_Init:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push di");
      RL ("  push bp");
      RL ("  push ds");
      RL ("  push es");
      RL ("  push cs");
      RL ("  pop ds");
      RL ("  mov ax, ds");
      RL ("  mov es, ax");
      RL ("  lea di, [ALB16_Key_Down]");
      RL ("  xor ax, ax");
      RL ("  mov cx, 128");
      RL ("  cld");
      RL ("  rep stosb");
      RL ("  mov word [ALB16_Mouse_Buttons], 0");
      RL ("  mov word [ALB_Mouse_X], 0");
      RL ("  mov word [ALB_Mouse_Y], 0");
      RL ("  mov word [ALB_VMouse_X], 0");
      RL ("  mov word [ALB_VMouse_Y], 0");
      RL ("  mov byte [ALB16_Mouse_Present], 0");
      RL ("  mov byte [ALB16_Mouse_Cursor_Shown], 0");
      RL ("  mov ax, 3509h");
      RL ("  int 21h");
      RL ("  mov word [ALB16_Key_Old_Off], bx");
      RL ("  mov word [ALB16_Key_Old_Seg], es");
      RL ("  mov dx, ALB16_Int09_Handler");
      RL ("  mov ax, 2509h");
      RL ("  int 21h");
      RL ("  xor ax, ax");
      RL ("  int 33h");
      RL ("  or ax, ax");
      RL ("  jz .font");
      RL ("  mov byte [ALB16_Mouse_Present], 1");
      RL ("  mov ax, 7");
      RL ("  xor cx, cx");
      RL ("  mov dx, word [ALB_Screen_Width]");
      RL ("  shl dx, 1");
      RL ("  dec dx");
      RL ("  int 33h");
      RL ("  mov ax, 8");
      RL ("  xor cx, cx");
      RL ("  mov dx, word [ALB_Screen_Height]");
      RL ("  dec dx");
      RL ("  int 33h");
      RL (".font:");
      RL ("  mov ax, 1130h");
      RL ("  mov bh, 03h");
      RL ("  int 10h");
      RL ("  mov word [ALB16_Font_Seg], es");
      RL ("  mov word [ALB16_Font_Off], bp");
      RL ("  or cx, cx");
      RL ("  jnz .font_height_ok");
      RL ("  mov cx, 8");
      RL (".font_height_ok:");
      RL ("  mov word [ALB16_Font_Height], cx");
      RL ("  pop es");
      RL ("  pop ds");
      RL ("  pop bp");
      RL ("  pop di");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_Input_Shutdown:");
      RL ("  push ax");
      RL ("  push dx");
      RL ("  push ds");
      RL ("  cmp word [ALB16_Key_Old_Seg], 0");
      RL ("  je .mouse");
      RL ("  mov dx, word [ALB16_Key_Old_Off]");
      RL ("  mov ax, word [ALB16_Key_Old_Seg]");
      RL ("  mov ds, ax");
      RL ("  mov ax, 2509h");
      RL ("  int 21h");
      RL ("  push cs");
      RL ("  pop ds");
      RL ("  mov word [ALB16_Key_Old_Off], 0");
      RL ("  mov word [ALB16_Key_Old_Seg], 0");
      RL (".mouse:");
      RL ("  cmp byte [ALB16_Mouse_Present], 0");
      RL ("  je .done");
      RL ("  call ALB16_Mouse_Show_Cursor");
      RL (".done:");
      RL ("  pop ds");
      RL ("  pop dx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_Input_Update:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  cmp byte [ALB16_Mouse_Present], 0");
      RL ("  je .no_mouse");
      RL ("  mov ax, 3");
      RL ("  int 33h");
      RL ("  mov word [ALB16_Mouse_Buttons], bx");
      RL ("  mov ax, cx");
      RL ("  shr ax, 1");
      RL ("  mov word [ALB_Mouse_X], ax");
      RL ("  mov word [ALB_Mouse_Y], dx");
      RL ("  mov ax, word [ALB_Mouse_X]");
      RL ("  mul word [ALB_Virtual_Width]");
      RL ("  mov bx, word [ALB_Screen_Width]");
      RL ("  div bx");
      RL ("  mov word [ALB_VMouse_X], ax");
      RL ("  mov ax, word [ALB_Mouse_Y]");
      RL ("  mul word [ALB_Virtual_Height]");
      RL ("  mov bx, word [ALB_Screen_Height]");
      RL ("  div bx");
      RL ("  mov word [ALB_VMouse_Y], ax");
      RL ("  jmp .done");
      RL (".no_mouse:");
      RL ("  mov word [ALB16_Mouse_Buttons], 0");
      RL ("  mov word [ALB_Mouse_X], 0");
      RL ("  mov word [ALB_Mouse_Y], 0");
      RL ("  mov word [ALB_VMouse_X], 0");
      RL ("  mov word [ALB_VMouse_Y], 0");
      RL (".done:");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_Mouse_Show_Cursor:");
      RL ("  push ax");
      RL ("  cmp byte [ALB16_Mouse_Present], 0");
      RL ("  je .done");
      RL ("  cmp byte [ALB16_Mouse_Cursor_Shown], 0");
      RL ("  jne .done");
      RL ("  mov ax, 1");
      RL ("  int 33h");
      RL ("  mov byte [ALB16_Mouse_Cursor_Shown], 1");
      RL (".done:");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_Mouse_Hide_Cursor:");
      RL ("  push ax");
      RL ("  cmp byte [ALB16_Mouse_Present], 0");
      RL ("  je .done");
      RL ("  cmp byte [ALB16_Mouse_Cursor_Shown], 0");
      RL ("  je .done");
      RL ("  mov ax, 2");
      RL ("  int 33h");
      RL ("  mov byte [ALB16_Mouse_Cursor_Shown], 0");
      RL (".done:");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_Mouse_Draw_Cursor:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  push ds");
      RL ("  cmp byte [ALB16_Mouse_Present], 0");
      RL ("  je .done");
      RL ("  push cs");
      RL ("  pop ds");
      RL ("  xor ah, ah");
      RL ("  mov al, byte [ALB16_GFX_Current_Color]");
      RL ("  push ax");
      RL ("  xor ah, ah");
      RL ("  mov al, byte [ALB16_GFX_Alpha_Mode]");
      RL ("  push ax");
      RL ("  xor ah, ah");
      RL ("  mov al, byte [ALB16_GFX_Alpha_Value]");
      RL ("  push ax");
      RL ("  mov byte [ALB16_GFX_Current_Color], 255");
      RL ("  mov byte [ALB16_GFX_Alpha_Mode], 0");
      RL ("  mov byte [ALB16_GFX_Alpha_Value], 255");
      RL ("  mov si, ALB16_Mouse_Cursor_Points");
      RL (".plot_loop:");
      RL ("  lodsb");
      RL ("  cmp al, 255");
      RL ("  je .restore");
      RL ("  xor ah, ah");
      RL ("  mov bx, ax");
      RL ("  lodsb");
      RL ("  xor ah, ah");
      RL ("  mov cx, ax");
      RL ("  mov ax, word [ALB_Mouse_X]");
      RL ("  add ax, bx");
      RL ("  mov dx, word [ALB_Mouse_Y]");
      RL ("  add dx, cx");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  jmp .plot_loop");
      RL (".restore:");
      RL ("  pop ax");
      RL ("  mov byte [ALB16_GFX_Alpha_Value], al");
      RL ("  pop ax");
      RL ("  mov byte [ALB16_GFX_Alpha_Mode], al");
      RL ("  pop ax");
      RL ("  mov byte [ALB16_GFX_Current_Color], al");
      RL (".done:");
      RL ("  pop ds");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_Map_SDL_Key_AX:");
      RL ("  cmp ax, 4");
      RL ("  jb .check_digits");
      RL ("  cmp ax, 29");
      RL ("  jbe .letters");
      RL (".check_digits:");
      RL ("  cmp ax, 30");
      RL ("  jb .check_fkeys");
      RL ("  cmp ax, 39");
      RL ("  jbe .digits");
      RL (".check_fkeys:");
      RL ("  cmp ax, 58");
      RL ("  jb .special");
      RL ("  cmp ax, 69");
      RL ("  jbe .fkeys");
      RL (".special:");
      RL ("  cmp ax, 40");
      RL ("  je .ret_enter");
      RL ("  cmp ax, 41");
      RL ("  je .ret_escape");
      RL ("  cmp ax, 42");
      RL ("  je .ret_backspace");
      RL ("  cmp ax, 43");
      RL ("  je .ret_tab");
      RL ("  cmp ax, 44");
      RL ("  je .ret_space");
      RL ("  cmp ax, 45");
      RL ("  je .ret_minus");
      RL ("  cmp ax, 46");
      RL ("  je .ret_equals");
      RL ("  cmp ax, 47");
      RL ("  je .ret_lbracket");
      RL ("  cmp ax, 48");
      RL ("  je .ret_rbracket");
      RL ("  cmp ax, 49");
      RL ("  je .ret_backslash");
      RL ("  cmp ax, 51");
      RL ("  je .ret_semicolon");
      RL ("  cmp ax, 52");
      RL ("  je .ret_apostrophe");
      RL ("  cmp ax, 53");
      RL ("  je .ret_grave");
      RL ("  cmp ax, 54");
      RL ("  je .ret_comma");
      RL ("  cmp ax, 55");
      RL ("  je .ret_period");
      RL ("  cmp ax, 56");
      RL ("  je .ret_slash");
      RL ("  cmp ax, 57");
      RL ("  je .ret_caps");
      RL ("  cmp ax, 79");
      RL ("  je .ret_right");
      RL ("  cmp ax, 80");
      RL ("  je .ret_left");
      RL ("  cmp ax, 81");
      RL ("  je .ret_down");
      RL ("  cmp ax, 82");
      RL ("  je .ret_up");
      RL ("  cmp ax, 224");
      RL ("  je .ret_lctrl");
      RL ("  cmp ax, 225");
      RL ("  je .ret_lshift");
      RL ("  cmp ax, 226");
      RL ("  je .ret_lalt");
      RL ("  cmp ax, 228");
      RL ("  je .ret_lctrl");
      RL ("  cmp ax, 229");
      RL ("  je .ret_rshift");
      RL ("  cmp ax, 230");
      RL ("  je .ret_lalt");
      RL ("  mov bx, 0FFFFh");
      RL ("  ret");
      RL (".letters:");
      RL ("  sub ax, 4");
      RL ("  mov bx, ax");
      RL ("  mov bl, byte [ALB16_SDL_Letter_To_Set1+bx]");
      RL ("  xor bh, bh");
      RL ("  ret");
      RL (".digits:");
      RL ("  mov bx, ax");
      RL ("  sub bx, 28");
      RL ("  ret");
      RL (".fkeys:");
      RL ("  mov bx, ax");
      RL ("  inc bx");
      RL ("  ret");
      RL (".ret_enter:");
      RL ("  mov bx, 1Ch");
      RL ("  ret");
      RL (".ret_escape:");
      RL ("  mov bx, 01h");
      RL ("  ret");
      RL (".ret_backspace:");
      RL ("  mov bx, 0Eh");
      RL ("  ret");
      RL (".ret_tab:");
      RL ("  mov bx, 0Fh");
      RL ("  ret");
      RL (".ret_space:");
      RL ("  mov bx, 39h");
      RL ("  ret");
      RL (".ret_minus:");
      RL ("  mov bx, 0Ch");
      RL ("  ret");
      RL (".ret_equals:");
      RL ("  mov bx, 0Dh");
      RL ("  ret");
      RL (".ret_lbracket:");
      RL ("  mov bx, 1Ah");
      RL ("  ret");
      RL (".ret_rbracket:");
      RL ("  mov bx, 1Bh");
      RL ("  ret");
      RL (".ret_backslash:");
      RL ("  mov bx, 2Bh");
      RL ("  ret");
      RL (".ret_semicolon:");
      RL ("  mov bx, 27h");
      RL ("  ret");
      RL (".ret_apostrophe:");
      RL ("  mov bx, 28h");
      RL ("  ret");
      RL (".ret_grave:");
      RL ("  mov bx, 29h");
      RL ("  ret");
      RL (".ret_comma:");
      RL ("  mov bx, 33h");
      RL ("  ret");
      RL (".ret_period:");
      RL ("  mov bx, 34h");
      RL ("  ret");
      RL (".ret_slash:");
      RL ("  mov bx, 35h");
      RL ("  ret");
      RL (".ret_caps:");
      RL ("  mov bx, 3Ah");
      RL ("  ret");
      RL (".ret_right:");
      RL ("  mov bx, 4Dh");
      RL ("  ret");
      RL (".ret_left:");
      RL ("  mov bx, 4Bh");
      RL ("  ret");
      RL (".ret_down:");
      RL ("  mov bx, 50h");
      RL ("  ret");
      RL (".ret_up:");
      RL ("  mov bx, 48h");
      RL ("  ret");
      RL (".ret_lctrl:");
      RL ("  mov bx, 1Dh");
      RL ("  ret");
      RL (".ret_lshift:");
      RL ("  mov bx, 2Ah");
      RL ("  ret");
      RL (".ret_rshift:");
      RL ("  mov bx, 36h");
      RL ("  ret");
      RL (".ret_lalt:");
      RL ("  mov bx, 38h");
      RL ("  ret");
      RL ("");

      RL ("ALB_Key_State:");
      RL ("  push bx");
      RL ("  call ALB16_Map_SDL_Key_AX");
      RL ("  cmp bx, 0FFFFh");
      RL ("  je .zero");
      RL ("  cmp bx, 128");
      RL ("  jae .zero");
      RL ("  xor ax, ax");
      RL ("  mov al, byte [ALB16_Key_Down+bx]");
      RL ("  xor dx, dx");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  mov ax, 1");
      RL ("  jmp .done");
      RL (".zero:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".done:");
      RL ("  pop bx");
      RL ("  ret");
      RL ("");

      RL ("ALB_Mouse_Click_State:");
      RL ("  push bx");
      RL ("  mov bx, word [ALB16_Mouse_Buttons]");
      RL ("  cmp ax, 0");
      RL ("  je .left");
      RL ("  cmp ax, 1");
      RL ("  je .middle");
      RL ("  cmp ax, 2");
      RL ("  je .right");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL ("  jmp .done");
      RL (".left:");
      RL ("  test bl, 01h");
      RL ("  jz .zero");
      RL ("  mov ax, 1");
      RL ("  xor dx, dx");
      RL ("  jmp .done");
      RL (".middle:");
      RL ("  test bl, 04h");
      RL ("  jz .zero");
      RL ("  mov ax, 1");
      RL ("  xor dx, dx");
      RL ("  jmp .done");
      RL (".right:");
      RL ("  test bl, 02h");
      RL ("  jz .zero");
      RL ("  mov ax, 1");
      RL ("  xor dx, dx");
      RL ("  jmp .done");
      RL (".zero:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".done:");
      RL ("  pop bx");
      RL ("  ret");
      RL ("");

      RL ("ALB_Set_Alpha:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  mov ax, [bp+4]");
      RL ("  or ax, ax");
      RL ("  jz .disable");
      RL ("  mov ax, [bp+8]");
      RL ("  cmp ax, 255");
      RL ("  jbe .store");
      RL ("  mov ax, 255");
      RL (".store:");
      RL ("  mov byte [ALB16_GFX_Alpha_Mode], 1");
      RL ("  mov byte [ALB16_GFX_Alpha_Value], al");
      RL ("  jmp .done");
      RL (".disable:");
      RL ("  mov byte [ALB16_GFX_Alpha_Mode], 0");
      RL ("  mov byte [ALB16_GFX_Alpha_Value], 255");
      RL (".done:");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 8");
      RL ("");

      RL ("ALB16_GFX_Ensure_Buffer:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push dx");
      RL ("  push es");
      RL ("  cmp word [ALB16_GFX_Framebuffer_Seg], 0");
      RL ("  jne .done");
      RL ("  cmp byte [ALB16_GFX_Speed_Mode], 0");
      RL ("  jne .use_vram");
      RL ("  cmp byte [ALB16_GFX_Double_Buffer], 0");
      RL ("  je .use_vram");
      RL ("  mov dx, [ALB16_PSP_Segment]");
      RL ("  or dx, dx");
      RL ("  jz .fallback_vram");
      RL ("  mov es, dx");
      RL ("  mov bx, word [es:2]");
      RL ("  mov ax, cs");
      RL ("  add ax, ((ALB16_Final_End_Of_Image + 15) / 16) + 512");
      RL ("  mov cx, ss");
      RL ("  add cx, 512");
      RL ("  cmp ax, cx");
      RL ("  jae .keep_top_ready");
      RL ("  mov ax, cx");
      RL (".keep_top_ready:");
      RL ("  cmp bx, ax");
      RL ("  jb .fallback_vram");
      RL ("  sub bx, ax");
      RL ("  cmp bx, 4000");
      RL ("  jb .fallback_vram");
      RL ("  sub ax, dx");
      RL ("  mov bx, ax");
      RL ("  mov es, dx");
      RL ("  mov ah, 4Ah");
      RL ("  int 21h");
      RL ("  jc .fallback_vram");
      RL ("  mov ah, 48h");
      RL ("  mov bx, 4000");
      RL ("  int 21h");
      RL ("  jc .fallback_vram");
      RL ("  mov word [ALB16_GFX_Framebuffer_Seg], ax");
      RL ("  jmp .done");
      RL (".fallback_vram:");
      RL (".use_vram:");
      RL ("  mov word [ALB16_GFX_Framebuffer_Seg], 0A000h");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop dx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_GFX_Color_To_Index:");
      RL ("  push bx");
      RL ("  mov bl, al");
      RL ("  mov al, dl");
      RL ("  and al, 11100000b");
      RL ("  mov bh, ah");
      RL ("  and bh, 11100000b");
      RL ("  shr bh, 1");
      RL ("  shr bh, 1");
      RL ("  shr bh, 1");
      RL ("  or al, bh");
      RL ("  shr bl, 1");
      RL ("  shr bl, 1");
      RL ("  shr bl, 1");
      RL ("  shr bl, 1");
      RL ("  shr bl, 1");
      RL ("  shr bl, 1");
      RL ("  or al, bl");
      RL ("  pop bx");
      RL ("  ret");
      RL ("");

      RL ("ALB16_GFX_Init_Palette:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  mov dx, 3C8h");
      RL ("  xor al, al");
      RL ("  out dx, al");
      RL ("  inc dx");
      RL ("  xor si, si");
      RL (".palette_loop:");
      RL ("  mov ax, si");
      RL ("  and al, 11100000b");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  mov bl, al");
      RL ("  shl al, 1");
      RL ("  shl al, 1");
      RL ("  shl al, 1");
      RL ("  add al, bl");
      RL ("  out dx, al");
      RL ("  mov ax, si");
      RL ("  and al, 00011100b");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  mov bl, al");
      RL ("  shl al, 1");
      RL ("  shl al, 1");
      RL ("  shl al, 1");
      RL ("  add al, bl");
      RL ("  out dx, al");
      RL ("  mov ax, si");
      RL ("  and al, 00000011b");
      RL ("  mov bl, al");
      RL ("  mov ah, al");
      RL ("  shl al, 1");
      RL ("  shl al, 1");
      RL ("  shl al, 1");
      RL ("  shl al, 1");
      RL ("  shl ah, 1");
      RL ("  shl ah, 1");
      RL ("  add al, ah");
      RL ("  add al, bl");
      RL ("  out dx, al");
      RL ("  inc si");
      RL ("  cmp si, 256");
      RL ("  jb .palette_loop");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB_Set_Color:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  mov ax, [bp+4]");
      RL ("  mov dx, [bp+6]");
      RL ("  call ALB16_GFX_Color_To_Index");
      RL ("  mov byte [ALB16_GFX_Current_Color], al");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 4");
      RL ("");

      RL ("ALB_Set_Clear_Color:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  mov ax, [bp+4]");
      RL ("  mov dx, [bp+6]");
      RL ("  call ALB16_GFX_Color_To_Index");
      RL ("  mov byte [ALB16_GFX_Clear_Color], al");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 4");
      RL ("");

      RL ("ALB_Set_Origin:");
      RL ("  ret 4");
      RL ("");

      RL ("ALB_Set_Clip:");
      RL ("  ret 8");
      RL ("");

      RL ("ALB_Sys_Renderer:");
      RL ("  cmp byte [ALB16_GFX_Mode_Active], 0");
      RL ("  je .none");
      RL ("  mov ax, 4");
      RL ("  xor dx, dx");
      RL ("  ret");
      RL (".none:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL ("  ret");
      RL ("");

      RL ("ALB_Read_Pixel:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  push bx");
      RL ("  push di");
      RL ("  push es");
      RL ("  mov bx, [bp+4]");
      RL ("  mov ax, [bp+6]");
      RL ("  cmp bx, [ALB_Screen_Width]");
      RL ("  jae .zero");
      RL ("  cmp ax, [ALB_Screen_Height]");
      RL ("  jae .zero");
      RL ("  mul word [ALB_Screen_Width]");
      RL ("  add ax, bx");
      RL ("  mov di, ax");
      RL ("  mov ax, [ALB16_GFX_Framebuffer_Seg]");
      RL ("  or ax, ax");
      RL ("  jz .zero");
      RL ("  mov es, ax");
      RL ("  xor ax, ax");
      RL ("  mov al, byte [es:di]");
      RL ("  xor dx, dx");
      RL ("  jmp .done");
      RL (".zero:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop di");
      RL ("  pop bx");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 4");
      RL ("");

      RL ("ALB16_GFX_Frame_Begin:");
      RL ("  push ax");
      RL ("  push cx");
      RL ("  push di");
      RL ("  push es");
      RL ("  mov ax, [ALB16_GFX_Framebuffer_Seg]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  mov es, ax");
      RL ("  xor di, di");
      RL ("  mov al, byte [ALB16_GFX_Clear_Color]");
      RL ("  mov ah, al");
      RL ("  mov cx, 32000");
      RL ("  cld");
      RL ("  rep stosw");
      RL ("  mov byte [ALB16_GFX_Frame_Dirty], 1");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop di");
      RL ("  pop cx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_GFX_Present:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  push ds");
      RL ("  push es");
      RL ("  cmp byte [ALB16_GFX_Frame_Dirty], 0");
      RL ("  je .done");
      RL ("  mov byte [ALB16_GFX_Frame_Dirty], 0");
      RL ("  mov bx, [ALB16_GFX_Framebuffer_Seg]");
      RL ("  or bx, bx");
      RL ("  jz .done");
      RL ("  cmp bx, 0A000h");
      RL ("  je .done");
      RL ("  cmp byte [ALB16_GFX_Speed_Mode], 0");
      RL ("  jne .copy");
      RL ("  cmp byte [ALB16_GFX_Present_Wait], 0");
      RL ("  je .copy");
      RL ("  mov dx, 03DAh");
      RL ("  mov cx, 0FFFFh");
      RL (".wait_not_retrace:");
      RL ("  in al, dx");
      RL ("  test al, 08h");
      RL ("  jz .wait_retrace_start");
      RL ("  loop .wait_not_retrace");
      RL ("  jmp .copy");
      RL (".wait_retrace_start:");
      RL ("  mov cx, 0FFFFh");
      RL (".wait_retrace:");
      RL ("  in al, dx");
      RL ("  test al, 08h");
      RL ("  jnz .copy");
      RL ("  loop .wait_retrace");
      RL (".copy:");
      RL ("  mov ds, bx");
      RL ("  mov ax, 0A000h");
      RL ("  mov es, ax");
      RL ("  xor si, si");
      RL ("  xor di, di");
      RL ("  mov cx, 32000");
      RL ("  cld");
      RL ("  rep movsw");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop ds");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_GFX_Shutdown:");
      RL ("  push ax");
      RL ("  cmp byte [ALB16_GFX_Mode_Active], 0");
      RL ("  je .done");
      RL ("  mov ax, 0003h");
      RL ("  int 10h");
      RL ("  mov byte [ALB16_GFX_Mode_Active], 0");
      RL ("  call ALB16_Input_Shutdown");
      RL (".done:");
      RL ("  mov word [ALB16_GFX_Framebuffer_Seg], 0");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_GFX_Plot_AX_DX:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push dx");
      RL ("  push di");
      RL ("  push es");
      RL ("  cmp ax, [ALB_Screen_Width]");
      RL ("  jae .done");
      RL ("  cmp dx, [ALB_Screen_Height]");
      RL ("  jae .done");
      RL ("  cmp byte [ALB16_GFX_Alpha_Mode], 0");
      RL ("  je .offset");
      RL ("  mov bl, byte [ALB16_GFX_Alpha_Value]");
      RL ("  cmp bl, 255");
      RL ("  je .offset");
      RL ("  mov bx, ax");
      RL ("  xor bx, dx");
      RL ("  and bl, 0Fh");
      RL ("  mov al, byte [ALB16_GFX_Alpha_Value]");
      RL ("  add al, 15");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  shr al, 1");
      RL ("  or al, al");
      RL ("  jz .done");
      RL ("  cmp bl, al");
      RL ("  jae .done");
      RL (".offset:");
      RL ("  mov di, dx");
      RL ("  mov bx, dx");
      RL ("  shl di, 6");
      RL ("  shl bx, 8");
      RL ("  add di, bx");
      RL ("  add di, ax");
      RL ("  mov ax, [ALB16_GFX_Framebuffer_Seg]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  mov es, ax");
      RL ("  mov al, byte [ALB16_GFX_Current_Color]");
      RL ("  mov byte [ALB16_GFX_Frame_Dirty], 1");
      RL ("  mov byte [es:di], al");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop di");
      RL ("  pop dx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_GFX_HLine_AX_BX_DX:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  push es");
      RL ("  cmp dx, [ALB_Screen_Height]");
      RL ("  jae .done");
      RL ("  cmp ax, bx");
      RL ("  jle .ordered");
      RL ("  xchg ax, bx");
      RL (".ordered:");
      RL ("  cmp bx, 0");
      RL ("  jl .done");
      RL ("  cmp ax, 0");
      RL ("  jge .left_ok");
      RL ("  xor ax, ax");
      RL (".left_ok:");
      RL ("  cmp ax, [ALB_Screen_Width]");
      RL ("  jae .done");
      RL ("  mov cx, [ALB_Screen_Width]");
      RL ("  dec cx");
      RL ("  cmp bx, cx");
      RL ("  jle .right_ok");
      RL ("  mov bx, cx");
      RL (".right_ok:");
      RL ("  mov si, ax");
      RL ("  cmp byte [ALB16_GFX_Alpha_Mode], 0");
      RL ("  je .solid");
      RL ("  mov al, byte [ALB16_GFX_Alpha_Value]");
      RL ("  cmp al, 255");
      RL ("  je .solid");
      RL (".alpha_loop:");
      RL ("  mov ax, si");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  cmp si, bx");
      RL ("  je .done");
      RL ("  inc si");
      RL ("  jmp .alpha_loop");
      RL (".solid:");
      RL ("  mov di, si");
      RL ("  mov ax, dx");
      RL ("  mov cx, ax");
      RL ("  shl ax, 6");
      RL ("  shl cx, 8");
      RL ("  add ax, cx");
      RL ("  add ax, di");
      RL ("  mov di, ax");
      RL ("  mov ax, [ALB16_GFX_Framebuffer_Seg]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  mov es, ax");
      RL ("  mov al, byte [ALB16_GFX_Current_Color]");
      RL ("  mov ah, al");
      RL ("  mov byte [ALB16_GFX_Frame_Dirty], 1");
      RL ("  mov cx, bx");
      RL ("  sub cx, si");
      RL ("  inc cx");
      RL ("  cld");
      RL ("  shr cx, 1");
      RL ("  jnc .even_count");
      RL ("  stosb");
      RL (".even_count:");
      RL ("  rep stosw");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("");

      RL ("ALB16_GFX_VLine_AX_DX_BX:");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  push es");
      RL ("  cmp ax, [ALB_Screen_Width]");
      RL ("  jae .done");
      RL ("  cmp dx, bx");
      RL ("  jle .ordered");
      RL ("  xchg dx, bx");
      RL (".ordered:");
      RL ("  cmp bx, 0");
      RL ("  jl .done");
      RL ("  cmp dx, 0");
      RL ("  jge .top_ok");
      RL ("  xor dx, dx");
      RL (".top_ok:");
      RL ("  cmp dx, [ALB_Screen_Height]");
      RL ("  jae .done");
      RL ("  mov cx, [ALB_Screen_Height]");
      RL ("  dec cx");
      RL ("  cmp bx, cx");
      RL ("  jle .bottom_ok");
      RL ("  mov bx, cx");
      RL (".bottom_ok:");
      RL ("  mov si, dx");
      RL ("  cmp byte [ALB16_GFX_Alpha_Mode], 0");
      RL ("  je .solid");
      RL ("  mov al, byte [ALB16_GFX_Alpha_Value]");
      RL ("  cmp al, 255");
      RL ("  je .solid");
      RL (".alpha_loop:");
      RL ("  mov dx, si");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  cmp si, bx");
      RL ("  je .done");
      RL ("  inc si");
      RL ("  jmp .alpha_loop");
      --  RL (".solid:");
      --  RL ("  mov di, si");
      --  RL ("  mov si, ax");
      --  RL ("  mov ax, di");
      --  RL ("  mov cx, [ALB_Screen_Width]");
      --  RL ("  mul cx");
      --  RL ("  add ax, si");
      --  RL ("  mov di, ax");
      --  RL ("  mov ax, [ALB16_GFX_Framebuffer_Seg]");
      --  RL ("  or ax, ax");
      --  RL ("  jz .done");
      --  RL ("  mov es, ax");
      --  RL ("  mov al, byte [ALB16_GFX_Current_Color]");
      --  RL ("  mov si, [ALB_Screen_Width]");
      --  RL ("  mov cx, bx");
      --  RL ("  sub cx, dx");
      --  RL ("  inc cx");
      --  RL (".solid_loop:");
      --  RL ("  mov byte [es:di], al");
      --  RL ("  add di, si");
      --  RL ("  loop .solid_loop");
      --  RL (".done:");
      RL (".solid:");
      RL ("  mov di, si");
      RL ("  mov si, ax");
      RL ("  mov ax, di");
      RL ("  mov cx, ax");
      RL ("  shl ax, 6");
      RL ("  shl cx, 8");
      RL ("  add ax, cx");
      RL ("  add ax, si");
      RL ("  mov di, ax");
      RL ("  mov ax, [ALB16_GFX_Framebuffer_Seg]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  mov es, ax");
      RL ("  mov al, byte [ALB16_GFX_Current_Color]");
      RL ("  mov si, 320");
      RL ("  mov cx, bx");
      RL ("  sub cx, dx");           -- DX is noo safe, height is correct
      RL ("  inc cx");
      RL ("  mov byte [ALB16_GFX_Frame_Dirty], 1");
      RL (".solid_loop:");
      RL ("  mov byte [es:di], al");
      RL ("  add di, si");
      RL ("  loop .solid_loop");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");              -- RESTORED!
      RL ("  pop ax");              -- RESTORED!
      RL ("  ret");                 -- RESTORED!
      RL ("");
      RL ("ALB_Put_Pixel:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  mov ax, [bp+4]");
      RL ("  mov dx, [bp+6]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 4");
      RL ("");

      RL ("ALB_Draw_Text:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  sub sp, 4");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  push es");
      RL ("  mov ax, [bp+4]");
      RL ("  mov word [bp-2], ax");
      RL ("  mov ax, [bp+8]");
      RL ("  mov word [bp-4], ax");
      RL ("  mov si, [bp+12]");
      RL ("  cmp si, 0");
      RL ("  je .done");
      RL (".char_loop:");
      RL ("  mov al, byte [si]");
      RL ("  or al, al");
      RL ("  jz .done");
      RL ("  cmp al, 'a'");
      RL ("  jb .glyph_select");
      RL ("  cmp al, 'z'");
      RL ("  ja .glyph_select");
      RL ("  sub al, 20h");
      RL (".glyph_select:");
      RL ("  mov bx, ALB16_Font5x7_Question");
      RL ("  cmp al, ' '");
      RL ("  je .glyph_space");             -- CHANGED: Jump to spacing logic instead of drawing
      RL ("  cmp al, ':'");
      RL ("  je .glyph_colon");
      RL ("  cmp al, '-'");
      RL ("  je .glyph_dash");
      RL ("  cmp al, '+'");
      RL ("  je .glyph_plus");
      RL ("  cmp al, '*'");
      RL ("  je .glyph_star");
      RL ("  cmp al, '/'");
      RL ("  je .glyph_slash");
      RL ("  cmp al, '='");
      RL ("  je .glyph_equals");
      RL ("  cmp al, '0'");
      RL ("  jb .glyph_letter_check");
      RL ("  cmp al, '9'");
      RL ("  ja .glyph_letter_check");
      RL ("  sub al, '0'");
      RL ("  xor ah, ah");
      RL ("  mov bx, 7");
      RL ("  mul bx");
      RL ("  add ax, ALB16_Font5x7_Digits");
      RL ("  mov bx, ax");
      RL ("  jmp .glyph_ready");
      RL (".glyph_letter_check:");
      RL ("  cmp al, 'A'");
      RL ("  jb .glyph_ready");
      RL ("  cmp al, 'Z'");
      RL ("  ja .glyph_ready");
      RL ("  sub al, 'A'");
      RL ("  xor ah, ah");
      RL ("  mov bx, 7");
      RL ("  mul bx");
      RL ("  add ax, ALB16_Font5x7_Letters");
      RL ("  mov bx, ax");
      RL ("  jmp .glyph_ready");
      RL (".glyph_colon:");
      RL ("  mov bx, ALB16_Font5x7_Colon");
      RL ("  jmp .glyph_ready");
      RL (".glyph_dash:");
      RL ("  mov bx, ALB16_Font5x7_Dash");
      RL ("  jmp .glyph_ready");
      RL (".glyph_plus:");
      RL ("  mov bx, ALB16_Font5x7_Plus");
      RL ("  jmp .glyph_ready");
      RL (".glyph_star:");
      RL ("  mov bx, ALB16_Font5x7_Star");
      RL ("  jmp .glyph_ready");
      RL (".glyph_slash:");
      RL ("  mov bx, ALB16_Font5x7_Slash");
      RL ("  jmp .glyph_ready");
      RL (".glyph_equals:");
      RL ("  mov bx, ALB16_Font5x7_Equals");
      RL ("  jmp .glyph_ready");
      RL (".glyph_ready:");
      RL ("  mov dx, word [bp-4]");
      RL ("  mov cx, 7");
      RL (".row_loop:");
      RL ("  mov al, byte [bx]");
      RL ("  mov di, word [bp-2]");
      RL ("  push cx");
      RL ("  mov cx, 5");
      RL (".bit_loop:");
      RL ("  test al, 10h");
      RL ("  jz .skip_bit");
      RL ("  push ax");                     -- ADDED: Save AL (font bitmap)
      RL ("  mov ax, di");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  pop ax");                      -- ADDED: Restore AL
      RL (".skip_bit:");
      RL ("  shl al, 1");
      RL ("  inc di");
      RL ("  loop .bit_loop");
      RL ("  pop cx");
      RL ("  inc bx");
      RL ("  inc dx");
      RL ("  loop .row_loop");
      RL (".glyph_space:");                 -- ADDED: Safely advance X and skip drawing
      RL ("  add word [bp-2], 6");
      RL ("  inc si");
      RL ("  jmp .char_loop");
      RL (".done:");
      RL ("  pop es");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 10");

      RL ("ALB_COLLIDE_RECT:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  push bx");
      RL ("  mov ax, [bp+4]");
      RL ("  mov bx, [bp+12]");
      RL ("  add bx, ax");
      RL ("  cmp bx, [bp+20]");
      RL ("  jle .no");
      RL ("  mov ax, [bp+20]");
      RL ("  mov bx, [bp+28]");
      RL ("  add bx, ax");
      RL ("  cmp bx, [bp+4]");
      RL ("  jle .no");
      RL ("  mov ax, [bp+8]");
      RL ("  mov bx, [bp+16]");
      RL ("  add bx, ax");
      RL ("  cmp bx, [bp+24]");
      RL ("  jle .no");
      RL ("  mov ax, [bp+24]");
      RL ("  mov bx, [bp+32]");
      RL ("  add bx, ax");
      RL ("  cmp bx, [bp+8]");
      RL ("  jle .no");
      RL ("  mov ax, 1");
      RL ("  xor dx, dx");
      RL ("  jmp .done");
      RL (".no:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".done:");
      RL ("  pop bx");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 32");
      RL ("");

      RL ("ALB_Draw_Line:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  sub sp, 20");
      RL ("  mov ax, [bp+4]");
      RL ("  mov [bp-2], ax");
      RL ("  mov ax, [bp+6]");
      RL ("  mov [bp-4], ax");
      RL ("  mov ax, [bp+8]");
      RL ("  mov [bp-6], ax");
      RL ("  mov ax, [bp+10]");
      RL ("  mov [bp-8], ax");
      RL ("  mov ax, [bp-4]");
      RL ("  cmp ax, [bp-8]");
      RL ("  jne .check_vertical");
      RL ("  mov ax, [bp-2]");
      RL ("  mov bx, [bp-6]");
      RL ("  mov dx, [bp-4]");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL ("  jmp .line_done");
      RL (".check_vertical:");
      RL ("  mov ax, [bp-2]");
      RL ("  cmp ax, [bp-6]");
      RL ("  jne .setup_bres");
      RL ("  mov dx, [bp-4]");
      RL ("  mov bx, [bp-8]");
      RL ("  call ALB16_GFX_VLine_AX_DX_BX");
      RL ("  jmp .line_done");
      RL (".setup_bres:");
      RL ("  mov ax, [bp-6]");
      RL ("  sub ax, [bp-2]");
      RL ("  jns .dx_abs");
      RL ("  neg ax");
      RL (".dx_abs:");
      RL ("  mov [bp-10], ax");
      RL ("  mov ax, 1");
      RL ("  mov bx, [bp-2]");
      RL ("  cmp bx, [bp-6]");
      RL ("  jl .sx_store");
      RL ("  neg ax");
      RL (".sx_store:");
      RL ("  mov [bp-16], ax");
      RL ("  mov ax, [bp-8]");
      RL ("  sub ax, [bp-4]");
      RL ("  jns .dy_abs");
      RL ("  neg ax");
      RL (".dy_abs:");
      RL ("  neg ax");
      RL ("  mov [bp-12], ax");
      RL ("  mov ax, 1");
      RL ("  mov bx, [bp-4]");
      RL ("  cmp bx, [bp-8]");
      RL ("  jl .sy_store");
      RL ("  neg ax");
      RL (".sy_store:");
      RL ("  mov [bp-18], ax");
      RL ("  mov ax, [bp-10]");
      RL ("  add ax, [bp-12]");
      RL ("  mov [bp-14], ax");
      RL (".line_loop:");
      RL ("  mov ax, [bp-2]");
      RL ("  mov dx, [bp-4]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  cmp ax, [bp-6]");
      RL ("  jne .line_not_done");
      RL ("  mov ax, [bp-4]");
      RL ("  cmp ax, [bp-8]");
      RL ("  je .line_done");
      RL (".line_not_done:");
      RL ("  mov ax, [bp-14]");
      RL ("  add ax, ax");
      RL ("  mov [bp-20], ax");
      RL ("  mov ax, [bp-20]");
      RL ("  cmp ax, [bp-12]");
      RL ("  jl .line_skip_x");
      RL ("  mov ax, [bp-14]");
      RL ("  add ax, [bp-12]");
      RL ("  mov [bp-14], ax");
      RL ("  mov ax, [bp-2]");
      RL ("  add ax, [bp-16]");
      RL ("  mov [bp-2], ax");
      RL (".line_skip_x:");
      RL ("  mov ax, [bp-20]");
      RL ("  cmp ax, [bp-10]");
      RL ("  jg .line_skip_y");
      RL ("  mov ax, [bp-14]");
      RL ("  add ax, [bp-10]");
      RL ("  mov [bp-14], ax");
      RL ("  mov ax, [bp-4]");
      RL ("  add ax, [bp-18]");
      RL ("  mov [bp-4], ax");
      RL (".line_skip_y:");
      RL ("  jmp .line_loop");
      RL (".line_done:");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 8");
      RL ("");

      RL ("ALB_Draw_Rect:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  mov ax, [bp+8]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  js .done");
      RL ("  mov ax, [bp+10]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  js .done");
      RL ("  mov ax, [bp+4]");
      RL ("  mov bx, [bp+8]");
      RL ("  dec bx");
      RL ("  add bx, ax");
      RL ("  mov dx, [bp+6]");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL ("  mov dx, [bp+6]");
      RL ("  mov cx, [bp+10]");
      RL ("  dec cx");
      RL ("  add cx, dx");
      RL ("  cmp cx, dx");
      RL ("  je .single_row");
      RL ("  mov ax, [bp+4]");
      RL ("  mov bx, [bp+8]");
      RL ("  dec bx");
      RL ("  add bx, ax");
      RL ("  mov dx, cx");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL (".single_row:");
      RL ("  mov ax, [bp+4]");
      RL ("  mov dx, [bp+6]");
      RL ("  mov bx, [bp+10]");
      RL ("  dec bx");
      RL ("  add bx, dx");
      RL ("  call ALB16_GFX_VLine_AX_DX_BX");
      RL ("  mov ax, [bp+8]");
      RL ("  cmp ax, 1");
      RL ("  je .done");
      RL ("  mov ax, [bp+4]");
      RL ("  mov bx, [bp+8]");
      RL ("  dec bx");
      RL ("  add ax, bx");
      RL ("  mov dx, [bp+6]");
      RL ("  mov bx, [bp+10]");
      RL ("  dec bx");
      RL ("  add bx, dx");
      RL ("  call ALB16_GFX_VLine_AX_DX_BX");
      RL (".done:");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 8");
      RL ("");

      RL ("ALB_Fill_Rect:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  sub sp, 6");
      RL ("  mov ax, [bp+8]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  js .done");
      RL ("  mov ax, [bp+10]");
      RL ("  or ax, ax");
      RL ("  jz .done");
      RL ("  js .done");
      RL ("  cmp byte [ALB16_GFX_Alpha_Mode], 0");
      RL ("  jne .fill_rect_slow_setup");
      RL ("  mov ax, [bp+8]");
      RL ("  mov ax, [bp+4]");
      RL ("  or ax, ax");
      RL ("  js .fill_rect_slow_setup");
      RL ("  cmp ax, [ALB_Screen_Width]");
      RL ("  jae .done");
      RL ("  mov dx, [bp+6]");
      RL ("  or dx, dx");
      RL ("  js .fill_rect_slow_setup");
      RL ("  cmp dx, [ALB_Screen_Height]");
      RL ("  jae .done");
      RL ("  mov bx, ax");
      RL ("  add bx, [bp+8]");
      RL ("  jc .fill_rect_slow_setup");
      RL ("  cmp bx, [ALB_Screen_Width]");
      RL ("  ja .fill_rect_slow_setup");
      RL ("  mov bx, dx");
      RL ("  add bx, [bp+10]");
      RL ("  jc .fill_rect_slow_setup");
      RL ("  cmp bx, [ALB_Screen_Height]");
      RL ("  ja .fill_rect_slow_setup");
      RL ("  push ax");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push di");
      RL ("  push es");
      RL ("  mov ax, [bp+6]");
      RL ("  mov bx, ax");
      RL ("  shl ax, 6");
      RL ("  shl bx, 8");
      RL ("  add ax, bx");
      RL ("  add ax, [bp+4]");
      RL ("  mov di, ax");
      RL ("  mov ax, [ALB16_GFX_Framebuffer_Seg]");
      RL ("  or ax, ax");
      RL ("  jz .fast_done");
      RL ("  mov es, ax");
      RL ("  mov al, byte [ALB16_GFX_Current_Color]");
      RL ("  mov byte [ALB16_GFX_Frame_Dirty], 1");
      RL ("  mov dx, [bp+10]");
      RL ("  mov bx, 320");
      RL ("  sub bx, [bp+8]");
      RL ("  mov cx, [bp+8]");
      RL ("  cld");
      RL (".fast_row:");
      RL ("  push cx");
      RL ("  rep stosb");
      RL ("  pop cx");
      RL ("  add di, bx");
      RL ("  dec dx");
      RL ("  jnz .fast_row");
      RL (".fast_done:");
      RL ("  pop es");
      RL ("  pop di");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop ax");
      RL ("  jmp .done");
      RL (".fill_rect_slow_setup:");
      RL ("  mov ax, [bp+4]");
      RL ("  mov bx, [bp+8]");
      RL ("  dec bx");
      RL ("  add ax, bx");
      RL ("  mov [bp-2], ax");
      RL ("  mov ax, [bp+6]");
      RL ("  mov [bp-4], ax");
      RL ("  mov bx, [bp+10]");
      RL ("  dec bx");
      RL ("  add ax, bx");
      RL ("  mov [bp-6], ax");
      RL (".fill_rect_loop:");
      RL ("  mov ax, [bp+4]");
      RL ("  mov bx, [bp-2]");
      RL ("  mov dx, [bp-4]");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL ("  mov ax, [bp-4]");
      RL ("  cmp ax, [bp-6]");
      RL ("  je .done");
      RL ("  inc ax");
      RL ("  mov [bp-4], ax");
      RL ("  jmp .fill_rect_loop");
      RL (".done:");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 8");
      RL ("");

      RL ("ALB_Draw_Circle:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  sub sp, 10");
      RL ("  mov ax, [bp+4]");
      RL ("  mov [bp-2], ax");
      RL ("  mov ax, [bp+6]");
      RL ("  mov [bp-4], ax");
      RL ("  mov word [bp-6], 0");
      RL ("  mov ax, [bp+8]");
      RL ("  mov [bp-8], ax");
      RL ("  mov ax, [bp+8]");
      RL ("  shl ax, 1");
      RL ("  mov bx, 3");
      RL ("  sub bx, ax");
      RL ("  mov [bp-10], bx");
      RL (".draw_circle_loop:");
      RL ("  mov ax, [bp-6]");
      RL ("  cmp ax, [bp-8]");
      RL ("  jg .done");
      RL ("  mov ax, [bp-2]");
      RL ("  add ax, [bp-6]");
      RL ("  mov dx, [bp-4]");
      RL ("  add dx, [bp-8]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-6]");
      RL ("  mov dx, [bp-4]");
      RL ("  add dx, [bp-8]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  add ax, [bp-6]");
      RL ("  mov dx, [bp-4]");
      RL ("  sub dx, [bp-8]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-6]");
      RL ("  mov dx, [bp-4]");
      RL ("  sub dx, [bp-8]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  add ax, [bp-8]");
      RL ("  mov dx, [bp-4]");
      RL ("  add dx, [bp-6]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-8]");
      RL ("  mov dx, [bp-4]");
      RL ("  add dx, [bp-6]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  add ax, [bp-8]");
      RL ("  mov dx, [bp-4]");
      RL ("  sub dx, [bp-6]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-8]");
      RL ("  mov dx, [bp-4]");
      RL ("  sub dx, [bp-6]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL ("  mov ax, [bp-6]");
      RL ("  inc ax");
      RL ("  mov [bp-6], ax");
      RL ("  mov ax, [bp-10]");
      RL ("  cmp ax, 0");
      RL ("  jle .draw_circle_no_dec");
      RL ("  mov ax, [bp-8]");
      RL ("  dec ax");
      RL ("  mov [bp-8], ax");
      RL ("  mov ax, [bp-6]");
      RL ("  sub ax, [bp-8]");
      RL ("  shl ax, 1");
      RL ("  shl ax, 1");
      RL ("  add ax, 10");
      RL ("  add [bp-10], ax");
      RL ("  jmp .draw_circle_loop");
      RL (".draw_circle_no_dec:");
      RL ("  mov ax, [bp-6]");
      RL ("  shl ax, 1");
      RL ("  shl ax, 1");
      RL ("  add ax, 6");
      RL ("  add [bp-10], ax");
      RL ("  jmp .draw_circle_loop");
      RL (".done:");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 6");
      RL ("");

      RL ("ALB_Fill_Circle:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  sub sp, 10");
      RL ("  mov ax, [bp+4]");
      RL ("  mov [bp-2], ax");
      RL ("  mov ax, [bp+6]");
      RL ("  mov [bp-4], ax");
      RL ("  mov word [bp-6], 0");
      RL ("  mov ax, [bp+8]");
      RL ("  mov [bp-8], ax");
      RL ("  mov ax, [bp+8]");
      RL ("  shl ax, 1");
      RL ("  mov bx, 3");
      RL ("  sub bx, ax");
      RL ("  mov [bp-10], bx");
      RL (".fill_circle_loop:");
      RL ("  mov ax, [bp-6]");
      RL ("  cmp ax, [bp-8]");
      RL ("  jg .done");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-6]");
      RL ("  mov bx, [bp-2]");
      RL ("  add bx, [bp-6]");
      RL ("  mov dx, [bp-4]");
      RL ("  add dx, [bp-8]");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-6]");
      RL ("  mov bx, [bp-2]");
      RL ("  add bx, [bp-6]");
      RL ("  mov dx, [bp-4]");
      RL ("  sub dx, [bp-8]");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-8]");
      RL ("  mov bx, [bp-2]");
      RL ("  add bx, [bp-8]");
      RL ("  mov dx, [bp-4]");
      RL ("  add dx, [bp-6]");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL ("  mov ax, [bp-2]");
      RL ("  sub ax, [bp-8]");
      RL ("  mov bx, [bp-2]");
      RL ("  add bx, [bp-8]");
      RL ("  mov dx, [bp-4]");
      RL ("  sub dx, [bp-6]");
      RL ("  call ALB16_GFX_HLine_AX_BX_DX");
      RL ("  mov ax, [bp-6]");
      RL ("  inc ax");
      RL ("  mov [bp-6], ax");
      RL ("  mov ax, [bp-10]");
      RL ("  cmp ax, 0");
      RL ("  jle .fill_circle_no_dec");
      RL ("  mov ax, [bp-8]");
      RL ("  dec ax");
      RL ("  mov [bp-8], ax");
      RL ("  mov ax, [bp-6]");
      RL ("  sub ax, [bp-8]");
      RL ("  shl ax, 1");
      RL ("  shl ax, 1");
      RL ("  add ax, 10");
      RL ("  add [bp-10], ax");
      RL ("  jmp .fill_circle_loop");
      RL (".fill_circle_no_dec:");
      RL ("  mov ax, [bp-6]");
      RL ("  shl ax, 1");
      RL ("  shl ax, 1");
      RL ("  add ax, 6");
      RL ("  add [bp-10], ax");
      RL ("  jmp .fill_circle_loop");
      RL (".done:");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 6");
      RL ("");

      RL ("ALB_Draw_Triangle:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  push word [bp+10]");
      RL ("  push word [bp+8]");
      RL ("  push word [bp+6]");
      RL ("  push word [bp+4]");
      RL ("  call ALB_Draw_Line");
      RL ("  push word [bp+14]");
      RL ("  push word [bp+12]");
      RL ("  push word [bp+10]");
      RL ("  push word [bp+8]");
      RL ("  call ALB_Draw_Line");
      RL ("  push word [bp+6]");
      RL ("  push word [bp+4]");
      RL ("  push word [bp+14]");
      RL ("  push word [bp+12]");
      RL ("  call ALB_Draw_Line");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 12");
      RL ("");

      RL ("ALB16_GFX_Edge_Sign:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  sub sp, 4");
      RL ("  mov ax, [bp+12]");
      RL ("  sub ax, [bp+4]");
      RL ("  mov bx, [bp+10]");
      RL ("  sub bx, [bp+6]");
      RL ("  imul bx");
      RL ("  mov [bp-4], ax");
      RL ("  mov [bp-2], dx");
      RL ("  mov ax, [bp+14]");
      RL ("  sub ax, [bp+6]");
      RL ("  mov bx, [bp+8]");
      RL ("  sub bx, [bp+4]");
      RL ("  imul bx");
      RL ("  mov bx, ax");
      RL ("  mov cx, dx");
      RL ("  mov ax, [bp-4]");
      RL ("  mov dx, [bp-2]");
      RL ("  sub ax, bx");
      RL ("  sbb dx, cx");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 12");
      RL ("");

      RL ("ALB_Fill_Triangle:");
      RL ("  push bp");
      RL ("  mov bp, sp");
      RL ("  sub sp, 14");
      RL ("  mov ax, [bp+4]");
      RL ("  cmp ax, [bp+8]");
      RL ("  jle .minx_12");
      RL ("  mov ax, [bp+8]");
      RL (".minx_12:");
      RL ("  cmp ax, [bp+12]");
      RL ("  jle .minx_done");
      RL ("  mov ax, [bp+12]");
      RL (".minx_done:");
      RL ("  mov [bp-2], ax");
      RL ("  mov ax, [bp+4]");
      RL ("  cmp ax, [bp+8]");
      RL ("  jge .maxx_12");
      RL ("  mov ax, [bp+8]");
      RL (".maxx_12:");
      RL ("  cmp ax, [bp+12]");
      RL ("  jge .maxx_done");
      RL ("  mov ax, [bp+12]");
      RL (".maxx_done:");
      RL ("  mov [bp-4], ax");
      RL ("  mov ax, [bp+6]");
      RL ("  cmp ax, [bp+10]");
      RL ("  jle .miny_12");
      RL ("  mov ax, [bp+10]");
      RL (".miny_12:");
      RL ("  cmp ax, [bp+14]");
      RL ("  jle .miny_done");
      RL ("  mov ax, [bp+14]");
      RL (".miny_done:");
      RL ("  mov [bp-6], ax");
      RL ("  mov ax, [bp+6]");
      RL ("  cmp ax, [bp+10]");
      RL ("  jge .maxy_12");
      RL ("  mov ax, [bp+10]");
      RL (".maxy_12:");
      RL ("  cmp ax, [bp+14]");
      RL ("  jge .maxy_done");
      RL ("  mov ax, [bp+14]");
      RL (".maxy_done:");
      RL ("  mov [bp-8], ax");
      RL ("  push word [bp+14]");
      RL ("  push word [bp+12]");
      RL ("  push word [bp+10]");
      RL ("  push word [bp+8]");
      RL ("  push word [bp+6]");
      RL ("  push word [bp+4]");
      RL ("  call ALB16_GFX_Edge_Sign");
      RL ("  test dx, 8000h");
      RL ("  jnz .area_negative");
      RL ("  mov word [bp-14], 1");
      RL ("  jmp .area_done");
      RL (".area_negative:");
      RL ("  mov word [bp-14], 0");
      RL (".area_done:");
      RL ("  mov ax, [bp-6]");
      RL ("  mov [bp-12], ax");
      RL (".fill_tri_y_loop:");
      RL ("  mov ax, [bp-2]");
      RL ("  mov [bp-10], ax");
      RL (".fill_tri_x_loop:");
      RL ("  cmp word [bp-14], 0");
      RL ("  je .check_neg_w0");
      RL ("  push word [bp-12]");
      RL ("  push word [bp-10]");
      RL ("  push word [bp+14]");
      RL ("  push word [bp+12]");
      RL ("  push word [bp+10]");
      RL ("  push word [bp+8]");
      RL ("  call ALB16_GFX_Edge_Sign");
      RL ("  test dx, 8000h");
      RL ("  jnz .outside");
      RL ("  push word [bp-12]");
      RL ("  push word [bp-10]");
      RL ("  push word [bp+6]");
      RL ("  push word [bp+4]");
      RL ("  push word [bp+14]");
      RL ("  push word [bp+12]");
      RL ("  call ALB16_GFX_Edge_Sign");
      RL ("  test dx, 8000h");
      RL ("  jnz .outside");
      RL ("  push word [bp-12]");
      RL ("  push word [bp-10]");
      RL ("  push word [bp+10]");
      RL ("  push word [bp+8]");
      RL ("  push word [bp+6]");
      RL ("  push word [bp+4]");
      RL ("  call ALB16_GFX_Edge_Sign");
      RL ("  test dx, 8000h");
      RL ("  jnz .outside");
      RL ("  jmp .inside");
      RL (".check_neg_w0:");
      RL ("  push word [bp-12]");
      RL ("  push word [bp-10]");
      RL ("  push word [bp+14]");
      RL ("  push word [bp+12]");
      RL ("  push word [bp+10]");
      RL ("  push word [bp+8]");
      RL ("  call ALB16_GFX_Edge_Sign");
      RL ("  test dx, 8000h");
      RL ("  jnz .neg_w0_ok");
      RL ("  mov bx, ax");
      RL ("  or bx, dx");
      RL ("  jnz .outside");
      RL (".neg_w0_ok:");
      RL ("  push word [bp-12]");
      RL ("  push word [bp-10]");
      RL ("  push word [bp+6]");
      RL ("  push word [bp+4]");
      RL ("  push word [bp+14]");
      RL ("  push word [bp+12]");
      RL ("  call ALB16_GFX_Edge_Sign");
      RL ("  test dx, 8000h");
      RL ("  jnz .neg_w1_ok");
      RL ("  mov bx, ax");
      RL ("  or bx, dx");
      RL ("  jnz .outside");
      RL (".neg_w1_ok:");
      RL ("  push word [bp-12]");
      RL ("  push word [bp-10]");
      RL ("  push word [bp+10]");
      RL ("  push word [bp+8]");
      RL ("  push word [bp+6]");
      RL ("  push word [bp+4]");
      RL ("  call ALB16_GFX_Edge_Sign");
      RL ("  test dx, 8000h");
      RL ("  jnz .inside");
      RL ("  mov bx, ax");
      RL ("  or bx, dx");
      RL ("  jnz .outside");
      RL (".inside:");
      RL ("  mov ax, [bp-10]");
      RL ("  mov dx, [bp-12]");
      RL ("  call ALB16_GFX_Plot_AX_DX");
      RL (".outside:");
      RL ("  mov ax, [bp-10]");
      RL ("  cmp ax, [bp-4]");
      RL ("  je .next_y");
      RL ("  inc ax");
      RL ("  mov [bp-10], ax");
      RL ("  jmp .fill_tri_x_loop");
      RL (".next_y:");
      RL ("  mov ax, [bp-12]");
      RL ("  cmp ax, [bp-8]");
      RL ("  je .done");
      RL ("  inc ax");
      RL ("  mov [bp-12], ax");
      RL ("  jmp .fill_tri_y_loop");
      RL (".done:");
      RL ("  mov sp, bp");
      RL ("  pop bp");
      RL ("  ret 12");
      RL ("");

      -- Prints AX as unsigned decimal, range 0..65535.
      if OK then Line ("if used ALB16_Print_U16", OK); end if;
      if OK then Line ("ALB16_Print_U16:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  cmp ax, 0", OK); end if;
      if OK then Line ("  jne .alb16_u16_convert", OK); end if;
      if OK then Line ("  mov dl, 30h", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  jmp .alb16_u16_done", OK); end if;
      if OK then Line (".alb16_u16_convert:", OK); end if;
      if OK then Line ("  xor cx, cx", OK); end if;
      if OK then Line ("  mov bx, 10", OK); end if;
      if OK then Line (".alb16_u16_next:", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  div bx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  inc cx", OK); end if;
      if OK then Line ("  cmp ax, 0", OK); end if;
      if OK then Line ("  jne .alb16_u16_next", OK); end if;
      if OK then Line (".alb16_u16_emit:", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  add dl, 30h", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  loop .alb16_u16_emit", OK); end if;
      if OK then Line (".alb16_u16_done:", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_Print_U32", OK); end if;
      if OK then Line ("ALB16_Print_U32:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  mov si, dx", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  cmp si, 0", OK); end if;
      if OK then Line ("  jne .alb16_u32_convert", OK); end if;
      if OK then Line ("  cmp di, 0", OK); end if;
      if OK then Line ("  jne .alb16_u32_convert", OK); end if;
      if OK then Line ("  mov dl, 30h", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  jmp .alb16_u32_done", OK); end if;
      if OK then Line (".alb16_u32_convert:", OK); end if;
      if OK then Line ("  xor cx, cx", OK); end if;
      if OK then Line ("  mov bx, 10", OK); end if;
      if OK then Line (".alb16_u32_next:", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  div bx", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  div bx", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  inc cx", OK); end if;
      if OK then Line ("  cmp si, 0", OK); end if;
      if OK then Line ("  jne .alb16_u32_next", OK); end if;
      if OK then Line ("  cmp di, 0", OK); end if;
      if OK then Line ("  jne .alb16_u32_next", OK); end if;
      if OK then Line (".alb16_u32_emit:", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  add dl, 30h", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  loop .alb16_u32_emit", OK); end if;
      if OK then Line (".alb16_u32_done:", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_Print_S32", OK); end if;
      if OK then Line ("ALB16_Print_S32:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  test dx, 8000h", OK); end if;
      if OK then Line ("  jz .alb16_s32_positive", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  mov dl, 2Dh", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  neg ax", OK); end if;
      if OK then Line ("  adc dx, 0", OK); end if;
      if OK then Line ("  neg dx", OK); end if;
      if OK then Line ("  call ALB16_Print_U32", OK); end if;
      if OK then Line ("  jmp .alb16_s32_done", OK); end if;
      if OK then Line (".alb16_s32_positive:", OK); end if;
      if OK then Line ("  call ALB16_Print_U32", OK); end if;
      if OK then Line (".alb16_s32_done:", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_Print_Pure", OK); end if;
      if OK then Line ("ALB16_Print_Pure:", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  mov bx, ax", OK); end if;
      if OK then Line ("  mov ax, dx", OK); end if;
      if OK then Line ("  cwd", OK); end if;
      if OK then Line ("  call ALB16_Print_S32", OK); end if;
      if OK then Line ("  mov dl, 20h", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  mov dl, 2Fh", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  mov dl, 20h", OK); end if;
      if OK then Line ("  mov ah, 02h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line ("  mov ax, bx", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  call ALB16_Print_U32", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_Pure_Normalize", OK); end if;
      if OK then Line ("ALB16_Pure_Normalize:", OK); end if;
      if OK then Line ("  cmp ax, 0", OK); end if;
      if OK then Emit_Long_Trap_Jcc ("je", "ALB16_Runtime_DivZero", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov di, dx", OK); end if;
      if OK then Line ("  xor bx, bx", OK); end if;
      if OK then Line ("  test di, 8000h", OK); end if;
      if OK then Line ("  jz .pure_abs_ready", OK); end if;
      if OK then Line ("  neg di", OK); end if;
      if OK then Line ("  mov bx, 1", OK); end if;
      if OK then Line (".pure_abs_ready:", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  cmp ax, 0", OK); end if;
      if OK then Line ("  jne .pure_gcd_have_num", OK); end if;
      if OK then Line ("  mov cx, si", OK); end if;
      if OK then Line ("  jmp .pure_reduce", OK); end if;
      if OK then Line (".pure_gcd_have_num:", OK); end if;
      if OK then Line ("  mov cx, si", OK); end if;
      if OK then Line (".pure_gcd_loop:", OK); end if;
      if OK then Line ("  cmp cx, 0", OK); end if;
      if OK then Line ("  je .pure_gcd_done", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  div cx", OK); end if;
      if OK then Line ("  mov ax, cx", OK); end if;
      if OK then Line ("  mov cx, dx", OK); end if;
      if OK then Line ("  jmp .pure_gcd_loop", OK); end if;
      if OK then Line (".pure_gcd_done:", OK); end if;
      if OK then Line ("  mov cx, ax", OK); end if;
      if OK then Line (".pure_reduce:", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  div cx", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      if OK then Line ("  div cx", OK); end if;
      if OK then Line ("  cmp bx, 0", OK); end if;
      if OK then Line ("  je .pure_sign_done", OK); end if;
      if OK then Line ("  neg ax", OK); end if;
      if OK then Line (".pure_sign_done:", OK); end if;
      if OK then Line ("  mov dx, ax", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_Pure_Add", OK); end if;
      if OK then Line ("ALB16_Pure_Add:", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  mov si, dx", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  imul bx", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov ax, cx", OK); end if;
      if OK then Line ("  imul di", OK); end if;
      if OK then Line ("  add si, ax", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  mul bx", OK); end if;
      if OK then Line ("  mov dx, si", OK); end if;
      if OK then Line ("  call ALB16_Pure_Normalize", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("if used ALB16_Pure_Sub", OK); end if;
      if OK then Line ("ALB16_Pure_Sub:", OK); end if;
      if OK then Line ("  neg cx", OK); end if;
      if OK then Line ("  jmp ALB16_Pure_Add", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("if used ALB16_Pure_Mul", OK); end if;
      if OK then Line ("ALB16_Pure_Mul:", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  push bp", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov di, dx", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  imul cx", OK); end if;
      if OK then Line ("  mov bp, ax", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  mul bx", OK); end if;
      if OK then Line ("  mov dx, bp", OK); end if;
      if OK then Line ("  call ALB16_Pure_Normalize", OK); end if;
      if OK then Line ("  pop bp", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("if used ALB16_Pure_Div", OK); end if;
      if OK then Line ("ALB16_Pure_Div:", OK); end if;
      if OK then Line ("  cmp cx, 0", OK); end if;
      if OK then Emit_Long_Trap_Jcc ("je", "ALB16_Runtime_DivZero", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  push bp", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov di, dx", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  imul bx", OK); end if;
      if OK then Line ("  mov bp, ax", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  imul cx", OK); end if;
      if OK then Line ("  mov dx, bp", OK); end if;
      if OK then Line ("  test ax, 8000h", OK); end if;
      if OK then Line ("  jz .pure_div_den_ok", OK); end if;
      if OK then Line ("  neg ax", OK); end if;
      if OK then Line ("  neg dx", OK); end if;
      if OK then Line (".pure_div_den_ok:", OK); end if;
      if OK then Line ("  call ALB16_Pure_Normalize", OK); end if;
      if OK then Line ("  pop bp", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("if used ALB16_Pure_Pow", OK); end if;
      if OK then Line ("ALB16_Pure_Pow:", OK); end if;
      if OK then Line ("  cmp bx, 1", OK); end if;
      if OK then Emit_Long_Trap_Jcc ("jne", "ALB16_Runtime_Range", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  push bp", OK); end if;
      if OK then Line ("  mov si, cx", OK); end if;
      if OK then Line ("  cmp si, 0", OK); end if;
      if OK then Line ("  jge .pure_pow_exp_ready", OK); end if;
      if OK then Line ("  cmp dx, 0", OK); end if;
      if OK then Emit_Long_Trap_Jcc ("je", "ALB16_Runtime_DivZero", OK); end if;
      if OK then Line ("  cmp si, 8000h", OK); end if;
      if OK then Emit_Long_Trap_Jcc ("je", "ALB16_Runtime_Range", OK); end if;
      if OK then Line ("  neg si", OK); end if;
      if OK then Line ("  xchg ax, dx", OK); end if;
      if OK then Line ("  call ALB16_Pure_Normalize", OK); end if;
      if OK then Line (".pure_pow_exp_ready:", OK); end if;
      if OK then Line ("  mov bp, ax", OK); end if;
      if OK then Line ("  mov di, dx", OK); end if;
      if OK then Line ("  mov ax, 1", OK); end if;
      if OK then Line ("  mov dx, 1", OK); end if;
      if OK then Line (".pure_pow_loop:", OK); end if;
      if OK then Line ("  cmp si, 0", OK); end if;
      if OK then Line ("  je .pure_pow_done", OK); end if;
      if OK then Line ("  mov bx, bp", OK); end if;
      if OK then Line ("  mov cx, di", OK); end if;
      if OK then Line ("  call ALB16_Pure_Mul", OK); end if;
      if OK then Line ("  dec si", OK); end if;
      if OK then Line ("  jmp .pure_pow_loop", OK); end if;
      if OK then Line (".pure_pow_done:", OK); end if;
      if OK then Line ("  pop bp", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("if used ALB16_Pure_Cmp", OK); end if;
      if OK then Line ("ALB16_Pure_Cmp:", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  mov si, dx", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  imul bx", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov ax, cx", OK); end if;
      if OK then Line ("  imul di", OK); end if;
      if OK then Line ("  sub si, ax", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_U32_Mul", OK); end if;
      if OK then Line ("ALB16_U32_Mul:", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  push bp", OK); end if;
      if OK then Line ("  mov si, ax", OK); end if;
      if OK then Line ("  mov di, dx", OK); end if;
      if OK then Line ("  mul bx", OK); end if;
      if OK then Line ("  push ax", OK); end if;
      if OK then Line ("  mov bp, dx", OK); end if;
      if OK then Line ("  mov ax, di", OK); end if;
      if OK then Line ("  mul bx", OK); end if;
      if OK then Line ("  add bp, ax", OK); end if;
      if OK then Line ("  mov ax, si", OK); end if;
      if OK then Line ("  mul cx", OK); end if;
      if OK then Line ("  add bp, ax", OK); end if;
      if OK then Line ("  pop ax", OK); end if;
      if OK then Line ("  mov dx, bp", OK); end if;
      if OK then Line ("  pop bp", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_U32_Div", OK); end if;
      if OK then Line ("ALB16_U32_Div:", OK); end if;
      if OK then Line ("  call ALB16_U32_DivCore", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_QuotLo]", OK); end if;
      if OK then Line ("  mov dx, word [ALB16_U32_QuotHi]", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_U32_Mod", OK); end if;
      if OK then Line ("ALB16_U32_Mod:", OK); end if;
      if OK then Line ("  call ALB16_U32_DivCore", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_RemLo]", OK); end if;
      if OK then Line ("  mov dx, word [ALB16_U32_RemHi]", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;
      if OK then Line ("if used ALB16_U32_DivCore", OK); end if;
      if OK then Line ("ALB16_U32_DivCore:", OK); end if;
      if OK then Line ("  cmp cx, 0", OK); end if;
      if OK then Line ("  jne .alb16_u32_div_have", OK); end if;
      if OK then Line ("  cmp bx, 0", OK); end if;
      if OK then Line ("  jne .alb16_u32_div_have", OK); end if;
      if OK then Line ("  mov bx, ALB16_Runtime_DivZero", OK); end if;
      if OK then Line ("  jmp bx", OK); end if;
      if OK then Line (".alb16_u32_div_have:", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_DividendLo], ax", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_DividendHi], dx", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_DivisorLo], bx", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_DivisorHi], cx", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_QuotLo], 0", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_QuotHi], 0", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_RemLo], 0", OK); end if;
      if OK then Line ("  mov word [ALB16_U32_RemHi], 0", OK); end if;
      if OK then Line ("  mov si, 32", OK); end if;
      if OK then Line (".alb16_u32_div_loop:", OK); end if;
      if OK then Line ("  shl word [ALB16_U32_QuotLo], 1", OK); end if;
      if OK then Line ("  rcl word [ALB16_U32_QuotHi], 1", OK); end if;
      if OK then Line ("  shl word [ALB16_U32_DividendLo], 1", OK); end if;
      if OK then Line ("  rcl word [ALB16_U32_DividendHi], 1", OK); end if;
      if OK then Line ("  rcl word [ALB16_U32_RemLo], 1", OK); end if;
      if OK then Line ("  rcl word [ALB16_U32_RemHi], 1", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_RemHi]", OK); end if;
      if OK then Line ("  cmp ax, word [ALB16_U32_DivisorHi]", OK); end if;
      if OK then Line ("  ja .alb16_u32_div_ge", OK); end if;
      if OK then Line ("  jb .alb16_u32_div_next", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_RemLo]", OK); end if;
      if OK then Line ("  cmp ax, word [ALB16_U32_DivisorLo]", OK); end if;
      if OK then Line ("  jb .alb16_u32_div_next", OK); end if;
      if OK then Line (".alb16_u32_div_ge:", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_DivisorLo]", OK); end if;
      if OK then Line ("  sub word [ALB16_U32_RemLo], ax", OK); end if;
      if OK then Line ("  mov ax, word [ALB16_U32_DivisorHi]", OK); end if;
      if OK then Line ("  sbb word [ALB16_U32_RemHi], ax", OK); end if;
      if OK then Line ("  or word [ALB16_U32_QuotLo], 1", OK); end if;
      if OK then Line (".alb16_u32_div_next:", OK); end if;
      if OK then Line ("  dec si", OK); end if;
      if OK then Line ("  jnz .alb16_u32_div_loop", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      
      RL ("if used ALB16_String_Pool_Dest");
      RL ("ALB16_String_Pool_Dest:");
      RL ("  cmp word [ALB16_Str_Ptr], ALB16_Str_Safe_Limit");
      RL ("  jbe .alb16_str_pool_ok");
      RL ("  mov word [ALB16_Str_Ptr], 0");
      RL (".alb16_str_pool_ok:");
      RL ("  lea di, [ALB16_Str_Pool]");
      RL ("  add di, word [ALB16_Str_Ptr]");
      RL ("  mov word [ALB16_Str_Start], di");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Finish");
      RL ("ALB16_String_Finish:");
      RL ("  mov byte [di], 0");
      RL ("  inc di");
      RL ("  mov ax, di");
      RL ("  sub ax, word [ALB16_Str_Start]");
      RL ("  add word [ALB16_Str_Ptr], ax");
      RL ("  mov ax, word [ALB16_Str_Start]");
      RL ("  mov dx, ax");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Len");
      RL ("ALB16_String_Len:");
      RL ("  push si");
      RL ("  push bx");
      RL ("  mov si, dx");
      RL ("  xor ax, ax");
      RL (".alb16_strlen_loop:");
      RL ("  cmp si, 0");
      RL ("  je .alb16_strlen_done");
      RL ("  mov bl, byte [si]");
      RL ("  cmp bl, 0");
      RL ("  je .alb16_strlen_done");
      RL ("  inc si");
      RL ("  inc ax");
      RL ("  jmp .alb16_strlen_loop");
      RL (".alb16_strlen_done:");
      RL ("  xor dx, dx");
      RL ("  pop bx");
      RL ("  pop si");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Mid");
      RL ("ALB16_String_Mid:");
      RL ("  mov si, dx");
      RL ("  mov cx, bx");
      RL ("  cmp cx, ALB16_Str_Result_Max");
      RL ("  jbe .alb16_mid_count_ok");
      RL ("  mov cx, ALB16_Str_Result_Max");
      RL (".alb16_mid_count_ok:");
      RL ("  cmp ax, 1");
      RL ("  jbe .alb16_mid_dest");
      RL ("  dec ax");
      RL (".alb16_mid_skip:");
      RL ("  cmp ax, 0");
      RL ("  je .alb16_mid_dest");
      RL ("  cmp si, 0");
      RL ("  je .alb16_mid_dest");
      RL ("  mov bl, byte [si]");
      RL ("  cmp bl, 0");
      RL ("  je .alb16_mid_dest");
      RL ("  inc si");
      RL ("  dec ax");
      RL ("  jmp .alb16_mid_skip");
      RL (".alb16_mid_dest:");
      RL ("  call ALB16_String_Pool_Dest");
      RL (".alb16_mid_loop:");
      RL ("  cmp cx, 0");
      RL ("  je .alb16_mid_done");
      RL ("  cmp si, 0");
      RL ("  je .alb16_mid_done");
      RL ("  mov al, byte [si]");
      RL ("  cmp al, 0");
      RL ("  je .alb16_mid_done");
      RL ("  mov byte [di], al");
      RL ("  inc si");
      RL ("  inc di");
      RL ("  dec cx");
      RL ("  jmp .alb16_mid_loop");
      RL (".alb16_mid_done:");
      RL ("  jmp ALB16_String_Finish");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Left");
      RL ("ALB16_String_Left:");
      RL ("  mov bx, ax");
      RL ("  mov ax, 1");
      RL ("  jmp ALB16_String_Mid");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Right");
      RL ("ALB16_String_Right:");
      RL ("  mov word [ALB16_Str_Start], dx");
      RL ("  mov word [ALB16_Str_Count], ax");
      RL ("  call ALB16_String_Len");
      RL ("  mov cx, word [ALB16_Str_Count]");
      RL ("  cmp cx, ax");
      RL ("  jbe .alb16_right_have_count");
      RL ("  mov cx, ax");
      RL (".alb16_right_have_count:");
      RL ("  sub ax, cx");
      RL ("  inc ax");
      RL ("  mov bx, cx");
      RL ("  mov dx, word [ALB16_Str_Start]");
      RL ("  jmp ALB16_String_Mid");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Concat");
      RL ("ALB16_String_Concat:");
      RL ("  mov si, dx");
      RL ("  mov word [ALB16_Str_Count], bx");
      RL ("  call ALB16_String_Pool_Dest");
      RL ("  mov cx, ALB16_Str_Result_Max");
      RL (".alb16_concat_left:");
      RL ("  cmp cx, 0");
      RL ("  je .alb16_concat_done");
      RL ("  cmp si, 0");
      RL ("  je .alb16_concat_right_start");
      RL ("  mov al, byte [si]");
      RL ("  cmp al, 0");
      RL ("  je .alb16_concat_right_start");
      RL ("  mov byte [di], al");
      RL ("  inc si");
      RL ("  inc di");
      RL ("  dec cx");
      RL ("  jmp .alb16_concat_left");
      RL (".alb16_concat_right_start:");
      RL ("  mov si, word [ALB16_Str_Count]");
      RL (".alb16_concat_right:");
      RL ("  cmp cx, 0");
      RL ("  je .alb16_concat_done");
      RL ("  cmp si, 0");
      RL ("  je .alb16_concat_done");
      RL ("  mov al, byte [si]");
      RL ("  cmp al, 0");
      RL ("  je .alb16_concat_done");
      RL ("  mov byte [di], al");
      RL ("  inc si");
      RL ("  inc di");
      RL ("  dec cx");
      RL ("  jmp .alb16_concat_right");
      RL (".alb16_concat_done:");
      RL ("  jmp ALB16_String_Finish");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Write_U32");
      RL ("ALB16_String_Write_U32:");
      RL ("  push bp");
      RL ("  push si");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  mov si, dx");
      RL ("  mov bx, ax");
      RL ("  cmp si, 0");
      RL ("  jne .alb16_write_u32_convert");
      RL ("  cmp bx, 0");
      RL ("  jne .alb16_write_u32_convert");
      RL ("  mov byte [di], 30h");
      RL ("  inc di");
      RL ("  jmp .alb16_write_u32_done");
      RL (".alb16_write_u32_convert:");
      RL ("  xor cx, cx");
      RL ("  mov bp, 10");
      RL (".alb16_write_u32_next:");
      RL ("  mov ax, si");
      RL ("  xor dx, dx");
      RL ("  div bp");
      RL ("  mov si, ax");
      RL ("  mov ax, bx");
      RL ("  div bp");
      RL ("  mov bx, ax");
      RL ("  push dx");
      RL ("  inc cx");
      RL ("  cmp si, 0");
      RL ("  jne .alb16_write_u32_next");
      RL ("  cmp bx, 0");
      RL ("  jne .alb16_write_u32_next");
      RL (".alb16_write_u32_emit:");
      RL ("  pop dx");
      RL ("  add dl, 30h");
      RL ("  mov byte [di], dl");
      RL ("  inc di");
      RL ("  loop .alb16_write_u32_emit");
      RL (".alb16_write_u32_done:");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  pop si");
      RL ("  pop bp");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_Write_S32");
      RL ("ALB16_String_Write_S32:");
      RL ("  test dx, 8000h");
      RL ("  jz .alb16_write_s32_positive");
      RL ("  mov byte [di], 2Dh");
      RL ("  inc di");
      RL ("  neg ax");
      RL ("  adc dx, 0");
      RL ("  neg dx");
      RL (".alb16_write_s32_positive:");
      RL ("  call ALB16_String_Write_U32");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_From_U32");
      RL ("ALB16_String_From_U32:");
      RL ("  call ALB16_String_Pool_Dest");
      RL ("  call ALB16_String_Write_U32");
      RL ("  jmp ALB16_String_Finish");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_From_S32");
      RL ("ALB16_String_From_S32:");
      RL ("  call ALB16_String_Pool_Dest");
      RL ("  call ALB16_String_Write_S32");
      RL ("  jmp ALB16_String_Finish");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_String_From_Pure");
      RL ("ALB16_String_From_Pure:");
      RL ("  push bx");
      RL ("  mov bx, ax");
      RL ("  call ALB16_String_Pool_Dest");
      RL ("  push bx");
      RL ("  mov ax, dx");
      RL ("  cwd");
      RL ("  call ALB16_String_Write_S32");
      RL ("  pop bx");
      RL ("  mov byte [di], 20h");
      RL ("  inc di");
      RL ("  mov byte [di], 2Fh");
      RL ("  inc di");
      RL ("  mov byte [di], 20h");
      RL ("  inc di");
      RL ("  mov ax, bx");
      RL ("  xor dx, dx");
      RL ("  call ALB16_String_Write_U32");
      RL ("  pop bx");
      RL ("  jmp ALB16_String_Finish");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_Str_Eq");
      RL ("ALB16_Str_Eq:");
      RL ("  push si");
      RL ("  push di");
      RL ("  mov si, dx");
      RL ("  mov di, bx");
      RL (".alb16_streq_loop:");
      RL ("  xor ax, ax");
      RL ("  cmp si, 0");
      RL ("  je .alb16_streq_left_ready");
      RL ("  mov al, byte [si]");
      RL (".alb16_streq_left_ready:");
      RL ("  cmp di, 0");
      RL ("  je .alb16_streq_right_ready");
      RL ("  mov ah, byte [di]");
      RL (".alb16_streq_right_ready:");
      RL ("  cmp al, ah");
      RL ("  jne .alb16_streq_false");
      RL ("  cmp al, 0");
      RL ("  je .alb16_streq_true");
      RL ("  inc si");
      RL ("  inc di");
      RL ("  jmp .alb16_streq_loop");
      RL (".alb16_streq_true:");
      RL ("  mov ax, 1");
      RL ("  xor dx, dx");
      RL ("  jmp .alb16_streq_done");
      RL (".alb16_streq_false:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".alb16_streq_done:");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_File_Open");
      RL ("ALB16_File_Open:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  mov si, bx");
      RL ("  cmp si, 0");
      RL ("  je .alb16_file_open_read");
      RL ("  mov al, byte [si]");
      RL ("  cmp al, 77h");
      RL ("  je .alb16_file_open_create");
      RL ("  cmp al, 57h");
      RL ("  je .alb16_file_open_create");
      RL ("  cmp al, 61h");
      RL ("  je .alb16_file_open_append");
      RL ("  cmp al, 41h");
      RL ("  je .alb16_file_open_append");
      RL (".alb16_file_open_read:");
      RL ("  mov ax, 3D00h");
      RL ("  int 21h");
      RL ("  jnc .alb16_file_open_done");
      RL ("  xor ax, ax");
      RL ("  jmp .alb16_file_open_done");
      RL (".alb16_file_open_create:");
      RL ("  mov ah, 3Ch");
      RL ("  xor cx, cx");
      RL ("  int 21h");
      RL ("  jnc .alb16_file_open_done");
      RL ("  xor ax, ax");
      RL ("  jmp .alb16_file_open_done");
      RL (".alb16_file_open_append:");
      RL ("  mov ax, 3D02h");
      RL ("  int 21h");
      RL ("  jnc .alb16_file_open_seek_end");
      RL ("  mov ah, 3Ch");
      RL ("  xor cx, cx");
      RL ("  int 21h");
      RL ("  jnc .alb16_file_open_done");
      RL ("  xor ax, ax");
      RL ("  jmp .alb16_file_open_done");
      RL (".alb16_file_open_seek_end:");
      RL ("  mov bx, ax");
      RL ("  mov ax, 4202h");
      RL ("  xor cx, cx");
      RL ("  xor dx, dx");
      RL ("  int 21h");
      RL ("  mov ax, bx");
      RL (".alb16_file_open_done:");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_File_Read");
      RL ("ALB16_File_Read:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push si");
      RL ("  push di");
      RL ("  mov word [ALB16_File_Handle], bx");
      RL ("  mov word [ALB16_File_Count], cx");
      RL ("  lea di, [ALB16_File_Buffer]");
      RL ("  cmp cx, 0");
      RL ("  jne .alb16_file_read_binary");
      RL ("  xor si, si");
      RL (".alb16_file_read_line_loop:");
      RL ("  cmp si, ALB16_File_Buffer_Max - 1");
      RL ("  jae .alb16_file_read_line_done");
      RL ("  mov bx, word [ALB16_File_Handle]");
      RL ("  mov ah, 3Fh");
      RL ("  mov cx, 1");
      RL ("  mov dx, ALB16_File_Byte");
      RL ("  int 21h");
      RL ("  jc .alb16_file_read_line_done");
      RL ("  cmp ax, 0");
      RL ("  je .alb16_file_read_line_done");
      RL ("  mov al, byte [ALB16_File_Byte]");
      RL ("  cmp al, 13");
      RL ("  je .alb16_file_read_line_done");
      RL ("  cmp al, 10");
      RL ("  je .alb16_file_read_line_done");
      RL ("  mov byte [di], al");
      RL ("  inc di");
      RL ("  inc si");
      RL ("  jmp .alb16_file_read_line_loop");
      RL (".alb16_file_read_line_done:");
      RL ("  mov byte [di], 0");
      RL ("  mov ax, ALB16_File_Buffer");
      RL ("  mov dx, ax");
      RL ("  jmp .alb16_file_read_done");
      RL (".alb16_file_read_binary:");
      RL ("  mov cx, word [ALB16_File_Count]");
      RL ("  cmp cx, ALB16_File_Buffer_Max - 1");
      RL ("  jbe .alb16_file_read_binary_count_ok");
      RL ("  mov cx, ALB16_File_Buffer_Max - 1");
      RL (".alb16_file_read_binary_count_ok:");
      RL ("  mov bx, word [ALB16_File_Handle]");
      RL ("  lea dx, [ALB16_File_Buffer]");
      RL ("  mov ah, 3Fh");
      RL ("  int 21h");
      RL ("  jc .alb16_file_read_fail");
      RL ("  lea di, [ALB16_File_Buffer]");
      RL ("  add di, ax");
      RL ("  mov byte [di], 0");
      RL ("  mov ax, ALB16_File_Buffer");
      RL ("  mov dx, ax");
      RL ("  jmp .alb16_file_read_done");
      RL (".alb16_file_read_fail:");
      RL ("  mov byte [ALB16_File_Buffer], 0");
      RL ("  mov ax, ALB16_File_Buffer");
      RL ("  mov dx, ax");
      RL (".alb16_file_read_done:");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_File_Write");
      RL ("ALB16_File_Write:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  mov si, dx");
      RL ("  call ALB16_String_Len");
      RL ("  mov cx, ax");
      RL ("  mov dx, si");
      RL ("  mov ah, 40h");
      RL ("  int 21h");
      RL ("  jnc .alb16_file_write_done");
      RL ("  xor ax, ax");
      RL (".alb16_file_write_done:");
      RL ("  xor dx, dx");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_File_Close");
      RL ("ALB16_File_Close:");
      RL ("  push ax");
      RL ("  cmp bx, 0");
      RL ("  je .alb16_file_close_done");
      RL ("  mov ah, 3Eh");
      RL ("  int 21h");
      RL (".alb16_file_close_done:");
      RL ("  pop ax");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_File_Load");
      RL ("ALB16_File_Load:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push di");
      RL ("  mov word [ALB16_File_Count], cx");
      RL ("  mov ax, 3D00h");
      RL ("  int 21h");
      RL ("  jc .alb16_file_load_fail");
      RL ("  mov word [ALB16_File_Handle], ax");
      RL ("  mov bx, ax");
      RL ("  mov cx, word [ALB16_File_Count]");
      RL ("  mov dx, di");
      RL ("  mov ah, 3Fh");
      RL ("  int 21h");
      RL ("  jc .alb16_file_load_close_fail");
      RL ("  push ax");
      RL ("  mov bx, word [ALB16_File_Handle]");
      RL ("  mov ah, 3Eh");
      RL ("  int 21h");
      RL ("  pop ax");
      RL ("  xor dx, dx");
      RL ("  jmp .alb16_file_load_done");
      RL (".alb16_file_load_close_fail:");
      RL ("  mov bx, word [ALB16_File_Handle]");
      RL ("  mov ah, 3Eh");
      RL ("  int 21h");
      RL (".alb16_file_load_fail:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".alb16_file_load_done:");
      RL ("  pop di");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_File_Flush");
      RL ("ALB16_File_Flush:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  mov word [ALB16_File_Count], cx");
      RL ("  mov ah, 3Ch");
      RL ("  xor cx, cx");
      RL ("  int 21h");
      RL ("  jc .alb16_file_flush_fail");
      RL ("  mov word [ALB16_File_Handle], ax");
      RL ("  mov bx, ax");
      RL ("  mov cx, word [ALB16_File_Count]");
      RL ("  mov dx, si");
      RL ("  mov ah, 40h");
      RL ("  int 21h");
      RL ("  jc .alb16_file_flush_close_fail");
      RL ("  push ax");
      RL ("  mov bx, word [ALB16_File_Handle]");
      RL ("  mov ah, 3Eh");
      RL ("  int 21h");
      RL ("  pop ax");
      RL ("  xor dx, dx");
      RL ("  jmp .alb16_file_flush_done");
      RL (".alb16_file_flush_close_fail:");
      RL ("  mov bx, word [ALB16_File_Handle]");
      RL ("  mov ah, 3Eh");
      RL ("  int 21h");
      RL (".alb16_file_flush_fail:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".alb16_file_flush_done:");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_Readline_Read");
      RL ("ALB16_Readline_Read:");
      RL ("  push bx");
      RL ("  mov dx, ALB16_Line_Buffer");
      RL ("  mov ah, 0Ah");
      RL ("  int 21h");
      RL ("  call ALB16_Print_Newline");
      RL ("  xor bx, bx");
      RL ("  mov bl, byte [ALB16_Line_Buffer+1]");
      RL ("  mov byte [ALB16_Line_Buffer+2+bx], 0");
      RL ("  mov ax, ALB16_Line_Buffer+2");
      RL ("  mov dx, ax");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      
      RL ("if used ALB16_Input_Read_U32");
      RL ("ALB16_Input_Read_U32:");
      RL ("  call ALB16_Read_Input_Buffer");
      RL ("  call ALB16_Parse_Input_Decimal");
      RL ("  cmp byte [ALB16_Input_Neg], 0");
      Trap_Jcc ("jne", "ALB16_Runtime_Range");
      RL ("  ret");
      RL ("end if");

      RL ("if used ALB16_Input_Read_S32");
      RL ("ALB16_Input_Read_S32:");
      RL ("  call ALB16_Read_Input_Buffer");
      RL ("  call ALB16_Parse_Input_Decimal");
      RL ("  cmp byte [ALB16_Input_Neg], 0");
      RL ("  jne .alb16_input_s32_neg");
      RL ("  cmp dx, 7FFFh");
      Trap_Jcc ("ja", "ALB16_Runtime_Range");
      RL ("  ret");
      RL (".alb16_input_s32_neg:");
      RL ("  cmp dx, 8000h");
      Trap_Jcc ("ja", "ALB16_Runtime_Range");
      RL ("  jb .alb16_input_s32_apply_neg");
      RL ("  cmp ax, 0");
      Trap_Jcc ("jne", "ALB16_Runtime_Range");
      RL (".alb16_input_s32_apply_neg:");
      RL ("  neg ax");
      RL ("  adc dx, 0");
      RL ("  neg dx");
      RL ("  ret");
      RL ("end if");

      RL ("if used ALB16_Read_Input_Buffer");
      RL ("ALB16_Read_Input_Buffer:");
      RL ("  push ax");
      RL ("  push dx");
      RL ("  mov dx, ALB16_Input_Buffer");
      RL ("  mov ah, 0Ah");
      RL ("  int 21h");
      RL ("  call ALB16_Print_Newline");
      RL ("  pop dx");
      RL ("  pop ax");
      RL ("  ret");
      RL ("end if");

      RL ("if used ALB16_Parse_Input_Decimal");
      RL ("ALB16_Parse_Input_Decimal:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push si");
      RL ("  mov word [ALB16_Input_ValueLo], 0");
      RL ("  mov word [ALB16_Input_ValueHi], 0");
      RL ("  mov byte [ALB16_Input_Digit], 0");
      RL ("  mov byte [ALB16_Input_Neg], 0");
      RL ("  mov byte [ALB16_Input_Seen], 0");
      RL ("  lea si, [ALB16_Input_Buffer+2]");
      RL ("  xor cx, cx");
      RL ("  mov cl, byte [ALB16_Input_Buffer+1]");
      RL (".alb16_input_skip:");
      RL ("  cmp cl, 0");
      Trap_Jcc ("je", "ALB16_Runtime_Range");
      RL ("  mov bl, byte [si]");
      RL ("  cmp bl, 20h");
      RL ("  je .alb16_input_skip_adv");
      RL ("  cmp bl, 09h");
      RL ("  je .alb16_input_skip_adv");
      RL ("  jmp .alb16_input_sign");
      RL (".alb16_input_skip_adv:");
      RL ("  inc si");
      RL ("  dec cl");
      RL ("  jmp .alb16_input_skip");
      RL (".alb16_input_sign:");
      RL ("  cmp bl, 2Dh");
      RL ("  jne .alb16_input_plus");
      RL ("  mov byte [ALB16_Input_Neg], 1");
      RL ("  inc si");
      RL ("  dec cl");
      RL ("  jmp .alb16_input_digits");
      RL (".alb16_input_plus:");
      RL ("  cmp bl, 2Bh");
      RL ("  jne .alb16_input_digits");
      RL ("  inc si");
      RL ("  dec cl");
      RL (".alb16_input_digits:");
      RL ("  cmp cl, 0");
      RL ("  je .alb16_input_after_digits");
      RL ("  mov bl, byte [si]");
      RL ("  cmp bl, 30h");
      RL ("  jb .alb16_input_after_digits");
      RL ("  cmp bl, 39h");
      RL ("  ja .alb16_input_after_digits");
      RL ("  sub bl, 30h");
      RL ("  mov byte [ALB16_Input_Digit], bl");
      RL ("  mov ax, word [ALB16_Input_ValueHi]");
      RL ("  cmp ax, 1999h");
      Trap_Jcc ("ja", "ALB16_Runtime_Range");
      RL ("  jb .alb16_input_mul");
      RL ("  mov ax, word [ALB16_Input_ValueLo]");
      RL ("  cmp ax, 9999h");
      Trap_Jcc ("ja", "ALB16_Runtime_Range");
      RL ("  jb .alb16_input_mul");
      RL ("  mov al, byte [ALB16_Input_Digit]");
      RL ("  cmp al, 5");
      Trap_Jcc ("ja", "ALB16_Runtime_Range");
      RL (".alb16_input_mul:");
      RL ("  mov ax, word [ALB16_Input_ValueLo]");
      RL ("  mov dx, word [ALB16_Input_ValueHi]");
      RL ("  push cx");
      RL ("  mov bx, 10");
      RL ("  xor cx, cx");
      RL ("  call ALB16_U32_Mul");
      RL ("  pop cx");
      RL ("  xor bx, bx");
      RL ("  mov bl, byte [ALB16_Input_Digit]");
      RL ("  add ax, bx");
      RL ("  adc dx, 0");
      Trap_Jcc ("jc", "ALB16_Runtime_Range");
      RL ("  mov word [ALB16_Input_ValueLo], ax");
      RL ("  mov word [ALB16_Input_ValueHi], dx");
      RL ("  mov byte [ALB16_Input_Seen], 1");
      RL ("  inc si");
      RL ("  dec cl");
      RL ("  jmp .alb16_input_digits");
      RL (".alb16_input_after_digits:");
      RL ("  cmp byte [ALB16_Input_Seen], 0");
      Trap_Jcc ("je", "ALB16_Runtime_Range");
      RL (".alb16_input_trail:");
      RL ("  cmp cl, 0");
      RL ("  je .alb16_input_done");
      RL ("  mov bl, byte [si]");
      RL ("  cmp bl, 20h");
      RL ("  je .alb16_input_trail_adv");
      RL ("  cmp bl, 09h");
      RL ("  je .alb16_input_trail_adv");
      RL ("  mov bx, ALB16_Runtime_Range");
      RL ("  jmp bx");
      RL (".alb16_input_trail_adv:");
      RL ("  inc si");
      RL ("  dec cl");
      RL ("  jmp .alb16_input_trail");
      RL (".alb16_input_done:");
      RL ("  mov ax, word [ALB16_Input_ValueLo]");
      RL ("  mov dx, word [ALB16_Input_ValueHi]");
      RL ("  pop si");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      
      RL ("if used ALB16_Hash");
      RL ("ALB16_Hash:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push si");
      RL ("  mov ax, 5381");
      RL ("  xor dx, dx");
      RL (".alb16_hash_loop:");
      RL ("  mov bl, byte [si]");
      RL ("  cmp bl, 0");
      RL ("  je .alb16_hash_done");
      RL ("  mov word [ALB16_Hash_OldLo], ax");
      RL ("  mov word [ALB16_Hash_OldHi], dx");
      RL ("  mov cx, 5");
      RL (".alb16_hash_mul32:");
      RL ("  shl ax, 1");
      RL ("  rcl dx, 1");
      RL ("  loop .alb16_hash_mul32");
      RL ("  add ax, word [ALB16_Hash_OldLo]");
      RL ("  adc dx, word [ALB16_Hash_OldHi]");
      RL ("  xor bh, bh");
      RL ("  add ax, bx");
      RL ("  adc dx, 0");
      RL ("  inc si");
      RL ("  jmp .alb16_hash_loop");
      RL (".alb16_hash_done:");
      RL ("  pop si");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_KB_Cell_To_SI");
      RL ("ALB16_KB_Cell_To_SI:");
      RL ("  mov bx, cx");
      RL ("  shl bx, 1");
      RL ("  shl bx, 1");
      RL ("  mov di, bx");
      RL ("  shl bx, 1");
      RL ("  add bx, di");
      RL ("  add bx, cx");
      RL ("  lea si, [ALB16_KB]");
      RL ("  add si, bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_Assert");
      RL ("ALB16_Assert:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  mov word [ALB16_KB_ArgLo], ax");
      RL ("  mov word [ALB16_KB_ArgHi], dx");
      RL ("  mov word [ALB16_KB_ValLo], bx");
      RL ("  mov word [ALB16_KB_ValHi], cx");
      RL ("  call ALB16_Hash");
      RL ("  mov word [ALB16_KB_HashLo], ax");
      RL ("  mov word [ALB16_KB_HashHi], dx");
      RL ("  xor cx, cx");
      RL (".alb16_assert_loop:");
      RL ("  cmp cx, 1024");
      RL ("  jae .alb16_assert_done");
      RL ("  call ALB16_KB_Cell_To_SI");
      RL ("  cmp byte [si + ALB16_Fact_Active], 0");
      RL ("  je .alb16_assert_write");
      RL ("  mov ax, word [si + ALB16_Fact_HashLo]");
      RL ("  cmp ax, word [ALB16_KB_HashLo]");
      RL ("  jne .alb16_assert_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashHi]");
      RL ("  cmp ax, word [ALB16_KB_HashHi]");
      RL ("  jne .alb16_assert_next");
      RL ("  mov ax, word [si + ALB16_Fact_ArgLo]");
      RL ("  cmp ax, word [ALB16_KB_ArgLo]");
      RL ("  jne .alb16_assert_next");
      RL ("  mov ax, word [si + ALB16_Fact_ArgHi]");
      RL ("  cmp ax, word [ALB16_KB_ArgHi]");
      RL ("  jne .alb16_assert_next");
      RL (".alb16_assert_write:");
      RL ("  mov ax, word [ALB16_KB_HashLo]");
      RL ("  mov word [si + ALB16_Fact_HashLo], ax");
      RL ("  mov ax, word [ALB16_KB_HashHi]");
      RL ("  mov word [si + ALB16_Fact_HashHi], ax");
      RL ("  mov ax, word [ALB16_KB_ArgLo]");
      RL ("  mov word [si + ALB16_Fact_ArgLo], ax");
      RL ("  mov ax, word [ALB16_KB_ArgHi]");
      RL ("  mov word [si + ALB16_Fact_ArgHi], ax");
      RL ("  mov ax, word [ALB16_KB_ValLo]");
      RL ("  mov word [si + ALB16_Fact_ValLo], ax");
      RL ("  mov ax, word [ALB16_KB_ValHi]");
      RL ("  mov word [si + ALB16_Fact_ValHi], ax");
      RL ("  mov byte [si + ALB16_Fact_Active], 1");
      RL ("  jmp .alb16_assert_done");
      RL (".alb16_assert_next:");
      RL ("  inc cx");
      RL ("  jmp .alb16_assert_loop");
      RL (".alb16_assert_done:");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_Query");
      RL ("ALB16_Query:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push si");
      RL ("  push di");
      RL ("  mov word [ALB16_KB_ArgLo], ax");
      RL ("  mov word [ALB16_KB_ArgHi], dx");
      RL ("  call ALB16_Hash");
      RL ("  mov word [ALB16_KB_HashLo], ax");
      RL ("  mov word [ALB16_KB_HashHi], dx");
      RL ("  xor cx, cx");
      RL (".alb16_query_loop:");
      RL ("  cmp cx, 1024");
      RL ("  jae .alb16_query_fail");
      RL ("  call ALB16_KB_Cell_To_SI");
      RL ("  cmp byte [si + ALB16_Fact_Active], 0");
      RL ("  je .alb16_query_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashLo]");
      RL ("  cmp ax, word [ALB16_KB_HashLo]");
      RL ("  jne .alb16_query_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashHi]");
      RL ("  cmp ax, word [ALB16_KB_HashHi]");
      RL ("  jne .alb16_query_next");
      RL ("  mov ax, word [si + ALB16_Fact_ArgLo]");
      RL ("  cmp ax, word [ALB16_KB_ArgLo]");
      RL ("  jne .alb16_query_check_val");
      RL ("  mov ax, word [si + ALB16_Fact_ArgHi]");
      RL ("  cmp ax, word [ALB16_KB_ArgHi]");
      RL ("  je .alb16_query_succ");
      RL (".alb16_query_check_val:");
      RL ("  mov ax, word [si + ALB16_Fact_ValLo]");
      RL ("  cmp ax, word [ALB16_KB_ArgLo]");
      RL ("  jne .alb16_query_next");
      RL ("  mov ax, word [si + ALB16_Fact_ValHi]");
      RL ("  cmp ax, word [ALB16_KB_ArgHi]");
      RL ("  je .alb16_query_succ");
      RL (".alb16_query_next:");
      RL ("  inc cx");
      RL ("  jmp .alb16_query_loop");
      RL (".alb16_query_succ:");
      RL ("  mov ax, 1");
      RL ("  xor dx, dx");
      RL ("  jmp .alb16_query_done");
      RL (".alb16_query_fail:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".alb16_query_done:");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_Find");
      RL ("ALB16_Find:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push si");
      RL ("  push di");
      RL ("  call ALB16_Hash");
      RL ("  mov word [ALB16_KB_HashLo], ax");
      RL ("  mov word [ALB16_KB_HashHi], dx");
      RL ("  xor cx, cx");
      RL (".alb16_find_loop:");
      RL ("  cmp cx, 1024");
      RL ("  jae .alb16_find_fail");
      RL ("  call ALB16_KB_Cell_To_SI");
      RL ("  cmp byte [si + ALB16_Fact_Active], 0");
      RL ("  je .alb16_find_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashLo]");
      RL ("  cmp ax, word [ALB16_KB_HashLo]");
      RL ("  jne .alb16_find_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashHi]");
      RL ("  cmp ax, word [ALB16_KB_HashHi]");
      RL ("  jne .alb16_find_next");
      RL ("  mov ax, word [si + ALB16_Fact_ValLo]");
      RL ("  mov dx, word [si + ALB16_Fact_ValHi]");
      RL ("  mov bx, ax");
      RL ("  or bx, dx");
      RL ("  jnz .alb16_find_done");
      RL ("  mov ax, word [si + ALB16_Fact_ArgLo]");
      RL ("  mov dx, word [si + ALB16_Fact_ArgHi]");
      RL ("  jmp .alb16_find_done");
      RL (".alb16_find_next:");
      RL ("  inc cx");
      RL ("  jmp .alb16_find_loop");
      RL (".alb16_find_fail:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".alb16_find_done:");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");
      
      
      RL ("if used ALB16_Retract");
      RL ("ALB16_Retract:");
      RL ("  push bx");
      RL ("  push cx");
      RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  mov word [ALB16_KB_ArgLo], ax");
      RL ("  mov word [ALB16_KB_ArgHi], dx");
      RL ("  call ALB16_Hash");
      RL ("  mov word [ALB16_KB_HashLo], ax");
      RL ("  mov word [ALB16_KB_HashHi], dx");
      RL ("  xor cx, cx");
      RL (".alb16_retract_loop:");
      RL ("  cmp cx, 1024");
      RL ("  jae .alb16_retract_done");
      RL ("  call ALB16_KB_Cell_To_SI");
      RL ("  cmp byte [si + ALB16_Fact_Active], 0");
      RL ("  je .alb16_retract_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashLo]");
      RL ("  cmp ax, word [ALB16_KB_HashLo]");
      RL ("  jne .alb16_retract_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashHi]");
      RL ("  cmp ax, word [ALB16_KB_HashHi]");
      RL ("  jne .alb16_retract_next");
      RL ("  mov ax, word [si + ALB16_Fact_ArgLo]");
      RL ("  cmp ax, word [ALB16_KB_ArgLo]");
      RL ("  jne .alb16_retract_next");
      RL ("  mov ax, word [si + ALB16_Fact_ArgHi]");
      RL ("  cmp ax, word [ALB16_KB_ArgHi]");
      RL ("  jne .alb16_retract_next");
      RL ("  mov byte [si + ALB16_Fact_Active], 0");
      RL ("  jmp .alb16_retract_done");
      RL (".alb16_retract_next:");
      RL ("  inc cx");
      RL ("  jmp .alb16_retract_loop");
      RL (".alb16_retract_done:");
      RL ("  pop di");
      RL ("  pop si");
      RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_Update");
      RL ("ALB16_Update:");
      RL ("  push bx");
      RL ("  push cx");
      --RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  mov word [ALB16_KB_ArgLo], ax");
      RL ("  mov word [ALB16_KB_ArgHi], dx");
      RL ("  mov word [ALB16_KB_ValLo], bx");
      RL ("  mov word [ALB16_KB_ValHi], cx");
      RL ("  call ALB16_Hash");
      RL ("  mov word [ALB16_KB_HashLo], ax");
      RL ("  mov word [ALB16_KB_HashHi], dx");
      RL ("  xor cx, cx");
      RL (".alb16_update_loop:");
      RL ("  cmp cx, 1024");
      RL ("  jae .alb16_update_fail");
      RL ("  call ALB16_KB_Cell_To_SI");
      RL ("  cmp byte [si + ALB16_Fact_Active], 0");
      RL ("  je .alb16_update_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashLo]");
      RL ("  cmp ax, word [ALB16_KB_HashLo]");
      RL ("  jne .alb16_update_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashHi]");
      RL ("  cmp ax, word [ALB16_KB_HashHi]");
      RL ("  jne .alb16_update_next");
      RL ("  mov ax, word [si + ALB16_Fact_ArgLo]");
      RL ("  cmp ax, word [ALB16_KB_ArgLo]");
      RL ("  jne .alb16_update_check_val");
      RL ("  mov ax, word [si + ALB16_Fact_ArgHi]");
      RL ("  cmp ax, word [ALB16_KB_ArgHi]");
      RL ("  jne .alb16_update_check_val");
      RL ("  mov ax, word [ALB16_KB_ValLo]");
      RL ("  mov word [si + ALB16_Fact_ArgLo], ax");
      RL ("  mov ax, word [ALB16_KB_ValHi]");
      RL ("  mov word [si + ALB16_Fact_ArgHi], ax");
      RL ("  jmp .alb16_update_succ");
      RL (".alb16_update_check_val:");
      RL ("  mov ax, word [si + ALB16_Fact_ValLo]");
      RL ("  cmp ax, word [ALB16_KB_ArgLo]");
      RL ("  jne .alb16_update_next");
      RL ("  mov ax, word [si + ALB16_Fact_ValHi]");
      RL ("  cmp ax, word [ALB16_KB_ArgHi]");
      RL ("  jne .alb16_update_next");
      RL ("  mov ax, word [ALB16_KB_ValLo]");
      RL ("  mov word [si + ALB16_Fact_ValLo], ax");
      RL ("  mov ax, word [ALB16_KB_ValHi]");
      RL ("  mov word [si + ALB16_Fact_ValHi], ax");
      RL ("  jmp .alb16_update_succ");
      RL (".alb16_update_next:");
      RL ("  inc cx");
      RL ("  jmp .alb16_update_loop");
      RL (".alb16_update_succ:");
      RL ("  mov ax, 1");
      RL ("  xor dx, dx");
      RL ("  jmp .alb16_update_done");
      RL (".alb16_update_fail:");
      RL ("  xor ax, ax");
      RL ("  xor dx, dx");
      RL (".alb16_update_done:");
      RL ("  pop di");
      RL ("  pop si");
      --RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");

      RL ("if used ALB16_FindAll");
      RL ("ALB16_FindAll:");
      RL ("  push bx");
      RL ("  push cx");
      --RL ("  push dx");
      RL ("  push si");
      RL ("  push di");
      RL ("  mov word [ALB16_KB_OutPtr], di");
      RL ("  mov word [ALB16_KB_Count], 0");
      RL ("  call ALB16_Hash");
      RL ("  mov word [ALB16_KB_HashLo], ax");
      RL ("  mov word [ALB16_KB_HashHi], dx");
      RL ("  xor cx, cx");
      RL (".alb16_findall_loop:");
      RL ("  cmp cx, 1024");
      RL ("  jae .alb16_findall_done");
      RL ("  call ALB16_KB_Cell_To_SI");
      RL ("  cmp byte [si + ALB16_Fact_Active], 0");
      RL ("  je .alb16_findall_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashLo]");
      RL ("  cmp ax, word [ALB16_KB_HashLo]");
      RL ("  jne .alb16_findall_next");
      RL ("  mov ax, word [si + ALB16_Fact_HashHi]");
      RL ("  cmp ax, word [ALB16_KB_HashHi]");
      RL ("  jne .alb16_findall_next");
      RL ("  mov ax, word [si + ALB16_Fact_ValLo]");
      RL ("  mov dx, word [si + ALB16_Fact_ValHi]");
      RL ("  mov bx, ax");
      RL ("  or bx, dx");
      RL ("  jnz .alb16_findall_have_value");
      RL ("  mov ax, word [si + ALB16_Fact_ArgLo]");
      RL ("  mov dx, word [si + ALB16_Fact_ArgHi]");
      RL (".alb16_findall_have_value:");
      RL ("  push cx");
      RL ("  mov bx, word [ALB16_KB_Count]");
      RL ("  inc bx");
      RL ("  shl bx, 1");
      RL ("  shl bx, 1");
      RL ("  mov di, word [ALB16_KB_OutPtr]");
      RL ("  add di, bx");
      RL ("  mov word [di], ax");
      RL ("  mov word [di+2], dx");
      RL ("  inc word [ALB16_KB_Count]");
      RL ("  pop cx");
      RL (".alb16_findall_next:");
      RL ("  inc cx");
      RL ("  jmp .alb16_findall_loop");
      RL (".alb16_findall_done:");
      RL ("  mov ax, word [ALB16_KB_Count]");
      RL ("  xor dx, dx");
      RL ("  pop di");
      RL ("  pop si");
      --RL ("  pop dx");
      RL ("  pop cx");
      RL ("  pop bx");
      RL ("  ret");
      RL ("end if");
      RL ("");
      
      if OK then Line ("if used ALB16_GC_Claim", OK); end if;
      if OK then Line ("ALB16_GC_Claim:", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  mov cx, 1", OK); end if;
      if OK then Line (".claim_loop:", OK); end if;
      if OK then Line ("  cmp cx, 1024", OK); end if;
      if OK then Line ("  ja .claim_fail", OK); end if;
      if OK then Line ("  mov ax, cx", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  mov dx, ax", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  add ax, dx", OK); end if;
      if OK then Line ("  lea si, [ALB16_GC_Grid]", OK); end if;
      if OK then Line ("  add si, ax", OK); end if;
      if OK then Line ("  cmp byte [si + ALB16_GC_Node_Alive], 0", OK); end if;
      if OK then Line ("  jne .claim_next", OK); end if;
      if OK then Line ("  mov byte [si + ALB16_GC_Node_Alive], 1", OK); end if;
      if OK then Line ("  mov byte [si + ALB16_GC_Node_Refs], 1", OK); end if;
      if OK then Line ("  mov word [si + ALB16_GC_Node_Child1], 0", OK); end if;
      if OK then Line ("  mov word [si + ALB16_GC_Node_Child2], 0", OK); end if;
      if OK then Line ("  mov ax, cx", OK); end if;
      if OK then Line ("  jmp .claim_done", OK); end if;
      if OK then Line (".claim_next:", OK); end if;
      if OK then Line ("  inc cx", OK); end if;
      if OK then Line ("  jmp .claim_loop", OK); end if;
      if OK then Line (".claim_fail:", OK); end if;
      if OK then Line ("  xor ax, ax", OK); end if;
      if OK then Line (".claim_done:", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_GC_Drop", OK); end if;
      if OK then Line ("ALB16_GC_Drop:", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  test ax, ax", OK); end if;
      if OK then Line ("  jz .drop_done", OK); end if;
      if OK then Line ("  cmp ax, 1024", OK); end if;
      if OK then Line ("  ja .drop_done", OK); end if;
      if OK then Line ("  mov bx, ax", OK); end if;
      if OK then Line ("  shl bx, 1", OK); end if;
      if OK then Line ("  mov dx, bx", OK); end if;
      if OK then Line ("  shl bx, 1", OK); end if;
      if OK then Line ("  add bx, dx", OK); end if;
      if OK then Line ("  lea si, [ALB16_GC_Grid]", OK); end if;
      if OK then Line ("  add si, bx", OK); end if;
      if OK then Line ("  cmp byte [si + ALB16_GC_Node_Alive], 0", OK); end if;
      if OK then Line ("  je .drop_done", OK); end if;
      if OK then Line ("  cmp byte [si + ALB16_GC_Node_Refs], 0", OK); end if;
      if OK then Line ("  je .drop_done", OK); end if;
      if OK then Line ("  dec byte [si + ALB16_GC_Node_Refs]", OK); end if;
      if OK then Line (".drop_done:", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_GC_Bind", OK); end if;
      if OK then Line ("ALB16_GC_Bind:", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  test ax, ax", OK); end if;
      if OK then Line ("  jz .bind_done", OK); end if;
      if OK then Line ("  cmp ax, 1024", OK); end if;
      if OK then Line ("  ja .bind_done", OK); end if;
      if OK then Line ("  mov cx, ax", OK); end if;
      if OK then Line ("  shl cx, 1", OK); end if;
      if OK then Line ("  mov si, cx", OK); end if;
      if OK then Line ("  shl cx, 1", OK); end if;
      if OK then Line ("  add cx, si", OK); end if;
      if OK then Line ("  lea si, [ALB16_GC_Grid]", OK); end if;
      if OK then Line ("  add si, cx", OK); end if;
      if OK then Line ("  cmp byte [si + ALB16_GC_Node_Alive], 0", OK); end if;
      if OK then Line ("  je .bind_done", OK); end if;
      if OK then Line ("  mov word [si + ALB16_GC_Node_Child1], bx", OK); end if;
      if OK then Line ("  mov word [si + ALB16_GC_Node_Child2], dx", OK); end if;
      if OK then Line (".bind_done:", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_GC_Sweep", OK); end if;
      if OK then Line ("ALB16_GC_Sweep:", OK); end if;
      if OK then Line ("  push bx", OK); end if;
      if OK then Line ("  push cx", OK); end if;
      if OK then Line ("  push dx", OK); end if;
      if OK then Line ("  push si", OK); end if;
      if OK then Line ("  push di", OK); end if;
      if OK then Line ("  mov bx, ax", OK); end if;
      if OK then Line ("  test bx, bx", OK); end if;
      if OK then Line ("  jz .sweep_done", OK); end if;
      if OK then Line ("  cmp bx, 1024", OK); end if;
      if OK then Line ("  jbe .steps_ready", OK); end if;
      if OK then Line ("  mov bx, 1024", OK); end if;
      if OK then Line (".steps_ready:", OK); end if;
      if OK then Line ("  xor cx, cx", OK); end if;
      if OK then Line (".sweep_loop:", OK); end if;
      if OK then Line ("  cmp cx, bx", OK); end if;
      if OK then Line ("  jae .sweep_done", OK); end if;
      if OK then Line ("  mov dx, word [ALB16_GC_Cursor]", OK); end if;
      if OK then Line ("  mov ax, dx", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  add ax, di", OK); end if;
      if OK then Line ("  lea si, [ALB16_GC_Grid]", OK); end if;
      if OK then Line ("  add si, ax", OK); end if;
      if OK then Line ("  cmp byte [si + ALB16_GC_Node_Alive], 0", OK); end if;
      if OK then Line ("  je .sweep_advance", OK); end if;
      if OK then Line ("  cmp byte [si + ALB16_GC_Node_Refs], 0", OK); end if;
      if OK then Line ("  jne .sweep_advance", OK); end if;
      if OK then Line ("  mov byte [si + ALB16_GC_Node_Alive], 0", OK); end if;
      if OK then Line ("  mov dx, word [si + ALB16_GC_Node_Child1]", OK); end if;
      if OK then Line ("  test dx, dx", OK); end if;
      if OK then Line ("  jz .sweep_child2", OK); end if;
      if OK then Line ("  cmp dx, 1024", OK); end if;
      if OK then Line ("  ja .sweep_child2", OK); end if;
      if OK then Line ("  mov ax, dx", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  add ax, di", OK); end if;
      if OK then Line ("  lea di, [ALB16_GC_Grid]", OK); end if;
      if OK then Line ("  add di, ax", OK); end if;
      if OK then Line ("  cmp byte [di + ALB16_GC_Node_Refs], 0", OK); end if;
      if OK then Line ("  je .sweep_child2", OK); end if;
      if OK then Line ("  dec byte [di + ALB16_GC_Node_Refs]", OK); end if;
      if OK then Line (".sweep_child2:", OK); end if;
      if OK then Line ("  mov dx, word [si + ALB16_GC_Node_Child2]", OK); end if;
      if OK then Line ("  test dx, dx", OK); end if;
      if OK then Line ("  jz .sweep_advance", OK); end if;
      if OK then Line ("  cmp dx, 1024", OK); end if;
      if OK then Line ("  ja .sweep_advance", OK); end if;
      if OK then Line ("  mov ax, dx", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  mov di, ax", OK); end if;
      if OK then Line ("  shl ax, 1", OK); end if;
      if OK then Line ("  add ax, di", OK); end if;
      if OK then Line ("  lea di, [ALB16_GC_Grid]", OK); end if;
      if OK then Line ("  add di, ax", OK); end if;
      if OK then Line ("  cmp byte [di + ALB16_GC_Node_Refs], 0", OK); end if;
      if OK then Line ("  je .sweep_advance", OK); end if;
      if OK then Line ("  dec byte [di + ALB16_GC_Node_Refs]", OK); end if;
      if OK then Line (".sweep_advance:", OK); end if;
      if OK then Line ("  inc word [ALB16_GC_Cursor]", OK); end if;
      if OK then Line ("  cmp word [ALB16_GC_Cursor], 1024", OK); end if;
      if OK then Line ("  jbe .sweep_next", OK); end if;
      if OK then Line ("  mov word [ALB16_GC_Cursor], 1", OK); end if;
      if OK then Line (".sweep_next:", OK); end if;
      if OK then Line ("  inc cx", OK); end if;
      if OK then Line ("  jmp .sweep_loop", OK); end if;
      if OK then Line (".sweep_done:", OK); end if;
      if OK then Line ("  pop di", OK); end if;
      if OK then Line ("  pop si", OK); end if;
      if OK then Line ("  pop dx", OK); end if;
      if OK then Line ("  pop cx", OK); end if;
      if OK then Line ("  pop bx", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("if used ALB16_Bool_Not", OK); end if;
      if OK then Line ("ALB16_Bool_Not:", OK); end if;
      if OK then Line ("  cmp ax, 0", OK); end if;
      if OK then Line ("  mov ax, 0", OK); end if;
      if OK then Line ("  jne .done", OK); end if;
      if OK then Line ("  inc ax", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Cmp_Eq", OK); end if;
      if OK then Line ("ALB16_Cmp_Eq:", OK); end if;
      if OK then Line ("  cmp ax, bx", OK); end if;
      if OK then Line ("  mov ax, 0", OK); end if;
      if OK then Line ("  jne .done", OK); end if;
      if OK then Line ("  inc ax", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Cmp_Neq", OK); end if;
      if OK then Line ("ALB16_Cmp_Neq:", OK); end if;
      if OK then Line ("  cmp ax, bx", OK); end if;
      if OK then Line ("  mov ax, 0", OK); end if;
      if OK then Line ("  je .done", OK); end if;
      if OK then Line ("  inc ax", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Cmp_Lt", OK); end if;
      if OK then Line ("ALB16_Cmp_Lt:", OK); end if;
      if OK then Line ("  cmp ax, bx", OK); end if;
      if OK then Line ("  mov ax, 0", OK); end if;
      if OK then Line ("  jae .done", OK); end if;
      if OK then Line ("  inc ax", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Cmp_Gt", OK); end if;
      if OK then Line ("ALB16_Cmp_Gt:", OK); end if;
      if OK then Line ("  cmp ax, bx", OK); end if;
      if OK then Line ("  mov ax, 0", OK); end if;
      if OK then Line ("  jbe .done", OK); end if;
      if OK then Line ("  inc ax", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Cmp_Lte", OK); end if;
      if OK then Line ("ALB16_Cmp_Lte:", OK); end if;
      if OK then Line ("  cmp ax, bx", OK); end if;
      if OK then Line ("  mov ax, 0", OK); end if;
      if OK then Line ("  ja .done", OK); end if;
      if OK then Line ("  inc ax", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;

      if OK then Line ("", OK); end if;

      if OK then Line ("if used ALB16_Cmp_Gte", OK); end if;
      if OK then Line ("ALB16_Cmp_Gte:", OK); end if;
      if OK then Line ("  cmp ax, bx", OK); end if;
      if OK then Line ("  mov ax, 0", OK); end if;
      if OK then Line ("  jb .done", OK); end if;
      if OK then Line ("  inc ax", OK); end if;
      if OK then Line (".done:", OK); end if;
      if OK then Line ("  ret", OK); end if;
      if OK then Line ("end if", OK); end if;
      
      if OK then Line ("", OK); end if;
      if OK then Line ("ALB16_Final_End_Of_Image:", OK); end if;

      Success := OK;
   end Emit_Program_End;
   
-- The idea in one sentence:
-- backbuffer = memory above the generated image inside the COM-owned block,
-- present = one blit to A000h during retrace,
-- fallback to A000h only if there truly is not enough room.


   procedure Emit_Raw
     (Text    : String;
      Success : out Boolean)
   is
      Target : constant String := FASM16_Call_Target (Text);
   begin
      if Target'Length > 0 then
         Emit_Absolute_Near_Call (Target, Success);
      else
         Append (Text, Success);
      end if;
   end Emit_Raw;
   
   function ALB_ASM_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      else
         return Ch;
      end if;
   end ALB_ASM_Upper;

   function ALB_ASM_Is_Space (Ch : Character) return Boolean is
   begin
      return Ch = ' ' or else Ch = ASCII.HT or else Ch = ASCII.CR;
   end ALB_ASM_Is_Space;

   function ALB_ASM_Is_End_Line (Line : String) return Boolean is
      First : Integer := Line'First;
      Last  : Integer := Line'Last;
   begin
      while First <= Last and then ALB_ASM_Is_Space (Line (First)) loop
         First := First + 1;
      end loop;

      while Last >= First and then ALB_ASM_Is_Space (Line (Last)) loop
         Last := Last - 1;
      end loop;

      if Last - First + 1 /= 7 then
         return False;
      end if;

      return
        ALB_ASM_Upper (Line (First))     = 'E' and then
        ALB_ASM_Upper (Line (First + 1)) = 'N' and then
        ALB_ASM_Upper (Line (First + 2)) = 'D' and then
        Line (First + 3)                 = ' ' and then
        ALB_ASM_Upper (Line (First + 4)) = 'A' and then
        ALB_ASM_Upper (Line (First + 5)) = 'S' and then
        ALB_ASM_Upper (Line (First + 6)) = 'M';
   end ALB_ASM_Is_End_Line;

   procedure Emit_Native_ASM_Body
     (Block_Text : String;
      Success    : out Boolean)
   is
      S          : Boolean := True;
      Pos        : Integer := Block_Text'First;
      Line_Start : Integer;
      Line_End   : Integer;
      First_Line : Boolean := True;
   begin
      Append ("  ; --- ALB FASM16 NATIVE ASM BEGIN ---", S);
      Emit_Newline (S);

      while Pos <= Block_Text'Last loop
         Line_Start := Pos;

         while Pos <= Block_Text'Last and then Block_Text (Pos) /= ASCII.LF loop
            Pos := Pos + 1;
         end loop;

         Line_End := Pos - 1;

         if First_Line then
            First_Line := False;

         elsif Line_End >= Line_Start then
            declare
               Line_Text : constant String := Block_Text (Line_Start .. Line_End);
            begin
               exit when ALB_ASM_Is_End_Line (Line_Text);

               Append (Line_Text, S);
               Emit_Newline (S);
            end;

         else
            Emit_Newline (S);
         end if;

         if Pos <= Block_Text'Last and then Block_Text (Pos) = ASCII.LF then
            Pos := Pos + 1;
         end if;
      end loop;

      Append ("  ; --- ALB FASM16 NATIVE ASM END ---", S);
      Emit_Newline (S);

      Success := S;
   end Emit_Native_ASM_Body;

   procedure Emit_Native_ASM_Block
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      Emit_Native_ASM_Body (Block_Text, Success);
   end Emit_Native_ASM_Block;

   procedure Emit_Native_ASM_Expression
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      Append ("  ; inline ASM expression result must be returned in DX:AX (or AX for 16-bit values)", Success);
      if not Success then
         return;
      end if;

      Emit_Newline (Success);
      Emit_Native_ASM_Body (Block_Text, Success);
   end Emit_Native_ASM_Expression;

   procedure Emit_Newline
     (Success : out Boolean)
   is
   begin
      Append ((1 => Character'Val (10)), Success);
   end Emit_Newline;

   procedure Emit_Indent
     (Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      for I in 1 .. Indent_Level loop
         Append ("   ", OK);

         if not OK then
            Success := False;
            return;
         end if;
      end loop;

      Success := True;
   end Emit_Indent;

   procedure Increase_Indent is
   begin
      Indent_Level := Indent_Level + 1;
   end Increase_Indent;

   procedure Decrease_Indent is
   begin
      if Indent_Level > 0 then
         Indent_Level := Indent_Level - 1;
      end if;
   end Decrease_Indent;

   procedure Emit_Profile_Banner
     (Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      Line ("; ----------------------------------------------------------", OK);
      if OK then Line ("; FASM16 PROFILE: Tiny16", OK); end if;
      if OK then Line ("; Native cell size: 16-bit", OK); end if;
      if OK then Line ("; Wider ALB values require explicit emulation later.", OK); end if;
      if OK then Line ("; ----------------------------------------------------------", OK); end if;

      Success := OK;
   end Emit_Profile_Banner;

   procedure Emit_Unsupported
     (Feature_Name : String;
      Success      : out Boolean)
   is
      OK : Boolean := True;
   begin
      Emit_Indent (OK);

      if OK then
         Append ("; FASM16 UNSUPPORTED: " & Feature_Name, OK);
      end if;

      if OK then
         Emit_Newline (OK);
      end if;

      -- Unsupported means the caller should treat emission as failed.
      Success := False;
   end Emit_Unsupported;

   procedure Emit_Literal_U64
     (Value   : U64;
      Success : out Boolean)
   is
   begin
      -- This emits the textual value only. Range validation belongs in
      -- the operation emitter that knows whether an immediate is 8/16-bit.
      Append (Trim_Image (U64'Image (Value)), Success);
   end Emit_Literal_U64;

   --  procedure Emit_Var_Decl
   --    (Name    : String;
   --     Tag     : ALB_Type_Tag;
   --     Success : out Boolean)
   --  is
   --     OK : Boolean := True;
   --  begin
   --     -- Tiny16 storage policy:
   --     -- U8/BOOLEAN get byte storage.
   --     -- Wider ALB semantics will require explicit multi-word emulation.
   --     Emit_Indent (OK);
   --  
   --     if OK then
   --        Append (Name, OK);
   --     end if;
   --  
   --     if OK then
   --         if Tag = Type_U8 or else Tag = Type_HW8 or else Tag = Type_Boolean then
   --            Append (" db 0", OK);
   --         elsif Tag = Type_U32 or else Tag = Type_S32 or else Tag = Type_HW32 or else Tag = Type_Pure then
   --            Append (" dd 0", OK);
   --         else
   --            Append (" dw 0", OK);
   --         end if;
   --      end if;
   --  
   --     if OK then
   --        Append (" ; FASM16 tiny storage", OK);
   --     end if;
   --  
   --     if OK then
   --        Emit_Newline (OK);
   --     end if;
   --  
   --     Success := OK;
   --  end Emit_Var_Decl;
   
   procedure Emit_Var_Decl
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      OK         : Boolean := True;
      Stored_Tag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Tag);
      Size_Text  : constant String :=
        Trim_Image (Natural'Image (Field_Size_Bytes (Stored_Tag)));
   begin
      -- Tiny16 storage policy:
      -- U8/BOOLEAN get byte storage.
      -- Wider or unsupported ALB semantics are coerced to the nearest
      -- usable 16-bit backend cell so emission can continue.
      Emit_Indent (OK);

      if OK then
         Append (Name, OK);
      end if;

      if OK then
         if Stored_Tag = Type_U8
           or else Stored_Tag = Type_S8
           or else Stored_Tag = Type_HW8
           or else Stored_Tag = Type_Boolean
           or else Stored_Tag = Type_Char
         then
            Append (" db 0", OK);
         elsif Stored_Tag = Type_U32
           or else Stored_Tag = Type_S32
           or else Stored_Tag = Type_HW32
           or else Stored_Tag = Type_Pure
         then
            Append (" dd 0", OK);
         else
            Append (" dw 0", OK);
         end if;
      end if;

      if OK then
         Append (" ; FASM16 tiny storage", OK);
      end if;

      if OK then
         Emit_Newline (OK);
      end if;

      if OK then
         Emit_Indent (OK);
      end if;

      if OK then
         Append ("sizeof." & Name & " = " & Size_Text, OK);
      end if;

      if OK then
         Emit_Newline (OK);
      end if;

      Success := OK;
   end Emit_Var_Decl;

   procedure Emit_Global_Var_Decl
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      Previous_Buffer : constant Buffer_Target := Current_Buffer;
   begin
      Current_Buffer := Buffer_Global;
      Emit_Var_Decl (Name, Tag, Success);
      Current_Buffer := Previous_Buffer;
   end Emit_Global_Var_Decl;

   procedure Emit_Reversible_Block_Start
     (Success : out Boolean)
   is
   begin
      Line ("  ; --- ALB16 REVERSIBLE BLOCK START ---", Success);
   end Emit_Reversible_Block_Start;

   procedure Emit_Reversible_Block_End
     (Success : out Boolean)
   is
   begin
      Line ("  ; --- ALB16 REVERSIBLE BLOCK END ---", Success);
   end Emit_Reversible_Block_End;

   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Target_Tag);
   begin
      if not FASM16_Tag_Supported (MTag) then
         Success := False;
         return;
      end if;

      case Field_Size_Bytes (MTag) is
         when 1 =>
            if OK then Line ("  add byte [" & Target_Name & "], al", OK); end if;

         when 4 =>
            if OK then Line ("  add word [" & Target_Name & "], ax", OK); end if;
            if OK then Line ("  adc word [" & Target_Name & "+2], dx", OK); end if;

         when others =>
            if OK then Line ("  add word [" & Target_Name & "], ax", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Add;

   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Target_Tag);
   begin
      if not FASM16_Tag_Supported (MTag) then
         Success := False;
         return;
      end if;

      case Field_Size_Bytes (MTag) is
         when 1 =>
            if OK then Line ("  sub byte [" & Target_Name & "], al", OK); end if;

         when 4 =>
            if OK then Line ("  sub word [" & Target_Name & "], ax", OK); end if;
            if OK then Line ("  sbb word [" & Target_Name & "+2], dx", OK); end if;

         when others =>
            if OK then Line ("  sub word [" & Target_Name & "], ax", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Sub;

   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Target_Tag);
   begin
      if not FASM16_Tag_Supported (MTag) then
         Success := False;
         return;
      end if;

      case Field_Size_Bytes (MTag) is
         when 1 =>
            if OK then Line ("  xor byte [" & Target_Name & "], al", OK); end if;

         when 4 =>
            if OK then Line ("  xor word [" & Target_Name & "], ax", OK); end if;
            if OK then Line ("  xor word [" & Target_Name & "+2], dx", OK); end if;

         when others =>
            if OK then Line ("  xor word [" & Target_Name & "], ax", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Xor;

   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Target_Tag);
      ID   : constant String := Fresh_Label_ID;
   begin
      if not FASM16_Tag_Supported (MTag) then
         Success := False;
         return;
      end if;

      case Field_Size_Bytes (MTag) is
         when 1 =>
            if OK then Line ("  mov cx, ax", OK); end if;
            if OK then Line ("  and cx, 7", OK); end if;
            if OK then Line ("  rol byte [" & Target_Name & "], cl", OK); end if;

         when 4 =>
            if OK then Line ("  mov bx, ax", OK); end if;
            if OK then Line ("  and bx, 31", OK); end if;
            if OK then Line ("  jz .alb16_revrol_done_" & ID, OK); end if;
            if OK then Line ("  mov ax, word [" & Target_Name & "]", OK); end if;
            if OK then Line ("  mov dx, word [" & Target_Name & "+2]", OK); end if;
            if OK then Line (".alb16_revrol_loop_" & ID & ":", OK); end if;
            if OK then Line ("  shl ax, 1", OK); end if;
            if OK then Line ("  rcl dx, 1", OK); end if;
            if OK then Line ("  adc ax, 0", OK); end if;
            if OK then Line ("  dec bx", OK); end if;
            if OK then Line ("  jnz .alb16_revrol_loop_" & ID, OK); end if;
            if OK then Line ("  mov word [" & Target_Name & "], ax", OK); end if;
            if OK then Line ("  mov word [" & Target_Name & "+2], dx", OK); end if;
            if OK then Line (".alb16_revrol_done_" & ID & ":", OK); end if;

         when others =>
            if OK then Line ("  mov cx, ax", OK); end if;
            if OK then Line ("  and cx, 15", OK); end if;
            if OK then Line ("  rol word [" & Target_Name & "], cl", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Rol;

   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Target_Tag);
      ID   : constant String := Fresh_Label_ID;
   begin
      if not FASM16_Tag_Supported (MTag) then
         Success := False;
         return;
      end if;

      case Field_Size_Bytes (MTag) is
         when 1 =>
            if OK then Line ("  mov cx, ax", OK); end if;
            if OK then Line ("  and cx, 7", OK); end if;
            if OK then Line ("  ror byte [" & Target_Name & "], cl", OK); end if;

         when 4 =>
            if OK then Line ("  mov bx, ax", OK); end if;
            if OK then Line ("  and bx, 31", OK); end if;
            if OK then Line ("  jz .alb16_revror_done_" & ID, OK); end if;
            if OK then Line ("  mov ax, word [" & Target_Name & "]", OK); end if;
            if OK then Line ("  mov dx, word [" & Target_Name & "+2]", OK); end if;
            if OK then Line (".alb16_revror_loop_" & ID & ":", OK); end if;
            if OK then Line ("  shr dx, 1", OK); end if;
            if OK then Line ("  rcr ax, 1", OK); end if;
            if OK then Line ("  jnc .alb16_revror_skip_" & ID, OK); end if;
            if OK then Line ("  or dx, 8000h", OK); end if;
            if OK then Line (".alb16_revror_skip_" & ID & ":", OK); end if;
            if OK then Line ("  dec bx", OK); end if;
            if OK then Line ("  jnz .alb16_revror_loop_" & ID, OK); end if;
            if OK then Line ("  mov word [" & Target_Name & "], ax", OK); end if;
            if OK then Line ("  mov word [" & Target_Name & "+2], dx", OK); end if;
            if OK then Line (".alb16_revror_done_" & ID & ":", OK); end if;

         when others =>
            if OK then Line ("  mov cx, ax", OK); end if;
            if OK then Line ("  and cx, 15", OK); end if;
            if OK then Line ("  ror word [" & Target_Name & "], cl", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Ror;

   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   is
      OK         : Boolean := True;
      Left_Size  : constant Natural := Field_Size_Bytes (Normalize_FASM16_Tag (Left_Tag));
      Right_Size : constant Natural := Field_Size_Bytes (Normalize_FASM16_Tag (Right_Tag));
   begin
      if not FASM16_Tag_Supported (Left_Tag)
        or else not FASM16_Tag_Supported (Right_Tag)
        or else Left_Size /= Right_Size
      then
         Success := False;
         return;
      end if;

      case Left_Size is
         when 1 =>
            if OK then Line ("  mov al, byte [" & Left_Name & "]", OK); end if;
            if OK then Line ("  mov ah, byte [" & Right_Name & "]", OK); end if;
            if OK then Line ("  mov byte [" & Left_Name & "], ah", OK); end if;
            if OK then Line ("  mov byte [" & Right_Name & "], al", OK); end if;

         when 4 =>
            if OK then Line ("  mov ax, word [" & Left_Name & "]", OK); end if;
            if OK then Line ("  mov dx, word [" & Left_Name & "+2]", OK); end if;
            if OK then Line ("  mov bx, word [" & Right_Name & "]", OK); end if;
            if OK then Line ("  mov cx, word [" & Right_Name & "+2]", OK); end if;
            if OK then Line ("  mov word [" & Left_Name & "], bx", OK); end if;
            if OK then Line ("  mov word [" & Left_Name & "+2], cx", OK); end if;
            if OK then Line ("  mov word [" & Right_Name & "], ax", OK); end if;
            if OK then Line ("  mov word [" & Right_Name & "+2], dx", OK); end if;

         when others =>
            if OK then Line ("  mov ax, word [" & Left_Name & "]", OK); end if;
            if OK then Line ("  mov bx, word [" & Right_Name & "]", OK); end if;
            if OK then Line ("  mov word [" & Left_Name & "], bx", OK); end if;
            if OK then Line ("  mov word [" & Right_Name & "], ax", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Swap;

   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Target_Tag);
   begin
      if not FASM16_Tag_Supported (MTag) then
         Success := False;
         return;
      end if;

      case Field_Size_Bytes (MTag) is
         when 1 =>
            if OK then Line ("  not byte [" & Target_Name & "]", OK); end if;

         when 4 =>
            if OK then Line ("  not word [" & Target_Name & "]", OK); end if;
            if OK then Line ("  not word [" & Target_Name & "+2]", OK); end if;

         when others =>
            if OK then Line ("  not word [" & Target_Name & "]", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Not;

   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      OK   : Boolean := True;
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Target_Tag);
   begin
      if not FASM16_Tag_Supported (MTag) then
         Success := False;
         return;
      end if;

      case Field_Size_Bytes (MTag) is
         when 1 =>
            if OK then Line ("  neg byte [" & Target_Name & "]", OK); end if;

         when 4 =>
            if OK then Line ("  mov ax, word [" & Target_Name & "]", OK); end if;
            if OK then Line ("  mov dx, word [" & Target_Name & "+2]", OK); end if;
            if OK then Line ("  neg ax", OK); end if;
            if OK then Line ("  adc dx, 0", OK); end if;
            if OK then Line ("  neg dx", OK); end if;
            if OK then Line ("  mov word [" & Target_Name & "], ax", OK); end if;
            if OK then Line ("  mov word [" & Target_Name & "+2], dx", OK); end if;

         when others =>
            if OK then Line ("  neg word [" & Target_Name & "]", OK); end if;
      end case;

      Success := OK;
   end Emit_Rev_Neg;

   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      OK          : Boolean := True;
      Old_Buffer  : constant Buffer_Target := Current_Buffer;
      Safe_Depth  : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Elem_Bytes  : constant Natural := Field_Size_Bytes (Normalize_FASM16_Tag (Tag));
      Depth_Text  : constant String := Trim_Image (Natural'Image (Safe_Depth));
      Bytes_Text  : constant String := Trim_Image (Natural'Image (Safe_Depth * Elem_Bytes));
   begin
      if not FASM16_Tag_Supported (Tag) then
         Success := False;
         return;
      end if;

      Emit_Var_Decl (Name, Tag, OK);
      if not OK then
         Success := False;
         return;
      end if;

      Current_Buffer := Buffer_Global;

      if OK then Emit_Indent (OK); end if;
      if OK then Append ("ALB_TEMP_" & Name & "_history rb " & Bytes_Text, OK); end if;
      if OK then Emit_Newline (OK); end if;

      if OK then Emit_Indent (OK); end if;
      if OK then Append ("ALB_TEMP_" & Name & "_head dw 0", OK); end if;
      if OK then Emit_Newline (OK); end if;

      if OK then Emit_Indent (OK); end if;
      if OK then Append ("sizeof.ALB_TEMP_" & Name & "_history = " & Bytes_Text, OK); end if;
      if OK then Emit_Newline (OK); end if;

      Current_Buffer := Old_Buffer;
      Success := OK;
   end Emit_Temporal_Var_Decl;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      OK         : Boolean := True;
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
      Elem_Bytes : constant Natural := Field_Size_Bytes (Normalize_FASM16_Tag (Tag));
      ID         : constant String := Fresh_Label_ID;
   begin
      if not FASM16_Tag_Supported (Tag) then
         Success := False;
         return;
      end if;

      Emit_Load_Cell_To_DXAX (Name, Tag, OK);
      if OK then Line ("  mov bx, word [ALB_TEMP_" & Name & "_head]", OK); end if;
      if OK then Emit_Scale_BX_For_Size (Elem_Bytes, OK); end if;
      if OK then Emit_Store_DXAX_To_Indexed_Base ("ALB_TEMP_" & Name & "_history", Tag, OK); end if;
      if OK then Line ("  mov bx, word [ALB_TEMP_" & Name & "_head]", OK); end if;
      if OK then Line ("  inc bx", OK); end if;
      if OK then Line ("  cmp bx, " & Depth_Text, OK); end if;
      if OK then Line ("  jb .alb16_temp_nowrap_" & ID, OK); end if;
      if OK then Line ("  xor bx, bx", OK); end if;
      if OK then Line (".alb16_temp_nowrap_" & ID & ":", OK); end if;
      if OK then Line ("  mov word [ALB_TEMP_" & Name & "_head], bx", OK); end if;

      Success := OK;
   end Emit_Temporal_Record_Current;

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
   begin
      Emit_Load_Cell_To_DXAX (Name, Tag, Success);
   end Emit_Temporal_Load_Now;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      OK         : Boolean := True;
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
      Elem_Bytes : constant Natural := Field_Size_Bytes (Normalize_FASM16_Tag (Tag));
      ID         : constant String := Fresh_Label_ID;
   begin
      if not FASM16_Tag_Supported (Tag) then
         Success := False;
         return;
      end if;

      if OK then Line ("  mov bx, word [ALB_TEMP_" & Name & "_head]", OK); end if;
      if OK then Line ("  test bx, bx", OK); end if;
      if OK then Line ("  jnz .alb16_temp_have_past_" & ID, OK); end if;
      if OK then Line ("  mov bx, " & Depth_Text, OK); end if;
      if OK then Line (".alb16_temp_have_past_" & ID & ":", OK); end if;
      if OK then Line ("  dec bx", OK); end if;
      if OK then Emit_Scale_BX_For_Size (Elem_Bytes, OK); end if;
      if OK then Emit_Load_Indexed_Base_To_DXAX ("ALB_TEMP_" & Name & "_history", Tag, OK); end if;

      Success := OK;
   end Emit_Temporal_Load_Past;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      if OK then Line ("  lea ax, [ALB_TEMP_" & Name & "_history]", OK); end if;
      if OK then Line ("  xor dx, dx", OK); end if;
      Success := OK;
   end Emit_Temporal_Load_Timeline;
   
   --  procedure Emit_Type_Definition
   --    (Tag     : ALB_Type_Tag;
   --     Success : out Boolean)
   --  is
   --  begin
   --     case Tag is
   --        when Type_U8 | Type_HW8 =>
   --           Append ("db ", Success);
   --        when Type_U16 | Type_HW16 =>
   --           Append ("dw ", Success);
   --        when Type_U32 | Type_S32 | Type_HW32 | Type_Pure =>
   --           Append ("dd ", Success);
   --        when Type_Boolean =>
   --           Append ("db ", Success);
   --        when others =>
   --           Append ("dq ", Success);
   --     end case;
   --  end Emit_Type_Definition;
   
   procedure Emit_Type_Definition
     (Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      MTag : constant ALB_Type_Tag := Normalize_FASM16_Tag (Tag);
   begin
      case MTag is
         when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
            Append ("db ", Success);

         when Type_U16 | Type_S16 | Type_HW16 | Type_Binary | Type_Reference =>
            Append ("dw ", Success);

         when Type_U32 | Type_S32 | Type_HW32 | Type_Pure =>
            Append ("dd ", Success);

         when others =>
            Append ("dd ", Success);
      end case;
   end Emit_Type_Definition;

   procedure Emit_Pure_Struct_Def
     (Success : out Boolean)
   is
      S : Boolean := True;
   begin
      --  Emit_Indent (S);
      --  if S then Append ("; PURE layout", S); end if;
      --  if S then Emit_Newline (S); end if;
      --  
      --  Emit_Indent (S);
      --  if S then Append ("PURE.num equ 0", S); end if;
      --  if S then Emit_Newline (S); end if;
      --  
      --  Emit_Indent (S);
      --  if S then Append ("PURE.den equ 8", S); end if;
      --  if S then Emit_Newline (S); end if;
      --  
      --  Emit_Indent (S);
      --  if S then Append ("sizeof.PURE equ 16", S); end if;
      --  if S then Emit_Newline (S); end if;
      Emit_Indent (S);
      if S then Append ("; PURE packed FASM16 layout", S); end if;
      if S then Emit_Newline (S); end if;

      Emit_Indent (S);
      if S then Append ("PURE.den equ 0", S); end if;
      if S then Emit_Newline (S); end if;

      Emit_Indent (S);
      if S then Append ("PURE.num equ 2", S); end if;
      if S then Emit_Newline (S); end if;

      Emit_Indent (S);
      if S then Append ("sizeof.PURE equ 4", S); end if;
      if S then Emit_Newline (S); end if;

      Success := S;
   end Emit_Pure_Struct_Def;

   procedure Emit_Struct_Start
     (Struct_Name : String;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      if Struct_Name'Length > Current_Struct_Name'Length then
         Success := False;
         return;
      end if;

      Current_Buffer := Buffer_Global;

      Current_Struct_Name := (others => ' ');
      Current_Struct_Name (1 .. Struct_Name'Length) := Struct_Name;
      Current_Struct_Len := Struct_Name'Length;
      Current_Struct_Offset := 0;

      Emit_Indent (S);
      if S then Append ("; struct " & Struct_Name & " layout", S); end if;
      if S then Emit_Newline (S); end if;

      Success := S;
   end Emit_Struct_Start;

   procedure Emit_Struct_End
     (Struct_Name : String;
      Success     : out Boolean)
   is
      pragma Unreferenced (Struct_Name);
      S        : Boolean := True;
      Size_Img : constant String := Trim_Image (Natural'Image (Current_Struct_Offset));
   begin
      if Current_Struct_Len = 0 then
         Success := False;
         return;
      end if;

      Emit_Indent (S);
      if S then
         Append
           ("sizeof." & Current_Struct_Name (1 .. Current_Struct_Len) &
            " equ " & Size_Img,
            S);
      end if;
      if S then Emit_Newline (S); end if;

      Current_Struct_Name := (others => ' ');
      Current_Struct_Len := 0;
      Current_Struct_Offset := 0;

      Current_Buffer := Buffer_Main;
      Success := S;
   end Emit_Struct_End;

   procedure Emit_Struct_Field
     (Field_Name : String;
      Tag        : ALB_Type_Tag;
      Success    : out Boolean)
   is
      S       : Boolean := True;
      Off_Img : constant String := Trim_Image (Natural'Image (Current_Struct_Offset));
   begin
      if Current_Struct_Len = 0 then
         Success := False;
         return;
      end if;

      Emit_Indent (S);
      if S then
         Append
           (Current_Struct_Name (1 .. Current_Struct_Len) & "." &
            Field_Name & " equ " & Off_Img,
            S);
      end if;
      if S then Emit_Newline (S); end if;

      Current_Struct_Offset :=
        Current_Struct_Offset + Field_Size_Bytes (Normalize_FASM16_Tag (Tag));

      Success := S;
   end Emit_Struct_Field;

   procedure Emit_Struct_Var_Decl
     (Struct_Name : String;
      Var_Name    : String;
      Success     : out Boolean)
   is
      S   : Boolean := True;
      Old : Buffer_Target := Current_Buffer;
   begin
      Current_Buffer := Buffer_Global;

      Emit_Indent (S);
      if S then
         Append (Var_Name & " rb sizeof." & Struct_Name, S);
      end if;
      if S then Emit_Newline (S); end if;

      Current_Buffer := Old;
      Success := S;
   end Emit_Struct_Var_Decl;


   procedure Emit_Print_Start
     (Tag     : ALB_Type_Tag;
      Piped   : Boolean;
      Success : out Boolean)
   is
      pragma Unreferenced (Tag, Piped);
   begin
      Emit_Unsupported
        ("PRINT for numeric/general values requires the FASM16 formatting runtime",
         Success);
   end Emit_Print_Start;

   procedure Emit_Print_End
     (Tag     : ALB_Type_Tag;
      Piped   : Boolean;
      Success : out Boolean)
   is
      pragma Unreferenced (Tag, Piped);
   begin
      Success := True;
   end Emit_Print_End;

   
   procedure Emit_String_Literal
     (Text    : String;
      Success : out Boolean)
   is
      OK       : Boolean := True;
      Id_Image : constant String := Natural'Image (String_Counter + 1);
      Id       : constant String := Trim_Image (Id_Image);
      Started  : Boolean := False;
      In_Quote : Boolean := False;

      procedure Begin_Item is
      begin
         if Started then
            Append (", ", OK);
         else
            Started := True;
         end if;
      end Begin_Item;

      procedure Append_Text_Char (Ch : Character) is
      begin
         if not In_Quote then
            Begin_Item;
            Append ("""", OK);
            In_Quote := True;
         end if;

         if Ch = '"' then
            Append ("""""", OK);
         else
            Append ((1 => Ch), OK);
         end if;
      end Append_Text_Char;

      procedure Append_Byte (Value : Natural) is
         Img : constant String := Natural'Image (Value);
      begin
         if In_Quote then
            Append ("""", OK);
            In_Quote := False;
         end if;

         Begin_Item;
         Append (Img (Img'First + 1 .. Img'Last), OK);
      end Append_Byte;
   begin
      -- ALB strings are NUL-terminated in FASM16. DOS '$' strings are kept
      -- only for fixed runtime messages printed through int 21h / AH=09h.
      String_Counter := String_Counter + 1;

      Emit_Indent (OK);
      if OK then Append ("jmp .alb16_skip_str_" & Id, OK); end if;
      if OK then Emit_Newline (OK); end if;

      Emit_Indent (OK);
      if OK then Append (".alb16_str_" & Id & " db ", OK); end if;

      for I in Text'Range loop
         if OK then
            if Text (I) = ASCII.CR then
               Append_Byte (13);
            elsif Text (I) = ASCII.LF then
               Append_Byte (10);
            else
               Append_Text_Char (Text (I));
            end if;
         end if;
      end loop;

      if In_Quote then
         Append ("""", OK);
         In_Quote := False;
      end if;

      if not Started then
         Begin_Item;
         Append ("""", OK);
         Append ("""", OK);
      end if;

      if OK then Append (", 0", OK); end if;
      if OK then Emit_Newline (OK); end if;

      Emit_Indent (OK);
      if OK then Append (".alb16_skip_str_" & Id & ":", OK); end if;
      if OK then Emit_Newline (OK); end if;

      Emit_Indent (OK);
      if OK then Append ("mov dx, .alb16_str_" & Id, OK); end if;
      if OK then Emit_Newline (OK); end if;
      
      Emit_Indent (OK);
      if OK then Append ("mov ax, dx", OK); end if;
      if OK then Emit_Newline (OK); end if;

      Success := OK;
   end Emit_String_Literal;
   
   procedure Emit_Let_Assign_Start
     (Type_Hint : String;
      Success   : out Boolean)
   is
      pragma Unreferenced (Type_Hint);
   begin
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then
           (Main_Buffer (Main_Len) = ASCII.LF or
            Main_Buffer (Main_Len) = ASCII.CR or
            Main_Buffer (Main_Len) = ' ')
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then
           (Global_Buffer (Global_Len) = ASCII.LF or
            Global_Buffer (Global_Len) = ASCII.CR or
            Global_Buffer (Global_Len) = ' ')
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;

      Append (", ", Success);
   end Emit_Let_Assign_Start;

   procedure Emit_Variable_Ref
     (Name    : String;
      Success : out Boolean)
   is
   begin
      Append ("[", Success);
      Append (Name, Success);
      Append ("]", Success);
   end Emit_Variable_Ref;

   procedure Emit_Array_Index_Open
     (Success : out Boolean)
   is
   begin
      Append (" + (", Success);
   end Emit_Array_Index_Open;

   procedure Emit_Array_Index_Close
     (Success : out Boolean)
   is
   begin
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then
           (Main_Buffer (Main_Len) = ASCII.LF or
            Main_Buffer (Main_Len) = ASCII.CR or
            Main_Buffer (Main_Len) = ' ')
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then
           (Global_Buffer (Global_Len) = ASCII.LF or
            Global_Buffer (Global_Len) = ASCII.CR or
            Global_Buffer (Global_Len) = ' ')
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;

      Append (")*2]", Success);
   end Emit_Array_Index_Close;

   procedure Emit_AddressOf
     (Success : out Boolean)
   is
   begin
      Append (" ", Success);
   end Emit_AddressOf;

   procedure Emit_Boolean_Cast_Start
     (Success : out Boolean)
   is
   begin
      Append (" ", Success);
   end Emit_Boolean_Cast_Start;

   procedure Emit_Expression_Open
     (Success : out Boolean)
   is
   begin
      Append ("(", Success);
   end Emit_Expression_Open;

   procedure Emit_Expression_Close
     (Success : out Boolean)
   is
   begin
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then
           (Main_Buffer (Main_Len) = ASCII.LF or
            Main_Buffer (Main_Len) = ASCII.CR or
            Main_Buffer (Main_Len) = ' ')
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then
           (Global_Buffer (Global_Len) = ASCII.LF or
            Global_Buffer (Global_Len) = ASCII.CR or
            Global_Buffer (Global_Len) = ' ')
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;

      Append (")", Success);
   end Emit_Expression_Close;

   procedure Emit_BinOp
     (Op      : ALB_Opcode;
      Success : out Boolean)
   is
   begin
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then
           (Main_Buffer (Main_Len) = ASCII.LF or
            Main_Buffer (Main_Len) = ASCII.CR or
            Main_Buffer (Main_Len) = ' ')
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then
           (Global_Buffer (Global_Len) = ASCII.LF or
            Global_Buffer (Global_Len) = ASCII.CR or
            Global_Buffer (Global_Len) = ' ')
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;

      case Op is
         when OP_ADD     => Append (" + ", Success);
         when OP_SUB     => Append (" - ", Success);
         when OP_MUL     => Append (" * ", Success);
         when OP_DIV     => Append (" / ", Success);
         when OP_CMP_EQ  => Append (" = ", Success);
         when OP_CMP_NEQ => Append (" <> ", Success);
         when OP_CMP_LT  => Append (" < ", Success);
         when OP_CMP_GT  => Append (" > ", Success);
         when OP_CMP_LTE => Append (" <= ", Success);
         when OP_CMP_GTE => Append (" >= ", Success);
         when OP_AND     => Append (" and ", Success);
         when OP_OR      => Append (" or ", Success);
         when OP_XOR     => Append (" xor ", Success);
         when OP_SHL     => Append (" shl ", Success);
         when OP_SHR     => Append (" shr ", Success);
         when others     => Append (" ; UNK ", Success);
      end case;
   end Emit_BinOp;

   procedure Emit_If_Start
     (Success : out Boolean)
   is
   begin
      Append (".if ", Success);
   end Emit_If_Start;

   procedure Emit_Then
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Then;

   procedure Emit_Else
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".else", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Else;

   procedure Emit_If_End
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".end if", S);
      Emit_Newline (S);
      Success := S;
   end Emit_If_End;

   procedure Emit_While_Start
     (Success : out Boolean)
   is
   begin
      Append (".while ", Success);
   end Emit_While_Start;

   procedure Emit_While_Loop_Start
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_While_Loop_Start;

   procedure Emit_Plain_Loop_Start
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Append (".repeat", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Plain_Loop_Start;

   procedure Emit_Exit_When
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".until ", S);
      Success := S;
   end Emit_Exit_When;

   procedure Emit_Case_Start
     (Success : out Boolean)
   is
   begin
      Append ("; SELECT ", Success);
   end Emit_Case_Start;

   procedure Emit_Is
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Is;

   procedure Emit_When
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append (".if ", S);
      Success := S;
   end Emit_When;

   procedure Emit_Arrow
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Arrow;

   procedure Emit_When_End
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".end if", S);
      Emit_Newline (S);
      Success := S;
   end Emit_When_End;

   procedure Emit_Case_End
     (Success : out Boolean)
   is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("; END SELECT", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Case_End;

   
   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean) is
   begin
      Success := True;
   end Emit_For_Start;

   procedure Emit_Foreach_Start (Iterator_Name : String; Array_Name : String; Success : out Boolean) is
   begin
      Emit_Unsupported ("Generic FOREACH routing", Success);
   end Emit_Foreach_Start;

   procedure Emit_DotDot (Success : out Boolean) is
   begin
      Success := True;
   end Emit_DotDot;

   procedure Emit_Loop_Step_Mid (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Loop_Step_Mid;

   procedure Emit_Loop_Step_End (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Loop_Step_End;

   procedure Emit_Loop_Start (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Loop_Start;

   procedure Emit_Loop_End (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Loop_End;

   procedure Emit_Try_Start
     (Success : out Boolean)
   is
   begin
      if Try_Depth >= Max_Try_Depth then
         Success := False;
         return;
      end if;

      Try_Counter := Try_Counter + 1;
      Try_Depth := Try_Depth + 1;
      Try_Stack (Try_Depth) := Try_Counter;
      Success := True;
   end Emit_Try_Start;

   procedure Emit_Catch_Start
     (Err_Var : String;
      Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      if Try_Depth = 0 then
         Success := False;
         return;
      end if;

      declare
         ID_Text : constant String := Trim_Image (Natural'Image (Try_Stack (Try_Depth)));
      begin
         if OK then Line ("  jmp .alb16_try_end_" & ID_Text, OK); end if;
         if OK then Line (".alb16_catch_" & ID_Text & ":", OK); end if;

         if Err_Var'Length > 0 and then OK then
            Line ("  mov word [" & Err_Var & "], ax", OK);
         end if;

         Success := OK;
      end;
   end Emit_Catch_Start;

   procedure Emit_Try_End
     (Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      if Try_Depth = 0 then
         Success := False;
         return;
      end if;

      declare
         ID_Text : constant String := Trim_Image (Natural'Image (Try_Stack (Try_Depth)));
      begin
         if OK then Line (".alb16_try_end_" & ID_Text & ":", OK); end if;
         Try_Depth := Try_Depth - 1;
         Success := OK;
      end;
   end Emit_Try_End;

   procedure Emit_Throw_Start
     (Success : out Boolean)
   is
   begin
      Success := True;
   end Emit_Throw_Start;

   procedure Emit_Throw_End
     (Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      if Try_Depth = 0 then
         Success := False;
         return;
      end if;

      declare
         ID_Text : constant String := Trim_Image (Natural'Image (Try_Stack (Try_Depth)));
      begin
         if OK then Line ("  jmp .alb16_catch_" & ID_Text, OK); end if;
         Success := OK;
      end;
   end Emit_Throw_End;
   
   --================================================================
   -- FUNCTIONS/PROCEDURES   ========================================
   --================================================================
   procedure Emit_Forward_Declaration
     (Func_Name : String;
      Success   : out Boolean)
   is
      pragma Unreferenced (Func_Name);
   begin
      Success := True;
   end Emit_Forward_Declaration;

   procedure Emit_Procedure_Decl_Start
     (Name    : String;
      Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      Current_Buffer := Buffer_Main;

      if OK then Line ("  jmp near ALB16_skip_proc_" & Name, OK); end if;
      if OK then Line (Name & ":", OK); end if;

      In_Global_Scope := False;
      Success := OK;
   end Emit_Procedure_Decl_Start;

   procedure Emit_Function_Decl_Start
     (Func_Name  : String;
      Return_Tag : ALB_Type_Tag;
      Success    : out Boolean)
   is
      pragma Unreferenced (Return_Tag);
   begin
      Emit_Procedure_Decl_Start (Func_Name, Success);
   end Emit_Function_Decl_Start;

   procedure Emit_Procedure_End
     (Name    : String;
      Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      Current_Buffer := Buffer_Main;

      if OK then Line ("  ret", OK); end if;
      if OK then Line ("ALB16_skip_proc_" & Name & ":", OK); end if;

      In_Global_Scope := True;
      Success := OK;
   end Emit_Procedure_End;
   
   procedure Emit_Return_Start
     (Success : out Boolean)
   is
   begin
      Append ("ret ", Success);
   end Emit_Return_Start;

   procedure Emit_Comma
     (Success : out Boolean)
   is
   begin
      Append (", ", Success);
   end Emit_Comma;

   procedure Emit_Window_Creation
     (Title   : String;
      Success : out Boolean)
   is
      pragma Unreferenced (Title);
      OK : Boolean := True;
   begin
      Current_Buffer := Buffer_Main;

      -- Use existing variables, which are now correctly initialized!
      if OK then Line ("  mov ax, word [ALB_Screen_Width]", OK); end if;
      if OK then Line ("  mov word [ALB_Virtual_Width], ax", OK); end if;
      if OK then Line ("  mov ax, word [ALB_Screen_Height]", OK); end if;
      if OK then Line ("  mov word [ALB_Virtual_Height], ax", OK); end if;
      if OK then Emit_Absolute_Near_Call ("ALB16_GFX_Ensure_Buffer", OK); end if;
      if OK then Line ("  mov ax, 0013h", OK); end if;
      if OK then Line ("  int 10h", OK); end if;
      if OK then Line ("  mov byte [ALB16_GFX_Mode_Active], 1", OK); end if;
      if OK then Emit_Absolute_Near_Call ("ALB16_GFX_Init_Palette", OK); end if;
      if OK then Emit_Absolute_Near_Call ("ALB16_Input_Init", OK); end if;
      if OK then Emit_Absolute_Near_Call ("ALB16_GFX_Frame_Begin", OK); end if;
      if OK then Emit_Absolute_Near_Call ("ALB16_GFX_Present", OK); end if;

      Success := OK;
   end Emit_Window_Creation;

   procedure Emit_Message_Loop
     (Success : out Boolean)
   is
      OK : Boolean := True;
   begin
      -- Transfer control to the terminal lean event loop (emitted at program end).
      -- LISTEN does not return until ESC / ALB_CEASE.
      if OK then Line ("  jmp ALB16_EVENT_LOOP", OK); end if;
      Success := OK;
   end Emit_Message_Loop;

   procedure Emit_Require_Start
     (Success : out Boolean)
   is
   begin
      Success := True;
   end Emit_Require_Start;

   procedure Emit_Ensure_Start
     (Success : out Boolean)
   is
   begin
      Success := True;
   end Emit_Ensure_Start;

   procedure Emit_Contract_End
     (Name    : String;
      Success : out Boolean)
   is
      OK  : Boolean := True;
      Img : constant String := Natural'Image (Contract_Check_Counter + 1);
      Id  : constant String := Img (Img'First + 1 .. Img'Last);
      Kind : constant String :=
        (if Name = "ENSURE" then "ENSURE" else "REQUIRE");
   begin
      Contract_Check_Counter := Contract_Check_Counter + 1;
      -- Predicate result is in DX:AX (FASM16 ABI). Non-zero = pass.
      if OK then Line ("  or ax, dx", OK); end if;
      if OK then Line ("  jnz .alb16_contract_ok_" & Id, OK); end if;
      if OK then Line ("  mov dx, ALB16_Contract_" & Kind, OK); end if;
      if OK then Line ("  call ALB16_Print_C_Str", OK); end if;
      if OK then Line ("  call ALB16_Print_Newline", OK); end if;
      if OK then Line ("  mov ax, 4C01h", OK); end if;
      if OK then Line ("  int 21h", OK); end if;
      if OK then Line (".alb16_contract_ok_" & Id & ":", OK); end if;
      Success := OK;
   end Emit_Contract_End;

   procedure Emit_Statement_End
     (Success : out Boolean)
   is
   begin
      Success := True;
   end Emit_Statement_End;

end Emit_Native_FASM16;
