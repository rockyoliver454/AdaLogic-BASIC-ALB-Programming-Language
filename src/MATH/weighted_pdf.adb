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

with Interfaces; use Interfaces;

package body Weighted_PDF is

   procedure Init (Sys : out PDF_System) is
      -- Registers
      P_Idx, One_Const, Out_Val : Integer;
   begin
      Sys.Count := 0;

      -- 1. Outcome 0: "Common" (1.0 - Pressure)
      declare
         -- Renaming works perfectly with the named Curve_Array type
         E : Expression renames Sys.Weight_Curves(0);
      begin
         Clear(E);
         P_Idx     := Add_Var(E, 0); -- Pressure
         One_Const := Add_Const(E, One);
         Out_Val   := Add_Sub(E, One_Const, P_Idx);
         Sys.Count := Sys.Count + 1;
      end;

      -- 2. Outcome 1: "Elite" (Pressure * Pressure)
      declare
         E : Expression renames Sys.Weight_Curves(1);
      begin
         Clear(E);
         P_Idx   := Add_Var(E, 0);
         Out_Val := Add_Mul(E, P_Idx, P_Idx);
         Sys.Count := Sys.Count + 1;
      end;
      
      pragma Assert (Sys.Count > 0);
   end Init;

   function Roll (Sys : PDF_System; Gen : in out Generator; Pressure_Val : Fix16) return Integer is
      -- [TITANIUM FIX] Named type for local array safety
      type Weight_Array is array (0 .. Max_Outcomes - 1) of Fix16;
      
      Weights    : Weight_Array;
      Vars       : Variable_Table := (others => Zero);
      Total_Mass : Unsigned_64 := 0; 
      
      RNG_Raw    : Unsigned_32;
      Roll_Val   : Unsigned_64;
      Accum      : Unsigned_64 := 0;
   begin
      Vars(0) := Pressure_Val;

      -- 1. Evaluate Weights & Total Mass
      for I in 0 .. Sys.Count - 1 loop
         Weights(I) := Evaluate(Sys.Weight_Curves(I), Vars);
         
         if Weights(I) < Zero then Weights(I) := Zero; end if;
         
         -- Convert Fixed Point (scaled by 2^16) directly to integer mass
         Total_Mass := Total_Mass + Unsigned_64(To_Int(Weights(I) * From_Int(65536))); 
      end loop;

      if Total_Mass = 0 then return 0; end if;

      -- 2. High Precision Roll
      -- Map RNG (0..65535) to Total_Mass
      RNG_Raw  := Shift_Right(Next(Gen), 16); -- 16-bit entropy
      Roll_Val := (Unsigned_64(RNG_Raw) * Total_Mass) / 65536;

      -- 3. Selection
      for I in 0 .. Sys.Count - 1 loop
         declare
            Weight_Int : Unsigned_64 := Unsigned_64(To_Int(Weights(I) * From_Int(65536)));
         begin
            Accum := Accum + Weight_Int;
            if Roll_Val < Accum then
               return I;
            end if;
         end;
      end loop;

      return Sys.Count - 1;
   end Roll;

end Weighted_PDF;