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

with GD_Fixed; use GD_Fixed;
with Geo_Vec2; use Geo_Vec2;

package Geo_Metric is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Norms (Magnitude definitions)
   -------------------------------------------------------------------------
   -- L1 Norm: |x| + |y| (Grid movement cost)
   function Norm_Manhattan (V : Vec2) return Fix16;
   
   -- L-Infinity Norm: Max(|x|, |y|) (Chebyshev cost)
   function Norm_Chebyshev (V : Vec2) return Fix16;
   
   -- (Note: L2 Norm (Euclidean) is Geo_Vec2.Length)

   -------------------------------------------------------------------------
   -- Distance Functions
   -------------------------------------------------------------------------
   -- |dx| + |dy|
   function Dist_Manhattan (A, B : Vec2) return Fix16;
   
   -- Max(|dx|, |dy|)
   function Dist_Chebyshev (A, B : Vec2) return Fix16;
   
   -- (Note: Euclidean Distance is Geo_Vec2.Distance)

   -------------------------------------------------------------------------
   -- Metric Operations
   -------------------------------------------------------------------------
   -- Limits the magnitude of V to Max_Len.
   -- If |V| <= Max_Len, returns V.
   -- Otherwise, returns Normalize(V) * Max_Len.
   function Clamp_Length (V : Vec2; Max_Len : Fix16) return Vec2;

   -- Linear Interpolation: A + (B - A) * T
   -- Clamps T to [0.0, 1.0] implicitly via scalar logic if needed, 
   -- but raw Lerp usually trusts the caller or clamps T explicitly.
   -- We will implement standard unbounded Lerp for flexibility.
   function Lerp (A, B : Vec2; T : Fix16) return Vec2;

   -- Moves Current towards Target by at most Max_Dist distance.
   -- Essential for smooth camera tracking and AI movement.
   function Move_Towards (Current, Target : Vec2; Max_Dist : Fix16) return Vec2;

end Geo_Metric;