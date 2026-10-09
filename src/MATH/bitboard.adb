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

package body Bitboard is

   -------------------------------------------------------------------------
   -- Pop Count (SWar Algorithm)
   -------------------------------------------------------------------------
   function Pop_Count (B : Board) return Integer is
      X : Board := B;
      K55 : constant Board := 16#5555555555555555#;
      K33 : constant Board := 16#3333333333333333#;
      K0F : constant Board := 16#0F0F0F0F0F0F0F0F#;
      K01 : constant Board := 16#0101010101010101#;
   begin
      -- b = b - ((b >> 1) & 0x55...)
      X := X - (Shift_Right(X, 1) and K55);
      -- b = (b & 0x33...) + ((b >> 2) & 0x33...)
      X := (X and K33) + (Shift_Right(X, 2) and K33);
      -- b = (b + (b >> 4)) & 0x0F...
      X := (X + Shift_Right(X, 4)) and K0F;
      
      -- return (b * 0x01...) >> 56
      return Integer(Shift_Right(X * K01, 56));
   end Pop_Count;

   -------------------------------------------------------------------------
   -- Get LSB (De Bruijn Sequence)
   -------------------------------------------------------------------------
   function Get_LSB (B : Board) return Integer is
      -- Magic De Bruijn Sequence
      type Table_Array is array (0 .. 63) of Integer;
      Magic_Table : constant Table_Array := (
         0, 1, 48, 2, 57, 49, 28, 3, 61, 58, 50, 42, 38, 29, 17, 4,
         62, 47, 56, 31, 22, 45, 51, 33, 53, 43, 39, 24, 13, 30, 18, 5,
         63, 59, 41, 37, 27, 21, 44, 32, 52, 23, 12, 16, 60, 40, 26, 20,
         46, 36, 11, 15, 25, 19, 35, 10, 14, 34, 9, 8, 7, 6, 55, 54
      );
      
      Magic_Num : constant Board := 16#03F79D71B4CB0A89#;
      Isolated  : Board;
      Product   : Board;
      Index     : Integer;
   begin
      if B = 0 then
         return -1;
      end if;

      -- Isolate LSB: b & -b (Two's complement trick)
      -- In Ada unsigned, -B is slightly tricky, use (not B) + 1
      Isolated := B and ((not B) + 1);
      
      -- Multiply by magic number and shift to map unique hash to index
      Product := Isolated * Magic_Num;
      Index   := Integer(Shift_Right(Product, 58));
      
      return Magic_Table(Index);
   end Get_LSB;

   -------------------------------------------------------------------------
   -- Shift
   -------------------------------------------------------------------------
   function Shift (B : Board; DX, DY : Integer) return Board is
      Res : Board := B;
   begin
      -- Vertical Shift
      if DY > 0 then
         Res := Shift_Left(Res, DY * 8);
      elsif DY < 0 then
         Res := Shift_Right(Res, abs(DY) * 8);
      end if;

      -- Horizontal Shift (with Masking)
      if DX > 0 then
         for I in 1 .. DX loop
            Res := Shift_Left(Res and (not File_H), 1);
         end loop;
      elsif DX < 0 then
         for I in 1 .. abs(DX) loop
            Res := Shift_Right(Res and (not File_A), 1);
         end loop;
      end if;

      return Res;
   end Shift;

   function Intersects (A, B : Board) return Boolean is
   begin
      return (A and B) /= 0;
   end Intersects;

   function Is_Set (B : Board; Index : Integer) return Boolean is
   begin
      return (B and Shift_Left(1, Index)) /= 0;
   end Is_Set;

   function Set_Bit (B : Board; Index : Integer) return Board is
   begin
      return B or Shift_Left(1, Index);
   end Set_Bit;

end Bitboard;