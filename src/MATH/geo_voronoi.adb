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

package body Geo_Voronoi is

   function Orient_2D (A, B, C : Vec2) return Fix16 is
   begin
      -- (B.x - A.x)(C.y - A.y) - (B.y - A.y)(C.x - A.x)
      return Sub_Sat(
         Mul_Sat(Sub_Sat(B.X, A.X), Sub_Sat(C.Y, A.Y)),
         Mul_Sat(Sub_Sat(B.Y, A.Y), Sub_Sat(C.X, A.X))
      );
   end Orient_2D;

   function Circumcenter (A, B, C : Vec2) return Vec2 is
      D : Fix16;
      UX, UY : Fix16;
      A_LenSq, B_LenSq, C_LenSq : Fix16;
      Result : Vec2;
      Inv_D : Fix16;
   begin
      -- D = 2 * (Ax(By - Cy) + Bx(Cy - Ay) + Cx(Ay - By))
      D := Mul_Sat(From_Int(2), Orient_2D(A, B, C));

      if Abs_Sat(D) <= Epsilon then
         return A; -- Collinear, undefined circumcenter
      end if;

      A_LenSq := Length_Sq(A);
      B_LenSq := Length_Sq(B);
      C_LenSq := Length_Sq(C);

      UX := Add_Sat(Mul_Sat(A_LenSq, Sub_Sat(B.Y, C.Y)), 
            Add_Sat(Mul_Sat(B_LenSq, Sub_Sat(C.Y, A.Y)), 
                    Mul_Sat(C_LenSq, Sub_Sat(A.Y, B.Y))));

      UY := Add_Sat(Mul_Sat(A_LenSq, Sub_Sat(C.X, B.X)), 
            Add_Sat(Mul_Sat(B_LenSq, Sub_Sat(A.X, C.X)), 
                    Mul_Sat(C_LenSq, Sub_Sat(B.X, A.X))));

      -- [TITANIUM FIX] Explicit GD_Fixed.One
      Inv_D := Div_Sat(GD_Fixed.One, D);
      
      Result.X := Mul_Sat(UX, Inv_D);
      Result.Y := Mul_Sat(UY, Inv_D);
      return Result;
   end Circumcenter;

   function In_Circle (A, B, C, P : Vec2) return Boolean is
      Center : Vec2 := Circumcenter(A, B, C);
      R_Sq   : Fix16 := Distance_Sq(Center, A);
      Dist_Sq: Fix16 := Distance_Sq(Center, P);
   begin
      -- If distance to P is less than Radius, it's inside.
      return Dist_Sq < Sub_Sat(R_Sq, Epsilon);
   end In_Circle;

   procedure Get_Bisector (A, B : Vec2; Origin, Dir : out Vec2) is
      Mid : Vec2;
      Diff : Vec2;
   begin
      -- Midpoint
      Mid := Scale(Add(A, B), Half);
      Origin := Mid;
      
      -- Direction: Rotate AB 90 degrees
      Diff := Sub(B, A);
      
      -- [TITANIUM FIX] Use scalar negation -Diff.Y
      Dir  := Create(-Diff.Y, Diff.X); -- (-y, x)
      Dir  := Normalize(Dir);
   end Get_Bisector;

end Geo_Voronoi;