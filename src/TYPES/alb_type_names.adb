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

package body ALB_Type_Names is

   function Upper_ASCII (S : String) return String is
      R : String (S'Range);
   begin
      for I in S'Range loop
         if S (I) in 'a' .. 'z' then
            R (I) := Character'Val (Character'Pos (S (I)) - 32);
         else
            R (I) := S (I);
         end if;
      end loop;
      return R;
   end Upper_ASCII;

   function Is_Void_Type_Name (Name : String) return Boolean is
      U : constant String := Upper_ASCII (Name);
   begin
      return U = "U0" or else U = "NONE" or else U = "VOID";
   end Is_Void_Type_Name;

   function Resolve_Type_Name (Name : String) return ALB_Type_Tag is
      U : constant String := Upper_ASCII (Name);
   begin
      if U'Length = 0 then
         return Type_None;
      end if;

      -- Void / sentinel (not a value AS type, but recognized)
      if Is_Void_Type_Name (Name) then
         return Type_None;
      end if;

      -- Unsigned
      if U = "U8" then
         return Type_U8;
      elsif U = "U16" then
         return Type_U16;
      elsif U = "U32" then
         return Type_U32;
      elsif U = "U64" then
         return Type_U64;
      elsif U = "U128" then
         return Type_U128;

      -- Signed + aliases
      elsif U = "S8" or else U = "I8" or else U = "INT8" then
         return Type_S8;
      elsif U = "S16" or else U = "I16" or else U = "INT16" then
         return Type_S16;
      elsif U = "S32" or else U = "I32" or else U = "INT32" then
         return Type_S32;
      elsif U = "S64" or else U = "I64" or else U = "INT64" then
         return Type_S64;
      elsif U = "S128" then
         return Type_S128;

      -- Float + aliases
      elsif U = "F32" or else U = "SINGLE" or else U = "FLOAT" then
         return Type_F32;
      elsif U = "F64" or else U = "REAL" or else U = "DOUBLE"
        or else U = "NUMBER"
      then
         return Type_F64;
      elsif U = "F128" then
         return Type_F128;

      -- Pure / rational
      elsif U = "PURE" or else U = "RATIONAL" then
         return Type_Pure;

      -- Bool / text / char
      elsif U = "BOOLEAN" or else U = "BOOL" then
         return Type_Boolean;
      elsif U = "STRING" or else U = "BINARY" then
         return Type_Binary;
      elsif U = "CHAR" then
         return Type_Char;

      -- Vectors / matrices
      elsif U = "FLOAT2" or else U = "F32X2" then
         return Type_F32x2;
      elsif U = "FLOAT4" or else U = "F32X4" then
         return Type_F32x4;
      elsif U = "MAT2" or else U = "MAT2X2" then
         return Type_Mat2x2;
      elsif U = "MAT3" or else U = "MAT3X3" then
         return Type_Mat3x3;
      elsif U = "MAT4" or else U = "MAT4X4" then
         return Type_Mat4x4;

      -- Hardware bitsets
      elsif U = "HW8" then
         return Type_HW8;
      elsif U = "HW16" then
         return Type_HW16;
      elsif U = "HW32" then
         return Type_HW32;
      elsif U = "HW64" then
         return Type_HW64;

      else
         return Type_None;
      end if;
   end Resolve_Type_Name;

   function Canonical_Type_Name (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8        => return "U8";
         when Type_U16       => return "U16";
         when Type_U32       => return "U32";
         when Type_U64       => return "U64";
         when Type_U128      => return "U128";
         when Type_S8        => return "S8";
         when Type_S16       => return "S16";
         when Type_S32       => return "S32";
         when Type_S64       => return "S64";
         when Type_S128      => return "S128";
         when Type_F32       => return "F32";
         when Type_F64       => return "F64";
         when Type_F128      => return "F128";
         when Type_F32x2     => return "FLOAT2";
         when Type_F32x4     => return "FLOAT4";
         when Type_U32x4     => return "U32X4";
         when Type_S32x4     => return "S32X4";
         when Type_Mat2x2    => return "MAT2";
         when Type_Mat3x3    => return "MAT3";
         when Type_Mat4x4    => return "MAT4";
         when Type_Boolean   => return "BOOLEAN";
         when Type_Char      => return "CHAR";
         when Type_Reference => return "REFERENCE";
         when Type_Pure      => return "PURE";
         when Type_HW8       => return "HW8";
         when Type_HW16      => return "HW16";
         when Type_HW32      => return "HW32";
         when Type_HW64      => return "HW64";
         when Type_Binary    => return "STRING";
         when Type_None      => return "NONE";
      end case;
   end Canonical_Type_Name;

   function Is_Builtin_Type_Name (Name : String) return Boolean is
   begin
      if Is_Void_Type_Name (Name) then
         return True;
      end if;
      return Resolve_Type_Name (Name) /= Type_None;
   end Is_Builtin_Type_Name;

   function Belongs_On
     (Tag   : ALB_Type_Tag;
      Class : Backend_Class) return Belong_Kind
   is
   begin
      if Tag = Type_None then
         return Belong_Void;
      end if;

      case Class is
         when Class_Erased =>
            return Belong_Soft;

         when Class_Retro_8_16 =>
            case Tag is
               when Type_U8 | Type_U16
                  | Type_S8 | Type_S16
                  | Type_HW8 | Type_HW16
                  | Type_Boolean | Type_Binary =>
                  return Belong_Must;
               when Type_Char
                  | Type_U32 | Type_S32 | Type_HW32
                  | Type_U64 | Type_S64 | Type_Pure =>
                  -- Existing FASM16 path may normalize/truncate these.
                  return Belong_Soft;
               when others =>
                  return Belong_Out;
            end case;

         when Class_Modern_Native | Class_Managed =>
            case Tag is
               when Type_U8 | Type_U16 | Type_U32 | Type_U64
                  | Type_S8 | Type_S16 | Type_S32 | Type_S64
                  | Type_F32 | Type_F64
                  | Type_Pure
                  | Type_Boolean | Type_Binary
                  | Type_HW8 | Type_HW16 | Type_HW32
                  | Type_F32x2 | Type_F32x4
                  | Type_Mat2x2 | Type_Mat3x3 | Type_Mat4x4 =>
                  return Belong_Must;

               when Type_U128 | Type_S128 | Type_Char | Type_HW64 =>
                  return Belong_Must;

               when Type_F128 =>
                  return Belong_Soft;

               when Type_U32x4 | Type_S32x4 | Type_Reference =>
                  return Belong_Out;

               when Type_None =>
                  return Belong_Void;
            end case;
      end case;
   end Belongs_On;

   function Allowed_As_Array_Element
     (Tag   : ALB_Type_Tag;
      Class : Backend_Class) return Boolean
   is
      Kind : constant Belong_Kind := Belongs_On (Tag, Class);
   begin
      if Kind = Belong_Out or else Kind = Belong_Void then
         return False;
      end if;

      case Class is
         when Class_Retro_8_16 =>
            return Tag in
              Type_U8 | Type_U16 | Type_S8 | Type_S16
              | Type_HW8 | Type_HW16 | Type_Boolean | Type_Char
              | Type_U32 | Type_S32 | Type_HW32 | Type_Pure;
            -- U32/S32/PURE may still be Soft-normalized on FASM16.

         when Class_Modern_Native | Class_Managed | Class_Erased =>
            return Tag in
              Type_U8 | Type_U16 | Type_U32 | Type_U64 | Type_U128
              | Type_S8 | Type_S16 | Type_S32 | Type_S64
              | Type_F32 | Type_F64
              | Type_Pure
              | Type_Boolean | Type_Char
              | Type_HW8 | Type_HW16 | Type_HW32 | Type_HW64
              | Type_F32x2 | Type_F32x4;
      end case;
   end Allowed_As_Array_Element;

end ALB_Type_Names;
