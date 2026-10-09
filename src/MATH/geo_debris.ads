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
with Geo_Algebra;    use Geo_Algebra;
with Geo_Compaction; use Geo_Compaction;

package Geo_Debris is

   -------------------------------------------------------------------------
   -- Constants
   -------------------------------------------------------------------------
   -- Maximum number of debris pieces per event.
   -- Keeps stack usage predictable (Power of Ten).
   Max_Debris : constant Integer := 64; 

   -------------------------------------------------------------------------
   -- Data Structures
   -------------------------------------------------------------------------
   type Debris_Particle is record
      Position : Multivector; -- 3D World Position
      Velocity : Multivector; -- 3D Linear Velocity
      Radius   : Fix16;       -- Collision Size
      Active   : Boolean;     -- Slot usage flag
   end record;

   type Debris_Array is array (1 .. Max_Debris) of Debris_Particle;

   type Debris_Cloud is record
      Particles : Debris_Array;
      Count     : Integer range 0 .. Max_Debris := 0;
   end record;

   -------------------------------------------------------------------------
   -- Operations
   -------------------------------------------------------------------------
   -- Generates physical debris based on the compaction report.
   -- 
   -- Cloud:       Output particle list.
   -- Report:      Data from Geo_Compaction (how much fell and where).
   -- Grid_Offset: The World (X, Z) of the chunk's corner.
   -- Grid_Scale:  The size of one voxel in world units (e.g., 1.0 meter).
   procedure Spawn_Debris 
     (Cloud       : out Debris_Cloud;
      Report      : Compaction_Report;
      Grid_Offset : Vec2;  
      Grid_Scale  : Fix16; 
      Seed        : Integer);

end Geo_Debris;