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

pragma SPARK_Mode (Off);

with Numerus_Magnus; use Numerus_Magnus;

package body ALBA_GC is

   Max_GC_Slots : constant Positive := 1024;

   Live_Flags : array (Positive range 1 .. Max_GC_Slots) of Boolean :=
     (others => False);
   Child_One : array (Positive range 1 .. Max_GC_Slots) of U64 :=
     (others => 0);
   Child_Two : array (Positive range 1 .. Max_GC_Slots) of U64 :=
     (others => 0);

   function To_Slot (Handle : U64) return Natural is
   begin
      if Handle = 0 or else Handle > U64 (Max_GC_Slots) then
         return 0;
      end if;
      return Natural (Handle);
   end To_Slot;

   function Claim return U64 is
   begin
      for Slot in Live_Flags'Range loop
         if not Live_Flags (Slot) then
            Live_Flags (Slot) := True;
            Child_One (Slot) := 0;
            Child_Two (Slot) := 0;
            return U64 (Slot);
         end if;
      end loop;
      return 0;
   end Claim;

   procedure Drop (Handle : in U64) is
      Slot : constant Natural := To_Slot (Handle);
   begin
      if Slot = 0 then
         return;
      end if;
      Live_Flags (Slot) := False;
      Child_One (Slot) := 0;
      Child_Two (Slot) := 0;
   end Drop;

   procedure Bind
     (Parent : in U64;
      Child1 : in U64;
      Child2 : in U64) is
      Slot : constant Natural := To_Slot (Parent);
   begin
      if Slot = 0 then
         return;
      end if;
      Child_One (Slot) := Child1;
      Child_Two (Slot) := Child2;
   end Bind;

   procedure Sweep (Chunk : in U64) is
      Limit : Natural := Max_GC_Slots;
   begin
      if Chunk > 0 and then Chunk < U64 (Max_GC_Slots) then
         Limit := Natural (Chunk);
      end if;

      for Slot in 1 .. Limit loop
         if not Live_Flags (Slot) then
            Child_One (Slot) := 0;
            Child_Two (Slot) := 0;
         end if;
      end loop;
   end Sweep;

end ALBA_GC;
