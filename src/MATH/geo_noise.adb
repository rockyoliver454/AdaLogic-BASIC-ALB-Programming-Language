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
-- [TITANIUM FIX] Explicitly qualify constants to avoid ambiguity
with GD_Fixed; use GD_Fixed;
with Geo_Vec2; use Geo_Vec2;

package body Geo_Noise is

   -------------------------------------------------------------------------
   -- Hashing Helpers
   -------------------------------------------------------------------------
   function Hash (X, Y, Seed : Integer) return Fix16 is
      U_N : Unsigned_32;
   begin
      U_N := Unsigned_32'Mod(X) + Unsigned_32'Mod(Y) * 57 + Unsigned_32'Mod(Seed) * 131;
      U_N := (U_N * (U_N * U_N * 15731 + 789221) + 1376312589) and 16#7fffffff#;
      return From_Float(1.0 - Float(U_N) / 1073741824.0);
   end Hash;

   function Get_Gradient (X, Y, Seed : Integer) return Vec2 is
      H : Unsigned_32;
      Res : Vec2;
      -- [TITANIUM FIX] Short aliases for readability
      F_One  : Fix16 := GD_Fixed.One;
      F_Zero : Fix16 := GD_Fixed.Zero;
   begin
      H := Unsigned_32'Mod(X) + Unsigned_32'Mod(Y) * 57 + Unsigned_32'Mod(Seed) * 131;
      H := (H * (H * H * 15731 + 789221) + 1376312589) and 7;
      
      case H is
         when 0 => Res := Create(F_One, F_Zero);
         when 1 => Res := Create(-F_One, F_Zero);
         when 2 => Res := Create(F_Zero, F_One);
         when 3 => Res := Create(F_Zero, -F_One);
         when 4 => Res := Normalize(Create(F_One, F_One));
         when 5 => Res := Normalize(Create(-F_One, F_One));
         when 6 => Res := Normalize(Create(F_One, -F_One));
         when others => Res := Normalize(Create(-F_One, -F_One));
      end case;
      return Res;
   end Get_Gradient;

   function Smooth_Curve (T : Fix16) return Fix16 is
      T2 : Fix16 := Mul_Sat(T, T);
      T3 : Fix16 := Mul_Sat(T2, T);
   begin
      return Sub_Sat(Mul_Sat(From_Int(3), T2), Mul_Sat(From_Int(2), T3));
   end Smooth_Curve;

   -------------------------------------------------------------------------
   -- Noise Implementation
   -------------------------------------------------------------------------
   function Noise_Value (P : Vec2; Seed : Integer) return Fix16 is
      IX : Integer := To_Int(P.X);
      IY : Integer := To_Int(P.Y);
      FX, FY : Fix16;
      F_Zero : Fix16 := GD_Fixed.Zero; -- [TITANIUM FIX] Explicit Zero
   begin
      if P.X < F_Zero and then P.X /= From_Int(IX) then IX := IX - 1; end if;
      if P.Y < F_Zero and then P.Y /= From_Int(IY) then IY := IY - 1; end if;

      FX := Sub_Sat(P.X, From_Int(IX));
      FY := Sub_Sat(P.Y, From_Int(IY));

      declare
         V00 : Fix16 := Hash(IX,   IY,   Seed);
         V10 : Fix16 := Hash(IX+1, IY,   Seed);
         V01 : Fix16 := Hash(IX,   IY+1, Seed);
         V11 : Fix16 := Hash(IX+1, IY+1, Seed);
         
         U : Fix16 := Smooth_Curve(FX);
         V : Fix16 := Smooth_Curve(FY);
         
         L1 : Fix16 := Add_Sat(V00, Mul_Sat(U, Sub_Sat(V10, V00)));
         L2 : Fix16 := Add_Sat(V01, Mul_Sat(U, Sub_Sat(V11, V01)));
      begin
         return Add_Sat(L1, Mul_Sat(V, Sub_Sat(L2, L1)));
      end;
   end Noise_Value;

   function Noise_Gradient (P : Vec2; Seed : Integer) return Fix16 is
      IX : Integer := To_Int(P.X);
      IY : Integer := To_Int(P.Y);
      FX, FY : Fix16;
      F_Zero : Fix16 := GD_Fixed.Zero; -- [TITANIUM FIX] Explicit Zero
      F_One  : Fix16 := GD_Fixed.One;  -- [TITANIUM FIX] Explicit One
   begin
      if P.X < F_Zero and then P.X /= From_Int(IX) then IX := IX - 1; end if;
      if P.Y < F_Zero and then P.Y /= From_Int(IY) then IY := IY - 1; end if;

      FX := Sub_Sat(P.X, From_Int(IX));
      FY := Sub_Sat(P.Y, From_Int(IY));

      declare
         G00 : Vec2 := Get_Gradient(IX,   IY,   Seed);
         G10 : Vec2 := Get_Gradient(IX+1, IY,   Seed);
         G01 : Vec2 := Get_Gradient(IX,   IY+1, Seed);
         G11 : Vec2 := Get_Gradient(IX+1, IY+1, Seed);

         D00 : Vec2 := Create(FX, FY);
         D10 : Vec2 := Create(Sub_Sat(FX, F_One), FY);
         D01 : Vec2 := Create(FX, Sub_Sat(FY, F_One));
         D11 : Vec2 := Create(Sub_Sat(FX, F_One), Sub_Sat(FY, F_One));

         N00 : Fix16 := Dot(G00, D00);
         N10 : Fix16 := Dot(G10, D10);
         N01 : Fix16 := Dot(G01, D01);
         N11 : Fix16 := Dot(G11, D11);

         U : Fix16 := Smooth_Curve(FX);
         V : Fix16 := Smooth_Curve(FY);
         
         L1 : Fix16 := Add_Sat(N00, Mul_Sat(U, Sub_Sat(N10, N00)));
         L2 : Fix16 := Add_Sat(N01, Mul_Sat(U, Sub_Sat(N11, N01)));
      begin
         return Add_Sat(L1, Mul_Sat(V, Sub_Sat(L2, L1)));
      end;
   end Noise_Gradient;

   function Noise_Curl (P : Vec2; Seed : Integer) return Vec2 is
      Eps : Fix16 := From_Float(0.01);
      F_Zero : Fix16 := GD_Fixed.Zero; -- [TITANIUM FIX] Explicit Zero
      N1, N2 : Fix16;
      N0 : Fix16 := Noise_Gradient(P, Seed);
      Dx, Dy : Fix16;
   begin
      N1 := Noise_Gradient(Add(P, Create(Eps, F_Zero)), Seed);
      N2 := Noise_Gradient(Add(P, Create(F_Zero, Eps)), Seed);
      
      Dx := Sub_Sat(N1, N0); 
      Dy := Sub_Sat(N2, N0); 
      
      return Create(Dy, -Dx);
   end Noise_Curl;

   function Noise_FBM (P : Vec2; Seed : Integer; Octaves : Integer; 
                       Lacunarity : Fix16 := From_Float(2.0); 
                       Gain       : Fix16 := From_Float(0.5)) return Fix16 is
      Total : Fix16 := GD_Fixed.Zero; -- [TITANIUM FIX] Explicit Zero
      Amp   : Fix16 := From_Float(0.5);
      Pos   : Vec2 := P;
      Max   : Fix16 := GD_Fixed.Zero; -- [TITANIUM FIX] Explicit Zero
   begin
      for I in 1 .. Octaves loop
         Total := Add_Sat(Total, Mul_Sat(Noise_Gradient(Pos, Seed), Amp));
         Max   := Add_Sat(Max, Amp);
         
         Pos := Scale(Pos, Lacunarity);
         Amp := Mul_Sat(Amp, Gain);
      end loop;
      
      return Div_Sat(Total, Max);
   end Noise_FBM;

end Geo_Noise;