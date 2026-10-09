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

package Geo_Entropy is
   pragma Pure;

   -- Discrete Probability Distribution
   type Prob_Array is array (Integer range <>) of Fix16;

   -------------------------------------------------------------------------
   -- Measures
   -------------------------------------------------------------------------
   -- Shannon Entropy: Sum(-p * log2(p))
   -- Measures randomness/uncertainty.
   -- Max entropy is Log2(N) (Uniform distribution).
   function Entropy (Probs : Prob_Array) return Fix16;

   -- Variance: Sum(p * (x - mean)^2)
   -- Measures spread.
   -- Values: The actual values corresponding to the probabilities.
   function Variance (Probs : Prob_Array; Values : Prob_Array) return Fix16;

   -- Returns Log2 approximation (Fixed Point).
   function Log2_Approx (X : Fix16) return Fix16;

end Geo_Entropy;