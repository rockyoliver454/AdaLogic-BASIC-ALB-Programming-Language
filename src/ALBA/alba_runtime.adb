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

pragma SPARK_Mode (Off);

with Ada.Numerics.Long_Elementary_Functions;
with Ada.Unchecked_Conversion;
with Interfaces;
with Pure_Types; use Pure_Types;

package body ALBA_Runtime is

   use Ada.Numerics.Long_Elementary_Functions;
   use type ALB_U8;
   use type ALB_U16;
   use type ALB_U32;
   use type ALB_U64;
   use type ALB_I16;
   use type ALB_I32;
   use type ALB_I64;
   use type U64;

   function F32_To_U32_Bits is new Ada.Unchecked_Conversion (F32, ALB_U32);
   function U32_Bits_To_F32 is new Ada.Unchecked_Conversion (ALB_U32, F32);
   function F64_To_U64_Bits is new Ada.Unchecked_Conversion (F64, ALB_U64);
   function U64_Bits_To_F64 is new Ada.Unchecked_Conversion (ALB_U64, F64);

   ALB_RNG_State : U64 := 16#4A39_B70D_EE62_F1A5#;

   function Trim_Image (S : String) return String is
      First : Positive := S'First;
   begin
      while First < S'Last and then S (First) = ' ' loop
         First := First + 1;
      end loop;
      return S (First .. S'Last);
   end Trim_Image;

   function ALB_STR (Text : String) return ALB_Text is
      Result : ALB_Text;
      Limit  : Natural := Text'Length;
   begin
      if Limit > Max_Text_Length then
         Limit := Max_Text_Length;
      end if;

      Result.Length := Limit;
      for I in 1 .. Limit loop
         Result.Data (I) := Text (Text'First + I - 1);
      end loop;
      return Result;
   end ALB_STR;

   function ALB_CAT (Left, Right : ALB_Text) return ALB_Text is
      Result : ALB_Text;
      Pos    : Natural := 0;
   begin
      for I in 1 .. Left.Length loop
         exit when Pos >= Max_Text_Length;
         Pos := Pos + 1;
         Result.Data (Pos) := Left.Data (I);
      end loop;

      for I in 1 .. Right.Length loop
         exit when Pos >= Max_Text_Length;
         Pos := Pos + 1;
         Result.Data (Pos) := Right.Data (I);
      end loop;

      Result.Length := Pos;
      return Result;
   end ALB_CAT;

   function ALB_CAT (Left : ALB_Text; Right : S32) return ALB_Text is
   begin
      return ALB_CAT (Left, ALB_IMAGE (Right));
   end ALB_CAT;

   function ALB_CAT (Left : S32; Right : ALB_Text) return ALB_Text is
   begin
      return ALB_CAT (ALB_IMAGE (Left), Right);
   end ALB_CAT;

   function ALB_CAT (Left : ALB_Text; Right : Integer) return ALB_Text is
   begin
      return ALB_CAT (Left, ALB_IMAGE (Right));
   end ALB_CAT;

   function ALB_CAT (Left : Integer; Right : ALB_Text) return ALB_Text is
   begin
      return ALB_CAT (ALB_IMAGE (Left), Right);
   end ALB_CAT;

   function ALB_CAT (Left : ALB_Text; Right : U64) return ALB_Text is
   begin
      return ALB_CAT (Left, ALB_IMAGE (Right));
   end ALB_CAT;

   function ALB_CAT (Left : U64; Right : ALB_Text) return ALB_Text is
   begin
      return ALB_CAT (ALB_IMAGE (Left), Right);
   end ALB_CAT;

   function ALB_CAT (Left : ALB_Text; Right : Boolean) return ALB_Text is
   begin
      return ALB_CAT (Left, ALB_IMAGE (Right));
   end ALB_CAT;

   function ALB_CAT (Left : Boolean; Right : ALB_Text) return ALB_Text is
   begin
      return ALB_CAT (ALB_IMAGE (Left), Right);
   end ALB_CAT;

   function ALB_CAT (Left : ALB_Text; Right : Pure_Rational) return ALB_Text is
   begin
      return ALB_CAT (Left, ALB_IMAGE (Right));
   end ALB_CAT;

   function ALB_CAT (Left : Pure_Rational; Right : ALB_Text) return ALB_Text is
   begin
      return ALB_CAT (ALB_IMAGE (Left), Right);
   end ALB_CAT;

   function ALB_TO_STRING (Text : ALB_Text) return String is
      Result : String (1 .. Text.Length);
   begin
      if Text.Length = 0 then
         return "";
      end if;
      for I in Result'Range loop
         Result (I) := Text.Data (I);
      end loop;
      return Result;
   end ALB_TO_STRING;

   function ALB_TEXT_LENGTH (Text : ALB_Text) return U32 is
   begin
      return U32 (Text.Length);
   end ALB_TEXT_LENGTH;

   function ALB_IMAGE (Value : U64) return ALB_Text is
   begin
      return ALB_STR (Trim_Image (U64'Image (Value)));
   end ALB_IMAGE;

   function ALB_IMAGE (Value : S32) return ALB_Text is
   begin
      return ALB_STR (Trim_Image (S32'Image (Value)));
   end ALB_IMAGE;

   function ALB_IMAGE (Value : Integer) return ALB_Text is
   begin
      return ALB_STR (Trim_Image (Integer'Image (Value)));
   end ALB_IMAGE;

   function ALB_IMAGE (Value : Boolean) return ALB_Text is
   begin
      if Value then
         return ALB_STR ("TRUE");
      end if;
      return ALB_STR ("FALSE");
   end ALB_IMAGE;

   function ALB_IMAGE (Value : Pure_Rational) return ALB_Text is
   begin
      return ALB_CAT
        (ALB_CAT (ALB_IMAGE (ALB_PURE_NUM (Value)), ALB_STR ("/")),
         ALB_IMAGE (U64 (Value.Den)));
   end ALB_IMAGE;

   function ALB_LEFT
     (Text  : ALB_Text;
      Count : U32) return ALB_Text
   is
      Result : ALB_Text;
      Limit  : Natural := Natural'Min (Natural (Count), Text.Length);
   begin
      Result.Length := Limit;
      for I in 1 .. Limit loop
         Result.Data (I) := Text.Data (I);
      end loop;
      return Result;
   end ALB_LEFT;

   function ALB_RIGHT
     (Text  : ALB_Text;
      Count : U32) return ALB_Text
   is
      Result : ALB_Text;
      Limit  : Natural := Natural'Min (Natural (Count), Text.Length);
      Start  : Natural := 1;
   begin
      if Limit = 0 then
         return ALB_STR ("");
      end if;

      Start := Text.Length - Limit + 1;
      Result.Length := Limit;
      for I in 1 .. Limit loop
         Result.Data (I) := Text.Data (Start + I - 1);
      end loop;
      return Result;
   end ALB_RIGHT;

   function ALB_MID
     (Text   : ALB_Text;
      Start  : U32;
      Count  : U32) return ALB_Text
   is
      Result      : ALB_Text;
      First_Index : Natural := Natural'Max (1, Natural (Start));
      Limit       : Natural := 0;
   begin
      if First_Index > Text.Length then
         return ALB_STR ("");
      end if;

      Limit := Natural'Min (Natural (Count), Text.Length - First_Index + 1);
      Result.Length := Limit;
      for I in 1 .. Limit loop
         Result.Data (I) := Text.Data (First_Index + I - 1);
      end loop;
      return Result;
   end ALB_MID;

   function ALB_CONCAT
     (Left  : ALB_Text;
      Right : ALB_Text) return ALB_Text is
   begin
      return ALB_CAT (Left, Right);
   end ALB_CONCAT;

   function ALB_PURE (Num, Den : Long_Integer) return Pure_Rational is
      Result  : Pure_Rational := (Num => 0, Den => 1);
      Success : Boolean := False;
   begin
      Create_Pure (Num, Den, Result, Success);
      if Success then
         return Result;
      end if;
      return (Num => 0, Den => 1);
   end ALB_PURE;

   function ALB_PURE (Num, Den : Integer) return Pure_Rational is
   begin
      return ALB_PURE (Long_Integer (Num), Long_Integer (Den));
   end ALB_PURE;

   function ALB_PURE_ADD (A, B : Pure_Rational) return Pure_Rational is
      Result  : Pure_Rational := (Num => 0, Den => 1);
      Success : Boolean := False;
   begin
      Add_Pure (A, B, Result, Success);
      if Success then
         return Result;
      end if;
      return (Num => 0, Den => 1);
   end ALB_PURE_ADD;

   function ALB_PURE_SUB (A, B : Pure_Rational) return Pure_Rational is
      Result  : Pure_Rational := (Num => 0, Den => 1);
      Success : Boolean := False;
   begin
      Sub_Pure (A, B, Result, Success);
      if Success then
         return Result;
      end if;
      return (Num => 0, Den => 1);
   end ALB_PURE_SUB;

   function ALB_PURE_MUL (A, B : Pure_Rational) return Pure_Rational is
      Result  : Pure_Rational := (Num => 0, Den => 1);
      Success : Boolean := False;
   begin
      Mul_Pure (A, B, Result, Success);
      if Success then
         return Result;
      end if;
      return (Num => 0, Den => 1);
   end ALB_PURE_MUL;

   function ALB_PURE_DIV (A, B : Pure_Rational) return Pure_Rational is
      Result  : Pure_Rational := (Num => 0, Den => 1);
      Success : Boolean := False;
   begin
      Div_Pure (A, B, Result, Success);
      if Success then
         return Result;
      end if;
      return (Num => 0, Den => 1);
   end ALB_PURE_DIV;

   function ALB_PURE_NUM (A : Pure_Rational) return S32 is
   begin
      return S32 (A.Num);
   end ALB_PURE_NUM;

   function ALB_PURE_DEN (A : Pure_Rational) return S32 is
   begin
      return S32 (A.Den);
   end ALB_PURE_DEN;

   function "<" (Left, Right : Pure_Rational) return Boolean is
   begin
      return (Left.Num * Right.Den) < (Right.Num * Left.Den);
   end "<";

   function ">" (Left, Right : Pure_Rational) return Boolean is
   begin
      return (Left.Num * Right.Den) > (Right.Num * Left.Den);
   end ">";

   function "<=" (Left, Right : Pure_Rational) return Boolean is
   begin
      return not (Left > Right);
   end "<=";

   function ">=" (Left, Right : Pure_Rational) return Boolean is
   begin
      return not (Left < Right);
   end ">=";

   function ALB_RND (Max_Value : U64) return U64 is
      Value : U64 := 0;
   begin
      ALB_RNG_State := (ALB_RNG_State * 1_103_515_245) + 12_345;
      Value := ALB_RNG_State and 16#7FFF_FFFF#;
      if Max_Value = 0 then
         return 0;
      end if;
      return Value mod Max_Value;
   end ALB_RND;

   function ALB_CHOOSE
     (Flag        : U64;
      Left_Value  : U64;
      Right_Value : U64) return U64
   is
   begin
      if Flag /= 0 then
         return Left_Value;
      end if;
      return Right_Value;
   end ALB_CHOOSE;

   function ALB_COLLIDE_RECT
     (AX : S32;
      AY : S32;
      AW : S32;
      AH : S32;
      BX : S32;
      BY : S32;
      BW : S32;
      BH : S32) return Boolean
   is
   begin
      return
        AX < (BX + BW)
        and then (AX + AW) > BX
        and then AY < (BY + BH)
        and then (AY + AH) > BY;
   end ALB_COLLIDE_RECT;

   function ALB_SIN (Degrees : S32) return S32 is
      Radians : constant Long_Float :=
        Long_Float (Degrees) * 0.017453292519943295;
   begin
      return S32 (Integer (Sin (Radians) * 1024.0));
   end ALB_SIN;

   function ALB_COS (Degrees : S32) return S32 is
      Radians : constant Long_Float :=
        Long_Float (Degrees) * 0.017453292519943295;
   begin
      return S32 (Integer (Cos (Radians) * 1024.0));
   end ALB_COS;

   function ALB_SQRT (Value : S32) return S32 is
   begin
      if Value <= 0 then
         return 0;
      end if;
      return S32 (Integer (Sqrt (Long_Float (Value))));
   end ALB_SQRT;

   function ALB_EXP (Value : S32) return S32 is
   begin
      return S32 (Integer (Exp (Long_Float (Value))));
   end ALB_EXP;

   function ALB_ROL
     (Value : U64;
      Bits  : U32;
      Width : U32) return U64
   is
      Use_Width : U32 := Width;
      Shift     : U32 := 0;
      Mask      : U64 := U64'Last;
      Left_Factor  : U64 := 1;
      Right_Factor : U64 := 1;
   begin
      if Use_Width = 0 then
         Use_Width := 64;
      elsif Use_Width > 64 then
         Use_Width := 64;
      end if;

      Shift := Bits mod Use_Width;
      if Use_Width < 64 then
         Mask := (U64 (2) ** Natural (Use_Width)) - 1;
      end if;

      if Shift = 0 then
         return Value and Mask;
      end if;

      Left_Factor := U64 (2) ** Natural (Shift);
      Right_Factor := U64 (2) ** Natural (Use_Width - Shift);
      return
        ((((Value and Mask) * Left_Factor) and Mask) or
         ((Value and Mask) / Right_Factor))
        and Mask;
   end ALB_ROL;

   function ALB_ROR
     (Value : U64;
      Bits  : U32;
      Width : U32) return U64
   is
      Use_Width : U32 := Width;
      Shift     : U32 := 0;
      Mask      : U64 := U64'Last;
      Left_Factor  : U64 := 1;
      Right_Factor : U64 := 1;
   begin
      if Use_Width = 0 then
         Use_Width := 64;
      elsif Use_Width > 64 then
         Use_Width := 64;
      end if;

      Shift := Bits mod Use_Width;
      if Use_Width < 64 then
         Mask := (U64 (2) ** Natural (Use_Width)) - 1;
      end if;

      if Shift = 0 then
         return Value and Mask;
      end if;

      Left_Factor := U64 (2) ** Natural (Use_Width - Shift);
      Right_Factor := U64 (2) ** Natural (Shift);
      return
        (((Value and Mask) / Right_Factor) or
         ((((Value and Mask) * Left_Factor) and Mask)))
        and Mask;
   end ALB_ROR;

   function ALB_BOOL_TO_U64 (Value : Boolean) return U64 is
   begin
      if Value then
         return 1;
      end if;
      return 0;
   end ALB_BOOL_TO_U64;

   function ALB_S8_TO_U64 (Value : S8) return U64 is
      Wide : constant ALB_I64 := ALB_I64 (Value);
   begin
      if Wide < 0 then
         return U64 (0) - U64 (ALB_U64 (-Wide));
      end if;
      return U64 (ALB_U64 (Wide));
   end ALB_S8_TO_U64;

   function ALB_S16_TO_U64 (Value : S16) return U64 is
      Wide : constant ALB_I64 := ALB_I64 (Value);
   begin
      if Wide < 0 then
         return U64 (0) - U64 (ALB_U64 (-Wide));
      end if;
      return U64 (ALB_U64 (Wide));
   end ALB_S16_TO_U64;

   function ALB_S32_TO_U64 (Value : S32) return U64 is
      Wide : constant ALB_I64 := ALB_I64 (Value);
   begin
      if Wide < 0 then
         return U64 (0) - U64 (ALB_U64 (-Wide));
      end if;
      return U64 (ALB_U64 (Wide));
   end ALB_S32_TO_U64;

   function ALB_S64_TO_U64 (Value : S64) return U64 is
      Wide : constant ALB_I64 := ALB_I64 (Value);
   begin
      if Wide = ALB_I64'First then
         return 16#8000_0000_0000_0000#;
      elsif Wide < 0 then
         return U64 (0) - U64 (ALB_U64 (-Wide));
      end if;
      return U64 (ALB_U64 (Wide));
   end ALB_S64_TO_U64;

   function ALB_ABS_S32_TO_U64 (Value : S32) return U64 is
      Wide : constant ALB_I64 := ALB_I64 (Value);
   begin
      if Wide < 0 then
         return U64 (ALB_U64 (-Wide));
      end if;
      return U64 (ALB_U64 (Wide));
   end ALB_ABS_S32_TO_U64;

   function ALB_U64_TO_U8 (Value : U64) return U8 is
   begin
      return U8 (ALB_U64 (Value) and 16#FF#);
   end ALB_U64_TO_U8;

   function ALB_U64_TO_U16 (Value : U64) return U16 is
   begin
      return U16 (ALB_U64 (Value) and 16#FFFF#);
   end ALB_U64_TO_U16;

   function ALB_U64_TO_U32 (Value : U64) return U32 is
   begin
      return U32 (ALB_U64 (Value) and 16#FFFF_FFFF#);
   end ALB_U64_TO_U32;

   function ALB_U64_TO_S8 (Value : U64) return S8 is
      Raw : constant U8 := ALB_U64_TO_U8 (Value);
   begin
      if Raw >= 16#80# then
         return S8 (ALB_I16 (Raw) - 16#100#);
      end if;
      return S8 (Raw);
   end ALB_U64_TO_S8;

   function ALB_U64_TO_S16 (Value : U64) return S16 is
      Raw : constant U16 := ALB_U64_TO_U16 (Value);
   begin
      if Raw >= 16#8000# then
         return S16 (ALB_I32 (Raw) - 16#1_0000#);
      end if;
      return S16 (Raw);
   end ALB_U64_TO_S16;

   function ALB_U64_TO_S32 (Value : U64) return S32 is
      Raw : constant U32 := ALB_U64_TO_U32 (Value);
   begin
      if Raw >= 16#8000_0000# then
         return S32 (ALB_I64 (Raw) - 16#1_0000_0000#);
      end if;
      return S32 (Raw);
   end ALB_U64_TO_S32;

   function ALB_U64_TO_S64 (Value : U64) return S64 is
      Raw : constant ALB_U64 := ALB_U64 (Value);
      Min_S64_Bit : constant ALB_U64 := 16#8000_0000_0000_0000#;
   begin
      if Raw = Min_S64_Bit then
         return S64'First;
      elsif Raw > Min_S64_Bit then
         return -S64 ((not Raw) + 1);
      end if;
      return S64 (Raw);
   end ALB_U64_TO_S64;

   function ALB_LOAD_BOOL (Index : Positive) return Boolean is
   begin
      return ALB_LOAD_U8 (Index) /= 0;
   end ALB_LOAD_BOOL;

   procedure ALB_STORE_BOOL
     (Index : Positive;
      Value : Boolean)
   is
   begin
      if Value then
         ALB_STORE_U8 (Index, 1);
      else
         ALB_STORE_U8 (Index, 0);
      end if;
   end ALB_STORE_BOOL;

   function ALB_LOAD_TEXT (Index : Positive) return ALB_Text is
      Result : ALB_Text;
      Raw_Len : constant U32 := U32 (ALB_LOAD_U32 (Index));
      Limit : Natural := Natural'Min (Natural (Raw_Len), Max_Text_Length);
   begin
      Result.Length := Limit;
      for I in 1 .. Limit loop
         Result.Data (I) := Character'Val (Integer (ALB_LOAD_U8 (Index + 4 + I - 1)));
      end loop;
      return Result;
   end ALB_LOAD_TEXT;

   procedure ALB_STORE_TEXT
     (Index : Positive;
      Value : ALB_Text)
   is
   begin
      ALB_STORE_U32 (Index, ALB_U32 (Value.Length));
      for I in 1 .. Max_Text_Length loop
         if I <= Value.Length then
            ALB_STORE_U8 (Index + 4 + I - 1, ALB_U8 (Character'Pos (Value.Data (I))));
         else
            ALB_STORE_U8 (Index + 4 + I - 1, 0);
         end if;
      end loop;
   end ALB_STORE_TEXT;

   function ALB_LOAD_PURE (Index : Positive) return Pure_Rational is
      Num64 : constant S64 := S64 (ALB_LOAD_I64 (Index));
      Den64 : constant S64 := S64 (ALB_LOAD_I64 (Index + 8));
   begin
      if Den64 = 0 then
         return ALB_PURE (Integer (Num64), 1);
      end if;
      return ALB_PURE (Long_Integer (Num64), Long_Integer (Den64));
   end ALB_LOAD_PURE;

   procedure ALB_STORE_PURE
     (Index : Positive;
      Value : Pure_Rational)
   is
   begin
      ALB_STORE_I64 (Index, ALB_I64 (S64 (Value.Num)));
      ALB_STORE_I64 (Index + 8, ALB_I64 (S64 (Value.Den)));
   end ALB_STORE_PURE;

   function ALB_LOAD_F32 (Index : Positive) return F32 is
   begin
      return U32_Bits_To_F32 (ALB_LOAD_U32 (Index));
   end ALB_LOAD_F32;

   procedure ALB_STORE_F32
     (Index : Positive;
      Value : F32)
   is
   begin
      ALB_STORE_U32 (Index, F32_To_U32_Bits (Value));
   end ALB_STORE_F32;

   function ALB_LOAD_F64 (Index : Positive) return F64 is
   begin
      return U64_Bits_To_F64 (ALB_U64 (ALB_LOAD_U64 (Index)));
   end ALB_LOAD_F64;

   procedure ALB_STORE_F64
     (Index : Positive;
      Value : F64)
   is
   begin
      ALB_STORE_U64 (Index, U64 (F64_To_U64_Bits (Value)));
   end ALB_STORE_F64;

   function ALB_LOAD_U8
     (Index : Positive) return ALB_U8
   is
   begin
      return ALB_VAS (Index);
   end ALB_LOAD_U8;

   function ALB_LOAD_U16
     (Index : Positive) return ALB_U16
   is
   begin
      return ALB_U16 (ALB_VAS (Index))
        or Interfaces.Shift_Left (ALB_U16 (ALB_VAS (Index + 1)), 8);
   end ALB_LOAD_U16;

   function ALB_LOAD_U32
     (Index : Positive) return ALB_U32
   is
   begin
      return ALB_U32 (ALB_VAS (Index))
        or Interfaces.Shift_Left (ALB_U32 (ALB_VAS (Index + 1)), 8)
        or Interfaces.Shift_Left (ALB_U32 (ALB_VAS (Index + 2)), 16)
        or Interfaces.Shift_Left (ALB_U32 (ALB_VAS (Index + 3)), 24);
   end ALB_LOAD_U32;

   function ALB_LOAD_U64
     (Index : Positive) return U64
   is
   begin
      return U64 (ALB_U64 (ALB_VAS (Index))
        or Interfaces.Shift_Left (ALB_U64 (ALB_VAS (Index + 1)), 8)
        or Interfaces.Shift_Left (ALB_U64 (ALB_VAS (Index + 2)), 16)
        or Interfaces.Shift_Left (ALB_U64 (ALB_VAS (Index + 3)), 24)
        or Interfaces.Shift_Left (ALB_U64 (ALB_VAS (Index + 4)), 32)
        or Interfaces.Shift_Left (ALB_U64 (ALB_VAS (Index + 5)), 40)
        or Interfaces.Shift_Left (ALB_U64 (ALB_VAS (Index + 6)), 48)
        or Interfaces.Shift_Left (ALB_U64 (ALB_VAS (Index + 7)), 56));
   end ALB_LOAD_U64;

   function ALB_LOAD_I8
     (Index : Positive) return ALB_I8
   is
   begin
      return ALB_I8 (ALB_VAS (Index));
   end ALB_LOAD_I8;

   function ALB_LOAD_I16
     (Index : Positive) return ALB_I16
   is
      Raw : constant ALB_U16 := ALB_LOAD_U16 (Index);
   begin
      if Raw >= 16#8000# then
         return ALB_I16 (ALB_I32 (Raw) - 16#1_0000#);
      end if;

      return ALB_I16 (Raw);
   end ALB_LOAD_I16;

   function ALB_LOAD_I32
     (Index : Positive) return ALB_I32
   is
      Raw : constant ALB_U32 := ALB_LOAD_U32 (Index);
   begin
      if Raw >= 16#8000_0000# then
         return ALB_I32 (ALB_I64 (Raw) - 16#1_0000_0000#);
      end if;

      return ALB_I32 (Raw);
   end ALB_LOAD_I32;

   function ALB_LOAD_I64
     (Index : Positive) return ALB_I64
   is
   begin
      return ALB_I64 (ALB_U64_TO_S64 (U64 (ALB_LOAD_U64 (Index))));
   end ALB_LOAD_I64;

   procedure ALB_STORE_U8
     (Index : Positive;
      Value : ALB_U8)
   is
   begin
      ALB_VAS (Index) := Value;
   end ALB_STORE_U8;

   procedure ALB_STORE_U16
     (Index : Positive;
      Value : ALB_U16)
   is
   begin
      ALB_VAS (Index)     := ALB_U8 (Value and 16#00FF#);
      ALB_VAS (Index + 1) := ALB_U8 (Interfaces.Shift_Right (Value, 8) and 16#00FF#);
   end ALB_STORE_U16;

   procedure ALB_STORE_U32
     (Index : Positive;
      Value : ALB_U32)
   is
   begin
      ALB_VAS (Index)     := ALB_U8 (Value and 16#0000_00FF#);
      ALB_VAS (Index + 1) := ALB_U8 (Interfaces.Shift_Right (Value, 8) and 16#0000_00FF#);
      ALB_VAS (Index + 2) := ALB_U8 (Interfaces.Shift_Right (Value, 16) and 16#0000_00FF#);
      ALB_VAS (Index + 3) := ALB_U8 (Interfaces.Shift_Right (Value, 24) and 16#0000_00FF#);
   end ALB_STORE_U32;

   procedure ALB_STORE_U64
     (Index : Positive;
      Value : U64)
   is
      Stored : constant ALB_U64 := ALB_U64 (Value);
   begin
      ALB_VAS (Index)     := ALB_U8 (Stored and 16#0000_0000_0000_00FF#);
      ALB_VAS (Index + 1) := ALB_U8 (Interfaces.Shift_Right (Stored, 8) and 16#0000_0000_0000_00FF#);
      ALB_VAS (Index + 2) := ALB_U8 (Interfaces.Shift_Right (Stored, 16) and 16#0000_0000_0000_00FF#);
      ALB_VAS (Index + 3) := ALB_U8 (Interfaces.Shift_Right (Stored, 24) and 16#0000_0000_0000_00FF#);
      ALB_VAS (Index + 4) := ALB_U8 (Interfaces.Shift_Right (Stored, 32) and 16#0000_0000_0000_00FF#);
      ALB_VAS (Index + 5) := ALB_U8 (Interfaces.Shift_Right (Stored, 40) and 16#0000_0000_0000_00FF#);
      ALB_VAS (Index + 6) := ALB_U8 (Interfaces.Shift_Right (Stored, 48) and 16#0000_0000_0000_00FF#);
      ALB_VAS (Index + 7) := ALB_U8 (Interfaces.Shift_Right (Stored, 56) and 16#0000_0000_0000_00FF#);
   end ALB_STORE_U64;

   procedure ALB_STORE_I8
     (Index : Positive;
      Value : ALB_I8)
   is
   begin
      ALB_STORE_U8
        (Index,
         ALB_U8 (ALB_U64_TO_U8 (ALB_S8_TO_U64 (S8 (Value)))));
   end ALB_STORE_I8;

   procedure ALB_STORE_I16
     (Index : Positive;
      Value : ALB_I16)
   is
   begin
      ALB_STORE_U16
        (Index,
         ALB_U16 (ALB_U64_TO_U16 (ALB_S16_TO_U64 (S16 (Value)))));
   end ALB_STORE_I16;

   procedure ALB_STORE_I32
     (Index : Positive;
      Value : ALB_I32)
   is
   begin
      ALB_STORE_U32
        (Index,
         ALB_U32 (ALB_U64_TO_U32 (ALB_S32_TO_U64 (S32 (Value)))));
   end ALB_STORE_I32;

   procedure ALB_STORE_I64
     (Index : Positive;
      Value : ALB_I64)
   is
   begin
      ALB_STORE_U64 (Index, ALB_S64_TO_U64 (S64 (Value)));
   end ALB_STORE_I64;

   procedure ALB_MEM_ZERO
     (Index : Positive;
      Size  : Natural)
   is
   begin
      if Size = 0 then
         return;
      end if;

      for Offset in 0 .. Size - 1 loop
         ALB_VAS (Index + Offset) := 0;
      end loop;
   end ALB_MEM_ZERO;

   procedure ALB_MEM_COPY
     (Destination : Positive;
      Source      : Positive;
      Size        : Natural)
   is
   begin
      if Size = 0 or else Destination = Source then
         return;
      end if;

      if Destination < Source then
         for Offset in 0 .. Size - 1 loop
            ALB_VAS (Destination + Offset) := ALB_VAS (Source + Offset);
         end loop;
      else
         for Offset in reverse 0 .. Size - 1 loop
            ALB_VAS (Destination + Offset) := ALB_VAS (Source + Offset);
         end loop;
      end if;
   end ALB_MEM_COPY;

   procedure ALB_VAS_COPY
     (Destination : Positive;
      Source      : Positive;
      Size        : Natural)
   is
   begin
      ALB_MEM_COPY (Destination, Source, Size);
   end ALB_VAS_COPY;

   function ALB_PEEK
     (Address : Positive) return U64
   is
   begin
      return U64 (ALB_LOAD_U64 (Address));
   end ALB_PEEK;

   function ALB_DEREF
     (Address : Positive) return U64
   is
   begin
      return U64 (ALB_LOAD_U64 (Address));
   end ALB_DEREF;

   procedure ALB_POKE
     (Address : Positive;
      Value   : U64)
   is
   begin
      ALB_STORE_U64 (Address, Value);
   end ALB_POKE;

end ALBA_Runtime;
