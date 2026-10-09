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

package body Geo_Boolean is

   -------------------------------------------------------------------------
   -- Subtract Sphere
   -------------------------------------------------------------------------
   function Subtract_Sphere 
     (C          : in out Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float) return Integer 
   is
      R2 : constant Float := Radius * Radius;
      DX, DY, DZ : Float;
      Dist_Sq    : Float;
      Removed    : Integer := 0;
      
      -- Bounding Box (Clamped to Chunk Size 0..15)
      Min_X : Integer := Integer(Float'Floor(CX - Radius));
      Max_X : Integer := Integer(Float'Ceiling(CX + Radius));
      Min_Y : Integer := Integer(Float'Floor(CY - Radius));
      Max_Y : Integer := Integer(Float'Ceiling(CY + Radius));
      Min_Z : Integer := Integer(Float'Floor(CZ - Radius));
      Max_Z : Integer := Integer(Float'Ceiling(CZ + Radius));
   begin
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
                  -- Check if we are actually removing something
                  if Get_Voxel(C, X, Y, Z) then
                     Set_Voxel(C, X, Y, Z, False); -- Carve
                     Removed := Removed + 1;
                  end if;
               end if;
            end loop;
         end loop;
      end loop;

      return Removed;
   end Subtract_Sphere;

   -------------------------------------------------------------------------
   -- Subtract Box
   -------------------------------------------------------------------------
   function Subtract_Box 
     (C          : in out Voxel_Chunk; 
      Min_X, Min_Y, Min_Z : Float;
      Max_X, Max_Y, Max_Z : Float) return Integer 
   is
      Start_X : Integer := Integer(Float'Floor(Min_X));
      End_X   : Integer := Integer(Float'Ceiling(Max_X));
      Start_Y : Integer := Integer(Float'Floor(Min_Y));
      End_Y   : Integer := Integer(Float'Ceiling(Max_Y));
      Start_Z : Integer := Integer(Float'Floor(Min_Z));
      End_Z   : Integer := Integer(Float'Ceiling(Max_Z));
      Removed : Integer := 0;
   begin
      if Start_X < 0 then Start_X := 0; end if;
      if End_X >= Chunk_Size then End_X := Chunk_Size - 1; end if;
      if Start_Y < 0 then Start_Y := 0; end if;
      if End_Y >= Chunk_Size then End_Y := Chunk_Size - 1; end if;
      if Start_Z < 0 then Start_Z := 0; end if;
      if End_Z >= Chunk_Size then End_Z := Chunk_Size - 1; end if;

      for Z in Start_Z .. End_Z loop
         for Y in Start_Y .. End_Y loop
            for X in Start_X .. End_X loop
               if Get_Voxel(C, X, Y, Z) then
                  Set_Voxel(C, X, Y, Z, False);
                  Removed := Removed + 1;
               end if;
            end loop;
         end loop;
      end loop;

      return Removed;
   end Subtract_Box;

   -------------------------------------------------------------------------
   -- Union Sphere
   -------------------------------------------------------------------------
   function Union_Sphere 
     (C          : in out Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float) return Integer 
   is
      R2 : constant Float := Radius * Radius;
      DX, DY, DZ : Float;
      Dist_Sq    : Float;
      Added      : Integer := 0;
      
      Min_X : Integer := Integer(Float'Floor(CX - Radius));
      Max_X : Integer := Integer(Float'Ceiling(CX + Radius));
      Min_Y : Integer := Integer(Float'Floor(CY - Radius));
      Max_Y : Integer := Integer(Float'Ceiling(CY + Radius));
      Min_Z : Integer := Integer(Float'Floor(CZ - Radius));
      Max_Z : Integer := Integer(Float'Ceiling(CZ + Radius));
   begin
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
                  if not Get_Voxel(C, X, Y, Z) then
                     Set_Voxel(C, X, Y, Z, True); -- Build
                     Added := Added + 1;
                  end if;
               end if;
            end loop;
         end loop;
      end loop;

      return Added;
   end Union_Sphere;

   -------------------------------------------------------------------------
   -- Intersect Sphere
   -------------------------------------------------------------------------
   function Intersect_Sphere 
     (C          : Voxel_Chunk; 
      CX, CY, CZ : Float; 
      Radius     : Float) return Boolean 
   is
      R2 : constant Float := Radius * Radius;
      DX, DY, DZ : Float;
      Dist_Sq    : Float;
      
      Min_X : Integer := Integer(Float'Floor(CX - Radius));
      Max_X : Integer := Integer(Float'Ceiling(CX + Radius));
      Min_Y : Integer := Integer(Float'Floor(CY - Radius));
      Max_Y : Integer := Integer(Float'Ceiling(CY + Radius));
      Min_Z : Integer := Integer(Float'Floor(CZ - Radius));
      Max_Z : Integer := Integer(Float'Ceiling(CZ + Radius));
   begin
      if Is_Empty(C) then return False; end if;

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
                  if Get_Voxel(C, X, Y, Z) then
                     return True; -- Impact detected!
                  end if;
               end if;
            end loop;
         end loop;
      end loop;

      return False;
   end Intersect_Sphere;

end Geo_Boolean;