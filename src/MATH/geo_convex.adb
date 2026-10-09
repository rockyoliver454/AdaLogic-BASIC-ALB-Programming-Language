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

package body Geo_Convex is

   -------------------------------------------------------------------------
   -- Support Functions
   -------------------------------------------------------------------------
   function Get_Support (S : Convex_Shape; Dir : Vec2) return Vec2 is
      Norm_Dir : Vec2;
   begin
      case S.Kind is
         when Point =>
            return S.Center;
            
         when Circle =>
            -- Center + Radius * Normalized(Dir)
            Norm_Dir := Normalize(Dir);
            return Add(S.Center, Scale(Norm_Dir, S.Radius));
            
         when Rectangle =>
            -- Sign of Dir components determines corner
            declare
               Corner : Vec2;
            begin
               if Dir.X >= GD_Fixed.Zero then Corner.X := S.Extent.X;
               else Corner.X := -S.Extent.X;
               end if;
               
               if Dir.Y >= GD_Fixed.Zero then Corner.Y := S.Extent.Y;
               else Corner.Y := -S.Extent.Y;
               end if;
               
               return Add(S.Center, Corner);
            end;
      end case;
   end Get_Support;

   -------------------------------------------------------------------------
   -- GJK Logic
   -------------------------------------------------------------------------
   -- Minkowski Difference Support
   function Support_Diff (A, B : Convex_Shape; Dir : Vec2) return Vec2 is
      Sup_A : Vec2 := Get_Support(A, Dir);
      Sup_B : Vec2 := Get_Support(B, Negate(Dir)); -- Geo_Vec2.Negate(Vec2) is correct here
   begin
      return Sub(Sup_A, Sup_B);
   end Support_Diff;

   -- Main Loop
   function GJK_Intersect (A, B : Convex_Shape) return Boolean is
      Simplex_A, Simplex_B, Simplex_C : Vec2;
      Count : Integer := 0;
      -- [TITANIUM FIX] Explicit GD_Fixed.One
      Dir   : Vec2 := Create(GD_Fixed.One, GD_Fixed.Zero); 
      New_Pt : Vec2;
      
      -- Helper: Cross Product Z magnitude
      function Cross_Z (U, V : Vec2) return Fix16 is
      begin
         return Sub_Sat(Mul_Sat(U.X, V.Y), Mul_Sat(U.Y, V.X));
      end Cross_Z;
      
      -- Helper: Triple Product (A x B) x A
      function Triple_Prod (U, V : Vec2) return Vec2 is
         Z : Fix16 := Cross_Z(U, V);
      begin
         -- [TITANIUM FIX] Use scalar negation (-U.Y) instead of Negate(U.Y)
         return Create(Mul_Sat(-U.Y, Z), Mul_Sat(U.X, Z));
      end Triple_Prod;

      AB, AC, AO : Vec2;
      
   begin
      -- 1. Initial Point
      New_Pt := Support_Diff(A, B, Dir);
      Simplex_A := New_Pt;
      Count := 1;
      
      -- Search towards origin
      Dir := Negate(Simplex_A);

      for Iter in 1 .. 20 loop
         -- 2. Get new point in direction of origin
         New_Pt := Support_Diff(A, B, Dir);
         
         -- If new point is not past the origin along Dir, we can't enclose origin
         if Dot(New_Pt, Dir) < GD_Fixed.Zero then
            return False;
         end if;
         
         -- Add to Simplex
         Count := Count + 1;
         if Count = 2 then
            Simplex_B := Simplex_A;
            Simplex_A := New_Pt;
         elsif Count = 3 then
            Simplex_C := Simplex_B;
            Simplex_B := Simplex_A;
            Simplex_A := New_Pt;
         end if;
         
         -- 3. Simplex Processing
         if Count = 2 then
            -- Line Segment AB
            AB := Sub(Simplex_B, Simplex_A);
            AO := Negate(Simplex_A);
            
            if Cross_Z(AB, AO) > GD_Fixed.Zero then
               -- Left side
               -- [TITANIUM FIX] Scalar negation
               Dir := Create(-AB.Y, AB.X);
            else
               -- Right side
               Dir := Create(AB.Y, -AB.X);
            end if;
            
         elsif Count = 3 then
            -- Triangle ABC
            AB := Sub(Simplex_B, Simplex_A);
            AC := Sub(Simplex_C, Simplex_A);
            AO := Negate(Simplex_A);
            
            -- Dir perp to AB
            -- [TITANIUM FIX] Scalar negation
            Dir := Create(-AB.Y, AB.X);
            if Dot(Dir, AC) > GD_Fixed.Zero then
               Dir := Negate(Dir); -- Vector negation
            end if;
            
            if Dot(Dir, AO) > GD_Fixed.Zero then
               -- Origin is outside AB
               Simplex_C := Simplex_A; 
               Count := 2;
            else
               -- Check AC
               -- [TITANIUM FIX] Scalar negation
               Dir := Create(-AC.Y, AC.X);
               if Dot(Dir, AB) > GD_Fixed.Zero then
                  Dir := Negate(Dir);
               end if;
               
               if Dot(Dir, AO) > GD_Fixed.Zero then
                  -- Origin outside AC
                  Simplex_B := Simplex_C; 
                  Count := 2;
               else
                  return True;
               end if;
            end if;
         end if;
      end loop;

      return False;
   end GJK_Intersect;

end Geo_Convex;