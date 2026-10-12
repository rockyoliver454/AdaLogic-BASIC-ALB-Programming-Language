pragma SPARK_Mode (Off);

package ALBA_Graphics is

   procedure Initialize
     (Title   : in String;
      Width   : in Natural;
      Height  : in Natural;
      Success : out Boolean);
   procedure Set_Fullscreen (Enabled : in Boolean);
   procedure Set_Resizable (Enabled : in Boolean);
   procedure Set_Stretchy (Enabled : in Boolean);

   procedure Shutdown;
   procedure Process_Events;
   procedure Present;
   function Window_Open return Boolean;
   procedure Request_Close;
   function Pending_Key_Event return Boolean;

   procedure Pause_For (Milliseconds : in Natural);
   function Monotonic_Millis return Natural;
   function Virtual_Width return Natural;
   function Virtual_Height return Natural;

   procedure Set_Color (RGB : in Natural);
   procedure Clear (RGB : in Natural);
   procedure Draw_Rect
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer);
   procedure Fill_Rect
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer);
   procedure Draw_Line
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer);
   procedure Draw_Circle
     (CX     : in Integer;
      CY     : in Integer;
      Radius : in Integer);
   procedure Fill_Circle
     (CX     : in Integer;
      CY     : in Integer;
      Radius : in Integer);
   procedure Draw_Triangle
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer;
      X3 : in Integer;
      Y3 : in Integer);
   procedure Fill_Triangle
     (X1 : in Integer;
      Y1 : in Integer;
      X2 : in Integer;
      Y2 : in Integer;
      X3 : in Integer;
      Y3 : in Integer);
   procedure Plot
     (X : in Integer;
      Y : in Integer);
   procedure Draw_Text
     (X    : in Integer;
      Y    : in Integer;
      Text : in String);
   procedure Set_Alpha
     (Channel : in Integer;
      Value   : in Integer);
   procedure Set_Clip
     (X : in Integer;
      Y : in Integer;
      W : in Integer;
      H : in Integer);
   procedure Set_Origin
     (X : in Integer;
      Y : in Integer);

   function Key_Down (Code : in Integer) return Boolean;
   function Mouse_X return Integer;
   function Mouse_Y return Integer;
   function VMouse_X return Integer;
   function VMouse_Y return Integer;
   function Mouse_Click (Button : in Integer) return Integer;
   function Read_Pixel
     (X : in Integer;
      Y : in Integer) return Natural;

end ALBA_Graphics;
