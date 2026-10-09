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

package Game_Timer is
   pragma Pure;

   type Timer_Data is record
      Target_DT      : Fix16; -- Target tick duration (e.g. 1/60)
      Accumulator    : Fix16; -- Stored unsimulated time
      Max_Frame_Time : Fix16; -- Cap to prevent "Spiral of Death"
      Time_Scale     : Fix16; -- Slow-Mo / Turbo (0.0 to 2.0)
      Ticks          : Integer; -- Total logic frames executed
   end record;

   -- Initialize with target Hertz (e.g., 60)
   procedure Init (T : out Timer_Data; Target_HZ : Integer);

   -- Adds real delta time. Returns number of physics steps to take.
   function Update (T : in out Timer_Data; Real_DT : Fix16) return Integer;

   -- Returns interpolation alpha (0.0 to 1.0) for rendering smooth movement
   function Get_Alpha (T : Timer_Data) return Fix16;

end Game_Timer;