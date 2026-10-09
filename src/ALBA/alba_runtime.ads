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

with Interfaces;
with Numerus_Magnus; use Numerus_Magnus;
with Pure_Types;     use Pure_Types;

package ALBA_Runtime is

   subtype ALB_U8  is Interfaces.Unsigned_8;
   subtype ALB_U16 is Interfaces.Unsigned_16;
   subtype ALB_U32 is Interfaces.Unsigned_32;
   subtype ALB_U64 is Interfaces.Unsigned_64;

   subtype ALB_I8  is Interfaces.Integer_8;
   subtype ALB_I16 is Interfaces.Integer_16;
   subtype ALB_I32 is Interfaces.Integer_32;
   subtype ALB_I64 is Interfaces.Integer_64;

   type ALB_U8_Array is array (Positive range <>) of ALB_U8
     with Component_Size => 8;
   type ALB_U16_Array is array (Positive range <>) of ALB_U16;
   type ALB_U32_Array is array (Positive range <>) of ALB_U32;
   type ALB_U64_Array is array (Positive range <>) of ALB_U64;
   type ALB_I8_Array is array (Positive range <>) of ALB_I8
     with Component_Size => 8;
   type ALB_I16_Array is array (Positive range <>) of ALB_I16;
   type ALB_I32_Array is array (Positive range <>) of ALB_I32;
   type ALB_I64_Array is array (Positive range <>) of ALB_I64;

   VAS_Size : constant Positive := 262_144;

   ALB_Null_Addr        : constant Natural := 0;
   ALB_VAS_Global_Base  : constant Positive := 1;
   ALB_VAS_Temp_Base    : constant Positive := 65_537;
   ALB_VAS_Frame_Base   : constant Positive := 196_609;
   ALB_VAS_Global_Limit : constant Positive := ALB_VAS_Temp_Base - 1;
   ALB_VAS_Temp_Limit   : constant Positive := ALB_VAS_Frame_Base - 1;
   ALB_VAS_Frame_Limit  : constant Positive := VAS_Size;

   type VAS_Array is array (1 .. VAS_Size) of ALB_U8
     with Component_Size => 8;

   ALB_VAS : VAS_Array := (others => 0);

   ALB_Frame_SP : Natural := ALB_VAS_Frame_Base;

   Max_Text_Length : constant Positive := 1024;
   subtype ALB_Text_Size is Natural range 0 .. Max_Text_Length;
   type ALB_Text_Buffer is array (1 .. Max_Text_Length) of Character;
   type ALB_Text is record
      Length : ALB_Text_Size := 0;
      Data   : ALB_Text_Buffer := (others => ' ');
   end record;

   function ALB_STR (Text : String) return ALB_Text;
   function ALB_CAT (Left, Right : ALB_Text) return ALB_Text;
   function ALB_CAT (Left : ALB_Text; Right : S32) return ALB_Text;
   function ALB_CAT (Left : S32; Right : ALB_Text) return ALB_Text;
   function ALB_CAT (Left : ALB_Text; Right : Integer) return ALB_Text;
   function ALB_CAT (Left : Integer; Right : ALB_Text) return ALB_Text;
   function ALB_CAT (Left : ALB_Text; Right : U64) return ALB_Text;
   function ALB_CAT (Left : U64; Right : ALB_Text) return ALB_Text;
   function ALB_CAT (Left : ALB_Text; Right : Boolean) return ALB_Text;
   function ALB_CAT (Left : Boolean; Right : ALB_Text) return ALB_Text;
   function ALB_CAT (Left : ALB_Text; Right : Pure_Rational) return ALB_Text;
   function ALB_CAT (Left : Pure_Rational; Right : ALB_Text) return ALB_Text;
   function ALB_TO_STRING (Text : ALB_Text) return String;
   function ALB_TEXT_LENGTH (Text : ALB_Text) return U32;
   function ALB_IMAGE (Value : U64) return ALB_Text;
   function ALB_IMAGE (Value : S32) return ALB_Text;
   function ALB_IMAGE (Value : Integer) return ALB_Text;
   function ALB_IMAGE (Value : Boolean) return ALB_Text;
   function ALB_IMAGE (Value : Pure_Rational) return ALB_Text;
   function ALB_LEFT
     (Text  : ALB_Text;
      Count : U32) return ALB_Text;
   function ALB_RIGHT
     (Text  : ALB_Text;
      Count : U32) return ALB_Text;
   function ALB_MID
     (Text   : ALB_Text;
      Start  : U32;
      Count  : U32) return ALB_Text;
   function ALB_CONCAT
     (Left  : ALB_Text;
      Right : ALB_Text) return ALB_Text;

   function ALB_PURE (Num, Den : Long_Integer) return Pure_Rational;
   function ALB_PURE (Num, Den : Integer) return Pure_Rational;
   function ALB_PURE_ADD (A, B : Pure_Rational) return Pure_Rational;
   function ALB_PURE_SUB (A, B : Pure_Rational) return Pure_Rational;
   function ALB_PURE_MUL (A, B : Pure_Rational) return Pure_Rational;
   function ALB_PURE_DIV (A, B : Pure_Rational) return Pure_Rational;
   function ALB_PURE_NUM (A : Pure_Rational) return S32;
   function ALB_PURE_DEN (A : Pure_Rational) return S32;
   function "<" (Left, Right : Pure_Rational) return Boolean;
   function ">" (Left, Right : Pure_Rational) return Boolean;
   function "<=" (Left, Right : Pure_Rational) return Boolean;
   function ">=" (Left, Right : Pure_Rational) return Boolean;
   function ALB_RND (Max_Value : U64) return U64;
   function ALB_CHOOSE
     (Flag        : U64;
      Left_Value  : U64;
      Right_Value : U64) return U64;
   function ALB_COLLIDE_RECT
     (AX : S32;
      AY : S32;
      AW : S32;
      AH : S32;
      BX : S32;
      BY : S32;
      BW : S32;
      BH : S32) return Boolean;
   function ALB_SIN (Degrees : S32) return S32;
   function ALB_COS (Degrees : S32) return S32;
   function ALB_SQRT (Value : S32) return S32;
   function ALB_EXP (Value : S32) return S32;
   function ALB_ROL
     (Value : U64;
      Bits  : U32;
      Width : U32) return U64;
   function ALB_ROR
     (Value : U64;
      Bits  : U32;
      Width : U32) return U64;
   function ALB_BOOL_TO_U64 (Value : Boolean) return U64;
   function ALB_S8_TO_U64 (Value : S8) return U64;
   function ALB_S16_TO_U64 (Value : S16) return U64;
   function ALB_S32_TO_U64 (Value : S32) return U64;
   function ALB_S64_TO_U64 (Value : S64) return U64;
   function ALB_ABS_S32_TO_U64 (Value : S32) return U64;
   function ALB_U64_TO_U8 (Value : U64) return U8;
   function ALB_U64_TO_U16 (Value : U64) return U16;
   function ALB_U64_TO_U32 (Value : U64) return U32;
   function ALB_U64_TO_S8 (Value : U64) return S8;
   function ALB_U64_TO_S16 (Value : U64) return S16;
   function ALB_U64_TO_S32 (Value : U64) return S32;
   function ALB_U64_TO_S64 (Value : U64) return S64;

   function Is_Valid_Range
     (Index : Natural;
      Size  : Positive) return Boolean
   is
     (Index >= 1
      and then Size <= VAS_Size
      and then Index <= VAS_Size - Size + 1);

   function Is_Valid_Range_Or_Empty
     (Index : Natural;
      Size  : Natural) return Boolean
   is
     (if Size = 0
      then Index >= 1 and then Index <= VAS_Size
      else Is_Valid_Range (Index, Positive (Size)));

   function ALB_LOAD_BOOL (Index : Positive) return Boolean
   with Pre => Is_Valid_Range (Index, 1);
   procedure ALB_STORE_BOOL
     (Index : Positive;
      Value : Boolean)
   with Pre => Is_Valid_Range (Index, 1);
   function ALB_LOAD_TEXT (Index : Positive) return ALB_Text
   with Pre => Is_Valid_Range (Index, 4 + Max_Text_Length);
   procedure ALB_STORE_TEXT
     (Index : Positive;
      Value : ALB_Text)
   with Pre => Is_Valid_Range (Index, 4 + Max_Text_Length);
   function ALB_LOAD_PURE (Index : Positive) return Pure_Rational
   with Pre => Is_Valid_Range (Index, 16);
   procedure ALB_STORE_PURE
     (Index : Positive;
      Value : Pure_Rational)
   with Pre => Is_Valid_Range (Index, 16);
   function ALB_LOAD_F32 (Index : Positive) return F32
   with Pre => Is_Valid_Range (Index, 4);
   procedure ALB_STORE_F32
     (Index : Positive;
      Value : F32)
   with Pre => Is_Valid_Range (Index, 4);
   function ALB_LOAD_F64 (Index : Positive) return F64
   with Pre => Is_Valid_Range (Index, 8);
   procedure ALB_STORE_F64
     (Index : Positive;
      Value : F64)
   with Pre => Is_Valid_Range (Index, 8);

   function ALB_LOAD_U8
     (Index : Positive) return ALB_U8
   with Pre => Is_Valid_Range (Index, 1);

   function ALB_LOAD_U16
     (Index : Positive) return ALB_U16
   with Pre => Is_Valid_Range (Index, 2);

   function ALB_LOAD_U32
     (Index : Positive) return ALB_U32
   with Pre => Is_Valid_Range (Index, 4);

   function ALB_LOAD_U64
     (Index : Positive) return U64
   with Pre => Is_Valid_Range (Index, 8);

   function ALB_LOAD_I8
     (Index : Positive) return ALB_I8
   with Pre => Is_Valid_Range (Index, 1);

   function ALB_LOAD_I16
     (Index : Positive) return ALB_I16
   with Pre => Is_Valid_Range (Index, 2);

   function ALB_LOAD_I32
     (Index : Positive) return ALB_I32
   with Pre => Is_Valid_Range (Index, 4);

   function ALB_LOAD_I64
     (Index : Positive) return ALB_I64
   with Pre => Is_Valid_Range (Index, 8);

   procedure ALB_STORE_U8
     (Index : Positive;
      Value : ALB_U8)
   with Pre => Is_Valid_Range (Index, 1);

   procedure ALB_STORE_U16
     (Index : Positive;
      Value : ALB_U16)
   with Pre => Is_Valid_Range (Index, 2);

   procedure ALB_STORE_U32
     (Index : Positive;
      Value : ALB_U32)
   with Pre => Is_Valid_Range (Index, 4);

   procedure ALB_STORE_U64
     (Index : Positive;
      Value : U64)
   with Pre => Is_Valid_Range (Index, 8);

   procedure ALB_STORE_I8
     (Index : Positive;
      Value : ALB_I8)
   with Pre => Is_Valid_Range (Index, 1);

   procedure ALB_STORE_I16
     (Index : Positive;
      Value : ALB_I16)
   with Pre => Is_Valid_Range (Index, 2);

   procedure ALB_STORE_I32
     (Index : Positive;
      Value : ALB_I32)
   with Pre => Is_Valid_Range (Index, 4);

   procedure ALB_STORE_I64
     (Index : Positive;
      Value : ALB_I64)
   with Pre => Is_Valid_Range (Index, 8);

   procedure ALB_MEM_ZERO
     (Index : Positive;
      Size  : Natural)
   with Pre => Is_Valid_Range_Or_Empty (Index, Size);

   procedure ALB_MEM_COPY
     (Destination : Positive;
      Source      : Positive;
      Size        : Natural)
   with
     Pre =>
       Is_Valid_Range_Or_Empty (Destination, Size)
       and then Is_Valid_Range_Or_Empty (Source, Size);

   procedure ALB_VAS_COPY
     (Destination : Positive;
      Source      : Positive;
      Size        : Natural)
   with
     Pre =>
       Is_Valid_Range_Or_Empty (Destination, Size)
       and then Is_Valid_Range_Or_Empty (Source, Size);

   function ALB_PEEK
     (Address : Positive) return U64
   with Pre => Is_Valid_Range (Address, 8);

   function ALB_DEREF
     (Address : Positive) return U64
   with Pre => Is_Valid_Range (Address, 8);

   procedure ALB_POKE
     (Address : Positive;
      Value   : U64)
   with Pre => Is_Valid_Range (Address, 8);

end ALBA_Runtime;
