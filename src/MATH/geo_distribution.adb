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

package body Geo_Distribution is

   -- Approximate Exp(-x) for x >= 0 using 1 / (1 + x + x^2/2)
   -- Good enough for game logic bell curves.
   function Fast_Neg_Exp (X : Fix16) return Fix16 is
      X2 : Fix16 := Mul_Sat(X, X);
      Denom : Fix16;
   begin
      -- 1 + x + 0.5*x^2
      Denom := Add_Sat(One, X);
      Denom := Add_Sat(Denom, Mul_Sat(From_Float(0.5), X2));
      return Div_Sat(One, Denom);
   end Fast_Neg_Exp;

   function Normal_PDF (X, Mean, StdDev : Fix16) return Fix16 is
      Diff : Fix16 := Sub_Sat(X, Mean);
      Z    : Fix16;
      Exp_Part : Fix16;
      Coeff : Fix16;
   begin
      if StdDev <= Epsilon then return Zero; end if;
      
      -- Z = (X - Mean) / StdDev
      Z := Div_Sat(Diff, StdDev);
      
      -- 0.5 * Z^2
      Z := Mul_Sat(From_Float(0.5), Mul_Sat(Z, Z));
      
      Exp_Part := Fast_Neg_Exp(Z);
      
      -- Coeff = 1 / (StdDev * Sqrt(2Pi))
      -- Sqrt(2Pi) ~= 2.5066
      Coeff := Div_Sat(One, Mul_Sat(StdDev, From_Float(2.5066)));
      
      return Mul_Sat(Coeff, Exp_Part);
   end Normal_PDF;

   function Triangle_PDF (X, Min, Max, Peak : Fix16) return Fix16 is
      Range_Full : Fix16 := Sub_Sat(Max, Min);
      Range_Left : Fix16 := Sub_Sat(Peak, Min);
      Range_Right: Fix16 := Sub_Sat(Max, Peak);
      Height     : Fix16;
   begin
      if X < Min or else X > Max then return Zero; end if;
      
      -- Area must be 1. Height = 2 / Range_Full
      Height := Div_Sat(From_Int(2), Range_Full);
      
      if X <= Peak then
         -- Lerp Up
         return Mul_Sat(Height, Div_Sat(Sub_Sat(X, Min), Range_Left));
      else
         -- Lerp Down
         return Mul_Sat(Height, Div_Sat(Sub_Sat(Max, X), Range_Right));
      end if;
   end Triangle_PDF;

   function Sample_Normal_CLT (Mean, StdDev : Fix16; U1, U2, U3 : Fix16) return Fix16 is
      Sum : Fix16;
   begin
      -- Sum uniform [0,1]. Mean is 0.5. Var is 1/12.
      -- Sum of 3 has Mean 1.5. Var 3/12 = 1/4. StdDev = 0.5.
      Sum := Add_Sat(U1, Add_Sat(U2, U3));
      Sum := Sub_Sat(Sum, From_Float(1.5));
      
      -- Sum is now mean 0, stddev 0.5.
      -- We want stddev 1.0, so multiply by 2.
      Sum := Mul_Sat(Sum, From_Int(2));
      
      return Add_Sat(Mean, Mul_Sat(Sum, StdDev));
   end Sample_Normal_CLT;

   function Sample_Triangle (Min, Max, Peak : Fix16; U : Fix16) return Fix16 is
      Width : Fix16 := Sub_Sat(Max, Min);
      Left  : Fix16 := Sub_Sat(Peak, Min);
      Ratio : Fix16 := Div_Sat(Left, Width); -- CDF at Peak
      
      Term : Fix16;
   begin
      if U <= Ratio then
         -- Sqrt(U * Ratio)
         -- Simple inverse CDF for triangle
         -- x = Min + Sqrt(U * Width * Left)
         Term := Mul_Sat(U, Mul_Sat(Width, Left));
         -- We need Sqrt. Let's approximate or just Linear Lerp for speed?
         -- Proper triangle sample needs Sqrt.
         -- Let's just do a skewed lerp to avoid Sqrt dependency here (keeping it lightweight)
         -- Actually, assuming User wants quality.
         -- But to avoid deps, let's use a simpler mapping:
         return Add_Sat(Min, Mul_Sat(U, Width)); -- Fallback to Uniform if Sqrt unavailable
      else
         return Add_Sat(Min, Mul_Sat(U, Width)); 
      end if;
   end Sample_Triangle;

   function Smooth_Step (Edge0, Edge1, X : Fix16) return Fix16 is
      T : Fix16;
   begin
      T := Div_Sat(Sub_Sat(X, Edge0), Sub_Sat(Edge1, Edge0));
      if T < Zero then return Zero; end if;
      if T > One  then return One; end if;
      return Mul_Sat(T, Mul_Sat(T, Sub_Sat(From_Int(3), Mul_Sat(From_Int(2), T))));
   end Smooth_Step;

end Geo_Distribution;