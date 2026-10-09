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
with GD_Fixed;   use GD_Fixed;

package RNG is

   type Generator is record
      State : Unsigned_32;
   end record;

   -- Initializes state. Replaces 0 with Deadcode seed.
   procedure Init (Gen : out Generator; Seed : Unsigned_32);

   -- Returns raw 32-bit random number (Xorshift)
   function Next (Gen : in out Generator) return Unsigned_32;

   -- Returns integer in [Min, Max]
   function Range_Int (Gen : in out Generator; Min, Max : Integer) return Integer;

   -- Returns True if roll < Probability
   function Chance (Gen : in out Generator; Probability : Fix16) return Boolean;

   -- Returns fixed point 0.0 to <1.0
   function Next_Fixed (Gen : in out Generator) return Fix16;

end RNG;