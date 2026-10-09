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

with Interfaces; use Interfaces;

package Bitboard is
   pragma Pure;

   type Board is new Unsigned_64;

   -- Masks (Constants)
   File_A : constant Board := 16#0101010101010101#;
   File_H : constant Board := 16#8080808080808080#;

   -------------------------------------------------------------------------
   -- Queries
   -------------------------------------------------------------------------
   -- Returns number of set bits (Population Count)
   function Pop_Count (B : Board) return Integer;

   -- Returns index (0-63) of the Least Significant Bit.
   -- Returns -1 if the board is empty.
   function Get_LSB (B : Board) return Integer;

   -- Checks if two bitboards overlap
   function Intersects (A, B : Board) return Boolean;

   -------------------------------------------------------------------------
   -- Manipulation
   -------------------------------------------------------------------------
   -- Shifts the grid. DX (Horizontal), DY (Vertical).
   -- Handles masking to prevent row-wrapping.
   function Shift (B : Board; DX, DY : Integer) return Board;

   -- Basic bit ops helper
   function Is_Set (B : Board; Index : Integer) return Boolean;
   function Set_Bit (B : Board; Index : Integer) return Board;

end Bitboard;