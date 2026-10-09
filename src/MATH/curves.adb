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

with GD_CORDIC; -- Needed for Pulse

package body Curves is

   -------------------------------------------------------------------------
   -- Ease In (Quadratic)
   -------------------------------------------------------------------------
   function Ease_In (T : Fix16) return Fix16 is
   begin
      -- Rule: Minimum two runtime assertions
      pragma Assert (T >= Zero);
      pragma Assert (T <= One);

      return Mul_Sat(T, T);
   end Ease_In;

   -------------------------------------------------------------------------
   -- Ease Out (Quadratic)
   -------------------------------------------------------------------------
   function Ease_Out (T : Fix16) return Fix16 is
      Inv : Fix16;
   begin
      pragma Assert (T >= Zero);
      pragma Assert (T <= One);

      Inv := Sub_Sat(One, T);
      return Sub_Sat(One, Mul_Sat(Inv, Inv));
   end Ease_Out;

   -------------------------------------------------------------------------
   -- Ease In-Out (SmoothStep)
   -- Formula: 3t^2 - 2t^3
   -------------------------------------------------------------------------
   function Ease_In_Out (T : Fix16) return Fix16 is
      T2, T3       : Fix16;
      Term1, Term2 : Fix16;
      Three        : constant Fix16 := From_Int(3);
      Two          : constant Fix16 := From_Int(2);
   begin
      pragma Assert (T >= Zero);
      pragma Assert (T <= One);

      -- Calculate Powers
      T2 := Mul_Sat(T, T);
      T3 := Mul_Sat(T2, T);

      -- Calculate Terms
      Term1 := Mul_Sat(Three, T2);
      Term2 := Mul_Sat(Two, T3);

      return Sub_Sat(Term1, Term2);
   end Ease_In_Out;

   -------------------------------------------------------------------------
   -- Linear Ramp
   -------------------------------------------------------------------------
   function Ramp (T, Start, Stop : Fix16) return Fix16 is
      Diff : Fix16;
   begin
      pragma Assert (T >= Zero);
      pragma Assert (T <= One);

      Diff := Sub_Sat(Stop, Start);
      return Add_Sat(Start, Mul_Sat(T, Diff));
   end Ramp;

   -------------------------------------------------------------------------
   -- Bell Curve
   -- Formula: 4 * t * (1 - t)
   -------------------------------------------------------------------------
   function Bell (T : Fix16) return Fix16 is
      Inv  : Fix16;
      Base : Fix16;
      Four : constant Fix16 := From_Int(4);
   begin
      pragma Assert (T >= Zero);
      pragma Assert (T <= One);

      Inv  := Sub_Sat(One, T);
      Base := Mul_Sat(T, Inv);
      
      return Mul_Sat(Four, Base);
   end Bell;

   -------------------------------------------------------------------------
   -- Pulse
   -- Logic inferred from header: Oscillate 0..1 based on frequency
   -------------------------------------------------------------------------
   function Pulse (T, Frequency : Fix16) return Fix16 is
      Angle  : Fix16;
      Raw_Sin : Fix16;
   begin
      pragma Assert (T >= Zero);
      -- Allow T > 1.0 for Pulse since it's periodic, but standard assertion applies
      pragma Assert (Frequency >= Zero);

      -- Angle = T * Freq * 2Pi
      Angle := Mul_Sat(T, Mul_Sat(Frequency, GD_CORDIC.Two_Pi));
      
      -- Raw_Sin is -1.0 to 1.0
      Raw_Sin := GD_CORDIC.Sin(Angle);

      -- Normalize to 0.0 to 1.0: (Sin + 1) / 2
      return Mul_Sat(Add_Sat(Raw_Sin, One), Half);
   end Pulse;

end Curves;