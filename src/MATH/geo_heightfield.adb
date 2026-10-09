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

with Geo_Noise;
with Fixed_Sqrt; -- [TITANIUM FIX] Added for Sqrt

package body Geo_Heightfield is

   -------------------------------------------------------------------------
   -- The Signal
   -------------------------------------------------------------------------
   function Get_Height (P : Vec2; Seed : Integer) return Fix16 is
      -- Terrain Parameters
      Scale_Factor : constant Fix16 := From_Float(0.02);
      Amplitude    : constant Fix16 := From_Float(30.0); 
      Octaves      : constant Integer := 5;
   begin
      -- H(x,z) = Amplitude * FBM(P * Scale)
      return Fix16(Amplitude * Geo_Noise.Noise_FBM(Scale(P, Scale_Factor), Seed, Octaves));
   end Get_Height;

   -------------------------------------------------------------------------
   -- Differential Geometry Implementation
   -------------------------------------------------------------------------
   function Get_Gradient (P : Vec2; Seed : Integer) return Vec2 is
      H_Left, H_Right : Fix16;
      H_Down, H_Up    : Fix16;
      Dx, Dz          : Fix16;
      Inv_Two_Eps     : Fix16;
   begin
      -- Central Difference: f'(x) approx (f(x+e) - f(x-e)) / 2e
      
      H_Left  := Get_Height(Create(P.X - Epsilon, P.Y), Seed);
      H_Right := Get_Height(Create(P.X + Epsilon, P.Y), Seed);
      
      H_Down  := Get_Height(Create(P.X, P.Y - Epsilon), Seed);
      H_Up    := Get_Height(Create(P.X, P.Y + Epsilon), Seed);
      
      -- Precompute 1 / (2 * epsilon)
      -- [TITANIUM FIX] Explicit conversions for Fixed Point arithmetic
      Inv_Two_Eps := Fix16(From_Float(1.0) / Fix16(From_Float(2.0) * Epsilon));
      
      Dx := Fix16((H_Right - H_Left) * Inv_Two_Eps);
      Dz := Fix16((H_Up - H_Down)    * Inv_Two_Eps);
      
      return Create(Dx, Dz);
   end Get_Gradient;

   function Get_Normal (P : Vec2; Seed : Integer) return Multivector is
      G : Vec2;
      Nx, Ny, Nz : Fix16;
      Mag_Sq, Inv_Mag : Fix16;
   begin
      -- Normal N = (-dH/dx, 1, -dH/dz)
      G := Get_Gradient(P, Seed);
      
      Nx := -G.X;
      Ny := From_Float(1.0);
      Nz := -G.Y; 
      
      -- Normalize
      Mag_Sq := Fix16(Nx * Nx) + Fix16(Ny * Ny) + Fix16(Nz * Nz);
      
      if Mag_Sq < From_Float(0.0001) then
         return Vector(From_Float(0.0), From_Float(1.0), From_Float(0.0));
      end if;
      
      -- [TITANIUM FIX] Use Fixed_Sqrt package
      Inv_Mag := Fix16(From_Float(1.0) / Fixed_Sqrt.Sqrt(Mag_Sq));
      
      return Vector(Fix16(Nx * Inv_Mag), Fix16(Ny * Inv_Mag), Fix16(Nz * Inv_Mag));
   end Get_Normal;

   function Get_Laplacian (P : Vec2; Seed : Integer) return Fix16 is
      Center, Left, Right, Up, Down : Fix16;
      Sum_Neighbors : Fix16;
      Inv_Eps_Sq : Fix16;
   begin
      -- Laplacian = (Sum(Neighbors) - 4*Center) / Epsilon^2
      
      Center := Get_Height(P, Seed);
      Left   := Get_Height(Create(P.X - Epsilon, P.Y), Seed);
      Right  := Get_Height(Create(P.X + Epsilon, P.Y), Seed);
      Down   := Get_Height(Create(P.X, P.Y - Epsilon), Seed);
      Up     := Get_Height(Create(P.X, P.Y + Epsilon), Seed);
      
      Sum_Neighbors := Left + Right + Up + Down;
      -- [TITANIUM FIX] Explicit conversion
      Inv_Eps_Sq    := Fix16(From_Float(1.0) / Fix16(Epsilon * Epsilon));
      
      return Fix16((Sum_Neighbors - Fix16(From_Float(4.0) * Center)) * Inv_Eps_Sq);
   end Get_Laplacian;

   function Get_Curvature (P : Vec2; Seed : Integer) return Fix16 is
   begin
      -- Laplacian is a good proxy for mean curvature on heightfields
      return Get_Laplacian(P, Seed);
   end Get_Curvature;

end Geo_Heightfield;