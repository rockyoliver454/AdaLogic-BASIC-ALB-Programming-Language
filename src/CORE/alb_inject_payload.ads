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

with Numerus_Magnus; use Numerus_Magnus;

package ALB_Inject_Payload is
   pragma Pure;

   -- Payload types (deterministic dispatch index, fits in U8)
   type Payload_Kind is
     (Payload_Mprotect,  -- syscall 10: change memory protection
      Payload_Mmap,      -- syscall 9:  allocate memory
      Payload_Mremap,    -- syscall 15: remap memory
      Payload_Execve,    -- syscall 59: execute program
      Payload_Clone)     -- syscall 56: fork thread/process
     with Size => 8;

   -- Inject flag bits (bitmask, U8)
   type Inject_Flag_Mask is mod 2**8;

   F_Dynamic_Page   : constant Inject_Flag_Mask := 2#0000_0001#;
   F_Multi_Arch     : constant Inject_Flag_Mask := 2#0000_0010#;
   F_Obfuscate      : constant Inject_Flag_Mask := 2#0000_0100#;
   F_Timing_Jitter  : constant Inject_Flag_Mask := 2#0000_1000#;
   F_Anti_Debug     : constant Inject_Flag_Mask := 2#0001_0000#;

   -- Syscall table entry (x86-64)
   type Syscall_Entry is record
      Num      : U8;       -- syscall number
      Arg_Regs : U8;       -- reserved for register rotation
      Prot_Val : U8;       -- default prot value for mprotect/mmap
      Flags_Val: U8;       -- default flags value for mmap
   end record;

   -- Table-driven syscall mapping (bounded, deterministic, no heap)
   type Syscall_Map is array (Payload_Kind) of Syscall_Entry;

   Syscall_Table : constant Syscall_Map :=
     (Payload_Mprotect => (Num => 10, Arg_Regs => 0, Prot_Val => 7,  Flags_Val => 0),
      Payload_Mmap     => (Num => 9,  Arg_Regs => 0, Prot_Val => 7,  Flags_Val => 16#22#),
      Payload_Mremap   => (Num => 15, Arg_Regs => 0, Prot_Val => 0,  Flags_Val => 0),
      Payload_Execve   => (Num => 59, Arg_Regs => 0, Prot_Val => 0,  Flags_Val => 0),
      Payload_Clone    => (Num => 56, Arg_Regs => 0, Prot_Val => 0,  Flags_Val => 0));

   -- Obfuscation XOR mask constant for immediate-value scrambling
   Obfuscate_Xor : constant U8 := 16#5A#;

   -- Page size constants
   Page_4KB  : constant U16 := 4096;
   Page_2MB  : constant U16 := 16#2000#;
   Page_1GB  : constant U16 := 16#4000#;

end ALB_Inject_Payload;
