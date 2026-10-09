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

procedure test_window_flags is
   Graphics_OK : Boolean := False;
   ALBA_User_Error : exception;
   ALBA_Last_Error : ALB_Text := ALB_STR("");
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
      ALB_POKE(Address, Raw_Value);
   end ALBA_Poke_Address;

   procedure ALB_On_Paint is
   begin
      ALBA_Graphics.Clear(Integer(16#000000#));
      ALBA_Graphics.Set_Color(Integer(16#FFFFFF#));
      ALBA_Graphics.Draw_Rect(Integer(0), Integer(0), Integer((S32(ALBA_Graphics.Virtual_Width) - 1)), Integer((S32(ALBA_Graphics.Virtual_Height) - 1)));
      ALBA_Graphics.Draw_Text(Integer(8), Integer(8), ALB_TO_STRING(ALB_STR("WINDOW FLAGS TEST")));
   end ALB_On_Paint;

begin
   ALBA_Graphics.Initialize("WINDOW FLAGS TEST", 320, 200, Graphics_OK);
   ALBA_Graphics.Set_Fullscreen(False);
   ALBA_Graphics.Set_Resizable(True);
   ALBA_Graphics.Set_Stretchy(False);
   while ALBA_Graphics.Window_Open loop
      ALBA_Graphics.Process_Events;
      ALB_On_Paint;
      ALBA_Graphics.Present;
   end loop;
   ALBA_Graphics.Shutdown;
   ALBA_Audio.Shutdown;
end test_window_flags;

