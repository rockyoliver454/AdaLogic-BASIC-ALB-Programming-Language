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

with GD_CORDIC;
with Fixed_Sqrt; use Fixed_Sqrt; -- [TITANIUM FIX] Use binary restoration sqrt

package body Geo_Skinning is

   function Normalize (M : Motor) return Motor is
      Len_Sq : Fix16;
      Len    : Fix16;
      Inv    : Fix16;
      Result : Motor := M;
   begin
      Len_Sq := Add_Sat(Mul_Sat(M.C, M.C), Mul_Sat(M.S, M.S));
      Len    := Sqrt(Len_Sq);

      if Len > Zero then
         Inv := Div_Sat(One, Len);
         Result.C := Mul_Sat(M.C, Inv);
         Result.S := Mul_Sat(M.S, Inv);
      else
         Result.C := One;
         Result.S := Zero;
      end if;
      return Result;
   end Normalize;

   function Identity return Motor is
   begin
      return (C => One, S => Zero, TX => Zero, TY => Zero);
   end Identity;

   function Create (Angle : Fix16; TX, TY : Fix16) return Motor is
      M : Motor;
   begin
      GD_CORDIC.Sin_Cos(Angle, M.S, M.C);
      M.TX := TX;
      M.TY := TY;
      return Normalize(M);
   end Create;

   function Blend (A : Motor; WA : Fix16; B : Motor; WB : Fix16) return Motor is
      Dot      : Fix16;
      Target_B : Motor := B;
      Result   : Motor;
   begin
      -- Hemisphere check (Dot product of rotors)
      Dot := Add_Sat(Mul_Sat(A.C, B.C), Mul_Sat(A.S, B.S));
      if Dot < Zero then
         Target_B.C := -B.C;
         Target_B.S := -B.S;
         Target_B.TX := -B.TX; 
         Target_B.TY := -B.TY;
      end if;

      Result.C := Add_Sat(Mul_Sat(A.C, WA), Mul_Sat(Target_B.C, WB));
      Result.S := Add_Sat(Mul_Sat(A.S, WA), Mul_Sat(Target_B.S, WB));
      Result.TX := Add_Sat(Mul_Sat(A.TX, WA), Mul_Sat(Target_B.TX, WB));
      Result.TY := Add_Sat(Mul_Sat(A.TY, WA), Mul_Sat(Target_B.TY, WB));

      return Normalize(Result);
   end Blend;

   procedure Transform (M : Motor; X, Y : in Fix16; Out_X, Out_Y : out Fix16) is
      RX, RY : Fix16;
   begin
      -- Rotate
      RX := Sub_Sat(Mul_Sat(M.C, X), Mul_Sat(M.S, Y));
      RY := Add_Sat(Mul_Sat(M.S, X), Mul_Sat(M.C, Y));

      -- Translate
      Out_X := Add_Sat(RX, M.TX);
      Out_Y := Add_Sat(RY, M.TY);
   end Transform;

end Geo_Skinning;