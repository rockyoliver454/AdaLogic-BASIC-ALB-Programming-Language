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

package body Geo_Fracture3D is

   procedure Apply_Fracture 
     (Chunk       : in out Voxel_Chunk;
      Pattern     : Fracture_Pattern;
      Grid_Offset : Vec2;
      Grid_Scale  : Fix16;
      Cut_Depth   : Integer := Chunk_Size)
   is
      -- Helpers to convert World Space -> Voxel Grid Space
      function To_Grid_X (World_X : Fix16) return Integer is
         Rel_X : Fix16;
      begin
         Rel_X := (World_X - Grid_Offset.X) / Grid_Scale;
         return To_Int(Rel_X);
      end To_Grid_X;

      function To_Grid_Z (World_Z : Fix16) return Integer is
         Rel_Z : Fix16;
      begin
         -- Fracture Pattern Y corresponds to World Z
         Rel_Z := (World_Z - Grid_Offset.Y) / Grid_Scale;
         return To_Int(Rel_Z);
      end To_Grid_Z;

      -- Raster variables
      X0, Z0, X1, Z1 : Integer;
      DX, DZ, Steps  : Integer;
      X_Inc, Z_Inc   : Float;
      Cur_X, Cur_Z   : Float;
      
      V_X, V_Z : Integer;
      Y_Limit  : Integer;

   begin
      if Pattern.Count = 0 then return; end if;

      -- Iterate over all cut segments
      for I in 1 .. Pattern.Count loop
         
         -- 1. Map Start/End points to Grid Indices
         X0 := To_Grid_X(Pattern.Segments(I).A.X);
         Z0 := To_Grid_Z(Pattern.Segments(I).A.Y); -- Pattern.Y is World Z
         X1 := To_Grid_X(Pattern.Segments(I).B.X);
         Z1 := To_Grid_Z(Pattern.Segments(I).B.Y);

         -- 2. Line Rasterization (DDA-like approach for simplicity)
         DX := X1 - X0;
         DZ := Z1 - Z0;

         -- Determine number of steps needed
         if Abs(DX) > Abs(DZ) then
            Steps := Abs(DX);
         else
            Steps := Abs(DZ);
         end if;

         -- Avoid division by zero
         if Steps > 0 then
            X_Inc := Float(DX) / Float(Steps);
            Z_Inc := Float(DZ) / Float(Steps);
            
            Cur_X := Float(X0);
            Cur_Z := Float(Z0);

            -- Walk the line
            for S in 0 .. Steps loop
               -- [TITANIUM FIX] Removed Float'Round. 
               -- Standard Integer conversion rounds Float to nearest integer automatically.
               V_X := Integer(Cur_X);
               V_Z := Integer(Cur_Z);

               -- 3. Carve Vertical Column
               -- We cut from Top (Chunk_Size-1) down to (Chunk_Size - Cut_Depth)
               -- Assuming Y=0 is bottom, Y=15 is top.
               if V_X >= 0 and V_X < Chunk_Size and V_Z >= 0 and V_Z < Chunk_Size then
                  
                  Y_Limit := Chunk_Size - Cut_Depth;
                  if Y_Limit < 0 then Y_Limit := 0; end if;

                  for Y in reverse Y_Limit .. Chunk_Size - 1 loop
                     -- Clear voxel (False)
                     Set_Voxel(Chunk, V_X, Y, V_Z, False);
                  end loop;
               end if;

               Cur_X := Cur_X + X_Inc;
               Cur_Z := Cur_Z + Z_Inc;
            end loop;
         end if;
      end loop;

   end Apply_Fracture;

end Geo_Fracture3D;