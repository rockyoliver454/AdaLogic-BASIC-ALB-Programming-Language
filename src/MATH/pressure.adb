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

package body Pressure is

   -------------------------------------------------------------------------
   -- Init
   -------------------------------------------------------------------------
   procedure Init (PS : out Pressure_System) is
      -- Register indices (Stack allocation, no heap)
      T_Idx, M_Idx              : Integer;
      Const_Esc, Const_Base     : Integer;
      Tension, Escalation, Sum  : Integer;
      Lo, Hi, Final_Out         : Integer;
   begin
      -- Rule: Initialize state explicitly
      Clear(PS.Curve);
      PS.Last_Value := Zero;

      -- 1. Define Variables
      -- Var 0 = Time, Var 1 = Mistakes
      T_Idx := Add_Var(PS.Curve, 0);
      M_Idx := Add_Var(PS.Curve, 1);

      -- 2. Escalation: Mistakes * 0.15
      Const_Esc  := Add_Const(PS.Curve, From_Float(0.15));
      Escalation := Add_Mul(PS.Curve, M_Idx, Const_Esc);

      -- 3. Tension: Time * 0.01
      Const_Base := Add_Const(PS.Curve, From_Float(0.01));
      Tension    := Add_Mul(PS.Curve, T_Idx, Const_Base);

      -- 4. Sum them up
      Sum := Add_Add(PS.Curve, Tension, Escalation);

      -- 5. Clamp between 0.0 and 1.0
      Lo := Add_Const(PS.Curve, Zero);
      Hi := Add_Const(PS.Curve, One);
      
      Final_Out := Add_Clamp(PS.Curve, Sum, Lo, Hi);

      -- Rule: Minimum two runtime assertions
      pragma Assert (Final_Out >= 0);
      
      -- [TITANIUM FIX] Use public getter to access private component
      pragma Assert (Get_Count(PS.Curve) > 0); 
   end Init;

   -------------------------------------------------------------------------
   -- Update
   -------------------------------------------------------------------------
   function Update (PS : in out Pressure_System; Time, Mistakes : Fix16) return Fix16 is
      Vars : Variable_Table := (others => Zero);
   begin
      -- Rule: Assert inputs are sane
      pragma Assert (Time >= Zero);
      
      -- Populate Variable Table
      Vars(0) := Time;
      Vars(1) := Mistakes;

      -- Execute the VM
      PS.Last_Value := Evaluate(PS.Curve, Vars);

      -- Rule: Assert Output is within the expected range
      pragma Assert (PS.Last_Value >= Zero);
      pragma Assert (PS.Last_Value <= One);

      return PS.Last_Value;
   end Update;

   -------------------------------------------------------------------------
   -- Get
   -------------------------------------------------------------------------
   function Get (PS : Pressure_System) return Fix16 is
   begin
      pragma Assert (PS.Last_Value >= Zero);
      pragma Assert (PS.Last_Value <= One);
      
      return PS.Last_Value;
   end Get;

end Pressure;