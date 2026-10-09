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

with Geo_Voxel_Ops; use Geo_Voxel_Ops;

package Geo_Boolean is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Destructive Operations (Carving)
   -------------------------------------------------------------------------
   -- Subtracts a sphere from the chunk.
   -- Returns the number of voxels that were actually removed (turned from 1 to 0).
   -- Use this to spawn the correct amount of debris particles.
   function Subtract_Sphere 
     (C          : in out Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float) return Integer;

   -- Subtracts an Axis-Aligned Box (AABB) from the chunk.
   -- Useful for structural damage or laser cuts.
   function Subtract_Box 
     (C          : in out Voxel_Chunk; 
      Min_X, Min_Y, Min_Z : Float;
      Max_X, Max_Y, Max_Z : Float) return Integer;

   -------------------------------------------------------------------------
   -- Constructive Operations (Building)
   -------------------------------------------------------------------------
   -- Adds a sphere to the chunk.
   -- Returns the number of voxels actually added (turned from 0 to 1).
   function Union_Sphere 
     (C          : in out Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float) return Integer;

   -------------------------------------------------------------------------
   -- Queries (Collision Detection)
   -------------------------------------------------------------------------
   -- Returns True if the sphere touches ANY solid voxel.
   -- Use this to trigger the explosion exactly when a missile hits the terrain.
   function Intersect_Sphere 
     (C          : Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float) return Boolean;

end Geo_Boolean;