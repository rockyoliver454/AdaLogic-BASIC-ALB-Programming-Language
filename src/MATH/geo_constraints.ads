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

package Geo_Constraints is
   pragma Pure;

   type Constraint_Result is record
      Correction_A : Vec2; -- Vector to add to Point A
      Correction_B : Vec2; -- Vector to add to Point B
   end record;

   -------------------------------------------------------------------------
   -- Distance Constraints
   -------------------------------------------------------------------------
   -- Ensures distance between A and B is exactly Target_Dist.
   -- Returns corrections weighted by inverse masses (Inv_Mass_A, Inv_Mass_B).
   -- Use Inv_Mass = 0 for static objects.
   function Solve_Distance (Pos_A, Pos_B : Vec2; 
                            Inv_Mass_A, Inv_Mass_B : Fix16; 
                            Target_Dist : Fix16) return Constraint_Result;

   -------------------------------------------------------------------------
   -- Angle / Joint Constraints
   -------------------------------------------------------------------------
   -- Projects a point 'Pos' onto the circle defined by 'Anchor' and 'Radius'.
   -- Useful for simple revolute joints or determining limit violation.
   function Project_To_Circle (Pos, Anchor : Vec2; Radius : Fix16) return Vec2;
   
   -- Solves a penetration constraint (Point B inside Shape A).
   -- Normal: Separation normal (pointing from B to A).
   -- Depth: Penetration depth (>0).
   function Solve_Penetration (Pos_A, Pos_B : Vec2;
                               Inv_Mass_A, Inv_Mass_B : Fix16;
                               Normal : Vec2;
                               Depth  : Fix16) return Constraint_Result;

end Geo_Constraints;