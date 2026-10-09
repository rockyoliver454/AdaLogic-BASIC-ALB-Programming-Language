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
with Sym_Expr; use Sym_Expr;
with RNG;      use RNG;

package Weighted_PDF is
   
   Max_Outcomes : constant := 8;

   -- [TITANIUM FIX] Named array type to avoid "anonymous array" errors
   type Curve_Array is array (0 .. Max_Outcomes - 1) of Expression;

   type PDF_System is record
      Weight_Curves : Curve_Array;
      Count         : Integer range 0 .. Max_Outcomes := 0;
   end record;

   -- Initializes the default Arcade curves (Common vs Elite)
   procedure Init (Sys : out PDF_System);

   -- Rolls for an outcome index based on current Pressure
   function Roll (Sys : PDF_System; Gen : in out Generator; Pressure_Val : Fix16) return Integer;

end Weighted_PDF;