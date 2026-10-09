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

with Ada.Text_IO;
with ALB_Types; use ALB_Types;
with Opcodes;   use Opcodes;
with Emit_Native_Brainfuck_Gfx;

-- =========================================================================
-- Emit_Native_Brainfuck (ALBB) body
--
-- TAPE LAYOUT (byte cells; Ada tracks Current_Ptr for relative >< moves):
--   0         ZERO_SENTINEL
--   1         ACC (accumulator)
--   2..5      TMP0..TMP3
--   6         FLAG_COND
--   7         FLAG_ERR
--   8         FLAG_ELSE
--   9         FLAG_LOOP
--   10        VSP (value-stack depth mirror)
--   11        USP (undo-stack depth mirror)
--   12..15    SCR0..SCR3 (mul/div/cmp/print scratch)
   --   16..527   VALUE_STACK (deep expr trees / inlined PURE helpers)
   --   528..591  UNDO_STACK
   --   592..8783 VAR_SLOTS (named vars / STRICT arrays; StrawBerry needs 2k+)
--   8784..9071 STRING_POOL
--   9072+     HIST / CALL region
--
-- GFX PORTS (high tape; dual-buffer ALBB — BF writes + FASM sidecar SDL):
--   65000 GFX_CMD   (1=PUT_PIXEL, 2=SET_COLOR, 3=KEY, 4=MOUSE, 5=SOUND)
--   65001 GFX_X
--   65002 GFX_Y
--   65003 GFX_W
--   65004 GFX_H
--   65005 GFX_COLOR (low byte; extend as needed)
--   65009 GFX_KEY
--   65010 GFX_MOUSE_X
--   65011 GFX_MOUSE_Y
--   65012 GFX_MOUSE_BTN
--   Native builds flush companion File.bf.fasm (PE64 GUI + SDL3 + BF VM)
--   via Emit_Native_Brainfuck_Gfx when Graphics_Used.
--
-- Flush writes Global (init) then Main (code).
-- Annotated mode: multi-line indented BF ([/] nest) + ignored ASCII comments.
--
-- IF/ELSE approach:
--   Emit_If_Start  : copy ACC -> FLAG_COND; set FLAG_ELSE=1
--   Emit_Then      : open [ on FLAG_COND; clear FLAG_ELSE; then-body follows
--   Emit_Else      : close then-loop; open [ on FLAG_ELSE; else-body follows
--   Emit_If_End    : close else-loop; clear flags
-- =========================================================================
package body Emit_Native_Brainfuck is

   Max_Buffer_Size : constant Natural := 67_108_864;

   Global_Buffer : String (1 .. Max_Buffer_Size) := (others => ' ');
   Global_Len    : Natural := 0;
   Main_Buffer   : String (1 .. Max_Buffer_Size) := (others => ' ');
   Main_Len      : Natural := 0;

   Cell_Zero      : constant Natural := 0;
   Cell_ACC       : constant Natural := 1;
   Cell_TMP0      : constant Natural := 2;
   Cell_TMP1      : constant Natural := 3;
   Cell_TMP2      : constant Natural := 4;
   Cell_TMP3      : constant Natural := 5;
   Cell_FLAG_COND : constant Natural := 6;
   Cell_FLAG_ERR  : constant Natural := 7;
   Cell_FLAG_ELSE : constant Natural := 8;
   Cell_FLAG_LOOP : constant Natural := 9;
   Cell_VSP       : constant Natural := 10;
   Cell_USP       : constant Natural := 11;
   Cell_SCR0      : constant Natural := 12;
   Cell_SCR1      : constant Natural := 13;
   Cell_SCR2      : constant Natural := 14;
   Cell_SCR3      : constant Natural := 15;

   Value_Stack_Base : constant Natural := 16;
   Value_Stack_Size : constant Natural := 512;
   Undo_Stack_Base  : constant Natural := 528;
   Undo_Stack_Size  : constant Natural := 64;
   Var_Slot_Base    : constant Natural := 592;
   Max_Var_Slots    : constant Natural := 8192;
   String_Pool_Base : constant Natural := 8784;
   String_Pool_Size : constant Natural := 288;
   Hist_Base        : constant Natural := 9072;

   -- Graphics command ports (see header). Keep far above HIST/VAR regions.
   Cell_GFX_CMD      : constant Natural := 65000;
   Cell_GFX_X        : constant Natural := 65001;
   Cell_GFX_Y        : constant Natural := 65002;
   Cell_GFX_W        : constant Natural := 65003;
   Cell_GFX_H        : constant Natural := 65004;
   Cell_GFX_COLOR    : constant Natural := 65005;
   Cell_GFX_KEY      : constant Natural := 65009;
   Cell_GFX_MOUSE_X  : constant Natural := 65010;
   Cell_GFX_MOUSE_Y  : constant Natural := 65011;
   Cell_GFX_MOUSE_BTN : constant Natural := 65012;

   BF_Nest_Indent   : Natural := 0;
   BF_Cmds_On_Line  : Natural := 0;
   BF_Line_Width    : constant Natural := 64;

   Current_Ptr      : Natural := 0;
   Next_Var_Slot    : Natural := Var_Slot_Base;
   Next_String_Cell : Natural := String_Pool_Base;
   VSP_Depth        : Natural := 0;
   USP_Depth        : Natural := 0;
   String_Counter   : Natural := 0;
   Reversible_Depth : Natural := 0;

   Max_Name_Length  : constant Natural := 320;
   -- FruitFractals + ALBMATH_PURE alone declare 130+ routines; keep headroom.
   Max_Var_Entries  : constant Natural := 2048;
   Max_Proc_Entries : constant Natural := 512;
   -- Per-proc fixed Body_Text blew RAM; record into a shared buffer then
   -- commit into a shared arena (DIV/MOD/PURE + call-inlining explode size).
   -- FruitFractals-scale ALBB programs exceed 32MB of recorded procedure BF.
   Max_Proc_Body_Cap : constant Natural := 128_000_000;
   Max_Body_Arena    : constant Natural := 192_000_000;
   Max_Ctrl_Depth    : constant Natural := 256;

   type Name_Record is record
      Len  : Natural := 0;
      Name : String (1 .. Max_Name_Length) := (others => ' ');
      Slot : Natural := 0;
      Size : Natural := 1;
   end record;
   type Name_Vault is array (1 .. Max_Var_Entries) of Name_Record;
   Var_Count : Natural := 0;
   Vars      : Name_Vault;

   type Proc_Record is record
      Len       : Natural := 0;
      Name      : String (1 .. Max_Name_Length) := (others => ' ');
      Body_Off  : Natural := 0;  -- 1-based offset into Body_Arena; 0 = empty
      Body_Len  : Natural := 0;
      Recording : Boolean := False;
   end record;
   type Proc_Vault is array (1 .. Max_Proc_Entries) of Proc_Record;
   Proc_Count         : Natural := 0;
   Procs              : Proc_Vault;
   Recording_Proc_Idx : Natural := 0;

   Recording_Buf : String (1 .. Max_Proc_Body_Cap) := (others => ' ');
   Recording_Len : Natural := 0;
   Body_Arena    : String (1 .. Max_Body_Arena) := (others => ' ');
   Arena_Len     : Natural := 0;

   Pending_Assign_Len  : Natural := 0;
   Pending_Assign_Name : String (1 .. Max_Name_Length) := (others => ' ');
   Pending_Call_Len    : Natural := 0;
   Pending_Call_Name   : String (1 .. Max_Name_Length) := (others => ' ');

   type Ctrl_ID_Vault is array (1 .. Max_Ctrl_Depth) of Natural;
   If_Counter   : Natural := 0;
   If_Depth     : Natural := 0;
   If_Stack     : Ctrl_ID_Vault := (others => 0);
   Loop_Counter : Natural := 0;
   Loop_Depth   : Natural := 0;
   Loop_Stack   : Ctrl_ID_Vault := (others => 0);
   Try_Counter  : Natural := 0;
   Try_Depth    : Natural := 0;
   Try_Stack    : Ctrl_ID_Vault := (others => 0);
   Case_Depth   : Natural := 0;
   Case_Stack   : Ctrl_ID_Vault := (others => 0);
   For_It_Slot  : Natural := 0;
   For_Hi_Slot  : Natural := 0;

   procedure Append (Str : String; Success : out Boolean);
   procedure Comment (Text : String; Success : out Boolean);
   procedure BF_Emit_Raw (Cmds : String; Success : out Boolean);
   procedure Move_To (Cell : Natural; Success : out Boolean);
   procedure Clear_Cell (Cell : Natural; Success : out Boolean);
   procedure Add_Const (Cell : Natural; N : Natural; Success : out Boolean);
   procedure Sub_Const (Cell : Natural; N : Natural; Success : out Boolean);
   procedure Set_Cell_Const (Cell : Natural; N : Natural; Success : out Boolean);
   procedure Copy_Cell (Src, Dest : Natural; Success : out Boolean);
   procedure Add_Cells (Src, Dest : Natural; Success : out Boolean);
   procedure Sub_Cells (Src, Dest : Natural; Success : out Boolean);
   procedure Mul_Cells (A, B, Dest : Natural; Success : out Boolean);
   procedure Push_Value_From (Cell : Natural; Success : out Boolean);
   procedure Pop_Value_To (Cell : Natural; Success : out Boolean);
   procedure Push_Undo_From (Cell : Natural; Success : out Boolean);
   procedure Print_Byte_At (Cell : Natural; Success : out Boolean);
   procedure Print_Number_ACC (Success : out Boolean);
   procedure Read_Byte_To (Cell : Natural; Success : out Boolean);
   procedure Host_Nop (Feature : String; Success : out Boolean);
   function Find_Var_Slot (Name : String) return Natural;
   function Alloc_Var_Slot (Name : String; Size : Natural) return Natural;
   function Find_Proc_Index (Name : String) return Natural;
   procedure Store_Name (Dest : out String; Dest_Len : out Natural; Src : String);
   procedure Emit_BinOp_Stack (Op : ALB_Opcode; Success : out Boolean);


   procedure Append (Str : String; Success : out Boolean) is
   begin
      if Recording_Proc_Idx > 0
        and then Procs (Recording_Proc_Idx).Recording
      then
         if Recording_Len + Str'Length <= Max_Proc_Body_Cap then
            Recording_Buf
              (Recording_Len + 1 ..
               Recording_Len + Str'Length) := Str;
            Recording_Len := Recording_Len + Str'Length;
            Success := True;
         else
            Ada.Text_IO.Put_Line
              ("ALBB FATAL: procedure body exceeded Max_Proc_Body_Cap ("
               & Natural'Image (Max_Proc_Body_Cap) & " bytes).");
            Success := False;
         end if;
         return;
      end if;

      if Current_Buffer = Buffer_Global then
         if Global_Len + Str'Length <= Max_Buffer_Size then
            Global_Buffer (Global_Len + 1 .. Global_Len + Str'Length) := Str;
            Global_Len := Global_Len + Str'Length;
            Success := True;
         else
            Success := False;
         end if;
      else
         if Main_Len + Str'Length <= Max_Buffer_Size then
            Main_Buffer (Main_Len + 1 .. Main_Len + Str'Length) := Str;
            Main_Len := Main_Len + Str'Length;
            Success := True;
         else
            Success := False;
         end if;
      end if;
   end Append;

   procedure Comment (Text : String; Success : out Boolean) is
   begin
      if Current_Format = Format_BF_Annotated then
         Append (ASCII.LF & Text & ASCII.LF, Success);
      else
         Success := True;
      end if;
   end Comment;

   procedure BF_Emit_Indent_Spaces (Success : in out Boolean) is
   begin
      for I in 1 .. BF_Nest_Indent * 2 loop
         exit when not Success;
         Append (" ", Success);
      end loop;
   end BF_Emit_Indent_Spaces;

   procedure BF_Emit_Cmd (Cmd : Character; Success : in out Boolean) is
   begin
      if not Success then
         return;
      end if;
      case Cmd is
         when '[' =>
            if Current_Format = Format_BF_Annotated then
               Append (String'(1 => ASCII.LF), Success);
               BF_Emit_Indent_Spaces (Success);
            end if;
            Append ("[", Success);
            BF_Nest_Indent := BF_Nest_Indent + 1;
            BF_Cmds_On_Line := 0;
            if Current_Format = Format_BF_Annotated then
               Append (String'(1 => ASCII.LF), Success);
               BF_Emit_Indent_Spaces (Success);
            end if;
         when ']' =>
            if BF_Nest_Indent > 0 then
               BF_Nest_Indent := BF_Nest_Indent - 1;
            end if;
            if Current_Format = Format_BF_Annotated then
               Append (String'(1 => ASCII.LF), Success);
               BF_Emit_Indent_Spaces (Success);
            end if;
            Append ("]", Success);
            BF_Cmds_On_Line := 0;
            if Current_Format = Format_BF_Annotated then
               Append (String'(1 => ASCII.LF), Success);
               BF_Emit_Indent_Spaces (Success);
            end if;
         when '>' | '<' | '+' | '-' | '.' | ',' =>
            if Current_Format = Format_BF_Annotated
              and then BF_Cmds_On_Line >= BF_Line_Width
            then
               Append (String'(1 => ASCII.LF), Success);
               BF_Emit_Indent_Spaces (Success);
               BF_Cmds_On_Line := 0;
            end if;
            Append (String'(1 => Cmd), Success);
            BF_Cmds_On_Line := BF_Cmds_On_Line + 1;
         when others =>
            if Current_Format = Format_BF_Annotated then
               Append (String'(1 => Cmd), Success);
            end if;
      end case;
   end BF_Emit_Cmd;

   procedure BF_Emit_Raw (Cmds : String; Success : out Boolean) is
      S : Boolean := True;
   begin
      for I in Cmds'Range loop
         exit when not S;
         case Cmds (I) is
            when '>' | '<' | '+' | '-' | '.' | ',' | '[' | ']' =>
               BF_Emit_Cmd (Cmds (I), S);
            when others =>
               if Current_Format = Format_BF_Annotated then
                  Append (String'(1 => Cmds (I)), S);
               end if;
         end case;
      end loop;
      Success := S;
   end BF_Emit_Raw;

   procedure Move_To (Cell : Natural; Success : out Boolean) is
      S : Boolean := True;
   begin
      if Cell > Current_Ptr then
         for I in 1 .. Cell - Current_Ptr loop
            BF_Emit_Raw (">", S);
            exit when not S;
         end loop;
      elsif Cell < Current_Ptr then
         for I in 1 .. Current_Ptr - Cell loop
            BF_Emit_Raw ("<", S);
            exit when not S;
         end loop;
      end if;
      if S then
         Current_Ptr := Cell;
      end if;
      Success := S;
   end Move_To;

   procedure Clear_Cell (Cell : Natural; Success : out Boolean) is
      S : Boolean;
   begin
      Move_To (Cell, S);
      if S then
         BF_Emit_Raw ("[-]", S);
      end if;
      Success := S;
   end Clear_Cell;

   procedure Add_Const (Cell : Natural; N : Natural; Success : out Boolean) is
      S      : Boolean;
      Remain : Natural := N;
   begin
      Move_To (Cell, S);
      while S and then Remain > 0 loop
         declare
            Chunk : constant Natural := Natural'Min (Remain, 16);
            Buf   : String (1 .. Chunk);
         begin
            for I in 1 .. Chunk loop
               Buf (I) := '+';
            end loop;
            BF_Emit_Raw (Buf, S);
            Remain := Remain - Chunk;
         end;
      end loop;
      Success := S;
   end Add_Const;

   procedure Sub_Const (Cell : Natural; N : Natural; Success : out Boolean) is
      S      : Boolean;
      Remain : Natural := N;
   begin
      Move_To (Cell, S);
      while S and then Remain > 0 loop
         declare
            Chunk : constant Natural := Natural'Min (Remain, 16);
            Buf   : String (1 .. Chunk);
         begin
            for I in 1 .. Chunk loop
               Buf (I) := '-';
            end loop;
            BF_Emit_Raw (Buf, S);
            Remain := Remain - Chunk;
         end;
      end loop;
      Success := S;
   end Sub_Const;

   procedure Set_Cell_Const (Cell : Natural; N : Natural; Success : out Boolean) is
      S : Boolean;
      V : constant Natural := N mod 256;
   begin
      Clear_Cell (Cell, S);
      if S and then V > 0 then
         Add_Const (Cell, V, S);
      end if;
      Success := S;
   end Set_Cell_Const;

   procedure Copy_Cell (Src, Dest : Natural; Success : out Boolean) is
      S : Boolean;
      T : constant Natural := Cell_TMP3;
   begin
      if Src = Dest then
         Success := True;
         return;
      end if;
      Clear_Cell (Dest, S);
      if not S then
         Success := False;
         return;
      end if;
      Clear_Cell (T, S);
      if not S then
         Success := False;
         return;
      end if;
      Move_To (Src, S);
      if S then BF_Emit_Raw ("[", S); end if;
      if S then BF_Emit_Raw ("-", S); end if;
      if S then Move_To (T, S); end if;
      if S then BF_Emit_Raw ("+", S); end if;
      if S then Move_To (Dest, S); end if;
      if S then BF_Emit_Raw ("+", S); end if;
      if S then Move_To (Src, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      if S then Move_To (T, S); end if;
      if S then BF_Emit_Raw ("[", S); end if;
      if S then BF_Emit_Raw ("-", S); end if;
      if S then Move_To (Src, S); end if;
      if S then BF_Emit_Raw ("+", S); end if;
      if S then Move_To (T, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      Success := S;
   end Copy_Cell;

   procedure Add_Cells (Src, Dest : Natural; Success : out Boolean) is
      S : Boolean;
      T : constant Natural := Cell_TMP2;
   begin
      Copy_Cell (Src, T, S);
      if not S then
         Success := False;
         return;
      end if;
      Move_To (T, S);
      if S then BF_Emit_Raw ("[", S); end if;
      if S then BF_Emit_Raw ("-", S); end if;
      if S then Move_To (Dest, S); end if;
      if S then BF_Emit_Raw ("+", S); end if;
      if S then Move_To (T, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      Success := S;
   end Add_Cells;

   procedure Sub_Cells (Src, Dest : Natural; Success : out Boolean) is
      S : Boolean;
      T : constant Natural := Cell_TMP2;
   begin
      Copy_Cell (Src, T, S);
      if not S then
         Success := False;
         return;
      end if;
      Move_To (T, S);
      if S then BF_Emit_Raw ("[", S); end if;
      if S then BF_Emit_Raw ("-", S); end if;
      if S then Move_To (Dest, S); end if;
      if S then BF_Emit_Raw ("-", S); end if;
      if S then Move_To (T, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      Success := S;
   end Sub_Cells;

   procedure Mul_Cells (A, B, Dest : Natural; Success : out Boolean) is
      S : Boolean;
   begin
      Clear_Cell (Dest, S);
      if not S then
         Success := False;
         return;
      end if;
      Copy_Cell (A, Cell_SCR0, S);
      if not S then
         Success := False;
         return;
      end if;
      Move_To (Cell_SCR0, S);
      if S then BF_Emit_Raw ("[", S); end if;
      if S then BF_Emit_Raw ("-", S); end if;
      if S then Copy_Cell (B, Cell_SCR1, S); end if;
      if S then Move_To (Cell_SCR1, S); end if;
      if S then BF_Emit_Raw ("[", S); end if;
      if S then BF_Emit_Raw ("-", S); end if;
      if S then Move_To (Dest, S); end if;
      if S then BF_Emit_Raw ("+", S); end if;
      if S then Move_To (Cell_SCR1, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      if S then Move_To (Cell_SCR0, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      Success := S;
   end Mul_Cells;

   procedure Push_Value_From (Cell : Natural; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      if VSP_Depth >= Value_Stack_Size then
         Ada.Text_IO.Put_Line
           ("ALBB FATAL: value stack overflow (VSP_Depth="
            & Natural'Image (VSP_Depth) & ").");
         Success := False;
         return;
      end if;
      Slot := Value_Stack_Base + VSP_Depth;
      Copy_Cell (Cell, Slot, S);
      if S then
         VSP_Depth := VSP_Depth + 1;
         Set_Cell_Const (Cell_VSP, VSP_Depth, S);
      end if;
      Success := S;
   end Push_Value_From;

   procedure Pop_Value_To (Cell : Natural; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      if VSP_Depth = 0 then
         Success := False;
         return;
      end if;
      VSP_Depth := VSP_Depth - 1;
      Slot := Value_Stack_Base + VSP_Depth;
      Copy_Cell (Slot, Cell, S);
      if S then
         Clear_Cell (Slot, S);
      end if;
      if S then
         Set_Cell_Const (Cell_VSP, VSP_Depth, S);
      end if;
      Success := S;
   end Pop_Value_To;

   procedure Push_Undo_From (Cell : Natural; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      if USP_Depth >= Undo_Stack_Size then
         Success := False;
         return;
      end if;
      Slot := Undo_Stack_Base + USP_Depth;
      Copy_Cell (Cell, Slot, S);
      if S then
         USP_Depth := USP_Depth + 1;
         Set_Cell_Const (Cell_USP, USP_Depth, S);
      end if;
      Success := S;
   end Push_Undo_From;

   procedure Print_Byte_At (Cell : Natural; Success : out Boolean) is
      S : Boolean;
   begin
      Move_To (Cell, S);
      if S then
         BF_Emit_Raw (".", S);
      end if;
      Success := S;
   end Print_Byte_At;

   procedure Read_Byte_To (Cell : Natural; Success : out Boolean) is
      S : Boolean;
   begin
      Move_To (Cell, S);
      if S then
         BF_Emit_Raw (",", S);
      end if;
      Success := S;
   end Read_Byte_To;


   -- Print ACC (0..255) as decimal. Digits stashed at Hist_Base..Hist_Base+2
   -- (ones, tens, hundreds), then printed high-to-low skipping leading zeros.
   procedure Print_Number_ACC (Success : out Boolean) is
      S : Boolean;
      D0 : constant Natural := Hist_Base;      -- ones ASCII
      D1 : constant Natural := Hist_Base + 1;  -- tens ASCII
      D2 : constant Natural := Hist_Base + 2;  -- hundreds ASCII
      NZ : constant Natural := Hist_Base + 3;  -- saw-nonzero flag
   begin
      Comment ("ALBB decimal print ACC", S);
      Clear_Cell (D0, S);
      if S then Clear_Cell (D1, S); end if;
      if S then Clear_Cell (D2, S); end if;
      if S then Clear_Cell (NZ, S); end if;
      if S then Copy_Cell (Cell_ACC, Cell_SCR0, S); end if;

      -- Hundreds digit: count subtractions of 100
      if S then Clear_Cell (Cell_SCR1, S); end if;
      if S then Move_To (Cell_SCR0, S); end if;
      -- Unrolled for 0..2 hundreds (byte max 255)
      for H in 1 .. 2 loop
         if not S then
            exit;
         end if;
         -- Try: if SCR0 >= 100, subtract 100 and SCR1++
         Copy_Cell (Cell_SCR0, Cell_TMP0, S);
         if S then Sub_Const (Cell_TMP0, 100, S); end if;
         -- If TMP0 underflowed wrapping in BF, detection is hard for emit-time
         -- unknown values. Use loop: set TMP1=100; while TMP1 and SCR0: both--
         -- Then if TMP1==0 we subtracted fully.
         if S then Set_Cell_Const (Cell_TMP1, 100, S); end if;
         if S then Copy_Cell (Cell_SCR0, Cell_TMP0, S); end if;
         if S then Move_To (Cell_TMP1, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then BF_Emit_Raw ("-", S); end if;
         if S then Move_To (Cell_TMP1, S); end if;
         if S then BF_Emit_Raw ("-", S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         if S then Move_To (Cell_TMP1, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         -- If TMP1==0, success: SCR0-=100, SCR1++
         if S then Copy_Cell (Cell_TMP1, Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Set_Cell_Const (Cell_TMP3, 1, S); end if;  -- fail flag
         if S then Clear_Cell (Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         -- if fail flag clear (TMP3==0): apply
         if S then Set_Cell_Const (Cell_TMP0, 1, S); end if;
         if S then Copy_Cell (Cell_TMP3, Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Clear_Cell (Cell_TMP0, S); end if;
         if S then Clear_Cell (Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Sub_Const (Cell_SCR0, 100, S); end if;
         if S then Add_Const (Cell_SCR1, 1, S); end if;
         if S then Clear_Cell (Cell_TMP0, S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         if S then Clear_Cell (Cell_TMP3, S); end if;
      end loop;

      if S then Copy_Cell (Cell_SCR1, D2, S); end if;
      if S then Add_Const (D2, 48, S); end if;

      -- Tens: count subtractions of 10 (up to 9)
      if S then Clear_Cell (Cell_SCR1, S); end if;
      for T in 1 .. 9 loop
         if not S then
            exit;
         end if;
         if S then Set_Cell_Const (Cell_TMP1, 10, S); end if;
         if S then Copy_Cell (Cell_SCR0, Cell_TMP0, S); end if;
         if S then Move_To (Cell_TMP1, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then BF_Emit_Raw ("-", S); end if;
         if S then Move_To (Cell_TMP1, S); end if;
         if S then BF_Emit_Raw ("-", S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         if S then Move_To (Cell_TMP1, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         if S then Clear_Cell (Cell_TMP3, S); end if;
         if S then Copy_Cell (Cell_TMP1, Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Set_Cell_Const (Cell_TMP3, 1, S); end if;
         if S then Clear_Cell (Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         if S then Set_Cell_Const (Cell_TMP0, 1, S); end if;
         if S then Copy_Cell (Cell_TMP3, Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Clear_Cell (Cell_TMP0, S); end if;
         if S then Clear_Cell (Cell_TMP2, S); end if;
         if S then Move_To (Cell_TMP2, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("[", S); end if;
         if S then Sub_Const (Cell_SCR0, 10, S); end if;
         if S then Add_Const (Cell_SCR1, 1, S); end if;
         if S then Clear_Cell (Cell_TMP0, S); end if;
         if S then Move_To (Cell_TMP0, S); end if;
         if S then BF_Emit_Raw ("]", S); end if;
      end loop;

      if S then Copy_Cell (Cell_SCR1, D1, S); end if;
      if S then Add_Const (D1, 48, S); end if;

      -- Ones = remaining SCR0
      if S then Copy_Cell (Cell_SCR0, D0, S); end if;
      if S then Add_Const (D0, 48, S); end if;

      -- Print D2,D1,D0 skipping leading zeros; always print at least ones.
      -- Hundreds:
      if S then Copy_Cell (D2, Cell_TMP0, S); end if;
      if S then Sub_Const (Cell_TMP0, 48, S); end if;
      if S then Move_To (Cell_TMP0, S); end if;
      if S then BF_Emit_Raw ("[", S); end if;
      if S then Print_Byte_At (D2, S); end if;
      if S then Set_Cell_Const (NZ, 1, S); end if;
      if S then Clear_Cell (Cell_TMP0, S); end if;
      if S then Move_To (Cell_TMP0, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      -- Tens if NZ or tens!=0:
      if S then Copy_Cell (D1, Cell_TMP0, S); end if;
      if S then Sub_Const (Cell_TMP0, 48, S); end if;
      if S then Add_Cells (NZ, Cell_TMP0, S); end if;
      if S then Move_To (Cell_TMP0, S); end if;
      if S then BF_Emit_Raw ("[", S); end if;
      if S then Print_Byte_At (D1, S); end if;
      if S then Set_Cell_Const (NZ, 1, S); end if;
      if S then Clear_Cell (Cell_TMP0, S); end if;
      if S then Move_To (Cell_TMP0, S); end if;
      if S then BF_Emit_Raw ("]", S); end if;
      -- Ones always
      if S then Print_Byte_At (D0, S); end if;
      Success := S;
   end Print_Number_ACC;

   procedure Host_Nop (Feature : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB NOP host feature: " & Feature, S);
      Clear_Cell (Cell_Zero, S);
      Success := S;
   end Host_Nop;

   procedure Store_Name (Dest : out String; Dest_Len : out Natural; Src : String) is
      N : Natural;
   begin
      Dest := (others => ' ');
      if Src'Length <= Dest'Length then
         N := Src'Length;
      else
         N := Dest'Length;
      end if;
      Dest (1 .. N) := Src (Src'First .. Src'First + N - 1);
      Dest_Len := N;
   end Store_Name;

   function Find_Var_Slot (Name : String) return Natural is
   begin
      for I in 1 .. Var_Count loop
         if Vars (I).Len = Name'Length
           and then Vars (I).Name (1 .. Name'Length) = Name
         then
            return Vars (I).Slot;
         end if;
      end loop;
      return 0;
   end Find_Var_Slot;

   function Alloc_Var_Slot (Name : String; Size : Natural) return Natural is
      Existing : constant Natural := Find_Var_Slot (Name);
      Slot     : Natural;
      Need     : constant Natural := Natural'Max (1, Size);
   begin
      if Existing > 0 then
         return Existing;
      end if;
      if Var_Count >= Max_Var_Entries then
         return 0;
      end if;
      if Next_Var_Slot + Need - 1 >= String_Pool_Base then
         return 0;
      end if;
      Slot := Next_Var_Slot;
      Next_Var_Slot := Next_Var_Slot + Need;
      Var_Count := Var_Count + 1;
      Vars (Var_Count).Len := Natural'Min (Name'Length, Max_Name_Length);
      Vars (Var_Count).Name (1 .. Vars (Var_Count).Len) :=
        Name (Name'First .. Name'First + Vars (Var_Count).Len - 1);
      Vars (Var_Count).Slot := Slot;
      Vars (Var_Count).Size := Need;
      return Slot;
   end Alloc_Var_Slot;

   function Find_Proc_Index (Name : String) return Natural is
   begin
      for I in 1 .. Proc_Count loop
         if Procs (I).Len = Name'Length
           and then Procs (I).Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Proc_Index;


   procedure Init_Emitter (Success : out Boolean) is
   begin
      Global_Len := 0;
      Main_Len := 0;
      Indent_Level := 0;
      In_Global_Scope := True;
      Current_Buffer := Buffer_Global;
      Current_Format := Format_BF_Annotated;
      BF_Emitter_Ready := True;
      Current_Ptr := 0;
      Next_Var_Slot := Var_Slot_Base;
      Next_String_Cell := String_Pool_Base;
      VSP_Depth := 0;
      USP_Depth := 0;
      String_Counter := 0;
      Reversible_Depth := 0;
      Var_Count := 0;
      Proc_Count := 0;
      Recording_Proc_Idx := 0;
      Recording_Len := 0;
      Arena_Len := 0;
      Pending_Assign_Len := 0;
      Pending_Call_Len := 0;
      If_Counter := 0;
      If_Depth := 0;
      If_Stack := (others => 0);
      Loop_Counter := 0;
      Loop_Depth := 0;
      Loop_Stack := (others => 0);
      Try_Counter := 0;
      Try_Depth := 0;
      Try_Stack := (others => 0);
      Case_Depth := 0;
      Case_Stack := (others => 0);
      For_It_Slot := 0;
      For_Hi_Slot := 0;
      BF_Nest_Indent := 0;
      BF_Cmds_On_Line := 0;
      Emit_Native_Brainfuck_Gfx.Init;
      Success := True;
   end Init_Emitter;

   procedure Flush_To_File (File_Path : String; Success : out Boolean) is
      File : Ada.Text_IO.File_Type;
      Gfx_OK : Boolean := True;
   begin
      Success := True;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, File_Path);
         Ada.Text_IO.Put (File, Global_Buffer (1 .. Global_Len));
         Ada.Text_IO.Put (File, Main_Buffer (1 .. Main_Len));
         Ada.Text_IO.Close (File);
      exception
         when others =>
            Success := False;
      end;

      if Success and then Emit_Native_Brainfuck_Gfx.Graphics_Used
        and then not Emit_Native_Brainfuck_Gfx.Skip_Companion_Write
      then
         Emit_Native_Brainfuck_Gfx.Write_Companion_Fasm
           (BF_File_Path => File_Path,
            BF_Part_A    => Global_Buffer (1 .. Global_Len),
            BF_Part_B    => Main_Buffer (1 .. Main_Len),
            Success      => Gfx_OK);
         if not Gfx_OK then
            Success := False;
         end if;
      end if;
   end Flush_To_File;

   procedure Set_Active_Buffer (Target : Buffer_Target) is
   begin
      Current_Buffer := Target;
   end Set_Active_Buffer;

   procedure Set_Output_Format (Format : BF_Output_Format) is
   begin
      Current_Format := Format;
   end Set_Output_Format;

   procedure Emit_Program_Start (Program_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Current_Buffer := Buffer_Global;
      Comment ("ALBB program " & Program_Name, S);
      case Current_Format is
         when Format_BF_Raw =>
            null;
         when Format_BF_Annotated =>
            Comment ("tape init clear sentinel and ACC", S);
         when Format_BF_Compact =>
            null;
      end case;
      Clear_Cell (Cell_Zero, S);
      if S then Clear_Cell (Cell_ACC, S); end if;
      if S then Clear_Cell (Cell_FLAG_COND, S); end if;
      if S then Clear_Cell (Cell_FLAG_ERR, S); end if;
      if S then Clear_Cell (Cell_VSP, S); end if;
      if S then Clear_Cell (Cell_USP, S); end if;
      Current_Buffer := Buffer_Main;
      In_Global_Scope := False;
      Comment ("ALBB main code stream", S);
      Success := S;
   end Emit_Program_Start;

   procedure Emit_Program_End (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB program end — pointer to ZERO", S);
      Move_To (Cell_Zero, S);
      Success := S;
   end Emit_Program_End;

   procedure Emit_Raw (Text : String; Success : out Boolean) is
   begin
      -- Pass through; BF_Emit_Raw filters in non-annotated modes when used,
      -- but Emit_Raw mirrors FASM and appends text as requested.
      if Current_Format = Format_BF_Annotated then
         Append (Text, Success);
      else
         BF_Emit_Raw (Text, Success);
      end if;
   end Emit_Raw;

   procedure Emit_Native_ASM_Block
     (Block_Text : String;
      Success    : out Boolean)
   is
      S : Boolean;
   begin
      Comment ("ALBB native block (BF-filtered)", S);
      BF_Emit_Raw (Block_Text, S);
      Success := S;
   end Emit_Native_ASM_Block;

   procedure Emit_Native_ASM_Expression
     (Block_Text : String;
      Success    : out Boolean)
   is
      S : Boolean;
   begin
      Comment ("ALBB native expr (BF-filtered)", S);
      BF_Emit_Raw (Block_Text, S);
      Success := S;
   end Emit_Native_ASM_Expression;


   -- =========================================================================
   -- BIJECTIVE ENGINE / REVERSIBLE STATE FORGE
   -- =========================================================================
   procedure Emit_Reversible_Block_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Reversible_Depth := Reversible_Depth + 1;
      Comment ("ALBB reversible block start", S);
      Success := S;
   end Emit_Reversible_Block_Start;

   procedure Emit_Reversible_Block_End (Success : out Boolean) is
      S : Boolean;
   begin
      if Reversible_Depth > 0 then
         Reversible_Depth := Reversible_Depth - 1;
      end if;
      Comment ("ALBB reversible block end", S);
      Success := S;
   end Emit_Reversible_Block_End;

   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Target_Tag);
   begin
      Comment ("ALBB REVADD " & Target_Name, S);
      Slot := Alloc_Var_Slot (Target_Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Slot, S);
      if S then
         Add_Cells (Cell_ACC, Slot, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Rev_Add;

   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Target_Tag);
   begin
      Comment ("ALBB REVSUB " & Target_Name, S);
      Slot := Alloc_Var_Slot (Target_Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Slot, S);
      if S then
         Sub_Cells (Cell_ACC, Slot, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Rev_Sub;

   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Target_Tag);
   begin
      -- Byte XOR via (a+b) - 2*(a AND b) approximation not exact in BF;
      -- pragmatic: push undo, then ACC := ACC + Slot (documented weak XOR).
      Comment ("ALBB REVXOR approx-add " & Target_Name, S);
      Slot := Alloc_Var_Slot (Target_Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Slot, S);
      if S then
         Add_Cells (Cell_ACC, Slot, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Rev_Xor;

   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Target_Tag);
   begin
      Comment ("ALBB REVROL (byte*2 wrap) " & Target_Name, S);
      Slot := Alloc_Var_Slot (Target_Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Slot, S);
      if S then
         Copy_Cell (Slot, Cell_TMP0, S);
      end if;
      if S then
         Add_Cells (Cell_TMP0, Slot, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Rev_Rol;

   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Target_Tag);
   begin
      Comment ("ALBB REVROR (halve) " & Target_Name, S);
      Slot := Alloc_Var_Slot (Target_Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Slot, S);
      -- Halve by pairing decrements into TMP0 count
      if S then
         Clear_Cell (Cell_TMP0, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_TMP1, S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         BF_Emit_Raw ("-", S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         BF_Emit_Raw ("-", S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("+", S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Copy_Cell (Cell_TMP0, Slot, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Rev_Ror;

   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   is
      S     : Boolean;
      Left  : Natural;
      Right : Natural;
      pragma Unreferenced (Left_Tag, Right_Tag);
   begin
      Comment ("ALBB REVSWAP " & Left_Name & " " & Right_Name, S);
      Left := Alloc_Var_Slot (Left_Name, 1);
      Right := Alloc_Var_Slot (Right_Name, 1);
      if Left = 0 or else Right = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Left, S);
      if S then
         Push_Undo_From (Right, S);
      end if;
      if S then
         Copy_Cell (Left, Cell_TMP0, S);
      end if;
      if S then
         Copy_Cell (Right, Left, S);
      end if;
      if S then
         Copy_Cell (Cell_TMP0, Right, S);
      end if;
      Success := S;
   end Emit_Rev_Swap;

   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Target_Tag);
   begin
      Comment ("ALBB REVNOT (255-x) " & Target_Name, S);
      Slot := Alloc_Var_Slot (Target_Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Slot, S);
      if S then
         Set_Cell_Const (Cell_TMP0, 255, S);
      end if;
      if S then
         Sub_Cells (Slot, Cell_TMP0, S);
      end if;
      if S then
         Copy_Cell (Cell_TMP0, Slot, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Rev_Not;

   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Target_Tag);
   begin
      Comment ("ALBB REVNEG (0-x wrap) " & Target_Name, S);
      Slot := Alloc_Var_Slot (Target_Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Push_Undo_From (Slot, S);
      if S then
         Clear_Cell (Cell_TMP0, S);
      end if;
      if S then
         Sub_Cells (Slot, Cell_TMP0, S);
      end if;
      if S then
         Copy_Cell (Cell_TMP0, Slot, S);
      end if;
      if S then
         Copy_Cell (Slot, Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Rev_Neg;

   procedure Emit_Newline (Success : out Boolean) is
   begin
      if Current_Format = Format_BF_Annotated then
         Append (ASCII.LF & "", Success);
      else
         Success := True;
      end if;
   end Emit_Newline;

   procedure Emit_Indent (Success : out Boolean) is
      S : Boolean := True;
   begin
      if Current_Format = Format_BF_Annotated then
         for I in 1 .. Indent_Level * 2 loop
            Append (" ", S);
            exit when not S;
         end loop;
      end if;
      Success := S;
   end Emit_Indent;

   procedure Increase_Indent is
   begin
      Indent_Level := Indent_Level + 1;
   end Increase_Indent;

   procedure Decrease_Indent is
   begin
      if Indent_Level > 0 then
         Indent_Level := Indent_Level - 1;
      end if;
   end Decrease_Indent;

   procedure Emit_Type_Definition (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
      pragma Unreferenced (Tag);
   begin
      Comment ("ALBB type def", S);
      Success := S;
   end Emit_Type_Definition;

   procedure Emit_Pure_Struct_Def (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB pure struct", S);
      Success := S;
   end Emit_Pure_Struct_Def;

   procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Current_Buffer := Buffer_Global;
      Comment ("ALBB struct start " & Struct_Name, S);
      Success := S;
   end Emit_Struct_Start;

   procedure Emit_Struct_Field
     (Field_Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S : Boolean;
      pragma Unreferenced (Tag);
   begin
      Comment ("ALBB struct field " & Field_Name, S);
      Success := S;
   end Emit_Struct_Field;

   procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB struct end " & Struct_Name, S);
      Current_Buffer := Buffer_Main;
      Success := S;
   end Emit_Struct_End;

   procedure Emit_Forward_Declaration
     (Func_Name : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Comment ("ALBB forward " & Func_Name, S);
      Success := S;
   end Emit_Forward_Declaration;

   procedure Emit_Var_Decl
     (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Tag);
   begin
      Comment ("ALBB var " & Name, S);
      Slot := Alloc_Var_Slot (Name, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Clear_Cell (Slot, S);
      Success := S;
   end Emit_Var_Decl;

   procedure Emit_Strict_Array_Decl
     (Name : String; Size_Bytes : Natural; Success : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      Need  : constant Natural := Natural'Max (1, Size_Bytes);
   begin
      Comment ("ALBB strict array " & Name, S);
      Slot := Alloc_Var_Slot (Name, Need);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      for I in 0 .. Need - 1 loop
         Clear_Cell (Slot + I, S);
         exit when not S;
      end loop;
      Success := S;
   end Emit_Strict_Array_Decl;

   procedure Emit_Slide_Array_Decl
     (Name : String; Max_Bytes : Natural; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Strict_Array_Decl (Name, Max_Bytes, S);
      Success := S;
   end Emit_Slide_Array_Decl;

   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      S    : Boolean;
      Need  : constant Natural := 1 + Natural'Max (1, History_Depth);
      Slot : Natural;
      pragma Unreferenced (Tag);
   begin
      Comment ("ALBB temporal var " & Name, S);
      Slot := Alloc_Var_Slot (Name, Need);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      for I in 0 .. Need - 1 loop
         Clear_Cell (Slot + I, S);
         exit when not S;
      end loop;
      Success := S;
   end Emit_Temporal_Var_Decl;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      Depth : constant Natural := Natural'Max (1, History_Depth);
      pragma Unreferenced (Tag);
   begin
      Comment ("ALBB temporal record " & Name, S);
      Slot := Alloc_Var_Slot (Name, 1 + Depth);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      -- Shift history cells right: slot+Depth .. slot+1 := previous
      for I in reverse 1 .. Depth loop
         Copy_Cell (Slot + I - 1, Slot + I, S);
         exit when not S;
      end loop;
      if S then
         Copy_Cell (Cell_ACC, Slot, S);
      end if;
      Success := S;
   end Emit_Temporal_Record_Current;

   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      pragma Unreferenced (Tag);
   begin
      Slot := Find_Var_Slot (Name);
      if Slot = 0 then
         Slot := Alloc_Var_Slot (Name, 2);
      end if;
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Copy_Cell (Slot, Cell_ACC, S);
      Success := S;
   end Emit_Temporal_Load_Now;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
      Off  : constant Natural := Natural'Min (History_Depth, 8);
      pragma Unreferenced (Tag);
   begin
      Slot := Find_Var_Slot (Name);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Copy_Cell (Slot + Off, Cell_ACC, S);
      Success := S;
   end Emit_Temporal_Load_Past;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   is
      S : Boolean;
   begin
      Comment ("ALBB temporal timeline " & Name, S);
      Host_Nop ("temporal_timeline", S);
      Success := S;
   end Emit_Temporal_Load_Timeline;

   procedure Emit_Struct_Var_Decl
     (Struct_Name : String; Var_Name : String; Success : out Boolean)
   is
      S    : Boolean;
      Slot : Natural;
   begin
      Comment ("ALBB struct var " & Struct_Name & "." & Var_Name, S);
      Slot := Alloc_Var_Slot (Var_Name, 8);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      for I in 0 .. 7 loop
         Clear_Cell (Slot + I, S);
         exit when not S;
      end loop;
      Success := S;
   end Emit_Struct_Var_Decl;

   procedure Emit_Function_Decl_Start
     (Name : String; Return_Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S   : Boolean;
      Idx : Natural;
      pragma Unreferenced (Return_Tag);
   begin
      Comment ("ALBB function " & Name, S);
      Idx := Find_Proc_Index (Name);
      if Idx = 0 then
         if Proc_Count >= Max_Proc_Entries then
            Ada.Text_IO.Put_Line
              ("ALBB FATAL: Max_Proc_Entries exceeded ("
               & Natural'Image (Max_Proc_Entries) & ").");
            Success := False;
            return;
         end if;
         Proc_Count := Proc_Count + 1;
         Idx := Proc_Count;
         Store_Name (Procs (Idx).Name, Procs (Idx).Len, Name);
      end if;
      Procs (Idx).Body_Off := 0;
      Procs (Idx).Body_Len := 0;
      Procs (Idx).Recording := True;
      Recording_Proc_Idx := Idx;
      Recording_Len := 0;
      Success := S;
   end Emit_Function_Decl_Start;

   procedure Emit_Let_Assign_Start (Type_Hint : String; Success : out Boolean) is
      S : Boolean;
      pragma Unreferenced (Type_Hint);
   begin
      Comment ("ALBB let/assign expr", S);
      Success := S;
   end Emit_Let_Assign_Start;

   procedure Emit_Variable_Ref (Name : String; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      Slot := Find_Var_Slot (Name);
      if Slot = 0 then
         Slot := Alloc_Var_Slot (Name, 1);
      end if;
      if Slot = 0 then
         Success := False;
         return;
      end if;
      Copy_Cell (Slot, Cell_ACC, S);
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      -- Remember for possible assignment target
      Store_Name (Pending_Assign_Name, Pending_Assign_Len, Name);
      Success := S;
   end Emit_Variable_Ref;

   procedure Emit_Array_Index_Open (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB array index open", S);
      -- Index expression will leave value on stack / ACC
      Success := S;
   end Emit_Array_Index_Open;

   procedure Emit_Array_Index_Close (Success : out Boolean) is
      S    : Boolean;
      Base : Natural;
      Idx  : Natural;
   begin
      Comment ("ALBB array index close", S);
      -- Pop index to TMP0; base name in Pending_Assign; load base[index] to ACC
      Pop_Value_To (Cell_TMP0, S);
      if not S then
         Success := False;
         return;
      end if;
      if Pending_Assign_Len = 0 then
         Success := False;
         return;
      end if;
      Base := Find_Var_Slot
        (Pending_Assign_Name (1 .. Pending_Assign_Len));
      if Base = 0 then
         Success := False;
         return;
      end if;
      -- Simplified: only support index 0..size via ACC=index already in TMP0;
      -- emit load of Base (index ignored beyond comment — use Base+0 for safety
      -- when runtime index unknown). Copy Base to ACC as element 0 fallback,
      -- then add TMP0 as offset by destructive walk into TMP1.
      Copy_Cell (Cell_TMP0, Cell_TMP1, S);
      if S then
         Set_Cell_Const (Cell_SCR0, Base, S);
      end if;
      -- Cannot compute runtime Base+index pointer easily without ptr cells;
      -- load Base cell and document limitation.
      if S then
         Copy_Cell (Base, Cell_ACC, S);
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Array_Index_Close;

   procedure Emit_AddressOf (Success : out Boolean) is
      S : Boolean;
   begin
      -- Leave slot index of pending name in ACC
      if Pending_Assign_Len > 0 then
         declare
            Slot : constant Natural :=
              Find_Var_Slot (Pending_Assign_Name (1 .. Pending_Assign_Len));
         begin
            if Slot = 0 then
               Success := False;
               return;
            end if;
            Set_Cell_Const (Cell_ACC, Slot, S);
            if S then
               Push_Value_From (Cell_ACC, S);
            end if;
            Success := S;
            return;
         end;
      end if;
      Host_Nop ("addressof", S);
      Success := S;
   end Emit_AddressOf;

   procedure Emit_Boolean_Cast_Start (Success : out Boolean) is
      S : Boolean;
   begin
      -- Normalize ACC to 0/1
      Comment ("ALBB bool cast", S);
      Copy_Cell (Cell_ACC, Cell_TMP0, S);
      if S then
         Clear_Cell (Cell_ACC, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Set_Cell_Const (Cell_ACC, 1, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP0, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      Success := S;
   end Emit_Boolean_Cast_Start;

   procedure Emit_Literal_U64 (Value : U64; Success : out Boolean) is
      S : Boolean;
      V : constant Natural := Natural (Value mod 16#100#);
   begin
      Set_Cell_Const (Cell_ACC, V, S);
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Literal_U64;

   procedure Emit_String_Literal (Text : String; Success : out Boolean) is
      S     : Boolean;
      Start : Natural;
      Len   : Natural;
   begin
      Comment ("ALBB string literal", S);
      Len := Text'Length;
      if Next_String_Cell + Len + 1 >= Hist_Base then
         Success := False;
         return;
      end if;
      Start := Next_String_Cell;
      for I in Text'Range loop
         Set_Cell_Const
           (Next_String_Cell, Character'Pos (Text (I)), S);
         exit when not S;
         Next_String_Cell := Next_String_Cell + 1;
      end loop;
      if S then
         Clear_Cell (Next_String_Cell, S);  -- NUL
         Next_String_Cell := Next_String_Cell + 1;
      end if;
      if S then
         Set_Cell_Const (Cell_ACC, Start, S);
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      String_Counter := String_Counter + 1;
      Success := S;
   end Emit_String_Literal;

   procedure Emit_Expression_Open (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB expr open", S);
      Success := S;
   end Emit_Expression_Open;

   procedure Emit_Expression_Close (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB expr close", S);
      -- Ensure ACC holds top of stack
      if VSP_Depth > 0 then
         Copy_Cell (Value_Stack_Base + VSP_Depth - 1, Cell_ACC, S);
      else
         S := True;
      end if;
      Success := S;
   end Emit_Expression_Close;

   procedure Emit_BinOp_Stack (Op : ALB_Opcode; Success : out Boolean) is
      S : Boolean;
   begin
      -- Pop RHS -> TMP1, Pop LHS -> TMP0, result -> ACC, push
      Pop_Value_To (Cell_TMP1, S);
      if not S then
         Success := False;
         return;
      end if;
      Pop_Value_To (Cell_TMP0, S);
      if not S then
         Success := False;
         return;
      end if;
      case Op is
         when OP_ADD =>
            Copy_Cell (Cell_TMP0, Cell_ACC, S);
            if S then
               Add_Cells (Cell_TMP1, Cell_ACC, S);
            end if;
         when OP_SUB =>
            Copy_Cell (Cell_TMP0, Cell_ACC, S);
            if S then
               Sub_Cells (Cell_TMP1, Cell_ACC, S);
            end if;
         when OP_MUL =>
            Mul_Cells (Cell_TMP0, Cell_TMP1, Cell_ACC, S);
         when OP_DIV | OP_MOD =>
            -- Integer div/mod via repeated subtraction
            Clear_Cell (Cell_ACC, S);
            if S then
               Copy_Cell (Cell_TMP0, Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Copy_Cell (Cell_TMP1, Cell_SCR1, S);
            end if;
            if S then
               -- subtract divisor from remaining; if can't, break
               Copy_Cell (Cell_SCR0, Cell_SCR2, S);
            end if;
            if S then
               Sub_Cells (Cell_SCR1, Cell_SCR2, S);
            end if;
            -- Heuristic: always subtract once and inc quot (byte-level)
            if S then
               Sub_Cells (Cell_TMP1, Cell_SCR0, S);
            end if;
            if S then
               Add_Const (Cell_ACC, 1, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
            if Op = OP_MOD then
               Copy_Cell (Cell_SCR0, Cell_ACC, S);
            end if;
         when OP_AND =>
            -- Boolean-ish AND: (LHS!=0) and (RHS!=0) -> 0/1
            Clear_Cell (Cell_ACC, S);
            Copy_Cell (Cell_TMP0, Cell_SCR0, S);
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Copy_Cell (Cell_TMP1, Cell_SCR1, S);
            end if;
            if S then
               Move_To (Cell_SCR1, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Set_Cell_Const (Cell_ACC, 1, S);
            end if;
            if S then
               Clear_Cell (Cell_SCR1, S);
            end if;
            if S then
               Move_To (Cell_SCR1, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
            if S then
               Clear_Cell (Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
         when OP_OR | OP_LOGICAL_OR =>
            Clear_Cell (Cell_ACC, S);
            Copy_Cell (Cell_TMP0, Cell_SCR0, S);
            if S then
               Add_Cells (Cell_TMP1, Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Set_Cell_Const (Cell_ACC, 1, S);
            end if;
            if S then
               Clear_Cell (Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
         when OP_XOR =>
            Copy_Cell (Cell_TMP0, Cell_ACC, S);
            if S then
               Add_Cells (Cell_TMP1, Cell_ACC, S);
            end if;
         when OP_SHL =>
            Copy_Cell (Cell_TMP0, Cell_ACC, S);
            Copy_Cell (Cell_TMP1, Cell_SCR0, S);
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               BF_Emit_Raw ("-", S);
            end if;
            if S then
               Copy_Cell (Cell_ACC, Cell_TMP2, S);
            end if;
            if S then
               Add_Cells (Cell_TMP2, Cell_ACC, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
         when OP_SHR =>
            Copy_Cell (Cell_TMP0, Cell_ACC, S);
            Copy_Cell (Cell_TMP1, Cell_SCR0, S);
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               BF_Emit_Raw ("-", S);
            end if;
            -- halve ACC once per shift
            Clear_Cell (Cell_TMP2, S);
            Copy_Cell (Cell_ACC, Cell_TMP3, S);
            if S then
               Move_To (Cell_TMP3, S);
            end if;
            if S then
               BF_Emit_Raw ("[->-<[->>+<<]]>", S);
            end if;
            -- fallback simple: ACC := ACC (no-op) if pattern messy — clear and copy TMP2
            if S then
               Copy_Cell (Cell_TMP2, Cell_ACC, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
         when OP_CMP_EQ =>
            -- ACC := (LHS==RHS) ? 1 : 0  via difference zero test
            Copy_Cell (Cell_TMP0, Cell_SCR0, S);
            if S then
               Sub_Cells (Cell_TMP1, Cell_SCR0, S);
            end if;
            Clear_Cell (Cell_ACC, S);
            Set_Cell_Const (Cell_SCR1, 1, S);
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Clear_Cell (Cell_SCR1, S);
            end if;
            if S then
               Clear_Cell (Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
            if S then
               Copy_Cell (Cell_SCR1, Cell_ACC, S);
            end if;
         when OP_CMP_NEQ =>
            Copy_Cell (Cell_TMP0, Cell_SCR0, S);
            if S then
               Sub_Cells (Cell_TMP1, Cell_SCR0, S);
            end if;
            Clear_Cell (Cell_ACC, S);
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Set_Cell_Const (Cell_ACC, 1, S);
            end if;
            if S then
               Clear_Cell (Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
         when OP_CMP_LT | OP_CMP_LTE | OP_CMP_GT | OP_CMP_GTE =>
            -- Approximate: ACC := (LHS - RHS) nonzero / zero tests
            Copy_Cell (Cell_TMP0, Cell_ACC, S);
            if S then
               Sub_Cells (Cell_TMP1, Cell_ACC, S);
            end if;
            -- Normalize to 0/1 for LT-ish (nonzero difference)
            Copy_Cell (Cell_ACC, Cell_SCR0, S);
            Clear_Cell (Cell_ACC, S);
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Set_Cell_Const (Cell_ACC, 1, S);
            end if;
            if S then
               Clear_Cell (Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
         when OP_LOGICAL_AND =>
            Clear_Cell (Cell_ACC, S);
            Copy_Cell (Cell_TMP0, Cell_SCR0, S);
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Copy_Cell (Cell_TMP1, Cell_SCR1, S);
            end if;
            if S then
               Move_To (Cell_SCR1, S);
            end if;
            if S then
               BF_Emit_Raw ("[", S);
            end if;
            if S then
               Set_Cell_Const (Cell_ACC, 1, S);
            end if;
            if S then
               Clear_Cell (Cell_SCR1, S);
            end if;
            if S then
               Move_To (Cell_SCR1, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
            if S then
               Clear_Cell (Cell_SCR0, S);
            end if;
            if S then
               Move_To (Cell_SCR0, S);
            end if;
            if S then
               BF_Emit_Raw ("]", S);
            end if;
         when others =>
            Copy_Cell (Cell_TMP0, Cell_ACC, S);
      end case;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_BinOp_Stack;

   procedure Emit_BinOp (Op : ALB_Opcode; Success : out Boolean) is
   begin
      Emit_BinOp_Stack (Op, Success);
   end Emit_BinOp;

   procedure Emit_Branchless_Condition_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB branchless cond", S);
      Success := S;
   end Emit_Branchless_Condition_Start;

   procedure Emit_Branchless_Mask_Op (Success : out Boolean) is
      S : Boolean;
   begin
      -- mask: pop mask, pop b, pop a -> (a&m)|(b&~m) approx as select
      Comment ("ALBB branchless mask", S);
      Pop_Value_To (Cell_TMP2, S);  -- mask
      if S then
         Pop_Value_To (Cell_TMP1, S);
      end if;
      if S then
         Pop_Value_To (Cell_TMP0, S);
      end if;
      if S then
         -- if mask: ACC=TMP0 else TMP1
         Clear_Cell (Cell_ACC, S);
      end if;
      if S then
         Copy_Cell (Cell_TMP2, Cell_SCR0, S);
      end if;
      if S then
         Move_To (Cell_SCR0, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Copy_Cell (Cell_TMP0, Cell_ACC, S);
      end if;
      if S then
         Set_Cell_Const (Cell_SCR1, 1, S);
      end if;
      if S then
         Clear_Cell (Cell_SCR0, S);
      end if;
      if S then
         Move_To (Cell_SCR0, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Set_Cell_Const (Cell_SCR0, 1, S);
      end if;
      if S then
         Copy_Cell (Cell_SCR1, Cell_TMP3, S);
      end if;
      if S then
         Move_To (Cell_TMP3, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Clear_Cell (Cell_SCR0, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP3, S);
      end if;
      if S then
         Move_To (Cell_TMP3, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Move_To (Cell_SCR0, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Copy_Cell (Cell_TMP1, Cell_ACC, S);
      end if;
      if S then
         Clear_Cell (Cell_SCR0, S);
      end if;
      if S then
         Move_To (Cell_SCR0, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Branchless_Mask_Op;


   -- =========================================================================
   -- CONTROL FLOW
   -- =========================================================================
   procedure Emit_If_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB if start", S);
      If_Counter := If_Counter + 1;
      if If_Depth < Max_Ctrl_Depth then
         If_Depth := If_Depth + 1;
         If_Stack (If_Depth) := If_Counter;
      end if;
      -- Condition already in ACC / stack top
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      if S then
         Copy_Cell (Cell_ACC, Cell_FLAG_COND, S);
      end if;
      if S then
         Set_Cell_Const (Cell_FLAG_ELSE, 1, S);
      end if;
      Success := S;
   end Emit_If_Start;

   procedure Emit_Then (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB then", S);
      Increase_Indent;
      -- while FLAG_COND: clear else-flag; then-body; clear FLAG_COND
      Move_To (Cell_FLAG_COND, S);
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Clear_Cell (Cell_FLAG_ELSE, S);
      end if;
      Success := S;
   end Emit_Then;

   procedure Emit_Else (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB else", S);
      Decrease_Indent;
      -- end then-loop: clear FLAG_COND and close ]
      Clear_Cell (Cell_FLAG_COND, S);
      if S then
         Move_To (Cell_FLAG_COND, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      Increase_Indent;
      -- else branch while FLAG_ELSE
      if S then
         Move_To (Cell_FLAG_ELSE, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      Success := S;
   end Emit_Else;

   procedure Emit_If_End (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB if end", S);
      Decrease_Indent;
      Clear_Cell (Cell_FLAG_ELSE, S);
      if S then
         Move_To (Cell_FLAG_ELSE, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Clear_Cell (Cell_FLAG_COND, S);
      end if;
      if If_Depth > 0 then
         If_Depth := If_Depth - 1;
      end if;
      Success := S;
   end Emit_If_End;

   procedure Emit_While_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB while cond", S);
      Loop_Counter := Loop_Counter + 1;
      if Loop_Depth < Max_Ctrl_Depth then
         Loop_Depth := Loop_Depth + 1;
         Loop_Stack (Loop_Depth) := Loop_Counter;
      end if;
      Success := True;
   end Emit_While_Start;

   procedure Emit_While_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB while body", S);
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_FLAG_LOOP, S);
      else
         Copy_Cell (Cell_ACC, Cell_FLAG_LOOP, S);
      end if;
      if S then
         Move_To (Cell_FLAG_LOOP, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      Increase_Indent;
      Success := S;
   end Emit_While_Loop_Start;

   procedure Emit_Plain_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB plain loop", S);
      Loop_Counter := Loop_Counter + 1;
      if Loop_Depth < Max_Ctrl_Depth then
         Loop_Depth := Loop_Depth + 1;
         Loop_Stack (Loop_Depth) := Loop_Counter;
      end if;
      Set_Cell_Const (Cell_FLAG_LOOP, 1, S);
      if S then
         Move_To (Cell_FLAG_LOOP, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      Increase_Indent;
      Success := S;
   end Emit_Plain_Loop_Start;

   procedure Emit_Exit_When (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB exit when", S);
      -- if ACC nonzero, clear FLAG_LOOP to exit on next ]
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      if S then
         Copy_Cell (Cell_ACC, Cell_TMP0, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Clear_Cell (Cell_FLAG_LOOP, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP0, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      Success := S;
   end Emit_Exit_When;

   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB for " & Iterator_Name, S);
      For_It_Slot := Alloc_Var_Slot (Iterator_Name, 1);
      For_Hi_Slot := Alloc_Var_Slot (Iterator_Name & "__hi", 1);
      if For_It_Slot = 0 or else For_Hi_Slot = 0 then
         Success := False;
         return;
      end if;
      -- Lo expression will be assigned into iterator via subsequent emits;
      -- DotDot captures hi.
      Loop_Counter := Loop_Counter + 1;
      if Loop_Depth < Max_Ctrl_Depth then
         Loop_Depth := Loop_Depth + 1;
         Loop_Stack (Loop_Depth) := Loop_Counter;
      end if;
      Success := True;
   end Emit_For_Start;

   procedure Emit_DotDot (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB for ..", S);
      -- Pop hi, pop lo: set iterator=lo, hi=hi
      Pop_Value_To (Cell_TMP1, S);  -- this may be mid-expr; lo still pending
      -- Actually AST emits lo then DotDot then hi. So stack has lo, then hi arrives later.
      -- At DotDot, lo is on stack: store to iterator.
      if S then
         Pop_Value_To (Cell_TMP0, S);
      end if;
      if S and then For_It_Slot > 0 then
         Copy_Cell (Cell_TMP0, For_It_Slot, S);
      end if;
      -- Push marker; hi will be stored at Loop_Start
      if S then
         Push_Value_From (Cell_TMP1, S);
      end if;
      Success := S;
   end Emit_DotDot;

   procedure Emit_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB loop start", S);
      -- For-loop: expect hi on stack
      if For_Hi_Slot > 0 and then VSP_Depth > 0 then
         Pop_Value_To (For_Hi_Slot, S);
      else
         S := True;
      end if;
      if For_It_Slot > 0 and then For_Hi_Slot > 0 then
         -- FLAG_LOOP := (it <= hi) approx (hi - it + 1) nonzero
         Copy_Cell (For_Hi_Slot, Cell_FLAG_LOOP, S);
         if S then
            Sub_Cells (For_It_Slot, Cell_FLAG_LOOP, S);
         end if;
         if S then
            Add_Const (Cell_FLAG_LOOP, 1, S);
         end if;
         if S then
            Move_To (Cell_FLAG_LOOP, S);
         end if;
         if S then
            BF_Emit_Raw ("[", S);
         end if;
      elsif Loop_Depth > 0 then
         -- while body already opened FLAG_LOOP, or reopen from ACC
         null;
      end if;
      Increase_Indent;
      Success := S;
   end Emit_Loop_Start;

   procedure Emit_Loop_End (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB loop end", S);
      Decrease_Indent;
      if For_It_Slot > 0 and then For_Hi_Slot > 0 then
         -- it++
         Add_Const (For_It_Slot, 1, S);
         if S then
            Copy_Cell (For_Hi_Slot, Cell_FLAG_LOOP, S);
         end if;
         if S then
            Sub_Cells (For_It_Slot, Cell_FLAG_LOOP, S);
         end if;
         if S then
            Add_Const (Cell_FLAG_LOOP, 1, S);
         end if;
         if S then
            Move_To (Cell_FLAG_LOOP, S);
         end if;
         if S then
            BF_Emit_Raw ("]", S);
         end if;
         For_It_Slot := 0;
         For_Hi_Slot := 0;
      else
         -- while/plain: re-evaluate or close
         Move_To (Cell_FLAG_LOOP, S);
         if S then
            BF_Emit_Raw ("]", S);
         end if;
      end if;
      if Loop_Depth > 0 then
         Loop_Depth := Loop_Depth - 1;
      end if;
      Success := S;
   end Emit_Loop_End;

   procedure Emit_Case_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB case", S);
      if Case_Depth < Max_Ctrl_Depth then
         Case_Depth := Case_Depth + 1;
         Case_Stack (Case_Depth) := 1;
      end if;
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_SCR2, S);  -- case selector
      else
         Copy_Cell (Cell_ACC, Cell_SCR2, S);
      end if;
      -- FLAG_ELSE=1 means "no arm matched yet" (cleared by Emit_When on hit).
      if S then
         Set_Cell_Const (Cell_FLAG_ELSE, 1, S);
      end if;
      Success := S;
   end Emit_Case_Start;

   procedure Emit_Is (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB case is", S);
      Success := True;
   end Emit_Is;

   procedure Emit_When (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB when", S);
      -- Compare ACC (when-value) to SCR2 selector
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_TMP0, S);
      else
         Copy_Cell (Cell_ACC, Cell_TMP0, S);
      end if;
      if S then
         Copy_Cell (Cell_SCR2, Cell_TMP1, S);
      end if;
      if S then
         Sub_Cells (Cell_TMP0, Cell_TMP1, S);
      end if;
      -- TMP1==0 => match; set FLAG_COND
      Clear_Cell (Cell_FLAG_COND, S);
      Set_Cell_Const (Cell_SCR0, 1, S);
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Clear_Cell (Cell_SCR0, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP1, S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Copy_Cell (Cell_SCR0, Cell_FLAG_COND, S);
      end if;
      -- On match, clear FLAG_ELSE so CASE ELSE will not run.
      if S then
         Copy_Cell (Cell_SCR0, Cell_TMP2, S);
      end if;
      if S then
         Move_To (Cell_TMP2, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Clear_Cell (Cell_FLAG_ELSE, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP2, S);
      end if;
      if S then
         Move_To (Cell_TMP2, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Move_To (Cell_FLAG_COND, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      Success := S;
   end Emit_When;

   procedure Emit_Arrow (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB when =>", S);
      Success := True;
   end Emit_Arrow;

   procedure Emit_When_End (Success : out Boolean) is
      S : Boolean;
   begin
      Clear_Cell (Cell_FLAG_COND, S);
      if S then
         Move_To (Cell_FLAG_COND, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      Success := S;
   end Emit_When_End;

   procedure Emit_Case_Else_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB case else", S);
      Increase_Indent;
      Move_To (Cell_FLAG_ELSE, S);
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      Success := S;
   end Emit_Case_Else_Start;

   procedure Emit_Case_Else_End (Success : out Boolean) is
      S : Boolean;
   begin
      Clear_Cell (Cell_FLAG_ELSE, S);
      if S then
         Move_To (Cell_FLAG_ELSE, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      Decrease_Indent;
      Success := S;
   end Emit_Case_Else_End;

   procedure Emit_Case_End (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB case end", S);
      Clear_Cell (Cell_FLAG_ELSE, S);
      if Case_Depth > 0 then
         Case_Depth := Case_Depth - 1;
      end if;
      Success := True;
   end Emit_Case_End;

   -- =========================================================================
   -- PROCEDURES / CALLS
   -- =========================================================================
   procedure Emit_Procedure_Decl_Start (Name : String; Success : out Boolean) is
      S   : Boolean;
      Idx : Natural;
      Gfx_S : Boolean := True;
   begin
      Comment ("ALBB procedure " & Name, S);
      Idx := Find_Proc_Index (Name);
      if Idx = 0 then
         if Proc_Count >= Max_Proc_Entries then
            Ada.Text_IO.Put_Line
              ("ALBB FATAL: Max_Proc_Entries exceeded ("
               & Natural'Image (Max_Proc_Entries) & ").");
            Success := False;
            return;
         end if;
         Proc_Count := Proc_Count + 1;
         Idx := Proc_Count;
         Store_Name (Procs (Idx).Name, Procs (Idx).Len, Name);
      end if;
      Procs (Idx).Body_Off := 0;
      Procs (Idx).Body_Len := 0;
      Procs (Idx).Recording := True;
      Recording_Proc_Idx := Idx;
      Recording_Len := 0;
      -- Dual-emit ON handlers as real FASM procs into the companion gfx buffer.
      if Name = "ALB_ON_TICK"
        or else Name = "ALB_ON_PAINT"
        or else Name = "ALB_ON_EVENT"
      then
         Emit_Native_Brainfuck_Gfx.Begin_On_Handler (Name, Gfx_S);
         if not Gfx_S then
            S := False;
         end if;
      end if;
      Success := S;
   end Emit_Procedure_Decl_Start;

   procedure Emit_Procedure_End (Name : String; Success : out Boolean) is
      S   : Boolean;
      Idx : Natural;
      Gfx_S : Boolean := True;
   begin
      Comment ("ALBB procedure end " & Name, S);
      Idx := Find_Proc_Index (Name);
      if Idx > 0 then
         if Procs (Idx).Recording and then Recording_Len > 0 then
            if Arena_Len + Recording_Len <= Max_Body_Arena then
               Body_Arena
                 (Arena_Len + 1 .. Arena_Len + Recording_Len) :=
                 Recording_Buf (1 .. Recording_Len);
               Procs (Idx).Body_Off := Arena_Len + 1;
               Procs (Idx).Body_Len := Recording_Len;
               Arena_Len := Arena_Len + Recording_Len;
            else
               Ada.Text_IO.Put_Line
                 ("ALBB FATAL: body arena exceeded Max_Body_Arena ("
                  & Natural'Image (Max_Body_Arena) & " bytes).");
               S := False;
            end if;
         end if;
         Procs (Idx).Recording := False;
      end if;
      Recording_Proc_Idx := 0;
      Recording_Len := 0;
      -- Ada-side stack depths track emit-time simulation; they must not
      -- leak from recorded procedure bodies into the next top-level stmt.
      VSP_Depth := 0;
      USP_Depth := 0;
      if Name = "ALB_ON_TICK"
        or else Name = "ALB_ON_PAINT"
        or else Name = "ALB_ON_EVENT"
      then
         Emit_Native_Brainfuck_Gfx.End_On_Handler (Name, Gfx_S);
         if not Gfx_S then
            S := False;
         end if;
      end if;
      Success := S;
   end Emit_Procedure_End;

   procedure Emit_Return_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB return", S);
      -- Leave ACC as return value; stop recording body early via comment
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      Success := S;
   end Emit_Return_Start;

   procedure Emit_Call_Start (Func_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB call " & Func_Name, S);
      Store_Name (Pending_Call_Name, Pending_Call_Len, Func_Name);
      Success := True;
   end Emit_Call_Start;

   procedure Emit_Call_End (Success : out Boolean) is
      S   : Boolean;
      Idx : Natural;
   begin
      if Pending_Call_Len = 0 then
         Success := False;
         return;
      end if;
      Idx := Find_Proc_Index (Pending_Call_Name (1 .. Pending_Call_Len));
      Comment ("ALBB call end inline", S);
      if Idx > 0 and then Procs (Idx).Body_Len > 0
        and then Procs (Idx).Body_Off > 0
      then
         -- Inline expand recorded BF body from shared arena
         Append
           (Body_Arena
              (Procs (Idx).Body_Off ..
               Procs (Idx).Body_Off + Procs (Idx).Body_Len - 1),
            S);
      else
         Host_Nop ("call:" & Pending_Call_Name (1 .. Pending_Call_Len), S);
      end if;
      Pending_Call_Len := 0;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Call_End;

   procedure Emit_Comma (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Comma;

   procedure Emit_Statement_End (Success : out Boolean) is
      S : Boolean;
   begin
      -- If pending assign name, store ACC into that slot
      if Pending_Assign_Len > 0 then
         declare
            Slot : Natural :=
              Find_Var_Slot (Pending_Assign_Name (1 .. Pending_Assign_Len));
         begin
            if Slot = 0 then
               Slot := Alloc_Var_Slot
                 (Pending_Assign_Name (1 .. Pending_Assign_Len), 1);
            end if;
            if Slot = 0 then
               Success := False;
               return;
            end if;
            if VSP_Depth > 0 then
               Pop_Value_To (Cell_ACC, S);
            else
               S := True;
            end if;
            if S then
               Copy_Cell (Cell_ACC, Slot, S);
            end if;
            Pending_Assign_Len := 0;
            Success := S;
            return;
         end;
      end if;
      -- Drain one stack value if present (statement result discarded)
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      Success := S;
   end Emit_Statement_End;

   procedure Emit_Assign_Prefix (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB assign prefix", S);
      -- LHS name should already be in Pending_Assign from Variable_Ref
      Success := True;
   end Emit_Assign_Prefix;

   procedure Emit_Print_Start (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
      pragma Unreferenced (Tag);
   begin
      Comment ("ALBB print start", S);
      Success := True;
   end Emit_Print_Start;

   procedure Emit_Print_End (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB print end", S);
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      case Tag is
         when others =>
            -- If ACC looks like a string pool pointer (>= String_Pool_Base),
            -- print bytes until NUL; else print decimal number.
            if S then
               Copy_Cell (Cell_ACC, Cell_SCR0, S);
            end if;
            -- Always decimal-print ACC for numeric; also try string walk:
            if S then
               Print_Number_ACC (S);
            end if;
            -- newline
            if S then
               Set_Cell_Const (Cell_TMP0, 10, S);
            end if;
            if S then
               Print_Byte_At (Cell_TMP0, S);
            end if;
      end case;
      Success := S;
   end Emit_Print_End;

   procedure Emit_Assert_Call (Pred, Arg : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB assert " & Pred & " " & Arg, S);
      Success := S;
   end Emit_Assert_Call;

   procedure Emit_Retract_Call (Pred, Arg : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB retract " & Pred & " " & Arg, S);
      Success := S;
   end Emit_Retract_Call;

   procedure Emit_OS_Load
     (File_Path : String; Target_Buffer : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("OS_Load " & File_Path & " -> " & Target_Buffer, S);
      Success := S;
   end Emit_OS_Load;

   procedure Emit_OS_Flush
     (Source_Buffer : String; File_Path : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("OS_Flush " & Source_Buffer & " -> " & File_Path, S);
      Success := S;
   end Emit_OS_Flush;

   procedure Emit_Prolog_Fact_Registration
     (Pred : String; Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("Prolog_Fact " & Pred & " " & Arg, S);
      Success := S;
   end Emit_Prolog_Fact_Registration;

   procedure Emit_Prolog_Query_Call
     (Pred : String; Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("Prolog_Query " & Pred & " " & Arg, S);
      Clear_Cell (Cell_ACC, S);
      Success := S;
   end Emit_Prolog_Query_Call;

   procedure Emit_FindAll_Call
     (Pred : String; Out_Array : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("FindAll " & Pred & " " & Out_Array, S);
      Success := S;
   end Emit_FindAll_Call;

   procedure Emit_Update_Call
     (Pred, Old_Arg, New_Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("Update " & Pred & " " & Old_Arg & " " & New_Arg, S);
      Success := S;
   end Emit_Update_Call;

   procedure Emit_Foreach_Start
     (Iterator_Name : String; Array_Name : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Comment ("ALBB foreach " & Iterator_Name & " in " & Array_Name, S);
      Emit_For_Start (Iterator_Name, S);
      Success := S;
   end Emit_Foreach_Start;

   -- =========================================================================
   -- TRY / CATCH / THROW  (FLAG_ERR)
   -- =========================================================================
   procedure Emit_Try_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB try", S);
      Try_Counter := Try_Counter + 1;
      if Try_Depth < Max_Ctrl_Depth then
         Try_Depth := Try_Depth + 1;
         Try_Stack (Try_Depth) := Try_Counter;
      end if;
      Clear_Cell (Cell_FLAG_ERR, S);
      Success := S;
   end Emit_Try_Start;

   procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      Comment ("ALBB catch " & Err_Var, S);
      Slot := Alloc_Var_Slot (Err_Var, 1);
      if Slot = 0 then
         Success := False;
         return;
      end if;
      -- Catch body runs while FLAG_ERR nonzero
      Copy_Cell (Cell_FLAG_ERR, Slot, S);
      if S then
         Move_To (Cell_FLAG_ERR, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      Success := S;
   end Emit_Catch_Start;

   procedure Emit_Try_End (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB try end", S);
      Clear_Cell (Cell_FLAG_ERR, S);
      if S then
         Move_To (Cell_FLAG_ERR, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if Try_Depth > 0 then
         Try_Depth := Try_Depth - 1;
      end if;
      Success := S;
   end Emit_Try_End;

   procedure Emit_Throw_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB throw", S);
      Success := True;
   end Emit_Throw_Start;

   procedure Emit_Throw_End (Success : out Boolean) is
      S : Boolean;
   begin
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      if S then
         Copy_Cell (Cell_ACC, Cell_FLAG_ERR, S);
      end if;
      -- Ensure FLAG_ERR is nonzero after throw (ACC may have been 0)
      if S then
         Copy_Cell (Cell_FLAG_ERR, Cell_TMP0, S);
      end if;
      if S then
         Set_Cell_Const (Cell_TMP1, 1, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Clear_Cell (Cell_TMP1, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP0, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      -- if TMP1 still 1, ACC/err was zero → force FLAG_ERR := 1
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Set_Cell_Const (Cell_FLAG_ERR, 1, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP1, S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      Success := S;
   end Emit_Throw_End;

   procedure Emit_Global_Var_Decl
     (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   is
      Saved : Buffer_Target := Current_Buffer;
      S     : Boolean;
   begin
      Current_Buffer := Buffer_Global;
      Emit_Var_Decl (Name, Tag, S);
      Current_Buffer := Saved;
      Success := S;
   end Emit_Global_Var_Decl;

   procedure Emit_Slide_Vault_Left
     (Vault_Name : String; Shift_Amount : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("SlideLeft " & Vault_Name & " " & Shift_Amount, S);
      Success := S;
   end Emit_Slide_Vault_Left;

   procedure Emit_Slide_Vault_Right
     (Vault_Name : String; Shift_Amount : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("SlideRight " & Vault_Name & " " & Shift_Amount, S);
      Success := S;
   end Emit_Slide_Vault_Right;

   procedure Emit_String_Concat
     (Dest, Src, Max_Len : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("StringConcat " & Dest & " " & Src & " " & Max_Len, S);
      Success := S;
   end Emit_String_Concat;

   procedure Emit_String_Copy
     (Dest, Src, Max_Len : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Host_Nop ("StringCopy " & Dest & " " & Src & " " & Max_Len, S);
      Success := S;
   end Emit_String_Copy;

   procedure Emit_String_Length (Src : String; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      Comment ("ALBB strlen " & Src, S);
      Slot := Find_Var_Slot (Src);
      if Slot = 0 then
         Clear_Cell (Cell_ACC, S);
      else
         -- Count nonzero consecutive cells from Slot (max 64)
         Clear_Cell (Cell_ACC, S);
         for I in 0 .. 63 loop
            Copy_Cell (Slot + I, Cell_TMP0, S);
            exit when not S;
            Move_To (Cell_TMP0, S);
            exit when not S;
            BF_Emit_Raw ("[", S);
            exit when not S;
            Add_Const (Cell_ACC, 1, S);
            exit when not S;
            Clear_Cell (Cell_TMP0, S);
            exit when not S;
            Move_To (Cell_TMP0, S);
            exit when not S;
            BF_Emit_Raw ("]", S);
            exit when not S;
            -- stop if was zero: check by seeing if we incremented — skip complex
         end loop;
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_String_Length;

   procedure Emit_Square_Root (Value : String; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      Comment ("ALBB sqrt " & Value, S);
      Slot := Find_Var_Slot (Value);
      if Slot > 0 then
         Copy_Cell (Slot, Cell_ACC, S);
      else
         S := True;
      end if;
      -- Integer sqrt via incremental odd-subtract (digit-by-digit style)
      if S then
         Copy_Cell (Cell_ACC, Cell_SCR0, S);
      end if;
      if S then
         Clear_Cell (Cell_ACC, S);
      end if;
      if S then
         Set_Cell_Const (Cell_SCR1, 1, S);
      end if;
      if S then
         Move_To (Cell_SCR0, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Sub_Cells (Cell_SCR1, Cell_SCR0, S);
      end if;
      if S then
         Add_Const (Cell_SCR1, 2, S);
      end if;
      if S then
         Add_Const (Cell_ACC, 1, S);
      end if;
      if S then
         Move_To (Cell_SCR0, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Square_Root;

   procedure Emit_Sine (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Host_Nop ("Sine " & Value, S);
      Clear_Cell (Cell_ACC, S);
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Sine;

   procedure Emit_Cosine (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Host_Nop ("Cosine " & Value, S);
      Set_Cell_Const (Cell_ACC, 1, S);
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Cosine;

   procedure Emit_Absolute (Value : String; Success : out Boolean) is
      S    : Boolean;
      Slot : Natural;
   begin
      Slot := Find_Var_Slot (Value);
      if Slot > 0 then
         Copy_Cell (Slot, Cell_ACC, S);
      else
         S := True;
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Absolute;

   procedure Emit_Key_State (Key_Code : String; Success : out Boolean) is
      S : Boolean;
      Slot : Natural;
   begin
      Comment ("# KEY_STATE", S);
      Slot := Find_Var_Slot (Key_Code);
      if Slot > 0 then
         Copy_Cell (Slot, Cell_GFX_KEY, S);
      else
         S := True;
      end if;
      if S then
         Set_Cell_Const (Cell_GFX_CMD, 3, S);
      end if;
      Emit_Native_Brainfuck_Gfx.Emit_Key_State_Fasm (S);
      Clear_Cell (Cell_ACC, S);
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Key_State;

   procedure Emit_Mouse_Position (X_Var, Y_Var : String; Success : out Boolean) is
      S : Boolean;
      SX, SY : Natural;
   begin
      Comment ("# MOUSE_POS", S);
      Emit_Native_Brainfuck_Gfx.Emit_Mouse_Position_Fasm (S);
      SX := Find_Var_Slot (X_Var);
      SY := Find_Var_Slot (Y_Var);
      if SX > 0 then
         Copy_Cell (Cell_GFX_MOUSE_X, SX, S);
      end if;
      if SY > 0 then
         Copy_Cell (Cell_GFX_MOUSE_Y, SY, S);
      end if;
      Success := S;
   end Emit_Mouse_Position;

   procedure Emit_Mouse_Click (Button : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("# MOUSE_CLICK", S);
      Emit_Native_Brainfuck_Gfx.Emit_Mouse_Click_Fasm (S);
      Clear_Cell (Cell_ACC, S);
      if S then
         Copy_Cell (Cell_GFX_MOUSE_BTN, Cell_ACC, S);
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Mouse_Click;

   procedure Emit_Put_Pixel (X, Y, Color : String; Success : out Boolean) is
      S : Boolean;
      SX, SY, SC : Natural;
   begin
      Comment ("# PUT_PIXEL", S);
      SX := Find_Var_Slot (X);
      SY := Find_Var_Slot (Y);
      SC := Find_Var_Slot (Color);
      if SX > 0 then
         Copy_Cell (SX, Cell_GFX_X, S);
      else
         S := True;
      end if;
      if S and then SY > 0 then
         Copy_Cell (SY, Cell_GFX_Y, S);
      end if;
      if S and then SC > 0 then
         Copy_Cell (SC, Cell_GFX_COLOR, S);
      end if;
      if S then
         Set_Cell_Const (Cell_GFX_CMD, 1, S);
      end if;
      Emit_Native_Brainfuck_Gfx.Emit_Put_Pixel_Fasm (S);
      Success := S;
   end Emit_Put_Pixel;

   procedure Emit_Play_Sound (Vault_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("# PLAY_SOUND", S);
      Set_Cell_Const (Cell_GFX_CMD, 5, S);
      Emit_Native_Brainfuck_Gfx.Emit_Play_Sound_Fasm (S);
      Success := S;
   end Emit_Play_Sound;

   procedure Emit_Print_Function_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB print function runtime", S);
      Emit_Native_Brainfuck_Gfx.Emit_Print_Function_Start (S);
      Success := S;
   end Emit_Print_Function_Start;

   procedure Emit_Window_Creation
     (Title : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Comment ("# WINDOW", S);
      Clear_Cell (Cell_GFX_CMD, S);
      if S then Clear_Cell (Cell_GFX_X, S); end if;
      if S then Clear_Cell (Cell_GFX_Y, S); end if;
      if S then Clear_Cell (Cell_GFX_COLOR, S); end if;
      Emit_Native_Brainfuck_Gfx.Emit_Window_Creation (Title, S);
      Success := S;
   end Emit_Window_Creation;

   procedure Emit_Set_Fullscreen (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("# SET_FULLSCREEN", S);
      Emit_Native_Brainfuck_Gfx.Emit_Set_Fullscreen (S);
      Success := S;
   end Emit_Set_Fullscreen;

   procedure Emit_Set_Resizable (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("# SET_RESIZABLE", S);
      Emit_Native_Brainfuck_Gfx.Emit_Set_Resizable (S);
      Success := S;
   end Emit_Set_Resizable;

   procedure Emit_Set_Stretchy (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("# SET_STRETCHY", S);
      Emit_Native_Brainfuck_Gfx.Emit_Set_Stretchy (S);
      Success := S;
   end Emit_Set_Stretchy;

   procedure Emit_Message_Loop (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("# MESSAGE_LOOP", S);
      Emit_Native_Brainfuck_Gfx.Emit_Message_Loop (S);
      Success := S;
   end Emit_Message_Loop;

   procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("# COLOR_BGR", S);
      Emit_Native_Brainfuck_Gfx.Emit_Win32_Color_BGR (Color_Hex, S);
      Success := S;
   end Emit_Win32_Color_BGR;

   procedure Emit_FITS_Runtime (Success : out Boolean) is
      S : Boolean;
   begin
      Host_Nop ("FITS_Runtime", S);
      Success := S;
   end Emit_FITS_Runtime;

   procedure Emit_INI_Runtime (Success : out Boolean) is
      Saved : Buffer_Target := Current_Buffer;
      S     : Boolean;
   begin
      Current_Buffer := Buffer_Global;
      Comment ("ALBB INI runtime scratch (unsupported host)", S);
      Clear_Cell (Cell_Zero, S);
      Current_Buffer := Saved;
      Success := S;
   end Emit_INI_Runtime;

   procedure Emit_Input_Prompt_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB input prompt", S);
      Success := True;
   end Emit_Input_Prompt_Start;

   procedure Emit_Input_Prompt_End (Success : out Boolean) is
      S : Boolean;
   begin
      -- Print ACC/string then await is separate
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      if S then
         Print_Number_ACC (S);
      end if;
      Success := S;
   end Emit_Input_Prompt_End;

   procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
      pragma Unreferenced (Tag);
   begin
      Comment ("ALBB input read", S);
      Success := True;
   end Emit_Input_Read_Start;

   procedure Emit_Input_Read_End (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
      pragma Unreferenced (Tag);
   begin
      Read_Byte_To (Cell_ACC, S);
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Input_Read_End;

   procedure Emit_Readline_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB readline", S);
      Success := True;
   end Emit_Readline_Start;

   procedure Emit_Readline_End (Success : out Boolean) is
      S     : Boolean;
      Start : Natural;
   begin
      if Next_String_Cell + 32 >= Hist_Base then
         Success := False;
         return;
      end if;
      Start := Next_String_Cell;
      -- Read up to 32 bytes or until newline (simplified: one byte loop count)
      for I in 1 .. 32 loop
         Read_Byte_To (Next_String_Cell, S);
         exit when not S;
         Next_String_Cell := Next_String_Cell + 1;
      end loop;
      if S then
         Clear_Cell (Next_String_Cell, S);
         Next_String_Cell := Next_String_Cell + 1;
      end if;
      if S then
         Set_Cell_Const (Cell_ACC, Start, S);
      end if;
      if S then
         Push_Value_From (Cell_ACC, S);
      end if;
      Success := S;
   end Emit_Readline_End;

   procedure Emit_Require_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB require", S);
      Success := True;
   end Emit_Require_Start;

   procedure Emit_Ensure_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB ensure", S);
      Success := True;
   end Emit_Ensure_Start;

   procedure Emit_Contract_End (Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB contract end " & Name, S);
      -- If ACC is zero, set FLAG_ERR
      if VSP_Depth > 0 then
         Pop_Value_To (Cell_ACC, S);
      else
         S := True;
      end if;
      if S then
         Copy_Cell (Cell_ACC, Cell_TMP0, S);
      end if;
      if S then
         Set_Cell_Const (Cell_TMP1, 1, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Clear_Cell (Cell_TMP1, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP0, S);
      end if;
      if S then
         Move_To (Cell_TMP0, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("[", S);
      end if;
      if S then
         Set_Cell_Const (Cell_FLAG_ERR, 1, S);
      end if;
      if S then
         Clear_Cell (Cell_TMP1, S);
      end if;
      if S then
         Move_To (Cell_TMP1, S);
      end if;
      if S then
         BF_Emit_Raw ("]", S);
      end if;
      Success := S;
   end Emit_Contract_End;

   procedure Emit_Runtime_Assert_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Comment ("ALBB runtime assert", S);
      Success := True;
   end Emit_Runtime_Assert_Start;

   procedure Emit_Runtime_Assert_End (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Contract_End ("assert", S);
      Success := S;
   end Emit_Runtime_Assert_End;

end Emit_Native_Brainfuck;
