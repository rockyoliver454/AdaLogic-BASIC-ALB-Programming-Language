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

package Geo_Convex is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Shapes (Implicit Definition)
   -------------------------------------------------------------------------
   type Shape_Type is (Circle, Rectangle, Point);

   type Convex_Shape (Kind : Shape_Type := Circle) is record
      Center : Vec2;
      case Kind is
         when Circle    => Radius : Fix16;
         when Rectangle => Extent : Vec2; -- Half-width, Half-height
         when Point     => null;
      end case;
   end record;

   -------------------------------------------------------------------------
   -- Support Functions
   -------------------------------------------------------------------------
   -- Returns the point on the shape furthest in the given Direction.
   function Get_Support (S : Convex_Shape; Dir : Vec2) return Vec2;

   -------------------------------------------------------------------------
   -- GJK Intersection
   -------------------------------------------------------------------------
   -- Returns True if Shape A and Shape B overlap.
   -- Uses iterative simplex evolution (Max 20 iterations).
   function GJK_Intersect (A, B : Convex_Shape) return Boolean;

end Geo_Convex;