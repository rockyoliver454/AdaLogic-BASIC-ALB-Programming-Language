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

with Interfaces; use Interfaces;
with GD_CORDIC;
with Fixed_Sqrt; use Fixed_Sqrt;
with GD_Fixed;   use GD_Fixed;

package body Geo_Algebra is

   -------------------------------------------------------------------------
   -- Constructors
   -------------------------------------------------------------------------
   function Zero return Multivector is
   begin
      return (others => GD_Fixed.Zero);
   end Zero;

   function Scalar (Val : Fix16) return Multivector is
      R : Multivector := Zero;
   begin
      R.S := Val;
      return R;
   end Scalar;

   function Vector (X, Y, Z : Fix16) return Multivector is
      R : Multivector := Zero;
   begin
      R.E1 := X; R.E2 := Y; R.E3 := Z;
      return R;
   end Vector;

   function Bivector (XY, YZ, ZX : Fix16) return Multivector is
      R : Multivector := Zero;
   begin
      R.E12 := XY; R.E23 := YZ; R.E31 := ZX;
      return R;
   end Bivector;

   -------------------------------------------------------------------------
   -- Axioms
   -------------------------------------------------------------------------
   function Add (A, B : Multivector) return Multivector is
   begin
      return (S   => Add_Sat(A.S, B.S),
              E1  => Add_Sat(A.E1, B.E1),  E2  => Add_Sat(A.E2, B.E2),  E3  => Add_Sat(A.E3, B.E3),
              E12 => Add_Sat(A.E12, B.E12), E23 => Add_Sat(A.E23, B.E23), E31 => Add_Sat(A.E31, B.E31),
              I   => Add_Sat(A.I, B.I));
   end Add;

   function Sub (A, B : Multivector) return Multivector is
   begin
      return (S   => Sub_Sat(A.S, B.S),
              E1  => Sub_Sat(A.E1, B.E1),  E2  => Sub_Sat(A.E2, B.E2),  E3  => Sub_Sat(A.E3, B.E3),
              E12 => Sub_Sat(A.E12, B.E12), E23 => Sub_Sat(A.E23, B.E23), E31 => Sub_Sat(A.E31, B.E31),
              I   => Sub_Sat(A.I, B.I));
   end Sub;

   function Scale (A : Multivector; S : Fix16) return Multivector is
   begin
      return (S   => Mul_Sat(A.S, S),
              E1  => Mul_Sat(A.E1, S),  E2  => Mul_Sat(A.E2, S),  E3  => Mul_Sat(A.E3, S),
              E12 => Mul_Sat(A.E12, S), E23 => Mul_Sat(A.E23, S), E31 => Mul_Sat(A.E31, S),
              I   => Mul_Sat(A.I, S));
   end Scale;

   -------------------------------------------------------------------------
   -- Helpers for a correct Cl(3,0) geometric product
   -------------------------------------------------------------------------
   subtype Blade is Natural range 0 .. 7;
   type Coeffs is array (Blade) of Fix16;

   function To_Canon (M : Multivector) return Coeffs is
      C : Coeffs := (others => GD_Fixed.Zero);
   begin
      C(0) := M.S;
      C(1) := M.E1;
      C(2) := M.E2;
      C(4) := M.E3;
      C(3) := M.E12;
      C(6) := M.E23;
      C(5) := -M.E31;  -- e13 coeff (because e31 = -e13)
      C(7) := M.I;
      return C;
   end To_Canon;

   function From_Canon (C : Coeffs) return Multivector is
   begin
      return (S   => C(0),
              E1  => C(1),
              E2  => C(2),
              E3  => C(4),
              E12 => C(3),
              E23 => C(6),
              E31 => -C(5),    -- back to e31 basis
              I   => C(7));
   end From_Canon;

   function Count_Ones (X : Unsigned_8) return Natural is
      Y : Unsigned_8 := X;
      N : Natural := 0;
   begin
      while Y /= 0 loop
         Y := Y and (Y - 1);
         N := N + 1;
      end loop;
      return N;
   end Count_Ones;

   function GP_Negative (A_Mask, B_Mask : Blade) return Boolean is
      A   : Unsigned_8 := Unsigned_8(A_Mask);
      B   : Unsigned_8 := Unsigned_8(B_Mask);
      Neg : Boolean := False;
      Low : Unsigned_8;
   begin
      while A /= 0 loop
         Low := A and ((not A) + 1); 
         A := A xor Low;

         if (Count_Ones(B and (Low - 1)) mod 2) = 1 then
            Neg := not Neg;
         end if;
      end loop;
      return Neg;
   end GP_Negative;

   -------------------------------------------------------------------------
   -- Geometric Product (FULL, correct)
   -------------------------------------------------------------------------
   function Mul (A, B : Multivector) return Multivector is
      CA   : Coeffs := To_Canon(A);
      CB   : Coeffs := To_Canon(B);
      CR   : Coeffs := (others => GD_Fixed.Zero);
      Prod : Fix16;
      K    : Blade;
   begin
      for I in Blade loop
         if CA(I) /= GD_Fixed.Zero then
            for J in Blade loop
               if CB(J) /= GD_Fixed.Zero then
                  
                  -- [TITANIUM FIX] Explicit cast to Unsigned_8 for bitwise XOR
                  K := Blade(Unsigned_8(I) xor Unsigned_8(J));

                  Prod := Mul_Sat(CA(I), CB(J));
                  if GP_Negative(I, J) then
                     Prod := Sub_Sat(GD_Fixed.Zero, Prod);
                  end if;

                  CR(K) := Add_Sat(CR(K), Prod);
               end if;
            end loop;
         end if;
      end loop;

      return From_Canon(CR);
   end Mul;

   -------------------------------------------------------------------------
   -- Derived Products
   -------------------------------------------------------------------------
   function Wedge (A, B : Multivector) return Multivector is
      P : Multivector := Mul(A, B);
      R : Multivector := Zero;
   begin
      R.E12 := P.E12;
      R.E23 := P.E23;
      R.E31 := P.E31;
      R.I   := P.I; 
      return R;
   end Wedge;

   function Dot (A, B : Multivector) return Multivector is
      P : Multivector := Mul(A, B);
   begin
      return Scalar(P.S);
   end Dot;

   -------------------------------------------------------------------------
   -- Unary Operators
   -------------------------------------------------------------------------
   function Reverse_MV (A : Multivector) return Multivector is
      R : Multivector := A;
   begin
      R.E12 := -A.E12;
      R.E23 := -A.E23;
      R.E31 := -A.E31;
      R.I   := -A.I;
      return R;
   end Reverse_MV;

   function Magnitude_Sq (A : Multivector) return Fix16 is
      P : Multivector := Mul(A, Reverse_MV(A));
   begin
      return P.S;
   end Magnitude_Sq;

   function Inverse (A : Multivector) return Multivector is
      Mag : Fix16 := Magnitude_Sq(A);
      Rev : Multivector;
   begin
      if Mag <= Epsilon then return Zero; end if;
      Rev := Reverse_MV(A);
      return Scale(Rev, Div_Sat(One, Mag));
   end Inverse;

   -------------------------------------------------------------------------
   -- Verbs
   -------------------------------------------------------------------------
   function Rotor (Angle : Fix16; X, Y, Z : Fix16) return Multivector is
      Len_Sq : Fix16 := Add_Sat(Mul_Sat(X, X), Add_Sat(Mul_Sat(Y, Y), Mul_Sat(Z, Z)));
      Len    : Fix16 := Sqrt(Len_Sq);
      Inv    : Fix16;
      NX, NY, NZ : Fix16;
      Half_Angle : Fix16;
      S, C       : Fix16;
      R          : Multivector := Zero;
   begin
      if Len > GD_Fixed.Zero then
         Inv := Div_Sat(One, Len);
         NX := Mul_Sat(X, Inv); NY := Mul_Sat(Y, Inv); NZ := Mul_Sat(Z, Inv);
      else
         NX := GD_Fixed.Zero; NY := GD_Fixed.Zero; NZ := GD_Fixed.Zero;
      end if;

      Half_Angle := Mul_Sat(Angle, Half);
      GD_CORDIC.Sin_Cos(Half_Angle, S, C);

      R.S   := C;
      R.E23 := -Mul_Sat(S, NX); 
      R.E31 := -Mul_Sat(S, NY); 
      R.E12 := -Mul_Sat(S, NZ); 
      
      return R;
   end Rotor;

   function Rotate (V, R : Multivector) return Multivector is
      R_Rev : Multivector := Reverse_MV(R);
      Temp  : Multivector := Mul(R, V);
   begin
      return Mul(Temp, R_Rev);
   end Rotate;

end Geo_Algebra;