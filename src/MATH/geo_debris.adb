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

package body Geo_Debris is

   procedure Spawn_Debris 
     (Cloud       : out Debris_Cloud;
      Report      : Compaction_Report;
      Grid_Offset : Vec2;
      Grid_Scale  : Fix16;
      Seed        : Integer)
   is
      -- Unpack the Center of Mass index
      Center_Idx : Integer := Report.Center_Of_Mass;
      V_X, V_Y, V_Z : Integer;
      
      World_X, World_Y, World_Z : Fix16;
      
      Spawn_Count : Integer;
      Noise_X, Noise_Z : Fix16;
      
      -- Constants
      Gravity_Bias : constant Fix16 := From_Float(-5.0);
      Scale_Half   : constant Fix16 := Fix16(Grid_Scale * From_Float(0.5));
   begin
      Cloud.Count := 0;

      if Report.Collapsed_Count <= 0 then
         return;
      end if;

      -- 1. Unpack Voxel Coordinates
      -- Index = X + (Y * 16) + (Z * 256)
      -- This mirrors the packing logic assumed in Geo_Compaction
      V_X := Center_Idx mod 16;
      V_Y := (Center_Idx / 16) mod 16;
      V_Z := (Center_Idx / 256);

      -- 2. Convert to World Space Center
      -- Note: Grid_Offset.Y holds the World Z coordinate. World Y is implicit from voxel height.
      World_X := Grid_Offset.X + Fix16(From_Int(V_X) * Grid_Scale);
      World_Y := Fix16(From_Int(V_Y) * Grid_Scale); 
      World_Z := Grid_Offset.Y + Fix16(From_Int(V_Z) * Grid_Scale);

      -- 3. Determine Spawn Count
      -- Logic: 1 particle per 4 voxels, clamped to Max_Debris.
      Spawn_Count := Report.Collapsed_Count / 4;
      if Spawn_Count < 1 then Spawn_Count := 1; end if;
      if Spawn_Count > Max_Debris then Spawn_Count := Max_Debris; end if;

      Cloud.Count := Spawn_Count;

      -- 4. Generate Particles
      for I in 1 .. Spawn_Count loop
         Cloud.Particles(I).Active := True;
         
         -- Generate Jitter
         -- Using Seed + I ensures deterministic spread
         Noise_X := Geo_Noise.Noise_Value(Create(World_X, World_Z), Seed + I);
         Noise_Z := Geo_Noise.Noise_Value(Create(World_X, World_Y), Seed - I);
         
         -- Position: Center + Random Jitter
         Cloud.Particles(I).Position := Vector(
            Fix16(World_X + (Noise_X * Grid_Scale)), 
            Fix16(World_Y + (Noise_X * Scale_Half)), -- Less vertical jitter
            Fix16(World_Z + (Noise_Z * Grid_Scale))
         );

         -- Velocity: Crumbling behavior
         -- Moves mostly down, with slight horizontal spread based on noise
         Cloud.Particles(I).Velocity := Vector(
            Fix16(Noise_X * From_Float(2.0)), -- Burst outward X
            Gravity_Bias,                     -- Fall down
            Fix16(Noise_Z * From_Float(2.0))  -- Burst outward Z
         );
         
         -- Size: Roughly half a voxel
         Cloud.Particles(I).Radius := Scale_Half; 
      end loop;

   end Spawn_Debris;

end Geo_Debris;