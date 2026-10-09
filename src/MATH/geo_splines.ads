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

package Geo_Splines is
   pragma Pure;

   MAX_POINTS : constant Integer := 64;

   -- [TITANIUM FIX] Define named array type to avoid anonymous array error
   type Point_Array is array (1 .. MAX_POINTS) of Vec2;

   type Spline is record
      Points : Point_Array;
      Count  : Integer := 0;
      Closed : Boolean := False; -- If true, loops last point to first
   end record;

   -------------------------------------------------------------------------
   -- Management
   -------------------------------------------------------------------------
   procedure Clear (S : out Spline);
   procedure Add_Point (S : in out Spline; P : Vec2);

   -------------------------------------------------------------------------
   -- Evaluation
   -------------------------------------------------------------------------
   -- T: [0.0, 1.0] representing the entire path duration.
   -- 0.0 = Start, 1.0 = End.
   function Eval (S : Spline; T : Fix16) return Vec2;

   -- Returns the interpolated velocity (derivative) at global T.
   function Velocity (S : Spline; T : Fix16) return Vec2;

   -------------------------------------------------------------------------
   -- Distance Traversal (Fixed Step)
   -------------------------------------------------------------------------
   -- Converts a distance (in meters/units) along the path to a Global T.
   -- Uses Geo_Curves.Catmull_Solve_T iteratively.
   -- Total_Length: Optional out parameter to get full path length.
   function Distance_To_T (S : Spline; Dist : Fix16; Total_Len : out Fix16) return Fix16;

   -- Total length of the spline (sum of all segments)
   function Length (S : Spline) return Fix16;

end Geo_Splines;