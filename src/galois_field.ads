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

pragma Ada_2012;

package Galois_Field
  with SPARK_Mode => On
is
   subtype Real is Float;

   type Word is mod 2 ** 32;
   type RNG_Word is mod 2 ** 64;

   Max_Poly_Degree : constant Positive := 15;
   subtype Poly_Index is Natural range 0 .. Max_Poly_Degree;

   type Word_Array is array (Positive range <>) of Word;
   type Poly_Coefficients is array (Poly_Index) of Word;

   type Polynomial is record
      Degree : Poly_Index := 0;
      Coeffs : Poly_Coefficients := (others => 0);
   end record;

   type RNG_State is record
      State     : RNG_Word := 0;
      Increment : RNG_Word := 1;
   end record;

   function Mix_Bits (Value : Word) return Word;
   function Hash_1D (Seed : Word; Value : Word) return Word;
   function Hash_2D (Seed : Word; Left : Word; Right : Word) return Word;
   function Hash_Sequence
     (Seed  : Word;
      Data  : Word_Array;
      Count : Natural) return Word
     with Pre => Count <= Data'Length;

   procedure Seed_State
     (Seed   : Word;
      Stream : Word;
      State  : out RNG_State);

   procedure Next_Word
     (State : in out RNG_State;
      Value : out Word);

   procedure Next_Unit_Real
     (State : in out RNG_State;
      Value : out Real);

   function Add_GF (Left : Word; Right : Word) return Word;
   function Sub_GF (Left : Word; Right : Word) return Word;
   function Mul_GF (Left : Word; Right : Word) return Word;

   procedure Pow_GF
     (Base     : Word;
      Exponent : Natural;
      Result   : out Word);

   procedure Poly_Clear (Value : out Polynomial);

   procedure Poly_Set
     (Value       : in out Polynomial;
      Coefficient : Word;
      Position    : Poly_Index);

   function Poly_Eval_GF
     (Value : Polynomial;
      X     : Word) return Word;

   procedure Poly_Mul_GF
     (Left      : Polynomial;
      Right     : Polynomial;
      Product   : out Polynomial;
      Saturated : out Boolean);

   function Checksum_Block
     (Data  : Word_Array;
      Count : Natural;
      Seed  : Word := 0) return Word
     with Pre => Count <= Data'Length;

   function To_Unit_Real (Value : Word) return Real;

end Galois_Field;
