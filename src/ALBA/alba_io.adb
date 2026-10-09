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

-- ALBA console I/O runtime.
-- Safety role: bounded external-input boundary (CODING_RULES §8.4).
-- Fail-safe: malformed numeric input returns documented defaults, never raises.

with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body ALBA_IO is

   use Ada.Streams;
   use Ada.Streams.Stream_IO;
   use Interfaces.C;
   use Interfaces.C.Strings;

   pragma Linker_Options ("-luser32");

   Max_Files : constant Positive := 32;

   type File_Record is record
      Opened : Boolean := False;
      Mode   : Character := 'r';
      File   : File_Type;
   end record;

   File_Table : array (Positive range 1 .. Max_Files) of File_Record;

   function MessageBoxA
     (Wnd     : System.Address;
      Text    : chars_ptr;
      Caption : chars_ptr;
      Flags   : unsigned) return int;
   pragma Import (Stdcall, MessageBoxA, "MessageBoxA");

   function Normalize (Text : ALB_Text) return String is
   begin
      return ALB_TO_STRING (Text);
   end Normalize;

   function To_Text (Value : String) return ALB_Text is
   begin
      return ALB_STR (Value);
   end To_Text;

   procedure Ensure_Parent_Path (Path : String) is
      Dir : constant String := Ada.Directories.Containing_Directory (Path);
   begin
      if Dir'Length > 0
        and then Dir /= "."
        and then not Ada.Directories.Exists (Dir)
      then
         Ada.Directories.Create_Path (Dir);
      end if;
   exception
      when others =>
         null;
   end Ensure_Parent_Path;

   function Trim_Image (Text : String) return String is
      First : Natural := Text'First;
   begin
      while First <= Text'Last and then Text (First) = ' ' loop
         First := First + 1;
      end loop;

      if First <= Text'Last then
         return Text (First .. Text'Last);
      end if;

      return "0";
   end Trim_Image;

   function Load_File_String (Path : String) return String is
      F      : File_Type;
      Last   : Stream_Element_Offset := 0;
   begin
      if Path'Length = 0 or else not Ada.Directories.Exists (Path) then
         return "";
      end if;

      Open (F, In_File, Path);
      declare
         Length : constant Natural := Natural (Size (F));
      begin
         if Length = 0 then
            Close (F);
            return "";
         end if;

         declare
            Buffer : Stream_Element_Array (1 .. Stream_Element_Offset (Length));
            Text   : String (1 .. Length);
         begin
            Read (F, Buffer, Last);
            Close (F);
            if Last <= 0 then
               return "";
            end if;

            for I in 1 .. Integer (Last) loop
               Text (I) := Character'Val (Buffer (Stream_Element_Offset (I)));
            end loop;
            return Text (1 .. Integer (Last));
         end;
      end;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         return "";
   end Load_File_String;

   function Next_Token
     (Source : String;
      Cursor : in out Natural) return String
   is
      Start : Natural := Cursor;
   begin
      if Source'Length = 0 then
         return "";
      end if;

      if Start < Source'First then
         Start := Source'First;
      end if;

      while Start <= Source'Last and then Source (Start) <= ' ' loop
         Start := Start + 1;
      end loop;

      Cursor := Start;
      while Cursor <= Source'Last and then Source (Cursor) > ' ' loop
         Cursor := Cursor + 1;
      end loop;

      if Start > Source'Last then
         return "";
      end if;

      return Source (Start .. Cursor - 1);
   end Next_Token;

   generic
      type Element_Type is mod <>;
      type Element_Array is array (Positive range <>) of Element_Type;
   procedure Load_Mod_Array
     (Data : in out Element_Array;
      Path : in ALB_Text);

   procedure Load_Mod_Array
     (Data : in out Element_Array;
      Path : in ALB_Text)
   is
      Contents : constant String := Load_File_String (Normalize (Path));
      Cursor   : Natural := (if Contents'Length = 0 then 1 else Contents'First);
   begin
      for I in Data'Range loop
         declare
            Token : constant String := Next_Token (Contents, Cursor);
            Value : Integer;
         begin
            if Token'Length = 0 then
               Data (I) := 0;
            elsif Try_Parse_Integer (Token, Value) and then Value >= 0 then
               Data (I) := Element_Type (Value);
            else
               Data (I) := 0;
            end if;
         end;
      end loop;
   end Load_Mod_Array;

   generic
      type Element_Type is range <>;
      type Element_Array is array (Positive range <>) of Element_Type;
   procedure Load_Int_Array
     (Data : in out Element_Array;
      Path : in ALB_Text);

   procedure Load_Int_Array
     (Data : in out Element_Array;
      Path : in ALB_Text)
   is
      Contents : constant String := Load_File_String (Normalize (Path));
      Cursor   : Natural := (if Contents'Length = 0 then 1 else Contents'First);
   begin
      for I in Data'Range loop
         declare
            Token : constant String := Next_Token (Contents, Cursor);
            Value : Integer;
         begin
            if Token'Length = 0 then
               Data (I) := 0;
            elsif Try_Parse_Integer (Token, Value)
              and then Long_Long_Integer (Value)
                     in Long_Long_Integer (Element_Type'First)
                        .. Long_Long_Integer (Element_Type'Last)
            then
               Data (I) := Element_Type (Value);
            else
               Data (I) := 0;
            end if;
         end;
      end loop;
   end Load_Int_Array;

   generic
      type Element_Type is mod <>;
      type Element_Array is array (Positive range <>) of Element_Type;
   procedure Flush_Mod_Array
     (Data : in Element_Array;
      Path : in ALB_Text);

   procedure Flush_Mod_Array
     (Data : in Element_Array;
      Path : in ALB_Text)
   is
      F : Ada.Text_IO.File_Type;
      P : constant String := Normalize (Path);
   begin
      if P'Length = 0 then
         return;
      end if;

      Ensure_Parent_Path (P);
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, P);
      for I in Data'Range loop
         if I > Data'First then
            Ada.Text_IO.Put (F, " ");
         end if;
         Ada.Text_IO.Put (F, Trim_Image (Element_Type'Image (Data (I))));
      end loop;
      Ada.Text_IO.Close (F);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (F) then
            Ada.Text_IO.Close (F);
         end if;
   end Flush_Mod_Array;

   generic
      type Element_Type is range <>;
      type Element_Array is array (Positive range <>) of Element_Type;
   procedure Flush_Int_Array
     (Data : in Element_Array;
      Path : in ALB_Text);

   procedure Flush_Int_Array
     (Data : in Element_Array;
      Path : in ALB_Text)
   is
      F : Ada.Text_IO.File_Type;
      P : constant String := Normalize (Path);
   begin
      if P'Length = 0 then
         return;
      end if;

      Ensure_Parent_Path (P);
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, P);
      for I in Data'Range loop
         if I > Data'First then
            Ada.Text_IO.Put (F, " ");
         end if;
         Ada.Text_IO.Put (F, Trim_Image (Element_Type'Image (Data (I))));
      end loop;
      Ada.Text_IO.Close (F);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (F) then
            Ada.Text_IO.Close (F);
         end if;
   end Flush_Int_Array;

   function Find_Free_Handle return U64 is
   begin
      for I in File_Table'Range loop
         if not File_Table (I).Opened then
            return U64 (I);
         end if;
      end loop;
      return 0;
   end Find_Free_Handle;

   Max_Input_Attempts : constant Natural := 3;

   function Trim_Both (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      if Text'Length = 0 then
         return "";
      end if;

      while First <= Last and then Text (First) <= ' ' loop
         First := First + 1;
      end loop;

      while Last >= First and then Text (Last) <= ' ' loop
         Last := Last - 1;
      end loop;

      if First > Last then
         return "";
      end if;

      return Text (First .. Last);
   end Trim_Both;

   function Try_Parse_Integer
     (Text  : String;
      Value : out Integer) return Boolean
   is
      Trimmed : constant String := Trim_Both (Text);
      Pos     : Natural;
      Sign    : Long_Long_Integer := 1;
      Acc     : Long_Long_Integer := 0;
      Started : Boolean := False;
   begin
      Value := 0;

      if Trimmed'Length = 0 then
         return False;
      end if;

      Pos := Trimmed'First;

      if Trimmed (Pos) = '-' then
         Sign := -1;
         Pos := Pos + 1;
      elsif Trimmed (Pos) = '+' then
         Pos := Pos + 1;
      end if;

      while Pos <= Trimmed'Last loop
         if Trimmed (Pos) in '0' .. '9' then
            Started := True;
            declare
               Digit : constant Long_Long_Integer :=
                 Long_Long_Integer (Character'Pos (Trimmed (Pos))
                                    - Character'Pos ('0'));
            begin
               if Acc > (Long_Long_Integer (Integer'Last) + 1) / 10 then
                  return False;
               end if;
               Acc := Acc * 10 + Digit;
               if Sign = 1 and then Acc > Long_Long_Integer (Integer'Last) then
                  return False;
               end if;
               if Sign = -1 and then Acc > Long_Long_Integer (Integer'Last) + 1 then
                  return False;
               end if;
            end;
         else
            return False;
         end if;
         Pos := Pos + 1;
      end loop;

      if not Started then
         return False;
      end if;

      Value := Integer (Sign * Acc);
      return True;
   end Try_Parse_Integer;

   function Read_Integer
     (Prompt  : ALB_Text;
      Default : Integer := 0) return Integer
   is
      Line  : constant String := Normalize (Input (Prompt));
      Value : Integer;
   begin
      if Try_Parse_Integer (Line, Value) then
         return Value;
      end if;
      return Default;
   end Read_Integer;

   function Read_Integer_In_Range
     (Prompt  : ALB_Text;
      Min_Val : Integer;
      Max_Val : Integer;
      Default : Integer) return Integer
   is
      Attempts : Natural := 0;
      Value    : Integer;
   begin
      if Min_Val > Max_Val then
         return Default;
      end if;

      while Attempts < Max_Input_Attempts loop
         declare
            Line : constant String := Normalize (Input (Prompt));
         begin
            if Try_Parse_Integer (Line, Value)
              and then Value >= Min_Val
              and then Value <= Max_Val
            then
               return Value;
            end if;
         end;

         Attempts := Attempts + 1;
         if Attempts < Max_Input_Attempts then
            Print_Text (ALB_STR ("Invalid input."), True);
         end if;
      end loop;

      return Default;
   end Read_Integer_In_Range;

   procedure Print_Text
     (Text    : in ALB_Text;
      Newline : in Boolean := True) is
      Value : constant String := Normalize (Text);
   begin
      if Newline then
         Ada.Text_IO.Put_Line (Value);
      else
         Ada.Text_IO.Put (Value);
      end if;
   end Print_Text;

   function Input (Prompt : in ALB_Text) return ALB_Text is
      Buffer : String (1 .. Max_Text_Length) := (others => ' ');
      Last   : Natural := 0;
   begin
      if Prompt.Length > 0 then
         Print_Text (Prompt, False);
      end if;

      Ada.Text_IO.Get_Line (Buffer, Last);
      if Last = 0 then
         return ALB_STR ("");
      end if;
      return ALB_STR (Buffer (1 .. Last));
   exception
      when Ada.IO_Exceptions.End_Error =>
         return ALB_STR ("");
   end Input;

   function Readline return ALB_Text is
      Buffer : String (1 .. Max_Text_Length) := (others => ' ');
      Last   : Natural := 0;
   begin
      Ada.Text_IO.Get_Line (Buffer, Last);
      if Last = 0 then
         return ALB_STR ("");
      end if;
      return ALB_STR (Buffer (1 .. Last));
   exception
      when Ada.IO_Exceptions.End_Error =>
         return ALB_STR ("");
   end Readline;

   procedure Locate
     (Col : in Integer;
      Row : in Integer := 1) is
      Esc : constant Character := Ada.Characters.Latin_1.ESC;
      R   : constant Integer := Integer'Max (1, Row);
      C   : constant Integer := Integer'Max (1, Col);
   begin
      -- ALB LOCATE X, Y passes column then row; ANSI CSI is row;column.
      Ada.Text_IO.Put
        (Esc & "[" &
         Integer'Image (R) (2 .. Integer'Image (R)'Last) & ";" &
         Integer'Image (C) (2 .. Integer'Image (C)'Last) & "H");
      Ada.Text_IO.Flush;
   end Locate;

   procedure Clear_Screen is
      Esc : constant Character := Ada.Characters.Latin_1.ESC;
   begin
      Ada.Text_IO.Put (Esc & "[2J" & Esc & "[1;1H");
      Ada.Text_IO.Flush;
   end Clear_Screen;

   procedure Message_Box
     (Body_Text  : in ALB_Text;
      Title : in ALB_Text) is
      Body_C  : chars_ptr := Null_Ptr;
      Title_C : chars_ptr := Null_Ptr;
      Dummy   : int := 0;
   begin
      Body_C := New_String (Normalize (Body_Text));
      Title_C := New_String (Normalize (Title));
      Dummy := MessageBoxA (System.Null_Address, Body_C, Title_C, 0);
      Free (Body_C);
      Free (Title_C);
      if Dummy /= 0 then
         null;
      end if;
   exception
      when others =>
         if Body_C /= Null_Ptr then
            Free (Body_C);
         end if;
         if Title_C /= Null_Ptr then
            Free (Title_C);
         end if;
         Print_Text (Title, True);
         Print_Text (Body_Text, True);
   end Message_Box;

   function File_Open
     (Path : in ALB_Text;
      Mode : in ALB_Text) return U64
   is
      Handle : constant U64 := Find_Free_Handle;
      Index  : Positive := 1;
      P      : constant String := Normalize (Path);
      M      : constant String := Normalize (Mode);
   begin
      if Handle = 0 or else P'Length = 0 then
         return 0;
      end if;

      Index := Positive (Handle);

      if M = "r" then
         Open (File_Table (Index).File, In_File, P);
         File_Table (Index).Mode := 'r';
      elsif M = "a" then
         Ensure_Parent_Path (P);
         if Ada.Directories.Exists (P) then
            Open (File_Table (Index).File, Append_File, P);
         else
            Create (File_Table (Index).File, Out_File, P);
         end if;
         File_Table (Index).Mode := 'a';
      else
         Ensure_Parent_Path (P);
         Create (File_Table (Index).File, Out_File, P);
         File_Table (Index).Mode := 'w';
      end if;

      File_Table (Index).Opened := True;
      return Handle;
   exception
      when others =>
         return 0;
   end File_Open;

   function File_Len (Path : in ALB_Text) return U64 is
      P : constant String := Normalize (Path);
   begin
      if P'Length = 0 or else not Ada.Directories.Exists (P) then
         return 0;
      end if;
      return U64 (Ada.Directories.Size (P));
   exception
      when others =>
         return 0;
   end File_Len;

   function File_Seek
     (Handle : in U64;
      Offset : in U64) return U64
   is
      Index : Positive := 1;
   begin
      if Handle = 0 then
         return 0;
      end if;
      Index := Positive (Handle);
      if Index not in File_Table'Range or else not File_Table (Index).Opened then
         return 0;
      end if;
      Set_Index (File_Table (Index).File, Count (Offset + 1));
      return U64 (Ada.Streams.Stream_IO.Index (File_Table (Index).File)) - 1;
   exception
      when others =>
         return 0;
   end File_Seek;

   function File_Read
     (Handle : in U64;
      Count  : in U64) return ALB_Text
   is
      Buffer : Stream_Element_Array (1 .. Stream_Element_Offset (Max_Text_Length));
      Last   : Stream_Element_Offset := 0;
      Limit  : Natural := Natural'Min (Natural (Count), Max_Text_Length);
      Index  : Positive := 1;
      Text   : ALB_Text;
   begin
      if Handle = 0 then
         return ALB_STR ("");
      end if;

      Index := Positive (Handle);
      if Index not in File_Table'Range or else not File_Table (Index).Opened then
         return ALB_STR ("");
      end if;

      if Limit = 0 then
         return ALB_STR ("");
      end if;

      Read (File_Table (Index).File, Buffer (1 .. Stream_Element_Offset (Limit)), Last);
      if Last <= 0 then
         return ALB_STR ("");
      end if;

      Text.Length := Natural (Last);
      for I in 1 .. Text.Length loop
         Text.Data (I) := Character'Val (Integer (Buffer (Stream_Element_Offset (I))));
      end loop;
      return Text;
   exception
      when others =>
         return ALB_STR ("");
   end File_Read;

   procedure File_Write
     (Handle : in U64;
      Data   : in ALB_Text)
   is
      Buffer : Stream_Element_Array (1 .. Stream_Element_Offset (Max_Text_Length));
      Index  : Positive := 1;
   begin
      if Handle = 0 then
         return;
      end if;

      Index := Positive (Handle);
      if Index not in File_Table'Range or else not File_Table (Index).Opened then
         return;
      end if;

      for I in 1 .. Data.Length loop
         Buffer (Stream_Element_Offset (I)) := Stream_Element (Character'Pos (Data.Data (I)));
      end loop;

      if Data.Length > 0 then
         Write (File_Table (Index).File, Buffer (1 .. Stream_Element_Offset (Data.Length)));
      end if;
   exception
      when others =>
         null;
   end File_Write;

   procedure File_Close (Handle : in U64) is
      Index : Positive := 1;
   begin
      if Handle = 0 then
         return;
      end if;

      Index := Positive (Handle);
      if Index in File_Table'Range and then File_Table (Index).Opened then
         Close (File_Table (Index).File);
         File_Table (Index).Opened := False;
      end if;
   exception
      when others =>
         null;
   end File_Close;

   function Load_File (Path : in ALB_Text) return ALB_Text is
      Handle : constant U64 := File_Open (Path, ALB_STR ("r"));
      Data   : ALB_Text := ALB_STR ("");
   begin
      if Handle = 0 then
         return ALB_STR ("");
      end if;
      Data := File_Read (Handle, U64 (Max_Text_Length));
      File_Close (Handle);
      return Data;
   end Load_File;

   procedure Flush_File
     (Data : in ALB_Text;
      Path : in ALB_Text)
   is
      Handle : constant U64 := File_Open (Path, ALB_STR ("w"));
   begin
      if Handle = 0 then
         return;
      end if;
      File_Write (Handle, Data);
      File_Close (Handle);
   end Flush_File;

   procedure Load_File
     (Data : in out ALB_U8_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Mod_Array (ALB_U8, ALB_U8_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Load_File
     (Data : in out ALB_U16_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Mod_Array (ALB_U16, ALB_U16_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Load_File
     (Data : in out ALB_U32_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Mod_Array (ALB_U32, ALB_U32_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Load_File
     (Data : in out ALB_U64_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Mod_Array (ALB_U64, ALB_U64_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Load_File
     (Data : in out ALB_I8_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Int_Array (ALB_I8, ALB_I8_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Load_File
     (Data : in out ALB_I16_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Int_Array (ALB_I16, ALB_I16_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Load_File
     (Data : in out ALB_I32_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Int_Array (ALB_I32, ALB_I32_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Load_File
     (Data : in out ALB_I64_Array;
      Path : in ALB_Text) is
      procedure Impl is new Load_Int_Array (ALB_I64, ALB_I64_Array);
   begin
      Impl (Data, Path);
   end Load_File;

   procedure Flush_File
     (Data : in ALB_U8_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Mod_Array (ALB_U8, ALB_U8_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

   procedure Flush_File
     (Data : in ALB_U16_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Mod_Array (ALB_U16, ALB_U16_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

   procedure Flush_File
     (Data : in ALB_U32_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Mod_Array (ALB_U32, ALB_U32_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

   procedure Flush_File
     (Data : in ALB_U64_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Mod_Array (ALB_U64, ALB_U64_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

   procedure Flush_File
     (Data : in ALB_I8_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Int_Array (ALB_I8, ALB_I8_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

   procedure Flush_File
     (Data : in ALB_I16_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Int_Array (ALB_I16, ALB_I16_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

   procedure Flush_File
     (Data : in ALB_I32_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Int_Array (ALB_I32, ALB_I32_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

   procedure Flush_File
     (Data : in ALB_I64_Array;
      Path : in ALB_Text) is
      procedure Impl is new Flush_Int_Array (ALB_I64, ALB_I64_Array);
   begin
      Impl (Data, Path);
   end Flush_File;

end ALBA_IO;
