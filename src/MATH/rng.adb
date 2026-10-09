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

package body RNG is

   procedure Init (Gen : out Generator; Seed : Unsigned_32) is
      Safe_Seed : Unsigned_32 := Seed;
   begin
      if Safe_Seed = 0 then
         Safe_Seed := 16#DEADC0DE#;
      end if;
      Gen.State := Safe_Seed;
   end Init;

   function Next (Gen : in out Generator) return Unsigned_32 is
      X : Unsigned_32 := Gen.State;
   begin
      -- Xorshift32 algorithm
      X := X xor Shift_Left(X, 13);
      X := X xor Shift_Right(X, 17);
      X := X xor Shift_Left(X, 5);
      
      Gen.State := X;
      return X;
   end Next;

   function Range_Int (Gen : in out Generator; Min, Max : Integer) return Integer is
      Range_Span : constant Unsigned_32 := Unsigned_32(Max - Min + 1);
      Raw        : constant Unsigned_32 := Next(Gen);
   begin
      if Min = Max then return Min; end if;
      return Min + Integer(Raw mod Range_Span);
   end Range_Int;

   function Next_Fixed (Gen : in out Generator) return Fix16 is
      Raw     : constant Unsigned_32 := Next(Gen);
      Reduced : constant Integer     := Integer(Shift_Right(Raw, 16));
   begin
      -- [TITANIUM FIX] Prevent Overflow
      -- Reduced is 0..65535. Fix16(Reduced) would crash because max is ~32768.
      -- We must scale it down using Float math BEFORE converting to Fix16.
      -- 2.0**(-16) is exactly Fix16'Small.
      return Fix16(Float(Reduced) * 2.0**(-16)); 
   end Next_Fixed;

   function Chance (Gen : in out Generator; Probability : Fix16) return Boolean is
      Roll : Fix16;
   begin
      if Probability <= Zero then return False; end if;
      if Probability >= One then return True; end if;
      
      Roll := Next_Fixed(Gen);
      return Roll < Probability;
   end Chance;

end RNG;
