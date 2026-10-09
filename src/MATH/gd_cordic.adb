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

with Fixed_Sqrt; use Fixed_Sqrt;

package body GD_CORDIC is

   -- =========================================================
   -- THE CORDIC TABLE
   -- Pre-calculated values of arctan(2^-i) in radians.
   -- This is constant, deterministic data.
   -- =========================================================
   type Atan_Array is array (0 .. 15) of Fix16;
   Atan_Table : constant Atan_Array := (
      0 => 0.78539, -- atan(2^0)  = 45.0 deg
      1 => 0.46364, -- atan(2^-1) = 26.5 deg
      2 => 0.24497, -- atan(2^-2) = 14.0 deg
      3 => 0.12435, -- atan(2^-3) = 7.1  deg
      4 => 0.06241, -- atan(2^-4)
      5 => 0.03123, -- atan(2^-5)
      6 => 0.01562, -- atan(2^-6)
      7 => 0.00781, -- atan(2^-7)
      8 => 0.00390,
      9 => 0.00195,
      10 => 0.00097,
      11 => 0.00048,
      12 => 0.00024,
      13 => 0.00012,
      14 => 0.00006,
      15 => 0.00003
   );

   -- The "Gain" (K) Factor
   -- K = 0.607252935
   K_Factor : constant Fix16 := 0.60725;

   ------------------------------------------------------------
   -- Core CORDIC Algorithm (Rotation Mode)
   ------------------------------------------------------------
   procedure Sin_Cos (Angle   : in Fix16; 
                      Sin_Val : out Fix16; 
                      Cos_Val : out Fix16) 
   is
      Current_Angle : Fix16 := Angle;
      X, Y, Z       : Fix16;
      New_X, New_Y  : Fix16;
      Factor        : Fix16;
      
      -- Quadrant adjustment vars
      Quad_Adj      : Integer := 0;
   begin
      -- 1. Range Reduction (Bring Angle into -Pi/2 .. +Pi/2)
      while Current_Angle > Pi loop
         Current_Angle := Current_Angle - Two_Pi;
      end loop;
      while Current_Angle < -Pi loop
         Current_Angle := Current_Angle + Two_Pi;
      end loop;

      if Current_Angle > Half_Pi then
         Current_Angle := Current_Angle - Pi;
         Quad_Adj := 1; -- We are in Q2/Q3, flip signs later
      elsif Current_Angle < -Half_Pi then
         Current_Angle := Current_Angle + Pi;
         Quad_Adj := 1;
      end if;

      -- 2. Initialize Vector
      X := K_Factor; -- Start at (X=0.607, Y=0)
      Y := 0.0;
      Z := Current_Angle;
      Factor := 1.0; -- This represents 2^0

      -- 3. The CORDIC Loop
      for I in Atan_Array'Range loop
         
         if Z < 0.0 then
            -- Rotate Counter-Clockwise
            New_X := Add_Sat(X, Mul_Sat(Y, Factor));
            New_Y := Sub_Sat(Y, Mul_Sat(X, Factor));
            Z     := Add_Sat(Z, Atan_Table(I));
         else
            -- Rotate Clockwise
            New_X := Sub_Sat(X, Mul_Sat(Y, Factor));
            New_Y := Add_Sat(Y, Mul_Sat(X, Factor));
            Z     := Sub_Sat(Z, Atan_Table(I));
         end if;

         X := New_X;
         Y := New_Y;
         
         Factor := Factor * 0.5;
      end loop;

      -- 4. Final Output assignment
      if Quad_Adj = 1 then
         Sin_Val := -Y;
         Cos_Val := -X;
      else
         Sin_Val := Y;
         Cos_Val := X;
      end if;
   end Sin_Cos;

   ------------------------------------------------------------
   -- Vectoring Mode (ArcTan2)
   ------------------------------------------------------------
   function ArcTan2 (Y, X : Fix16) return Fix16 is
      -- We calculate using Q1 equivalence (Abs(X), Abs(Y)) then map back
      Abs_X : Fix16 := Abs_Sat(X);
      Abs_Y : Fix16 := Abs_Sat(Y);
      
      CX : Fix16 := Abs_X;
      CY : Fix16 := Abs_Y;
      CZ : Fix16 := 0.0;
      
      NX : Fix16;
      Factor : Fix16 := 1.0;
   begin
      if X = 0.0 and then Y = 0.0 then return 0.0; end if;

      -- CORDIC Vectoring loop (Drive Y to 0)
      for I in Atan_Array'Range loop
         
         if CY > 0.0 then
            -- Angle too high (positive Y in Q1), rotate CW (subtract angle)
            NX := Add_Sat(CX, Mul_Sat(CY, Factor));
            CY := Sub_Sat(CY, Mul_Sat(CX, Factor));
            CX := NX;
            CZ := Add_Sat(CZ, Atan_Table(I));
         else
            NX := Sub_Sat(CX, Mul_Sat(CY, Factor));
            CY := Add_Sat(CY, Mul_Sat(CX, Factor));
            CX := NX;
            CZ := Sub_Sat(CZ, Atan_Table(I));
         end if;
         
         Factor := Factor * 0.5;
      end loop;
      
      -- Quadrant Mapping
      if X >= 0.0 then
         if Y >= 0.0 then return CZ;           -- Q1
         else return -CZ;                      -- Q4
         end if;
      else
         if Y >= 0.0 then return Pi - CZ;      -- Q2
         else return -Pi + CZ;                 -- Q3
         end if;
      end if;
   end ArcTan2;

   ------------------------------------------------------------
   -- ArcCos
   ------------------------------------------------------------
   function ArcCos (Val : Fix16) return Fix16 is
      -- acos(x) = atan2(sqrt(1-x^2), x)
      One_Minus_Sq : Fix16 := Sub_Sat(1.0, Mul_Sat(Val, Val));
      Root : Fix16;
   begin
      if One_Minus_Sq <= 0.0 then
         if Val >= 0.0 then return 0.0; else return Pi; end if;
      end if;
      
      Root := Fixed_Sqrt.Sqrt(One_Minus_Sq);
      return ArcTan2(Root, Val);
   end ArcCos;

   ------------------------------------------------------------
   -- Convenience Wrappers
   ------------------------------------------------------------
   function Sin (Angle : Fix16) return Fix16 is
      S, C : Fix16;
   begin
      Sin_Cos(Angle, S, C);
      return S;
   end Sin;

   function Cos (Angle : Fix16) return Fix16 is
      S, C : Fix16;
   begin
      Sin_Cos(Angle, S, C);
      return C;
   end Cos;

end GD_CORDIC;