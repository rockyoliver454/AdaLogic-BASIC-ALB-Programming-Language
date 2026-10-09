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

with GD_Fixed;    use GD_Fixed;
with Geo_Vec2;    use Geo_Vec2;
with Geo_Algebra; use Geo_Algebra;

package Geo_Heightfield is
   -- [TITANIUM FIX] Removed pragma Pure to allow function calls (From_Float) in constants.
   -- pragma Pure; 

   -------------------------------------------------------------------------
   -- Configuration
   -------------------------------------------------------------------------
   -- The sampling distance for finite difference calculations.
   -- Too small = floating point noise. Too large = smoothing artifacts.
   Epsilon : constant Fix16 := From_Float(0.1);

   -------------------------------------------------------------------------
   -- The Signal (Ground Truth)
   -------------------------------------------------------------------------
   -- The fundamental height function H(x,z).
   -- Input P.X = World X, P.Y = World Z. Returns World Y.
   function Get_Height (P : Vec2; Seed : Integer) return Fix16;

   -------------------------------------------------------------------------
   -- Differential Geometry (Derived Properties)
   -------------------------------------------------------------------------
   -- 1. Gradient (Slope)
   -- Returns the 2D vector of steepest ascent (dH/dx, dH/dz).
   -- Magnitude = Steepness. Direction = Uphill.
   function Get_Gradient (P : Vec2; Seed : Integer) return Vec2;

   -- 2. Surface Normal
   -- Returns the normalized 3D vector perpendicular to the surface.
   -- ( -dH/dx, 1, -dH/dz ).Normalized()
   function Get_Normal (P : Vec2; Seed : Integer) return Multivector;

   -- 3. Curvature (Mean)
   -- Measure of convexity/concavity.
   -- Positive = Valley/Bowl (Material collects here).
   -- Negative = Peak/Ridge (Material erodes from here).
   -- Essential for stress fracture seeding.
   function Get_Curvature (P : Vec2; Seed : Integer) return Fix16;

   -- 4. Laplacian (Diffusion)
   -- The divergence of the gradient field (Flux).
   -- Describes how the surface "flows". Used for hydraulic erosion simulation.
   function Get_Laplacian (P : Vec2; Seed : Integer) return Fix16;

end Geo_Heightfield;