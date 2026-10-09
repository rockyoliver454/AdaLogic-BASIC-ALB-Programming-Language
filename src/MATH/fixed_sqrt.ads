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

package Fixed_Sqrt is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Square Root (Binary Restoration)
   -------------------------------------------------------------------------
   -- Calculates sqrt(x) using bitwise binary restoration.
   -- Input/Output are Q16.16 Fixed Point.
   function Sqrt (X : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- Euclidean Distance
   -------------------------------------------------------------------------
   -- Calculates sqrt(dx^2 + dy^2) safely using 64-bit intermediates.
   function Distance (X1, Y1, X2, Y2 : Fix16) return Fix16;

end Fixed_Sqrt;