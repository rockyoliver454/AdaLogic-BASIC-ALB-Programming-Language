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

with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body ALB_Graphics is

   pragma Linker_Options ("-luser32");
   pragma Linker_Options ("-lgdi32");
   pragma Linker_Options ("-lkernel32");

   use Interfaces.C;
   use Interfaces.C.Strings;
   use type System.Address;

   subtype BOOL  is Interfaces.C.int;
   subtype INT   is Interfaces.C.int;
   subtype LONG  is Interfaces.C.long;
   subtype SHORT is Interfaces.C.short;

   type DWORD is mod 2 ** 32;
   for DWORD'Size use 32;

   type UINT is mod 2 ** 32;
   for UINT'Size use 32;

   type COLORREF is mod 2 ** 32;
   for COLORREF'Size use 32;

   type UINT_PTR is mod 2 ** Standard'Address_Size;
   for UINT_PTR'Size use Standard'Address_Size;

   subtype LRESULT is Interfaces.C.long_long;

   type POINT is record
      X : LONG := 0;
      Y : LONG := 0;
   end record;
   pragma Convention (C_Pass_By_Copy, POINT);

   type RECT is record
      Left   : LONG := 0;
      Top    : LONG := 0;
      Right  : LONG := 0;
      Bottom : LONG := 0;
   end record;
   pragma Convention (C_Pass_By_Copy, RECT);

   type MSG is record
      Hwnd     : System.Address := System.Null_Address;
      Message  : UINT := 0;
      WParam   : UINT_PTR := 0;
      LParam   : UINT_PTR := 0;
      Time     : DWORD := 0;
      Pt       : POINT := (X => 0, Y => 0);
      LPrivate : DWORD := 0;
   end record;
   pragma Convention (C_Pass_By_Copy, MSG);

   type Point_Array is array (Natural range <>) of aliased POINT;
   pragma Convention (C, Point_Array);

   function AdjustWindowRectEx
     (LpRect    : access RECT;
      DwStyle   : DWORD;
      BMenu     : BOOL;
      DwExStyle : DWORD) return BOOL;
   pragma Import (Stdcall, AdjustWindowRectEx, "AdjustWindowRectEx");

   function CreateWindowExA
     (DwExStyle    : DWORD;
      LpClassName  : chars_ptr;
      LpWindowName : chars_ptr;
      DwStyle      : DWORD;
      X            : INT;
      Y            : INT;
      NWidth       : INT;
      NHeight      : INT;
      HWndParent   : System.Address;
      HMenu        : System.Address;
      HInstance    : System.Address;
      LpParam      : System.Address) return System.Address;
   pragma Import (Stdcall, CreateWindowExA, "CreateWindowExA");

   function DestroyWindow (HWnd : System.Address) return BOOL;
   pragma Import (Stdcall, DestroyWindow, "DestroyWindow");

   function ShowWindow (HWnd : System.Address; NCmdShow : INT) return BOOL;
   pragma Import (Stdcall, ShowWindow, "ShowWindow");

   function UpdateWindow (HWnd : System.Address) return BOOL;
   pragma Import (Stdcall, UpdateWindow, "UpdateWindow");

   function GetModuleHandleA (LpModuleName : chars_ptr) return System.Address;
   pragma Import (Stdcall, GetModuleHandleA, "GetModuleHandleA");

   function IsWindow (HWnd : System.Address) return BOOL;
   pragma Import (Stdcall, IsWindow, "IsWindow");

   function PeekMessageA
     (LpMsg          : access MSG;
      HWnd           : System.Address;
      WMsgFilterMin  : UINT;
      WMsgFilterMax  : UINT;
      WRemoveMsg     : UINT) return BOOL;
   pragma Import (Stdcall, PeekMessageA, "PeekMessageA");

   function TranslateMessage (LpMsg : access MSG) return BOOL;
   pragma Import (Stdcall, TranslateMessage, "TranslateMessage");

   function DispatchMessageA (LpMsg : access MSG) return LRESULT;
   pragma Import (Stdcall, DispatchMessageA, "DispatchMessageA");

   function GetDC (HWnd : System.Address) return System.Address;
   pragma Import (Stdcall, GetDC, "GetDC");

   function ReleaseDC
     (HWnd : System.Address;
      HDC  : System.Address) return INT;
   pragma Import (Stdcall, ReleaseDC, "ReleaseDC");

   function CreateCompatibleDC (HDC : System.Address) return System.Address;
   pragma Import (Stdcall, CreateCompatibleDC, "CreateCompatibleDC");

   function DeleteDC (HDC : System.Address) return BOOL;
   pragma Import (Stdcall, DeleteDC, "DeleteDC");

   function CreateCompatibleBitmap
     (HDC : System.Address;
      CX  : INT;
      CY  : INT) return System.Address;
   pragma Import (Stdcall, CreateCompatibleBitmap, "CreateCompatibleBitmap");

   function SelectObject
     (HDC     : System.Address;
      HGDIObj : System.Address) return System.Address;
   pragma Import (Stdcall, SelectObject, "SelectObject");

   function DeleteObject (HObject : System.Address) return BOOL;
   pragma Import (Stdcall, DeleteObject, "DeleteObject");

   function CreateSolidBrush (CrColor : COLORREF) return System.Address;
   pragma Import (Stdcall, CreateSolidBrush, "CreateSolidBrush");

   function CreatePen
     (IStyle : INT;
      CWidth : INT;
      Color  : COLORREF) return System.Address;
   pragma Import (Stdcall, CreatePen, "CreatePen");

   function GetStockObject (I : INT) return System.Address;
   pragma Import (Stdcall, GetStockObject, "GetStockObject");

   function FillRect
     (HDC  : System.Address;
      Lprc : access RECT;
      Hbr  : System.Address) return INT;
   pragma Import (Stdcall, FillRect, "FillRect");

   function Rectangle
     (HDC    : System.Address;
      Left   : INT;
      Top    : INT;
      Right  : INT;
      Bottom : INT) return BOOL;
   pragma Import (Stdcall, Rectangle, "Rectangle");

   function MoveToEx
     (HDC     : System.Address;
      X       : INT;
      Y       : INT;
      LpPoint : System.Address) return BOOL;
   pragma Import (Stdcall, MoveToEx, "MoveToEx");

   function LineTo
     (HDC : System.Address;
      X   : INT;
      Y   : INT) return BOOL;
   pragma Import (Stdcall, LineTo, "LineTo");

   function Ellipse
     (HDC    : System.Address;
      Left   : INT;
      Top    : INT;
      Right  : INT;
      Bottom : INT) return BOOL;
   pragma Import (Stdcall, Ellipse, "Ellipse");

   function Polygon
     (HDC : System.Address;
      Apt : access POINT;
      Cpt : INT) return BOOL;
   pragma Import (Stdcall, Polygon, "Polygon");

   function SetPixelV
     (HDC   : System.Address;
      X     : INT;
      Y     : INT;
      Color : COLORREF) return BOOL;
   pragma Import (Stdcall, SetPixelV, "SetPixelV");

   function GetPixel
     (HDC : System.Address;
      X   : INT;
      Y   : INT) return COLORREF;
   pragma Import (Stdcall, GetPixel, "GetPixel");

   function TextOutA
     (HDC      : System.Address;
      X        : INT;
      Y        : INT;
      LpString : chars_ptr;
      C        : INT) return BOOL;
   pragma Import (Stdcall, TextOutA, "TextOutA");

   function SetTextColor
     (HDC   : System.Address;
      Color : COLORREF) return COLORREF;
   pragma Import (Stdcall, SetTextColor, "SetTextColor");

   function SetBkMode
     (HDC  : System.Address;
      Mode : INT) return INT;
   pragma Import (Stdcall, SetBkMode, "SetBkMode");

   function BitBlt
     (HdcDest : System.Address;
      XDest   : INT;
      YDest   : INT;
      Width   : INT;
      Height  : INT;
      HdcSrc  : System.Address;
      XSrc    : INT;
      YSrc    : INT;
      Rop     : DWORD) return BOOL;
   pragma Import (Stdcall, BitBlt, "BitBlt");

   function CreateRectRgn
     (Left   : INT;
      Top    : INT;
      Right  : INT;
      Bottom : INT) return System.Address;
   pragma Import (Stdcall, CreateRectRgn, "CreateRectRgn");

   function SelectClipRgn
     (HDC  : System.Address;
      HRgn : System.Address) return INT;
   pragma Import (Stdcall, SelectClipRgn, "SelectClipRgn");

   function GetCursorPos (LpPoint : access POINT) return BOOL;
   pragma Import (Stdcall, GetCursorPos, "GetCursorPos");

   function ScreenToClient
     (HWnd    : System.Address;
      LpPoint : access POINT) return BOOL;
   pragma Import (Stdcall, ScreenToClient, "ScreenToClient");

   function GetAsyncKeyState (VKey : INT) return SHORT;
   pragma Import (Stdcall, GetAsyncKeyState, "GetAsyncKeyState");

   procedure Sleep (DwMilliseconds : DWORD);
   pragma Import (Stdcall, Sleep, "Sleep");

   function GetTickCount return DWORD;
   pragma Import (Stdcall, GetTickCount, "GetTickCount");

   Window_Style : constant DWORD := 16#10CF0000#;
   PM_REMOVE    : constant UINT  := 1;
   WM_QUIT      : constant UINT  := 16#0012#;
   WM_MOUSEMOVE   : constant UINT := 16#0200#;
   WM_LBUTTONDOWN : constant UINT := 16#0201#;
   WM_LBUTTONUP   : constant UINT := 16#0202#;
   WM_RBUTTONDOWN : constant UINT := 16#0204#;
   WM_RBUTTONUP   : constant UINT := 16#0205#;
   WM_MBUTTONDOWN : constant UINT := 16#0207#;
   WM_MBUTTONUP   : constant UINT := 16#0208#;
   SRCCOPY      : constant DWORD := 16#00CC0020#;
   SW_SHOWNORMAL : constant INT  := 1;
   PS_SOLID     : constant INT   := 0;
   TRANSPARENT  : constant INT   := 1;
   NULL_BRUSH   : constant INT   := 5;
   NULL_PEN     : constant INT   := 8;

   VK_LEFT    : constant INT := 16#25#;
   VK_UP      : constant INT := 16#26#;
   VK_RIGHT   : constant INT := 16#27#;
   VK_DOWN    : constant INT := 16#28#;
   VK_SPACE   : constant INT := 16#20#;
   VK_RETURN  : constant INT := 16#0D#;
   VK_ESCAPE  : constant INT := 16#1B#;
   VK_SHIFT   : constant INT := 16#10#;
   VK_CONTROL : constant INT := 16#11#;
   VK_MENU    : constant INT := 16#12#;
   VK_LBUTTON : constant INT := 16#01#;
   VK_RBUTTON : constant INT := 16#02#;
   VK_MBUTTON : constant INT := 16#04#;

   Window_Handle  : System.Address := System.Null_Address;
   Memory_DC      : System.Address := System.Null_Address;
   Surface_Bitmap : System.Address := System.Null_Address;
   Old_Bitmap     : System.Address := System.Null_Address;
   Is_Ready       : Boolean := False;
   Close_Requested : Boolean := False;
   Width_Px       : Natural := 0;
   Height_Px      : Natural := 0;
   Current_Color  : COLORREF := 0;
   Origin_X       : Integer := 0;
   Origin_Y       : Integer := 0;
   Clip_Enabled   : Boolean := False;
   Clip_X         : Integer := 0;
   Clip_Y         : Integer := 0;
   Clip_W         : Integer := 0;
   Clip_H         : Integer := 0;
   Alpha_Channel  : Integer := 1;
   Alpha_Value    : Integer := 255;
   Mouse_X_Pos    : Integer := 0;
   Mouse_Y_Pos    : Integer := 0;
   Key_Event_Flag : Boolean := False;

   type Key_State_Array is array (0 .. 255) of Boolean;
   type Mouse_State_Array is array (0 .. 2) of Boolean;

   Key_Is_Down   : Key_State_Array := (others => False);
   Mouse_Is_Down : Mouse_State_Array := (others => False);
   Mouse_Pressed : Mouse_State_Array := (others => False);

   function Decode_Mouse_Coord
     (Packed : UINT_PTR;
      Shift  : Natural) return Integer
   is
      Raw : constant Integer :=
        Integer ((Packed / UINT_PTR (2 ** Shift)) mod UINT_PTR (2 ** 16));
   begin
      if Raw >= 16#8000# then
         return Raw - 16#10000#;
      else
         return Raw;
      end if;
   end Decode_Mouse_Coord;

   function Mouse_LParam_X (Packed : UINT_PTR) return Integer is
   begin
      return Decode_Mouse_Coord (Packed, 0);
   end Mouse_LParam_X;

   function Mouse_LParam_Y (Packed : UINT_PTR) return Integer is
   begin
      return Decode_Mouse_Coord (Packed, 16);
   end Mouse_LParam_Y;

   procedure Ignore (Value : Interfaces.C.int) is
   begin
      null;
   end Ignore;

   procedure Ignore (Value : LRESULT) is
   begin
      null;
   end Ignore;

   procedure Ignore (Value : COLORREF) is
   begin
      null;
   end Ignore;

   procedure Ignore (Value : System.Address) is
   begin
      null;
   end Ignore;

   function To_Colorref (RGB : Natural) return COLORREF is
      R : constant Natural := (RGB / 16#10000#) mod 16#100#;
      G : constant Natural := (RGB / 16#100#) mod 16#100#;
      B : constant Natural := RGB mod 16#100#;
   begin
      return COLORREF (R + G * 16#100# + B * 16#10000#);
   end To_Colorref;

   function To_RGB (Value : COLORREF) return Natural is
      Raw : constant Natural := Natural (Value);
      R   : constant Natural := Raw mod 16#100#;
      G   : constant Natural := (Raw / 16#100#) mod 16#100#;
      B   : constant Natural := (Raw / 16#10000#) mod 16#100#;
   begin
      return R * 16#10000# + G * 16#100# + B;
   end To_RGB;

   function Map_Key_Code (Code : Integer) return INT is
   begin
      if Code in 4 .. 29 then
         return INT (Character'Pos ('A') + (Code - 4));
      elsif Code in 30 .. 38 then
         return INT (Character'Pos ('1') + (Code - 30));
      elsif Code = 39 then
         return INT (Character'Pos ('0'));
      end if;

      case Code is
         when 40 =>
            return VK_RETURN;
         when 41 =>
            return VK_ESCAPE;
         when 44 =>
            return VK_SPACE;
         when 79 =>
            return VK_RIGHT;
         when 80 =>
            return VK_LEFT;
         when 81 =>
            return VK_DOWN;
         when 82 =>
            return VK_UP;
         when 224 | 228 =>
            return VK_CONTROL;
         when 225 | 229 =>
            return VK_SHIFT;
         when 226 | 230 =>
            return VK_MENU;
         when others =>
            if Code in 0 .. 255 then
               return INT (Code);
            else
               return 0;
            end if;
      end case;
   end Map_Key_Code;

   procedure Apply_Clip is
      Region : System.Address := System.Null_Address;
      Left   : Integer := 0;
      Top    : Integer := 0;
      Right  : Integer := 0;
      Bottom : Integer := 0;
   begin
      if Memory_DC = System.Null_Address then
         return;
      end if;

      if not Clip_Enabled then
         Ignore (SelectClipRgn (Memory_DC, System.Null_Address));
         return;
      end if;

      Left := Clip_X + Origin_X;
      Top := Clip_Y + Origin_Y;
      Right := Left + Clip_W;
      Bottom := Top + Clip_H;
      Region :=
        CreateRectRgn
          (INT (Left),
           INT (Top),
           INT (Right),
           INT (Bottom));
      if Region /= System.Null_Address then
         Ignore (SelectClipRgn (Memory_DC, Region));
         Ignore (DeleteObject (Region));
      end if;
   end Apply_Clip;

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

   procedure Fill_Rect_With_Color
     (X     : in Integer;
      Y     : in Integer;
      W     : in Integer;
      H     : in Integer;
      Color : in COLORREF)
   is
      Draw_X : Integer := X + Origin_X;
      Draw_Y : Integer := Y + Origin_Y;
      Draw_W : Integer := W;
      Draw_H : Integer := H;
      Area   : aliased RECT;
      Brush  : System.Address := System.Null_Address;
   begin
      if Memory_DC = System.Null_Address then
         return;
      end if;

      Normalize_Rect (Draw_X, Draw_Y, Draw_W, Draw_H);
      if Draw_W <= 0 or else Draw_H <= 0 then
         return;
      end if;

      Area :=
        (Left   => LONG (Draw_X),
         Top    => LONG (Draw_Y),
         Right  => LONG (Draw_X + Draw_W),
         Bottom => LONG (Draw_Y + Draw_H));
      Brush := CreateSolidBrush (Color);
      if Brush /= System.Null_Address then
         Ignore (FillRect (Memory_DC, Area'Access, Brush));
         Ignore (DeleteObject (Brush));
      end if;
   end Fill_Rect_With_Color;

   procedure Select_Pen_And_Brush
     (Filled    : in Boolean;
      Brush_Clr : in COLORREF;
      Pen_Clr   : in COLORREF;
      Pen       : out System.Address;
      Brush     : out System.Address;
      Old_Pen   : out System.Address;
      Old_Brush : out System.Address)
   is
   begin
      Pen := CreatePen (PS_SOLID, 1, Pen_Clr);
      if Filled then
         Brush := CreateSolidBrush (Brush_Clr);
      else
         Brush := GetStockObject (NULL_BRUSH);
      end if;

      if Pen /= System.Null_Address then
         Old_Pen := SelectObject (Memory_DC, Pen);
      else
         Old_Pen := System.Null_Address;
      end if;

      if Brush /= System.Null_Address then
         Old_Brush := SelectObject (Memory_DC, Brush);
      else
         Old_Brush := System.Null_Address;
      end if;
   end Select_Pen_And_Brush;

   procedure Restore_Pen_And_Brush
     (Pen       : in System.Address;
      Brush     : in System.Address;
      Old_Pen   : in System.Address;
      Old_Brush : in System.Address;
      Filled    : in Boolean)
   is
   begin
      if Old_Pen /= System.Null_Address then
         Ignore (SelectObject (Memory_DC, Old_Pen));
      end if;
      if Old_Brush /= System.Null_Address then
         Ignore (SelectObject (Memory_DC, Old_Brush));
      end if;

      if Pen /= System.Null_Address then
         Ignore (DeleteObject (Pen));
      end if;
      if Filled and then Brush /= System.Null_Address then
         Ignore (DeleteObject (Brush));
      end if;
   end Restore_Pen_And_Brush;

   procedure Initialize
     (Title   : in String;
      Width   : in Natural;
      Height  : in Natural;
      Success : out Boolean)
   is
      Class_Name  : chars_ptr := New_String ("STATIC");
      Window_Name : chars_ptr := New_String (Title);
      Module      : System.Address := System.Null_Address;
      Window_DC   : System.Address := System.Null_Address;
      Bounds      : aliased RECT :=
        (Left => 0,
         Top => 0,
         Right => LONG (Integer'Max (1, Integer (Width))),
         Bottom => LONG (Integer'Max (1, Integer (Height))));
      Outer_W     : INT := INT (Integer'Max (1, Integer (Width)));
      Outer_H     : INT := INT (Integer'Max (1, Integer (Height)));
   begin
      Shutdown;
      Success := False;

      Ignore (AdjustWindowRectEx (Bounds'Access, Window_Style, 0, 0));
      Outer_W := INT (Integer (Bounds.Right - Bounds.Left));
      Outer_H := INT (Integer (Bounds.Bottom - Bounds.Top));

      Module := GetModuleHandleA (Null_Ptr);
      Window_Handle :=
        CreateWindowExA
          (DwExStyle    => 0,
           LpClassName  => Class_Name,
           LpWindowName => Window_Name,
           DwStyle      => Window_Style,
           X            => 100,
           Y            => 100,
           NWidth       => Outer_W,
           NHeight      => Outer_H,
           HWndParent   => System.Null_Address,
           HMenu        => System.Null_Address,
           HInstance    => Module,
           LpParam      => System.Null_Address);
      Free (Class_Name);
      Free (Window_Name);

      if Window_Handle = System.Null_Address then
         return;
      end if;

      Ignore (ShowWindow (Window_Handle, SW_SHOWNORMAL));
      Ignore (UpdateWindow (Window_Handle));

      Window_DC := GetDC (Window_Handle);
      if Window_DC = System.Null_Address then
         Shutdown;
         return;
      end if;

      Memory_DC := CreateCompatibleDC (Window_DC);
      if Memory_DC = System.Null_Address then
         Ignore (ReleaseDC (Window_Handle, Window_DC));
         Shutdown;
         return;
      end if;

      Surface_Bitmap :=
        CreateCompatibleBitmap
          (Window_DC,
           INT (Integer'Max (1, Integer (Width))),
           INT (Integer'Max (1, Integer (Height))));
      Ignore (ReleaseDC (Window_Handle, Window_DC));

      if Surface_Bitmap = System.Null_Address then
         Shutdown;
         return;
      end if;

      Old_Bitmap := SelectObject (Memory_DC, Surface_Bitmap);
      Ignore (SetBkMode (Memory_DC, TRANSPARENT));

      Is_Ready := True;
      Close_Requested := False;
      Width_Px := Natural'Max (1, Width);
      Height_Px := Natural'Max (1, Height);
      Current_Color := To_Colorref (16#FFFFFF#);
      Origin_X := 0;
      Origin_Y := 0;
      Clip_Enabled := False;
      Mouse_X_Pos := 0;
      Mouse_Y_Pos := 0;
      Key_Event_Flag := False;
      Key_Is_Down := (others => False);
      Mouse_Is_Down := (others => False);
      Mouse_Pressed := (others => False);
      Apply_Clip;
      Fill_Rect_With_Color (0, 0, Integer (Width_Px), Integer (Height_Px), To_Colorref (0));
      Success := True;
   end Initialize;

   procedure Shutdown is
   begin
      if Memory_DC /= System.Null_Address and then Old_Bitmap /= System.Null_Address then
         Ignore (SelectObject (Memory_DC, Old_Bitmap));
      end if;

      if Surface_Bitmap /= System.Null_Address then
         Ignore (DeleteObject (Surface_Bitmap));
      end if;
      if Memory_DC /= System.Null_Address then
         Ignore (DeleteDC (Memory_DC));
      end if;
      if Window_Handle /= System.Null_Address and then IsWindow (Window_Handle) /= 0 then
         Ignore (DestroyWindow (Window_Handle));
      end if;

      Window_Handle := System.Null_Address;
      Memory_DC := System.Null_Address;
      Surface_Bitmap := System.Null_Address;
      Old_Bitmap := System.Null_Address;
      Is_Ready := False;
      Close_Requested := False;
      Width_Px := 0;
      Height_Px := 0;
      Origin_X := 0;
      Origin_Y := 0;
      Clip_Enabled := False;
      Key_Event_Flag := False;
      Key_Is_Down := (others => False);
      Mouse_Is_Down := (others => False);
      Mouse_Pressed := (others => False);
   end Shutdown;

   function Window_Open return Boolean is
   begin
      return
        Is_Ready
        and then not Close_Requested
        and then Window_Handle /= System.Null_Address
        and then IsWindow (Window_Handle) /= 0;
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
      Message                 : aliased MSG;
      Cursor                  : aliased POINT;
      Was_Down                : Boolean := False;
      Was_Mouse_Down          : Mouse_State_Array := Mouse_Is_Down;
      Mouse_Event_Pos_Seen    : Boolean := False;
      Mouse_Click_Pos_Latched : Boolean := False;

      procedure Update_Mouse_From_Message
        (Packed         : UINT_PTR;
         Latch_For_Click : Boolean := False)
      is
      begin
         if Mouse_Click_Pos_Latched and then not Latch_For_Click then
            return;
         end if;

         Mouse_X_Pos := Mouse_LParam_X (Packed);
         Mouse_Y_Pos := Mouse_LParam_Y (Packed);
         Mouse_Event_Pos_Seen := True;

         if Latch_For_Click then
            Mouse_Click_Pos_Latched := True;
         end if;
      end Update_Mouse_From_Message;
   begin
      if not Is_Ready then
         return;
      end if;

      Mouse_Pressed := (others => False);
      while PeekMessageA (Message'Access, System.Null_Address, 0, 0, PM_REMOVE) /= 0 loop
         if Message.Message = WM_QUIT then
            Close_Requested := True;
         else
            case Message.Message is
               when WM_MOUSEMOVE =>
                  Update_Mouse_From_Message (Message.LParam);
               when WM_LBUTTONDOWN =>
                  Mouse_Is_Down (0) := True;
                  Mouse_Pressed (0) := True;
                  Update_Mouse_From_Message (Message.LParam, Latch_For_Click => True);
               when WM_LBUTTONUP =>
                  Mouse_Is_Down (0) := False;
                  Update_Mouse_From_Message (Message.LParam);
               when WM_RBUTTONDOWN =>
                  Mouse_Is_Down (1) := True;
                  Mouse_Pressed (1) := True;
                  Update_Mouse_From_Message (Message.LParam, Latch_For_Click => True);
               when WM_RBUTTONUP =>
                  Mouse_Is_Down (1) := False;
                  Update_Mouse_From_Message (Message.LParam);
               when WM_MBUTTONDOWN =>
                  Mouse_Is_Down (2) := True;
                  Mouse_Pressed (2) := True;
                  Update_Mouse_From_Message (Message.LParam, Latch_For_Click => True);
               when WM_MBUTTONUP =>
                  Mouse_Is_Down (2) := False;
                  Update_Mouse_From_Message (Message.LParam);
               when others =>
                  null;
            end case;
            Ignore (TranslateMessage (Message'Access));
            Ignore (DispatchMessageA (Message'Access));
         end if;
      end loop;

      if not Window_Open then
         Close_Requested := True;
         return;
      end if;

      Key_Event_Flag := False;
      for I in Key_Is_Down'Range loop
         Was_Down := Key_Is_Down (I);
         Key_Is_Down (I) := GetAsyncKeyState (INT (I)) < 0;
         if Key_Is_Down (I) and then not Was_Down then
            Key_Event_Flag := True;
         end if;
      end loop;

      Mouse_Is_Down (0) := GetAsyncKeyState (VK_LBUTTON) < 0;
      if Mouse_Is_Down (0) and then not Was_Mouse_Down (0) then
         Mouse_Pressed (0) := True;
      end if;

      Mouse_Is_Down (1) := GetAsyncKeyState (VK_RBUTTON) < 0;
      if Mouse_Is_Down (1) and then not Was_Mouse_Down (1) then
         Mouse_Pressed (1) := True;
      end if;

      Mouse_Is_Down (2) := GetAsyncKeyState (VK_MBUTTON) < 0;
      if Mouse_Is_Down (2) and then not Was_Mouse_Down (2) then
         Mouse_Pressed (2) := True;
      end if;

      if not Mouse_Event_Pos_Seen then
         if GetCursorPos (Cursor'Access) /= 0 and then ScreenToClient (Window_Handle, Cursor'Access) /= 0 then
            Mouse_X_Pos := Integer (Cursor.X);
            Mouse_Y_Pos := Integer (Cursor.Y);
         else
            Mouse_X_Pos := 0;
            Mouse_Y_Pos := 0;
         end if;
      end if;
   end Process_Events;

   procedure Present is
      Window_DC : System.Address := System.Null_Address;
   begin
      if not Window_Open or else Memory_DC = System.Null_Address then
         return;
      end if;

      Window_DC := GetDC (Window_Handle);
      if Window_DC = System.Null_Address then
         return;
      end if;

      Ignore
        (BitBlt
           (HdcDest => Window_DC,
            XDest   => 0,
            YDest   => 0,
            Width   => INT (Width_Px),
            Height  => INT (Height_Px),
            HdcSrc  => Memory_DC,
            XSrc    => 0,
            YSrc    => 0,
            Rop     => SRCCOPY));
      Ignore (ReleaseDC (Window_Handle, Window_DC));
   end Present;

   procedure Pause_For (Milliseconds : in Natural) is
   begin
      Sleep (DWORD (Milliseconds));
   end Pause_For;

   function Monotonic_Millis return Natural is
   begin
      return Natural (GetTickCount);
   end Monotonic_Millis;

   procedure Set_Color (RGB : in Natural) is
   begin
      Current_Color := To_Colorref (RGB);
   end Set_Color;

   procedure Clear (RGB : in Natural) is
   begin
      Fill_Rect_With_Color (0, 0, Integer (Width_Px), Integer (Height_Px), To_Colorref (RGB));
   end Clear;

   procedure Draw_Rect
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer)
   is
      Draw_X    : Integer := X + Origin_X;
      Draw_Y    : Integer := Y + Origin_Y;
      Draw_W    : Integer := W;
      Draw_H    : Integer := H;
      Pen       : System.Address := System.Null_Address;
      Brush     : System.Address := System.Null_Address;
      Old_Pen   : System.Address := System.Null_Address;
      Old_Brush : System.Address := System.Null_Address;
   begin
      if Memory_DC = System.Null_Address then
         return;
      end if;

      Normalize_Rect (Draw_X, Draw_Y, Draw_W, Draw_H);
      if Draw_W <= 0 or else Draw_H <= 0 then
         return;
      end if;

      Select_Pen_And_Brush (False, Current_Color, Current_Color, Pen, Brush, Old_Pen, Old_Brush);
      Ignore
        (Rectangle
           (Memory_DC,
            INT (Draw_X),
            INT (Draw_Y),
            INT (Draw_X + Draw_W),
            INT (Draw_Y + Draw_H)));
      Restore_Pen_And_Brush (Pen, Brush, Old_Pen, Old_Brush, False);
   end Draw_Rect;

   procedure Fill_Rect
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer)
   is
   begin
      Fill_Rect_With_Color (X, Y, W, H, Current_Color);
   end Fill_Rect;

   procedure Draw_Line
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer)
   is
      Pen     : System.Address := System.Null_Address;
      Old_Pen : System.Address := System.Null_Address;
   begin
      if Memory_DC = System.Null_Address then
         return;
      end if;

      Pen := CreatePen (PS_SOLID, 1, Current_Color);
      if Pen = System.Null_Address then
         return;
      end if;

      Old_Pen := SelectObject (Memory_DC, Pen);
      Ignore (MoveToEx (Memory_DC, INT (X1 + Origin_X), INT (Y1 + Origin_Y), System.Null_Address));
      Ignore (LineTo (Memory_DC, INT (X2 + Origin_X), INT (Y2 + Origin_Y)));
      if Old_Pen /= System.Null_Address then
         Ignore (SelectObject (Memory_DC, Old_Pen));
      end if;
      Ignore (DeleteObject (Pen));
   end Draw_Line;

   procedure Draw_Circle
     (CX     : in Integer;
      CY     : in Integer;
      Radius : in Integer)
   is
      Pen       : System.Address := System.Null_Address;
      Brush     : System.Address := System.Null_Address;
      Old_Pen   : System.Address := System.Null_Address;
      Old_Brush : System.Address := System.Null_Address;
   begin
      if Memory_DC = System.Null_Address or else Radius <= 0 then
         return;
      end if;

      Select_Pen_And_Brush (False, Current_Color, Current_Color, Pen, Brush, Old_Pen, Old_Brush);
      Ignore
        (Ellipse
           (Memory_DC,
            INT (CX - Radius + Origin_X),
            INT (CY - Radius + Origin_Y),
            INT (CX + Radius + Origin_X),
            INT (CY + Radius + Origin_Y)));
      Restore_Pen_And_Brush (Pen, Brush, Old_Pen, Old_Brush, False);
   end Draw_Circle;

   procedure Fill_Circle
     (CX     : in Integer;
      CY     : in Integer;
      Radius : in Integer)
   is
      Pen       : System.Address := System.Null_Address;
      Brush     : System.Address := System.Null_Address;
      Old_Pen   : System.Address := System.Null_Address;
      Old_Brush : System.Address := System.Null_Address;
   begin
      if Memory_DC = System.Null_Address or else Radius <= 0 then
         return;
      end if;

      Select_Pen_And_Brush (True, Current_Color, Current_Color, Pen, Brush, Old_Pen, Old_Brush);
      Ignore
        (Ellipse
           (Memory_DC,
            INT (CX - Radius + Origin_X),
            INT (CY - Radius + Origin_Y),
            INT (CX + Radius + Origin_X),
            INT (CY + Radius + Origin_Y)));
      Restore_Pen_And_Brush (Pen, Brush, Old_Pen, Old_Brush, True);
   end Fill_Circle;

   procedure Draw_Triangle
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer;
      X3 : in Integer;
      Y3 : in Integer)
   is
      Pen       : System.Address := System.Null_Address;
      Brush     : System.Address := System.Null_Address;
      Old_Pen   : System.Address := System.Null_Address;
      Old_Brush : System.Address := System.Null_Address;
      Points    : aliased Point_Array (0 .. 2) :=
        (0 => (X => LONG (X1 + Origin_X), Y => LONG (Y1 + Origin_Y)),
         1 => (X => LONG (X2 + Origin_X), Y => LONG (Y2 + Origin_Y)),
         2 => (X => LONG (X3 + Origin_X), Y => LONG (Y3 + Origin_Y)));
   begin
      if Memory_DC = System.Null_Address then
         return;
      end if;

      Select_Pen_And_Brush (False, Current_Color, Current_Color, Pen, Brush, Old_Pen, Old_Brush);
      Ignore (Polygon (Memory_DC, Points (0)'Access, 3));
      Restore_Pen_And_Brush (Pen, Brush, Old_Pen, Old_Brush, False);
   end Draw_Triangle;

   procedure Fill_Triangle
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer;
      X3 : in Integer;
      Y3 : in Integer)
   is
      Pen       : System.Address := System.Null_Address;
      Brush     : System.Address := System.Null_Address;
      Old_Pen   : System.Address := System.Null_Address;
      Old_Brush : System.Address := System.Null_Address;
      Points    : aliased Point_Array (0 .. 2) :=
        (0 => (X => LONG (X1 + Origin_X), Y => LONG (Y1 + Origin_Y)),
         1 => (X => LONG (X2 + Origin_X), Y => LONG (Y2 + Origin_Y)),
         2 => (X => LONG (X3 + Origin_X), Y => LONG (Y3 + Origin_Y)));
   begin
      if Memory_DC = System.Null_Address then
         return;
      end if;

      Select_Pen_And_Brush (True, Current_Color, Current_Color, Pen, Brush, Old_Pen, Old_Brush);
      Ignore (Polygon (Memory_DC, Points (0)'Access, 3));
      Restore_Pen_And_Brush (Pen, Brush, Old_Pen, Old_Brush, True);
   end Fill_Triangle;

   procedure Plot
     (X : in Integer;
      Y : in Integer)
   is
   begin
      if Memory_DC = System.Null_Address then
         return;
      end if;

      Ignore (SetPixelV (Memory_DC, INT (X + Origin_X), INT (Y + Origin_Y), Current_Color));
   end Plot;

   procedure Draw_Text
     (X    : in Integer;
      Y    : in Integer;
      Text : in String)
   is
      Buffer : chars_ptr := Null_Ptr;
   begin
      if Memory_DC = System.Null_Address or else Text'Length = 0 then
         return;
      end if;

      Buffer := New_String (Text);
      Ignore (SetTextColor (Memory_DC, Current_Color));
      Ignore (SetBkMode (Memory_DC, TRANSPARENT));
      Ignore
        (TextOutA
           (Memory_DC,
            INT (X + Origin_X),
            INT (Y + Origin_Y),
            Buffer,
            INT (Text'Length)));
      Free (Buffer);
   end Draw_Text;

   procedure Set_Alpha
     (Channel : in Integer;
      Value   : in Integer)
   is
   begin
      Alpha_Channel := Channel;
      Alpha_Value := Value;
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
      else
         Clip_Enabled := True;
         Clip_X := X;
         Clip_Y := Y;
         Clip_W := W;
         Clip_H := H;
      end if;
      Apply_Clip;
   end Set_Clip;

   procedure Set_Origin
     (X : in Integer;
      Y : in Integer)
   is
   begin
      Origin_X := X;
      Origin_Y := Y;
      Apply_Clip;
   end Set_Origin;

   function Key_Down (Code : in Integer) return Boolean is
      Virtual_Key : constant INT := Map_Key_Code (Code);
   begin
      if Virtual_Key < 0 or else Virtual_Key > 255 then
         return False;
      end if;
      return Key_Is_Down (Integer (Virtual_Key));
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
      return Mouse_X_Pos;
   end VMouse_X;

   function VMouse_Y return Integer is
   begin
      return Mouse_Y_Pos;
   end VMouse_Y;

   function Mouse_Click (Button : in Integer) return Integer is
   begin
      if Button in Mouse_Pressed'Range and then Mouse_Pressed (Button) then
         return 1;
      end if;
      return 0;
   end Mouse_Click;

   function Read_Pixel
     (X : in Integer;
      Y : in Integer) return Natural
   is
      Pixel : COLORREF := 0;
   begin
      if Memory_DC = System.Null_Address then
         return 0;
      end if;

      Pixel := GetPixel (Memory_DC, INT (X + Origin_X), INT (Y + Origin_Y));
      if Pixel = COLORREF (16#FFFF_FFFF#) then
         return 0;
      end if;
      return To_RGB (Pixel);
   end Read_Pixel;

end ALB_Graphics;
