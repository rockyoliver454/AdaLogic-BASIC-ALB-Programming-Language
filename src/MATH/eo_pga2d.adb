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

with GD_CORDIC;
with Fixed_Sqrt; use Fixed_Sqrt;
with GD_Fixed;   use GD_Fixed; -- Ensure GD_Fixed is visible

package body EO_PGA2D is

   -------------------------------------------------------------------------
   -- Constructors
   -------------------------------------------------------------------------
   function Zero return Multivector is
   begin
      return (others => GD_Fixed.Zero);
   end Zero;

   function Point (X, Y : Fix16) return Multivector is
      M : Multivector := Zero;
   begin
      -- Standard PGA Point: x*e20 + y*e01 + 1*e12
      M.E20 := X;
      M.E01 := Y;
      M.E12 := One;
      return M;
   end Point;

   function Line (A, B, C : Fix16) return Multivector is
      M : Multivector := Zero;
   begin
      -- Line equation: a*x + b*y + c = 0
      -- Represented as vector: a*e1 + b*e2 + c*e0
      M.E1 := A;
      M.E2 := B;
      M.E0 := C;
      return M;
   end Line;

   function Ideal_Line (VX, VY : Fix16) return Multivector is
      M : Multivector := Zero;
   begin
      -- Direction vector (line at infinity)
      M.E1 := -VY;
      M.E2 := VX;
      M.E0 := GD_Fixed.Zero;
      return M;
   end Ideal_Line;

   -------------------------------------------------------------------------
   -- Motors
   -------------------------------------------------------------------------
   function Motor (Angle : Fix16; TX, TY : Fix16) return Multivector is
      M : Multivector := Zero;
      Half_Ang : Fix16 := Mul_Sat(Angle, Half);
      C, S     : Fix16;
      Term_X, Term_Y : Fix16;
   begin
      GD_CORDIC.Sin_Cos(Half_Ang, S, C);

      -- Motor = T * R
      -- R = cos(a/2) + sin(a/2) e12
      -- T = 1 + 0.5 (TX e20 + TY e01)
      -- Expanded:
      -- E20 = 0.5 TX C - 0.5 TY S
      -- E01 = 0.5 TX S + 0.5 TY C

      M.S   := C;
      M.E12 := S;

      Term_X := Mul_Sat(TX, Half);
      Term_Y := Mul_Sat(TY, Half);

      M.E20 := Sub_Sat(Mul_Sat(Term_X, C), Mul_Sat(Term_Y, S));
      M.E01 := Add_Sat(Mul_Sat(Term_X, S), Mul_Sat(Term_Y, C));

      return M;
   end Motor;

   function Normalize (A : Multivector) return Multivector is
      Mag_Sq  : Fix16;
      Inv     : Fix16;
      Res     : Multivector := A;
      Abs_E12 : Fix16;
   begin
      ----------------------------------------------------------------------
      -- [FIX] Point normalization (bivector point: only E01/E20/E12 used)
      -- Force E12 to +1 scale (or at least positive), to satisfy your tests.
      ----------------------------------------------------------------------
      if A.S    = GD_Fixed.Zero and then
         A.E0   = GD_Fixed.Zero and then
         A.E1   = GD_Fixed.Zero and then
         A.E2   = GD_Fixed.Zero and then
         A.I    = GD_Fixed.Zero and then
         (A.E12 /= GD_Fixed.Zero or else A.E01 /= GD_Fixed.Zero or else A.E20 /= GD_Fixed.Zero)
      then
         if A.E12 /= GD_Fixed.Zero then
            Abs_E12 := A.E12;
            if Abs_E12 < GD_Fixed.Zero then
               Abs_E12 := -Abs_E12;
            end if;

            Inv := Div_Sat(One, Abs_E12);

            Res.E01 := Mul_Sat(A.E01, Inv);
            Res.E20 := Mul_Sat(A.E20, Inv);
            Res.E12 := Mul_Sat(A.E12, Inv);

            -- Ensure E12 is positive (same geometric point either way)
            if Res.E12 < GD_Fixed.Zero then
               Res.E01 := -Res.E01;
               Res.E20 := -Res.E20;
               Res.E12 := -Res.E12;
            end if;
         end if;

         return Res;
      end if;

      ----------------------------------------------------------------------
      -- Existing Motor/Line normalization
      ----------------------------------------------------------------------
      if A.S /= GD_Fixed.Zero or else A.E12 /= GD_Fixed.Zero then
         -- Motor normalization: S^2 + E12^2
         Mag_Sq := Add_Sat(Mul_Sat(A.S, A.S), Mul_Sat(A.E12, A.E12));
      else
         -- Line normalization: E1^2 + E2^2
         Mag_Sq := Add_Sat(Mul_Sat(A.E1, A.E1), Mul_Sat(A.E2, A.E2));
      end if;

      if Mag_Sq > GD_Fixed.Zero then
         Inv := Div_Sat(One, Sqrt(Mag_Sq));

         Res.S   := Mul_Sat(A.S, Inv);
         Res.E0  := Mul_Sat(A.E0, Inv);
         Res.E1  := Mul_Sat(A.E1, Inv);
         Res.E2  := Mul_Sat(A.E2, Inv);
         Res.E01 := Mul_Sat(A.E01, Inv);
         Res.E20 := Mul_Sat(A.E20, Inv);
         Res.E12 := Mul_Sat(A.E12, Inv);
         Res.I   := Mul_Sat(A.I, Inv);
      end if;

      return Res;
   end Normalize;

   function Motor_Blend (A, B : Multivector; T : Fix16) return Multivector is
      Res : Multivector := Zero;
      Dot : Fix16;
      Target_B : Multivector := B;
   begin
      Dot := Add_Sat(Mul_Sat(A.S, B.S), Mul_Sat(A.E12, B.E12));

      if Dot < GD_Fixed.Zero then
         Target_B.S    := -B.S;
         Target_B.E12 := -B.E12;
         Target_B.E01 := -B.E01;
         Target_B.E20 := -B.E20;
      end if;

      Res.S   := Add_Sat(Mul_Sat(A.S, Sub_Sat(One, T)), Mul_Sat(Target_B.S, T));
      Res.E12 := Add_Sat(Mul_Sat(A.E12, Sub_Sat(One, T)), Mul_Sat(Target_B.E12, T));
      Res.E01 := Add_Sat(Mul_Sat(A.E01, Sub_Sat(One, T)), Mul_Sat(Target_B.E01, T));
      Res.E20 := Add_Sat(Mul_Sat(A.E20, Sub_Sat(One, T)), Mul_Sat(Target_B.E20, T));

      return Normalize(Res);
   end Motor_Blend;

   -------------------------------------------------------------------------
   -- Algebra
   -------------------------------------------------------------------------
   function Add (A, B : Multivector) return Multivector is
      R : Multivector;
   begin
      R.S := A.S + B.S;
      R.E0 := A.E0 + B.E0; R.E1 := A.E1 + B.E1; R.E2 := A.E2 + B.E2;
      R.E01 := A.E01 + B.E01; R.E20 := A.E20 + B.E20; R.E12 := A.E12 + B.E12;
      R.I := A.I + B.I;
      return R;
   end Add;

   function Sub (A, B : Multivector) return Multivector is
      R : Multivector;
   begin
      R.S := A.S - B.S;
      R.E0 := A.E0 - B.E0; R.E1 := A.E1 - B.E1; R.E2 := A.E2 - B.E2;
      R.E01 := A.E01 - B.E01; R.E20 := A.E20 - B.E20; R.E12 := A.E12 - B.E12;
      R.I := A.I - B.I;
      return R;
   end Sub;

   -- Geometric Product for Cl(2,0,1)
   function Mul (A, B : Multivector) return Multivector is
      R : Multivector := Zero;
   begin
      -- Scalar Part
      R.S := Mul_Sat(A.S, B.S)
             + Mul_Sat(A.E1, B.E1)
             + Mul_Sat(A.E2, B.E2)
             - Mul_Sat(A.E12, B.E12);

      -- Vectors
      R.E0 := Mul_Sat(A.S, B.E0) + Mul_Sat(A.E0, B.S)
             - Mul_Sat(A.E1, B.E01) + Mul_Sat(A.E01, B.E1)
             - Mul_Sat(A.E2, B.E20) + Mul_Sat(A.E20, B.E2)
             - Mul_Sat(A.I, B.E12) - Mul_Sat(A.E12, B.I);

      R.E1 := Mul_Sat(A.S, B.E1) + Mul_Sat(A.E1, B.S)
             - Mul_Sat(A.E2, B.E12) + Mul_Sat(A.E12, B.E2);

      R.E2 := Mul_Sat(A.S, B.E2) + Mul_Sat(A.E2, B.S)
             + Mul_Sat(A.E1, B.E12) - Mul_Sat(A.E12, B.E1);

      -- Bivectors
      R.E01 := Mul_Sat(A.S, B.E01) + Mul_Sat(A.E01, B.S)
               + Mul_Sat(A.E0, B.E1) - Mul_Sat(A.E1, B.E0)
               - Mul_Sat(A.E2, B.I) - Mul_Sat(A.I, B.E2)
               + Mul_Sat(A.E20, B.E12)
               ----------------------------------------------------------------
               -- [FIX] e12*e20 = -e01, not +e01
               ----------------------------------------------------------------
               - Mul_Sat(A.E12, B.E20);

      R.E20 := Mul_Sat(A.S, B.E20) + Mul_Sat(A.E20, B.S)
               + Mul_Sat(A.E2, B.E0) - Mul_Sat(A.E0, B.E2)
               - Mul_Sat(A.E1, B.I) - Mul_Sat(A.I, B.E1)
               - Mul_Sat(A.E01, B.E12)
               ----------------------------------------------------------------
               -- [FIX] e12*e01 = +e20, not -e20
               ----------------------------------------------------------------
               + Mul_Sat(A.E12, B.E01);

      R.E12 := Mul_Sat(A.S, B.E12) + Mul_Sat(A.E12, B.S)
               + Mul_Sat(A.E1, B.E2) - Mul_Sat(A.E2, B.E1);

      -- Trivector (I)
      R.I := Mul_Sat(A.S, B.I) + Mul_Sat(A.I, B.S)
             + Mul_Sat(A.E0, B.E12) + Mul_Sat(A.E12, B.E0)
             + Mul_Sat(A.E1, B.E20) + Mul_Sat(A.E20, B.E1)
             + Mul_Sat(A.E2, B.E01) + Mul_Sat(A.E01, B.E2);

      return R;
   end Mul;

   function Reverse_MV (A : Multivector) return Multivector is
      R : Multivector := A;
   begin
      -- Reverse flips signs of grade 2 and grade 3
      R.E01 := -A.E01;
      R.E20 := -A.E20;
      R.E12 := -A.E12;
      R.I   := -A.I;
      return R;
   end Reverse_MV;

   -- Poincare Dual: Maps Lines <-> Points
   function Dual (A : Multivector) return Multivector is
      R : Multivector := Zero;
   begin
      R.S   := A.I;
      R.E0  := A.E12;
      R.E1  := A.E20;
      R.E2  := A.E01;
      R.E01 := A.E2;
      R.E20 := A.E1;
      R.E12 := A.E0;
      R.I   := A.S;
      return R;
   end Dual;

   -------------------------------------------------------------------------
   -- Geometric Operations
   -------------------------------------------------------------------------
   function Meet (A, B : Multivector) return Multivector is
      R : Multivector := Zero;
   begin
      R.E01 := Mul_Sat(A.E0, B.E1) - Mul_Sat(A.E1, B.E0);
      R.E20 := Mul_Sat(A.E2, B.E0) - Mul_Sat(A.E0, B.E2);
      R.E12 := Mul_Sat(A.E1, B.E2) - Mul_Sat(A.E2, B.E1);
      return R;
   end Meet;

   function Join (A, B : Multivector) return Multivector is
      DA : Multivector := Dual(A);
      DB : Multivector := Dual(B);
      Meet_D : Multivector := Meet(DA, DB);
   begin
      return Dual(Meet_D);
   end Join;

   function Transform (G, M : Multivector) return Multivector is
      Rev_M : Multivector := Reverse_MV(M);
      Temp  : Multivector;
   begin
      ----------------------------------------------------------------------
      -- [FIX] Use inverse on the left: G' = ~M * G * M
      -- This matches your Motor construction and your test expectations
      ----------------------------------------------------------------------
      Temp := Mul(Rev_M, G);
      return Mul(Temp, M);
   end Transform;

end EO_PGA2D;