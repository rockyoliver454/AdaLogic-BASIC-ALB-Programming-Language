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

package Geo_Mass is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Center of Mass
   -------------------------------------------------------------------------
   -- Computes the centroid (geometric center) of a set of points.
   -- Assumes uniform density/mass per point.
   type Point_Array is array (Integer range <>) of Vec2;
   function Centroid (Points : Point_Array) return Vec2;

   -- Computes the weighted center of mass.
   -- Mass * Pos sum / Total Mass.
   function Center_Of_Mass (P1 : Vec2; M1 : Fix16; P2 : Vec2; M2 : Fix16) return Vec2;

   -------------------------------------------------------------------------
   -- Moment of Inertia (Scalar I)
   -------------------------------------------------------------------------
   -- Moment of Inertia for a solid box (around center).
   -- I = m * (w^2 + h^2) / 12
   function Moment_Box (Mass, Width, Height : Fix16) return Fix16;

   -- Moment of Inertia for a solid circle/disk.
   -- I = 0.5 * m * r^2
   function Moment_Circle (Mass, Radius : Fix16) return Fix16;

   -- Moment of Inertia for a thin rod (length L) around center.
   -- I = m * L^2 / 12
   function Moment_Rod (Mass, Length : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- Theorems
   -------------------------------------------------------------------------
   -- Parallel Axis Theorem.
   -- Calculates inertia around a new axis offset by Dist from CM.
   -- I_new = I_cm + m * d^2
   function Parallel_Axis (I_CM : Fix16; Mass, Dist : Fix16) return Fix16;

end Geo_Mass;