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

package body Geo_Voxel_Ops is

   -------------------------------------------------------------------------
   -- Bitwise Helpers
   -------------------------------------------------------------------------
   function Get_Indices (X, Y, Z : Integer) return Integer is
   begin
      -- Wrap coordinates to handle safe access (or assert)
      if X < 0 or X >= Chunk_Size or 
         Y < 0 or Y >= Chunk_Size or 
         Z < 0 or Z >= Chunk_Size 
      then
         return -1; -- Invalid
      end if;
      return X + (Y * Chunk_Size) + (Z * Chunk_Size * Chunk_Size);
   end Get_Indices;

   -------------------------------------------------------------------------
   -- Basic Operations
   -------------------------------------------------------------------------
   function Create_Empty return Voxel_Chunk is
      C : Voxel_Chunk;
   begin
      C.Bits := (others => 0);
      return C;
   end Create_Empty;

   function Create_Solid return Voxel_Chunk is
      C : Voxel_Chunk;
   begin
      C.Bits := (others => Bit_Word'Last); -- All 1s
      return C;
   end Create_Solid;

   procedure Set_Voxel (C : in out Voxel_Chunk; X, Y, Z : Integer; Value : Boolean) is
      Total_Idx : Integer;
      Word_Idx  : Integer;
      Bit_Idx   : Integer;
      Mask      : Bit_Word;
   begin
      Total_Idx := Get_Indices(X, Y, Z);
      if Total_Idx = -1 then return; end if;

      Word_Idx := Total_Idx / 64;
      Bit_Idx  := Total_Idx mod 64;
      Mask     := Shift_Left(1, Bit_Idx);

      if Value then
         C.Bits(Word_Idx) := C.Bits(Word_Idx) or Mask;
      else
         C.Bits(Word_Idx) := C.Bits(Word_Idx) and (not Mask);
      end if;
   end Set_Voxel;

   function Get_Voxel (C : Voxel_Chunk; X, Y, Z : Integer) return Boolean is
      Total_Idx : Integer;
      Word_Idx  : Integer;
      Bit_Idx   : Integer;
   begin
      Total_Idx := Get_Indices(X, Y, Z);
      if Total_Idx = -1 then return False; end if; -- Boundary is empty

      Word_Idx := Total_Idx / 64;
      Bit_Idx  := Total_Idx mod 64;
      
      return (C.Bits(Word_Idx) and Shift_Left(1, Bit_Idx)) /= 0;
   end Get_Voxel;

   -------------------------------------------------------------------------
   -- Volumetric Operations
   -------------------------------------------------------------------------
   procedure Rasterize_Sphere 
     (C      : in out Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float; 
      Value      : Boolean) 
   is
      R2 : constant Float := Radius * Radius;
      DX, DY, DZ : Float;
      Dist_Sq : Float;
      
      -- Bounding Box Optimization
      Min_X : Integer := Integer(CX - Radius);
      Max_X : Integer := Integer(CX + Radius);
      Min_Y : Integer := Integer(CY - Radius);
      Max_Y : Integer := Integer(CY + Radius);
      Min_Z : Integer := Integer(CZ - Radius);
      Max_Z : Integer := Integer(CZ + Radius);
   begin
      -- Clamp to grid
      if Min_X < 0 then Min_X := 0; end if;
      if Max_X >= Chunk_Size then Max_X := Chunk_Size - 1; end if;
      if Min_Y < 0 then Min_Y := 0; end if;
      if Max_Y >= Chunk_Size then Max_Y := Chunk_Size - 1; end if;
      if Min_Z < 0 then Min_Z := 0; end if;
      if Max_Z >= Chunk_Size then Max_Z := Chunk_Size - 1; end if;

      for Z in Min_Z .. Max_Z loop
         DZ := Float(Z) - CZ;
         for Y in Min_Y .. Max_Y loop
            DY := Float(Y) - CY;
            for X in Min_X .. Max_X loop
               DX := Float(X) - CX;
               
               Dist_Sq := (DX*DX) + (DY*DY) + (DZ*DZ);
               
               if Dist_Sq <= R2 then
                  Set_Voxel(C, X, Y, Z, Value);
               end if;
            end loop;
         end loop;
      end loop;
   end Rasterize_Sphere;

   function Is_Empty (C : Voxel_Chunk) return Boolean is
   begin
      for I in C.Bits'Range loop
         if C.Bits(I) /= 0 then
            return False;
         end if;
      end loop;
      return True;
   end Is_Empty;

end Geo_Voxel_Ops;