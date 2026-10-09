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

package body Geo_Metric is

   -------------------------------------------------------------------------
   -- Norms
   -------------------------------------------------------------------------
   function Norm_Manhattan (V : Vec2) return Fix16 is
   begin
      return Add_Sat(Abs_Sat(V.X), Abs_Sat(V.Y));
   end Norm_Manhattan;

   function Norm_Chebyshev (V : Vec2) return Fix16 is
      AX : Fix16 := Abs_Sat(V.X);
      AY : Fix16 := Abs_Sat(V.Y);
   begin
      if AX > AY then
         return AX;
      else
         return AY;
      end if;
   end Norm_Chebyshev;

   -------------------------------------------------------------------------
   -- Distance Functions
   -------------------------------------------------------------------------
   function Dist_Manhattan (A, B : Vec2) return Fix16 is
      D : Vec2 := Sub(A, B);
   begin
      return Norm_Manhattan(D);
   end Dist_Manhattan;

   function Dist_Chebyshev (A, B : Vec2) return Fix16 is
      D : Vec2 := Sub(A, B);
   begin
      return Norm_Chebyshev(D);
   end Dist_Chebyshev;

   -------------------------------------------------------------------------
   -- Metric Operations
   -------------------------------------------------------------------------
   function Clamp_Length (V : Vec2; Max_Len : Fix16) return Vec2 is
      Len_Sq : Fix16 := Length_Sq(V);
      Max_Sq : Fix16 := Mul_Sat(Max_Len, Max_Len);
   begin
      -- Optimization: Avoid Sqrt if already within limits
      if Len_Sq <= Max_Sq then
         return V;
      end if;

      return Scale(Normalize(V), Max_Len);
   end Clamp_Length;

   function Lerp (A, B : Vec2; T : Fix16) return Vec2 is
      Diff   : Vec2 := Sub(B, A);
      Scaled : Vec2 := Scale(Diff, T);
   begin
      return Add(A, Scaled);
   end Lerp;

   function Move_Towards (Current, Target : Vec2; Max_Dist : Fix16) return Vec2 is
      Diff    : Vec2 := Sub(Target, Current);
      Len     : Fix16 := Length(Diff);
      Inv_Len : Fix16;
   begin
      if Len <= Max_Dist or else Len <= Epsilon then
         return Target;
      end if;
      
      -- [TITANIUM FIX] Explicitly use GD_Fixed.One to resolve ambiguity
      Inv_Len := Div_Sat(GD_Fixed.One, Len);
      
      return Add(Current, Scale(Diff, Mul_Sat(Inv_Len, Max_Dist)));
   end Move_Towards;

end Geo_Metric;