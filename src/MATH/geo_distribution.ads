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

package Geo_Distribution is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Distributions (Analytical)
   -------------------------------------------------------------------------
   -- Evaluate Normal PDF at X.
   -- Uses an approximation for exp().
   function Normal_PDF (X, Mean, StdDev : Fix16) return Fix16;

   -- Evaluate Triangle PDF at X.
   function Triangle_PDF (X, Min, Max, Peak : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- Sampling (Input: Uniform Random 0.0 .. 1.0)
   -------------------------------------------------------------------------
   -- Samples a Normal distribution using Central Limit Theorem approx.
   -- Requires 3 uniform random inputs [0..1] for reasonable quality.
   -- (U1 + U2 + U3 - 1.5) scaled.
   function Sample_Normal_CLT (Mean, StdDev : Fix16; U1, U2, U3 : Fix16) return Fix16;

   -- Samples a Triangle distribution.
   function Sample_Triangle (Min, Max, Peak : Fix16; U : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- Utilities
   -------------------------------------------------------------------------
   -- Smoothstep function (CDF-like S-curve).
   function Smooth_Step (Edge0, Edge1, X : Fix16) return Fix16;

end Geo_Distribution;