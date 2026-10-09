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

package Opcodes is
   pragma Pure;

   -- =========================================================================
   -- Da Lexicon o' Binary Commands (The Iron Bytecode)
   -- =========================================================================
   type ALB_Opcode is
     (OP_NOP,          -- 00: Sleep / Do Nothing

      -- Memory & Stack Operations
      OP_LOAD_CONST,   -- 10: Load a numeric literal onto da stack
      OP_LOAD_VAR,     -- 11: Load a variable's value frae da symbol vault
      OP_STORE_VAR,    -- 12: Save da top o' da stack intae da symbol vault
      OP_LOAD_ARRAY,   -- 13: Load value frae array (pops index frae stack)
      OP_STORE_ARRAY,  -- 14: Store value intae array (pops value, then index)
      OP_PEEK,         -- 15: Read raw 64-bit value frae address
      OP_POKE,         -- 16: Write raw 64-bit value tae address
      OP_DEREF,        -- 17: Dereference a pointer/address

      -- Mathematics (The Anvil)
      OP_ADD,          -- 20: Add top twa values
      OP_SUB,          -- 21: Subtract
      OP_MUL,          -- 22: Multiply
      OP_DIV,          -- 23: Divide

      -- HEX and LOGIC
      OP_AND,          -- 24: Bitwise AND
      OP_OR,           -- 25: Bitwise OR
      OP_XOR,          -- 26: Bitwise XOR
      OP_SHL,          -- 27: Shift Left
      OP_SHR,          -- 28: Shift Right
      OP_MOD,          -- 29: Modulo (Da missing anvil strike!)
      
      -- Logic Gates
      OP_CMP_EQ,       -- 30: Compare Equal
      OP_CMP_LT,       -- 31: Compare Less Than
      OP_CMP_GT,       -- 32: Compare Greater Than
      OP_CMP_LTE,      -- 33: Compare Less Than or Equal
      OP_CMP_GTE,      -- 34: Compare Greater Than or Equal
      OP_CMP_NEQ,      -- 35: Compare Not Equal
      
      -- NEW: Logical Short-Circuit Gates
      OP_LOGICAL_AND,  -- 36: Logical AND (Short-circuit)
      OP_LOGICAL_OR,   -- 37: Logical OR (Short-circuit)

      -- Control Flow (Strictly Bounded Jumps)
      OP_JMP,          -- 40: Absolute Jump tae instruction index
      OP_JMP_IF_FALSE, -- 41: Conditional Jump (For IF/REPEAT bounds)

      -- I/O Operations
      OP_PRINT,        -- 50: Output top o' stack tae terminal
      
      OP_CHOOSE,   -- Branchless ternary: Pops 3, masks, pushes 1

      -- DA NEW NATIVE GATEWAY!
      OP_CALL,         -- 60: Call a native engine/OS function by hash
      OP_RETURN,   -- Yields control back tae the C caller (Win32 Message Loop)
      OP_LISTEN,    -- Fires the Win32 Message Loop
      OP_CALL_SCRIPT,  -- NEW: Pushes return PC, jumps to script procedure
      OP_RETURN_SCRIPT,-- NEW: Pops return PC, jumps back

      OP_HALT          -- FF: Cleanly shut doon da engine
     );

   -- =========================================================================
   -- Da Hardware Alignment (Data-Driven Design)
   -- We force da Ada compiler tae use exact 8-bit hex values for ilka Opcode.
   -- =========================================================================
   for ALB_Opcode use
     (OP_NOP          => 16#00#,

      OP_LOAD_CONST   => 16#10#,
      OP_LOAD_VAR     => 16#11#,
      OP_STORE_VAR    => 16#12#,
      OP_LOAD_ARRAY   => 16#13#,
      OP_STORE_ARRAY  => 16#14#,
      OP_PEEK         => 16#15#,
      OP_POKE         => 16#16#,
      OP_DEREF        => 16#17#,

      OP_ADD          => 16#20#,
      OP_SUB          => 16#21#,
      OP_MUL          => 16#22#,
      OP_DIV          => 16#23#,
      
      OP_AND          => 16#24#,
      OP_OR           => 16#25#,
      OP_XOR          => 16#26#,
      OP_SHL          => 16#27#,
      OP_SHR          => 16#28#,
      OP_MOD          => 16#29#,

      OP_CMP_EQ       => 16#30#,
      OP_CMP_LT       => 16#31#,
      OP_CMP_GT       => 16#32#,
      OP_CMP_LTE      => 16#33#,
      OP_CMP_GTE      => 16#34#,
      OP_CMP_NEQ      => 16#35#,
      
      OP_LOGICAL_AND  => 16#36#,
      OP_LOGICAL_OR   => 16#37#,

      OP_JMP          => 16#40#,
      OP_JMP_IF_FALSE => 16#41#,

      OP_PRINT        => 16#50#,
      OP_CHOOSE       => 16#51#,

      OP_CALL         => 16#60#,
      OP_RETURN       => 16#61#,
      OP_LISTEN       => 16#62#,
      OP_CALL_SCRIPT  => 16#63#,
      OP_RETURN_SCRIPT=> 16#64#,

      OP_HALT         => 16#FF#
     );
   
end Opcodes;
