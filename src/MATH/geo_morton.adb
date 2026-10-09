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

package body Geo_Morton is

   -------------------------------------------------------------------------
   -- Bit Manipulation Helpers
   -------------------------------------------------------------------------
   -- Spreads the lower 16 bits of x into 32 bits (000000000000abcd -> 0a0b0c0d)
   function Part_1_By_1 (Val : Unsigned_32) return Unsigned_32 is
      X : Unsigned_32 := Val;
   begin
      X := X and 16#0000_FFFF#;
      X := (X xor Shift_Left(X, 8)) and 16#00FF_00FF#;
      X := (X xor Shift_Left(X, 4)) and 16#0F0F_0F0F#;
      X := (X xor Shift_Left(X, 2)) and 16#3333_3333#;
      X := (X xor Shift_Left(X, 1)) and 16#5555_5555#;
      return X;
   end Part_1_By_1;

   -- Compacts 32 bits back to 16 (Inverse of Part_1_By_1)
   function Compact_1_By_1 (Val : Unsigned_32) return Unsigned_32 is
      X : Unsigned_32 := Val;
   begin
      X := X and 16#5555_5555#;
      X := (X xor Shift_Right(X, 1)) and 16#3333_3333#;
      X := (X xor Shift_Right(X, 2)) and 16#0F0F_0F0F#;
      X := (X xor Shift_Right(X, 4)) and 16#00FF_00FF#;
      X := (X xor Shift_Right(X, 8)) and 16#0000_FFFF#;
      return X;
   end Compact_1_By_1;

   -------------------------------------------------------------------------
   -- Encoding / Decoding
   -------------------------------------------------------------------------
   function Encode_2D (X, Y : Integer) return Morton_Code is
      UX : Unsigned_32 := Unsigned_32(Integer'Max(0, Integer'Min(65535, X)));
      UY : Unsigned_32 := Unsigned_32(Integer'Max(0, Integer'Min(65535, Y)));
   begin
      return Morton_Code(Part_1_By_1(UX) or Shift_Left(Part_1_By_1(UY), 1));
   end Encode_2D;

   procedure Decode_2D (Code : Morton_Code; X, Y : out Integer) is
      Val : Unsigned_32 := Unsigned_32(Code);
   begin
      X := Integer(Compact_1_By_1(Val));
      Y := Integer(Compact_1_By_1(Shift_Right(Val, 1)));
   end Decode_2D;

   function Encode_Point (X, Y : Fix16) return Morton_Code is
   begin
      -- Direct integer mapping. In a real engine, you might scale this 
      -- relative to a world bounds (e.g., (X + Offset) * Scale).
      -- For now, we assume X/Y are already in grid coordinates.
      return Encode_2D(To_Int(X), To_Int(Y));
   end Encode_Point;

   -------------------------------------------------------------------------
   -- Traversal
   -------------------------------------------------------------------------
   function Neighbor (Code : Morton_Code; DX, DY : Integer) return Morton_Code is
      X, Y : Integer;
   begin
      Decode_2D(Code, X, Y);
      return Encode_2D(X + DX, Y + DY);
   end Neighbor;

   procedure Get_Range (Min_X, Min_Y, Max_X, Max_Y : Fix16; 
                        Start_Code, End_Code : out Morton_Code) is
   begin
      -- Z-order curve preserves locality but not simple range continuity.
      -- This provides the absolute min and max codes covering the box.
      -- Iterating between Start and End will cover the box + extra zigzag areas.
      Start_Code := Encode_Point(Min_X, Min_Y);
      End_Code   := Encode_Point(Max_X, Max_Y);
   end Get_Range;

end Geo_Morton;