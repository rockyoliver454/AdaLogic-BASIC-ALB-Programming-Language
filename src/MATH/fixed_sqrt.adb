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
with Ada.Unchecked_Conversion;

package body Fixed_Sqrt is

   -- Access to raw bits of the fixed point type
   function To_Raw is new Ada.Unchecked_Conversion (Fix16, Integer_32);
   function From_Raw is new Ada.Unchecked_Conversion (Integer_32, Fix16);

   -------------------------------------------------------------------------
   -- Sqrt (Binary Restoration)
   -------------------------------------------------------------------------
   function Sqrt (X : Fix16) return Fix16 is
      Raw_X     : Integer_32;
      Root      : Unsigned_64 := 0;
      Remainder : Unsigned_64;
      Place     : Unsigned_64 := 16#4000_0000_0000_0000#; -- High bit
   begin
      if X <= Zero then
         return Zero;
      end if;

      Raw_X := To_Raw(X);
      
      -- Align to Q16.16 output space (Shift Left 16)
      -- We cast to Unsigned_64 to ensure safe bitwise operations
      Remainder := Unsigned_64(Raw_X) * 65536;

      -- 1. Find the active bit range
      while Place > Remainder loop
         Place := Shift_Right(Place, 2);
      end loop;

      -- 2. Binary Restoration Loop
      while Place /= 0 loop
         if Remainder >= Root + Place then
            Remainder := Remainder - (Root + Place);
            Root      := Shift_Right(Root, 1) + Place;
         else
            Root      := Shift_Right(Root, 1);
         end if;
         Place := Shift_Right(Place, 2);
      end loop;

      -- Result is already in Q16.16 format
      return From_Raw(Integer_32(Root));
   end Sqrt;

   -------------------------------------------------------------------------
   -- Distance
   -------------------------------------------------------------------------
   function Distance (X1, Y1, X2, Y2 : Fix16) return Fix16 is
      DX_Raw : Integer_64;
      DY_Raw : Integer_64;
      Sum_Sq : Integer_64;
      
      -- Helper to safely shift signed 64-bit integers by treating them as unsigned
      function Shift_Signed (Val : Integer_64; Amount : Natural) return Integer_64 is
      begin
         return Integer_64(Shift_Right(Unsigned_64(Val), Amount));
      end Shift_Signed;
   begin
      -- Calculate deltas (Fix16 -> Integer_32 -> Integer_64)
      DX_Raw := Integer_64(To_Raw(Sub_Sat(X2, X1)));
      DY_Raw := Integer_64(To_Raw(Sub_Sat(Y2, Y1)));

      -- Calculate Squares in 64-bit space
      -- (Q16 * Q16) >> 16 = Q16 result
      -- [TITANIUM FIX] Explicit casting to Unsigned_64 for bitwise shift
      Sum_Sq := Shift_Signed(DX_Raw * DX_Raw, 16) + Shift_Signed(DY_Raw * DY_Raw, 16);

      -- Clamp negative results (safety for overflow cases)
      if Sum_Sq < 0 then
         Sum_Sq := 0;
      end if;

      -- Handle potential overflow of the 32-bit container for Sqrt
      if Sum_Sq > Integer_64(Integer_32'Last) then
         return Max_Val; 
      end if;

      return Sqrt(From_Raw(Integer_32(Sum_Sq)));
   end Distance;

end Fixed_Sqrt;