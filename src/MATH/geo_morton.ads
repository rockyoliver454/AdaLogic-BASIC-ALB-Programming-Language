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
with Interfaces; use Interfaces;

package Geo_Morton is
   pragma Pure;

   -- 32-bit Morton Code (16 bits per axis)
   -- Capable of indexing a 65536x65536 grid.
   type Morton_Code is new Unsigned_32;

   -------------------------------------------------------------------------
   -- Encoding / Decoding
   -------------------------------------------------------------------------
   -- Converts a 2D point into a Morton Code.
   -- Inputs are clamped to [0 .. 65535].
   function Encode_2D (X, Y : Integer) return Morton_Code;

   -- Decodes a Morton Code back into 2D coordinates.
   procedure Decode_2D (Code : Morton_Code; X, Y : out Integer);

   -- Fixed-Point Wrappers (Auto-scales Fix16 to grid space)
   -- Assumes World_Min/Max range fits within 16-bit integer space after scaling.
   function Encode_Point (X, Y : Fix16) return Morton_Code;

   -------------------------------------------------------------------------
   -- Traversal
   -------------------------------------------------------------------------
   -- Returns the Morton Code of the neighbor in the given direction.
   -- DX, DY: -1, 0, or 1.
   -- Returns Code if boundary crossed (clamped).
   function Neighbor (Code : Morton_Code; DX, DY : Integer) return Morton_Code;

   -- Calculates the range of Morton Codes that cover an AABB.
   -- Useful for querying a quadtree or linear spatial map.
   procedure Get_Range (Min_X, Min_Y, Max_X, Max_Y : Fix16; 
                        Start_Code, End_Code : out Morton_Code);

end Geo_Morton;