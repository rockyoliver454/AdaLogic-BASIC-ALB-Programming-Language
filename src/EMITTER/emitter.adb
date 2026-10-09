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

package body Emitter is

   State : Emitter_State := (Buffer => (others => 0), IP => 0);

   procedure Init_Emitter (Success : out Boolean) is
   begin
      State.Buffer := (others => 0);
      State.IP     := 0;
      Success      := True;
   end Init_Emitter;

   procedure Emit_Op (Op : in ALB_Opcode; Success : out Boolean) is
      Safe_Bounds : RS_Interval;
      Valid_Range : Boolean;
   begin
      -- Assertion 1: Create a strict range for da bytecode buffer bounds
      Range_Spec.Create (1.0, Long_Float(Max_Bytecode_Size), Safe_Bounds, Valid_Range);
      
      -- Assertion 2: Verify da current IP + 1 winna breach da vault
      if Valid_Range and then Range_Spec.Contains (Safe_Bounds, Long_Float(State.IP + 1)) then
         State.IP := State.IP + 1;
         
         -- We cast da enum's internal representation directly tae U8.
         -- Ada allows Enum'Pos, but since we locked da sizes in opcodes.ads, 
         -- we can safely use Unchecked_Conversion or direct casting depending on yer compiler flags.
         -- For strict SPARK safety without Unchecked_Conversion, we use 'Pos:
         State.Buffer(State.IP) := U8 (ALB_Opcode'Pos (Op));
         Success := True;
      else
         Success := False;
      end if;
   end Emit_Op;

   procedure Emit_U8 (Val : in U8; Success : out Boolean) is
      Safe_Bounds : RS_Interval;
      Valid_Range : Boolean;
   begin
      -- Assertion 1: Create a strict range for da bytecode buffer bounds
      Range_Spec.Create (1.0, Long_Float(Max_Bytecode_Size), Safe_Bounds, Valid_Range);
      
      -- Assertion 2: Verify da current IP + 1 winna overflow
      if Valid_Range and then Range_Spec.Contains (Safe_Bounds, Long_Float(State.IP + 1)) then
         State.IP := State.IP + 1;
         State.Buffer(State.IP) := Val;
         Success := True;
      else
         Success := False;
      end if;
   end Emit_U8;
   
  
end Emitter;
