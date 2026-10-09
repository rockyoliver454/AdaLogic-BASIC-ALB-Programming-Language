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
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with ALB_Types; use ALB_Types;
with Opcodes;   use Opcodes;
with Code_Vault; use Code_Vault;

package body Emit_Native_C is

   -- =========================================================================
   -- THE DUAL-VAULT STATIC BUFFERS (Strictly Nae Heap!)
   -- =========================================================================
   --  Match FASM vault so the same GameDeck host can emit C without clipping.
   Max_Buffer_Size : constant Natural := 8_388_608;

   Global_Buffer : String (1 .. Max_Buffer_Size) := (others => ' ');
   Global_Len    : Natural := 0;

   Main_Buffer : String (1 .. Max_Buffer_Size) := (others => ' ');
   Main_Len    : Natural := 0;
   
   -- DA NEW DECLARATION VAULT FOR FORWARD DECLS
   Decl_Buffer : String (1 .. Max_Buffer_Size) := (others => ' ');
   Decl_Len    : Natural := 0;
   Headers_End_Idx : Natural := 0;
   
   FFI_Loader_Emitted : Boolean := False;

   Current_For_Iterator : String (1 .. 64) := (others => ' ');
   Current_For_Len      : Natural := 0;
   Loop_Extra_Scope     : array (1 .. 128) of Boolean := (others => False);
   Loop_Extra_Top       : Natural := 0;
   
   Is_GUI_Active : Boolean := False;

   -- =========================================================================
   -- HELPER: ROUTED APPEND (Writes tae da Active Vault)
   -- =========================================================================
   procedure Append (Str : String; Success : out Boolean) is
   begin
      if Current_Buffer = Buffer_Global then
         if Global_Len + Str'Length <= Max_Buffer_Size then
            Global_Buffer (Global_Len + 1 .. Global_Len + Str'Length) := Str;
            Global_Len := Global_Len + Str'Length;
            Success := True;
         else
            Success := False; -- Architecture Breach: Global Vault Exhausted
         end if;
      else
         if Main_Len + Str'Length <= Max_Buffer_Size then
            Main_Buffer (Main_Len + 1 .. Main_Len + Str'Length) := Str;
            Main_Len := Main_Len + Str'Length;
            Success := True;
         else
            Success := False; -- Architecture Breach: Main Vault Exhausted
         end if;
      end if;
   end Append;
   
   procedure Insert_Header_Text (Text : String; Success : out Boolean) is
      Insert_At : Natural;
   begin
      if Headers_End_Idx = 0 then
         if Global_Len + Text'Length <= Max_Buffer_Size then
            Global_Buffer (Global_Len + 1 .. Global_Len + Text'Length) := Text;
            Global_Len := Global_Len + Text'Length;
            Headers_End_Idx := Headers_End_Idx + Text'Length;
            Success := True;
         else
            Success := False;
         end if;
         return;
      end if;

      if Global_Len + Text'Length > Max_Buffer_Size then
         Success := False;
         return;
      end if;

      Insert_At := Headers_End_Idx + 1;

      if Insert_At <= Global_Len then
         for I in reverse Insert_At .. Global_Len loop
            Global_Buffer (I + Text'Length) := Global_Buffer (I);
         end loop;
      end if;

      for I in Text'Range loop
         Global_Buffer (Insert_At + (I - Text'First)) := Text (I);
      end loop;

      Global_Len := Global_Len + Text'Length;
      Headers_End_Idx := Headers_End_Idx + Text'Length;
      Success := True;
   end Insert_Header_Text;

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

   function C_Type_Name (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 =>
            return "uint8_t";

         when Type_S8 | Type_HW8 | Type_Char =>
            return "int8_t";

         when Type_U16 =>
            return "uint16_t";

         when Type_S16 | Type_HW16 =>
            return "int16_t";

         when Type_U32 =>
            return "uint32_t";

         when Type_S32 | Type_HW32 =>
            return "int32_t";

         when Type_U64 =>
            return "uint64_t";

         when Type_S64 | Type_HW64 =>
            return "int64_t";

         when Type_U128 =>
            return "unsigned __int128";

         when Type_S128 =>
            return "__int128";

         when Type_F32 =>
            return "float";

         when Type_F64 | Type_F128 =>
            return "double";

         when Type_Boolean =>
            return "uint8_t";

         when Type_Pure =>
            return "uint64_t";  -- packed soft limb; runtime macros own layout

         when Type_Binary =>
            return "char*";

         when Type_F32x2 =>
            return "ALB_F32x2";

         when Type_F32x4 =>
            return "ALB_F32x4";

         when Type_U32x4 =>
            return "ALB_U32x4";

         when Type_S32x4 =>
            return "ALB_S32x4";

         when Type_Mat2x2 =>
            return "ALB_F32x2";

         when Type_Mat3x3 =>
            return "ALB_F32x4";

         when Type_Mat4x4 =>
            return "ALB_F32x4";

         when others =>
            return "uint64_t";
      end case;
   end C_Type_Name;

   function Declaration_Exists (Text : String) return Boolean is
   begin
      if Text'Length = 0 or else Decl_Len < Text'Length then
         return False;
      end if;

      for I in 1 .. Decl_Len - Text'Length + 1 loop
         if Decl_Buffer (I .. I + Text'Length - 1) = Text then
            return True;
         end if;
      end loop;

      return False;
   end Declaration_Exists;

   procedure Append_Declaration_Text (Text : String; Success : out Boolean) is
   begin
      if Declaration_Exists (Text) then
         Success := True;
      elsif Decl_Len + Text'Length <= Max_Buffer_Size then
         Decl_Buffer (Decl_Len + 1 .. Decl_Len + Text'Length) := Text;
         Decl_Len := Decl_Len + Text'Length;
         Success := True;
      else
         Success := False;
      end if;
   end Append_Declaration_Text;

   procedure Push_Loop_Close (Has_Extra_Scope : Boolean) is
   begin
      if Loop_Extra_Top < Loop_Extra_Scope'Last then
         Loop_Extra_Top := Loop_Extra_Top + 1;
         Loop_Extra_Scope (Loop_Extra_Top) := Has_Extra_Scope;
      end if;
   end Push_Loop_Close;

   function Pop_Loop_Close return Boolean is
      Result : Boolean := False;
   begin
      if Loop_Extra_Top > 0 then
         Result := Loop_Extra_Scope (Loop_Extra_Top);
         Loop_Extra_Top := Loop_Extra_Top - 1;
      end if;

      return Result;
   end Pop_Loop_Close;

   function C_Block_Is_Space (Ch : Character) return Boolean is
   begin
      return Ch = ' ' or else Ch = ASCII.HT or else Ch = ASCII.CR;
   end C_Block_Is_Space;

   function C_Block_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      else
         return Ch;
      end if;
   end C_Block_Upper;

   function C_Block_Is_End_Enable_Line (Line : String) return Boolean is
      First : Integer := Line'First;
      Last  : Integer := Line'Last;
   begin
      while First <= Last and then C_Block_Is_Space (Line (First)) loop
         First := First + 1;
      end loop;

      while Last >= First and then C_Block_Is_Space (Line (Last)) loop
         Last := Last - 1;
      end loop;

      if Last < First then
         return False;
      end if;

      declare
         Len : constant Integer := Last - First + 1;
      begin
         if Len = 10 then
            return
              C_Block_Upper (Line (First)) = 'E'
                and then C_Block_Upper (Line (First + 1)) = 'N'
                and then C_Block_Upper (Line (First + 2)) = 'D'
                and then (Line (First + 3) = ' ' or else Line (First + 3) = '_')
                and then C_Block_Upper (Line (First + 4)) = 'E'
                and then C_Block_Upper (Line (First + 5)) = 'N'
                and then C_Block_Upper (Line (First + 6)) = 'A'
                and then C_Block_Upper (Line (First + 7)) = 'B'
                and then C_Block_Upper (Line (First + 8)) = 'L'
                and then C_Block_Upper (Line (First + 9)) = 'E';
         else
            return False;
         end if;
      end;
   end C_Block_Is_End_Enable_Line;

   function C_Reversible_Current_Expr
     (Name : String;
      Tag  : ALB_Type_Tag) return String
   is
   begin
      case Tag is
         when Type_U8 | Type_Boolean =>
            return "((uint64_t)(uint8_t)(" & Name & "))";

         when Type_HW8 =>
            return "((uint64_t)(uint8_t)(int8_t)(" & Name & "))";

         when Type_U16 =>
            return "((uint64_t)(uint16_t)(" & Name & "))";

         when Type_HW16 =>
            return "((uint64_t)(uint16_t)(int16_t)(" & Name & "))";

         when Type_U32 =>
            return "((uint64_t)(uint32_t)(" & Name & "))";

         when Type_S32 | Type_HW32 =>
            return "((uint64_t)(uint32_t)(int32_t)(" & Name & "))";

         when others =>
            return "((uint64_t)(" & Name & "))";
      end case;
   end C_Reversible_Current_Expr;

   function C_Reversible_Assign_Expr
     (Tag        : ALB_Type_Tag;
      Value_Expr : String) return String
   is
   begin
      case Tag is
         when Type_U8 | Type_Boolean =>
            return "((uint8_t)(" & Value_Expr & "))";

         when Type_HW8 =>
            return "((int8_t)(uint8_t)(" & Value_Expr & "))";

         when Type_U16 =>
            return "((uint16_t)(" & Value_Expr & "))";

         when Type_HW16 =>
            return "((int16_t)(uint16_t)(" & Value_Expr & "))";

         when Type_U32 =>
            return "((uint32_t)(" & Value_Expr & "))";

         when Type_S32 | Type_HW32 =>
            return "((int32_t)(uint32_t)(" & Value_Expr & "))";

         when others =>
            return "((uint64_t)(" & Value_Expr & "))";
      end case;
   end C_Reversible_Assign_Expr;

   function C_Reversible_Width_Bits
     (Tag : ALB_Type_Tag) return Natural
   is
   begin
      case Tag is
         when Type_U8 | Type_HW8 | Type_Boolean =>
            return 8;

         when Type_U16 | Type_HW16 =>
            return 16;

         when Type_U32 | Type_S32 | Type_HW32 =>
            return 32;

         when others =>
            return 64;
      end case;
   end C_Reversible_Width_Bits;

   function C_Temporal_Pack_Expr
     (Value_Expr : String;
      Tag        : ALB_Type_Tag) return String
   is
   begin
      case Tag is
         when Type_U8 | Type_Boolean =>
            return "((uint64_t)(uint8_t)(" & Value_Expr & "))";

         when Type_HW8 =>
            return "((uint64_t)(int64_t)(int8_t)(" & Value_Expr & "))";

         when Type_U16 =>
            return "((uint64_t)(uint16_t)(" & Value_Expr & "))";

         when Type_HW16 =>
            return "((uint64_t)(int64_t)(int16_t)(" & Value_Expr & "))";

         when Type_U32 =>
            return "((uint64_t)(uint32_t)(" & Value_Expr & "))";

         when Type_S32 | Type_HW32 =>
            return "((uint64_t)(int64_t)(int32_t)(" & Value_Expr & "))";

         when others =>
            return "((uint64_t)(" & Value_Expr & "))";
      end case;
   end C_Temporal_Pack_Expr;

   function C_Temporal_Unpack_Expr
     (Value_Expr : String;
      Tag        : ALB_Type_Tag) return String
   is
   begin
      case Tag is
         when Type_U8 | Type_Boolean =>
            return "((uint64_t)(uint8_t)(" & Value_Expr & "))";

         when Type_HW8 =>
            return "((uint64_t)(int64_t)(int8_t)(" & Value_Expr & "))";

         when Type_U16 =>
            return "((uint64_t)(uint16_t)(" & Value_Expr & "))";

         when Type_HW16 =>
            return "((uint64_t)(int64_t)(int16_t)(" & Value_Expr & "))";

         when Type_U32 =>
            return "((uint64_t)(uint32_t)(" & Value_Expr & "))";

         when Type_S32 | Type_HW32 =>
            return "((uint64_t)(int64_t)(int32_t)(" & Value_Expr & "))";

         when others =>
            return "((uint64_t)(" & Value_Expr & "))";
      end case;
   end C_Temporal_Unpack_Expr;

   function C_Assign_Cast_Expr
     (Value_Expr : String;
      Tag        : ALB_Type_Tag) return String
   is
   begin
      case Tag is
         when Type_U8 | Type_Boolean =>
            return "(uint8_t)(" & Value_Expr & ")";

         when Type_HW8 =>
            return "(int8_t)(" & Value_Expr & ")";

         when Type_U16 =>
            return "(uint16_t)(" & Value_Expr & ")";

         when Type_HW16 =>
            return "(int16_t)(" & Value_Expr & ")";

         when Type_U32 =>
            return "(uint32_t)(" & Value_Expr & ")";

         when Type_S32 | Type_HW32 =>
            return "(int32_t)(" & Value_Expr & ")";

         when others =>
            return "(uint64_t)(" & Value_Expr & ")";
      end case;
   end C_Assign_Cast_Expr;
   

   -- =========================================================================
   -- INITIALIZATION & LIFECYCLE
   -- =========================================================================
   procedure Init_Emitter (Success : out Boolean) is
   begin
      Global_Len := 0;
      Main_Len := 0;
      Decl_Len := 0;
      Headers_End_Idx := 0;
      Loop_Extra_Top := 0;
      FFI_Loader_Emitted := False;
      Indent_Level := 0;
      In_Global_Scope := True;
      Current_Buffer := Buffer_Global;
      C_Emitter_Ready := True;
      Success := True;
   end Init_Emitter;

   procedure Set_Active_Buffer (Target : Buffer_Target) is
   begin
      Current_Buffer := Target;
   end Set_Active_Buffer;

   --  procedure Flush_To_File (File_Path : String; Success : out Boolean) is
   --     File : Ada.Text_IO.File_Type;
   --  begin
   --     Success := True;
   --     begin
   --        Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, File_Path);
   --  
   --        -- Stitch da vaults thegither wi' da declarations safely in da middle!
   --        if Headers_End_Idx > 0 then
   --           Ada.Text_IO.Put (File, Global_Buffer (1 .. Headers_End_Idx));
   --           Ada.Text_IO.Put (File, Decl_Buffer (1 .. Decl_Len));
   --           Ada.Text_IO.Put (File, Global_Buffer (Headers_End_Idx + 1 .. Global_Len));
   --        else
   --           Ada.Text_IO.Put (File, Global_Buffer (1 .. Global_Len));
   --        end if;
   --  
   --        Ada.Text_IO.Put (File, Main_Buffer (1 .. Main_Len));
   --        Ada.Text_IO.Close (File);
   --     exception
   --        when others =>
   --           Success := False;
   --     end;
   --  end Flush_To_File;
   procedure Flush_To_File (File_Path : String; Success : out Boolean) is
      File : Ada.Text_IO.File_Type;
   begin
      Success := True;

      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, File_Path);
         
         -- Stitch the fixed header, explicit forward declarations, global bodies,
         -- and then main output in deterministic order.
         if Headers_End_Idx > 0 then
            Ada.Text_IO.Put (File, Global_Buffer (1 .. Headers_End_Idx));
            if Decl_Len > 0 then
               Ada.Text_IO.Put (File, Decl_Buffer (1 .. Decl_Len));
            end if;
            Ada.Text_IO.Put (File, Global_Buffer (Headers_End_Idx + 1 .. Global_Len));
         else
            if Decl_Len > 0 then
               Ada.Text_IO.Put (File, Decl_Buffer (1 .. Decl_Len));
            end if;
            Ada.Text_IO.Put (File, Global_Buffer (1 .. Global_Len));
         end if;
         
         Ada.Text_IO.Put (File, Main_Buffer (1 .. Main_Len));
         Ada.Text_IO.Close (File);
      exception
         when others =>
            Success := False;
      end;
   end Flush_To_File;
   
   -- =========================================================================
   -- HELPER: CORE BOILERPLATE
   -- =========================================================================
   procedure Emit_Core_Boilerplate (Success : out Boolean) is
      S : Boolean := True;
   begin
      Append ("/* ========================================================== */", S); Emit_Newline (S);
      Append ("/* GENERATED BY ADALOGIC BASIC (ALB) TRANSPILER v0.0.2.24     */", S); Emit_Newline (S);
      Append ("/* TARGET: ANSI C89 / VC6-ERA NATIVE C BACKEND                */", S); Emit_Newline (S);
      Append ("/* ========================================================== */", S); Emit_Newline (S);
      Emit_Newline (S);
      
      -- DA FIX: Silence pedantic warnings sae the Transpiler output compiles clean!
      Append ("#if defined(__GNUC__)", S); Emit_Newline (S);
      Append ("#pragma GCC diagnostic ignored ""-Wformat""", S); Emit_Newline (S);
      Append ("#pragma GCC diagnostic ignored ""-Wunused-result""", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("#include <stdio.h>", S); Emit_Newline (S);
      Append ("#include <stddef.h> /* DA NEW OFFSETOF FORGE */", S); Emit_Newline (S);
      Append ("#include <stdlib.h>", S); Emit_Newline (S);
      Append ("#include <string.h>", S); Emit_Newline (S);
      Append ("#include <math.h>", S); Emit_Newline (S);
      Append ("#include <time.h>", S); Emit_Newline (S);
      Append ("#include <setjmp.h>", S); Emit_Newline (S);
      Append ("#include <limits.h>", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("typedef signed char int8_t;", S); Emit_Newline (S);
      Append ("typedef unsigned char uint8_t;", S); Emit_Newline (S);
      Append ("typedef signed short int16_t;", S); Emit_Newline (S);
      Append ("typedef unsigned short uint16_t;", S); Emit_Newline (S);
      Append ("#if UINT_MAX == 0xFFFFFFFFU", S); Emit_Newline (S);
      Append ("typedef signed int int32_t;", S); Emit_Newline (S);
      Append ("typedef unsigned int uint32_t;", S); Emit_Newline (S);
      Append ("#else", S); Emit_Newline (S);
      Append ("#error ""ALB C backend requires 32-bit int support.""", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("#if defined(_WIN32) || defined(_WIN64)", S); Emit_Newline (S);
      Append ("typedef signed __int64 int64_t;", S); Emit_Newline (S);
      Append ("typedef unsigned __int64 uint64_t;", S); Emit_Newline (S);
      Append ("#define ALB_S64_FMT ""%I64d""", S); Emit_Newline (S);
      Append ("#define ALB_U64_FMT ""%I64u""", S); Emit_Newline (S);
      Append ("#elif ULONG_MAX > 0xFFFFFFFFUL", S); Emit_Newline (S);
      Append ("typedef signed long int64_t;", S); Emit_Newline (S);
      Append ("typedef unsigned long uint64_t;", S); Emit_Newline (S);
      Append ("#define ALB_S64_FMT ""%ld""", S); Emit_Newline (S);
      Append ("#define ALB_U64_FMT ""%lu""", S); Emit_Newline (S);
      Append ("#else", S); Emit_Newline (S);
      Append ("#error ""ALB C backend requires a compiler wi' 64-bit integer support.""", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("typedef size_t uintptr_t;", S); Emit_Newline (S);
      Append ("#define ALB_U64_ZERO ((uint64_t)0)", S); Emit_Newline (S);
      Append ("#define ALB_U64_ONE ((uint64_t)1)", S); Emit_Newline (S);
      Append ("#define ALB_U64_CONST(hi, lo) ((((uint64_t)((uint32_t)(hi))) << 32) | ((uint64_t)((uint32_t)(lo))))", S); Emit_Newline (S);
      Emit_Newline (S);
      
      -- DA NEW HARDWARE TSC ORACLE FIX
      Append ("/* --- DA HARDWARE TSC ORACLE --- */", S); Emit_Newline (S);
      Append ("#if defined(_MSC_VER)", S); Emit_Newline (S);
      Append ("    static uint64_t __rdtsc(void) { return ALB_U64_ZERO; }", S); Emit_Newline (S);
      Append ("#elif defined(__GNUC__) || defined(__clang__)", S); Emit_Newline (S);
      Append ("    #if defined(__x86_64__) || defined(__i386__)", S); Emit_Newline (S);
      Append ("        #include <x86intrin.h>", S); Emit_Newline (S);
      Append ("    #else", S); Emit_Newline (S);
      Append ("        /* ARM / Non-x86 Fallback sae the Vault disna crash! */", S); Emit_Newline (S);
      Append ("        static uint64_t __rdtsc(void) { return ALB_U64_ZERO; }", S); Emit_Newline (S);
      Append ("    #endif", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("typedef union { uint64_t u; double d; } ALB_Double_Bits;", S); Emit_Newline (S);
      Append ("static double ALB_U64_As_Double(uint64_t val) { ALB_Double_Bits bits; bits.u = val; return bits.d; }", S); Emit_Newline (S);
      Append ("static uint64_t ALB_Double_As_U64(double val) { ALB_Double_Bits bits; bits.d = val; return bits.u; }", S); Emit_Newline (S);
      Append ("static void ALB_Format_U64(char* dest, uint64_t val) { sprintf(dest, ALB_U64_FMT, val); }", S); Emit_Newline (S);
      Append ("static void ALB_Format_S64(char* dest, int64_t val) { sprintf(dest, ALB_S64_FMT, val); }", S); Emit_Newline (S);
      Append ("static void ALB_Format_Pure(char* dest, int32_t num, uint32_t den) { sprintf(dest, ALB_S64_FMT "" / %u"", (int64_t)num, (unsigned)den); }", S); Emit_Newline (S);
      Emit_Newline (S);
      
      Append ("static jmp_buf ALB_Err_Stack[256]; /* Deeply nestable */", S); Emit_Newline (S);
      Append ("static int ALB_Err_SP = -1;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_Last_Err = 0;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_TEMP_Future_Depth = 0;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_TEMP_Future_Result = 0;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_TEMP_Future_Suppress_IO = 0;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_REV_Tmp = 0;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_REV_Tmp2 = 0;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_Running = 1;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_Rnd_Seed = ALB_U64_CONST(0x00000001, 0x23456789);", S); Emit_Newline (S);
      Emit_Newline (S);
      Success := S;
   end Emit_Core_Boilerplate;
   
   procedure Emit_Platform_HAL (Success : out Boolean) is
      S : Boolean := True;
   begin
      Append ("/* --- ALB PLATFORM HAL (PURE SDL3) --- */", S); Emit_Newline (S);
      Append ("#if defined(_WIN32) || defined(_WIN64)", S); Emit_Newline (S);
      Append ("    #define ALB_PLAT_WIN 1", S); Emit_Newline (S);
      Append ("    #include <winsock2.h>", S); Emit_Newline (S);
      Append ("    #include <ws2tcpip.h>", S); Emit_Newline (S);
      Append ("    #include <windows.h>", S); Emit_Newline (S);
      Append ("    #if defined(_MSC_VER)", S); Emit_Newline (S);
      Append ("    #pragma comment(lib, ""ws2_32.lib"")", S); Emit_Newline (S);
      Append ("    #endif", S); Emit_Newline (S);
      Append ("#elif defined(__linux__) || defined(__unix__) || defined(__FreeBSD__)", S); Emit_Newline (S);
      Append ("    #define ALB_PLAT_POSIX 1", S); Emit_Newline (S);
      Append ("    #include <unistd.h>", S); Emit_Newline (S);
      Append ("    #include <pthread.h>", S); Emit_Newline (S);
      Append ("    #include <semaphore.h>", S); Emit_Newline (S);
      Append ("    #include <fcntl.h>", S); Emit_Newline (S);
      Append ("    #include <sys/time.h>", S); Emit_Newline (S);
      Append ("    #include <sys/types.h>", S); Emit_Newline (S);
      Append ("    #include <sys/socket.h>", S); Emit_Newline (S);
      Append ("    #include <netinet/in.h>", S); Emit_Newline (S);
      Append ("    #include <arpa/inet.h>", S); Emit_Newline (S);
      Append ("#else", S); Emit_Newline (S);
      Append ("    #error ""ALB Native Forge doesna support this target OS yet!""", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Emit_Newline (S);

      --  Append ("/* --- THE SDL3 MASTER INCLUDE --- */", S); Emit_Newline (S);
      --  Append ("#include <SDL3/SDL.h>", S); Emit_Newline (S);
      --  Emit_Newline (S);

      Append ("/* DA TYPE-SAFE SMART PRINT FORGE */", S); Emit_Newline (S);
      Append ("#if defined(ALB_PLAT_POSIX)", S); Emit_Newline (S);
      Append ("static int ALB_Is_Valid_Ptr(uint64_t val) {", S); Emit_Newline (S);
      Append ("    int fd;", S); Emit_Newline (S);
      Append ("    int res;", S); Emit_Newline (S);
      Append ("    if (val < 0x10000) return 0;", S); Emit_Newline (S);
      Append ("    if ((val & ALB_U64_CONST(0xFF000000, 0x00000000)) != 0) return 0;", S); Emit_Newline (S);
      Append ("    fd = open(""/dev/null"", O_WRONLY);", S); Emit_Newline (S);
      Append ("    if (fd < 0) return 0;", S); Emit_Newline (S);
      Append ("    res = (int)write(fd, (const void*)(uintptr_t)val, 1);", S); Emit_Newline (S);
      Append ("    close(fd); return (res >= 0);", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      
      Append ("static void ALB_Smart_Print_Piped(uint64_t val) {", S); Emit_Newline (S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline (S);
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline (S);
      Append ("    if (val > 0x10000 && !IsBadStringPtrA((LPCSTR)(uintptr_t)val, 8192)) {", S); Emit_Newline (S);
      Append ("        printf(""%s"", (char*)(uintptr_t)val); return;", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("#elif defined(ALB_PLAT_POSIX)", S); Emit_Newline (S);
      Append ("    if (ALB_Is_Valid_Ptr(val)) {", S); Emit_Newline (S);
      Append ("        printf(""%s"", (char*)(uintptr_t)val); return;", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("    printf(ALB_S64_FMT, (int64_t)val);", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("static void ALB_Smart_Print(uint64_t val) {", S); Emit_Newline (S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline (S);
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline (S);
      Append ("    if (val > 0x10000 && !IsBadStringPtrA((LPCSTR)(uintptr_t)val, 8192)) {", S); Emit_Newline (S);
      Append ("        printf(""%s\n"", (char*)(uintptr_t)val); return;", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("#elif defined(ALB_PLAT_POSIX)", S); Emit_Newline (S);
      Append ("    if (ALB_Is_Valid_Ptr(val)) {", S); Emit_Newline (S);
      Append ("        printf(""%s\n"", (char*)(uintptr_t)val); return;", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("    printf(ALB_S64_FMT ""\n"", (int64_t)val);", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);
      
      -- DA NEW FLOAT PRINTING FORGE (Paste this right beneath ALB_Smart_Print)
      Append ("static void ALB_Print_Float_Piped(uint64_t val) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    printf(""%g"", ALB_U64_As_Double(val));", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      
      Append ("static void ALB_Print_Float(uint64_t val) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    printf(""%g\n"", ALB_U64_As_Double(val));", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);

      --  Append ("/* CROSS-PLATFORM DELAY */", S); Emit_Newline (S);
      --  Append ("static void ALB_Delay(uint64_t ms) {", S); Emit_Newline (S);
      --  Append ("    SDL_Delay((Uint32)ms);", S); Emit_Newline (S);
      --  Append ("}", S); Emit_Newline (S);
      --  Emit_Newline (S);
      
      Append ("/* CROSS-PLATFORM DELAY (Native C) */", S); Emit_Newline (S);
      Append ("static void ALB_Delay(uint64_t ms) {", S); Emit_Newline (S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline (S);
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline (S);
      Append ("    Sleep((DWORD)ms);", S); Emit_Newline (S);
      Append ("#elif defined(ALB_PLAT_POSIX)", S); Emit_Newline (S);
      Append ("    usleep((unsigned long)(ms * 1000UL));", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Append ("static void ALB_CEASE(void) {", S); Emit_Newline (S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline (S);
      Append ("    ALB_Running = 0;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      
      Success := S;
   end Emit_Platform_HAL;
   
   -- =========================================================================
   -- HELPER: CORE ROUTINES (Strings, Math, File I/O, & VM)
   -- =========================================================================
   procedure Emit_Core_Routines (Success : out Boolean) is
      S : Boolean := True;
   begin
      Append ("/* --- ALB CORE ROUTINES (Math, Strings, I/O) --- */", S); Emit_Newline (S);
      
      -- Math & Constructors
      Append ("#define U64(x) ((uint64_t)(x))", S); Emit_Newline (S);
      Append ("#define S64(x) ((uint64_t)(int64_t)(x))", S); Emit_Newline (S);
      Append ("#define ALB_MASK_OP(cond, t_val, f_val) (((-(uint64_t)(cond)) & (uint64_t)(t_val)) | (~(-(uint64_t)(cond)) & (uint64_t)(f_val)))", S); Emit_Newline (S);
      Append ("#undef PURE", S); Emit_Newline (S);
      Append ("#define PURE(n, d) ((((uint64_t)(n)) << 32) | ((uint32_t)(d)))", S); Emit_Newline (S);
      Append ("static uint64_t ALB_Rol_U64(uint64_t value, uint64_t count, uint64_t width) {", S); Emit_Newline (S);
      Append ("    uint64_t mask;", S); Emit_Newline (S);
      Append ("    if (width == 0) return value;", S); Emit_Newline (S);
      Append ("    if (width >= 64) { count &= 63; if (count == 0) return value; return (value << count) | (value >> (64 - count)); }", S); Emit_Newline (S);
      Append ("    mask = (((uint64_t)1) << width) - 1;", S); Emit_Newline (S);
      Append ("    value &= mask; count %= width; if (count == 0) return value; return ((value << count) | (value >> (width - count))) & mask;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Append ("static uint64_t ALB_Ror_U64(uint64_t value, uint64_t count, uint64_t width) {", S); Emit_Newline (S);
      Append ("    uint64_t mask;", S); Emit_Newline (S);
      Append ("    if (width == 0) return value;", S); Emit_Newline (S);
      Append ("    if (width >= 64) { count &= 63; if (count == 0) return value; return (value >> count) | (value << (64 - count)); }", S); Emit_Newline (S);
      Append ("    mask = (((uint64_t)1) << width) - 1;", S); Emit_Newline (S);
      Append ("    value &= mask; count %= width; if (count == 0) return value; return ((value >> count) | (value << (width - count))) & mask;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      -- Pure Fraction Math
      Append ("static uint64_t ALB_GCD(uint64_t a, uint64_t b) { while (b != 0) { uint64_t t = b; b = a % b; a = t; } return a; }", S); Emit_Newline (S);
      Append ("static uint64_t ALB_PURE_SIMPLIFY(uint64_t n, uint64_t d) { uint64_t g; if (d == 0) return 0; g = ALB_GCD(n, d); return PURE(n/g, d/g); }", S); Emit_Newline (S);
      Append ("static uint64_t ALB_PURE_ADD(uint64_t a, uint64_t b) { uint64_t n = (a>>32)*(b&0xFFFFFFFF) + (b>>32)*(a&0xFFFFFFFF); return ALB_PURE_SIMPLIFY(n, (a&0xFFFFFFFF)*(b&0xFFFFFFFF)); }", S); Emit_Newline (S);
      Append ("static uint64_t ALB_PURE_SUB(uint64_t a, uint64_t b) { uint64_t n = (a>>32)*(b&0xFFFFFFFF) - (b>>32)*(a&0xFFFFFFFF); return ALB_PURE_SIMPLIFY(n, (a&0xFFFFFFFF)*(b&0xFFFFFFFF)); }", S); Emit_Newline (S);
      Append ("static uint64_t ALB_PURE_MUL(uint64_t a, uint64_t b) { return ALB_PURE_SIMPLIFY((a>>32)*(b>>32), (a&0xFFFFFFFF)*(b&0xFFFFFFFF)); }", S); Emit_Newline (S);
      Append ("static uint64_t ALB_PURE_DIV(uint64_t a, uint64_t b) { return ALB_PURE_SIMPLIFY((a>>32)*(b&0xFFFFFFFF), (a&0xFFFFFFFF)*(b>>32)); }", S); Emit_Newline (S);
      Append ("static int64_t ALB_PURE_CMP(uint64_t a, uint64_t b) { int64_t an = (int64_t)(a >> 32); int64_t ad = (int64_t)(a & 0xFFFFFFFF); int64_t bn = (int64_t)(b >> 32); int64_t bd = (int64_t)(b & 0xFFFFFFFF); int64_t lhs = an * bd; int64_t rhs = bn * ad; return (lhs > rhs) - (lhs < rhs); }", S); Emit_Newline (S);
      Append ("static void ALB_PRINT_PURE(uint64_t p) { if (ALB_TEMP_Future_Suppress_IO) return; printf(""%u / %u\n"", (uint32_t)(p >> 32), (uint32_t)(p & 0xFFFFFFFF)); }", S); Emit_Newline (S);
      Append ("static uint64_t ALB_PURE_POW(uint64_t base, uint64_t exp_val) {", S); Emit_Newline (S);
      Append ("    int32_t exp_num = (int32_t)(exp_val >> 32);", S); Emit_Newline (S);
      Append ("    int32_t exp_den = (int32_t)(exp_val & 0xFFFFFFFFu);", S); Emit_Newline (S);
      Append ("    uint64_t result = PURE(1, 1);", S); Emit_Newline (S);
      Append ("    uint64_t factor = base;", S); Emit_Newline (S);
      Append ("    uint32_t power;", S); Emit_Newline (S);
      Append ("    if (exp_den != 1) return PURE(0, 1);", S); Emit_Newline (S);
      Append ("    if (exp_num == 0) return result;", S); Emit_Newline (S);
      Append ("    if (exp_num < 0) { if ((int32_t)(base >> 32) == 0) return PURE(0, 1); factor = ALB_PURE_DIV(PURE(1, 1), base); power = (uint32_t)(-(int64_t)exp_num); } else { power = (uint32_t)exp_num; }", S); Emit_Newline (S);
      Append ("    while (power > 0) { if ((power & 1u) != 0u) result = ALB_PURE_MUL(result, factor); power >>= 1u; if (power > 0) factor = ALB_PURE_MUL(factor, factor); }", S); Emit_Newline (S);
      Append ("    return result;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Append ("static int64_t ALB_POW_S64(int64_t base, int64_t exp_val) { int64_t result = 1; int64_t factor = base; uint64_t power; if (exp_val < 0) { if (base == 1) return 1; if (base == -1) return (exp_val & 1) ? -1 : 1; return 0; } power = (uint64_t)exp_val; while (power > 0) { if ((power & 1U) != 0U) result *= factor; power >>= 1; if (power > 0) factor *= factor; } return result; }", S); Emit_Newline (S);
      -- DA NEW PURE EXTRACTORS FORGE
      Append ("#define ALB_PURE_NUM(p) ((uint64_t)((p) >> 32))", S); Emit_Newline (S);
      Append ("#define ALB_PURE_DEN(p) ((uint64_t)((p) & 0xFFFFFFFF))", S); Emit_Newline (S);
      
      Append ("static void ALB_PRINT_PURE_PIPED(uint64_t p) { if (ALB_TEMP_Future_Suppress_IO) return; printf(""%u / %u"", (uint32_t)(p >> 32), (uint32_t)(p & 0xFFFFFFFF)); }", S); Emit_Newline (S);
      
      -- =====================================================================
      -- DA HARDWARE SIMD MATRIX FORGE
      -- =====================================================================
      Append ("/* --- DA HARDWARE SIMD MATRIX FORGE --- */", S); Emit_Newline (S);
      Append ("#if defined(__GNUC__) || defined(__clang__)", S); Emit_Newline (S);
      Append ("typedef float ALB_F32x4 __attribute__ ((vector_size (16)));", S); Emit_Newline (S);
      Append ("typedef float ALB_F32x2 __attribute__ ((vector_size (8)));", S); Emit_Newline (S);
      Append ("typedef int32_t ALB_S32x4 __attribute__ ((vector_size (16)));", S); Emit_Newline (S);
      Append ("typedef uint32_t ALB_U32x4 __attribute__ ((vector_size (16)));", S); Emit_Newline (S);
      
      Append ("static ALB_F32x4 ALB_Splat(float v) { ALB_F32x4 r; r[0] = v; r[1] = v; r[2] = v; r[3] = v; return r; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_FMA(ALB_F32x4 a, ALB_F32x4 b, ALB_F32x4 c) { return a * b + c; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_Lerp(ALB_F32x4 a, ALB_F32x4 b, float t) { return a + (b - a) * ALB_Splat(t); }", S); Emit_Newline (S);
      
      Append ("static float ALB_Dot(ALB_F32x4 a, ALB_F32x4 b) {", S); Emit_Newline (S);
      Append ("    ALB_F32x4 r = a * b; return r[0] + r[1] + r[2] + r[3];", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      
      Append ("static ALB_F32x4 ALB_Cross(ALB_F32x4 a, ALB_F32x4 b) {", S); Emit_Newline (S);
      Append ("    ALB_F32x4 r; r[0] = a[1]*b[2] - a[2]*b[1]; r[1] = a[2]*b[0] - a[0]*b[2]; r[2] = a[0]*b[1] - a[1]*b[0]; r[3] = 0.0f; return r;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("static ALB_F32x4 ALB_Normalize(ALB_F32x4 a) {", S); Emit_Newline (S);
      Append ("    float d = ALB_Dot(a, a); if (d == 0.0f) return ALB_Splat(0.0f);", S); Emit_Newline (S);
      Append ("    return a * ALB_Splat(1.0f / (float)sqrt((double)d));", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("static ALB_F32x4 ALB_Clamp(ALB_F32x4 v, ALB_F32x4 l, ALB_F32x4 h) {", S); Emit_Newline (S);
      Append ("    ALB_F32x4 r;", S); Emit_Newline (S);
      Append ("    int i; for (i = 0; i < 4; i++) { r[i] = v[i] < l[i] ? l[i] : (v[i] > h[i] ? h[i] : v[i]); }", S); Emit_Newline (S);
      Append ("    return r;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("static ALB_F32x4 ALB_Blend(ALB_F32x4 m, ALB_F32x4 t, ALB_F32x4 f) {", S); Emit_Newline (S);
      Append ("    ALB_F32x4 r;", S); Emit_Newline (S);
      Append ("    int i; for (i = 0; i < 4; i++) { r[i] = m[i] != 0.0f ? t[i] : f[i]; }", S); Emit_Newline (S);
      Append ("    return r;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Append ("#else", S); Emit_Newline (S);
      Append ("typedef struct { float v[4]; } ALB_F32x4;", S); Emit_Newline (S);
      Append ("typedef struct { float v[2]; } ALB_F32x2;", S); Emit_Newline (S);
      Append ("typedef struct { int32_t v[4]; } ALB_S32x4;", S); Emit_Newline (S);
      Append ("typedef struct { uint32_t v[4]; } ALB_U32x4;", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_Splat(float v) { ALB_F32x4 r; int i; for (i = 0; i < 4; ++i) r.v[i] = v; return r; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_FMA(ALB_F32x4 a, ALB_F32x4 b, ALB_F32x4 c) { ALB_F32x4 r; int i; for (i = 0; i < 4; ++i) r.v[i] = a.v[i] * b.v[i] + c.v[i]; return r; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_Lerp(ALB_F32x4 a, ALB_F32x4 b, float t) { ALB_F32x4 r; int i; for (i = 0; i < 4; ++i) r.v[i] = a.v[i] + ((b.v[i] - a.v[i]) * t); return r; }", S); Emit_Newline (S);
      Append ("static float ALB_Dot(ALB_F32x4 a, ALB_F32x4 b) { float sum = 0.0f; int i; for (i = 0; i < 4; ++i) sum += a.v[i] * b.v[i]; return sum; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_Cross(ALB_F32x4 a, ALB_F32x4 b) { ALB_F32x4 r; r.v[0] = a.v[1]*b.v[2] - a.v[2]*b.v[1]; r.v[1] = a.v[2]*b.v[0] - a.v[0]*b.v[2]; r.v[2] = a.v[0]*b.v[1] - a.v[1]*b.v[0]; r.v[3] = 0.0f; return r; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_Normalize(ALB_F32x4 a) { ALB_F32x4 r; float d = ALB_Dot(a, a); int i; if (d == 0.0f) return ALB_Splat(0.0f); for (i = 0; i < 4; ++i) r.v[i] = a.v[i] * (1.0f / (float)sqrt(d)); return r; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_Clamp(ALB_F32x4 v, ALB_F32x4 l, ALB_F32x4 h) { ALB_F32x4 r; int i; for (i = 0; i < 4; ++i) r.v[i] = v.v[i] < l.v[i] ? l.v[i] : (v.v[i] > h.v[i] ? h.v[i] : v.v[i]); return r; }", S); Emit_Newline (S);
      Append ("static ALB_F32x4 ALB_Blend(ALB_F32x4 m, ALB_F32x4 t, ALB_F32x4 f) { ALB_F32x4 r; int i; for (i = 0; i < 4; ++i) r.v[i] = m.v[i] != 0.0f ? t.v[i] : f.v[i]; return r; }", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Emit_Newline (S);
      
      -- Random Number Generator
      Append ("uint64_t ALB_Rnd(uint64_t max_val) {", S); Emit_Newline(S);
      Append ("    if (ALB_Rnd_Seed == ALB_U64_CONST(0x00000001, 0x23456789)) { ALB_Rnd_Seed ^= (uint64_t)time(NULL); }", S); Emit_Newline(S);
      Append ("    ALB_Rnd_Seed ^= ALB_Rnd_Seed << 13; ALB_Rnd_Seed ^= ALB_Rnd_Seed >> 7; ALB_Rnd_Seed ^= ALB_Rnd_Seed << 17;", S); Emit_Newline(S);
      Append ("    return (max_val > 0) ? (ALB_Rnd_Seed % max_val) : ALB_U64_ZERO;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);

      -- Bounded String Manipulation (Fixed Buffers)
      Append ("static uint64_t ALB_Text_Pipe_Left = 0;", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Text_Pipe_Right = 0;", S); Emit_Newline(S);
      Append ("static char* ALB_Last_Binary_Read = NULL;", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Last_Binary_Length = 0;", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_String_Left(uint64_t str_ptr, uint64_t len) {", S); Emit_Newline(S);
      Append ("    static char b[16][8192];", S); Emit_Newline(S);
      Append ("    static int i = 0;", S); Emit_Newline(S);
      Append ("    char* s = (char*)(uintptr_t)str_ptr;", S); Emit_Newline(S);
      Append ("    char* d;", S); Emit_Newline(S);
      Append ("    uint64_t l;", S); Emit_Newline(S);
      Append ("    if (!s) return (uint64_t)(uintptr_t)"""";", S); Emit_Newline(S);
      Append ("    d = b[i = (i + 1) % 16];", S); Emit_Newline(S);
      Append ("    l = (s == ALB_Last_Binary_Read) ? ALB_Last_Binary_Length : (uint64_t)strlen(s);", S); Emit_Newline(S);
      Append ("    if (len > l) { len = l; }", S); Emit_Newline(S);
      Append ("    if (len > 8191) { len = 8191; }", S); Emit_Newline(S);
      Append ("    memcpy(d, s, (size_t)len);", S); Emit_Newline(S);
      Append ("    d[len] = '\0';", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static uint64_t ALB_String_Mid(uint64_t str_ptr, uint64_t start, uint64_t len) {", S); Emit_Newline(S);
      Append ("    static char b[16][8192];", S); Emit_Newline(S);
      Append ("    static int i = 0;", S); Emit_Newline(S);
      Append ("    char* s = (char*)(uintptr_t)str_ptr;", S); Emit_Newline(S);
      Append ("    char* d;", S); Emit_Newline(S);
      Append ("    uint64_t l;", S); Emit_Newline(S);
      Append ("    if (!s || start == 0) return (uint64_t)(uintptr_t)"""";", S); Emit_Newline(S);
      Append ("    l = (s == ALB_Last_Binary_Read) ? ALB_Last_Binary_Length : (uint64_t)strlen(s);", S); Emit_Newline(S);
      Append ("    if (start > l) return (uint64_t)(uintptr_t)"""";", S); Emit_Newline(S);
      Append ("    s += (start - 1);", S); Emit_Newline(S);
      Append ("    l = l - (start - 1);", S); Emit_Newline(S);
      Append ("    d = b[i = (i + 1) % 16];", S); Emit_Newline(S);
      Append ("    if (len > l) { len = l; }", S); Emit_Newline(S);
      Append ("    if (len > 8191) { len = 8191; }", S); Emit_Newline(S);
      Append ("    memcpy(d, s, (size_t)len);", S); Emit_Newline(S);
      Append ("    d[len] = '\0';", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static uint64_t ALB_String_Right(uint64_t str_ptr, uint64_t len) {", S); Emit_Newline(S);
      Append ("    static char b[16][8192];", S); Emit_Newline(S);
      Append ("    static int i = 0;", S); Emit_Newline(S);
      Append ("    char* s = (char*)(uintptr_t)str_ptr;", S); Emit_Newline(S);
      Append ("    char* d;", S); Emit_Newline(S);
      Append ("    uint64_t l;", S); Emit_Newline(S);
      Append ("    if (!s) return (uint64_t)(uintptr_t)"""";", S); Emit_Newline(S);
      Append ("    l = (s == ALB_Last_Binary_Read) ? ALB_Last_Binary_Length : (uint64_t)strlen(s);", S); Emit_Newline(S);
      Append ("    if (len > l) len = l;", S); Emit_Newline(S);
      Append ("    s += (l - len);", S); Emit_Newline(S);
      Append ("    d = b[i = (i + 1) % 16];", S); Emit_Newline(S);
      Append ("    if (len > 8191) { len = 8191; }", S); Emit_Newline(S);
      Append ("    memcpy(d, s, (size_t)len);", S); Emit_Newline(S);
      Append ("    d[len] = '\0';", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static uint64_t ALB_String_Asc(uint64_t str_ptr) {", S); Emit_Newline(S);
      Append ("    char* s = (char*)(uintptr_t)str_ptr;", S); Emit_Newline(S);
      Append ("    if(!s || s[0] == '\0') return 0;", S); Emit_Newline(S);
      Append ("    return (uint64_t)(unsigned char)s[0];", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      -- DA NEW CONCAT, INSERT, AND REMOVE FORGE
      Append ("static uint64_t ALB_String_Concat(uint64_t s1_p, uint64_t s2_p) {", S); Emit_Newline(S);
      Append ("    static char b[128][8192]; static int i=0;", S); Emit_Newline(S);
      Append ("    char* s1 = (char*)(uintptr_t)s1_p; char* s2 = (char*)(uintptr_t)s2_p;", S); Emit_Newline(S);
      Append ("    char* d = b[i=(i+1)%128]; d[0] = '\0';", S); Emit_Newline(S);
      Append ("    if(s1) { strncpy(d, s1, 8191); d[8191] = '\0'; }", S); Emit_Newline(S);
      Append ("    if(s2) { strncat(d, s2, 8191 - strlen(d)); }", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_String_From_U64(uint64_t val) {", S); Emit_Newline(S);
      Append ("    static char b[128][64]; static int i = 0; char* d = b[i = (i + 1) % 128];", S); Emit_Newline(S);
      Append ("    ALB_Format_U64(d, val);", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_String_From_S64(uint64_t val) {", S); Emit_Newline(S);
      Append ("    static char b[128][64]; static int i = 0; char* d = b[i = (i + 1) % 128];", S); Emit_Newline(S);
      Append ("    ALB_Format_S64(d, (int64_t)val);", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_String_From_F64(uint64_t val) {", S); Emit_Newline(S);
      Append ("    static char b[128][64]; static int i = 0; char* d = b[i = (i + 1) % 128];", S); Emit_Newline(S);
      Append ("    snprintf(d, 64, ""%g"", ALB_U64_As_Double(val));", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_String_From_Pure(uint64_t p) {", S); Emit_Newline(S);
      Append ("    static char b[128][64]; static int i = 0; char* d = b[i = (i + 1) % 128];", S); Emit_Newline(S);
      Append ("    int32_t num = (int32_t)(p >> 32); uint32_t den = (uint32_t)(p & 0xFFFFFFFFu);", S); Emit_Newline(S);
      Append ("    ALB_Format_Pure(d, num, den);", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      
      -- DA NATIVE CHR GENERATOR
      Append ("static uint64_t ALB_String_Chr(uint64_t val) {", S); Emit_Newline(S);
      Append ("    static char b[128][2]; static int i=0;", S); Emit_Newline(S);
      Append ("    char* d = b[i=(i+1)%128];", S); Emit_Newline(S);
      Append ("    d[0] = (char)val; d[1] = '\0';", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static uint64_t ALB_String_Insert(uint64_t s1_p, uint64_t pos, uint64_t s2_p) {", S); Emit_Newline(S);
      Append ("    static char b[128][8192]; static int i=0;", S); Emit_Newline(S);
      Append ("    char* s1 = (char*)(uintptr_t)s1_p; char* s2 = (char*)(uintptr_t)s2_p;", S); Emit_Newline(S);
      Append ("    char* d = b[i=(i+1)%128]; d[0] = '\0';", S); Emit_Newline(S);
      Append ("    if(!s1) s1 = """";", S); Emit_Newline(S);
      Append ("    if(!s2) s2 = """";", S); Emit_Newline(S);
      Append ("    { uint64_t l1 = (uint64_t)strlen(s1); if(pos > l1) pos = l1; }", S); Emit_Newline(S);
      Append ("    strncpy(d, s1, pos); d[pos] = '\0';", S); Emit_Newline(S);
      Append ("    strncat(d, s2, 8191 - strlen(d));", S); Emit_Newline(S);
      Append ("    strncat(d, s1 + pos, 8191 - strlen(d));", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static uint64_t ALB_String_Remove(uint64_t s1_p, uint64_t pos, uint64_t count) {", S); Emit_Newline(S);
      Append ("    static char b[128][8192]; static int i=0;", S); Emit_Newline(S);
      Append ("    char* s1 = (char*)(uintptr_t)s1_p;", S); Emit_Newline(S);
      Append ("    char* d = b[i=(i+1)%128]; d[0] = '\0';", S); Emit_Newline(S);
      Append ("    if(!s1) return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("    { uint64_t l1 = (uint64_t)strlen(s1); if(pos >= l1) { strncpy(d, s1, 8191); return (uint64_t)(uintptr_t)d; } }", S); Emit_Newline(S);
      Append ("    strncpy(d, s1, pos); d[pos] = '\0';", S); Emit_Newline(S);
      Append ("    { uint64_t l1 = (uint64_t)strlen(s1); if(pos + count < l1) strncat(d, s1 + pos + count, 8191 - strlen(d)); }", S); Emit_Newline(S);
      Append ("    return (uint64_t)(uintptr_t)d;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      
      -- File Read
      Append ("static char* ALB_File_Read_Stream(FILE* f, uint64_t bytes) {", S); Emit_Newline (S);
      Append ("    static char fbuf[65536]; /* NASA/JPL static buffer */", S); Emit_Newline (S);
      Append ("    if (!f) return """";", S); Emit_Newline (S);
      Append ("    if (bytes == 0) { if (fgets(fbuf, 65536, f)) return fbuf; return """"; }", S); Emit_Newline (S);
      Append ("    { uint64_t r_b = bytes < 65535 ? bytes : 65535; size_t r = fread(fbuf, 1, (size_t)r_b, f); fbuf[r] = '\0'; ALB_Last_Binary_Read = fbuf; ALB_Last_Binary_Length = (uint64_t)r; return fbuf; }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("#define ALB_MAX_OPEN_FILES 256", S); Emit_Newline (S);
      Append ("typedef struct { FILE* Stream; } ALB_File_Slot;", S); Emit_Newline (S);
      Append ("static ALB_File_Slot ALB_File_Table[ALB_MAX_OPEN_FILES];", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("static FILE* ALB_File_From_Handle(uint64_t handle) {", S); Emit_Newline (S);
      Append ("    if (handle == 0 || handle >= ALB_MAX_OPEN_FILES) return (FILE*)0;", S); Emit_Newline (S);
      Append ("    return ALB_File_Table[(size_t)handle].Stream;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_File_Open(uint64_t path_u, uint64_t mode_u) {", S); Emit_Newline (S);
      Append ("    const char* path = (const char*)(uintptr_t)path_u;", S); Emit_Newline (S);
      Append ("    const char* mode = (const char*)(uintptr_t)mode_u;", S); Emit_Newline (S);
      Append ("    FILE* fp;", S); Emit_Newline (S);
      Append ("    size_t slot;", S); Emit_Newline (S);
      Append ("    if (!path || !mode) return 0;", S); Emit_Newline (S);
      Append ("    fp = fopen(path, mode);", S); Emit_Newline (S);
      Append ("    if (!fp) return 0;", S); Emit_Newline (S);
      Append ("    for (slot = 1; slot < ALB_MAX_OPEN_FILES; ++slot) {", S); Emit_Newline (S);
      Append ("        if (!ALB_File_Table[slot].Stream) {", S); Emit_Newline (S);
      Append ("            ALB_File_Table[slot].Stream = fp;", S); Emit_Newline (S);
      Append ("            return (uint64_t)slot;", S); Emit_Newline (S);
      Append ("        }", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("    fclose(fp);", S); Emit_Newline (S);
      Append ("    return 0;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_File_Read(uint64_t handle, uint64_t bytes) {", S); Emit_Newline (S);
      Append ("    FILE* fp = ALB_File_From_Handle(handle);", S); Emit_Newline (S);
      Append ("    return (uint64_t)(uintptr_t)ALB_File_Read_Stream(fp, bytes);", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("static void ALB_File_Write(uint64_t data, uint64_t handle) {", S); Emit_Newline (S);
      Append ("    FILE* fp = ALB_File_From_Handle(handle);", S); Emit_Newline (S);
      Append ("    if (!fp || ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline (S);
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline (S);
      Append ("    if (data > 0x10000 && !IsBadStringPtrA((LPCSTR)(uintptr_t)data, 8192)) {", S); Emit_Newline (S);
      Append ("        fputs((const char*)(uintptr_t)data, fp); return;", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("#elif defined(ALB_PLAT_POSIX)", S); Emit_Newline (S);
      Append ("    if (ALB_Is_Valid_Ptr(data)) {", S); Emit_Newline (S);
      Append ("        fputs((const char*)(uintptr_t)data, fp); return;", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("    fprintf(fp, ALB_S64_FMT, (int64_t)data);", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("static void ALB_File_Close(uint64_t handle) {", S); Emit_Newline (S);
      Append ("    FILE* fp;", S); Emit_Newline (S);
      Append ("    if (handle == 0 || handle >= ALB_MAX_OPEN_FILES) return;", S); Emit_Newline (S);
      Append ("    fp = ALB_File_Table[(size_t)handle].Stream;", S); Emit_Newline (S);
      Append ("    if (!fp) return;", S); Emit_Newline (S);
      Append ("    fclose(fp);", S); Emit_Newline (S);
      Append ("    ALB_File_Table[(size_t)handle].Stream = (FILE*)0;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_File_Len(uint64_t path_u) {", S); Emit_Newline (S);
      Append ("    const char* path = (const char*)(uintptr_t)path_u;", S); Emit_Newline (S);
      Append ("    FILE* fp;", S); Emit_Newline (S);
      Append ("    uint64_t sz = 0;", S); Emit_Newline (S);
      Append ("    if (!path) return 0;", S); Emit_Newline (S);
      Append ("    fp = fopen(path, ""rb"");", S); Emit_Newline (S);
      Append ("    if (!fp) return 0;", S); Emit_Newline (S);
      Append ("#if defined(_WIN32)", S); Emit_Newline (S);
      Append ("    if (_fseeki64(fp, 0, SEEK_END) == 0) sz = (uint64_t)_ftelli64(fp);", S); Emit_Newline (S);
      Append ("#else", S); Emit_Newline (S);
      Append ("    if (fseeko(fp, 0, SEEK_END) == 0) sz = (uint64_t)ftello(fp);", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("    fclose(fp);", S); Emit_Newline (S);
      Append ("    return sz;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_File_Seek(uint64_t handle, uint64_t offset) {", S); Emit_Newline (S);
      Append ("    FILE* fp = ALB_File_From_Handle(handle);", S); Emit_Newline (S);
      Append ("    if (!fp) return 0;", S); Emit_Newline (S);
      Append ("#if defined(_WIN32)", S); Emit_Newline (S);
      Append ("    if (_fseeki64(fp, (int64_t)offset, SEEK_SET) != 0) return 0;", S); Emit_Newline (S);
      Append ("    return (uint64_t)_ftelli64(fp);", S); Emit_Newline (S);
      Append ("#else", S); Emit_Newline (S);
      Append ("    if (fseeko(fp, (off_t)offset, SEEK_SET) != 0) return 0;", S); Emit_Newline (S);
      Append ("    return (uint64_t)ftello(fp);", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      if Code_Vault.Secure_Mode then
         Append ("/* --- THE CODE VAULT POLYMORPHIC VM --- */", S); Emit_Newline (S);
         Append ("static uint64_t _ALB_Sum_V(const uint64_t* w, int c) {", S); Emit_Newline (S);
         Append ("    static uint64_t vault_drift = 0;", S); Emit_Newline (S);
         Append ("    uint64_t t1 = __rdtsc();", S); Emit_Newline (S);
         Append ("    uint64_t res = 0;", S); Emit_Newline (S);
         Append ("    static const uint8_t ALB_SBOX[256] = {", S); Emit_Newline (S);
         Append ("        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,", S); Emit_Newline (S);
         Append ("        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,", S); Emit_Newline (S);
         Append ("        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,", S); Emit_Newline (S);
         Append ("        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,", S); Emit_Newline (S);
         Append ("        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,", S); Emit_Newline (S);
         Append ("        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,", S); Emit_Newline (S);
         Append ("        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,", S); Emit_Newline (S);
         Append ("        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,", S); Emit_Newline (S);
         Append ("        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,", S); Emit_Newline (S);
         Append ("        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,", S); Emit_Newline (S);
         Append ("        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,", S); Emit_Newline (S);
         Append ("        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,", S); Emit_Newline (S);
         Append ("        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,", S); Emit_Newline (S);
         Append ("        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,", S); Emit_Newline (S);
         Append ("        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,", S); Emit_Newline (S);
         Append ("        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16", S); Emit_Newline (S);
         Append ("    };", S); Emit_Newline (S);
         Append ("    int i;", S); Emit_Newline (S);
         Append ("    for (i = 0; i < c; i++) {", S); Emit_Newline (S);
         Append ("        uint64_t op = w[i] & ALB_U64_CONST(0xFF000000, 0x00000000);", S); Emit_Newline (S);
         Append ("        uint64_t val = w[i] & ALB_U64_CONST(0x00FFFFFF, 0xFFFFFFFF);", S); Emit_Newline (S);
         Append ("        switch(op) {", S); Emit_Newline (S);
         Append ("            case ALB_U64_CONST(0xA1000000, 0x00000000): res += (uint64_t)(((int64_t)((val ^ (uint64_t)(((i + 1) * 0x31337) % 0xFFFF)) << 8)) >> 8); break;", S); Emit_Newline (S);
         -- DA FIX: Mask XOR result to 56 bits to prevent high-bit corruption from the 0x55AA mask
         Append ("            case ALB_U64_CONST(0xB2000000, 0x00000000): res += (val ^ ALB_U64_CONST(0x55AA55AA, 0x55AA55AA)) & ALB_U64_CONST(0x00FFFFFF, 0xFFFFFFFF); break;", S); Emit_Newline (S);
         Append ("            case ALB_U64_CONST(0xC3000000, 0x00000000): res ^= (val << (i % 8)) & ALB_U64_CONST(0x00FFFFFF, 0xFFFFFFFF); break;", S); Emit_Newline (S);
         Append ("            case ALB_U64_CONST(0xD4000000, 0x00000000): res += ALB_SBOX[val & 0xFF]; break;", S); Emit_Newline (S);
         Append ("            case ALB_U64_CONST(0xE5000000, 0x00000000): res += (uint64_t)sqrt((double)val * (double)val) & ALB_U64_CONST(0x00FFFFFF, 0xFFFFFFFF); break;", S); Emit_Newline (S);
         Append ("            default: res += val & ALB_U64_CONST(0x00FFFFFF, 0xFFFFFFFF); break;", S); Emit_Newline (S);
         Append ("        }", S); Emit_Newline (S);
         Append ("    }", S); Emit_Newline (S);
         Append ("    uint64_t t2 = __rdtsc();", S); Emit_Newline (S);
         Append ("    if ((t2 - t1) > 1000000) { vault_drift += 0xDEADBEEF; }", S); Emit_Newline (S);
         Append ("    return res ^ vault_drift;", S); Emit_Newline (S);
         Append ("}", S); Emit_Newline (S);
         Append ("#define ALB_V(...) _ALB_Sum_V((uint64_t[]){__VA_ARGS__}, sizeof((uint64_t[]){__VA_ARGS__})/8)", S); Emit_Newline (S);
      end if;
      
      -- PASTE THIS RIGHT BEFORE `Success := S;` IN Emit_Core_Routines:
      Append ("/* --- DA CORE ENGINE STATE & TRUE CONSOLE ORACLE --- */", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Current_Color = 0;", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Clear_Color = 0;", S); Emit_Newline(S);
      Append ("static void ALB_Set_Clear_Color(uint64_t color) { if (ALB_TEMP_Future_Suppress_IO) return; ALB_Clear_Color = color; }", S); Emit_Newline(S);

      -- DA TRUE ANSI COLOR SETTER (24-bit True Color!)
      Append ("static void ALB_Set_Color(uint64_t color) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Current_Color = color;", S); Emit_Newline(S);
      Append ("    /* Track 3 (C): Set_Color used to unconditionally print an", S); Emit_Newline(S);
      Append ("       ANSI escape code, which flooded stdout with megabytes", S); Emit_Newline(S);
      Append ("       of escape sequences inside ON PAINT loops.  Define", S); Emit_Newline(S);
      Append ("       ALB_CONSOLE_TILE_ANSI at compile time to re-enable it", S); Emit_Newline(S);
      Append ("       for retro tile-mode rendering. */", S); Emit_Newline(S);
      Append ("#ifdef ALB_CONSOLE_TILE_ANSI", S); Emit_Newline(S);
      Append ("    printf(""\033[38;2;%d;%d;%dm"", (int)((color >> 16) & 0xFF), (int)((color >> 8) & 0xFF), (int)(color & 0xFF));", S); Emit_Newline(S);
      Append ("#endif", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);
      
      Append ("static uint64_t ALB_Console_Width(void) { return (uint64_t)80; }", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Console_Height(void) { return (uint64_t)25; }", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Poll_Event(void) { return ALB_U64_ZERO; }", S); Emit_Newline(S);

      -- DA TRUE ANSI LOCATE (Y;X 1-based indexing)
      Append ("static void ALB_Locate(uint64_t x, uint64_t y) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    printf(""\033[%d;%dH"", (int)y, (int)x);", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      -- DA TRUE ANSI CLEAR SCREEN (Clears terminal and homes cursor)
      Append ("static void ALB_Clear_Console(void) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    printf(""\033[2J\033[1;1H"");", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      
      -- DA NATIVE AUDIO PASSTHROUGH
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline(S);
      Append ("static void ALB_Play_Sound(uint64_t path_ptr, uint64_t loop) { if (ALB_TEMP_Future_Suppress_IO) return; PlaySoundA((char*)(uintptr_t)path_ptr, NULL, SND_ASYNC | SND_FILENAME); (void)loop; }", S); Emit_Newline(S);
      Append ("#else", S); Emit_Newline(S);
      Append ("static void ALB_Play_Sound(uint64_t path_ptr, uint64_t loop) { (void)path_ptr; (void)loop; }", S); Emit_Newline(S);
      Append ("#endif", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("static int ALB_Mml_Number(const char* text, int* pos, int fallback) {", S); Emit_Newline(S);
      Append ("    int value = 0;", S); Emit_Newline(S);
      Append ("    int any = 0;", S); Emit_Newline(S);
      Append ("    while (text[*pos] >= '0' && text[*pos] <= '9') {", S); Emit_Newline(S);
      Append ("        any = 1;", S); Emit_Newline(S);
      Append ("        value = (value * 10) + (text[*pos] - '0');", S); Emit_Newline(S);
      Append ("        *pos = *pos + 1;", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("    return any ? value : fallback;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static int ALB_Mml_Semitone(int ch) {", S); Emit_Newline(S);
      Append ("    switch (ch) {", S); Emit_Newline(S);
      Append ("        case 'C': return 0;", S); Emit_Newline(S);
      Append ("        case 'D': return 2;", S); Emit_Newline(S);
      Append ("        case 'E': return 4;", S); Emit_Newline(S);
      Append ("        case 'F': return 5;", S); Emit_Newline(S);
      Append ("        case 'G': return 7;", S); Emit_Newline(S);
      Append ("        case 'A': return 9;", S); Emit_Newline(S);
      Append ("        case 'B': return 11;", S); Emit_Newline(S);
      Append ("        default: return -1;", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Play_Music(uint64_t music_ptr) {", S); Emit_Newline(S);
      Append ("    const char* music = (const char*)(uintptr_t)music_ptr;", S); Emit_Newline(S);
      Append ("    int pos = 0;", S); Emit_Newline(S);
      Append ("    int tempo = 120;", S); Emit_Newline(S);
      Append ("    int octave = 4;", S); Emit_Newline(S);
      Append ("    int def_len = 4;", S); Emit_Newline(S);
      Append ("    int semi = -1;", S); Emit_Newline(S);
      Append ("    int len = 0;", S); Emit_Newline(S);
      Append ("    int ms = 0;", S); Emit_Newline(S);
      Append ("    int midi = 0;", S); Emit_Newline(S);
      Append ("    int acc = 0;", S); Emit_Newline(S);
      Append ("    int ch = 0;", S); Emit_Newline(S);
      Append ("    double hz = 0.0;", S); Emit_Newline(S);
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline(S);
      Append ("    DWORD freq = 0;", S); Emit_Newline(S);
      Append ("#endif", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) { return; }", S); Emit_Newline(S);
      Append ("    if (!music) { return; }", S); Emit_Newline(S);
      Append ("    while (music[pos] != '\0') {", S); Emit_Newline(S);
      Append ("        ch = (unsigned char)music[pos];", S); Emit_Newline(S);
      Append ("        if (ch >= 'a' && ch <= 'z') { ch = ch - 'a' + 'A'; }", S); Emit_Newline(S);
      Append ("        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == ',') {", S); Emit_Newline(S);
      Append ("            pos = pos + 1;", S); Emit_Newline(S);
      Append ("        } else if (ch == 'T') {", S); Emit_Newline(S);
      Append ("            pos = pos + 1;", S); Emit_Newline(S);
      Append ("            tempo = ALB_Mml_Number(music, &pos, tempo);", S); Emit_Newline(S);
      Append ("            if (tempo <= 0) { tempo = 120; }", S); Emit_Newline(S);
      Append ("        } else if (ch == 'O') {", S); Emit_Newline(S);
      Append ("            pos = pos + 1;", S); Emit_Newline(S);
      Append ("            octave = ALB_Mml_Number(music, &pos, octave);", S); Emit_Newline(S);
      Append ("            if (octave < 0) { octave = 0; }", S); Emit_Newline(S);
      Append ("            if (octave > 8) { octave = 8; }", S); Emit_Newline(S);
      Append ("        } else if (ch == 'L') {", S); Emit_Newline(S);
      Append ("            pos = pos + 1;", S); Emit_Newline(S);
      Append ("            def_len = ALB_Mml_Number(music, &pos, def_len);", S); Emit_Newline(S);
      Append ("            if (def_len <= 0) { def_len = 4; }", S); Emit_Newline(S);
      Append ("        } else if (ch == '>') {", S); Emit_Newline(S);
      Append ("            if (octave < 8) { octave = octave + 1; }", S); Emit_Newline(S);
      Append ("            pos = pos + 1;", S); Emit_Newline(S);
      Append ("        } else if (ch == '<') {", S); Emit_Newline(S);
      Append ("            if (octave > 0) { octave = octave - 1; }", S); Emit_Newline(S);
      Append ("            pos = pos + 1;", S); Emit_Newline(S);
      Append ("        } else {", S); Emit_Newline(S);
      Append ("            semi = ALB_Mml_Semitone(ch);", S); Emit_Newline(S);
      Append ("            if (semi >= 0 || ch == 'R' || ch == 'P') {", S); Emit_Newline(S);
      Append ("                pos = pos + 1;", S); Emit_Newline(S);
      Append ("                if (semi >= 0) {", S); Emit_Newline(S);
      Append ("                    acc = (unsigned char)music[pos];", S); Emit_Newline(S);
      Append ("                    if (acc == '#' || acc == '+') { semi = semi + 1; pos = pos + 1; }", S); Emit_Newline(S);
      Append ("                    else if (acc == '-') { semi = semi - 1; pos = pos + 1; }", S); Emit_Newline(S);
      Append ("                }", S); Emit_Newline(S);
      Append ("                len = ALB_Mml_Number(music, &pos, def_len);", S); Emit_Newline(S);
      Append ("                if (len <= 0) { len = def_len; }", S); Emit_Newline(S);
      Append ("                if (len <= 0) { len = 4; }", S); Emit_Newline(S);
      Append ("                if (tempo <= 0) { tempo = 120; }", S); Emit_Newline(S);
      Append ("                ms = 240000 / tempo;", S); Emit_Newline(S);
      Append ("                ms = ms / len;", S); Emit_Newline(S);
      Append ("                if (ms < 1) { ms = 1; }", S); Emit_Newline(S);
      Append ("                if (semi >= 0) {", S); Emit_Newline(S);
      Append ("                    midi = (octave + 1) * 12 + semi;", S); Emit_Newline(S);
      Append ("                    hz = 440.0 * pow(2.0, ((double)midi - 69.0) / 12.0);", S); Emit_Newline(S);
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline(S);
      Append ("                    if (hz < 37.0) { hz = 37.0; }", S); Emit_Newline(S);
      Append ("                    if (hz > 32767.0) { hz = 32767.0; }", S); Emit_Newline(S);
      Append ("                    freq = (DWORD)(hz + 0.5);", S); Emit_Newline(S);
      Append ("                    Beep(freq, (DWORD)ms);", S); Emit_Newline(S);
      Append ("#else", S); Emit_Newline(S);
      Append ("                    ALB_Delay((uint64_t)ms);", S); Emit_Newline(S);
      Append ("#endif", S); Emit_Newline(S);
      Append ("                } else {", S); Emit_Newline(S);
      Append ("                    ALB_Delay((uint64_t)ms);", S); Emit_Newline(S);
      Append ("                }", S); Emit_Newline(S);
      Append ("            } else {", S); Emit_Newline(S);
      Append ("                pos = pos + 1;", S); Emit_Newline(S);
      Append ("            }", S); Emit_Newline(S);
      Append ("        }", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Success := S;
   end Emit_Core_Routines;
   
   procedure Emit_Media_Bindings (Success : out Boolean) is
      S : Boolean := True;
      procedure Add_Decl (Text : String) is
      begin
         if S then
            Append_Declaration_Text (Text & ASCII.LF, S);
         end if;
      end Add_Decl;
    begin
      Append ("/* --- THE SDL3 MASTER INCLUDE --- */", S); Emit_Newline (S);
      Append ("#include <SDL3/SDL.h>", S); Emit_Newline (S);
      
      Append ("/* --- NATIVE FORGE MEDIA BINDINGS (SDL3) --- */", S); Emit_Newline(S);
      Append ("static uint8_t ALB_Render_Target = 1; /* 1 = SDL3 GUI */", S); Emit_Newline(S);
      --Append ("static uint64_t ALB_Current_Color = 0;", S); Emit_Newline(S);
      --Append ("static uint64_t ALB_Clear_Color = 0;", S); Emit_Newline(S);
      --Append ("static void ALB_Set_Clear_Color(uint64_t color) { ALB_Clear_Color = color; }", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Scale_Mode = 0; /* 0 = Dynamic Bounds, 1 = Retro Stretch */", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Window_Resizable = 0;", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Window_Fullscreen = 0;", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("/* --- DA MASTER SDL3 GLOBALS --- */", S); Emit_Newline(S);
      Append ("static SDL_Window* ALB_Window = NULL;", S); Emit_Newline(S);
      Append ("static SDL_Renderer* ALB_Renderer = NULL;", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("static uint64_t ALB_Key_Map[256] = {0};", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Key_State(uint64_t key) { return (key < 256) ? ALB_Key_Map[key] : ALB_U64_ZERO; }", S); Emit_Newline(S);
      Emit_Newline (S);

      Add_Decl ("static uint64_t ALB_Key_State(uint64_t key);");
      Add_Decl ("static uint64_t ALB_Screen_Width;");
      Add_Decl ("static uint64_t ALB_Screen_Height;");
      Add_Decl ("static uint64_t ALB_Virtual_Width;");
      Add_Decl ("static uint64_t ALB_Virtual_Height;");
      Add_Decl ("static uint64_t ALB_Mouse_X;");
      Add_Decl ("static uint64_t ALB_Mouse_Y;");
      Add_Decl ("static int64_t ALB_Mouse_Wheel;");
      Add_Decl ("static uint64_t ALB_VMouse_X;");
      Add_Decl ("static uint64_t ALB_VMouse_Y;");
      Add_Decl ("static uint64_t ALB_Mouse_Btn;");
      Add_Decl ("static uint64_t ALB_Mouse_Click_State(uint64_t btn);");
      Add_Decl ("static uint64_t ALB_Read_Pixel(uint64_t x, uint64_t y);");
      Add_Decl ("static void ALB_Apply_Color(void);");
      Add_Decl ("static void ALB_Fill_Rect(uint64_t x, uint64_t y, uint64_t w, uint64_t h);");
      Add_Decl ("static void ALB_Draw_Rect(uint64_t x, uint64_t y, uint64_t w, uint64_t h);");
      Add_Decl ("static void ALB_Draw_Line(uint64_t x1, uint64_t y1, uint64_t x2, uint64_t y2);");
      Add_Decl ("static void ALB_Draw_Circle(uint64_t xc_in, uint64_t yc_in, uint64_t r_in);");
      Add_Decl ("static void ALB_Fill_Circle(uint64_t xc_in, uint64_t yc_in, uint64_t r_in);");
      Add_Decl ("static void ALB_Put_Pixel(uint64_t x, uint64_t y);");
      Add_Decl ("static void ALB_Draw_Text(uint64_t x, uint64_t y, uint64_t text_ptr);");
      Add_Decl ("static void ALB_Set_Fullscreen(uint64_t value);");
      Add_Decl ("static void ALB_Set_Resizable(uint64_t value);");
      Add_Decl ("static void ALB_Set_Stretchy(uint64_t value);");
      Add_Decl ("static void ALB_Set_Alpha(uint64_t mode, uint64_t value);");
      Add_Decl ("static uint64_t ALB_Collide_Rect(uint64_t x1, uint64_t y1, uint64_t w1, uint64_t h1, uint64_t x2, uint64_t y2, uint64_t w2, uint64_t h2);");

      Append ("/* --- DA COLLISION FORGE --- */", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Collide_Rect(uint64_t x1, uint64_t y1, uint64_t w1, uint64_t h1, uint64_t x2, uint64_t y2, uint64_t w2, uint64_t h2) {", S); Emit_Newline(S);
      Append ("    if (x1 < (x2 + w2) && (x1 + w1) > x2 && y1 < (y2 + h2) && (y1 + h1) > y2) return ALB_U64_ONE;", S); Emit_Newline(S);
      Append ("    return ALB_U64_ZERO;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      Emit_Newline (S);

      Append ("/* --- DA ENVIRONMENTAL ORACLE (Virtual Bounds & Scaled Mouse) --- */", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Screen_Width = 0; static uint64_t ALB_Screen_Height = 0;", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Virtual_Width = 0; static uint64_t ALB_Virtual_Height = 0;", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Mouse_X = 0; static uint64_t ALB_Mouse_Y = 0; static int64_t ALB_Mouse_Wheel = 0; static uint64_t ALB_Mouse_Btn = 0;", S); Emit_Newline (S);
      Append ("static uint64_t ALB_VMouse_X = 0; static uint64_t ALB_VMouse_Y = 0;", S); Emit_Newline(S);
      Append ("static uint64_t ALB_Mouse_Click_State(uint64_t btn) { uint64_t bit = btn; if (btn == 1) { bit = 2; } else if (btn == 2) { bit = 1; } return (ALB_Mouse_Btn & (ALB_U64_ONE << bit)) ? ALB_U64_ONE : ALB_U64_ZERO; }", S); Emit_Newline (S);
      Emit_Newline (S);

      --  Append ("/* --- DA STUBS FOR CONSOLE COMPATIBILITY --- */", S); Emit_Newline(S);
      --  Append ("static uint64_t ALB_Console_Width(void) { return 80ULL; }", S); Emit_Newline(S);
      --  Append ("static uint64_t ALB_Console_Height(void) { return 25ULL; }", S); Emit_Newline(S);
      --  Append ("static uint64_t ALB_Poll_Event(void) { return 0ULL; }", S); Emit_Newline(S);
      --  Append ("static void ALB_Locate(uint64_t x, uint64_t y) { (void)x; (void)y; }", S); Emit_Newline(S);
      --  Append ("static void ALB_Clear_Console(void) { }", S); Emit_Newline(S);
      --  Append ("static void ALB_Set_Color(uint64_t color) { ALB_Current_Color = color; }", S); Emit_Newline(S);
      --  Append ("static void ALB_Play_Sound(uint64_t path_ptr, uint64_t loop) { /* TODO: SDL3 Audio */ (void)path_ptr; (void)loop; }", S); Emit_Newline(S);

      Success := S;
   end Emit_Media_Bindings;
   
   -- =========================================================================
   -- HELPER: CONCURRENCY & LOGIC FORGE
   -- =========================================================================
   procedure Emit_Concurrency_And_Logic (Success : out Boolean) is
      S : Boolean := True;
   begin
      Append ("/* --- THE KNOWLEDGE BASE (Prolog/Datalog Engine) --- */", S); Emit_Newline (S);
      Append ("typedef struct { uint64_t hash; uint64_t arg_hash; uint64_t val; uint8_t active; } ALB_Fact;", S); Emit_Newline (S);
      Append ("static ALB_Fact ALB_KB[1024] = {0};", S); Emit_Newline (S);
      
      Append ("static uint64_t ALB_Hash(const char* str) {", S); Emit_Newline (S);
      Append ("    uint64_t h = 5381; while (*str) { h = (h * 33) + (uint8_t)*str++; } return h;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      -- Full KB Functions
      Append ("typedef uint64_t (*ALB_Event_Hook)(void);", S); Emit_Newline (S);
      Append ("static ALB_Event_Hook ALB_Change_Hooks[1024] = {0};", S); Emit_Newline (S);
      Append ("static uint64_t ALB_Change_Hashes[1024] = {0};", S); Emit_Newline (S);
      Append ("static int ALB_Hook_Count = 0;", S); Emit_Newline (S);

      Append ("void ALB_Register_Hook(const char* pred, ALB_Event_Hook hook) {", S); Emit_Newline (S);
      Append ("    ALB_Change_Hashes[ALB_Hook_Count] = ALB_Hash(pred);", S); Emit_Newline (S);
      Append ("    ALB_Change_Hooks[ALB_Hook_Count] = hook;", S); Emit_Newline (S);
      Append ("    ALB_Hook_Count++;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Assert(const char* pred, uint64_t arg_hash, uint64_t val) {", S); Emit_Newline (S);
      Append ("    uint64_t h = ALB_Hash(pred);", S); Emit_Newline (S);
      Append ("    int i; for (i = 0; i < 1024; i++) { if (!ALB_KB[i].active || (ALB_KB[i].hash == h && ALB_KB[i].arg_hash == arg_hash)) {", S); Emit_Newline (S);
      Append ("        ALB_KB[i].hash = h; ALB_KB[i].arg_hash = arg_hash; ALB_KB[i].val = val; ALB_KB[i].active = 1; return; }", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Retract(const char* pred, uint64_t arg_hash) {", S); Emit_Newline (S);
      Append ("    uint64_t h = ALB_Hash(pred);", S); Emit_Newline (S);
      Append ("    int i; for (i = 0; i < 1024; i++) { if (ALB_KB[i].active && ALB_KB[i].hash == h && ALB_KB[i].arg_hash == arg_hash) ALB_KB[i].active = 0; }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("uint64_t ALB_Query(const char* pred, uint64_t arg_hash) {", S); Emit_Newline (S);
      Append ("    uint64_t h = ALB_Hash(pred);", S); Emit_Newline (S);
      Append ("    int i; for (i = 0; i < 1024; i++) { if (ALB_KB[i].active && ALB_KB[i].hash == h && (ALB_KB[i].arg_hash == arg_hash || ALB_KB[i].val == arg_hash)) return ALB_U64_ONE; }", S); Emit_Newline (S);
      Append ("    return ALB_U64_ZERO;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("uint64_t ALB_Find(const char* pred) {", S); Emit_Newline (S);
      Append ("    uint64_t h = ALB_Hash(pred);", S); Emit_Newline (S);
      Append ("    int i; for (i = 0; i < 1024; i++) { if (ALB_KB[i].active && ALB_KB[i].hash == h) return (ALB_KB[i].val != 0) ? ALB_KB[i].val : ALB_KB[i].arg_hash; }", S); Emit_Newline (S);
      Append ("    return ALB_U64_ZERO;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Update(const char* pred, uint64_t old_arg, uint64_t new_arg) {", S); Emit_Newline (S);
      Append ("    uint64_t h = ALB_Hash(pred);", S); Emit_Newline (S);
      Append ("    int i; int j; for (i = 0; i < 1024; i++) { if (ALB_KB[i].active && ALB_KB[i].hash == h) {", S); Emit_Newline (S);
      Append ("        if (ALB_KB[i].arg_hash == old_arg) { ALB_KB[i].arg_hash = new_arg; }", S); Emit_Newline (S);
      Append ("        else if (ALB_KB[i].val == old_arg) { ALB_KB[i].val = new_arg; }", S); Emit_Newline (S);
      Append ("        else { continue; } /* Nae match! Skip loop. */", S); Emit_Newline (S);
      Append ("        for (j = 0; j < ALB_Hook_Count; j++) { if (ALB_Change_Hashes[j] == h) ALB_Change_Hooks[j](); }", S); Emit_Newline (S);
      Append ("    } }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_FindAll(const char* pred, uint64_t* out_arr) {", S); Emit_Newline (S);
      Append ("    uint64_t h = ALB_Hash(pred); int count = 0; int i;", S); Emit_Newline (S);
      Append ("    for (i = 0; i < 1024; i++) { if (ALB_KB[i].active && ALB_KB[i].hash == h) { out_arr[count++] = ALB_KB[i].arg_hash; } }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      
      Emit_Newline (S);
      Append ("/* --- NATIVE FORGE THREAD POOL --- */", S); Emit_Newline (S);
      Append ("typedef uint64_t (*ALB_Task_Func)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);", S); Emit_Newline (S);
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline(S);
      Append ("#define ALB_MAX_TASKS 256", S); Emit_Newline (S);
      Append ("#define ALB_NUM_CORES 8", S); Emit_Newline (S);
      Append ("typedef struct { ALB_Task_Func func; uint64_t args[8]; } ALB_Task;", S); Emit_Newline (S);
      
      -- Full Threading Implementation
      Append ("static ALB_Task ALB_Task_Queue[ALB_MAX_TASKS] = {0};", S); Emit_Newline (S);
      Append ("static volatile LONG ALB_Task_Head = 0;", S); Emit_Newline (S);
      Append ("static volatile LONG ALB_Task_Tail = 0;", S); Emit_Newline (S);
      Append ("static volatile LONG ALB_Active_Tasks = 0;", S); Emit_Newline (S);
      Append ("static volatile LONG ALB_Atomic_Mutex = 0;", S); Emit_Newline (S);
      Append ("static HANDLE ALB_Task_Sem = NULL;", S); Emit_Newline (S);

      Append ("void ALB_Atomic_Lock(void) { while (InterlockedCompareExchange((LPLONG)&ALB_Atomic_Mutex, 1, 0) != 0) { Sleep(0); } }", S); Emit_Newline (S);
      Append ("void ALB_Atomic_Unlock(void) { InterlockedExchange((LPLONG)&ALB_Atomic_Mutex, 0); }", S); Emit_Newline (S);

      Append ("DWORD WINAPI ALB_Worker_Thread(LPVOID lpParam) {", S); Emit_Newline (S);
      Append ("    LONG tail;", S); Emit_Newline (S);
      Append ("    ALB_Task t;", S); Emit_Newline (S);
      Append ("    (void)lpParam;", S); Emit_Newline (S);
      Append ("    while (1) {", S); Emit_Newline (S);
      Append ("        WaitForSingleObject(ALB_Task_Sem, INFINITE);", S); Emit_Newline (S);
      Append ("        tail = ALB_Task_Tail;", S); Emit_Newline (S);
      Append ("        while (tail < ALB_Task_Head) {", S); Emit_Newline (S);
      Append ("            if (InterlockedCompareExchange((LPLONG)&ALB_Task_Tail, tail + 1, tail) == tail) {", S); Emit_Newline (S);
      Append ("                t = ALB_Task_Queue[tail % ALB_MAX_TASKS];", S); Emit_Newline (S);
      Append ("                if (t.func) t.func(t.args[0], t.args[1], t.args[2], t.args[3], t.args[4], t.args[5], t.args[6], t.args[7]);", S); Emit_Newline (S);
      Append ("                InterlockedDecrement((LPLONG)&ALB_Active_Tasks);", S); Emit_Newline (S);
      Append ("                break;", S); Emit_Newline (S);
      Append ("            }", S); Emit_Newline (S);
      Append ("            tail = ALB_Task_Tail;", S); Emit_Newline (S);
      Append ("        }", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("    return 0;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Init_Threads(void) {", S); Emit_Newline (S);
      Append ("    int i;", S); Emit_Newline (S);
      Append ("    ALB_Task_Sem = CreateSemaphoreA(NULL, 0, ALB_MAX_TASKS, NULL);", S); Emit_Newline (S);
      Append ("    for (i = 0; i < ALB_NUM_CORES; i++) { CreateThread(NULL, 0, ALB_Worker_Thread, NULL, 0, NULL); }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Dispatch_Task(ALB_Task_Func func, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {", S); Emit_Newline (S);
      Append ("    LONG head;", S); Emit_Newline (S);
      Append ("    head = InterlockedIncrement((LPLONG)&ALB_Task_Head) - 1;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].func = func;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[0] = a0;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[1] = a1;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[2] = a2;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[3] = a3;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[4] = a4;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[5] = a5;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[6] = a6;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[7] = a7;", S); Emit_Newline (S);
      Append ("    InterlockedIncrement((LPLONG)&ALB_Active_Tasks);", S); Emit_Newline (S);
      Append ("    ReleaseSemaphore(ALB_Task_Sem, 1, NULL);", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Sync_Tasks(void) {", S); Emit_Newline (S);
      Append ("    while (ALB_Active_Tasks > 0) { Sleep(0); }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      
      Append ("#else", S); Emit_Newline(S);
      -- DA POSIX THREAD POOL FORGE
      Append ("#define ALB_MAX_TASKS 256", S); Emit_Newline (S);
      Append ("#define ALB_NUM_CORES 8", S); Emit_Newline (S);
      Append ("typedef struct { ALB_Task_Func func; uint64_t args[8]; } ALB_Task;", S); Emit_Newline (S);
      
      Append ("static ALB_Task ALB_Task_Queue[ALB_MAX_TASKS] = {0};", S); Emit_Newline (S);
      Append ("static volatile long ALB_Task_Head = 0;", S); Emit_Newline (S);
      Append ("static volatile long ALB_Task_Tail = 0;", S); Emit_Newline (S);
      Append ("static volatile long ALB_Active_Tasks = 0;", S); Emit_Newline (S);
      Append ("static sem_t ALB_Task_Sem;", S); Emit_Newline (S);
      Append ("static pthread_mutex_t ALB_Task_Mutex = PTHREAD_MUTEX_INITIALIZER;", S); Emit_Newline (S);
      Append ("static pthread_mutex_t ALB_Atomic_Mutex = PTHREAD_MUTEX_INITIALIZER;", S); Emit_Newline (S);

      Append ("void ALB_Atomic_Lock(void) { pthread_mutex_lock(&ALB_Atomic_Mutex); }", S); Emit_Newline (S);
      Append ("void ALB_Atomic_Unlock(void) { pthread_mutex_unlock(&ALB_Atomic_Mutex); }", S); Emit_Newline (S);

      Append ("void* ALB_Worker_Thread(void* arg) {", S); Emit_Newline (S);
      Append ("    long tail;", S); Emit_Newline (S);
      Append ("    long slot;", S); Emit_Newline (S);
      Append ("    ALB_Task t;", S); Emit_Newline (S);
      Append ("    (void)arg;", S); Emit_Newline (S);
      Append ("    while (1) {", S); Emit_Newline (S);
      Append ("        sem_wait(&ALB_Task_Sem);", S); Emit_Newline (S);
      Append ("        pthread_mutex_lock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("        tail = ALB_Task_Tail;", S); Emit_Newline (S);
      Append ("        if (tail >= ALB_Task_Head) {", S); Emit_Newline (S);
      Append ("            pthread_mutex_unlock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("            continue;", S); Emit_Newline (S);
      Append ("        }", S); Emit_Newline (S);
      Append ("        slot = tail % ALB_MAX_TASKS;", S); Emit_Newline (S);
      Append ("        ALB_Task_Tail = tail + 1;", S); Emit_Newline (S);
      Append ("        t = ALB_Task_Queue[slot];", S); Emit_Newline (S);
      Append ("        pthread_mutex_unlock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("        if (t.func) t.func(t.args[0], t.args[1], t.args[2], t.args[3], t.args[4], t.args[5], t.args[6], t.args[7]);", S); Emit_Newline (S);
      Append ("        pthread_mutex_lock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("        ALB_Active_Tasks = ALB_Active_Tasks - 1;", S); Emit_Newline (S);
      Append ("        pthread_mutex_unlock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("    return NULL;", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Init_Threads(void) {", S); Emit_Newline (S);
      Append ("    int i;", S); Emit_Newline (S);
      Append ("    pthread_t t;", S); Emit_Newline (S);
      Append ("    sem_init(&ALB_Task_Sem, 0, 0);", S); Emit_Newline (S);
      Append ("    for (i = 0; i < ALB_NUM_CORES; i++) { pthread_create(&t, NULL, ALB_Worker_Thread, NULL); pthread_detach(t); }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Dispatch_Task(ALB_Task_Func func, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {", S); Emit_Newline (S);
      Append ("    long head;", S); Emit_Newline (S);
      Append ("    pthread_mutex_lock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("    head = ALB_Task_Head;", S); Emit_Newline (S);
      Append ("    ALB_Task_Head = ALB_Task_Head + 1;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].func = func;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[0] = a0;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[1] = a1;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[2] = a2;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[3] = a3;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[4] = a4;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[5] = a5;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[6] = a6;", S); Emit_Newline (S);
      Append ("    ALB_Task_Queue[head % ALB_MAX_TASKS].args[7] = a7;", S); Emit_Newline (S);
      Append ("    ALB_Active_Tasks = ALB_Active_Tasks + 1;", S); Emit_Newline (S);
      Append ("    pthread_mutex_unlock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("    sem_post(&ALB_Task_Sem);", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);

      Append ("void ALB_Sync_Tasks(void) {", S); Emit_Newline (S);
      Append ("    long active;", S); Emit_Newline (S);
      Append ("    for (;;) {", S); Emit_Newline (S);
      Append ("        pthread_mutex_lock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("        active = ALB_Active_Tasks;", S); Emit_Newline (S);
      Append ("        pthread_mutex_unlock(&ALB_Task_Mutex);", S); Emit_Newline (S);
      Append ("        if (active <= 0) { break; }", S); Emit_Newline (S);
      Append ("        usleep(1000);", S); Emit_Newline (S);
      Append ("    }", S); Emit_Newline (S);
      Append ("}", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline(S);

      Success := S;
   end Emit_Concurrency_And_Logic;
   
   procedure Emit_Program_Start (Program_Name : String; Success : out Boolean) is
      S : Boolean := True;
   begin
      -- 1. Setup Global Vault
      Current_Buffer := Buffer_Global;
      Emit_Core_Boilerplate (S);
      if not S then Success := False; return; end if;

      Emit_Platform_HAL (S);
      if not S then Success := False; return; end if;

      Emit_Core_Routines (S);
      if not S then Success := False; return; end if;

      --Emit_Media_Bindings (S);
      --if not S then Success := False; return; end if;

      Emit_Concurrency_And_Logic (S);
      if not S then Success := False; return; end if;

      -- DA FIX: Capture the end of the headers sae we can inject forward declarations here!
      Headers_End_Idx := Global_Len;
      
      -- =========================================================================
      -- DA DUMPTRUCK (C RUNTIME INJECTION)
      -- =========================================================================
      Append ("/* =================================================== */", S); Emit_Newline(S);
      Append ("/* DA DUMPTRUCK (C RUNTIME MEMORY MANAGER) */", S); Emit_Newline(S);
      Append ("/* =================================================== */", S); Emit_Newline(S);
      Append ("#define ALB_GC_MAX_NODES 1024", S); Emit_Newline(S);
      Append ("typedef struct { uint8_t Alive; uint8_t Refs; uint64_t Child_1; uint64_t Child_2; } ALB_GC_Node;", S); Emit_Newline(S);
      Append ("ALB_GC_Node ALB_GC_Grid[ALB_GC_MAX_NODES + 1] = {0};", S); Emit_Newline(S);
      Append ("uint64_t ALB_GC_Cursor = 1;", S); Emit_Newline(S);
      
      Append ("void ALB_GC_Claim(uint64_t* ID) { uint64_t i; *ID = 1; for(i = 1; i <= ALB_GC_MAX_NODES; i++) { if(!ALB_GC_Grid[i].Alive) { ALB_GC_Grid[i].Alive = 1; ALB_GC_Grid[i].Refs = 1; ALB_GC_Grid[i].Child_1 = 0; ALB_GC_Grid[i].Child_2 = 0; *ID = i; return; } } }", S); Emit_Newline(S);
      Append ("void ALB_GC_Drop(uint64_t ID) { if(ID>=1 && ID<=ALB_GC_MAX_NODES && ALB_GC_Grid[ID].Alive && ALB_GC_Grid[ID].Refs>0) { ALB_GC_Grid[ID].Refs--; } }", S); Emit_Newline(S);
      Append ("void ALB_GC_Bind(uint64_t Parent, uint64_t C1, uint64_t C2) { if(Parent>=1 && Parent<=ALB_GC_MAX_NODES && ALB_GC_Grid[Parent].Alive) { ALB_GC_Grid[Parent].Child_1=C1; ALB_GC_Grid[Parent].Child_2=C2; } }", S); Emit_Newline(S);
      Append ("void ALB_GC_Sweep(uint64_t Chunk) { uint64_t Steps = (Chunk > ALB_GC_MAX_NODES) ? ALB_GC_MAX_NODES : Chunk; uint64_t i; for(i = 0; i < Steps; i++) { uint64_t C = ALB_GC_Cursor; if(ALB_GC_Grid[C].Alive && ALB_GC_Grid[C].Refs == 0) { uint64_t c1 = ALB_GC_Grid[C].Child_1; uint64_t c2 = ALB_GC_Grid[C].Child_2; ALB_GC_Grid[C].Alive = 0; if(c1 > 0 && ALB_GC_Grid[c1].Refs > 0) ALB_GC_Grid[c1].Refs--; if(c2 > 0 && ALB_GC_Grid[c2].Refs > 0) ALB_GC_Grid[c2].Refs--; } ALB_GC_Cursor++; if(ALB_GC_Cursor > ALB_GC_MAX_NODES) ALB_GC_Cursor = 1; } }", S); Emit_Newline(S);

      -- 2. Setup Main Vault (Execution Loop)
      Current_Buffer := Buffer_Main;
      Emit_Indent (S);
      Append ("int main(int argc, char** argv) {", S); Emit_Newline (S);
      In_Global_Scope := False;
      Increase_Indent;

      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("HANDLE hOut;", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("DWORD dwMode = 0;", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("(void)argc;", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("(void)argv;", S); Emit_Newline (S);
      
      Emit_Indent (S);
      Append ("ALB_Init_Threads(); /* Spark da forge! */", S); Emit_Newline (S);
      
      -- =========================================================================
      -- DA NEW VIRTUAL TERMINAL ORACLE (Fixes Wine/ANSI Bleeding)
      -- =========================================================================
      Append ("#if defined(ALB_PLAT_WIN)", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("hOut = GetStdHandle(STD_OUTPUT_HANDLE);", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("if (GetConsoleMode(hOut, &dwMode)) {", S); Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("SetConsoleMode(hOut, dwMode | 0x0004); /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */", S); Emit_Newline (S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline (S);
      Append ("#endif", S); Emit_Newline (S);
      
      Success := S;
   end Emit_Program_Start;

   procedure Emit_Program_End (Success : out Boolean) is
      S : Boolean;
   begin
      Current_Buffer := Buffer_Main;
      Emit_Indent (S);
      Append ("return 0;", S);
      Emit_Newline (S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Program_End;

   -- =========================================================================
   -- RAW TEXT FORMATTING
   -- =========================================================================
   procedure Emit_Raw (Text : String; Success : out Boolean) is
   begin
      Append (Text, Success);
   end Emit_Raw;

   procedure Emit_Native_C_Block
     (Block_Text : String;
      Success    : out Boolean)
   is
      S            : Boolean := True;
      Pos          : Integer := Block_Text'First;
      Line_Start   : Integer;
      Line_End     : Integer;
      First_Line   : Boolean := True;
      --  ENABLEC bodies are top-level C definitions (functions, includes,
      --  globals). They must land in Buffer_Global so IMPORT_C wrappers and
      --  ordinary ALB calls can link against them. Emitting into Buffer_Main
      --  nests them inside main() and produces undefined-reference link errors.
      Saved_Buffer : constant Buffer_Target := Current_Buffer;
      Saved_Scope  : constant Boolean := In_Global_Scope;
   begin
      Current_Buffer := Buffer_Global;
      In_Global_Scope := True;

      Append ("/* --- ALB NATIVE C BEGIN --- */", S);
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
               Line : constant String := Block_Text (Line_Start .. Line_End);
            begin
               exit when C_Block_Is_End_Enable_Line (Line);
               Append (Line, S);
               Emit_Newline (S);
            end;
         else
            Emit_Newline (S);
         end if;

         if Pos <= Block_Text'Last and then Block_Text (Pos) = ASCII.LF then
            Pos := Pos + 1;
         end if;
      end loop;

      Append ("/* --- ALB NATIVE C END --- */", S);
      Emit_Newline (S);

      Current_Buffer := Saved_Buffer;
      In_Global_Scope := Saved_Scope;
      Success := S;
   end Emit_Native_C_Block;

   procedure Emit_Native_C_Expression
     (Block_Text : String;
      Success    : out Boolean)
   is
      S          : Boolean := True;
      Pos        : Integer := Block_Text'First;
      Line_Start : Integer;
      Line_End   : Integer;
      First_Line : Boolean := True;
      Need_Space : Boolean := False;
   begin
      Append ("(", S);

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
               Line  : constant String := Block_Text (Line_Start .. Line_End);
               First : Integer := Line'First;
               Last  : Integer := Line'Last;
            begin
               exit when C_Block_Is_End_Enable_Line (Line);

               while First <= Last and then C_Block_Is_Space (Line (First)) loop
                  First := First + 1;
               end loop;

               while Last >= First and then C_Block_Is_Space (Line (Last)) loop
                  Last := Last - 1;
               end loop;

               if Last >= First then
                  if Need_Space then
                     Append (" ", S);
                  end if;

                  Append (Line (First .. Last), S);
                  Need_Space := True;
               end if;
            end;
         end if;

         if Pos <= Block_Text'Last and then Block_Text (Pos) = ASCII.LF then
            Pos := Pos + 1;
         end if;
      end loop;

      Append (")", S);
      Success := S;
   end Emit_Native_C_Expression;

   procedure Emit_Newline (Success : out Boolean) is
      LF : constant String := (1 => ASCII.LF);
   begin
      Append (LF, Success);
   end Emit_Newline;

   procedure Emit_Indent (Success : out Boolean) is
      S : Boolean := True;
   begin
      for I in 1 .. Indent_Level loop
         Append ("    ", S);
         if not S then
            exit;
         end if;
      end loop;
      Success := S;
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
   
   procedure Emit_FFI_Header_Include (Library_Name : String; Success : out Boolean) is
   begin
      Insert_Header_Text ("#include """ & Library_Name & """" & ASCII.LF, Success);
   end Emit_FFI_Header_Include;

   procedure Emit_FFI_Loader_Prelude (Success : out Boolean) is
      S : Boolean := True;

      procedure Push (Line : String) is
      begin
         if S then
            Insert_Header_Text (Line & ASCII.LF, S);
         end if;
      end Push;
   begin
      if FFI_Loader_Emitted then
         Success := True;
         return;
      end if;

      Push ("#if defined(ALB_PLAT_POSIX)");
      Push ("#include <dlfcn.h>");
      Push ("#endif");
      Push ("");
      Push ("typedef void (*ALB_FFI_Symbol_Func)(void);");
      Push ("static ALB_FFI_Symbol_Func ALB_Load_Foreign_Symbol(const char* lib_name, const char* sym_name) {");
      Push ("#if defined(ALB_PLAT_WIN)");
      Push ("    HMODULE lib = LoadLibraryA(lib_name);");
      Push ("    if (!lib) return (ALB_FFI_Symbol_Func)0;");
      Push ("    return (ALB_FFI_Symbol_Func)GetProcAddress(lib, sym_name);");
      Push ("#elif defined(ALB_PLAT_POSIX)");
      Push ("    void* lib = dlopen(lib_name, RTLD_LAZY | RTLD_LOCAL);");
      Push ("    void* raw = NULL;");
      Push ("    ALB_FFI_Symbol_Func sym = 0;");
      Push ("    if (!lib) return (ALB_FFI_Symbol_Func)0;");
      Push ("    raw = dlsym(lib, sym_name);");
      Push ("    if (!raw) return (ALB_FFI_Symbol_Func)0;");
      Push ("    memcpy(&sym, &raw, (sizeof(sym) < sizeof(raw)) ? sizeof(sym) : sizeof(raw));");
      Push ("    return sym;");
      Push ("#else");
      Push ("    (void)lib_name; (void)sym_name; return (ALB_FFI_Symbol_Func)0;");
      Push ("#endif");
      Push ("}");
      Push ("");

      if S then
         FFI_Loader_Emitted := True;
      end if;

      Success := S;
   end Emit_FFI_Loader_Prelude;

   
   procedure Emit_Input_Prompt_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("printf(""%s"", (char*)(uintptr_t)(", S);
      Success := S;
   end Emit_Input_Prompt_Start;

   procedure Emit_Input_Prompt_End (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("));", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Input_Prompt_End;

   procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      if Tag = Type_Binary then
         -- Braw string buffer for the console read
         Append ("{ static char _in[2048]; scanf(""%2047s"", _in); ", S);
      else
         -- DA FIX: Use correct format strings tae prevent stack corruption!
         case Tag is
            when Type_U8      => Append ("scanf(""%hhu"", &", S);
            when Type_U16     => Append ("scanf(""%hu"", &", S);
            when Type_U32     => Append ("scanf(""%u"", &", S);
            when Type_Boolean => Append ("scanf(""%hhu"", &", S);
            when others       => Append ("scanf(""%llu"", &", S);
         end case;
      end if;
      Success := S;
   end Emit_Input_Read_Start;

   procedure Emit_Input_Read_End (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
   begin
      if Tag = Type_Binary then
         -- Assign the static string buffer pointer tae the string variable
         Append (" = (uint64_t)(uintptr_t)_in; }", S);
      else
         Append (");", S);
      end if;
      Emit_Newline (S);
      Success := S;
   end Emit_Input_Read_End;

   -- =========================================================================
   -- USER-DEFINED STRUCTS & TYPE MAPPING
   -- =========================================================================
   procedure Emit_Type_Definition (Tag : ALB_Type_Tag; Success : out Boolean)
   is
   begin
      Append (C_Type_Name (Tag), Success);
   end Emit_Type_Definition;

   procedure Emit_Pure_Struct_Def (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("typedef struct {", S);
      Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("uint64_t num;", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("uint64_t den;", S);
      Emit_Newline (S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("} PURE;", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Pure_Struct_Def;

   procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      -- DA FIX: Hoist all structs tae the global header space!
      Current_Buffer := Buffer_Global;
      Emit_Indent (S);
      Append ("typedef struct {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Struct_Start;

   procedure Emit_Struct_Field
     (Field_Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Emit_Type_Definition (Tag, S);
      Append (" " & Field_Name & ";", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Struct_Field;

   procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("} " & Struct_Name & ";", S);
      Emit_Newline (S);
      -- DA FIX: Restore the buffer back tae main!
      Current_Buffer := Buffer_Main;
      Success := S;
   end Emit_Struct_End;

   -- =========================================================================
   -- VARIABLE ALLOCATION & STATIC MEMORY VAULTS
   -- =========================================================================
   --  procedure Emit_Forward_Declaration
   --    (Func_Name : String; Success : out Boolean)
   --  is
   --     Decl_Str : constant String := "uint64_t " & Func_Name & "_func();" & ASCII.LF;
   --  begin
   --     -- DA FIX: Route forward declarations strictly tae the Decl_Buffer sae they precede ALL definitions!
   --     if Decl_Len + Decl_Str'Length <= Max_Buffer_Size then
   --        Decl_Buffer (Decl_Len + 1 .. Decl_Len + Decl_Str'Length) := Decl_Str;
   --        Decl_Len := Decl_Len + Decl_Str'Length;
   --        Success := True;
   --     else
   --        Success := False;
   --     end if;
   --  end Emit_Forward_Declaration;
   procedure Emit_Forward_Declaration
     (Func_Name   : String;
      Return_Tag : ALB_Type_Tag;
      Param_Count : Natural;
      Success    : out Boolean)
   is
      Decl_Str : Unbounded_String :=
        To_Unbounded_String (C_Type_Name (Return_Tag) & " " & Func_Name & "_func(");
   begin
      if Param_Count = 0 then
         Append (Decl_Str, "void");
      else
         for I in 1 .. Param_Count loop
            Append (Decl_Str, "uint64_t");
            if I < Param_Count then
               Append (Decl_Str, ", ");
            end if;
         end loop;
      end if;

      Append (Decl_Str, ");" & ASCII.LF);
      Append_Declaration_Text (To_String (Decl_Str), Success);
   end Emit_Forward_Declaration;

   procedure Emit_Var_Decl
     (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Emit_Type_Definition (Tag, S);
      
      -- DA NEW FIX: Vector & Matrix types need curly-brace initialization!
      if Tag in Type_F32x2 .. Type_Mat4x4 then
         Append (" " & Name & " = {0};", S);
      else
         Append (" " & Name & " = 0;", S);
      end if;
      
      Emit_Newline (S);
      Success := S;
   end Emit_Var_Decl;

   procedure Emit_Struct_Var_Decl
     (Struct_Name : String; Var_Name : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      -- Emits: Circuit grid = {0};
      Append (Struct_Name & " " & Var_Name & " = {0};", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Struct_Var_Decl;

   -- ==========================================
   -- Auto-Routing for Vaults and Procedures
   -- ==========================================
   procedure Emit_Strict_Array_Decl
     (Name : String; Size_Bytes : Natural; Success : out Boolean)
   is
      S        : Boolean;
      Elements : Natural := Size_Bytes / 8;
      Old_Buf  : Buffer_Target := Current_Buffer;
   begin
      Current_Buffer := Buffer_Global; -- Send to BSS!
      Emit_Indent (S);
      Append
        ("uint64_t " & Name & "[" & Natural'Image (Elements) & "] = {0};", S);
      Emit_Newline (S);
      Current_Buffer := Old_Buf; -- Restore Scope
      Success := S;
   end Emit_Strict_Array_Decl;

   procedure Emit_Slide_Array_Decl
     (Name : String; Max_Bytes : Natural; Success : out Boolean) is
   begin
      Emit_Strict_Array_Decl
         (Name, Max_Bytes, Success); -- In C, SLIDE is mapped tae a flat array.
   end Emit_Slide_Array_Decl;

   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      S         : Boolean := True;
      Old_Buf   : constant Buffer_Target := Current_Buffer;
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
   begin
      Current_Buffer := Buffer_Global;

      Emit_Indent (S);
      Emit_Type_Definition (Tag, S);
      Append (" " & Name & " = 0;", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("uint64_t ALB_TEMP_" & Name & "_history[" & Depth_Text & "] = {0};", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("uint64_t ALB_TEMP_" & Name & "_head = 0;", S);
      Emit_Newline (S);

      Current_Buffer := Old_Buf;
      Success := S;
   end Emit_Temporal_Var_Decl;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      S          : Boolean := True;
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
   begin
      Emit_Indent (S);
      Append
        ("ALB_TEMP_" & Name & "_history[ALB_TEMP_" & Name & "_head] = " &
         C_Temporal_Pack_Expr (Name, Tag) &
         ";",
         S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append
        ("ALB_TEMP_" & Name & "_head = (ALB_TEMP_" & Name & "_head + 1) % " &
         Depth_Text &
         ";",
         S);
      Emit_Newline (S);

      Success := S;
   end Emit_Temporal_Record_Current;

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
   begin
      Append (C_Temporal_Unpack_Expr (Name, Tag), Success);
   end Emit_Temporal_Load_Now;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
      Index_Expr : constant String :=
        "(ALB_TEMP_" & Name & "_head == 0 ? " & Depth_Text & " - 1 : ALB_TEMP_" &
        Name &
        "_head - 1)";
   begin
      Append
        (C_Temporal_Unpack_Expr
           ("ALB_TEMP_" & Name & "_history[" & Index_Expr & "]",
            Tag),
         Success);
   end Emit_Temporal_Load_Past;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   is
   begin
      Append ("(uint64_t)(uintptr_t)ALB_TEMP_" & Name & "_history", Success);
   end Emit_Temporal_Load_Timeline;

   procedure Emit_Slide_Vault_Left
     (Vault_Name : String; Shift_Amount : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append
        ("memmove("
         & Vault_Name
         & ", "
         & Vault_Name
         & " + "
         & Shift_Amount
         & ", sizeof("
         & Vault_Name
         & ") - ("
         & Shift_Amount
         & " * sizeof(uint64_t)));",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Slide_Vault_Left;

   procedure Emit_Slide_Vault_Right
     (Vault_Name : String; Shift_Amount : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append
        ("memmove("
         & Vault_Name
         & " + "
         & Shift_Amount
         & ", "
         & Vault_Name
         & ", sizeof("
         & Vault_Name
         & ") - ("
         & Shift_Amount
         & " * sizeof(uint64_t)));",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Slide_Vault_Right;

   procedure Emit_Let_Assign_Start (Type_Hint : String; Success : out Boolean)
   is
   begin
      Append (" = ", Success);
   end Emit_Let_Assign_Start;

   procedure Emit_Variable_Ref (Name : String; Success : out Boolean) is
   begin
      Append (Name, Success);
   end Emit_Variable_Ref;

   procedure Emit_Array_Index_Open (Success : out Boolean) is
   begin
      Append ("[", Success);
   end Emit_Array_Index_Open;

   --  procedure Emit_Array_Index_Close (Success : out Boolean) is
   --  begin
   --     Append ("]", Success);
   --  end Emit_Array_Index_Close;

   procedure Emit_Array_Index_Close (Success : out Boolean) is
   begin
      -- This adds the " - 1" only if Secure_Mode is on!
      Append (Code_Vault.Index_Offset_Suffix & "]", Success);
   end Emit_Array_Index_Close;
   
   -- =========================================================================
   -- BOUNDED STRING MANIPULATION (NASA/JPL SAFE)
   -- =========================================================================
   procedure Emit_String_Concat
     (Dest, Src, Max_Len : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Append ("strncat(" & Dest & ", " & Src & ", " & Max_Len & ");", S);
      Success := S;
   end Emit_String_Concat;

   procedure Emit_String_Copy
     (Dest, Src, Max_Len : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Append ("strncpy(" & Dest & ", " & Src & ", " & Max_Len & ");", S);
      -- Always manually null-terminate bounded strings in C!
      Emit_Newline (S);
      Emit_Indent (S);
      Append (Dest & "[" & Max_Len & " - 1] = '\0';", S);
      Success := S;
   end Emit_String_Copy;

   procedure Emit_String_Length (Src : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("strlen(" & Src & ")", S);
      Success := S;
   end Emit_String_Length;

   -- =========================================================================
   -- OPERATORS, LITERALS & ADVANCED MATH
   -- =========================================================================
   procedure Emit_AddressOf (Success : out Boolean) is
   begin
      -- Flattens da pointer safely intae our 64-bit universe!
      Append ("(uint64_t)(uintptr_t)&", Success);
   end Emit_AddressOf;

   procedure Emit_Boolean_Cast_Start (Success : out Boolean) is
   begin
      Append ("(uint64_t)(", Success);
   end Emit_Boolean_Cast_Start;

   --  procedure Emit_Literal_U64 (Value : U64; Success : out Boolean) is
   --     Img : constant String := U64'Image (Value);
   --  begin
   --     if Img (Img'First) = ' ' then
   --        Append (Img (Img'First + 1 .. Img'Last) & "ULL", Success);
   --     else
   --        Append (Img & "ULL", Success);
   --     end if;
   --  end Emit_Literal_U64;
   
   --  procedure Emit_Literal_U64 (Value : U64; Success : out Boolean) is
   --  begin
   --     -- Ask the vault tae forge the hex sequence (e.g. ALB_V(0x5))
   --     Append (Code_Vault.To_Roman_Literal(Value), Success);
   --  end Emit_Literal_U64;
   
   procedure Emit_Literal_U64 (Value : U64; Success : out Boolean) is
      Img : constant String := U64'Image (Value);
      Hi  : constant U64 := Value / 16#1_0000_0000#;
      Lo  : constant U64 := Value mod 16#1_0000_0000#;

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
   begin
      if Value <= U64 (16#FFFF_FFFF#) then
         Append ("((uint64_t)" & Trim_Image (Img) & ")", Success);
      else
         Append
           ("ALB_U64_CONST(" &
            Trim_Image (U64'Image (Hi)) &
            ", " &
            Trim_Image (U64'Image (Lo)) &
            ")",
            Success);
      end if;
   end Emit_Literal_U64;
   
   procedure Emit_Float_Literal (Text : String; Success : out Boolean) is
   begin
      Append ("ALB_Double_As_U64(" & Text & ")", Success);
   end Emit_Float_Literal;


   procedure Emit_Global_Var_Decl
     (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S : Boolean;
      Old_Buf : Buffer_Target := Current_Buffer;
   begin
      Current_Buffer := Buffer_Global; -- Auto-route to Global Memory!
      Emit_Indent (S);
      Emit_Type_Definition (Tag, S);
      
      -- DA NEW FIX: Zeroing out Global SIMD structures safely
      if Tag in Type_F32x2 .. Type_Mat4x4 then
         Append (" " & Name & " = {0};", S);
      else
         Append (" " & Name & " = 0;", S);
      end if;
      
      Emit_Newline (S);
      Current_Buffer := Old_Buf; -- Restore Scope
      Success := S;
   end Emit_Global_Var_Decl;

   procedure Emit_String_Literal (Text : String; Success : out Boolean) is
      S : Boolean := True;
   begin
      Append ("(uint64_t)(uintptr_t)""", S);
      for I in Text'Range loop
         case Text (I) is
            when '"' =>
               Append (String'(1 => '\', 2 => '"'), S);

            when '\' =>
               Append (String'(1 => '\', 2 => '\'), S);

            when ASCII.LF =>
               Append (String'(1 => '\', 2 => 'n'), S);

            when ASCII.CR =>
               Append (String'(1 => '\', 2 => 'r'), S);

            when ASCII.HT =>
               Append (String'(1 => '\', 2 => 't'), S);

            when others =>
               Append (String'(1 => Text (I)), S);
         end case;
      end loop;
      Append ("""", S);
      Success := S;
   end Emit_String_Literal;

   procedure Emit_Expression_Open (Success : out Boolean) is
   begin
      Append ("(", Success);
   end Emit_Expression_Open;

   procedure Emit_Expression_Close (Success : out Boolean) is
   begin
      Append (")", Success);
   end Emit_Expression_Close;

   procedure Emit_BinOp (Op : ALB_Opcode; Success : out Boolean) is
   begin
      case Op is
         when OP_ADD =>
            Append (" + ", Success);

         when OP_SUB =>
            Append (" - ", Success);

         when OP_MUL =>
            Append (" * ", Success);

         when OP_DIV =>
            Append (" / ", Success);

         when OP_MOD =>
            Append (" % ", Success);  -- Added Modulo armor!

         when OP_AND =>
            Append (" & ", Success);

         when OP_OR =>
            Append (" | ", Success);
          
         when OP_LOGICAL_AND => 
            Append (" && ", Success);
            
         when OP_LOGICAL_OR => 
            Append (" || ", Success);

         when OP_XOR =>
            Append (" ^ ", Success);

         when OP_SHL =>
            Append (" << ", Success);

         when OP_SHR =>
            Append (" >> ", Success);

         when OP_CMP_EQ =>
            Append (" == ", Success);

         when OP_CMP_NEQ =>
            Append (" != ", Success); -- Da missing Not Equal!

         when OP_CMP_LT =>
            Append (" < ", Success);

         when OP_CMP_GT =>
            Append (" > ", Success);

         when OP_CMP_LTE =>
            Append (" <= ", Success);

         when OP_CMP_GTE =>
            Append (" >= ", Success);

         when others =>
            Append (" /* UNK */ ", Success);
      end case;
   end Emit_BinOp;

   -- Math Hooks mapped tae <math.h>.
   -- SIN/COS use ALB's fixed-point degree semantics: radians conversion + x1024 scale.
   procedure Emit_Square_Root (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("(uint64_t)sqrt((double)(" & Value & "))", S);
      Success := S;
   end Emit_Square_Root;

   procedure Emit_Sine (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append
        ("(uint64_t)((int64_t)(sin(((double)(int64_t)(" & Value
          & ")) * 0.017453292519943295) * 1024.0))",
         S);
      Success := S;
   end Emit_Sine;

   procedure Emit_Cosine (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append
        ("(uint64_t)((int64_t)(cos(((double)(int64_t)(" & Value
          & ")) * 0.017453292519943295) * 1024.0))",
         S);
      Success := S;
   end Emit_Cosine;

   procedure Emit_Absolute (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("(uint64_t)abs((int64_t)(" & Value & "))", S);
      Success := S;
   end Emit_Absolute;

   -- =========================================================================
   -- DA BRANCHLESS LOGIC VAULT
   -- =========================================================================
   procedure Emit_Branchless_Condition_Start (Success : out Boolean) is
   begin
      Append ("ALB_MASK_OP(", Success);
   end Emit_Branchless_Condition_Start;

   procedure Emit_Branchless_Mask_Op (Success : out Boolean) is
   begin
      Append (", ", Success);
   end Emit_Branchless_Mask_Op;

   procedure Emit_If_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("if (", S);
      Success := S;
   end Emit_If_Start;

   procedure Emit_Then (Success : out Boolean) is
      S : Boolean;
   begin
      Append (") {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Then;

   procedure Emit_Else (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("} else {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Else;

   procedure Emit_If_End (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S);
      Emit_Newline (S);
      Success := S;
   end Emit_If_End;
   
   procedure Emit_Require_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("if (!(", S);
      Success := S;
   end Emit_Require_Start;

   procedure Emit_Ensure_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("if (!(", S);
      Success := S;
   end Emit_Ensure_Start;

   procedure Emit_Contract_End (Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append (")) { printf(""" & Name & " Contract Violation!\n""); exit(1); }", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Contract_End;

   -- =========================================================================
   -- FIXED-BOUND LOOPS (NASA/JPL COMPLIANT)
   -- =========================================================================
   procedure Emit_While_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("while (", S);
      Success := S;
   end Emit_While_Start;

   procedure Emit_While_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append (") {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_While_Loop_Start;

   procedure Emit_Plain_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("for (;;) {", S);
      Emit_Newline (S);
      Increase_Indent;
      Push_Loop_Close (False);
      Success := S;
   end Emit_Plain_Loop_Start;

   procedure Emit_Exit_When (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("if (", S);
      Success := S;
   end Emit_Exit_When;

   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Current_For_Len := Iterator_Name'Length;
      Current_For_Iterator (1 .. Current_For_Len) := Iterator_Name;
      Emit_Indent (S);
      Append ("for (" & Iterator_Name & " = ", S);
      Success := S;
   end Emit_For_Start;

   procedure Emit_DotDot (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("; " & Current_For_Iterator (1 .. Current_For_Len) & " <= ", S);
      Success := S;
   end Emit_DotDot;

   procedure Emit_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("; " & Current_For_Iterator (1 .. Current_For_Len) & "++) {", S);
      Emit_Newline (S);
      Increase_Indent;
      Push_Loop_Close (False);
      Success := S;
   end Emit_Loop_Start;
   
   -- =====================================================================
   -- DA FOREACH FORGE (NASA/JPL Bounded Safety)
   -- =====================================================================
   procedure Emit_Foreach_Start (Iterator_Name : String; Array_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("{", S);
      Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("uint64_t _idx_" & Iterator_Name & ";", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("for (_idx_" & Iterator_Name & " = 0; _idx_" & Iterator_Name & " < (sizeof(" & Array_Name & ")/sizeof(" & Array_Name & "[0])); _idx_" & Iterator_Name & "++) {", S);
      Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("uint64_t " & Iterator_Name & " = " & Array_Name & "[_idx_" & Iterator_Name & "];", S);
      Emit_Newline (S);
      Push_Loop_Close (True);
      Success := S;
   end Emit_Foreach_Start;

   procedure Emit_Loop_End (Success : out Boolean) is
      S : Boolean;
      Has_Extra_Scope : Boolean;
   begin
      Has_Extra_Scope := Pop_Loop_Close;
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S);
      Emit_Newline (S);
      if Has_Extra_Scope then
         Decrease_Indent;
         Emit_Indent (S);
         Append ("}", S);
         Emit_Newline (S);
      end if;
      Success := S;
   end Emit_Loop_End;

   procedure Emit_Case_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("switch (", S);
      Success := S;
   end Emit_Case_Start;

   procedure Emit_Is (Success : out Boolean) is
      S : Boolean;
   begin
      Append (") {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Is;

   procedure Emit_When (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("case ", S);
      Success := S;
   end Emit_When;

   procedure Emit_Arrow (Success : out Boolean) is
      S : Boolean;
   begin
      Append (": {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Arrow;

   procedure Emit_When_End (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("break;", S);
      Emit_Newline (S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S);
      Emit_Newline (S);
      Success := S;
   end Emit_When_End;

   procedure Emit_Case_End (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Case_End;

   -- =========================================================================
   -- PROCEDURES
   -- =========================================================================
   procedure Emit_Procedure_Decl_Start (Name : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Current_Buffer := Buffer_Global;
      Emit_Indent (S);
      -- Change void tae uint64_t and append _func
      Append ("uint64_t " & Name & "_func(void) {", S);
      Emit_Newline (S);
      Increase_Indent;
      In_Global_Scope := False;
      Success := S;
   end Emit_Procedure_Decl_Start;
   
   procedure Emit_Function_Decl_Start (Name : String; Return_Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S : Boolean;
   begin
      Current_Buffer := Buffer_Global; -- DA FIX: Force output OUTSIDE of main()!
      Emit_Indent (S);
      Emit_Type_Definition (Return_Tag, S);
      Append (" " & Name & "_func", S);
      In_Global_Scope := False;
      Success := S;
   end Emit_Function_Decl_Start;

   procedure Emit_Procedure_End (Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      -- A catch-all return tae keep GCC quiet!
      Append ("    return ALB_U64_ZERO;", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("}", S);
      Emit_Newline (S);
      In_Global_Scope := True;
      Current_Buffer := Buffer_Main;
      Success := S;
   end Emit_Procedure_End;

   procedure Emit_Return_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("return ", S);
      Success := S;
   end Emit_Return_Start;

   procedure Emit_Call_Start (Func_Name : String; Success : out Boolean) is
   begin
      -- DA FIX: Intercept standard string library calls tae da Native Forge!
      if Func_Name = "MID" then
         Append ("ALB_String_Mid(", Success);
      elsif Func_Name = "LEFT" then
         Append ("ALB_String_Left(", Success);
      elsif Func_Name = "RIGHT" then
         Append ("ALB_String_Right(", Success);
      elsif Func_Name = "ASC" then
         Append ("ALB_String_Asc(", Success);
         
      -- DA NEW CHR ROUTER
      elsif Func_Name = "CHR" then
         Append ("ALB_String_Chr(", Success);
       
      -- DA NEW STRING MAPS
      elsif Func_Name = "CONCAT" then
         Append ("ALB_String_Concat(", Success);
      elsif Func_Name = "INSERT" then
         Append ("ALB_String_Insert(", Success);
      elsif Func_Name = "REMOVE" then
         Append ("ALB_String_Remove(", Success);
         
      -- DA NEW COLLISION FORGE INTERCEPTOR!
      elsif Func_Name = "COLLIDE_RECT" then
         Append ("ALB_Collide_Rect(", Success);
         
      -- DA NEW HARDWARE WIPE INTERCEPTOR!
      -- Catch da module-prefixed call an' route it straight tae da C macro!
      elsif Func_Name = "ALB_CON_ALB_Clear_Console" then
         Append ("ALB_Clear_Console(", Success);
         
      -- DA NEW TERMINAL ORACLE INTERCEPTORS (Case Sensitive!)
      elsif Func_Name = "ALB_CON_ALB_Console_Width" then
         Append ("ALB_Console_Width(", Success);
      elsif Func_Name = "ALB_CON_ALB_Console_Height" then
         Append ("ALB_Console_Height(", Success);
         
      -- DA NEW CONIO KEYBOARD INTERCEPTOR (Case Sensitive!)
      elsif Func_Name = "ALB_CON_KeyPress" then
         Append ("ALB_Poll_Event(", Success);
         
      -- DA INTRINSIC MODULE BYPASS
      elsif Func_Name = "ALB_CON_LEFT" then
         Append ("ALB_String_Left(", Success);
      elsif Func_Name = "ALB_CON_RIGHT" then
         Append ("ALB_String_Right(", Success);
      elsif Func_Name = "ALB_CON_CONCAT" then
         Append ("ALB_String_Concat(", Success);
      elsif Func_Name = "ALB_CON_ALB_Set_Color" then
         Append ("ALB_Set_Color_func(", Success);
         
      -- DA PERMANENT FIX: Protect da ALB_CON module from da native macro trap!
      -- If it's a module call, it MUST get da _func suffix!
      elsif Func_Name'Length >= 8 and then Func_Name (Func_Name'First .. Func_Name'First + 7) = "ALB_CON_" then
         Append (Func_Name & "_func(", Success);
         
      -- Catch raw internal C macros (like ALB_Locate)
      elsif Func_Name'Length >= 4 and then Func_Name (Func_Name'First .. Func_Name'First + 3) = "ALB_" then
         Append (Func_Name & "(", Success);
         
      -- Standard user functions
      else
         Append (Func_Name & "_func(", Success);
      end if;
   end Emit_Call_Start;

   procedure Emit_Call_End (Success : out Boolean) is
   begin
      Append (")", Success);
   end Emit_Call_End;

   procedure Emit_Comma (Success : out Boolean) is
   begin
      Append (", ", Success);
   end Emit_Comma;

   procedure Emit_Statement_End (Success : out Boolean) is
      S : Boolean;
   begin
      Append (";", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Statement_End;

   procedure Emit_Assign_Prefix (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Success := S;
   end Emit_Assign_Prefix;

   --  procedure Emit_Print_Start (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean) is
   --     S : Boolean;
   --  begin
   --     Emit_Indent (S);
   --     if Tag = Type_Pure then
   --        if Piped then Append ("ALB_PRINT_PURE_PIPED(", S);
   --        else Append ("ALB_PRINT_PURE(", S); end if;
   --     elsif Tag = Type_S32 then
   --        if Piped then Append ("printf(""%lld"", (long long)(int32_t)(", S);
   --        else Append ("printf(""%lld\n"", (long long)(int32_t)(", S); end if;
   --     else
   --        if Piped then Append ("ALB_Smart_Print_Piped(", S);
   --        else Append ("ALB_Smart_Print(", S); end if;
   --     end if;
   --     Success := S;
   --  end Emit_Print_Start;
   
   procedure Emit_Print_Start (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean) is
   S : Boolean;
begin
   Emit_Indent (S);
   if Tag = Type_Pure then
      if Piped then Append ("ALB_PRINT_PURE_PIPED(", S);
      else Append ("ALB_PRINT_PURE(", S); end if;
   elsif Tag = Type_S32 then
      if Piped then Append ("printf(""%ld"", (long)(", S);
      else Append ("printf(""%ld\n"", (long)(", S); end if;
      
   -- DA FIX: Route tae da Float Printing Forge 
   elsif Tag = Type_F64 then
      if Piped then Append ("ALB_Print_Float_Piped(", S);
      else Append ("ALB_Print_Float(", S); end if;
      
   else
      if Piped then Append ("ALB_Smart_Print_Piped(", S);
      else Append ("ALB_Smart_Print(", S); end if;
   end if;
   Success := S;
end Emit_Print_Start;

   procedure Emit_Print_End (Tag : ALB_Type_Tag; Piped : Boolean; Success : out Boolean) is
      S : Boolean;
   begin
      if Tag = Type_S32 then
         Append ("));", S);
      else
         Append (");", S);
      end if;
      Success := S;
   end Emit_Print_End;
   
   procedure Emit_File_Open_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_File_Open((uint64_t)(", S);
      Success := S;
   end Emit_File_Open_Start;

   procedure Emit_File_Open_Mid (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("), (uint64_t)(", S);
      Success := S;
   end Emit_File_Open_Mid;

   procedure Emit_File_Read_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_File_Read((uint64_t)(", S);
      Success := S;
   end Emit_File_Read_Start;

   procedure Emit_File_Read_Mid (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("), (uint64_t)(", S);
      Success := S;
   end Emit_File_Read_Mid;

   procedure Emit_File_Write_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_File_Write((uint64_t)(", S);
      Success := S;
   end Emit_File_Write_Start;

   procedure Emit_File_Write_Mid (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("), (uint64_t)(", S);
      Success := S;
   end Emit_File_Write_Mid;

   procedure Emit_File_Close_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_File_Close((uint64_t)(", S);
      Success := S;
   end Emit_File_Close_Start;

   procedure Emit_File_Len_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_File_Len((uint64_t)(", S);
      Success := S;
   end Emit_File_Len_Start;

   procedure Emit_File_Seek_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_File_Seek((uint64_t)(", S);
      Success := S;
   end Emit_File_Seek_Start;

   procedure Emit_File_Seek_Mid (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("), (uint64_t)(", S);
      Success := S;
   end Emit_File_Seek_Mid;

   -- =========================================================================
   -- OS FILE VAULTS & KNOWLEDGE (PROLOG)
   -- =========================================================================
   procedure Emit_OS_Load
     (File_Path : String; Target_Buffer : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("FILE* fp = fopen(""" & File_Path & """, ""rb"");", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append
        ("if (fp) { fread("
         & Target_Buffer
         & ", 1, sizeof("
         & Target_Buffer
         & "), fp); fclose(fp); }",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_OS_Load;

   -- =========================================================================
   -- DA BARE-METAL MEMORY FORGE (Streaming)
   -- =========================================================================
   procedure Emit_Poke_Start (Success : out Boolean) is
   begin
      Append ("*(uint64_t*)(uintptr_t)(", Success);
   end Emit_Poke_Start;

   procedure Emit_Poke_Mid (Success : out Boolean) is
   begin
      Append (") = ", Success);
   end Emit_Poke_Mid;

   procedure Emit_Peek_Start (Success : out Boolean) is
   begin
      Append ("(*(uint64_t*)(uintptr_t)(", Success);
   end Emit_Peek_Start;

   procedure Emit_Deref_Start (Success : out Boolean) is
   begin
      Append ("(*(uint64_t*)(uintptr_t)(", Success);
   end Emit_Deref_Start;

   procedure Emit_OS_Flush
     (Source_Buffer : String; File_Path : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("FILE* fp = fopen(""" & File_Path & """, ""wb"");", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append
        ("if (fp) { fwrite("
         & Source_Buffer
         & ", 1, sizeof("
         & Source_Buffer
         & "), fp); fclose(fp); }",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_OS_Flush;

   procedure Emit_Prolog_Fact_Registration
     (Pred : String; Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("/* PROLOG FACT: " & Pred & "(" & Arg & ") */", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Prolog_Fact_Registration;

   procedure Emit_Prolog_Query_Call
     (Pred : String; Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Append ("ALB_Query(""" & Pred & """, " & Arg & ")", S);
      Success := S;
   end Emit_Prolog_Query_Call;

   -- =========================================================================
   -- DA NATIVE FORGE: INPUT, GRAPHICS & AUDIO BINDINGS
   -- =========================================================================
   procedure Emit_Key_State (Key_Code : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Key_State(" & Key_Code & ")", S);
      Success := S;
   end Emit_Key_State;

   procedure Emit_Mouse_Position (X_Var, Y_Var : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Append ("/* Mouse Position Mapping */", S);
      Success := S;
   end Emit_Mouse_Position;

   procedure Emit_Mouse_Click (Button : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("/* Mouse Click Mapping */", S);
      Success := S;
   end Emit_Mouse_Click;

   procedure Emit_Put_Pixel (X, Y, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Put_Pixel(" & X & ", " & Y & ", ALB_Current_Color);", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Put_Pixel;

   procedure Emit_Draw_Line (X1, Y1, X2, Y2, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Draw_Line(" & X1 & ", " & Y1 & ", " & X2 & ", " & Y2 & ", ALB_Current_Color);", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Draw_Line;
   
   procedure Emit_Draw_Circle (X, Y, R, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Draw_Circle(" & X & ", " & Y & ", " & R & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Draw_Circle;

   procedure Emit_Draw_Triangle (X1, Y1, X2, Y2, X3, Y3, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Draw_Triangle(" & X1 & ", " & Y1 & ", " & X2 & ", " & Y2 & ", " & X3 & ", " & Y3 & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Draw_Triangle;
   
   procedure Emit_Fill_Circle (X, Y, R, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Fill_Circle(" & X & ", " & Y & ", " & R & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Fill_Circle;

   procedure Emit_Fill_Triangle (X1, Y1, X2, Y2, X3, Y3, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Fill_Triangle(" & X1 & ", " & Y1 & ", " & X2 & ", " & Y2 & ", " & X3 & ", " & Y3 & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Fill_Triangle;

   procedure Emit_Draw_Rect (X, Y, W, H, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Draw_Rect(" & X & ", " & Y & ", " & W & ", " & H & ", ALB_Current_Color);", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Draw_Rect;

   procedure Emit_Fill_Rect (X, Y, W, H, Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Fill_Rect(" & X & ", " & Y & ", " & W & ", " & H & ", ALB_Current_Color);", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Fill_Rect;

   procedure Emit_Blit_Image
     (Source_Vault, X, Y : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Append
        ("ALB_Blit_Image(" & Source_Vault & ", " & X & ", " & Y & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Blit_Image;

   procedure Emit_Load_Sound
     (File_Path, Target_Vault : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      -- We dinna actually need tae "load" sounds into a vault for PlaySoundA if we just play them directly from disk!
      -- But we can store the file path pointer in the vault!
      Append (Target_Vault & " = (uint64_t)(uintptr_t)""" & File_Path & """;", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Load_Sound;

   procedure Emit_Play_Sound (Vault_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      -- SND_ASYNC plays in the background, SND_FILENAME says we are passing a file path!
      Append ("PlaySoundA((char*)(uintptr_t)" & Vault_Name & ", NULL, SND_ASYNC | SND_FILENAME);", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Play_Sound;

   -- =========================================================================
   -- WIN32 UI TRANSLATION
   -- =========================================================================
   procedure Emit_Print_Function_Start (Success : out Boolean) is
   begin
      Append ("printf(", Success);
   end Emit_Print_Function_Start;
   
   --  procedure Emit_Window_Creation
   --     (Title : String; W, H : Natural; Success : out Boolean)
   --  is
   --     S       : Boolean := True;
   --     Old_Buf : Buffer_Target := Current_Buffer;
   --  begin
   --     Current_Buffer := Buffer_Global;
   --  
   --     Is_GUI_Active := True;
   --     Emit_Media_Bindings (S);
   --  
   --     -- UNIVERSAL: Forward declare the event hooks!
   --     Append ("uint64_t ALB_ON_TICK_func(void);", S); Emit_Newline(S);
   --     Append ("uint64_t ALB_ON_PAINT_func(void);", S); Emit_Newline(S);
   --     Emit_Newline (S);
   --  
   --     -- =========================================================
   --     -- DA NEW SDL3 GRAPHICS FORGE
   --     -- =========================================================
   --     Append ("static uint64_t ALB_Sys_Renderer(void) {", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) return 4; /* 4 = SDL3 Active */", S); Emit_Newline(S);
   --     Append ("    return 0;", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     -- Origin manipulation in SDL3 requires adjusting the viewport or using logical size
   --     Append ("static void ALB_Set_Origin(uint64_t x, uint64_t y) {", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        SDL_Rect r; r.x = (int)x; r.y = (int)y; r.w = (int)ALB_Screen_Width; r.h = (int)ALB_Screen_Height;", S); Emit_Newline(S);
   --     Append ("        SDL_SetRenderViewport(ALB_Renderer, &r);", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Set_Clip(uint64_t x, uint64_t y, uint64_t w, uint64_t h) {", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        if (w == 0 && h == 0) {", S); Emit_Newline(S);
   --     Append ("            SDL_SetRenderClipRect(ALB_Renderer, NULL);", S); Emit_Newline(S);
   --     Append ("        } else {", S); Emit_Newline(S);
   --     Append ("            SDL_Rect r; r.x = (int)x; r.y = (int)y; r.w = (int)w; r.h = (int)h;", S); Emit_Newline(S);
   --     Append ("            SDL_SetRenderClipRect(ALB_Renderer, &r);", S); Emit_Newline(S);
   --     Append ("        }", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Set_Alpha(uint64_t mode, uint64_t value) {", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        if (mode > 0) {", S); Emit_Newline(S);
   --     Append ("            SDL_SetRenderDrawBlendMode(ALB_Renderer, SDL_BLENDMODE_BLEND);", S); Emit_Newline(S);
   --     Append ("        } else {", S); Emit_Newline(S);
   --     Append ("            SDL_SetRenderDrawBlendMode(ALB_Renderer, SDL_BLENDMODE_NONE);", S); Emit_Newline(S);
   --     Append ("        }", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static uint64_t ALB_Read_Pixel(uint64_t x, uint64_t y) {", S); Emit_Newline(S);
   --     Append ("    uint64_t color = 0;", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        SDL_Rect r; r.x = (int)x; r.y = (int)y; r.w = 1; r.h = 1;", S); Emit_Newline(S);
   --     Append ("        SDL_Surface* surface = SDL_RenderReadPixels(ALB_Renderer, &r);", S); Emit_Newline(S);
   --     Append ("        if (surface) {", S); Emit_Newline(S);
   --     Append ("            uint32_t* pixels = (uint32_t*)surface->pixels;", S); Emit_Newline(S);
   --     Append ("            color = (uint64_t)pixels[0];", S); Emit_Newline(S);
   --     Append ("            SDL_DestroySurface(surface);", S); Emit_Newline(S);
   --     Append ("        }", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("    return color;", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     -- Helper to set the color before drawing
   --     Append ("static void ALB_Apply_Color(void) {", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        Uint8 r = (ALB_Current_Color >> 16) & 0xFF;", S); Emit_Newline(S);
   --     Append ("        Uint8 g = (ALB_Current_Color >> 8) & 0xFF;", S); Emit_Newline(S);
   --     Append ("        Uint8 b = ALB_Current_Color & 0xFF;", S); Emit_Newline(S);
   --     Append ("        Uint8 a = (ALB_Current_Color >> 24) & 0xFF;", S); Emit_Newline(S);
   --     Append ("        if (a == 0) a = 255; /* Default to opaque if alpha not set */", S); Emit_Newline(S);
   --     Append ("        SDL_SetRenderDrawColor(ALB_Renderer, r, g, b, a);", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     -- =========================================================
   --     -- ALB Drawing Primitives (Routed to SDL3)
   --     -- =========================================================
   --     Append ("static void ALB_Fill_Rect(uint64_t x, uint64_t y, uint64_t w, uint64_t h) {", S); Emit_Newline(S);
   --     Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        SDL_FRect r; r.x = (float)x; r.y = (float)y; r.w = (float)w; r.h = (float)h;", S); Emit_Newline(S);
   --     Append ("        SDL_RenderFillRect(ALB_Renderer, &r);", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Draw_Rect(uint64_t x, uint64_t y, uint64_t w, uint64_t h) {", S); Emit_Newline(S);
   --     Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        SDL_FRect r; r.x = (float)x; r.y = (float)y; r.w = (float)w; r.h = (float)h;", S); Emit_Newline(S);
   --     Append ("        SDL_RenderRect(ALB_Renderer, &r);", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Draw_Line(uint64_t x1, uint64_t y1, uint64_t x2, uint64_t y2) {", S); Emit_Newline(S);
   --     Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        SDL_RenderLine(ALB_Renderer, (float)x1, (float)y1, (float)x2, (float)y2);", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Put_Pixel(uint64_t x, uint64_t y) {", S); Emit_Newline(S);
   --     Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
   --     Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
   --     Append ("        SDL_RenderPoint(ALB_Renderer, (float)x, (float)y);", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     -- DA SOFTWARE RASTERIZERS (Using SDL_RenderPoint)
   --     Append ("static void ALB_Draw_Circle(uint64_t xc, uint64_t yc, uint64_t r) {", S); Emit_Newline(S);
   --     Append ("    int64_t x = 0, y = (int64_t)r;", S); Emit_Newline(S);
   --     Append ("    int64_t d = 3 - 2 * (int64_t)r;", S); Emit_Newline(S);
   --     Append ("    while (y >= x && x <= 8192) {", S); Emit_Newline(S);
   --     Append ("        ALB_Put_Pixel(xc + x, yc + y); ALB_Put_Pixel(xc - x, yc + y);", S); Emit_Newline(S);
   --     Append ("        ALB_Put_Pixel(xc + x, yc - y); ALB_Put_Pixel(xc - x, yc - y);", S); Emit_Newline(S);
   --     Append ("        ALB_Put_Pixel(xc + y, yc + x); ALB_Put_Pixel(xc - y, yc + x);", S); Emit_Newline(S);
   --     Append ("        ALB_Put_Pixel(xc + y, yc - x); ALB_Put_Pixel(xc - y, yc - x);", S); Emit_Newline(S);
   --     Append ("        x++;", S); Emit_Newline(S);
   --     Append ("        if (d > 0) { y--; d = d + 4 * (x - y) + 10; }", S); Emit_Newline(S);
   --     Append ("        else { d = d + 4 * x + 6; }", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Fill_Circle(uint64_t xc, uint64_t yc, uint64_t r) {", S); Emit_Newline(S);
   --     Append ("    int64_t x = 0, y = (int64_t)r;", S); Emit_Newline(S);
   --     Append ("    int64_t d = 3 - 2 * (int64_t)r;", S); Emit_Newline(S);
   --     Append ("    while (y >= x && x <= 8192) {", S); Emit_Newline(S);
   --     Append ("        ALB_Draw_Line(xc - x, yc + y, xc + x, yc + y);", S); Emit_Newline(S);
   --     Append ("        ALB_Draw_Line(xc - x, yc - y, xc + x, yc - y);", S); Emit_Newline(S);
   --     Append ("        ALB_Draw_Line(xc - y, yc + x, xc + y, yc + x);", S); Emit_Newline(S);
   --     Append ("        ALB_Draw_Line(xc - y, yc - x, xc + y, yc - x);", S); Emit_Newline(S);
   --     Append ("        x++;", S); Emit_Newline(S);
   --     Append ("        if (d > 0) { y--; d = d + 4 * (x - y) + 10; }", S); Emit_Newline(S);
   --     Append ("        else { d = d + 4 * x + 6; }", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Draw_Triangle(uint64_t x1, uint64_t y1, uint64_t x2, uint64_t y2, uint64_t x3, uint64_t y3) {", S); Emit_Newline(S);
   --     Append ("    ALB_Draw_Line(x1, y1, x2, y2);", S); Emit_Newline(S);
   --     Append ("    ALB_Draw_Line(x2, y2, x3, y3);", S); Emit_Newline(S);
   --     Append ("    ALB_Draw_Line(x3, y3, x1, y1);", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static int64_t ALB_Edge_Func(int64_t x1, int64_t y1, int64_t x2, int64_t y2, int64_t x3, int64_t y3) {", S); Emit_Newline(S);
   --     Append ("    return (x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1);", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Fill_Triangle(uint64_t x1, uint64_t y1, uint64_t x2, uint64_t y2, uint64_t x3, uint64_t y3) {", S); Emit_Newline(S);
   --     Append ("    int64_t minX = x1; if(x2 < minX) minX = x2; if(x3 < minX) minX = x3;", S); Emit_Newline(S);
   --     Append ("    int64_t minY = y1; if(y2 < minY) minY = y2; if(y3 < minY) minY = y3;", S); Emit_Newline(S);
   --     Append ("    int64_t maxX = x1; if(x2 > maxX) maxX = x2; if(x3 > maxX) maxX = x3;", S); Emit_Newline(S);
   --     Append ("    int64_t maxY = y1; if(y2 > maxY) maxY = y2; if(y3 > maxY) maxY = y3;", S); Emit_Newline(S);
   --     Append ("    if (minX < 0) minX = 0; if (minY < 0) minY = 0;", S); Emit_Newline(S);
   --     Append ("    if (maxX > 8192) maxX = 8192; if (maxY > 8192) maxY = 8192;", S); Emit_Newline(S);
   --     Append ("    int64_t w0, w1, w2;", S); Emit_Newline(S);
   --     Append ("    for (int64_t y = minY; y <= maxY; y++) {", S); Emit_Newline(S);
   --     Append ("        for (int64_t x = minX; x <= maxX; x++) {", S); Emit_Newline(S);
   --     Append ("            w0 = ALB_Edge_Func(x2, y2, x3, y3, x, y);", S); Emit_Newline(S);
   --     Append ("            w1 = ALB_Edge_Func(x3, y3, x1, y1, x, y);", S); Emit_Newline(S);
   --     Append ("            w2 = ALB_Edge_Func(x1, y1, x2, y2, x, y);", S); Emit_Newline(S);
   --     Append ("            if ((w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)) {", S); Emit_Newline(S);
   --     Append ("                ALB_Put_Pixel((uint64_t)x, (uint64_t)y);", S); Emit_Newline(S);
   --     Append ("            }", S); Emit_Newline(S);
   --     Append ("        }", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     --  Append ("static void ALB_Draw_Text(uint64_t x, uint64_t y, uint64_t text_ptr) {", S); Emit_Newline(S);
   --     --  Append ("    /* TODO: Implement text rendering with SDL_ttf or bitmap font */", S); Emit_Newline(S);
   --     --  Append ("}", S); Emit_Newline(S);
   --     -- =========================================================
   --     -- DA HARDCODED 8x8 TERMINAL FONT & TEXT RASTERIZER
   --     -- =========================================================
   --     Append ("/* --- DA HARDCODED 8x8 TERMINAL FONT (ASCII 32-127) --- */", S); Emit_Newline(S);
   --     Append ("static const uint8_t ALB_Font8x8[96][8] = {", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, {0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x6C,0x6C,0x6C,0x00,0x00,0x00,0x00,0x00}, {0x6C,0x6C,0xFE,0x6C,0xFE,0x6C,0x6C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x18,0x3E,0x60,0x3C,0x06,0x7C,0x18,0x00}, {0x00,0xC6,0xCC,0x18,0x30,0x66,0xC6,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x38,0x6C,0x6C,0x38,0x6D,0x66,0x3B,0x00}, {0x0C,0x18,0x30,0x00,0x00,0x00,0x00,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00}, {0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00}, {0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30}, {0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00}, {0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00}, {0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x3C,0x66,0x06,0x0C,0x30,0x60,0x7E,0x00}, {0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x0C,0x1C,0x3C,0x6C,0xFE,0x0C,0x0C,0x00}, {0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x3C,0x66,0x60,0x7C,0x66,0x66,0x3C,0x00}, {0x7E,0x66,0x06,0x0C,0x18,0x18,0x18,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00}, {0x3C,0x66,0x66,0x3E,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00}, {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30},", S); Emit_Newline(S);
   --     Append ("    {0x0C,0x18,0x30,0x60,0x30,0x18,0x0C,0x00}, {0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x30,0x18,0x0C,0x06,0x0C,0x18,0x30,0x00}, {0x3C,0x66,0x06,0x18,0x18,0x00,0x18,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x3C,0x66,0x6E,0x6E,0x60,0x66,0x3C,0x00}, {0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00}, {0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00}, {0x7E,0x60,0x60,0x78,0x60,0x60,0x7E,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x7E,0x60,0x60,0x78,0x60,0x60,0x60,0x00}, {0x3C,0x66,0x60,0x6E,0x66,0x66,0x3E,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00}, {0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x1E,0x0C,0x0C,0x0C,0x0C,0x6C,0x38,0x00}, {0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00}, {0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00}, {0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00}, {0x3C,0x66,0x66,0x66,0x6A,0x6C,0x36,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x7C,0x66,0x66,0x7C,0x6C,0x66,0x66,0x00}, {0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00}, {0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00}, {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00}, {0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00}, {0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x80,0xC0,0x60,0x30,0x18,0x0C,0x06,0x00}, {0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x18,0x3C,0x66,0x00,0x00,0x00,0x00,0x00}, {0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x30,0x30,0x18,0x00,0x00,0x00,0x00,0x00}, {0x00,0x00,0x3C,0x06,0x3E,0x66,0x3E,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x60,0x60,0x7C,0x66,0x66,0x66,0x7C,0x00}, {0x00,0x00,0x3C,0x60,0x60,0x60,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x06,0x06,0x3E,0x66,0x66,0x66,0x3E,0x00}, {0x00,0x00,0x3C,0x66,0x7E,0x60,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x1C,0x30,0x7C,0x30,0x30,0x30,0x30,0x00}, {0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x3C},", S); Emit_Newline(S);
   --     Append ("    {0x60,0x60,0x7C,0x66,0x66,0x66,0x66,0x00}, {0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x0C,0x00,0x0C,0x0C,0x0C,0x0C,0x0C,0x38}, {0x60,0x60,0x66,0x6C,0x78,0x6C,0x66,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00}, {0x00,0x00,0x76,0x7F,0x6B,0x6B,0x6B,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x7C,0x66,0x66,0x66,0x66,0x00}, {0x00,0x00,0x3C,0x66,0x66,0x66,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x7C,0x66,0x66,0x7C,0x60,0x60}, {0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x06},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x7C,0x66,0x60,0x60,0x60,0x00}, {0x00,0x00,0x3E,0x60,0x3C,0x06,0x3C,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x30,0x30,0x7C,0x30,0x30,0x34,0x18,0x00}, {0x00,0x00,0x66,0x66,0x66,0x66,0x3E,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x66,0x66,0x66,0x3C,0x18,0x00}, {0x00,0x00,0x63,0x6B,0x6B,0x7F,0x36,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x66,0x3C,0x18,0x3C,0x66,0x00}, {0x00,0x00,0x66,0x66,0x66,0x3E,0x06,0x3C},", S); Emit_Newline(S);
   --     Append ("    {0x00,0x00,0x7E,0x0C,0x18,0x30,0x7E,0x00}, {0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18}, {0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00},", S); Emit_Newline(S);
   --     Append ("    {0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00}, {0x00,0x10,0x38,0x54,0x10,0x10,0x10,0x00}", S); Emit_Newline(S);
   --     Append ("};", S); Emit_Newline(S);
   --  
   --     Append ("static void ALB_Draw_Text(uint64_t x, uint64_t y, uint64_t text_ptr) {", S); Emit_Newline(S);
   --     Append ("    char* str = (char*)(uintptr_t)text_ptr;", S); Emit_Newline(S);
   --     Append ("    if (!str || !ALB_Renderer) return;", S); Emit_Newline(S);
   --     Append ("    int cursor_x = (int)x; int cursor_y = (int)y;", S); Emit_Newline(S);
   --     Append ("    while (*str) {", S); Emit_Newline(S);
   --     Append ("        unsigned char c = (unsigned char)*str;", S); Emit_Newline(S);
   --     Append ("        if (c == '\n') {", S); Emit_Newline (S);
   --     Append ("            cursor_x = (int)x; cursor_y += 10; /* Drop down a line */", S); Emit_Newline(S);
   --     Append ("        } else if (c >= 32 && c <= 127) {", S); Emit_Newline(S);
   --     Append ("            int char_idx = c - 32;", S); Emit_Newline(S);
   --     Append ("            for (int row = 0; row < 8; row++) {", S); Emit_Newline(S);
   --     Append ("                uint8_t row_data = ALB_Font8x8[char_idx][row];", S); Emit_Newline(S);
   --     Append ("                if (row_data == 0) continue; /* Fast skip empty rows */", S); Emit_Newline(S);
   --     Append ("                for (int col = 0; col < 8; col++) {", S); Emit_Newline(S);
   --     Append ("                    /* Check if the bit is set (from left to right) */", S); Emit_Newline(S);
   --     Append ("                    if (row_data & (0x80 >> col)) {", S); Emit_Newline(S);
   --     Append ("                        ALB_Put_Pixel(cursor_x + col, cursor_y + row);", S); Emit_Newline(S);
   --     Append ("                    }", S); Emit_Newline(S);
   --     Append ("                }", S); Emit_Newline(S);
   --     Append ("            }", S); Emit_Newline(S);
   --     Append ("            cursor_x += 8; /* Move cursor right by character width */", S); Emit_Newline(S);
   --     Append ("        }", S); Emit_Newline(S);
   --     Append ("        str++;", S); Emit_Newline(S);
   --     Append ("    }", S); Emit_Newline(S);
   --     Append ("}", S); Emit_Newline(S);
   --  
   --     -- =================================================================
   --     -- MAIN INITIALIZATION (Buffer_Main)
   --     -- =================================================================
   --     --  Current_Buffer := Buffer_Main;
   --     --
   --     --  Emit_Indent (S);
   --     --  Append ("/* --- IGNITE THE SDL3 FORGE --- */", S); Emit_Newline(S);
   --     --  Emit_Indent (S);
   --     --  Append ("if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) { return 1; }", S); Emit_Newline(S);
   --     --
   --     --  Emit_Indent (S);
   --     --  Append ("if (!SDL_CreateWindowAndRenderer(""" & Title & """, " & Natural'Image(W) & ", " & Natural'Image(H) & ", 0, &ALB_Window, &ALB_Renderer)) { return 1; }", S); Emit_Newline(S);
   --  
   --     -- =================================================================
   --     -- MAIN INITIALIZATION (Buffer_Main)
   --     -- =================================================================
   --     Current_Buffer := Buffer_Main;
   --     Emit_Indent (S);
   --     Append ("/* --- IGNITE THE SDL3 FORGE --- */", S); Emit_Newline(S);
   --  
   --     Emit_Indent (S);
   --     Append ("if (!SDL_Init(SDL_INIT_VIDEO)) { printf(""[ALB FATAL] SDL_Init Video Error: %s\n"", SDL_GetError()); return 1; }", S); Emit_Newline(S);
   --  
   --     Emit_Indent (S);
   --     Append ("if (!SDL_Init(SDL_INIT_AUDIO)) { printf(""[ALB WARN] SDL_Init Audio Failed (Non-Fatal): %s\n"", SDL_GetError()); }", S); Emit_Newline(S);
   --  
   --     Emit_Indent (S);
   --     Append ("if (!SDL_CreateWindowAndRenderer(""" & Title & """, " & Natural'Image(W) & ", " & Natural'Image(H) & ", 0, &ALB_Window, &ALB_Renderer)) { printf(""[ALB FATAL] SDL_Window Error: %s\n"", SDL_GetError()); return 1; }", S);
   --     Emit_Newline(S);
   --  
   --     Emit_Indent (S);
   --     Append ("/* Lock the Environmental Oracle Dimensions */", S); Emit_Newline(S);
   --     Emit_Indent (S);
   --     Append ("ALB_Screen_Width = " & Natural'Image(W) & ";", S); Emit_Newline(S);
   --     Emit_Indent (S);
   --     Append ("ALB_Screen_Height = " & Natural'Image(H) & ";", S); Emit_Newline(S);
   --     Emit_Indent (S);
   --     Append ("ALB_Virtual_Width = ALB_Screen_Width;", S); Emit_Newline(S);
   --     Emit_Indent (S);
   --     Append ("ALB_Virtual_Height = ALB_Screen_Height;", S); Emit_Newline(S);
   --  
   --     -- Restore safety buffer
   --     Current_Buffer := Buffer_Global;
   --  
   --     Success := S;
   --  end Emit_Window_Creation;
   
   procedure Emit_Window_Creation
      (Title : String; Success : out Boolean)
   is
      S       : Boolean := True;
      Old_Buf : Buffer_Target := Current_Buffer;
   begin
      Current_Buffer := Buffer_Global;
      
      Is_GUI_Active := True;
      Emit_Media_Bindings (S);
      
      -- UNIVERSAL: Forward declare the event hooks!
      Append ("uint64_t ALB_ON_TICK_func(void);", S); Emit_Newline(S);
      Append ("uint64_t ALB_ON_PAINT_func(void);", S); Emit_Newline(S);
      Emit_Newline (S);
      
      -- =========================================================
      -- DA NEW SDL3 GRAPHICS FORGE
      -- =========================================================
      Append ("static uint64_t ALB_Sys_Renderer(void) {", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) return 4; /* 4 = SDL3 Active */", S); Emit_Newline(S);
      Append ("    return 0;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Apply_Render_Presentation(void) {", S); Emit_Newline(S);
      Append ("    if (!ALB_Renderer) return;", S); Emit_Newline(S);
      Append ("    if (ALB_Scale_Mode != 0 && ALB_Virtual_Width > 0 && ALB_Virtual_Height > 0) {", S); Emit_Newline(S);
      Append ("        SDL_SetRenderLogicalPresentation(ALB_Renderer, (int)ALB_Virtual_Width, (int)ALB_Virtual_Height, SDL_LOGICAL_PRESENTATION_STRETCH);", S); Emit_Newline(S);
      Append ("    } else {", S); Emit_Newline(S);
      Append ("        SDL_SetRenderLogicalPresentation(ALB_Renderer, 0, 0, SDL_LOGICAL_PRESENTATION_DISABLED);", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Update_Output_State(void) {", S); Emit_Newline(S);
      Append ("    int out_w = 0;", S); Emit_Newline(S);
      Append ("    int out_h = 0;", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer && SDL_GetCurrentRenderOutputSize(ALB_Renderer, &out_w, &out_h)) {", S); Emit_Newline(S);
      Append ("        ALB_Screen_Width = (uint64_t)out_w;", S); Emit_Newline(S);
      Append ("        ALB_Screen_Height = (uint64_t)out_h;", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("    if (ALB_Scale_Mode == 0 && ALB_Screen_Width > 0 && ALB_Screen_Height > 0) {", S); Emit_Newline(S);
      Append ("        ALB_Virtual_Width = ALB_Screen_Width;", S); Emit_Newline(S);
      Append ("        ALB_Virtual_Height = ALB_Screen_Height;", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("    ALB_Apply_Render_Presentation();", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Apply_Clip(void) {", S); Emit_Newline(S);
      Append ("    /* C backend clip state is applied directly by ALB_Set_Clip. */", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Set_Fullscreen(uint64_t value) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Window_Fullscreen = value & ALB_U64_ONE;", S); Emit_Newline(S);
      Append ("    if (ALB_Window) {", S); Emit_Newline(S);
      Append ("        SDL_SetWindowFullscreen(ALB_Window, ALB_Window_Fullscreen ? 1 : 0);", S); Emit_Newline(S);
      Append ("        ALB_Update_Output_State();", S); Emit_Newline(S);
      Append ("        ALB_Apply_Clip();", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Set_Resizable(uint64_t value) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Window_Resizable = value & ALB_U64_ONE;", S); Emit_Newline(S);
      Append ("    if (ALB_Window) {", S); Emit_Newline(S);
      Append ("        SDL_SetWindowResizable(ALB_Window, ALB_Window_Resizable ? 1 : 0);", S); Emit_Newline(S);
      Append ("        ALB_Update_Output_State();", S); Emit_Newline(S);
      Append ("        ALB_Apply_Clip();", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Set_Stretchy(uint64_t value) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Scale_Mode = value & ALB_U64_ONE;", S); Emit_Newline(S);
      Append ("    ALB_Update_Output_State();", S); Emit_Newline(S);
      Append ("    ALB_Apply_Clip();", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      -- Origin manipulation in SDL3 requires adjusting the viewport or using logical size
      Append ("static void ALB_Set_Origin(uint64_t x, uint64_t y) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        SDL_Rect r; r.x = (int)(int64_t)x; r.y = (int)(int64_t)y; r.w = (int)ALB_Screen_Width; r.h = (int)ALB_Screen_Height;", S); Emit_Newline(S);
      Append ("        SDL_SetRenderViewport(ALB_Renderer, &r);", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Set_Clip(uint64_t x, uint64_t y, uint64_t w, uint64_t h) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        if (w == 0 && h == 0) {", S); Emit_Newline(S);
      Append ("            SDL_SetRenderClipRect(ALB_Renderer, NULL);", S); Emit_Newline(S);
      Append ("        } else {", S); Emit_Newline(S);
      Append ("            SDL_Rect r; r.x = (int)(int64_t)x; r.y = (int)(int64_t)y; r.w = (int)(int64_t)w; r.h = (int)(int64_t)h;", S); Emit_Newline(S);
      Append ("            SDL_SetRenderClipRect(ALB_Renderer, &r);", S); Emit_Newline(S);
      Append ("        }", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Set_Alpha(uint64_t mode, uint64_t value) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        if (mode > 0) {", S); Emit_Newline(S);
      Append ("            SDL_SetRenderDrawBlendMode(ALB_Renderer, SDL_BLENDMODE_BLEND);", S); Emit_Newline(S);
      Append ("        } else {", S); Emit_Newline(S);
      Append ("            SDL_SetRenderDrawBlendMode(ALB_Renderer, SDL_BLENDMODE_NONE);", S); Emit_Newline(S);
      Append ("        }", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static uint64_t ALB_Read_Pixel(uint64_t x, uint64_t y) {", S); Emit_Newline(S);
      Append ("    uint64_t color = 0;", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        SDL_Rect r; r.x = (int)(int64_t)x; r.y = (int)(int64_t)y; r.w = 1; r.h = 1;", S); Emit_Newline(S);
      Append ("        SDL_Surface* surface = SDL_RenderReadPixels(ALB_Renderer, &r);", S); Emit_Newline(S);
      Append ("        if (surface) {", S); Emit_Newline(S);
      Append ("            uint32_t* pixels = (uint32_t*)surface->pixels;", S); Emit_Newline(S);
      Append ("            color = (uint64_t)pixels[0];", S); Emit_Newline(S);
      Append ("            SDL_DestroySurface(surface);", S); Emit_Newline(S);
      Append ("        }", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("    return color;", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      -- Helper to set the color before drawing
      Append ("static void ALB_Apply_Color(void) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        Uint8 r = (ALB_Current_Color >> 16) & 0xFF;", S); Emit_Newline(S);
      Append ("        Uint8 g = (ALB_Current_Color >> 8) & 0xFF;", S); Emit_Newline(S);
      Append ("        Uint8 b = ALB_Current_Color & 0xFF;", S); Emit_Newline(S);
      Append ("        Uint8 a = (ALB_Current_Color >> 24) & 0xFF;", S); Emit_Newline(S);
      Append ("        if (a == 0) a = 255; /* Default to opaque if alpha not set */", S); Emit_Newline(S);
      Append ("        SDL_SetRenderDrawColor(ALB_Renderer, r, g, b, a);", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      -- =========================================================
      -- ALB Drawing Primitives (Routed to SDL3)
      -- =========================================================
      Append ("static void ALB_Fill_Rect(uint64_t x, uint64_t y, uint64_t w, uint64_t h) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        SDL_FRect r; r.x = (float)(int32_t)x; r.y = (float)(int32_t)y; r.w = (float)(int32_t)w; r.h = (float)(int32_t)h;", S); Emit_Newline(S);
      Append ("        SDL_RenderFillRect(ALB_Renderer, &r);", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Draw_Rect(uint64_t x, uint64_t y, uint64_t w, uint64_t h) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        SDL_FRect r; r.x = (float)(int32_t)x; r.y = (float)(int32_t)y; r.w = (float)(int32_t)w; r.h = (float)(int32_t)h;", S); Emit_Newline(S);
      Append ("        SDL_RenderRect(ALB_Renderer, &r);", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Draw_Line(uint64_t x1, uint64_t y1, uint64_t x2, uint64_t y2) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        SDL_RenderLine(ALB_Renderer, (float)(int32_t)x1, (float)(int32_t)y1, (float)(int32_t)x2, (float)(int32_t)y2);", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);
      
      Append ("static void ALB_Put_Pixel(uint64_t x, uint64_t y) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Apply_Color();", S); Emit_Newline(S);
      Append ("    if (ALB_Renderer) {", S); Emit_Newline(S);
      Append ("        SDL_RenderPoint(ALB_Renderer, (float)(int32_t)x, (float)(int32_t)y);", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      -- DA SOFTWARE RASTERIZERS (Using SDL_RenderPoint)
      Append ("static void ALB_Draw_Circle(uint64_t xc_in, uint64_t yc_in, uint64_t r_in) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    int32_t xc = (int32_t)xc_in, yc = (int32_t)yc_in, r = (int32_t)r_in;", S); Emit_Newline(S);
      Append ("    int32_t x = 0, y = r;", S); Emit_Newline(S);
      Append ("    int32_t d = 3 - 2 * r;", S); Emit_Newline(S);
      Append ("    while (y >= x && x <= 8192) {", S); Emit_Newline(S);
      Append ("        ALB_Put_Pixel((uint64_t)(xc + x), (uint64_t)(yc + y)); ALB_Put_Pixel((uint64_t)(xc - x), (uint64_t)(yc + y));", S); Emit_Newline(S);
      Append ("        ALB_Put_Pixel((uint64_t)(xc + x), (uint64_t)(yc - y)); ALB_Put_Pixel((uint64_t)(xc - x), (uint64_t)(yc - y));", S); Emit_Newline(S);
      Append ("        ALB_Put_Pixel((uint64_t)(xc + y), (uint64_t)(yc + x)); ALB_Put_Pixel((uint64_t)(xc - y), (uint64_t)(yc + x));", S); Emit_Newline(S);
      Append ("        ALB_Put_Pixel((uint64_t)(xc + y), (uint64_t)(yc - x)); ALB_Put_Pixel((uint64_t)(xc - y), (uint64_t)(yc - x));", S); Emit_Newline(S);
      Append ("        x++;", S); Emit_Newline(S);
      Append ("        if (d > 0) { y--; d = d + 4 * (x - y) + 10; }", S); Emit_Newline(S);
      Append ("        else { d = d + 4 * x + 6; }", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Fill_Circle(uint64_t xc_in, uint64_t yc_in, uint64_t r_in) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    int32_t xc = (int32_t)xc_in, yc = (int32_t)yc_in, r = (int32_t)r_in;", S); Emit_Newline(S);
      Append ("    int32_t x = 0, y = r;", S); Emit_Newline(S);
      Append ("    int32_t d = 3 - 2 * r;", S); Emit_Newline(S);
      Append ("    while (y >= x && x <= 8192) {", S); Emit_Newline(S);
      Append ("        ALB_Draw_Line((uint64_t)(xc - x), (uint64_t)(yc + y), (uint64_t)(xc + x), (uint64_t)(yc + y));", S); Emit_Newline(S);
      Append ("        ALB_Draw_Line((uint64_t)(xc - x), (uint64_t)(yc - y), (uint64_t)(xc + x), (uint64_t)(yc - y));", S); Emit_Newline(S);
      Append ("        ALB_Draw_Line((uint64_t)(xc - y), (uint64_t)(yc + x), (uint64_t)(xc + y), (uint64_t)(yc + x));", S); Emit_Newline(S);
      Append ("        ALB_Draw_Line((uint64_t)(xc - y), (uint64_t)(yc - x), (uint64_t)(xc + y), (uint64_t)(yc - x));", S); Emit_Newline(S);
      Append ("        x++;", S); Emit_Newline(S);
      Append ("        if (d > 0) { y--; d = d + 4 * (x - y) + 10; }", S); Emit_Newline(S);
      Append ("        else { d = d + 4 * x + 6; }", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Draw_Triangle(uint64_t x1, uint64_t y1, uint64_t x2, uint64_t y2, uint64_t x3, uint64_t y3) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    ALB_Draw_Line(x1, y1, x2, y2);", S); Emit_Newline(S);
      Append ("    ALB_Draw_Line(x2, y2, x3, y3);", S); Emit_Newline(S);
      Append ("    ALB_Draw_Line(x3, y3, x1, y1);", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static int32_t ALB_Edge_Func(int32_t x1, int32_t y1, int32_t x2, int32_t y2, int32_t x3, int32_t y3) {", S); Emit_Newline(S);
      Append ("    return (x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1);", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("static void ALB_Fill_Triangle(uint64_t x1, uint64_t y1, uint64_t x2, uint64_t y2, uint64_t x3, uint64_t y3) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    int32_t minX = (int32_t)x1; if((int32_t)x2 < minX) minX = (int32_t)x2; if((int32_t)x3 < minX) minX = (int32_t)x3;", S); Emit_Newline(S);
      Append ("    int32_t minY = (int32_t)y1; if((int32_t)y2 < minY) minY = (int32_t)y2; if((int32_t)y3 < minY) minY = (int32_t)y3;", S); Emit_Newline(S);
      Append ("    int32_t maxX = (int32_t)x1; if((int32_t)x2 > maxX) maxX = (int32_t)x2; if((int32_t)x3 > maxX) maxX = (int32_t)x3;", S); Emit_Newline(S);
      Append ("    int32_t maxY = (int32_t)y1; if((int32_t)y2 > maxY) maxY = (int32_t)y2; if((int32_t)y3 > maxY) maxY = (int32_t)y3;", S); Emit_Newline(S);
      Append ("    if (minX < 0) minX = 0; if (minY < 0) minY = 0;", S); Emit_Newline(S);
      Append ("    if (maxX > 8192) maxX = 8192; if (maxY > 8192) maxY = 8192;", S); Emit_Newline(S);
      Append ("    int32_t x;", S); Emit_Newline(S);
      Append ("    int32_t y;", S); Emit_Newline(S);
      Append ("    int32_t w0, w1, w2;", S); Emit_Newline(S);
      Append ("    for (y = minY; y <= maxY; y++) {", S); Emit_Newline(S);
      Append ("        for (x = minX; x <= maxX; x++) {", S); Emit_Newline(S);
      Append ("            w0 = ALB_Edge_Func((int32_t)x2, (int32_t)y2, (int32_t)x3, (int32_t)y3, x, y);", S); Emit_Newline(S);
      Append ("            w1 = ALB_Edge_Func((int32_t)x3, (int32_t)y3, (int32_t)x1, (int32_t)y1, x, y);", S); Emit_Newline(S);
      Append ("            w2 = ALB_Edge_Func((int32_t)x1, (int32_t)y1, (int32_t)x2, (int32_t)y2, x, y);", S); Emit_Newline(S);
      Append ("            if ((w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)) {", S); Emit_Newline(S);
      Append ("                ALB_Put_Pixel((uint64_t)x, (uint64_t)y);", S); Emit_Newline(S);
      Append ("            }", S); Emit_Newline(S);
      Append ("        }", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      Append ("/* --- DA HARDCODED 8x8 TERMINAL FONT (ASCII 32-127) --- */", S); Emit_Newline(S);
      Append ("static const uint8_t ALB_Font8x8[96][8] = {", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, {0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00},", S); Emit_Newline(S);
      Append ("    {0x6C,0x6C,0x6C,0x00,0x00,0x00,0x00,0x00}, {0x6C,0x6C,0xFE,0x6C,0xFE,0x6C,0x6C,0x00},", S); Emit_Newline(S);
      Append ("    {0x18,0x3E,0x60,0x3C,0x06,0x7C,0x18,0x00}, {0x00,0xC6,0xCC,0x18,0x30,0x66,0xC6,0x00},", S); Emit_Newline(S);
      Append ("    {0x38,0x6C,0x6C,0x38,0x6D,0x66,0x3B,0x00}, {0x0C,0x18,0x30,0x00,0x00,0x00,0x00,0x00},", S); Emit_Newline(S);
      Append ("    {0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00}, {0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00}, {0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30}, {0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00}, {0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00},", S); Emit_Newline(S);
      Append ("    {0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00}, {0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00},", S); Emit_Newline(S);
      Append ("    {0x3C,0x66,0x06,0x0C,0x30,0x60,0x7E,0x00}, {0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x0C,0x1C,0x3C,0x6C,0xFE,0x0C,0x0C,0x00}, {0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x3C,0x66,0x60,0x7C,0x66,0x66,0x3C,0x00}, {0x7E,0x66,0x06,0x0C,0x18,0x18,0x18,0x00},", S); Emit_Newline(S);
      Append ("    {0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00}, {0x3C,0x66,0x66,0x3E,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00}, {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30},", S); Emit_Newline(S);
      Append ("    {0x0C,0x18,0x30,0x60,0x30,0x18,0x0C,0x00}, {0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00},", S); Emit_Newline(S);
      Append ("    {0x30,0x18,0x0C,0x06,0x0C,0x18,0x30,0x00}, {0x3C,0x66,0x06,0x18,0x18,0x00,0x18,0x00},", S); Emit_Newline(S);
      Append ("    {0x3C,0x66,0x6E,0x6E,0x60,0x66,0x3C,0x00}, {0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00},", S); Emit_Newline(S);
      Append ("    {0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00}, {0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00}, {0x7E,0x60,0x60,0x78,0x60,0x60,0x7E,0x00},", S); Emit_Newline(S);
      Append ("    {0x7E,0x60,0x60,0x78,0x60,0x60,0x60,0x00}, {0x3C,0x66,0x60,0x6E,0x66,0x66,0x3E,0x00},", S); Emit_Newline(S);
      Append ("    {0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00}, {0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x1E,0x0C,0x0C,0x0C,0x0C,0x6C,0x38,0x00}, {0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00},", S); Emit_Newline(S);
      Append ("    {0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00}, {0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00},", S); Emit_Newline(S);
      Append ("    {0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00}, {0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00}, {0x3C,0x66,0x66,0x66,0x6A,0x6C,0x36,0x00},", S); Emit_Newline(S);
      Append ("    {0x7C,0x66,0x66,0x7C,0x6C,0x66,0x66,0x00}, {0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00}, {0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00}, {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00},", S); Emit_Newline(S);
      Append ("    {0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00}, {0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00},", S); Emit_Newline(S);
      Append ("    {0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00}, {0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x80,0xC0,0x60,0x30,0x18,0x0C,0x06,0x00}, {0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x18,0x3C,0x66,0x00,0x00,0x00,0x00,0x00}, {0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0x00},", S); Emit_Newline(S);
      Append ("    {0x30,0x30,0x18,0x00,0x00,0x00,0x00,0x00}, {0x00,0x00,0x3C,0x06,0x3E,0x66,0x3E,0x00},", S); Emit_Newline(S);
      Append ("    {0x60,0x60,0x7C,0x66,0x66,0x66,0x7C,0x00}, {0x00,0x00,0x3C,0x60,0x60,0x60,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x06,0x06,0x3E,0x66,0x66,0x66,0x3E,0x00}, {0x00,0x00,0x3C,0x66,0x7E,0x60,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x1C,0x30,0x7C,0x30,0x30,0x30,0x30,0x00}, {0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x3C},", S); Emit_Newline(S);
      Append ("    {0x60,0x60,0x7C,0x66,0x66,0x66,0x66,0x00}, {0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x0C,0x00,0x0C,0x0C,0x0C,0x0C,0x0C,0x38}, {0x60,0x60,0x66,0x6C,0x78,0x6C,0x66,0x00},", S); Emit_Newline(S);
      Append ("    {0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00}, {0x00,0x00,0x76,0x7F,0x6B,0x6B,0x6B,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x7C,0x66,0x66,0x66,0x66,0x00}, {0x00,0x00,0x3C,0x66,0x66,0x66,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x7C,0x66,0x66,0x7C,0x60,0x60}, {0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x06},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x7C,0x66,0x60,0x60,0x60,0x00}, {0x00,0x00,0x3E,0x60,0x3C,0x06,0x3C,0x00},", S); Emit_Newline(S);
      Append ("    {0x30,0x30,0x7C,0x30,0x30,0x34,0x18,0x00}, {0x00,0x00,0x66,0x66,0x66,0x66,0x3E,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x66,0x66,0x66,0x3C,0x18,0x00}, {0x00,0x00,0x63,0x6B,0x6B,0x7F,0x36,0x00},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x66,0x3C,0x18,0x3C,0x66,0x00}, {0x00,0x00,0x66,0x66,0x66,0x3E,0x06,0x3C},", S); Emit_Newline(S);
      Append ("    {0x00,0x00,0x7E,0x0C,0x18,0x30,0x7E,0x00}, {0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00},", S); Emit_Newline(S);
      Append ("    {0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18}, {0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00},", S); Emit_Newline(S);
      Append ("    {0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00}, {0x00,0x10,0x38,0x54,0x10,0x10,0x10,0x00}", S); Emit_Newline(S);
      Append ("};", S); Emit_Newline(S);

      Append ("static void ALB_Draw_Text(uint64_t x, uint64_t y, uint64_t text_ptr) {", S); Emit_Newline(S);
      Append ("    if (ALB_TEMP_Future_Suppress_IO) return;", S); Emit_Newline(S);
      Append ("    char* str = (char*)(uintptr_t)text_ptr;", S); Emit_Newline(S);
      Append ("    int cursor_x = (int)(int32_t)x; int cursor_y = (int)(int32_t)y;", S); Emit_Newline(S);
      Append ("    int row;", S); Emit_Newline(S);
      Append ("    int col;", S); Emit_Newline(S);
      Append ("    if (!str || !ALB_Renderer) return;", S); Emit_Newline(S);
      Append ("    while (*str) {", S); Emit_Newline(S);
      Append ("        unsigned char c = (unsigned char)*str;", S); Emit_Newline(S);
      Append ("        if (c == '\n') {", S); Emit_Newline (S);
      Append ("            cursor_x = (int)(int32_t)x; cursor_y += 10; /* Drop down a line */", S); Emit_Newline(S);
      Append ("        } else if (c >= 32 && c <= 127) {", S); Emit_Newline(S);
      Append ("            int char_idx = c - 32;", S); Emit_Newline(S);
      Append ("            for (row = 0; row < 8; row++) {", S); Emit_Newline(S);
      Append ("                uint8_t row_data = ALB_Font8x8[char_idx][row];", S); Emit_Newline(S);
      Append ("                if (row_data == 0) continue; /* Fast skip empty rows */", S); Emit_Newline(S);
      Append ("                for (col = 0; col < 8; col++) {", S); Emit_Newline(S);
      Append ("                    /* Check if the bit is set (from left to right) */", S); Emit_Newline(S);
      Append ("                    if (row_data & (0x80 >> col)) {", S); Emit_Newline(S);
      Append ("                        ALB_Put_Pixel(cursor_x + col, cursor_y + row);", S); Emit_Newline(S);
      Append ("                    }", S); Emit_Newline(S);
      Append ("                }", S); Emit_Newline(S);
      Append ("            }", S); Emit_Newline(S);
      Append ("            cursor_x += 8; /* Move cursor right by character width */", S); Emit_Newline(S);
      Append ("        }", S); Emit_Newline(S);
      Append ("        str++;", S); Emit_Newline(S);
      Append ("    }", S); Emit_Newline(S);
      Append ("}", S); Emit_Newline(S);

      -- =================================================================
      -- MAIN INITIALIZATION (Buffer_Main)
      -- =================================================================
      Current_Buffer := Buffer_Main;
      Emit_Indent (S);
      Append ("/* --- IGNITE THE SDL3 FORGE --- */", S); Emit_Newline(S);
      
      Emit_Indent (S);
      Append ("if (!SDL_Init(SDL_INIT_VIDEO)) { printf(""[ALB FATAL] SDL_Init Video Error: %s\n"", SDL_GetError()); return 1; }", S); Emit_Newline(S);
      
      Emit_Indent (S);
      Append ("if (!SDL_Init(SDL_INIT_AUDIO)) { printf(""[ALB WARN] SDL_Init Audio Failed (Non-Fatal): %s\n"", SDL_GetError()); }", S); Emit_Newline(S);
      
      Emit_Indent (S);
      Append ("if (!SDL_CreateWindowAndRenderer(""" & Title & """, ALB_Screen_Width, ALB_Screen_Height, 0, &ALB_Window, &ALB_Renderer)) { printf(""[ALB FATAL] SDL_Window Error: %s\n"", SDL_GetError()); return 1; }", S);
      Emit_Newline(S);
      
      Emit_Indent (S);
      Append ("ALB_Virtual_Width = ALB_Screen_Width;", S); Emit_Newline(S);
      Emit_Indent (S);
      Append ("ALB_Virtual_Height = ALB_Screen_Height;", S); Emit_Newline(S);
      Emit_Indent (S);
      Append ("ALB_Set_Resizable(ALB_Window_Resizable);", S); Emit_Newline(S);
      Emit_Indent (S);
      Append ("ALB_Set_Fullscreen(ALB_Window_Fullscreen);", S); Emit_Newline(S);

      -- Keep subsequent BEGIN-block statements in main().
      Current_Buffer := Buffer_Main;

      Success := S;
   end Emit_Window_Creation;

   procedure Emit_Set_Fullscreen (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("ALB_Set_Fullscreen(", S);
      Success := S;
   end Emit_Set_Fullscreen;

   procedure Emit_Set_Resizable (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("ALB_Set_Resizable(", S);
      Success := S;
   end Emit_Set_Resizable;

   procedure Emit_Set_Stretchy (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("ALB_Set_Stretchy(", S);
      Success := S;
   end Emit_Set_Stretchy;
    
   procedure Emit_Message_Loop (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("ALB_Running = 1;", S); Emit_Newline (S);
      
      -- DA SMART HEADLESS FORK
      if not Is_GUI_Active then
         Emit_Indent (S);
         Append ("/* --- PURE HEADLESS CONSOLE LOOP --- */", S); Emit_Newline (S);
         Emit_Indent (S);
         Append ("while (ALB_Running) {", S); Emit_Newline (S);
         Increase_Indent;
         Emit_Indent (S);
         Append ("ALB_ON_TICK_func();", S); Emit_Newline (S);
         Emit_Indent (S);
         Append ("ALB_Delay(16); /* ~60 TPS Engine Tick */", S); Emit_Newline (S);
         Decrease_Indent;
         Emit_Indent (S);
         Append ("}", S); Emit_Newline (S);
         Success := S;
         return;
      end if;
      
      -- =========================================================================
      -- =========================================================================
      -- ||                          THE SDL3 FORGE                             ||
      -- =========================================================================
      -- =========================================================================
      
      Emit_Indent (S);
      Append ("SDL_Event ev;", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("while (ALB_Running) {", S); Emit_Newline (S);
      Increase_Indent;
      
      -- ==========================================
      -- 1. THE EVENT PUMP
      -- ==========================================
      Emit_Indent (S);
      Append ("/* --- 1. THE SDL3 EVENT PUMP --- */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("while (SDL_PollEvent(&ev)) {", S); Emit_Newline (S);
      Increase_Indent;
      
      Emit_Indent (S);
      Append ("if (ev.type == SDL_EVENT_QUIT) goto end_loop;", S); Emit_Newline (S);
      
      -- ==========================================
      -- 2. WINDOW RESIZE INTERCEPTOR
      -- ==========================================
      Emit_Indent (S);
      Append ("/* Intercept Resizes for the Oracle */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("else if (ev.type == SDL_EVENT_WINDOW_RESIZED) {", S); Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("ALB_Screen_Width = (uint64_t)ev.window.data1; ALB_Screen_Height = (uint64_t)ev.window.data2;", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("if (ALB_Scale_Mode == 0) { ALB_Virtual_Width = ALB_Screen_Width; ALB_Virtual_Height = ALB_Screen_Height; }", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("ALB_Update_Output_State();", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("ALB_Apply_Clip();", S); Emit_Newline (S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline (S);
      
      -- ==========================================
      -- 3. KEYBOARD & MOUSE INPUT
      -- ==========================================
      Emit_Indent (S);
      Append ("/* Keyboard Tracking */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("else if (ev.type == SDL_EVENT_KEY_DOWN && ev.key.scancode < 256) { ALB_Key_Map[ev.key.scancode] = 1; }", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("else if (ev.type == SDL_EVENT_KEY_UP && ev.key.scancode < 256) { ALB_Key_Map[ev.key.scancode] = 0; }", S); Emit_Newline (S);
      
      Emit_Indent (S);
      Append ("/* Mouse Tracking & Oracle Scaling Math */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("else if (ev.type == SDL_EVENT_MOUSE_MOTION) {", S); Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("ALB_Mouse_X = (uint64_t)ev.motion.x; ALB_Mouse_Y = (uint64_t)ev.motion.y;", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("if (ALB_Screen_Width > 0 && ALB_Screen_Height > 0) {", S); Emit_Newline(S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("ALB_VMouse_X = (ALB_Mouse_X * ALB_Virtual_Width) / ALB_Screen_Width;", S); Emit_Newline(S);
      Emit_Indent (S);
      Append ("ALB_VMouse_Y = (ALB_Mouse_Y * ALB_Virtual_Height) / ALB_Screen_Height;", S); Emit_Newline(S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline(S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline (S);
      
      Emit_Indent (S);
      Append ("/* Mouse Clicks */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("else if (ev.type == SDL_EVENT_MOUSE_BUTTON_DOWN) { ALB_Mouse_Btn |= (ALB_U64_ONE << (ev.button.button - 1)); }", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("else if (ev.type == SDL_EVENT_MOUSE_BUTTON_UP) { ALB_Mouse_Btn &= ~(ALB_U64_ONE << (ev.button.button - 1)); }", S); Emit_Newline (S);

      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline (S); -- End PollEvent Loop

      -- ==========================================
      -- 4. LOGIC TICK
      -- ==========================================
      Emit_Indent (S);
      Append ("/* --- 2. THE LOGIC TICK --- */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("ALB_ON_TICK_func();", S); Emit_Newline (S);

      -- ==========================================
      -- 5. RENDER PREPARATION (Clear)
      -- ==========================================
      Emit_Indent (S);
      Append ("/* --- 3. RENDER PREPARATION (CLEAR) --- */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("if (ALB_Renderer) {", S); Emit_Newline(S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("SDL_SetRenderDrawColor(ALB_Renderer, (ALB_Clear_Color >> 16) & 0xFF, (ALB_Clear_Color >> 8) & 0xFF, ALB_Clear_Color & 0xFF, 255);", S); Emit_Newline(S);
      Emit_Indent (S);
      Append ("SDL_RenderClear(ALB_Renderer);", S); Emit_Newline(S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline(S);
      
      -- ==========================================
      -- 6. RENDER EXECUTION
      -- ==========================================
      Emit_Indent (S);
      Append ("/* --- 4. EXECUTE PAINT LOGIC --- */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("ALB_ON_PAINT_func();", S); Emit_Newline (S);

      -- ==========================================
      -- 7. V-SYNC & BUFFER SWAPS
      -- ==========================================
      Emit_Indent (S);
      Append ("/* --- 5. SWAP BUFFERS TO SCREEN --- */", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("if (ALB_Renderer) { SDL_RenderPresent(ALB_Renderer); }", S); Emit_Newline(S);
      
      Emit_Indent (S);
      Append ("SDL_Delay(16); /* ~60 FPS Target */", S); Emit_Newline (S);

      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline (S); -- End of main while(1) loop
      
      -- ==========================================
      -- 8. CLEANUP
      -- ==========================================
      Emit_Indent (S);
      Append ("end_loop:", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("if (ALB_Renderer) { SDL_DestroyRenderer(ALB_Renderer); ALB_Renderer = NULL; }", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("if (ALB_Window) { SDL_DestroyWindow(ALB_Window); ALB_Window = NULL; }", S); Emit_Newline (S);
      Emit_Indent (S);
      Append ("SDL_Quit();", S); Emit_Newline (S);

      Success := S;
   end Emit_Message_Loop;

   procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean)
   is
   begin
      Append ("0x" & Color_Hex, Success);
   end Emit_Win32_Color_BGR;
   
   procedure Emit_Try_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("if (setjmp(ALB_Err_Stack[++ALB_Err_SP]) == 0) {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Try_Start;

   procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_Err_SP--; /* Pop on success */", S); Emit_Newline (S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("} else {", S); Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append ("ALB_Err_SP--; /* Pop on error */", S); Emit_Newline (S);
      if Err_Var'Length > 0 then
         Emit_Indent (S);
         Append (Err_Var & " = ALB_Last_Err;", S); Emit_Newline (S);
      end if;
      Success := S;
   end Emit_Catch_Start;

   procedure Emit_Try_End (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S); Emit_Newline (S);
      Success := S;
   end Emit_Try_End;

   procedure Emit_Throw_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_Last_Err = (uint64_t)(", S);
      Success := S;
   end Emit_Throw_Start;

   procedure Emit_Throw_End (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("); longjmp(ALB_Err_Stack[ALB_Err_SP], 1);", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Throw_End;
   
   -- =========================================================================
   -- DA NEW COMPILE-TIME ORACLES & GUARDS IMPLEMENTATION
   -- =========================================================================
   procedure Emit_SizeOf_Start (Success : out Boolean) is
   begin
      Append ("(uint64_t)sizeof(", Success);
   end Emit_SizeOf_Start;

   procedure Emit_OffsetOf_Start (Success : out Boolean) is
   begin
      Append ("(uint64_t)offsetof(", Success);
   end Emit_OffsetOf_Start;

   procedure Emit_Runtime_Assert_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("if (!(", S);
      Success := S;
   end Emit_Runtime_Assert_Start;

   procedure Emit_Runtime_Assert_End (Success : out Boolean) is
      S : Boolean;
   begin
      Append (")) { printf(""ALB RUNTIME ASSERTION FAILED!\n""); exit(1); }", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Runtime_Assert_End;
   
   -- =========================================================================
   -- DA NEW TEXT & LOGIC SEVERS IMPLEMENTATION
   -- =========================================================================
   procedure Emit_Readline_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("fgets((char*)(", S);
      Success := S;
   end Emit_Readline_Start;

   procedure Emit_Readline_End (Success : out Boolean) is
      S : Boolean;
   begin
      -- Standard 2048 bounded read tae prevent buffer overflows!
      Append ("), 2048, stdin);", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Readline_End;

   procedure Emit_Cut_Operator (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      -- Sets the internal logic sever flag for the engine's backtracking loop
      Append ("ALB_Logic_Cut = 1; /* DA PROLOG CUT TRIGGER */", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Cut_Operator;

   -- =========================================================================
   -- DA NEW STEP LOOP HOOKS IMPLEMENTATION
   -- =========================================================================
   procedure Emit_Loop_Step_Mid (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("; " & Current_For_Iterator (1 .. Current_For_Len) & " += ", S);
      Success := S;
   end Emit_Loop_Step_Mid;

   procedure Emit_Loop_Step_End (Success : out Boolean) is
      S : Boolean;
   begin
      Append (") {", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Loop_Step_End;
   
   -- =========================================================================
   -- DA MULTI-CORE DISPATCH FORGE IMPLEMENTATION
   -- =========================================================================
   procedure Emit_Spawn_Start (Func_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_Dispatch_Task((ALB_Task_Func)" & Func_Name & "_func", S);
      Success := S;
   end Emit_Spawn_Start;

   procedure Emit_Spawn_End (Success : out Boolean) is
      S : Boolean;
   begin
      Append (");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Spawn_End;

   procedure Emit_Sync (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_Sync_Tasks();", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Sync;

   procedure Emit_Atomic_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_Atomic_Lock();", S);
      Emit_Newline (S);
      Append ("{", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Atomic_Start;

   procedure Emit_Atomic_End (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("}", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("ALB_Atomic_Unlock();", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Atomic_End;

   procedure Emit_Reversible_Block_Start (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("/* ALB REVERSIBLE BEGIN */", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Reversible_Block_Start;

   procedure Emit_Reversible_Block_End (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("/* ALB REVERSIBLE END */", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Reversible_Block_End;

   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append
        (Target_Name & " = " &
         C_Reversible_Assign_Expr
           (Target_Tag,
            C_Reversible_Current_Expr (Target_Name, Target_Tag) & " + ALB_REV_Tmp") &
         ";",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Add;

   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append
        (Target_Name & " = " &
         C_Reversible_Assign_Expr
           (Target_Tag,
            C_Reversible_Current_Expr (Target_Name, Target_Tag) & " - ALB_REV_Tmp") &
         ";",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Sub;

   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      pragma Unreferenced (Target_Tag);
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append (Target_Name & " ^= ALB_REV_Tmp;", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Xor;

   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S     : Boolean := True;
      Width : constant Natural := C_Reversible_Width_Bits (Target_Tag);
   begin
      Emit_Indent (S);
      Append
        (Target_Name & " = " &
         C_Reversible_Assign_Expr
           (Target_Tag,
            "ALB_Rol_U64(" &
            C_Reversible_Current_Expr (Target_Name, Target_Tag) &
            ", ALB_REV_Tmp, " &
            Trim_Image (Natural'Image (Width)) &
            ")") &
         ";",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Rol;

   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S     : Boolean := True;
      Width : constant Natural := C_Reversible_Width_Bits (Target_Tag);
   begin
      Emit_Indent (S);
      Append
        (Target_Name & " = " &
         C_Reversible_Assign_Expr
           (Target_Tag,
            "ALB_Ror_U64(" &
            C_Reversible_Current_Expr (Target_Name, Target_Tag) &
            ", ALB_REV_Tmp, " &
            Trim_Image (Natural'Image (Width)) &
            ")") &
         ";",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Ror;

   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("ALB_REV_Tmp = " & C_Reversible_Current_Expr (Left_Name, Left_Tag) & ";", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("ALB_REV_Tmp2 = " & C_Reversible_Current_Expr (Right_Name, Right_Tag) & ";", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append
        (Left_Name & " = " &
         C_Reversible_Assign_Expr (Left_Tag, "ALB_REV_Tmp2") &
         ";",
         S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append
        (Right_Name & " = " &
         C_Reversible_Assign_Expr (Right_Tag, "ALB_REV_Tmp") &
         ";",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Swap;

   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append
        (Target_Name & " = " &
         C_Reversible_Assign_Expr
           (Target_Tag,
            "(~" & C_Reversible_Current_Expr (Target_Name, Target_Tag) & ")") &
         ";",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Not;

   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append
        (Target_Name & " = " &
         C_Reversible_Assign_Expr
           (Target_Tag,
            "((uint64_t)0 - " &
            C_Reversible_Current_Expr (Target_Name, Target_Tag) &
            ")") &
         ";",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Rev_Neg;
   

   -- =========================================================================
   -- DA DUMPTRUCK EMITTERS (Garbage Collection & Object Pools)
   -- =========================================================================
   procedure Emit_Claim (Var_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      -- We pass the address so the C runtime can assign the Node_ID to the var
      Append ("ALB_GC_Claim(&" & Var_Name & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Claim;

   procedure Emit_Drop (Var_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_GC_Drop(" & Var_Name & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Drop;

   procedure Emit_Sweep (Chunk_Expr : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("ALB_GC_Sweep(" & Chunk_Expr & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Sweep;

   procedure Emit_Bind (Parent_Var : String; Child1_Expr : String; Child2_Expr : String; Success : out Boolean) is
      S : Boolean;
      -- If a bairn is empty, we default to 0 (Nae Bairn in dy architecture)
      C1 : constant String := (if Child1_Expr = "" then "0" else Child1_Expr);
      C2 : constant String := (if Child2_Expr = "" then "0" else Child2_Expr);
   begin
      Emit_Indent (S);
      Append ("ALB_GC_Bind(" & Parent_Var & ", " & C1 & ", " & C2 & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Bind;
   
   procedure Emit_Clear_Color (Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("ALB_Set_Clear_Color(" & Color & ");", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Clear_Color;

end Emit_Native_C;
