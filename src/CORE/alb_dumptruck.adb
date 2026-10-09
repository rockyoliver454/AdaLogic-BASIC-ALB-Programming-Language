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

pragma SPARK_Mode (On);

package body ALB_Dumptruck is

   -- Fully initialized State_Grid to satisfy da SPARK compiler
   State_Grid : Tracker_Array := (others => (Alive => False, Refs => 0, Child_1 => 0, Child_2 => 0));
   Is_Ignited : Boolean := False;
   Truck_Bounds : RS_Interval;

   -- Da Steady Shovel's position
   Sweep_Cursor : Node_ID := 1;
   
   -- Metrics Trackers
   Active_Nodes_Count : Natural := 0;
   Peak_Active_Nodes  : Natural := 0;
   
   -- We define a strict type for da drop stack (max 2 * nodes to completely prevent overflow)
   Max_Stack_Size : constant := 2048; 
   type Drop_Stack_Array is array (1 .. Max_Stack_Size) of Link_ID;

   procedure Ignite_Dumptruck (Success : out Boolean) is
      Alloc_Success : Boolean := False;
   begin
      pragma Assert (not Is_Ignited);
      
      -- We claim a block frae dy static pool tae represent da memory we track
      Claim_Strict_Block (Req_Bytes => Pool_Index(Max_Nodes * 8), Bounds => Truck_Bounds, Success => Alloc_Success);
      
      pragma Assert (Alloc_Success = True or Alloc_Success = False);

      if Alloc_Success then
         Is_Ignited := True;
         Success := True;
      else
         Success := False;
      end if;
   end Ignite_Dumptruck;

   procedure Grab_New_Node (ID : out Node_ID; Success : out Boolean) is
      Found : Boolean := False;
   begin
      pragma Assert (Is_Ignited = True or Is_Ignited = False);
      ID := 1; 

      if not Is_Ignited then
         Success := False;
         return;
      end if;

      -- Fixed bound loop: sweeps da array tae find an empty slot
      for I in Node_ID loop
         pragma Loop_Invariant (Is_Ignited);
         if not State_Grid (I).Alive and not Found then
            State_Grid (I).Alive := True;
            State_Grid (I).Refs  := 1; -- Starts wi' 1 reference
            
            -- Wiping the slate clean upon grabbin' a recycled node!
            State_Grid (I).Child_1 := 0;
            State_Grid (I).Child_2 := 0;
            
            Active_Nodes_Count := Active_Nodes_Count + 1;
            if Active_Nodes_Count > Peak_Active_Nodes then
               Peak_Active_Nodes := Active_Nodes_Count;
            end if;

            ID := I;
            Found := True;
         end if;
      end loop;

      pragma Assert (Found = True or Found = False);
      Success := Found;
   end Grab_New_Node;

   procedure Set_Bairns (Parent : in Node_ID; C1 : in Link_ID; C2 : in Link_ID; Success : out Boolean) is
   begin
      pragma Assert (Parent >= 1 and Parent <= Max_Nodes);
      pragma Assert (C1 >= 0 and C2 >= 0);

      if not Is_Ignited or else not State_Grid (Parent).Alive then
         Success := False;
         return;
      end if;

      State_Grid (Parent).Child_1 := C1;
      State_Grid (Parent).Child_2 := C2;
      Success := True;
   end Set_Bairns;

   procedure Add_Reference (ID : in Node_ID; Success : out Boolean) is
   begin
      pragma Assert (ID >= 1);
      pragma Assert (ID <= Max_Nodes);

      if not Is_Ignited or else not State_Grid (ID).Alive or else State_Grid (ID).Refs = 255 then
         Success := False;
         return;
      end if;

      State_Grid (ID).Refs := State_Grid (ID).Refs + 1;
      Success := True;
   end Add_Reference;

   procedure Drop_Reference (ID : in Node_ID; Success : out Boolean) is
   begin
      pragma Assert (ID >= 1);
      pragma Assert (ID <= Max_Nodes);

      if not Is_Ignited or else not State_Grid (ID).Alive or else State_Grid (ID).Refs = 0 then
         Success := False;
         return;
      end if;

      State_Grid (ID).Refs := State_Grid (ID).Refs - 1;
      Success := True;
   end Drop_Reference;

   procedure Run_Sweep (Freed_Nodes : out Natural; Success : out Boolean) is
      Count       : Natural := 0;
      Drop_Stack  : Drop_Stack_Array := (others => 0);
      Stack_Top   : Natural := 0;
      Curr_Link   : Link_ID;
      Curr_Node   : Node_ID;
      C1, C2      : Node_ID;
   begin
      pragma Assert (Count = 0);
      pragma Assert (Stack_Top = 0);

      if not Is_Ignited then
         Freed_Nodes := 0;
         Success := False;
         return;
      end if;

      -- STEP 1: Find all absolute roots dat are currently dead and load da stack
      for I in Node_ID loop
         pragma Loop_Invariant (Stack_Top <= Natural(I));
         if State_Grid (I).Alive and then State_Grid (I).Refs = 0 then
            if Stack_Top < Max_Stack_Size then
               Stack_Top := Stack_Top + 1;
               Drop_Stack (Stack_Top) := Link_ID(I);
            end if;
         end if;
      end loop;

      -- STEP 2: Da Static Cascade Stack (Flattened Recursion!)
      for S in 1 .. Integer(Max_Nodes) loop
         pragma Loop_Invariant (Count <= S - 1);
         
         if Stack_Top > 0 then
            Curr_Link := Drop_Stack (Stack_Top);
            Stack_Top := Stack_Top - 1;

            if Curr_Link > 0 then
               Curr_Node := Node_ID(Curr_Link);

               if State_Grid (Curr_Node).Alive then
                  State_Grid (Curr_Node).Alive := False;
                  Count := Count + 1;
                  Active_Nodes_Count := Active_Nodes_Count - 1;

                  -- Bairn 1
                  if State_Grid (Curr_Node).Child_1 > 0 then
                     C1 := Node_ID(State_Grid (Curr_Node).Child_1);
                     if State_Grid (C1).Refs > 0 then
                        State_Grid (C1).Refs := State_Grid (C1).Refs - 1;
                     end if;
                     
                     if State_Grid (C1).Refs = 0 and then State_Grid (C1).Alive then
                        if Stack_Top < Max_Stack_Size then
                           Stack_Top := Stack_Top + 1;
                           Drop_Stack (Stack_Top) := Link_ID(C1);
                        end if;
                     end if;
                  end if;

                  -- Bairn 2
                  if State_Grid (Curr_Node).Child_2 > 0 then
                     C2 := Node_ID(State_Grid (Curr_Node).Child_2);
                     if State_Grid (C2).Refs > 0 then
                        State_Grid (C2).Refs := State_Grid (C2).Refs - 1;
                     end if;
                     
                     if State_Grid (C2).Refs = 0 and then State_Grid (C2).Alive then
                        if Stack_Top < Max_Stack_Size then
                           Stack_Top := Stack_Top + 1;
                           Drop_Stack (Stack_Top) := Link_ID(C2);
                        end if;
                     end if;
                  end if;

               end if;
            end if;
         end if;
      end loop;

      pragma Assert (Count <= Integer(Max_Nodes));
      
      Freed_Nodes := Count;
      Success := True;
   end Run_Sweep;
   
   procedure Run_Incremental_Sweep (Chunk_Size : in Natural; Freed_Nodes : out Natural; Success : out Boolean) is
      Count : Natural := 0;
      Steps : Natural;
      Curr_Node : Node_ID;
   begin
      pragma Assert (Count = 0);

      if not Is_Ignited or else Chunk_Size = 0 then
         Freed_Nodes := 0;
         Success := False;
         return;
      end if;

      if Chunk_Size > Integer(Max_Nodes) then
         Steps := Integer(Max_Nodes);
      else
         Steps := Chunk_Size;
      end if;

      for I in 1 .. Steps loop
         pragma Loop_Invariant (Count <= I - 1);
         
         Curr_Node := Sweep_Cursor;

         if State_Grid (Curr_Node).Alive and then State_Grid (Curr_Node).Refs = 0 then
            State_Grid (Curr_Node).Alive := False;
            Count := Count + 1;
            Active_Nodes_Count := Active_Nodes_Count - 1;
            
            -- We just drop the refs of da bairns. The next incremental step will 
            -- find them dead and sweep them without needing a massive cascade stack!
            if State_Grid (Curr_Node).Child_1 > 0 then
               if State_Grid (Node_ID(State_Grid (Curr_Node).Child_1)).Refs > 0 then
                  State_Grid (Node_ID(State_Grid (Curr_Node).Child_1)).Refs := State_Grid (Node_ID(State_Grid (Curr_Node).Child_1)).Refs - 1;
               end if;
            end if;
            
            if State_Grid (Curr_Node).Child_2 > 0 then
               if State_Grid (Node_ID(State_Grid (Curr_Node).Child_2)).Refs > 0 then
                  State_Grid (Node_ID(State_Grid (Curr_Node).Child_2)).Refs := State_Grid (Node_ID(State_Grid (Curr_Node).Child_2)).Refs - 1;
               end if;
            end if;
         end if;

         if Sweep_Cursor = Max_Nodes then
            Sweep_Cursor := 1;
         else
            Sweep_Cursor := Sweep_Cursor + 1;
         end if;
      end loop;

      pragma Assert (Count <= Steps);
      Freed_Nodes := Count;
      Success := True;
   end Run_Incremental_Sweep;
   
   function Is_Node_Alive (ID : in Node_ID) return Boolean is
   begin
      if not Is_Ignited then
         return False;
      end if;
      return State_Grid (ID).Alive;
   end Is_Node_Alive;

   procedure Get_Peak_Nodes (Peak : out Natural; Success : out Boolean) is
   begin
      if not Is_Ignited then
         Peak := 0;
         Success := False;
      else
         Peak := Peak_Active_Nodes;
         Success := True;
      end if;
   end Get_Peak_Nodes;

end ALB_Dumptruck;
