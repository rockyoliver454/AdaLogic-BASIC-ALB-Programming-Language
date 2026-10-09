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

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories; use type Ada.Directories.File_Kind;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams; use type Ada.Streams.Stream_Element_Offset;
with Ada.Streams.Stream_IO;
with GNAT.OS_Lib;

with Compiler_State;  use Compiler_State;
with Tokenizer;       use Tokenizer;
with Parser;          use Parser;
with AST;             use AST;
with Interpreter;     use Interpreter;
with ALB_Oracle;      use ALB_Oracle;
with ALB_Types;       use ALB_Types;
with Numerus_Magnus;  use Numerus_Magnus;
with Opcodes;         use Opcodes;
with memory_allocator;
with Transpiler_Native_HAL; use Transpiler_Native_HAL;
with Emit_Native_Java;
with Alb_MSVC;
with ALB_System_Includes;


procedure ALBJ is

   Input_Len     : Natural := 0;
   Token_Count   : Natural := 0;
   Root          : Node_Index := 0;
   Parse_Success : Boolean := False;
   Emit_Success  : Boolean := False;
   Mem_Success   : Boolean := False;

   Lex_Diag   : Lexer_Diagnostic;
   Parse_Diag : Parser_Diagnostic;

   Input_File  : String (1 .. 256) := (others => ' ');
   Input_Flen  : Natural := 0;
   Output_File : String (1 .. 256) := (others => ' ');
   Output_Flen : Natural := 0;
   Out_Dir     : String (1 .. 256) := (others => ' ');
   Out_Dir_Len : Natural := 0;
   Final_Dir   : String (1 .. 256) := (others => ' ');
   Final_Dir_Len : Natural := 0;
   Build_Mode  : Boolean := False;
   Run_Mode    : Boolean := False;
   Arg_Error   : Boolean := False;

   Max_Includes : constant := 2048;
   Max_Path_Len : constant := 512;

   subtype Include_Path is String (1 .. Max_Path_Len);
   Include_Vault : array (1 .. Max_Includes) of Include_Path :=
     (others => (others => ' '));
   Include_Lens  : array (1 .. Max_Includes) of Natural := (others => 0);
   Include_Count : Natural := 0;

   Max_Absolute_Lines : constant := 131072;
   type Source_Map_Record is record
      File_ID  : Natural := 1;
      Rel_Line : Positive := 1;
   end record;
   Source_Map : array (1 .. Max_Absolute_Lines) of Source_Map_Record :=
     (others => (File_ID => 1, Rel_Line => 1));
   Abs_Line_Count : Natural := 1;

   type Compiler_Diagnostic is record
      Success     : Boolean := True;
      Error_Line  : Positive := 1;
      Error_Col   : Positive := 1;
      Code        : Oracle_Code := Err_None;
      Culprit     : String (1 .. 64) := (others => ' ');
      Culprit_Len : Natural := 0;
   end record;

   Emit_Diag : Compiler_Diagnostic;

   type Java_Dim_Array is array (1 .. 4) of Natural;

   type Java_Storage_Kind is
     (Storage_Scalar,
      Storage_Array,
      Storage_Parallel_Group,
      Storage_Parallel_Field);

   Max_Java_Symbols : constant := 4096;
   type Java_Symbol_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. 64) := (others => ' ');
      Name_Len : Natural := 0;
      Tag      : ALB_Type_Tag := Type_None;
      Storage  : Java_Storage_Kind := Storage_Scalar;
      Rank     : Natural range 0 .. 4 := 0;
      Dims     : Java_Dim_Array := (others => 0);
      Spilled  : Boolean := False;
      VAS_Offset : Natural := 0;
      VAS_Size_Bytes : Natural := 0;
      Struct_Name : String (1 .. 64) := (others => ' ');
      Struct_Name_Len : Natural := 0;
   end record;
   Java_Symbols : array (1 .. Max_Java_Symbols) of Java_Symbol_Record :=
     (others =>
        (Active   => False,
         Name     => (others => ' '),
         Name_Len => 0,
         Tag      => Type_None,
         Storage  => Storage_Scalar,
         Rank     => 0,
         Dims     => (others => 0),
         Spilled  => False,
        VAS_Offset => 0,
        VAS_Size_Bytes => 0,
        Struct_Name => (others => ' '),
        Struct_Name_Len => 0));
   Java_Symbol_Count : Natural := 0;

   Max_Type_Aliases : constant := 256;
   type Type_Alias_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. 64) := (others => ' ');
      Name_Len : Natural := 0;
      Tag      : ALB_Type_Tag := Type_None;
   end record;
   Type_Aliases : array (1 .. Max_Type_Aliases) of Type_Alias_Record :=
     (others =>
        (Active   => False,
         Name     => (others => ' '),
         Name_Len => 0,
         Tag      => Type_None));
   Type_Alias_Count : Natural := 0;

   Max_Consts : constant := 512;
   type Const_Record is record
      Active    : Boolean := False;
      Name      : String (1 .. 64) := (others => ' ');
      Name_Len  : Natural := 0;
      Value     : String (1 .. 128) := (others => ' ');
      Value_Len : Natural := 0;
   end record;
   Consts : array (1 .. Max_Consts) of Const_Record :=
     (others =>
        (Active    => False,
         Name      => (others => ' '),
         Name_Len  => 0,
         Value     => (others => ' '),
         Value_Len => 0));
   Const_Count : Natural := 0;

   Max_Parallel_Fields : constant := 512;
   type Parallel_Field_Record is record
      Active           : Boolean := False;
      Group_Name       : String (1 .. 64) := (others => ' ');
      Group_Name_Len   : Natural := 0;
      Field_Name       : String (1 .. 64) := (others => ' ');
      Field_Name_Len   : Natural := 0;
      Backing_Name     : String (1 .. 64) := (others => ' ');
      Backing_Name_Len : Natural := 0;
      Tag              : ALB_Type_Tag := Type_None;
   end record;
   Parallel_Fields : array (1 .. Max_Parallel_Fields) of Parallel_Field_Record :=
     (others =>
        (Active           => False,
         Group_Name       => (others => ' '),
         Group_Name_Len   => 0,
         Field_Name       => (others => ' '),
         Field_Name_Len   => 0,
         Backing_Name     => (others => ' '),
         Backing_Name_Len => 0,
         Tag              => Type_None));
   Parallel_Field_Count : Natural := 0;

   Max_Struct_Fields : constant := 512;
   type Struct_Field_Record is record
      Active           : Boolean := False;
      Struct_Name      : String (1 .. 64) := (others => ' ');
      Struct_Name_Len  : Natural := 0;
      Field_Name       : String (1 .. 64) := (others => ' ');
      Field_Name_Len   : Natural := 0;
      Tag              : ALB_Type_Tag := Type_None;
      Offset_Bytes     : Natural := 0;
   end record;
   Struct_Fields : array (1 .. Max_Struct_Fields) of Struct_Field_Record :=
     (others =>
        (Active          => False,
         Struct_Name     => (others => ' '),
         Struct_Name_Len => 0,
         Field_Name      => (others => ' '),
         Field_Name_Len  => 0,
         Tag             => Type_None,
         Offset_Bytes    => 0));
   Struct_Field_Count : Natural := 0;

   Max_Emitted_Routines : constant := 512;
   type Routine_Record is record
      Active        : Boolean := False;
      Java_Name     : String (1 .. 128) := (others => ' ');
      Java_Name_Len : Natural := 0;
   end record;
   Emitted_Routines : array (1 .. Max_Emitted_Routines) of Routine_Record :=
     (others =>
        (Active        => False,
         Java_Name     => (others => ' '),
         Java_Name_Len => 0));
   Emitted_Routine_Count : Natural := 0;

   Max_Advanced_Nodes : constant := 128;
   type Named_Node_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. 64) := (others => ' ');
      Name_Len : Natural := 0;
      Node     : Node_Index := 0;
   end record;
   Network_Sockets : array (1 .. Max_Advanced_Nodes) of Named_Node_Record :=
     (others =>
        (Active   => False,
         Name     => (others => ' '),
         Name_Len => 0,
         Node     => 0));
   Network_Socket_Count : Natural := 0;

   Max_Knows_Change_Hooks : constant := 256;
   type Knows_Change_Hook_Record is record
      Active             : Boolean := False;
      Predicate_Name     : String (1 .. 64) := (others => ' ');
      Predicate_Name_Len : Natural := 0;
      Method_Name        : String (1 .. 128) := (others => ' ');
      Method_Name_Len    : Natural := 0;
   end record;
   Knows_Change_Hooks : array (1 .. Max_Knows_Change_Hooks) of Knows_Change_Hook_Record :=
     (others =>
        (Active             => False,
         Predicate_Name     => (others => ' '),
         Predicate_Name_Len => 0,
         Method_Name        => (others => ' '),
         Method_Name_Len    => 0));
   Knows_Change_Hook_Count : Natural := 0;

   Max_Local_Symbols : constant := 256;
   type Local_Symbol_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. 64) := (others => ' ');
      Name_Len : Natural := 0;
      Tag      : ALB_Type_Tag := Type_None;
      Is_Out   : Boolean := False;
      Spilled  : Boolean := False;
      Frame_Offset : Natural := 0;
      VAS_Size_Bytes : Natural := 0;
      Struct_Name : String (1 .. 64) := (others => ' ');
      Struct_Name_Len : Natural := 0;
   end record;
   Local_Symbols : array (1 .. Max_Local_Symbols) of Local_Symbol_Record :=
     (others =>
        (Active   => False,
         Name     => (others => ' '),
         Name_Len => 0,
         Tag      => Type_None,
         Is_Out   => False,
         Spilled  => False,
         Frame_Offset => 0,
         VAS_Size_Bytes => 0,
         Struct_Name => (others => ' '),
         Struct_Name_Len => 0));
   Local_Symbol_Count : Natural := 0;

   Max_Temporal_Symbols : constant := 256;
   type Temporal_Symbol_Record is record
      Active       : Boolean := False;
      Name         : String (1 .. 64) := (others => ' ');
      Name_Len     : Natural := 0;
      Tag          : ALB_Type_Tag := Type_None;
      History_Size : Natural := 0;
      Current_Offset : Natural := 0;
      Timeline_Offset : Natural := 0;
      Slot_Size_Bytes : Natural := 0;
   end record;
   Temporal_Symbols : array (1 .. Max_Temporal_Symbols) of Temporal_Symbol_Record :=
     (others =>
        (Active       => False,
         Name         => (others => ' '),
         Name_Len     => 0,
         Tag          => Type_None,
         History_Size => 0,
         Current_Offset => 0,
         Timeline_Offset => 0,
         Slot_Size_Bytes => 0));
   Temporal_Symbol_Count : Natural := 0;

   Max_Struct_Types : constant := 128;
   type Struct_Type_Record is record
      Active     : Boolean := False;
      Name       : String (1 .. 64) := (others => ' ');
      Name_Len   : Natural := 0;
      Size_Bytes : Natural := 0;
   end record;
   Struct_Types : array (1 .. Max_Struct_Types) of Struct_Type_Record :=
     (others =>
        (Active => False,
         Name => (others => ' '),
         Name_Len => 0,
         Size_Bytes => 0));
   Struct_Type_Count : Natural := 0;

   Max_Frame_Plan_Symbols : constant := 256;
   type Frame_Plan_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. 64) := (others => ' ');
      Name_Len : Natural := 0;
      Tag      : ALB_Type_Tag := Type_None;
      Offset_Bytes : Natural := 0;
      VAS_Size_Bytes : Natural := 0;
      Struct_Name : String (1 .. 64) := (others => ' ');
      Struct_Name_Len : Natural := 0;
      Is_Param  : Boolean := False;
   end record;
   Current_Frame_Plan : array (1 .. Max_Frame_Plan_Symbols) of Frame_Plan_Record :=
     (others =>
        (Active => False,
         Name => (others => ' '),
         Name_Len => 0,
         Tag => Type_None,
         Offset_Bytes => 0,
         VAS_Size_Bytes => 0,
         Struct_Name => (others => ' '),
         Struct_Name_Len => 0,
         Is_Param => False));
   Current_Frame_Plan_Count : Natural := 0;

   Max_Routine_Spill_Marks : constant := 256;
   type Spill_Mark_Record is record
      Active   : Boolean := False;
      Name     : String (1 .. 64) := (others => ' ');
      Name_Len : Natural := 0;
   end record;
   Current_Spill_Marks : array (1 .. Max_Routine_Spill_Marks) of Spill_Mark_Record :=
     (others =>
        (Active => False,
         Name => (others => ' '),
         Name_Len => 0));
   Current_Spill_Mark_Count : Natural := 0;
   Current_Frame_Size_Bytes : Natural := 0;
   Current_Frame_Base_Name : String (1 .. 64) := (others => ' ');
   Current_Frame_Base_Len  : Natural := 0;

   VAS_Global_Base : constant Natural := 1;
   VAS_Frame_Reserve_Bytes : constant Natural := 262_144;
   VAS_Global_Next : Natural := VAS_Global_Base;
   VAS_Temporal_Next : Natural := 0;
   VAS_Config_Emitted : Boolean := False;

   Current_Module_Name : String (1 .. 64) := (others => ' ');
   Current_Module_Len  : Natural := 0;
   Local_Scope_Depth   : Natural := 0;
   Declare_Module_Depth : Natural := 0;
   Active_Return_Tag   : ALB_Type_Tag := Type_None;

   function Upper_ASCII (S : String) return String is
      R : String (1 .. S'Length);
      C : Character;
   begin
      for I in S'Range loop
         C := S (I);
         if C >= 'a' and then C <= 'z' then
            R (I - S'First + 1) := Character'Val (Character'Pos (C) - 32);
         else
            R (I - S'First + 1) := C;
         end if;
      end loop;
      return R;
   end Upper_ASCII;

   function Trim_Image (S : String) return String is
      Start_At : Positive := S'First;
   begin
      while Start_At < S'Last and then S (Start_At) = ' ' loop
         Start_At := Start_At + 1;
      end loop;
      return S (Start_At .. S'Last);
   end Trim_Image;

   function Is_Java_Keyword (Name : String) return Boolean is
      U : constant String := Upper_ASCII (Name);
   begin
      return
        U = "ABSTRACT" or else U = "ASSERT" or else U = "BOOLEAN" or else
        U = "BREAK" or else U = "BYTE" or else U = "CASE" or else
        U = "CATCH" or else U = "CHAR" or else U = "CLASS" or else
        U = "CONST" or else U = "CONTINUE" or else U = "DEFAULT" or else
        U = "DO" or else U = "DOUBLE" or else U = "ELSE" or else
        U = "ENUM" or else U = "EXTENDS" or else U = "FINAL" or else
        U = "FINALLY" or else U = "FLOAT" or else U = "FOR" or else
        U = "IF" or else U = "IMPLEMENTS" or else U = "IMPORT" or else
        U = "INT" or else U = "INTERFACE" or else U = "LONG" or else
        U = "NATIVE" or else U = "NEW" or else U = "PACKAGE" or else
        U = "PRIVATE" or else U = "PROTECTED" or else U = "PUBLIC" or else
        U = "RETURN" or else U = "SHORT" or else U = "STATIC" or else
        U = "STRICTFP" or else U = "SUPER" or else U = "SWITCH" or else
        U = "SYNCHRONIZED" or else U = "THIS" or else U = "THROW" or else
        U = "THROWS" or else U = "TRANSIENT" or else U = "TRY" or else
        U = "VOID" or else U = "VOLATILE" or else U = "WHILE";
   end Is_Java_Keyword;

   function Java_Safe_Symbol (Lexeme : String) return String is
      Temp : String (1 .. Lexeme'Length + 4) := (others => '_');
      Len  : Natural := 0;
      C    : Character;
      U    : String (1 .. 1);
   begin
      if Lexeme'Length = 0 then
         return "alb_var";
      end if;

      if Lexeme (Lexeme'First) in '0' .. '9' then
         Len := Len + 1;
         Temp (Len) := '_';
      end if;

      for I in Lexeme'Range loop
         C := Lexeme (I);
         if (C in 'A' .. 'Z') or else (C in 'a' .. 'z') or else
            (C in '0' .. '9') or else C = '_'
         then
            Len := Len + 1;
            Temp (Len) := C;
         else
            Len := Len + 1;
            Temp (Len) := '_';
         end if;
      end loop;

      if Len = 0 then
         return "alb_var";
      end if;

      declare
         Candidate : constant String := Temp (1 .. Len);
      begin
         if Is_Java_Keyword (Candidate) then
            U (1) := '_';
            return Candidate & U;
         else
            return Candidate;
         end if;
      end;
   end Java_Safe_Symbol;

   function Raw_Lexeme (Tok_Idx : Natural) return String is
      Tok : constant Token := Tokens (Tok_Idx);
   begin
      return Input_Buffer (Tok.Start .. Tok.Start + Tok.Length - 1);
   end Raw_Lexeme;

   function Strip_String_Node (Idx : Node_Index) return String is
      Tok : constant Token := Tokens (Tree (Idx).Token_Index);
   begin
      if Tok.Length >= 2 then
         return Input_Buffer (Tok.Start + 1 .. Tok.Start + Tok.Length - 2);
      else
         return "";
      end if;
   end Strip_String_Node;

   function Extract_Java_Block_Body (Block_Text : String) return String is
      Start_At : Natural := Block_Text'First;
      End_At   : Natural := Block_Text'Last;
      Last_Line_Start : Natural := Block_Text'Last;
   begin
      while Start_At <= Block_Text'Last and then Block_Text (Start_At) /= ASCII.LF loop
         Start_At := Start_At + 1;
      end loop;

      if Start_At > Block_Text'Last then
         return "";
      end if;

      Start_At := Start_At + 1;
      Last_Line_Start := Block_Text'Last;
      while Last_Line_Start > Start_At
        and then Block_Text (Last_Line_Start - 1) /= ASCII.LF
      loop
         Last_Line_Start := Last_Line_Start - 1;
      end loop;

      End_At := Last_Line_Start - 1;
      if End_At < Start_At then
         return "";
      end if;

      return Block_Text (Start_At .. End_At);
   end Extract_Java_Block_Body;

   function Type_Tag_From_Name (Name : String) return ALB_Type_Tag is
      U : constant String := Upper_ASCII (Name);
   begin
      if U = "U8" then return Type_U8; end if;
      if U = "U16" then return Type_U16; end if;
      if U = "U32" then return Type_U32; end if;
      if U = "U64" then return Type_U64; end if;
      if U = "U128" then return Type_U128; end if;
      if U = "S8" or else U = "I8" or else U = "INT8" then return Type_S8; end if;
      if U = "S16" or else U = "I16" or else U = "INT16" then return Type_S16; end if;
      if U = "S32" or else U = "I32" or else U = "INT32" then return Type_S32; end if;
      if U = "S64" or else U = "I64" or else U = "INT64" then return Type_S64; end if;
      if U = "S128" then return Type_S128; end if;
      if U = "F32" then return Type_F32; end if;
      if U = "F64" or else U = "REAL" then return Type_F64; end if;
      if U = "F128" then return Type_F128; end if;
      if U = "FLOAT2" or else U = "F32X2" then return Type_F32x2; end if;
      if U = "FLOAT4" or else U = "F32X4" then return Type_F32x4; end if;
      if U = "MAT2" or else U = "MAT2X2" then return Type_Mat2x2; end if;
      if U = "MAT3" or else U = "MAT3X3" then return Type_Mat3x3; end if;
      if U = "MAT4" or else U = "MAT4X4" then return Type_Mat4x4; end if;
      if U = "BOOL" or else U = "BOOLEAN" then return Type_Boolean; end if;
      if U = "CHAR" then return Type_Char; end if;
      if U = "PURE" or else U = "RATIONAL" then return Type_Pure; end if;
      if U = "HW8" then return Type_HW8; end if;
      if U = "HW16" then return Type_HW16; end if;
      if U = "HW32" then return Type_HW32; end if;
      if U = "HW64" then return Type_HW64; end if;
      if U = "STRING" then return Type_Binary; end if;
      for I in 1 .. Type_Alias_Count loop
         if Type_Aliases (I).Active
           and then Type_Aliases (I).Name_Len = U'Length
           and then Upper_ASCII (Type_Aliases (I).Name (1 .. Type_Aliases (I).Name_Len)) = U
         then
            return Type_Aliases (I).Tag;
         end if;
      end loop;
      return Type_None;
   end Type_Tag_From_Name;

   function Java_Primitive_Type (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 =>
            return "int";
         when Type_S8 | Type_Boolean | Type_HW8 =>
            return "byte";
         when Type_U16 =>
            return "int";
         when Type_S16 | Type_HW16 =>
            return "short";
         when Type_U32 =>
            return "long";
         when Type_S32 | Type_HW32 | Type_Reference =>
            return "int";
         when Type_U64 | Type_S64 | Type_HW64 =>
            return "long";
         when Type_F32 =>
            return "float";
         when Type_F32x2 | Type_F32x4 | Type_U32x4 | Type_S32x4 |
              Type_Mat2x2 | Type_Mat3x3 | Type_Mat4x4 =>
            return "float[]";
         when Type_F64 | Type_F128 =>
            return "double";
         when Type_Binary | Type_Char =>
            return "int";
         when Type_Pure | Type_U128 | Type_S128 =>
            return "long[]";
         when others =>
            return "long";
      end case;
   end Java_Primitive_Type;

   function Java_Global_Array_Type (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_Binary | Type_Char =>
            return "int";
         when Type_Pure | Type_U128 | Type_S128 =>
            return "long";
         when Type_F32x2 | Type_F32x4 | Type_U32x4 | Type_S32x4 |
              Type_Mat2x2 | Type_Mat3x3 | Type_Mat4x4 =>
            return "float[]";
         when others =>
            return Java_Primitive_Type (Tag);
      end case;
   end Java_Global_Array_Type;

   function Java_Slot_Count (Tag : ALB_Type_Tag) return Positive is
   begin
      case Tag is
         when Type_Pure | Type_U128 | Type_S128 =>
            return 2;

         when Type_F32x2 =>
            return 2;

         when Type_F32x4 | Type_U32x4 | Type_S32x4 | Type_Mat2x2 =>
            return 4;

         when Type_Mat3x3 =>
            return 9;

         when Type_Mat4x4 =>
            return 16;

         when others =>
            return 1;
      end case;
   end Java_Slot_Count;

   function Java_Local_Default_Init (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 =>
            return "0";
         when Type_S8 | Type_Boolean | Type_HW8 =>
            return "(byte)0";
         when Type_U16 =>
            return "0";
         when Type_S16 | Type_HW16 =>
            return "(short)0";
         when Type_U32 =>
            return "0L";
         when Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char =>
            return "0";
         when Type_U64 | Type_S64 | Type_HW64 =>
            return "0L";
         when Type_F32 =>
            return "0.0f";
         when Type_F32x2 =>
            return "new float[2]";
         when Type_F32x4 | Type_U32x4 | Type_S32x4 =>
            return "new float[4]";
         when Type_Mat2x2 =>
            return "new float[4]";
         when Type_Mat3x3 =>
            return "new float[9]";
         when Type_Mat4x4 =>
            return "new float[16]";
         when Type_F64 | Type_F128 =>
            return "0.0d";
         when Type_Pure | Type_U128 | Type_S128 =>
            return "new long[2]";
         when others =>
            return "0L";
      end case;
   end Java_Local_Default_Init;

   function Java_Default_Return_Expr (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 =>
            return "0";
         when Type_S8 | Type_Boolean | Type_HW8 =>
            return "(byte)0";
         when Type_U16 =>
            return "0";
         when Type_S16 | Type_HW16 =>
            return "(short)0";
         when Type_U32 =>
            return "0L";
         when Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char =>
            return "0";
         when Type_U64 | Type_S64 | Type_HW64 =>
            return "0L";
         when Type_F32 =>
            return "0.0f";
         when Type_F32x2 =>
            return "new float[2]";
         when Type_F32x4 | Type_U32x4 | Type_S32x4 =>
            return "new float[4]";
         when Type_Mat2x2 =>
            return "new float[4]";
         when Type_Mat3x3 =>
            return "new float[9]";
         when Type_Mat4x4 =>
            return "new float[16]";
         when Type_F64 | Type_F128 =>
            return "0.0d";
         when Type_Pure | Type_U128 | Type_S128 =>
            return "ALB_PURE_ZERO";
         when others =>
            return "0L";
      end case;
   end Java_Default_Return_Expr;

   function Type_Size_Bytes (Tag : ALB_Type_Tag) return Natural is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 =>
            return 1;
         when Type_U16 | Type_S16 | Type_HW16 =>
            return 2;
         when Type_U32 | Type_S32 | Type_HW32 | Type_F32 |
              Type_Reference | Type_Binary | Type_Char =>
            return 4;
         when Type_U64 | Type_S64 | Type_HW64 | Type_F64 | Type_F128 =>
            return 8;
         when Type_Pure | Type_U128 | Type_S128 =>
            return 16;
         when Type_F32x2 =>
            return 8;
         when Type_F32x4 | Type_U32x4 | Type_S32x4 | Type_Mat2x2 =>
            return 16;
         when Type_Mat3x3 =>
            return 36;
         when Type_Mat4x4 =>
            return 64;
         when others =>
            return 8;
      end case;
   end Type_Size_Bytes;

   function Align_To
     (Value     : Natural;
      Alignment : Natural) return Natural is
   begin
      if Alignment <= 1 then
         return Value;
      elsif Value mod Alignment = 0 then
         return Value;
      else
         return Value + (Alignment - (Value mod Alignment));
      end if;
   end Align_To;

   function Tag_Align_Bytes (Tag : ALB_Type_Tag) return Natural is
      Size : constant Natural := Type_Size_Bytes (Tag);
   begin
      if Size >= 8 then
         return 8;
      elsif Size >= 4 then
         return 4;
      elsif Size >= 2 then
         return 2;
      else
         return 1;
      end if;
   end Tag_Align_Bytes;

   function Find_Struct_Type (Name : String) return Natural is
   begin
      for I in 1 .. Struct_Type_Count loop
         if Struct_Types (I).Active
           and then Struct_Types (I).Name_Len = Name'Length
           and then Struct_Types (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Struct_Type;

   procedure Register_Struct_Type
     (Name       : String;
      Size_Bytes : Natural) is
      Idx : Natural := Find_Struct_Type (Name);
   begin
      if Idx = 0 then
         if Struct_Type_Count >= Max_Struct_Types or else Name'Length > 64 then
            return;
         end if;

         Struct_Type_Count := Struct_Type_Count + 1;
         Idx := Struct_Type_Count;
         Struct_Types (Idx).Active := True;
         Struct_Types (Idx).Name_Len := Name'Length;
         Struct_Types (Idx).Name (1 .. Name'Length) := Name;
      end if;

      Struct_Types (Idx).Size_Bytes := Size_Bytes;
   end Register_Struct_Type;

   function Struct_Size_Bytes_By_Name (Name : String) return Natural is
      Idx : constant Natural := Find_Struct_Type (Name);
   begin
      if Idx = 0 then
         return 0;
      end if;
      return Struct_Types (Idx).Size_Bytes;
   end Struct_Size_Bytes_By_Name;

   function Allocate_Global_VAS
     (Size_Bytes : Natural;
      Align_Bytes : Natural) return Natural is
      Offset : Natural := Align_To (VAS_Global_Next, Align_Bytes);
   begin
      VAS_Global_Next := Offset + Size_Bytes;
      return Offset;
   end Allocate_Global_VAS;

   function Allocate_Temporal_VAS
     (Size_Bytes : Natural;
      Align_Bytes : Natural) return Natural is
      Offset : Natural := Align_To (VAS_Temporal_Next, Align_Bytes);
   begin
      VAS_Temporal_Next := Offset + Size_Bytes;
      return Offset;
   end Allocate_Temporal_VAS;

   procedure Register_Type_Alias
     (Name : String;
      Tag  : ALB_Type_Tag) is
   begin
      if Type_Alias_Count < Max_Type_Aliases and then Name'Length <= 64 then
         Type_Alias_Count := Type_Alias_Count + 1;
         Type_Aliases (Type_Alias_Count).Active := True;
         Type_Aliases (Type_Alias_Count).Name_Len := Name'Length;
         Type_Aliases (Type_Alias_Count).Name (1 .. Name'Length) := Name;
         Type_Aliases (Type_Alias_Count).Tag := Tag;
      end if;
   end Register_Type_Alias;

   function Is_Already_Included (File_Name : String) return Boolean is
      Check_Len : constant Natural := File_Name'Length;
   begin
      for I in 1 .. Include_Count loop
         if Include_Lens (I) = Check_Len and then
            Include_Vault (I) (1 .. Check_Len) = File_Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Already_Included;

   procedure Register_Include
     (File_Name : String;
      Success   : in out Boolean;
      ID        : out Natural) is
   begin
      if Include_Count < Max_Includes and then File_Name'Length <= Max_Path_Len then
         Include_Count := Include_Count + 1;
         Include_Lens (Include_Count) := File_Name'Length;
         Include_Vault (Include_Count) (1 .. File_Name'Length) := File_Name;
         ID := Include_Count;
      else
         Put_Line ("FATAL: Could not register include path: " & File_Name);
         Success := False;
         ID := 0;
      end if;
   end Register_Include;

   function Is_Absolute_Path (Path : String) return Boolean;

   procedure Append_Source_Line
     (Line_Text : String;
      Line_Len  : Natural;
      File_ID   : Natural;
      Rel_Line  : Positive;
      Success   : in out Boolean) is
   begin
      if not Success then
         return;
      end if;

      if Abs_Line_Count <= Max_Absolute_Lines then
         Source_Map (Abs_Line_Count) := (File_ID => File_ID, Rel_Line => Rel_Line);
      end if;

      if Input_Len + Line_Len + 1 > Input_Buffer'Length then
         Success := False;
         return;
      end if;

      if Line_Len > 0 then
         Input_Buffer (Input_Len + 1 .. Input_Len + Line_Len) :=
           Line_Text (Line_Text'First .. Line_Text'First + Line_Len - 1);
         Input_Len := Input_Len + Line_Len;
      end if;

      Input_Len := Input_Len + 1;
      Input_Buffer (Input_Len) := ASCII.LF;

      if Abs_Line_Count < Max_Absolute_Lines then
         Abs_Line_Count := Abs_Line_Count + 1;
      end if;
   end Append_Source_Line;

   procedure Parse_Include_Line
     (Line_Text : String;
      Line_Len  : Natural;
      Match     : out Boolean;
      Is_System : out Boolean;
      File_Name : out String;
      File_Len  : out Natural) is
      I     : Natural := 1;
      Start : Natural := 0;
      Stop  : Natural := 0;
   begin
      Match := False;
      Is_System := False;
      File_Len := 0;
      File_Name := (others => ' ');

      while I <= Line_Len and then Line_Text (I) = ' ' loop
         I := I + 1;
      end loop;

      if I + 6 > Line_Len then
         return;
      end if;

      if Upper_ASCII (Line_Text (I .. I + 6)) /= "INCLUDE" then
         return;
      end if;

      I := I + 7;
      while I <= Line_Len and then Line_Text (I) = ' ' loop
         I := I + 1;
      end loop;

      if I > Line_Len then
         return;
      end if;

      if Line_Text (I) = '"' then
         Is_System := False;
         Start := I + 1;
         Stop := Start;
         while Stop <= Line_Len and then Line_Text (Stop) /= '"' loop
            Stop := Stop + 1;
         end loop;

         if Stop <= Line_Len and then Stop > Start then
            File_Len := Stop - Start;
            if File_Len <= File_Name'Length then
               File_Name (File_Name'First .. File_Name'First + File_Len - 1) :=
                 Line_Text (Start .. Stop - 1);
               Match := True;
            end if;
         end if;
      elsif Line_Text (I) = '<' then
         Is_System := True;
         Start := I + 1;
         Stop := Start;
         while Stop <= Line_Len
           and then Line_Text (Stop) /= '>'
           and then Line_Text (Stop) /= ASCII.LF
         loop
            Stop := Stop + 1;
         end loop;

         if Stop <= Line_Len
           and then Line_Text (Stop) = '>'
           and then Stop > Start
         then
            File_Len := Stop - Start;
            if File_Len <= File_Name'Length then
               File_Name (File_Name'First .. File_Name'First + File_Len - 1) :=
                 Line_Text (Start .. Stop - 1);
               Match := True;
            end if;
         end if;
      end if;
   end Parse_Include_Line;

   procedure Process_File_Weave
     (F_Name  : String;
      Success : in out Boolean) is
      File       : Ada.Streams.Stream_IO.File_Type;
      Stream_Ptr : Ada.Streams.Stream_IO.Stream_Access;
      Ch         : Character;
      File_ID    : Natural := 0;
      File_Dir   : constant String := Ada.Directories.Containing_Directory (F_Name);
      Rel_Line   : Positive := 1;
      Line_Buffer : String (1 .. 1024) := (others => ' ');
      Line_Len    : Natural := 0;
      function Compose_Include_Path
        (Dir  : String;
         Leaf : String) return String
      is
      begin
         if Dir'Length = 0 then
            return Leaf;
         elsif Leaf'Length = 0 then
            return Dir;
         elsif Is_Absolute_Path (Leaf) then
            return Leaf;
         end if;

         for I in Leaf'Range loop
            if Leaf (I) = '\' or else Leaf (I) = '/' then
               if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
                  return Dir & Leaf;
               else
                  return Dir & "\" & Leaf;
               end if;
            end if;
         end loop;

         return Ada.Directories.Compose (Dir, Leaf);
      end Compose_Include_Path;

      procedure Flush_Line is
         Include_Match : Boolean := False;
         Include_System : Boolean := False;
         Include_Name  : String (1 .. Max_Path_Len) := (others => ' ');
         Include_Len   : Natural := 0;
      begin
         Parse_Include_Line
           (Line_Buffer,
            Line_Len,
            Include_Match,
            Include_System,
            Include_Name,
            Include_Len);

         if Include_Match then
            if Include_System then
               declare
                  Leaf : constant String := Include_Name (1 .. Include_Len);
                  Resolved_Include : constant String :=
                    ALB_System_Includes.Resolve_System_Include (Leaf);
               begin
                  if not Ada.Directories.Exists (Resolved_Include) then
                     Put_Line
                       ("FATAL: System include not found: <" &
                        Leaf &
                        "> (searched under " &
                        ALB_System_Includes.Vendor_Root &
                        ")");
                     Success := False;
                  else
                     Process_File_Weave (Resolved_Include, Success);
                  end if;
               end;
            else
               declare
                  Resolved_Include : constant String :=
                     (if Is_Absolute_Path (Include_Name (1 .. Include_Len))
                         or else File_Dir'Length = 0
                      then Include_Name (1 .. Include_Len)
                      else Compose_Include_Path
                        (File_Dir, Include_Name (1 .. Include_Len)));
               begin
                  Process_File_Weave (Resolved_Include, Success);
               end;
            end if;
         else
            Append_Source_Line (Line_Buffer, Line_Len, File_ID, Rel_Line, Success);
         end if;

         Rel_Line := Rel_Line + 1;
         Line_Len := 0;
      end Flush_Line;
   begin
      if not Success then
         return;
      end if;

      if Is_Already_Included (F_Name) then
         return;
      end if;

      Register_Include (F_Name, Success, File_ID);
      if not Success then
         return;
      end if;

      begin
         Ada.Streams.Stream_IO.Open
           (File,
            Ada.Streams.Stream_IO.In_File,
            F_Name);
         Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);

         while not Ada.Streams.Stream_IO.End_Of_File (File) loop
            Character'Read (Stream_Ptr, Ch);

            if Ch = ASCII.CR then
               null;
            elsif Ch = ASCII.LF then
               Flush_Line;
               exit when not Success;
            else
               if Line_Len < Line_Buffer'Length then
                  Line_Len := Line_Len + 1;
                  Line_Buffer (Line_Len) := Ch;
               else
                  Put_Line ("FATAL: Source line exceeded Java weave buffer in " & F_Name);
                  Success := False;
                  exit;
               end if;
            end if;
         end loop;

         if Success and then Line_Len > 0 then
            Flush_Line;
         end if;

         Ada.Streams.Stream_IO.Close (File);
      exception
         when E : others =>
            if Ada.Streams.Stream_IO.Is_Open (File) then
               Ada.Streams.Stream_IO.Close (File);
            end if;
            Put_Line
              ("FATAL: Java weave could not open or read " &
               F_Name &
               ": " &
               Ada.Exceptions.Exception_Message (E));
            Success := False;
      end;
   end Process_File_Weave;

   procedure Parse_Decimal (Str : in String; Val : out U64; Success : out Boolean) is
      Temp       : U64 := 0;
      Negative   : Boolean := False;
      Seen_Sign  : Boolean := False;
      Seen_Digit : Boolean := False;
   begin
      Success := True;

      for I in Str'Range loop
         if Str (I) = '.' then
            exit;
         elsif Str (I) = ' ' or else Str (I) = ASCII.LF or else Str (I) = '_' then
            null;
         elsif Str (I) = '-' and then not Seen_Sign and then not Seen_Digit then
            Negative := True;
            Seen_Sign := True;
         elsif Str (I) = '+' and then not Seen_Sign and then not Seen_Digit then
            Seen_Sign := True;
         elsif Str (I) in '0' .. '9' then
            Seen_Digit := True;
            Temp := Temp * 10 + U64 (Character'Pos (Str (I)) - Character'Pos ('0'));
         else
            Success := False;
            return;
         end if;
      end loop;

      if not Seen_Digit then
         Success := False;
         return;
      end if;

      if Negative then
         Val := 0 - Temp;
      else
         Val := Temp;
      end if;
   end Parse_Decimal;

   function Is_Real_Number_Text (Text : String) return Boolean is
   begin
      for I in Text'Range loop
         if Text (I) = '.' or else Text (I) = 'e' or else Text (I) = 'E' then
            return True;
         end if;
      end loop;
      return False;
   end Is_Real_Number_Text;

   function Hex_Digit (Value : U64) return Character is
      N : constant Natural := Natural (Value);
   begin
      if N < 10 then
         return Character'Val (Character'Pos ('0') + N);
      else
         return Character'Val (Character'Pos ('A') + (N - 10));
      end if;
   end Hex_Digit;

   function U64_Hex_Image (Value : U64) return String is
      Buf   : String (1 .. 16);
      Tmp   : U64 := Value;
      First : Positive := 1;
   begin
      for I in reverse Buf'Range loop
         Buf (I) := Hex_Digit (Tmp mod 16);
         Tmp := Tmp / 16;
      end loop;

      while First < Buf'Last and then Buf (First) = '0' loop
         First := First + 1;
      end loop;

      return Buf (First .. Buf'Last);
   end U64_Hex_Image;

   procedure Parse_Hex (Str : in String; Val : out U64; Success : out Boolean) is
      Temp : U64 := 0;
      C    : Character;
   begin
      Success := True;
      for I in Str'Range loop
         C := Str (I);
         if C = '$' or else C = '_' then
            null;
         elsif C in '0' .. '9' then
            Temp := Temp * 16 + U64 (Character'Pos (C) - Character'Pos ('0'));
         elsif C in 'A' .. 'F' then
            Temp := Temp * 16 + U64 (Character'Pos (C) - Character'Pos ('A') + 10);
         elsif C in 'a' .. 'f' then
            Temp := Temp * 16 + U64 (Character'Pos (C) - Character'Pos ('a') + 10);
         else
            Success := False;
            return;
         end if;
      end loop;
      Val := Temp;
   end Parse_Hex;

   procedure Parse_Octal (Str : in String; Val : out U64; Success : out Boolean) is
      Temp : U64 := 0;
   begin
      Success := True;
      for I in Str'Range loop
         if Str (I) = '&' or else Str (I) = 'O' or else Str (I) = 'o' or else Str (I) = '_' then
            null;
         elsif Str (I) in '0' .. '7' then
            Temp := Temp * 8 + U64 (Character'Pos (Str (I)) - Character'Pos ('0'));
         else
            Success := False;
            return;
         end if;
      end loop;
      Val := Temp;
   end Parse_Octal;

   procedure Parse_Binary (Str : in String; Val : out U64; Success : out Boolean) is
      Temp : U64 := 0;
   begin
      Success := True;
      for I in Str'Range loop
         if Str (I) = '%' or else Str (I) = '_' then
            null;
         elsif Str (I) = '0' then
            Temp := Temp * 2;
         elsif Str (I) = '1' then
            Temp := Temp * 2 + 1;
         else
            Success := False;
            return;
         end if;
      end loop;
      Val := Temp;
   end Parse_Binary;

   function Find_Java_Symbol (Name : String) return Natural is
   begin
      for I in 1 .. Java_Symbol_Count loop
         if Java_Symbols (I).Active
           and then Java_Symbols (I).Name_Len = Name'Length
           and then Java_Symbols (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Java_Symbol;

   function Find_Local_Symbol (Name : String) return Natural is
   begin
      for I in reverse 1 .. Local_Symbol_Count loop
         if Local_Symbols (I).Active
           and then Local_Symbols (I).Name_Len = Name'Length
           and then Local_Symbols (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Local_Symbol;

   function Find_Frame_Plan (Name : String) return Natural is
   begin
      for I in 1 .. Current_Frame_Plan_Count loop
         if Current_Frame_Plan (I).Active
           and then Current_Frame_Plan (I).Name_Len = Name'Length
           and then Current_Frame_Plan (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Frame_Plan;

   function Infer_Type_Tag (Idx : Node_Index) return ALB_Type_Tag;

   procedure Clear_Frame_Plan is
   begin
      Current_Frame_Plan_Count := 0;
      Current_Spill_Mark_Count := 0;
      Current_Frame_Size_Bytes := 0;
      Current_Frame_Base_Name := (others => ' ');
      Current_Frame_Base_Len := 0;

      for I in Current_Frame_Plan'Range loop
         Current_Frame_Plan (I).Active := False;
      end loop;
      for I in Current_Spill_Marks'Range loop
         Current_Spill_Marks (I).Active := False;
      end loop;
   end Clear_Frame_Plan;

   procedure Mark_Current_Spill (Name : String) is
   begin
      if Name'Length = 0 then
         return;
      end if;

      for I in 1 .. Current_Spill_Mark_Count loop
         if Current_Spill_Marks (I).Active
           and then Current_Spill_Marks (I).Name_Len = Name'Length
           and then Current_Spill_Marks (I).Name (1 .. Name'Length) = Name
         then
            return;
         end if;
      end loop;

      if Current_Spill_Mark_Count < Max_Routine_Spill_Marks
        and then Name'Length <= 64
      then
         Current_Spill_Mark_Count := Current_Spill_Mark_Count + 1;
         Current_Spill_Marks (Current_Spill_Mark_Count).Active := True;
         Current_Spill_Marks (Current_Spill_Mark_Count).Name_Len := Name'Length;
         Current_Spill_Marks (Current_Spill_Mark_Count).Name (1 .. Name'Length) := Name;
      end if;
   end Mark_Current_Spill;

   function Current_Spill_Requested (Name : String) return Boolean is
   begin
      for I in 1 .. Current_Spill_Mark_Count loop
         if Current_Spill_Marks (I).Active
           and then Current_Spill_Marks (I).Name_Len = Name'Length
           and then Current_Spill_Marks (I).Name (1 .. Name'Length) = Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Current_Spill_Requested;

   procedure Add_Frame_Plan_Entry
     (Name        : String;
      Tag         : ALB_Type_Tag;
      Size_Bytes  : Natural;
      Struct_Name : String;
      Is_Param    : Boolean) is
      Offset : Natural := 0;
   begin
      if Name'Length = 0 or else Size_Bytes = 0 then
         return;
      end if;

      if Find_Frame_Plan (Name) /= 0 then
         return;
      end if;

      if Current_Frame_Plan_Count >= Max_Frame_Plan_Symbols
        or else Name'Length > 64
        or else Struct_Name'Length > 64
      then
         return;
      end if;

      Offset := Align_To (Current_Frame_Size_Bytes, Tag_Align_Bytes (Tag));
      Current_Frame_Size_Bytes := Offset + Size_Bytes;

      Current_Frame_Plan_Count := Current_Frame_Plan_Count + 1;
      Current_Frame_Plan (Current_Frame_Plan_Count).Active := True;
      Current_Frame_Plan (Current_Frame_Plan_Count).Name_Len := Name'Length;
      Current_Frame_Plan (Current_Frame_Plan_Count).Name (1 .. Name'Length) := Name;
      Current_Frame_Plan (Current_Frame_Plan_Count).Tag := Tag;
      Current_Frame_Plan (Current_Frame_Plan_Count).Offset_Bytes := Offset;
      Current_Frame_Plan (Current_Frame_Plan_Count).VAS_Size_Bytes := Size_Bytes;
      Current_Frame_Plan (Current_Frame_Plan_Count).Struct_Name_Len := Struct_Name'Length;
      if Struct_Name'Length > 0 then
         Current_Frame_Plan (Current_Frame_Plan_Count).Struct_Name
           (1 .. Struct_Name'Length) := Struct_Name;
      end if;
      Current_Frame_Plan (Current_Frame_Plan_Count).Is_Param := Is_Param;
   end Add_Frame_Plan_Entry;

   procedure Analyze_Routine_Frame
     (Decl_Node : Node_Index) is
      Name_Node  : constant Node_Index := Tree (Decl_Node).Left_Child;
      Body_Node  : constant Node_Index := Tree (Decl_Node).Right_Child;
      Param_List : constant Node_Index :=
        (if Name_Node /= 0 then Tree (Name_Node).Right_Child else 0);

      function Local_Name_Of (Node : Node_Index) return String is
      begin
         if Node /= 0 and then Tree (Node).Token_Index > 0 then
            return Java_Safe_Symbol (Raw_Lexeme (Tree (Node).Token_Index));
         end if;
         return "";
      end Local_Name_Of;

      function Struct_Type_Name_Of (Type_Node : Node_Index) return String is
      begin
         if Type_Node /= 0 and then Tree (Type_Node).Token_Index > 0 then
            return Java_Safe_Symbol (Raw_Lexeme (Tree (Type_Node).Token_Index));
         end if;
         return "";
      end Struct_Type_Name_Of;

      procedure Mark_Address_Target (Target_Node : Node_Index) is
      begin
         if Target_Node = 0 then
            return;
         end if;

         case Tree (Target_Node).Kind is
            when AST_Var_Expr =>
               Mark_Current_Spill (Local_Name_Of (Target_Node));

            when AST_Member_Expr =>
               Mark_Address_Target (Tree (Target_Node).Left_Child);

            when others =>
               null;
         end case;
      end Mark_Address_Target;

      procedure Walk_Marks (Node : Node_Index) is
         Curr : Node_Index := Node;
      begin
         while Curr /= 0 loop
            case Tree (Curr).Kind is
               when AST_AddressOf | AST_Ref_Expr =>
                  Mark_Address_Target (Tree (Curr).Left_Child);

               when AST_Procedure_Decl | AST_Function_Decl =>
                  null;

               when others =>
                  Walk_Marks (Tree (Curr).Left_Child);
                  Walk_Marks (Tree (Curr).Right_Child);
            end case;

            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Walk_Marks;

      procedure Walk_Plans (Node : Node_Index) is
         Curr         : Node_Index := Node;
         Struct_Idx   : Natural := 0;
         Final_Tag    : ALB_Type_Tag := Type_None;
         Size_Bytes   : Natural := 0;
      begin
         while Curr /= 0 loop
            case Tree (Curr).Kind is
               when AST_Let_Stmt =>
                  if Tree (Curr).Left_Child /= 0
                    and then Tree (Tree (Curr).Left_Child).Kind = AST_Var_Expr
                  then
                     declare
                        Safe_Name : constant String :=
                          Local_Name_Of (Tree (Curr).Left_Child);
                        Type_Name : constant String :=
                          (if Tree (Curr).Token_Index > 0
                           then Java_Safe_Symbol (Raw_Lexeme (Tree (Curr).Token_Index))
                           else "");
                     begin
                        Struct_Idx := Find_Struct_Type (Type_Name);
                        if Struct_Idx > 0 then
                           Add_Frame_Plan_Entry
                             (Safe_Name,
                              Type_Reference,
                              Struct_Types (Struct_Idx).Size_Bytes,
                              Type_Name,
                              False);
                        elsif Current_Spill_Requested (Safe_Name) then
                           Final_Tag := Type_Tag_From_Name (Type_Name);
                           if Final_Tag = Type_None then
                              Final_Tag := Infer_Type_Tag (Tree (Curr).Right_Child);
                           end if;
                           if Final_Tag = Type_None then
                              Final_Tag := Type_U64;
                           end if;
                           Size_Bytes := Type_Size_Bytes (Final_Tag);
                           Add_Frame_Plan_Entry
                             (Safe_Name,
                              Final_Tag,
                              Size_Bytes,
                              "",
                              False);
                        end if;
                     end;
                  end if;

               when AST_Temporal_Decl =>
                  if Tree (Curr).Left_Child /= 0 then
                     declare
                        Safe_Name : constant String :=
                          Local_Name_Of (Tree (Curr).Left_Child);
                     begin
                        Final_Tag := Type_U64;
                        if Tree (Curr).Token_Index > 0 then
                           Final_Tag := Type_Tag_From_Name (Raw_Lexeme (Tree (Curr).Token_Index));
                        end if;
                        if Final_Tag = Type_None then
                           Final_Tag := Type_U64;
                        end if;
                        Add_Frame_Plan_Entry
                          (Safe_Name,
                           Final_Tag,
                           Type_Size_Bytes (Final_Tag),
                           "",
                           False);
                     end;
                  end if;

               when AST_Procedure_Decl | AST_Function_Decl =>
                  null;

               when others =>
                  Walk_Plans (Tree (Curr).Left_Child);
                  Walk_Plans (Tree (Curr).Right_Child);
            end case;

            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Walk_Plans;

      Param_Curr : Node_Index := 0;
      Param_Struct_Idx : Natural := 0;
      Param_Tag : ALB_Type_Tag := Type_None;
   begin
      Clear_Frame_Plan;

      Walk_Marks (Body_Node);

      if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
         Param_Curr := Tree (Param_List).Left_Child;
      else
         Param_Curr := Param_List;
      end if;

      while Param_Curr /= 0 loop
         if Tree (Param_Curr).Kind = AST_Param_Decl
           and then Tree (Param_Curr).Left_Child /= 0
         then
            declare
               Param_Name : constant String :=
                 Local_Name_Of (Tree (Param_Curr).Left_Child);
               Param_Type_Name : constant String :=
                 Struct_Type_Name_Of (Tree (Param_Curr).Right_Child);
            begin
               Param_Struct_Idx := Find_Struct_Type (Param_Type_Name);
               if Param_Struct_Idx > 0 then
                  Add_Frame_Plan_Entry
                    (Param_Name,
                     Type_Reference,
                     Struct_Types (Param_Struct_Idx).Size_Bytes,
                     Param_Type_Name,
                     True);
               elsif Current_Spill_Requested (Param_Name) then
                  Param_Tag := Type_Tag_From_Name (Param_Type_Name);
                  if Param_Tag = Type_None then
                     Param_Tag := Type_U64;
                  end if;
                  Add_Frame_Plan_Entry
                    (Param_Name,
                     Param_Tag,
                     Type_Size_Bytes (Param_Tag),
                     "",
                     True);
               end if;
            end;
         end if;
         Param_Curr := Tree (Param_Curr).Next_Sibling;
      end loop;

      Walk_Plans (Body_Node);

      if Name_Node /= 0 and then Tree (Name_Node).Token_Index > 0 then
         declare
            Safe_Name : constant String :=
              Java_Safe_Symbol (Raw_Lexeme (Tree (Name_Node).Token_Index));
            Frame_Name : constant String := "alb_frame_" & Safe_Name;
         begin
            Current_Frame_Base_Len :=
              Frame_Name'Length;
            if Current_Frame_Base_Len > Current_Frame_Base_Name'Length then
               Current_Frame_Base_Len := Current_Frame_Base_Name'Length;
            end if;
            Current_Frame_Base_Name (1 .. Current_Frame_Base_Len) :=
              Frame_Name
                (1 .. Current_Frame_Base_Len);
         end;
      else
         Current_Frame_Base_Len := 9;
         Current_Frame_Base_Name (1 .. Current_Frame_Base_Len) := "alb_frame";
      end if;
   end Analyze_Routine_Frame;

   procedure Clear_Local_Symbols is
   begin
      Local_Symbol_Count := 0;
      for I in Local_Symbols'Range loop
         Local_Symbols (I).Active := False;
      end loop;
   end Clear_Local_Symbols;

   procedure Register_Local_Symbol
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Is_Out  : Boolean;
      Success : in out Boolean) is
   begin
      if not Success then
         return;
      end if;

      if Find_Local_Symbol (Name) /= 0 then
         return;
      end if;

      if Local_Symbol_Count >= Max_Local_Symbols or else Name'Length > 64 then
         Success := False;
         return;
      end if;

      Local_Symbol_Count := Local_Symbol_Count + 1;
      Local_Symbols (Local_Symbol_Count).Active := True;
      Local_Symbols (Local_Symbol_Count).Name_Len := Name'Length;
      Local_Symbols (Local_Symbol_Count).Name (1 .. Name'Length) := Name;
      Local_Symbols (Local_Symbol_Count).Tag := Tag;
      Local_Symbols (Local_Symbol_Count).Is_Out := Is_Out;

      declare
         Plan_Idx : constant Natural := Find_Frame_Plan (Name);
      begin
         if Plan_Idx > 0 then
            Local_Symbols (Local_Symbol_Count).Spilled := True;
            Local_Symbols (Local_Symbol_Count).Frame_Offset :=
              Current_Frame_Plan (Plan_Idx).Offset_Bytes;
            Local_Symbols (Local_Symbol_Count).VAS_Size_Bytes :=
              Current_Frame_Plan (Plan_Idx).VAS_Size_Bytes;
            Local_Symbols (Local_Symbol_Count).Struct_Name_Len :=
              Current_Frame_Plan (Plan_Idx).Struct_Name_Len;
            if Current_Frame_Plan (Plan_Idx).Struct_Name_Len > 0 then
               Local_Symbols (Local_Symbol_Count).Struct_Name
                 (1 .. Current_Frame_Plan (Plan_Idx).Struct_Name_Len) :=
                   Current_Frame_Plan (Plan_Idx).Struct_Name
                     (1 .. Current_Frame_Plan (Plan_Idx).Struct_Name_Len);
            end if;
         end if;
      end;
   end Register_Local_Symbol;

   procedure Emit_Local_Symbol_Decl
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : in out Boolean) is
   begin
      if not Success then
         return;
      end if;

      declare
         Plan_Idx : constant Natural := Find_Frame_Plan (Name);
      begin
         if Plan_Idx > 0 then
            return;
         end if;
      end;

      Emit_Native_Java.Emit_Indent (Success);
      if Success then
         Emit_Native_Java.Emit_Raw
           (Java_Primitive_Type (Tag) & " " & Name & " = " &
            Java_Local_Default_Init (Tag) & ";",
            Success);
      end if;
      if Success then
         Emit_Native_Java.Emit_Newline (Success);
      end if;
   end Emit_Local_Symbol_Decl;

   procedure Register_Const
     (Name      : String;
      Value_Text: String) is
      Idx : Natural := 0;
      Stored_Len : Natural := Value_Text'Length;
   begin
      for I in 1 .. Const_Count loop
         if Consts (I).Active
           and then Consts (I).Name_Len = Name'Length
           and then Consts (I).Name (1 .. Name'Length) = Name
         then
            Idx := I;
            exit;
         end if;
      end loop;

      if Idx = 0 then
         if Const_Count >= Max_Consts or else Name'Length > 64 then
            return;
         end if;
         Const_Count := Const_Count + 1;
         Idx := Const_Count;
         Consts (Idx).Active := True;
         Consts (Idx).Name_Len := Name'Length;
         Consts (Idx).Name (1 .. Name'Length) := Name;
      end if;

      if Stored_Len > Consts (Idx).Value'Length then
         Stored_Len := Consts (Idx).Value'Length;
      end if;
      Consts (Idx).Value_Len := Stored_Len;
      if Stored_Len > 0 then
         Consts (Idx).Value (1 .. Stored_Len) :=
           Value_Text (Value_Text'First .. Value_Text'First + Stored_Len - 1);
      end if;

      if Name'Length > 1 and then Name (Name'First) = '#' then
         Register_Const (Name (Name'First + 1 .. Name'Last), Value_Text);
      end if;
   end Register_Const;

   function Find_Const (Name : String) return Natural is
   begin
      for I in 1 .. Const_Count loop
         if Consts (I).Active
           and then Consts (I).Name_Len = Name'Length
           and then Consts (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Const;

   procedure Register_Routine_Name (Java_Name : String) is
   begin
      if Emitted_Routine_Count < Max_Emitted_Routines
        and then Java_Name'Length <= 128
      then
         Emitted_Routine_Count := Emitted_Routine_Count + 1;
         Emitted_Routines (Emitted_Routine_Count).Active := True;
         Emitted_Routines (Emitted_Routine_Count).Java_Name_Len := Java_Name'Length;
         Emitted_Routines (Emitted_Routine_Count).Java_Name (1 .. Java_Name'Length) := Java_Name;
      end if;
   end Register_Routine_Name;

   function Routine_Already_Emitted (Java_Name : String) return Boolean is
   begin
      for I in 1 .. Emitted_Routine_Count loop
         if Emitted_Routines (I).Active
           and then Emitted_Routines (I).Java_Name_Len = Java_Name'Length
           and then Emitted_Routines (I).Java_Name (1 .. Java_Name'Length) = Java_Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Routine_Already_Emitted;

   procedure Register_Knows_Change_Hook
     (Predicate_Name : String;
      Method_Name    : String) is
   begin
      if Predicate_Name'Length = 0 or else Method_Name'Length = 0 then
         return;
      end if;

      for I in 1 .. Knows_Change_Hook_Count loop
         if Knows_Change_Hooks (I).Active
           and then Knows_Change_Hooks (I).Predicate_Name_Len = Predicate_Name'Length
           and then Knows_Change_Hooks (I).Predicate_Name
             (1 .. Predicate_Name'Length) = Predicate_Name
           and then Knows_Change_Hooks (I).Method_Name_Len = Method_Name'Length
           and then Knows_Change_Hooks (I).Method_Name
             (1 .. Method_Name'Length) = Method_Name
         then
            return;
         end if;
      end loop;

      if Knows_Change_Hook_Count < Max_Knows_Change_Hooks
        and then Predicate_Name'Length <= 64
        and then Method_Name'Length <= 128
      then
         Knows_Change_Hook_Count := Knows_Change_Hook_Count + 1;
         Knows_Change_Hooks (Knows_Change_Hook_Count).Active := True;
         Knows_Change_Hooks (Knows_Change_Hook_Count).Predicate_Name_Len :=
           Predicate_Name'Length;
         Knows_Change_Hooks (Knows_Change_Hook_Count).Predicate_Name
           (1 .. Predicate_Name'Length) := Predicate_Name;
         Knows_Change_Hooks (Knows_Change_Hook_Count).Method_Name_Len :=
           Method_Name'Length;
         Knows_Change_Hooks (Knows_Change_Hook_Count).Method_Name
           (1 .. Method_Name'Length) := Method_Name;
      end if;
   end Register_Knows_Change_Hook;

   procedure Emit_Line
     (Text    : String;
      Success : in out Boolean);

   function Qualified_Java_Name (Base_Name : String) return String;
   function Java_Assign_Cast_Prefix (Tag : ALB_Type_Tag) return String;
   function Java_Assign_Cast_Suffix (Tag : ALB_Type_Tag) return String;
   function Predicate_Name_Of (Idx : Node_Index) return String;
   function Predicate_Arg_Node (Idx : Node_Index) return Node_Index;
   procedure Emit_Expression
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean);

   procedure Run_Comptime_Blocks
     (Start_Node : Node_Index;
      Success    : out Boolean) is
      State : Interpreter.Engine_State;

      procedure Walk
        (Idx : Node_Index;
         OK  : in out Boolean) is
         Curr    : Node_Index := Idx;
         Exec_OK : Boolean := True;
      begin
         while Curr /= 0 and then OK loop
            case Tree (Curr).Kind is
               when AST_Comptime_Block =>
                  if Tree (Curr).Left_Child /= 0 then
                     Interpreter.Execute
                       (Input_Buffer (1 .. Input_Len),
                        Tokens,
                        Tree,
                        Tree (Curr).Left_Child,
                        State,
                        Exec_OK,
                        1.0);
                     OK := Exec_OK;
                  end if;

               when AST_Module | AST_DeclareModule =>
                  if Tree (Curr).Right_Child /= 0
                    and then Tree (Tree (Curr).Right_Child).Left_Child /= 0
                  then
                     Walk (Tree (Tree (Curr).Right_Child).Left_Child, OK);
                  end if;

               when others =>
                  null;
            end case;

            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Walk;
   begin
      Success := True;
      Walk (Start_Node, Success);
   end Run_Comptime_Blocks;

   procedure Emit_Import_C_Stub
     (Decl_Node : Node_Index;
      Lib_Node  : Node_Index;
      Is_DLL    : Boolean;
      Success   : in out Boolean) is
      Name_Node     : constant Node_Index := Tree (Decl_Node).Left_Child;
      Saved_Buffer  : constant Emit_Native_Java.Buffer_Target :=
        Emit_Native_Java.Current_Buffer;
      Saved_Indent  : constant Natural := Emit_Native_Java.Indent_Level;
      Java_Name     : constant String :=
        Qualified_Java_Name
          (Java_Safe_Symbol
             (Raw_Lexeme (Tree (Name_Node).Token_Index)));
      Bare_Name     : constant String :=
        Upper_ASCII
          (Java_Safe_Symbol
             (Raw_Lexeme (Tree (Name_Node).Token_Index)));
      Param_List    : Node_Index := Tree (Name_Node).Right_Child;
      Param_Curr    : Node_Index := 0;
      Param_Tag     : ALB_Type_Tag := Type_U64;
      Return_Tag    : ALB_Type_Tag := Type_None;
      First_Param   : String (1 .. 64) := (others => ' ');
      First_Param_Len : Natural := 0;
      Call_Args     : String (1 .. 2048) := (others => ' ');
      Call_Args_Len : Natural := 0;
   begin
      if Decl_Node = 0 or else Name_Node = 0 or else Routine_Already_Emitted (Java_Name) then
         return;
      end if;

      Register_Routine_Name (Java_Name);
      Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Global);
      Emit_Native_Java.Indent_Level := 1;
      Clear_Local_Symbols;

      if Tree (Decl_Node).Kind = AST_Function_Decl then
         if Tree (Decl_Node).Token_Index > 0 then
            Return_Tag := Type_Tag_From_Name (Raw_Lexeme (Tree (Decl_Node).Token_Index));
         else
            Return_Tag := Type_U64;
         end if;
         if Return_Tag = Type_None then
            Return_Tag := Type_U64;
         end if;
      end if;

      Emit_Native_Java.Emit_Indent (Success);
      if Success then
         if Tree (Decl_Node).Kind = AST_Function_Decl then
            Emit_Native_Java.Emit_Raw
              ("private static " & Java_Primitive_Type (Return_Tag) & " " &
               Java_Name & "(",
               Success);
         else
            Emit_Native_Java.Emit_Raw
              ("private static void " & Java_Name & "(",
               Success);
         end if;
      end if;

      if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
         Param_Curr := Tree (Param_List).Left_Child;
      else
         Param_Curr := Param_List;
      end if;

      while Param_Curr /= 0 and then Success and then Tree (Param_Curr).Kind = AST_Param_Decl loop
         Param_Tag := Type_U64;
         if Tree (Param_Curr).Right_Child > 0 then
            Param_Tag :=
              Type_Tag_From_Name
                (Raw_Lexeme (Tree (Tree (Param_Curr).Right_Child).Token_Index));
         end if;
         if Param_Tag = Type_None then
            Param_Tag := Type_U64;
         end if;

         declare
            Param_Name : constant String :=
              Java_Safe_Symbol
                (Raw_Lexeme (Tree (Tree (Param_Curr).Left_Child).Token_Index));
         begin
            if First_Param_Len = 0 and then Param_Name'Length <= First_Param'Length then
               First_Param_Len := Param_Name'Length;
               First_Param (1 .. First_Param_Len) := Param_Name;
            end if;
            declare
               Arg_Text : constant String := "(int)(" & Param_Name & ")";
               Comma_Text : constant String := (if Call_Args_Len > 0 then ", " else "");
            begin
               if Call_Args_Len + Comma_Text'Length + Arg_Text'Length <= Call_Args'Length then
                  Call_Args (Call_Args_Len + 1 .. Call_Args_Len + Comma_Text'Length) := Comma_Text;
                  Call_Args_Len := Call_Args_Len + Comma_Text'Length;
                  Call_Args (Call_Args_Len + 1 .. Call_Args_Len + Arg_Text'Length) := Arg_Text;
                  Call_Args_Len := Call_Args_Len + Arg_Text'Length;
               end if;
            end;
            Emit_Native_Java.Emit_Raw
              (Java_Primitive_Type (Param_Tag) & " " & Param_Name,
               Success);
         end;

         Param_Curr := Tree (Param_Curr).Next_Sibling;
         if Param_Curr /= 0 and then Success then
            Emit_Native_Java.Emit_Raw (", ", Success);
         end if;
      end loop;

      if Success then
         Emit_Native_Java.Emit_Raw (") throws Exception {", Success);
      end if;
      if Success then
         Emit_Native_Java.Emit_Newline (Success);
      end if;
      Emit_Native_Java.Increase_Indent;

      if Success and then Lib_Node /= 0 then
         Emit_Line
           ((if Is_DLL then "// IMPORT_DLL from " else "// IMPORT_C from ") &
            Raw_Lexeme (Tree (Lib_Node).Token_Index),
            Success);
      end if;

      if Is_DLL then
         Emit_Native_Java.Emit_Indent (Success);
         if Tree (Decl_Node).Kind = AST_Function_Decl then
            Emit_Native_Java.Emit_Raw
              ("return " & Java_Assign_Cast_Prefix (Return_Tag) & "ALB_CALL_I32(",
               Success);
         else
            Emit_Native_Java.Emit_Raw ("ALB_CALL_I32(", Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_String_Literal (Strip_String_Node (Lib_Node), Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (", ", Success);
            Emit_Native_Java.Emit_String_Literal (Raw_Lexeme (Tree (Name_Node).Token_Index), Success);
         end if;
         if Call_Args_Len > 0 then
            Emit_Native_Java.Emit_Raw (", " & Call_Args (1 .. Call_Args_Len), Success);
         end if;
         if Tree (Decl_Node).Kind = AST_Function_Decl then
            Emit_Native_Java.Emit_Raw (")" & Java_Assign_Cast_Suffix (Return_Tag) & ";", Success);
         else
            Emit_Native_Java.Emit_Raw (");", Success);
         end if;
         Emit_Native_Java.Emit_Newline (Success);
      elsif Bare_Name = "GETTICKCOUNT" and then Tree (Decl_Node).Kind = AST_Function_Decl then
         Emit_Line
           ("return " & Java_Assign_Cast_Prefix (Return_Tag) &
            "alb_tick_counter[0]" &
            Java_Assign_Cast_Suffix (Return_Tag) & ";",
            Success);
      elsif Bare_Name = "KERNELSLEEP" and then First_Param_Len > 0 then
         Emit_Line
           ("ALB_DELAY((long)(" &
            First_Param (1 .. First_Param_Len) & "));",
            Success);
      elsif Tree (Decl_Node).Kind = AST_Function_Decl then
         Emit_Line ("return " & Java_Default_Return_Expr (Return_Tag) & ";", Success);
      else
         Emit_Line ("return;", Success);
      end if;

      Emit_Native_Java.Decrease_Indent;
      Emit_Native_Java.Indent_Level := 1;
      if Success then
         Emit_Line ("}", Success);
      end if;

      Clear_Local_Symbols;
      Emit_Native_Java.Set_Active_Buffer (Saved_Buffer);
      Emit_Native_Java.Indent_Level := Saved_Indent;
   end Emit_Import_C_Stub;

   procedure Emit_Rule_Registration
     (Idx     : Node_Index;
      Success : in out Boolean) is
      Max_Rule_Vars : constant := 16;
      type Rule_Var_Name_Array is array (1 .. Max_Rule_Vars) of String (1 .. 64);
      Rule_Vars      : Rule_Var_Name_Array := (others => (others => ' '));
      Rule_Var_Lens  : array (1 .. Max_Rule_Vars) of Natural := (others => 0);
      Rule_Var_Count : Natural := 0;
      Head_Node      : constant Node_Index := Tree (Idx).Left_Child;
      Body_Node      : constant Node_Index := Tree (Idx).Right_Child;
      Rule_Name      : constant String :=
        "alb_rule_" & Trim_Image (Integer'Image (Idx));

      function Register_Var (Arg_Node : Node_Index) return Natural is
         Name : constant String := Predicate_Name_Of (Arg_Node);
      begin
         if Arg_Node = 0 or else Tree (Arg_Node).Kind /= AST_Logic_Var then
            return 0;
         end if;

         for I in 1 .. Rule_Var_Count loop
            if Rule_Var_Lens (I) = Name'Length
              and then Rule_Vars (I) (1 .. Name'Length) = Name
            then
               return I;
            end if;
         end loop;

         if Rule_Var_Count < Max_Rule_Vars and then Name'Length <= 64 then
            Rule_Var_Count := Rule_Var_Count + 1;
            Rule_Var_Lens (Rule_Var_Count) := Name'Length;
            Rule_Vars (Rule_Var_Count) (1 .. Name'Length) := Name;
            return Rule_Var_Count;
         end if;

         return 0;
      end Register_Var;

      procedure Scan_Arg (Arg_Node : Node_Index) is
         Dummy_Id : Natural := 0;
      begin
         if Arg_Node /= 0 and then Tree (Arg_Node).Kind = AST_Logic_Var then
            Dummy_Id := Register_Var (Arg_Node);
         end if;
      end Scan_Arg;

      procedure Emit_Arg_Mode_Value
        (Arg_Node : Node_Index;
         Success  : in out Boolean) is
      begin
         if Arg_Node = 0 then
            Emit_Native_Java.Emit_Raw ("0, 0", Success);
         elsif Tree (Arg_Node).Kind = AST_Logic_Var then
            Emit_Native_Java.Emit_Raw
              ("2, " & Trim_Image (Natural'Image (Register_Var (Arg_Node))),
               Success);
         else
            Emit_Native_Java.Emit_Raw ("1, ", Success);
            if Success then
               Emit_Expression (Arg_Node, 1, Success);
            end if;
         end if;
      end Emit_Arg_Mode_Value;

      Body_Curr : Node_Index := 0;
      Arg_Node  : Node_Index := 0;
   begin
      if Head_Node = 0 then
         return;
      end if;

      Scan_Arg (Predicate_Arg_Node (Head_Node));
      if Body_Node /= 0 then
         Body_Curr := Tree (Body_Node).Left_Child;
         while Body_Curr /= 0 loop
            Scan_Arg (Predicate_Arg_Node (Body_Curr));
            Body_Curr := Tree (Body_Curr).Next_Sibling;
         end loop;
      end if;

      Emit_Native_Java.Emit_Indent (Success);
      if Success then
         Emit_Native_Java.Emit_Raw
           ("int " & Rule_Name & " = ALB_RULE_REGISTER(ALB_HASH(",
            Success);
      end if;
      if Success then
         Emit_Native_Java.Emit_String_Literal (Predicate_Name_Of (Head_Node), Success);
      end if;
      if Success then
         Emit_Native_Java.Emit_Raw ("), ", Success);
      end if;
      if Success then
         Emit_Arg_Mode_Value (Predicate_Arg_Node (Head_Node), Success);
      end if;
      if Success then
         Emit_Native_Java.Emit_Raw
           (", " & Trim_Image (Natural'Image (Rule_Var_Count)) & ");",
            Success);
      end if;
      if Success then
         Emit_Native_Java.Emit_Newline (Success);
      end if;

      if Body_Node /= 0 then
         Body_Curr := Tree (Body_Node).Left_Child;
         while Body_Curr /= 0 and then Success loop
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               Emit_Native_Java.Emit_Raw
                 ("ALB_RULE_ADD_TERM(" & Rule_Name & ", ALB_HASH(",
                  Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_String_Literal (Predicate_Name_Of (Body_Curr), Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("), ", Success);
            end if;
            Arg_Node := Predicate_Arg_Node (Body_Curr);
            if Success then
               Emit_Arg_Mode_Value (Arg_Node, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw (");", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;
            Body_Curr := Tree (Body_Curr).Next_Sibling;
         end loop;
      end if;
   end Emit_Rule_Registration;

   procedure Emit_Knows_Change_Dispatcher
     (Success : in out Boolean) is
      Saved_Buffer : constant Emit_Native_Java.Buffer_Target :=
        Emit_Native_Java.Current_Buffer;
      Saved_Indent : constant Natural := Emit_Native_Java.Indent_Level;
   begin
      if not Success then
         return;
      end if;

      Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Global);
      Emit_Native_Java.Indent_Level := 1;

      Emit_Line ("private static void ALB_KB_NOTIFY(int predHash, int changeValue) throws Exception {", Success);
      Emit_Native_Java.Increase_Indent;

      if Knows_Change_Hook_Count = 0 then
         Emit_Line ("return;", Success);
      else
         for I in 1 .. Knows_Change_Hook_Count loop
            exit when not Success;
            if Knows_Change_Hooks (I).Active then
               Emit_Line
                 ("if (predHash == ALB_HASH(""" &
                  Knows_Change_Hooks (I).Predicate_Name
                    (1 .. Knows_Change_Hooks (I).Predicate_Name_Len) &
                  """)) {",
                  Success);
               Emit_Native_Java.Increase_Indent;
               if Success then
                  Emit_Line
                    (Knows_Change_Hooks (I).Method_Name
                       (1 .. Knows_Change_Hooks (I).Method_Name_Len) &
                     "(changeValue);",
                     Success);
               end if;
               Emit_Native_Java.Decrease_Indent;
               if Success then
                  Emit_Line ("}", Success);
               end if;
            end if;
         end loop;
      end if;

      Emit_Native_Java.Decrease_Indent;
      if Success then
         Emit_Line ("}", Success);
      end if;

      Emit_Native_Java.Set_Active_Buffer (Saved_Buffer);
      Emit_Native_Java.Indent_Level := Saved_Indent;
   end Emit_Knows_Change_Dispatcher;

   procedure Register_Parallel_Field
     (Group_Name   : String;
      Field_Name   : String;
      Backing_Name : String;
      Tag          : ALB_Type_Tag) is
   begin
      if Parallel_Field_Count < Max_Parallel_Fields
        and then Group_Name'Length <= 64
        and then Field_Name'Length <= 64
        and then Backing_Name'Length <= 64
      then
         Parallel_Field_Count := Parallel_Field_Count + 1;
         Parallel_Fields (Parallel_Field_Count).Active := True;
         Parallel_Fields (Parallel_Field_Count).Group_Name_Len := Group_Name'Length;
         Parallel_Fields (Parallel_Field_Count).Group_Name (1 .. Group_Name'Length) := Group_Name;
         Parallel_Fields (Parallel_Field_Count).Field_Name_Len := Field_Name'Length;
         Parallel_Fields (Parallel_Field_Count).Field_Name (1 .. Field_Name'Length) := Field_Name;
         Parallel_Fields (Parallel_Field_Count).Backing_Name_Len := Backing_Name'Length;
         Parallel_Fields (Parallel_Field_Count).Backing_Name (1 .. Backing_Name'Length) := Backing_Name;
         Parallel_Fields (Parallel_Field_Count).Tag := Tag;
      end if;
   end Register_Parallel_Field;

   function Find_Parallel_Field
     (Group_Name : String;
      Field_Name : String) return Natural is
   begin
      for I in 1 .. Parallel_Field_Count loop
         if Parallel_Fields (I).Active
           and then Parallel_Fields (I).Group_Name_Len = Group_Name'Length
           and then Parallel_Fields (I).Field_Name_Len = Field_Name'Length
           and then Parallel_Fields (I).Group_Name (1 .. Group_Name'Length) = Group_Name
           and then Parallel_Fields (I).Field_Name (1 .. Field_Name'Length) = Field_Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Parallel_Field;

   procedure Register_Network_Socket
     (Name : String;
      Node : Node_Index) is
   begin
      if Name'Length = 0 or else Name'Length > 64 then
         return;
      end if;

      for I in 1 .. Network_Socket_Count loop
         if Network_Sockets (I).Active
           and then Network_Sockets (I).Name_Len = Name'Length
           and then Network_Sockets (I).Name (1 .. Name'Length) = Name
         then
            Network_Sockets (I).Node := Node;
            return;
         end if;
      end loop;

      if Network_Socket_Count < Max_Advanced_Nodes then
         Network_Socket_Count := Network_Socket_Count + 1;
         Network_Sockets (Network_Socket_Count).Active := True;
         Network_Sockets (Network_Socket_Count).Name_Len := Name'Length;
         Network_Sockets (Network_Socket_Count).Name (1 .. Name'Length) := Name;
         Network_Sockets (Network_Socket_Count).Node := Node;
      end if;
   end Register_Network_Socket;

   function Find_Network_Socket (Name : String) return Natural is
   begin
      for I in 1 .. Network_Socket_Count loop
         if Network_Sockets (I).Active
           and then Network_Sockets (I).Name_Len = Name'Length
           and then Network_Sockets (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Network_Socket;

   procedure Register_Struct_Field
     (Struct_Name : String;
      Field_Name  : String;
      Tag         : ALB_Type_Tag;
      Offset      : Natural) is
   begin
      if Struct_Field_Count < Max_Struct_Fields
        and then Struct_Name'Length <= 64
        and then Field_Name'Length <= 64
      then
         Struct_Field_Count := Struct_Field_Count + 1;
         Struct_Fields (Struct_Field_Count).Active := True;
         Struct_Fields (Struct_Field_Count).Struct_Name_Len := Struct_Name'Length;
         Struct_Fields (Struct_Field_Count).Struct_Name (1 .. Struct_Name'Length) := Struct_Name;
         Struct_Fields (Struct_Field_Count).Field_Name_Len := Field_Name'Length;
         Struct_Fields (Struct_Field_Count).Field_Name (1 .. Field_Name'Length) := Field_Name;
         Struct_Fields (Struct_Field_Count).Tag := Tag;
         Struct_Fields (Struct_Field_Count).Offset_Bytes := Offset;
      end if;
   end Register_Struct_Field;

   procedure Register_Temporal_Symbol
     (Name         : String;
      Tag          : ALB_Type_Tag;
      History_Size : Natural;
      Current_Offset : Natural;
      Timeline_Offset : Natural;
      Slot_Size_Bytes : Natural) is
   begin
      if Temporal_Symbol_Count < Max_Temporal_Symbols and then Name'Length <= 64 then
         for I in 1 .. Temporal_Symbol_Count loop
            if Temporal_Symbols (I).Active
              and then Temporal_Symbols (I).Name_Len = Name'Length
              and then Temporal_Symbols (I).Name (1 .. Name'Length) = Name
            then
               Temporal_Symbols (I).Tag := Tag;
               Temporal_Symbols (I).History_Size := History_Size;
               Temporal_Symbols (I).Current_Offset := Current_Offset;
               Temporal_Symbols (I).Timeline_Offset := Timeline_Offset;
               Temporal_Symbols (I).Slot_Size_Bytes := Slot_Size_Bytes;
               return;
            end if;
         end loop;

         Temporal_Symbol_Count := Temporal_Symbol_Count + 1;
         Temporal_Symbols (Temporal_Symbol_Count).Active := True;
         Temporal_Symbols (Temporal_Symbol_Count).Name_Len := Name'Length;
         Temporal_Symbols (Temporal_Symbol_Count).Name (1 .. Name'Length) := Name;
         Temporal_Symbols (Temporal_Symbol_Count).Tag := Tag;
         Temporal_Symbols (Temporal_Symbol_Count).History_Size := History_Size;
         Temporal_Symbols (Temporal_Symbol_Count).Current_Offset := Current_Offset;
         Temporal_Symbols (Temporal_Symbol_Count).Timeline_Offset := Timeline_Offset;
         Temporal_Symbols (Temporal_Symbol_Count).Slot_Size_Bytes := Slot_Size_Bytes;
      end if;
   end Register_Temporal_Symbol;

   function Find_Temporal_Symbol (Name : String) return Natural is
   begin
      for I in 1 .. Temporal_Symbol_Count loop
         if Temporal_Symbols (I).Active
           and then Temporal_Symbols (I).Name_Len = Name'Length
           and then Temporal_Symbols (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Temporal_Symbol;

   function Find_Struct_Field
     (Struct_Name : String;
      Field_Name  : String) return Natural is
   begin
      for I in 1 .. Struct_Field_Count loop
         if Struct_Fields (I).Active
           and then Struct_Fields (I).Struct_Name_Len = Struct_Name'Length
           and then Struct_Fields (I).Field_Name_Len = Field_Name'Length
           and then Struct_Fields (I).Struct_Name (1 .. Struct_Name'Length) = Struct_Name
           and then Struct_Fields (I).Field_Name (1 .. Field_Name'Length) = Field_Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Struct_Field;

   procedure Emit_Line
     (Text    : String;
      Success : in out Boolean) is
      S : Boolean := Success;
   begin
      if not S then
         return;
      end if;

      Emit_Native_Java.Emit_Indent (S);
      if S then
         Emit_Native_Java.Emit_Raw (Text, S);
      end if;
      if S then
         Emit_Native_Java.Emit_Newline (S);
      end if;
      Success := S;
   end Emit_Line;

   procedure Emit_Global_Line
     (Text    : String;
      Success : in out Boolean) is
      Saved_Buffer : constant Emit_Native_Java.Buffer_Target := Emit_Native_Java.Current_Buffer;
      Saved_Indent : constant Natural := Emit_Native_Java.Indent_Level;
   begin
      if not Success then
         return;
      end if;

      Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Global);
      Emit_Native_Java.Indent_Level := 1;
      Emit_Line (Text, Success);
      Emit_Native_Java.Current_Buffer := Saved_Buffer;
      Emit_Native_Java.Indent_Level := Saved_Indent;
   end Emit_Global_Line;

   procedure Emit_VAS_Config
     (Success : in out Boolean) is
      Temp_Base  : constant Natural := Align_To (VAS_Global_Next, 8);
      Frame_Base : constant Natural := Align_To (Temp_Base + VAS_Temporal_Next, 8);
      Total_Size : constant Natural := Frame_Base + VAS_Frame_Reserve_Bytes;
   begin
      if not Success or else VAS_Config_Emitted then
         return;
      end if;

      Emit_Global_Line
        ("private static final int ALB_VAS_GLOBAL_BASE = " &
         Trim_Image (Natural'Image (VAS_Global_Base)) & ";",
         Success);
      if Success then
         Emit_Global_Line
           ("private static final int ALB_VAS_TEMP_BASE = " &
            Trim_Image (Natural'Image (Temp_Base)) & ";",
            Success);
      end if;
      if Success then
         Emit_Global_Line
           ("private static final int ALB_VAS_FRAME_BASE = " &
            Trim_Image (Natural'Image (Frame_Base)) & ";",
            Success);
      end if;
      if Success then
         Emit_Global_Line
           ("private static final int ALB_VAS_SIZE = " &
            Trim_Image (Natural'Image (Total_Size)) & ";",
            Success);
      end if;
      if Success then
         Emit_Global_Line ("static {", Success);
      end if;
      if Success then
         Emit_Global_Line ("    alb_vas = new byte[ALB_VAS_SIZE];", Success);
      end if;
      if Success then
         Emit_Global_Line ("    alb_frame_sp = ALB_VAS_FRAME_BASE;", Success);
      end if;
      if Success then
         Emit_Global_Line ("}", Success);
      end if;

      VAS_Config_Emitted := Success;
   end Emit_VAS_Config;

   procedure Emit_User_Save_State_Support
     (Success : in out Boolean) is
      function Is_Direct_Saveable_Symbol
        (Sym_Idx : Natural) return Boolean is
      begin
         return
           Java_Symbols (Sym_Idx).Active
           and then not Java_Symbols (Sym_Idx).Spilled
           and then Java_Symbols (Sym_Idx).Struct_Name_Len = 0
           and then Java_Symbols (Sym_Idx).Storage /= Storage_Parallel_Group
           and then Java_Symbols (Sym_Idx).Storage /= Storage_Parallel_Field;
      end Is_Direct_Saveable_Symbol;
   begin
      if not Success then
         return;
      end if;

      Emit_Global_Line
        ("private static final byte[][] alb_saved_vas = new byte[16][];",
         Success);

      for I in 1 .. Java_Symbol_Count loop
         exit when not Success;
         if Is_Direct_Saveable_Symbol (I) then
            declare
               Name     : constant String :=
                 Java_Symbols (I).Name (1 .. Java_Symbols (I).Name_Len);
               Elem_Type : constant String :=
                 Java_Global_Array_Type (Java_Symbols (I).Tag);
            begin
               Emit_Global_Line
                 ("private static final " & Elem_Type & "[][] " & Name &
                  "_saved = new " & Elem_Type & "[16][];",
                  Success);
            end;
         end if;
      end loop;

      Emit_Global_Line ("private static void ALB_SAVE_USER_STATE(int slot) {", Success);
      if Success then
         Emit_Global_Line ("if (alb_vas != null) {", Success);
      end if;
      if Success then
         Emit_Global_Line
           ("if (alb_saved_vas[slot] == null || alb_saved_vas[slot].length != alb_vas.length) {",
            Success);
      end if;
      if Success then
         Emit_Global_Line ("alb_saved_vas[slot] = new byte[alb_vas.length];", Success);
      end if;
      if Success then
         Emit_Global_Line ("}", Success);
      end if;
      if Success then
         Emit_Global_Line
           ("System.arraycopy(alb_vas, 0, alb_saved_vas[slot], 0, alb_vas.length);",
            Success);
      end if;
      if Success then
         Emit_Global_Line ("}", Success);
      end if;
      for I in 1 .. Java_Symbol_Count loop
         exit when not Success;
         if Is_Direct_Saveable_Symbol (I) then
            declare
               Name : constant String :=
                 Java_Symbols (I).Name (1 .. Java_Symbols (I).Name_Len);
            begin
               Emit_Global_Line (Name & "_saved[slot] = " & Name & ".clone();", Success);
            end;
         end if;
      end loop;
      Emit_Global_Line ("}", Success);

      Emit_Global_Line ("private static void ALB_LOAD_USER_STATE(int slot) {", Success);
      if Success then
         Emit_Global_Line
           ("if (alb_saved_vas[slot] != null && alb_vas != null) {",
            Success);
      end if;
      if Success then
         Emit_Global_Line
           ("System.arraycopy(alb_saved_vas[slot], 0, alb_vas, 0, Math.min(alb_vas.length, alb_saved_vas[slot].length));",
            Success);
      end if;
      if Success then
         Emit_Global_Line ("}", Success);
      end if;
      for I in 1 .. Java_Symbol_Count loop
         exit when not Success;
         if Is_Direct_Saveable_Symbol (I) then
            declare
               Name : constant String :=
                 Java_Symbols (I).Name (1 .. Java_Symbols (I).Name_Len);
            begin
               Emit_Global_Line ("if (" & Name & "_saved[slot] != null) {", Success);
               if Success then
                  Emit_Global_Line
                    ("System.arraycopy(" & Name & "_saved[slot], 0, " & Name &
                     ", 0, Math.min(" & Name & ".length, " & Name & "_saved[slot].length));",
                     Success);
               end if;
               if Success then
                  Emit_Global_Line ("}", Success);
               end if;
            end;
         end if;
      end loop;
      Emit_Global_Line ("}", Success);
   end Emit_User_Save_State_Support;

   function Java_VAS_Load_Expr
     (Tag          : ALB_Type_Tag;
      Address_Expr : String) return String is
   begin
      case Tag is
         when Type_U8 =>
            return "(ALB_VAS_LOAD_I8(" & Address_Expr & ") & 0xFF)";
         when Type_S8 | Type_Boolean | Type_HW8 =>
            return "(byte)(ALB_VAS_LOAD_I8(" & Address_Expr & "))";
         when Type_U16 =>
            return "(ALB_VAS_LOAD_I16(" & Address_Expr & ") & 0xFFFF)";
         when Type_S16 | Type_HW16 =>
            return "(short)(ALB_VAS_LOAD_I16(" & Address_Expr & "))";
         when Type_U32 =>
            return "(ALB_VAS_LOAD_I32(" & Address_Expr & ") & 0xFFFFFFFFL)";
         when Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char =>
            return "ALB_VAS_LOAD_I32(" & Address_Expr & ")";
         when Type_U64 | Type_S64 | Type_HW64 =>
            return "ALB_VAS_LOAD_I64(" & Address_Expr & ")";
         when Type_F32 =>
            return "ALB_VAS_LOAD_F32(" & Address_Expr & ")";
         when Type_F64 | Type_F128 =>
            return "ALB_VAS_LOAD_F64(" & Address_Expr & ")";
         when others =>
            return "ALB_VAS_LOAD_I64(" & Address_Expr & ")";
      end case;
   end Java_VAS_Load_Expr;

   function Java_VAS_Store_Open
     (Tag          : ALB_Type_Tag;
      Address_Expr : String) return String is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 =>
            return "ALB_VAS_STORE_I8(" & Address_Expr & ", (int)(";
         when Type_U16 | Type_S16 | Type_HW16 =>
            return "ALB_VAS_STORE_I16(" & Address_Expr & ", (int)(";
         when Type_U32 | Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char =>
            return "ALB_VAS_STORE_I32(" & Address_Expr & ", (int)(";
         when Type_U64 | Type_S64 | Type_HW64 =>
            return "ALB_VAS_STORE_I64(" & Address_Expr & ", (long)(";
         when Type_F32 =>
            return "ALB_VAS_STORE_F32(" & Address_Expr & ", (float)(";
         when Type_F64 | Type_F128 =>
            return "ALB_VAS_STORE_F64(" & Address_Expr & ", (double)(";
         when others =>
            return "ALB_VAS_STORE_I64(" & Address_Expr & ", (long)(";
      end case;
   end Java_VAS_Store_Open;

   function Java_VAS_Store_Close (Tag : ALB_Type_Tag) return String is
      pragma Unreferenced (Tag);
   begin
      return "))";
   end Java_VAS_Store_Close;

   function Struct_Name_Of_Resolved_Name (Name : String) return String is
      Local_Idx : constant Natural := Find_Local_Symbol (Name);
      Sym_Idx   : constant Natural := Find_Java_Symbol (Name);
   begin
      if Local_Idx > 0 and then Local_Symbols (Local_Idx).Struct_Name_Len > 0 then
         return Local_Symbols (Local_Idx).Struct_Name
           (1 .. Local_Symbols (Local_Idx).Struct_Name_Len);
      elsif Sym_Idx > 0 and then Java_Symbols (Sym_Idx).Struct_Name_Len > 0 then
         return Java_Symbols (Sym_Idx).Struct_Name
           (1 .. Java_Symbols (Sym_Idx).Struct_Name_Len);
      else
         return "";
      end if;
   end Struct_Name_Of_Resolved_Name;

   function Symbol_Address_Expr (Name : String) return String is
      Local_Idx : constant Natural := Find_Local_Symbol (Name);
      Sym_Idx   : constant Natural := Find_Java_Symbol (Name);
   begin
      if Local_Idx > 0 and then Local_Symbols (Local_Idx).Spilled then
         return Current_Frame_Base_Name (1 .. Current_Frame_Base_Len) &
           " + " &
           Trim_Image (Natural'Image (Local_Symbols (Local_Idx).Frame_Offset));
      elsif Sym_Idx > 0 and then Java_Symbols (Sym_Idx).Spilled then
         return Trim_Image (Natural'Image (Java_Symbols (Sym_Idx).VAS_Offset));
      else
         return "0";
      end if;
   end Symbol_Address_Expr;

   function Resolve_Symbol_Name (Raw_Name : String) return String;
   function Java_Value_Ref (Name : String) return String;
   function Java_Read_Expr (Name : String) return String;
   function Target_Address_Expr (Target_Node : Node_Index) return String;
   function Is_ALB_Builtin_Call_Name (Name : String) return Boolean;
   function Resolve_ALB_Call_Name (Target_Node : Node_Index) return String;
   function Find_Routine_Return_Tag
     (Java_Name : String) return ALB_Type_Tag;
   function Find_Routine_Param_Tag
     (Java_Name : String;
      Position  : Positive) return ALB_Type_Tag;
   procedure Emit_Temporal_Backing
     (Name         : String;
      Tag          : ALB_Type_Tag;
      History_Size : Natural;
      Success      : in out Boolean);
   procedure Emit_Temporal_Init
     (Name         : String;
      Tag          : ALB_Type_Tag;
      History_Size : Natural;
      Success      : in out Boolean);

   procedure Declare_Java_Symbol
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : in out Boolean;
      Storage : Java_Storage_Kind := Storage_Scalar;
      Rank    : Natural := 0;
      Dims    : Java_Dim_Array := (others => 0);
      Spill   : Boolean := False;
      Struct_Name : String := "") is
      Idx        : Natural := 0;
      Total_Size : Natural := 1;
      Slots      : Natural := 1;
      Size_Bytes : Natural := 0;
   begin
      if not Success then
         return;
      end if;

      Idx := Find_Java_Symbol (Name);
      if Idx /= 0 then
         return;
      end if;

      if Java_Symbol_Count >= Max_Java_Symbols or else Name'Length > 64 then
         Success := False;
         return;
      end if;

      Java_Symbol_Count := Java_Symbol_Count + 1;
      Java_Symbols (Java_Symbol_Count).Active := True;
      Java_Symbols (Java_Symbol_Count).Name_Len := Name'Length;
      Java_Symbols (Java_Symbol_Count).Name (1 .. Name'Length) := Name;
      Java_Symbols (Java_Symbol_Count).Tag := Tag;
      Java_Symbols (Java_Symbol_Count).Storage := Storage;
      Java_Symbols (Java_Symbol_Count).Rank := Rank;
      Java_Symbols (Java_Symbol_Count).Dims := Dims;
      Java_Symbols (Java_Symbol_Count).Struct_Name_Len := Struct_Name'Length;
      if Struct_Name'Length > 0 then
         Java_Symbols (Java_Symbol_Count).Struct_Name (1 .. Struct_Name'Length) := Struct_Name;
      end if;

      if Storage = Storage_Scalar then
         if Spill or else Struct_Name'Length > 0 then
            Size_Bytes :=
              (if Struct_Name'Length > 0
               then Struct_Size_Bytes_By_Name (Struct_Name)
               else Type_Size_Bytes (Tag));
            Java_Symbols (Java_Symbol_Count).Spilled := True;
            Java_Symbols (Java_Symbol_Count).VAS_Size_Bytes := Size_Bytes;
            Java_Symbols (Java_Symbol_Count).VAS_Offset :=
              Allocate_Global_VAS
                (Size_Bytes,
                 (if Struct_Name'Length > 0 then 8 else Tag_Align_Bytes (Tag)));
         elsif Tag = Type_Pure or else Tag = Type_U128 or else Tag = Type_S128 then
            Emit_Global_Line
              ("private static final " & Java_Global_Array_Type (Tag) & "[] " &
               Name & " = new " & Java_Global_Array_Type (Tag) & "[2];",
               Success);
         else
            Emit_Global_Line
              ("private static final " & Java_Global_Array_Type (Tag) & "[] " &
               Name & " = new " & Java_Global_Array_Type (Tag) & "[1];",
               Success);
         end if;
      elsif Storage = Storage_Parallel_Group then
         null;
      else
         Slots := 1;
         for I in 1 .. Rank loop
            if Dims (I) = 0 then
               Slots := Slots * 1;
            else
               Slots := Slots * Dims (I);
            end if;
         end loop;
         Total_Size := (Slots + 1) * Java_Slot_Count (Tag); -- preserve ALB 1-based indexing
         Emit_Global_Line
           ("private static final " & Java_Global_Array_Type (Tag) & "[] " &
            Name & " = new " & Java_Global_Array_Type (Tag) & "[" &
            Trim_Image (Natural'Image (Total_Size)) & "];",
            Success);
      end if;
   end Declare_Java_Symbol;

   procedure Emit_Temporal_Backing
     (Name         : String;
      Tag          : ALB_Type_Tag;
      History_Size : Natural;
      Success      : in out Boolean) is
      pragma Unreferenced (Tag);
   begin
      if not Success or else History_Size = 0 then
         return;
      end if;

      Emit_Global_Line
        ("private static final int[] " & Name & "_head = new int[1];",
         Success);
   end Emit_Temporal_Backing;

   procedure Emit_Temporal_Init
     (Name         : String;
      Tag          : ALB_Type_Tag;
      History_Size : Natural;
      Success      : in out Boolean) is
      Loop_Name : constant String := "alb_hist_" & Name;
      T_Idx     : constant Natural := Find_Temporal_Symbol (Name);
   begin
      if not Success or else History_Size = 0 or else T_Idx = 0 then
         return;
      end if;

      Emit_Line
        ("ALB_VAS_ZERO(ALB_VAS_TEMP_BASE + " &
         Trim_Image (Natural'Image (Temporal_Symbols (T_Idx).Timeline_Offset)) &
         ", " &
         Trim_Image
           (Natural'Image
              (Temporal_Symbols (T_Idx).History_Size *
               Temporal_Symbols (T_Idx).Slot_Size_Bytes)) &
         ");",
         Success);
      Emit_Line
        ("for (int " & Loop_Name & " = 0; " & Loop_Name & " < " &
         Trim_Image (Natural'Image (History_Size)) & "; " & Loop_Name & "++) {",
         Success);
      Emit_Native_Java.Increase_Indent;
      Emit_Line
        ("ALB_VAS_COPY(ALB_VAS_TEMP_BASE + " &
         Trim_Image (Natural'Image (Temporal_Symbols (T_Idx).Timeline_Offset)) &
         " + " & Loop_Name & " * " &
         Trim_Image (Natural'Image (Temporal_Symbols (T_Idx).Slot_Size_Bytes)) &
         ", " &
         Trim_Image (Natural'Image (Temporal_Symbols (T_Idx).Current_Offset)) &
         ", " &
         Trim_Image (Natural'Image (Temporal_Symbols (T_Idx).Slot_Size_Bytes)) &
         ");",
         Success);
      Emit_Native_Java.Decrease_Indent;
      Emit_Line ("}", Success);
      if Success then
         Emit_Line (Name & "_head[0] = 0;", Success);
      end if;
   end Emit_Temporal_Init;

   function Predicate_Name_Of (Idx : Node_Index) return String is
   begin
      if Idx = 0 then
         return "";
      end if;

      case Tree (Idx).Kind is
         when AST_Assert_Stmt | AST_Retract_Stmt =>
            if Tree (Idx).Token_Index > 0 then
               return Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
            end if;

         when AST_Query | AST_Findall_Query =>
            return Predicate_Name_Of (Tree (Idx).Left_Child);

         when AST_Predicate | AST_Atom | AST_Var_Expr | AST_Logic_Var =>
            if Tree (Idx).Token_Index > 0 then
               return Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
            end if;

         when AST_Knows_Query | AST_Find_Query =>
            return Predicate_Name_Of (Tree (Idx).Left_Child);

         when others =>
            null;
      end case;

      return "";
   end Predicate_Name_Of;

   function Predicate_Arg_Node (Idx : Node_Index) return Node_Index is
   begin
      if Idx = 0 then
         return 0;
      end if;

      case Tree (Idx).Kind is
         when AST_Assert_Stmt | AST_Retract_Stmt =>
            return Tree (Idx).Left_Child;

         when AST_Query | AST_Findall_Query | AST_Knows_Query | AST_Find_Query =>
            return Predicate_Arg_Node (Tree (Idx).Left_Child);

         when AST_Predicate =>
            return Tree (Idx).Left_Child;

         when others =>
            return 0;
      end case;
   end Predicate_Arg_Node;

   function Qualified_Java_Name (Base_Name : String) return String is
   begin
      if Current_Module_Len > 0 then
         return Current_Module_Name (1 .. Current_Module_Len) & "_" & Base_Name;
      else
         return Base_Name;
      end if;
   end Qualified_Java_Name;

   function Find_Routine_Param_Tag
     (Java_Name : String;
      Position  : Positive) return ALB_Type_Tag is
      function Join_Module_Name
        (Module_Name : String;
         Base_Name   : String) return String is
      begin
         if Module_Name'Length = 0 then
            return Base_Name;
         else
            return Module_Name & "_" & Base_Name;
         end if;
      end Join_Module_Name;

      function Search
        (Idx         : Node_Index;
         Module_Name : String) return ALB_Type_Tag is
         Curr : Node_Index := Idx;
      begin
         while Curr /= 0 loop
            declare
               Desc_Module_Name : constant String :=
                 (if Tree (Curr).Kind in AST_Module | AST_DeclareModule
                     and then Tree (Curr).Left_Child /= 0
                  then Join_Module_Name
                    (Module_Name,
                     Java_Safe_Symbol
                       (Raw_Lexeme
                          (Tree (Tree (Curr).Left_Child).Token_Index)))
                  else Module_Name);
               Found_Tag : ALB_Type_Tag := Type_None;
            begin
               if Tree (Curr).Kind = AST_Procedure_Decl
                 or else Tree (Curr).Kind = AST_Function_Decl
               then
                  declare
                     Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                  begin
                     if Name_Node /= 0 then
                        declare
                           Candidate_Name : constant String :=
                             Join_Module_Name
                               (Module_Name,
                                Java_Safe_Symbol
                                  (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                           Param_List : Node_Index := Tree (Name_Node).Right_Child;
                           Param_Curr : Node_Index := 0;
                           Param_Pos  : Positive := 1;
                           Param_Tag  : ALB_Type_Tag := Type_U64;
                        begin
                           if Candidate_Name = Java_Name then
                              if Param_List /= 0
                                and then Tree (Param_List).Kind = AST_Arg_List
                              then
                                 Param_Curr := Tree (Param_List).Left_Child;
                              else
                                 Param_Curr := Param_List;
                              end if;

                              while Param_Curr /= 0
                                and then Tree (Param_Curr).Kind = AST_Param_Decl
                              loop
                                 if Param_Pos = Position then
                                    if Tree (Param_Curr).Right_Child > 0 then
                                       Param_Tag :=
                                         Type_Tag_From_Name
                                           (Raw_Lexeme
                                              (Tree
                                                 (Tree (Param_Curr).Right_Child)
                                                 .Token_Index));
                                    end if;

                                    if Param_Tag = Type_None then
                                       Param_Tag := Type_U64;
                                    end if;

                                    return Param_Tag;
                                 end if;

                                 Param_Pos := Param_Pos + 1;
                                 Param_Curr := Tree (Param_Curr).Next_Sibling;
                              end loop;

                              return Type_None;
                           end if;
                        end;
                     end if;
                  end;
               end if;

               Found_Tag := Search (Tree (Curr).Left_Child, Desc_Module_Name);
               if Found_Tag /= Type_None then
                  return Found_Tag;
               end if;

               Found_Tag := Search (Tree (Curr).Right_Child, Desc_Module_Name);
               if Found_Tag /= Type_None then
                  return Found_Tag;
               end if;
            end;

            Curr := Tree (Curr).Next_Sibling;
         end loop;

         return Type_None;
      end Search;
   begin
      return Search (Root, "");
   end Find_Routine_Param_Tag;

   function Find_Routine_Return_Tag
     (Java_Name : String) return ALB_Type_Tag is
      function Join_Module_Name
        (Module_Name : String;
         Base_Name   : String) return String is
      begin
         if Module_Name'Length = 0 then
            return Base_Name;
         else
            return Module_Name & "_" & Base_Name;
         end if;
      end Join_Module_Name;

      function Search
        (Idx         : Node_Index;
         Module_Name : String) return ALB_Type_Tag is
         Curr : Node_Index := Idx;
      begin
         while Curr /= 0 loop
            declare
               Desc_Module_Name : constant String :=
                 (if Tree (Curr).Kind in AST_Module | AST_DeclareModule
                     and then Tree (Curr).Left_Child /= 0
                  then Join_Module_Name
                    (Module_Name,
                     Java_Safe_Symbol
                       (Raw_Lexeme
                          (Tree (Tree (Curr).Left_Child).Token_Index)))
                  else Module_Name);
               Found_Tag : ALB_Type_Tag := Type_None;
            begin
               if Tree (Curr).Kind = AST_Function_Decl then
                  declare
                     Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                  begin
                     if Name_Node /= 0 then
                        declare
                           Candidate_Name : constant String :=
                             Join_Module_Name
                               (Module_Name,
                                Java_Safe_Symbol
                                  (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                           Return_Tag : ALB_Type_Tag := Type_U64;
                        begin
                           if Candidate_Name = Java_Name then
                              if Tree (Curr).Token_Index > 0 then
                                 Return_Tag :=
                                   Type_Tag_From_Name
                                     (Raw_Lexeme (Tree (Curr).Token_Index));
                              end if;

                              if Return_Tag = Type_None then
                                 Return_Tag := Type_U64;
                              end if;

                              return Return_Tag;
                           end if;
                        end;
                     end if;
                  end;
               end if;

               Found_Tag := Search (Tree (Curr).Left_Child, Desc_Module_Name);
               if Found_Tag /= Type_None then
                  return Found_Tag;
               end if;

               Found_Tag := Search (Tree (Curr).Right_Child, Desc_Module_Name);
               if Found_Tag /= Type_None then
                  return Found_Tag;
               end if;
            end;

            Curr := Tree (Curr).Next_Sibling;
         end loop;

         return Type_None;
      end Search;
   begin
      return Search (Root, "");
   end Find_Routine_Return_Tag;

   function Resolve_Target_Name (Idx : Node_Index) return String is
   begin
      if Idx = 0 then
         return "alb_missing";
      end if;

      case Tree (Idx).Kind is
         when AST_Var_Expr =>
            return Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));

         when AST_Member_Expr =>
            declare
               Left_Name : constant String := Resolve_Target_Name (Tree (Idx).Left_Child);
               Right_Name : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
            begin
               return Left_Name & "_" & Right_Name;
            end;

         when AST_Func_Call =>
            return Resolve_Target_Name (Tree (Idx).Left_Child);

         when others =>
            return "alb_unknown";
      end case;
   end Resolve_Target_Name;

   function Is_ALB_Builtin_Call_Name (Name : String) return Boolean is
      U : constant String := Upper_ASCII (Name);
   begin
      return U = "PURE"
        or else U = "RATIONAL"
        or else U = "PURE_ADD" or else U = "PURE_SUB"
        or else U = "PURE_MUL" or else U = "PURE_DIV"
        or else U = "PURE_POW" or else U = "PURE_NUM"
        or else U = "PURE_DEN" or else U = "PRINT_PURE"
        or else U = "HW8" or else U = "HW16" or else U = "HW32"
        or else U = "U8"  or else U = "U16"  or else U = "U32"
        or else U = "U64" or else U = "U128" or else U = "S32"
        or else U = "F64" or else U = "REAL" or else U = "LEN"  or else U = "LEFT"
        or else U = "RIGHT" or else U = "MID" or else U = "MID$"
        or else U = "CHR" or else U = "CONCAT" or else U = "SIN" or else U = "COS"
        or else U = "SQRT" or else U = "EXP"
        or else U = "COLLIDE_RECT" or else U = "GETTICKCOUNT"
        or else U = "PROVE"
        or else Type_Tag_From_Name (U) /= Type_None;
   end Is_ALB_Builtin_Call_Name;

   function Resolve_ALB_Call_Name (Target_Node : Node_Index) return String is
   begin
      if Target_Node = 0 then
         return "alb_missing";
      end if;

      if Tree (Target_Node).Kind = AST_Var_Expr then
         declare
            Safe : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Target_Node).Token_Index));
         begin
            if Is_ALB_Builtin_Call_Name (Safe) then
               return Safe;
            elsif Current_Module_Len > 0 then
               return Current_Module_Name (1 .. Current_Module_Len) & "_" & Safe;
            else
               return Safe;
            end if;
         end;
      elsif Tree (Target_Node).Kind = AST_Member_Expr then
         return Resolve_Target_Name (Target_Node);
      else
         return Resolve_Target_Name (Target_Node);
      end if;
   end Resolve_ALB_Call_Name;

   procedure Try_Evaluate_Static_U64
     (Idx     : Node_Index;
      Value   : out U64;
      Success : out Boolean) is
      Tmp    : U64 := 0;
      S      : Boolean := False;
      CIdx   : Natural := 0;
      Txt    : String (1 .. 128) := (others => ' ');
      Txt_Len: Natural := 0;
   begin
      if Idx = 0 then
         Value := 0;
         Success := False;
         return;
      end if;

      case Tree (Idx).Kind is
         when AST_Number_Expr =>
            Parse_Decimal (Raw_Lexeme (Tree (Idx).Token_Index), Tmp, S);

         when AST_Hex_Expr =>
            Parse_Hex (Raw_Lexeme (Tree (Idx).Token_Index), Tmp, S);

         when AST_Bin_Expr =>
            Parse_Binary (Raw_Lexeme (Tree (Idx).Token_Index), Tmp, S);

         when AST_Octal_Expr =>
            Parse_Octal (Raw_Lexeme (Tree (Idx).Token_Index), Tmp, S);

         when AST_Const_Ref =>
            CIdx := Find_Const (Raw_Lexeme (Tree (Idx).Token_Index));
            if CIdx > 0 then
               Txt_Len := Consts (CIdx).Value_Len;
               if Txt_Len > 0 then
                  Txt (1 .. Txt_Len) := Consts (CIdx).Value (1 .. Txt_Len);
               end if;
               Parse_Decimal (Txt (1 .. Txt_Len), Tmp, S);
               if not S and then Txt_Len > 1 and then Txt (1) = '0' and then Txt (2) = 'x' then
                  Parse_Hex ("$" & Txt (3 .. Txt_Len), Tmp, S);
               end if;
               if not S and then Txt_Len > 1 and then Txt (1) = '0' and then Txt (2) = 'b' then
                  Parse_Binary ("%" & Txt (3 .. Txt_Len), Tmp, S);
               end if;
            else
               S := False;
            end if;

         when others =>
            S := False;
      end case;

      Value := Tmp;
      Success := S;
   end Try_Evaluate_Static_U64;

   function Java_Integer_Text (Idx : Node_Index) return String is
      Parsed          : U64 := 0;
      Parse_OK        : Boolean := False;
      Signed_Int_Max  : constant U64 := 16#7FFF_FFFF#;
      Signed_Long_Max : constant U64 := 16#7FFF_FFFF_FFFF_FFFF#;
   begin
      Try_Evaluate_Static_U64 (Idx, Parsed, Parse_OK);
      if Parse_OK then
         if Parsed <= Signed_Int_Max then
            return Trim_Image (U64'Image (Parsed));
         elsif Parsed <= Signed_Long_Max then
            return Trim_Image (U64'Image (Parsed)) & "L";
         else
            return "0x" & U64_Hex_Image (Parsed) & "L";
         end if;
      end if;

      return Raw_Lexeme (Tree (Idx).Token_Index);
   end Java_Integer_Text;

   function Java_Numeric_Text (Idx : Node_Index) return String is
      Lex : constant String := Raw_Lexeme (Tree (Idx).Token_Index);
   begin
      if Tree (Idx).Kind = AST_Number_Expr and then Is_Real_Number_Text (Lex) then
         return Lex;
      else
         return Java_Integer_Text (Idx);
      end if;
   end Java_Numeric_Text;

   function Infer_Type_Tag (Idx : Node_Index) return ALB_Type_Tag is
      Kind : Node_Kind;
      Tok  : Token;
      Left_Tag  : ALB_Type_Tag := Type_None;
      Right_Tag : ALB_Type_Tag := Type_None;
      Sym_Idx : Natural := 0;
   begin
      if Idx = 0 then
         return Type_None;
      end if;

      Kind := Tree (Idx).Kind;

      case Kind is
         when AST_Number_Expr =>
            if Is_Real_Number_Text (Raw_Lexeme (Tree (Idx).Token_Index)) then
               return Type_F64;
            end if;
            return Type_U64;

         when AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
            return Type_U64;

         when AST_String_Expr =>
            return Type_Binary;

         when AST_Str_Len | AST_SizeOf_Expr | AST_OffsetOf_Expr |
              AST_Read_Pixel | AST_File_Open | AST_File_Len | AST_File_Seek | AST_Rnd_Expr =>
            return Type_U64;

         when AST_Peek_Expr | AST_Deref_Expr =>
            return Type_U32;

         when AST_Str_Left | AST_Str_Right | AST_Str_Mid | AST_Str_Concat |
              AST_TypeOf_Expr | AST_File_Read =>
            return Type_Binary;

         when AST_True | AST_False =>
            return Type_Boolean;

         when AST_Mouse_X | AST_Mouse_Y | AST_Mouse_Wheel | AST_VMouse_X | AST_VMouse_Y |
              AST_SCREEN_WIDTH | AST_SCREEN_HEIGHT |
              AST_VIRTUAL_WIDTH | AST_VIRTUAL_HEIGHT =>
            return Type_S32;

         when AST_Mouse_Click | AST_Key_State | AST_Query | AST_Knows_Query =>
            return Type_Boolean;

         when AST_Constructor =>
            if Tree (Idx).Token_Index > 0 then
               return Type_Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
            else
               return Type_None;
            end if;

         when AST_Cast_Expr =>
            if Tree (Idx).Token_Index > 0 then
               return Type_Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
            else
               return Type_None;
            end if;

         when AST_Var_Expr =>
            if Tree (Idx).Token_Index > 0 then
               declare
                  Safe_Name : constant String := Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
                  Local_Idx : constant Natural := Find_Local_Symbol (Safe_Name);
               begin
                  if Local_Idx > 0 then
                     return Local_Symbols (Local_Idx).Tag;
                  end if;
                  Sym_Idx := Find_Java_Symbol (Safe_Name);
                  if Sym_Idx > 0 then
                     return Java_Symbols (Sym_Idx).Tag;
                  end if;
               end;
            end if;
            return Type_U64;

         when AST_Member_Expr =>
            if Tree (Idx).Right_Child > 0 and then Tree (Tree (Idx).Right_Child).Token_Index > 0 then
               declare
                  Left_Name : constant String := Resolve_Target_Name (Tree (Idx).Left_Child);
                  Field_Name : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                  PF_Idx : constant Natural := Find_Parallel_Field (Left_Name, Field_Name);
                  Struct_Name : constant String :=
                    Struct_Name_Of_Resolved_Name (Resolve_Target_Name (Tree (Idx).Left_Child));
                  SF_Idx : constant Natural :=
                    (if Struct_Name'Length > 0
                     then Find_Struct_Field (Struct_Name, Field_Name)
                     else 0);
               begin
                  if PF_Idx > 0 then
                     return Parallel_Fields (PF_Idx).Tag;
                  elsif SF_Idx > 0 then
                     return Struct_Fields (SF_Idx).Tag;
                  end if;
               end;
            end if;
            return Type_U64;

         when AST_Choose =>
            if Tree (Idx).Right_Child > 0 then
               return Infer_Type_Tag (Tree (Tree (Idx).Right_Child).Left_Child);
            else
               return Type_U64;
            end if;

         when AST_Func_Call =>
            declare
               Call_Name    : constant String := Upper_ASCII (Resolve_Target_Name (Tree (Idx).Left_Child));
               Routine_Name : constant String := Resolve_ALB_Call_Name (Tree (Idx).Left_Child);
               Return_Tag   : constant ALB_Type_Tag := Find_Routine_Return_Tag (Routine_Name);
            begin
               if Call_Name = "LEFT" or else Call_Name = "RIGHT" or else
                  Call_Name = "MID" or else Call_Name = "CHR" or else Call_Name = "CONCAT"
               then
                  return Type_Binary;
               elsif Call_Name = "PURE_ADD" or else Call_Name = "PURE_SUB" or else
                     Call_Name = "PURE_MUL" or else Call_Name = "PURE_DIV" or else
                     Call_Name = "PURE_POW"
               then
                  return Type_Pure;
               elsif Type_Tag_From_Name (Call_Name) /= Type_None then
                  return Type_Tag_From_Name (Call_Name);
               elsif Call_Name = "PURE_NUM" or else Call_Name = "PURE_DEN" then
                  return Type_S32;
               elsif Call_Name = "COLLIDE_RECT" or else Call_Name = "PROVE" then
                  return Type_Boolean;
               elsif Call_Name = "TYPEOF" then
                  return Type_Binary;
               elsif Return_Tag /= Type_None then
                  return Return_Tag;
               else
                  return Type_U64;
               end if;
            end;

         when AST_BinOp =>
            Tok := Tokens (Tree (Idx).Token_Index);
            Left_Tag := Infer_Type_Tag (Tree (Idx).Left_Child);
            Right_Tag := Infer_Type_Tag (Tree (Idx).Right_Child);

            case Tok.Kind is
               when TOK_PIPE =>
                  return Type_Binary;

               when TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL | TOK_LESS | TOK_GREATER |
                    TOK_LESS_EQUAL | TOK_GREATER_EQUAL | TOK_AND | TOK_OR | TOK_XOR =>
                  return Type_Boolean;

               when others =>
                  if Left_Tag = Type_Pure or else Right_Tag = Type_Pure then
                     return Type_Pure;
                  elsif Left_Tag = Type_F64 or else Right_Tag = Type_F64 or else
                        Left_Tag = Type_F32 or else Right_Tag = Type_F32
                  then
                     return Type_F64;
                  else
                     return Type_U64;
                  end if;
            end case;

         when others =>
            null;
      end case;

      return Type_U64;
   end Infer_Type_Tag;

   function Map_Binop (Kind : Token_Kind) return ALB_Opcode is
   begin
      case Kind is
         when TOK_PLUS          => return OP_ADD;
         when TOK_MINUS         => return OP_SUB;
         when TOK_MUL           => return OP_MUL;
         when TOK_DIV           => return OP_DIV;
         when TOK_MOD           => return OP_MOD;
         when TOK_AND           => return OP_AND;
         when TOK_OR            => return OP_OR;
         when TOK_XOR           => return OP_XOR;
         when TOK_SHL           => return OP_SHL;
         when TOK_SHR           => return OP_SHR;
         when TOK_ASSIGN        => return OP_CMP_EQ;
         when TOK_EQUAL         => return OP_CMP_EQ;
         when TOK_NOT_EQUAL     => return OP_CMP_NEQ;
         when TOK_LESS          => return OP_CMP_LT;
         when TOK_GREATER       => return OP_CMP_GT;
         when TOK_LESS_EQUAL    => return OP_CMP_LTE;
         when TOK_GREATER_EQUAL => return OP_CMP_GTE;
         when others            => return OP_NOP;
      end case;
   end Map_Binop;

   function Simple_Expr_Text (Idx : Node_Index) return String is
   begin
      if Idx = 0 then
         return "0";
      end if;

      case Tree (Idx).Kind is
         when AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
            return Java_Numeric_Text (Idx);

         when AST_String_Expr =>
            return """" & Strip_String_Node (Idx) & """";

         when AST_Const_Ref =>
            declare
               Const_Idx : constant Natural := Find_Const (Raw_Lexeme (Tree (Idx).Token_Index));
            begin
               if Const_Idx > 0 then
                  return Consts (Const_Idx).Value (1 .. Consts (Const_Idx).Value_Len);
               else
                  return "0";
               end if;
            end;

         when AST_True =>
            return "1";

         when AST_False =>
            return "0";

         when AST_Var_Expr =>
            declare
               Const_Idx : constant Natural := Find_Const (Raw_Lexeme (Tree (Idx).Token_Index));
            begin
               if Const_Idx > 0 then
                  return Consts (Const_Idx).Value (1 .. Consts (Const_Idx).Value_Len);
               else
                  return Java_Value_Ref (Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index)));
               end if;
            end;

         when others =>
            return "0";
      end case;
   end Simple_Expr_Text;

   procedure Emit_Comment (Text : String; Success : in out Boolean) is
      S : Boolean := Success;
   begin
      if not S then
         return;
      end if;

      Emit_Native_Java.Emit_Indent (S);
      if S then
         Emit_Native_Java.Emit_Raw ("// " & Text, S);
      end if;
      if S then
         Emit_Native_Java.Emit_Newline (S);
      end if;
      Success := S;
   end Emit_Comment;

   function Is_Comparison_Operator (Kind : Token_Kind) return Boolean is
   begin
      return Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL | TOK_LESS |
        TOK_GREATER | TOK_LESS_EQUAL | TOK_GREATER_EQUAL;
   end Is_Comparison_Operator;

   function Default_Return_Expr (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_Binary | Type_Char =>
            return "0";
         when Type_Pure | Type_U128 | Type_S128 =>
            return "ALB_PURE_ZERO";
         when Type_F32 =>
            return "0.0f";
         when Type_F64 | Type_F128 =>
            return "0.0d";
         when others =>
            return "0";
      end case;
   end Default_Return_Expr;

   function Resolve_Symbol_Name (Raw_Name : String) return String is
      Safe : constant String := Java_Safe_Symbol (Raw_Name);
   begin
      if Find_Local_Symbol (Safe) /= 0 then
         return Safe;
      end if;

      if Current_Module_Len > 0 then
         declare
            Qualified : constant String :=
              Current_Module_Name (1 .. Current_Module_Len) & "_" & Safe;
         begin
            if Find_Java_Symbol (Qualified) /= 0 then
               return Qualified;
            end if;
         end;
      end if;

      return Safe;
   end Resolve_Symbol_Name;

   function Java_Value_Ref (Name : String) return String is
      Local_Idx : constant Natural := Find_Local_Symbol (Name);
      Sym_Idx   : constant Natural := Find_Java_Symbol (Name);
   begin
      if Local_Idx > 0 then
         if Local_Symbols (Local_Idx).Struct_Name_Len > 0 then
            return Symbol_Address_Expr (Name);
         elsif Local_Symbols (Local_Idx).Spilled then
            return Java_Read_Expr (Name);
         else
            return Name;
         end if;
      elsif Sym_Idx > 0 and then Java_Symbols (Sym_Idx).Struct_Name_Len > 0 then
         return Symbol_Address_Expr (Name);
      elsif Sym_Idx > 0 and then Java_Symbols (Sym_Idx).Spilled then
         return Java_Read_Expr (Name);
      elsif Sym_Idx > 0
        and then (Java_Symbols (Sym_Idx).Tag = Type_Pure
          or else Java_Symbols (Sym_Idx).Tag = Type_U128
          or else Java_Symbols (Sym_Idx).Tag = Type_S128)
      then
         return Name;
      else
         return Name & "[0]";
      end if;
   end Java_Value_Ref;

   function Java_Read_Expr (Name : String) return String is
      Local_Idx : constant Natural := Find_Local_Symbol (Name);
      Sym_Idx   : constant Natural := Find_Java_Symbol (Name);
      Tag       : ALB_Type_Tag := Type_U64;
   begin
      if Local_Idx > 0 then
         Tag := Local_Symbols (Local_Idx).Tag;
         if Local_Symbols (Local_Idx).Struct_Name_Len > 0 then
            return Symbol_Address_Expr (Name);
         elsif Local_Symbols (Local_Idx).Spilled then
            return Java_VAS_Load_Expr (Tag, Symbol_Address_Expr (Name));
         elsif Local_Symbols (Local_Idx).Is_Out then
            return Name & "[0]";
         else
            return Name;
         end if;
      elsif Sym_Idx > 0 then
         Tag := Java_Symbols (Sym_Idx).Tag;
         if Java_Symbols (Sym_Idx).Struct_Name_Len > 0 then
            return Symbol_Address_Expr (Name);
         elsif Java_Symbols (Sym_Idx).Spilled then
            return Java_VAS_Load_Expr (Tag, Symbol_Address_Expr (Name));
         elsif Tag = Type_Pure or else Tag = Type_U128 or else Tag = Type_S128 then
            return Name;
         else
            return Name & "[0]";
         end if;
      else
         return Name & "[0]";
      end if;
   end Java_Read_Expr;

   function Resolved_Symbol_Tag (Name : String) return ALB_Type_Tag is
      Local_Idx : constant Natural := Find_Local_Symbol (Name);
      Sym_Idx   : constant Natural := Find_Java_Symbol (Name);
   begin
      if Local_Idx > 0 then
         return Local_Symbols (Local_Idx).Tag;
      elsif Sym_Idx > 0 then
         return Java_Symbols (Sym_Idx).Tag;
      else
         return Type_U64;
      end if;
   end Resolved_Symbol_Tag;

   function Java_Assign_Cast_Prefix (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 =>
            return "(int)(";
         when Type_S8 | Type_Boolean | Type_HW8 =>
            return "(byte)(";
         when Type_U16 =>
            return "(int)(";
         when Type_S16 | Type_HW16 =>
            return "(short)(";
         when Type_U32 =>
            return "(long)(";
         when Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char =>
            return "(int)(";
         when Type_U64 | Type_S64 | Type_HW64 =>
            return "(long)(";
         when Type_F32 =>
            return "(float)(";
         when Type_F64 | Type_F128 =>
            return "(double)(";
         when others =>
            return "";
      end case;
   end Java_Assign_Cast_Prefix;

   function Java_Assign_Cast_Suffix (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 |
              Type_U16 | Type_S16 | Type_HW16 |
              Type_U32 | Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char |
              Type_U64 | Type_S64 | Type_HW64 |
              Type_F32 | Type_F64 | Type_F128 =>
            return ")";
         when others =>
            return "";
      end case;
   end Java_Assign_Cast_Suffix;

   function Is_Pureish_Tag (Tag : ALB_Type_Tag) return Boolean is
   begin
      return Tag = Type_Pure or else Tag = Type_U128 or else Tag = Type_S128;
   end Is_Pureish_Tag;

   function Graphics_Pure_Source_Node (Idx : Node_Index) return Node_Index is
      Target_Node : Node_Index := 0;
      Arg_List    : Node_Index := 0;
      Arg_Node    : Node_Index := 0;
   begin
      if Idx = 0 or else Tree (Idx).Kind /= AST_Func_Call then
         return 0;
      end if;

      Target_Node := Tree (Idx).Left_Child;
      if Target_Node = 0 or else Tree (Target_Node).Kind /= AST_Var_Expr then
         return 0;
      end if;

      if Upper_ASCII (Resolve_Target_Name (Target_Node)) /= "PURE_NUM" then
         return 0;
      end if;

      Arg_List := Tree (Idx).Right_Child;
      if Arg_List /= 0 and then Tree (Arg_List).Kind = AST_Arg_List then
         Arg_Node := Tree (Arg_List).Left_Child;
      else
         Arg_Node := Arg_List;
      end if;

      if Arg_Node /= 0 and then Is_Pureish_Tag (Infer_Type_Tag (Arg_Node)) then
         return Arg_Node;
      end if;

      return 0;
   end Graphics_Pure_Source_Node;

   function Find_Resolved_Symbol (Raw_Name : String) return Natural is
      Resolved : constant String := Resolve_Symbol_Name (Raw_Name);
      Idx      : Natural := 0;
   begin
      Idx := Find_Local_Symbol (Resolved);
      if Idx /= 0 then
         return 0;
      end if;
      return Find_Java_Symbol (Resolved);
   end Find_Resolved_Symbol;

   function Target_Tag (Idx : Node_Index) return ALB_Type_Tag is
      Sym_Idx : Natural := 0;
      LIdx    : Natural := 0;
   begin
      if Idx = 0 then
         return Type_U64;
      end if;

      case Tree (Idx).Kind is
         when AST_Var_Expr =>
            declare
               Resolved : constant String :=
                 Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
            begin
               LIdx := Find_Local_Symbol (Resolved);
               if LIdx /= 0 then
                  return Local_Symbols (LIdx).Tag;
               end if;
               Sym_Idx := Find_Java_Symbol (Resolved);
               if Sym_Idx /= 0 then
                  return Java_Symbols (Sym_Idx).Tag;
               end if;
            end;
            return Type_U64;

         when AST_Member_Expr =>
            return Infer_Type_Tag (Idx);

         when others =>
            return Infer_Type_Tag (Idx);
      end case;
   end Target_Tag;

   function Java_VAS_Store_Call
     (Tag          : ALB_Type_Tag;
      Address_Expr : String;
      Value_Expr   : String) return String is
   begin
      return Java_VAS_Store_Open (Tag, Address_Expr) &
        Value_Expr &
        Java_VAS_Store_Close (Tag);
   end Java_VAS_Store_Call;

   function Java_Array_Data_Count
     (Sym_Idx : Natural) return Natural is
      Slots : Natural := 1;
   begin
      if Sym_Idx = 0 then
         return 0;
      end if;

      for I in 1 .. Java_Symbols (Sym_Idx).Rank loop
         if Java_Symbols (Sym_Idx).Dims (I) > 0 then
            Slots := Slots * Java_Symbols (Sym_Idx).Dims (I);
         end if;
      end loop;

      return Slots * Java_Slot_Count (Java_Symbols (Sym_Idx).Tag);
   end Java_Array_Data_Count;

   function Target_Byte_Size
     (Target_Node : Node_Index) return Natural is
   begin
      if Target_Node = 0 then
         return 0;
      end if;

      case Tree (Target_Node).Kind is
         when AST_Var_Expr =>
            declare
               Name     : constant String :=
                 Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Local_Idx : constant Natural := Find_Local_Symbol (Name);
               Sym_Idx   : constant Natural := Find_Java_Symbol (Name);
            begin
               if Local_Idx > 0 then
                  if Local_Symbols (Local_Idx).VAS_Size_Bytes > 0 then
                     return Local_Symbols (Local_Idx).VAS_Size_Bytes;
                  else
                     return Type_Size_Bytes (Local_Symbols (Local_Idx).Tag);
                  end if;
               elsif Sym_Idx > 0 then
                  if Java_Symbols (Sym_Idx).Storage = Storage_Array then
                     return Java_Array_Data_Count (Sym_Idx) *
                       Type_Size_Bytes (Java_Symbols (Sym_Idx).Tag);
                  elsif Java_Symbols (Sym_Idx).VAS_Size_Bytes > 0 then
                     return Java_Symbols (Sym_Idx).VAS_Size_Bytes;
                  else
                     return Type_Size_Bytes (Java_Symbols (Sym_Idx).Tag);
                  end if;
               else
                  return Type_Size_Bytes (Type_U64);
               end if;
            end;

         when AST_Member_Expr =>
            declare
               Left_Node   : constant Node_Index := Tree (Target_Node).Left_Child;
               Field_Node  : constant Node_Index := Tree (Target_Node).Right_Child;
               Group_Name  : constant String := Resolve_Target_Name (Left_Node);
               Field_Name  : constant String :=
                 Java_Safe_Symbol (Raw_Lexeme (Tree (Field_Node).Token_Index));
               PF_Idx      : constant Natural :=
                 Find_Parallel_Field (Group_Name, Field_Name);
               Struct_Name : constant String :=
                 Struct_Name_Of_Resolved_Name (Resolve_Target_Name (Left_Node));
               SF_Idx      : constant Natural :=
                 (if Struct_Name'Length > 0
                  then Find_Struct_Field (Struct_Name, Field_Name)
                  else 0);
            begin
               if PF_Idx > 0 then
                  return Type_Size_Bytes (Parallel_Fields (PF_Idx).Tag);
               elsif SF_Idx > 0 then
                  return Type_Size_Bytes (Struct_Fields (SF_Idx).Tag);
               else
                  return Type_Size_Bytes (Target_Tag (Target_Node));
               end if;
            end;

         when others =>
            return Type_Size_Bytes (Target_Tag (Target_Node));
      end case;
   end Target_Byte_Size;

   function Java_Array_Load_Call_Name
     (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 =>
            return "ALB_ARRAY_LOAD_I8";
         when Type_U16 | Type_S16 | Type_HW16 =>
            return "ALB_ARRAY_LOAD_I16";
         when Type_U32 | Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char =>
            return "ALB_ARRAY_LOAD_I32";
         when Type_U64 | Type_S64 | Type_HW64 |
              Type_Pure | Type_U128 | Type_S128 =>
            return "ALB_ARRAY_LOAD_I64";
         when Type_F32 =>
            return "ALB_ARRAY_LOAD_F32";
         when Type_F64 | Type_F128 =>
            return "ALB_ARRAY_LOAD_F64";
         when others =>
            return "ALB_ARRAY_LOAD_I64";
      end case;
   end Java_Array_Load_Call_Name;

   function Java_Array_Flush_Call_Name
     (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 =>
            return "ALB_ARRAY_FLUSH_I8";
         when Type_U16 | Type_S16 | Type_HW16 =>
            return "ALB_ARRAY_FLUSH_I16";
         when Type_U32 | Type_S32 | Type_HW32 | Type_Reference |
              Type_Binary | Type_Char =>
            return "ALB_ARRAY_FLUSH_I32";
         when Type_U64 | Type_S64 | Type_HW64 |
              Type_Pure | Type_U128 | Type_S128 =>
            return "ALB_ARRAY_FLUSH_I64";
         when Type_F32 =>
            return "ALB_ARRAY_FLUSH_F32";
         when Type_F64 | Type_F128 =>
            return "ALB_ARRAY_FLUSH_F64";
         when others =>
            return "ALB_ARRAY_FLUSH_I64";
      end case;
   end Java_Array_Flush_Call_Name;

   procedure Emit_Text_Value
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean);

   procedure Emit_Graphics_Integer_Expr
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean);

   procedure Emit_Graphics_Arg_List
     (List_Node : Node_Index;
      Depth     : Natural;
      Success   : in out Boolean);

   procedure Emit_Pure_Comparable_Expr
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean);

   procedure Emit_Coerced_Expression
     (Idx        : Node_Index;
      Target_Tag : ALB_Type_Tag;
      Depth      : Natural;
      Success    : in out Boolean);

   procedure Emit_Comparison_Test
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean);

   procedure Emit_Arg_List
     (List_Node : Node_Index;
      Depth     : Natural;
      Success   : in out Boolean);

   procedure Emit_Routine_Arg_List
     (Routine_Name : String;
      List_Node    : Node_Index;
      Depth        : Natural;
      Success      : in out Boolean);

   procedure Emit_Flat_Array_Index
     (Sym_Idx    : Natural;
      Index_Node : Node_Index;
      Depth      : Natural;
      Success    : in out Boolean);

   procedure Emit_Pure_Array_Access
     (Array_Name : String;
      Sym_Idx    : Natural;
      Index_Node : Node_Index;
      Depth      : Natural;
      Success    : in out Boolean);

   procedure Emit_Pure_Target_Open
     (Target_Node : Node_Index;
      Depth       : Natural;
      Success     : in out Boolean);

   procedure Emit_Condition
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean);

   procedure Emit_Text_Value
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean) is
      Tag : constant ALB_Type_Tag := Infer_Type_Tag (Idx);
   begin
      case Tag is
         when Type_Binary | Type_Char =>
            Emit_Expression (Idx, Depth + 1, Success);

         when Type_Pure =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_OF_PURE(", Success);
            if Success then
               Emit_Expression (Idx, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw (")", Success);
            end if;

         when Type_F32 | Type_F64 | Type_F128 =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_OF_DOUBLE((double)(", Success);
            if Success then
               Emit_Expression (Idx, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("))", Success);
            end if;

         when Type_Boolean =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_OF_BOOL((long)(", Success);
            if Success then
               Emit_Expression (Idx, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("))", Success);
            end if;

         when others =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_OF_LONG((long)(", Success);
            if Success then
               Emit_Expression (Idx, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("))", Success);
            end if;
      end case;
   end Emit_Text_Value;

   procedure Emit_Arg_List
     (List_Node : Node_Index;
      Depth     : Natural;
      Success   : in out Boolean) is
      Curr : Node_Index := List_Node;
   begin
      if Curr > 0 and then Tree (Curr).Kind = AST_Arg_List then
         Curr := Tree (Curr).Left_Child;
      end if;

      while Curr > 0 and then Success loop
         Emit_Expression (Curr, Depth + 1, Success);
         Curr := Tree (Curr).Next_Sibling;
         if Curr > 0 and then Success then
            Emit_Native_Java.Emit_Raw (", ", Success);
         end if;
      end loop;
   end Emit_Arg_List;

   procedure Emit_Routine_Arg_List
     (Routine_Name : String;
      List_Node    : Node_Index;
      Depth        : Natural;
      Success      : in out Boolean) is
      Curr      : Node_Index := List_Node;
      Param_Pos : Positive := 1;
      Param_Tag : ALB_Type_Tag := Type_None;
   begin
      if Curr > 0 and then Tree (Curr).Kind = AST_Arg_List then
         Curr := Tree (Curr).Left_Child;
      end if;

      while Curr > 0 and then Success loop
         Param_Tag := Find_Routine_Param_Tag (Routine_Name, Param_Pos);
         if Param_Tag = Type_None then
            Emit_Expression (Curr, Depth + 1, Success);
         else
            Emit_Coerced_Expression (Curr, Param_Tag, Depth + 1, Success);
         end if;

         Curr := Tree (Curr).Next_Sibling;
         Param_Pos := Param_Pos + 1;
         if Curr > 0 and then Success then
            Emit_Native_Java.Emit_Raw (", ", Success);
         end if;
      end loop;
   end Emit_Routine_Arg_List;

   procedure Emit_Graphics_Integer_Expr
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean) is
      Pure_Node : constant Node_Index := Graphics_Pure_Source_Node (Idx);
      Tok       : Token;
      Cast_Tag  : ALB_Type_Tag := Type_U64;
   begin
      if Pure_Node /= 0 then
         Emit_Native_Java.Emit_Raw ("ALB_PURE_VALUE(", Success);
         if Success then
            Emit_Expression (Pure_Node, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (")", Success);
         end if;
      elsif Is_Pureish_Tag (Infer_Type_Tag (Idx)) then
         Emit_Native_Java.Emit_Raw ("ALB_PURE_VALUE(", Success);
         if Success then
            Emit_Expression (Idx, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (")", Success);
         end if;
      elsif Idx /= 0 and then Tree (Idx).Kind = AST_BinOp then
         Tok := Tokens (Tree (Idx).Token_Index);
         if Tok.Kind = TOK_PIPE or else
           Tok.Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL |
             TOK_LESS | TOK_GREATER | TOK_LESS_EQUAL | TOK_GREATER_EQUAL
         then
            Emit_Expression (Idx, Depth + 1, Success);
         else
            Emit_Native_Java.Emit_Expression_Open (Success);
            if Success then
               Emit_Graphics_Integer_Expr (Tree (Idx).Left_Child, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_BinOp (Map_Binop (Tok.Kind), Success);
            end if;
            if Success then
               Emit_Graphics_Integer_Expr (Tree (Idx).Right_Child, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Expression_Close (Success);
            end if;
         end if;
      elsif Idx /= 0 and then Tree (Idx).Kind = AST_Unary_Minus then
         Emit_Native_Java.Emit_Raw ("(-", Success);
         if Success then
            Emit_Graphics_Integer_Expr (Tree (Idx).Left_Child, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (")", Success);
         end if;
      elsif Idx /= 0 and then Tree (Idx).Kind = AST_Cast_Expr then
         if Tree (Idx).Token_Index > 0 then
            Cast_Tag := Type_Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
         end if;
         if Cast_Tag = Type_None then
            Cast_Tag := Type_U64;
         end if;
         Emit_Native_Java.Emit_Raw ("(" & Java_Primitive_Type (Cast_Tag) & ")(", Success);
         if Success then
            Emit_Graphics_Integer_Expr (Tree (Idx).Left_Child, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (")", Success);
         end if;
      else
         Emit_Expression (Idx, Depth + 1, Success);
      end if;
   end Emit_Graphics_Integer_Expr;

   procedure Emit_Graphics_Arg_List
     (List_Node : Node_Index;
      Depth     : Natural;
      Success   : in out Boolean) is
      Curr : Node_Index := List_Node;
   begin
      if Curr > 0 and then Tree (Curr).Kind = AST_Arg_List then
         Curr := Tree (Curr).Left_Child;
      end if;

      while Curr > 0 and then Success loop
         Emit_Graphics_Integer_Expr (Curr, Depth + 1, Success);
         Curr := Tree (Curr).Next_Sibling;
         if Curr > 0 and then Success then
            Emit_Native_Java.Emit_Raw (", ", Success);
         end if;
      end loop;
   end Emit_Graphics_Arg_List;

   procedure Emit_Pure_Comparable_Expr
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean) is
   begin
      if Is_Pureish_Tag (Infer_Type_Tag (Idx)) then
         Emit_Expression (Idx, Depth + 1, Success);
      else
         Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST((long)(", Success);
         if Success then
            Emit_Expression (Idx, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw ("), 1)", Success);
         end if;
      end if;
   end Emit_Pure_Comparable_Expr;

   procedure Emit_Coerced_Expression
     (Idx        : Node_Index;
      Target_Tag : ALB_Type_Tag;
      Depth      : Natural;
      Success    : in out Boolean) is
      Source_Tag : constant ALB_Type_Tag := Infer_Type_Tag (Idx);
   begin
      if Target_Tag = Type_None then
         Emit_Expression (Idx, Depth + 1, Success);
      elsif Is_Pureish_Tag (Target_Tag) then
         if Is_Pureish_Tag (Source_Tag) then
            Emit_Expression (Idx, Depth + 1, Success);
         else
            Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST((long)(", Success);
            if Success then
               Emit_Expression (Idx, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("), 1)", Success);
            end if;
         end if;
      elsif Is_Pureish_Tag (Source_Tag) then
         Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Prefix (Target_Tag), Success);
         case Target_Tag is
            when Type_F32 | Type_F64 | Type_F128 =>
               if Success then
                  Emit_Native_Java.Emit_Raw ("ALB_PURE_DOUBLE(", Success);
               end if;
               if Success then
                  Emit_Expression (Idx, Depth + 1, Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (")", Success);
               end if;

            when others =>
               if Success then
                  Emit_Native_Java.Emit_Raw ("ALB_PURE_VALUE(", Success);
               end if;
               if Success then
                  Emit_Expression (Idx, Depth + 1, Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (")", Success);
               end if;
         end case;
         if Success then
            Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Suffix (Target_Tag), Success);
         end if;
      else
         Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Prefix (Target_Tag), Success);
         if Success then
            Emit_Expression (Idx, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Suffix (Target_Tag), Success);
         end if;
      end if;
   end Emit_Coerced_Expression;

   procedure Emit_Comparison_Test
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean) is
      Tok : Token;
      function Is_Logical_Operator (Kind : Token_Kind) return Boolean is
      begin
         return Kind in TOK_AND | TOK_OR | TOK_XOR;
      end Is_Logical_Operator;

      function Is_Logical_Binop_Node (Node : Node_Index) return Boolean is
      begin
         return Node /= 0
           and then Tree (Node).Kind = AST_BinOp
           and then Tree (Node).Token_Index > 0
           and then Is_Logical_Operator (Tokens (Tree (Node).Token_Index).Kind);
      end Is_Logical_Binop_Node;

      procedure Emit_Logical_Operator
        (Kind          : Token_Kind;
         Local_Success : in out Boolean) is
      begin
         case Kind is
            when TOK_AND =>
               Emit_Native_Java.Emit_Raw (" && ", Local_Success);

            when TOK_OR =>
               Emit_Native_Java.Emit_Raw (" || ", Local_Success);

            when TOK_XOR =>
               Emit_Native_Java.Emit_Raw (" ^ ", Local_Success);

            when others =>
               Emit_Native_Java.Emit_Raw (" || ", Local_Success);
         end case;
      end Emit_Logical_Operator;

      procedure Emit_Basic_Comparison
        (Left_Node     : Node_Index;
         Op_Kind       : Token_Kind;
         Right_Node    : Node_Index;
         Local_Success : in out Boolean) is
         Left_Tag  : constant ALB_Type_Tag := Infer_Type_Tag (Left_Node);
         Right_Tag : constant ALB_Type_Tag := Infer_Type_Tag (Right_Node);
      begin
         if (Left_Tag in Type_Binary | Type_Char)
           and then (Right_Tag in Type_Binary | Type_Char)
         then
            Emit_Native_Java.Emit_Raw ("(ALB_TEXT_COMPARE(", Local_Success);
            if Local_Success then
               Emit_Expression (Left_Node, Depth + 1, Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_Raw (", ", Local_Success);
            end if;
            if Local_Success then
               Emit_Expression (Right_Node, Depth + 1, Local_Success);
            end if;
            if Local_Success then
               case Op_Kind is
                  when TOK_ASSIGN | TOK_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") == 0)", Local_Success);
                  when TOK_NOT_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") != 0)", Local_Success);
                  when TOK_LESS =>
                     Emit_Native_Java.Emit_Raw (") < 0)", Local_Success);
                  when TOK_GREATER =>
                     Emit_Native_Java.Emit_Raw (") > 0)", Local_Success);
                  when TOK_LESS_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") <= 0)", Local_Success);
                  when TOK_GREATER_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") >= 0)", Local_Success);
                  when others =>
                     Emit_Native_Java.Emit_Raw (") == 0)", Local_Success);
               end case;
            end if;

         elsif Is_Pureish_Tag (Left_Tag) or else Is_Pureish_Tag (Right_Tag) then
            Emit_Native_Java.Emit_Raw ("(ALB_PURE_COMPARE(", Local_Success);
            if Local_Success then
               Emit_Pure_Comparable_Expr (Left_Node, Depth + 1, Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_Raw (", ", Local_Success);
            end if;
            if Local_Success then
               Emit_Pure_Comparable_Expr (Right_Node, Depth + 1, Local_Success);
            end if;
            if Local_Success then
               case Op_Kind is
                  when TOK_ASSIGN | TOK_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") == 0)", Local_Success);
                  when TOK_NOT_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") != 0)", Local_Success);
                  when TOK_LESS =>
                     Emit_Native_Java.Emit_Raw (") < 0)", Local_Success);
                  when TOK_GREATER =>
                     Emit_Native_Java.Emit_Raw (") > 0)", Local_Success);
                  when TOK_LESS_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") <= 0)", Local_Success);
                  when TOK_GREATER_EQUAL =>
                     Emit_Native_Java.Emit_Raw (") >= 0)", Local_Success);
                  when others =>
                     Emit_Native_Java.Emit_Raw (") == 0)", Local_Success);
               end case;
            end if;

         else
            Emit_Native_Java.Emit_Raw ("(", Local_Success);
            if Local_Success then
               Emit_Expression (Left_Node, Depth + 1, Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_BinOp (Map_Binop (Op_Kind), Local_Success);
            end if;
            if Local_Success then
               Emit_Expression (Right_Node, Depth + 1, Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_Raw (")", Local_Success);
            end if;
         end if;
      end Emit_Basic_Comparison;

      procedure Emit_Assign_Comparison
        (Left_Node     : Node_Index;
         Right_Node    : Node_Index;
         Local_Success : in out Boolean);

      procedure Emit_Assign_Comparison
        (Left_Node     : Node_Index;
         Right_Node    : Node_Index;
         Local_Success : in out Boolean) is
         Logic_Node : Node_Index := 0;
         Logic_Tok  : Token;
      begin
         if Is_Logical_Binop_Node (Left_Node) then
            Logic_Node := Left_Node;
            Logic_Tok := Tokens (Tree (Logic_Node).Token_Index);
            Emit_Native_Java.Emit_Raw ("(", Local_Success);
            if Local_Success then
               Emit_Condition (Tree (Logic_Node).Left_Child, Depth + 1, Local_Success);
            end if;
            if Local_Success then
               Emit_Logical_Operator (Logic_Tok.Kind, Local_Success);
            end if;
            if Local_Success then
               Emit_Assign_Comparison
                 (Tree (Logic_Node).Right_Child,
                  Right_Node,
                  Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_Raw (")", Local_Success);
            end if;
            return;
         end if;

         if Right_Node /= 0
           and then Tree (Right_Node).Kind = AST_BinOp
           and then Tree (Right_Node).Token_Index > 0
           and then Tokens (Tree (Right_Node).Token_Index).Kind = TOK_ASSIGN
           and then Is_Logical_Binop_Node (Tree (Right_Node).Left_Child)
         then
            Logic_Node := Tree (Right_Node).Left_Child;
            Logic_Tok := Tokens (Tree (Logic_Node).Token_Index);
            Emit_Native_Java.Emit_Raw ("(", Local_Success);
            if Local_Success then
               Emit_Assign_Comparison
                 (Left_Node,
                  Tree (Logic_Node).Left_Child,
                  Local_Success);
            end if;
            if Local_Success then
               Emit_Logical_Operator (Logic_Tok.Kind, Local_Success);
            end if;
            if Local_Success then
               Emit_Assign_Comparison
                 (Tree (Logic_Node).Right_Child,
                  Tree (Right_Node).Right_Child,
                  Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_Raw (")", Local_Success);
            end if;
            return;
         end if;

         Emit_Basic_Comparison
           (Left_Node,
            TOK_ASSIGN,
            Right_Node,
            Local_Success);
      end Emit_Assign_Comparison;
   begin
      if Idx = 0 or else Tree (Idx).Kind /= AST_BinOp or else Tree (Idx).Token_Index <= 0 then
         Emit_Native_Java.Emit_Raw ("false", Success);
         return;
      end if;

      Tok := Tokens (Tree (Idx).Token_Index);
      if Tok.Kind = TOK_ASSIGN then
         Emit_Assign_Comparison
           (Tree (Idx).Left_Child,
            Tree (Idx).Right_Child,
            Success);
      elsif Is_Comparison_Operator (Tok.Kind) then
         Emit_Basic_Comparison
           (Tree (Idx).Left_Child,
            Tok.Kind,
            Tree (Idx).Right_Child,
            Success);
      else
         Emit_Native_Java.Emit_Raw ("(", Success);
         if Success then
            Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_BinOp (Map_Binop (Tok.Kind), Success);
         end if;
         if Success then
            Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (")", Success);
         end if;
      end if;
   end Emit_Comparison_Test;

   procedure Emit_Flat_Array_Index
     (Sym_Idx    : Natural;
      Index_Node : Node_Index;
      Depth      : Natural;
      Success    : in out Boolean) is
      Curr   : Node_Index := Index_Node;
      Factor : Natural := 1;
   begin
      if Sym_Idx = 0 or else Java_Symbols (Sym_Idx).Rank <= 1 then
         if Curr > 0 then
            Emit_Native_Java.Emit_Raw ("((int)(", Success);
            if Success then
               Emit_Expression (Curr, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("))", Success);
            end if;
         else
            Emit_Native_Java.Emit_Raw ("1", Success);
         end if;
         return;
      end if;

      Emit_Native_Java.Emit_Raw ("(", Success);
      for Dim in 1 .. Java_Symbols (Sym_Idx).Rank loop
         Factor := 1;
         for Next_Dim in Dim + 1 .. Java_Symbols (Sym_Idx).Rank loop
            Factor := Factor * Java_Symbols (Sym_Idx).Dims (Next_Dim);
         end loop;

         if Dim < Java_Symbols (Sym_Idx).Rank then
            Emit_Native_Java.Emit_Raw ("((((int)(", Success);
            if Curr > 0 then
               Emit_Expression (Curr, Depth + 1, Success);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Native_Java.Emit_Raw ("1", Success);
            end if;
            Emit_Native_Java.Emit_Raw (")) - 1) * " & Trim_Image (Natural'Image (Factor)) & " + ", Success);
         else
            if Curr > 0 then
               Emit_Native_Java.Emit_Raw ("((int)(", Success);
               if Success then
                  Emit_Expression (Curr, Depth + 1, Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw ("))", Success);
               end if;
            else
               Emit_Native_Java.Emit_Raw ("1", Success);
            end if;
         end if;
      end loop;
      Emit_Native_Java.Emit_Raw (")", Success);
   end Emit_Flat_Array_Index;

   procedure Emit_Pure_Array_Access
     (Array_Name : String;
      Sym_Idx    : Natural;
      Index_Node : Node_Index;
      Depth      : Natural;
      Success    : in out Boolean) is
   begin
      Emit_Native_Java.Emit_Raw ("ALB_PURE_AT(" & Array_Name & ", ", Success);
      if Success then
         Emit_Flat_Array_Index (Sym_Idx, Index_Node, Depth + 1, Success);
      end if;
      if Success then
         Emit_Native_Java.Emit_Raw (")", Success);
      end if;
   end Emit_Pure_Array_Access;

   procedure Emit_Pure_Target_Open
     (Target_Node : Node_Index;
      Depth       : Natural;
      Success     : in out Boolean) is
      Sym_Idx   : Natural := 0;
      Local_Idx : Natural := 0;
   begin
      if Target_Node = 0 or else not Success then
         return;
      end if;

      case Tree (Target_Node).Kind is
         when AST_Var_Expr =>
            declare
               Resolved : constant String :=
                 Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
            begin
               Local_Idx := Find_Local_Symbol (Resolved);
               Sym_Idx := Find_Java_Symbol (Resolved);

               if Tree (Target_Node).Left_Child /= 0
                 and then Sym_Idx > 0
                 and then Java_Symbols (Sym_Idx).Storage = Storage_Array
               then
                  Emit_Native_Java.Emit_Raw ("ALB_COPY_PURE_AT(" & Resolved & ", ", Success);
                  if Success then
                     Emit_Flat_Array_Index (Sym_Idx, Tree (Target_Node).Left_Child, Depth + 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw (", ", Success);
                  end if;
               elsif Local_Idx > 0 or else Sym_Idx > 0 then
                  Emit_Native_Java.Emit_Raw ("ALB_COPY_PURE(" & Resolved & ", ", Success);
               else
                  Emit_Native_Java.Emit_Raw ("ALB_COPY_PURE(ALB_PURE_TMP(), ", Success);
               end if;
            end;

         when AST_Member_Expr =>
            declare
               Left_Node   : constant Node_Index := Tree (Target_Node).Left_Child;
               Field_Node  : constant Node_Index := Tree (Target_Node).Right_Child;
               Group_Name  : constant String := Resolve_Target_Name (Left_Node);
               Field_Name  : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Field_Node).Token_Index));
               PF_Idx      : constant Natural := Find_Parallel_Field (Group_Name, Field_Name);
               Backing_Sym : Natural := 0;
            begin
               if PF_Idx > 0 then
                  Backing_Sym := Find_Java_Symbol
                    (Parallel_Fields (PF_Idx).Backing_Name (1 .. Parallel_Fields (PF_Idx).Backing_Name_Len));
                  Emit_Native_Java.Emit_Raw
                    ("ALB_COPY_PURE_AT(" &
                     Parallel_Fields (PF_Idx).Backing_Name (1 .. Parallel_Fields (PF_Idx).Backing_Name_Len) &
                     ", ",
                     Success);
                  if Success then
                     if Tree (Left_Node).Kind = AST_Var_Expr then
                        Emit_Flat_Array_Index (Backing_Sym, Tree (Left_Node).Left_Child, Depth + 1, Success);
                     else
                        Emit_Native_Java.Emit_Raw ("1", Success);
                     end if;
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw (", ", Success);
                  end if;
               else
                  Emit_Native_Java.Emit_Raw ("ALB_COPY_PURE(ALB_PURE_TMP(), ", Success);
               end if;
            end;

         when others =>
            Emit_Native_Java.Emit_Raw ("ALB_COPY_PURE(ALB_PURE_TMP(), ", Success);
      end case;
   end Emit_Pure_Target_Open;

   procedure Emit_Condition
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean) is
      Tok : Token;
   begin
      if Idx = 0 then
         Emit_Native_Java.Emit_Raw ("false", Success);
         return;
      end if;

      if Tree (Idx).Kind = AST_True then
         Emit_Native_Java.Emit_Raw ("true", Success);
      elsif Tree (Idx).Kind = AST_False then
         Emit_Native_Java.Emit_Raw ("false", Success);
      elsif Tree (Idx).Kind = AST_BinOp and then Tree (Idx).Token_Index > 0 then
         Tok := Tokens (Tree (Idx).Token_Index);
         if Is_Comparison_Operator (Tok.Kind) then
            Emit_Comparison_Test (Idx, Depth + 1, Success);
         else
            Emit_Native_Java.Emit_Raw ("(", Success);
            if Is_Pureish_Tag (Infer_Type_Tag (Idx)) then
               Emit_Native_Java.Emit_Raw ("ALB_PURE_VALUE(", Success);
               if Success then
                  Emit_Expression (Idx, Depth + 1, Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (")", Success);
               end if;
            else
               Emit_Expression (Idx, Depth + 1, Success);
            end if;
            Emit_Native_Java.Emit_Raw (") != 0", Success);
         end if;
      else
         Emit_Native_Java.Emit_Raw ("(", Success);
         if Is_Pureish_Tag (Infer_Type_Tag (Idx)) then
            Emit_Native_Java.Emit_Raw ("ALB_PURE_VALUE(", Success);
            if Success then
               Emit_Expression (Idx, Depth + 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw (")", Success);
            end if;
         else
            Emit_Expression (Idx, Depth + 1, Success);
         end if;
         Emit_Native_Java.Emit_Raw (") != 0", Success);
      end if;
   end Emit_Condition;

   procedure Emit_Expression
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean) is
      Local_Success : Boolean := Success;
      Tok : Token;
      Sym_Idx : Natural := 0;
      Local_Idx : Natural := 0;
   begin
      if not Local_Success then
         return;
      end if;

      if Depth > 64 or else Idx = 0 then
         Emit_Native_Java.Emit_Raw ("0", Local_Success);
         Success := Local_Success;
         return;
      end if;

      case Tree (Idx).Kind is
         when AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
            Emit_Native_Java.Emit_Raw (Java_Numeric_Text (Idx), Local_Success);

         when AST_String_Expr =>
            Emit_Native_Java.Emit_Raw ("ALB_INTERN(", Local_Success);
            if Local_Success then
               Emit_Native_Java.Emit_String_Literal (Strip_String_Node (Idx), Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_Raw (")", Local_Success);
            end if;

         when AST_Const_Ref =>
            declare
               Const_Name : constant String := Raw_Lexeme (Tree (Idx).Token_Index);
               Const_Idx  : constant Natural := Find_Const (Const_Name);
            begin
               if Const_Idx > 0 then
                  Emit_Native_Java.Emit_Raw
                    (Consts (Const_Idx).Value (1 .. Consts (Const_Idx).Value_Len),
                     Local_Success);
               else
                  Emit_Native_Java.Emit_Raw ("0", Local_Success);
               end if;
            end;

         when AST_Var_Expr =>
            declare
               Safe_Name : constant String :=
                 Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
               Const_Idx : constant Natural := Find_Const (Raw_Lexeme (Tree (Idx).Token_Index));
            begin
               if Const_Idx > 0 then
                  Emit_Native_Java.Emit_Raw
                    (Consts (Const_Idx).Value (1 .. Consts (Const_Idx).Value_Len),
                     Local_Success);
               else
                  Local_Idx := Find_Local_Symbol (Safe_Name);
                  Sym_Idx := Find_Java_Symbol (Safe_Name);

                  if Tree (Idx).Left_Child /= 0 and then Sym_Idx > 0 and then Java_Symbols (Sym_Idx).Storage = Storage_Array then
                     if Java_Symbols (Sym_Idx).Tag = Type_Pure
                       or else Java_Symbols (Sym_Idx).Tag = Type_U128
                       or else Java_Symbols (Sym_Idx).Tag = Type_S128
                     then
                        Emit_Pure_Array_Access
                          (Safe_Name,
                           Sym_Idx,
                           Tree (Idx).Left_Child,
                           Depth + 1,
                           Local_Success);
                     else
                        Emit_Native_Java.Emit_Raw (Safe_Name & "[", Local_Success);
                        if Local_Success then
                           Emit_Flat_Array_Index (Sym_Idx, Tree (Idx).Left_Child, Depth + 1, Local_Success);
                        end if;
                        if Local_Success then
                           Emit_Native_Java.Emit_Raw ("]", Local_Success);
                        end if;
                     end if;
                  else
                     Emit_Native_Java.Emit_Raw
                       (Java_Read_Expr (Safe_Name),
                        Local_Success);
                  end if;
               end if;
            end;

         when AST_Member_Expr =>
            declare
               Left_Node  : constant Node_Index := Tree (Idx).Left_Child;
               Field_Node : constant Node_Index := Tree (Idx).Right_Child;
               Group_Name : constant String := Resolve_Target_Name (Left_Node);
               Field_Name : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Field_Node).Token_Index));
               PF_Idx     : constant Natural := Find_Parallel_Field (Group_Name, Field_Name);
               Struct_Name : constant String := Struct_Name_Of_Resolved_Name (Group_Name);
               SF_Idx     : constant Natural :=
                 (if Struct_Name'Length > 0
                  then Find_Struct_Field (Struct_Name, Field_Name)
                  else 0);
               Backing_Sym : Natural := 0;
            begin
               if PF_Idx > 0 then
                  Backing_Sym := Find_Java_Symbol
                    (Parallel_Fields (PF_Idx).Backing_Name (1 .. Parallel_Fields (PF_Idx).Backing_Name_Len));
                  if Backing_Sym > 0 and then
                    (Java_Symbols (Backing_Sym).Tag = Type_Pure
                    or else Java_Symbols (Backing_Sym).Tag = Type_U128
                    or else Java_Symbols (Backing_Sym).Tag = Type_S128)
                  then
                     Emit_Pure_Array_Access
                       (Parallel_Fields (PF_Idx).Backing_Name (1 .. Parallel_Fields (PF_Idx).Backing_Name_Len),
                        Backing_Sym,
                        Tree (Left_Node).Left_Child,
                        Depth + 1,
                        Local_Success);
                  else
                     Emit_Native_Java.Emit_Raw
                       (Parallel_Fields (PF_Idx).Backing_Name (1 .. Parallel_Fields (PF_Idx).Backing_Name_Len) & "[",
                        Local_Success);
                     if Local_Success then
                        if Tree (Left_Node).Kind = AST_Var_Expr then
                           Emit_Flat_Array_Index (Backing_Sym, Tree (Left_Node).Left_Child, Depth + 1, Local_Success);
                        else
                           Emit_Native_Java.Emit_Raw ("1", Local_Success);
                        end if;
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw ("]", Local_Success);
                     end if;
                  end if;
               elsif SF_Idx > 0 then
                  Emit_Native_Java.Emit_Raw
                    (Java_VAS_Load_Expr
                       (Struct_Fields (SF_Idx).Tag,
                        "(" & Symbol_Address_Expr (Group_Name) & ") + " &
                        Trim_Image (Natural'Image (Struct_Fields (SF_Idx).Offset_Bytes))),
                     Local_Success);
               else
                  Emit_Native_Java.Emit_Raw ("0", Local_Success);
               end if;
            end;

         when AST_True =>
            Emit_Native_Java.Emit_Raw ("1", Local_Success);

         when AST_False =>
            Emit_Native_Java.Emit_Raw ("0", Local_Success);

         when AST_Constructor =>
            declare
               TName : constant String := Upper_ASCII (Raw_Lexeme (Tree (Idx).Token_Index));
               Arg_1 : Node_Index := Tree (Idx).Left_Child;
               Arg_2 : Node_Index := 0;
            begin
               if TName = "PURE" or else TName = "RATIONAL" then
                  if Arg_1 /= 0 then
                     Arg_2 := Tree (Arg_1).Next_Sibling;
                  end if;
                  Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST(", Local_Success);
                  if Local_Success and then Arg_1 /= 0 then Emit_Expression (Arg_1, Depth + 1, Local_Success); end if;
                  if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
                  if Local_Success and then Arg_2 /= 0 then Emit_Expression (Arg_2, Depth + 1, Local_Success); else Emit_Native_Java.Emit_Raw ("1", Local_Success); end if;
                  if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;
               elsif TName = "U128" or else TName = "S128" then
                  Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST(", Local_Success);
                  if Local_Success and then Arg_1 /= 0 then
                     Emit_Expression (Arg_1, Depth + 1, Local_Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw (", 1)", Local_Success);
                  end if;
               elsif Type_Tag_From_Name (TName) /= Type_None then
                  declare
                     Cast_Tag : constant ALB_Type_Tag := Type_Tag_From_Name (TName);
                  begin
                     Emit_Native_Java.Emit_Raw ("(", Local_Success);
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw (Java_Primitive_Type (Cast_Tag) & ")(", Local_Success);
                     end if;
                     if Local_Success and then Arg_1 /= 0 then
                        Emit_Coerced_Expression (Arg_1, Cast_Tag, Depth + 1, Local_Success);
                     else
                        Emit_Native_Java.Emit_Raw ("0", Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw (")", Local_Success);
                     end if;
                  end;
               elsif Tree (Idx).Left_Child /= 0 then
                  Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);
               else
                  Emit_Native_Java.Emit_Raw ("0", Local_Success);
               end if;
            end;

         when AST_Cast_Expr =>
            declare
               Cast_Tag : constant ALB_Type_Tag :=
                 (if Tree (Idx).Token_Index > 0
                  then Type_Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index))
                  else Type_U64);
            begin
               if Cast_Tag = Type_Pure or else Cast_Tag = Type_U128 or else Cast_Tag = Type_S128 then
                  Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST(", Local_Success);
                  if Local_Success then
                     Emit_Coerced_Expression (Tree (Idx).Left_Child, Cast_Tag, Depth + 1, Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw (", 1)", Local_Success);
                  end if;
               else
                  Emit_Native_Java.Emit_Raw ("(" & Java_Primitive_Type (Cast_Tag) & ")(", Local_Success);
                  if Local_Success then
                     Emit_Coerced_Expression (Tree (Idx).Left_Child, Cast_Tag, Depth + 1, Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw (")", Local_Success);
                  end if;
               end if;
            end;

         when AST_BinOp =>
            Tok := Tokens (Tree (Idx).Token_Index);
            if Tok.Kind = TOK_PIPE then
               Emit_Native_Java.Emit_Raw ("ALB_TEXT_CONCAT(", Local_Success);
               if Local_Success then
                  Emit_Text_Value (Tree (Idx).Left_Child, Depth + 1, Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_Raw (", ", Local_Success);
               end if;
               if Local_Success then
                  Emit_Text_Value (Tree (Idx).Right_Child, Depth + 1, Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_Raw (")", Local_Success);
               end if;
            elsif Tok.Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL |
                               TOK_LESS | TOK_GREATER |
                               TOK_LESS_EQUAL | TOK_GREATER_EQUAL
            then
               Emit_Native_Java.Emit_Raw ("(", Local_Success);
               if Local_Success then
                  Emit_Comparison_Test (Idx, Depth + 1, Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_Raw (" ? 1 : 0)", Local_Success);
               end if;
            elsif Tok.Kind = TOK_POW then
               declare
                  Result_Tag : constant ALB_Type_Tag := Infer_Type_Tag (Idx);
               begin
                  if Result_Tag = Type_F64 or else Result_Tag = Type_F32 then
                     Emit_Native_Java.Emit_Raw ("Math.pow((double)(", Local_Success);
                     if Local_Success then
                        Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw ("), (double)(", Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw ("))", Local_Success);
                     end if;
                  else
                     Emit_Native_Java.Emit_Raw ("((long)Math.pow((double)(", Local_Success);
                     if Local_Success then
                        Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw ("), (double)(", Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw (")))", Local_Success);
                     end if;
                  end if;
               end;
            else
               Emit_Native_Java.Emit_Expression_Open (Local_Success);
               if Local_Success then
                  Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_BinOp (Map_Binop (Tok.Kind), Local_Success);
               end if;
               if Local_Success then
                  Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_Expression_Close (Local_Success);
               end if;
            end if;

         when AST_Str_Len =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_LEN(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Str_Left =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_LEFT(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success then Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Str_Right =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_RIGHT(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success then Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Str_Mid =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_MID(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success then Emit_Arg_List (Tree (Idx).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Str_Concat =>
            Emit_Native_Java.Emit_Raw ("ALB_TEXT_CONCAT(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success then Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Rnd_Expr =>
            Emit_Native_Java.Emit_Raw ("ALB_RND(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Choose =>
            Emit_Native_Java.Emit_Raw ("ALB_CHOOSE(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success and then Tree (Idx).Right_Child > 0 then Emit_Expression (Tree (Tree (Idx).Right_Child).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success and then Tree (Idx).Right_Child > 0 then Emit_Expression (Tree (Tree (Idx).Right_Child).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Key_State =>
            Emit_Native_Java.Emit_Raw ("ALB_KEY(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Mouse_X =>
            Emit_Native_Java.Emit_Raw ("ALB_MOUSE_X()", Local_Success);
         when AST_Mouse_Y =>
            Emit_Native_Java.Emit_Raw ("ALB_MOUSE_Y()", Local_Success);
         when AST_Mouse_Wheel =>
            Emit_Native_Java.Emit_Raw ("ALB_MOUSE_WHEEL()", Local_Success);
         when AST_VMouse_X =>
            Emit_Native_Java.Emit_Raw ("ALB_VIRTUAL_MOUSE_X()", Local_Success);
         when AST_VMouse_Y =>
            Emit_Native_Java.Emit_Raw ("ALB_VIRTUAL_MOUSE_Y()", Local_Success);
         when AST_SCREEN_WIDTH =>
            Emit_Native_Java.Emit_Raw ("ALB_SCREEN_WIDTH()", Local_Success);
         when AST_SCREEN_HEIGHT =>
            Emit_Native_Java.Emit_Raw ("ALB_SCREEN_HEIGHT()", Local_Success);
         when AST_VIRTUAL_WIDTH =>
            Emit_Native_Java.Emit_Raw ("ALB_VIRTUAL_WIDTH()", Local_Success);
         when AST_VIRTUAL_HEIGHT =>
            Emit_Native_Java.Emit_Raw ("ALB_VIRTUAL_HEIGHT()", Local_Success);

         when AST_Mouse_Click =>
            Emit_Native_Java.Emit_Raw ("ALB_MOUSE_CLICK(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Read_Pixel =>
            Emit_Native_Java.Emit_Raw ("ALB_READ_PIXEL(", Local_Success);
            if Local_Success then Emit_Graphics_Arg_List (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Peek_Expr =>
            Emit_Native_Java.Emit_Raw ("ALB_PEEK(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Deref_Expr =>
            Emit_Native_Java.Emit_Raw ("ALB_DEREF(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_File_Open =>
            Emit_Native_Java.Emit_Raw ("ALB_FILE_OPEN(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success then Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_File_Len =>
            Emit_Native_Java.Emit_Raw ("ALB_FILE_LEN(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_File_Seek =>
            Emit_Native_Java.Emit_Raw ("ALB_FILE_SEEK(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success then Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_File_Read =>
            Emit_Native_Java.Emit_Raw ("ALB_FILE_READ(", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (", ", Local_Success); end if;
            if Local_Success then Emit_Expression (Tree (Idx).Right_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_SizeOf_Expr =>
            Emit_Native_Java.Emit_Raw
              (Trim_Image (Natural'Image (Type_Size_Bytes (Infer_Type_Tag (Tree (Idx).Left_Child)))),
               Local_Success);

         when AST_TypeOf_Expr =>
            Emit_Native_Java.Emit_Raw ("ALB_INTERN(", Local_Success);
            if Local_Success then
               Emit_Native_Java.Emit_String_Literal
                 (ALB_Type_Tag'Image (Infer_Type_Tag (Tree (Idx).Left_Child)),
                  Local_Success);
            end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_OffsetOf_Expr =>
            declare
               Struct_Name : constant String := Resolve_Target_Name (Tree (Idx).Left_Child);
               Field_Name  : constant String := Resolve_Target_Name (Tree (Idx).Right_Child);
               SF_Idx      : constant Natural := Find_Struct_Field (Struct_Name, Field_Name);
            begin
               if SF_Idx > 0 then
                  Emit_Native_Java.Emit_Raw
                    (Trim_Image (Natural'Image (Struct_Fields (SF_Idx).Offset_Bytes)),
                     Local_Success);
               else
                  Emit_Native_Java.Emit_Raw ("0", Local_Success);
               end if;
            end;

         when AST_Query | AST_Knows_Query =>
            declare
               Pred_Name : constant String := Predicate_Name_Of (Idx);
               Arg_Node  : constant Node_Index := Predicate_Arg_Node (Idx);
            begin
               Emit_Native_Java.Emit_Raw ("ALB_KB_PROVE(ALB_HASH(", Local_Success);
               if Local_Success then
                  Emit_Native_Java.Emit_String_Literal (Pred_Name, Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_Raw ("), ", Local_Success);
               end if;
               if Arg_Node /= 0 then
                  if Local_Success then
                     Emit_Expression (Arg_Node, Depth + 1, Local_Success);
                  end if;
               elsif Local_Success then
                  Emit_Native_Java.Emit_Raw ("0", Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_Raw (")", Local_Success);
               end if;
            end;

         when AST_Find_Query =>
            declare
               Pred_Name : constant String := Predicate_Name_Of (Idx);
            begin
               Emit_Native_Java.Emit_Raw ("ALB_KB_FIND_FIRST(ALB_HASH(", Local_Success);
               if Local_Success then
                  Emit_Native_Java.Emit_String_Literal (Pred_Name, Local_Success);
               end if;
               if Local_Success then
                  Emit_Native_Java.Emit_Raw ("))", Local_Success);
               end if;
            end;

         when AST_Temporal_Ref =>
            declare
               Base_Name : constant String :=
                 (if Tree (Idx).Left_Child /= 0 and then Tree (Tree (Idx).Left_Child).Token_Index > 0
                  then Resolve_Symbol_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index))
                  else "");
               T_Idx     : constant Natural := Find_Temporal_Symbol (Base_Name);
            begin
               if Tree (Idx).Token_Index > 0 then
                  case Tokens (Tree (Idx).Token_Index).Kind is
                     when Tok_Timeline =>
                        if T_Idx > 0 then
                           Emit_Native_Java.Emit_Raw
                             ("(long)(ALB_VAS_TEMP_BASE + " &
                              Trim_Image
                                (Natural'Image (Temporal_Symbols (T_Idx).Timeline_Offset)) &
                              ")",
                              Local_Success);
                        else
                           Emit_Native_Java.Emit_Raw ("0L", Local_Success);
                        end if;

                     when Tok_Past =>
                        if T_Idx > 0 and then Temporal_Symbols (T_Idx).History_Size > 0 then
                           Emit_Native_Java.Emit_Raw
                             (Java_VAS_Load_Expr
                                (Temporal_Symbols (T_Idx).Tag,
                                 "(ALB_VAS_TEMP_BASE + " &
                                 Trim_Image (Natural'Image (Temporal_Symbols (T_Idx).Timeline_Offset)) &
                                 " + (((" & Base_Name & "_head[0] + " &
                                 Trim_Image
                                   (Natural'Image (Temporal_Symbols (T_Idx).History_Size - 1)) &
                                 ") % " &
                                 Trim_Image
                                   (Natural'Image (Temporal_Symbols (T_Idx).History_Size)) &
                                 ") * " &
                                 Trim_Image
                                   (Natural'Image (Temporal_Symbols (T_Idx).Slot_Size_Bytes)) &
                                 "))"),
                              Local_Success);
                        else
                           Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);
                        end if;

                     when Tok_Now | Tok_Future =>
                        Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);

                     when others =>
                        Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);
                  end case;
               else
                  Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success);
               end if;
            end;

         when AST_AddressOf | AST_Ref_Expr =>
            Emit_Native_Java.Emit_Raw
              ("(long)(" & Target_Address_Expr (Tree (Idx).Left_Child) & ")",
               Local_Success);

         when AST_Inline_Java_Expr =>
            Emit_Native_Java.Emit_Raw
              (Extract_Java_Block_Body (Raw_Lexeme (Tree (Idx).Token_Index)),
               Local_Success);

         when AST_Atom =>
            Emit_Native_Java.Emit_Raw ("ALB_INTERN(", Local_Success);
            if Local_Success then
               Emit_Native_Java.Emit_String_Literal
                 (Raw_Lexeme (Tree (Idx).Token_Index),
                  Local_Success);
            end if;
            if Local_Success then
               Emit_Native_Java.Emit_Raw (")", Local_Success);
            end if;

         when AST_Not =>
            Emit_Native_Java.Emit_Raw ("((", Local_Success);
            if Local_Success then Emit_Condition (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (") ? 0 : 1)", Local_Success); end if;

         when AST_Unary_Minus =>
            Emit_Native_Java.Emit_Raw ("(-", Local_Success);
            if Local_Success then Emit_Expression (Tree (Idx).Left_Child, Depth + 1, Local_Success); end if;
            if Local_Success then Emit_Native_Java.Emit_Raw (")", Local_Success); end if;

         when AST_Func_Call =>
            declare
               Call_Name  : constant String := Resolve_ALB_Call_Name (Tree (Idx).Left_Child);
               Call_Upper : constant String := Upper_ASCII (Call_Name);
               Bare_Done  : Boolean := False;
               Arg_1      : Node_Index := 0;
               Arg_2      : Node_Index := 0;
               Cast_Tag   : ALB_Type_Tag := Type_None;
            begin
               if Tree (Idx).Right_Child > 0 then
                  if Tree (Tree (Idx).Right_Child).Kind = AST_Arg_List then
                     Arg_1 := Tree (Tree (Idx).Right_Child).Left_Child;
                  else
                     Arg_1 := Tree (Idx).Right_Child;
                  end if;
               end if;
               if Arg_1 > 0 then
                  Arg_2 := Tree (Arg_1).Next_Sibling;
               end if;

               if Call_Upper = "GETTICKCOUNT" then
                  Emit_Native_Java.Emit_Raw ("alb_tick_counter[0]", Local_Success);
                  Bare_Done := True;
               elsif Call_Upper = "PROVE" then
                  Emit_Native_Java.Emit_Raw ("ALB_KB_PROVE(ALB_HASH(", Local_Success);
                  if Local_Success then
                     Emit_Native_Java.Emit_String_Literal (Predicate_Name_Of (Arg_1), Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw ("), ", Local_Success);
                  end if;
                  if Predicate_Arg_Node (Arg_1) /= 0 then
                     if Local_Success then
                        Emit_Expression (Predicate_Arg_Node (Arg_1), Depth + 1, Local_Success);
                     end if;
                  elsif Local_Success then
                     Emit_Native_Java.Emit_Raw ("0", Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw (")", Local_Success);
                  end if;
                  Bare_Done := True;
               elsif Call_Upper = "LEFT" then
                  Emit_Native_Java.Emit_Raw ("ALB_TEXT_LEFT(", Local_Success);
               elsif Call_Upper = "RIGHT" then
                  Emit_Native_Java.Emit_Raw ("ALB_TEXT_RIGHT(", Local_Success);
               elsif Call_Upper = "MID" then
                  Emit_Native_Java.Emit_Raw ("ALB_TEXT_MID(", Local_Success);
               elsif Call_Upper = "CHR" then
                  Emit_Native_Java.Emit_Raw ("ALB_TEXT_CHR(", Local_Success);
                  if Local_Success and then Arg_1 /= 0 then
                     Emit_Expression (Arg_1, Depth + 1, Local_Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw (")", Local_Success);
                  end if;
                  Bare_Done := True;
               elsif Call_Upper = "PURE" or else Call_Upper = "RATIONAL" or else Call_Upper = "U128" or else Call_Upper = "S128" then
                  Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST(", Local_Success);
                  if Local_Success and then Arg_1 /= 0 then
                     Emit_Expression (Arg_1, Depth + 1, Local_Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw (", ", Local_Success);
                  end if;
                  if Local_Success and then Arg_2 /= 0 then
                     Emit_Expression (Arg_2, Depth + 1, Local_Success);
                  else
                     Emit_Native_Java.Emit_Raw ("1", Local_Success);
                  end if;
                  if Local_Success then
                     Emit_Native_Java.Emit_Raw (")", Local_Success);
                  end if;
                  Bare_Done := True;
               elsif Call_Upper = "COLLIDE_RECT" then
                  Emit_Native_Java.Emit_Raw ("ALB_COLLIDE_RECT(", Local_Success);
               elsif Call_Upper = "SIN" then
                  Emit_Native_Java.Emit_Raw ("ALB_SIN(", Local_Success);
               elsif Call_Upper = "COS" then
                  Emit_Native_Java.Emit_Raw ("ALB_COS(", Local_Success);
               elsif Call_Upper = "SQRT" then
                  Emit_Native_Java.Emit_Raw ("ALB_SQRT(", Local_Success);
               elsif Call_Upper = "EXP" then
                  Emit_Native_Java.Emit_Raw ("ALB_EXP(", Local_Success);
               elsif Call_Upper = "PURE_ADD" or else Call_Upper = "PURE_SUB" or else
                     Call_Upper = "PURE_MUL" or else Call_Upper = "PURE_DIV" or else
                     Call_Upper = "PURE_POW" or else Call_Upper = "PURE_NUM" or else
                     Call_Upper = "PURE_DEN" or else
                     Call_Upper = "PRINT_PURE"
               then
                  Emit_Native_Java.Emit_Raw ("ALB_" & Call_Upper & "(", Local_Success);
               elsif Call_Upper = "CONCAT" then
                  Emit_Native_Java.Emit_Raw ("ALB_TEXT_CONCAT(", Local_Success);
               elsif Type_Tag_From_Name (Call_Upper) /= Type_None then
                  Cast_Tag := Type_Tag_From_Name (Call_Upper);
                  if Cast_Tag = Type_Pure or else Cast_Tag = Type_U128 or else Cast_Tag = Type_S128 then
                     Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST(", Local_Success);
                     if Local_Success and then Arg_1 /= 0 then
                        Emit_Coerced_Expression (Arg_1, Cast_Tag, Depth + 1, Local_Success);
                     else
                        Emit_Native_Java.Emit_Raw ("0", Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw (", 1)", Local_Success);
                     end if;
                  else
                     Emit_Native_Java.Emit_Raw
                       ("(" & Java_Primitive_Type (Cast_Tag) & ")(",
                        Local_Success);
                     if Local_Success and then Arg_1 /= 0 then
                        Emit_Coerced_Expression (Arg_1, Cast_Tag, Depth + 1, Local_Success);
                     else
                        Emit_Native_Java.Emit_Raw ("0", Local_Success);
                     end if;
                     if Local_Success then
                        Emit_Native_Java.Emit_Raw (")", Local_Success);
                     end if;
                  end if;
                  Bare_Done := True;
               else
                  Emit_Native_Java.Emit_Raw (Call_Name & "(", Local_Success);
               end if;

               if Local_Success and then not Bare_Done then
                  Emit_Routine_Arg_List
                    (Call_Name,
                     Tree (Idx).Right_Child,
                     Depth + 1,
                     Local_Success);
               end if;
               if Local_Success and then not Bare_Done then
                  Emit_Native_Java.Emit_Raw (")", Local_Success);
               end if;
            end;

         when others =>
            Emit_Native_Java.Emit_Raw ("0", Local_Success);
      end case;

      Success := Local_Success;
   end Emit_Expression;

   function Target_Address_Expr (Target_Node : Node_Index) return String is
   begin
      if Target_Node = 0 then
         return "0";
      end if;

      case Tree (Target_Node).Kind is
         when AST_Var_Expr =>
            return Symbol_Address_Expr
              (Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index)));

         when AST_Member_Expr =>
            declare
               Left_Node  : constant Node_Index := Tree (Target_Node).Left_Child;
               Field_Node : constant Node_Index := Tree (Target_Node).Right_Child;
               Base_Name  : constant String := Resolve_Target_Name (Left_Node);
               Struct_Name : constant String := Struct_Name_Of_Resolved_Name (Base_Name);
               Field_Name : constant String :=
                 Java_Safe_Symbol (Raw_Lexeme (Tree (Field_Node).Token_Index));
               SF_Idx : constant Natural :=
                 (if Struct_Name'Length > 0
                  then Find_Struct_Field (Struct_Name, Field_Name)
                  else 0);
            begin
               if SF_Idx > 0 then
                  return "(" & Symbol_Address_Expr (Base_Name) & ") + " &
                    Trim_Image (Natural'Image (Struct_Fields (SF_Idx).Offset_Bytes));
               else
                  return "0";
               end if;
            end;

         when others =>
            return "0";
      end case;
   end Target_Address_Expr;

   function Target_Uses_VAS (Target_Node : Node_Index) return Boolean is
      function Symbol_Uses_VAS (Name : String) return Boolean is
         Local_Idx : constant Natural := Find_Local_Symbol (Name);
         Sym_Idx   : constant Natural := Find_Java_Symbol (Name);
      begin
         return (Local_Idx > 0 and then Local_Symbols (Local_Idx).Spilled)
           or else (Sym_Idx > 0 and then Java_Symbols (Sym_Idx).Spilled)
           or else Struct_Name_Of_Resolved_Name (Name)'Length > 0;
      end Symbol_Uses_VAS;
   begin
      if Target_Node = 0 then
         return False;
      end if;

      case Tree (Target_Node).Kind is
         when AST_Var_Expr =>
            declare
               Name      : constant String :=
                 Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
            begin
               return Symbol_Uses_VAS (Name);
            end;

         when AST_Member_Expr =>
            return Target_Address_Expr (Target_Node) /= "0";

         when others =>
            return False;
      end case;
   end Target_Uses_VAS;

   procedure Emit_Target_LHS
     (Target_Node : Node_Index;
      Depth       : Natural;
      Success     : in out Boolean) is
      Sym_Idx   : Natural := 0;
      Local_Idx : Natural := 0;
   begin
      if Target_Node = 0 or else not Success then
         return;
      end if;

      if Target_Uses_VAS (Target_Node) then
         Success := False;
         return;
      end if;

      case Tree (Target_Node).Kind is
         when AST_Var_Expr =>
            declare
               Resolved : constant String :=
                 Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
            begin
               Local_Idx := Find_Local_Symbol (Resolved);
               Sym_Idx := Find_Java_Symbol (Resolved);

               if Tree (Target_Node).Left_Child /= 0 and then Sym_Idx > 0 and then Java_Symbols (Sym_Idx).Storage = Storage_Array then
                  Emit_Native_Java.Emit_Raw (Resolved & "[", Success);
                  if Success then
                     Emit_Flat_Array_Index (Sym_Idx, Tree (Target_Node).Left_Child, Depth + 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw ("]", Success);
                  end if;
               elsif Local_Idx > 0 then
                  Emit_Native_Java.Emit_Raw (Resolved, Success);
               elsif Sym_Idx > 0 and then
                 (Java_Symbols (Sym_Idx).Tag = Type_Pure or else
                  Java_Symbols (Sym_Idx).Tag = Type_U128 or else
                  Java_Symbols (Sym_Idx).Tag = Type_S128)
               then
                  Emit_Native_Java.Emit_Raw (Resolved, Success);
               else
                  Emit_Native_Java.Emit_Raw (Resolved & "[0]", Success);
               end if;
            end;

         when AST_Member_Expr =>
            declare
               Left_Node   : constant Node_Index := Tree (Target_Node).Left_Child;
               Field_Node  : constant Node_Index := Tree (Target_Node).Right_Child;
               Group_Name  : constant String := Resolve_Target_Name (Left_Node);
               Field_Name  : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Field_Node).Token_Index));
               PF_Idx      : constant Natural := Find_Parallel_Field (Group_Name, Field_Name);
               Backing_Sym : Natural := 0;
            begin
               if PF_Idx > 0 then
                  Backing_Sym := Find_Java_Symbol
                    (Parallel_Fields (PF_Idx).Backing_Name (1 .. Parallel_Fields (PF_Idx).Backing_Name_Len));
                  Emit_Native_Java.Emit_Raw
                    (Parallel_Fields (PF_Idx).Backing_Name (1 .. Parallel_Fields (PF_Idx).Backing_Name_Len) & "[",
                     Success);
                  if Success then
                     if Tree (Left_Node).Kind = AST_Var_Expr then
                        Emit_Flat_Array_Index (Backing_Sym, Tree (Left_Node).Left_Child, Depth + 1, Success);
                     else
                        Emit_Native_Java.Emit_Raw ("1", Success);
                     end if;
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw ("]", Success);
                  end if;
               else
                  Emit_Native_Java.Emit_Raw ("alb_missing_target", Success);
               end if;
            end;

         when others =>
            Emit_Native_Java.Emit_Raw ("alb_missing_target", Success);
      end case;
   end Emit_Target_LHS;

   procedure Emit_Text_Assignment_To_Target
     (Target_Node : Node_Index;
      Expr_Text   : String;
      Success     : in out Boolean) is
      Tag : constant ALB_Type_Tag := Target_Tag (Target_Node);
   begin
      if not Success or else Target_Node = 0 then
         return;
      end if;

      Emit_Native_Java.Emit_Indent (Success);
      if not Success then
         return;
      end if;

      if Is_Pureish_Tag (Tag) then
         Emit_Pure_Target_Open (Target_Node, 1, Success);
         if Success then
            Emit_Native_Java.Emit_Raw (Expr_Text & ");", Success);
         end if;
      elsif Target_Uses_VAS (Target_Node) then
         Emit_Native_Java.Emit_Raw
           (Java_VAS_Store_Call (Tag, Target_Address_Expr (Target_Node), Expr_Text) & ";",
            Success);
      else
         Emit_Target_LHS (Target_Node, 1, Success);
         if Success then
            Emit_Native_Java.Emit_Raw
              (" = " &
               Java_Assign_Cast_Prefix (Tag) &
               Expr_Text &
               Java_Assign_Cast_Suffix (Tag) &
               ";",
               Success);
         end if;
      end if;

      if Success then
         Emit_Native_Java.Emit_Newline (Success);
      end if;
   end Emit_Text_Assignment_To_Target;

   procedure Emit_Handle_Assignment
     (Target_Node : Node_Index;
      Handle_Name : String;
      Success     : in out Boolean) is
      Tag : constant ALB_Type_Tag := Target_Tag (Target_Node);
   begin
      if not Success or else Target_Node = 0 then
         return;
      end if;

      if Is_Pureish_Tag (Tag) then
         Emit_Native_Java.Emit_Indent (Success);
         if Success then
            Emit_Pure_Target_Open (Target_Node, 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST(ALB_PARSE_LONG(" & Handle_Name & "), 1));", Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Newline (Success);
         end if;
      elsif Target_Uses_VAS (Target_Node) then
         Emit_Native_Java.Emit_Indent (Success);
         if Success then
            Emit_Native_Java.Emit_Raw
              (Java_VAS_Store_Open (Tag, Target_Address_Expr (Target_Node)),
               Success);
         end if;
         if Success then
            case Tag is
               when Type_Binary | Type_Char =>
                  Emit_Native_Java.Emit_Raw ("(int)(" & Handle_Name & ")", Success);

               when Type_Boolean =>
                  Emit_Native_Java.Emit_Raw ("(byte)(ALB_PARSE_BOOL(" & Handle_Name & "))", Success);

               when Type_U8 | Type_S8 | Type_HW8 =>
                  Emit_Native_Java.Emit_Raw ("(byte)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_U16 | Type_S16 | Type_HW16 =>
                  Emit_Native_Java.Emit_Raw ("(short)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_U32 | Type_S32 | Type_HW32 | Type_Reference =>
                  Emit_Native_Java.Emit_Raw ("(int)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_U64 | Type_S64 | Type_HW64 =>
                  Emit_Native_Java.Emit_Raw ("(long)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_F32 =>
                  Emit_Native_Java.Emit_Raw ("(float)(ALB_PARSE_DOUBLE(" & Handle_Name & "))", Success);

               when Type_F64 | Type_F128 =>
                  Emit_Native_Java.Emit_Raw ("(double)(ALB_PARSE_DOUBLE(" & Handle_Name & "))", Success);

               when others =>
                  Emit_Native_Java.Emit_Raw ("(int)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);
            end case;
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (Java_VAS_Store_Close (Tag) & ";", Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Newline (Success);
         end if;
      else
         Emit_Native_Java.Emit_Indent (Success);
         if Success then
            Emit_Target_LHS (Target_Node, 1, Success);
         end if;
         if Success then
            Emit_Native_Java.Emit_Raw (" = ", Success);
         end if;
         if Success then
            case Tag is
               when Type_Binary | Type_Char =>
                  Emit_Native_Java.Emit_Raw (Handle_Name, Success);

               when Type_Boolean =>
                  Emit_Native_Java.Emit_Raw ("(byte)(ALB_PARSE_BOOL(" & Handle_Name & "))", Success);

               when Type_U8 | Type_S8 | Type_HW8 =>
                  Emit_Native_Java.Emit_Raw ("(byte)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_U16 | Type_S16 | Type_HW16 =>
                  Emit_Native_Java.Emit_Raw ("(short)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_U32 | Type_S32 | Type_HW32 | Type_Reference =>
                  Emit_Native_Java.Emit_Raw ("(int)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_U64 | Type_S64 | Type_HW64 =>
                  Emit_Native_Java.Emit_Raw ("(long)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);

               when Type_F32 =>
                  Emit_Native_Java.Emit_Raw ("(float)(ALB_PARSE_DOUBLE(" & Handle_Name & "))", Success);

               when Type_F64 | Type_F128 =>
                  Emit_Native_Java.Emit_Raw ("(double)(ALB_PARSE_DOUBLE(" & Handle_Name & "))", Success);

               when others =>
                  Emit_Native_Java.Emit_Raw ("(int)(ALB_PARSE_LONG(" & Handle_Name & "))", Success);
            end case;
         end if;
         if Success then
            Emit_Native_Java.Emit_Statement_End (Success);
         end if;
      end if;
   end Emit_Handle_Assignment;

   procedure Emit_Assignment_To_Target
     (Target_Node : Node_Index;
      RHS_Node    : Node_Index;
      Success     : in out Boolean) is
      Tag : constant ALB_Type_Tag := Target_Tag (Target_Node);
      S   : Boolean := Success;
   begin
      if not S then
         return;
      end if;

      if Tag = Type_Pure or else Tag = Type_U128 or else Tag = Type_S128 then
         Emit_Native_Java.Emit_Indent (S);
         if S then
            Emit_Pure_Target_Open (Target_Node, 1, S);
         end if;
         if S then
            Emit_Expression (RHS_Node, 1, S);
         end if;
         if S then
            Emit_Native_Java.Emit_Raw (");", S);
         end if;
         if S then
            Emit_Native_Java.Emit_Newline (S);
         end if;
      elsif Target_Uses_VAS (Target_Node) then
         Emit_Native_Java.Emit_Indent (S);
         if S then
            Emit_Native_Java.Emit_Raw
              (Java_VAS_Store_Open (Tag, Target_Address_Expr (Target_Node)),
               S);
         end if;
         if S then
            Emit_Coerced_Expression (RHS_Node, Tag, 1, S);
         end if;
         if S then
            Emit_Native_Java.Emit_Raw (Java_VAS_Store_Close (Tag) & ";", S);
         end if;
         if S then
            Emit_Native_Java.Emit_Newline (S);
         end if;
      else
         Emit_Native_Java.Emit_Indent (S);
         if S then
            Emit_Target_LHS (Target_Node, 1, S);
         end if;
         if S then
            Emit_Native_Java.Emit_Raw (" = ", S);
         end if;
         if S then
            Emit_Coerced_Expression (RHS_Node, Tag, 1, S);
         end if;
         if S then
            Emit_Native_Java.Emit_Statement_End (S);
         end if;
      end if;

      Success := S;
   end Emit_Assignment_To_Target;

   procedure Emit_Scalar_Assignment
     (Target_Name : String;
      Tag         : ALB_Type_Tag;
      RHS_Node    : Node_Index;
      Success     : in out Boolean) is
      S : Boolean := Success;
   begin
      if not S then
         return;
      end if;

      Emit_Native_Java.Emit_Indent (S);
      if S then
         Emit_Native_Java.Emit_Raw (Target_Name & "[0] = ", S);
      end if;

      if S then
         case Tag is
            when Type_U8 =>
               Emit_Native_Java.Emit_Raw ("(int)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_S8 | Type_Boolean | Type_HW8 =>
               Emit_Native_Java.Emit_Raw ("(byte)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_U16 =>
               Emit_Native_Java.Emit_Raw ("(int)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_S16 | Type_HW16 =>
               Emit_Native_Java.Emit_Raw ("(short)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_U32 | Type_U64 =>
               Emit_Native_Java.Emit_Raw ("(long)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_S32 | Type_HW32 | Type_Reference =>
               Emit_Native_Java.Emit_Raw ("(int)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_S64 | Type_HW64 =>
               Emit_Native_Java.Emit_Raw ("(long)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_F32 =>
               Emit_Native_Java.Emit_Raw ("(float)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_F64 | Type_F128 =>
               Emit_Native_Java.Emit_Raw ("(double)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when Type_Char | Type_Binary =>
               Emit_Native_Java.Emit_Raw ("(int)(", S);
               if S then Emit_Expression (RHS_Node, 1, S); end if;
               if S then Emit_Native_Java.Emit_Raw (")", S); end if;

            when others =>
               Emit_Expression (RHS_Node, 1, S);
         end case;
      end if;

      if S then
         Emit_Native_Java.Emit_Statement_End (S);
      end if;

      Success := S;
   end Emit_Scalar_Assignment;

   procedure Emit_Pure_Assignment
     (Target_Name : String;
      RHS_Node    : Node_Index;
      Success     : in out Boolean) is
      S : Boolean := Success;
   begin
      if not S then
         return;
      end if;
      Emit_Native_Java.Emit_Indent (S);
      if S then Emit_Native_Java.Emit_Raw ("ALB_COPY_PURE(" & Target_Name & ", ", S); end if;
      if S then Emit_Expression (RHS_Node, 1, S); end if;
      if S then Emit_Native_Java.Emit_Raw (");", S); end if;
      if S then Emit_Native_Java.Emit_Newline (S); end if;

      Success := S;
   end Emit_Pure_Assignment;

   procedure Emit_Node
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean);

   procedure Emit_Node
     (Idx     : Node_Index;
      Depth   : Natural;
      Success : in out Boolean) is
      Curr         : Node_Index := 0;
      Target_Node  : Node_Index := 0;
      RHS_Node     : Node_Index := 0;
      Name         : String (1 .. 128) := (others => ' ');
      Name_Len     : Natural := 0;
      Safe_Name    : String (1 .. 128) := (others => ' ');
      Safe_Len     : Natural := 0;
      Final_Tag    : ALB_Type_Tag := Type_None;
      Width_Value  : U64 := 0;
      Height_Value : U64 := 0;
      Parse_OK     : Boolean := False;
      Saved_Buffer : Emit_Native_Java.Buffer_Target := Emit_Native_Java.Current_Buffer;
   begin
      if not Success or else Idx = 0 then
         return;
      end if;

      if Depth > 256 then
         Emit_Comment ("Depth guard tripped during FlatJVM emission.", Success);
         return;
      end if;

      case Tree (Idx).Kind is
         when AST_Program =>
            Curr := Tree (Idx).Left_Child;
            while Curr /= 0 loop
               Emit_Node (Curr, Depth + 1, Success);
               Curr := Tree (Curr).Next_Sibling;
               exit when not Success;
            end loop;

         when AST_Block_Stmt =>
            Curr := Tree (Idx).Left_Child;
            while Curr /= 0 loop
               Emit_Node (Curr, Depth + 1, Success);
               Curr := Tree (Curr).Next_Sibling;
               exit when not Success;
            end loop;

        when AST_Let_Stmt =>
            Target_Node := Tree (Idx).Left_Child;
            RHS_Node := Tree (Idx).Right_Child;

            if Target_Node /= 0 and then Tree (Target_Node).Token_Index > 0 then
               declare
                  Raw_Name : constant String := Raw_Lexeme (Tree (Target_Node).Token_Index);
                  Safe     : constant String := Resolve_Symbol_Name (Raw_Name);
               begin
                  Safe_Len := Safe'Length;
                  Safe_Name (1 .. Safe_Len) := Safe;
               end;
            else
               Safe_Len := 7;
               Safe_Name (1 .. Safe_Len) := "alb_tmp";
            end if;

            declare
               Explicit_Type_Name : constant String :=
                 (if Tree (Idx).Token_Index > 0
                  then Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index))
                  else "");
               Explicit_Struct_Idx : constant Natural :=
                 Find_Struct_Type (Explicit_Type_Name);
            begin
               if Explicit_Struct_Idx > 0 then
                  Final_Tag := Type_Reference;
               elsif Tree (Idx).Token_Index > 0 then
                  Final_Tag := Type_Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
               end if;

               if Final_Tag = Type_None then
                  Final_Tag := Infer_Type_Tag (RHS_Node);
               end if;

               if Final_Tag = Type_None then
                  Final_Tag := Type_U64;
               end if;

               if Target_Node /= 0
                 and then Tree (Target_Node).Kind = AST_Var_Expr
                 and then Find_Local_Symbol (Safe_Name (1 .. Safe_Len)) = 0
                 and then Find_Java_Symbol (Safe_Name (1 .. Safe_Len)) = 0
               then
                  if Local_Scope_Depth > 0 then
                     Emit_Local_Symbol_Decl (Safe_Name (1 .. Safe_Len), Final_Tag, Success);
                     Register_Local_Symbol (Safe_Name (1 .. Safe_Len), Final_Tag, False, Success);
                  else
                     Declare_Java_Symbol
                       (Safe_Name (1 .. Safe_Len),
                        Final_Tag,
                        Success,
                        Spill => not Is_Pureish_Tag (Final_Tag) or else Explicit_Struct_Idx > 0,
                        Struct_Name =>
                          (if Explicit_Struct_Idx > 0
                           then Explicit_Type_Name
                           else ""));
                  end if;
               end if;
            end;

            if Success then
               Emit_Assignment_To_Target (Target_Node, RHS_Node, Success);
            end if;

         when AST_Strict_Stmt =>
            Target_Node := Tree (Idx).Left_Child;
            RHS_Node := Tree (Idx).Right_Child;

            if Target_Node /= 0 and then Tree (Target_Node).Token_Index > 0 then
               declare
                  Safe : constant String := Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
                  Dims : Java_Dim_Array := (others => 0);
                  Rank : Natural := 0;
                  Elem : Node_Index := RHS_Node;
                  Elem_Type : ALB_Type_Tag := Type_U8;
               begin
                  if Tree (Target_Node).Right_Child > 0 then
                     Elem_Type := Type_Tag_From_Name
                       (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index));
                  end if;
                  while Elem /= 0 and then Rank < 4 loop
                     Rank := Rank + 1;
                     Try_Evaluate_Static_U64 (Elem, Width_Value, Parse_OK);
                     if not Parse_OK or else Width_Value = 0 then
                        Width_Value := 256;
                     end if;
                     Dims (Rank) := Natural (Width_Value);
                     Elem := Tree (Elem).Next_Sibling;
                  end loop;
                  Declare_Java_Symbol
                    (Safe,
                     Elem_Type,
                     Success,
                     Storage_Array,
                     Rank,
                     Dims);
               end;
            end if;

         when AST_Slide_Stmt =>
            Target_Node := Tree (Idx).Left_Child;
            RHS_Node := Tree (Idx).Right_Child;

            if Target_Node /= 0 and then Tree (Target_Node).Token_Index > 0 then
               declare
                  Safe : constant String := Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
                  Dims : Java_Dim_Array := (others => 0);
                  Elem_Type : ALB_Type_Tag := Type_U8;
               begin
                  if Tree (Target_Node).Right_Child > 0 then
                     Elem_Type := Type_Tag_From_Name
                       (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index));
                  end if;
                  Try_Evaluate_Static_U64 (RHS_Node, Width_Value, Parse_OK);
                  if not Parse_OK or else Width_Value = 0 then
                     Width_Value := 256;
                  end if;
                  Dims (1) := Natural (Width_Value);
                  Declare_Java_Symbol
                    (Safe,
                     Elem_Type,
                     Success,
                     Storage_Array,
                     1,
                     Dims);
               end;
            end if;

         when AST_Markov_Model_Decl =>
            declare
               Name_Node   : constant Node_Index := Tree (Idx).Left_Child;
               Model_Name  : constant String :=
                 (if Name_Node /= 0 and then Tree (Name_Node).Token_Index > 0
                  then Java_Safe_Symbol (Raw_Lexeme (Tree (Name_Node).Token_Index))
                  else "alb_markov");
               Curr_Setting : Node_Index := Tree (Idx).Right_Child;
               States_Node  : Node_Index := 0;
               Matrix_Node  : Node_Index := 0;
               Row_Node     : Node_Index := 0;
               Elem_Node    : Node_Index := 0;
               Line_Text    : String (1 .. 4096) := (others => ' ');
               Line_Len     : Natural := 0;
               First_Value  : Boolean := True;

               procedure Append_Text (Text : String) is
               begin
                  if Line_Len + Text'Length <= Line_Text'Length then
                     Line_Text (Line_Len + 1 .. Line_Len + Text'Length) := Text;
                     Line_Len := Line_Len + Text'Length;
                  else
                     Success := False;
                  end if;
               end Append_Text;
            begin
               while Curr_Setting /= 0 loop
                  case Tree (Curr_Setting).Kind is
                     when AST_Markov_States =>
                        States_Node := Tree (Curr_Setting).Left_Child;
                     when AST_Markov_Transition_Matrix =>
                        Matrix_Node := Curr_Setting;
                     when others =>
                        null;
                  end case;
                  Curr_Setting := Tree (Curr_Setting).Next_Sibling;
               end loop;

               Emit_Global_Line
                 ("private static final int ALB_MARKOV_" & Model_Name & "_STATES = " &
                  (if States_Node /= 0 and then Tree (States_Node).Token_Index > 0
                   then Raw_Lexeme (Tree (States_Node).Token_Index)
                   else "0") & ";",
                  Success);

               Line_Len := 0;
               Append_Text ("private static final double[] ALB_MARKOV_" & Model_Name & " = new double[] { ");
               if Matrix_Node /= 0 then
                  Row_Node := Tree (Matrix_Node).Left_Child;
                  while Row_Node /= 0 loop
                     Elem_Node := Tree (Row_Node).Left_Child;
                     while Elem_Node /= 0 loop
                        if not First_Value then
                           Append_Text (", ");
                        end if;
                        Append_Text (Raw_Lexeme (Tree (Elem_Node).Token_Index));
                        First_Value := False;
                        Elem_Node := Tree (Elem_Node).Next_Sibling;
                     end loop;
                     Row_Node := Tree (Row_Node).Next_Sibling;
                  end loop;
               end if;
               Append_Text (" };");
               if Success then
                  Emit_Global_Line (Line_Text (1 .. Line_Len), Success);
               end if;
            end;

         when AST_Neural_Topology_Decl =>
            declare
               Name_Node  : constant Node_Index := Tree (Idx).Left_Child;
               Model_Name : constant String :=
                 (if Name_Node /= 0 and then Tree (Name_Node).Token_Index > 0
                  then Java_Safe_Symbol (Raw_Lexeme (Tree (Name_Node).Token_Index))
                  else "alb_nn");
               Layer_Node : Node_Index := Tree (Idx).Right_Child;
               Line_Text  : String (1 .. 4096) := (others => ' ');
               Line_Len   : Natural := 0;

               procedure Append_Text (Text : String) is
               begin
                  if Line_Len + Text'Length <= Line_Text'Length then
                     Line_Text (Line_Len + 1 .. Line_Len + Text'Length) := Text;
                     Line_Len := Line_Len + Text'Length;
                  else
                     Success := False;
                  end if;
               end Append_Text;

               function Activation_Code (Node : Node_Index) return String is
               begin
                  if Node = 0 or else Tree (Node).Token_Index = 0 then
                     return "0";
                  elsif Upper_ASCII (Raw_Lexeme (Tree (Node).Token_Index)) = "RELU" then
                     return "1";
                  elsif Upper_ASCII (Raw_Lexeme (Tree (Node).Token_Index)) = "SIGMOID" then
                     return "2";
                  elsif Upper_ASCII (Raw_Lexeme (Tree (Node).Token_Index)) = "TANH" then
                     return "3";
                  else
                     return "0";
                  end if;
               end Activation_Code;
               First_Item : Boolean := True;
            begin
               Append_Text ("private static final ALB_NN_Model ALB_NN_" & Model_Name & " = ALB_NN_CREATE(new int[] { ");
               while Layer_Node /= 0 loop
                  if not First_Item then
                     Append_Text (", ");
                  end if;
                  if Tree (Layer_Node).Left_Child /= 0 and then Tree (Tree (Layer_Node).Left_Child).Token_Index > 0 then
                     Append_Text (Raw_Lexeme (Tree (Tree (Layer_Node).Left_Child).Token_Index));
                  else
                     Append_Text ("1");
                  end if;
                  First_Item := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Append_Text (" }, new int[] { ");
               Layer_Node := Tree (Idx).Right_Child;
               First_Item := True;
               while Layer_Node /= 0 loop
                  if not First_Item then
                     Append_Text (", ");
                  end if;
                  Append_Text (Activation_Code (Tree (Layer_Node).Right_Child));
                  First_Item := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Append_Text (" });");
               Emit_Global_Line (Line_Text (1 .. Line_Len), Success);
            end;

         when AST_Network_Socket_Decl =>
            if Tree (Idx).Left_Child /= 0 and then Tree (Tree (Idx).Left_Child).Token_Index > 0 then
               declare
                  Socket_Name : constant String := Resolve_Target_Name (Tree (Idx).Left_Child);
               begin
                  Register_Network_Socket (Socket_Name, Idx);
                  Declare_Java_Symbol
                    (Socket_Name,
                     Type_U64,
                     Success);
               end;
            end if;

         when AST_Memory_Firewall_Decl =>
            null;

         when AST_Export_DLL | AST_Export_ES | AST_Export_WASM |
              AST_Import_ES | AST_Import_WASM =>
            null;

         when AST_Print_Stmt =>
            RHS_Node := Tree (Idx).Left_Child;
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               if Infer_Type_Tag (RHS_Node) = Type_Binary or else Infer_Type_Tag (RHS_Node) = Type_Char then
                  Emit_Native_Java.Emit_Raw ("ALB_PRINT_TEXT(", Success);
                  if Success then Emit_Expression (RHS_Node, 1, Success); end if;
                  if Success then Emit_Native_Java.Emit_Raw (", true);", Success); end if;
               elsif Infer_Type_Tag (RHS_Node) = Type_Pure then
                  Emit_Native_Java.Emit_Raw ("ALB_PRINT_PURE(", Success);
                  if Success then Emit_Expression (RHS_Node, 1, Success); end if;
                  if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
               else
                  Emit_Native_Java.Emit_Raw ("System.out.println(", Success);
                  if Success then Emit_Expression (RHS_Node, 1, Success); end if;
                  if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
               end if;
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_Predict_Markov_Stmt =>
            declare
               Model_Node  : constant Node_Index := Tree (Idx).Left_Child;
               State_Node  : constant Node_Index := Tree (Idx).Right_Child;
               Output_Node : constant Node_Index := (if State_Node /= 0 then Tree (State_Node).Next_Sibling else 0);
               Model_Name  : constant String :=
                 (if Model_Node /= 0 and then Tree (Model_Node).Token_Index > 0
                  then Java_Safe_Symbol (Raw_Lexeme (Tree (Model_Node).Token_Index))
                  else "alb_markov");
               Output_Tag  : constant ALB_Type_Tag :=
                 (if Output_Node /= 0 then Target_Tag (Output_Node) else Type_U64);
            begin
               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  if Output_Node /= 0 and then Target_Uses_VAS (Output_Node) then
                     Emit_Native_Java.Emit_Raw
                       (Java_VAS_Store_Open (Output_Tag, Target_Address_Expr (Output_Node)),
                        Success);
                  elsif Output_Node /= 0 then
                     Emit_Target_LHS (Output_Node, 1, Success);
                     if Success then
                        Emit_Native_Java.Emit_Raw (" = ", Success);
                     end if;
                  end if;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw
                    ("ALB_MARKOV_PREDICT(ALB_MARKOV_" & Model_Name &
                     ", ALB_MARKOV_" & Model_Name & "_STATES, (long)(",
                     Success);
               end if;
               if Success then
                  Emit_Expression (State_Node, 1, Success);
               end if;
               if Success then
                  if Output_Node /= 0 and then Target_Uses_VAS (Output_Node) then
                     Emit_Native_Java.Emit_Raw ("))" & Java_VAS_Store_Close (Output_Tag) & ";", Success);
                  else
                     Emit_Native_Java.Emit_Raw ("));", Success);
                  end if;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Infer_Network_Stmt =>
            declare
               Model_Node  : constant Node_Index := Tree (Idx).Left_Child;
               Input_Node  : constant Node_Index := Tree (Idx).Right_Child;
               Output_Node : constant Node_Index := (if Input_Node /= 0 then Tree (Input_Node).Next_Sibling else 0);
               Model_Name  : constant String :=
                 (if Model_Node /= 0 and then Tree (Model_Node).Token_Index > 0
                  then Java_Safe_Symbol (Raw_Lexeme (Tree (Model_Node).Token_Index))
                  else "alb_nn");
            begin
               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  Emit_Native_Java.Emit_Raw
                    ("ALB_NN_INFER(ALB_NN_" & Model_Name & ", " &
                     Resolve_Target_Name (Input_Node) & ", " &
                     Resolve_Target_Name (Output_Node) & ");",
                     Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Train_Network_Stmt =>
            declare
               Model_Node  : constant Node_Index := Tree (Idx).Left_Child;
               Train_Node  : constant Node_Index := Tree (Idx).Right_Child;
               Expect_Node : constant Node_Index := (if Train_Node /= 0 then Tree (Train_Node).Next_Sibling else 0);
               Epoch_Node  : constant Node_Index := (if Expect_Node /= 0 then Tree (Expect_Node).Next_Sibling else 0);
               Model_Name  : constant String :=
                 (if Model_Node /= 0 and then Tree (Model_Node).Token_Index > 0
                  then Java_Safe_Symbol (Raw_Lexeme (Tree (Model_Node).Token_Index))
                  else "alb_nn");
            begin
               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  Emit_Native_Java.Emit_Raw
                    ("ALB_NN_TRAIN(ALB_NN_" & Model_Name & ", " &
                     Resolve_Target_Name (Train_Node) & ", " &
                     Resolve_Target_Name (Expect_Node) & ", ",
                     Success);
               end if;
               if Success then
                  if Epoch_Node /= 0 then
                     Emit_Expression (Epoch_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("1", Success);
                  end if;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (");", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Network_Listen_Stmt =>
            declare
               Socket_Node    : constant Node_Index := Tree (Idx).Left_Child;
               Socket_Name    : constant String := Resolve_Target_Name (Socket_Node);
               Socket_Id      : constant Natural := Find_Network_Socket (Socket_Name);
               Decl_Node      : constant Node_Index := (if Socket_Id > 0 then Network_Sockets (Socket_Id).Node else 0);
               Setting_Node   : Node_Index := (if Decl_Node /= 0 then Tree (Decl_Node).Right_Child else 0);
               Protocol_Code  : Natural := 1;
               Port_Node      : Node_Index := 0;
               Size_Node      : Node_Index := 0;
            begin
               while Setting_Node /= 0 loop
                  case Tree (Setting_Node).Kind is
                     when AST_Network_Protocol =>
                        if Tree (Setting_Node).Left_Child /= 0
                          and then Upper_ASCII (Raw_Lexeme (Tree (Tree (Setting_Node).Left_Child).Token_Index)) = "UDP"
                        then
                           Protocol_Code := 2;
                        else
                           Protocol_Code := 1;
                        end if;
                     when AST_Network_Port =>
                        Port_Node := Tree (Setting_Node).Left_Child;
                     when AST_Network_Buffer_Size =>
                        Size_Node := Tree (Setting_Node).Left_Child;
                     when others =>
                        null;
                  end case;
                  Setting_Node := Tree (Setting_Node).Next_Sibling;
               end loop;

               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  Emit_Target_LHS (Socket_Node, 1, Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (" = ALB_NET_LISTEN_SOCKET(" & Socket_Name & "[0], " &
                    Trim_Image (Natural'Image (Protocol_Code)) & ", ", Success);
               end if;
               if Success then
                  if Port_Node /= 0 then
                     Emit_Expression (Port_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Success);
                  end if;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (", ", Success);
               end if;
               if Success then
                  if Size_Node /= 0 then
                     Emit_Expression (Size_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("1", Success);
                  end if;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (");", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Network_Receive_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               Emit_Native_Java.Emit_Raw
                 ("ALB_NET_RECEIVE(" & Resolve_Target_Name (Tree (Idx).Left_Child) & "[0], " &
                  Resolve_Target_Name (Tree (Idx).Right_Child) & ");",
                  Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_Network_Send_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               Emit_Native_Java.Emit_Raw
                 ("ALB_NET_SEND(" & Resolve_Target_Name (Tree (Idx).Left_Child) & "[0], " &
                  Resolve_Target_Name (Tree (Idx).Right_Child) & ");",
                  Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_Network_Close_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               Emit_Native_Java.Emit_Raw
                 ("ALB_NET_CLOSE(" & Resolve_Target_Name (Tree (Idx).Left_Child) & ");",
                  Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;


         when AST_Print_Str_Stmt =>
            RHS_Node := Tree (Idx).Left_Child;
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               if Infer_Type_Tag (RHS_Node) = Type_Binary or else Infer_Type_Tag (RHS_Node) = Type_Char then
                  Emit_Native_Java.Emit_Raw ("ALB_PRINT_TEXT(", Success);
                  if Success then Emit_Expression (RHS_Node, 1, Success); end if;
                  if Success then Emit_Native_Java.Emit_Raw (", false);", Success); end if;
               elsif Infer_Type_Tag (RHS_Node) = Type_Pure then
                  Emit_Native_Java.Emit_Raw ("ALB_PRINT_TEXT(ALB_TEXT_OF_PURE(", Success);
                  if Success then Emit_Expression (RHS_Node, 1, Success); end if;
                  if Success then Emit_Native_Java.Emit_Raw ("), false);", Success); end if;
               else
                  Emit_Native_Java.Emit_Raw ("System.out.print(", Success);
                  if Success then Emit_Expression (RHS_Node, 1, Success); end if;
                  if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
               end if;
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_Create_Window =>
            declare
               Title_Node  : constant Node_Index := Tree (Idx).Left_Child;
               Pair_Node   : constant Node_Index := Tree (Idx).Right_Child;
               Width_Node  : Node_Index := 0;
               Height_Node : Node_Index := 0;
               Title_Text  : constant String := (if Title_Node /= 0 then Strip_String_Node (Title_Node) else "ALB");
            begin
               if Pair_Node /= 0 then
                  Width_Node := Tree (Pair_Node).Left_Child;
                  Height_Node := Tree (Pair_Node).Right_Child;
               end if;

               Parse_Decimal (Simple_Expr_Text (Width_Node), Width_Value, Parse_OK);
               if not Parse_OK then
                  Width_Value := 320;
               end if;

               Parse_Decimal (Simple_Expr_Text (Height_Node), Height_Value, Parse_OK);
               if not Parse_OK then
                  Height_Value := 200;
               end if;

               Emit_Native_Java.Emit_Window_Creation
                 (Title_Text,
                  Natural (Width_Value),
                  Natural (Height_Value),
                  Success);
            end;

         when AST_Set_Fullscreen | AST_Set_Resizable | AST_Set_Stretchy =>
            declare
               Target_Name : constant String :=
                 (case Tree (Idx).Kind is
                    when AST_Set_Fullscreen => "alb_window_fullscreen",
                    when AST_Set_Resizable  => "alb_window_resizable",
                    when others             => "alb_window_stretchy");
            begin
               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  Emit_Native_Java.Emit_Raw (Target_Name & "[0] = (int)(", Success);
               end if;
               if Success then
                  Emit_Expression (Tree (Idx).Left_Child, 1, Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (");", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Const_Decl =>
            if Tree (Idx).Left_Child /= 0 and then Tree (Tree (Idx).Left_Child).Token_Index > 0 then
               Register_Const
                 (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                  Simple_Expr_Text (Tree (Idx).Right_Child));
            end if;

         when AST_Range_Type_Decl =>
            if Tree (Idx).Left_Child /= 0 and then Tree (Idx).Right_Child /= 0 then
               Register_Type_Alias
                 (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                  Type_Tag_From_Name (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index)));
            end if;

         when AST_Enum_Decl =>
            declare
               Enum_Curr  : Node_Index := Tree (Idx).Left_Child;
               Enum_Value : Natural := 0;
            begin
               while Enum_Curr /= 0 loop
                  Register_Const
                    (Raw_Lexeme (Tree (Enum_Curr).Token_Index),
                     Trim_Image (Natural'Image (Enum_Value)));
                  Enum_Value := Enum_Value + 1;
                  Enum_Curr := Tree (Enum_Curr).Next_Sibling;
               end loop;
            end;

         when AST_Struct_Decl =>
            declare
               Struct_Name : constant String :=
                 Resolve_Target_Name (Tree (Idx).Left_Child);
               Field_Curr   : Node_Index := 0;
               Offset_Bytes : Natural := 0;
               Field_Tag    : ALB_Type_Tag := Type_U64;
            begin
               if Tree (Idx).Right_Child /= 0 then
                  Field_Curr := Tree (Tree (Idx).Right_Child).Left_Child;
               end if;

               while Field_Curr /= 0 loop
                  if Tree (Field_Curr).Kind = AST_Bitfield_Decl then
                     Register_Struct_Field
                       (Struct_Name,
                        Resolve_Target_Name (Tree (Field_Curr).Left_Child),
                        Type_U8,
                        Offset_Bytes);
                     Offset_Bytes := Offset_Bytes + 1;
                  elsif Tree (Field_Curr).Left_Child /= 0 then
                     Field_Tag := Type_U64;
                     if Tree (Field_Curr).Token_Index > 0 then
                        Field_Tag := Type_Tag_From_Name (Raw_Lexeme (Tree (Field_Curr).Token_Index));
                     end if;
                     Register_Struct_Field
                       (Struct_Name,
                        Resolve_Target_Name (Tree (Field_Curr).Left_Child),
                        Field_Tag,
                        Offset_Bytes);
                     Offset_Bytes := Offset_Bytes + Type_Size_Bytes (Field_Tag);
                  end if;
                  Field_Curr := Tree (Field_Curr).Next_Sibling;
               end loop;

               Register_Struct_Type (Struct_Name, Offset_Bytes);
            end;

         when AST_Module | AST_DeclareModule =>
            declare
               Prev_Name : constant String := Current_Module_Name;
               Prev_Len  : constant Natural := Current_Module_Len;
               Entered_Declare_Module : constant Boolean := Tree (Idx).Kind = AST_DeclareModule;
            begin
               Current_Module_Name := (others => ' ');
               if Tree (Idx).Left_Child /= 0 then
                  declare
                     Safe : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
                  begin
                     Current_Module_Len := Safe'Length;
                     Current_Module_Name (1 .. Current_Module_Len) := Safe;
                  end;
               else
                  Current_Module_Len := 0;
               end if;

               if Entered_Declare_Module then
                  Declare_Module_Depth := Declare_Module_Depth + 1;
               end if;
               Emit_Node (Tree (Idx).Right_Child, Depth + 1, Success);
               if Entered_Declare_Module and then Declare_Module_Depth > 0 then
                  Declare_Module_Depth := Declare_Module_Depth - 1;
               end if;

               Current_Module_Name := Prev_Name;
               Current_Module_Len := Prev_Len;
            end;

         when AST_Import =>
            null;

         when AST_Import_C | AST_Import_DLL =>
            if Tree (Idx).Left_Child /= 0 then
               Emit_Import_C_Stub
                 (Tree (Idx).Left_Child,
                  Tree (Idx).Right_Child,
                  Tree (Idx).Kind = AST_Import_DLL,
                  Success);
            end if;

         when AST_Comptime_Block =>
            null;

         when AST_Predicate_Decl =>
            null;

         when AST_Rule_Decl | AST_Constraint_Decl =>
            Emit_Rule_Registration (Idx, Success);

         when AST_Parallel_Decl =>
            declare
               Group_Node : constant Node_Index := Tree (Idx).Left_Child;
               Group_Name : constant String := Resolve_Target_Name (Group_Node);
               Dims       : Java_Dim_Array := (others => 0);
               Rank       : Natural := 0;
               Bound      : Node_Index := 0;
               Field_Curr : Node_Index := Tree (Idx).Right_Child;
               Field_Tag  : ALB_Type_Tag := Type_U64;
            begin
               if Group_Node /= 0 then
                  Bound := Tree (Group_Node).Left_Child;
               end if;
               while Bound /= 0 and then Rank < 4 loop
                  Rank := Rank + 1;
                  Try_Evaluate_Static_U64 (Bound, Width_Value, Parse_OK);
                  if not Parse_OK or else Width_Value = 0 then
                     Width_Value := 64;
                  end if;
                  Dims (Rank) := Natural (Width_Value);
                  Bound := Tree (Bound).Next_Sibling;
               end loop;

               Declare_Java_Symbol
                 (Group_Name,
                  Type_U32,
                  Success,
                  Storage_Parallel_Group,
                  Rank,
                  Dims);

               while Field_Curr /= 0 loop
                  if Tree (Field_Curr).Left_Child /= 0 then
                     Field_Tag := Type_U64;
                     if Tree (Tree (Field_Curr).Left_Child).Right_Child > 0 then
                        Field_Tag := Type_Tag_From_Name
                          (Raw_Lexeme (Tree (Tree (Tree (Field_Curr).Left_Child).Right_Child).Token_Index));
                     end if;
                     declare
                        Field_Name : constant String := Resolve_Target_Name (Tree (Field_Curr).Left_Child);
                        Backing    : constant String := Group_Name & "_" & Field_Name;
                     begin
                        Register_Parallel_Field (Group_Name, Field_Name, Backing, Field_Tag);
                        Declare_Java_Symbol
                          (Backing,
                           Field_Tag,
                           Success,
                           Storage_Array,
                           Rank,
                           Dims);
                     end;
                  end if;
                  Field_Curr := Tree (Field_Curr).Next_Sibling;
               end loop;
            end;

         when AST_Temporal_Decl =>
            Target_Node := Tree (Idx).Left_Child;
            RHS_Node := Tree (Idx).Right_Child;
            if Target_Node /= 0 and then Tree (Target_Node).Token_Index > 0 then
               declare
                  Safe : constant String := Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
                  Init_Node : Node_Index := 0;
                  History_Size : Natural := 1;
                  Sym_Idx : Natural := 0;
                  Timeline_Offset : Natural := 0;
               begin
                  Final_Tag := Type_U64;
                  if Tree (Idx).Token_Index > 0 then
                     Final_Tag := Type_Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
                  end if;
                  if Final_Tag = Type_None then
                     Final_Tag := Type_U64;
                  end if;
                  if RHS_Node /= 0 then
                     Try_Evaluate_Static_U64 (RHS_Node, Width_Value, Parse_OK);
                     if Parse_OK and then Width_Value > 0 then
                        History_Size := Natural (Width_Value);
                     else
                        History_Size := 8;
                     end if;
                  end if;
                  if Find_Local_Symbol (Safe) = 0 and then Find_Java_Symbol (Safe) = 0 then
                     if Local_Scope_Depth > 0 then
                        Emit_Local_Symbol_Decl (Safe, Final_Tag, Success);
                        Register_Local_Symbol (Safe, Final_Tag, False, Success);
                     else
                        Declare_Java_Symbol (Safe, Final_Tag, Success, Spill => True);
                        Sym_Idx := Find_Java_Symbol (Safe);
                        if Success then
                           Emit_Temporal_Backing (Safe, Final_Tag, History_Size, Success);
                        end if;
                        if Success then
                           Timeline_Offset :=
                             Allocate_Temporal_VAS
                               (History_Size * Type_Size_Bytes (Final_Tag),
                                Tag_Align_Bytes (Final_Tag));
                           Register_Temporal_Symbol
                             (Safe,
                              Final_Tag,
                              History_Size,
                              (if Sym_Idx > 0 then Java_Symbols (Sym_Idx).VAS_Offset else 0),
                              Timeline_Offset,
                              Type_Size_Bytes (Final_Tag));
                        end if;
                     end if;
                  end if;
                  if RHS_Node /= 0 then
                     Init_Node := Tree (RHS_Node).Next_Sibling;
                  end if;
                  if Init_Node /= 0 then
                     Emit_Assignment_To_Target (Target_Node, Init_Node, Success);
                     if Success and then Local_Scope_Depth = 0 then
                        Emit_Temporal_Init (Safe, Final_Tag, History_Size, Success);
                     end if;
                  end if;
               end;
            end if;

         when AST_Temporal_Block | AST_Atomic_Block | AST_Reversible_Block =>
            Emit_Node (Tree (Idx).Left_Child, Depth + 1, Success);

         when AST_Enable_Java_Block =>
            Emit_Native_Java.Emit_Raw
              (Extract_Java_Block_Body (Raw_Lexeme (Tree (Idx).Token_Index)),
               Success);
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_On_Block =>
            Saved_Buffer := Emit_Native_Java.Current_Buffer;
            if Tree (Idx).Token_Index > 0 then
               case Tokens (Tree (Idx).Token_Index).Kind is
                  when TOK_TICK =>
                     Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Tick);
                  when TOK_PAINT =>
                     Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Paint);
                  when TOK_KEY =>
                     Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Key);
                  when others =>
                     Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Boot);
               end case;
            end if;

            Clear_Local_Symbols;
            Local_Scope_Depth := Local_Scope_Depth + 1;
            Emit_Node (Tree (Idx).Left_Child, Depth + 1, Success);
            if Local_Scope_Depth > 0 then
               Local_Scope_Depth := Local_Scope_Depth - 1;
            end if;
            Clear_Local_Symbols;
            Emit_Native_Java.Set_Active_Buffer (Saved_Buffer);

         when AST_Listen =>
            Saved_Buffer := Emit_Native_Java.Current_Buffer;
            Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Main);
            Emit_Native_Java.Emit_Message_Loop (Success);
            Emit_Native_Java.Set_Active_Buffer (Saved_Buffer);

         when AST_Version =>
            Emit_Comment ("ALB version " & Simple_Expr_Text (Tree (Idx).Left_Child), Success);

         when AST_Assert_Stmt | AST_Retract_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Tree (Idx).Kind = AST_Assert_Stmt then
               if Success then
                  Emit_Native_Java.Emit_Raw ("ALB_KB_ASSERT(ALB_HASH(", Success);
               end if;
            else
               if Success then
                  Emit_Native_Java.Emit_Raw ("ALB_KB_RETRACT(ALB_HASH(", Success);
               end if;
            end if;
            if Success then
               Emit_Native_Java.Emit_String_Literal
                 (Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index)),
                  Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("), ", Success);
            end if;
            if Tree (Idx).Left_Child /= 0 then
               if Success then
                  Emit_Expression (Tree (Idx).Left_Child, 1, Success);
               end if;
            elsif Success then
               Emit_Native_Java.Emit_Raw ("0", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw (");", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_Knows_Fact =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               Emit_Native_Java.Emit_Raw ("ALB_KB_ASSERT(ALB_HASH(", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_String_Literal
                 (Predicate_Name_Of (Tree (Idx).Left_Child),
                  Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("), ", Success);
            end if;
            if Tree (Idx).Right_Child /= 0 then
               if Success then
                  Emit_Expression (Tree (Idx).Right_Child, 1, Success);
               end if;
            elsif Success then
               Emit_Native_Java.Emit_Raw ("0", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw (");", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_Update_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then
               Emit_Native_Java.Emit_Raw ("ALB_KB_UPDATE(ALB_HASH(", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_String_Literal (Predicate_Name_Of (Tree (Idx).Left_Child), Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw ("), ", Success);
            end if;
            if Success then
               if Predicate_Arg_Node (Tree (Idx).Left_Child) /= 0 then
                  Emit_Expression (Predicate_Arg_Node (Tree (Idx).Left_Child), 1, Success);
               else
                  Emit_Native_Java.Emit_Raw ("0", Success);
               end if;
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw (", ", Success);
            end if;
            if Success then
               Emit_Expression (Tree (Idx).Right_Child, 1, Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Raw (");", Success);
            end if;
            if Success then
               Emit_Native_Java.Emit_Newline (Success);
            end if;

         when AST_Clear =>
            Emit_Native_Java.Emit_Clear_Color (Simple_Expr_Text (Tree (Idx).Left_Child), Success);

         when AST_Color =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_COLOR((long)(", Success); end if;
            if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw ("));", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Draw | AST_FILL | AST_Plot | AST_SET_ALPHA | AST_SET_CLIP | AST_SET_ORIGIN =>
            declare
               Arg_List : Node_Index := Tree (Idx).Left_Child;
            begin
               Emit_Native_Java.Emit_Indent (Success);
               if Tree (Idx).Kind = AST_DRAW and then Tokens (Tree (Idx).Token_Index).Kind = TOK_RECT then
                  Emit_Native_Java.Emit_Raw ("ALB_DRAW_RECT(", Success);
               elsif Tree (Idx).Kind = AST_DRAW and then Tokens (Tree (Idx).Token_Index).Kind = TOK_LINE then
                  Emit_Native_Java.Emit_Raw ("ALB_DRAW_LINE(", Success);
               elsif Tree (Idx).Kind = AST_DRAW and then Tokens (Tree (Idx).Token_Index).Kind = TOK_CIRCLE then
                  Emit_Native_Java.Emit_Raw ("ALB_DRAW_CIRCLE(", Success);
               elsif Tree (Idx).Kind = AST_DRAW and then Tokens (Tree (Idx).Token_Index).Kind = TOK_TRIANGLE then
                  Emit_Native_Java.Emit_Raw ("ALB_DRAW_TRIANGLE(", Success);
               elsif Tree (Idx).Kind = AST_FILL and then Tokens (Tree (Idx).Token_Index).Kind = TOK_RECT then
                  Emit_Native_Java.Emit_Raw ("ALB_FILL_RECT(", Success);
               elsif Tree (Idx).Kind = AST_FILL and then Tokens (Tree (Idx).Token_Index).Kind = TOK_CIRCLE then
                  Emit_Native_Java.Emit_Raw ("ALB_FILL_CIRCLE(", Success);
               elsif Tree (Idx).Kind = AST_PLOT then
                  Emit_Native_Java.Emit_Raw ("ALB_PLOT(", Success);
               elsif Tree (Idx).Kind = AST_SET_ALPHA then
                  Emit_Native_Java.Emit_Raw ("ALB_SET_ALPHA(", Success);
               elsif Tree (Idx).Kind = AST_SET_CLIP then
                  Emit_Native_Java.Emit_Raw ("ALB_SET_CLIP(", Success);
               else
                  Emit_Native_Java.Emit_Raw ("ALB_SET_ORIGIN(", Success);
               end if;
               if Success then Emit_Graphics_Arg_List (Arg_List, 1, Success); end if;
               if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
               if Success then Emit_Native_Java.Emit_Newline (Success); end if;
            end;

         when AST_Text =>
            declare
               Arg_Node : Node_Index := 0;
               Y_Node   : Node_Index := 0;
               T_Node   : Node_Index := 0;
            begin
               if Tree (Idx).Left_Child /= 0 then
                  Arg_Node := Tree (Tree (Idx).Left_Child).Left_Child;
               end if;
               if Arg_Node /= 0 then Y_Node := Tree (Arg_Node).Next_Sibling; end if;
               if Y_Node /= 0 then T_Node := Tree (Y_Node).Next_Sibling; end if;
               Emit_Native_Java.Emit_Indent (Success);
               if Success then Emit_Native_Java.Emit_Raw ("ALB_TEXT_AT(", Success); end if;
               if Success then
                  if Arg_Node /= 0 then
                     Emit_Graphics_Integer_Expr (Arg_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
               if Success then
                  if Y_Node /= 0 then
                     Emit_Graphics_Integer_Expr (Y_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
               if Success then
                  if T_Node /= 0 then
                     Emit_Text_Value (T_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("ALB_INTERN("""")", Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
               if Success then Emit_Native_Java.Emit_Newline (Success); end if;
            end;

         when AST_Play_Sound | AST_Play_Music | AST_Play_Music_From =>
            Emit_Native_Java.Emit_Indent (Success);
            if Tree (Idx).Kind = AST_Play_Sound then
               Emit_Native_Java.Emit_Raw ("ALB_PLAY_SOUND(", Success);
            elsif Tree (Idx).Kind = AST_Play_Music then
               Emit_Native_Java.Emit_Raw ("ALB_PLAY_MUSIC(", Success);
            else
               Emit_Native_Java.Emit_Raw ("ALB_PLAY_MUSIC_FROM(", Success);
            end if;
            if Success then Emit_Text_Value (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Call_Stmt | AST_Func_Call =>
            Emit_Native_Java.Emit_Indent (Success);
            if Tree (Idx).Kind = AST_Call_Stmt and then Tree (Idx).Left_Child /= 0 then
               if Tree (Tree (Idx).Left_Child).Kind = AST_Func_Call then
                  Emit_Expression (Tree (Idx).Left_Child, 1, Success);
               else
                  Emit_Native_Java.Emit_Raw (Resolve_ALB_Call_Name (Tree (Idx).Left_Child) & "()", Success);
               end if;
            else
               Emit_Expression (Idx, 1, Success);
            end if;
            if Success then Emit_Native_Java.Emit_Raw (";", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Procedure_Decl | AST_Function_Decl =>
            declare
               Name_Node   : constant Node_Index := Tree (Idx).Left_Child;
               Body_Node   : constant Node_Index := Tree (Idx).Right_Child;
               Saved_Indent : constant Natural := Emit_Native_Java.Indent_Level;
               Saved_Return_Tag : constant ALB_Type_Tag := Active_Return_Tag;
               Java_Name    : constant String := Qualified_Java_Name (Java_Safe_Symbol (Raw_Lexeme (Tree (Name_Node).Token_Index)));
               Param_List   : Node_Index := Tree (Name_Node).Right_Child;
               Param_Curr   : Node_Index := 0;
               Param_Tag    : ALB_Type_Tag := Type_U64;
               Has_Body     : constant Boolean := Body_Node /= 0 and then Tree (Body_Node).Left_Child /= 0;
            begin
               if Declare_Module_Depth > 0 and then not Has_Body then
                  null;
               elsif not Routine_Already_Emitted (Java_Name) then
                  Register_Routine_Name (Java_Name);
                  Saved_Buffer := Emit_Native_Java.Current_Buffer;
                  Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Global);
                  Emit_Native_Java.Indent_Level := 1;
                  Clear_Local_Symbols;
                  Analyze_Routine_Frame (Idx);

                  Emit_Native_Java.Emit_Indent (Success);
                  if Success then
                     if Tree (Idx).Kind = AST_Function_Decl then
                        if Tree (Idx).Token_Index > 0 then
                           Final_Tag := Type_Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
                        else
                           Final_Tag := Type_U64;
                        end if;
                        if Final_Tag = Type_None then Final_Tag := Type_U64; end if;
                        Emit_Native_Java.Emit_Raw ("private static " & Java_Primitive_Type (Final_Tag) & " " & Java_Name & "(", Success);
                     else
                        Emit_Native_Java.Emit_Raw ("private static void " & Java_Name & "(", Success);
                     end if;
                  end if;

                  if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
                     Param_Curr := Tree (Param_List).Left_Child;
                  else
                     Param_Curr := Param_List;
                  end if;

                  while Param_Curr /= 0 and then Success and then Tree (Param_Curr).Kind = AST_Param_Decl loop
                     Param_Tag := Type_U64;
                     if Tree (Param_Curr).Right_Child > 0 then
                        declare
                           Param_Type_Name : constant String :=
                             Resolve_Symbol_Name
                               (Raw_Lexeme (Tree (Tree (Param_Curr).Right_Child).Token_Index));
                        begin
                           if Find_Struct_Type (Param_Type_Name) > 0 then
                              Param_Tag := Type_Reference;
                           else
                              Param_Tag := Type_Tag_From_Name
                                (Raw_Lexeme (Tree (Tree (Param_Curr).Right_Child).Token_Index));
                           end if;
                        end;
                     end if;
                     if Param_Tag = Type_None then Param_Tag := Type_U64; end if;
                     declare
                        Param_Name : constant String := Java_Safe_Symbol (Raw_Lexeme (Tree (Tree (Param_Curr).Left_Child).Token_Index));
                     begin
                        Emit_Native_Java.Emit_Raw (Java_Primitive_Type (Param_Tag) & " " & Param_Name, Success);
                        Register_Local_Symbol (Param_Name, Param_Tag, False, Success);
                     end;
                     Param_Curr := Tree (Param_Curr).Next_Sibling;
                     if Param_Curr /= 0 and then Success then
                        Emit_Native_Java.Emit_Raw (", ", Success);
                     end if;
                  end loop;

                  if Success then Emit_Native_Java.Emit_Raw (") throws Exception {", Success); end if;
                  if Success then Emit_Native_Java.Emit_Newline (Success); end if;
                  Emit_Native_Java.Increase_Indent;
                  if Current_Frame_Size_Bytes > 0 then
                     Emit_Line
                       ("int " & Current_Frame_Base_Name (1 .. Current_Frame_Base_Len) &
                        " = alb_frame_sp;",
                        Success);
                     if Success then
                        Emit_Line
                          ("ALB_VAS_RESERVE(" &
                           Trim_Image (Natural'Image (Current_Frame_Size_Bytes)) &
                           ");",
                           Success);
                     end if;
                     if Success then
                        Emit_Line
                          ("ALB_VAS_ZERO(" &
                           Current_Frame_Base_Name (1 .. Current_Frame_Base_Len) &
                           ", " &
                           Trim_Image (Natural'Image (Current_Frame_Size_Bytes)) &
                           ");",
                           Success);
                     end if;
                     if Success then
                        Emit_Line ("try {", Success);
                     end if;
                     Emit_Native_Java.Increase_Indent;

                     if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
                        Param_Curr := Tree (Param_List).Left_Child;
                     else
                        Param_Curr := Param_List;
                     end if;

                     while Param_Curr /= 0 and then Success and then Tree (Param_Curr).Kind = AST_Param_Decl loop
                        declare
                           Param_Name : constant String :=
                             Java_Safe_Symbol
                               (Raw_Lexeme (Tree (Tree (Param_Curr).Left_Child).Token_Index));
                           Local_Idx : constant Natural := Find_Local_Symbol (Param_Name);
                           Local_Tag : constant ALB_Type_Tag := Resolved_Symbol_Tag (Param_Name);
                        begin
                           if Local_Idx > 0 and then Local_Symbols (Local_Idx).Spilled then
                              Emit_Native_Java.Emit_Indent (Success);
                              if Success then
                                 Emit_Native_Java.Emit_Raw
                                   (Java_VAS_Store_Open
                                      (Local_Tag,
                                       Target_Address_Expr (Tree (Param_Curr).Left_Child)),
                                    Success);
                              end if;
                              if Success then
                                 Emit_Native_Java.Emit_Raw (Param_Name, Success);
                              end if;
                              if Success then
                                 Emit_Native_Java.Emit_Raw
                                   (Java_VAS_Store_Close (Local_Tag) & ";",
                                    Success);
                              end if;
                              if Success then
                                 Emit_Native_Java.Emit_Newline (Success);
                              end if;
                           end if;
                        end;
                        Param_Curr := Tree (Param_Curr).Next_Sibling;
                     end loop;
                  end if;
                  if Tree (Idx).Kind = AST_Function_Decl then
                     Active_Return_Tag := Final_Tag;
                  else
                     Active_Return_Tag := Type_None;
                  end if;
                  Local_Scope_Depth := Local_Scope_Depth + 1;
                  Emit_Node (Body_Node, Depth + 1, Success);
                  if Local_Scope_Depth > 0 then
                     Local_Scope_Depth := Local_Scope_Depth - 1;
                  end if;
                  Active_Return_Tag := Saved_Return_Tag;
                  if Current_Frame_Size_Bytes > 0 then
                     Emit_Native_Java.Decrease_Indent;
                     Emit_Line ("} finally {", Success);
                     Emit_Native_Java.Increase_Indent;
                     Emit_Line
                       ("alb_frame_sp = " &
                        Current_Frame_Base_Name (1 .. Current_Frame_Base_Len) &
                        ";",
                        Success);
                     Emit_Native_Java.Decrease_Indent;
                     Emit_Line ("}", Success);
                  end if;
                  Emit_Native_Java.Decrease_Indent;
                  Emit_Native_Java.Indent_Level := 1;
                  Emit_Line ("}", Success);
                  Clear_Local_Symbols;
                  Clear_Frame_Plan;
                  Emit_Native_Java.Set_Active_Buffer (Saved_Buffer);
                  Emit_Native_Java.Indent_Level := Saved_Indent;
               end if;
            end;

         when AST_Return_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Tree (Idx).Left_Child /= 0 then
               Emit_Native_Java.Emit_Raw ("return ", Success);
               if Success then
                  if Active_Return_Tag /= Type_None then
                     Emit_Coerced_Expression
                       (Tree (Idx).Left_Child,
                        Active_Return_Tag,
                        1,
                        Success);
                  else
                     Emit_Expression (Tree (Idx).Left_Child, 1, Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Raw (";", Success); end if;
            else
               Emit_Native_Java.Emit_Raw ("return;", Success);
            end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_If_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("if (", Success); end if;
            if Success then Emit_Condition (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (") {", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;
            Emit_Native_Java.Increase_Indent;
            Emit_Node (Tree (Idx).Right_Child, Depth + 1, Success);
            Emit_Native_Java.Decrease_Indent;
            Emit_Line ("}", Success);
            if Tree (Idx).Right_Child /= 0 and then Tree (Tree (Idx).Right_Child).Next_Sibling /= 0 then
               Emit_Line ("else {", Success);
               Emit_Native_Java.Increase_Indent;
               Emit_Node (Tree (Tree (Idx).Right_Child).Next_Sibling, Depth + 1, Success);
               Emit_Native_Java.Decrease_Indent;
               Emit_Line ("}", Success);
            end if;

         when AST_While_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("while (", Success); end if;
            if Success then Emit_Condition (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (") {", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;
            Emit_Native_Java.Increase_Indent;
            Emit_Node (Tree (Idx).Right_Child, Depth + 1, Success);
            Emit_Native_Java.Decrease_Indent;
            Emit_Line ("}", Success);

         when AST_Repeat_Stmt =>
            Emit_Line ("do {", Success);
            Emit_Native_Java.Increase_Indent;
            Emit_Node (Tree (Idx).Left_Child, Depth + 1, Success);
            Emit_Native_Java.Decrease_Indent;
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("} while (!(", Success); end if;
            if Success then Emit_Condition (Tree (Idx).Right_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw ("));", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_For_Stmt =>
            declare
               Loop_Name : constant String := Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
               Dummy     : constant Node_Index := Tree (Idx).Left_Child;
               Start_N   : Node_Index := 0;
               End_N     : Node_Index := 0;
               Step_N    : Node_Index := 0;
               Step_Var  : constant String := "alb_for_step_" & Trim_Image (Integer'Image (Idx));
               End_Var   : constant String := "alb_for_end_" & Trim_Image (Integer'Image (Idx));
               Loop_Tag  : ALB_Type_Tag := Type_S32;
               Loop_Local_Idx : Natural := 0;
               Loop_Sym_Idx   : Natural := 0;
               Loop_Uses_VAS  : Boolean := False;
               procedure Emit_Long_Assign
                 (Var_Name     : String;
                  Expr_Node    : Node_Index;
                  Default_Text : String) is
               begin
                  Emit_Native_Java.Emit_Indent (Success);
                  if Success then
                     Emit_Native_Java.Emit_Raw
                       ("long " & Var_Name & " = (long)(",
                        Success);
                  end if;
                  if Success then
                     if Expr_Node /= 0 then
                        Emit_Expression (Expr_Node, 1, Success);
                     else
                        Emit_Native_Java.Emit_Raw (Default_Text, Success);
                     end if;
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw (");", Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Newline (Success);
                  end if;
               end Emit_Long_Assign;
            begin
               if Find_Local_Symbol (Loop_Name) = 0 and then Find_Java_Symbol (Loop_Name) = 0 then
                  if Local_Scope_Depth > 0 then
                     Emit_Local_Symbol_Decl (Loop_Name, Type_S32, Success);
                     Register_Local_Symbol (Loop_Name, Type_S32, False, Success);
                  else
                     Declare_Java_Symbol (Loop_Name, Type_S32, Success);
                  end if;
               end if;
               Loop_Tag := Resolved_Symbol_Tag (Loop_Name);
               Loop_Local_Idx := Find_Local_Symbol (Loop_Name);
               Loop_Sym_Idx := Find_Java_Symbol (Loop_Name);
               Loop_Uses_VAS :=
                 (Loop_Local_Idx > 0 and then Local_Symbols (Loop_Local_Idx).Spilled)
                   or else (Loop_Sym_Idx > 0 and then Java_Symbols (Loop_Sym_Idx).Spilled)
                   or else Struct_Name_Of_Resolved_Name (Loop_Name)'Length > 0;
               if Dummy /= 0 then
                  Start_N := Tree (Dummy).Left_Child;
                  if Tree (Dummy).Right_Child /= 0 and then Tree (Tree (Dummy).Right_Child).Kind = AST_Arg_List then
                     End_N := Tree (Tree (Dummy).Right_Child).Left_Child;
                     if End_N /= 0 then Step_N := Tree (End_N).Next_Sibling; end if;
                  else
                     End_N := Tree (Dummy).Right_Child;
                  end if;
               end if;
               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  if Loop_Uses_VAS then
                     Emit_Native_Java.Emit_Raw
                       (Java_VAS_Store_Open (Loop_Tag, Symbol_Address_Expr (Loop_Name)),
                        Success);
                  else
                     Emit_Native_Java.Emit_Raw
                       (Java_Value_Ref (Loop_Name) & " = " &
                        Java_Assign_Cast_Prefix (Loop_Tag),
                        Success);
                  end if;
               end if;
               if Success then Emit_Expression (Start_N, 1, Success); end if;
               if Success then
                  if Loop_Uses_VAS then
                     Emit_Native_Java.Emit_Raw
                       (Java_VAS_Store_Close (Loop_Tag) & ";",
                        Success);
                  else
                     Emit_Native_Java.Emit_Raw
                       (Java_Assign_Cast_Suffix (Loop_Tag) & ";",
                        Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Newline (Success); end if;
               Emit_Long_Assign (End_Var, End_N, "0");
               if Step_N /= 0 then
                  Emit_Long_Assign (Step_Var, Step_N, "1L");
               else
                  Emit_Line ("long " & Step_Var & " = 1L;", Success);
               end if;
               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  if Loop_Uses_VAS then
                     Emit_Native_Java.Emit_Raw
                       ("for (; (" & Step_Var & " >= 0L && " & Java_Value_Ref (Loop_Name) & " <= " & End_Var &
                        ") || (" & Step_Var & " < 0L && " & Java_Value_Ref (Loop_Name) & " >= " & End_Var &
                        "); " &
                        Java_VAS_Store_Call
                          (Loop_Tag,
                           Symbol_Address_Expr (Loop_Name),
                           Java_Assign_Cast_Prefix (Loop_Tag) &
                           Java_Value_Ref (Loop_Name) & " + " & Step_Var &
                           Java_Assign_Cast_Suffix (Loop_Tag)) &
                        ") {",
                        Success);
                  else
                     Emit_Native_Java.Emit_Raw
                       ("for (; (" & Step_Var & " >= 0L && " & Java_Value_Ref (Loop_Name) & " <= " & End_Var &
                        ") || (" & Step_Var & " < 0L && " & Java_Value_Ref (Loop_Name) & " >= " & End_Var &
                        "); " & Java_Value_Ref (Loop_Name) & " = " &
                        Java_Assign_Cast_Prefix (Loop_Tag) &
                        Java_Value_Ref (Loop_Name) & " + " & Step_Var &
                        Java_Assign_Cast_Suffix (Loop_Tag) & ") {",
                        Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Newline (Success); end if;
               Emit_Native_Java.Increase_Indent;
               Emit_Node (Tree (Idx).Right_Child, Depth + 1, Success);
               Emit_Native_Java.Decrease_Indent;
               Emit_Line ("}", Success);
            end;

         when AST_Foreach_Stmt =>
            declare
               Iter_Name : constant String := Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
               Array_Name : constant String := Resolve_Target_Name (Tree (Idx).Left_Child);
               Arr_Idx   : constant Natural := Find_Java_Symbol (Array_Name);
               Limit     : Natural := 1;
               Elem_Tag  : ALB_Type_Tag := Type_U64;
               Iter_Tag  : ALB_Type_Tag := Type_U64;
               Iter_Local_Idx : Natural := 0;
               Iter_Sym_Idx   : Natural := 0;
               Iter_Uses_VAS  : Boolean := False;
            begin
               if Arr_Idx > 0 then
                  Elem_Tag := Java_Symbols (Arr_Idx).Tag;
                  for D in 1 .. Java_Symbols (Arr_Idx).Rank loop
                     if Java_Symbols (Arr_Idx).Dims (D) > 0 then
                        Limit := Limit * Java_Symbols (Arr_Idx).Dims (D);
                     end if;
                  end loop;
               end if;
               if Find_Local_Symbol (Iter_Name) = 0 and then Find_Java_Symbol (Iter_Name) = 0 then
                  if Local_Scope_Depth > 0 then
                     Emit_Local_Symbol_Decl (Iter_Name, Elem_Tag, Success);
                     Register_Local_Symbol (Iter_Name, Elem_Tag, False, Success);
                  else
                     Declare_Java_Symbol (Iter_Name, Elem_Tag, Success);
                  end if;
               end if;
               Iter_Tag := Resolved_Symbol_Tag (Iter_Name);
               Iter_Local_Idx := Find_Local_Symbol (Iter_Name);
               Iter_Sym_Idx := Find_Java_Symbol (Iter_Name);
               Iter_Uses_VAS :=
                 (Iter_Local_Idx > 0 and then Local_Symbols (Iter_Local_Idx).Spilled)
                   or else (Iter_Sym_Idx > 0 and then Java_Symbols (Iter_Sym_Idx).Spilled)
                   or else Struct_Name_Of_Resolved_Name (Iter_Name)'Length > 0;
               Emit_Line ("for (int alb_each_" & Trim_Image (Integer'Image (Idx)) & " = 1; alb_each_" &
                 Trim_Image (Integer'Image (Idx)) & " <= " & Trim_Image (Natural'Image (Limit)) & "; alb_each_" &
                 Trim_Image (Integer'Image (Idx)) & "++) {", Success);
               Emit_Native_Java.Increase_Indent;
               if Is_Pureish_Tag (Iter_Tag) then
                  Emit_Line
                    ("ALB_COPY_PURE(" & Java_Value_Ref (Iter_Name) & ", ALB_PURE_AT(" &
                     Array_Name & ", alb_each_" & Trim_Image (Integer'Image (Idx)) & "));",
                     Success);
               else
                  if Iter_Uses_VAS then
                     Emit_Native_Java.Emit_Indent (Success);
                     if Success then
                        Emit_Native_Java.Emit_Raw
                          (Java_VAS_Store_Call
                             (Iter_Tag,
                              Symbol_Address_Expr (Iter_Name),
                              Array_Name & "[alb_each_" &
                                Trim_Image (Integer'Image (Idx)) & "]") &
                           ";",
                           Success);
                     end if;
                     if Success then
                        Emit_Native_Java.Emit_Newline (Success);
                     end if;
                  else
                     Emit_Line
                       (Java_Value_Ref (Iter_Name) & " = " &
                        Java_Assign_Cast_Prefix (Iter_Tag) &
                        Array_Name & "[alb_each_" &
                        Trim_Image (Integer'Image (Idx)) & "]" &
                        Java_Assign_Cast_Suffix (Iter_Tag) & ";",
                        Success);
                  end if;
               end if;
               Emit_Node (Tree (Idx).Right_Child, Depth + 1, Success);
               Emit_Native_Java.Decrease_Indent;
               Emit_Line ("}", Success);
            end;

         when AST_Select_Stmt | AST_Match_Stmt =>
            declare
               Case_Node : Node_Index := Tree (Idx).Right_Child;
               First_Arm : Boolean := True;
               Match_Var : constant String := "alb_match_" & Trim_Image (Integer'Image (Idx));
            begin
               Emit_Line ("long " & Match_Var & " = (long)(" & Simple_Expr_Text (Tree (Idx).Left_Child) & ");", Success);
               while Case_Node /= 0 loop
                  if Tree (Case_Node).Left_Child = 0 then
                     if First_Arm then
                        Emit_Line ("{", Success);
                     else
                        Emit_Line ("else {", Success);
                     end if;
                  else
                     if First_Arm then
                        Emit_Native_Java.Emit_Indent (Success);
                        if Success then Emit_Native_Java.Emit_Raw ("if (" & Match_Var & " == ", Success); end if;
                     else
                        Emit_Native_Java.Emit_Indent (Success);
                        if Success then Emit_Native_Java.Emit_Raw ("else if (" & Match_Var & " == ", Success); end if;
                     end if;
                     if Success then Emit_Expression (Tree (Case_Node).Left_Child, 1, Success); end if;
                     if Success then Emit_Native_Java.Emit_Raw (") {", Success); end if;
                     if Success then Emit_Native_Java.Emit_Newline (Success); end if;
                  end if;
                  Emit_Native_Java.Increase_Indent;
                  Emit_Node (Tree (Case_Node).Right_Child, Depth + 1, Success);
                  Emit_Native_Java.Decrease_Indent;
                  Emit_Line ("}", Success);
                  First_Arm := False;
                  Case_Node := Tree (Case_Node).Next_Sibling;
               end loop;
            end;

         when AST_Break_Stmt =>
            Emit_Line ("break;", Success);

         when AST_Continue_Stmt =>
            Emit_Line ("continue;", Success);

         when AST_File_Write =>
            Emit_Native_Java.Emit_Indent (Success);
            if Infer_Type_Tag (Tree (Idx).Right_Child) = Type_Binary or else Infer_Type_Tag (Tree (Idx).Right_Child) = Type_Char then
               Emit_Native_Java.Emit_Raw ("ALB_FILE_WRITE(", Success);
               if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
               if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
               if Success then Emit_Expression (Tree (Idx).Right_Child, 1, Success); end if;
            else
               Emit_Native_Java.Emit_Raw ("ALB_FILE_WRITE_NUM(", Success);
               if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
               if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
               if Success then Emit_Expression (Tree (Idx).Right_Child, 1, Success); end if;
            end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_File_Close =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_FILE_CLOSE(", Success); end if;
            if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Load_Stmt =>
            declare
               File_Node   : constant Node_Index := Tree (Idx).Left_Child;
               Target_Node : constant Node_Index := Tree (Idx).Right_Child;
               Target_Name : constant String := Resolve_Target_Name (Target_Node);
               Sym_Idx     : constant Natural := Find_Java_Symbol (Target_Name);
            begin
               Emit_Native_Java.Emit_Indent (Success);
               if Success and then Target_Uses_VAS (Target_Node) then
                  Emit_Native_Java.Emit_Raw ("ALB_VAS_LOAD_FILE((int)(", Success);
                  if Success then
                     Emit_Expression (File_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw
                       ("), " & Target_Address_Expr (Target_Node) & ", " &
                        Trim_Image (Natural'Image (Target_Byte_Size (Target_Node))) & ");",
                        Success);
                  end if;
               elsif Success and then Sym_Idx > 0
                 and then Java_Symbols (Sym_Idx).Storage = Storage_Array
               then
                  Emit_Native_Java.Emit_Raw
                    (Java_Array_Load_Call_Name (Java_Symbols (Sym_Idx).Tag) & "((int)(",
                     Success);
                  if Success then
                     Emit_Expression (File_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw
                       ("), " & Target_Name & ", " &
                        Trim_Image (Natural'Image (Java_Array_Data_Count (Sym_Idx))) & ");",
                        Success);
                  end if;
               else
                  Success := False;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Flush_Stmt =>
            declare
               Target_Node : constant Node_Index := Tree (Idx).Left_Child;
               File_Node   : constant Node_Index := Tree (Idx).Right_Child;
               Target_Name : constant String := Resolve_Target_Name (Target_Node);
               Sym_Idx     : constant Natural := Find_Java_Symbol (Target_Name);
            begin
               Emit_Native_Java.Emit_Indent (Success);
               if Success and then Sym_Idx > 0
                 and then Java_Symbols (Sym_Idx).Tag = Type_Binary
               then
                  Emit_Native_Java.Emit_Raw ("ALB_TEXT_FLUSH_FILE((int)(", Success);
                  if Success then
                     Emit_Expression (Target_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw ("), (int)(", Success);
                     Emit_Expression (File_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw ("));", Success);
                  end if;
               elsif Success and then Target_Uses_VAS (Target_Node) then
                  Emit_Native_Java.Emit_Raw
                    ("ALB_VAS_FLUSH_FILE(" & Target_Address_Expr (Target_Node) & ", " &
                     Trim_Image (Natural'Image (Target_Byte_Size (Target_Node))) & ", (int)(",
                     Success);
                  if Success then
                     Emit_Expression (File_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw ("));", Success);
                  end if;
               elsif Success and then Sym_Idx > 0
                 and then Java_Symbols (Sym_Idx).Storage = Storage_Array
               then
                  Emit_Native_Java.Emit_Raw
                    (Java_Array_Flush_Call_Name (Java_Symbols (Sym_Idx).Tag) &
                     "(" & Target_Name & ", " &
                     Trim_Image (Natural'Image (Java_Array_Data_Count (Sym_Idx))) &
                     ", (int)(",
                     Success);
                  if Success then
                     Emit_Expression (File_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw ("));", Success);
                  end if;
               else
                  Success := False;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Input_Stmt =>
            declare
               Prompt_Node : Node_Index := Tree (Idx).Left_Child;
               Target_Node : Node_Index := Tree (Idx).Right_Child;
               Temp_Name   : constant String := "alb_input_" & Trim_Image (Integer'Image (Idx));
            begin
               if Target_Node = 0 then
                  Target_Node := Prompt_Node;
                  Prompt_Node := 0;
               end if;

               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  Emit_Native_Java.Emit_Raw ("int " & Temp_Name & " = ALB_INPUT(", Success);
               end if;
               if Success then
                  if Prompt_Node /= 0 then
                     Emit_Text_Value (Prompt_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("ALB_INTERN("""")", Success);
                  end if;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (");", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
               if Success and then Target_Node /= 0 then
                  Emit_Handle_Assignment (Target_Node, Temp_Name, Success);
               end if;
            end;

         when AST_Readline_Stmt =>
            declare
               Target_Node : Node_Index := Tree (Idx).Right_Child;
               Temp_Name   : constant String := "alb_readline_" & Trim_Image (Integer'Image (Idx));
            begin
               if Target_Node = 0 then
                  Target_Node := Tree (Idx).Left_Child;
               end if;

               Emit_Line ("int " & Temp_Name & " = ALB_READLINE();", Success);
               if Success and then Target_Node /= 0 then
                  Emit_Handle_Assignment (Target_Node, Temp_Name, Success);
               end if;
            end;

         when AST_Locate_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_LOCATE(", Success); end if;
            if Success then Emit_Graphics_Integer_Expr (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
            if Success and then Tree (Idx).Right_Child /= 0 then
               Emit_Graphics_Integer_Expr (Tree (Idx).Right_Child, 1, Success);
            elsif Success then
               Emit_Native_Java.Emit_Raw ("0", Success);
            end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Msg_Box =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_MSG_BOX(", Success); end if;
            if Success then Emit_Text_Value (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
            if Success then Emit_Text_Value (Tree (Idx).Right_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Claim_Stmt =>
            declare
               Target_Node : constant Node_Index := Tree (Idx).Left_Child;
               Tag         : constant ALB_Type_Tag := Target_Tag (Target_Node);
            begin
               if Is_Pureish_Tag (Tag) then
                  Emit_Native_Java.Emit_Indent (Success);
                  if Success then
                     Emit_Pure_Target_Open (Target_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw ("ALB_PURE_CONST(ALB_GC_CLAIM(), 1));", Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Newline (Success);
                  end if;
               else
                  Emit_Native_Java.Emit_Indent (Success);
                  if Success and then Target_Uses_VAS (Target_Node) then
                     Emit_Native_Java.Emit_Raw
                       (Java_VAS_Store_Open (Tag, Target_Address_Expr (Target_Node)) &
                        "ALB_GC_CLAIM()" &
                        Java_VAS_Store_Close (Tag) &
                        ";",
                        Success);
                  else
                     if Success then
                        Emit_Target_LHS (Target_Node, 1, Success);
                     end if;
                     if Success then
                        Emit_Native_Java.Emit_Raw (" = " & Java_Assign_Cast_Prefix (Tag) & "ALB_GC_CLAIM()" &
                          Java_Assign_Cast_Suffix (Tag) & ";", Success);
                     end if;
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Newline (Success);
                  end if;
               end if;
            end;

         when AST_Drop_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_GC_DROP(", Success); end if;
            if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Sweep_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_GC_SWEEP(", Success); end if;
            if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Bind_Stmt =>
            declare
               Parent_Node : constant Node_Index := Tree (Idx).Left_Child;
               Arg_List    : Node_Index := Tree (Idx).Right_Child;
               Child_1     : Node_Index := 0;
               Child_2     : Node_Index := 0;
            begin
               if Arg_List /= 0 and then Tree (Arg_List).Kind = AST_Arg_List then
                  Child_1 := Tree (Arg_List).Left_Child;
               else
                  Child_1 := Arg_List;
               end if;
               if Child_1 /= 0 then
                  Child_2 := Tree (Child_1).Next_Sibling;
               end if;

               Emit_Native_Java.Emit_Indent (Success);
               if Success then Emit_Native_Java.Emit_Raw ("ALB_GC_BIND(", Success); end if;
               if Success then Emit_Expression (Parent_Node, 1, Success); end if;
               if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
               if Success then
                  if Child_1 /= 0 then
                     Emit_Expression (Child_1, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
               if Success then
                  if Child_2 /= 0 then
                     Emit_Expression (Child_2, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
               if Success then Emit_Native_Java.Emit_Newline (Success); end if;
            end;

         when AST_Delay_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_DELAY(", Success); end if;
            if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Sync_Stmt =>
            Emit_Line ("ALB_SYNC();", Success);

         when AST_Poke_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("ALB_POKE(", Success); end if;
            if Success then Emit_Expression (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (", ", Success); end if;
            if Success then Emit_Expression (Tree (Idx).Right_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (");", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Save_State =>
            Emit_Line ("ALB_SAVE_STATE();", Success);

         when AST_Load_State =>
            Emit_Line ("ALB_LOAD_STATE();", Success);

         when AST_Advance_Stmt =>
            declare
               Steps_Var : constant String := "alb_advance_steps_" & Trim_Image (Integer'Image (Idx));
               Loop_Var  : constant String := "alb_advance_i_" & Trim_Image (Integer'Image (Idx));
               T_Name    : String (1 .. 64) := (others => ' ');
               T_Len     : Natural := 0;
            begin
               Emit_Line ("long " & Steps_Var & " = 1L;", Success);
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Native_Java.Emit_Indent (Success);
                  if Success then
                     Emit_Native_Java.Emit_Raw (Steps_Var & " = ", Success);
                  end if;
                  if Success then
                     Emit_Expression (Tree (Idx).Left_Child, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw (";", Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Newline (Success);
                  end if;
               end if;

               Emit_Line ("for (long " & Loop_Var & " = 0L; " & Loop_Var & " < " & Steps_Var & "; " & Loop_Var & "++) {", Success);
               Emit_Native_Java.Increase_Indent;
               Emit_Line ("ALB_ADVANCE(1);", Success);

               for T in 1 .. Temporal_Symbol_Count loop
                  if not Success then
                     exit;
                  end if;

                  if Temporal_Symbols (T).Active and then Temporal_Symbols (T).History_Size > 0 then
                     T_Len := Temporal_Symbols (T).Name_Len;
                     T_Name (1 .. T_Len) := Temporal_Symbols (T).Name (1 .. T_Len);
                     Emit_Line
                       (T_Name (1 .. T_Len) & "_head[0] = " & T_Name (1 .. T_Len) & "_head[0] + 1;",
                        Success);
                     if Success then
                        Emit_Line
                          ("if (" & T_Name (1 .. T_Len) & "_head[0] >= " &
                           Trim_Image (Natural'Image (Temporal_Symbols (T).History_Size)) &
                           ") { " & T_Name (1 .. T_Len) & "_head[0] = 0; }",
                           Success);
                     end if;

                     if Success then
                        Emit_Line
                          ("ALB_VAS_COPY(ALB_VAS_TEMP_BASE + " &
                           Trim_Image
                             (Natural'Image (Temporal_Symbols (T).Timeline_Offset)) &
                           " + " & T_Name (1 .. T_Len) & "_head[0] * " &
                           Trim_Image
                             (Natural'Image (Temporal_Symbols (T).Slot_Size_Bytes)) &
                           ", " &
                           Trim_Image
                             (Natural'Image (Temporal_Symbols (T).Current_Offset)) &
                           ", " &
                           Trim_Image
                             (Natural'Image (Temporal_Symbols (T).Slot_Size_Bytes)) &
                           ");",
                           Success);
                     end if;
                  end if;
               end loop;

               Emit_Native_Java.Decrease_Indent;
               Emit_Line ("}", Success);
            end;

         when AST_Cease =>
            Emit_Line ("alb_running[0] = 0;", Success);

         when AST_Runtime_Assert =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("if (!(", Success); end if;
            if Success then Emit_Condition (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw (")) { throw new Exception(""ALB runtime assert""); }", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Throw_Stmt =>
            Emit_Native_Java.Emit_Indent (Success);
            if Success then Emit_Native_Java.Emit_Raw ("throw new Exception(ALB_TO_STRING(", Success); end if;
            if Success then Emit_Text_Value (Tree (Idx).Left_Child, 1, Success); end if;
            if Success then Emit_Native_Java.Emit_Raw ("));", Success); end if;
            if Success then Emit_Native_Java.Emit_Newline (Success); end if;

         when AST_Try_Stmt =>
            Emit_Line ("try {", Success);
            Emit_Native_Java.Increase_Indent;
            Emit_Node (Tree (Idx).Left_Child, Depth + 1, Success);
            Emit_Native_Java.Decrease_Indent;
            Emit_Line ("} catch (Exception alb_ex) {", Success);
            Emit_Native_Java.Increase_Indent;
            if Tree (Idx).Token_Index > 0 then
               declare
                  Catch_Name : constant String := Resolve_Symbol_Name (Raw_Lexeme (Tree (Idx).Token_Index));
               begin
                  -- Each Java catch block has its own local scope, so we must
                  -- emit the catch variable declaration every time even if the
                  -- same ALB catch name was used in an earlier catch block.
                  Emit_Local_Symbol_Decl (Catch_Name, Type_Binary, Success);
                  if Find_Local_Symbol (Catch_Name) = 0 then
                     Register_Local_Symbol (Catch_Name, Type_Binary, False, Success);
                  end if;
                  Emit_Line (Catch_Name & " = ALB_INTERN(alb_ex.getMessage() == null ? """" : alb_ex.getMessage());", Success);
               end;
            end if;
            Emit_Node (Tree (Idx).Right_Child, Depth + 1, Success);
            Emit_Native_Java.Decrease_Indent;
            Emit_Line ("}", Success);

         when AST_Spawn_Stmt =>
            if Tree (Idx).Left_Child /= 0 then
               Emit_Native_Java.Emit_Indent (Success);
               if Tree (Idx).Right_Child /= 0 then
                  if Success then
                     Emit_Native_Java.Emit_Raw (Resolve_Target_Name (Tree (Idx).Left_Child) & "(", Success);
                  end if;
                  if Success then
                     Emit_Arg_List (Tree (Idx).Right_Child, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw (")", Success);
                  end if;
               elsif Tree (Tree (Idx).Left_Child).Kind = AST_Func_Call then
                  Emit_Expression (Tree (Idx).Left_Child, 1, Success);
               else
                  if Success then
                     Emit_Native_Java.Emit_Raw (Resolve_Target_Name (Tree (Idx).Left_Child) & "()", Success);
                  end if;
               end if;
               if Success then Emit_Native_Java.Emit_Raw (";", Success); end if;
               if Success then Emit_Native_Java.Emit_Newline (Success); end if;
            end if;

         when AST_Rev_Add_Stmt | AST_Rev_Sub_Stmt | AST_Rev_Xor_Stmt |
              AST_Rev_Rol_Stmt | AST_Rev_Ror_Stmt | AST_Rev_Not_Stmt |
              AST_Rev_Neg_Stmt =>
            declare
               Target_Node : constant Node_Index := Tree (Idx).Left_Child;
               Value_Node  : constant Node_Index := Tree (Idx).Right_Child;
               Tag         : constant ALB_Type_Tag := Target_Tag (Target_Node);
               Uses_VAS    : constant Boolean := Target_Uses_VAS (Target_Node);
            begin
               if Is_Pureish_Tag (Tag) then
                  Emit_Comment (Node_Kind'Image (Tree (Idx).Kind), Success);
               else
                  Emit_Native_Java.Emit_Indent (Success);
                  if Success then
                     if Uses_VAS then
                        Emit_Native_Java.Emit_Raw
                          (Java_VAS_Store_Open (Tag, Target_Address_Expr (Target_Node)),
                           Success);
                     else
                        Emit_Target_LHS (Target_Node, 1, Success);
                     end if;
                  end if;
                  if Success then
                     if not Uses_VAS then
                        Emit_Native_Java.Emit_Raw (" = ", Success);
                     end if;
                  end if;
                  if Success then
                     case Tree (Idx).Kind is
                        when AST_Rev_Add_Stmt =>
                           Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Prefix (Tag), Success);
                           if Success then Emit_Expression (Target_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (" + ", Success); end if;
                           if Success then Emit_Expression (Value_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Suffix (Tag), Success); end if;

                        when AST_Rev_Sub_Stmt =>
                           Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Prefix (Tag), Success);
                           if Success then Emit_Expression (Target_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (" - ", Success); end if;
                           if Success then Emit_Expression (Value_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Suffix (Tag), Success); end if;

                        when AST_Rev_Xor_Stmt =>
                           Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Prefix (Tag), Success);
                           if Success then Emit_Expression (Target_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (" ^ ", Success); end if;
                           if Success then Emit_Expression (Value_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Suffix (Tag), Success); end if;

                        when AST_Rev_Rol_Stmt =>
                           case Tag is
                              when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 =>
                                 Emit_Native_Java.Emit_Raw ("(byte)(ALB_ROL8((int)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                              when Type_U16 | Type_S16 | Type_HW16 =>
                                 Emit_Native_Java.Emit_Raw ("(short)(ALB_ROL16((int)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                              when Type_U64 | Type_S64 | Type_HW64 =>
                                 Emit_Native_Java.Emit_Raw ("(long)(ALB_ROL64((long)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                              when others =>
                                 Emit_Native_Java.Emit_Raw ("(int)(ALB_ROL32((int)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                           end case;

                        when AST_Rev_Ror_Stmt =>
                           case Tag is
                              when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 =>
                                 Emit_Native_Java.Emit_Raw ("(byte)(ALB_ROR8((int)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                              when Type_U16 | Type_S16 | Type_HW16 =>
                                 Emit_Native_Java.Emit_Raw ("(short)(ALB_ROR16((int)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                              when Type_U64 | Type_S64 | Type_HW64 =>
                                 Emit_Native_Java.Emit_Raw ("(long)(ALB_ROR64((long)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                              when others =>
                                 Emit_Native_Java.Emit_Raw ("(int)(ALB_ROR32((int)(", Success);
                                 if Success then Emit_Expression (Target_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw ("), (int)(", Success); end if;
                                 if Success then Emit_Expression (Value_Node, 1, Success); end if;
                                 if Success then Emit_Native_Java.Emit_Raw (")))", Success); end if;
                           end case;

                        when AST_Rev_Not_Stmt =>
                           Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Prefix (Tag) & "~(", Success);
                           if Success then Emit_Expression (Target_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (")" & Java_Assign_Cast_Suffix (Tag), Success); end if;

                        when AST_Rev_Neg_Stmt =>
                           Emit_Native_Java.Emit_Raw (Java_Assign_Cast_Prefix (Tag) & "-(", Success);
                           if Success then Emit_Expression (Target_Node, 1, Success); end if;
                           if Success then Emit_Native_Java.Emit_Raw (")" & Java_Assign_Cast_Suffix (Tag), Success); end if;

                        when others =>
                           Emit_Native_Java.Emit_Raw ("0", Success);
                     end case;
                  end if;
                  if Success then
                     if Uses_VAS then
                        Emit_Native_Java.Emit_Raw
                          (Java_VAS_Store_Close (Tag) & ";",
                           Success);
                     else
                        Emit_Native_Java.Emit_Statement_End (Success);
                     end if;
                  end if;
               end if;
            end;

         when AST_Rev_Swap_Stmt =>
            declare
               Left_Node  : constant Node_Index := Tree (Idx).Left_Child;
               Right_Node : constant Node_Index := Tree (Idx).Right_Child;
               Left_Tag   : constant ALB_Type_Tag := Target_Tag (Left_Node);
               Right_Tag  : constant ALB_Type_Tag := Target_Tag (Right_Node);
               Temp_Name  : constant String := "alb_rev_swap_" & Trim_Image (Integer'Image (Idx));
            begin
               if Is_Pureish_Tag (Left_Tag) or else Is_Pureish_Tag (Right_Tag) then
                  Emit_Comment (Node_Kind'Image (Tree (Idx).Kind), Success);
               else
                  Emit_Native_Java.Emit_Indent (Success);
                  if Success then
                     Emit_Native_Java.Emit_Raw (Java_Primitive_Type (Left_Tag) & " " & Temp_Name & " = ", Success);
                  end if;
                  if Success then
                     Emit_Expression (Left_Node, 1, Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Raw (";", Success);
                  end if;
                  if Success then
                     Emit_Native_Java.Emit_Newline (Success);
                  end if;

                  Emit_Assignment_To_Target (Left_Node, Right_Node, Success);
                  if Success then
                     Emit_Text_Assignment_To_Target (Right_Node, Temp_Name, Success);
                  end if;
               end if;
            end;

         when AST_SwapPop_Stmt =>
            declare
               Target_Node : constant Node_Index := Tree (Idx).Left_Child;
               Count_Node  : constant Node_Index := Tree (Idx).Right_Child;
               Index_Node  : Node_Index := 0;
               Group_Name  : constant String :=
                 (if Target_Node /= 0 and then Tree (Target_Node).Kind = AST_Var_Expr
                  then Resolve_Symbol_Name (Raw_Lexeme (Tree (Target_Node).Token_Index))
                  else "");
               Count_Tag   : ALB_Type_Tag := Type_U64;
               Last_Name   : constant String := "alb_swappop_last_" & Trim_Image (Integer'Image (Idx));
               Index_Name  : constant String := "alb_swappop_index_" & Trim_Image (Integer'Image (Idx));
            begin
               if Target_Node /= 0 and then Tree (Target_Node).Kind = AST_Var_Expr then
                  Index_Node := Tree (Target_Node).Left_Child;
               end if;
               Count_Tag := Target_Tag (Count_Node);

               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  Emit_Native_Java.Emit_Raw ("int " & Last_Name & " = (int)(", Success);
               end if;
               if Success then
                  Emit_Expression (Count_Node, 1, Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (");", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;

               Emit_Line ("if (" & Last_Name & " > 0) {", Success);
               Emit_Native_Java.Increase_Indent;
               Emit_Native_Java.Emit_Indent (Success);
               if Success then
                  Emit_Native_Java.Emit_Raw ("int " & Index_Name & " = (int)(", Success);
               end if;
               if Success then
                  if Index_Node /= 0 then
                     Emit_Expression (Index_Node, 1, Success);
                  else
                     Emit_Native_Java.Emit_Raw ("0", Success);
                  end if;
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw (");", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;

               Emit_Line ("if (" & Index_Name & " > 0 && " & Index_Name & " <= " & Last_Name & ") {", Success);
               Emit_Native_Java.Increase_Indent;
               Emit_Line ("if (" & Index_Name & " != " & Last_Name & ") {", Success);
               Emit_Native_Java.Increase_Indent;
               for PF in 1 .. Parallel_Field_Count loop
                  if Parallel_Fields (PF).Active
                    and then Parallel_Fields (PF).Group_Name_Len = Group_Name'Length
                    and then Parallel_Fields (PF).Group_Name (1 .. Group_Name'Length) = Group_Name
                  then
                     declare
                        Backing_Name : constant String :=
                          Parallel_Fields (PF).Backing_Name
                            (1 .. Parallel_Fields (PF).Backing_Name_Len);
                     begin
                        Emit_Line (Backing_Name & "[" & Index_Name & "] = " &
                          Backing_Name & "[" & Last_Name & "];", Success);
                     end;
                  end if;
               end loop;
               Emit_Native_Java.Decrease_Indent;
               Emit_Line ("}", Success);
               if Success then
                  Emit_Text_Assignment_To_Target
                    (Count_Node,
                     Last_Name & " - 1",
                     Success);
               end if;
               Emit_Native_Java.Decrease_Indent;
               Emit_Line ("}", Success);
               Emit_Native_Java.Decrease_Indent;
               Emit_Line ("}", Success);
            end;

         when AST_Knows_Change =>
            declare
               Pred_Node    : constant Node_Index := Tree (Idx).Right_Child;
               Block_Node   : constant Node_Index := Tree (Idx).Left_Child;
               Pred_Name    : constant String := Predicate_Name_Of (Pred_Node);
               Arg_Node     : constant Node_Index := Predicate_Arg_Node (Pred_Node);
               Hook_Name    : constant String :=
                 "ALB_ON_CHANGE_" &
                 Java_Safe_Symbol (Pred_Name) &
                 "_" &
                 Trim_Image (Integer'Image (Integer (Idx)));
               Saved_Buffer : constant Emit_Native_Java.Buffer_Target :=
                 Emit_Native_Java.Current_Buffer;
               Saved_Indent : constant Natural := Emit_Native_Java.Indent_Level;
            begin
               if Pred_Name'Length = 0 then
                  Emit_Comment (Node_Kind'Image (Tree (Idx).Kind), Success);
               else
                  Register_Knows_Change_Hook (Pred_Name, Hook_Name);

                  if not Routine_Already_Emitted (Hook_Name) then
                     Register_Routine_Name (Hook_Name);
                     Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Global);
                     Emit_Native_Java.Indent_Level := 1;
                     Clear_Local_Symbols;

                     Emit_Native_Java.Emit_Indent (Success);
                     if Success then
                        Emit_Native_Java.Emit_Raw
                          ("private static void " & Hook_Name & "(int changeValue) throws Exception {",
                           Success);
                     end if;
                     if Success then
                        Emit_Native_Java.Emit_Newline (Success);
                     end if;
                     Emit_Native_Java.Increase_Indent;
                     if Arg_Node /= 0 and then Tree (Arg_Node).Kind = AST_Logic_Var then
                        declare
                           Arg_Name : constant String :=
                             Java_Safe_Symbol (Raw_Lexeme (Tree (Arg_Node).Token_Index));
                        begin
                           Register_Local_Symbol (Arg_Name, Type_U32, False, Success);
                           if Success then
                              Emit_Line ("int " & Arg_Name & " = changeValue;", Success);
                           end if;
                        end;
                     end if;
                     Local_Scope_Depth := Local_Scope_Depth + 1;
                     Emit_Node (Block_Node, Depth + 1, Success);
                     if Local_Scope_Depth > 0 then
                        Local_Scope_Depth := Local_Scope_Depth - 1;
                     end if;
                     Emit_Native_Java.Decrease_Indent;
                     if Success then
                        Emit_Native_Java.Emit_Indent (Success);
                     end if;
                     if Success then
                        Emit_Native_Java.Emit_Raw ("}", Success);
                     end if;
                     if Success then
                        Emit_Native_Java.Emit_Newline (Success);
                        Emit_Native_Java.Emit_Newline (Success);
                     end if;

                     Clear_Local_Symbols;
                     Emit_Native_Java.Set_Active_Buffer (Saved_Buffer);
                     Emit_Native_Java.Indent_Level := Saved_Indent;
                  end if;
               end if;
            end;

         when AST_Findall_Query =>
            declare
               Target_Name : constant String := Resolve_Target_Name (Tree (Idx).Right_Child);
               Target_Idx  : constant Natural := Find_Java_Symbol (Target_Name);
               Target_Tag  : constant ALB_Type_Tag := Resolved_Symbol_Tag (Target_Name);
               Limit       : Natural := 16;
            begin
               if Target_Idx > 0 and then Java_Symbols (Target_Idx).Rank > 0 and then Java_Symbols (Target_Idx).Dims (1) > 0 then
                  Limit := Java_Symbols (Target_Idx).Dims (1) - 1;
               end if;

               Emit_Native_Java.Emit_Indent (Success);
               Emit_Native_Java.Emit_Raw (Target_Name & "[0] = ", Success);
               if Target_Tag = Type_U16 or else Target_Tag = Type_S16 or else Target_Tag = Type_HW16 then
                  Emit_Native_Java.Emit_Raw ("(short)", Success);
               elsif Target_Tag = Type_U8 or else Target_Tag = Type_S8 or else Target_Tag = Type_Boolean or else Target_Tag = Type_HW8 then
                  Emit_Native_Java.Emit_Raw ("(byte)", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw ("ALB_KB_FINDALL(ALB_HASH(", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_String_Literal (Predicate_Name_Of (Idx), Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Raw ("), " & Target_Name & ", " & Trim_Image (Natural'Image (Limit)) & ");", Success);
               end if;
               if Success then
                  Emit_Native_Java.Emit_Newline (Success);
               end if;
            end;

         when AST_Static_Surface_Decl =>
            declare
               Name_Node    : constant Node_Index := Tree (Idx).Left_Child;
               Surface_Name : constant String :=
                 (if Name_Node /= 0
                  then Java_Safe_Symbol (Raw_Lexeme (Tree (Name_Node).Token_Index))
                  else "");
            begin
               if Surface_Name'Length > 0 then
                  if Find_Java_Symbol (Surface_Name) = 0
                    and then Java_Symbol_Count < Max_Java_Symbols
                    and then Surface_Name'Length <= 64
                  then
                     Java_Symbol_Count := Java_Symbol_Count + 1;
                     Java_Symbols (Java_Symbol_Count).Active := True;
                     Java_Symbols (Java_Symbol_Count).Name_Len := Surface_Name'Length;
                     Java_Symbols (Java_Symbol_Count).Name (1 .. Surface_Name'Length) :=
                       Surface_Name;
                     Java_Symbols (Java_Symbol_Count).Tag := Type_S32;
                     Java_Symbols (Java_Symbol_Count).Storage := Storage_Scalar;
                     Emit_Global_Line
                       ("private static final int[] " &
                        Surface_Name &
                        " = new int[] { 1 };",
                        Success);
                  end if;
               else
                  Emit_Native_Java.Emit_Unsupported
                    (Node_Kind'Image (Tree (Idx).Kind),
                     Success);
               end if;
            end;

         when others =>
            Emit_Native_Java.Emit_Unsupported
              (Node_Kind'Image (Tree (Idx).Kind),
               Success);
      end case;
   end Emit_Node;

   procedure Render_Parse_Diagnostics is
      Err_Line  : Positive := 1;
      Err_Col   : Positive := 1;
      Err_Code  : Oracle_Code := Err_None;
      M_Rec     : Source_Map_Record := (File_ID => 1, Rel_Line => 1);
      FName_Len : Natural := 1;
      FName     : String (1 .. Max_Path_Len) := (others => ' ');
   begin
      if Input_Flen > 0 then
         FName_Len := Input_Flen;
         FName (1 .. Input_Flen) := Input_File (1 .. Input_Flen);
      else
         FName (1) := '?';
      end if;

      if Parse_Diag.Error_Count > 0 then
         Err_Line := Parse_Diag.Errors (1).Line;
         Err_Col  := Parse_Diag.Errors (1).Col;
         Err_Code := Parse_Diag.Errors (1).Code;
      else
         Err_Line := Parse_Diag.Error_Line;
         Err_Col  := Parse_Diag.Error_Col;
         Err_Code := Parse_Diag.Code;
      end if;

      if Err_Line <= Abs_Line_Count then
         M_Rec := Source_Map (Err_Line);
         if M_Rec.File_ID in 1 .. Include_Count then
            FName_Len := Include_Lens (M_Rec.File_ID);
            FName := (others => ' ');
            if FName_Len > 0 then
               FName (1 .. FName_Len) :=
                 Include_Vault (M_Rec.File_ID) (1 .. FName_Len);
            end if;
         end if;
      end if;

      ALB_Oracle.Render_Consultation
        (Input_Buffer (1 .. Input_Len),
         Err_Line,
         M_Rec.Rel_Line,
         Err_Col,
         FName (1 .. FName_Len),
         Err_Code);
   end Render_Parse_Diagnostics;

   function Strip_Extension (File_Name : String) return String is
      Dot_Pos : Natural := 0;
   begin
      for I in reverse File_Name'Range loop
         if File_Name (I) = '.' then
            Dot_Pos := I;
            exit;
         end if;
      end loop;

      if Dot_Pos > File_Name'First then
         return File_Name (File_Name'First .. Dot_Pos - 1);
      end if;

      return File_Name;
   end Strip_Extension;

   function Safe_Containing_Directory (Path : String) return String is
   begin
      return Ada.Directories.Containing_Directory (Path);
   exception
      when others =>
         return "";
   end Safe_Containing_Directory;

   function Is_Absolute_Path (Path : String) return Boolean is
   begin
      if Path'Length = 0 then
         return False;
      end if;

      if Path (Path'First) = '\' or else Path (Path'First) = '/' then
         return True;
      end if;

      return Path'Length >= 2 and then Path (Path'First + 1) = ':';
   end Is_Absolute_Path;

   function Default_Output_Name return String is
   begin
      return "ALB_Core.java";
   end Default_Output_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "java_" & Strip_Extension (Ada.Directories.Simple_Name (Input));
   exception
      when others =>
         return "java_output";
   end Default_Out_Dir;

   procedure Print_Help is
   begin
      Put_Line ("ALBJ: AdaLogic BASIC for Java/FlatJVM");
      Put_Line ("Usage: albj [options] <input.alb> [ALB_Core.java]");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  -o <file>             Output Java source path (must end with ALB_Core.java)");
      Put_Line ("  --outdir <dir>        Output directory");
      Put_Line ("  --build, -b           Full build: transpile + javac + native-image");
      Put_Line ("  --run                 Dev run: transpile + javac + java ALB_Desktop");
      Put_Line ("  --help, -h            Show this help");
      Put_Line ("  --gfx=<backend>       RHI hint (opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12; stored for tooling parity)");
      New_Line;
      Put_Line ("System includes: INCLUDE <name.albi> resolves under SDK stdlib/vendor/.");
      New_Line;
      Put_Line ("Legacy forms are still accepted:");
      Put_Line ("  albj compile <input.alb>");
      Put_Line ("  albj run <input.alb>");
   end Print_Help;

   procedure Store_Path
     (Text   : String;
      Buffer : out String;
      Length : out Natural;
      Label  : String) is
   begin
      Buffer := (others => ' ');
      if Text'Length > Buffer'Length then
         Put_Line ("ALBJ: " & Label & " path is too long: " & Text);
         Length := 0;
         Arg_Error := True;
      else
         Length := Text'Length;
         Buffer (Buffer'First .. Buffer'First + Length - 1) := Text;
      end if;
   end Store_Path;

   function Find_Desktop_Shell_Source return String is
      Working_Copy : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Current_Directory,
           "ALB_Desktop",
           "java");
      Exec_Dir : constant String :=
        Safe_Containing_Directory (Ada.Command_Line.Command_Name);
      Project_Dir : constant String :=
        (if Exec_Dir'Length > 0
         then Safe_Containing_Directory (Exec_Dir)
         else "");
      Installed_Copy : constant String :=
        (if Exec_Dir'Length > 0
         then Ada.Directories.Compose (Exec_Dir, "ALB_Desktop", "java")
         else "");
      Source_Copy : constant String :=
        (if Project_Dir'Length > 0
         then Ada.Directories.Compose
           (Ada.Directories.Compose (Project_Dir, "src"),
            "ALB_Desktop",
            "java")
         else "");
   begin
      if Ada.Directories.Exists (Working_Copy) then
         return Working_Copy;
      end if;

      if Installed_Copy'Length > 0
        and then Ada.Directories.Exists (Installed_Copy)
      then
         return Installed_Copy;
      end if;

      if Source_Copy'Length > 0
        and then Ada.Directories.Exists (Source_Copy)
      then
         return Source_Copy;
      end if;

      return "";
   end Find_Desktop_Shell_Source;

   procedure Safe_Delete_Tree (Path : String) is
   begin
      if Path'Length > 0 and then Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_Tree (Path);
      end if;
   exception
      when others =>
         Put_Line ("WARN: Could not remove staging directory " & Path);
   end Safe_Delete_Tree;

   procedure Ensure_Fresh_Stage_Directory
     (Stage_Dir : String;
      Success   : out Boolean) is
   begin
      Success := False;
      Safe_Delete_Tree (Stage_Dir);
      Ada.Directories.Create_Path (Stage_Dir);
      Success := True;
   exception
      when E : others =>
         Put_Line
           ("FATAL: Could not prepare staging directory " &
            Stage_Dir &
            ": " &
            Ada.Exceptions.Exception_Message (E));
   end Ensure_Fresh_Stage_Directory;

   procedure Copy_File_Overwrite
     (Source_Path : String;
      Dest_Path   : String;
      Success     : out Boolean) is
      Source_File : Ada.Streams.Stream_IO.File_Type;
      Dest_File   : Ada.Streams.Stream_IO.File_Type;
      Buffer      : Ada.Streams.Stream_Element_Array (1 .. 8192);
      Last        : Ada.Streams.Stream_Element_Offset;
      Source_Open : Boolean := False;
      Dest_Open   : Boolean := False;
   begin
      Success := False;

      declare
         Dest_Parent : constant String := Safe_Containing_Directory (Dest_Path);
      begin
         if Dest_Parent'Length > 0 then
            Ada.Directories.Create_Path (Dest_Parent);
         end if;
      end;

      Ada.Streams.Stream_IO.Open
        (Source_File,
         Ada.Streams.Stream_IO.In_File,
         Source_Path);
      Source_Open := True;

      Ada.Streams.Stream_IO.Create
        (Dest_File,
         Ada.Streams.Stream_IO.Out_File,
         Dest_Path);
      Dest_Open := True;

      while not Ada.Streams.Stream_IO.End_Of_File (Source_File) loop
         Ada.Streams.Stream_IO.Read (Source_File, Buffer, Last);
         if Last >= Buffer'First then
            Ada.Streams.Stream_IO.Write (Dest_File, Buffer (Buffer'First .. Last));
         end if;
      end loop;

      Ada.Streams.Stream_IO.Close (Source_File);
      Ada.Streams.Stream_IO.Close (Dest_File);
      Success := True;
   exception
      when E : others =>
         if Source_Open then
            begin
               Ada.Streams.Stream_IO.Close (Source_File);
            exception
               when others =>
                  null;
            end;
         end if;

         if Dest_Open then
            begin
               Ada.Streams.Stream_IO.Close (Dest_File);
            exception
               when others =>
                  null;
            end;
         end if;

         Put_Line
           ("FATAL: Could not copy file " &
            Source_Path &
            " to " &
            Dest_Path &
            ": " &
            Ada.Exceptions.Exception_Message (E));
   end Copy_File_Overwrite;

   procedure Free_Argument_List
     (Args : in out GNAT.OS_Lib.Argument_List) is
   begin
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
   end Free_Argument_List;

   function Spawn_And_Check
     (Label             : String;
      Working_Directory : String;
      Program_Name      : String;
      Args              : GNAT.OS_Lib.Argument_List) return Boolean is
      Original_Directory : constant String :=
        Ada.Directories.Current_Directory;
      Exit_Code : Integer := -1;
   begin
      Ada.Directories.Set_Directory (Working_Directory);
      Exit_Code := GNAT.OS_Lib.Spawn (Program_Name, Args);
      Ada.Directories.Set_Directory (Original_Directory);

      if Exit_Code /= 0 then
         Put_Line
           ("FATAL: " &
            Label &
            " failed with exit status" &
            Integer'Image (Exit_Code) &
            ".");
         return False;
      end if;

      return True;
   exception
      when E : others =>
         begin
            Ada.Directories.Set_Directory (Original_Directory);
         exception
            when others =>
               null;
         end;

         Put_Line
           ("FATAL: Could not execute " &
            Label &
            ": " &
            Ada.Exceptions.Exception_Message (E));
         return False;
   end Spawn_And_Check;

   function Run_Javac_Pass (Stage_Dir : String) return Boolean is
   begin
      Put_Line ("ALBJ> Running javac in " & Stage_Dir);

      if Ada.Environment_Variables.Exists ("ComSpec") then
         declare
            Args : GNAT.OS_Lib.Argument_List (1 .. 4) :=
              (1 => new String'("/c"),
               2 => new String'("javac"),
               3 => new String'("ALB_Core.java"),
               4 => new String'("ALB_Desktop.java"));
            Success : Boolean := False;
         begin
            Success :=
              Spawn_And_Check
                ("javac",
                 Stage_Dir,
                 Ada.Environment_Variables.Value ("ComSpec"),
                 Args);
            Free_Argument_List (Args);
            return Success;
         end;
      else
         declare
            Args : GNAT.OS_Lib.Argument_List (1 .. 2) :=
              (1 => new String'("ALB_Core.java"),
               2 => new String'("ALB_Desktop.java"));
            Success : Boolean := False;
         begin
            Success := Spawn_And_Check ("javac", Stage_Dir, "javac", Args);
            Free_Argument_List (Args);
            return Success;
         end;
      end if;
   end Run_Javac_Pass;

   function Run_Java_Desktop_Pass (Stage_Dir : String) return Boolean is
   begin
      Put_Line ("ALBJ> Running java ALB_Desktop in " & Stage_Dir);

      if Ada.Environment_Variables.Exists ("ComSpec") then
         declare
            Args : GNAT.OS_Lib.Argument_List (1 .. 3) :=
              (1 => new String'("/c"),
               2 => new String'("java"),
               3 => new String'("ALB_Desktop"));
            Success : Boolean := False;
         begin
            Success :=
              Spawn_And_Check
                ("java",
                 Stage_Dir,
                 Ada.Environment_Variables.Value ("ComSpec"),
                 Args);
            Free_Argument_List (Args);
            return Success;
         end;
      else
         declare
            Args : GNAT.OS_Lib.Argument_List (1 .. 1) :=
              (1 => new String'("ALB_Desktop"));
            Success : Boolean := False;
         begin
            Success := Spawn_And_Check ("java", Stage_Dir, "java", Args);
            Free_Argument_List (Args);
            return Success;
         end;
      end if;
   end Run_Java_Desktop_Pass;

   function Run_Metadata_Agent_Pass (Stage_Dir : String) return Boolean is
      Metadata_Dir : constant String :=
        Ada.Directories.Compose (Stage_Dir, "native-image-config");
      Final_Metadata_Dir : constant String :=
        Ada.Directories.Compose (Stage_Dir, "native-image-config-ready");
      function Finalize_Metadata_Output return Boolean is
         Metadata_File : constant String :=
           Ada.Directories.Compose
             (Final_Metadata_Dir, "reachability-metadata.json");
         Search : Ada.Directories.Search_Type;
         Dir_Entry  : Ada.Directories.Directory_Entry_Type;
         Filter : constant Ada.Directories.Filter_Type :=
           (Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False);
         Copied    : Boolean := False;

         procedure Copy_Metadata_File (Src, Name : String) is
            Dst : constant String :=
              Ada.Directories.Compose (Final_Metadata_Dir, Name);
            Copy_OK : Boolean := False;
         begin
            if Name /= "." and then Name /= ".." and then Name /= ".lock" then
               Copy_File_Overwrite (Src, Dst, Copy_OK);
               if Copy_OK or else Ada.Directories.Exists (Dst) then
                  Copied := True;
               end if;
            end if;
         end Copy_Metadata_File;

         procedure Promote_Temp_Files (Temp_Dir : String) is
            Temp_Search : Ada.Directories.Search_Type;
            Temp_Entry  : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Start_Search
              (Temp_Search,
               Directory => Temp_Dir,
               Pattern   => "*",
               Filter    => Filter);

            while Ada.Directories.More_Entries (Temp_Search) loop
               Ada.Directories.Get_Next_Entry (Temp_Search, Temp_Entry);

               declare
                  Name : constant String :=
                    Ada.Directories.Simple_Name (Temp_Entry);
                  Kind : constant Ada.Directories.File_Kind :=
                    Ada.Directories.Kind (Temp_Entry);
                  Src  : constant String :=
                    Ada.Directories.Full_Name (Temp_Entry);
               begin
                  if Name /= "." and then Name /= ".." then
                     if Kind = Ada.Directories.Directory then
                        Promote_Temp_Files (Src);
                     elsif Kind = Ada.Directories.Ordinary_File then
                        Copy_Metadata_File (Src, Name);
                     end if;
                  end if;
               end;
            end loop;

            Ada.Directories.End_Search (Temp_Search);
         exception
            when others =>
               begin
                  Ada.Directories.End_Search (Temp_Search);
               exception
                  when others =>
                     null;
               end;
               null;
         end Promote_Temp_Files;
      begin
         begin
            if Ada.Directories.Exists (Final_Metadata_Dir) then
               Ada.Directories.Delete_Tree (Final_Metadata_Dir);
            end if;
            Ada.Directories.Create_Path (Final_Metadata_Dir);
         exception
            when others =>
               return False;
         end;

         Ada.Directories.Start_Search
           (Search,
            Directory => Metadata_Dir,
            Pattern   => "*",
            Filter    => Filter);

         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

            declare
               Name : constant String :=
                 Ada.Directories.Simple_Name (Dir_Entry);
               Kind : constant Ada.Directories.File_Kind :=
                 Ada.Directories.Kind (Dir_Entry);
               Full : constant String :=
                 Ada.Directories.Full_Name (Dir_Entry);
            begin
               if Name /= "." and then Name /= ".." then
                  if Kind = Ada.Directories.Directory
                    and then Name'Length >= 9
                    and then Name (Name'First .. Name'First + 8) = "agent-pid"
                  then
                     Promote_Temp_Files (Full);
                  elsif Kind = Ada.Directories.Ordinary_File then
                     Copy_Metadata_File (Full, Name);
                  end if;
               end if;
            end;
         end loop;

         Ada.Directories.End_Search (Search);
         return Copied or else Ada.Directories.Exists (Metadata_File);
      exception
         when others =>
            begin
               Ada.Directories.End_Search (Search);
            exception
               when others =>
                  null;
            end;
            return Ada.Directories.Exists (Metadata_File);
      end Finalize_Metadata_Output;
   begin
      Put_Line ("ALBJ> Collecting GraalVM reachability metadata in " & Metadata_Dir);

      begin
         if Ada.Directories.Exists (Metadata_Dir) then
            Ada.Directories.Delete_Tree (Metadata_Dir);
         end if;
         Ada.Directories.Create_Path (Metadata_Dir);
      exception
         when E : others =>
            Put_Line
              ("FATAL: Could not prepare metadata directory " &
               Metadata_Dir &
               ": " &
               Ada.Exceptions.Exception_Message (E));
            return False;
      end;

      if Ada.Environment_Variables.Exists ("ComSpec") then
         declare
            Args : GNAT.OS_Lib.Argument_List (1 .. 5) :=
              (1 => new String'("/c"),
               2 => new String'("java"),
               3 => new String'
                 ("-agentlib:native-image-agent=config-output-dir=" &
                  Ada.Directories.Full_Name (Metadata_Dir)),
                4 => new String'("ALB_Desktop"),
                5 => new String'("--trace-awt-metadata"));
            Success : Boolean := False;
         begin
            Success :=
              Spawn_And_Check
                ("metadata tracing",
                 Stage_Dir,
                 Ada.Environment_Variables.Value ("ComSpec"),
                 Args);
            Free_Argument_List (Args);
            declare
               Metadata_OK : constant Boolean := Finalize_Metadata_Output;
            begin
               if not Success and then Metadata_OK then
                  Put_Line
                    ("ALBJ> Metadata trace completed with a non-fatal agent warning; using finalized metadata output.");
               end if;
               Success := Success or else Metadata_OK;
            end;
            return Success;
         end;
      else
         declare
            Args : GNAT.OS_Lib.Argument_List (1 .. 3) :=
              (1 => new String'
                 ("-agentlib:native-image-agent=config-output-dir=" &
                  Ada.Directories.Full_Name (Metadata_Dir)),
               2 => new String'("ALB_Desktop"),
               3 => new String'("--trace-awt-metadata"));
            Success : Boolean := False;
         begin
            Success :=
              Spawn_And_Check
                ("metadata tracing",
                 Stage_Dir,
                 "java",
                 Args);
            Free_Argument_List (Args);
            declare
               Metadata_OK : constant Boolean := Finalize_Metadata_Output;
            begin
               if not Success and then Metadata_OK then
                  Put_Line
                    ("ALBJ> Metadata trace completed with a non-fatal agent warning; using finalized metadata output.");
               end if;
               Success := Success or else Metadata_OK;
            end;
            return Success;
         end;
      end if;
   end Run_Metadata_Agent_Pass;

   function Write_Supplemental_Metadata (Stage_Dir : String) return Boolean is
      Metadata_Dir : constant String :=
        Ada.Directories.Compose (Stage_Dir, "native-image-manual");
      Metadata_File : constant String :=
        Ada.Directories.Compose
          (Metadata_Dir, "reachability-metadata", "json");
      type Type_List is array (Positive range <>) of access constant String;
      Event_Types : constant Type_List :=
        (new String'("java.awt.AWTEvent"),
         new String'("java.awt.Component"),
         new String'("java.awt.Container"),
         new String'("java.awt.Window"),
         new String'("java.awt.Frame"),
         new String'("java.awt.Toolkit"),
         new String'("java.awt.event.ActionEvent"),
         new String'("java.awt.event.ComponentEvent"),
         new String'("java.awt.event.ContainerEvent"),
         new String'("java.awt.event.FocusEvent"),
         new String'("java.awt.event.HierarchyEvent"),
         new String'("java.awt.event.InputEvent"),
         new String'("java.awt.event.InputMethodEvent"),
         new String'("java.awt.event.InvocationEvent"),
         new String'("java.awt.event.ItemEvent"),
         new String'("java.awt.event.KeyEvent"),
         new String'("java.awt.event.MouseEvent"),
         new String'("java.awt.event.MouseWheelEvent"),
         new String'("java.awt.event.PaintEvent"),
         new String'("java.awt.event.TextEvent"),
         new String'("java.awt.event.WindowEvent"));

      procedure Put_Type_Block
        (File_Handle : in out Ada.Text_IO.File_Type;
         Type_Name   : String;
         Is_Last     : Boolean) is
      begin
         Put_Line (File_Handle, "    {");
         Put_Line (File_Handle, "      ""type"": """ & Type_Name & """,");
         Put_Line (File_Handle, "      ""allDeclaredConstructors"": true,");
         Put_Line (File_Handle, "      ""allPublicConstructors"": true,");
         Put_Line (File_Handle, "      ""allDeclaredMethods"": true,");
         Put_Line (File_Handle, "      ""allPublicMethods"": true,");
         Put_Line (File_Handle, "      ""allDeclaredFields"": true,");
         Put_Line (File_Handle, "      ""allPublicFields"": true");
         if Is_Last then
            Put_Line (File_Handle, "    }");
         else
            Put_Line (File_Handle, "    },");
         end if;
      end Put_Type_Block;

      File_Handle : Ada.Text_IO.File_Type;
   begin
      begin
         if Ada.Directories.Exists (Metadata_Dir) then
            Ada.Directories.Delete_Tree (Metadata_Dir);
         end if;
         Ada.Directories.Create_Path (Metadata_Dir);
      exception
         when E : others =>
            Put_Line
              ("FATAL: Could not prepare supplemental metadata directory " &
               Metadata_Dir &
               ": " &
               Ada.Exceptions.Exception_Message (E));
            return False;
      end;

      Ada.Text_IO.Create
        (File_Handle,
         Ada.Text_IO.Out_File,
         Metadata_File);

      Put_Line (File_Handle, "{");
      Put_Line (File_Handle, "  ""reflection"": [");
      for I in Event_Types'Range loop
         Put_Type_Block (File_Handle, Event_Types (I).all, I = Event_Types'Last);
      end loop;
      Put_Line (File_Handle, "  ],");
      Put_Line (File_Handle, "  ""jni"": [");
      for I in Event_Types'Range loop
         Put_Line (File_Handle, "    {");
         Put_Line (File_Handle, "      ""type"": """ & Event_Types (I).all & """,");
         Put_Line (File_Handle, "      ""jniAccessible"": true,");
         Put_Line (File_Handle, "      ""allDeclaredConstructors"": true,");
         Put_Line (File_Handle, "      ""allPublicConstructors"": true,");
         Put_Line (File_Handle, "      ""allDeclaredMethods"": true,");
         Put_Line (File_Handle, "      ""allPublicMethods"": true,");
         Put_Line (File_Handle, "      ""allDeclaredFields"": true,");
         Put_Line (File_Handle, "      ""allPublicFields"": true");
         if I = Event_Types'Last then
            Put_Line (File_Handle, "    }");
         else
            Put_Line (File_Handle, "    },");
         end if;
      end loop;
      Put_Line (File_Handle, "  ]");
      Put_Line (File_Handle, "}");
      Ada.Text_IO.Close (File_Handle);
      return True;
   exception
      when E : others =>
         begin
            if Ada.Text_IO.Is_Open (File_Handle) then
               Ada.Text_IO.Close (File_Handle);
            end if;
         exception
            when others =>
               null;
         end;

         Put_Line
           ("FATAL: Could not write supplemental Graal metadata: " &
            Ada.Exceptions.Exception_Message (E));
         return False;
   end Write_Supplemental_Metadata;

   function Run_Native_Image_Pass
     (Stage_Dir    : String;
      Program_Name : String) return Boolean is
      Metadata_Dirs : constant String :=
        Ada.Directories.Full_Name
          (Ada.Directories.Compose (Stage_Dir, "native-image-config-ready")) &
        "," &
        Ada.Directories.Full_Name
          (Ada.Directories.Compose (Stage_Dir, "native-image-manual"));
      function Quote_Cmd_Arg (Text : String) return String is
      begin
         return '"' & Text & '"';
      end Quote_Cmd_Arg;


      procedure Write_Command_File
        (Command_File : String;
         VCVars64_Bat : String) is
         Handle : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create
           (Handle,
            Ada.Text_IO.Out_File,
            Command_File);
         Ada.Text_IO.Put_Line (Handle, "@echo off");

         Ada.Text_IO.Put_Line (Handle, "set ""INCLUDE=""");
         Ada.Text_IO.Put_Line (Handle, "set ""LIB=""");
         Ada.Text_IO.Put_Line (Handle, "set ""LIBPATH=""");
         Ada.Text_IO.Put_Line (Handle, "set ""ALBJ_CL=cl.exe""");

         if VCVars64_Bat'Length > 0 then
            Ada.Text_IO.Put_Line
              (Handle,
               "call " & Quote_Cmd_Arg (VCVars64_Bat));
            Ada.Text_IO.Put_Line
              (Handle,
               "if errorlevel 1 exit /b %errorlevel%");
            Ada.Text_IO.Put_Line
              (Handle,
               "if defined VCToolsInstallDir set ""PATH=%VCToolsInstallDir%bin\Hostx64\x64;%PATH%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "if defined VCToolsInstallDir set ""ALBJ_CL=%VCToolsInstallDir%bin\Hostx64\x64\cl.exe""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""PATH=%PATH:C:\Program Files (x86)\Microsoft Visual Studio\VC98\bin;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""PATH=%PATH:C:\Program Files (x86)\Microsoft Visual Studio\Common\MSDev98\Bin;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""PATH=%PATH:C:\Program Files (x86)\Microsoft Visual Studio\Common\Tools\WinNT;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""PATH=%PATH:C:\Program Files (x86)\Microsoft Visual Studio\Common\Tools;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""INCLUDE=%INCLUDE:C:\Program Files (x86)\Microsoft Visual Studio\VC98\atl\include;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""INCLUDE=%INCLUDE:C:\Program Files (x86)\Microsoft Visual Studio\VC98\mfc\include;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""INCLUDE=%INCLUDE:C:\Program Files (x86)\Microsoft Visual Studio\VC98\include;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""LIB=%LIB:C:\Program Files (x86)\Microsoft Visual Studio\VC98\mfc\lib;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""LIB=%LIB:C:\Program Files (x86)\Microsoft Visual Studio\VC98\lib;=%""");
            Ada.Text_IO.Put_Line
              (Handle,
               "set ""CC=%ALBJ_CL%""");
         end if;

          Ada.Text_IO.Put_Line
            (Handle,
             "native-image --no-fallback -march=compatibility " &
             "-H:+UnlockExperimentalVMOptions " &
             "-H:-CheckToolchain " &
             Quote_Cmd_Arg ("-H:CCompilerPath=%ALBJ_CL%") & " " &
             "-H:ConfigurationFileDirectories=" &
             Quote_Cmd_Arg (Metadata_Dirs) &
             " ALB_Desktop -o " &
            Program_Name);
         Ada.Text_IO.Close (Handle);
      exception
         when others =>
            if Ada.Text_IO.Is_Open (Handle) then
               Ada.Text_IO.Close (Handle);
            end if;
            raise;
      end Write_Command_File;
   begin
      Put_Line ("ALBJ> Running native-image in " & Stage_Dir);

      if Ada.Environment_Variables.Exists ("ComSpec") then
         declare
            VCVars64_Bat : constant String := Alb_MSVC.Find_VCVars64_Bat;
            Command_File : constant String :=
              Ada.Directories.Compose
                (Stage_Dir,
                 "albj_native_image.cmd");
            Args : GNAT.OS_Lib.Argument_List (1 .. 2) :=
              (1 => new String'("/c"),
               2 => new String'("albj_native_image.cmd"));
            Success : Boolean := False;
         begin
            if VCVars64_Bat'Length > 0 then
               Put_Line ("ALBJ> Priming MSVC environment with " & VCVars64_Bat);
            else
               Put_Line ("ALBJ> MSVC Build Tools not found; install from " & Alb_MSVC.Official_Build_Tools_URL);
            end if;

            Write_Command_File (Command_File, VCVars64_Bat);
            Success :=
              Spawn_And_Check
                ("native-image",
                 Stage_Dir,
                 Ada.Environment_Variables.Value ("ComSpec"),
                 Args);
            Free_Argument_List (Args);
            return Success;
         end;
      else
         declare
             Args : GNAT.OS_Lib.Argument_List (1 .. 8) :=
               (1 => new String'("--no-fallback"),
                2 => new String'("-march=compatibility"),
                3 => new String'("-H:+UnlockExperimentalVMOptions"),
                4 => new String'("-H:-CheckToolchain"),
                5 => new String'("-H:ConfigurationFileDirectories=" & Metadata_Dirs),
                6 => new String'("ALB_Desktop"),
                7 => new String'("-o"),
                8 => new String'(Program_Name));
            Success : Boolean := False;
         begin
            Success :=
              Spawn_And_Check
                ("native-image",
                 Stage_Dir,
                 "native-image",
                 Args);
            Free_Argument_List (Args);
            return Success;
         end;
      end if;
   end Run_Native_Image_Pass;

   function Has_Suffix_CI
     (Text   : String;
      Suffix : String) return Boolean is
      Text_Lower   : constant String :=
        Ada.Characters.Handling.To_Lower (Text);
      Suffix_Lower : constant String :=
        Ada.Characters.Handling.To_Lower (Suffix);
   begin
      if Text_Lower'Length < Suffix_Lower'Length then
         return False;
      end if;

      return
        Text_Lower
          (Text_Lower'Last - Suffix_Lower'Length + 1 .. Text_Lower'Last) =
        Suffix_Lower;
   end Has_Suffix_CI;

   function Same_Text_CI
     (Left  : String;
      Right : String) return Boolean is
   begin
      return Ada.Characters.Handling.To_Lower (Left) =
             Ada.Characters.Handling.To_Lower (Right);
   end Same_Text_CI;

   function Is_Rescued_Artifact
     (Entry_Name   : String;
      Program_Name : String) return Boolean is
   begin
      return
        Has_Suffix_CI (Entry_Name, ".exe")
        or else Has_Suffix_CI (Entry_Name, ".dll")
        or else Same_Text_CI (Entry_Name, Program_Name);
   end Is_Rescued_Artifact;

   function Is_Primary_Executable
     (Entry_Name   : String;
      Program_Name : String) return Boolean is
   begin
      return
        Same_Text_CI (Entry_Name, Program_Name)
        or else Same_Text_CI (Entry_Name, Program_Name & ".exe");
   end Is_Primary_Executable;

   procedure Rescue_Native_Artifacts
     (Stage_Dir     : String;
      Output_Dir    : String;
      Program_Name  : String;
      Success       : out Boolean) is
      Rescue_Failed       : Boolean := False;
      Found_Executable    : Boolean := False;
      Rescued_File_Count  : Natural := 0;

      procedure Copy_Artifact
        (Source_Path : String;
         Entry_Name  : String) is
         Target_Path : constant String :=
           Ada.Directories.Compose (Output_Dir, Entry_Name);
      begin
         if Ada.Directories.Exists (Target_Path) then
            if Ada.Directories.Kind (Target_Path) =
               Ada.Directories.Ordinary_File
            then
               Ada.Directories.Delete_File (Target_Path);
            else
               Put_Line
                 ("FATAL: Output artifact path is not a file: " &
                  Target_Path);
               Rescue_Failed := True;
               return;
            end if;
         end if;

         Ada.Directories.Copy_File (Source_Path, Target_Path);
         Rescued_File_Count := Rescued_File_Count + 1;

         if Is_Primary_Executable (Entry_Name, Program_Name) then
            Found_Executable := True;
         end if;
      exception
         when E : others =>
            Put_Line
              ("FATAL: Could not rescue build artifact " &
               Source_Path &
               ": " &
               Ada.Exceptions.Exception_Message (E));
            Rescue_Failed := True;
      end Copy_Artifact;

      procedure Rescue_Directory (Directory_Path : String) is
         Search : Ada.Directories.Search_Type;
         Dir_Entry : Ada.Directories.Directory_Entry_Type;
         Filter : constant Ada.Directories.Filter_Type :=
           (Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False);
      begin
         Ada.Directories.Start_Search
           (Search,
            Directory => Directory_Path,
            Pattern   => "*",
            Filter    => Filter);

         while Ada.Directories.More_Entries (Search)
           and then not Rescue_Failed
         loop
            Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

            declare
               Entry_Name : constant String :=
                 Ada.Directories.Simple_Name (Dir_Entry);
               Entry_Kind : constant Ada.Directories.File_Kind :=
                 Ada.Directories.Kind (Dir_Entry);
               Entry_Path : constant String :=
                 Ada.Directories.Full_Name (Dir_Entry);
            begin
               if Entry_Name /= "." and then Entry_Name /= ".." then
                  if Entry_Kind = Ada.Directories.Directory then
                     Rescue_Directory (Entry_Path);
                  elsif Entry_Kind = Ada.Directories.Ordinary_File
                    and then Is_Rescued_Artifact (Entry_Name, Program_Name)
                  then
                     Copy_Artifact (Entry_Path, Entry_Name);
                  end if;
               end if;
            end;
         end loop;

         Ada.Directories.End_Search (Search);
      exception
         when E : others =>
            begin
               Ada.Directories.End_Search (Search);
            exception
               when others =>
                  null;
            end;

            Put_Line
              ("FATAL: Could not scan staging directory " &
               Directory_Path &
               ": " &
               Ada.Exceptions.Exception_Message (E));
            Rescue_Failed := True;
      end Rescue_Directory;
   begin
      Success := False;
      Rescue_Directory (Stage_Dir);

      if Rescue_Failed then
         return;
      end if;

      if not Found_Executable then
         Put_Line
           ("FATAL: Could not find the native executable " &
            Program_Name &
            " in the staging directory.");
         return;
      end if;

      Put_Line
        ("ALBJ> Rescued" &
         Natural'Image (Rescued_File_Count) &
         " build artifact(s) to " &
         Output_Dir);
      Success := True;
   exception
      when E : others =>
         Put_Line
           ("FATAL: Could not rescue native build artifacts: " &
            Ada.Exceptions.Exception_Message (E));
   end Rescue_Native_Artifacts;

   procedure Parse_Args is
      Skip_Next   : Boolean := False;
      Start_Index : Positive := 1;
   begin
      if Ada.Command_Line.Argument_Count >= 1 then
         if Ada.Command_Line.Argument (1) = "compile" then
            Build_Mode := True;
            Start_Index := 2;
         elsif Ada.Command_Line.Argument (1) = "run" then
            Run_Mode := True;
            Start_Index := 2;
         end if;
      end if;

      for I in Start_Index .. Ada.Command_Line.Argument_Count loop
         if Skip_Next then
            Skip_Next := False;
         else
            declare
               Arg : constant String := Ada.Command_Line.Argument (I);
            begin
               if Arg = "-o" then
                  if I < Ada.Command_Line.Argument_Count then
                     Store_Path
                       (Ada.Command_Line.Argument (I + 1),
                        Output_File,
                        Output_Flen,
                        "output");
                     Skip_Next := True;
                  else
                     Put_Line ("ALBJ: '-o' requires a filename.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--outdir" then
                  if I < Ada.Command_Line.Argument_Count then
                     Store_Path
                       (Ada.Command_Line.Argument (I + 1),
                        Out_Dir,
                        Out_Dir_Len,
                        "output directory");
                     Skip_Next := True;
                  else
                     Put_Line ("ALBJ: '--outdir' requires a directory.");
                     Arg_Error := True;
                  end if;
               elsif Arg = "--build" or else Arg = "-b" then
                  Build_Mode := True;
               elsif Arg = "--run" then
                  Run_Mode := True;
               elsif Arg = "--help" or else Arg = "-h" then
                  Print_Help;
                  Arg_Error := True;
               elsif ALB_System_Includes.Try_Parse_Gfx_Arg
                       (Arg,
                        (if I < Ada.Command_Line.Argument_Count
                         then Ada.Command_Line.Argument (I + 1)
                         else ""),
                        I < Ada.Command_Line.Argument_Count,
                        Skip_Next,
                        Arg_Error)
               then
                  if Arg_Error then
                     Put_Line
                       ("ALBJ: unknown or missing --gfx backend (use opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12).");
                  end if;
               elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
                  Put_Line ("ALBJ: unknown option " & Arg);
                  Arg_Error := True;
               else
                  if Input_Flen = 0 then
                     Store_Path (Arg, Input_File, Input_Flen, "input");
                  elsif Output_Flen = 0 then
                     Store_Path (Arg, Output_File, Output_Flen, "output");
                  else
                     Put_Line ("ALBJ: unexpected extra argument " & Arg);
                     Arg_Error := True;
                  end if;
               end if;
            end;
         end if;
      end loop;

      if Build_Mode and then Run_Mode then
         Put_Line ("ALBJ: '--build' and '--run' cannot be used together.");
         Arg_Error := True;
      end if;
   end Parse_Args;

   procedure Resolve_Output_Paths is
      Default_Name : constant String := Default_Output_Name;
   begin
      if Build_Mode or else Run_Mode then
         if Out_Dir_Len = 0 and then Output_Flen = 0 then
            Store_Path
              (Default_Out_Dir (Input_File (1 .. Input_Flen)),
               Out_Dir,
               Out_Dir_Len,
               "output directory");
         end if;

         if Out_Dir_Len > 0 then
            Store_Path
              (Out_Dir (1 .. Out_Dir_Len),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         elsif Output_Flen > 0
           and then Safe_Containing_Directory (Output_File (1 .. Output_Flen))'Length > 0
         then
            Store_Path
              (Safe_Containing_Directory (Output_File (1 .. Output_Flen)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         else
            Store_Path
              (Default_Out_Dir (Input_File (1 .. Input_Flen)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;

         if Output_Flen = 0 then
            Store_Path
              (Ada.Directories.Compose
                 (Final_Dir (1 .. Final_Dir_Len),
                  Default_Name),
               Output_File,
               Output_Flen,
               "output");
         elsif Ada.Directories.Simple_Name (Output_File (1 .. Output_Flen)) = Output_File (1 .. Output_Flen) then
            Store_Path
              (Ada.Directories.Compose
                 (Final_Dir (1 .. Final_Dir_Len),
                  Output_File (1 .. Output_Flen)),
               Output_File,
               Output_Flen,
               "output");
         else
            Store_Path
              (Safe_Containing_Directory (Output_File (1 .. Output_Flen)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;
      else
         if Output_Flen = 0 then
            if Out_Dir_Len > 0 then
               Store_Path
                 (Ada.Directories.Compose
                    (Out_Dir (1 .. Out_Dir_Len),
                     Default_Name),
                  Output_File,
                  Output_Flen,
                  "output");
               Store_Path
                 (Out_Dir (1 .. Out_Dir_Len),
                  Final_Dir,
                  Final_Dir_Len,
                  "output directory");
            else
               Store_Path (Default_Name, Output_File, Output_Flen, "output");
            end if;
         elsif Out_Dir_Len > 0
           and then not Is_Absolute_Path (Output_File (1 .. Output_Flen))
           and then Ada.Directories.Simple_Name (Output_File (1 .. Output_Flen)) = Output_File (1 .. Output_Flen)
         then
            Store_Path
              (Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Output_File (1 .. Output_Flen)),
               Output_File,
               Output_Flen,
               "output");
            Store_Path
              (Out_Dir (1 .. Out_Dir_Len),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;

         if Final_Dir_Len = 0
           and then Output_Flen > 0
           and then Safe_Containing_Directory (Output_File (1 .. Output_Flen))'Length > 0
         then
            Store_Path
              (Safe_Containing_Directory (Output_File (1 .. Output_Flen)),
               Final_Dir,
               Final_Dir_Len,
               "output directory");
         end if;
      end if;

      if Output_Flen > 0
        and then Ada.Directories.Simple_Name (Output_File (1 .. Output_Flen)) /= "ALB_Core.java"
      then
         Put_Line
           ("ALBJ: output file must be named ALB_Core.java for the current desktop shell.");
         Arg_Error := True;
      end if;
   exception
      when others =>
         Put_Line ("ALBJ: failed to resolve output paths.");
         Arg_Error := True;
   end Resolve_Output_Paths;

   procedure Run_Java_Emission
     (Input_Path  : String;
      Output_Path : String;
      Success     : out Boolean) is
   begin
      Success := False;

      if Input_Path'Length > Input_File'Length then
         Put_Line ("FATAL: Input path too long for static vault.");
         return;
      end if;

      if Output_Path'Length > Output_File'Length then
         Put_Line ("FATAL: Output path too long for static vault.");
         return;
      end if;

      Input_File := (others => ' ');
      Output_File := (others => ' ');
      Input_Flen := Input_Path'Length;
      Output_Flen := Output_Path'Length;
      Input_File (1 .. Input_Flen) := Input_Path;
      Output_File (1 .. Output_Flen) := Output_Path;
      Include_Count := 0;
      Abs_Line_Count := 1;
      Java_Symbol_Count := 0;
      Type_Alias_Count := 0;
      Const_Count := 0;
      Parallel_Field_Count := 0;
      Struct_Field_Count := 0;
      Struct_Type_Count := 0;
      Emitted_Routine_Count := 0;
      Knows_Change_Hook_Count := 0;
      Temporal_Symbol_Count := 0;
      VAS_Global_Next := VAS_Global_Base;
      VAS_Temporal_Next := 0;
      VAS_Config_Emitted := False;
      Clear_Local_Symbols;
      Clear_Frame_Plan;

      memory_allocator.Alloc_Static_Pool (1_048_576, Mem_Success);
      if not Mem_Success then
         Put_Line ("FATAL: Static compiler pool could not be initialized.");
         return;
      end if;

      Configure_Target_Profile (Backend_Java, Profile_FlatJVM, Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Could not configure FlatJVM profile.");
         return;
      end if;

      Init_HAL (Backend_Java, Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Java emitter could not be initialized.");
         return;
      end if;

      Input_Len := 0;
      Process_File_Weave (Input_File (1 .. Input_Flen), Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Source weave failed.");
         return;
      end if;

      Tokenizer.Tokenize
        (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, Lex_Diag);
      if not Lex_Diag.Success then
         declare
            M_Rec : constant Source_Map_Record :=
              Source_Map (Lex_Diag.Error_Line);
            FName : constant String :=
              Include_Vault (M_Rec.File_ID) (1 .. Include_Lens (M_Rec.File_ID));
         begin
            ALB_Oracle.Render_Consultation
              (Input_Buffer (1 .. Input_Len),
               Lex_Diag.Error_Line,
               M_Rec.Rel_Line,
               Lex_Diag.Error_Col,
               FName,
               Lex_Diag.Code);
         end;
         return;
      end if;

      Parser.Parse
        (Tokens, Token_Count, Tree, Root, Parse_Success, Parse_Diag);
      if not Parse_Success or else Parse_Diag.Error_Count > 0 then
         Render_Parse_Diagnostics;
         return;
      end if;

      Run_Comptime_Blocks (Root, Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: COMPTIME block execution failed.");
         return;
      end if;

      Emit_Native_Java.Emit_Program_Start ("ALB_Core", Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Java program prelude emission failed.");
         return;
      end if;

      Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Global);
      Emit_Comment
        ("HAL profile=FlatJVM registers=" &
         Trim_Image (Positive'Image (Active_Environment.Register_Bits)) &
         " ptr=" &
         Trim_Image (Positive'Image (Active_Environment.Pointer_Bits)) &
         " char=" &
         Trim_Image (Positive'Image (Active_Environment.Char_Bits)),
         Emit_Success);

      Emit_Native_Java.Set_Active_Buffer (Emit_Native_Java.Buffer_Boot);
      declare
         Top_Node : Node_Index := Root;
      begin
         while Top_Node /= 0 and then Emit_Success loop
            Emit_Node (Top_Node, 1, Emit_Success);
            Top_Node := Tree (Top_Node).Next_Sibling;
         end loop;
      end;
      if not Emit_Success then
         Put_Line ("FATAL: Java AST emission failed.");
         return;
      end if;

      Emit_Knows_Change_Dispatcher (Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Java KNOWS_CHANGE dispatcher emission failed.");
         return;
      end if;

      Emit_VAS_Config (Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Java VAS configuration emission failed.");
         return;
      end if;

      Emit_User_Save_State_Support (Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Java save-state support emission failed.");
         return;
      end if;

      Emit_Native_Java.Emit_Program_End (Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Java program finalization failed.");
         return;
      end if;

      Emit_Native_Java.Flush_To_File
        (Output_File (1 .. Output_Flen), Emit_Success);
      if not Emit_Success then
         Put_Line ("FATAL: Could not flush Java source file.");
         return;
      end if;

      Put_Line ("ALBJ> Wrote FlatJVM scaffold to " & Output_Path);
      Success := True;
   end Run_Java_Emission;

   procedure Prepare_Java_Stage
     (Input_Path      : String;
      Stage_Directory : String;
      Stage_Core_Java : String;
      Success         : out Boolean) is
      Shell_Source : constant String := Find_Desktop_Shell_Source;
      Stage_Desktop_Java : constant String :=
        Ada.Directories.Compose (Stage_Directory, "ALB_Desktop", "java");
   begin
      Success := False;

      Ensure_Fresh_Stage_Directory (Stage_Directory, Success);
      if not Success then
         return;
      end if;

      if Shell_Source'Length = 0 then
         Put_Line
           ("FATAL: Could not locate ALB_Desktop.java in the current or installed tool directory.");
         Success := False;
         return;
      end if;

      begin
         Ada.Directories.Copy_File (Shell_Source, Stage_Desktop_Java);
      exception
         when E : others =>
            Put_Line
              ("FATAL: Could not stage ALB_Desktop.java: " &
               Ada.Exceptions.Exception_Message (E));
            Success := False;
            return;
      end;

      Run_Java_Emission (Input_Path, Stage_Core_Java, Success);
   end Prepare_Java_Stage;

   procedure Run_Compile_Pipeline
     (Input_Path  : String;
      Output_Dir  : String) is
      Stage_Directory : constant String :=
        Ada.Directories.Compose (Output_Dir, "_stage");
      Stage_Core_Java : constant String :=
        Ada.Directories.Compose (Stage_Directory, "ALB_Core", "java");
      Final_Core_Java : constant String :=
        Ada.Directories.Compose (Output_Dir, "ALB_Core", "java");
      Final_Desktop_Java : constant String :=
        Ada.Directories.Compose (Output_Dir, "ALB_Desktop", "java");
      Program_Name : constant String :=
        Strip_Extension (Ada.Directories.Simple_Name (Input_Path));
      Step_Success : Boolean := False;
      Build_Success : Boolean := True;
   begin
      begin
         Ada.Directories.Create_Path (Output_Dir);
      exception
         when E : others =>
            Put_Line
              ("FATAL: Could not create output directory " &
               Output_Dir &
               ": " &
               Ada.Exceptions.Exception_Message (E));
            return;
      end;

      if Build_Success then
         Prepare_Java_Stage
           (Input_Path,
            Stage_Directory,
            Stage_Core_Java,
            Step_Success);
         Build_Success := Step_Success;
      end if;

      if Build_Success then
         Copy_File_Overwrite (Stage_Core_Java, Final_Core_Java, Step_Success);
         Build_Success := Step_Success;
      end if;

      if Build_Success then
         Copy_File_Overwrite
           (Ada.Directories.Compose (Stage_Directory, "ALB_Desktop", "java"),
            Final_Desktop_Java,
            Step_Success);
         Build_Success := Step_Success;
      end if;

      if Build_Success then
         Build_Success := Run_Javac_Pass (Stage_Directory);
      end if;

      if Build_Success then
         Build_Success := Run_Metadata_Agent_Pass (Stage_Directory);
      end if;

      if Build_Success then
         Build_Success := Write_Supplemental_Metadata (Stage_Directory);
      end if;

      if Build_Success then
         Build_Success :=
           Run_Native_Image_Pass (Stage_Directory, Program_Name);
      end if;

      if Build_Success then
         Rescue_Native_Artifacts
           (Stage_Directory,
            Output_Dir,
            Program_Name,
            Step_Success);
         Build_Success := Step_Success;
      end if;

      if Build_Success then
         Safe_Delete_Tree (Stage_Directory);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      else
         Put_Line
           ("WARN: Preserving staging directory for inspection: " &
             Stage_Directory);
      end if;
   exception
      when E : others =>
         Put_Line
           ("FATAL: Build pipeline aborted: " &
            Ada.Exceptions.Exception_Message (E));
         Put_Line
            ("WARN: Preserving staging directory for inspection: " &
             Stage_Directory);
   end Run_Compile_Pipeline;

   procedure Run_Dev_Pipeline
     (Input_Path  : String;
      Output_Dir  : String) is
      Stage_Directory : constant String :=
        Ada.Directories.Compose (Output_Dir, "_run_stage");
      Stage_Core_Java : constant String :=
        Ada.Directories.Compose (Stage_Directory, "ALB_Core", "java");
      Step_Success : Boolean := False;
      Build_Success : Boolean := True;
   begin
      begin
         Ada.Directories.Create_Path (Output_Dir);
      exception
         when E : others =>
            Put_Line
              ("FATAL: Could not create output directory " &
               Output_Dir &
               ": " &
               Ada.Exceptions.Exception_Message (E));
            return;
      end;

      if Build_Success then
         Prepare_Java_Stage
           (Input_Path,
            Stage_Directory,
            Stage_Core_Java,
            Step_Success);
         Build_Success := Step_Success;
      end if;

      if Build_Success then
         Build_Success := Run_Javac_Pass (Stage_Directory);
      end if;

      if Build_Success then
         Build_Success := Run_Java_Desktop_Pass (Stage_Directory);
      end if;

      Safe_Delete_Tree (Stage_Directory);
      if Build_Success then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      end if;
   exception
      when E : others =>
         Put_Line
           ("FATAL: Dev run aborted: " &
            Ada.Exceptions.Exception_Message (E));
         Safe_Delete_Tree (Stage_Directory);
   end Run_Dev_Pipeline;

begin
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);

   if Ada.Command_Line.Argument_Count < 1 then
      Print_Help;
      return;
   end if;

   Parse_Args;
   if Arg_Error then
      return;
   end if;

   if Input_Flen = 0 then
      Put_Line ("ALBJ: no input file specified.");
      Print_Help;
      return;
   end if;

   Resolve_Output_Paths;
   if Arg_Error or else Output_Flen = 0 then
      return;
   end if;

   if Run_Mode then
      declare
         Input_Path_Copy : constant String := Input_File (1 .. Input_Flen);
         Output_Dir_Copy : constant String :=
           (if Final_Dir_Len > 0
            then Final_Dir (1 .. Final_Dir_Len)
            else Ada.Directories.Current_Directory);
      begin
         Run_Dev_Pipeline (Input_Path_Copy, Output_Dir_Copy);
      end;
   elsif Build_Mode then
      declare
         Input_Path_Copy : constant String := Input_File (1 .. Input_Flen);
         Output_Dir_Copy : constant String :=
           (if Final_Dir_Len > 0
            then Final_Dir (1 .. Final_Dir_Len)
            else Ada.Directories.Current_Directory);
      begin
         Run_Compile_Pipeline (Input_Path_Copy, Output_Dir_Copy);
      end;
   else
      declare
         Input_Path_Copy  : constant String := Input_File (1 .. Input_Flen);
         Output_Path_Copy : constant String := Output_File (1 .. Output_Flen);
         Success : Boolean := False;
      begin
         if Final_Dir_Len > 0 then
            Ada.Directories.Create_Path (Final_Dir (1 .. Final_Dir_Len));
         end if;

         Run_Java_Emission
           (Input_Path_Copy,
            Output_Path_Copy,
            Success);

         if Success then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
         end if;
      exception
         when E : others =>
            Put_Line
              ("FATAL: Could not write Java output: " &
               Ada.Exceptions.Exception_Message (E));
      end;
   end if;
end ALBJ;
