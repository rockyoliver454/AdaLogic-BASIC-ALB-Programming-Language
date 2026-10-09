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

procedure test_window01 is
   Graphics_OK : Boolean := False;
   ALBA_User_Error : exception;
   ALBA_Last_Error : ALB_Text := ALB_STR("");
   Obj_Pos_X : S32 := 0;
   Obj_Pos_Y : S32 := 0;
   Cam_Z : S32 := 0;
   ModelScale : S32 := 0;
   ZDepth : S32 := 0;
   LUT_Sin : array (Positive range 1 .. 360) of S32 := (others => 0);
   LUT_Cos : array (Positive range 1 .. 360) of S32 := (others => 0);
   Degree : S32 := 0;
   Global_Yaw : S32 := 0;
   cam_sn : S32 := 0;
   cam_cn : S32 := 0;
   Global_Pitch : S32 := 0;
   pitch_sn : S32 := 0;
   pitch_cn : S32 := 0;
   Yaw_X : S32 := 0;
   Yaw_Z : S32 := 0;
   Model_x : array (Positive range 1 .. 24) of S32 := (others => 0);
   Model_y : array (Positive range 1 .. 24) of S32 := (others => 0);
   Model_z : array (Positive range 1 .. 24) of S32 := (others => 0);
   top_y : S32 := 0;
   bot_y : S32 := 0;
   rad : S32 := 0;
   Screen_x : array (Positive range 1 .. 24) of S32 := (others => 0);
   Screen_y : array (Positive range 1 .. 24) of S32 := (others => 0);
   View_x : array (Positive range 1 .. 24) of S32 := (others => 0);
   View_y : array (Positive range 1 .. 24) of S32 := (others => 0);
   View_z : array (Positive range 1 .. 24) of S32 := (others => 0);
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
         Obj_Pos_X := S32(ALB_LOAD_I32(Positive(4)));
         return;
      end if;
      if Address < 12 and then (Address + 7) >= 8 then
         ALB_POKE(Address, Raw_Value);
         Obj_Pos_Y := S32(ALB_LOAD_I32(Positive(8)));
         return;
      end if;
      if Address < 16 and then (Address + 7) >= 12 then
         ALB_POKE(Address, Raw_Value);
         Cam_Z := S32(ALB_LOAD_I32(Positive(12)));
         return;
      end if;
      if Address < 20 and then (Address + 7) >= 16 then
         ALB_POKE(Address, Raw_Value);
         ModelScale := S32(ALB_LOAD_I32(Positive(16)));
         return;
      end if;
      if Address < 24 and then (Address + 7) >= 20 then
         ALB_POKE(Address, Raw_Value);
         ZDepth := S32(ALB_LOAD_I32(Positive(20)));
         return;
      end if;
      if Address < 1464 and then (Address + 7) >= 24 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_6 in 0 .. 359 loop
            declare
               Element_Base : constant Natural := 24 + (ALBA_Reload_Elem_6 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  LUT_Sin(Positive(ALBA_Reload_Elem_6 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 2904 and then (Address + 7) >= 1464 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_7 in 0 .. 359 loop
            declare
               Element_Base : constant Natural := 1464 + (ALBA_Reload_Elem_7 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  LUT_Cos(Positive(ALBA_Reload_Elem_7 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 2908 and then (Address + 7) >= 2904 then
         ALB_POKE(Address, Raw_Value);
         Degree := S32(ALB_LOAD_I32(Positive(2904)));
         return;
      end if;
      if Address < 2912 and then (Address + 7) >= 2908 then
         ALB_POKE(Address, Raw_Value);
         Global_Yaw := S32(ALB_LOAD_I32(Positive(2908)));
         return;
      end if;
      if Address < 2916 and then (Address + 7) >= 2912 then
         ALB_POKE(Address, Raw_Value);
         cam_sn := S32(ALB_LOAD_I32(Positive(2912)));
         return;
      end if;
      if Address < 2920 and then (Address + 7) >= 2916 then
         ALB_POKE(Address, Raw_Value);
         cam_cn := S32(ALB_LOAD_I32(Positive(2916)));
         return;
      end if;
      if Address < 2924 and then (Address + 7) >= 2920 then
         ALB_POKE(Address, Raw_Value);
         Global_Pitch := S32(ALB_LOAD_I32(Positive(2920)));
         return;
      end if;
      if Address < 2928 and then (Address + 7) >= 2924 then
         ALB_POKE(Address, Raw_Value);
         pitch_sn := S32(ALB_LOAD_I32(Positive(2924)));
         return;
      end if;
      if Address < 2932 and then (Address + 7) >= 2928 then
         ALB_POKE(Address, Raw_Value);
         pitch_cn := S32(ALB_LOAD_I32(Positive(2928)));
         return;
      end if;
      if Address < 2936 and then (Address + 7) >= 2932 then
         ALB_POKE(Address, Raw_Value);
         Yaw_X := S32(ALB_LOAD_I32(Positive(2932)));
         return;
      end if;
      if Address < 2940 and then (Address + 7) >= 2936 then
         ALB_POKE(Address, Raw_Value);
         Yaw_Z := S32(ALB_LOAD_I32(Positive(2936)));
         return;
      end if;
      if Address < 3036 and then (Address + 7) >= 2940 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_17 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 2940 + (ALBA_Reload_Elem_17 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  Model_x(Positive(ALBA_Reload_Elem_17 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 3132 and then (Address + 7) >= 3036 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_18 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 3036 + (ALBA_Reload_Elem_18 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  Model_y(Positive(ALBA_Reload_Elem_18 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 3228 and then (Address + 7) >= 3132 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_19 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 3132 + (ALBA_Reload_Elem_19 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  Model_z(Positive(ALBA_Reload_Elem_19 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 3232 and then (Address + 7) >= 3228 then
         ALB_POKE(Address, Raw_Value);
         top_y := S32(ALB_LOAD_I32(Positive(3228)));
         return;
      end if;
      if Address < 3236 and then (Address + 7) >= 3232 then
         ALB_POKE(Address, Raw_Value);
         bot_y := S32(ALB_LOAD_I32(Positive(3232)));
         return;
      end if;
      if Address < 3240 and then (Address + 7) >= 3236 then
         ALB_POKE(Address, Raw_Value);
         rad := S32(ALB_LOAD_I32(Positive(3236)));
         return;
      end if;
      if Address < 3336 and then (Address + 7) >= 3240 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_23 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 3240 + (ALBA_Reload_Elem_23 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  Screen_x(Positive(ALBA_Reload_Elem_23 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 3432 and then (Address + 7) >= 3336 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_24 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 3336 + (ALBA_Reload_Elem_24 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  Screen_y(Positive(ALBA_Reload_Elem_24 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 3528 and then (Address + 7) >= 3432 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_25 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 3432 + (ALBA_Reload_Elem_25 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  View_x(Positive(ALBA_Reload_Elem_25 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 3624 and then (Address + 7) >= 3528 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_26 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 3528 + (ALBA_Reload_Elem_26 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  View_y(Positive(ALBA_Reload_Elem_26 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      if Address < 3720 and then (Address + 7) >= 3624 then
         ALB_POKE(Address, Raw_Value);
         for ALBA_Reload_Elem_27 in 0 .. 23 loop
            declare
               Element_Base : constant Natural := 3624 + (ALBA_Reload_Elem_27 * 4);
            begin
               if Address < Element_Base + 4 and then (Address + 7) >= Element_Base then
                  View_z(Positive(ALBA_Reload_Elem_27 + 1)) := S32(ALB_LOAD_I32(Positive(Element_Base)));
               end if;
            end;
         end loop;
         return;
      end if;
      ALB_POKE(Address, Raw_Value);
   end ALBA_Poke_Address;

   procedure ALB_On_Tick is
   ALB_On_Tick_Angle_Idx : S32 := 0;
   ALB_On_Tick_safe_pitch : S32 := 0;
   ALB_On_Tick_Pitch_Idx : S32 := 0;
   ALB_On_Tick_LUTDivide : S32 := 0;
   ALB_On_Tick_i : S32 := 0;

   begin
      if 
   ((if ALBA_Graphics.Key_Down(Integer(26)) then 1 else 0) > 0) then
         Global_Pitch := (Global_Pitch + 2);
         ALB_STORE_I32(Positive(2920), ALB_I32(Global_Pitch));
      end if;
      if 
   ((if ALBA_Graphics.Key_Down(Integer(22)) then 1 else 0) > 0) then
         Global_Pitch := (Global_Pitch - 2);
         ALB_STORE_I32(Positive(2920), ALB_I32(Global_Pitch));
      end if;
      if 
   ((if ALBA_Graphics.Key_Down(Integer(4)) then 1 else 0) > 0) then
         Global_Yaw := (Global_Yaw - 2);
         ALB_STORE_I32(Positive(2908), ALB_I32(Global_Yaw));
      end if;
      if 
   ((if ALBA_Graphics.Key_Down(Integer(7)) then 1 else 0) > 0) then
         Global_Yaw := (Global_Yaw + 2);
         ALB_STORE_I32(Positive(2908), ALB_I32(Global_Yaw));
      end if;
      if 
   (Global_Pitch > 90) then
         Global_Pitch := 90;
         ALB_STORE_I32(Positive(2920), ALB_I32(Global_Pitch));
      end if;
      if 
   (Global_Pitch < -90) then
         Global_Pitch := -90;
         ALB_STORE_I32(Positive(2920), ALB_I32(Global_Pitch));
      end if;
      if 
   (Global_Yaw < 0) then
         Global_Yaw := (Global_Yaw + 360);
         ALB_STORE_I32(Positive(2908), ALB_I32(Global_Yaw));
      end if;
      if 
   (Global_Yaw > 359) then
         Global_Yaw := (Global_Yaw - 360);
         ALB_STORE_I32(Positive(2908), ALB_I32(Global_Yaw));
      end if;
      ALB_On_Tick_Angle_Idx := (S32(Global_Yaw) + 1);
      cam_sn := LUT_Sin (Positive(ALB_On_Tick_Angle_Idx));
      ALB_STORE_I32(Positive(2912), ALB_I32(cam_sn));
      cam_cn := LUT_Cos (Positive(ALB_On_Tick_Angle_Idx));
      ALB_STORE_I32(Positive(2916), ALB_I32(cam_cn));
      ALB_On_Tick_safe_pitch := Global_Pitch;
      if 
   (ALB_On_Tick_safe_pitch < 0) then
         ALB_On_Tick_safe_pitch := (ALB_On_Tick_safe_pitch + 360);
      end if;
      ALB_On_Tick_Pitch_Idx := (S32(ALB_On_Tick_safe_pitch) + 1);
      pitch_sn := LUT_Sin (Positive(ALB_On_Tick_Pitch_Idx));
      ALB_STORE_I32(Positive(2924), ALB_I32(pitch_sn));
      pitch_cn := LUT_Cos (Positive(ALB_On_Tick_Pitch_Idx));
      ALB_STORE_I32(Positive(2928), ALB_I32(pitch_cn));
      ALB_On_Tick_LUTDivide := 1000;
      ALB_On_Tick_i := 0;
      ALB_On_Tick_i := 1;
      while ALB_On_Tick_i <= 24 loop
         Yaw_X := (((Model_x (Positive(ALB_On_Tick_i)) * cam_cn) / ALB_On_Tick_LUTDivide) - ((Model_z (Positive(ALB_On_Tick_i)) * cam_sn) / ALB_On_Tick_LUTDivide));
         ALB_STORE_I32(Positive(2932), ALB_I32(Yaw_X));
         Yaw_Z := (((Model_x (Positive(ALB_On_Tick_i)) * cam_sn) / ALB_On_Tick_LUTDivide) + ((Model_z (Positive(ALB_On_Tick_i)) * cam_cn) / ALB_On_Tick_LUTDivide));
         ALB_STORE_I32(Positive(2936), ALB_I32(Yaw_Z));
         View_x (Positive(ALB_On_Tick_i)) := Yaw_X;
         View_y (Positive(ALB_On_Tick_i)) := (((Model_y (Positive(ALB_On_Tick_i)) * pitch_cn) / ALB_On_Tick_LUTDivide) - ((Yaw_Z * pitch_sn) / ALB_On_Tick_LUTDivide));
         View_z (Positive(ALB_On_Tick_i)) := (((Model_y (Positive(ALB_On_Tick_i)) * pitch_sn) / ALB_On_Tick_LUTDivide) + ((Yaw_Z * pitch_cn) / ALB_On_Tick_LUTDivide));
         <<ALBA_CONTINUE_1>>
         ALB_On_Tick_i := ALB_On_Tick_i + 1;
      end loop;
      ALB_On_Tick_i := 1;
      while ALB_On_Tick_i <= 24 loop
         View_z (Positive(ALB_On_Tick_i)) := (View_z (Positive(ALB_On_Tick_i)) + Cam_Z);
         if 
      (View_z (Positive(ALB_On_Tick_i)) < 1) then
            View_z (Positive(ALB_On_Tick_i)) := 1;
         end if;
         <<ALBA_CONTINUE_2>>
         ALB_On_Tick_i := ALB_On_Tick_i + 1;
      end loop;
      ALB_On_Tick_i := 1;
      while ALB_On_Tick_i <= 24 loop
         Screen_x (Positive(ALB_On_Tick_i)) := (Obj_Pos_X + ((View_x (Positive(ALB_On_Tick_i)) * ModelScale) / View_z (Positive(ALB_On_Tick_i))));
         Screen_y (Positive(ALB_On_Tick_i)) := (Obj_Pos_Y + ((View_y (Positive(ALB_On_Tick_i)) * ModelScale) / View_z (Positive(ALB_On_Tick_i))));
         <<ALBA_CONTINUE_3>>
         ALB_On_Tick_i := ALB_On_Tick_i + 1;
      end loop;
   end ALB_On_Tick;

   procedure ALB_On_Paint is
   ALB_On_Paint_t : S32 := 0;

   begin
      ALBA_Graphics.Clear(Integer(2#1010101#));
      ALBA_Graphics.Set_Color(Integer(2#0000000000000001111111111#));
      ALB_On_Paint_t := 1;
      ALB_On_Paint_t := 1;
      while ALB_On_Paint_t <= 24 loop
         ALBA_Graphics.Draw_Triangle(Integer(Screen_x (Positive(ALB_On_Paint_t))), Integer(Screen_y (Positive(ALB_On_Paint_t))), Integer(Screen_x (Positive((ALB_On_Paint_t + 1)))), Integer(Screen_y (Positive((ALB_On_Paint_t + 1)))), Integer(Screen_x (Positive((ALB_On_Paint_t + 2)))), Integer(Screen_y (Positive((ALB_On_Paint_t + 2)))));
         <<ALBA_CONTINUE_4>>
         ALB_On_Paint_t := ALB_On_Paint_t + 3;
      end loop;
   end ALB_On_Paint;

begin
   ALBA_Graphics.Initialize("TEST_WINDOW01", 320, 200, Graphics_OK);
   Obj_Pos_X := (320 / 2);
   ALB_STORE_I32(Positive(4), ALB_I32(Obj_Pos_X));
   Obj_Pos_Y := (200 / 2);
   ALB_STORE_I32(Positive(8), ALB_I32(Obj_Pos_Y));
   Cam_Z := (320 / 2);
   ALB_STORE_I32(Positive(12), ALB_I32(Cam_Z));
   ModelScale := (320 / 2);
   ALB_STORE_I32(Positive(16), ALB_I32(ModelScale));
   ZDepth := 0;
   ALB_STORE_I32(Positive(20), ALB_I32(ZDepth));
   Degree := 0;
   ALB_STORE_I32(Positive(2904), ALB_I32(Degree));
   Degree := 1;
   ALB_STORE_I32(Positive(2904), ALB_I32(Degree));
   while Degree <= 360 loop
      LUT_Sin (Positive(Degree)) := S32(ALB_SIN((Degree - 1)));
      ALB_STORE_I32(Positive((24 + ((Degree - 1) * 4))), ALB_I32(LUT_Sin (Positive(Degree))));
      LUT_Cos (Positive(Degree)) := S32(ALB_COS((Degree - 1)));
      ALB_STORE_I32(Positive((1464 + ((Degree - 1) * 4))), ALB_I32(LUT_Cos (Positive(Degree))));
      <<ALBA_CONTINUE_5>>
      Degree := Degree + 1;
      ALB_STORE_I32(Positive(2904), ALB_I32(Degree));
   end loop;
   Global_Yaw := 0;
   ALB_STORE_I32(Positive(2908), ALB_I32(Global_Yaw));
   cam_sn := 0;
   ALB_STORE_I32(Positive(2912), ALB_I32(cam_sn));
   cam_cn := 0;
   ALB_STORE_I32(Positive(2916), ALB_I32(cam_cn));
   Global_Pitch := 0;
   ALB_STORE_I32(Positive(2920), ALB_I32(Global_Pitch));
   pitch_sn := 0;
   ALB_STORE_I32(Positive(2924), ALB_I32(pitch_sn));
   pitch_cn := 0;
   ALB_STORE_I32(Positive(2928), ALB_I32(pitch_cn));
   Yaw_X := 0;
   ALB_STORE_I32(Positive(2932), ALB_I32(Yaw_X));
   Yaw_Z := 0;
   ALB_STORE_I32(Positive(2936), ALB_I32(Yaw_Z));
   top_y := (0 - 50);
   ALB_STORE_I32(Positive(3228), ALB_I32(top_y));
   bot_y := 50;
   ALB_STORE_I32(Positive(3232), ALB_I32(bot_y));
   rad := 50;
   ALB_STORE_I32(Positive(3236), ALB_I32(rad));
   Model_x (Positive(1)) := 0;
   Model_y (Positive(1)) := top_y;
   Model_z (Positive(1)) := 0;
   Model_x (Positive(2)) := 0;
   Model_y (Positive(2)) := 0;
   Model_z (Positive(2)) := rad;
   Model_x (Positive(3)) := rad;
   Model_y (Positive(3)) := 0;
   Model_z (Positive(3)) := 0;
   Model_x (Positive(4)) := 0;
   Model_y (Positive(4)) := top_y;
   Model_z (Positive(4)) := 0;
   Model_x (Positive(5)) := rad;
   Model_y (Positive(5)) := 0;
   Model_z (Positive(5)) := 0;
   Model_x (Positive(6)) := 0;
   Model_y (Positive(6)) := 0;
   Model_z (Positive(6)) := (0 - rad);
   Model_x (Positive(7)) := 0;
   Model_y (Positive(7)) := top_y;
   Model_z (Positive(7)) := 0;
   Model_x (Positive(8)) := 0;
   Model_y (Positive(8)) := 0;
   Model_z (Positive(8)) := (0 - rad);
   Model_x (Positive(9)) := (0 - rad);
   Model_y (Positive(9)) := 0;
   Model_z (Positive(9)) := 0;
   Model_x (Positive(10)) := 0;
   Model_y (Positive(10)) := top_y;
   Model_z (Positive(10)) := 0;
   Model_x (Positive(11)) := (0 - rad);
   Model_y (Positive(11)) := 0;
   Model_z (Positive(11)) := 0;
   Model_x (Positive(12)) := 0;
   Model_y (Positive(12)) := 0;
   Model_z (Positive(12)) := rad;
   Model_x (Positive(13)) := 0;
   Model_y (Positive(13)) := bot_y;
   Model_z (Positive(13)) := 0;
   Model_x (Positive(14)) := rad;
   Model_y (Positive(14)) := 0;
   Model_z (Positive(14)) := 0;
   Model_x (Positive(15)) := 0;
   Model_y (Positive(15)) := 0;
   Model_z (Positive(15)) := rad;
   Model_x (Positive(16)) := 0;
   Model_y (Positive(16)) := bot_y;
   Model_z (Positive(16)) := 0;
   Model_x (Positive(17)) := 0;
   Model_y (Positive(17)) := 0;
   Model_z (Positive(17)) := (0 - rad);
   Model_x (Positive(18)) := rad;
   Model_y (Positive(18)) := 0;
   Model_z (Positive(18)) := 0;
   Model_x (Positive(19)) := 0;
   Model_y (Positive(19)) := bot_y;
   Model_z (Positive(19)) := 0;
   Model_x (Positive(20)) := (0 - rad);
   Model_y (Positive(20)) := 0;
   Model_z (Positive(20)) := 0;
   Model_x (Positive(21)) := 0;
   Model_y (Positive(21)) := 0;
   Model_z (Positive(21)) := (0 - rad);
   Model_x (Positive(22)) := 0;
   Model_y (Positive(22)) := bot_y;
   Model_z (Positive(22)) := 0;
   Model_x (Positive(23)) := 0;
   Model_y (Positive(23)) := 0;
   Model_z (Positive(23)) := rad;
   Model_x (Positive(24)) := (0 - rad);
   Model_y (Positive(24)) := 0;
   Model_z (Positive(24)) := 0;
   while ALBA_Graphics.Window_Open loop
      ALBA_Graphics.Process_Events;
      ALB_On_Tick;
      ALB_On_Paint;
      ALBA_Graphics.Present;
   end loop;
   ALBA_Graphics.Shutdown;
   ALBA_Audio.Shutdown;
end test_window01;

