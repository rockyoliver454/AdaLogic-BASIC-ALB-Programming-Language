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

package body GD_Fixed is

   -------------------------------------------------------------------------
   -- Saturating Arithmetic
   -------------------------------------------------------------------------
   function Add_Sat (Left, Right : Fix16) return Fix16 is
      -- Use wider type to detect overflow
      L : constant Long_Float := Long_Float(Left);
      R : constant Long_Float := Long_Float(Right);
      Res : constant Long_Float := L + R;
   begin
      if Res > Long_Float(Fix16'Last) then
         return Fix16'Last;
      elsif Res < Long_Float(Fix16'First) then
         return Fix16'First;
      else
         return Fix16(Res);
      end if;
   end Add_Sat;

   function Sub_Sat (Left, Right : Fix16) return Fix16 is
      L : constant Long_Float := Long_Float(Left);
      R : constant Long_Float := Long_Float(Right);
      Res : constant Long_Float := L - R;
   begin
      if Res > Long_Float(Fix16'Last) then
         return Fix16'Last;
      elsif Res < Long_Float(Fix16'First) then
         return Fix16'First;
      else
         return Fix16(Res);
      end if;
   end Sub_Sat;

   function Mul_Sat (Left, Right : Fix16) return Fix16 is
      L : constant Long_Float := Long_Float(Left);
      R : constant Long_Float := Long_Float(Right);
      Res : constant Long_Float := L * R;
   begin
      if Res > Long_Float(Fix16'Last) then
         return Fix16'Last;
      elsif Res < Long_Float(Fix16'First) then
         return Fix16'First;
      else
         return Fix16(Res);
      end if;
   end Mul_Sat;

   function Div_Sat (Left, Right : Fix16) return Fix16 is
      L : constant Long_Float := Long_Float(Left);
      R : constant Long_Float := Long_Float(Right);
      Res : Long_Float;
   begin
      if Right = 0.0 then
         -- Return Max or Min depending on sign of Left
         if Left >= 0.0 then return Fix16'Last; else return Fix16'First; end if;
      end if;

      Res := L / R;

      if Res > Long_Float(Fix16'Last) then
         return Fix16'Last;
      elsif Res < Long_Float(Fix16'First) then
         return Fix16'First;
      else
         return Fix16(Res);
      end if;
   end Div_Sat;

   -- [TITANIUM NEW] Saturating Absolute Value
   function Abs_Sat (Value : Fix16) return Fix16 is
   begin
      -- Edge case: Abs(Min_Val) is 32768.0, which is > Max_Val (32767.99998)
      if Value = Fix16'First then
         return Fix16'Last;
      elsif Value < 0.0 then
         return -Value;
      else
         return Value;
      end if;
   end Abs_Sat;

   -------------------------------------------------------------------------
   -- Conversions
   -------------------------------------------------------------------------
   function From_Int (Value : Integer) return Fix16 is
   begin
      if Value > Integer(Fix16'Last) then return Fix16'Last; end if;
      if Value < Integer(Fix16'First) then return Fix16'First; end if;
      return Fix16(Value);
   end From_Int;

   function To_Int (Value : Fix16) return Integer is
   begin
      return Integer(Value);
   end To_Int;

   function From_Float (Value : Float) return Fix16 is
   begin
      if Value > Float(Fix16'Last) then return Fix16'Last; end if;
      if Value < Float(Fix16'First) then return Fix16'First; end if;
      return Fix16(Value);
   end From_Float;

   function To_Float (Value : Fix16) return Float is
   begin
      return Float(Value);
   end To_Float;

   -------------------------------------------------------------------------
   -- Comparisons
   -------------------------------------------------------------------------
   function Approx_Equal (A, B : Fix16; Tolerance : Fix16 := Epsilon) return Boolean is
      Diff : Fix16;
   begin
      -- Safe difference calculation
      if A > B then Diff := A - B;
      else Diff := B - A;
      end if;
      
      return Diff <= Tolerance;
   end Approx_Equal;

end GD_Fixed;