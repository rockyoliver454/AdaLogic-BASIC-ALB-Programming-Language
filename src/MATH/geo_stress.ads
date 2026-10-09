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

with GD_Fixed;       use GD_Fixed;
with Geo_Vec2;       use Geo_Vec2;
with Geo_Heightfield;

package Geo_Stress is
   -- [TITANIUM FIX] Removed pragma Pure to allow dependency on Geo_Heightfield
   -- pragma Pure;

   -------------------------------------------------------------------------
   -- Stress Types
   -------------------------------------------------------------------------
   type Stress_Mode is (
      Safe,       -- Structure is stable
      Tensile,    -- Being pulled apart (Peaks/Ridges) -> Cracks open up
      Compressive -- Being pushed together (Valleys/Impacts) -> Crushing/Spalling
   );

   type Stress_Report is record
      Mode      : Stress_Mode;
      Magnitude : Fix16; -- 0.0 to 1.0 (Normalized stress factor)
      Direction : Vec2;  -- The direction of principal stress (typically Gradient)
   end record;

   -------------------------------------------------------------------------
   -- Configuration
   -------------------------------------------------------------------------
   -- How much curvature is required to trigger a fracture?
   -- Tuned for the FBM noise in Geo_Heightfield.
   Fracture_Threshold : constant Fix16 := From_Float(0.65);

   -------------------------------------------------------------------------
   -- Analysis Operations
   -------------------------------------------------------------------------
   -- Analyzes the terrain at Point P to determine its mechanical stress state.
   -- Uses Curvature from the Heightfield Oracle.
   function Analyze_Point (P : Vec2; Seed : Integer) return Stress_Report;

   -- Scans a circular area to find the weakest point (Highest Stress).
   -- Useful for "Snapping" an explosion to the nearest structural weak point.
   -- Steps: Number of samples in the search (Power of Ten: Fixed bounds).
   function Find_Weakest_Point 
     (Center : Vec2; 
      Radius : Fix16; 
      Steps  : Integer; 
      Seed   : Integer) return Vec2;

end Geo_Stress;