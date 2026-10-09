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
with memory_allocator; use memory_allocator;
with range_spec;       use range_spec;

package ALB_Dumptruck is

   -- Da fixed size o' da Dumptruck's payload
   Max_Nodes : constant := 1024;
   type Node_ID is range 1 .. Max_Nodes;
   
   -- 0 means "Nae Bairn" (null pointer equivalent)
   type Link_ID is range 0 .. Max_Nodes; 
   type Ref_Count_Type is range 0 .. 255;

   -- Da Node noo kens its bairns!
   type Node_State is record
      Alive   : Boolean;
      Refs    : Ref_Count_Type;
      Child_1 : Link_ID;
      Child_2 : Link_ID;
   end record;

   type Tracker_Array is array (Node_ID) of Node_State;

   procedure Ignite_Dumptruck (Success : out Boolean);
   procedure Grab_New_Node (ID : out Node_ID; Success : out Boolean);
   
   -- DA NEW FEATURE: Bind parent tae bairns
   procedure Set_Bairns (Parent : in Node_ID; C1 : in Link_ID; C2 : in Link_ID; Success : out Boolean);

   procedure Add_Reference (ID : in Node_ID; Success : out Boolean);
   procedure Drop_Reference (ID : in Node_ID; Success : out Boolean);
   
   -- Da sweep noo features Da Static Drop Stack for cascaded drops!
   procedure Run_Sweep (Freed_Nodes : out Natural; Success : out Boolean);

   -- Da Steady Shovel
   procedure Run_Incremental_Sweep (Chunk_Size : in Natural; Freed_Nodes : out Natural; Success : out Boolean);
   
   -- DA GENTLE HAUD (Weak References)
   -- Allows checking if a node is still valid afore accessin' it
   function Is_Node_Alive (ID : in Node_ID) return Boolean;

   -- DA MIDDEN METRICS (High-Water Mark)
   -- Returns da peak number o' active nodes ever held at aince
   procedure Get_Peak_Nodes (Peak : out Natural; Success : out Boolean);

end ALB_Dumptruck;
