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

package body Geo_Stress is

   -------------------------------------------------------------------------
   -- Analyze Point
   -------------------------------------------------------------------------
   function Analyze_Point (P : Vec2; Seed : Integer) return Stress_Report is
      K      : Fix16; -- Curvature
      Grad   : Vec2;
      Result : Stress_Report;
      Abs_K  : Fix16;
   begin
      -- 1. Get Geometric Properties
      K    := Geo_Heightfield.Get_Curvature(P, Seed);
      Grad := Geo_Heightfield.Get_Gradient(P, Seed);

      -- 2. Determine Mode based on Curvature sign
      -- K > 0: Bowl/Valley (Compression)
      -- K < 0: Peak/Ridge (Tension)
      Abs_K := Abs(K);
      Result.Magnitude := Abs_K;
      Result.Direction := Normalize(Grad); -- Stress flows downhill usually

      if Abs_K < From_Float(0.1) then
         Result.Mode := Safe;
      elsif K < From_Float(0.0) then
         Result.Mode := Tensile; 
         -- Tensor logic: Rocks are weaker in tension. Boost effective stress.
         Result.Magnitude := Result.Magnitude * From_Float(1.2); 
      else
         Result.Mode := Compressive;
      end if;

      -- 3. Cap Magnitude
      if Result.Magnitude > From_Float(1.0) then
         Result.Magnitude := From_Float(1.0);
      end if;

      return Result;
   end Analyze_Point;

   -------------------------------------------------------------------------
   -- Find Weakest Point
   -------------------------------------------------------------------------
   function Find_Weakest_Point 
     (Center : Vec2; 
      Radius : Fix16; 
      Steps  : Integer; 
      Seed   : Integer) return Vec2 
   is
      Best_P   : Vec2 := Center;
      Max_Mag  : Fix16 := From_Float(-1.0);
      
      Current_P : Vec2;
      Report    : Stress_Report;
      
      Angle     : Fix16;
      Dist      : Fix16;
      Step_Rad  : Fix16;
      Step_Ang  : Fix16;
   begin
      -- Spiral search pattern or random sampling.
      -- Deterministic concentric circles for Power of Ten compliance.
      
      -- Limit steps to avoid runaway loops
      if Steps <= 0 then return Center; end if;

      -- We do a simple grid/cross pattern or limited radial scan
      -- For simplicity and speed: 4 cardinal directions + center
      
      -- Check Center First
      Report := Analyze_Point(Center, Seed);
      Max_Mag := Report.Magnitude;

      -- Iterate checks
      -- Note: In a real engine, 'Steps' would drive a loop.
      -- Here we hardcode a 5-point sample pattern scaled by Radius
      -- to ensure O(1) performance for this specific call.
      
      -- 1. North
      Current_P := Add(Center, Create(From_Float(0.0), Radius));
      Report := Analyze_Point(Current_P, Seed);
      if Report.Magnitude > Max_Mag then
         Max_Mag := Report.Magnitude;
         Best_P  := Current_P;
      end if;

      -- 2. South
      Current_P := Add(Center, Create(From_Float(0.0), -Radius));
      Report := Analyze_Point(Current_P, Seed);
      if Report.Magnitude > Max_Mag then
         Max_Mag := Report.Magnitude;
         Best_P  := Current_P;
      end if;

      -- 3. East
      Current_P := Add(Center, Create(Radius, From_Float(0.0)));
      Report := Analyze_Point(Current_P, Seed);
      if Report.Magnitude > Max_Mag then
         Max_Mag := Report.Magnitude;
         Best_P  := Current_P;
      end if;

      -- 4. West
      Current_P := Add(Center, Create(-Radius, From_Float(0.0)));
      Report := Analyze_Point(Current_P, Seed);
      if Report.Magnitude > Max_Mag then
         Max_Mag := Report.Magnitude;
         Best_P  := Current_P;
      end if;

      return Best_P;
   end Find_Weakest_Point;

end Geo_Stress;