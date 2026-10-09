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

-- =========================================================================
-- Emit_Native_Brainfuck_Gfx — FASM/SDL3 graphics sidecar for ALBB
--
-- Pure Brainfuck cannot call SDL. This package accumulates a parallel FASM
-- PE64 GUI + SDL3 runtime (ported from Emit_Native_FASM) that Flush writes
-- beside the .bf when Graphics_Used.
--
-- Architecture (playable):
--   Companion .bf.fasm = real PE64 GUI (SDL3) that stays alive.
--   BF is a tape machine the GUI may call for GFX port ops — NOT the app entry.
--   ALB_ON_TICK / ALB_ON_PAINT / ALB_ON_KEY are real FASM procs (or empty ret
--   stubs). FruitFractals playable .exe comes from albf's FASM second pass;
--   the companion proves the BF-gfx SDL shell.
-- =========================================================================
package Emit_Native_Brainfuck_Gfx is

   Graphics_Used         : Boolean := False;
   SDL3_Runtime_Emitted  : Boolean := False;
   Window_Title_Len      : Natural := 0;
   -- Legacy: skip writing companion. Prefer Omit_BF_Payload under --build.
   Skip_Companion_Write  : Boolean := False;
   -- When True, companion embeds no BF payload (db 0 only). Avoids 40MB+ .text
   -- data and the BF-as-main AV path. albf sets this under --build.
   Omit_BF_Payload       : Boolean := False;

   On_Tick_Emitted       : Boolean := False;
   On_Paint_Emitted      : Boolean := False;
   On_Event_Emitted      : Boolean := False;
   In_On_Handler         : Boolean := False;
   Message_Loop_Emitted  : Boolean := False;

   Screen_W              : Natural := 800;
   Screen_H              : Natural := 600;

   procedure Init;

   procedure Set_Screen_Size (W, H : Natural);

   procedure Gfx_Append (Str : String; Success : in out Boolean);
   procedure Gfx_Newline (Success : in out Boolean);
   procedure Gfx_Line (Text : String; Success : in out Boolean);

   procedure Emit_SDL3_Runtime_Support (Success : out Boolean);
   procedure Emit_Window_Creation (Title : String; Success : out Boolean);
   procedure Emit_Set_Fullscreen (Success : out Boolean);
   procedure Emit_Set_Resizable (Success : out Boolean);
   procedure Emit_Set_Stretchy (Success : out Boolean);
   procedure Emit_Message_Loop (Success : out Boolean);
   procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean);
   procedure Emit_Print_Function_Start (Success : out Boolean);
   procedure Emit_Key_State_Fasm (Success : out Boolean);
   procedure Emit_Mouse_Position_Fasm (Success : out Boolean);
   procedure Emit_Mouse_Click_Fasm (Success : out Boolean);
   procedure Emit_Put_Pixel_Fasm (Success : out Boolean);
   procedure Emit_Play_Sound_Fasm (Success : out Boolean);

   -- Dual-emit ON handler bodies as real FASM into the companion gfx buffer.
   procedure Begin_On_Handler (Name : String; Success : out Boolean);
   procedure End_On_Handler (Name : String; Success : out Boolean);
   -- Emit `mov rcx, Imm; call Callee` into the current ON handler (gfx).
   procedure Emit_Handler_Imm_Call
     (Callee : String; Imm_Hex : String; Success : out Boolean);
   procedure Emit_Handler_Current_Color_Clear (Success : out Boolean);

   -- Write companion PE64 GUI (.bf.fasm). BF payload optional (Omit_BF_Payload).
   -- Entry: SDL init → window → message loop. Does NOT run BF as main.
   procedure Write_Companion_Fasm
     (BF_File_Path : String;
      BF_Part_A    : String;
      BF_Part_B    : String;
      Success      : out Boolean);

   function Companion_Fasm_Path (BF_File_Path : String) return String;

end Emit_Native_Brainfuck_Gfx;
