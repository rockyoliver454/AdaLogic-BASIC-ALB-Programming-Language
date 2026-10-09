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
with Geo_Voxel_Ops;  use Geo_Voxel_Ops;

package Geo_Erosion is

   -------------------------------------------------------------------------
   -- Configuration
   -------------------------------------------------------------------------
   -- How many "years" of erosion happen per game tick?
   -- Higher = faster smoothing.
   Erosion_Rate : constant Integer := 1; 

   -------------------------------------------------------------------------
   -- Operations
   -------------------------------------------------------------------------
   -- Applies Thermal Erosion (Material Slippage) to the chunk.
   -- Converts unstable vertical columns into stable 45-degree slopes.
   --
   -- Chunk:      The voxel data to erode.
   -- Iterations: How many passes to run (e.g., 5 for a quick settle).
   -- Seed:       For randomized slippage direction.
   procedure Apply_Thermal_Erosion 
     (Chunk      : in out Voxel_Chunk;
      Iterations : Integer;
      Seed       : Integer);

   -------------------------------------------------------------------------
   -- Analysis
   -------------------------------------------------------------------------
   -- Returns the "Roughness" of the chunk (Surface Area / Volume ratio approx).
   -- Used to decide if a chunk NEEDS erosion (Optimization).
   function Calculate_Roughness (Chunk : Voxel_Chunk) return Fix16;

end Geo_Erosion;