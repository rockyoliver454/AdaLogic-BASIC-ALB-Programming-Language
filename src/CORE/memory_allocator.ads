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
with range_spec;   use range_spec;
with Numerus_Verus; use Numerus_Verus;

package memory_allocator is


   -- Da physical limits of our engine.  Range is 8 GiB so a 6 GiB whole-
   -- program pool plus the +1 used in remaining-space math cannot wrap.
   -- This is an index type, not an OS malloc: Alloc_Static_Pool still
   -- only records the caller's Total_Bytes (albt boots at 1 MiB).
   -- Do NOT write Natural (Pool_Index'Last) -- Last no longer fits Natural.
   type Pool_Index is range 0 .. 8589934592; 

   ---------------------------------------------------------------------
   -- 1. DA MALLOC EQUIVALENT (Run exactly once at boot)
   ---------------------------------------------------------------------
   -- Enforces Rule 3: Carves out the single massive block. 
   procedure Alloc_Static_Pool (Total_Bytes : in Pool_Index; Success : out Boolean)
     with Pre  => Total_Bytes > 0;

   ---------------------------------------------------------------------
   -- 2. STRICT_BLOCK (Contiguous memspan, strictly secure)
   ---------------------------------------------------------------------
   -- Carves a permanent chunk from the pool.
   procedure Claim_Strict_Block 
     (Req_Bytes : in Pool_Index; 
      Bounds    : out RS_Interval; 
      Success   : out Boolean)
     with Pre  => Req_Bytes > 0;

   ---------------------------------------------------------------------
   -- 3. SLIDING_BLOCK (Active window wi' [MAX] constraint)
   ---------------------------------------------------------------------
   -- Creates a bounded flex span without touching the OS heap.
   procedure Claim_Sliding_Block 
     (Max_Bytes    : in Pool_Index; 
      Active_Limit : in Pool_Index; 
      Bounds       : out RS_Interval;
      Success      : out Boolean)
     with Pre  => Active_Limit <= Max_Bytes;

   ---------------------------------------------------------------------
   -- 4. THE VERIFIER (Diagnostics & Safety)
   ---------------------------------------------------------------------
   -- Uses dy native Range_Spec functions tae guarantee safety afore access
   function Verify_Access (Target_Interval : RS_Interval; Requested_Index : Long_Float) return Boolean;
   
   ---------------------------------------------------------------------
   -- 5. METRICS & ARENA RESET (The Dynamic Illusion)
   ---------------------------------------------------------------------
   -- Queries da exact bytes remainin' in da static pool for diagnostics
   procedure Get_Space_Left (Space : out Pool_Index; Success : out Boolean);

   -- Resets da arena bump-pointer back tae 1. 
   -- Dis allows complete reuse o' da memory pool wi'out touchin' da OS heap (Rule 3).
   procedure Reset_Pool (Success : out Boolean);
   
   -- Retrieves the absolute peak memory ever claimed across the lifetime o' the engine.
   -- Dis survives arena resets, watchin' the true high-water mark like a hawk.
   procedure Get_High_Water_Mark (Peak_Bytes : out Pool_Index; Success : out Boolean);
   

end memory_allocator;
