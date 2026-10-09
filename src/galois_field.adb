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

package body Galois_Field
  with SPARK_Mode => On
is
   Word_Max_Real : constant Real := 4_294_967_295.0;

   function Mix_Bits (Value : Word) return Word is
      Result : Word := Value;
   begin
      Result := Result xor (Result / 2 ** 16);
      Result := Result * 16#85EB_CA6B#;
      Result := Result xor (Result / 2 ** 13);
      Result := Result * 16#C2B2_AE35#;
      Result := Result xor (Result / 2 ** 16);
      return Result;
   end Mix_Bits;

   function Hash_1D (Seed : Word; Value : Word) return Word is
   begin
      return Mix_Bits (Mix_Bits (Seed) xor Mix_Bits (Value));
   end Hash_1D;

   function Hash_2D (Seed : Word; Left : Word; Right : Word) return Word is
      Result : Word := Seed;
   begin
      Result := Result xor Mix_Bits (Left);
      Result := Mix_Bits (Result);
      Result := Result xor Mix_Bits (Right);
      Result := Mix_Bits (Result);
      return Result;
   end Hash_2D;

   function Hash_Sequence
     (Seed  : Word;
      Data  : Word_Array;
      Count : Natural) return Word
   is
      Result : Word := Mix_Bits (Seed xor Word (Count));
   begin
      if Count = 0 then
         return Result;
      end if;

      for Offset in 0 .. Count - 1 loop
         declare
            Index : constant Positive := Data'First + Offset;
         begin
            Result := Result xor Mix_Bits (Data (Index));
            Result := Mix_Bits (Result xor Word (Offset + 1));
         end;
      end loop;

      return Result;
   end Hash_Sequence;

   procedure Seed_State
     (Seed   : Word;
      Stream : Word;
      State  : out RNG_State) is
   begin
      State.State := RNG_Word (Mix_Bits (Seed)) * 6364136223846793005;
      State.Increment :=
        RNG_Word ((Stream * 2) + 1) + RNG_Word (16#DA3E_39CB_94B9_5BDB#);
      State.State := State.State + State.Increment;
   end Seed_State;

   procedure Next_Word
     (State : in out RNG_State;
      Value : out Word) is
      High : Word;
      Low  : Word;
   begin
      State.State :=
        State.State * 6364136223846793005 + State.Increment;
      High := Word (State.State / 2 ** 32);
      Low := Word (State.State mod 2 ** 32);
      Value := Mix_Bits (High xor Mix_Bits (Low));
   end Next_Word;

   function To_Unit_Real (Value : Word) return Real is
   begin
      return Real (Value) / Word_Max_Real;
   end To_Unit_Real;

   procedure Next_Unit_Real
     (State : in out RNG_State;
      Value : out Real) is
      Raw : Word := 0;
   begin
      Next_Word (State, Raw);
      Value := To_Unit_Real (Raw);
   end Next_Unit_Real;

   function Add_GF (Left : Word; Right : Word) return Word is
   begin
      return Left xor Right;
   end Add_GF;

   function Sub_GF (Left : Word; Right : Word) return Word is
   begin
      return Left xor Right;
   end Sub_GF;

   function Mul_GF (Left : Word; Right : Word) return Word is
      A      : Word := Left;
      B      : Word := Right;
      Result : Word := 0;
   begin
      for Step in 1 .. 32 loop
         if (A mod 2) = 1 then
            Result := Result xor B;
         end if;
         A := A / 2;
         B := B * 2;
      end loop;
      return Result;
   end Mul_GF;

   procedure Pow_GF
     (Base     : Word;
      Exponent : Natural;
      Result   : out Word) is
      Working_Base : Word := Base;
      Power        : Natural := Exponent;
      Accumulator  : Word := 1;
   begin
      while Power > 0 loop
         if (Power mod 2) = 1 then
            Accumulator := Mul_GF (Accumulator, Working_Base);
         end if;
         Power := Power / 2;
         exit when Power = 0;
         Working_Base := Mul_GF (Working_Base, Working_Base);
      end loop;
      Result := Accumulator;
   end Pow_GF;

   procedure Poly_Clear (Value : out Polynomial) is
   begin
      Value.Degree := 0;
      Value.Coeffs := (others => 0);
   end Poly_Clear;

   procedure Poly_Set
     (Value       : in out Polynomial;
      Coefficient : Word;
      Position    : Poly_Index) is
   begin
      Value.Coeffs (Position) := Coefficient;
      if Coefficient /= 0 and then Position > Value.Degree then
         Value.Degree := Position;
      elsif Position = Value.Degree and then Coefficient = 0 then
         for Scan in reverse 0 .. Max_Poly_Degree loop
            if Value.Coeffs (Scan) /= 0 then
               Value.Degree := Scan;
               return;
            end if;
         end loop;
         Value.Degree := 0;
      end if;
   end Poly_Set;

   function Poly_Eval_GF
     (Value : Polynomial;
      X     : Word) return Word is
      Result : Word := 0;
   begin
      for Index in reverse 0 .. Value.Degree loop
         Result := Mul_GF (Result, X);
         Result := Add_GF (Result, Value.Coeffs (Index));
      end loop;
      return Result;
   end Poly_Eval_GF;

   procedure Poly_Mul_GF
     (Left      : Polynomial;
      Right     : Polynomial;
      Product   : out Polynomial;
      Saturated : out Boolean) is
      Working : Polynomial := (Degree => 0, Coeffs => (others => 0));
      Index_Sum : Natural := 0;
   begin
      Saturated := False;
      Poly_Clear (Product);

      for L in 0 .. Left.Degree loop
         for R in 0 .. Right.Degree loop
            Index_Sum := L + R;
            if Index_Sum > Max_Poly_Degree then
               Saturated := True;
            else
               Working.Coeffs (Poly_Index (Index_Sum)) :=
                 Add_GF
                   (Working.Coeffs (Poly_Index (Index_Sum)),
                    Mul_GF (Left.Coeffs (L), Right.Coeffs (R)));
               if Working.Coeffs (Poly_Index (Index_Sum)) /= 0
                 and then Poly_Index (Index_Sum) > Working.Degree
               then
                  Working.Degree := Poly_Index (Index_Sum);
               end if;
            end if;
         end loop;
      end loop;

      Product := Working;
   end Poly_Mul_GF;

   function Checksum_Block
     (Data  : Word_Array;
      Count : Natural;
      Seed  : Word := 0) return Word is
      Result : Word := Mix_Bits (Seed xor Word (Count));
   begin
      if Count = 0 then
         return Result;
      end if;

      for Offset in 0 .. Count - 1 loop
         declare
            Index : constant Positive := Data'First + Offset;
         begin
            Result := Hash_2D (Result, Data (Index), Word (Offset + 1));
         end;
      end loop;

      return Result;
   end Checksum_Block;

end Galois_Field;
