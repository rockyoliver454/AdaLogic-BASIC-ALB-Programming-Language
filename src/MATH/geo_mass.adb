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

package body Geo_Mass is

   function Centroid (Points : Point_Array) return Vec2 is
      Sum : Vec2 := Geo_Vec2.Zero;
      Count_Inv : Fix16;
   begin
      if Points'Length = 0 then return Geo_Vec2.Zero; end if;

      for I in Points'Range loop
         Sum := Add(Sum, Points(I));
      end loop;

      -- [TITANIUM FIX] Explicit GD_Fixed.One
      Count_Inv := Div_Sat(GD_Fixed.One, From_Int(Points'Length));
      return Scale(Sum, Count_Inv);
   end Centroid;

   function Center_Of_Mass (P1 : Vec2; M1 : Fix16; P2 : Vec2; M2 : Fix16) return Vec2 is
      Total_Mass : Fix16 := Add_Sat(M1, M2);
      Inv_Mass   : Fix16;
      Sum        : Vec2;
   begin
      if Total_Mass <= Epsilon then return Geo_Vec2.Zero; end if;
      
      -- [TITANIUM FIX] Explicit GD_Fixed.One
      Inv_Mass := Div_Sat(GD_Fixed.One, Total_Mass);
      Sum := Add(Scale(P1, M1), Scale(P2, M2));
      return Scale(Sum, Inv_Mass);
   end Center_Of_Mass;

   function Moment_Box (Mass, Width, Height : Fix16) return Fix16 is
      W2 : Fix16 := Mul_Sat(Width, Width);
      H2 : Fix16 := Mul_Sat(Height, Height);
      Sum : Fix16 := Add_Sat(W2, H2);
      Num : Fix16 := Mul_Sat(Mass, Sum);
      Denom : Fix16 := From_Int(12);
   begin
      return Div_Sat(Num, Denom);
   end Moment_Box;

   function Moment_Circle (Mass, Radius : Fix16) return Fix16 is
      R2 : Fix16 := Mul_Sat(Radius, Radius);
      Num : Fix16 := Mul_Sat(Mass, R2);
   begin
      return Mul_Sat(Num, Half);
   end Moment_Circle;

   function Moment_Rod (Mass, Length : Fix16) return Fix16 is
      L2 : Fix16 := Mul_Sat(Length, Length);
      Num : Fix16 := Mul_Sat(Mass, L2);
      Denom : Fix16 := From_Int(12);
   begin
      return Div_Sat(Num, Denom);
   end Moment_Rod;

   function Parallel_Axis (I_CM : Fix16; Mass, Dist : Fix16) return Fix16 is
      D2 : Fix16 := Mul_Sat(Dist, Dist);
      Term : Fix16 := Mul_Sat(Mass, D2);
   begin
      return Add_Sat(I_CM, Term);
   end Parallel_Axis;

end Geo_Mass;