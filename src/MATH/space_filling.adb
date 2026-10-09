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

package body Space_Filling is

   -------------------------------------------------------------------------
   -- Helper: Spread Bits
   -- Spreads 16 bits into 32 bits (0000... -> 0 0 0 0...)
   -------------------------------------------------------------------------
   function Spread_Bits (Value : Unsigned_32) return Unsigned_32 is
      V : Unsigned_32 := Value;
   begin
      -- Rule: Assertions for input bounds (Standard NASA/Titanium rule)
      pragma Assert (V <= 16#FFFF#);

      -- Magic Number Bit Spreading
      -- Matches logic in space_filling.c
      V := (V or Shift_Left(V, 8)) and 16#00FF00FF#;
      V := (V or Shift_Left(V, 4)) and 16#0F0F0F0F#;
      V := (V or Shift_Left(V, 2)) and 16#33333333#;
      V := (V or Shift_Left(V, 1)) and 16#55555555#;
      
      return V;
   end Spread_Bits;

   -------------------------------------------------------------------------
   -- Morton Encode
   -------------------------------------------------------------------------
   function Morton_Encode (X, Y : Unsigned_16) return Unsigned_32 is
      X32 : constant Unsigned_32 := Unsigned_32(X);
      Y32 : constant Unsigned_32 := Unsigned_32(Y);
   begin
      -- Logic: Spread X (Even bits) | Spread Y (Odd bits)
      return Spread_Bits(X32) or Shift_Left(Spread_Bits(Y32), 1);
   end Morton_Encode;

end Space_Filling;