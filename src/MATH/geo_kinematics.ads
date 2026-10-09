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
with EO_PGA2D; use EO_PGA2D;

package Geo_Kinematics is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Forward Kinematics
   -------------------------------------------------------------------------
   -- Chains a local motor onto a parent motor.
   -- Result = Parent * Local
   function FK_Chain (Parent_Motor, Local_Motor : Multivector) return Multivector;

   -- Extracts the 2D Euclidean position from a Motor.
   -- Effectively: Motor * Origin * ~Motor
   function Get_Position (M : Multivector) return Vec2;
   
   -- Extracts the 2D Rotation angle from a Motor.
   function Get_Rotation (M : Multivector) return Fix16;

   -------------------------------------------------------------------------
   -- Inverse Kinematics Helpers (Jacobian / CCD)
   -------------------------------------------------------------------------
   -- Calculates the required angle change for a single joint to rotate 
   -- its end-effector towards a target.
   -- Used for CCD (Cyclic Coordinate Descent) IK.
   -- Joint_Pos: World position of the joint pivot.
   -- Effector_Pos: World position of the tip/end-effector.
   -- Target_Pos: World position to reach.
   function Solve_CCD_Angle (Joint_Pos, Effector_Pos, Target_Pos : Vec2) return Fix16;

   -- Simple 2-Bone IK Solver (Analytic).
   -- Returns the two joint angles (relative) to reach Target (local to Root).
   -- L1, L2: Bone lengths.
   -- Target: Position relative to Root joint.
   -- Bend_Right: Preference for elbow bending direction.
   -- Returns (Angle1, Angle2). Returns (0,0) if unreachable.
   type IK_Result is record
      Theta_1 : Fix16;
      Theta_2 : Fix16;
      Valid   : Boolean;
   end record;

   function Solve_Two_Bone (L1, L2 : Fix16; Target : Vec2; Bend_Right : Boolean) return IK_Result;

end Geo_Kinematics;