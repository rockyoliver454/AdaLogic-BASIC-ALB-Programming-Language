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
with Interfaces.C; use Interfaces.C; -- Required for Export conventions

package GD_CORDIC is
   pragma Pure;

   -- =========================================================
   -- NASA RULE 5: CONTRACTS
   -- =========================================================

   -- Standard Sin/Cos computation
   procedure Sin_Cos (Angle   : in Fix16; 
                      Sin_Val : out Fix16; 
                      Cos_Val : out Fix16);
   -- EXPORT TO C: "gd_sincos"
   pragma Export (C, Sin_Cos, "gd_sincos");

   -- Convenience Wrappers
   function Sin (Angle : Fix16) return Fix16;
   -- EXPORT TO C: "gd_sin"
   pragma Export (C, Sin, "gd_sin");

   function Cos (Angle : Fix16) return Fix16;
   -- EXPORT TO C: "gd_cos"
   pragma Export (C, Cos, "gd_cos");

   -- [TITANIUM NEW] Vectoring Mode: Computes Atan2(Y, X)
   function ArcTan2 (Y, X : Fix16) return Fix16;

   -- [TITANIUM NEW] ArcCos using Atan2 and Sqrt
   function ArcCos (Val : Fix16) return Fix16;

   -- Constants
   Pi      : constant Fix16 := 3.14159;
   Half_Pi : constant Fix16 := 1.57079;
   Two_Pi  : constant Fix16 := 6.28318;

end GD_CORDIC;