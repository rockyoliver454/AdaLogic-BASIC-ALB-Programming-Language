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

package Geo_Voronoi is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Geometric Predicates
   -------------------------------------------------------------------------
   -- Returns the center of the circle passing through A, B, C.
   -- Returns A if points are collinear (degenerate).
   function Circumcenter (A, B, C : Vec2) return Vec2;

   -- Returns True if Point P is inside the circumcircle of Triangle ABC.
   -- A, B, C must be in counter-clockwise order.
   -- Essential for Delaunay flip algorithm.
   function In_Circle (A, B, C, P : Vec2) return Boolean;

   -- Returns > 0 if C is to the left of AB, < 0 if right, 0 if collinear.
   -- (Robust orientation test).
   function Orient_2D (A, B, C : Vec2) return Fix16;

   -------------------------------------------------------------------------
   -- Voronoi Helpers
   -------------------------------------------------------------------------
   -- Returns the bisector line of A and B (Point + Direction).
   -- Point is the midpoint. Direction is orthogonal to AB.
   procedure Get_Bisector (A, B : Vec2; Origin, Dir : out Vec2);

end Geo_Voronoi;