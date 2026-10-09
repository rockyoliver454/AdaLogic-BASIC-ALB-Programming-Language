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

package Geo_Voxel_Ops is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Constants (Fixed Volume)
   -------------------------------------------------------------------------
   Chunk_Size : constant Integer := 16;
   Total_Bits : constant Integer := Chunk_Size * Chunk_Size * Chunk_Size; -- 4096
   
   -- We pack 4096 bits into 64-bit integers.
   -- 4096 / 64 = 64 integers exactly.
   Storage_Size : constant Integer := Total_Bits / 64;

   -------------------------------------------------------------------------
   -- Data Structures
   -------------------------------------------------------------------------
   type Bit_Word is new Unsigned_64;
   type Storage_Array is array (0 .. Storage_Size - 1) of Bit_Word;

   type Voxel_Chunk is record
      Bits : Storage_Array;
   end record;

   -------------------------------------------------------------------------
   -- Basic Operations
   -------------------------------------------------------------------------
   function Create_Empty return Voxel_Chunk;
   function Create_Solid return Voxel_Chunk;

   procedure Set_Voxel (C : in out Voxel_Chunk; X, Y, Z : Integer; Value : Boolean);
   function Get_Voxel (C : Voxel_Chunk; X, Y, Z : Integer) return Boolean;

   -------------------------------------------------------------------------
   -- Volumetric Operations (Constructive Solid Geometry)
   -------------------------------------------------------------------------
   -- Sets all voxels inside the sphere to 'Value' (True=Add, False=Carve)
   -- Center is in Grid Space (e.g., 8.0, 8.0, 8.0 is middle)
   procedure Rasterize_Sphere 
     (C      : in out Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float; 
      Value      : Boolean);

   -------------------------------------------------------------------------
   -- Analysis
   -------------------------------------------------------------------------
   -- Returns true if the chunk is completely empty (Optimization hint)
   function Is_Empty (C : Voxel_Chunk) return Boolean;

end Geo_Voxel_Ops;