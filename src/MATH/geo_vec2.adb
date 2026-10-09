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

package body Geo_Vec2 is

   -------------------------------------------------------------------------
   -- Constructors
   -------------------------------------------------------------------------
   function Create (X, Y : Fix16) return Vec2 is
   begin
      return (X, Y);
   end Create;

   function Zero return Vec2 is
   begin
      return (GD_Fixed.Zero, GD_Fixed.Zero);
   end Zero;

   function One return Vec2 is
   begin
      return (GD_Fixed.One, GD_Fixed.One);
   end One;

   function Unit_X return Vec2 is
   begin
      return (GD_Fixed.One, GD_Fixed.Zero);
   end Unit_X;

   function Unit_Y return Vec2 is
   begin
      return (GD_Fixed.Zero, GD_Fixed.One);
   end Unit_Y;

   -------------------------------------------------------------------------
   -- Basic Arithmetic
   -------------------------------------------------------------------------
   function Add (A, B : Vec2) return Vec2 is
   begin
      return (Add_Sat(A.X, B.X), Add_Sat(A.Y, B.Y));
   end Add;

   function Sub (A, B : Vec2) return Vec2 is
   begin
      return (Sub_Sat(A.X, B.X), Sub_Sat(A.Y, B.Y));
   end Sub;

   function Scale (V : Vec2; S : Fix16) return Vec2 is
   begin
      return (Mul_Sat(V.X, S), Mul_Sat(V.Y, S));
   end Scale;

   function Negate (V : Vec2) return Vec2 is
   begin
      -- -X is 0 - X
      return (Sub_Sat(GD_Fixed.Zero, V.X), Sub_Sat(GD_Fixed.Zero, V.Y));
   end Negate;

   -------------------------------------------------------------------------
   -- Products
   -------------------------------------------------------------------------
   function Dot (A, B : Vec2) return Fix16 is
   begin
      return Add_Sat(Mul_Sat(A.X, B.X), Mul_Sat(A.Y, B.Y));
   end Dot;

   function Perp_Dot (A, B : Vec2) return Fix16 is
   begin
      return Sub_Sat(Mul_Sat(A.X, B.Y), Mul_Sat(A.Y, B.X));
   end Perp_Dot;

   -------------------------------------------------------------------------
   -- Metric Operations
   -------------------------------------------------------------------------
   function Length_Sq (V : Vec2) return Fix16 is
   begin
      return Add_Sat(Mul_Sat(V.X, V.X), Mul_Sat(V.Y, V.Y));
   end Length_Sq;

   function Length (V : Vec2) return Fix16 is
   begin
      return Sqrt(Length_Sq(V));
   end Length;

   function Distance_Sq (A, B : Vec2) return Fix16 is
      D : Vec2 := Sub(A, B);
   begin
      return Length_Sq(D);
   end Distance_Sq;

   function Distance (A, B : Vec2) return Fix16 is
   begin
      return Sqrt(Distance_Sq(A, B));
   end Distance;

   function Normalize (V : Vec2) return Vec2 is
      Len_Sq : Fix16 := Length_Sq(V);
      Len    : Fix16;
      Inv    : Fix16;
   begin
      if Len_Sq <= Epsilon then
         return Zero;
      end if;

      Len := Sqrt(Len_Sq);
      
      -- Safety check for extremely small length after sqrt (underflow protection)
      if Len <= Epsilon then
         return Zero;
      end if;

      Inv := Div_Sat(GD_Fixed.One, Len);
      return Scale(V, Inv);
   end Normalize;

   -------------------------------------------------------------------------
   -- Geometric Verbs
   -------------------------------------------------------------------------
   function Reflect (V, N : Vec2) return Vec2 is
      -- R = V - 2(V.N)N
      Dot_Val : Fix16 := Dot(V, N);
      Two_Dot : Fix16 := Mul_Sat(From_Int(2), Dot_Val);
      Sub_Vec : Vec2  := Scale(N, Two_Dot);
   begin
      return Sub(V, Sub_Vec);
   end Reflect;

   function Project (V, N : Vec2) return Vec2 is
      -- P = (V.N)N
      Dot_Val : Fix16 := Dot(V, N);
   begin
      return Scale(N, Dot_Val);
   end Project;

   function Oriented_Area (A, B, C : Vec2) return Fix16 is
      AB : Vec2 := Sub(B, A);
      AC : Vec2 := Sub(C, A);
   begin
      -- 2D Cross Product of (B-A) and (C-A)
      return Perp_Dot(AB, AC);
   end Oriented_Area;

end Geo_Vec2;