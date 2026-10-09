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

package Geo_Curves is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Hermite Spline
   -------------------------------------------------------------------------
   -- Interpolates between P0 and P1 with tangents T0 and T1.
   -- t: [0.0, 1.0]
   -- Formula: (2t^3 - 3t^2 + 1)P0 + (t^3 - 2t^2 + t)T0 + (-2t^3 + 3t^2)P1 + (t^3 - t^2)T1
   function Hermite_Eval (P0, T0, P1, T1 : Vec2; T : Fix16) return Vec2;

   -------------------------------------------------------------------------
   -- Catmull-Rom Spline
   -------------------------------------------------------------------------
   -- Interpolates between P1 and P2, using P0 and P3 to calculate tangents.
   -- P0 -> [P1 -> P2] -> P3
   -- t: [0.0, 1.0] representing position between P1 and P2.
   -- Implements the "Uniform" parameterization (Alpha = 0).
   function Catmull_Eval (P0, P1, P2, P3 : Vec2; T : Fix16) return Vec2;

   -------------------------------------------------------------------------
   -- Derivatives & Curvature
   -------------------------------------------------------------------------
   -- Calculates the first derivative (Velocity) of a Catmull-Rom spline at t.
   function Catmull_Velocity (P0, P1, P2, P3 : Vec2; T : Fix16) return Vec2;

   -- Calculates the second derivative (Acceleration) of a Catmull-Rom spline at t.
   function Catmull_Acceleration (P0, P1, P2, P3 : Vec2; T : Fix16) return Vec2;

   -- Calculates signed curvature (k) at t.
   -- k = (x'y'' - y'x'') / (x'^2 + y'^2)^(3/2)
   -- Positive k = Left Turn, Negative k = Right Turn.
   function Catmull_Curvature (P0, P1, P2, P3 : Vec2; T : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- Arc-Length Utilities
   -------------------------------------------------------------------------
   -- Approximates the total length of the curve segment (P1->P2) using subdivision.
   -- Segments: Number of linear steps to measure (e.g., 10). Higher = More precision.
   function Catmull_Arc_Length (P0, P1, P2, P3 : Vec2; Segments : Integer := 10) return Fix16;

   -- Solves for the 't' value that corresponds to a specific distance along the curve.
   -- Target_Dist: Distance from P1 along the curve.
   -- Uses iterative approximation. Returns -1.0 if Target_Dist is out of range.
   function Catmull_Solve_T (P0, P1, P2, P3 : Vec2; Target_Dist : Fix16; Tolerance : Fix16) return Fix16;

end Geo_Curves;