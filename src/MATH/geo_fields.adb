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

with GD_Fixed; use GD_Fixed;
with Geo_Vec2; use Geo_Vec2;
with Interfaces; use Interfaces; -- [TITANIUM FIX] Needed for Unsigned_32 and bitwise ops

package body Geo_Fields is

   -------------------------------------------------------------------------
   -- Hashing / Random
   -------------------------------------------------------------------------
   function Hash (X, Y, Seed : Integer) return Fix16 is
      -- [TITANIUM FIX] Use Unsigned_32 for bitwise math logic
      U_N : Unsigned_32;
   begin
      -- 'Mod handles negative integers by wrapping correctly
      U_N := Unsigned_32'Mod(X) + Unsigned_32'Mod(Y) * 57 + Unsigned_32'Mod(Seed) * 131;
      
      -- Integer hashing math with wrapping overflow
      U_N := (U_N * (U_N * U_N * 15731 + 789221) + 1376312589) and 16#7fffffff#;
      
      return From_Float(1.0 - Float(U_N) / 1073741824.0);
   end Hash;

   function Smooth_Step_Kernel (T : Fix16) return Fix16 is
      T2 : Fix16;
      T3 : Fix16;
      Term1 : Fix16;
      Term2 : Fix16;
   begin
      T2 := Mul_Sat(T, T);
      T3 := Mul_Sat(T2, T);
      Term1 := Mul_Sat(From_Int(3), T2);
      Term2 := Mul_Sat(From_Int(2), T3);
      return Sub_Sat(Term1, Term2);
   end Smooth_Step_Kernel;

   -------------------------------------------------------------------------
   -- Noise Implementation
   -------------------------------------------------------------------------
   function Noise_2D (X, Y : Fix16; Scale : Fix16; Seed : Integer) return Fix16 is
      SX, SY : Fix16;
      IX, IY : Integer;
      FX, FY : Fix16;
      N00, N10, N01, N11 : Fix16;
      U, V : Fix16;
      NX0, NX1 : Fix16;
   begin
      SX := Mul_Sat(X, Scale);
      SY := Mul_Sat(Y, Scale);
      
      IX := To_Int(SX); 
      IY := To_Int(SY);
      
      -- Fractional parts
      FX := Sub_Sat(SX, From_Int(IX));
      FY := Sub_Sat(SY, From_Int(IY));
      
      -- Corners
      N00 := Hash(IX,     IY,     Seed);
      N10 := Hash(IX + 1, IY,     Seed);
      N01 := Hash(IX,     IY + 1, Seed);
      N11 := Hash(IX + 1, IY + 1, Seed);
      
      -- Interpolate
      U := Smooth_Step_Kernel(FX);
      V := Smooth_Step_Kernel(FY);
      
      -- Lerp X
      NX0 := Add_Sat(N00, Mul_Sat(U, Sub_Sat(N10, N00)));
      NX1 := Add_Sat(N01, Mul_Sat(U, Sub_Sat(N11, N01)));
      
      -- Lerp Y
      return Add_Sat(NX0, Mul_Sat(V, Sub_Sat(NX1, NX0)));
   end Noise_2D;

   -------------------------------------------------------------------------
   -- Vector Fields
   -------------------------------------------------------------------------
   function Gradient_Noise (Pos : Vec2; Scale : Fix16; Seed : Integer) return Vec2 is
      Eps : Fix16 := From_Float(0.01);
      H_Center : Fix16;
      H_Right  : Fix16;
      H_Up     : Fix16;
      DX, DY   : Fix16;
   begin
      H_Center := Noise_2D(Pos.X, Pos.Y, Scale, Seed);
      H_Right  := Noise_2D(Add_Sat(Pos.X, Eps), Pos.Y, Scale, Seed);
      H_Up     := Noise_2D(Pos.X, Add_Sat(Pos.Y, Eps), Scale, Seed);
      
      DX := Sub_Sat(H_Right, H_Center);
      DY := Sub_Sat(H_Up, H_Center);
      
      return Create(DX, DY);
   end Gradient_Noise;

   function Vortex (Pos : Vec2; Center : Vec2; Strength : Fix16; Decay : Fix16) return Vec2 is
      Diff : Vec2 := Sub(Pos, Center);
      Len  : Fix16 := Length(Diff);
      Mag  : Fix16;
      Perp : Vec2;
   begin
      if Len <= Epsilon then return Geo_Vec2.Zero; end if;
      
      Mag := Div_Sat(Strength, Add_Sat(GD_Fixed.One, Mul_Sat(Decay, Len)));
      
      -- Tangent direction: (-y, x)
      -- [TITANIUM FIX] Use scalar negation (-Diff.Y) instead of Geo_Vec2.Negate
      Perp := Create(-Diff.Y, Diff.X);
      Perp := Normalize(Perp);
      
      return Scale(Perp, Mag);
   end Vortex;

   function Radial_Source (Pos : Vec2; Center : Vec2; Strength : Fix16; Decay : Fix16) return Vec2 is
      Diff : Vec2 := Sub(Pos, Center);
      Len  : Fix16 := Length(Diff);
      Mag  : Fix16;
   begin
      if Len <= Epsilon then return Geo_Vec2.Zero; end if;
      
      Mag := Div_Sat(Strength, Add_Sat(GD_Fixed.One, Mul_Sat(Decay, Len)));
      
      return Scale(Normalize(Diff), Mag);
   end Radial_Source;

   function Curl_Noise (Pos : Vec2; Scale : Fix16; Seed : Integer) return Vec2 is
      Eps : Fix16 := From_Float(0.01);
      N0, N1, N2 : Fix16;
      Dy_N, Dx_N : Fix16;
   begin
      N0 := Noise_2D(Pos.X, Pos.Y, Scale, Seed);
      N1 := Noise_2D(Add_Sat(Pos.X, Eps), Pos.Y, Scale, Seed); -- x + eps
      N2 := Noise_2D(Pos.X, Add_Sat(Pos.Y, Eps), Scale, Seed); -- y + eps
      
      Dx_N := Sub_Sat(N1, N0);
      Dy_N := Sub_Sat(N2, N0);
      
      -- Vector = (dPsi/dy, -dPsi/dx)
      return Create(Dy_N, Sub_Sat(GD_Fixed.Zero, Dx_N));
   end Curl_Noise;

end Geo_Fields;