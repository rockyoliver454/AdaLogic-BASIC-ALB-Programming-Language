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

package body Game_Timer is

   procedure Init (T : out Timer_Data; Target_HZ : Integer) is
   begin
      -- Rule: Assertions for inputs
      pragma Assert (Target_HZ > 0);

      -- DT = 1.0 / Target_HZ
      T.Target_DT := Div_Sat(One, From_Int(Target_HZ));
      
      T.Accumulator := Zero;
      T.Ticks       := 0;
      
      -- Default: 1.0 scale, Max Lag 0.25s (15 frames @ 60hz)
      T.Time_Scale     := One;
      T.Max_Frame_Time := From_Float(0.25);
   end Init;

   function Update (T : in out Timer_Data; Real_DT : Fix16) return Integer is
      Delta_Time : Fix16 := Real_DT;
      Steps      : Integer := 0;
   begin
      -- 1. Apply Time Scale
      if T.Time_Scale /= One then
         Delta_Time := Mul_Sat(Delta_Time, T.Time_Scale);
      end if;

      -- 2. Lag Cap (Spiral of Death prevention)
      if Delta_Time > T.Max_Frame_Time then
         Delta_Time := T.Max_Frame_Time;
      end if;

      T.Accumulator := Add_Sat(T.Accumulator, Delta_Time);

      -- 3. Consume Accumulator in Fixed Chunks
      -- Rule: Fixed bound loop to prevent infinite hang (Max 20 steps)
      for I in 1 .. 20 loop
         if T.Accumulator >= T.Target_DT then
            T.Accumulator := Sub_Sat(T.Accumulator, T.Target_DT);
            T.Ticks := T.Ticks + 1;
            Steps := Steps + 1;
         else
            exit;
         end if;
      end loop;

      return Steps;
   end Update;

   function Get_Alpha (T : Timer_Data) return Fix16 is
   begin
      -- Alpha = Accumulator / Target_DT
      return Div_Sat(T.Accumulator, T.Target_DT);
   end Get_Alpha;

end Game_Timer;