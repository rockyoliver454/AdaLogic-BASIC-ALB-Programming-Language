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

procedure ARC is
   Graphics_OK : Boolean := False;
   ALBA_User_Error : exception;
   ALBA_Last_Error : ALB_Text := ALB_STR("");
   app_state : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   sim_mode : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   volt : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   dist : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   is_arcing : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   cx : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   cy : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   mx : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   my : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   prev_click : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   cap_timer : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
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
      if Address < 24 and then (Address + 7) >= 8 then
         ALB_POKE(Address, Raw_Value);
         app_state := ALB_LOAD_PURE(Positive(8));
         return;
      end if;
      if Address < 40 and then (Address + 7) >= 24 then
         ALB_POKE(Address, Raw_Value);
         sim_mode := ALB_LOAD_PURE(Positive(24));
         return;
      end if;
      if Address < 56 and then (Address + 7) >= 40 then
         ALB_POKE(Address, Raw_Value);
         volt := ALB_LOAD_PURE(Positive(40));
         return;
      end if;
      if Address < 72 and then (Address + 7) >= 56 then
         ALB_POKE(Address, Raw_Value);
         dist := ALB_LOAD_PURE(Positive(56));
         return;
      end if;
      if Address < 88 and then (Address + 7) >= 72 then
         ALB_POKE(Address, Raw_Value);
         is_arcing := ALB_LOAD_PURE(Positive(72));
         return;
      end if;
      if Address < 104 and then (Address + 7) >= 88 then
         ALB_POKE(Address, Raw_Value);
         cx := ALB_LOAD_PURE(Positive(88));
         return;
      end if;
      if Address < 120 and then (Address + 7) >= 104 then
         ALB_POKE(Address, Raw_Value);
         cy := ALB_LOAD_PURE(Positive(104));
         return;
      end if;
      if Address < 136 and then (Address + 7) >= 120 then
         ALB_POKE(Address, Raw_Value);
         mx := ALB_LOAD_PURE(Positive(120));
         return;
      end if;
      if Address < 152 and then (Address + 7) >= 136 then
         ALB_POKE(Address, Raw_Value);
         my := ALB_LOAD_PURE(Positive(136));
         return;
      end if;
      if Address < 168 and then (Address + 7) >= 152 then
         ALB_POKE(Address, Raw_Value);
         prev_click := ALB_LOAD_PURE(Positive(152));
         return;
      end if;
      if Address < 184 and then (Address + 7) >= 168 then
         ALB_POKE(Address, Raw_Value);
         cap_timer := ALB_LOAD_PURE(Positive(168));
         return;
      end if;
      ALB_POKE(Address, Raw_Value);
   end ALBA_Poke_Address;

   procedure ALB_On_Tick is
   ALB_On_Tick_clk : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Tick_is_click : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Tick_dx : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Tick_dy : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Tick_eff_volt : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));

   begin
      mx := ALB_PURE(Long_Integer(S32(ALBA_Graphics.Mouse_X)), Long_Integer(1));
      ALB_STORE_PURE(Positive(120), mx);
      if 
   (ALB_PURE_NUM(mx) > 320) then
         mx := ALB_PURE(Long_Integer(320), Long_Integer(1));
         ALB_STORE_PURE(Positive(120), mx);
      end if;
      my := ALB_PURE(Long_Integer(S32(ALBA_Graphics.Mouse_Y)), Long_Integer(1));
      ALB_STORE_PURE(Positive(136), my);
      if 
   (ALB_PURE_NUM(my) > 200) then
         my := ALB_PURE(Long_Integer(200), Long_Integer(1));
         ALB_STORE_PURE(Positive(136), my);
      end if;
      ALB_On_Tick_clk := ALB_PURE(Long_Integer(U32(ALBA_Graphics.Mouse_Click(Integer(0)))), Long_Integer(1));
      ALB_On_Tick_is_click := ALB_PURE(Long_Integer(0), Long_Integer(1));
      if 
   (ALB_PURE_NUM(ALB_On_Tick_clk) = 1) then
         if 
      (ALB_PURE_NUM(prev_click) = 0) then
            ALB_On_Tick_is_click := ALB_PURE(Long_Integer(1), Long_Integer(1));
         end if;
      end if;
      prev_click := ALB_On_Tick_clk;
      ALB_STORE_PURE(Positive(152), prev_click);
      if 
   (ALB_PURE_NUM(app_state) = 0) then
         if 
      (ALB_PURE_NUM(ALB_On_Tick_is_click) = 1) then
            if 
         ALB_COLLIDE_RECT(S32(ALBA_Graphics.Mouse_X), S32(ALBA_Graphics.Mouse_Y), 1, 1, 60, 60, 200, 30) then
               sim_mode := ALB_PURE(Long_Integer(1), Long_Integer(1));
               ALB_STORE_PURE(Positive(24), sim_mode);
               app_state := ALB_PURE(Long_Integer(1), Long_Integer(1));
               ALB_STORE_PURE(Positive(8), app_state);
               volt := ALB_PURE(Long_Integer(150), Long_Integer(1));
               ALB_STORE_PURE(Positive(40), volt);
               cap_timer := ALB_PURE(Long_Integer(0), Long_Integer(1));
               ALB_STORE_PURE(Positive(168), cap_timer);
               ALBA_Audio.Play_Music(ALB_TO_STRING(ALB_STR("T240 O5 L16 C E")));
            end if;
            if 
         ALB_COLLIDE_RECT(S32(ALBA_Graphics.Mouse_X), S32(ALBA_Graphics.Mouse_Y), 1, 1, 60, 100, 200, 30) then
               sim_mode := ALB_PURE(Long_Integer(2), Long_Integer(1));
               ALB_STORE_PURE(Positive(24), sim_mode);
               app_state := ALB_PURE(Long_Integer(1), Long_Integer(1));
               ALB_STORE_PURE(Positive(8), app_state);
               volt := ALB_PURE(Long_Integer(50), Long_Integer(1));
               ALB_STORE_PURE(Positive(40), volt);
               cap_timer := ALB_PURE(Long_Integer(0), Long_Integer(1));
               ALB_STORE_PURE(Positive(168), cap_timer);
               ALBA_Audio.Play_Music(ALB_TO_STRING(ALB_STR("T240 O5 L16 C G")));
            end if;
            if 
         ALB_COLLIDE_RECT(S32(ALBA_Graphics.Mouse_X), S32(ALBA_Graphics.Mouse_Y), 1, 1, 60, 140, 200, 30) then
               sim_mode := ALB_PURE(Long_Integer(3), Long_Integer(1));
               ALB_STORE_PURE(Positive(24), sim_mode);
               app_state := ALB_PURE(Long_Integer(1), Long_Integer(1));
               ALB_STORE_PURE(Positive(8), app_state);
               volt := ALB_PURE(Long_Integer(350), Long_Integer(1));
               ALB_STORE_PURE(Positive(40), volt);
               cap_timer := ALB_PURE(Long_Integer(0), Long_Integer(1));
               ALB_STORE_PURE(Positive(168), cap_timer);
               ALBA_Audio.Play_Music(ALB_TO_STRING(ALB_STR("T240 O5 L16 C > C")));
            end if;
         end if;
      else
         if 
      (ALB_PURE_NUM(ALB_On_Tick_is_click) = 1) then
            if 
         ALB_COLLIDE_RECT(S32(ALBA_Graphics.Mouse_X), S32(ALBA_Graphics.Mouse_Y), 1, 1, 260, 5, 55, 15) then
               app_state := ALB_PURE(Long_Integer(0), Long_Integer(1));
               ALB_STORE_PURE(Positive(8), app_state);
               ALBA_Audio.Play_Music(ALB_TO_STRING(ALB_STR("T240 O4 L16 G E")));
            end if;
            if 
         ALB_COLLIDE_RECT(S32(ALBA_Graphics.Mouse_X), S32(ALBA_Graphics.Mouse_Y), 1, 1, 5, 80, 30, 15) then
               volt := ALB_PURE_ADD(volt, ALB_PURE(Long_Integer(25), Long_Integer(1)));
               ALB_STORE_PURE(Positive(40), volt);
               if 
            (ALB_PURE_NUM(volt) > 500) then
                  volt := ALB_PURE(Long_Integer(500), Long_Integer(1));
                  ALB_STORE_PURE(Positive(40), volt);
               end if;
               ALBA_Audio.Play_Music(ALB_TO_STRING(ALB_STR("T240 O5 L32 C")));
            end if;
            if 
         ALB_COLLIDE_RECT(S32(ALBA_Graphics.Mouse_X), S32(ALBA_Graphics.Mouse_Y), 1, 1, 40, 80, 30, 15) then
               volt := ALB_PURE_SUB(volt, ALB_PURE(Long_Integer(25), Long_Integer(1)));
               ALB_STORE_PURE(Positive(40), volt);
               if 
            (ALB_PURE_NUM(volt) < 25) then
                  volt := ALB_PURE(Long_Integer(25), Long_Integer(1));
                  ALB_STORE_PURE(Positive(40), volt);
               end if;
               ALBA_Audio.Play_Music(ALB_TO_STRING(ALB_STR("T240 O4 L32 G")));
            end if;
         end if;
         ALB_On_Tick_dx := ALB_PURE(Long_Integer(0), Long_Integer(1));
         if 
      (ALB_PURE_NUM(mx) >= ALB_PURE_NUM(cx)) then
            ALB_On_Tick_dx := ALB_PURE_SUB(mx, cx);
         else
            ALB_On_Tick_dx := ALB_PURE_SUB(cx, mx);
         end if;
         ALB_On_Tick_dy := ALB_PURE(Long_Integer(0), Long_Integer(1));
         if 
      (ALB_PURE_NUM(my) >= ALB_PURE_NUM(cy)) then
            ALB_On_Tick_dy := ALB_PURE_SUB(my, cy);
         else
            ALB_On_Tick_dy := ALB_PURE_SUB(cy, my);
         end if;
         dist := ALB_PURE_ADD(ALB_On_Tick_dx, ALB_On_Tick_dy);
         ALB_STORE_PURE(Positive(56), dist);
         ALB_On_Tick_eff_volt := volt;
         if 
      (ALB_PURE_NUM(sim_mode) = 2) then
            ALB_On_Tick_eff_volt := ALB_PURE_MUL(volt, ALB_PURE(Long_Integer(3), Long_Integer(1)));
         end if;
         if 
      (ALB_PURE_NUM(sim_mode) = 3) then
            ALB_On_Tick_eff_volt := ALB_PURE_DIV(volt, ALB_PURE(Long_Integer(3), Long_Integer(1)));
         end if;
         if 
      (ALB_PURE_NUM(dist) < ALB_PURE_NUM(ALB_On_Tick_eff_volt)) then
            is_arcing := ALB_PURE(Long_Integer(1), Long_Integer(1));
            ALB_STORE_PURE(Positive(72), is_arcing);
         else
            is_arcing := ALB_PURE(Long_Integer(0), Long_Integer(1));
            ALB_STORE_PURE(Positive(72), is_arcing);
            cap_timer := ALB_PURE(Long_Integer(0), Long_Integer(1));
            ALB_STORE_PURE(Positive(168), cap_timer);
         end if;
      end if;
   end ALB_On_Tick;

   procedure ALB_On_Paint is
   ALB_On_Paint_do_render : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_r_dx : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_r_dy : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_step_x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_step_y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_dir_x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_dir_y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_n1x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_n1y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_n2x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_n2y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_n3x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_n3y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_j1x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_j1y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_j2x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_j2y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_j3x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_j3y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_p1x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_p1y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_p2x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_p2y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_p3x : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_On_Paint_p3y : Pure_Rational := ALB_PURE(Long_Integer(0), Long_Integer(1));

   begin
      ALBA_Graphics.Clear(Integer(16#050510#));
      if 
   (ALB_PURE_NUM(app_state) = 0) then
         ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
         ALBA_Graphics.Draw_Text(Integer(35), Integer(20), ALB_TO_STRING(ALB_STR("DIELECTRIC BREAKDOWN SIMULATOR")));
         ALBA_Graphics.Set_Color(Integer(16#5555AA#));
         ALBA_Graphics.Draw_Line(Integer(35), Integer(32), Integer(285), Integer(32));
         ALBA_Graphics.Set_Color(Integer(16#222233#));
         ALBA_Graphics.Fill_Rect(Integer(60), Integer(60), Integer(200), Integer(30));
         ALBA_Graphics.Set_Color(Integer(16#5555AA#));
         ALBA_Graphics.Draw_Rect(Integer(60), Integer(60), Integer(200), Integer(30));
         ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
         ALBA_Graphics.Draw_Text(Integer(70), Integer(70), ALB_TO_STRING(ALB_STR("SCENARIO 1: STANDARD AIR")));
         ALBA_Graphics.Set_Color(Integer(16#222233#));
         ALBA_Graphics.Fill_Rect(Integer(60), Integer(100), Integer(200), Integer(30));
         ALBA_Graphics.Set_Color(Integer(16#5555AA#));
         ALBA_Graphics.Draw_Rect(Integer(60), Integer(100), Integer(200), Integer(30));
         ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
         ALBA_Graphics.Draw_Text(Integer(70), Integer(110), ALB_TO_STRING(ALB_STR("SCENARIO 2: LOW PRESSURE VACUUM")));
         ALBA_Graphics.Set_Color(Integer(16#222233#));
         ALBA_Graphics.Fill_Rect(Integer(60), Integer(140), Integer(200), Integer(30));
         ALBA_Graphics.Set_Color(Integer(16#5555AA#));
         ALBA_Graphics.Draw_Rect(Integer(60), Integer(140), Integer(200), Integer(30));
         ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
         ALBA_Graphics.Draw_Text(Integer(70), Integer(150), ALB_TO_STRING(ALB_STR("SCENARIO 3: SOLID DIELECTRIC")));
      else
         if 
      (ALB_PURE_NUM(sim_mode) = 2) then
            ALBA_Graphics.Set_Color(Integer(16#112233#));
            ALBA_Graphics.Fill_Rect(Integer(120), Integer(40), Integer(80), Integer(160));
            ALBA_Graphics.Set_Color(Integer(16#446688#));
            ALBA_Graphics.Draw_Rect(Integer(120), Integer(40), Integer(80), Integer(160));
         end if;
         if 
      (ALB_PURE_NUM(sim_mode) = 3) then
            ALBA_Graphics.Set_Color(Integer(16#332211#));
            ALBA_Graphics.Fill_Rect(Integer(90), Integer(120), Integer(140), Integer(30));
            ALBA_Graphics.Set_Color(Integer(16#664422#));
            ALBA_Graphics.Draw_Rect(Integer(90), Integer(120), Integer(140), Integer(30));
         end if;
         ALBA_Graphics.Set_Color(Integer(16#111122#));
         ALBA_Graphics.Fill_Rect(Integer(5), Integer(5), Integer(140), Integer(70));
         ALBA_Graphics.Set_Color(Integer(16#333366#));
         ALBA_Graphics.Draw_Rect(Integer(5), Integer(5), Integer(140), Integer(70));
         ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
         ALBA_Graphics.Draw_Text(Integer(10), Integer(10), ALB_TO_STRING(ALB_CAT(ALB_STR("kV:   "), ALB_IMAGE(S32(ALB_PURE_NUM(volt))))));
         ALBA_Graphics.Draw_Text(Integer(10), Integer(25), ALB_TO_STRING(ALB_CAT(ALB_STR("GAP:  "), ALB_IMAGE(S32(ALB_PURE_NUM(dist))))));
         if 
      (ALB_PURE_NUM(sim_mode) = 1) then
            ALBA_Graphics.Set_Color(Integer(16#AAAAAA#));
            ALBA_Graphics.Draw_Text(Integer(10), Integer(40), ALB_TO_STRING(ALB_STR("MEDIUM: AIR (3kV/mm)")));
         end if;
         if 
      (ALB_PURE_NUM(sim_mode) = 2) then
            ALBA_Graphics.Set_Color(Integer(16#6688AA#));
            ALBA_Graphics.Draw_Text(Integer(10), Integer(40), ALB_TO_STRING(ALB_STR("MEDIUM: VAC (PASCHEN)")));
         end if;
         if 
      (ALB_PURE_NUM(sim_mode) = 3) then
            ALBA_Graphics.Set_Color(Integer(16#AA8866#));
            ALBA_Graphics.Draw_Text(Integer(10), Integer(40), ALB_TO_STRING(ALB_STR("MEDIUM: RUBBER (25kV/m)")));
         end if;
         if 
      (ALB_PURE_NUM(is_arcing) = 1) then
            if 
         (ALB_PURE_NUM(sim_mode) = 3) then
               ALBA_Graphics.Set_Color(Integer(16#FFFF33#));
               ALBA_Graphics.Draw_Text(Integer(10), Integer(55), ALB_TO_STRING(ALB_STR("STATUS: CHARGING...")));
            else
               ALBA_Graphics.Set_Color(Integer(16#FF3333#));
               ALBA_Graphics.Draw_Text(Integer(10), Integer(55), ALB_TO_STRING(ALB_STR("STATUS: ARCING!")));
            end if;
         else
            ALBA_Graphics.Set_Color(Integer(16#33FF33#));
            ALBA_Graphics.Draw_Text(Integer(10), Integer(55), ALB_TO_STRING(ALB_STR("STATUS: INSULATED")));
         end if;
         ALBA_Graphics.Set_Color(Integer(16#444455#));
         ALBA_Graphics.Fill_Rect(Integer(5), Integer(80), Integer(30), Integer(15));
         ALBA_Graphics.Fill_Rect(Integer(40), Integer(80), Integer(30), Integer(15));
         ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
         ALBA_Graphics.Draw_Text(Integer(12), Integer(84), ALB_TO_STRING(ALB_STR("V+")));
         ALBA_Graphics.Draw_Text(Integer(47), Integer(84), ALB_TO_STRING(ALB_STR("V-")));
         ALBA_Graphics.Set_Color(Integer(16#553333#));
         ALBA_Graphics.Fill_Rect(Integer(260), Integer(5), Integer(55), Integer(15));
         ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
         ALBA_Graphics.Draw_Text(Integer(265), Integer(9), ALB_TO_STRING(ALB_STR("MENU")));
         ALBA_Graphics.Set_Color(Integer(16#555555#));
         ALBA_Graphics.Fill_Rect(Integer((ALB_PURE_NUM(cx) - 15)), Integer((ALB_PURE_NUM(cy) - 5)), Integer(30), Integer(10));
         ALBA_Graphics.Set_Color(Integer(16#22FF22#));
         ALBA_Graphics.Draw_Text(Integer((ALB_PURE_NUM(cx) - 22)), Integer((ALB_PURE_NUM(cy) + 8)), ALB_TO_STRING(ALB_STR("CATHODE")));
         ALBA_Graphics.Set_Color(Integer(16#AAAAAA#));
         ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(mx)), Integer(ALB_PURE_NUM(my)), Integer(4));
         ALBA_Graphics.Set_Color(Integer(16#FF2222#));
         ALBA_Graphics.Draw_Text(Integer((ALB_PURE_NUM(mx) + 8)), Integer((ALB_PURE_NUM(my) - 4)), ALB_TO_STRING(ALB_STR("ANODE")));
         if 
      (ALB_PURE_NUM(is_arcing) = 1) then
            ALB_On_Paint_do_render := ALB_PURE(Long_Integer(1), Long_Integer(1));
            if 
         (ALB_PURE_NUM(sim_mode) = 3) then
               cap_timer := ALB_PURE_ADD(cap_timer, ALB_PURE(Long_Integer(1), Long_Integer(1)));
               ALB_STORE_PURE(Positive(168), cap_timer);
               if 
            (ALB_PURE_NUM(cap_timer) > 20) then
                  ALB_On_Paint_do_render := ALB_PURE(Long_Integer(1), Long_Integer(1));
                  if 
               (ALB_PURE_NUM(cap_timer) > 23) then
                     cap_timer := ALB_PURE(Long_Integer(0), Long_Integer(1));
                     ALB_STORE_PURE(Positive(168), cap_timer);
                  end if;
               else
                  ALB_On_Paint_do_render := ALB_PURE(Long_Integer(0), Long_Integer(1));
               end if;
            end if;
            if 
         (ALB_PURE_NUM(ALB_On_Paint_do_render) = 1) then
               ALBA_Audio.Play_Music(ALB_TO_STRING(ALB_STR("T255 O1 L64 E")));
               ALB_On_Paint_r_dx := ALB_PURE(Long_Integer(0), Long_Integer(1));
               if 
            (ALB_PURE_NUM(mx) >= ALB_PURE_NUM(cx)) then
                  ALB_On_Paint_r_dx := ALB_PURE_SUB(mx, cx);
               else
                  ALB_On_Paint_r_dx := ALB_PURE_SUB(cx, mx);
               end if;
               ALB_On_Paint_r_dy := ALB_PURE(Long_Integer(0), Long_Integer(1));
               if 
            (ALB_PURE_NUM(my) >= ALB_PURE_NUM(cy)) then
                  ALB_On_Paint_r_dy := ALB_PURE_SUB(my, cy);
               else
                  ALB_On_Paint_r_dy := ALB_PURE_SUB(cy, my);
               end if;
               ALB_On_Paint_step_x := ALB_PURE_DIV(ALB_On_Paint_r_dx, ALB_PURE(Long_Integer(4), Long_Integer(1)));
               ALB_On_Paint_step_y := ALB_PURE_DIV(ALB_On_Paint_r_dy, ALB_PURE(Long_Integer(4), Long_Integer(1)));
               ALB_On_Paint_dir_x := ALB_PURE(Long_Integer(1), Long_Integer(1));
               if 
            (ALB_PURE_NUM(mx) < ALB_PURE_NUM(cx)) then
                  ALB_On_Paint_dir_x := ALB_PURE(Long_Integer(0), Long_Integer(1));
               end if;
               ALB_On_Paint_dir_y := ALB_PURE(Long_Integer(1), Long_Integer(1));
               if 
            (ALB_PURE_NUM(my) < ALB_PURE_NUM(cy)) then
                  ALB_On_Paint_dir_y := ALB_PURE(Long_Integer(0), Long_Integer(1));
               end if;
               ALB_On_Paint_n1x := cx;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_dir_x) = 1) then
                  ALB_On_Paint_n1x := ALB_PURE_ADD(ALB_On_Paint_n1x, ALB_On_Paint_step_x);
               else
                  ALB_On_Paint_n1x := ALB_PURE_SUB(ALB_On_Paint_n1x, ALB_On_Paint_step_x);
               end if;
               ALB_On_Paint_n1y := cy;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_dir_y) = 1) then
                  ALB_On_Paint_n1y := ALB_PURE_ADD(ALB_On_Paint_n1y, ALB_On_Paint_step_y);
               else
                  ALB_On_Paint_n1y := ALB_PURE_SUB(ALB_On_Paint_n1y, ALB_On_Paint_step_y);
               end if;
               ALB_On_Paint_n2x := ALB_On_Paint_n1x;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_dir_x) = 1) then
                  ALB_On_Paint_n2x := ALB_PURE_ADD(ALB_On_Paint_n2x, ALB_On_Paint_step_x);
               else
                  ALB_On_Paint_n2x := ALB_PURE_SUB(ALB_On_Paint_n2x, ALB_On_Paint_step_x);
               end if;
               ALB_On_Paint_n2y := ALB_On_Paint_n1y;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_dir_y) = 1) then
                  ALB_On_Paint_n2y := ALB_PURE_ADD(ALB_On_Paint_n2y, ALB_On_Paint_step_y);
               else
                  ALB_On_Paint_n2y := ALB_PURE_SUB(ALB_On_Paint_n2y, ALB_On_Paint_step_y);
               end if;
               ALB_On_Paint_n3x := ALB_On_Paint_n2x;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_dir_x) = 1) then
                  ALB_On_Paint_n3x := ALB_PURE_ADD(ALB_On_Paint_n3x, ALB_On_Paint_step_x);
               else
                  ALB_On_Paint_n3x := ALB_PURE_SUB(ALB_On_Paint_n3x, ALB_On_Paint_step_x);
               end if;
               ALB_On_Paint_n3y := ALB_On_Paint_n2y;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_dir_y) = 1) then
                  ALB_On_Paint_n3y := ALB_PURE_ADD(ALB_On_Paint_n3y, ALB_On_Paint_step_y);
               else
                  ALB_On_Paint_n3y := ALB_PURE_SUB(ALB_On_Paint_n3y, ALB_On_Paint_step_y);
               end if;
               ALB_On_Paint_j1x := ALB_PURE(Long_Integer(ALB_RND(20)), Long_Integer(1));
               ALB_On_Paint_j1y := ALB_PURE(Long_Integer(ALB_RND(20)), Long_Integer(1));
               ALB_On_Paint_j2x := ALB_PURE(Long_Integer(ALB_RND(20)), Long_Integer(1));
               ALB_On_Paint_j2y := ALB_PURE(Long_Integer(ALB_RND(20)), Long_Integer(1));
               ALB_On_Paint_j3x := ALB_PURE(Long_Integer(ALB_RND(20)), Long_Integer(1));
               ALB_On_Paint_j3y := ALB_PURE(Long_Integer(ALB_RND(20)), Long_Integer(1));
               ALB_On_Paint_p1x := ALB_On_Paint_n1x;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_j1x) > 10) then
                  ALB_On_Paint_p1x := ALB_PURE_ADD(ALB_On_Paint_p1x, ALB_PURE_SUB(ALB_On_Paint_j1x, ALB_PURE(Long_Integer(10), Long_Integer(1))));
               else
                  if 
               (ALB_PURE_NUM(ALB_On_Paint_p1x) >= ALB_PURE_NUM(ALB_On_Paint_j1x)) then
                     ALB_On_Paint_p1x := ALB_PURE_SUB(ALB_On_Paint_p1x, ALB_On_Paint_j1x);
                  else
                     ALB_On_Paint_p1x := ALB_PURE(Long_Integer(0), Long_Integer(1));
                  end if;
               end if;
               ALB_On_Paint_p1y := ALB_On_Paint_n1y;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_j1y) > 10) then
                  ALB_On_Paint_p1y := ALB_PURE_ADD(ALB_On_Paint_p1y, ALB_PURE_SUB(ALB_On_Paint_j1y, ALB_PURE(Long_Integer(10), Long_Integer(1))));
               else
                  if 
               (ALB_PURE_NUM(ALB_On_Paint_p1y) >= ALB_PURE_NUM(ALB_On_Paint_j1y)) then
                     ALB_On_Paint_p1y := ALB_PURE_SUB(ALB_On_Paint_p1y, ALB_On_Paint_j1y);
                  else
                     ALB_On_Paint_p1y := ALB_PURE(Long_Integer(0), Long_Integer(1));
                  end if;
               end if;
               ALB_On_Paint_p2x := ALB_On_Paint_n2x;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_j2x) > 10) then
                  ALB_On_Paint_p2x := ALB_PURE_ADD(ALB_On_Paint_p2x, ALB_PURE_SUB(ALB_On_Paint_j2x, ALB_PURE(Long_Integer(10), Long_Integer(1))));
               else
                  if 
               (ALB_PURE_NUM(ALB_On_Paint_p2x) >= ALB_PURE_NUM(ALB_On_Paint_j2x)) then
                     ALB_On_Paint_p2x := ALB_PURE_SUB(ALB_On_Paint_p2x, ALB_On_Paint_j2x);
                  else
                     ALB_On_Paint_p2x := ALB_PURE(Long_Integer(0), Long_Integer(1));
                  end if;
               end if;
               ALB_On_Paint_p2y := ALB_On_Paint_n2y;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_j2y) > 10) then
                  ALB_On_Paint_p2y := ALB_PURE_ADD(ALB_On_Paint_p2y, ALB_PURE_SUB(ALB_On_Paint_j2y, ALB_PURE(Long_Integer(10), Long_Integer(1))));
               else
                  if 
               (ALB_PURE_NUM(ALB_On_Paint_p2y) >= ALB_PURE_NUM(ALB_On_Paint_j2y)) then
                     ALB_On_Paint_p2y := ALB_PURE_SUB(ALB_On_Paint_p2y, ALB_On_Paint_j2y);
                  else
                     ALB_On_Paint_p2y := ALB_PURE(Long_Integer(0), Long_Integer(1));
                  end if;
               end if;
               ALB_On_Paint_p3x := ALB_On_Paint_n3x;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_j3x) > 10) then
                  ALB_On_Paint_p3x := ALB_PURE_ADD(ALB_On_Paint_p3x, ALB_PURE_SUB(ALB_On_Paint_j3x, ALB_PURE(Long_Integer(10), Long_Integer(1))));
               else
                  if 
               (ALB_PURE_NUM(ALB_On_Paint_p3x) >= ALB_PURE_NUM(ALB_On_Paint_j3x)) then
                     ALB_On_Paint_p3x := ALB_PURE_SUB(ALB_On_Paint_p3x, ALB_On_Paint_j3x);
                  else
                     ALB_On_Paint_p3x := ALB_PURE(Long_Integer(0), Long_Integer(1));
                  end if;
               end if;
               ALB_On_Paint_p3y := ALB_On_Paint_n3y;
               if 
            (ALB_PURE_NUM(ALB_On_Paint_j3y) > 10) then
                  ALB_On_Paint_p3y := ALB_PURE_ADD(ALB_On_Paint_p3y, ALB_PURE_SUB(ALB_On_Paint_j3y, ALB_PURE(Long_Integer(10), Long_Integer(1))));
               else
                  if 
               (ALB_PURE_NUM(ALB_On_Paint_p3y) >= ALB_PURE_NUM(ALB_On_Paint_j3y)) then
                     ALB_On_Paint_p3y := ALB_PURE_SUB(ALB_On_Paint_p3y, ALB_On_Paint_j3y);
                  else
                     ALB_On_Paint_p3y := ALB_PURE(Long_Integer(0), Long_Integer(1));
                  end if;
               end if;
               ALBA_Graphics.Set_Color(Integer(16#441188#));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(cx)), Integer(ALB_PURE_NUM(cy)), Integer(8));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p1x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1y)), Integer(8));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p2x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2y)), Integer(8));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p3x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3y)), Integer(8));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(mx)), Integer(ALB_PURE_NUM(my)), Integer(8));
               ALBA_Graphics.Set_Color(Integer(16#6666FF#));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(cx)), Integer(ALB_PURE_NUM(cy)), Integer(4));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p1x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1y)), Integer(4));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p2x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2y)), Integer(4));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p3x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3y)), Integer(4));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(mx)), Integer(ALB_PURE_NUM(my)), Integer(4));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(cx)), Integer(ALB_PURE_NUM(cy)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1y)));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(ALB_On_Paint_p1x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1y)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2y)));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(ALB_On_Paint_p2x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2y)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3y)));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(ALB_On_Paint_p3x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3y)), Integer(ALB_PURE_NUM(mx)), Integer(ALB_PURE_NUM(my)));
               ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(cx)), Integer(ALB_PURE_NUM(cy)), Integer(2));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p1x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1y)), Integer(2));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p2x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2y)), Integer(2));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(ALB_On_Paint_p3x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3y)), Integer(2));
               ALBA_Graphics.Fill_Circle(Integer(ALB_PURE_NUM(mx)), Integer(ALB_PURE_NUM(my)), Integer(2));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(cx)), Integer(ALB_PURE_NUM(cy)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1y)));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(ALB_On_Paint_p1x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p1y)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2y)));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(ALB_On_Paint_p2x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p2y)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3y)));
               ALBA_Graphics.Draw_Line(Integer(ALB_PURE_NUM(ALB_On_Paint_p3x)), Integer(ALB_PURE_NUM(ALB_On_Paint_p3y)), Integer(ALB_PURE_NUM(mx)), Integer(ALB_PURE_NUM(my)));
            end if;
         end if;
      end if;
   end ALB_On_Paint;

begin
   ALBA_Graphics.Initialize("Dielectric Sim", Natural(Integer(320)), Natural(Integer(200)), Graphics_OK);
   app_state := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_STORE_PURE(Positive(8), app_state);
   sim_mode := ALB_PURE(Long_Integer(1), Long_Integer(1));
   ALB_STORE_PURE(Positive(24), sim_mode);
   volt := ALB_PURE(Long_Integer(150), Long_Integer(1));
   ALB_STORE_PURE(Positive(40), volt);
   dist := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_STORE_PURE(Positive(56), dist);
   is_arcing := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_STORE_PURE(Positive(72), is_arcing);
   cx := ALB_PURE(Long_Integer(160), Long_Integer(1));
   ALB_STORE_PURE(Positive(88), cx);
   cy := ALB_PURE(Long_Integer(180), Long_Integer(1));
   ALB_STORE_PURE(Positive(104), cy);
   mx := ALB_PURE(Long_Integer(160), Long_Integer(1));
   ALB_STORE_PURE(Positive(120), mx);
   my := ALB_PURE(Long_Integer(50), Long_Integer(1));
   ALB_STORE_PURE(Positive(136), my);
   prev_click := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_STORE_PURE(Positive(152), prev_click);
   cap_timer := ALB_PURE(Long_Integer(0), Long_Integer(1));
   ALB_STORE_PURE(Positive(168), cap_timer);
   while ALBA_Graphics.Window_Open loop
      ALBA_Graphics.Process_Events;
      ALB_On_Tick;
      ALB_On_Paint;
      ALBA_Graphics.Present;
   end loop;
   ALBA_Graphics.Shutdown;
   ALBA_Audio.Shutdown;
end ARC;

