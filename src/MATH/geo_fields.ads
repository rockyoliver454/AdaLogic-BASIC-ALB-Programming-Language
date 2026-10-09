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

package Geo_Fields is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Noise (Deterministic)
   -------------------------------------------------------------------------
   -- 2D Value Noise. Returns [-1.0, 1.0].
   -- Smooth interpolation of random hash values on a grid.
   -- Scale: Zoom level (e.g., 0.1 for large hills, 1.0 for static).
   function Noise_2D (X, Y : Fix16; Scale : Fix16; Seed : Integer) return Fix16;

   -------------------------------------------------------------------------
   -- Vector Fields
   -------------------------------------------------------------------------
   -- Generates a vector based on the gradient (slope) of the noise field.
   -- Useful for terrain flow or "downhill" movement.
   function Gradient_Noise (Pos : Vec2; Scale : Fix16; Seed : Integer) return Vec2;

   -- A purely rotational field (Vortex).
   -- Strength: Rotation speed. Decay: How fast it weakens with distance.
   function Vortex (Pos : Vec2; Center : Vec2; Strength : Fix16; Decay : Fix16) return Vec2;

   -- A "Source" (Push away) or "Sink" (Pull in) field.
   -- Strength > 0 is Push, < 0 is Pull.
   function Radial_Source (Pos : Vec2; Center : Vec2; Strength : Fix16; Decay : Fix16) return Vec2;

   -- Curl Noise: Divergence-free fluid-like movement.
   -- Derived by taking the curl of a scalar noise potential.
   -- Physically guarantees particles won't "clump" or sink.
   function Curl_Noise (Pos : Vec2; Scale : Fix16; Seed : Integer) return Vec2;

end Geo_Fields;