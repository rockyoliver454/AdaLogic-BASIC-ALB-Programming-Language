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

with Geo_Noise;
with Geo_Vec2; use Geo_Vec2;

package body Geo_Erosion is

   procedure Apply_Thermal_Erosion 
     (Chunk      : in out Voxel_Chunk;
      Iterations : Integer;
      Seed       : Integer)
   is
      Moved : Boolean;
      Noise : Fix16;
      
      -- Neighbor Offsets (8 directions)
      type Offset is record X, Z : Integer; end record;
      Offsets : array (1 .. 8) of Offset := (
         (-1, -1), (0, -1), (1, -1),
         (-1,  0),          (1,  0),
         (-1,  1), (0,  1), (1,  1)
      );
      
      Target_X, Target_Z : Integer;
      Landing_Y : Integer; -- [TITANIUM FIX] Track where the particle lands
   begin
      if Is_Empty(Chunk) then return; end if;

      for I in 1 .. Iterations loop
         Moved := False;

         -- Scan Top-Down
         for Y in reverse 1 .. Chunk_Size - 1 loop
            for Z in 0 .. Chunk_Size - 1 loop
               for X in 0 .. Chunk_Size - 1 loop
                  
                  -- If Current is Solid
                  if Get_Voxel(Chunk, X, Y, Z) then
                     
                     -- Support Check: Only erode if we are currently stable
                     if Y > 0 and then Get_Voxel(Chunk, X, Y - 1, Z) then
                        
                        Noise := Geo_Noise.Noise_Value(Create(From_Int(X), From_Int(Z)), Seed + I);
                        
                        -- Check neighbors
                        for O in Offsets'Range loop
                           Target_X := X + Offsets(O).X;
                           Target_Z := Z + Offsets(O).Z;
                           
                           -- Bounds Check
                           if Target_X >= 0 and Target_X < Chunk_Size and 
                              Target_Z >= 0 and Target_Z < Chunk_Size then
                              
                              -- Check the spot diagonally below (Y-1)
                              if not Get_Voxel(Chunk, Target_X, Y - 1, Target_Z) then
                                 
                                 -- [TITANIUM FIX] GRAVITY DROP
                                 -- We found a hole at Y-1. But is there ground below THAT?
                                 -- If not, we must drop the particle all the way down.
                                 
                                 Landing_Y := Y - 1;
                                 
                                 -- Scan down from Y-1 to 0 to find the floor
                                 while Landing_Y > 0 loop
                                    if Get_Voxel(Chunk, Target_X, Landing_Y - 1, Target_Z) then
                                       exit; -- Found solid ground below Landing_Y
                                    end if;
                                    Landing_Y := Landing_Y - 1;
                                 end loop;
                                 
                                 -- Execute the Move
                                 Set_Voxel(Chunk, X, Y, Z, False);             -- Remove from peak
                                 Set_Voxel(Chunk, Target_X, Landing_Y, Target_Z, True); -- Place at bottom
                                 
                                 Moved := True;
                                 exit; -- Done with this voxel
                              end if;
                           end if;
                        end loop;
                        
                     end if; -- End Support Check
                  end if; -- End Solid Check
                  
               end loop;
            end loop;
         end loop;

         if not Moved then
            exit; -- Stable
         end if;
      end loop;

   end Apply_Thermal_Erosion;

   function Calculate_Roughness (Chunk : Voxel_Chunk) return Fix16 is
      Surface_Count : Integer := 0;
      Total_Count   : Integer := 0;
   begin
      for Z in 0 .. Chunk_Size - 1 loop
         for Y in 0 .. Chunk_Size - 1 loop
            for X in 0 .. Chunk_Size - 1 loop
               if Get_Voxel(Chunk, X, Y, Z) then
                  Total_Count := Total_Count + 1;
                  
                  if X=0 or else not Get_Voxel(Chunk, X-1, Y, Z) then Surface_Count := Surface_Count + 1; end if;
                  if X=15 or else not Get_Voxel(Chunk, X+1, Y, Z) then Surface_Count := Surface_Count + 1; end if;
                  if Y=0 or else not Get_Voxel(Chunk, X, Y-1, Z) then Surface_Count := Surface_Count + 1; end if;
                  if Y=15 or else not Get_Voxel(Chunk, X, Y+1, Z) then Surface_Count := Surface_Count + 1; end if;
                  if Z=0 or else not Get_Voxel(Chunk, X, Y, Z-1) then Surface_Count := Surface_Count + 1; end if;
                  if Z=15 or else not Get_Voxel(Chunk, X, Y, Z+1) then Surface_Count := Surface_Count + 1; end if;
               end if;
            end loop;
         end loop;
      end loop;

      if Total_Count = 0 then return From_Float(0.0); end if;
      return Fix16(From_Int(Surface_Count) / From_Int(Total_Count));
   end Calculate_Roughness;

end Geo_Erosion;