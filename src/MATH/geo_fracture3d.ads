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
with Geo_Voxel_Ops;  use Geo_Voxel_Ops;
with Geo_Fracture2D; use Geo_Fracture2D;

package Geo_Fracture3D is

   -------------------------------------------------------------------------
   -- Operations
   -------------------------------------------------------------------------
   -- Applies the 2D fracture pattern to the 3D voxel volume.
   -- Effectively "Extrudes" the cracks downwards to create vertical fault lines.
   --
   -- Chunk:       The voxel data to modify.
   -- Pattern:     The list of cut lines from Geo_Fracture2D.
   -- Grid_Offset: The World Position of the Voxel Chunk's corner (X, Z).
   -- Grid_Scale:  The world size of a single voxel (e.g., 1.0).
   -- Cut_Depth:   How far down (in voxels) the crack extends (e.g., 16 for full chunk).
   procedure Apply_Fracture 
     (Chunk       : in out Voxel_Chunk;
      Pattern     : Fracture_Pattern;
      Grid_Offset : Vec2;
      Grid_Scale  : Fix16;
      Cut_Depth   : Integer := Chunk_Size);

end Geo_Fracture3D;