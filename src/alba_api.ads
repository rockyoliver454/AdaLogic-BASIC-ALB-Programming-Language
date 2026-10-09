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

with Ada.Unchecked_Conversion;

package ALBA_API is
   pragma SPARK_Mode (Off);

   type U8 is mod 2 ** 8;
   for U8'Size use 8;

   type U16 is mod 2 ** 16;
   for U16'Size use 16;

   type U32 is mod 2 ** 32;
   for U32'Size use 32;

   type U64 is mod 2 ** 64;
   for U64'Size use 64;

   type S8 is range -(2 ** 7) .. (2 ** 7) - 1;
   for S8'Size use 8;

   type S16 is range -(2 ** 15) .. (2 ** 15) - 1;
   for S16'Size use 16;

   type S32 is range -(2 ** 31) .. (2 ** 31) - 1;
   for S32'Size use 32;

   type S64 is range -(2 ** 63) .. (2 ** 63) - 1;
   for S64'Size use 64;

   type F32 is digits 6;
   for F32'Size use 32;

   type F64 is digits 15;
   for F64'Size use 64;

   function S32_As_U32 is new Ada.Unchecked_Conversion (S32, U32);
   function U32_As_S32 is new Ada.Unchecked_Conversion (U32, S32);
   function S64_As_U64 is new Ada.Unchecked_Conversion (S64, U64);
   function U64_As_S64 is new Ada.Unchecked_Conversion (U64, S64);

   function "and" (Left, Right : S32) return S32 is
     (U32_As_S32 (S32_As_U32 (Left) and S32_As_U32 (Right)));
   function "or" (Left, Right : S32) return S32 is
     (U32_As_S32 (S32_As_U32 (Left) or S32_As_U32 (Right)));
   function "xor" (Left, Right : S32) return S32 is
     (U32_As_S32 (S32_As_U32 (Left) xor S32_As_U32 (Right)));
   function "not" (Value : S32) return S32 is
     (U32_As_S32 (not S32_As_U32 (Value)));

   function "and" (Left, Right : S64) return S64 is
     (U64_As_S64 (S64_As_U64 (Left) and S64_As_U64 (Right)));
   function "or" (Left, Right : S64) return S64 is
     (U64_As_S64 (S64_As_U64 (Left) or S64_As_U64 (Right)));
   function "xor" (Left, Right : S64) return S64 is
     (U64_As_S64 (S64_As_U64 (Left) xor S64_As_U64 (Right)));
   function "not" (Value : S64) return S64 is
     (U64_As_S64 (not S64_As_U64 (Value)));

   function "and" (Left : Boolean; Right : S32) return Boolean is
     (Left and (Right /= 0));
   function "and" (Left : S32; Right : Boolean) return Boolean is
     ((Left /= 0) and Right);
   function "or" (Left : Boolean; Right : S32) return Boolean is
     (Left or (Right /= 0));
   function "or" (Left : S32; Right : Boolean) return Boolean is
     ((Left /= 0) or Right);
   function "xor" (Left : Boolean; Right : S32) return Boolean is
     (Left xor (Right /= 0));
   function "xor" (Left : S32; Right : Boolean) return Boolean is
     ((Left /= 0) xor Right);

   subtype ALB_U8  is U8;
   subtype ALB_U16 is U16;
   subtype ALB_U32 is U32;
   subtype ALB_U64 is U64;

   subtype ALB_I8  is S8;
   subtype ALB_I16 is S16;
   subtype ALB_I32 is S32;
   subtype ALB_I64 is S64;

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

   type Pure_Rational is record
      Num : Long_Integer := 0;
      Den : Long_Integer := 1;
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
   function ALB_PURE_POW (A, B : Pure_Rational) return Pure_Rational;
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

   package ALBA_Graphics is

      procedure Initialize
        (Title   : in String;
         Width   : in Natural;
         Height  : in Natural;
         Success : out Boolean);
      procedure Set_Fullscreen (Enabled : in Boolean);
      procedure Set_Resizable (Enabled : in Boolean);
      procedure Set_Stretchy (Enabled : in Boolean);

      procedure Shutdown;
      procedure Process_Events;
      procedure Present;
      function Window_Open return Boolean;
      procedure Request_Close;
      function Pending_Key_Event return Boolean;

      procedure Pause_For (Milliseconds : in Natural);
      function Monotonic_Millis return Natural;
      function Virtual_Width return Natural;
      function Virtual_Height return Natural;

      procedure Set_Color (RGB : in Natural);
      procedure Clear (RGB : in Natural);
      procedure Draw_Rect
        (X : in Integer;
         Y : in Integer;
         W : in Integer;
         H : in Integer);
      procedure Fill_Rect
        (X : in Integer;
         Y : in Integer;
         W : in Integer;
         H : in Integer);
      procedure Draw_Line
        (X1 : in Integer;
         Y1 : in Integer;
         X2 : in Integer;
         Y2 : in Integer);
      procedure Draw_Circle
        (CX     : in Integer;
         CY     : in Integer;
         Radius : in Integer);
      procedure Fill_Circle
        (CX     : in Integer;
         CY     : in Integer;
         Radius : in Integer);
      procedure Draw_Triangle
        (X1 : in Integer;
         Y1 : in Integer;
         X2 : in Integer;
         Y2 : in Integer;
         X3 : in Integer;
         Y3 : in Integer);
      procedure Fill_Triangle
        (X1 : in Integer;
         Y1 : in Integer;
         X2 : in Integer;
         Y2 : in Integer;
         X3 : in Integer;
         Y3 : in Integer);
      procedure Plot
        (X : in Integer;
         Y : in Integer);
      procedure Draw_Text
        (X    : in Integer;
         Y    : in Integer;
         Text : in String);
      procedure Set_Alpha
        (Channel : in Integer;
         Value   : in Integer);
      procedure Set_Clip
        (X : in Integer;
         Y : in Integer;
         W : in Integer;
         H : in Integer);
      procedure Set_Origin
        (X : in Integer;
         Y : in Integer);

      function Key_Down (Code : in Integer) return Boolean;
      function Mouse_X return Integer;
      function Mouse_Y return Integer;
      function VMouse_X return Integer;
      function VMouse_Y return Integer;
      function Mouse_Click (Button : in Integer) return Integer;
      function Read_Pixel
        (X : in Integer;
         Y : in Integer) return Natural;

   end ALBA_Graphics;

   package ALBA_Audio is

      procedure Play_Sound (Path : in String);
      procedure Play_Music (MML : in String);
      procedure Play_Music_From (Path : in String);
      procedure Shutdown;

   end ALBA_Audio;

   package ALBA_GC is

      function Claim return U64;
      procedure Drop (Handle : in U64);
      procedure Bind
        (Parent : in U64;
         Child1 : in U64;
         Child2 : in U64);
      procedure Sweep (Chunk : in U64);

   end ALBA_GC;

   package ALBA_Logic is

      Max_Find_Results : constant Positive := 256;

      function Hash_Name (Text : String) return U32;
      procedure Assert_Fact
        (Pred_Hash : in U32;
         Value     : in S32);
      procedure Retract_Fact
        (Pred_Hash : in U32;
         Value     : in S32);
      procedure Update_Fact
        (Pred_Hash : in U32;
         Old_Value : in S32;
         New_Value : in S32);
      function Prove
        (Pred_Hash : in U32;
         Value     : in S32) return Boolean;
      function Find_First
        (Pred_Hash : in U32) return S32;
      procedure Find_All (Pred_Hash : in U32);
      function Find_Result_Count return Natural;
      function Find_Result (Index : in Positive) return S32;
      function Register_Rule
        (Head_Pred_Hash : in U32;
         Head_Mode      : in Natural;
         Head_Value     : in S32;
         Var_Count      : in Natural) return Natural;
      procedure Add_Rule_Term
        (Rule_Index : in Natural;
         Pred_Hash  : in U32;
         Arg_Mode   : in Natural;
         Arg_Value  : in S32);

   end ALBA_Logic;

   package ALBA_IO is

      procedure Print_Text
        (Text    : in ALB_Text;
         Newline : in Boolean := True);

      function Input (Prompt : in ALB_Text) return ALB_Text;
      function Readline return ALB_Text;

      function Read_Integer
        (Prompt  : in ALB_Text;
         Default : in Integer := 0) return Integer;

      function Read_Integer_In_Range
        (Prompt  : in ALB_Text;
         Min_Val : in Integer;
         Max_Val : in Integer;
         Default : in Integer) return Integer;

      procedure Locate
        (Col : in Integer;
         Row : in Integer := 1);

      procedure Message_Box
        (Body_Text : in ALB_Text;
         Title     : in ALB_Text);

      function File_Open
        (Path : in ALB_Text;
         Mode : in ALB_Text) return U64;

      function File_Read
        (Handle : in U64;
         Count  : in U64) return ALB_Text;

      procedure File_Write
        (Handle : in U64;
         Data   : in ALB_Text);

      procedure File_Close (Handle : in U64);

      function Load_File (Path : in ALB_Text) return ALB_Text;
      procedure Load_File
        (Data : in out ALB_U8_Array;
         Path : in ALB_Text);
      procedure Load_File
        (Data : in out ALB_U16_Array;
         Path : in ALB_Text);
      procedure Load_File
        (Data : in out ALB_U32_Array;
         Path : in ALB_Text);
      procedure Load_File
        (Data : in out ALB_U64_Array;
         Path : in ALB_Text);
      procedure Load_File
        (Data : in out ALB_I8_Array;
         Path : in ALB_Text);
      procedure Load_File
        (Data : in out ALB_I16_Array;
         Path : in ALB_Text);
      procedure Load_File
        (Data : in out ALB_I32_Array;
         Path : in ALB_Text);
      procedure Load_File
        (Data : in out ALB_I64_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_Text;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_U8_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_U16_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_U32_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_U64_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_I8_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_I16_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_I32_Array;
         Path : in ALB_Text);
      procedure Flush_File
        (Data : in ALB_I64_Array;
         Path : in ALB_Text);

   end ALBA_IO;

end ALBA_API;
