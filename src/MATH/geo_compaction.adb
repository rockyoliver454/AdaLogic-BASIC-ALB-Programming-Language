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

package body Geo_Compaction is

   procedure Stabilize_Chunk 
     (Chunk : in out Voxel_Chunk; 
      Report : out Compaction_Report) 
   is
      Supported : Voxel_Chunk;
      Changed   : Boolean;
      
      -- Indices
      Idx : Integer;
      N_X, N_Y, N_Z : Integer;
      
      -- For center of mass calc
      Sum_X, Sum_Y, Sum_Z : Integer := 0;
   begin
      Report.Collapsed_Count := 0;
      Report.Center_Of_Mass  := 0;
      
      -- 1. Initialize Support (Base Layer Y=0)
      Supported := Create_Empty;
      
      if Is_Empty(Chunk) then
         return; -- Nothing to stabilize
      end if;

      -- Seed: Anything solid at Y=0 is supported
      for Z in 0 .. Chunk_Size - 1 loop
         for X in 0 .. Chunk_Size - 1 loop
            if Get_Voxel(Chunk, X, 0, Z) then
               Set_Voxel(Supported, X, 0, Z, True);
            end if;
         end loop;
      end loop;

      -- 2. Propagate Support (Iterative Flood Fill)
      -- Worst case path is a snake winding through all 4096 voxels.
      -- However, usually stabilizes much faster. We limit iterations for safety.
      for Pass in 1 .. Total_Bits loop 
         Changed := False;
         
         -- Scan all voxels
         for Z in 0 .. Chunk_Size - 1 loop
            for Y in 1 .. Chunk_Size - 1 loop -- Skip Y=0 (Already set)
               for X in 0 .. Chunk_Size - 1 loop
                  
                  -- Only check if this voxel is Solid but not yet Supported
                  if Get_Voxel(Chunk, X, Y, Z) and then not Get_Voxel(Supported, X, Y, Z) then
                     
                     -- Check 6 Neighbors for Support
                     -- Down (Most likely support)
                     if Get_Voxel(Supported, X, Y - 1, Z) then
                        Set_Voxel(Supported, X, Y, Z, True);
                        Changed := True;
                     
                     -- Up
                     elsif Y < Chunk_Size - 1 and then Get_Voxel(Supported, X, Y + 1, Z) then
                        Set_Voxel(Supported, X, Y, Z, True);
                        Changed := True;

                     -- Left
                     elsif X > 0 and then Get_Voxel(Supported, X - 1, Y, Z) then
                        Set_Voxel(Supported, X, Y, Z, True);
                        Changed := True;

                     -- Right
                     elsif X < Chunk_Size - 1 and then Get_Voxel(Supported, X + 1, Y, Z) then
                        Set_Voxel(Supported, X, Y, Z, True);
                        Changed := True;

                     -- Back
                     elsif Z > 0 and then Get_Voxel(Supported, X, Y, Z - 1) then
                        Set_Voxel(Supported, X, Y, Z, True);
                        Changed := True;
                     
                     -- Forward
                     elsif Z < Chunk_Size - 1 and then Get_Voxel(Supported, X, Y, Z + 1) then
                        Set_Voxel(Supported, X, Y, Z, True);
                        Changed := True;
                     end if;
                  end if;
                  
               end loop;
            end loop;
         end loop;

         if not Changed then
            exit; -- Converged
         end if;
      end loop;

      -- 3. Collapse Unstable Voxels
      -- Anything Solid but NOT Supported is rubble.
      for Z in 0 .. Chunk_Size - 1 loop
         for Y in 0 .. Chunk_Size - 1 loop
            for X in 0 .. Chunk_Size - 1 loop
               
               if Get_Voxel(Chunk, X, Y, Z) then -- Is Solid
                  if not Get_Voxel(Supported, X, Y, Z) then -- Is NOT Supported
                     -- Collapse it!
                     Set_Voxel(Chunk, X, Y, Z, False);
                     Report.Collapsed_Count := Report.Collapsed_Count + 1;
                     
                     Sum_X := Sum_X + X;
                     Sum_Y := Sum_Y + Y;
                     Sum_Z := Sum_Z + Z;
                  end if;
               end if;
               
            end loop;
         end loop;
      end loop;

      -- 4. Calculate Center of Mass (Simple Average)
      if Report.Collapsed_Count > 0 then
         -- We just pack a rough center index to help Debris spawn location
         declare
            Avg_X : Integer := Sum_X / Report.Collapsed_Count;
            Avg_Y : Integer := Sum_Y / Report.Collapsed_Count;
            Avg_Z : Integer := Sum_Z / Report.Collapsed_Count;
         begin
            -- Helper from Voxel_Ops? We'll reproduce logic to avoid circular/private issues
            -- or just assume 16x16x16
            Report.Center_Of_Mass := Avg_X + (Avg_Y * 16) + (Avg_Z * 256);
         end;
      end if;

   end Stabilize_Chunk;

end Geo_Compaction;