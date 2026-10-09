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
with range_spec; use range_spec;

package body memory_allocator is

   ---------------------------------------------------------------------
   -- INTERNAL STATE (The Fortress Vault)
   ---------------------------------------------------------------------
   -- We track exactly hoo much is carved. 
   -- SPARK will guarantee we never breach Total_Capacity.
   Total_Capacity  : Pool_Index := 0;
   Next_Free_Byte  : Pool_Index := 0;
   High_Water_Mark : Pool_Index := 0; -- Da Hawk's Eye
   Is_Bootstrapped : Boolean := False;

   ---------------------------------------------------------------------
   -- 1. ALLOC_STATIC_POOL
   ---------------------------------------------------------------------
   procedure Alloc_Static_Pool (Total_Bytes : in Pool_Index; Success : out Boolean) is
   begin
      -- Rule 3 check: Dis can only be called AINCE at boot.
      if Is_Bootstrapped then
         Success := False; 
      else
         Total_Capacity  := Total_Bytes;
         Next_Free_Byte  := 1;
         Is_Bootstrapped := True;
         Success         := True;
      end if;
   end Alloc_Static_Pool;

   ---------------------------------------------------------------------
   -- 2. CLAIM_STRICT_BLOCK (For FITS headers, Roman specs, etc.)
   ---------------------------------------------------------------------
   procedure Claim_Strict_Block 
     (Req_Bytes : in Pool_Index; 
      Bounds    : out RS_Interval; 
      Success   : out Boolean)
   is
      Space_Left : Pool_Index;
   begin
      if not Is_Bootstrapped then
         Success := False;
         Bounds  := (Lower => 1.0, Upper => -1.0);
         return;
      end if;
      
      Space_Left := (Total_Capacity + 1) - Next_Free_Byte;
      
      -- If they ask for mair than what's left, we trigger Pool Exhaustion
      if Req_Bytes > Space_Left then
         Success := False; 
         Bounds  := (Lower => 1.0, Upper => -1.0);
      else
         -- Use dy native Range_Spec tae forge the interval
         range_spec.Create (Val_A   => Long_Float (Next_Free_Byte), 
                            Val_B   => Long_Float (Next_Free_Byte + Req_Bytes - 1), 
                            Result  => Bounds, 
                            Success => Success);
         
         if Success then
            -- Safely shift the pointer forward. Memory is noo locked.
            Next_Free_Byte := Next_Free_Byte + Req_Bytes;
            -- Track the absolute peak across resets
            if (Next_Free_Byte - 1) > High_Water_Mark then
               High_Water_Mark := Next_Free_Byte - 1;
            end if;
         end if;
      end if;
   end Claim_Strict_Block;

   ---------------------------------------------------------------------
   -- 3. CLAIM_SLIDING_BLOCK (The Safe Dynamic Array)
   ---------------------------------------------------------------------
   procedure Claim_Sliding_Block 
     (Max_Bytes    : in Pool_Index; 
      Active_Limit : in Pool_Index; 
      Bounds       : out RS_Interval;
      Success      : out Boolean)
   is
      Space_Left : Pool_Index;
   begin
      if not Is_Bootstrapped then
         Success := False;
         Bounds  := (Lower => 0.0, Upper => 0.0);
         return;
      end if;
      
      Space_Left := (Total_Capacity + 1) - Next_Free_Byte;
      
      -- The engine MUST physically reserve the [MAX] constraint
      if Max_Bytes > Space_Left then
         Success := False;
         Bounds  := (Lower => 0.0, Upper => 0.0);
      else
         -- We forge the interval based on the ACTIVE window, no' the MAX window.
         range_spec.Create (Val_A   => Long_Float (Next_Free_Byte), 
                            Val_B   => Long_Float (Next_Free_Byte + Active_Limit - 1), 
                            Result  => Bounds, 
                            Success => Success);
                            
         if Success then
            -- We shift the pointer by MAX_BYTES, permanently reserving the headroom
            -- sae the active bounds can be shifted later withoot crashing intae another block.
            Next_Free_Byte := Next_Free_Byte + Max_Bytes;
            -- Track the absolute peak across resets
            if (Next_Free_Byte - 1) > High_Water_Mark then
               High_Water_Mark := Next_Free_Byte - 1;
            end if;
         end if;
      end if;
   end Claim_Sliding_Block;

   ---------------------------------------------------------------------
   -- 4. VERIFY_ACCESS
   ---------------------------------------------------------------------
   function Verify_Access (Target_Interval : RS_Interval; Requested_Index : Long_Float) return Boolean is
   begin
      -- A perfectly clean wrapper relying entirely on dy native SPARK logic
      return range_spec.Contains (Target_Interval, Requested_Index);
   end Verify_Access;
   
   ---------------------------------------------------------------------
   -- 5. METRICS & ARENA RESET
   ---------------------------------------------------------------------
   procedure Get_Space_Left (Space : out Pool_Index; Success : out Boolean) is
   begin
      if not Is_Bootstrapped then
         Space   := 0;
         Success := False;
      else
         -- Accountin' for 1-based indexin'
         Space   := (Total_Capacity + 1) - Next_Free_Byte;
         Success := True;
      end if;
   end Get_Space_Left;

   procedure Reset_Pool (Success : out Boolean) is
   begin
      if not Is_Bootstrapped then
         Success := False;
      else
         -- Da magic trick! We dinna free memory, we just reset the bump pointer.
         -- Dis keeps us strictly compliant wi' Rule 3.
         Next_Free_Byte := 1;
         Success        := True;
      end if;
   end Reset_Pool;
   
   
   procedure Get_High_Water_Mark (Peak_Bytes : out Pool_Index; Success : out Boolean) is
   begin
      if not Is_Bootstrapped then
         Peak_Bytes := 0;
         Success    := False;
      else
         Peak_Bytes := High_Water_Mark;
         Success    := True;
      end if;
   end Get_High_Water_Mark;

end memory_allocator;
