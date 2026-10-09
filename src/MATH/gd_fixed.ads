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

package GD_Fixed is
   pragma Pure;

   -------------------------------------------------------------------------
   -- 1. Type Definition
   -------------------------------------------------------------------------
   -- Range is approx -32768.0 to +32767.99998
   type Fix16 is delta 2.0**(-16) range -32768.0 .. 32768.0 - 2.0**(-16);
   for Fix16'Size use 32;
   for Fix16'Small use 2.0**(-16);

   -------------------------------------------------------------------------
   -- 2. Constants
   -------------------------------------------------------------------------
   Zero     : constant Fix16 := 0.0;
   One      : constant Fix16 := 1.0;
   Half     : constant Fix16 := 0.5;
   Epsilon  : constant Fix16 := Fix16'Small;
   Min_Val  : constant Fix16 := Fix16'First;
   Max_Val  : constant Fix16 := Fix16'Last;

   -------------------------------------------------------------------------
   -- 3. Saturating Arithmetic
   -------------------------------------------------------------------------
   function Add_Sat (Left, Right : Fix16) return Fix16;
   function Sub_Sat (Left, Right : Fix16) return Fix16;
   function Mul_Sat (Left, Right : Fix16) return Fix16;
   function Div_Sat (Left, Right : Fix16) return Fix16;
   
   -- [TITANIUM NEW] Saturating Absolute Value
   -- Handles the edge case: Abs(Min_Val) -> Max_Val
   function Abs_Sat (Value : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- 4. Explicit Conversions
   -------------------------------------------------------------------------
   function From_Int (Value : Integer) return Fix16;
   function To_Int   (Value : Fix16)   return Integer;
   
   function From_Float (Value : Float) return Fix16;
   function To_Float   (Value : Fix16) return Float;

   -------------------------------------------------------------------------
   -- 5. Comparisons
   -------------------------------------------------------------------------
   function Approx_Equal (A, B : Fix16; Tolerance : Fix16 := Epsilon) return Boolean;

end GD_Fixed;