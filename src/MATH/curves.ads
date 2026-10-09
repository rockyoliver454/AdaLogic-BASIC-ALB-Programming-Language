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

package Curves is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Standard Easing Functions
   -- All functions expect 'T' to be in range [0.0, 1.0]
   -------------------------------------------------------------------------
   
   -- Quadratic Ease In: t^2
   function Ease_In (T : Fix16) return Fix16;

   -- Quadratic Ease Out: 1 - (1-t)^2
   function Ease_Out (T : Fix16) return Fix16;

   -- SmoothStep (Ease In-Out): 3t^2 - 2t^3
   function Ease_In_Out (T : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- Temporal Ramping
   -------------------------------------------------------------------------
   
   -- Linear Interpolation (Lerp): Start + T * (End - Start)
   function Ramp (T, Start, Stop : Fix16) return Fix16;

   -------------------------------------------------------------------------
   -- Esoteric Envelopes
   -------------------------------------------------------------------------
   
   -- Gaussian-ish Bell Curve: 4 * t * (1-t)
   -- Peaks at 1.0 when T = 0.5
   function Bell (T : Fix16) return Fix16;

   -- Sine-based Pulse: (Sin(T * Freq * 2Pi) + 1) / 2
   -- Ranges from 0.0 to 1.0
   function Pulse (T, Frequency : Fix16) return Fix16;

end Curves;