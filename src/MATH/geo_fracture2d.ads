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

with GD_Fixed;   use GD_Fixed;
with Geo_Vec2;   use Geo_Vec2;
with Geo_Stress; use Geo_Stress;

package Geo_Fracture2D is
   -- Standard unit, no Pure/Preelaborate due to math dependencies
   
   -------------------------------------------------------------------------
   -- Constants (Power of Ten: Fixed Limits)
   -------------------------------------------------------------------------
   -- A single fracture event won't generate more than 32 segments.
   -- This keeps the "Explosion Event" lightweight.
   Max_Segments : constant Integer := 32;

   -------------------------------------------------------------------------
   -- Data Structures
   -------------------------------------------------------------------------
   type Segment is record
      A, B : Vec2; -- Start and End of the cut line
   end record;

   type Segment_Array is array (1 .. Max_Segments) of Segment;

   type Fracture_Pattern is record
      Segments : Segment_Array;
      Count    : Integer range 0 .. Max_Segments := 0;
   end record;

   -------------------------------------------------------------------------
   -- Operations
   -------------------------------------------------------------------------
   -- Generates a fracture geometry based on the stress state at the epicenter.
   -- Epicenter: Where the break starts.
   -- Report:    The stress analysis (Mode, Direction, Magnitude) from Geo_Stress.
   -- Radius:    How large the fracture area is.
   function Generate_Fracture 
     (Epicenter : Vec2; 
      Report    : Stress_Report; 
      Radius    : Fix16;
      Seed      : Integer) return Fracture_Pattern;

end Geo_Fracture2D;