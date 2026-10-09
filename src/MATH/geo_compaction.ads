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

with GD_Fixed;      use GD_Fixed;
with Geo_Voxel_Ops; use Geo_Voxel_Ops;

package Geo_Compaction is

   -------------------------------------------------------------------------
   -- Data Structures
   -------------------------------------------------------------------------
   type Compaction_Report is record
      Collapsed_Count : Integer; -- How many voxels fell?
      Center_Of_Mass  : Integer; -- Approximate location (packed index) for spawning debris
   end record;

   -------------------------------------------------------------------------
   -- Operations
   -------------------------------------------------------------------------
   -- Scans the chunk for floating islands (unconnected to Y=0).
   -- Removes them from the chunk.
   -- Returns a report describing what fell.
   procedure Stabilize_Chunk 
     (Chunk : in out Voxel_Chunk; 
      Report : out Compaction_Report);

end Geo_Compaction;