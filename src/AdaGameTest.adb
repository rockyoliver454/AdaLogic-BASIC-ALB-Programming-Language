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

with ALBA_API; use ALBA_API;

procedure AdaGameTest is
   Graphics_OK : Boolean := False;
   ALBA_User_Error : exception;
   ALBA_Last_Error : ALB_Text := ALB_STR("");
   Screen_W : S32 := 0;
   Screen_H : S32 := 0;
   Cell_Size : S32 := 0;
   Grid_Cols : S32 := 0;
   Grid_Rows : S32 := 0;
   Player_X : S32 := 0;
   Player_Y : S32 := 0;
   Player_W : S32 := 0;
   Player_H : S32 := 0;
   Enemy_X : S32 := 0;
   Enemy_Y : S32 := 0;
   Enemy_W : S32 := 0;
   Enemy_H : S32 := 0;
   Enemy_Target_X : S32 := 0;
   Enemy_Target_Y : S32 := 0;
   Move_Speed : S32 := 0;
   Enemy_Step : S32 := 0;
   Frame_Counter : U32 := 0;
   Bit_Pulse : S32 := 0;
   Path_Signature : U32 := 0;
   Collided : Boolean := False;
   Wall_X : S32 := 0;
   Wall_W : S32 := 0;
   Wall_Top_H : S32 := 0;
   Wall_Bot_Y : S32 := 0;
   Wall_Bot_H : S32 := 0;
   Barrier_X : S32 := 0;
   Barrier_Y : S32 := 0;
   Barrier_W : S32 := 0;
   Barrier_H : S32 := 0;
   Next_Player_X : S32 := 0;
   Next_Player_Y : S32 := 0;
   Player_Blocked : Boolean := False;
   ALBA_Save_Max : constant Natural := 16;
   ALBA_Save_Top : Natural := 0;
   procedure ALBA_Save_State is
   begin
      if ALBA_Save_Top < ALBA_Save_Max then
         ALBA_Save_Top := ALBA_Save_Top + 1;
      end if;
   end ALBA_Save_State;

   procedure ALBA_Load_State is
   begin
      if ALBA_Save_Top > 0 then
         ALBA_Save_Top := ALBA_Save_Top - 1;
      end if;
   end ALBA_Load_State;

   function ALBA_Deref_Address (Address : Positive) return U64 is
   begin
      return ALB_DEREF(Address);
   end ALBA_Deref_Address;

   function ALBA_Peek_Address (Address : Positive) return U64 is
   begin
      return ALB_PEEK(Address);
   end ALBA_Peek_Address;

   procedure ALBA_Poke_Address (Address : Positive; Raw_Value : U64) is
   begin
      if Address < 8 and then (Address + 7) >= 4 then
         ALB_POKE(Address, Raw_Value);
         Screen_W := S32(ALB_LOAD_I32(Positive(4)));
         return;
      end if;
      if Address < 12 and then (Address + 7) >= 8 then
         ALB_POKE(Address, Raw_Value);
         Screen_H := S32(ALB_LOAD_I32(Positive(8)));
         return;
      end if;
      if Address < 16 and then (Address + 7) >= 12 then
         ALB_POKE(Address, Raw_Value);
         Cell_Size := S32(ALB_LOAD_I32(Positive(12)));
         return;
      end if;
      if Address < 20 and then (Address + 7) >= 16 then
         ALB_POKE(Address, Raw_Value);
         Grid_Cols := S32(ALB_LOAD_I32(Positive(16)));
         return;
      end if;
      if Address < 24 and then (Address + 7) >= 20 then
         ALB_POKE(Address, Raw_Value);
         Grid_Rows := S32(ALB_LOAD_I32(Positive(20)));
         return;
      end if;
      if Address < 28 and then (Address + 7) >= 24 then
         ALB_POKE(Address, Raw_Value);
         Player_X := S32(ALB_LOAD_I32(Positive(24)));
         return;
      end if;
      if Address < 32 and then (Address + 7) >= 28 then
         ALB_POKE(Address, Raw_Value);
         Player_Y := S32(ALB_LOAD_I32(Positive(28)));
         return;
      end if;
      if Address < 36 and then (Address + 7) >= 32 then
         ALB_POKE(Address, Raw_Value);
         Player_W := S32(ALB_LOAD_I32(Positive(32)));
         return;
      end if;
      if Address < 40 and then (Address + 7) >= 36 then
         ALB_POKE(Address, Raw_Value);
         Player_H := S32(ALB_LOAD_I32(Positive(36)));
         return;
      end if;
      if Address < 44 and then (Address + 7) >= 40 then
         ALB_POKE(Address, Raw_Value);
         Enemy_X := S32(ALB_LOAD_I32(Positive(40)));
         return;
      end if;
      if Address < 48 and then (Address + 7) >= 44 then
         ALB_POKE(Address, Raw_Value);
         Enemy_Y := S32(ALB_LOAD_I32(Positive(44)));
         return;
      end if;
      if Address < 52 and then (Address + 7) >= 48 then
         ALB_POKE(Address, Raw_Value);
         Enemy_W := S32(ALB_LOAD_I32(Positive(48)));
         return;
      end if;
      if Address < 56 and then (Address + 7) >= 52 then
         ALB_POKE(Address, Raw_Value);
         Enemy_H := S32(ALB_LOAD_I32(Positive(52)));
         return;
      end if;
      if Address < 60 and then (Address + 7) >= 56 then
         ALB_POKE(Address, Raw_Value);
         Enemy_Target_X := S32(ALB_LOAD_I32(Positive(56)));
         return;
      end if;
      if Address < 64 and then (Address + 7) >= 60 then
         ALB_POKE(Address, Raw_Value);
         Enemy_Target_Y := S32(ALB_LOAD_I32(Positive(60)));
         return;
      end if;
      if Address < 68 and then (Address + 7) >= 64 then
         ALB_POKE(Address, Raw_Value);
         Move_Speed := S32(ALB_LOAD_I32(Positive(64)));
         return;
      end if;
      if Address < 72 and then (Address + 7) >= 68 then
         ALB_POKE(Address, Raw_Value);
         Enemy_Step := S32(ALB_LOAD_I32(Positive(68)));
         return;
      end if;
      if Address < 76 and then (Address + 7) >= 72 then
         ALB_POKE(Address, Raw_Value);
         Frame_Counter := U32(ALB_LOAD_U32(Positive(72)));
         return;
      end if;
      if Address < 80 and then (Address + 7) >= 76 then
         ALB_POKE(Address, Raw_Value);
         Bit_Pulse := S32(ALB_LOAD_I32(Positive(76)));
         return;
      end if;
      if Address < 84 and then (Address + 7) >= 80 then
         ALB_POKE(Address, Raw_Value);
         Path_Signature := U32(ALB_LOAD_U32(Positive(80)));
         return;
      end if;
      if Address < 85 and then (Address + 7) >= 84 then
         ALB_POKE(Address, Raw_Value);
         Collided := ALB_LOAD_BOOL(Positive(84));
         return;
      end if;
      if Address < 92 and then (Address + 7) >= 88 then
         ALB_POKE(Address, Raw_Value);
         Wall_X := S32(ALB_LOAD_I32(Positive(88)));
         return;
      end if;
      if Address < 96 and then (Address + 7) >= 92 then
         ALB_POKE(Address, Raw_Value);
         Wall_W := S32(ALB_LOAD_I32(Positive(92)));
         return;
      end if;
      if Address < 100 and then (Address + 7) >= 96 then
         ALB_POKE(Address, Raw_Value);
         Wall_Top_H := S32(ALB_LOAD_I32(Positive(96)));
         return;
      end if;
      if Address < 104 and then (Address + 7) >= 100 then
         ALB_POKE(Address, Raw_Value);
         Wall_Bot_Y := S32(ALB_LOAD_I32(Positive(100)));
         return;
      end if;
      if Address < 108 and then (Address + 7) >= 104 then
         ALB_POKE(Address, Raw_Value);
         Wall_Bot_H := S32(ALB_LOAD_I32(Positive(104)));
         return;
      end if;
      if Address < 112 and then (Address + 7) >= 108 then
         ALB_POKE(Address, Raw_Value);
         Barrier_X := S32(ALB_LOAD_I32(Positive(108)));
         return;
      end if;
      if Address < 116 and then (Address + 7) >= 112 then
         ALB_POKE(Address, Raw_Value);
         Barrier_Y := S32(ALB_LOAD_I32(Positive(112)));
         return;
      end if;
      if Address < 120 and then (Address + 7) >= 116 then
         ALB_POKE(Address, Raw_Value);
         Barrier_W := S32(ALB_LOAD_I32(Positive(116)));
         return;
      end if;
      if Address < 124 and then (Address + 7) >= 120 then
         ALB_POKE(Address, Raw_Value);
         Barrier_H := S32(ALB_LOAD_I32(Positive(120)));
         return;
      end if;
      if Address < 128 and then (Address + 7) >= 124 then
         ALB_POKE(Address, Raw_Value);
         Next_Player_X := S32(ALB_LOAD_I32(Positive(124)));
         return;
      end if;
      if Address < 132 and then (Address + 7) >= 128 then
         ALB_POKE(Address, Raw_Value);
         Next_Player_Y := S32(ALB_LOAD_I32(Positive(128)));
         return;
      end if;
      if Address < 133 and then (Address + 7) >= 132 then
         ALB_POKE(Address, Raw_Value);
         Player_Blocked := ALB_LOAD_BOOL(Positive(132));
         return;
      end if;
      ALB_POKE(Address, Raw_Value);
   end ALBA_Poke_Address;

   procedure ALB_On_Tick is
   begin
      Frame_Counter := (Frame_Counter + 1);
      ALB_STORE_U32(Positive(72), ALB_U32(Frame_Counter));
      Screen_W := S32(S32(S32(ALBA_Graphics.Virtual_Width)));
      ALB_STORE_I32(Positive(4), ALB_I32(Screen_W));
      Screen_H := S32(S32(S32(ALBA_Graphics.Virtual_Height)));
      ALB_STORE_I32(Positive(8), ALB_I32(Screen_H));
      Grid_Cols := (Screen_W / Cell_Size);
      ALB_STORE_I32(Positive(16), ALB_I32(Grid_Cols));
      Grid_Rows := (Screen_H / Cell_Size);
      ALB_STORE_I32(Positive(20), ALB_I32(Grid_Rows));
      if 
   (Grid_Cols < 8) then
         Grid_Cols := 8;
         ALB_STORE_I32(Positive(16), ALB_I32(Grid_Cols));
      end if;
      if 
   (Grid_Rows < 8) then
         Grid_Rows := 8;
         ALB_STORE_I32(Positive(20), ALB_I32(Grid_Rows));
      end if;
      Wall_X := ((Screen_W / 2) - (Cell_Size / 2));
      ALB_STORE_I32(Positive(88), ALB_I32(Wall_X));
      Wall_W := Cell_Size;
      ALB_STORE_I32(Positive(92), ALB_I32(Wall_W));
      Wall_Top_H := ((Screen_H / 2) - (Cell_Size * 2));
      ALB_STORE_I32(Positive(96), ALB_I32(Wall_Top_H));
      if 
   (Wall_Top_H < Cell_Size) then
         Wall_Top_H := Cell_Size;
         ALB_STORE_I32(Positive(96), ALB_I32(Wall_Top_H));
      end if;
      Wall_Bot_Y := ((Screen_H / 2) + Cell_Size);
      ALB_STORE_I32(Positive(100), ALB_I32(Wall_Bot_Y));
      if 
   (Wall_Bot_Y < (Wall_Top_H + (Cell_Size * 2))) then
         Wall_Bot_Y := (Wall_Top_H + (Cell_Size * 2));
         ALB_STORE_I32(Positive(100), ALB_I32(Wall_Bot_Y));
      end if;
      Wall_Bot_H := (Screen_H - Wall_Bot_Y);
      ALB_STORE_I32(Positive(104), ALB_I32(Wall_Bot_H));
      if 
   (Wall_Bot_H < Cell_Size) then
         Wall_Bot_H := Cell_Size;
         ALB_STORE_I32(Positive(104), ALB_I32(Wall_Bot_H));
      end if;
      Barrier_X := (Cell_Size * 2);
      ALB_STORE_I32(Positive(108), ALB_I32(Barrier_X));
      Barrier_Y := (Screen_H - (Cell_Size * 4));
      ALB_STORE_I32(Positive(112), ALB_I32(Barrier_Y));
      if 
   (Barrier_Y < (Cell_Size * 2)) then
         Barrier_Y := (Cell_Size * 2);
         ALB_STORE_I32(Positive(112), ALB_I32(Barrier_Y));
      end if;
      Barrier_W := (Cell_Size * 4);
      ALB_STORE_I32(Positive(116), ALB_I32(Barrier_W));
      Barrier_H := Cell_Size;
      ALB_STORE_I32(Positive(120), ALB_I32(Barrier_H));
      Next_Player_X := Player_X;
      ALB_STORE_I32(Positive(124), ALB_I32(Next_Player_X));
      Next_Player_Y := Player_Y;
      ALB_STORE_I32(Positive(128), ALB_I32(Next_Player_Y));
      if 
   ((if ALBA_Graphics.Key_Down(Integer(4)) then 1 else 0) > 0) then
         Next_Player_X := (Next_Player_X - Move_Speed);
         ALB_STORE_I32(Positive(124), ALB_I32(Next_Player_X));
      end if;
      if 
   ((if ALBA_Graphics.Key_Down(Integer(7)) then 1 else 0) > 0) then
         Next_Player_X := (Next_Player_X + Move_Speed);
         ALB_STORE_I32(Positive(124), ALB_I32(Next_Player_X));
      end if;
      if 
   ((if ALBA_Graphics.Key_Down(Integer(26)) then 1 else 0) > 0) then
         Next_Player_Y := (Next_Player_Y - Move_Speed);
         ALB_STORE_I32(Positive(128), ALB_I32(Next_Player_Y));
      end if;
      if 
   ((if ALBA_Graphics.Key_Down(Integer(22)) then 1 else 0) > 0) then
         Next_Player_Y := (Next_Player_Y + Move_Speed);
         ALB_STORE_I32(Positive(128), ALB_I32(Next_Player_Y));
      end if;
      if 
   (Next_Player_X < 0) then
         Next_Player_X := 0;
         ALB_STORE_I32(Positive(124), ALB_I32(Next_Player_X));
      end if;
      if 
   (Next_Player_Y < 0) then
         Next_Player_Y := 0;
         ALB_STORE_I32(Positive(128), ALB_I32(Next_Player_Y));
      end if;
      if 
   (Next_Player_X > (Screen_W - Player_W)) then
         Next_Player_X := (Screen_W - Player_W);
         ALB_STORE_I32(Positive(124), ALB_I32(Next_Player_X));
      end if;
      if 
   (Next_Player_Y > (Screen_H - Player_H)) then
         Next_Player_Y := (Screen_H - Player_H);
         ALB_STORE_I32(Positive(128), ALB_I32(Next_Player_Y));
      end if;
      Player_Blocked := False;
      ALB_STORE_BOOL(Positive(132), Player_Blocked);
      if 
   (ALB_COLLIDE_RECT(Next_Player_X, Player_Y, Player_W, Player_H, Wall_X, 0, Wall_W, Wall_Top_H) = True) then
         Player_Blocked := True;
         ALB_STORE_BOOL(Positive(132), Player_Blocked);
      end if;
      if 
   (ALB_COLLIDE_RECT(Next_Player_X, Player_Y, Player_W, Player_H, Wall_X, Wall_Bot_Y, Wall_W, Wall_Bot_H) = True) then
         Player_Blocked := True;
         ALB_STORE_BOOL(Positive(132), Player_Blocked);
      end if;
      if 
   (ALB_COLLIDE_RECT(Next_Player_X, Player_Y, Player_W, Player_H, Barrier_X, Barrier_Y, Barrier_W, Barrier_H) = True) then
         Player_Blocked := True;
         ALB_STORE_BOOL(Positive(132), Player_Blocked);
      end if;
      if 
   (Player_Blocked = False) then
         Player_X := Next_Player_X;
         ALB_STORE_I32(Positive(24), ALB_I32(Player_X));
      end if;
      Player_Blocked := False;
      ALB_STORE_BOOL(Positive(132), Player_Blocked);
      if 
   (ALB_COLLIDE_RECT(Player_X, Next_Player_Y, Player_W, Player_H, Wall_X, 0, Wall_W, Wall_Top_H) = True) then
         Player_Blocked := True;
         ALB_STORE_BOOL(Positive(132), Player_Blocked);
      end if;
      if 
   (ALB_COLLIDE_RECT(Player_X, Next_Player_Y, Player_W, Player_H, Wall_X, Wall_Bot_Y, Wall_W, Wall_Bot_H) = True) then
         Player_Blocked := True;
         ALB_STORE_BOOL(Positive(132), Player_Blocked);
      end if;
      if 
   (ALB_COLLIDE_RECT(Player_X, Next_Player_Y, Player_W, Player_H, Barrier_X, Barrier_Y, Barrier_W, Barrier_H) = True) then
         Player_Blocked := True;
         ALB_STORE_BOOL(Positive(132), Player_Blocked);
      end if;
      if 
   (Player_Blocked = False) then
         Player_Y := Next_Player_Y;
         ALB_STORE_I32(Positive(28), ALB_I32(Player_Y));
      end if;
      Bit_Pulse := S32(S32 (4 + Integer ((U32 (Frame_Counter) xor U32 (16#0000_001F#)) and U32 (16#0000_000F#)))
);
      ALB_STORE_I32(Positive(76), ALB_I32(Bit_Pulse));
      declare
         procedure ALBA_Unsafe_Block_670 is
            pragma SPARK_Mode (Off);
         begin
            declare
   Max_Cols  : constant Integer := 128;
   Max_Rows  : constant Integer := 128;
   Max_Cells : constant Integer := Max_Cols * Max_Rows;

   subtype Col_Index is Integer range 0 .. Max_Cols - 1;
   subtype Row_Index is Integer range 0 .. Max_Rows - 1;

   type Bool_Grid is array (Col_Index, Row_Index) of Boolean;
   type Int_Grid  is array (Col_Index, Row_Index) of Integer;
   type Queue_Array is array (Integer range 0 .. Max_Cells - 1) of Integer;

   Blocked : Bool_Grid := (others => (others => False));
   Visited : Bool_Grid := (others => (others => False));
   Prev_X  : Int_Grid := (others => (others => -1));
   Prev_Y  : Int_Grid := (others => (others => -1));
   Queue_X : Queue_Array := (others => 0);
   Queue_Y : Queue_Array := (others => 0);

   Head : Integer := 0;
   Tail : Integer := 0;

   Cell_Step : Integer := Integer (Cell_Size);
   Cols      : Integer := Integer (Grid_Cols);
   Rows      : Integer := Integer (Grid_Rows);

   Start_X : Integer := 0;
   Start_Y : Integer := 0;
   Goal_X  : Integer := 0;
   Goal_Y  : Integer := 0;

   Cur_X : Integer := 0;
   Cur_Y : Integer := 0;
   Step_X : Integer := 0;
   Step_Y : Integer := 0;
   Found  : Boolean := False;

   Packed_State : U32 := U32 (Frame_Counter);
   Shifted_A    : U32 := 0;
   Shifted_B    : U32 := 0;
   Wall_Col           : Integer := 0;
   Gap_Row            : Integer := 0;
   Barrier_Row        : Integer := 0;
   Barrier_Col_Start  : Integer := 0;
   Barrier_Col_End    : Integer := 0;

   procedure Push
     (X  : Integer;
      Y  : Integer;
      PX : Integer;
      PY : Integer) is
   begin
      if X < 0 or else X >= Cols or else Y < 0 or else Y >= Rows then
         return;
      end if;

      if Blocked (X, Y) or else Visited (X, Y) then
         return;
      end if;

      Visited (X, Y) := True;
      Prev_X (X, Y) := PX;
      Prev_Y (X, Y) := PY;
      Queue_X (Tail) := X;
      Queue_Y (Tail) := Y;
      Tail := Tail + 1;
   end Push;
begin
   if Cell_Step < 1 then
      Cell_Step := 1;
   end if;

   if Cols < 8 then Cols := 8; end if;
   if Rows < 8 then Rows := 8; end if;
   if Cols > Max_Cols then Cols := Max_Cols; end if;
   if Rows > Max_Rows then Rows := Max_Rows; end if;

   Start_X := (Integer (Enemy_X) + (Integer (Enemy_W) / 2)) / Cell_Step;
   Start_Y := (Integer (Enemy_Y) + (Integer (Enemy_H) / 2)) / Cell_Step;
   Goal_X := (Integer (Player_X) + (Integer (Player_W) / 2)) / Cell_Step;
   Goal_Y := (Integer (Player_Y) + (Integer (Player_H) / 2)) / Cell_Step;

   Packed_State := (Packed_State xor U32 (16#00AA_5511#));
   Shifted_A := Packed_State * U32 (2);
   Shifted_B := Packed_State / U32 (4);
   Packed_State := (Shifted_A xor Shifted_B) and U32 (16#0000_00FF#);

   Path_Signature := Packed_State;
   Enemy_Step := S32 (1 + Integer (Packed_State mod U32 (3)));

   Wall_Col := Integer (Wall_X) / Cell_Step;
   Gap_Row := Rows / 2;
   for Y in 0 .. Rows - 1 loop
      if Y /= Gap_Row and then Y /= Gap_Row - 1 then
         if Wall_Col >= 0 and then Wall_Col < Cols then
            Blocked (Wall_Col, Y) := True;
         end if;
      end if;
   end loop;

   Barrier_Row := Integer (Barrier_Y) / Cell_Step;
   Barrier_Col_Start := Integer (Barrier_X) / Cell_Step;
   Barrier_Col_End := Integer (Barrier_X + Barrier_W - 1) / Cell_Step;
   if Barrier_Row >= 0 and then Barrier_Row < Rows then
      for X in Barrier_Col_Start .. Barrier_Col_End loop
         if X >= 0 and then X < Cols then
            Blocked (X, Barrier_Row) := True;
         end if;
      end loop;
   end if;

   if Start_X < 0 then Start_X := 0; end if;
   if Start_X >= Cols then Start_X := Cols - 1; end if;
   if Start_Y < 0 then Start_Y := 0; end if;
   if Start_Y >= Rows then Start_Y := Rows - 1; end if;

   if Goal_X < 0 then Goal_X := 0; end if;
   if Goal_X >= Cols then Goal_X := Cols - 1; end if;
   if Goal_Y < 0 then Goal_Y := 0; end if;
   if Goal_Y >= Rows then Goal_Y := Rows - 1; end if;

   Blocked (Start_X, Start_Y) := False;
   Blocked (Goal_X, Goal_Y) := False;

   Visited (Start_X, Start_Y) := True;
   Prev_X (Start_X, Start_Y) := Start_X;
   Prev_Y (Start_X, Start_Y) := Start_Y;
   Queue_X (0) := Start_X;
   Queue_Y (0) := Start_Y;
   Tail := 1;

   while Head < Tail and then not Found loop
      Cur_X := Queue_X (Head);
      Cur_Y := Queue_Y (Head);
      Head := Head + 1;

      if Cur_X = Goal_X and then Cur_Y = Goal_Y then
         Found := True;
      else
         Push (Cur_X + 1, Cur_Y, Cur_X, Cur_Y);
         Push (Cur_X - 1, Cur_Y, Cur_X, Cur_Y);
         Push (Cur_X, Cur_Y + 1, Cur_X, Cur_Y);
         Push (Cur_X, Cur_Y - 1, Cur_X, Cur_Y);
      end if;
   end loop;

   if Found then
      Step_X := Goal_X;
      Step_Y := Goal_Y;

      while not (Prev_X (Step_X, Step_Y) = Start_X and then Prev_Y (Step_X, Step_Y) = Start_Y) loop
         declare
            PX : constant Integer := Prev_X (Step_X, Step_Y);
            PY : constant Integer := Prev_Y (Step_X, Step_Y);
         begin
            exit when PX < 0 or else PY < 0;
            Step_X := PX;
            Step_Y := PY;
            exit when Step_X = Start_X and then Step_Y = Start_Y;
         end;
      end loop;

      if Step_X = Start_X and then Step_Y = Start_Y then
         Step_X := Goal_X;
         Step_Y := Goal_Y;
      end if;

      Enemy_Target_X := S32 ((Step_X * Cell_Step) + 2);
      Enemy_Target_Y := S32 ((Step_Y * Cell_Step) + 2);
   else
      Enemy_Target_X := Player_X;
      Enemy_Target_Y := Player_Y;
   end if;
end;

         end ALBA_Unsafe_Block_670;
      begin
         ALBA_Unsafe_Block_670;
      end;
      if 
   (Enemy_X < Enemy_Target_X) then
         Enemy_X := (Enemy_X + Enemy_Step);
         ALB_STORE_I32(Positive(40), ALB_I32(Enemy_X));
      end if;
      if 
   (Enemy_X > Enemy_Target_X) then
         Enemy_X := (Enemy_X - Enemy_Step);
         ALB_STORE_I32(Positive(40), ALB_I32(Enemy_X));
      end if;
      if 
   (Enemy_Y < Enemy_Target_Y) then
         Enemy_Y := (Enemy_Y + Enemy_Step);
         ALB_STORE_I32(Positive(44), ALB_I32(Enemy_Y));
      end if;
      if 
   (Enemy_Y > Enemy_Target_Y) then
         Enemy_Y := (Enemy_Y - Enemy_Step);
         ALB_STORE_I32(Positive(44), ALB_I32(Enemy_Y));
      end if;
      if 
   (Enemy_X < 0) then
         Enemy_X := 0;
         ALB_STORE_I32(Positive(40), ALB_I32(Enemy_X));
      end if;
      if 
   (Enemy_Y < 0) then
         Enemy_Y := 0;
         ALB_STORE_I32(Positive(44), ALB_I32(Enemy_Y));
      end if;
      if 
   (Enemy_X > (Screen_W - Enemy_W)) then
         Enemy_X := (Screen_W - Enemy_W);
         ALB_STORE_I32(Positive(40), ALB_I32(Enemy_X));
      end if;
      if 
   (Enemy_Y > (Screen_H - Enemy_H)) then
         Enemy_Y := (Screen_H - Enemy_H);
         ALB_STORE_I32(Positive(44), ALB_I32(Enemy_Y));
      end if;
      Collided := ALB_COLLIDE_RECT(Player_X, Player_Y, Player_W, Player_H, Enemy_X, Enemy_Y, Enemy_W, Enemy_H);
      ALB_STORE_BOOL(Positive(84), Collided);
   end ALB_On_Tick;

   procedure ALB_On_Paint is
   begin
      if 
   (Collided = True) then
         ALBA_Graphics.Clear(Integer(2#0000100000000000#));
      else
         ALBA_Graphics.Clear(Integer(2#0000000000000000#));
      end if;
      ALBA_Graphics.Set_Color(Integer(2#0000000011111111#));
      ALBA_Graphics.Fill_Rect(Integer(Wall_X), Integer(0), Integer(Wall_W), Integer(Wall_Top_H));
      ALBA_Graphics.Fill_Rect(Integer(Wall_X), Integer(Wall_Bot_Y), Integer(Wall_W), Integer(Wall_Bot_H));
      ALBA_Graphics.Fill_Rect(Integer(Barrier_X), Integer(Barrier_Y), Integer(Barrier_W), Integer(Barrier_H));
      ALBA_Graphics.Set_Color(Integer(2#1111111100000000#));
      ALBA_Graphics.Fill_Rect(Integer(Player_X), Integer(Player_Y), Integer((Player_W + (Bit_Pulse / 8))), Integer(Player_H));
      if 
   (Collided = True) then
         ALBA_Graphics.Set_Color(Integer(2#1111111100001111#));
      else
         ALBA_Graphics.Set_Color(Integer(2#0000000000001111#));
      end if;
      ALBA_Graphics.Fill_Rect(Integer(Enemy_X), Integer(Enemy_Y), Integer(Enemy_W), Integer(Enemy_H));
      ALBA_Graphics.Set_Color(Integer(2#1111111111111111#));
      ALBA_Graphics.Draw_Rect(Integer(Enemy_Target_X), Integer(Enemy_Target_Y), Integer(Enemy_W), Integer(Enemy_H));
   end ALB_On_Paint;

begin
   Screen_W := 640;
   ALB_STORE_I32(Positive(4), ALB_I32(Screen_W));
   Screen_H := 480;
   ALB_STORE_I32(Positive(8), ALB_I32(Screen_H));
   Cell_Size := 20;
   ALB_STORE_I32(Positive(12), ALB_I32(Cell_Size));
   Grid_Cols := 32;
   ALB_STORE_I32(Positive(16), ALB_I32(Grid_Cols));
   Grid_Rows := 24;
   ALB_STORE_I32(Positive(20), ALB_I32(Grid_Rows));
   ALBA_Graphics.Set_Stretchy(True);
   ALBA_Graphics.Set_Resizable(True);
   ALBA_Graphics.Initialize("ADA_GAME_TEST", Natural(Integer(Screen_W)), Natural(Integer(Screen_H)), Graphics_OK);
   Player_X := (Cell_Size + 12);
   ALB_STORE_I32(Positive(24), ALB_I32(Player_X));
   Player_Y := (Cell_Size + 12);
   ALB_STORE_I32(Positive(28), ALB_I32(Player_Y));
   Player_W := 16;
   ALB_STORE_I32(Positive(32), ALB_I32(Player_W));
   Player_H := 16;
   ALB_STORE_I32(Positive(36), ALB_I32(Player_H));
   Enemy_X := ((Screen_W - (Cell_Size * 2)) - 8);
   ALB_STORE_I32(Positive(40), ALB_I32(Enemy_X));
   Enemy_Y := ((Screen_H - (Cell_Size * 3)) - 8);
   ALB_STORE_I32(Positive(44), ALB_I32(Enemy_Y));
   Enemy_W := 16;
   ALB_STORE_I32(Positive(48), ALB_I32(Enemy_W));
   Enemy_H := 16;
   ALB_STORE_I32(Positive(52), ALB_I32(Enemy_H));
   Enemy_Target_X := Enemy_X;
   ALB_STORE_I32(Positive(56), ALB_I32(Enemy_Target_X));
   Enemy_Target_Y := Enemy_Y;
   ALB_STORE_I32(Positive(60), ALB_I32(Enemy_Target_Y));
   Move_Speed := 3;
   ALB_STORE_I32(Positive(64), ALB_I32(Move_Speed));
   Enemy_Step := 2;
   ALB_STORE_I32(Positive(68), ALB_I32(Enemy_Step));
   Frame_Counter := U32(0);
   ALB_STORE_U32(Positive(72), ALB_U32(Frame_Counter));
   Bit_Pulse := 0;
   ALB_STORE_I32(Positive(76), ALB_I32(Bit_Pulse));
   Path_Signature := U32(0);
   ALB_STORE_U32(Positive(80), ALB_U32(Path_Signature));
   Collided := False;
   ALB_STORE_BOOL(Positive(84), Collided);
   Wall_X := 0;
   ALB_STORE_I32(Positive(88), ALB_I32(Wall_X));
   Wall_W := 0;
   ALB_STORE_I32(Positive(92), ALB_I32(Wall_W));
   Wall_Top_H := 0;
   ALB_STORE_I32(Positive(96), ALB_I32(Wall_Top_H));
   Wall_Bot_Y := 0;
   ALB_STORE_I32(Positive(100), ALB_I32(Wall_Bot_Y));
   Wall_Bot_H := 0;
   ALB_STORE_I32(Positive(104), ALB_I32(Wall_Bot_H));
   Barrier_X := 0;
   ALB_STORE_I32(Positive(108), ALB_I32(Barrier_X));
   Barrier_Y := 0;
   ALB_STORE_I32(Positive(112), ALB_I32(Barrier_Y));
   Barrier_W := 0;
   ALB_STORE_I32(Positive(116), ALB_I32(Barrier_W));
   Barrier_H := 0;
   ALB_STORE_I32(Positive(120), ALB_I32(Barrier_H));
   Next_Player_X := Player_X;
   ALB_STORE_I32(Positive(124), ALB_I32(Next_Player_X));
   Next_Player_Y := Player_Y;
   ALB_STORE_I32(Positive(128), ALB_I32(Next_Player_Y));
   Player_Blocked := False;
   ALB_STORE_BOOL(Positive(132), Player_Blocked);
   while ALBA_Graphics.Window_Open loop
      ALBA_Graphics.Process_Events;
      ALB_On_Tick;
      ALB_On_Paint;
      ALBA_Graphics.Present;
   end loop;
   ALBA_Graphics.Shutdown;
   ALBA_Audio.Shutdown;
end AdaGameTest;

