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

package body Geo_Entropy is

   function Log2_Approx (X : Fix16) return Fix16 is
      -- Integer-based Log2 approximation
      Val : Fix16 := X;
      Int_Part : Integer := 0;
      Frac_Part : Fix16;
      Res : Fix16;
   begin
      if Val <= Epsilon then return From_Int(-16); end if; -- Floor
      
      -- Normalize to [1, 2)
      while Val >= From_Int(2) loop
         Val := Mul_Sat(Val, From_Float(0.5));
         Int_Part := Int_Part + 1;
      end loop;
      while Val < One loop
         Val := Mul_Sat(Val, From_Int(2));
         Int_Part := Int_Part - 1;
      end loop;
      
      -- Val is now 1.xxxxx
      -- Linear approx: Log2(x) ~= x - 1 for x in [1,2]
      Frac_Part := Sub_Sat(Val, One);
      
      return Add_Sat(From_Int(Int_Part), Frac_Part);
   end Log2_Approx;

   function Entropy (Probs : Prob_Array) return Fix16 is
      Sum : Fix16 := Zero;
      P   : Fix16;
      LogP : Fix16;
   begin
      for I in Probs'Range loop
         P := Probs(I);
         if P > Epsilon then
            LogP := Log2_Approx(P);
            Sum := Sub_Sat(Sum, Mul_Sat(P, LogP)); -- Sum -= P * LogP
         end if;
      end loop;
      return Sum;
   end Entropy;

   function Variance (Probs : Prob_Array; Values : Prob_Array) return Fix16 is
      Mean : Fix16 := Zero;
      Var  : Fix16 := Zero;
      Diff : Fix16;
      Val  : Fix16;
   begin
      -- Calculate Mean
      for I in Probs'Range loop
         Mean := Add_Sat(Mean, Mul_Sat(Probs(I), Values(I)));
      end loop;
      
      -- Calculate Variance
      for I in Probs'Range loop
         Val := Values(I);
         Diff := Sub_Sat(Val, Mean);
         -- Var += P * Diff^2
         Var := Add_Sat(Var, Mul_Sat(Probs(I), Mul_Sat(Diff, Diff)));
      end loop;
      
      return Var;
   end Variance;

end Geo_Entropy;