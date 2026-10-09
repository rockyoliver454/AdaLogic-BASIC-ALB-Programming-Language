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

package body Geo_Fracture2D is

   function Generate_Fracture 
     (Epicenter : Vec2; 
      Report    : Stress_Report; 
      Radius    : Fix16;
      Seed      : Integer) return Fracture_Pattern 
   is
      Result : Fracture_Pattern;
      
      -- Helper to add a segment safely
      procedure Add_Seg (P1, P2 : Vec2) is
      begin
         if Result.Count < Max_Segments then
            Result.Count := Result.Count + 1;
            Result.Segments(Result.Count).A := P1;
            Result.Segments(Result.Count).B := P2;
         end if;
      end Add_Seg;

      Perp_Dir : Vec2;
      Start_P, End_P : Vec2;
      Noise_Val : Fix16;
      Offset    : Vec2;
      
      Spoke_Dir : Vec2;
      Angle     : Fix16;
      
      -- Constants
      Steps : constant Integer := 8;
      Step_Len : Fix16;
      
      PI_Fixed : constant Fix16 := From_Float(3.14159);
      Two_PI   : constant Fix16 := From_Float(6.28318);
   begin
      -- Safety: If Safe, no fracture.
      if Report.Mode = Safe then
         return Result;
      end if;

      if Report.Mode = Tensile then
         -------------------------------------------------------------------
         -- Tensile: A split perpendicular to stress (Gradient).
         -------------------------------------------------------------------
         
         -- Rotate Direction 90 degrees: (X, Y) -> (-Y, X)
         Perp_Dir := Create(-Report.Direction.Y, Report.Direction.X);
         
         -- We build a jagged line from -Radius to +Radius along Perp_Dir
         Start_P := Add(Epicenter, Scale(Perp_Dir, -Radius));
         
         -- [TITANIUM FIX] Use From_Int for steps and explicit Fix16 conversion
         Step_Len := Fix16(Fix16(Radius * From_Float(2.0)) / From_Int(Steps));
         
         declare
            Current : Vec2 := Start_P;
            Next_P  : Vec2;
            T       : Fix16;
         begin
            for I in 1 .. Steps loop
               -- Advance along main crack axis
               T := From_Int(I);
               -- [TITANIUM FIX] Explicit cast for multiplication
               Next_P := Add(Start_P, Scale(Perp_Dir, Fix16(Step_Len * T)));
               
               -- Add Jitter (Noise) perpendicular to the cut (parallel to stress)
               Noise_Val := Geo_Noise.Noise_Value(Next_P, Seed + I); 
               
               -- [TITANIUM FIX] Explicit cast for multiple multiplications
               -- (Noise * Radius * 0.2)
               Offset := Scale(Report.Direction, 
                               Fix16(Fix16(Noise_Val * Radius) * From_Float(0.2)));
                               
               Next_P := Add(Next_P, Offset);
               
               Add_Seg(Current, Next_P);
               Current := Next_P;
            end loop;
         end;

      elsif Report.Mode = Compressive then
         -------------------------------------------------------------------
         -- Compressive: Radial star/spiderweb pattern.
         -------------------------------------------------------------------
         declare
            Num_Spokes : Integer := 3 + (Seed mod 3); -- 3 to 5
            Rad_Step   : Fix16 := Fix16(Two_PI / From_Int(Num_Spokes));
            Current_Ang : Fix16 := From_Float(0.0);
         begin
            for I in 1 .. Num_Spokes loop
               -- Workaround: Use Noise to generate random points on circle
               Noise_Val := Geo_Noise.Noise_Value(Epicenter, Seed * 10 + I);
               
               -- [TITANIUM FIX] Explicit cast
               Angle := Fix16(Noise_Val * PI_Fixed);
               
               Start_P := Epicenter;
               
               -- [TITANIUM FIX] Explicit casts for multiplications
               End_P := Add(Epicenter, 
                            Create(Fix16(Noise_Val * Radius), 
                                   Fix16(Fix16(From_Float(1.0) - Abs(Noise_Val)) * Radius)));
               
               -- Normalize and Scale to Radius
               Spoke_Dir := Normalize(Sub(End_P, Start_P));
               End_P     := Add(Epicenter, Scale(Spoke_Dir, Radius));
               
               Add_Seg(Start_P, End_P);
            end loop;
         end;
      end if;

      return Result;
   end Generate_Fracture;

end Geo_Fracture2D;