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

with Ada.Unchecked_Conversion;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body ALBA_Graphics is

   pragma Linker_Options ("-lkernel32");

   use Interfaces;
   use Interfaces.C;
   use Interfaces.C.Strings;
   use type System.Address;
   use type Unsigned_32;

   subtype C_Int   is Interfaces.C.int;
   subtype C_Float is Interfaces.C.C_float;
   subtype Uint8   is Interfaces.Unsigned_8;
   subtype Uint32  is Interfaces.Unsigned_32;
   subtype DWORD   is Interfaces.Unsigned_32;
   subtype SDL_Bool is Interfaces.C.int;

   SDL_INIT_AUDIO : constant Uint32 := 16#0000_0010#;
   SDL_INIT_VIDEO : constant Uint32 := 16#0000_0020#;

   SDL_EVENT_QUIT : constant Uint32 := 16#0000_0100#;

   SDL_BLENDMODE_NONE  : constant C_Int := 0;
   SDL_BLENDMODE_BLEND : constant C_Int := 1;

   type SDL_Rect is record
      X : C_Int := 0;
      Y : C_Int := 0;
      W : C_Int := 0;
      H : C_Int := 0;
   end record
     with Convention => C;

   type SDL_FRect is record
      X : C_Float := 0.0;
      Y : C_Float := 0.0;
      W : C_Float := 0.0;
      H : C_Float := 0.0;
   end record
     with Convention => C;

   type Key_State_Buffer is array (Natural range 0 .. 255) of aliased Uint8;
   type Key_State_Buffer_Access is access all Key_State_Buffer;

   type Event_Buffer_Array is array (Natural range 0 .. 255) of aliased Uint8;

   type SDL_Init_Fn is access function (Flags : Uint32) return SDL_Bool
     with Convention => C;
   type SDL_Quit_Fn is access procedure
     with Convention => C;
   type SDL_CreateWindowAndRenderer_Fn is access function
     (Title        : System.Address;
      Width        : C_Int;
      Height       : C_Int;
      Flags        : Uint32;
      Window_Out   : access System.Address;
      Renderer_Out : access System.Address) return SDL_Bool
     with Convention => C;
   type SDL_PollEvent_Fn is access function (Event_Ptr : System.Address) return SDL_Bool
     with Convention => C;
   type SDL_GetKeyboardState_Fn is access function (Numkeys : access C_Int) return System.Address
     with Convention => C;
   type SDL_GetMouseState_Fn is access function (X : access C_Float; Y : access C_Float) return Uint32
     with Convention => C;
   type SDL_GetCurrentRenderOutputSize_Fn is access function
     (Renderer : System.Address;
      Width    : access C_Int;
      Height   : access C_Int) return SDL_Bool
     with Convention => C;
   type SDL_SetRenderDrawColor_Fn is access function
     (Renderer : System.Address;
      R        : Uint8;
      G        : Uint8;
      B        : Uint8;
      A        : Uint8) return SDL_Bool
     with Convention => C;
   type SDL_RenderClear_Fn is access function (Renderer : System.Address) return SDL_Bool
     with Convention => C;
   type SDL_RenderPresent_Fn is access procedure (Renderer : System.Address)
     with Convention => C;
   type SDL_DestroyRenderer_Fn is access procedure (Renderer : System.Address)
     with Convention => C;
   type SDL_DestroyWindow_Fn is access procedure (Window : System.Address)
     with Convention => C;
   type SDL_SetWindowResizable_Fn is access function
     (Window    : System.Address;
      Resizable : SDL_Bool) return SDL_Bool
     with Convention => C;
   type SDL_SetWindowFullscreen_Fn is access function
     (Window     : System.Address;
      Fullscreen : SDL_Bool) return SDL_Bool
     with Convention => C;
   type SDL_RenderRect_Fn is access function
     (Renderer : System.Address;
      Rect     : access SDL_FRect) return SDL_Bool
     with Convention => C;
   type SDL_RenderFillRect_Fn is access function
     (Renderer : System.Address;
      Rect     : access SDL_FRect) return SDL_Bool
     with Convention => C;
   type SDL_RenderLine_Fn is access function
     (Renderer : System.Address;
      X1       : C_Float;
      Y1       : C_Float;
      X2       : C_Float;
      Y2       : C_Float) return SDL_Bool
     with Convention => C;
   type SDL_RenderPoint_Fn is access function
     (Renderer : System.Address;
      X        : C_Float;
      Y        : C_Float) return SDL_Bool
     with Convention => C;
   type SDL_RenderDebugText_Fn is access function
     (Renderer : System.Address;
      X        : C_Float;
      Y        : C_Float;
      Text     : System.Address) return SDL_Bool
     with Convention => C;
   type SDL_SetRenderClipRect_Fn is access function
     (Renderer : System.Address;
      Rect     : access SDL_Rect) return SDL_Bool
     with Convention => C;
   type SDL_SetRenderDrawBlendMode_Fn is access function
     (Renderer : System.Address;
      Mode     : C_Int) return SDL_Bool
     with Convention => C;
   type SDL_RenderReadPixels_Fn is access function
     (Renderer : System.Address;
      Rect     : access SDL_Rect) return System.Address
     with Convention => C;
   type SDL_ReadSurfacePixel_Fn is access function
     (Surface : System.Address;
      X       : C_Int;
      Y       : C_Int;
      R       : access Uint8;
      G       : access Uint8;
      B       : access Uint8;
      A       : access Uint8) return SDL_Bool
     with Convention => C;
   type SDL_DestroySurface_Fn is access procedure (Surface : System.Address)
     with Convention => C;
   type SDL_Delay_Fn is access procedure (Milliseconds : Uint32)
     with Convention => C;

   function To_Key_State_Buffer_Access is new Ada.Unchecked_Conversion
     (System.Address, Key_State_Buffer_Access);
   function To_SDL_Init is new Ada.Unchecked_Conversion (System.Address, SDL_Init_Fn);
   function To_SDL_Quit is new Ada.Unchecked_Conversion (System.Address, SDL_Quit_Fn);
   function To_SDL_CreateWindowAndRenderer is new Ada.Unchecked_Conversion
     (System.Address, SDL_CreateWindowAndRenderer_Fn);
   function To_SDL_PollEvent is new Ada.Unchecked_Conversion (System.Address, SDL_PollEvent_Fn);
   function To_SDL_GetKeyboardState is new Ada.Unchecked_Conversion
     (System.Address, SDL_GetKeyboardState_Fn);
   function To_SDL_GetMouseState is new Ada.Unchecked_Conversion
     (System.Address, SDL_GetMouseState_Fn);
   function To_SDL_GetCurrentRenderOutputSize is new Ada.Unchecked_Conversion
     (System.Address, SDL_GetCurrentRenderOutputSize_Fn);
   function To_SDL_SetRenderDrawColor is new Ada.Unchecked_Conversion
     (System.Address, SDL_SetRenderDrawColor_Fn);
   function To_SDL_RenderClear is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderClear_Fn);
   function To_SDL_RenderPresent is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderPresent_Fn);
   function To_SDL_DestroyRenderer is new Ada.Unchecked_Conversion
     (System.Address, SDL_DestroyRenderer_Fn);
   function To_SDL_DestroyWindow is new Ada.Unchecked_Conversion
     (System.Address, SDL_DestroyWindow_Fn);
   function To_SDL_SetWindowResizable is new Ada.Unchecked_Conversion
     (System.Address, SDL_SetWindowResizable_Fn);
   function To_SDL_SetWindowFullscreen is new Ada.Unchecked_Conversion
     (System.Address, SDL_SetWindowFullscreen_Fn);
   function To_SDL_RenderRect is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderRect_Fn);
   function To_SDL_RenderFillRect is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderFillRect_Fn);
   function To_SDL_RenderLine is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderLine_Fn);
   function To_SDL_RenderPoint is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderPoint_Fn);
   function To_SDL_RenderDebugText is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderDebugText_Fn);
   function To_SDL_SetRenderClipRect is new Ada.Unchecked_Conversion
     (System.Address, SDL_SetRenderClipRect_Fn);
   function To_SDL_SetRenderDrawBlendMode is new Ada.Unchecked_Conversion
     (System.Address, SDL_SetRenderDrawBlendMode_Fn);
   function To_SDL_RenderReadPixels is new Ada.Unchecked_Conversion
     (System.Address, SDL_RenderReadPixels_Fn);
   function To_SDL_ReadSurfacePixel is new Ada.Unchecked_Conversion
     (System.Address, SDL_ReadSurfacePixel_Fn);
   function To_SDL_DestroySurface is new Ada.Unchecked_Conversion
     (System.Address, SDL_DestroySurface_Fn);
   function To_SDL_Delay is new Ada.Unchecked_Conversion (System.Address, SDL_Delay_Fn);

   function LoadLibraryA (LpLibFileName : chars_ptr) return System.Address;
   pragma Import (Stdcall, LoadLibraryA, "LoadLibraryA");

   function GetProcAddress
     (HModule   : System.Address;
      LpProcName : chars_ptr) return System.Address;
   pragma Import (Stdcall, GetProcAddress, "GetProcAddress");

   procedure Sleep (DwMilliseconds : DWORD);
   pragma Import (Stdcall, Sleep, "Sleep");

   function GetTickCount return DWORD;
   pragma Import (Stdcall, GetTickCount, "GetTickCount");

   SDL_Library : System.Address := System.Null_Address;

   SDL_Init_Ptr                     : SDL_Init_Fn := null;
   SDL_Quit_Ptr                     : SDL_Quit_Fn := null;
   SDL_CreateWindowAndRenderer_Ptr  : SDL_CreateWindowAndRenderer_Fn := null;
   SDL_PollEvent_Ptr                : SDL_PollEvent_Fn := null;
   SDL_GetKeyboardState_Ptr         : SDL_GetKeyboardState_Fn := null;
   SDL_GetMouseState_Ptr            : SDL_GetMouseState_Fn := null;
   SDL_GetCurrentRenderOutputSize_Ptr : SDL_GetCurrentRenderOutputSize_Fn := null;
   SDL_SetRenderDrawColor_Ptr       : SDL_SetRenderDrawColor_Fn := null;
   SDL_RenderClear_Ptr              : SDL_RenderClear_Fn := null;
   SDL_RenderPresent_Ptr            : SDL_RenderPresent_Fn := null;
   SDL_DestroyRenderer_Ptr          : SDL_DestroyRenderer_Fn := null;
   SDL_DestroyWindow_Ptr            : SDL_DestroyWindow_Fn := null;
   SDL_SetWindowResizable_Ptr       : SDL_SetWindowResizable_Fn := null;
   SDL_SetWindowFullscreen_Ptr      : SDL_SetWindowFullscreen_Fn := null;
   SDL_RenderRect_Ptr               : SDL_RenderRect_Fn := null;
   SDL_RenderFillRect_Ptr           : SDL_RenderFillRect_Fn := null;
   SDL_RenderLine_Ptr               : SDL_RenderLine_Fn := null;
   SDL_RenderPoint_Ptr              : SDL_RenderPoint_Fn := null;
   SDL_RenderDebugText_Ptr          : SDL_RenderDebugText_Fn := null;
   SDL_SetRenderClipRect_Ptr        : SDL_SetRenderClipRect_Fn := null;
   SDL_SetRenderDrawBlendMode_Ptr   : SDL_SetRenderDrawBlendMode_Fn := null;
   SDL_RenderReadPixels_Ptr         : SDL_RenderReadPixels_Fn := null;
   SDL_ReadSurfacePixel_Ptr         : SDL_ReadSurfacePixel_Fn := null;
   SDL_DestroySurface_Ptr           : SDL_DestroySurface_Fn := null;
   SDL_Delay_Ptr                    : SDL_Delay_Fn := null;

   Window_Handle    : System.Address := System.Null_Address;
   Renderer_Handle  : System.Address := System.Null_Address;
   Initialized      : Boolean := False;
   Close_Requested  : Boolean := False;
   Current_Color    : Natural := 16#FFFFFF#;
   Alpha_Channel    : Integer := 0;
   Alpha_Value      : Uint8 := 255;
   Origin_X_Pos     : Integer := 0;
   Origin_Y_Pos     : Integer := 0;
   Clip_Enabled     : Boolean := False;
   Clip_X_Pos       : Integer := 0;
   Clip_Y_Pos       : Integer := 0;
   Clip_W_Px        : Integer := 0;
   Clip_H_Px        : Integer := 0;
   Base_Width_Px    : Natural := 1;
   Base_Height_Px   : Natural := 1;
   Screen_Width_Px  : Natural := 1;
   Screen_Height_Px : Natural := 1;
   Virtual_Width_Px : Natural := 1;
   Virtual_Height_Px : Natural := 1;
   Content_Offset_X : Integer := 0;
   Content_Offset_Y : Integer := 0;
   Target_Frame_Millis : constant Natural := 16;
   Last_Present_Tick   : Natural := 0;
   Mouse_X_Pos      : Integer := 0;
   Mouse_Y_Pos      : Integer := 0;
   Virtual_Mouse_X_Pos : Integer := 0;
   Virtual_Mouse_Y_Pos : Integer := 0;
   Mouse_Button_Mask : Uint32 := 0;
   Key_Event_Flag   : Boolean := False;
   Key_Map          : array (Natural range 0 .. 255) of Boolean := (others => False);
   Event_Buffer     : aliased Event_Buffer_Array := (others => 0);
   Fullscreen_Enabled : Boolean := False;
   Resizable_Enabled  : Boolean := False;
   Stretchy_Enabled   : Boolean := False;

   procedure Ignore (Value : SDL_Bool) is
   begin
      null;
   end Ignore;

   function Clamp_Byte (Value : Integer) return Uint8 is
   begin
      if Value < 0 then
         return 0;
      elsif Value > 255 then
         return 255;
      else
         return Uint8 (Value);
      end if;
   end Clamp_Byte;

   function To_Float (Value : Integer) return C_Float is
   begin
      return C_Float (Value);
   end To_Float;

   function To_Int (Value : C_Float) return Integer is
   begin
      return Integer (Float (Value));
   end To_Int;

   function To_SDL_Bool (Value : Boolean) return SDL_Bool is
   begin
      if Value then
         return 1;
      else
         return 0;
      end if;
   end To_SDL_Bool;

   procedure Normalize_Rect
     (X : in out Integer;
      Y : in out Integer;
      W : in out Integer;
      H : in out Integer)
   is
   begin
      if W < 0 then
         X := X + W;
         W := -W;
      end if;
      if H < 0 then
         Y := Y + H;
         H := -H;
      end if;
   end Normalize_Rect;

   function Event_Type return Uint32 is
   begin
      return Uint32 (Event_Buffer (0))
        or Interfaces.Shift_Left (Uint32 (Event_Buffer (1)), 8)
        or Interfaces.Shift_Left (Uint32 (Event_Buffer (2)), 16)
        or Interfaces.Shift_Left (Uint32 (Event_Buffer (3)), 24);
   end Event_Type;

   procedure Refresh_Presentation is
   begin
      if Stretchy_Enabled then
         Virtual_Width_Px := Natural'Max (1, Base_Width_Px);
         Virtual_Height_Px := Natural'Max (1, Base_Height_Px);
         Content_Offset_X := 0;
         Content_Offset_Y := 0;
      else
         Virtual_Width_Px := Natural'Max (1, Base_Width_Px);
         Virtual_Height_Px := Natural'Max (1, Base_Height_Px);
         if Screen_Width_Px > Base_Width_Px then
            Content_Offset_X :=
              Integer ((Long_Long_Integer (Screen_Width_Px) - Long_Long_Integer (Base_Width_Px)) / 2);
         else
            Content_Offset_X := 0;
         end if;
         if Screen_Height_Px > Base_Height_Px then
            Content_Offset_Y :=
              Integer ((Long_Long_Integer (Screen_Height_Px) - Long_Long_Integer (Base_Height_Px)) / 2);
         else
            Content_Offset_Y := 0;
         end if;
      end if;
   end Refresh_Presentation;

   function Scale_To_Screen
     (Value    : Integer;
      Screen   : Natural;
      Virtual  : Natural) return Integer
   is
      Numerator : constant Long_Long_Integer :=
        Long_Long_Integer (Value) * Long_Long_Integer (Screen);
      Denom     : constant Long_Long_Integer :=
        Long_Long_Integer (Natural'Max (1, Virtual));
   begin
      return Integer (Numerator / Denom);
   end Scale_To_Screen;

   function Scale_From_Screen
     (Value    : Integer;
      Screen   : Natural;
      Virtual  : Natural) return Integer
   is
      Numerator : constant Long_Long_Integer :=
        Long_Long_Integer (Value) * Long_Long_Integer (Natural'Max (1, Virtual));
      Denom     : constant Long_Long_Integer :=
        Long_Long_Integer (Natural'Max (1, Screen));
   begin
      return Integer (Numerator / Denom);
   end Scale_From_Screen;

   function Map_Render_X (Value : Integer) return Integer is
   begin
      if Stretchy_Enabled then
         return
           Scale_To_Screen
             (Value + Origin_X_Pos,
              Screen_Width_Px,
              Virtual_Width_Px);
      else
         return Value + Origin_X_Pos + Content_Offset_X;
      end if;
   end Map_Render_X;

   function Map_Render_Y (Value : Integer) return Integer is
   begin
      if Stretchy_Enabled then
         return
           Scale_To_Screen
             (Value + Origin_Y_Pos,
              Screen_Height_Px,
              Virtual_Height_Px);
      else
         return Value + Origin_Y_Pos + Content_Offset_Y;
      end if;
   end Map_Render_Y;

   function Clamp_To_Virtual (Value : Integer; Limit : Natural) return Integer is
      Max_Value : Integer := 0;
   begin
      if Limit = 0 then
         return 0;
      end if;

      Max_Value := Integer (Limit) - 1;
      if Value < 0 then
         return 0;
      elsif Value > Max_Value then
         return Max_Value;
      else
         return Value;
      end if;
   end Clamp_To_Virtual;

   function Load_SDL_Library return Boolean is
      function Try_Path (Path : String) return System.Address is
         C_Path : chars_ptr := New_String (Path);
         Value  : System.Address := System.Null_Address;
      begin
         Value := LoadLibraryA (C_Path);
         Free (C_Path);
         return Value;
      end Try_Path;
   begin
      if SDL_Library /= System.Null_Address then
         return True;
      end if;

      SDL_Library := Try_Path ("SDL3.dll");
      if SDL_Library = System.Null_Address then
         SDL_Library := Try_Path ("..\obj\SDL3.dll");
      end if;
      if SDL_Library = System.Null_Address then
         SDL_Library := Try_Path ("obj\SDL3.dll");
      end if;
      return SDL_Library /= System.Null_Address;
   end Load_SDL_Library;

   function Load_Symbol (Name : String) return System.Address is
      C_Name : chars_ptr := New_String (Name);
      Value  : System.Address := System.Null_Address;
   begin
      if SDL_Library = System.Null_Address then
         Free (C_Name);
         return System.Null_Address;
      end if;

      Value := GetProcAddress (SDL_Library, C_Name);
      Free (C_Name);
      return Value;
   end Load_Symbol;

   function Bind_SDL return Boolean is
   begin
      if not Load_SDL_Library then
         return False;
      end if;

      SDL_Init_Ptr := To_SDL_Init (Load_Symbol ("SDL_Init"));
      SDL_Quit_Ptr := To_SDL_Quit (Load_Symbol ("SDL_Quit"));
      SDL_CreateWindowAndRenderer_Ptr :=
        To_SDL_CreateWindowAndRenderer (Load_Symbol ("SDL_CreateWindowAndRenderer"));
      SDL_PollEvent_Ptr := To_SDL_PollEvent (Load_Symbol ("SDL_PollEvent"));
      SDL_GetKeyboardState_Ptr := To_SDL_GetKeyboardState (Load_Symbol ("SDL_GetKeyboardState"));
      SDL_GetMouseState_Ptr := To_SDL_GetMouseState (Load_Symbol ("SDL_GetMouseState"));
      SDL_GetCurrentRenderOutputSize_Ptr :=
        To_SDL_GetCurrentRenderOutputSize (Load_Symbol ("SDL_GetCurrentRenderOutputSize"));
      SDL_SetRenderDrawColor_Ptr :=
        To_SDL_SetRenderDrawColor (Load_Symbol ("SDL_SetRenderDrawColor"));
      SDL_RenderClear_Ptr := To_SDL_RenderClear (Load_Symbol ("SDL_RenderClear"));
      SDL_RenderPresent_Ptr := To_SDL_RenderPresent (Load_Symbol ("SDL_RenderPresent"));
      SDL_DestroyRenderer_Ptr := To_SDL_DestroyRenderer (Load_Symbol ("SDL_DestroyRenderer"));
      SDL_DestroyWindow_Ptr := To_SDL_DestroyWindow (Load_Symbol ("SDL_DestroyWindow"));
      SDL_SetWindowResizable_Ptr :=
        To_SDL_SetWindowResizable (Load_Symbol ("SDL_SetWindowResizable"));
      SDL_SetWindowFullscreen_Ptr :=
        To_SDL_SetWindowFullscreen (Load_Symbol ("SDL_SetWindowFullscreen"));
      SDL_RenderRect_Ptr := To_SDL_RenderRect (Load_Symbol ("SDL_RenderRect"));
      SDL_RenderFillRect_Ptr := To_SDL_RenderFillRect (Load_Symbol ("SDL_RenderFillRect"));
      SDL_RenderLine_Ptr := To_SDL_RenderLine (Load_Symbol ("SDL_RenderLine"));
      SDL_RenderPoint_Ptr := To_SDL_RenderPoint (Load_Symbol ("SDL_RenderPoint"));
      SDL_RenderDebugText_Ptr := To_SDL_RenderDebugText (Load_Symbol ("SDL_RenderDebugText"));
      SDL_SetRenderClipRect_Ptr := To_SDL_SetRenderClipRect (Load_Symbol ("SDL_SetRenderClipRect"));
      SDL_SetRenderDrawBlendMode_Ptr :=
        To_SDL_SetRenderDrawBlendMode (Load_Symbol ("SDL_SetRenderDrawBlendMode"));
      SDL_RenderReadPixels_Ptr := To_SDL_RenderReadPixels (Load_Symbol ("SDL_RenderReadPixels"));
      SDL_ReadSurfacePixel_Ptr := To_SDL_ReadSurfacePixel (Load_Symbol ("SDL_ReadSurfacePixel"));
      SDL_DestroySurface_Ptr := To_SDL_DestroySurface (Load_Symbol ("SDL_DestroySurface"));
      SDL_Delay_Ptr := To_SDL_Delay (Load_Symbol ("SDL_Delay"));

      return
        SDL_Init_Ptr /= null
        and then SDL_Quit_Ptr /= null
        and then SDL_CreateWindowAndRenderer_Ptr /= null
        and then SDL_PollEvent_Ptr /= null
        and then SDL_GetKeyboardState_Ptr /= null
        and then SDL_GetMouseState_Ptr /= null
        and then SDL_GetCurrentRenderOutputSize_Ptr /= null
        and then SDL_SetRenderDrawColor_Ptr /= null
        and then SDL_RenderClear_Ptr /= null
        and then SDL_RenderPresent_Ptr /= null
        and then SDL_DestroyRenderer_Ptr /= null
        and then SDL_DestroyWindow_Ptr /= null
        and then SDL_RenderRect_Ptr /= null
        and then SDL_RenderFillRect_Ptr /= null
        and then SDL_RenderLine_Ptr /= null
        and then SDL_RenderPoint_Ptr /= null
        and then SDL_RenderDebugText_Ptr /= null
        and then SDL_SetRenderClipRect_Ptr /= null
        and then SDL_SetRenderDrawBlendMode_Ptr /= null;
   end Bind_SDL;

   procedure Apply_Clip;

   procedure Refresh_Output_State is
      Width  : aliased C_Int := 0;
      Height : aliased C_Int := 0;
   begin
      if Renderer_Handle = System.Null_Address
        or else SDL_GetCurrentRenderOutputSize_Ptr = null
      then
         return;
      end if;

      if SDL_GetCurrentRenderOutputSize_Ptr
        (Renderer_Handle, Width'Access, Height'Access) /= 0
      then
         if Integer (Width) > 0 then
            Screen_Width_Px := Natural (Integer (Width));
         else
            Screen_Width_Px := 1;
         end if;

         if Integer (Height) > 0 then
            Screen_Height_Px := Natural (Integer (Height));
         else
            Screen_Height_Px := 1;
         end if;

         Refresh_Presentation;
      end if;
   end Refresh_Output_State;

   procedure Refresh_Input_State is
      Count      : aliased C_Int := 0;
      State_Addr : System.Address := System.Null_Address;
      State      : Key_State_Buffer_Access := null;
      Mouse_X_F  : aliased C_Float := 0.0;
      Mouse_Y_F  : aliased C_Float := 0.0;
      New_State  : Boolean := False;
      Raw_Mouse_X : Integer := 0;
      Raw_Mouse_Y : Integer := 0;
   begin
      Key_Event_Flag := False;

      if SDL_GetKeyboardState_Ptr /= null then
         State_Addr := SDL_GetKeyboardState_Ptr (Count'Access);
         if State_Addr /= System.Null_Address then
            State := To_Key_State_Buffer_Access (State_Addr);
            for I in Key_Map'Range loop
               New_State := State (I) /= 0;
               if New_State and then not Key_Map (I) then
                  Key_Event_Flag := True;
               end if;
               Key_Map (I) := New_State;
            end loop;
         end if;
      end if;

      if SDL_GetMouseState_Ptr /= null then
         Mouse_Button_Mask := SDL_GetMouseState_Ptr (Mouse_X_F'Access, Mouse_Y_F'Access);
         Raw_Mouse_X := To_Int (Mouse_X_F);
         Raw_Mouse_Y := To_Int (Mouse_Y_F);
         Mouse_X_Pos := Raw_Mouse_X;
         Mouse_Y_Pos := Raw_Mouse_Y;
         if Stretchy_Enabled then
            Virtual_Mouse_X_Pos :=
              Clamp_To_Virtual
                (Scale_From_Screen
                   (Raw_Mouse_X,
                    Screen_Width_Px,
                    Virtual_Width_Px),
                 Virtual_Width_Px);
            Virtual_Mouse_Y_Pos :=
              Clamp_To_Virtual
                (Scale_From_Screen
                   (Raw_Mouse_Y,
                    Screen_Height_Px,
                    Virtual_Height_Px),
                 Virtual_Height_Px);
         else
            Virtual_Mouse_X_Pos :=
              Clamp_To_Virtual (Raw_Mouse_X - Content_Offset_X, Virtual_Width_Px);
            Virtual_Mouse_Y_Pos :=
              Clamp_To_Virtual (Raw_Mouse_Y - Content_Offset_Y, Virtual_Height_Px);
         end if;
      end if;
   end Refresh_Input_State;

   procedure Apply_Color_Value (RGB : Natural) is
      R : constant Uint8 := Uint8 ((RGB / 16#10000#) mod 16#100#);
      G : constant Uint8 := Uint8 ((RGB / 16#100#) mod 16#100#);
      B : constant Uint8 := Uint8 (RGB mod 16#100#);
      A : Uint8 := Uint8 ((RGB / 16#1000000#) mod 16#100#);
   begin
      if Renderer_Handle = System.Null_Address or else SDL_SetRenderDrawColor_Ptr = null then
         return;
      end if;

      if A = 0 then
         if Alpha_Channel > 0 then
            A := Alpha_Value;
         else
            A := 255;
         end if;
      end if;

      Ignore (SDL_SetRenderDrawColor_Ptr (Renderer_Handle, R, G, B, A));
   end Apply_Color_Value;

   procedure Apply_Current_Color is
   begin
      Apply_Color_Value (Current_Color);
   end Apply_Current_Color;

   procedure Apply_Clip is
      Rect : aliased SDL_Rect;
   begin
      if Renderer_Handle = System.Null_Address or else SDL_SetRenderClipRect_Ptr = null then
         return;
      end if;

      if not Clip_Enabled then
         Ignore (SDL_SetRenderClipRect_Ptr (Renderer_Handle, null));
         return;
      end if;

      Rect :=
        (X => C_Int (Map_Render_X (Clip_X_Pos)),
         Y => C_Int (Map_Render_Y (Clip_Y_Pos)),
         W => C_Int (Integer'Max (1, Map_Render_X (Clip_X_Pos + Clip_W_Px) - Map_Render_X (Clip_X_Pos))),
         H => C_Int (Integer'Max (1, Map_Render_Y (Clip_Y_Pos + Clip_H_Px) - Map_Render_Y (Clip_Y_Pos))));
      Ignore (SDL_SetRenderClipRect_Ptr (Renderer_Handle, Rect'Access));
   end Apply_Clip;

   procedure Render_Point_Raw (X : Integer; Y : Integer) is
   begin
      if Renderer_Handle = System.Null_Address or else SDL_RenderPoint_Ptr = null then
         return;
      end if;

      Ignore (SDL_RenderPoint_Ptr (Renderer_Handle, To_Float (X), To_Float (Y)));
   end Render_Point_Raw;

   procedure Render_Line_Raw
     (X1 : Integer;
      Y1 : Integer;
      X2 : Integer;
      Y2 : Integer)
   is
   begin
      if Renderer_Handle = System.Null_Address or else SDL_RenderLine_Ptr = null then
         return;
      end if;

      Ignore
        (SDL_RenderLine_Ptr
           (Renderer_Handle,
            To_Float (X1),
            To_Float (Y1),
            To_Float (X2),
            To_Float (Y2)));
   end Render_Line_Raw;

   procedure Initialize
     (Title   : in String;
      Width   : in Natural;
      Height  : in Natural;
      Success : out Boolean)
   is
      C_Title : aliased Interfaces.C.char_array := Interfaces.C.To_C (Title);
      Win     : aliased System.Address := System.Null_Address;
      Ren     : aliased System.Address := System.Null_Address;
   begin
      Shutdown;
      Success := False;

      if not Bind_SDL then
         return;
      end if;

      if SDL_Init_Ptr (SDL_INIT_VIDEO) = 0 then
         return;
      end if;

      Ignore (SDL_Init_Ptr (SDL_INIT_AUDIO));

      if SDL_CreateWindowAndRenderer_Ptr
        (C_Title (C_Title'First)'Address,
         C_Int (Natural'Max (1, Width)),
         C_Int (Natural'Max (1, Height)),
         0,
         Win'Access,
         Ren'Access) = 0
      then
         if SDL_Quit_Ptr /= null then
            SDL_Quit_Ptr.all;
         end if;
         return;
      end if;

      Window_Handle := Win;
      Renderer_Handle := Ren;
      Initialized := True;
      Close_Requested := False;
      Current_Color := 16#FFFFFF#;
      Alpha_Channel := 0;
      Alpha_Value := 255;
      Origin_X_Pos := 0;
      Origin_Y_Pos := 0;
      Clip_Enabled := False;
      Clip_X_Pos := 0;
      Clip_Y_Pos := 0;
      Clip_W_Px := 0;
      Clip_H_Px := 0;
      Mouse_X_Pos := 0;
      Mouse_Y_Pos := 0;
      Virtual_Mouse_X_Pos := 0;
      Virtual_Mouse_Y_Pos := 0;
      Mouse_Button_Mask := 0;
      Key_Event_Flag := False;
      Key_Map := (others => False);

      Base_Width_Px := Natural'Max (1, Width);
      Base_Height_Px := Natural'Max (1, Height);
      Screen_Width_Px := Base_Width_Px;
      Screen_Height_Px := Base_Height_Px;
      Refresh_Presentation;
      Last_Present_Tick := 0;

      if SDL_SetWindowResizable_Ptr /= null then
         Ignore
           (SDL_SetWindowResizable_Ptr
              (Window_Handle, To_SDL_Bool (Resizable_Enabled)));
      end if;
      if SDL_SetWindowFullscreen_Ptr /= null then
         Ignore
           (SDL_SetWindowFullscreen_Ptr
              (Window_Handle, To_SDL_Bool (Fullscreen_Enabled)));
      end if;

      Refresh_Output_State;
      Apply_Clip;
      Success := True;
   end Initialize;

   procedure Shutdown is
   begin
      if Renderer_Handle /= System.Null_Address and then SDL_DestroyRenderer_Ptr /= null then
         SDL_DestroyRenderer_Ptr.all (Renderer_Handle);
      end if;

      if Window_Handle /= System.Null_Address and then SDL_DestroyWindow_Ptr /= null then
         SDL_DestroyWindow_Ptr.all (Window_Handle);
      end if;

      if Initialized and then SDL_Quit_Ptr /= null then
         SDL_Quit_Ptr.all;
      end if;

      Window_Handle := System.Null_Address;
      Renderer_Handle := System.Null_Address;
      Initialized := False;
      Close_Requested := False;
      Current_Color := 16#FFFFFF#;
      Alpha_Channel := 0;
      Alpha_Value := 255;
      Origin_X_Pos := 0;
      Origin_Y_Pos := 0;
      Clip_Enabled := False;
      Clip_X_Pos := 0;
      Clip_Y_Pos := 0;
      Clip_W_Px := 0;
      Clip_H_Px := 0;
      Base_Width_Px := 1;
      Base_Height_Px := 1;
      Screen_Width_Px := 1;
      Screen_Height_Px := 1;
      Virtual_Width_Px := 1;
      Virtual_Height_Px := 1;
      Content_Offset_X := 0;
      Content_Offset_Y := 0;
      Last_Present_Tick := 0;
      Mouse_X_Pos := 0;
      Mouse_Y_Pos := 0;
      Virtual_Mouse_X_Pos := 0;
      Virtual_Mouse_Y_Pos := 0;
      Mouse_Button_Mask := 0;
      Key_Event_Flag := False;
      Key_Map := (others => False);
      Event_Buffer := (others => 0);
   end Shutdown;

   procedure Set_Fullscreen (Enabled : in Boolean) is
   begin
      Fullscreen_Enabled := Enabled;
      if Window_Handle /= System.Null_Address
        and then SDL_SetWindowFullscreen_Ptr /= null
      then
         Ignore
           (SDL_SetWindowFullscreen_Ptr
              (Window_Handle, To_SDL_Bool (Enabled)));
         Refresh_Output_State;
      end if;
   end Set_Fullscreen;

   procedure Set_Resizable (Enabled : in Boolean) is
   begin
      Resizable_Enabled := Enabled;
      if Window_Handle /= System.Null_Address
        and then SDL_SetWindowResizable_Ptr /= null
      then
         Ignore
           (SDL_SetWindowResizable_Ptr
              (Window_Handle, To_SDL_Bool (Enabled)));
         Refresh_Output_State;
      end if;
   end Set_Resizable;

   procedure Set_Stretchy (Enabled : in Boolean) is
   begin
      Stretchy_Enabled := Enabled;
      Refresh_Presentation;
      Apply_Clip;
   end Set_Stretchy;

   function Window_Open return Boolean is
   begin
      return Initialized and then not Close_Requested and then Renderer_Handle /= System.Null_Address;
   end Window_Open;

   procedure Request_Close is
   begin
      Close_Requested := True;
   end Request_Close;

   function Pending_Key_Event return Boolean is
   begin
      return Key_Event_Flag;
   end Pending_Key_Event;

   procedure Process_Events is
   begin
      if not Window_Open or else SDL_PollEvent_Ptr = null then
         return;
      end if;

      while SDL_PollEvent_Ptr (Event_Buffer (0)'Address) /= 0 loop
         if Event_Type = SDL_EVENT_QUIT then
            Close_Requested := True;
         end if;
      end loop;

      Refresh_Output_State;
      Refresh_Input_State;
   end Process_Events;

   procedure Present is
      Now_Tick     : Natural := 0;
      Elapsed      : Natural := 0;
      Delay_Amount : Natural := 0;
   begin
      if not Window_Open or else SDL_RenderPresent_Ptr = null then
         return;
      end if;

      Now_Tick := Monotonic_Millis;
      if Last_Present_Tick /= 0 and then Now_Tick >= Last_Present_Tick then
         Elapsed := Now_Tick - Last_Present_Tick;
         if Elapsed < Target_Frame_Millis then
            Delay_Amount := Target_Frame_Millis - Elapsed;
            Pause_For (Delay_Amount);
         end if;
      end if;

      SDL_RenderPresent_Ptr.all (Renderer_Handle);
      Last_Present_Tick := Monotonic_Millis;
   end Present;

   procedure Pause_For (Milliseconds : in Natural) is
   begin
      if SDL_Delay_Ptr /= null then
         SDL_Delay_Ptr.all (Uint32 (Milliseconds));
      else
         Sleep (DWORD (Milliseconds));
      end if;
   end Pause_For;

   function Monotonic_Millis return Natural is
   begin
      return Natural (GetTickCount);
   end Monotonic_Millis;

   function Virtual_Width return Natural is
   begin
      return Virtual_Width_Px;
   end Virtual_Width;

   function Virtual_Height return Natural is
   begin
      return Virtual_Height_Px;
   end Virtual_Height;

   procedure Set_Color (RGB : in Natural) is
   begin
      Current_Color := RGB;
   end Set_Color;

   procedure Clear (RGB : in Natural) is
   begin
      if not Window_Open or else SDL_RenderClear_Ptr = null then
         return;
      end if;

      Apply_Color_Value (RGB);
      Ignore (SDL_RenderClear_Ptr (Renderer_Handle));
   end Clear;

   procedure Draw_Rect
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer)
   is
      Draw_X : Integer := Map_Render_X (X);
      Draw_Y : Integer := Map_Render_Y (Y);
      Draw_W : Integer := Map_Render_X (X + W) - Draw_X;
      Draw_H : Integer := Map_Render_Y (Y + H) - Draw_Y;
      Rect   : aliased SDL_FRect;
   begin
      if not Window_Open or else SDL_RenderRect_Ptr = null then
         return;
      end if;

      Normalize_Rect (Draw_X, Draw_Y, Draw_W, Draw_H);
      if Draw_W <= 0 or else Draw_H <= 0 then
         return;
      end if;

      Apply_Current_Color;
      Rect :=
        (X => To_Float (Draw_X),
         Y => To_Float (Draw_Y),
         W => To_Float (Draw_W),
         H => To_Float (Draw_H));
      Ignore (SDL_RenderRect_Ptr (Renderer_Handle, Rect'Access));
   end Draw_Rect;

   procedure Fill_Rect
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer)
   is
      Draw_X : Integer := Map_Render_X (X);
      Draw_Y : Integer := Map_Render_Y (Y);
      Draw_W : Integer := Map_Render_X (X + W) - Draw_X;
      Draw_H : Integer := Map_Render_Y (Y + H) - Draw_Y;
      Rect   : aliased SDL_FRect;
   begin
      if not Window_Open or else SDL_RenderFillRect_Ptr = null then
         return;
      end if;

      Normalize_Rect (Draw_X, Draw_Y, Draw_W, Draw_H);
      if Draw_W <= 0 or else Draw_H <= 0 then
         return;
      end if;

      Apply_Current_Color;
      Rect :=
        (X => To_Float (Draw_X),
         Y => To_Float (Draw_Y),
         W => To_Float (Draw_W),
         H => To_Float (Draw_H));
      Ignore (SDL_RenderFillRect_Ptr (Renderer_Handle, Rect'Access));
   end Fill_Rect;

   procedure Draw_Line
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer)
   is
   begin
      if not Window_Open then
         return;
      end if;

      Apply_Current_Color;
      Render_Line_Raw
        (Map_Render_X (X1),
         Map_Render_Y (Y1),
         Map_Render_X (X2),
         Map_Render_Y (Y2));
   end Draw_Line;

   procedure Draw_Circle
     (CX     : in Integer;
      CY     : in Integer;
      Radius : in Integer)
   is
      X       : Integer := 0;
      Y       : Integer := Radius;
      D       : Integer := 3 - 2 * Radius;
   begin
      if not Window_Open or else Radius < 0 then
         return;
      end if;

      Apply_Current_Color;
      while Y >= X and then X <= 8192 loop
         Render_Point_Raw (Map_Render_X (CX + X), Map_Render_Y (CY + Y));
         Render_Point_Raw (Map_Render_X (CX - X), Map_Render_Y (CY + Y));
         Render_Point_Raw (Map_Render_X (CX + X), Map_Render_Y (CY - Y));
         Render_Point_Raw (Map_Render_X (CX - X), Map_Render_Y (CY - Y));
         Render_Point_Raw (Map_Render_X (CX + Y), Map_Render_Y (CY + X));
         Render_Point_Raw (Map_Render_X (CX - Y), Map_Render_Y (CY + X));
         Render_Point_Raw (Map_Render_X (CX + Y), Map_Render_Y (CY - X));
         Render_Point_Raw (Map_Render_X (CX - Y), Map_Render_Y (CY - X));

         X := X + 1;
         if D > 0 then
            Y := Y - 1;
            D := D + 4 * (X - Y) + 10;
         else
            D := D + 4 * X + 6;
         end if;
      end loop;
   end Draw_Circle;

   procedure Fill_Circle
     (CX     : in Integer;
      CY     : in Integer;
      Radius : in Integer)
   is
      X       : Integer := 0;
      Y       : Integer := Radius;
      D       : Integer := 3 - 2 * Radius;
   begin
      if not Window_Open or else Radius < 0 then
         return;
      end if;

      Apply_Current_Color;
      while Y >= X and then X <= 8192 loop
         Render_Line_Raw
           (Map_Render_X (CX - X),
            Map_Render_Y (CY + Y),
            Map_Render_X (CX + X),
            Map_Render_Y (CY + Y));
         Render_Line_Raw
           (Map_Render_X (CX - X),
            Map_Render_Y (CY - Y),
            Map_Render_X (CX + X),
            Map_Render_Y (CY - Y));
         Render_Line_Raw
           (Map_Render_X (CX - Y),
            Map_Render_Y (CY + X),
            Map_Render_X (CX + Y),
            Map_Render_Y (CY + X));
         Render_Line_Raw
           (Map_Render_X (CX - Y),
            Map_Render_Y (CY - X),
            Map_Render_X (CX + Y),
            Map_Render_Y (CY - X));

         X := X + 1;
         if D > 0 then
            Y := Y - 1;
            D := D + 4 * (X - Y) + 10;
         else
            D := D + 4 * X + 6;
         end if;
      end loop;
   end Fill_Circle;

   procedure Draw_Triangle
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer;
      X3 : in Integer;
      Y3 : in Integer)
   is
   begin
      if not Window_Open then
         return;
      end if;

      Apply_Current_Color;
      Render_Line_Raw (Map_Render_X (X1), Map_Render_Y (Y1), Map_Render_X (X2), Map_Render_Y (Y2));
      Render_Line_Raw (Map_Render_X (X2), Map_Render_Y (Y2), Map_Render_X (X3), Map_Render_Y (Y3));
      Render_Line_Raw (Map_Render_X (X3), Map_Render_Y (Y3), Map_Render_X (X1), Map_Render_Y (Y1));
   end Draw_Triangle;

   function Edge_Func
     (X1 : Integer;
      Y1 : Integer;
      X2 : Integer;
      Y2 : Integer;
      X3 : Integer;
      Y3 : Integer) return Integer
   is
   begin
      return (X3 - X1) * (Y2 - Y1) - (Y3 - Y1) * (X2 - X1);
   end Edge_Func;

   procedure Fill_Triangle
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer;
      X3 : in Integer;
      Y3 : in Integer)
   is
      AX : constant Integer := Map_Render_X (X1);
      AY : constant Integer := Map_Render_Y (Y1);
      BX : constant Integer := Map_Render_X (X2);
      BY : constant Integer := Map_Render_Y (Y2);
      CXI : constant Integer := Map_Render_X (X3);
      CYI : constant Integer := Map_Render_Y (Y3);
      Min_X : Integer := Integer'Min (AX, Integer'Min (BX, CXI));
      Min_Y : Integer := Integer'Min (AY, Integer'Min (BY, CYI));
      Max_X : Integer := Integer'Max (AX, Integer'Max (BX, CXI));
      Max_Y : Integer := Integer'Max (AY, Integer'Max (BY, CYI));
      W0 : Integer := 0;
      W1 : Integer := 0;
      W2 : Integer := 0;
   begin
      if not Window_Open then
         return;
      end if;

      if Min_X < 0 then
         Min_X := 0;
      end if;
      if Min_Y < 0 then
         Min_Y := 0;
      end if;
      if Max_X > Integer (Screen_Width_Px) + 8192 then
         Max_X := Integer (Screen_Width_Px) + 8192;
      end if;
      if Max_Y > Integer (Screen_Height_Px) + 8192 then
         Max_Y := Integer (Screen_Height_Px) + 8192;
      end if;

      Apply_Current_Color;
      for Y in Min_Y .. Max_Y loop
         for X in Min_X .. Max_X loop
            W0 := Edge_Func (BX, BY, CXI, CYI, X, Y);
            W1 := Edge_Func (CXI, CYI, AX, AY, X, Y);
            W2 := Edge_Func (AX, AY, BX, BY, X, Y);
            if (W0 >= 0 and then W1 >= 0 and then W2 >= 0)
              or else (W0 <= 0 and then W1 <= 0 and then W2 <= 0)
            then
               Render_Point_Raw (X, Y);
            end if;
         end loop;
      end loop;
   end Fill_Triangle;

   procedure Plot
     (X : in Integer;
      Y : in Integer)
   is
   begin
      if not Window_Open then
         return;
      end if;

      Apply_Current_Color;
      Render_Point_Raw (Map_Render_X (X), Map_Render_Y (Y));
   end Plot;

   procedure Draw_Text
     (X    : in Integer;
      Y    : in Integer;
      Text : in String)
   is
      Start    : Integer := Text'First;
      Cursor_Y : Integer := Map_Render_Y (Y);

      procedure Render_Line (Line : String; Draw_Y : Integer) is
         C_Text : aliased Interfaces.C.char_array := Interfaces.C.To_C (Line);
      begin
         if Line'Length = 0 then
            return;
         end if;

         Ignore
           (SDL_RenderDebugText_Ptr
              (Renderer_Handle,
               To_Float (Map_Render_X (X)),
               To_Float (Draw_Y),
               C_Text (C_Text'First)'Address));
      end Render_Line;
   begin
      if not Window_Open or else SDL_RenderDebugText_Ptr = null or else Text'Length = 0 then
         return;
      end if;

      Apply_Current_Color;

      for I in Text'Range loop
         if Text (I) = ASCII.LF then
            if I > Start then
               Render_Line (Text (Start .. I - 1), Cursor_Y);
            end if;
            Start := I + 1;
            Cursor_Y := Cursor_Y + 10;
         end if;
      end loop;

      if Start <= Text'Last then
         Render_Line (Text (Start .. Text'Last), Cursor_Y);
      end if;
   end Draw_Text;

   procedure Set_Alpha
     (Channel : in Integer;
      Value   : in Integer)
   is
      Mode : C_Int := SDL_BLENDMODE_NONE;
   begin
      Alpha_Channel := Channel;
      Alpha_Value := Clamp_Byte (Value);

      if Alpha_Channel > 0 then
         Mode := SDL_BLENDMODE_BLEND;
      end if;

      if Window_Open and then SDL_SetRenderDrawBlendMode_Ptr /= null then
         Ignore (SDL_SetRenderDrawBlendMode_Ptr (Renderer_Handle, Mode));
      end if;
   end Set_Alpha;

   procedure Set_Clip
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer)
   is
   begin
      if W <= 0 or else H <= 0 then
         Clip_Enabled := False;
         Clip_X_Pos := 0;
         Clip_Y_Pos := 0;
         Clip_W_Px := 0;
         Clip_H_Px := 0;
      else
         Clip_Enabled := True;
         Clip_X_Pos := X;
         Clip_Y_Pos := Y;
         Clip_W_Px := W;
         Clip_H_Px := H;
      end if;

      Apply_Clip;
   end Set_Clip;

   procedure Set_Origin
     (X : in Integer;
      Y : in Integer)
   is
   begin
      Origin_X_Pos := X;
      Origin_Y_Pos := Y;
      Apply_Clip;
   end Set_Origin;

   function Key_Down (Code : in Integer) return Boolean is
   begin
      if Code in Key_Map'Range then
         return Key_Map (Code);
      else
         return False;
      end if;
   end Key_Down;

   function Mouse_X return Integer is
   begin
      return Mouse_X_Pos;
   end Mouse_X;

   function Mouse_Y return Integer is
   begin
      return Mouse_Y_Pos;
   end Mouse_Y;

   function VMouse_X return Integer is
   begin
      return Virtual_Mouse_X_Pos;
   end VMouse_X;

   function VMouse_Y return Integer is
   begin
      return Virtual_Mouse_Y_Pos;
   end VMouse_Y;

   function Mouse_Click (Button : in Integer) return Integer is
   begin
      if Button < 0 or else Button > 31 then
         return 0;
      elsif (Mouse_Button_Mask and Interfaces.Shift_Left (Uint32 (1), Button)) /= 0 then
         return 1;
      else
         return 0;
      end if;
   end Mouse_Click;

   function Read_Pixel
     (X : in Integer;
      Y : in Integer) return Natural
   is
      Rect    : aliased SDL_Rect;
      Surface : System.Address := System.Null_Address;
      R       : aliased Uint8 := 0;
      G       : aliased Uint8 := 0;
      B       : aliased Uint8 := 0;
      A       : aliased Uint8 := 0;
      Result  : Natural := 0;
   begin
      if not Window_Open
        or else SDL_RenderReadPixels_Ptr = null
        or else SDL_ReadSurfacePixel_Ptr = null
      then
         return 0;
      end if;

      Rect :=
        (X => C_Int (Map_Render_X (X)),
         Y => C_Int (Map_Render_Y (Y)),
         W => 1,
         H => 1);
      Surface := SDL_RenderReadPixels_Ptr (Renderer_Handle, Rect'Access);
      if Surface = System.Null_Address then
         return 0;
      end if;

      Ignore (SDL_ReadSurfacePixel_Ptr (Surface, 0, 0, R'Access, G'Access, B'Access, A'Access));
      if SDL_DestroySurface_Ptr /= null then
         SDL_DestroySurface_Ptr.all (Surface);
      end if;

      Result :=
        Natural (A) * 16#1000000#
        + Natural (R) * 16#10000#
        + Natural (G) * 16#100#
        + Natural (B);
      return Result;
   end Read_Pixel;

end ALBA_Graphics;
