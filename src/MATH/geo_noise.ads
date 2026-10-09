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
with Geo_Vec2; use Geo_Vec2;

package Geo_Noise is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Noise Primitives
   -------------------------------------------------------------------------
   -- Value Noise: Interpolated hash values. Blocky/Smooth look.
   -- Range: [-1.0, 1.0] approx.
   function Noise_Value (P : Vec2; Seed : Integer) return Fix16;

   -- Gradient Noise: Interpolated gradients (Perlin-like). Organic look.
   -- Range: [-1.0, 1.0] approx.
   function Noise_Gradient (P : Vec2; Seed : Integer) return Fix16;

   -------------------------------------------------------------------------
   -- Derived Noise
   -------------------------------------------------------------------------
   -- Curl Noise: Divergence-free vector field derived from Gradient Noise.
   -- Ideal for fluid simulation (particles flow without sinking/exploding).
   function Noise_Curl (P : Vec2; Seed : Integer) return Vec2;

   -- Fractal Brownian Motion (FBM) wrapper for Gradient Noise.
   -- Octaves: Number of layers.
   -- Lacunarity: Frequency multiplier (usually 2.0).
   -- Gain: Amplitude multiplier (usually 0.5).
   function Noise_FBM (P : Vec2; Seed : Integer; Octaves : Integer; 
                       Lacunarity : Fix16 := From_Float(2.0); 
                       Gain       : Fix16 := From_Float(0.5)) return Fix16;

end Geo_Noise;