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

with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;      use Ada.Text_IO;
with Ada.Numerics.Long_Elementary_Functions;
with ALB_Audio;
with ALB_Graphics;
with Memory_Allocator; use Memory_Allocator;
with Pure_Types;       use Pure_Types;
with Numerus_Magnus;   use Numerus_Magnus;
with HW_Types;         use HW_Types;

package body Interpreter is

   Max_Call_Args : constant := 64;

   type Arg_Value_Array is array (1 .. Max_Call_Args) of ALB_Value;
   type Int_Arg_Array is array (1 .. Max_Call_Args) of Long_Integer;
   type Actual_Node_Array is array (1 .. Max_Call_Args) of Node_Index;
   type Bool_Array is array (1 .. Max_Call_Args) of Boolean;
   type Saved_Var_Record is record
      Slot       : Natural := 0;
      Was_Active : Boolean := False;
      Old_Name   : Var_Name := (others => ' ');
      Old_Value  : ALB_Value := (Tag => Type_None);
   end record;
   type Saved_Var_Array is array (1 .. Max_Call_Args) of Saved_Var_Record;

   Last_Failure_Code : Oracle_Code := Err_None;
   Last_Failure_Node : Node_Index  := 0;

   function To_Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
   end To_Upper;

   function Trim_Leading_Space (S : String) return String is
      First : Natural := 0;
   begin
      for I in S'Range loop
         if S (I) /= ' ' then
            First := I;
            exit;
         end if;
      end loop;

      if First = 0 then
         return "";
      end if;

      return S (First .. S'Last);
   end Trim_Leading_Space;

   function Trimmed_Length (Name : Var_Name) return Natural is
   begin
      for I in reverse Name'Range loop
         if Name (I) /= ' ' then
            return I;
         end if;
      end loop;
      return 0;
   end Trimmed_Length;

   function Name_Text (Name : Var_Name) return String is
      Len : constant Natural := Trimmed_Length (Name);
   begin
      if Len = 0 then
         return "";
      end if;
      return Name (1 .. Len);
   end Name_Text;

   function Extract_Name (Source : String; T : Token) return Var_Name is
      Result : Var_Name := (others => ' ');
      Limit  : Natural := T.Length;
      Pos    : Natural := 1;
   begin
      if Limit > Max_Name_Length then
         Limit := Max_Name_Length;
      end if;

      for I in 0 .. Limit - 1 loop
         if T.Start + I in Source'Range then
            Result (Pos) := To_Upper (Source (T.Start + I));
            Pos := Pos + 1;
         end if;
      end loop;

      return Result;
   end Extract_Name;

   function Extract_String_Literal (Source : String; T : Token) return String is
      First : Natural := T.Start;
      Last  : Natural := T.Start + T.Length - 1;
   begin
      if T.Length = 0 or else First not in Source'Range or else Last not in Source'Range then
         return "";
      end if;

      if T.Length >= 2
        and then (Source (First) = '"' or else Source (First) = '`')
        and then Source (Last) = Source (First)
      then
         if Last > First + 1 then
            return Source (First + 1 .. Last - 1);
         else
            return "";
         end if;
      end if;

      return Source (First .. Last);
   end Extract_String_Literal;

   function Token_Lexeme (Source : String; T : Token) return String is
      Last : Natural := T.Start + T.Length - 1;
   begin
      if T.Length = 0 or else T.Start not in Source'Range or else Last not in Source'Range then
         return "";
      end if;
      return Source (T.Start .. Last);
   end Token_Lexeme;

   procedure Set_Failure
     (Node    : in Node_Index;
      Code    : in Oracle_Code;
      Success : out Boolean)
   is
   begin
      Last_Failure_Code := Code;
      Last_Failure_Node := Node;
      Success := False;
   end Set_Failure;

   procedure Clear_Last_Failure is
   begin
      Last_Failure_Code := Err_None;
      Last_Failure_Node := 0;
   end Clear_Last_Failure;

   procedure Get_Last_Failure (Code : out Oracle_Code; Node : out Node_Index) is
   begin
      Code := Last_Failure_Code;
      Node := Last_Failure_Node;
   end Get_Last_Failure;

   procedure Try_As_Integer
     (State   : in Engine_State;
      Val     : in ALB_Value;
      Number  : out Long_Integer;
      Success : out Boolean);

   procedure Try_As_Float
     (State   : in Engine_State;
      Val     : in ALB_Value;
      Number  : out Long_Float;
      Success : out Boolean);

   function Value_To_String
     (State : Engine_State;
      Val   : ALB_Value) return String;

   function Type_Tag_From_Name (Name : Var_Name) return ALB_Type_Tag is
      Text : constant String := Name_Text (Name);
   begin
      if Text = "U8" then
         return Type_U8;
      elsif Text = "U16" then
         return Type_U16;
      elsif Text = "U32" then
         return Type_U32;
      elsif Text = "U64" then
         return Type_U64;
      elsif Text = "U128" then
         return Type_U128;
      elsif Text = "S8" or else Text = "I8" or else Text = "INT8" then
         return Type_S8;
      elsif Text = "S16" or else Text = "I16" or else Text = "INT16" then
         return Type_S16;
      elsif Text = "S32" or else Text = "I32" or else Text = "INT32" then
         return Type_S32;
      elsif Text = "S64" or else Text = "I64" or else Text = "INT64" then
         return Type_S64;
      elsif Text = "S128" then
         return Type_S128;
      elsif Text = "F32" or else Text = "SINGLE" or else Text = "FLOAT" then
         return Type_F32;
      elsif Text = "F64" or else Text = "REAL" or else Text = "DOUBLE"
        or else Text = "NUMBER"
      then
         return Type_F64;
      elsif Text = "F128" then
         return Type_F128;
      elsif Text = "PURE" or else Text = "RATIONAL" then
         return Type_Pure;
      elsif Text = "HW8" then
         return Type_HW8;
      elsif Text = "HW16" then
         return Type_HW16;
      elsif Text = "HW32" then
         return Type_HW32;
      elsif Text = "HW64" then
         return Type_HW64;
      elsif Text = "BOOL" or else Text = "BOOLEAN" then
         return Type_Boolean;
      elsif Text = "STRING" then
         return Type_Binary;
      elsif Text = "BINARY" then
         return Type_Binary;
      elsif Text = "CHAR" then
         return Type_Char;
      else
         return Type_None;
      end if;
   end Type_Tag_From_Name;

   function Find_Named_Type (State : Engine_State; Name : Var_Name) return Natural is
   begin
      for I in 1 .. Max_Named_Types loop
         if State.Named_Types (I).Active and then State.Named_Types (I).Name = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Named_Type;

   function Resolve_Type_Tag
     (State : Engine_State;
      Name  : Var_Name) return ALB_Type_Tag
   is
      Slot : constant Natural := Find_Named_Type (State, Name);
      Tag  : constant ALB_Type_Tag := Type_Tag_From_Name (Name);
   begin
      if Tag /= Type_None then
         return Tag;
      elsif Slot /= 0 then
         return State.Named_Types (Slot).Base_Tag;
      else
         return Type_None;
      end if;
   end Resolve_Type_Tag;

   function Type_Name_From_Tag (Tag : ALB_Type_Tag) return String is
   begin
      case Tag is
         when Type_U8      => return "U8";
         when Type_U16     => return "U16";
         when Type_U32     => return "U32";
         when Type_U64     => return "U64";
         when Type_U128    => return "U128";
         when Type_S8      => return "S8";
         when Type_S16     => return "S16";
         when Type_S32     => return "S32";
         when Type_S64     => return "S64";
         when Type_S128    => return "S128";
         when Type_F32     => return "F32";
         when Type_F64     => return "F64";
         when Type_F128    => return "F128";
         when Type_Boolean => return "BOOL";
         when Type_Char    => return "CHAR";
         when Type_Pure    => return "PURE";
         when Type_HW8     => return "HW8";
         when Type_HW16    => return "HW16";
         when Type_HW32    => return "HW32";
         when Type_HW64    => return "HW64";
         when Type_Binary  => return "STRING";
         when others       => return "NONE";
      end case;
   end Type_Name_From_Tag;

   function Make_Name (Text : String) return Var_Name is
      Result : Var_Name := (others => ' ');
      Pos    : Natural := 1;
   begin
      for C of Text loop
         exit when Pos > Max_Name_Length;
         Result (Pos) := To_Upper (C);
         Pos := Pos + 1;
      end loop;
      return Result;
   end Make_Name;

   function Compose_Name (Left, Right : Var_Name) return Var_Name is
      Result : Var_Name := Left;
      Pos    : Natural := Trimmed_Length (Left) + 1;
      R_Text : constant String := Name_Text (Right);
   begin
      if Pos <= Max_Name_Length then
         Result (Pos) := '.';
         Pos := Pos + 1;
      end if;

      for C of R_Text loop
         exit when Pos > Max_Name_Length;
         Result (Pos) := C;
         Pos := Pos + 1;
      end loop;

      return Result;
   end Compose_Name;

   function Has_Qualifier (Name : Var_Name) return Boolean is
      Len : constant Natural := Trimmed_Length (Name);
   begin
      for I in 1 .. Len loop
         if Name (I) = '.' then
            return True;
         end if;
      end loop;
      return False;
   end Has_Qualifier;

   function In_Module_Scope (State : Engine_State) return Boolean is
   begin
      return Trimmed_Length (State.Current_Module) > 0;
   end In_Module_Scope;

   function Declaration_Name
     (State : Engine_State;
      Name  : Var_Name) return Var_Name
   is
   begin
      if In_Module_Scope (State) and then not Has_Qualifier (Name) then
         return Compose_Name (State.Current_Module, Name);
      else
         return Name;
      end if;
   end Declaration_Name;

   function Module_Prefix (Name : Var_Name) return Var_Name is
      Result : Var_Name := (others => ' ');
      Pos    : Natural := 1;
      Len    : constant Natural := Trimmed_Length (Name);
      Found  : Boolean := False;
   begin
      for I in 1 .. Len loop
         if Name (I) = '.' then
            Found := True;
            exit;
         end if;
         exit when Pos > Max_Name_Length;
         Result (Pos) := Name (I);
         Pos := Pos + 1;
      end loop;

      if Found then
         return Result;
      else
         return (others => ' ');
      end if;
   end Module_Prefix;

   function Find_Binary_Text
     (State : Engine_State;
      Text  : String) return Natural
   is
   begin
      for I in 1 .. Max_Binary_Slots loop
         if State.Binary_Bank (I).Active
           and then State.Binary_Bank (I).Length = Text'Length
           and then (Text'Length = 0
                     or else State.Binary_Bank (I).Data (1 .. Text'Length) = Text)
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Binary_Text;

   procedure Make_Binary_Value
     (State   : in out Engine_State;
      Text    : in String;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Slot : Natural := Find_Binary_Text (State, Text);
      Use_Len : constant Natural :=
        (if Text'Length > Max_Binary_Length then Max_Binary_Length else Text'Length);
   begin
      if Slot = 0 then
         for I in 1 .. Max_Binary_Slots loop
            if not State.Binary_Bank (I).Active then
               Slot := I;
               exit;
            end if;
         end loop;
      end if;

      if Slot = 0 then
         Result := (Tag => Type_None);
         Success := False;
         return;
      end if;

      State.Binary_Bank (Slot).Active := True;
      State.Binary_Bank (Slot).Length := Use_Len;
      State.Binary_Bank (Slot).Data := (others => ' ');
      if Use_Len > 0 then
         State.Binary_Bank (Slot).Data (1 .. Use_Len) := Text (Text'First .. Text'First + Use_Len - 1);
      end if;
      if Slot > State.Binary_Count then
         State.Binary_Count := Slot;
      end if;

      Result :=
        (Tag => Type_Binary,
         Val_Bin => (Block_Index => Slot, Offset => 0, Length => Use_Len));
      Success := True;
   end Make_Binary_Value;

   function Binary_To_String
     (State : Engine_State;
      Val   : ALB_Value) return String
   is
   begin
      if Val.Tag /= Type_Binary then
         return "";
      end if;

      declare
         Slot : constant Natural := Val.Val_Bin.Block_Index;
         Len  : constant Natural := Val.Val_Bin.Length;
      begin
         if Slot = 0
           or else Slot > Max_Binary_Slots
           or else not State.Binary_Bank (Slot).Active
         then
            return "";
         elsif Len = 0 then
            return "";
         elsif Len > State.Binary_Bank (Slot).Length then
            return State.Binary_Bank (Slot).Data (1 .. State.Binary_Bank (Slot).Length);
         else
            return State.Binary_Bank (Slot).Data (1 .. Len);
         end if;
      end;
   end Binary_To_String;

   function Trim_Text (Text : String) return String is
      First : Natural := 0;
      Last  : Natural := 0;
   begin
      for I in Text'Range loop
         if Text (I) /= ' '
           and then Text (I) /= ASCII.HT
           and then Text (I) /= ASCII.CR
           and then Text (I) /= ASCII.LF
         then
            First := I;
            exit;
         end if;
      end loop;

      if First = 0 then
         return "";
      end if;

      Last := First;
      for I in reverse Text'Range loop
         if Text (I) /= ' '
           and then Text (I) /= ASCII.HT
           and then Text (I) /= ASCII.CR
           and then Text (I) /= ASCII.LF
         then
            Last := I;
            exit;
         end if;
      end loop;

      return Text (First .. Last);
   end Trim_Text;

   procedure Parse_Integer_Text
     (Text    : in String;
      Number  : out Long_Integer;
      Success : out Boolean)
   is
      Clean    : constant String := Trim_Text (Text);
      Negative : Boolean := False;
      Start    : Positive := 1;
      Value    : Long_Integer := 0;
      Digit    : Long_Integer := 0;
   begin
      Number := 0;
      Success := False;
      if Clean'Length = 0 then
         return;
      end if;

      if Clean (Clean'First) = '+' then
         Start := Clean'First + 1;
      elsif Clean (Clean'First) = '-' then
         Negative := True;
         Start := Clean'First + 1;
      else
         Start := Clean'First;
      end if;

      if Start > Clean'Last then
         return;
      end if;

      for I in Start .. Clean'Last loop
         if Clean (I) not in '0' .. '9' then
            return;
         end if;
         Digit := Long_Integer (Character'Pos (Clean (I)) - Character'Pos ('0'));
         Value := (Value * 10) + Digit;
      end loop;

      if Negative then
         Number := -Value;
      else
         Number := Value;
      end if;
      Success := True;
   end Parse_Integer_Text;

   procedure Parse_Float_Text
     (Text    : in String;
      Number  : out Long_Float;
      Success : out Boolean)
   is
      Clean : constant String := Trim_Text (Text);
   begin
      if Clean'Length = 0 then
         Number := 0.0;
         Success := False;
         return;
      end if;

      Number := Long_Float'Value (Clean);
      Success := True;
   exception
      when others =>
         Number := 0.0;
         Success := False;
   end Parse_Float_Text;

   procedure Parse_Boolean_Text
     (Text    : in String;
      Value   : out Boolean;
      Success : out Boolean)
   is
      Clean : constant String := Trim_Text (Text);
      Upper : String (1 .. Clean'Length) := (others => ' ');
   begin
      if Clean'Length = 0 then
         Value := False;
         Success := False;
         return;
      end if;

      for I in Clean'Range loop
         Upper (I - Clean'First + 1) := To_Upper (Clean (I));
      end loop;

      if Upper = "TRUE" or else Upper = "YES" or else Upper = "ON" or else Upper = "1" then
         Value := True;
         Success := True;
      elsif Upper = "FALSE" or else Upper = "NO" or else Upper = "OFF" or else Upper = "0" then
         Value := False;
         Success := True;
      else
         Value := False;
         Success := False;
      end if;
   end Parse_Boolean_Text;

   function Runtime_File_Path (Info : Runtime_File_Record) return String is
   begin
      if Info.Path_Length = 0 then
         return "";
      else
         return Info.Path (1 .. Info.Path_Length);
      end if;
   end Runtime_File_Path;

   function Find_Free_Runtime_File (State : Engine_State) return Natural is
   begin
      for I in 1 .. Max_Open_Files loop
         if not State.Files (I).Active then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Free_Runtime_File;

   procedure Parse_File_Mode
     (Text    : in String;
      Mode    : out Runtime_File_Mode;
      Success : out Boolean)
   is
      Clean : constant String := Trim_Text (Text);
      Upper : String (1 .. Clean'Length) := (others => ' ');
   begin
      if Clean'Length = 0 then
         Mode := File_Mode_Read;
         Success := False;
         return;
      end if;

      for I in Clean'Range loop
         Upper (I - Clean'First + 1) := To_Upper (Clean (I));
      end loop;

      if Upper = "R" or else Upper = "RB" or else Upper = "READ" then
         Mode := File_Mode_Read;
         Success := True;
      elsif Upper = "W" or else Upper = "WB" or else Upper = "WRITE" then
         Mode := File_Mode_Write;
         Success := True;
      elsif Upper = "A" or else Upper = "AB" or else Upper = "APPEND" then
         Mode := File_Mode_Append;
         Success := True;
      else
         Mode := File_Mode_Read;
         Success := False;
      end if;
   end Parse_File_Mode;

   procedure Read_Console_Line
     (Prompt  : in String;
      State   : in out Engine_State;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Buffer : String (1 .. Max_Binary_Length) := (others => ' ');
      Last   : Natural := 0;
   begin
      if Prompt'Length > 0 then
         Put (Prompt);
         if Prompt (Prompt'Last) /= ' ' then
            Put (" ");
         end if;
      end if;

      Get_Line (Buffer, Last);
      if Last = 0 then
         Make_Binary_Value (State, "", Result, Success);
      else
         Make_Binary_Value (State, Buffer (1 .. Last), Result, Success);
      end if;
   exception
      when others =>
         Result := (Tag => Type_None);
         Success := False;
   end Read_Console_Line;

   procedure Resolve_File_Handle
     (State   : in Engine_State;
      Handle  : in ALB_Value;
      Slot    : out Natural;
      Success : out Boolean)
   is
      Handle_Num : Long_Integer := 0;
   begin
      Try_As_Integer (State, Handle, Handle_Num, Success);
      if not Success
        or else Handle_Num < 1
        or else Handle_Num > Max_Open_Files
      then
         Slot := 0;
         Success := False;
         return;
      end if;

      Slot := Natural (Handle_Num);
      Success := State.Files (Slot).Active;
      if not Success then
         Slot := 0;
      end if;
   end Resolve_File_Handle;

   procedure Runtime_Load_File
     (State    : in out Engine_State;
      Path     : in String;
      Max_Read : in Natural;
      Result   : out ALB_Value;
      Success  : out Boolean)
   is
      use Ada.Streams;
      File      : Ada.Streams.Stream_IO.File_Type;
      Buffer    : Stream_Element_Array (1 .. Stream_Element_Offset (Max_Binary_Length));
      Last      : Stream_Element_Offset := 0;
      Text      : String (1 .. Max_Binary_Length) := (others => ' ');
      Use_Read  : constant Natural := Natural'Min (Max_Read, Max_Binary_Length);
      Text_Len  : Natural := 0;
   begin
      if Use_Read = 0 then
         Make_Binary_Value (State, "", Result, Success);
         return;
      end if;

      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      Ada.Streams.Stream_IO.Read
        (File,
         Buffer (1 .. Stream_Element_Offset (Use_Read)),
         Last);

      if Last > 0 then
         Text_Len := Natural (Last);
         for I in 1 .. Text_Len loop
            Text (I) := Character'Val (Integer (Buffer (Stream_Element_Offset (I))));
         end loop;
         Make_Binary_Value (State, Text (1 .. Text_Len), Result, Success);
      else
         Make_Binary_Value (State, "", Result, Success);
      end if;

      if Ada.Streams.Stream_IO.Is_Open (File) then
         Ada.Streams.Stream_IO.Close (File);
      end if;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Result := (Tag => Type_None);
         Success := False;
   end Runtime_Load_File;

   procedure Runtime_Open_File
     (State     : in out Engine_State;
      Path_Text : in String;
      Mode_Text : in String;
      Result    : out ALB_Value;
      Success   : out Boolean)
   is
      Path : constant String := Trim_Text (Path_Text);
      Slot : Natural := 0;
      Mode : Runtime_File_Mode := File_Mode_Read;
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Result := (Tag => Type_None);
      if Path'Length = 0 or else Path'Length > Max_File_Path_Length then
         Success := False;
         return;
      end if;

      Parse_File_Mode (Mode_Text, Mode, Success);
      if not Success then
         return;
      end if;

      Slot := Find_Free_Runtime_File (State);
      if Slot = 0 then
         Success := False;
         return;
      end if;

      if Mode = File_Mode_Write then
         Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
         Ada.Streams.Stream_IO.Close (File);
      elsif Mode = File_Mode_Append and then not Ada.Directories.Exists (Path) then
         Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
         Ada.Streams.Stream_IO.Close (File);
      elsif Mode = File_Mode_Read and then not Ada.Directories.Exists (Path) then
         Success := False;
         return;
      end if;

      State.Files (Slot).Active := True;
      State.Files (Slot).Path_Length := Path'Length;
      State.Files (Slot).Path := (others => ' ');
      State.Files (Slot).Path (1 .. Path'Length) := Path;
      State.Files (Slot).Mode := Mode;
      State.Files (Slot).Position := 0;
      Result := (Tag => Type_U64, Val_U64 => U64 (Slot));
      Success := True;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Result := (Tag => Type_None);
         Success := False;
   end Runtime_Open_File;

   procedure Runtime_Read_File
     (State        : in out Engine_State;
      Handle_Value : in ALB_Value;
      Count_Value  : in ALB_Value;
      Result       : out ALB_Value;
      Success      : out Boolean)
   is
      use Ada.Streams;
      Slot       : Natural := 0;
      Read_Count : Long_Integer := 0;
      Use_Read   : Natural := 0;
      File       : Ada.Streams.Stream_IO.File_Type;
      File_Size  : Natural := 0;
      Last       : Stream_Element_Offset := 0;
      Buffer     : Stream_Element_Array (1 .. Stream_Element_Offset (Max_Binary_Length));
      Text       : String (1 .. Max_Binary_Length) := (others => ' ');
      Text_Len   : Natural := 0;
   begin
      Resolve_File_Handle (State, Handle_Value, Slot, Success);
      if not Success or else State.Files (Slot).Mode /= File_Mode_Read then
         Result := (Tag => Type_None);
         Success := False;
         return;
      end if;

      Try_As_Integer (State, Count_Value, Read_Count, Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      if Read_Count <= 0 then
         Make_Binary_Value (State, "", Result, Success);
         return;
      end if;

      Use_Read := Natural'Min (Natural (Read_Count), Max_Binary_Length);
      Ada.Streams.Stream_IO.Open
        (File,
         Ada.Streams.Stream_IO.In_File,
         Runtime_File_Path (State.Files (Slot)));
      File_Size := Natural (Ada.Streams.Stream_IO.Size (File));
      if State.Files (Slot).Position >= File_Size then
         Make_Binary_Value (State, "", Result, Success);
      else
         Ada.Streams.Stream_IO.Set_Index
           (File,
            Ada.Streams.Stream_IO.Positive_Count (State.Files (Slot).Position + 1));
         Ada.Streams.Stream_IO.Read
           (File,
            Buffer (1 .. Stream_Element_Offset (Use_Read)),
            Last);
         Text_Len := Natural (Last);
         for I in 1 .. Text_Len loop
            Text (I) := Character'Val (Integer (Buffer (Stream_Element_Offset (I))));
         end loop;
         State.Files (Slot).Position := State.Files (Slot).Position + Text_Len;
         if Text_Len = 0 then
            Make_Binary_Value (State, "", Result, Success);
         else
            Make_Binary_Value (State, Text (1 .. Text_Len), Result, Success);
         end if;
      end if;

      if Ada.Streams.Stream_IO.Is_Open (File) then
         Ada.Streams.Stream_IO.Close (File);
      end if;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Result := (Tag => Type_None);
         Success := False;
   end Runtime_Read_File;

   procedure Runtime_Write_File
     (State        : in out Engine_State;
      Handle_Value : in ALB_Value;
      Data_Value   : in ALB_Value;
      Success      : out Boolean)
   is
      use Ada.Streams;
      Slot     : Natural := 0;
      Data     : constant String := Value_To_String (State, Data_Value);
      File     : Ada.Streams.Stream_IO.File_Type;
   begin
      Resolve_File_Handle (State, Handle_Value, Slot, Success);
      if not Success or else State.Files (Slot).Mode = File_Mode_Read then
         Success := False;
         return;
      end if;

      if Data'Length = 0 then
         Success := True;
         return;
      end if;

      declare
         Buffer : Stream_Element_Array (1 .. Stream_Element_Offset (Data'Length));
      begin
         for I in Data'Range loop
            Buffer (Stream_Element_Offset (I - Data'First + 1)) :=
              Stream_Element (Character'Pos (Data (I)));
         end loop;

         if Ada.Directories.Exists (Runtime_File_Path (State.Files (Slot))) then
            Ada.Streams.Stream_IO.Open
              (File,
               Ada.Streams.Stream_IO.Append_File,
               Runtime_File_Path (State.Files (Slot)));
         else
            Ada.Streams.Stream_IO.Create
              (File,
               Ada.Streams.Stream_IO.Out_File,
               Runtime_File_Path (State.Files (Slot)));
         end if;

         Ada.Streams.Stream_IO.Write (File, Buffer);
         State.Files (Slot).Position := State.Files (Slot).Position + Data'Length;
      end;

      if Ada.Streams.Stream_IO.Is_Open (File) then
         Ada.Streams.Stream_IO.Close (File);
      end if;
      Success := True;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Success := False;
   end Runtime_Write_File;

   procedure Runtime_Close_File
     (State        : in out Engine_State;
      Handle_Value : in ALB_Value;
      Success      : out Boolean)
   is
      Slot : Natural := 0;
   begin
      Resolve_File_Handle (State, Handle_Value, Slot, Success);
      if not Success then
         return;
      end if;

      State.Files (Slot) :=
        (Active => False,
         Path_Length => 0,
         Path => (others => ' '),
         Mode => File_Mode_Read,
         Position => 0);
      Success := True;
   end Runtime_Close_File;

   procedure Runtime_File_Len
     (State     : in out Engine_State;
      Path_Text : in String;
      Result    : out ALB_Value;
      Success   : out Boolean)
   is
      Path : constant String := Trim_Text (Path_Text);
      Sz   : Ada.Directories.File_Size := 0;
   begin
      Result := (Tag => Type_U64, Val_U64 => 0);
      Success := True;
      if Path'Length = 0 or else not Ada.Directories.Exists (Path) then
         if State.Files (1).Active then
            Result := (Tag => Type_U64, Val_U64 => 0);
         end if;
         return;
      end if;
      Sz := Ada.Directories.Size (Path);
      Result := (Tag => Type_U64, Val_U64 => U64 (Sz));
   exception
      when others =>
         Result := (Tag => Type_U64, Val_U64 => 0);
         Success := True;
   end Runtime_File_Len;

   procedure Runtime_File_Seek
     (State        : in out Engine_State;
      Handle_Value : in ALB_Value;
      Offset_Value : in ALB_Value;
      Result       : out ALB_Value;
      Success      : out Boolean)
   is
      Slot   : Natural := 0;
      Off    : Long_Integer := 0;
   begin
      Result := (Tag => Type_U64, Val_U64 => 0);
      Resolve_File_Handle (State, Handle_Value, Slot, Success);
      if not Success then
         Success := True;
         return;
      end if;
      Try_As_Integer (State, Offset_Value, Off, Success);
      if not Success or else Off < 0 then
         Result := (Tag => Type_U64, Val_U64 => 0);
         Success := True;
         return;
      end if;
      State.Files (Slot).Position := Natural (Off);
      Result := (Tag => Type_U64, Val_U64 => U64 (State.Files (Slot).Position));
      Success := True;
   end Runtime_File_Seek;

   procedure Runtime_Flush_File
     (Data_Text : in String;
      Path_Text : in String;
      Success   : out Boolean)
   is
      use Ada.Streams;
      File : Ada.Streams.Stream_IO.File_Type;
      Path : constant String := Trim_Text (Path_Text);
   begin
      if Path'Length = 0 or else Path'Length > Max_File_Path_Length then
         Success := False;
         return;
      end if;

      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      if Data_Text'Length > 0 then
         declare
            Buffer : Stream_Element_Array (1 .. Stream_Element_Offset (Data_Text'Length));
         begin
            for I in Data_Text'Range loop
               Buffer (Stream_Element_Offset (I - Data_Text'First + 1)) :=
                 Stream_Element (Character'Pos (Data_Text (I)));
            end loop;
            Ada.Streams.Stream_IO.Write (File, Buffer);
         end;
      end if;

      if Ada.Streams.Stream_IO.Is_Open (File) then
         Ada.Streams.Stream_IO.Close (File);
      end if;
      Success := True;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Success := False;
   end Runtime_Flush_File;

   function Value_To_String
     (State : Engine_State;
      Val   : ALB_Value) return String
   is
   begin
      case Val.Tag is
         when Type_U8 =>
            return Trim_Leading_Space (U8'Image (Val.Val_U8));
         when Type_U16 =>
            return Trim_Leading_Space (U16'Image (Val.Val_U16));
         when Type_U32 =>
            return Trim_Leading_Space (U32'Image (Val.Val_U32));
         when Type_U64 =>
            return Trim_Leading_Space (U64'Image (Val.Val_U64));
         when Type_U128 =>
            return Trim_Leading_Space (U64'Image (Val.Val_U128.Low));
         when Type_S8 =>
            return Trim_Leading_Space (S8'Image (Val.Val_S8));
         when Type_S16 =>
            return Trim_Leading_Space (S16'Image (Val.Val_S16));
         when Type_S32 =>
            return Trim_Leading_Space (S32'Image (Val.Val_S32));
         when Type_S64 =>
            return Trim_Leading_Space (S64'Image (Val.Val_S64));
         when Type_S128 =>
            return Trim_Leading_Space (S64'Image (Val.Val_S128.High));
         when Type_F32 =>
            declare
               F : constant Long_Float := Long_Float (Val.Val_F32);
            begin
               if F = Long_Float'Floor (F) and then F >= Long_Float (Long_Integer'First) and then F <= Long_Float (Long_Integer'Last) then
                  return Trim_Leading_Space (Long_Integer'Image (Long_Integer (F)));
               else
                  return Trim_Leading_Space (F32'Image (Val.Val_F32));
               end if;
            end;
         when Type_F64 =>
            declare
               F : constant Long_Float := Long_Float (Val.Val_F64);
            begin
               if F = Long_Float'Floor (F) and then F >= Long_Float (Long_Integer'First) and then F <= Long_Float (Long_Integer'Last) then
                  return Trim_Leading_Space (Long_Integer'Image (Long_Integer (F)));
               else
                  return Trim_Leading_Space (F64'Image (Val.Val_F64));
               end if;
            end;
         when Type_F128 =>
            return Trim_Leading_Space (F64'Image (Val.Val_F128.High));
         when Type_Pure =>
            return
              Trim_Leading_Space (Long_Integer'Image (Val.Val_Pure.Num))
              & "/"
              & Trim_Leading_Space (Long_Integer'Image (Val.Val_Pure.Den));
         when Type_Boolean =>
            return (if Val.Val_Bool then "TRUE" else "FALSE");
         when Type_Char =>
            return String'(1 => Val.Val_Char);
         when Type_HW8 =>
            return Trim_Leading_Space (U8'Image (Val.Val_HW8.Value));
         when Type_HW16 =>
            return Trim_Leading_Space (U16'Image (Val.Val_HW16.Value));
         when Type_HW32 =>
            return Trim_Leading_Space (U32'Image (Val.Val_HW32.Value));
         when Type_HW64 =>
            return Trim_Leading_Space (U64'Image (Val.Val_HW64.Value));
         when Type_Binary =>
            return Binary_To_String (State, Val);
         when others =>
            return "";
      end case;
   end Value_To_String;

   procedure Default_Value
     (Tag     : in ALB_Type_Tag;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      P_Zero : Pure_Rational;
   begin
      Success := True;
      case Tag is
         when Type_None =>
            Result := (Tag => Type_None);
         when Type_U8 =>
            Result := (Tag => Type_U8, Val_U8 => 0);
         when Type_U16 =>
            Result := (Tag => Type_U16, Val_U16 => 0);
         when Type_U32 =>
            Result := (Tag => Type_U32, Val_U32 => 0);
         when Type_U64 =>
            Result := (Tag => Type_U64, Val_U64 => 0);
         when Type_U128 =>
            Result := (Tag => Type_U128, Val_U128 => (High => 0, Low => 0));
         when Type_S8 =>
            Result := (Tag => Type_S8, Val_S8 => 0);
         when Type_S16 =>
            Result := (Tag => Type_S16, Val_S16 => 0);
         when Type_S32 =>
            Result := (Tag => Type_S32, Val_S32 => 0);
         when Type_S64 =>
            Result := (Tag => Type_S64, Val_S64 => 0);
         when Type_S128 =>
            Result := (Tag => Type_S128, Val_S128 => (High => 0, Low => 0));
         when Type_F32 =>
            Result := (Tag => Type_F32, Val_F32 => 0.0);
         when Type_F64 =>
            Result := (Tag => Type_F64, Val_F64 => 0.0);
         when Type_F128 =>
            Result := (Tag => Type_F128, Val_F128 => (High => 0.0, Low => 0.0));
         when Type_Boolean =>
            Result := (Tag => Type_Boolean, Val_Bool => False);
         when Type_Char =>
            Result := (Tag => Type_Char, Val_Char => ASCII.NUL);
         when Type_Pure =>
            Create_Pure (0, 1, P_Zero, Success);
            if Success then
               Result := (Tag => Type_Pure, Val_Pure => P_Zero);
            else
               Result := (Tag => Type_None);
            end if;
         when Type_HW8 =>
            Result := (Tag => Type_HW8, Val_HW8 => (Value => 0));
         when Type_HW16 =>
            Result := (Tag => Type_HW16, Val_HW16 => (Value => 0));
         when Type_HW32 =>
            Result := (Tag => Type_HW32, Val_HW32 => (Value => 0));
         when Type_HW64 =>
            Result := (Tag => Type_HW64, Val_HW64 => (Value => 0));
         when Type_Binary =>
            Result := (Tag => Type_Binary, Val_Bin => (Block_Index => 0, Offset => 0, Length => 0));
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Default_Value;

   procedure Try_As_Float
     (State   : in Engine_State;
      Val     : in ALB_Value;
      Number  : out Long_Float;
      Success : out Boolean)
   is
      Slash      : Natural := 0;
      Numerator  : Long_Integer := 0;
      Denominator : Long_Integer := 1;
   begin
      Success := True;
      case Val.Tag is
         when Type_U8 =>
            Number := Long_Float (Val.Val_U8);
         when Type_U16 =>
            Number := Long_Float (Val.Val_U16);
         when Type_U32 =>
            Number := Long_Float (Val.Val_U32);
         when Type_U64 =>
            Number := Long_Float (Val.Val_U64);
         when Type_U128 =>
            Number := Long_Float (Val.Val_U128.Low);
         when Type_S8 =>
            Number := Long_Float (Val.Val_S8);
         when Type_S16 =>
            Number := Long_Float (Val.Val_S16);
         when Type_S32 =>
            Number := Long_Float (Val.Val_S32);
         when Type_S64 =>
            Number := Long_Float (Val.Val_S64);
         when Type_S128 =>
            Number := Long_Float (Val.Val_S128.High);
         when Type_F32 =>
            Number := Long_Float (Val.Val_F32);
         when Type_F64 =>
            Number := Long_Float (Val.Val_F64);
         when Type_F128 =>
            Number := Long_Float (Val.Val_F128.High);
         when Type_Pure =>
            Number := Long_Float (Val.Val_Pure.Num) / Long_Float (Val.Val_Pure.Den);
         when Type_Boolean =>
            Number := Long_Float (Boolean'Pos (Val.Val_Bool));
         when Type_Char =>
            Number := Long_Float (Character'Pos (Val.Val_Char));
         when Type_HW8 =>
            Number := Long_Float (Val.Val_HW8.Value);
         when Type_HW16 =>
            Number := Long_Float (Val.Val_HW16.Value);
         when Type_HW32 =>
            Number := Long_Float (Val.Val_HW32.Value);
         when Type_HW64 =>
            Number := Long_Float (Val.Val_HW64.Value);
         when Type_Binary =>
            declare
               Clean : constant String := Trim_Text (Binary_To_String (State, Val));
            begin
               Parse_Float_Text (Clean, Number, Success);
               if not Success and then Clean'Length > 0 then
                  for I in Clean'Range loop
                     if Clean (I) = '/' then
                        Slash := I;
                        exit;
                     end if;
                  end loop;

                  if Slash /= 0 then
                     if Slash = Clean'First or else Slash = Clean'Last then
                        Number := 0.0;
                        Success := False;
                        return;
                     end if;

                     declare
                        Num_Text : constant String :=
                          Trim_Text (Clean (Clean'First .. Slash - 1));
                        Den_Text : constant String :=
                          Trim_Text (Clean (Slash + 1 .. Clean'Last));
                     begin
                        Parse_Integer_Text (Num_Text, Numerator, Success);
                        if Success then
                           Parse_Integer_Text (Den_Text, Denominator, Success);
                        end if;

                        if Success and then Denominator /= 0 then
                           Number :=
                             Long_Float (Numerator) / Long_Float (Denominator);
                        else
                           Number := 0.0;
                           Success := False;
                        end if;
                     end;
                  else
                     Number := 0.0;
                  end if;
               end if;
            end;
         when others =>
            Number := 0.0;
            Success := False;
      end case;
   end Try_As_Float;

   function Truncate_Toward_Zero (Value : Long_Float) return Long_Integer is
      Magnitude : constant Long_Float :=
        Long_Float'Floor (abs Value);
   begin
      if Value < 0.0 then
         return -Long_Integer (Magnitude);
      else
         return Long_Integer (Magnitude);
      end if;
   end Truncate_Toward_Zero;

   procedure Try_As_Integer
     (State   : in Engine_State;
      Val     : in ALB_Value;
      Number  : out Long_Integer;
      Success : out Boolean)
   is
      Temp : Long_Float;
   begin
      case Val.Tag is
         when Type_U8 =>
            Number := Long_Integer (Val.Val_U8);
            Success := True;
         when Type_U16 =>
            Number := Long_Integer (Val.Val_U16);
            Success := True;
         when Type_U32 =>
            Number := Long_Integer (Val.Val_U32);
            Success := True;
         when Type_U64 =>
            Number := Long_Integer (Val.Val_U64);
            Success := True;
         when Type_U128 =>
            Number := Long_Integer (Val.Val_U128.Low);
            Success := True;
         when Type_S8 =>
            Number := Long_Integer (Val.Val_S8);
            Success := True;
         when Type_S16 =>
            Number := Long_Integer (Val.Val_S16);
            Success := True;
         when Type_S32 =>
            Number := Long_Integer (Val.Val_S32);
            Success := True;
         when Type_S64 =>
            Number := Long_Integer (Val.Val_S64);
            Success := True;
         when Type_S128 =>
            Number := Long_Integer (Val.Val_S128.High);
            Success := True;
         when Type_Pure =>
            if Val.Val_Pure.Den = 0 then
               Number := 0;
               Success := False;
            else
               Number := Val.Val_Pure.Num / Val.Val_Pure.Den;
               Success := True;
            end if;
         when Type_Boolean =>
            Number := Boolean'Pos (Val.Val_Bool);
            Success := True;
         when Type_Char =>
            Number := Character'Pos (Val.Val_Char);
            Success := True;
         when Type_HW8 =>
            Number := Long_Integer (Val.Val_HW8.Value);
            Success := True;
         when Type_HW16 =>
            Number := Long_Integer (Val.Val_HW16.Value);
            Success := True;
         when Type_HW32 =>
            Number := Long_Integer (Val.Val_HW32.Value);
            Success := True;
         when Type_HW64 =>
            Number := Long_Integer (Val.Val_HW64.Value);
            Success := True;
         when Type_Binary =>
            Parse_Integer_Text (Binary_To_String (State, Val), Number, Success);
            if not Success then
               Try_As_Float (State, Val, Temp, Success);
               if Success then
                  Number := Truncate_Toward_Zero (Temp);
               else
                  Number := 0;
               end if;
            end if;
         when others =>
            Try_As_Float (State, Val, Temp, Success);
            if Success then
               Number := Truncate_Toward_Zero (Temp);
            else
               Number := 0;
            end if;
      end case;
   end Try_As_Integer;

   --  procedure Try_As_Whole_Integer
   --    (State   : in Engine_State;
   --     Val     : in ALB_Value;
   --     Number  : out Long_Integer;
   --     Success : out Boolean)
   --  is
   --     Temp        : Long_Float := 0.0;
   --     Slash       : Natural := 0;
   --     Numerator   : Long_Integer := 0;
   --     Denominator : Long_Integer := 1;
   --  begin
   --     Success := True;
   --     case Val.Tag is
   --        when Type_U8 =>
   --           Number := Long_Integer (Val.Val_U8);
   --        when Type_U16 =>
   --           Number := Long_Integer (Val.Val_U16);
   --        when Type_U32 =>
   --           Number := Long_Integer (Val.Val_U32);
   --        when Type_U64 =>
   --           Number := Long_Integer (Val.Val_U64);
   --        when Type_S8 =>
   --           Number := Long_Integer (Val.Val_S8);
   --        when Type_S16 =>
   --           Number := Long_Integer (Val.Val_S16);
   --        when Type_S32 =>
   --           Number := Long_Integer (Val.Val_S32);
   --        when Type_S64 =>
   --           Number := Long_Integer (Val.Val_S64);
   --        when Type_F32 | Type_F64 | Type_F128 =>
   --           Try_As_Float (State, Val, Temp, Success);
   --           if Success then
   --              Number := Long_Integer (Temp);
   --              Success := Long_Float (Number) = Temp;
   --           else
   --              Number := 0;
   --           end if;
   --        when Type_Pure =>
   --           if Val.Val_Pure.Den /= 0
   --             and then (Val.Val_Pure.Num mod Val.Val_Pure.Den = 0)
   --           then
   --              Number := Val.Val_Pure.Num / Val.Val_Pure.Den;
   --           else
   --              Number := 0;
   --              Success := False;
   --           end if;
   --        when Type_Boolean =>
   --           Number := Boolean'Pos (Val.Val_Bool);
   --        when Type_Char =>
   --           Number := Character'Pos (Val.Val_Char);
   --        when Type_HW8 =>
   --           Number := Long_Integer (Val.Val_HW8.Value);
   --        when Type_HW16 =>
   --           Number := Long_Integer (Val.Val_HW16.Value);
   --        when Type_HW32 =>
   --           Number := Long_Integer (Val.Val_HW32.Value);
   --        when Type_HW64 =>
   --           Number := Long_Integer (Val.Val_HW64.Value);
   --        when Type_Binary =>
   --           declare
   --              Clean : constant String := Trim_Text (Binary_To_String (State, Val));
   --           begin
   --              Parse_Integer_Text (Clean, Number, Success);
   --              if Success then
   --                 return;
   --              end if;
   --
   --              if Clean'Length > 0 then
   --                 for I in Clean'Range loop
   --                    if Clean (I) = '/' then
   --                       Slash := I;
   --                       exit;
   --                    end if;
   --                 end loop;
   --              end if;
   --
   --              if Slash /= 0 then
   --                 if Slash = Clean'First or else Slash = Clean'Last then
   --                    Number := 0;
   --                    Success := False;
   --                    return;
   --                 end if;
   --
   --                 declare
   --                    Num_Text : constant String :=
   --                      Trim_Text (Clean (Clean'First .. Slash - 1));
   --                    Den_Text : constant String :=
   --                      Trim_Text (Clean (Slash + 1 .. Clean'Last));
   --                 begin
   --                    Parse_Integer_Text (Num_Text, Numerator, Success);
   --                    if Success then
   --                       Parse_Integer_Text (Den_Text, Denominator, Success);
   --                    end if;
   --
   --                    if Success
   --                      and then Denominator /= 0
   --                      and then Numerator mod Denominator = 0
   --                    then
   --                       Number := Numerator / Denominator;
   --                       Success := True;
   --                    else
   --                       Number := 0;
   --                       Success := False;
   --                    end if;
   --                 end;
   --              else
   --                 Try_As_Float (State, Val, Temp, Success);
   --                 if Success then
   --                    Number := Long_Integer (Temp);
   --                    Success := Long_Float (Number) = Temp;
   --                 else
   --                    Number := 0;
   --                 end if;
   --              end if;
   --           end;
   --        when others =>
   --           Number := 0;
   --           Success := False;
   --     end case;
   --  end Try_As_Whole_Integer;

   procedure Try_As_Whole_Integer
     (State   : in Engine_State;
      Val     : in ALB_Value;
      Number  : out Long_Integer;
      Success : out Boolean)
   is
   begin
      -- Da operand shield is gone!
      -- We bypass da strict whole-number math checks an' just truncate dynamically.
      Try_As_Integer (State, Val, Number, Success);

      -- Let them shoot themselves! Never fail on integer coercion.
      if not Success then
         Number := 0;
         Success := True;
      end if;
   end Try_As_Whole_Integer;

   procedure Try_As_Pure_Operand
     (State   : in Engine_State;
      Val     : in ALB_Value;
      Number  : out Pure_Rational;
      Success : out Boolean)
   is
      Int_Val     : Long_Integer := 0;
      Slash       : Natural := 0;
      Numerator   : Long_Integer := 0;
      Denominator : Long_Integer := 1;
   begin
      if Val.Tag = Type_Pure then
         Number := Val.Val_Pure;
         Success := True;
      elsif Val.Tag = Type_Binary then
         declare
            Clean : constant String := Trim_Text (Binary_To_String (State, Val));
         begin
            for I in Clean'Range loop
               if Clean (I) = '/' then
                  Slash := I;
                  exit;
               end if;
            end loop;

            if Slash = 0 then
               Try_As_Whole_Integer (State, Val, Int_Val, Success);
               if Success then
                  Create_Pure (Int_Val, 1, Number, Success);
               else
                  Number := (Num => 0, Den => 1);
               end if;
            else
               if Slash = Clean'First or else Slash = Clean'Last then
                  Number := (Num => 0, Den => 1);
                  Success := False;
                  return;
               end if;

               declare
                  Num_Text : constant String :=
                    Trim_Text (Clean (Clean'First .. Slash - 1));
                  Den_Text : constant String :=
                    Trim_Text (Clean (Slash + 1 .. Clean'Last));
               begin
                  Parse_Integer_Text (Num_Text, Numerator, Success);
                  if Success then
                     Parse_Integer_Text (Den_Text, Denominator, Success);
                  end if;

                  if Success then
                     Create_Pure (Numerator, Denominator, Number, Success);
                  else
                     Number := (Num => 0, Den => 1);
                  end if;
               end;
            end if;
         end;
      else
         Try_As_Whole_Integer (State, Val, Int_Val, Success);
         if Success then
            Create_Pure (Int_Val, 1, Number, Success);
         else
            Number := (Num => 0, Den => 1);
         end if;
      end if;
   end Try_As_Pure_Operand;

   function Is_Hardware_Tag (Tag : ALB_Type_Tag) return Boolean is
   begin
      return Tag = Type_HW8
        or else Tag = Type_HW16
        or else Tag = Type_HW32
        or else Tag = Type_HW64;
   end Is_Hardware_Tag;

   function Is_Float_Tag (Tag : ALB_Type_Tag) return Boolean is
   begin
      return Tag = Type_F32
        or else Tag = Type_F64
        or else Tag = Type_F128;
   end Is_Float_Tag;

   function Is_Discrete_Tag (Tag : ALB_Type_Tag) return Boolean is
   begin
      return Tag = Type_U8
        or else Tag = Type_U16
        or else Tag = Type_U32
        or else Tag = Type_U64
        or else Tag = Type_U128
        or else Tag = Type_S8
        or else Tag = Type_S16
        or else Tag = Type_S32
        or else Tag = Type_S64
        or else Tag = Type_S128
        or else Tag = Type_Boolean
        or else Tag = Type_Char
        or else Is_Hardware_Tag (Tag);
   end Is_Discrete_Tag;

   function Is_Text_Tag (Tag : ALB_Type_Tag) return Boolean is
   begin
      return Tag = Type_Binary or else Tag = Type_Char;
   end Is_Text_Tag;

   function Discrete_Rank (Tag : ALB_Type_Tag) return Natural is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_Boolean | Type_Char | Type_HW8 =>
            return 1;
         when Type_U16 | Type_S16 | Type_HW16 =>
            return 2;
         when Type_U32 | Type_S32 | Type_HW32 =>
            return 3;
         when Type_U64 | Type_S64 | Type_U128 | Type_S128 | Type_HW64 =>
            return 4;
         when others =>
            return 0;
      end case;
   end Discrete_Rank;

   function Float_Target_For_Coercion
     (Left_Tag  : in ALB_Type_Tag;
      Right_Tag : in ALB_Type_Tag) return ALB_Type_Tag
   is
      Use_F32 : constant Boolean :=
        Left_Tag = Type_F32 or else Right_Tag = Type_F32;
      Use_F64 : constant Boolean :=
        Left_Tag = Type_F64
        or else Right_Tag = Type_F64
        or else Left_Tag = Type_F128
        or else Right_Tag = Type_F128
        or else Left_Tag = Type_Pure
        or else Right_Tag = Type_Pure
        or else Left_Tag = Type_Binary
        or else Right_Tag = Type_Binary;
   begin
      if Use_F64 then
         return Type_F64;
      elsif Use_F32 then
         return Type_F32;
      else
         return Type_F64;
      end if;
   end Float_Target_For_Coercion;

   function Discrete_Target_For_Coercion
     (Left_Tag  : in ALB_Type_Tag;
      Right_Tag : in ALB_Type_Tag) return ALB_Type_Tag
   is
      Rank       : Natural := 0;
      Use_Signed : Boolean := False;

      procedure Consider (Tag : in ALB_Type_Tag) is
         Tag_Rank : constant Natural := Discrete_Rank (Tag);
      begin
         if Tag_Rank > Rank then
            Rank := Tag_Rank;
         end if;

         if Tag = Type_S8
           or else Tag = Type_S16
           or else Tag = Type_S32
           or else Tag = Type_S64
           or else Tag = Type_S128
         then
            Use_Signed := True;
         end if;
      end Consider;
   begin
      Consider (Left_Tag);
      Consider (Right_Tag);

      if Rank = 0 then
         return Type_S64;
      elsif Use_Signed then
         case Rank is
            when 1 => return Type_S8;
            when 2 => return Type_S16;
            when 3 => return Type_S32;
            when others => return Type_S64;
         end case;
      else
         case Rank is
            when 1 => return Type_U8;
            when 2 => return Type_U16;
            when 3 => return Type_U32;
            when others => return Type_U64;
         end case;
      end if;
   end Discrete_Target_For_Coercion;

   type Coercion_Context is
     (Context_Assignment,
      Context_Parameter,
      Context_Arithmetic,
      Context_Addition,
      Context_Comparison,
      Context_Logical);

   procedure Cast_Value
     (State   : in out Engine_State;
      Target  : in ALB_Type_Tag;
      Source  : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Int_Val : Long_Integer := 0;
      F_Val   : Long_Float := 0.0;
      P_Val   : Pure_Rational;
      B_Val   : Boolean := False;
   begin
      if Source.Tag = Target then
         Result := Source;
         Success := True;
         return;
      end if;

      case Target is
         when Type_U8 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_U8, Val_U8 => U8 (Int_Val)); end if;
         when Type_U16 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_U16, Val_U16 => U16 (Int_Val)); end if;
         when Type_U32 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_U32, Val_U32 => U32 (Int_Val)); end if;
         when Type_U64 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_U64, Val_U64 => U64 (Int_Val)); end if;
         when Type_U128 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then
               Result := (Tag => Type_U128, Val_U128 => (High => 0, Low => U64 (Int_Val)));
            end if;
         when Type_S8 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_S8, Val_S8 => S8 (Int_Val)); end if;
         when Type_S16 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_S16, Val_S16 => S16 (Int_Val)); end if;
         when Type_S32 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_S32, Val_S32 => S32 (Int_Val)); end if;
         when Type_S64 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_S64, Val_S64 => S64 (Int_Val)); end if;
         when Type_S128 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then
               Result := (Tag => Type_S128, Val_S128 => (High => S64 (Int_Val), Low => 0));
            end if;
         when Type_F32 =>
            Try_As_Float (State, Source, F_Val, Success);
            if Success then Result := (Tag => Type_F32, Val_F32 => F32 (F_Val)); end if;
         when Type_F64 =>
            Try_As_Float (State, Source, F_Val, Success);
            if Success then Result := (Tag => Type_F64, Val_F64 => F64 (F_Val)); end if;
         when Type_F128 =>
            Try_As_Float (State, Source, F_Val, Success);
            if Success then
               Result := (Tag => Type_F128, Val_F128 => (High => F64 (F_Val), Low => 0.0));
            end if;
         when Type_Pure =>
            Try_As_Pure_Operand (State, Source, P_Val, Success);
            if Success then
               Result := (Tag => Type_Pure, Val_Pure => P_Val);
            end if;
         when Type_Boolean =>
            if Source.Tag = Type_Binary then
               Parse_Boolean_Text (Binary_To_String (State, Source), B_Val, Success);
               if Success then
                  Result := (Tag => Type_Boolean, Val_Bool => B_Val);
               else
                  Result :=
                    (Tag => Type_Boolean,
                     Val_Bool => Trim_Text (Binary_To_String (State, Source))'Length /= 0);
                  Success := True;
               end if;
            else
               Try_As_Float (State, Source, F_Val, Success);
               if Success then
                  Result := (Tag => Type_Boolean, Val_Bool => (F_Val /= 0.0));
               end if;
            end if;
         when Type_Char =>
            if Source.Tag = Type_Binary then
               declare
                  Text : constant String := Binary_To_String (State, Source);
               begin
                  if Text'Length = 0 then
                     Result := (Tag => Type_Char, Val_Char => ASCII.NUL);
                  else
                     Result := (Tag => Type_Char, Val_Char => Text (Text'First));
                  end if;
                  Success := True;
               end;
            else
               Try_As_Integer (State, Source, Int_Val, Success);
               if Success then
                  Result := (Tag => Type_Char, Val_Char => Character'Val (Integer (Int_Val mod 256)));
               end if;
            end if;
         when Type_HW8 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_HW8, Val_HW8 => (Value => U8 (Int_Val))); end if;
         when Type_HW16 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_HW16, Val_HW16 => (Value => U16 (Int_Val))); end if;
         when Type_HW32 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_HW32, Val_HW32 => (Value => U32 (Int_Val))); end if;
         when Type_HW64 =>
            Try_As_Integer (State, Source, Int_Val, Success);
            if Success then Result := (Tag => Type_HW64, Val_HW64 => (Value => U64 (Int_Val))); end if;
         when Type_Binary =>
            Make_Binary_Value (State, Value_To_String (State, Source), Result, Success);
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;

      if not Success then
         Result := (Tag => Type_None);
      end if;
   end Cast_Value;

   procedure Cast_Runtime_Value
     (State   : in out Engine_State;
      Target  : in ALB_Type_Tag;
      Source  : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
   begin
      Cast_Value (State, Target, Source, Result, Success);
   end Cast_Runtime_Value;

   procedure Try_Common_Target
     (State        : in out Engine_State;
      Left         : in ALB_Value;
      Right        : in ALB_Value;
      Target       : in ALB_Type_Tag;
      Common       : out ALB_Type_Tag;
      Coerced_Left : out ALB_Value;
      Coerced_Right : out ALB_Value;
      Success      : out Boolean)
   is
   begin
      Common := Type_None;
      Coerced_Left := (Tag => Type_None);
      Coerced_Right := (Tag => Type_None);
      Success := False;

      if Target = Type_None then
         return;
      end if;

      Cast_Runtime_Value (State, Target, Left, Coerced_Left, Success);
      if not Success then
         return;
      end if;

      Cast_Runtime_Value (State, Target, Right, Coerced_Right, Success);
      if not Success then
         Coerced_Left := (Tag => Type_None);
         return;
      end if;

      Common := Target;
      Success := True;
   end Try_Common_Target;

   procedure Coerce_To_Common
     (State         : in out Engine_State;
      Left          : in ALB_Value;
      Right         : in ALB_Value;
      Context       : in Coercion_Context;
      Common        : out ALB_Type_Tag;
      Coerced_Left  : out ALB_Value;
      Coerced_Right : out ALB_Value;
      Success       : out Boolean)
   is
      Done : Boolean := False;

      procedure Try_Target (Target : in ALB_Type_Tag) is
      begin
         if Done or else Target = Type_None then
            return;
         end if;

         Try_Common_Target
           (State,
            Left,
            Right,
            Target,
            Common,
            Coerced_Left,
            Coerced_Right,
            Success);
         Done := Success;
      end Try_Target;
   begin
      Common := Type_None;
      Coerced_Left := (Tag => Type_None);
      Coerced_Right := (Tag => Type_None);
      Success := False;

      case Context is
         when Context_Addition =>
            if Is_Text_Tag (Left.Tag) and then Is_Text_Tag (Right.Tag) then
               Try_Target (Type_Binary);
            end if;

            if not Done
              and then (Left.Tag = Type_Pure or else Right.Tag = Type_Pure)
              and then not (Is_Float_Tag (Left.Tag) or else Is_Float_Tag (Right.Tag))
            then
               Try_Target (Type_Pure);
            end if;

            if not Done and then (Is_Float_Tag (Left.Tag) or else Is_Float_Tag (Right.Tag)) then
               Try_Target (Float_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done then
               Try_Target (Discrete_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done and then not (Is_Float_Tag (Left.Tag) or else Is_Float_Tag (Right.Tag)) then
               Try_Target (Float_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done and then (Is_Text_Tag (Left.Tag) or else Is_Text_Tag (Right.Tag)) then
               Try_Target (Type_Binary);
            end if;

         when Context_Arithmetic =>
            if (Left.Tag = Type_Pure or else Right.Tag = Type_Pure)
              and then not (Is_Float_Tag (Left.Tag) or else Is_Float_Tag (Right.Tag))
            then
               Try_Target (Type_Pure);
            end if;

            if not Done and then (Is_Float_Tag (Left.Tag) or else Is_Float_Tag (Right.Tag)) then
               Try_Target (Float_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done then
               Try_Target (Discrete_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done then
               Try_Target (Float_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

         when Context_Comparison =>
            if Left.Tag = Type_Boolean or else Right.Tag = Type_Boolean then
               Try_Target (Type_Boolean);
            end if;

            if not Done and then Is_Text_Tag (Left.Tag) and then Is_Text_Tag (Right.Tag) then
               if Left.Tag = Type_Char and then Right.Tag = Type_Char then
                  Try_Target (Type_Char);
               else
                  Try_Target (Type_Binary);
               end if;
            end if;

            if not Done and then (Is_Float_Tag (Left.Tag) or else Is_Float_Tag (Right.Tag)) then
               Try_Target (Float_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done
              and then (Left.Tag = Type_Pure or else Right.Tag = Type_Pure)
              and then not (Is_Float_Tag (Left.Tag) or else Is_Float_Tag (Right.Tag))
            then
               Try_Target (Type_Pure);
            end if;

            if not Done then
               Try_Target (Discrete_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done then
               Try_Target (Float_Target_For_Coercion (Left.Tag, Right.Tag));
            end if;

            if not Done and then (Is_Text_Tag (Left.Tag) or else Is_Text_Tag (Right.Tag)) then
               Try_Target (Type_Binary);
            end if;

         when others =>
            null;
      end case;

      if not Success then
         Common := Type_None;
         Coerced_Left := (Tag => Type_None);
         Coerced_Right := (Tag => Type_None);
      end if;
   end Coerce_To_Common;

   procedure Add_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      P_Res                : Pure_Rational;
      Common              : ALB_Type_Tag := Type_None;
      Coerced_Left        : ALB_Value := (Tag => Type_None);
      Coerced_Right       : ALB_Value := (Tag => Type_None);
   begin
      Coerce_To_Common
        (State,
         A,
         B,
         Context_Addition,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_Binary =>
            Make_Binary_Value
              (State,
               Value_To_String (State, Coerced_Left)
               & Value_To_String (State, Coerced_Right),
               Result,
               Success);
         when Type_U8 =>
            Result :=
              (Tag => Type_U8,
               Val_U8 => Coerced_Left.Val_U8 + Coerced_Right.Val_U8);
         when Type_U16 =>
            Result :=
              (Tag => Type_U16,
               Val_U16 => Coerced_Left.Val_U16 + Coerced_Right.Val_U16);
         when Type_U32 =>
            Result :=
              (Tag => Type_U32,
               Val_U32 => Coerced_Left.Val_U32 + Coerced_Right.Val_U32);
         when Type_U64 =>
            Result :=
              (Tag => Type_U64,
               Val_U64 => Coerced_Left.Val_U64 + Coerced_Right.Val_U64);
         when Type_S8 =>
            Result :=
              (Tag => Type_S8,
               Val_S8 => Coerced_Left.Val_S8 + Coerced_Right.Val_S8);
         when Type_S16 =>
            Result :=
              (Tag => Type_S16,
               Val_S16 => Coerced_Left.Val_S16 + Coerced_Right.Val_S16);
         when Type_S32 =>
            Result :=
              (Tag => Type_S32,
               Val_S32 => Coerced_Left.Val_S32 + Coerced_Right.Val_S32);
         when Type_S64 =>
            Result :=
              (Tag => Type_S64,
               Val_S64 => Coerced_Left.Val_S64 + Coerced_Right.Val_S64);
         when Type_F32 =>
            Result :=
              (Tag => Type_F32,
               Val_F32 => Coerced_Left.Val_F32 + Coerced_Right.Val_F32);
         when Type_F64 =>
            Result :=
              (Tag => Type_F64,
               Val_F64 => Coerced_Left.Val_F64 + Coerced_Right.Val_F64);
         when Type_Pure =>
            Add_Pure (Coerced_Left.Val_Pure, Coerced_Right.Val_Pure, P_Res, Success);
            if Success then
               Result := (Tag => Type_Pure, Val_Pure => P_Res);
            else
               Result := (Tag => Type_None);
            end if;
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Add_Runtime_Values;

   procedure Sub_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      P_Res         : Pure_Rational;
      Common        : ALB_Type_Tag := Type_None;
      Coerced_Left  : ALB_Value := (Tag => Type_None);
      Coerced_Right : ALB_Value := (Tag => Type_None);
   begin
      Coerce_To_Common
        (State,
         A,
         B,
         Context_Arithmetic,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_U8 =>
            Result := (Tag => Type_U8, Val_U8 => Coerced_Left.Val_U8 - Coerced_Right.Val_U8);
         when Type_U16 =>
            Result := (Tag => Type_U16, Val_U16 => Coerced_Left.Val_U16 - Coerced_Right.Val_U16);
         when Type_U32 =>
            Result := (Tag => Type_U32, Val_U32 => Coerced_Left.Val_U32 - Coerced_Right.Val_U32);
         when Type_U64 =>
            Result := (Tag => Type_U64, Val_U64 => Coerced_Left.Val_U64 - Coerced_Right.Val_U64);
         when Type_S8 =>
            Result := (Tag => Type_S8, Val_S8 => Coerced_Left.Val_S8 - Coerced_Right.Val_S8);
         when Type_S16 =>
            Result := (Tag => Type_S16, Val_S16 => Coerced_Left.Val_S16 - Coerced_Right.Val_S16);
         when Type_S32 =>
            Result := (Tag => Type_S32, Val_S32 => Coerced_Left.Val_S32 - Coerced_Right.Val_S32);
         when Type_S64 =>
            Result := (Tag => Type_S64, Val_S64 => Coerced_Left.Val_S64 - Coerced_Right.Val_S64);
         when Type_F32 =>
            Result := (Tag => Type_F32, Val_F32 => Coerced_Left.Val_F32 - Coerced_Right.Val_F32);
         when Type_F64 =>
            Result := (Tag => Type_F64, Val_F64 => Coerced_Left.Val_F64 - Coerced_Right.Val_F64);
         when Type_Pure =>
            Sub_Pure (Coerced_Left.Val_Pure, Coerced_Right.Val_Pure, P_Res, Success);
            if Success then
               Result := (Tag => Type_Pure, Val_Pure => P_Res);
            else
               Result := (Tag => Type_None);
            end if;
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Sub_Runtime_Values;

   procedure Mul_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      P_Res         : Pure_Rational;
      Common        : ALB_Type_Tag := Type_None;
      Coerced_Left  : ALB_Value := (Tag => Type_None);
      Coerced_Right : ALB_Value := (Tag => Type_None);
   begin
      Coerce_To_Common
        (State,
         A,
         B,
         Context_Arithmetic,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_U8 =>
            Result := (Tag => Type_U8, Val_U8 => Coerced_Left.Val_U8 * Coerced_Right.Val_U8);
         when Type_U16 =>
            Result := (Tag => Type_U16, Val_U16 => Coerced_Left.Val_U16 * Coerced_Right.Val_U16);
         when Type_U32 =>
            Result := (Tag => Type_U32, Val_U32 => Coerced_Left.Val_U32 * Coerced_Right.Val_U32);
         when Type_U64 =>
            Result := (Tag => Type_U64, Val_U64 => Coerced_Left.Val_U64 * Coerced_Right.Val_U64);
         when Type_S8 =>
            Result := (Tag => Type_S8, Val_S8 => Coerced_Left.Val_S8 * Coerced_Right.Val_S8);
         when Type_S16 =>
            Result := (Tag => Type_S16, Val_S16 => Coerced_Left.Val_S16 * Coerced_Right.Val_S16);
         when Type_S32 =>
            Result := (Tag => Type_S32, Val_S32 => Coerced_Left.Val_S32 * Coerced_Right.Val_S32);
         when Type_S64 =>
            Result := (Tag => Type_S64, Val_S64 => Coerced_Left.Val_S64 * Coerced_Right.Val_S64);
         when Type_F32 =>
            Result := (Tag => Type_F32, Val_F32 => Coerced_Left.Val_F32 * Coerced_Right.Val_F32);
         when Type_F64 =>
            Result := (Tag => Type_F64, Val_F64 => Coerced_Left.Val_F64 * Coerced_Right.Val_F64);
         when Type_Pure =>
            Mul_Pure (Coerced_Left.Val_Pure, Coerced_Right.Val_Pure, P_Res, Success);
            if Success then
               Result := (Tag => Type_Pure, Val_Pure => P_Res);
            else
               Result := (Tag => Type_None);
            end if;
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Mul_Runtime_Values;

   procedure Mod_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Common        : ALB_Type_Tag := Type_None;
      Coerced_Left  : ALB_Value := (Tag => Type_None);
      Coerced_Right : ALB_Value := (Tag => Type_None);
   begin
      Coerce_To_Common
        (State,
         A,
         B,
         Context_Arithmetic,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_U8 =>
            if Coerced_Right.Val_U8 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U8, Val_U8 => Coerced_Left.Val_U8 mod Coerced_Right.Val_U8); end if;
         when Type_U16 =>
            if Coerced_Right.Val_U16 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U16, Val_U16 => Coerced_Left.Val_U16 mod Coerced_Right.Val_U16); end if;
         when Type_U32 =>
            if Coerced_Right.Val_U32 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U32, Val_U32 => Coerced_Left.Val_U32 mod Coerced_Right.Val_U32); end if;
         when Type_U64 =>
            if Coerced_Right.Val_U64 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U64, Val_U64 => Coerced_Left.Val_U64 mod Coerced_Right.Val_U64); end if;
         when Type_S8 =>
            if Coerced_Right.Val_S8 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S8, Val_S8 => Coerced_Left.Val_S8 mod Coerced_Right.Val_S8); end if;
         when Type_S16 =>
            if Coerced_Right.Val_S16 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S16, Val_S16 => Coerced_Left.Val_S16 mod Coerced_Right.Val_S16); end if;
         when Type_S32 =>
            if Coerced_Right.Val_S32 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S32, Val_S32 => Coerced_Left.Val_S32 mod Coerced_Right.Val_S32); end if;
         when Type_S64 =>
            if Coerced_Right.Val_S64 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S64, Val_S64 => Coerced_Left.Val_S64 mod Coerced_Right.Val_S64); end if;
         when Type_F32 =>
            if Coerced_Right.Val_F32 = 0.0 then
               Success := False; Result := (Tag => Type_None);
            else
               declare
                  L : constant Long_Float := Long_Float (Coerced_Left.Val_F32);
                  R : constant Long_Float := Long_Float (Coerced_Right.Val_F32);
               begin
                  Result := (Tag => Type_F32, Val_F32 => F32 (L - R * Long_Float'Floor (L / R)));
               end;
            end if;
         when Type_F64 =>
            if Coerced_Right.Val_F64 = 0.0 then
               Success := False; Result := (Tag => Type_None);
            else
               declare
                  L : constant Long_Float := Long_Float (Coerced_Left.Val_F64);
                  R : constant Long_Float := Long_Float (Coerced_Right.Val_F64);
               begin
                  Result := (Tag => Type_F64, Val_F64 => F64 (L - R * Long_Float'Floor (L / R)));
               end;
            end if;
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Mod_Runtime_Values;

   procedure Div_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      P_Res         : Pure_Rational;
      Common        : ALB_Type_Tag := Type_None;
      Coerced_Left  : ALB_Value := (Tag => Type_None);
      Coerced_Right : ALB_Value := (Tag => Type_None);
   begin
      Coerce_To_Common
        (State,
         A,
         B,
         Context_Arithmetic,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_U8 =>
            if Coerced_Right.Val_U8 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U8, Val_U8 => Coerced_Left.Val_U8 / Coerced_Right.Val_U8); end if;
         when Type_U16 =>
            if Coerced_Right.Val_U16 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U16, Val_U16 => Coerced_Left.Val_U16 / Coerced_Right.Val_U16); end if;
         when Type_U32 =>
            if Coerced_Right.Val_U32 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U32, Val_U32 => Coerced_Left.Val_U32 / Coerced_Right.Val_U32); end if;
         when Type_U64 =>
            if Coerced_Right.Val_U64 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_U64, Val_U64 => Coerced_Left.Val_U64 / Coerced_Right.Val_U64); end if;
         when Type_S8 =>
            if Coerced_Right.Val_S8 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S8, Val_S8 => Coerced_Left.Val_S8 / Coerced_Right.Val_S8); end if;
         when Type_S16 =>
            if Coerced_Right.Val_S16 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S16, Val_S16 => Coerced_Left.Val_S16 / Coerced_Right.Val_S16); end if;
         when Type_S32 =>
            if Coerced_Right.Val_S32 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S32, Val_S32 => Coerced_Left.Val_S32 / Coerced_Right.Val_S32); end if;
         when Type_S64 =>
            if Coerced_Right.Val_S64 = 0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_S64, Val_S64 => Coerced_Left.Val_S64 / Coerced_Right.Val_S64); end if;
         when Type_F32 =>
            if Coerced_Right.Val_F32 = 0.0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_F32, Val_F32 => Coerced_Left.Val_F32 / Coerced_Right.Val_F32); end if;
         when Type_F64 =>
            if Coerced_Right.Val_F64 = 0.0 then Success := False; Result := (Tag => Type_None);
            else Result := (Tag => Type_F64, Val_F64 => Coerced_Left.Val_F64 / Coerced_Right.Val_F64); end if;
         when Type_Pure =>
            Div_Pure (Coerced_Left.Val_Pure, Coerced_Right.Val_Pure, P_Res, Success);
            if Success then
               Result := (Tag => Type_Pure, Val_Pure => P_Res);
            else
               Result := (Tag => Type_None);
            end if;
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Div_Runtime_Values;

   procedure Equal_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Common        : ALB_Type_Tag := Type_None;
      Coerced_Left  : ALB_Value := (Tag => Type_None);
      Coerced_Right : ALB_Value := (Tag => Type_None);
   begin
      Result := (Tag => Type_Boolean, Val_Bool => False);

      Coerce_To_Common
        (State,
         A,
         B,
         Context_Comparison,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_U8 =>
            Result.Val_Bool := Coerced_Left.Val_U8 = Coerced_Right.Val_U8;
         when Type_U16 =>
            Result.Val_Bool := Coerced_Left.Val_U16 = Coerced_Right.Val_U16;
         when Type_U32 =>
            Result.Val_Bool := Coerced_Left.Val_U32 = Coerced_Right.Val_U32;
         when Type_U64 =>
            Result.Val_Bool := Coerced_Left.Val_U64 = Coerced_Right.Val_U64;
         when Type_S8 =>
            Result.Val_Bool := Coerced_Left.Val_S8 = Coerced_Right.Val_S8;
         when Type_S16 =>
            Result.Val_Bool := Coerced_Left.Val_S16 = Coerced_Right.Val_S16;
         when Type_S32 =>
            Result.Val_Bool := Coerced_Left.Val_S32 = Coerced_Right.Val_S32;
         when Type_S64 =>
            Result.Val_Bool := Coerced_Left.Val_S64 = Coerced_Right.Val_S64;
         when Type_F32 =>
            Result.Val_Bool := Coerced_Left.Val_F32 = Coerced_Right.Val_F32;
         when Type_F64 =>
            Result.Val_Bool := Coerced_Left.Val_F64 = Coerced_Right.Val_F64;
         when Type_Pure =>
            Result.Val_Bool :=
              Coerced_Left.Val_Pure.Num = Coerced_Right.Val_Pure.Num
              and then Coerced_Left.Val_Pure.Den = Coerced_Right.Val_Pure.Den;
         when Type_Boolean =>
            Result.Val_Bool := Coerced_Left.Val_Bool = Coerced_Right.Val_Bool;
         when Type_Char =>
            Result.Val_Bool := Coerced_Left.Val_Char = Coerced_Right.Val_Char;
         when Type_HW8 =>
            Result.Val_Bool := Coerced_Left.Val_HW8.Value = Coerced_Right.Val_HW8.Value;
         when Type_HW16 =>
            Result.Val_Bool := Coerced_Left.Val_HW16.Value = Coerced_Right.Val_HW16.Value;
         when Type_HW32 =>
            Result.Val_Bool := Coerced_Left.Val_HW32.Value = Coerced_Right.Val_HW32.Value;
         when Type_HW64 =>
            Result.Val_Bool := Coerced_Left.Val_HW64.Value = Coerced_Right.Val_HW64.Value;
         when Type_Binary =>
            Result.Val_Bool :=
              Binary_To_String (State, Coerced_Left)
              = Binary_To_String (State, Coerced_Right);
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Equal_Runtime_Values;

   procedure Less_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Common        : ALB_Type_Tag := Type_None;
      Coerced_Left  : ALB_Value := (Tag => Type_None);
      Coerced_Right : ALB_Value := (Tag => Type_None);
   begin
      Result := (Tag => Type_Boolean, Val_Bool => False);

      Coerce_To_Common
        (State,
         A,
         B,
         Context_Comparison,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_U8 =>
            Result.Val_Bool := Coerced_Left.Val_U8 < Coerced_Right.Val_U8;
         when Type_U16 =>
            Result.Val_Bool := Coerced_Left.Val_U16 < Coerced_Right.Val_U16;
         when Type_U32 =>
            Result.Val_Bool := Coerced_Left.Val_U32 < Coerced_Right.Val_U32;
         when Type_U64 =>
            Result.Val_Bool := Coerced_Left.Val_U64 < Coerced_Right.Val_U64;
         when Type_S8 =>
            Result.Val_Bool := Coerced_Left.Val_S8 < Coerced_Right.Val_S8;
         when Type_S16 =>
            Result.Val_Bool := Coerced_Left.Val_S16 < Coerced_Right.Val_S16;
         when Type_S32 =>
            Result.Val_Bool := Coerced_Left.Val_S32 < Coerced_Right.Val_S32;
         when Type_S64 =>
            Result.Val_Bool := Coerced_Left.Val_S64 < Coerced_Right.Val_S64;
         when Type_F32 =>
            Result.Val_Bool := Coerced_Left.Val_F32 < Coerced_Right.Val_F32;
         when Type_F64 =>
            Result.Val_Bool := Coerced_Left.Val_F64 < Coerced_Right.Val_F64;
         when Type_Pure =>
            Result.Val_Bool :=
              Coerced_Left.Val_Pure.Num * Coerced_Right.Val_Pure.Den
              < Coerced_Right.Val_Pure.Num * Coerced_Left.Val_Pure.Den;
         when Type_Boolean =>
            Result.Val_Bool :=
              Boolean'Pos (Coerced_Left.Val_Bool)
              < Boolean'Pos (Coerced_Right.Val_Bool);
         when Type_Char =>
            Result.Val_Bool := Coerced_Left.Val_Char < Coerced_Right.Val_Char;
         when Type_HW8 =>
            Result.Val_Bool := Coerced_Left.Val_HW8.Value < Coerced_Right.Val_HW8.Value;
         when Type_HW16 =>
            Result.Val_Bool := Coerced_Left.Val_HW16.Value < Coerced_Right.Val_HW16.Value;
         when Type_HW32 =>
            Result.Val_Bool := Coerced_Left.Val_HW32.Value < Coerced_Right.Val_HW32.Value;
         when Type_HW64 =>
            Result.Val_Bool := Coerced_Left.Val_HW64.Value < Coerced_Right.Val_HW64.Value;
         when Type_Binary =>
            Result.Val_Bool :=
              Binary_To_String (State, Coerced_Left)
              < Binary_To_String (State, Coerced_Right);
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Less_Runtime_Values;

   procedure Greater_Runtime_Values
     (State   : in out Engine_State;
      A, B    : in ALB_Value;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Common        : ALB_Type_Tag := Type_None;
      Coerced_Left  : ALB_Value := (Tag => Type_None);
      Coerced_Right : ALB_Value := (Tag => Type_None);
   begin
      Result := (Tag => Type_Boolean, Val_Bool => False);

      Coerce_To_Common
        (State,
         A,
         B,
         Context_Comparison,
         Common,
         Coerced_Left,
         Coerced_Right,
         Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      case Common is
         when Type_U8 =>
            Result.Val_Bool := Coerced_Left.Val_U8 > Coerced_Right.Val_U8;
         when Type_U16 =>
            Result.Val_Bool := Coerced_Left.Val_U16 > Coerced_Right.Val_U16;
         when Type_U32 =>
            Result.Val_Bool := Coerced_Left.Val_U32 > Coerced_Right.Val_U32;
         when Type_U64 =>
            Result.Val_Bool := Coerced_Left.Val_U64 > Coerced_Right.Val_U64;
         when Type_S8 =>
            Result.Val_Bool := Coerced_Left.Val_S8 > Coerced_Right.Val_S8;
         when Type_S16 =>
            Result.Val_Bool := Coerced_Left.Val_S16 > Coerced_Right.Val_S16;
         when Type_S32 =>
            Result.Val_Bool := Coerced_Left.Val_S32 > Coerced_Right.Val_S32;
         when Type_S64 =>
            Result.Val_Bool := Coerced_Left.Val_S64 > Coerced_Right.Val_S64;
         when Type_F32 =>
            Result.Val_Bool := Coerced_Left.Val_F32 > Coerced_Right.Val_F32;
         when Type_F64 =>
            Result.Val_Bool := Coerced_Left.Val_F64 > Coerced_Right.Val_F64;
         when Type_Pure =>
            Result.Val_Bool :=
              Coerced_Left.Val_Pure.Num * Coerced_Right.Val_Pure.Den
              > Coerced_Right.Val_Pure.Num * Coerced_Left.Val_Pure.Den;
         when Type_Boolean =>
            Result.Val_Bool :=
              Boolean'Pos (Coerced_Left.Val_Bool)
              > Boolean'Pos (Coerced_Right.Val_Bool);
         when Type_Char =>
            Result.Val_Bool := Coerced_Left.Val_Char > Coerced_Right.Val_Char;
         when Type_HW8 =>
            Result.Val_Bool := Coerced_Left.Val_HW8.Value > Coerced_Right.Val_HW8.Value;
         when Type_HW16 =>
            Result.Val_Bool := Coerced_Left.Val_HW16.Value > Coerced_Right.Val_HW16.Value;
         when Type_HW32 =>
            Result.Val_Bool := Coerced_Left.Val_HW32.Value > Coerced_Right.Val_HW32.Value;
         when Type_HW64 =>
            Result.Val_Bool := Coerced_Left.Val_HW64.Value > Coerced_Right.Val_HW64.Value;
         when Type_Binary =>
            Result.Val_Bool :=
              Binary_To_String (State, Coerced_Left)
              > Binary_To_String (State, Coerced_Right);
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Greater_Runtime_Values;

   procedure Boolean_Truth
     (State   : in Engine_State;
      Val     : in ALB_Value;
      Truth   : out Boolean;
      Success : out Boolean)
   is
      F : Long_Float := 0.0;
   begin
      if Val.Tag = Type_Boolean then
         Truth := Val.Val_Bool;
         Success := True;
      elsif Val.Tag = Type_Binary then
         Parse_Boolean_Text (Binary_To_String (State, Val), Truth, Success);
         if not Success then
            Truth := Trim_Text (Binary_To_String (State, Val))'Length /= 0;
            Success := True;
         end if;
      else
         Try_As_Float (State, Val, F, Success);
         if Success then
            Truth := F /= 0.0;
         else
            Truth := False;
         end if;
      end if;
   end Boolean_Truth;

   function Find_Var (State : Engine_State; Name : Var_Name) return Natural is
   begin
      for I in 1 .. Max_Vars loop
         if State.Bank (I).Active and then State.Bank (I).Name = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Var;

   function Find_Array (State : Engine_State; Name : Var_Name) return Natural is
   begin
      for I in 1 .. Max_Arrays loop
         if State.Arrays (I).Active and then State.Arrays (I).Name = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Array;

   function Find_Struct (State : Engine_State; Name : Var_Name) return Natural is
   begin
      for I in 1 .. Max_Structs loop
         if State.Structs (I).Active and then State.Structs (I).Name = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Struct;

   function Find_Parallel (State : Engine_State; Name : Var_Name) return Natural is
   begin
      for I in 1 .. Max_Parallel_Groups loop
         if State.Parallels (I).Active and then State.Parallels (I).Name = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Parallel;

   function Find_Parallel_Field
     (State      : Engine_State;
      Group_Slot : Natural;
      Field_Name : Var_Name) return Natural
   is
   begin
      if Group_Slot = 0 or else Group_Slot > Max_Parallel_Groups then
         return 0;
      end if;

      for I in 1 .. Max_Parallel_Fields loop
         if State.Parallels (Group_Slot).Fields (I).Active
           and then State.Parallels (Group_Slot).Fields (I).Field_Name = Field_Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Parallel_Field;

   function Find_Proc (State : Engine_State; Name : Var_Name) return Natural is
   begin
      for I in 1 .. Max_Procs loop
         if State.Procs (I).Active and then State.Procs (I).Name = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Proc;

   procedure Upsert_Var
     (State   : in out Engine_State;
      Name    : in Var_Name;
      Value   : in ALB_Value;
      Success : out Boolean)
   is
      Slot : Natural := Find_Var (State, Name);
   begin
      if Slot = 0 then
         for I in 1 .. Max_Vars loop
            if not State.Bank (I).Active then
               State.Bank (I).Active := True;
               State.Bank (I).Name := Name;
               State.Bank (I).Value := Value;
               State.Count := State.Count + 1;
               Success := True;
               return;
            end if;
         end loop;
         Success := False;
      else
         State.Bank (Slot).Value := Value;
         Success := True;
      end if;
   end Upsert_Var;

   function Find_Call_Scope_Save
     (State : Engine_State;
      Name  : Var_Name) return Natural
   is
   begin
      if State.Call_Depth = 0 or else State.Call_Depth > Max_Call_Depth then
         return 0;
      end if;

      for I in 1 .. State.Call_Scopes (State.Call_Depth).Save_Count loop
         if State.Call_Scopes (State.Call_Depth).Saves (I).Active
           and then State.Call_Scopes (State.Call_Depth).Saves (I).Name = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Call_Scope_Save;

   function Current_Call_Local_Var_Slot
     (State : Engine_State;
      Name  : Var_Name) return Natural
   is
      Save_Slot : constant Natural := Find_Call_Scope_Save (State, Name);
   begin
      if Save_Slot = 0 then
         return 0;
      end if;

      return State.Call_Scopes (State.Call_Depth).Saves (Save_Slot).Slot;
   end Current_Call_Local_Var_Slot;

   procedure Begin_Call_Scope (State : in out Engine_State) is
      Blank : Call_Scope_Record;
   begin
      if State.Call_Depth = 0 or else State.Call_Depth > Max_Call_Depth then
         return;
      end if;

      State.Call_Scopes (State.Call_Depth) := Blank;
   end Begin_Call_Scope;

   procedure Restore_Call_Scope (State : in out Engine_State) is
      Depth : constant Natural := State.Call_Depth;
   begin
      if Depth = 0 or else Depth > Max_Call_Depth then
         return;
      end if;

      for I in reverse 1 .. State.Call_Scopes (Depth).Save_Count loop
         if State.Call_Scopes (Depth).Saves (I).Active
           and then State.Call_Scopes (Depth).Saves (I).Slot > 0
         then
            declare
               Save : Call_Scope_Save_Record renames State.Call_Scopes (Depth).Saves (I);
            begin
               if Save.Was_Active then
                  State.Bank (Save.Slot).Active := True;
                  State.Bank (Save.Slot).Name := Save.Old_Name;
                  State.Bank (Save.Slot).Value := Save.Old_Value;
               else
                  if State.Bank (Save.Slot).Active and then State.Count > 0 then
                     State.Count := State.Count - 1;
                  end if;
                  State.Bank (Save.Slot).Active := False;
                  State.Bank (Save.Slot).Name := (others => ' ');
                  State.Bank (Save.Slot).Value := (Tag => Type_None);
               end if;
            end;
         end if;
      end loop;

      Begin_Call_Scope (State);
   end Restore_Call_Scope;

   procedure Upsert_Scoped_Local_Var
     (State   : in out Engine_State;
      Name    : in Var_Name;
      Value   : in ALB_Value;
      Success : out Boolean)
   is
      Save_Slot : Natural := 0;
      Slot      : Natural := 0;
      Depth     : constant Natural := State.Call_Depth;
   begin
      if Depth = 0 or else Depth > Max_Call_Depth then
         Upsert_Var (State, Name, Value, Success);
         return;
      end if;

      Save_Slot := Find_Call_Scope_Save (State, Name);
      if Save_Slot /= 0 then
         Slot := State.Call_Scopes (Depth).Saves (Save_Slot).Slot;
         if Slot = 0 then
            Success := False;
            return;
         end if;

         State.Bank (Slot).Active := True;
         State.Bank (Slot).Name := Name;
         State.Bank (Slot).Value := Value;
         Success := True;
         return;
      end if;

      Slot := Find_Var (State, Name);
      Save_Slot := State.Call_Scopes (Depth).Save_Count + 1;
      if Save_Slot > Max_Vars then
         Success := False;
         return;
      end if;

      State.Call_Scopes (Depth).Save_Count := Save_Slot;
      if Slot = 0 then
         for I in 1 .. Max_Vars loop
            if not State.Bank (I).Active then
               Slot := I;
               exit;
            end if;
         end loop;

         if Slot = 0 then
            State.Call_Scopes (Depth).Save_Count := Save_Slot - 1;
            Success := False;
            return;
         end if;

         State.Call_Scopes (Depth).Saves (Save_Slot) :=
           (Active     => True,
            Name       => Name,
            Slot       => Slot,
            Was_Active => False,
            Old_Name   => (others => ' '),
            Old_Value  => (Tag => Type_None));
         State.Bank (Slot).Active := True;
         State.Bank (Slot).Name := Name;
         State.Bank (Slot).Value := Value;
         State.Count := State.Count + 1;
      else
         State.Call_Scopes (Depth).Saves (Save_Slot) :=
           (Active     => True,
            Name       => Name,
            Slot       => Slot,
            Was_Active => True,
            Old_Name   => State.Bank (Slot).Name,
            Old_Value  => State.Bank (Slot).Value);
         State.Bank (Slot).Active := True;
         State.Bank (Slot).Name := Name;
         State.Bank (Slot).Value := Value;
      end if;

      Success := True;
   end Upsert_Scoped_Local_Var;

   function Resolve_Scoped_Var_Name
     (State : Engine_State;
      Name  : Var_Name) return Var_Name
   is
      Local_Name : Var_Name := Name;
   begin
      if Has_Qualifier (Name) then
         return Name;
      end if;

      if Find_Var (State, Name) /= 0 then
         return Name;
      end if;

      if In_Module_Scope (State) then
         Local_Name := Compose_Name (State.Current_Module, Name);
         if Find_Var (State, Local_Name) /= 0 then
            return Local_Name;
         end if;
      end if;

      return Name;
   end Resolve_Scoped_Var_Name;

   function Resolve_Scoped_Array_Name
     (State : Engine_State;
      Name  : Var_Name) return Var_Name
   is
      Local_Name : Var_Name := Name;
   begin
      if Has_Qualifier (Name) then
         return Name;
      end if;

      if Find_Array (State, Name) /= 0 then
         return Name;
      end if;

      if In_Module_Scope (State) then
         Local_Name := Compose_Name (State.Current_Module, Name);
         if Find_Array (State, Local_Name) /= 0 then
            return Local_Name;
         end if;
      end if;

      return Name;
   end Resolve_Scoped_Array_Name;

   function Resolve_Scoped_Parallel_Name
     (State : Engine_State;
      Name  : Var_Name) return Var_Name
   is
      Local_Name : Var_Name := Name;
   begin
      if Has_Qualifier (Name) then
         return Name;
      end if;

      if Find_Parallel (State, Name) /= 0 then
         return Name;
      end if;

      if In_Module_Scope (State) then
         Local_Name := Compose_Name (State.Current_Module, Name);
         if Find_Parallel (State, Local_Name) /= 0 then
            return Local_Name;
         end if;
      end if;

      return Name;
   end Resolve_Scoped_Parallel_Name;

   procedure Read_Target
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      State   : in out Engine_State;
      Result  : out ALB_Value;
      Success : out Boolean);

   function Find_Temporal
     (State : Engine_State;
      Name  : Var_Name) return Natural
   is
   begin
      for I in 1 .. Max_Temporal_Vars loop
         if State.Temporals (I).Active and then State.Temporals (I).Name = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Temporal;

   procedure Recount_Temporals (State : in out Engine_State) is
      Count : Natural := 0;
   begin
      for I in 1 .. Max_Temporal_Vars loop
         if State.Temporals (I).Active then
            Count := Count + 1;
         end if;
      end loop;
      State.Temporal_Count := Count;
   end Recount_Temporals;

   procedure Sync_Temporal_Slot
     (State   : in out Engine_State;
      Slot    : in Natural;
      Success : out Boolean)
   is
      Var_Slot : Natural := 0;
   begin
      Success := False;
      if Slot = 0
        or else Slot > Max_Temporal_Vars
        or else not State.Temporals (Slot).Active
        or else State.Temporals (Slot).Cursor = 0
        or else State.Temporals (Slot).Cursor > Max_Temporal_History
      then
         return;
      end if;

      Var_Slot := Find_Var (State, State.Temporals (Slot).Name);
      if Var_Slot = 0 then
         return;
      end if;

      State.Temporals (Slot).Values (State.Temporals (Slot).Cursor) :=
        State.Bank (Var_Slot).Value;
      if State.Temporals (Slot).Length = 0 then
         State.Temporals (Slot).Length := 1;
      end if;
      Success := True;
   end Sync_Temporal_Slot;

   procedure Sync_Temporal_Var
     (State   : in out Engine_State;
      Name    : in Var_Name;
      Success : out Boolean)
   is
      Slot : constant Natural := Find_Temporal (State, Name);
   begin
      if Slot = 0 then
         Success := True;
      else
         Sync_Temporal_Slot (State, Slot, Success);
      end if;
   end Sync_Temporal_Var;

   procedure Register_Temporal
     (State         : in out Engine_State;
      Name          : in Var_Name;
      History_Limit : in Natural;
      Initial_Value : in ALB_Value;
      Success       : out Boolean)
   is
      Slot      : Natural := Find_Temporal (State, Name);
      Use_Limit : Natural := History_Limit;
   begin
      if Use_Limit = 0 then
         Use_Limit := 1;
      elsif Use_Limit > Max_Temporal_History then
         Use_Limit := Max_Temporal_History;
      end if;

      if Slot = 0 then
         for I in 1 .. Max_Temporal_Vars loop
            if not State.Temporals (I).Active then
               Slot := I;
               exit;
            end if;
         end loop;
      end if;

      if Slot = 0 then
         Success := False;
         return;
      end if;

      declare
         Blank_Temporal : Temporal_Record;
      begin
         State.Temporals (Slot) := Blank_Temporal;
      end;

      State.Temporals (Slot).Active := True;
      State.Temporals (Slot).Name := Name;
      State.Temporals (Slot).History_Limit := Use_Limit;
      State.Temporals (Slot).Length := 1;
      State.Temporals (Slot).Cursor := 1;
      State.Temporals (Slot).Values (1) := Initial_Value;
      Recount_Temporals (State);
      Success := True;
   end Register_Temporal;

   procedure Advance_Temporal_State
     (State      : in out Engine_State;
      Step_Count : in Natural;
      Success    : out Boolean)
   is
      Next_Cursor : Natural := 1;
      Limit       : Natural := 1;
      Current     : ALB_Value := (Tag => Type_None);
   begin
      Success := True;
      if Step_Count = 0 then
         return;
      end if;

      for Step in 1 .. Step_Count loop
         for I in 1 .. Max_Temporal_Vars loop
            if State.Temporals (I).Active then
               Sync_Temporal_Slot (State, I, Success);
               if not Success then
                  return;
               end if;

               Limit := State.Temporals (I).History_Limit;
               if Limit = 0 then
                  Limit := 1;
               elsif Limit > Max_Temporal_History then
                  Limit := Max_Temporal_History;
               end if;

               Current := State.Temporals (I).Values (State.Temporals (I).Cursor);
               Next_Cursor := State.Temporals (I).Cursor + 1;
               if Next_Cursor > Limit then
                  Next_Cursor := 1;
               end if;

               State.Temporals (I).Cursor := Next_Cursor;
               State.Temporals (I).Values (Next_Cursor) := Current;
               if State.Temporals (I).Length < Limit then
                  State.Temporals (I).Length := State.Temporals (I).Length + 1;
               end if;
            end if;
         end loop;
      end loop;
   end Advance_Temporal_State;

   procedure Save_Temporal_State
     (State   : in out Engine_State;
      Success : out Boolean)
   is
   begin
      for I in 1 .. Max_Temporal_Vars loop
         if State.Temporals (I).Active then
            Sync_Temporal_Slot (State, I, Success);
            if not Success then
               return;
            end if;
         end if;
      end loop;

      if State.Temporal_Save_Depth >= Max_Temporal_Snapshots then
         Success := False;
         return;
      end if;

      State.Temporal_Save_Depth := State.Temporal_Save_Depth + 1;
      State.Temporal_Snapshots (State.Temporal_Save_Depth).Active := True;
      State.Temporal_Snapshots (State.Temporal_Save_Depth).Temporals := State.Temporals;
      Success := True;
   end Save_Temporal_State;

   procedure Load_Temporal_State
     (State   : in out Engine_State;
      Success : out Boolean)
   is
      Var_Slot : Natural := 0;
   begin
      if State.Temporal_Save_Depth = 0
        or else not State.Temporal_Snapshots (State.Temporal_Save_Depth).Active
      then
         Success := False;
         return;
      end if;

      State.Temporals := State.Temporal_Snapshots (State.Temporal_Save_Depth).Temporals;
      State.Temporal_Snapshots (State.Temporal_Save_Depth).Active := False;
      State.Temporal_Save_Depth := State.Temporal_Save_Depth - 1;
      Recount_Temporals (State);

      for I in 1 .. Max_Temporal_Vars loop
         if State.Temporals (I).Active then
            Var_Slot := Find_Var (State, State.Temporals (I).Name);
            if Var_Slot = 0
              or else State.Temporals (I).Cursor = 0
              or else State.Temporals (I).Cursor > Max_Temporal_History
            then
               Success := False;
               return;
            end if;

            State.Bank (Var_Slot).Value :=
              State.Temporals (I).Values (State.Temporals (I).Cursor);
         end if;
      end loop;

      Success := True;
   end Load_Temporal_State;

   procedure Resolve_Temporal_Reference
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      State   : in out Engine_State;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Base_Node  : constant Node_Index := Tree (Node).Left_Child;
      Base_Name  : Var_Name := (others => ' ');
      Temp_Slot  : Natural := 0;
      Prev_Slot  : Natural := 1;
      Selector   : Token_Kind := Tok_Error;
   begin
      if Node = 0 or else Base_Node = 0 or else Tree (Node).Token_Index = 0 then
         Result := (Tag => Type_None);
         Success := False;
         return;
      end if;

      if Tree (Base_Node).Kind = AST_Var_Expr and then Tree (Base_Node).Left_Child = 0 then
         Base_Name := Extract_Name (Source, Tokens (Tree (Base_Node).Token_Index));
         Base_Name := Resolve_Scoped_Var_Name (State, Base_Name);
         Temp_Slot := Find_Temporal (State, Base_Name);
      end if;

      if Temp_Slot = 0 then
         Read_Target (Source, Tokens, Tree, Base_Node, State, Result, Success);
         return;
      end if;

      Sync_Temporal_Slot (State, Temp_Slot, Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      Selector := Tokens (Tree (Node).Token_Index).Kind;
      case Selector is
         when Tok_Past =>
            if State.Temporals (Temp_Slot).Length <= 1 then
               Result := State.Temporals (Temp_Slot).Values (State.Temporals (Temp_Slot).Cursor);
            else
               if State.Temporals (Temp_Slot).Cursor = 1 then
                  if State.Temporals (Temp_Slot).Length < State.Temporals (Temp_Slot).History_Limit then
                     Prev_Slot := State.Temporals (Temp_Slot).Length;
                  else
                     Prev_Slot := State.Temporals (Temp_Slot).History_Limit;
                  end if;
               else
                  Prev_Slot := State.Temporals (Temp_Slot).Cursor - 1;
               end if;
               Result := State.Temporals (Temp_Slot).Values (Prev_Slot);
            end if;
            Success := True;

         when Tok_Now | Tok_Future =>
            Result := State.Temporals (Temp_Slot).Values (State.Temporals (Temp_Slot).Cursor);
            Success := True;

         when Tok_Timeline =>
            Result := (Tag => Type_U64, Val_U64 => U64 (Temp_Slot));
            Success := True;

         when others =>
            Read_Target (Source, Tokens, Tree, Base_Node, State, Result, Success);
      end case;
   end Resolve_Temporal_Reference;

   function Type_Size_Bytes (Tag : ALB_Type_Tag) return Natural is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_Boolean | Type_HW8 | Type_Char =>
            return 1;
         when Type_U16 | Type_S16 | Type_HW16 =>
            return 2;
         when Type_U32 | Type_S32 | Type_F32 | Type_HW32 =>
            return 4;
         when Type_U64 | Type_S64 | Type_F64 | Type_HW64 =>
            return 8;
         when Type_U128 | Type_S128 | Type_F128 =>
            return 16;
         when Type_Pure =>
            return 16;
         when Type_Binary =>
            return 16;
         when others =>
            return 8;
      end case;
   end Type_Size_Bytes;

   procedure Emit_Value (Val : ALB_Value) is
   begin
      Put ("[VALUE]");
   end Emit_Value;

   function Parse_Decimal (Source : String; T : Token) return Long_Float is
      Value     : Long_Float := 0.0;
      Fraction  : Long_Float := 1.0;
      Seen_Dot  : Boolean := False;
      Negative  : Boolean := False;
      Last      : constant Natural := T.Start + T.Length - 1;
      C         : Character;
      D         : Long_Float;
   begin
      if T.Length = 0 then
         return 0.0;
      end if;

      for I in T.Start .. Last loop
         exit when I not in Source'Range;
         C := Source (I);
         if C = '-' and then I = T.Start then
            Negative := True;
         elsif C = '.' then
            Seen_Dot := True;
         elsif C in '0' .. '9' then
            D := Long_Float (Character'Pos (C) - Character'Pos ('0'));
            if Seen_Dot then
               Fraction := Fraction * 10.0;
               Value := Value + (D / Fraction);
            else
               Value := (Value * 10.0) + D;
            end if;
         end if;
      end loop;

      if Negative then
         return -Value;
      end if;
      return Value;
   end Parse_Decimal;

   function Parse_Radix
     (Source : String;
      T      : Token;
      Base   : Positive;
      Skip   : Natural) return Long_Float
   is
      Value : Long_Float := 0.0;
      Last  : constant Natural := T.Start + T.Length - 1;
      C     : Character;
      D     : Long_Float;
   begin
      for I in T.Start + Skip .. Last loop
         exit when I not in Source'Range;
         C := Source (I);
         if C in '0' .. '9' then
            D := Long_Float (Character'Pos (C) - Character'Pos ('0'));
         elsif C in 'A' .. 'F' then
            D := Long_Float (Character'Pos (C) - Character'Pos ('A') + 10);
         elsif C in 'a' .. 'f' then
            D := Long_Float (Character'Pos (C) - Character'Pos ('a') + 10);
         else
            D := -1.0;
         end if;

         if D >= 0.0 and then D < Long_Float (Base) then
            Value := (Value * Long_Float (Base)) + D;
         end if;
      end loop;
      return Value;
   end Parse_Radix;

   procedure Evaluate_Expr
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Root    : in Node_Index;
      State   : in out Engine_State;
      Result  : out ALB_Value;
      Success : out Boolean);

   procedure Evaluate_Index_List
     (Source   : in String;
      Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Root     : in Node_Index;
      State    : in out Engine_State;
      Values   : out Dim_Array;
      Count    : out Natural;
      Success  : out Boolean)
   is
      Curr  : Node_Index := Root;
      Item  : ALB_Value;
      Num   : Long_Integer := 0;
   begin
      Values := (others => 0);
      Count := 0;
      Success := True;

      while Curr /= 0 loop
         if Count = Max_Dimensions then
            Success := False;
            return;
         end if;

         Evaluate_Expr (Source, Tokens, Tree, Curr, State, Item, Success);
         if not Success then
            return;
         end if;

         Try_As_Integer (State, Item, Num, Success);
         if not Success or else Num < 1 then
            Success := False;
            return;
         end if;

         Count := Count + 1;
         Values (Count) := Natural (Num);
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Evaluate_Index_List;

   function Flatten_Indices
     (Info    : Array_Record;
      Indices : Dim_Array;
      Count   : Natural) return Natural
   is
      Offset : Natural := 0;
      Stride : Natural := 1;
   begin
      if Count /= Info.Dim_Count then
         return 0;
      end if;

      for I in reverse 1 .. Info.Dim_Count loop
         if Indices (I) = 0 or else Indices (I) > Info.Dims (I) then
            return 0;
         end if;
         Offset := Offset + ((Indices (I) - 1) * Stride);
         Stride := Stride * Info.Dims (I);
      end loop;

      return Offset + 1;
   end Flatten_Indices;

   procedure Read_Target
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      State   : in out Engine_State;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      Name    : Var_Name := (others => ' ');
      Base_Name : Var_Name := (others => ' ');
      Field_Name : Var_Name := (others => ' ');
      Full_Name : Var_Name := (others => ' ');
      Slot    : Natural := 0;
      A_Slot  : Natural := 0;
      P_Slot  : Natural := 0;
      Indices : Dim_Array := (others => 0);
      Count   : Natural := 0;
      Offset  : Natural := 0;
   begin
      if Node = 0 then
         Result := (Tag => Type_None);
         Success := False;
         return;
      end if;

      case Tree (Node).Kind is
         when AST_Var_Expr | AST_Const_Ref =>
            Name := Extract_Name (Source, Tokens (Tree (Node).Token_Index));
            if Tree (Node).Left_Child = 0 then
               Name := Resolve_Scoped_Var_Name (State, Name);
               Slot := Find_Var (State, Name);
               if Slot = 0 then
                  Result := (Tag => Type_None);
                  Success := False;
               else
                  Result := State.Bank (Slot).Value;
                  Success := True;
               end if;
            else
               Name := Resolve_Scoped_Array_Name (State, Name);
               A_Slot := Find_Array (State, Name);
               if A_Slot = 0 then
                  Result := (Tag => Type_None);
                  Success := False;
                  return;
               end if;

               Evaluate_Index_List
                 (Source, Tokens, Tree, Tree (Node).Left_Child, State, Indices, Count, Success);
               if not Success then
                  Result := (Tag => Type_None);
                  return;
               end if;

               Offset := Flatten_Indices (State.Arrays (A_Slot), Indices, Count);
               if Offset = 0
                 or else Offset > State.Arrays (A_Slot).Active_Length
                 or else State.Arrays (A_Slot).Base + Offset - 1 > Max_Array_Cells
               then
                  Result := (Tag => Type_None);
                  Success := False;
                  return;
               end if;

               Result := State.Array_Cells (State.Arrays (A_Slot).Base + Offset - 1);
               Success := True;
            end if;
         when AST_Member_Expr =>
            if Tree (Node).Left_Child = 0
              or else Tree (Node).Right_Child = 0
              or else Tree (Tree (Node).Left_Child).Kind /= AST_Var_Expr
              or else Tree (Tree (Node).Right_Child).Kind /= AST_Var_Expr
            then
               Result := (Tag => Type_None);
               Success := False;
               return;
            end if;

            Base_Name := Extract_Name (Source, Tokens (Tree (Tree (Node).Left_Child).Token_Index));
            Field_Name := Extract_Name (Source, Tokens (Tree (Tree (Node).Right_Child).Token_Index));
            Base_Name := Resolve_Scoped_Parallel_Name (State, Base_Name);
            P_Slot := Find_Parallel (State, Base_Name);

            if P_Slot /= 0 then
               Full_Name := Compose_Name (Base_Name, Field_Name);
               A_Slot := Find_Array (State, Full_Name);
               if A_Slot = 0 then
                  Result := (Tag => Type_None);
                  Success := False;
                  return;
               end if;

               Evaluate_Index_List
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Node).Left_Child).Left_Child,
                  State,
                  Indices,
                  Count,
                  Success);
               if not Success then
                  Result := (Tag => Type_None);
                  return;
               end if;

               Offset := Flatten_Indices (State.Arrays (A_Slot), Indices, Count);
               if Offset = 0
                 or else Offset > State.Arrays (A_Slot).Active_Length
                 or else State.Arrays (A_Slot).Base + Offset - 1 > Max_Array_Cells
               then
                  Result := (Tag => Type_None);
                  Success := False;
                  return;
               end if;

               Result := State.Array_Cells (State.Arrays (A_Slot).Base + Offset - 1);
               Success := True;
            else
               Full_Name := Compose_Name (Base_Name, Field_Name);
               Slot := Find_Var (State, Full_Name);
               if Slot = 0 then
                  Slot := Find_Var (State, Field_Name);
               end if;

               if Slot = 0 then
                  Result := (Tag => Type_None);
                  Success := False;
               else
                  Result := State.Bank (Slot).Value;
                  Success := True;
               end if;
            end if;
         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   end Read_Target;

   procedure Write_Target
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      State   : in out Engine_State;
      Value   : in ALB_Value;
      Success : out Boolean)
   is
      Name      : Var_Name := (others => ' ');
      Base_Name : Var_Name := (others => ' ');
      Field_Name : Var_Name := (others => ' ');
      Full_Name : Var_Name := (others => ' ');
      Slot      : Natural := 0;
      A_Slot    : Natural := 0;
      P_Slot    : Natural := 0;
      Indices   : Dim_Array := (others => 0);
      Count     : Natural := 0;
      Offset    : Natural := 0;
      Casted    : ALB_Value := (Tag => Type_None);
      Need_Cast : Boolean := False;
   begin
      if Node = 0 or else Tree (Node).Kind not in AST_Var_Expr | AST_Member_Expr then
         Success := False;
         return;
      end if;

      if Tree (Node).Kind = AST_Member_Expr then
         if Tree (Node).Left_Child = 0
           or else Tree (Node).Right_Child = 0
           or else Tree (Tree (Node).Left_Child).Kind /= AST_Var_Expr
           or else Tree (Tree (Node).Right_Child).Kind /= AST_Var_Expr
         then
            Success := False;
            return;
         end if;

         Base_Name := Extract_Name (Source, Tokens (Tree (Tree (Node).Left_Child).Token_Index));
         Field_Name := Extract_Name (Source, Tokens (Tree (Tree (Node).Right_Child).Token_Index));
         Base_Name := Resolve_Scoped_Parallel_Name (State, Base_Name);
         P_Slot := Find_Parallel (State, Base_Name);

         if P_Slot /= 0 then
            Full_Name := Compose_Name (Base_Name, Field_Name);
            A_Slot := Find_Array (State, Full_Name);
            if A_Slot = 0 then
               Success := False;
               return;
            end if;

            Evaluate_Index_List
              (Source,
               Tokens,
               Tree,
               Tree (Tree (Node).Left_Child).Left_Child,
               State,
               Indices,
               Count,
               Success);
            if not Success then
               return;
            end if;

            Offset := Flatten_Indices (State.Arrays (A_Slot), Indices, Count);
            if Offset = 0
              or else Offset > State.Arrays (A_Slot).Active_Length
              or else State.Arrays (A_Slot).Base + Offset - 1 > Max_Array_Cells
            then
               Success := False;
               return;
            end if;

            Need_Cast :=
              State.Arrays (A_Slot).Element_Tag /= Type_None
              and then State.Arrays (A_Slot).Element_Tag /= Value.Tag;

            if Need_Cast then
               Cast_Runtime_Value (State, State.Arrays (A_Slot).Element_Tag, Value, Casted, Success);
               if not Success then
                  return;
               end if;
               State.Array_Cells (State.Arrays (A_Slot).Base + Offset - 1) := Casted;
            else
               State.Array_Cells (State.Arrays (A_Slot).Base + Offset - 1) := Value;
               Success := True;
            end if;
         else
            Full_Name := Compose_Name (Base_Name, Field_Name);
            Upsert_Var (State, Full_Name, Value, Success);
         end if;
      else
         Name := Extract_Name (Source, Tokens (Tree (Node).Token_Index));
         if Tree (Node).Left_Child = 0 then
            Name := Resolve_Scoped_Var_Name (State, Name);

            -- Da shield is gone! We dinna care aboot Slot or tags anymore.
            -- We just force da new value and its new tag into da bank.
            Upsert_Var (State, Name, Value, Success);

            if Success then
               Sync_Temporal_Var (State, Name, Success);
            end if;
         else
            -- Keep dis part as is! Arrays/Structs should bide strict.
            Name := Resolve_Scoped_Array_Name (State, Name);
            A_Slot := Find_Array (State, Name);
            if A_Slot = 0 then
               Success := False;
               return;
            end if;

            Evaluate_Index_List
              (Source, Tokens, Tree, Tree (Node).Left_Child, State, Indices, Count, Success);
            if not Success then
               return;
            end if;

            Offset := Flatten_Indices (State.Arrays (A_Slot), Indices, Count);
            if Offset = 0
              or else Offset > State.Arrays (A_Slot).Active_Length
              or else State.Arrays (A_Slot).Base + Offset - 1 > Max_Array_Cells
            then
               Success := False;
               return;
            end if;

            Need_Cast :=
              State.Arrays (A_Slot).Element_Tag /= Type_None
              and then State.Arrays (A_Slot).Element_Tag /= Value.Tag;

            if Need_Cast then
               Cast_Runtime_Value (State, State.Arrays (A_Slot).Element_Tag, Value, Casted, Success);
               if not Success then
                  return;
               end if;
               State.Array_Cells (State.Arrays (A_Slot).Base + Offset - 1) := Casted;
            else
               State.Array_Cells (State.Arrays (A_Slot).Base + Offset - 1) := Value;
               Success := True;
            end if;
         end if;
      end if;
   end Write_Target;

   --  procedure Write_Declared_Target
   --    (Source  : in String;
   --     Tokens  : in Token_Array;
   --     Tree    : in Node_Array;
   --     Node    : in Node_Index;
   --     State   : in out Engine_State;
   --     Value   : in ALB_Value;
   --     Success : out Boolean)
   --  is
   --     Name   : Var_Name := (others => ' ');
   --     Slot   : Natural := 0;
   --     Casted : ALB_Value := (Tag => Type_None);
   --  begin
   --     if Node /= 0
   --       and then Tree (Node).Kind = AST_Var_Expr
   --       and then Tree (Node).Left_Child = 0
   --     then
   --        Name := Extract_Name (Source, Tokens (Tree (Node).Token_Index));
   --        Name := Declaration_Name (State, Name);
   --        if State.Call_Depth > 0 then
   --           Slot := Current_Call_Local_Var_Slot (State, Name);
   --        else
   --           Slot := Find_Var (State, Name);
   --        end if;
   --
   --     if Slot /= 0
   --       and then State.Bank (Slot).Value.Tag /= Type_None
   --       and then State.Bank (Slot).Value.Tag /= Value.Tag
   --     then
   --        Cast_Runtime_Value (State, State.Bank (Slot).Value.Tag, Value, Casted, Success);
   --        if not Success then
   --           return;
   --        end if;
   --        Upsert_Scoped_Local_Var (State, Name, Casted, Success);
   --        else
   --           Upsert_Scoped_Local_Var (State, Name, Value, Success);
   --        end if;
   --     else
   --        Write_Target (Source, Tokens, Tree, Node, State, Value, Success);
   --     end if;
   --  end Write_Declared_Target;

   procedure Write_Declared_Target
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      State   : in out Engine_State;
      Value   : in ALB_Value;
      Success : out Boolean)
   is
      Name   : Var_Name := (others => ' ');
      Slot   : Natural := 0;
   begin
      if Node /= 0
        and then Tree (Node).Kind = AST_Var_Expr
        and then Tree (Node).Left_Child = 0
      then
         Name := Extract_Name (Source, Tokens (Tree (Node).Token_Index));
         Name := Declaration_Name (State, Name);

         if State.Call_Depth > 0 then
            Slot := Current_Call_Local_Var_Slot (State, Name);
         else
            Slot := Find_Var (State, Name);
         end if;

         -- Da strict shield is gane! Just update da value an' let da tag mutate.
         Upsert_Scoped_Local_Var (State, Name, Value, Success);
      else
         Write_Target (Source, Tokens, Tree, Node, State, Value, Success);
      end if;
   end Write_Declared_Target;

   procedure Evaluate_Arguments
     (Source   : in String;
      Tokens   : in Token_Array;
      Tree     : in Node_Array;
      First    : in Node_Index;
      State    : in out Engine_State;
      Values   : out Arg_Value_Array;
      Count    : out Natural;
      Success  : out Boolean)
   is
      Curr : Node_Index := First;
   begin
      Values := (others => (Tag => Type_None));
      Count := 0;
      Success := True;

      while Curr /= 0 loop
         if Count = Max_Call_Args then
            Success := False;
            return;
         end if;

         Count := Count + 1;
         Evaluate_Expr (Source, Tokens, Tree, Curr, State, Values (Count), Success);
         if not Success then
            return;
         end if;

         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Evaluate_Arguments;

   function Graphics_Pure_Source_Node
     (Source    : String;
      Tokens    : Token_Array;
      Tree      : Node_Array;
      Expr_Node : Node_Index) return Node_Index
   is
      Target_Node : Node_Index := 0;
      Arg_List    : Node_Index := 0;
   begin
      if Expr_Node = 0 or else Tree (Expr_Node).Kind /= AST_Func_Call then
         return 0;
      end if;

      Target_Node := Tree (Expr_Node).Left_Child;
      if Target_Node = 0 or else Tree (Target_Node).Kind /= AST_Var_Expr then
         return 0;
      end if;

      if Name_Text (Extract_Name (Source, Tokens (Tree (Target_Node).Token_Index))) /= "PURE_NUM" then
         return 0;
      end if;

      Arg_List := Tree (Expr_Node).Right_Child;
      if Arg_List /= 0 and then Tree (Arg_List).Kind = AST_Arg_List then
         return Tree (Arg_List).Left_Child;
      end if;
      return 0;
   end Graphics_Pure_Source_Node;

   procedure Evaluate_Graphics_Integer_Expr
     (Source   : in String;
      Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      State    : in out Engine_State;
      Value    : out Long_Integer;
      Success  : out Boolean)
   is
      Raw_Value  : ALB_Value := (Tag => Type_None);
      Pure_Node  : constant Node_Index :=
        Graphics_Pure_Source_Node (Source, Tokens, Tree, Node);
   begin
      Value := 0;
      Success := False;

      if Pure_Node /= 0 then
         Evaluate_Expr (Source, Tokens, Tree, Pure_Node, State, Raw_Value, Success);
         if Success and then Raw_Value.Tag = Type_Pure then
            Try_As_Integer (State, Raw_Value, Value, Success);
            if Success then
               return;
            end if;
         end if;
      end if;

      Evaluate_Expr (Source, Tokens, Tree, Node, State, Raw_Value, Success);
      if not Success then
         return;
      end if;

      if Raw_Value.Tag = Type_Pure then
         Try_As_Integer (State, Raw_Value, Value, Success);
      else
         Try_As_Integer (State, Raw_Value, Value, Success);
      end if;
   end Evaluate_Graphics_Integer_Expr;

   procedure Evaluate_Argument_Integers
     (Source   : in String;
      Tokens   : in Token_Array;
      Tree     : in Node_Array;
      First    : in Node_Index;
      State    : in out Engine_State;
      Values   : out Int_Arg_Array;
      Count    : out Natural;
      Success  : out Boolean)
   is
      Raw_Values : Arg_Value_Array := (others => (Tag => Type_None));
   begin
      Values := (others => 0);
      Evaluate_Arguments (Source, Tokens, Tree, First, State, Raw_Values, Count, Success);
      if not Success then
         return;
      end if;

      for I in 1 .. Count loop
         Try_As_Integer (State, Raw_Values (I), Values (I), Success);
         if not Success then
            return;
         end if;
      end loop;
   end Evaluate_Argument_Integers;

   procedure Evaluate_Graphics_Argument_Integers
     (Source   : in String;
      Tokens   : in Token_Array;
      Tree     : in Node_Array;
      First    : in Node_Index;
      State    : in out Engine_State;
      Values   : out Int_Arg_Array;
      Count    : out Natural;
      Success  : out Boolean)
   is
      Curr : Node_Index := First;
   begin
      Values := (others => 0);
      Count := 0;
      Success := True;

      while Curr /= 0 loop
         if Count = Max_Call_Args then
            Success := False;
            return;
         end if;

         Count := Count + 1;
         Evaluate_Graphics_Integer_Expr
           (Source,
            Tokens,
            Tree,
            Curr,
            State,
            Values (Count),
            Success);
         if not Success then
            return;
         end if;

         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Evaluate_Graphics_Argument_Integers;

   --  function Resolve_Call_Name
   --    (Source : String;
   --     Tokens : Token_Array;
   --     Tree   : Node_Array;
   --     Node   : Node_Index) return Var_Name
   --  is
   --     Left_Name  : Var_Name := (others => ' ');
   --     Right_Name : Var_Name := (others => ' ');
   --  begin
   --     if Node = 0 then
   --        return (others => ' ');
   --     elsif Tree (Node).Kind = AST_Var_Expr then
   --        return Extract_Name (Source, Tokens (Tree (Node).Token_Index));
   --     elsif Tree (Node).Kind = AST_Member_Expr
   --       and then Tree (Node).Left_Child /= 0
   --       and then Tree (Node).Right_Child /= 0
   --       and then Tree (Tree (Node).Left_Child).Kind = AST_Var_Expr
   --       and then Tree (Tree (Node).Right_Child).Kind = AST_Var_Expr
   --     then
   --        Left_Name := Extract_Name (Source, Tokens (Tree (Tree (Node).Left_Child).Token_Index));
   --        Right_Name := Extract_Name (Source, Tokens (Tree (Tree (Node).Right_Child).Token_Index));
   --        return Compose_Name (Left_Name, Right_Name);
   --     else
   --        return (others => ' ');
   --     end if;
   --  end Resolve_Call_Name;

   function Resolve_Call_Name
     (Source : String;
      Tokens : Token_Array;
      Tree   : Node_Array;
      Node   : Node_Index) return Var_Name
   is
      Left_Name  : Var_Name := (others => ' ');
      Right_Name : Var_Name := (others => ' ');
      Right_Node : Node_Index;
   begin
      if Node = 0 then
         return (others => ' ');
      elsif Tree (Node).Kind = AST_Var_Expr then
         return Extract_Name (Source, Tokens (Tree (Node).Token_Index));
      elsif Tree (Node).Kind = AST_Member_Expr
        and then Tree (Node).Left_Child /= 0
        and then Tree (Node).Right_Child /= 0
        and then Tree (Tree (Node).Left_Child).Kind = AST_Var_Expr
      then
         Right_Node := Tree (Node).Right_Child;

         -- Unwrap nested function calls if the parser grouped them under the member expression
         if Tree (Right_Node).Kind = AST_Func_Call then
            Right_Node := Tree (Right_Node).Left_Child;
         end if;

         if Right_Node /= 0 and then Tree (Right_Node).Kind = AST_Var_Expr then
            Left_Name := Extract_Name (Source, Tokens (Tree (Tree (Node).Left_Child).Token_Index));
            Right_Name := Extract_Name (Source, Tokens (Tree (Right_Node).Token_Index));
            return Compose_Name (Left_Name, Right_Name);
         end if;
      end if;

      return (others => ' ');
   end Resolve_Call_Name;

   procedure Invoke_Routine
     (Source       : in String;
      Tokens       : in Token_Array;
      Tree         : in Node_Array;
      Name         : in Var_Name;
      Actual_First : in Node_Index;
      State        : in out Engine_State;
      Result       : out ALB_Value;
      Success      : out Boolean)
   is
      Proc_Slot           : Natural := 0;
      Resolved_Name       : Var_Name := Name;
      Args                : Arg_Value_Array := (others => (Tag => Type_None));
      Actual_Nodes        : Actual_Node_Array := (others => 0);
      Out_Params          : Bool_Array := (others => False);
      Saved               : Saved_Var_Array :=
        (others => (Slot => 0, Was_Active => False, Old_Name => (others => ' '), Old_Value => (Tag => Type_None)));
      Count               : Natural := 0;
      Param_Node          : Node_Index := 0;
      Current_Actual      : Node_Index := Actual_First;
      Save_Count          : Natural := 0;
      Arg_Index           : Natural := 0;
      Param_Name          : Var_Name := (others => ' ');
      Slot                : Natural := 0;
      Param_Tag           : ALB_Type_Tag := Type_None;
      Bound_Value         : ALB_Value := (Tag => Type_None);
      Prev_Return_Pending : Boolean := State.Return_Pending;
      Prev_Return_Value   : ALB_Value := State.Return_Value;
      Prev_Break          : Boolean := State.Break_Pending;
      Prev_Continue       : Boolean := State.Continue_Pending;
      Prev_Module         : Var_Name := State.Current_Module;
      Call_Module         : Var_Name := (others => ' ');
   begin
      Result := (Tag => Type_None);
      Success := False;

      Proc_Slot := Find_Proc (State, Resolved_Name);
      if Proc_Slot = 0
        and then In_Module_Scope (State)
        and then not Has_Qualifier (Resolved_Name)
      then
         Resolved_Name := Compose_Name (State.Current_Module, Name);
         Proc_Slot := Find_Proc (State, Resolved_Name);
      end if;
      if Proc_Slot = 0 then
         if Name_Text (Name) = "GETTICKCOUNT" then
            Slot := Find_Var (State, Make_Name ("TICK_COUNTER"));
            if Slot /= 0 then
               Result := State.Bank (Slot).Value;
            else
               Result := (Tag => Type_U32, Val_U32 => 0);
            end if;
            Success := True;
         elsif Name_Text (Name) = "PRINT_PURE" then
            Evaluate_Arguments (Source, Tokens, Tree, Actual_First, State, Args, Count, Success);
            if Success and then Count = 1 then
               Put_Line (Value_To_String (State, Args (1)));
            else
               Success := False;
            end if;
         elsif Name_Text (Name) = "INIT_SCREEN" then
            Success := True;
         end if;
         return;
      end if;

      Evaluate_Arguments (Source, Tokens, Tree, Actual_First, State, Args, Count, Success);
      if not Success then
         return;
      end if;

      if State.Procs (Proc_Slot).Params_Node /= 0 then
         Param_Node := Tree (State.Procs (Proc_Slot).Params_Node).Left_Child;
      end if;

      while Param_Node /= 0 loop
         Arg_Index := Arg_Index + 1;
         if Arg_Index > Count or else Arg_Index > Max_Call_Args then
            Success := False;
            return;
         end if;

         if Tree (Param_Node).Kind = AST_Param_Decl then
            Param_Name :=
              Extract_Name (Source, Tokens (Tree (Tree (Param_Node).Left_Child).Token_Index));
            if Tree (Param_Node).Right_Child /= 0 then
               Param_Tag :=
                 Resolve_Type_Tag
                   (State,
                    Extract_Name (Source, Tokens (Tree (Tree (Param_Node).Right_Child).Token_Index)));
            else
               Param_Tag := Type_None;
            end if;
            Out_Params (Arg_Index) :=
              Tree (Param_Node).Token_Index /= 0
              and then Tokens (Tree (Param_Node).Token_Index).Kind = Tok_Out;
         elsif Tree (Param_Node).Kind = AST_Var_Expr then
            Param_Name := Extract_Name (Source, Tokens (Tree (Param_Node).Token_Index));
            Param_Tag := Type_None;
         else
            Success := False;
            return;
         end if;

         Bound_Value := Args (Arg_Index);
         if Param_Tag /= Type_None and then Bound_Value.Tag /= Param_Tag then
            Cast_Runtime_Value (State, Param_Tag, Bound_Value, Bound_Value, Success);
            if not Success then
               return;
            end if;
         end if;

         Slot := Find_Var (State, Param_Name);
         Save_Count := Save_Count + 1;
         if Slot = 0 then
            for I in 1 .. Max_Vars loop
               if not State.Bank (I).Active then
                  Slot := I;
                  exit;
               end if;
            end loop;
            if Slot = 0 then
               Success := False;
               return;
            end if;
            Saved (Save_Count) :=
              (Slot => Slot, Was_Active => False, Old_Name => (others => ' '), Old_Value => (Tag => Type_None));
            State.Bank (Slot).Active := True;
            State.Bank (Slot).Name := Param_Name;
         else
            Saved (Save_Count) :=
              (Slot       => Slot,
               Was_Active => True,
               Old_Name   => State.Bank (Slot).Name,
               Old_Value  => State.Bank (Slot).Value);
         end if;

         State.Bank (Slot).Value := Bound_Value;
         Actual_Nodes (Arg_Index) := Current_Actual;
         if Current_Actual /= 0 then
            Current_Actual := Tree (Current_Actual).Next_Sibling;
         end if;
         Param_Node := Tree (Param_Node).Next_Sibling;
      end loop;

      if Arg_Index /= Count then
         Success := False;
         return;
      end if;

      State.Return_Pending := False;
      State.Return_Value := (Tag => Type_None);
      State.Break_Pending := False;
      State.Continue_Pending := False;

      if State.Procs (Proc_Slot).Body_Node = 0 then
         if Name_Text (Name) = "GETTICKCOUNT" then
            Slot := Find_Var (State, Make_Name ("TICK_COUNTER"));
            if Slot /= 0 then
               Result := State.Bank (Slot).Value;
            else
               Result := (Tag => Type_U32, Val_U32 => 0);
            end if;
            Success := True;
         elsif State.Procs (Proc_Slot).Return_Tag /= Type_None then
            Default_Value (State.Procs (Proc_Slot).Return_Tag, Result, Success);
         else
            Result := (Tag => Type_None);
            Success := True;
         end if;
      else
         Call_Module := Module_Prefix (State.Procs (Proc_Slot).Name);
         if Trimmed_Length (Call_Module) > 0 then
            State.Current_Module := Call_Module;
         end if;
         if State.Call_Depth = Max_Call_Depth then
            Success := False;
            return;
         end if;
         State.Call_Depth := State.Call_Depth + 1;
         Begin_Call_Scope (State);
         Execute (Source, Tokens, Tree, State.Procs (Proc_Slot).Body_Node, State, Success, 1.0);
         Restore_Call_Scope (State);
         State.Call_Depth := State.Call_Depth - 1;
         State.Current_Module := Prev_Module;

         if Success then
            if State.Return_Pending then
               Result := State.Return_Value;
            elsif State.Procs (Proc_Slot).Return_Tag /= Type_None then
               Default_Value (State.Procs (Proc_Slot).Return_Tag, Result, Success);
            else
               Result := (Tag => Type_None);
            end if;
         end if;
      end if;

      if Success then
         if State.Procs (Proc_Slot).Params_Node /= 0 then
            Param_Node := Tree (State.Procs (Proc_Slot).Params_Node).Left_Child;
         else
            Param_Node := 0;
         end if;
         Arg_Index := 0;
         while Param_Node /= 0 loop
            Arg_Index := Arg_Index + 1;
            if Out_Params (Arg_Index) and then Actual_Nodes (Arg_Index) /= 0 then
               declare
                  Local_Name : Var_Name := (others => ' ');
                  Local_Slot : Natural := 0;
               begin
                  if Tree (Param_Node).Kind = AST_Param_Decl then
                     Local_Name :=
                       Extract_Name (Source, Tokens (Tree (Tree (Param_Node).Left_Child).Token_Index));
                  else
                     Local_Name := Extract_Name (Source, Tokens (Tree (Param_Node).Token_Index));
                  end if;
                  Local_Slot := Find_Var (State, Local_Name);
                  if Local_Slot /= 0 then
                     Write_Target
                       (Source,
                        Tokens,
                        Tree,
                        Actual_Nodes (Arg_Index),
                        State,
                        State.Bank (Local_Slot).Value,
                        Success);
                     exit when not Success;
                  end if;
               end;
            end if;
            Param_Node := Tree (Param_Node).Next_Sibling;
         end loop;
      end if;

      State.Return_Pending := Prev_Return_Pending;
      State.Return_Value := Prev_Return_Value;
      State.Break_Pending := Prev_Break;
      State.Continue_Pending := Prev_Continue;

      for I in reverse 1 .. Save_Count loop
         if Saved (I).Slot > 0 then
            if Saved (I).Was_Active then
               State.Bank (Saved (I).Slot).Active := True;
               State.Bank (Saved (I).Slot).Name := Saved (I).Old_Name;
               State.Bank (Saved (I).Slot).Value := Saved (I).Old_Value;
            else
               State.Bank (Saved (I).Slot).Active := False;
               State.Bank (Saved (I).Slot).Name := (others => ' ');
               State.Bank (Saved (I).Slot).Value := (Tag => Type_None);
            end if;
         end if;
      end loop;
   end Invoke_Routine;

   procedure Evaluate_Call
     (Source      : in String;
      Tokens      : in Token_Array;
      Tree        : in Node_Array;
      Node        : in Node_Index;
      State       : in out Engine_State;
      Result      : out ALB_Value;
      Success     : out Boolean)
   is
      Name       : Var_Name := (others => ' ');
      Target     : Node_Index := 0;
      First_Arg  : Node_Index := 0;
      Args       : Arg_Value_Array := (others => (Tag => Type_None));
      Count      : Natural := 0;
      I_Val      : Long_Integer := 0;
      F_Val      : Long_Float := 0.0;
      Temp       : ALB_Value := (Tag => Type_None);
      P_Result   : Pure_Rational;
      R1, B1, W1, H1, R2, B2, W2, H2 : Long_Integer := 0;
      Hit        : Boolean := False;
   begin
      Result := (Tag => Type_None);
      Success := False;

      if Tree (Node).Kind = AST_Constructor then
         Name := Extract_Name (Source, Tokens (Tree (Node).Token_Index));
         First_Arg := Tree (Node).Left_Child;
      elsif Tree (Node).Kind = AST_Func_Call then
         Target := Tree (Node).Left_Child;
         Name := Resolve_Call_Name (Source, Tokens, Tree, Target);
         if Tree (Node).Right_Child /= 0 then
            First_Arg := Tree (Tree (Node).Right_Child).Left_Child;
         end if;
      else
         return;
      end if;

      Evaluate_Arguments (Source, Tokens, Tree, First_Arg, State, Args, Count, Success);
      if not Success then
         Result := (Tag => Type_None);
         return;
      end if;

      if Tree (Node).Kind = AST_Func_Call
        and then Target /= 0
        and then Tree (Target).Token_Index /= 0
        and then Tokens (Tree (Target).Token_Index).Kind = Tok_Pipe
      then
         declare
            Joined : Unbounded_String := To_Unbounded_String ("");
         begin
            for I in 1 .. Count loop
               Append (Joined, Value_To_String (State, Args (I)));
            end loop;
            Make_Binary_Value (State, To_String (Joined), Result, Success);
         end;
         return;
      end if;


      if Name_Text (Name) = "PURE" then
         if Count /= 2 then
            Result := (Tag => Type_Pure, Val_Pure => (Num => 0, Den => 1));
            Success := True;
            return;
         end if;

         Try_As_Whole_Integer (State, Args (1), I_Val, Success);

         declare
            Den : Long_Integer := 0;
         begin
            Try_As_Whole_Integer (State, Args (2), Den, Success);

            -- Let them shoot themselves, but dinna divide by zero under da hood!
            if Den = 0 then
               Den := 1;
            end if;

            Create_Pure (I_Val, Den, P_Result, Success);

            -- If formal reduction fails (e.g. overflow), force da unreduced fraction through anyway!
            if not Success then
               P_Result := (Num => I_Val, Den => Den);
            end if;

            Result := (Tag => Type_Pure, Val_Pure => P_Result);
            Success := True;
         end;
         return;

      elsif Resolve_Type_Tag (State, Name) /= Type_None then
         if Count /= 1 then
            Success := False;
            return;
         end if;
         Cast_Runtime_Value (State, Resolve_Type_Tag (State, Name), Args (1), Result, Success);
         return;
      elsif Name_Text (Name) = "PURE_ADD" then
         if Count = 2 then
            Add_Runtime_Values (State, Args (1), Args (2), Result, Success);
         end if;
         return;
      elsif Name_Text (Name) = "PURE_SUB" then
         if Count = 2 then
            Sub_Runtime_Values (State, Args (1), Args (2), Result, Success);
         end if;
         return;
      elsif Name_Text (Name) = "PURE_MUL" then
         if Count = 2 then
            Mul_Runtime_Values (State, Args (1), Args (2), Result, Success);
         end if;
         return;
      elsif Name_Text (Name) = "PURE_DIV" then
         if Count = 2 then
            Div_Runtime_Values (State, Args (1), Args (2), Result, Success);
         end if;
         return;
      elsif Name_Text (Name) = "PURE_POW" then
         if Count = 2 and then Args (1).Tag = Type_Pure then
            Try_As_Whole_Integer (State, Args (2), I_Val, Success);
            if not Success then
               return;
            end if;
            if I_Val = 0 then
               Create_Pure (1, 1, P_Result, Success);
               if Success then
                  Result := (Tag => Type_Pure, Val_Pure => P_Result);
               end if;
            else
               declare
                  Base_Value : ALB_Value := Args (1);
                  Power      : Natural := Natural (abs I_Val);
               begin
                  if I_Val < 0 then
                     Create_Pure
                       (Args (1).Val_Pure.Den,
                        Args (1).Val_Pure.Num,
                        P_Result,
                        Success);
                     if not Success then
                        Result := (Tag => Type_None);
                        return;
                     end if;
                     Base_Value := (Tag => Type_Pure, Val_Pure => P_Result);
                  end if;

                  Create_Pure (1, 1, P_Result, Success);
                  if not Success then
                     Result := (Tag => Type_None);
                     return;
                  end if;

                  Result := (Tag => Type_Pure, Val_Pure => P_Result);
                  for I in 1 .. Power loop
                     Mul_Runtime_Values (State, Result, Base_Value, Result, Success);
                     exit when not Success;
                  end loop;
               end;
            end if;
         end if;
         return;
      elsif Name_Text (Name) = "PURE_NUM" then
         if Count = 1 and then Args (1).Tag = Type_Pure then
            Result := (Tag => Type_S64, Val_S64 => S64 (Args (1).Val_Pure.Num));
            Success := True;
         end if;
         return;
      elsif Name_Text (Name) = "PURE_DEN" then
         if Count = 1 and then Args (1).Tag = Type_Pure then
            Result := (Tag => Type_S64, Val_S64 => S64 (Args (1).Val_Pure.Den));
            Success := True;
         end if;
         return;
      elsif Name_Text (Name) = "LEN" then
         if Count = 1 then
            Result := (Tag => Type_U32, Val_U32 => U32 (Value_To_String (State, Args (1))'Length));
            Success := True;
         end if;
         return;
      elsif Name_Text (Name) = "LEFT" or else Name_Text (Name) = "LEFT$" then
         if Count = 2 then
            declare
               S       : constant String := Value_To_String (State, Args (1));
               Take_Val : Long_Integer := 0;
               Use_Len : Natural := 0;
            begin
               Try_As_Integer (State, Args (2), Take_Val, Success);
               if Success then
                  if Take_Val > 0 then
                     Use_Len := Natural'Min (Natural (Take_Val), S'Length);
                  end if;
                  if Use_Len = 0 then
                     Make_Binary_Value (State, "", Result, Success);
                  else
                     Make_Binary_Value (State, S (1 .. Use_Len), Result, Success);
                  end if;
               end if;
            end;
         end if;
         return;
      elsif Name_Text (Name) = "RIGHT" or else Name_Text (Name) = "RIGHT$" then
         if Count = 2 then
            declare
               S       : constant String := Value_To_String (State, Args (1));
               Take_Val : Long_Integer := 0;
               Use_Len : Natural := 0;
            begin
               Try_As_Integer (State, Args (2), Take_Val, Success);
               if Success then
                  if Take_Val > 0 then
                     Use_Len := Natural'Min (Natural (Take_Val), S'Length);
                  end if;
                  if Use_Len = 0 then
                     Make_Binary_Value (State, "", Result, Success);
                  else
                     Make_Binary_Value (State, S (S'Length - Use_Len + 1 .. S'Length), Result, Success);
                  end if;
               end if;
            end;
         end if;
         return;
      elsif Name_Text (Name) = "MID" or else Name_Text (Name) = "MID$" then
         if Count = 3 then
            declare
               S         : constant String := Value_To_String (State, Args (1));
               Start_Pos : Long_Integer := 1;
               Take_Val  : Long_Integer := 0;
            begin
               Try_As_Integer (State, Args (2), Start_Pos, Success);
               if not Success then return; end if;
               Try_As_Integer (State, Args (3), Take_Val, Success);
               if not Success then return; end if;

               if Start_Pos < 1 or else Take_Val <= 0 or else Natural (Start_Pos) > S'Length then
                  Make_Binary_Value (State, "", Result, Success);
               else
                  declare
                     Last_Pos : constant Natural :=
                       Natural'Min (S'Length, Natural (Start_Pos + Take_Val - 1));
                  begin
                     Make_Binary_Value (State, S (Natural (Start_Pos) .. Last_Pos), Result, Success);
                  end;
               end if;
            end;
         end if;
         return;
      elsif Name_Text (Name) = "ASC" then
         if Count = 1 then
            declare
               S : constant String := Value_To_String (State, Args (1));
            begin
               if S'Length = 0 then
                  Result := (Tag => Type_U32, Val_U32 => 0);
               else
                  Result := (Tag => Type_U32, Val_U32 => U32 (Character'Pos (S (S'First))));
               end if;
               Success := True;
            end;
         end if;
         return;
      elsif Name_Text (Name) = "CONCAT" then
         if Count = 2 then
            Make_Binary_Value
              (State,
               Value_To_String (State, Args (1)) & Value_To_String (State, Args (2)),
               Result,
               Success);
         end if;
         return;
      elsif Name_Text (Name) = "CHOOSE" then
         if Count = 3 then
            declare
               Flag : Boolean := False;
            begin
               Boolean_Truth (State, Args (1), Flag, Success);
               if Success then
                  Result := (if Flag then Args (2) else Args (3));
               end if;
            end;
         end if;
         return;
      elsif Name_Text (Name) = "SIN" then
         if Count = 1 then
            Try_As_Float (State, Args (1), F_Val, Success);
            if Success then
               Result :=
                 (Tag => Type_F64,
                  Val_F64 => F64 (Ada.Numerics.Long_Elementary_Functions.Sin (F_Val)));
            end if;
         end if;
         return;
      elsif Name_Text (Name) = "COS" then
         if Count = 1 then
            Try_As_Float (State, Args (1), F_Val, Success);
            if Success then
               Result :=
                 (Tag => Type_F64,
                  Val_F64 => F64 (Ada.Numerics.Long_Elementary_Functions.Cos (F_Val)));
            end if;
         end if;
         return;
      elsif Name_Text (Name) = "SQRT" then
         if Count = 1 then
            Try_As_Float (State, Args (1), F_Val, Success);
            if Success then
               Result :=
                 (Tag => Type_F64,
                  Val_F64 => F64 (Ada.Numerics.Long_Elementary_Functions.Sqrt (F_Val)));
            end if;
         end if;
         return;
      elsif Name_Text (Name) = "EXP" then
         if Count = 1 then
            Try_As_Float (State, Args (1), F_Val, Success);
            if Success then
               Result :=
                 (Tag => Type_F64,
                  Val_F64 => F64 (Ada.Numerics.Long_Elementary_Functions.Exp (F_Val)));
            end if;
         end if;
         return;
      elsif Name_Text (Name) = "COLLIDE_RECT" then
         if Count /= 8 then
            return;
         end if;

         Try_As_Integer (State, Args (1), R1, Success); if not Success then return; end if;
         Try_As_Integer (State, Args (2), B1, Success); if not Success then return; end if;
         Try_As_Integer (State, Args (3), W1, Success); if not Success then return; end if;
         Try_As_Integer (State, Args (4), H1, Success); if not Success then return; end if;
         Try_As_Integer (State, Args (5), R2, Success); if not Success then return; end if;
         Try_As_Integer (State, Args (6), B2, Success); if not Success then return; end if;
         Try_As_Integer (State, Args (7), W2, Success); if not Success then return; end if;
         Try_As_Integer (State, Args (8), H2, Success); if not Success then return; end if;

         Hit :=
           (R1 < R2 + W2)
           and then (R1 + W1 > R2)
           and then (B1 < B2 + H2)
           and then (B1 + H1 > B2);
         Result := (Tag => Type_Boolean, Val_Bool => Hit);
         Success := True;
         return;
      end if;

      Invoke_Routine (Source, Tokens, Tree, Name, First_Arg, State, Result, Success);
      if not Success then
         declare
            Fail_Code : Oracle_Code;
            Fail_Node : Node_Index;
         begin
            Get_Last_Failure (Fail_Code, Fail_Node);
            if Fail_Code = Err_None then
               Set_Failure (Node, Err_Proc_Not_Found, Success);
            end if;
         end;
      end if;
   end Evaluate_Call;

   procedure Evaluate_Expr
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Root    : in Node_Index;
      State   : in out Engine_State;
      Result  : out ALB_Value;
      Success : out Boolean)
   is
      L_Val, R_Val, Tmp : ALB_Value := (Tag => Type_None);
      Truth             : Boolean := False;
      Rnd_Limit         : Long_Integer := 0;
      Int_L             : Long_Integer := 0;
      Int_R             : Long_Integer := 0;
      Name              : Var_Name := (others => ' ');
      Target_Tag        : ALB_Type_Tag := Type_None;
      Slot              : Natural := 0;
      Struct_Slot       : Natural := 0;
   begin
      Result := (Tag => Type_None);
      Success := False;

      if Root = 0 then
         return;
      end if;

      case Tree (Root).Kind is

         when AST_Number_Expr =>
            declare
               Tok_Text : constant String := Token_Lexeme (Source, Tokens (Tree (Root).Token_Index));
               Is_Float : Boolean := False;
               Num      : Long_Integer;
            begin
               for C of Tok_Text loop
                  if C = '.' then
                     Is_Float := True;
                     exit;
                  end if;
               end loop;

               if Is_Float then
                  Result := (Tag => Type_F64, Val_F64 => F64 (Parse_Decimal (Source, Tokens (Tree (Root).Token_Index))));
               else
                  Parse_Integer_Text (Tok_Text, Num, Success);
                  if Success then
                     Result := (Tag => Type_S64, Val_S64 => S64 (Num));
                  else
                     -- Fallback tae float ONLY if it's too massive for Long_Integer
                     Result := (Tag => Type_F64, Val_F64 => F64 (Parse_Decimal (Source, Tokens (Tree (Root).Token_Index))));
                  end if;
               end if;
               Success := True;
            end;

         when AST_Hex_Expr =>
            Result := (Tag => Type_S64, Val_S64 => S64 (Long_Integer (Parse_Radix (Source, Tokens (Tree (Root).Token_Index), 16, 1))));
            Success := True;

         when AST_Bin_Expr =>
            Result := (Tag => Type_S64, Val_S64 => S64 (Long_Integer (Parse_Radix (Source, Tokens (Tree (Root).Token_Index), 2, 1))));
            Success := True;

         when AST_Octal_Expr =>
            Result := (Tag => Type_S64, Val_S64 => S64 (Long_Integer (Parse_Radix (Source, Tokens (Tree (Root).Token_Index), 8, 1))));
            Success := True;

         when AST_True =>
            Result := (Tag => Type_Boolean, Val_Bool => True);
            Success := True;

         when AST_False =>
            Result := (Tag => Type_Boolean, Val_Bool => False);
            Success := True;

         when AST_String_Expr =>
            Make_Binary_Value
              (State,
               Extract_String_Literal (Source, Tokens (Tree (Root).Token_Index)),
               Result,
               Success);

         when AST_Var_Expr | AST_Const_Ref | AST_Member_Expr =>
            Read_Target (Source, Tokens, Tree, Root, State, Result, Success);

         when AST_Not =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if Success then
               Boolean_Truth (State, L_Val, Truth, Success);
               if Success then
                  Result := (Tag => Type_Boolean, Val_Bool => not Truth);
               end if;
            end if;

         when AST_Unary_Minus =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then
               return;
            end if;

            case L_Val.Tag is
               when Type_F32 =>
                  Result := (Tag => Type_F32, Val_F32 => -L_Val.Val_F32);
                  Success := True;
               when Type_F64 =>
                  Result := (Tag => Type_F64, Val_F64 => -L_Val.Val_F64);
                  Success := True;
               when Type_S8 =>
                  Result := (Tag => Type_S8, Val_S8 => -L_Val.Val_S8);
                  Success := True;
               when Type_S16 =>
                  Result := (Tag => Type_S16, Val_S16 => -L_Val.Val_S16);
                  Success := True;
               when Type_S32 =>
                  Result := (Tag => Type_S32, Val_S32 => -L_Val.Val_S32);
                  Success := True;
               when Type_S64 =>
                  Result := (Tag => Type_S64, Val_S64 => -L_Val.Val_S64);
                  Success := True;
               when Type_Pure =>
                  Result := (Tag => Type_Pure, Val_Pure => (Num => -L_Val.Val_Pure.Num, Den => L_Val.Val_Pure.Den));
                  Success := True;
               when others =>
                  Result := (Tag => Type_None);
                  Success := False;
            end case;

         when AST_Cast_Expr =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then
               return;
            end if;
            Name := Extract_Name (Source, Tokens (Tree (Root).Token_Index));
            Target_Tag := Resolve_Type_Tag (State, Name);
            if Target_Tag = Type_None then
               Success := False;
               return;
            end if;
            Cast_Runtime_Value (State, Target_Tag, L_Val, Result, Success);

         when AST_Constructor | AST_Func_Call =>
            Evaluate_Call (Source, Tokens, Tree, Root, State, Result, Success);

         when AST_Str_Len =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if Success then
               Result := (Tag => Type_U32, Val_U32 => U32 (Value_To_String (State, L_Val)'Length));
            end if;

         when AST_Str_Left =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then return; end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
            if not Success then return; end if;
            declare
               S        : constant String := Value_To_String (State, L_Val);
               Take_Val : Long_Integer := 0;
               Use_Len  : Natural := 0;
            begin
               Try_As_Integer (State, R_Val, Take_Val, Success);
               if Success then
                  if Take_Val > 0 then
                     Use_Len := Natural'Min (Natural (Take_Val), S'Length);
                  end if;
                  if Use_Len = 0 then
                     Make_Binary_Value (State, "", Result, Success);
                  else
                     Make_Binary_Value (State, S (1 .. Use_Len), Result, Success);
                  end if;
               end if;
            end;

         when AST_Str_Right =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then return; end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
            if not Success then return; end if;
            declare
               S        : constant String := Value_To_String (State, L_Val);
               Take_Val : Long_Integer := 0;
               Use_Len  : Natural := 0;
            begin
               Try_As_Integer (State, R_Val, Take_Val, Success);
               if Success then
                  if Take_Val > 0 then
                     Use_Len := Natural'Min (Natural (Take_Val), S'Length);
                  end if;
                  if Use_Len = 0 then
                     Make_Binary_Value (State, "", Result, Success);
                  else
                     Make_Binary_Value (State, S (S'Length - Use_Len + 1 .. S'Length), Result, Success);
                  end if;
               end if;
            end;

         when AST_Str_Mid =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then return; end if;
            if Tree (Root).Right_Child = 0 then
               Success := False;
               return;
            end if;
            Evaluate_Expr
              (Source,
               Tokens,
               Tree,
               Tree (Tree (Root).Right_Child).Left_Child,
               State,
               R_Val,
               Success);
            if not Success then return; end if;
            Evaluate_Expr
              (Source,
               Tokens,
               Tree,
               Tree (Tree (Tree (Root).Right_Child).Left_Child).Next_Sibling,
               State,
               Tmp,
               Success);
            if not Success then return; end if;
            declare
               S         : constant String := Value_To_String (State, L_Val);
               Start_Pos : Long_Integer := 1;
               Take_Val  : Long_Integer := 0;
            begin
               Try_As_Integer (State, R_Val, Start_Pos, Success);
               if not Success then return; end if;
               Try_As_Integer (State, Tmp, Take_Val, Success);
               if not Success then return; end if;
               if Start_Pos < 1 or else Take_Val <= 0 or else Natural (Start_Pos) > S'Length then
                  Make_Binary_Value (State, "", Result, Success);
               else
                  declare
                     Last_Pos : constant Natural :=
                       Natural'Min (S'Length, Natural (Start_Pos + Take_Val - 1));
                  begin
                     Make_Binary_Value (State, S (Natural (Start_Pos) .. Last_Pos), Result, Success);
                  end;
               end if;
            end;

         when AST_Str_Concat =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then return; end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
            if not Success then return; end if;
            Make_Binary_Value
              (State,
               Value_To_String (State, L_Val) & Value_To_String (State, R_Val),
               Result,
               Success);

         when AST_SizeOf_Expr =>
            if Tree (Root).Left_Child = 0 then
               Success := False;
               return;
            end if;
            Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            Slot := Find_Var (State, Name);
            if Slot /= 0 then
               Result := (Tag => Type_U32, Val_U32 => U32 (Type_Size_Bytes (State.Bank (Slot).Value.Tag)));
            else
               Struct_Slot := Find_Struct (State, Name);
               if Struct_Slot /= 0 then
                  Result := (Tag => Type_U32, Val_U32 => U32 (State.Structs (Struct_Slot).Size_Bytes));
               else
                  Result := (Tag => Type_U32, Val_U32 => U32 (Type_Size_Bytes (Resolve_Type_Tag (State, Name))));
               end if;
            end if;
            Success := True;

         when AST_TypeOf_Expr =>
            if Tree (Root).Left_Child = 0 then
               Success := False;
               return;
            end if;
            Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            Slot := Find_Var (State, Name);
            if Slot /= 0 then
               Make_Binary_Value (State, Type_Name_From_Tag (State.Bank (Slot).Value.Tag), Result, Success);
            elsif Find_Struct (State, Name) /= 0 then
               Make_Binary_Value (State, "STRUCT", Result, Success);
            else
               Make_Binary_Value (State, Type_Name_From_Tag (Resolve_Type_Tag (State, Name)), Result, Success);
            end if;

         when AST_OffsetOf_Expr =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Success := False;
               return;
            end if;
            Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            Struct_Slot := Find_Struct (State, Name);
            if Struct_Slot = 0 then
               Result := (Tag => Type_U32, Val_U32 => 0);
               Success := True;
            else
               declare
                  Field_Name : constant Var_Name :=
                    Extract_Name (Source, Tokens (Tree (Tree (Root).Right_Child).Token_Index));
                  Found : Boolean := False;
               begin
                  for I in 1 .. Max_Struct_Fields loop
                     if State.Structs (Struct_Slot).Fields (I).Active
                       and then State.Structs (Struct_Slot).Fields (I).Name = Field_Name
                     then
                        Result :=
                          (Tag => Type_U32,
                           Val_U32 => U32 (State.Structs (Struct_Slot).Fields (I).Offset));
                        Found := True;
                        exit;
                     end if;
                  end loop;
                  if not Found then
                     Result := (Tag => Type_U32, Val_U32 => 0);
                  end if;
                  Success := True;
               end;
            end if;

         when AST_Choose =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then return; end if;
            Boolean_Truth (State, L_Val, Truth, Success);
            if not Success then return; end if;
            if Tree (Root).Right_Child = 0 then
               Success := False;
               return;
            end if;
            if Truth then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Tree (Root).Right_Child).Left_Child, State, Result, Success);
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Tree (Root).Right_Child).Right_Child, State, Result, Success);
            end if;

         when AST_Rnd_Expr =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then
               return;
            end if;

            Try_As_Integer (State, L_Val, Rnd_Limit, Success);
            if not Success or else Rnd_Limit <= 0 then
               Success := False;
               return;
            end if;

            State.Random_Seed :=
              Natural ((1103515245 * Long_Long_Integer (State.Random_Seed) + 12345) mod 2147483647);
            Result :=
              (Tag => Type_S32,
               Val_S32 => S32 (State.Random_Seed mod Natural (Rnd_Limit)));
            Success := True;

         when AST_Key_State =>
            if Tree (Root).Left_Child = 0 then
               Result := (Tag => Type_Boolean, Val_Bool => False);
               Success := True;
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
               if not Success then
                  return;
               end if;
               Try_As_Integer (State, L_Val, Int_L, Success);
               if not Success then
                  return;
               end if;
               Result :=
                 (Tag => Type_Boolean,
                  Val_Bool => ALB_Graphics.Key_Down (Integer (Int_L)));
               Success := True;
            end if;

         when AST_Mouse_X | AST_Mouse_Y | AST_Mouse_Wheel | AST_VMouse_X | AST_VMouse_y =>
            case Tree (Root).Kind is
               when AST_Mouse_X =>
                  Result := (Tag => Type_S32, Val_S32 => S32 (ALB_Graphics.Mouse_X));
               when AST_Mouse_Y =>
                  Result := (Tag => Type_S32, Val_S32 => S32 (ALB_Graphics.Mouse_Y));
               when AST_Mouse_Wheel =>
                  Result := (Tag => Type_S32, Val_S32 => 0);
               when AST_VMouse_X =>
                  Result := (Tag => Type_S32, Val_S32 => S32 (ALB_Graphics.VMouse_X));
               when others =>
                  Result := (Tag => Type_S32, Val_S32 => S32 (ALB_Graphics.VMouse_Y));
            end case;
            Success := True;

         when AST_Mouse_Click =>
            if Tree (Root).Left_Child = 0 then
               Result := (Tag => Type_Boolean, Val_Bool => False);
               Success := True;
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
               if not Success then
                  return;
               end if;
               Try_As_Integer (State, L_Val, Int_L, Success);
               if not Success then
                  return;
               end if;
               Result :=
                 (Tag => Type_Boolean,
                  Val_Bool => ALB_Graphics.Mouse_Click (Integer (Int_L)) /= 0);
               Success := True;
            end if;

         when AST_SCREEN_WIDTH | AST_VIRTUAL_WIDTH =>
            Result := (Tag => Type_S32, Val_S32 => S32 (State.Window_Width));
            Success := True;

         when AST_SCREEN_HEIGHT | AST_VIRTUAL_HEIGHT =>
            Result := (Tag => Type_S32, Val_S32 => S32 (State.Window_Height));
            Success := True;

         when AST_READ_PIXEL =>
            if Tree (Root).Left_Child = 0
              or else Tree (Tree (Root).Left_Child).Left_Child = 0
            then
               Result := (Tag => Type_S32, Val_S32 => 0);
               Success := True;
            else
               Evaluate_Graphics_Integer_Expr
                 (Source, Tokens, Tree, Tree (Tree (Root).Left_Child).Left_Child, State, Int_L, Success);
               if not Success then return; end if;

               if Tree (Tree (Root).Left_Child).Left_Child /= 0
                 and then Tree (Tree (Tree (Root).Left_Child).Left_Child).Next_Sibling /= 0
               then
                  Evaluate_Graphics_Integer_Expr
                    (Source, Tokens, Tree, Tree (Tree (Tree (Root).Left_Child).Left_Child).Next_Sibling, State, Int_R, Success);
                  if not Success then return; end if;
               else
                  Int_R := 0;
               end if;

               Result :=
                 (Tag => Type_S32,
                  Val_S32 => S32 (ALB_Graphics.Read_Pixel (Integer (Int_L), Integer (Int_R))));
               Success := True;
            end if;

         when AST_Peek_Expr | AST_Deref_Expr =>
            Result := (Tag => Type_U32, Val_U32 => 0);
            Success := True;

         when AST_File_Open =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               Result := (Tag => Type_None);
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;

               Runtime_Open_File
                 (State,
                  Value_To_String (State, L_Val),
                  Value_To_String (State, R_Val),
                  Result,
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               end if;
            end if;

         when AST_File_Read =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               Result := (Tag => Type_None);
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;

               Runtime_Read_File (State, L_Val, R_Val, Result, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               end if;
            end if;

         when AST_File_Len =>
            if Tree (Root).Left_Child = 0 then
               Result := (Tag => Type_U64, Val_U64 => 0);
               Success := True;
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;
               Runtime_File_Len (State, Value_To_String (State, L_Val), Result, Success);
            end if;

         when AST_File_Seek =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Result := (Tag => Type_U64, Val_U64 => 0);
               Success := True;
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;
               Runtime_File_Seek (State, L_Val, R_Val, Result, Success);
            end if;

         when AST_Temporal_Ref =>
            Resolve_Temporal_Reference (Source, Tokens, Tree, Root, State, Result, Success);

         when AST_Find_Query =>
            declare
               Pred_Name : constant Var_Name := Extract_Name (Source, Tokens (Tree (Root).Token_Index));
               Match_Count : U32 := 0;
            begin
               for I in 1 .. Max_Clauses loop
                  exit when I > State.Clause_Count;
                  if State.Clauses (I).Active and then State.Clauses (I).Head_Name = Pred_Name then
                     if Tree (Root).Left_Child = 0 then
                        Match_Count := Match_Count + 1;
                     elsif State.Clauses (I).Arg_Count = 0 then
                        null;
                     elsif Tree (Tree (Root).Left_Child).Kind = AST_Var_Expr then
                        Match_Count := Match_Count + 1;
                     else
                        Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
                        if not Success then
                           return;
                        end if;
                        if Value_To_String (State, L_Val) = Name_Text (State.Clauses (I).Args (1).Name) then
                           Match_Count := Match_Count + 1;
                        end if;
                     end if;
                  end if;
               end loop;
               Result := (Tag => Type_U32, Val_U32 => Match_Count);
               Success := True;
            end;

         when AST_Atom =>
            Make_Binary_Value
              (State,
               Token_Lexeme (Source, Tokens (Tree (Root).Token_Index)),
               Result,
               Success);

         when AST_BinOp =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then return; end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
            if not Success then return; end if;

            case Tokens (Tree (Root).Token_Index).Kind is
               when Tok_Plus =>
                  Add_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Minus =>
                  Sub_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Mul =>
                  Mul_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Div =>
                  Div_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Mod =>
                  Mod_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Less =>
                  Less_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Greater =>
                  Greater_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Less_Equal =>
                  Greater_Runtime_Values (State, L_Val, R_Val, Tmp, Success);
                  if Success and then Tmp.Tag = Type_Boolean then
                     Result := (Tag => Type_Boolean, Val_Bool => not Tmp.Val_Bool);
                  else
                     Result := (Tag => Type_None);
                     Success := False;
                  end if;
               when Tok_Greater_Equal =>
                  Less_Runtime_Values (State, L_Val, R_Val, Tmp, Success);
                  if Success and then Tmp.Tag = Type_Boolean then
                     Result := (Tag => Type_Boolean, Val_Bool => not Tmp.Val_Bool);
                  else
                     Result := (Tag => Type_None);
                     Success := False;
                  end if;
               when Tok_Equal | Tok_Assign =>
                  Equal_Runtime_Values (State, L_Val, R_Val, Result, Success);
               when Tok_Not_Equal =>
                  Equal_Runtime_Values (State, L_Val, R_Val, Tmp, Success);
                  if Success and then Tmp.Tag = Type_Boolean then
                     Result := (Tag => Type_Boolean, Val_Bool => not Tmp.Val_Bool);
                  else
                     Result := (Tag => Type_None);
                     Success := False;
                  end if;
               when Tok_And =>
                  Boolean_Truth (State, L_Val, Truth, Success);
                  if Success then
                     declare
                        Other : Boolean := False;
                     begin
                        Boolean_Truth (State, R_Val, Other, Success);
                        if Success then
                           Result := (Tag => Type_Boolean, Val_Bool => (Truth and then Other));
                        end if;
                     end;
                  end if;
               when Tok_Or =>
                  Boolean_Truth (State, L_Val, Truth, Success);
                  if Success then
                     declare
                        Other : Boolean := False;
                     begin
                        Boolean_Truth (State, R_Val, Other, Success);
                        if Success then
                           Result := (Tag => Type_Boolean, Val_Bool => (Truth or else Other));
                        end if;
                     end;
                  end if;
               when Tok_Xor =>
                  Boolean_Truth (State, L_Val, Truth, Success);
                  if Success then
                     declare
                        Other : Boolean := False;
                     begin
                        Boolean_Truth (State, R_Val, Other, Success);
                        if Success then
                           Result := (Tag => Type_Boolean, Val_Bool => (Truth /= Other));
                        end if;
                     end;
                  end if;
               when Tok_Pipe =>
                  Make_Binary_Value
                    (State,
                     Value_To_String (State, L_Val) & Value_To_String (State, R_Val),
                     Result,
                     Success);
               when others =>
                  Result := (Tag => Type_None);
                  Success := False;
            end case;

         when others =>
            Result := (Tag => Type_None);
            Success := False;
      end case;
   exception
      when others =>
         Result := (Tag => Type_None);
         Set_Failure (Root, Err_Runtime_Unsupported, Success);
   end Evaluate_Expr;

   procedure Emit_Print_Item
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      State   : in out Engine_State;
      Success : out Boolean)
   is
      Value : ALB_Value := (Tag => Type_None);
   begin
      if Node = 0 then
         Success := True;
         return;
      end if;

      if Tree (Node).Kind = AST_String_Expr then
         Put (Extract_String_Literal (Source, Tokens (Tree (Node).Token_Index)));
         Success := True;
      else
         Evaluate_Expr (Source, Tokens, Tree, Node, State, Value, Success);
         if Success then
            Put (Value_To_String (State, Value));
         end if;
      end if;
   end Emit_Print_Item;

   procedure Solve_Query
     (Source      : in String;
      Tokens      : in Token_Array;
      Tree        : in Node_Array;
      Query_Pred  : in Node_Index;
      State       : in Engine_State;
      Success     : out Boolean)
   is
      Q_Name     : Var_Name := (others => ' ');
      Q_Arg      : Node_Index := 0;
      Match      : Boolean := False;
      Bind_Count : Natural := 0;
      type Binding is record
         Logic_Var : Var_Name := (others => ' ');
         Bound_Val : Var_Name := (others => ' ');
         Active    : Boolean := False;
      end record;
      type Bind_Array is array (1 .. Max_Logic_Args) of Binding;
      Binds : Bind_Array := (others => (Logic_Var => (others => ' '), Bound_Val => (others => ' '), Active => False));
   begin
      Success := False;
      if Query_Pred = 0 then
         return;
      end if;

      Q_Name := Extract_Name (Source, Tokens (Tree (Query_Pred).Token_Index));

      for I in 1 .. Max_Clauses loop
         exit when I > State.Clause_Count;
         if State.Clauses (I).Active and then State.Clauses (I).Head_Name = Q_Name then
            Match := True;
            Bind_Count := 0;
            Q_Arg := Tree (Query_Pred).Left_Child;

            for J in 1 .. Max_Logic_Args loop
               exit when Q_Arg = 0 and then J > State.Clauses (I).Arg_Count;

               if Q_Arg = 0 or else J > State.Clauses (I).Arg_Count then
                  Match := False;
                  exit;
               end if;

               declare
                  Q_Name_Arg : constant Var_Name := Make_Name (Token_Lexeme (Source, Tokens (Tree (Q_Arg).Token_Index)));
                  F_Name_Arg : constant Var_Name := State.Clauses (I).Args (J).Name;
               begin
                  if Tree (Q_Arg).Kind in AST_Atom | AST_Number_Expr | AST_Hex_Expr |
                                           AST_Bin_Expr | AST_Octal_Expr | AST_String_Expr
                  then
                     if Q_Name_Arg /= F_Name_Arg then
                        Match := False;
                        exit;
                     end if;
                  elsif Tree (Q_Arg).Kind = AST_Logic_Var then
                     if Bind_Count < Max_Logic_Args then
                        Bind_Count := Bind_Count + 1;
                        Binds (Bind_Count) :=
                          (Logic_Var => Q_Name_Arg, Bound_Val => F_Name_Arg, Active => True);
                     end if;
                  else
                     Match := False;
                     exit;
                  end if;
               end;

               Q_Arg := Tree (Q_Arg).Next_Sibling;
            end loop;

            if Match then
               Put_Line ("ALB-LOGIC> MATCH");
               for B in 1 .. Bind_Count loop
                  if Binds (B).Active then
                     Put_Line
                       ("ALB-LOGIC> "
                        & Name_Text (Binds (B).Logic_Var)
                        & " = "
                        & Name_Text (Binds (B).Bound_Val));
                  end if;
               end loop;
               Success := True;
            end if;
         end if;
      end loop;

      if not Success then
         Put_Line ("ALB-LOGIC> FALSE");
      end if;
   end Solve_Query;

   procedure Execute
     (Source  : in String;
      Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Root    : in Node_Index;
      State   : in out Engine_State;
      Success : out Boolean;
      Mask    : in Long_Float)
   is
      Res        : ALB_Value := (Tag => Type_None);
      Tmp        : ALB_Value := (Tag => Type_None);
      L_Val      : ALB_Value := (Tag => Type_None);
      R_Val      : ALB_Value := (Tag => Type_None);
      Cond       : Boolean := False;
      Curr       : Node_Index := 0;
      Next_Print : Node_Index := 0;
      Name_Node  : Node_Index := 0;
      Target     : Node_Index := 0;
      V_Name     : Var_Name := (others => ' ');
      Expected   : ALB_Type_Tag := Type_None;
      Defaulted  : ALB_Value := (Tag => Type_None);
      Dims       : Dim_Array := (others => 0);
      Dim_Count  : Natural := 0;
      Total      : Natural := 0;
      Arr_Slot   : Natural := 0;
      Bounds     : RS_Interval := (Lower => 0.0, Upper => 0.0);
      Bytes      : Natural := 0;
      Max_Val    : Long_Integer := 0;
      Active_Val : Long_Integer := 0;
      Proc_Slot  : Natural := 0;
      Call_Name  : Var_Name := (others => ' ');
      Struct_Slot : Natural := 0;
      Parallel_Slot : Natural := 0;
      Field_Slot : Natural := 0;
      Saved      : Saved_Var_Array := (others => (Slot => 0, Was_Active => False, Old_Name => (others => ' '), Old_Value => (Tag => Type_None)));
      Arg_Values : Arg_Value_Array := (others => (Tag => Type_None));
      Arg_Ints   : Int_Arg_Array := (others => 0);
      Arg_Count  : Natural := 0;
   begin
      if Mask = 0.0 then
         Success := True;
         return;
      end if;

      if Root = 0 then
         Success := True;
         return;
      end if;

      Clear_Last_Failure;
      Success := True;

      case Tree (Root).Kind is
         when AST_Version =>
            Success := True;

         when AST_Print_Stmt | AST_Print_Str_Stmt =>
            Curr := Root;
            while Curr /= 0 loop
               Emit_Print_Item (Source, Tokens, Tree, Tree (Curr).Left_Child, State, Success);
               if not Success then
                  Set_Failure (Curr, Err_Type_Conflict, Success);
                  return;
               end if;
               Curr := Tree (Curr).Right_Child;
            end loop;
            New_Line;

         when AST_Program =>
            if Tree (Root).Left_Child /= 0 then
               Execute (Source, Tokens, Tree, Tree (Root).Left_Child, State, Success, 1.0);
            else
               Success := True;
            end if;

         when AST_Block_Stmt =>
            Curr := Tree (Root).Left_Child;
            while Curr /= 0 loop
               Execute (Source, Tokens, Tree, Curr, State, Success, 1.0);
               if not Success then
                  return;
               end if;
               exit when State.Return_Pending or else State.Break_Pending or else State.Continue_Pending;
               Curr := Tree (Curr).Next_Sibling;
            end loop;

         --  when AST_Let_Stmt =>
         --     Target := Tree (Root).Left_Child;
         --     if Target = 0 then
         --        Set_Failure (Root, Err_Type_Conflict, Success);
         --        return;
         --     end if;
         --
         --     if Tree (Root).Token_Index /= 0 then
         --        Expected :=
         --          Resolve_Type_Tag
         --            (State, Extract_Name (Source, Tokens (Tree (Root).Token_Index)));
         --     else
         --        Expected := Type_None;
         --     end if;
         --
         --     if Tree (Root).Right_Child = 0 then
         --        if Expected = Type_None then
         --           Defaulted := (Tag => Type_None);
         --           Success := True;
         --        else
         --           Default_Value (Expected, Defaulted, Success);
         --        end if;
         --     else
         --        Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, Res, Success);
         --        if not Success then
         --           Set_Failure (Root, Err_Type_Conflict, Success);
         --           return;
         --        end if;
         --
         --        if Expected /= Type_None and then Res.Tag /= Expected then
         --           Cast_Runtime_Value (State, Expected, Res, Defaulted, Success);
         --           if not Success then
         --              Set_Failure (Root, Err_Type_Conflict, Success);
         --              return;
         --           end if;
         --        else
         --           Defaulted := Res;
         --        end if;
         --     end if;
         --
         --     Write_Declared_Target (Source, Tokens, Tree, Target, State, Defaulted, Success);
         --     if not Success then
         --        Set_Failure (Root, Err_Type_Conflict, Success);
         --     end if;

         when AST_Let_Stmt =>
            Target := Tree (Root).Left_Child;
            if Target = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            if Tree (Root).Token_Index /= 0 then
               Expected :=
                 Resolve_Type_Tag
                   (State, Extract_Name (Source, Tokens (Tree (Root).Token_Index)));
            else
               Expected := Type_None;
            end if;

            if Tree (Root).Right_Child = 0 then
               if Expected = Type_None then
                  Defaulted := (Tag => Type_None);
                  Success := True;
               else
                  Default_Value (Expected, Defaulted, Success);
               end if;
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, Res, Success);
               if not Success then
                  declare
                     Fail_Code : Oracle_Code;
                     Fail_Node : Node_Index;
                  begin
                     Get_Last_Failure (Fail_Code, Fail_Node);
                     if Fail_Code = Err_None then
                        Set_Failure (Root, Err_Type_Conflict, Success);
                     end if;
                  end;
                  return;
               end if;

               if Expected /= Type_None and then Res.Tag /= Expected then
                  Cast_Runtime_Value (State, Expected, Res, Defaulted, Success);
                  if not Success then
                     declare
                        Fail_Code : Oracle_Code;
                        Fail_Node : Node_Index;
                     begin
                        Get_Last_Failure (Fail_Code, Fail_Node);
                        if Fail_Code = Err_None then
                           Set_Failure (Root, Err_Type_Conflict, Success);
                        end if;
                     end;
                     return;
                  end if;
               else
                  Defaulted := Res;
               end if;
            end if;

            Write_Declared_Target (Source, Tokens, Tree, Target, State, Defaulted, Success);
            if not Success then
               declare
                  Fail_Code : Oracle_Code;
                  Fail_Node : Node_Index;
               begin
                  Get_Last_Failure (Fail_Code, Fail_Node);
                  if Fail_Code = Err_None then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                  end if;
               end;
            end if;

         when AST_Const_Decl =>
            Name_Node := Tree (Root).Left_Child;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            if Name_Node = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            V_Name := Extract_Name (Source, Tokens (Tree (Name_Node).Token_Index));
            V_Name := Declaration_Name (State, V_Name);
            Upsert_Scoped_Local_Var (State, V_Name, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
            end if;

         when AST_If_Stmt =>
            if Tree (Tree (Root).Left_Child).Kind = AST_Query then
               Solve_Query (Source, Tokens, Tree, Tree (Tree (Root).Left_Child).Left_Child, State, Success);
               Cond := Success;
               Success := True;
            else
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Boolean_Truth (State, Res, Cond, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
            end if;

            if Cond then
               Execute (Source, Tokens, Tree, Tree (Root).Right_Child, State, Success, 1.0);
            elsif Tree (Tree (Root).Right_Child).Next_Sibling /= 0 then
               Execute
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Root).Right_Child).Next_Sibling,
                  State,
                  Success,
                  1.0);
            else
               Success := True;
            end if;

         when AST_Repeat_Stmt =>
            for I in 1 .. 1024 loop
               Execute (Source, Tokens, Tree, Tree (Root).Left_Child, State, Success, 1.0);
               if not Success then
                  return;
               end if;
               if State.Return_Pending then
                  return;
               elsif State.Break_Pending then
                  State.Break_Pending := False;
                  exit;
               elsif State.Continue_Pending then
                  State.Continue_Pending := False;
               end if;

               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Boolean_Truth (State, Res, Cond, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               exit when Cond;
            end loop;

         when AST_For_Stmt =>
            declare
               Dummy      : constant Node_Index := Tree (Root).Left_Child;
               Start_Node : constant Node_Index := Tree (Dummy).Left_Child;
               End_Node   : Node_Index := 0;
               Step_Node  : Node_Index := 0;
               Start_Val  : ALB_Value := (Tag => Type_None);
               End_Val    : ALB_Value := (Tag => Type_None);
               Step_Val   : ALB_Value := (Tag => Type_None);
               Loop_Val   : ALB_Value := (Tag => Type_None);
               Check      : ALB_Value := (Tag => Type_None);
               Negative_Step : Boolean := False;
               Step_Float : Long_Float := 0.0;
               Loop_Name  : constant Var_Name := Extract_Name (Source, Tokens (Tree (Root).Token_Index));
            begin
               Evaluate_Expr (Source, Tokens, Tree, Start_Node, State, Start_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;

               if Tree (Dummy).Right_Child /= 0 and then Tree (Tree (Dummy).Right_Child).Kind = AST_Arg_List then
                  End_Node := Tree (Tree (Dummy).Right_Child).Left_Child;
                  if End_Node /= 0 then
                     Step_Node := Tree (End_Node).Next_Sibling;
                  end if;
               else
                  End_Node := Tree (Dummy).Right_Child;
               end if;

               Evaluate_Expr (Source, Tokens, Tree, End_Node, State, End_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;

               if Step_Node = 0 then
                  Default_Value (Start_Val.Tag, Step_Val, Success);
                  if not Success then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                     return;
                  end if;
                  case Start_Val.Tag is
                     when Type_U8 =>
                        Step_Val := (Tag => Type_U8, Val_U8 => 1);
                     when Type_U16 =>
                        Step_Val := (Tag => Type_U16, Val_U16 => 1);
                     when Type_U32 =>
                        Step_Val := (Tag => Type_U32, Val_U32 => 1);
                     when Type_U64 =>
                        Step_Val := (Tag => Type_U64, Val_U64 => 1);
                     when Type_S8 =>
                        Step_Val := (Tag => Type_S8, Val_S8 => 1);
                     when Type_S16 =>
                        Step_Val := (Tag => Type_S16, Val_S16 => 1);
                     when Type_S32 =>
                        Step_Val := (Tag => Type_S32, Val_S32 => 1);
                     when Type_S64 =>
                        Step_Val := (Tag => Type_S64, Val_S64 => 1);
                     when Type_F32 =>
                        Step_Val := (Tag => Type_F32, Val_F32 => 1.0);
                     when Type_F64 =>
                        Step_Val := (Tag => Type_F64, Val_F64 => 1.0);
                     when Type_Pure =>
                        declare
                           P_Step : Pure_Rational;
                        begin
                           Create_Pure (1, 1, P_Step, Success);
                           if not Success then
                              Set_Failure (Root, Err_Type_Conflict, Success);
                              return;
                           end if;
                           Step_Val := (Tag => Type_Pure, Val_Pure => P_Step);
                        end;
                     when others =>
                        Set_Failure (Root, Err_Type_Conflict, Success);
                        return;
                  end case;
               else
                  Evaluate_Expr (Source, Tokens, Tree, Step_Node, State, Step_Val, Success);
                  if not Success then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                     return;
                  end if;
               end if;

               Try_As_Float (State, Step_Val, Step_Float, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Negative_Step := Step_Float < 0.0;

               Upsert_Scoped_Local_Var (State, Loop_Name, Start_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;

               Loop_Val := Start_Val;
               for I in 1 .. 4096 loop
                  if Negative_Step then
                     Less_Runtime_Values (State, Loop_Val, End_Val, Check, Success);
                  else
                     Greater_Runtime_Values (State, Loop_Val, End_Val, Check, Success);
                  end if;
                  if not Success then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                     return;
                  end if;
                  exit when Check.Tag = Type_Boolean and then Check.Val_Bool;

                  Execute (Source, Tokens, Tree, Tree (Root).Right_Child, State, Success, 1.0);
                  if not Success then
                     return;
                  end if;
                  if State.Return_Pending then
                     return;
                  elsif State.Break_Pending then
                     State.Break_Pending := False;
                     exit;
                  elsif State.Continue_Pending then
                     State.Continue_Pending := False;
                  end if;

                  Add_Runtime_Values (State, Loop_Val, Step_Val, Loop_Val, Success);
                  if not Success then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                     return;
                  end if;

                  Upsert_Scoped_Local_Var (State, Loop_Name, Loop_Val, Success);
                  if not Success then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                     return;
                  end if;
               end loop;
            end;

         when AST_Select_Stmt =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            Curr := Tree (Root).Right_Child;
            while Curr /= 0 loop
               if Tree (Curr).Left_Child = 0 then
                  Execute (Source, Tokens, Tree, Tree (Curr).Right_Child, State, Success, 1.0);
                  return;
               end if;

               Evaluate_Expr (Source, Tokens, Tree, Tree (Curr).Left_Child, State, Defaulted, Success);
               if not Success then
                  Set_Failure (Curr, Err_Type_Conflict, Success);
                  return;
               end if;
               Equal_Runtime_Values (State, Res, Defaulted, Tmp, Success);
               if not Success then
                  Set_Failure (Curr, Err_Type_Conflict, Success);
                  return;
               end if;
               if Tmp.Tag = Type_Boolean and then Tmp.Val_Bool then
                  Execute (Source, Tokens, Tree, Tree (Curr).Right_Child, State, Success, 1.0);
                  return;
               end if;
               Curr := Tree (Curr).Next_Sibling;
            end loop;
            Success := True;

         when AST_Match_Stmt =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            Curr := Tree (Root).Right_Child;
            while Curr /= 0 loop
               if Tree (Curr).Left_Child = 0 then
                  Execute (Source, Tokens, Tree, Tree (Curr).Right_Child, State, Success, 1.0);
                  return;
               end if;

               Evaluate_Expr (Source, Tokens, Tree, Tree (Curr).Left_Child, State, Defaulted, Success);
               if not Success then
                  Set_Failure (Curr, Err_Type_Conflict, Success);
                  return;
               end if;
               Equal_Runtime_Values (State, Res, Defaulted, Tmp, Success);
               if not Success then
                  Set_Failure (Curr, Err_Type_Conflict, Success);
                  return;
               end if;
               if Tmp.Tag = Type_Boolean and then Tmp.Val_Bool then
                  Execute (Source, Tokens, Tree, Tree (Curr).Right_Child, State, Success, 1.0);
                  return;
               end if;
               Curr := Tree (Curr).Next_Sibling;
            end loop;
            Success := True;

         when AST_While_Stmt =>
            for I in 1 .. 4096 loop
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Boolean_Truth (State, Res, Cond, Success);
               if not Success or else not Cond then
                  exit;
               end if;

               Execute (Source, Tokens, Tree, Tree (Root).Right_Child, State, Success, 1.0);
               if not Success then
                  return;
               elsif State.Return_Pending then
                  return;
               elsif State.Break_Pending then
                  State.Break_Pending := False;
                  exit;
               elsif State.Continue_Pending then
                  State.Continue_Pending := False;
               end if;
            end loop;
            Success := True;

         when AST_Foreach_Stmt =>
            Name_Node := Tree (Root).Left_Child;
            if Name_Node = 0 or else Tree (Name_Node).Kind /= AST_Var_Expr then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            V_Name := Extract_Name (Source, Tokens (Tree (Name_Node).Token_Index));
            V_Name := Resolve_Scoped_Array_Name (State, V_Name);
            Arr_Slot := Find_Array (State, V_Name);
            if Arr_Slot = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Call_Name := Extract_Name (Source, Tokens (Tree (Root).Token_Index));
            for I in 1 .. State.Arrays (Arr_Slot).Active_Length loop
               Upsert_Scoped_Local_Var
                 (State,
                  Call_Name,
                  State.Array_Cells (State.Arrays (Arr_Slot).Base + I - 1),
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Execute (Source, Tokens, Tree, Tree (Root).Right_Child, State, Success, 1.0);
               if not Success then
                  return;
               elsif State.Return_Pending then
                  return;
               elsif State.Break_Pending then
                  State.Break_Pending := False;
                  exit;
               elsif State.Continue_Pending then
                  State.Continue_Pending := False;
               end if;
            end loop;
            Success := True;

         when AST_Range_Type_Decl =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            V_Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            Expected :=
              Resolve_Type_Tag
                (State, Extract_Name (Source, Tokens (Tree (Tree (Root).Right_Child).Token_Index)));
            if Expected = Type_None then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Proc_Slot := Find_Named_Type (State, V_Name);
            if Proc_Slot = 0 then
               for I in 1 .. Max_Named_Types loop
                  if not State.Named_Types (I).Active then
                     Proc_Slot := I;
                     exit;
                  end if;
               end loop;
            end if;
            if Proc_Slot = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            State.Named_Types (Proc_Slot).Active := True;
            State.Named_Types (Proc_Slot).Name := V_Name;
            State.Named_Types (Proc_Slot).Base_Tag := Expected;
            Success := True;

         when AST_Enum_Decl =>
            Curr := Tree (Root).Left_Child;
            Max_Val := 0;
            while Curr /= 0 loop
               V_Name := Extract_Name (Source, Tokens (Tree (Curr).Token_Index));
               Upsert_Scoped_Local_Var
                 (State,
                  V_Name,
                  (Tag => Type_U32, Val_U32 => U32 (Max_Val)),
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Max_Val := Max_Val + 1;
               Curr := Tree (Curr).Next_Sibling;
            end loop;
            Success := True;

         when AST_Struct_Decl =>
            if Tree (Root).Left_Child = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            V_Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            Struct_Slot := Find_Struct (State, V_Name);
            if Struct_Slot = 0 then
               for I in 1 .. Max_Structs loop
                  if not State.Structs (I).Active then
                     Struct_Slot := I;
                     exit;
                  end if;
               end loop;
            end if;
            if Struct_Slot = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            declare
               Blank_Struct : Struct_Record;
            begin
               State.Structs (Struct_Slot) := Blank_Struct;
            end;
            State.Structs (Struct_Slot).Active := True;
            State.Structs (Struct_Slot).Name := V_Name;
            Bytes := 0;
            Curr :=
              (if Tree (Root).Right_Child = 0
               then 0
               elsif Tree (Tree (Root).Right_Child).Kind = AST_Block_Stmt
               then Tree (Tree (Root).Right_Child).Left_Child
               else Tree (Root).Right_Child);
            while Curr /= 0 loop
               if State.Structs (Struct_Slot).Field_Count = Max_Struct_Fields then
                  exit;
               end if;
               State.Structs (Struct_Slot).Field_Count :=
                 State.Structs (Struct_Slot).Field_Count + 1;
               Field_Slot := State.Structs (Struct_Slot).Field_Count;

               if Tree (Curr).Kind = AST_Bitfield_Decl then
                  State.Structs (Struct_Slot).Fields (Field_Slot).Active := True;
                  State.Structs (Struct_Slot).Fields (Field_Slot).Name :=
                    Extract_Name (Source, Tokens (Tree (Tree (Curr).Left_Child).Token_Index));
                  State.Structs (Struct_Slot).Fields (Field_Slot).Tag := Type_U8;
                  State.Structs (Struct_Slot).Fields (Field_Slot).Offset := Bytes;
                  State.Structs (Struct_Slot).Fields (Field_Slot).Size := 1;
                  Bytes := Bytes + 1;
               elsif Tree (Curr).Left_Child /= 0 then
                  State.Structs (Struct_Slot).Fields (Field_Slot).Active := True;
                  State.Structs (Struct_Slot).Fields (Field_Slot).Name :=
                    Extract_Name (Source, Tokens (Tree (Tree (Curr).Left_Child).Token_Index));
                  if Tree (Tree (Curr).Left_Child).Right_Child /= 0 then
                     Expected :=
                       Resolve_Type_Tag
                         (State,
                          Extract_Name
                            (Source,
                             Tokens (Tree (Tree (Tree (Curr).Left_Child).Right_Child).Token_Index)));
                  else
                     Expected := Type_U32;
                  end if;
                  State.Structs (Struct_Slot).Fields (Field_Slot).Tag := Expected;
                  State.Structs (Struct_Slot).Fields (Field_Slot).Offset := Bytes;
                  State.Structs (Struct_Slot).Fields (Field_Slot).Size := Type_Size_Bytes (Expected);
                  Bytes := Bytes + Type_Size_Bytes (Expected);
               end if;
               Curr := Tree (Curr).Next_Sibling;
            end loop;
            State.Structs (Struct_Slot).Size_Bytes := Bytes;
            Success := True;

         when AST_Temporal_Decl =>
            Target := Tree (Root).Left_Child;
            if Target = 0 or else Tree (Root).Right_Child = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            if Tree (Root).Token_Index /= 0 then
               Expected := Resolve_Type_Tag (State, Extract_Name (Source, Tokens (Tree (Root).Token_Index)));
            else
               Expected := Type_None;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, Tmp, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Try_As_Integer (State, Tmp, Max_Val, Success);
            if not Success or else Max_Val < 1 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Next_Print := Tree (Tree (Root).Right_Child).Next_Sibling;
            if Next_Print = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Next_Print, State, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            if Expected /= Type_None and then Res.Tag /= Expected then
               Cast_Runtime_Value (State, Expected, Res, Defaulted, Success);
            else
               Defaulted := Res;
               Success := True;
            end if;
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Write_Declared_Target (Source, Tokens, Tree, Target, State, Defaulted, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            if Tree (Target).Kind = AST_Var_Expr and then Tree (Target).Left_Child = 0 then
               V_Name := Extract_Name (Source, Tokens (Tree (Target).Token_Index));
               V_Name := Resolve_Scoped_Var_Name (State, V_Name);
               Register_Temporal
                 (State,
                  V_Name,
                  (if Max_Val > Long_Integer (Max_Temporal_History)
                   then Max_Temporal_History
                   else Natural (Max_Val)),
                  Defaulted,
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
               end if;
            end if;

         when AST_Input_Stmt | AST_Readline_Stmt =>
            declare
               Prompt_Text  : Unbounded_String := To_Unbounded_String ("");
               Prompt_Value : ALB_Value := (Tag => Type_None);
            begin
               if Tree (Root).Kind = AST_Input_Stmt and then Tree (Root).Left_Child /= 0 then
                  Evaluate_Expr
                    (Source,
                     Tokens,
                     Tree,
                     Tree (Root).Left_Child,
                     State,
                     Prompt_Value,
                     Success);
                  if not Success then
                     Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                     return;
                  end if;
                  Prompt_Text := To_Unbounded_String (Value_To_String (State, Prompt_Value));
               end if;

               Read_Console_Line (To_String (Prompt_Text), State, Res, Success);
               if Success and then Tree (Root).Right_Child /= 0 then
                  Write_Target (Source, Tokens, Tree, Tree (Root).Right_Child, State, Res, Success);
               elsif Success and then Tree (Root).Left_Child /= 0 then
                  Write_Target (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               end if;
            end;
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
            end if;

         when AST_Parallel_Decl =>
            if Tree (Root).Left_Child = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            V_Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            V_Name := Declaration_Name (State, V_Name);
            Evaluate_Index_List (Source, Tokens, Tree, Tree (Tree (Root).Left_Child).Left_Child, State, Dims, Dim_Count, Success);
            if not Success or else Dim_Count = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            Parallel_Slot := Find_Parallel (State, V_Name);
            if Parallel_Slot = 0 then
               for I in 1 .. Max_Parallel_Groups loop
                  if not State.Parallels (I).Active then
                     Parallel_Slot := I;
                     exit;
                  end if;
               end loop;
            end if;
            if Parallel_Slot = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            declare
               Blank_Parallel : Parallel_Record;
            begin
               State.Parallels (Parallel_Slot) := Blank_Parallel;
            end;
            State.Parallels (Parallel_Slot).Active := True;
            State.Parallels (Parallel_Slot).Name := V_Name;
            State.Parallels (Parallel_Slot).Capacity := Dims (1);

            Curr := Tree (Root).Right_Child;
            while Curr /= 0 loop
               exit when State.Parallels (Parallel_Slot).Field_Count = Max_Parallel_Fields;
               if Tree (Curr).Left_Child = 0 then
                  Curr := Tree (Curr).Next_Sibling;
               else
                  State.Parallels (Parallel_Slot).Field_Count :=
                    State.Parallels (Parallel_Slot).Field_Count + 1;
                  Field_Slot := State.Parallels (Parallel_Slot).Field_Count;
                  Name_Node := Tree (Curr).Left_Child;
                  State.Parallels (Parallel_Slot).Fields (Field_Slot).Active := True;
                  State.Parallels (Parallel_Slot).Fields (Field_Slot).Field_Name :=
                    Extract_Name (Source, Tokens (Tree (Name_Node).Token_Index));
                  State.Parallels (Parallel_Slot).Fields (Field_Slot).Array_Name :=
                    Compose_Name (V_Name, State.Parallels (Parallel_Slot).Fields (Field_Slot).Field_Name);

                  if Tree (Name_Node).Right_Child /= 0 then
                     Expected :=
                       Resolve_Type_Tag
                         (State, Extract_Name (Source, Tokens (Tree (Tree (Name_Node).Right_Child).Token_Index)));
                  else
                     Expected := Type_U32;
                  end if;

                  if State.Array_Count = Max_Arrays
                    or else State.Next_Cell + Dims (1) - 1 > Max_Array_Cells
                  then
                     Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
                     return;
                  end if;

                  Arr_Slot := State.Array_Count + 1;
                  State.Array_Count := Arr_Slot;
                  State.Arrays (Arr_Slot).Active := True;
                  State.Arrays (Arr_Slot).Name := State.Parallels (Parallel_Slot).Fields (Field_Slot).Array_Name;
                  State.Arrays (Arr_Slot).Element_Tag := Expected;
                  State.Arrays (Arr_Slot).Sliding := False;
                  State.Arrays (Arr_Slot).Dim_Count := 1;
                  State.Arrays (Arr_Slot).Dims := (others => 0);
                  State.Arrays (Arr_Slot).Dims (1) := Dims (1);
                  State.Arrays (Arr_Slot).Length := Dims (1);
                  State.Arrays (Arr_Slot).Active_Length := Dims (1);
                  State.Arrays (Arr_Slot).Base := State.Next_Cell;
                  Bytes := Dims (1) * Type_Size_Bytes (Expected);
                  Claim_Strict_Block (Pool_Index (Bytes), Bounds, Success);
                  if not Success then
                     Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
                     return;
                  end if;
                  State.Arrays (Arr_Slot).Bounds := Bounds;
                  for I in State.Next_Cell .. State.Next_Cell + Dims (1) - 1 loop
                     Default_Value (Expected, State.Array_Cells (I), Success);
                     if not Success then
                        Set_Failure (Root, Err_Type_Conflict, Success);
                        return;
                     end if;
                  end loop;
                  State.Next_Cell := State.Next_Cell + Dims (1);
                  Curr := Tree (Curr).Next_Sibling;
               end if;
            end loop;
            Success := True;

         when AST_Strict_Stmt =>
            Name_Node := Tree (Root).Left_Child;
            if Name_Node = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            V_Name := Extract_Name (Source, Tokens (Tree (Name_Node).Token_Index));
            V_Name := Declaration_Name (State, V_Name);
            Evaluate_Index_List (Source, Tokens, Tree, Tree (Root).Right_Child, State, Dims, Dim_Count, Success);
            if not Success or else Dim_Count = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            Total := 1;
            for I in 1 .. Dim_Count loop
               Total := Total * Dims (I);
            end loop;

            if State.Array_Count = Max_Arrays
              or else State.Next_Cell + Total - 1 > Max_Array_Cells
            then
               Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
               return;
            end if;

            Arr_Slot := State.Array_Count + 1;
            State.Array_Count := Arr_Slot;
            State.Arrays (Arr_Slot).Active := True;
            State.Arrays (Arr_Slot).Name := V_Name;
            State.Arrays (Arr_Slot).Dim_Count := Dim_Count;
            State.Arrays (Arr_Slot).Dims := Dims;
            State.Arrays (Arr_Slot).Length := Total;
            State.Arrays (Arr_Slot).Active_Length := Total;
            State.Arrays (Arr_Slot).Base := State.Next_Cell;
            State.Arrays (Arr_Slot).Sliding := False;

            if Tree (Name_Node).Right_Child /= 0 then
               State.Arrays (Arr_Slot).Element_Tag :=
                 Resolve_Type_Tag
                   (State,
                    Extract_Name (Source, Tokens (Tree (Tree (Name_Node).Right_Child).Token_Index)));
            else
               State.Arrays (Arr_Slot).Element_Tag := Type_None;
            end if;

            Bytes := Total * Type_Size_Bytes (State.Arrays (Arr_Slot).Element_Tag);
            --  Pool_Index'Last is 8 GiB and does not fit in Natural. A
            --  Natural byte count always fits the index type; the claim
            --  still fail-closes if the live pool is smaller.
            if Bytes = 0 then
               Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
               return;
            end if;

            Claim_Strict_Block (Pool_Index (Bytes), Bounds, Success);
            if not Success then
               Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
               return;
            end if;
            State.Arrays (Arr_Slot).Bounds := Bounds;

            for I in State.Next_Cell .. State.Next_Cell + Total - 1 loop
               if State.Arrays (Arr_Slot).Element_Tag = Type_None then
                  State.Array_Cells (I) := (Tag => Type_None);
               else
                  Default_Value (State.Arrays (Arr_Slot).Element_Tag, State.Array_Cells (I), Success);
                  if not Success then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                     return;
                  end if;
               end if;
            end loop;
            State.Next_Cell := State.Next_Cell + Total;
            Success := True;

         when AST_Slide_Stmt =>
            Name_Node := Tree (Root).Left_Child;
            if Name_Node = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            V_Name := Extract_Name (Source, Tokens (Tree (Name_Node).Token_Index));
            V_Name := Declaration_Name (State, V_Name);
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Try_As_Integer (State, Res, Max_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            if Tree (Tree (Root).Right_Child).Next_Sibling = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            Evaluate_Expr
              (Source,
               Tokens,
               Tree,
               Tree (Tree (Root).Right_Child).Next_Sibling,
               State,
               Res,
               Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Try_As_Integer (State, Res, Active_Val, Success);
            if not Success or else Max_Val < 1 or else Active_Val < 0 or else Active_Val > Max_Val then
               Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
               return;
            end if;

            if State.Array_Count = Max_Arrays
              or else State.Next_Cell + Natural (Max_Val) - 1 > Max_Array_Cells
            then
               Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
               return;
            end if;

            Arr_Slot := State.Array_Count + 1;
            State.Array_Count := Arr_Slot;
            State.Arrays (Arr_Slot).Active := True;
            State.Arrays (Arr_Slot).Name := V_Name;
            State.Arrays (Arr_Slot).Dim_Count := 1;
            State.Arrays (Arr_Slot).Dims (1) := Natural (Max_Val);
            State.Arrays (Arr_Slot).Length := Natural (Max_Val);
            State.Arrays (Arr_Slot).Active_Length := Natural (Active_Val);
            State.Arrays (Arr_Slot).Base := State.Next_Cell;
            State.Arrays (Arr_Slot).Sliding := True;

            if Tree (Name_Node).Right_Child /= 0 then
               State.Arrays (Arr_Slot).Element_Tag :=
                 Resolve_Type_Tag
                   (State,
                    Extract_Name (Source, Tokens (Tree (Tree (Name_Node).Right_Child).Token_Index)));
            else
               State.Arrays (Arr_Slot).Element_Tag := Type_None;
            end if;

            Bytes := Natural (Max_Val) * Type_Size_Bytes (State.Arrays (Arr_Slot).Element_Tag);
            if Bytes = 0 then
               Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
               return;
            end if;

            Claim_Sliding_Block (Pool_Index (Bytes), Pool_Index (Active_Val * Long_Integer (Type_Size_Bytes (State.Arrays (Arr_Slot).Element_Tag))), Bounds, Success);
            if not Success then
               Set_Failure (Root, Err_Mem_Out_Of_Bounds, Success);
               return;
            end if;
            State.Arrays (Arr_Slot).Bounds := Bounds;

            for I in State.Next_Cell .. State.Next_Cell + Natural (Max_Val) - 1 loop
               if State.Arrays (Arr_Slot).Element_Tag = Type_None then
                  State.Array_Cells (I) := (Tag => Type_None);
               else
                  Default_Value (State.Arrays (Arr_Slot).Element_Tag, State.Array_Cells (I), Success);
                  if not Success then
                     Set_Failure (Root, Err_Type_Conflict, Success);
                     return;
                  end if;
               end if;
            end loop;
            State.Next_Cell := State.Next_Cell + Natural (Max_Val);
            Success := True;

         when AST_Procedure_Decl | AST_Function_Decl =>
            if State.Proc_Count = Max_Procs or else Tree (Root).Left_Child = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            declare
               Target_Node : Node_Index := Tree (Root).Left_Child;
            begin
               if Tree (Target_Node).Kind = AST_Func_Call then
                  Target_Node := Tree (Target_Node).Left_Child;
               end if;
               -- Change here: Use Resolve_Call_Name tae unwrap da member expression correctly!
               V_Name := Resolve_Call_Name (Source, Tokens, Tree, Target_Node);
            end;
            V_Name := Declaration_Name (State, V_Name);
            Proc_Slot := Find_Proc (State, V_Name);
            if Proc_Slot = 0 then
               for I in 1 .. Max_Procs loop
                  if not State.Procs (I).Active then
                     Proc_Slot := I;
                     exit;
                  end if;
               end loop;
            end if;
            if Proc_Slot = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            State.Procs (Proc_Slot).Active := True;
            State.Procs (Proc_Slot).Name := V_Name;
            if Tree (Tree (Root).Left_Child).Right_Child /= 0
              and then Tree (Tree (Root).Left_Child).Right_Child <= Max_Nodes
              and then Tree (Tree (Tree (Root).Left_Child).Right_Child).Kind = AST_Arg_List
            then
               State.Procs (Proc_Slot).Params_Node := Tree (Tree (Root).Left_Child).Right_Child;
            else
               State.Procs (Proc_Slot).Params_Node := 0;
            end if;
            State.Procs (Proc_Slot).Body_Node := Tree (Root).Right_Child;
            if Tree (Root).Kind = AST_Function_Decl and then Tree (Root).Token_Index /= 0 then
               State.Procs (Proc_Slot).Return_Tag :=
                 Resolve_Type_Tag (State, Extract_Name (Source, Tokens (Tree (Root).Token_Index)));
            else
               State.Procs (Proc_Slot).Return_Tag := Type_None;
            end if;
            if Proc_Slot > State.Proc_Count then
               State.Proc_Count := Proc_Slot;
            end if;
            Success := True;

         --  when AST_Call_Stmt =>
         --     if Tree (Root).Left_Child = 0 then
         --        Set_Failure (Root, Err_Proc_Not_Found, Success);
         --        return;
         --     end if;
         --
         --     if Tree (Tree (Root).Left_Child).Kind = AST_Func_Call then
         --        Call_Name :=
         --          Resolve_Call_Name (Source, Tokens, Tree, Tree (Tree (Root).Left_Child).Left_Child);
         --        if Tree (Tree (Root).Left_Child).Right_Child /= 0 then
         --           Next_Print := Tree (Tree (Tree (Root).Left_Child).Right_Child).Left_Child;
         --        else
         --           Next_Print := 0;
         --        end if;
         --     elsif Tree (Tree (Root).Left_Child).Kind = AST_Constructor then
         --        Call_Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
         --        Next_Print := Tree (Tree (Root).Left_Child).Left_Child;
         --     else
         --        Call_Name := Resolve_Call_Name (Source, Tokens, Tree, Tree (Root).Left_Child);
         --        Next_Print := 0;
         --     end if;
         --
         --     Invoke_Routine (Source, Tokens, Tree, Call_Name, Next_Print, State, Res, Success);
         --     if not Success then
         --        Set_Failure (Root, Err_Proc_Not_Found, Success);
         --     end if;
         when AST_Call_Stmt =>
            if Tree (Root).Left_Child = 0 then
               Set_Failure (Root, Err_Proc_Not_Found, Success);
               return;
            end if;

            if Tree (Tree (Root).Left_Child).Kind = AST_Func_Call then
               Call_Name :=
                 Resolve_Call_Name (Source, Tokens, Tree, Tree (Tree (Root).Left_Child).Left_Child);
               if Tree (Tree (Root).Left_Child).Right_Child /= 0 then
                  Next_Print := Tree (Tree (Tree (Root).Left_Child).Right_Child).Left_Child;
               else
                  Next_Print := 0;
               end if;
            elsif Tree (Tree (Root).Left_Child).Kind = AST_Constructor then
               Call_Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
               Next_Print := Tree (Tree (Root).Left_Child).Left_Child;
            else
               Call_Name := Resolve_Call_Name (Source, Tokens, Tree, Tree (Root).Left_Child);
               Next_Print := 0;
            end if;

            Invoke_Routine (Source, Tokens, Tree, Call_Name, Next_Print, State, Res, Success);
            if not Success then
               declare
                  Fail_Code : Oracle_Code;
                  Fail_Node : Node_Index;
               begin
                  Get_Last_Failure (Fail_Code, Fail_Node);
                  -- Only set Err_Proc_Not_Found if nae ither error wis generated inside da routine!
                  if Fail_Code = Err_None then
                     Set_Failure (Root, Err_Proc_Not_Found, Success);
                  end if;
               end;
            end if;

         when AST_Query =>
            Solve_Query (Source, Tokens, Tree, Tree (Root).Left_Child, State, Success);

         when AST_Fact | AST_Horn_Clause | AST_Rule_Decl | AST_Constraint_Decl =>
            if State.Clause_Count = Max_Clauses or else Tree (Root).Left_Child = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            State.Clause_Count := State.Clause_Count + 1;
            Curr := Tree (Root).Left_Child;
            State.Clauses (State.Clause_Count).Active := True;
            State.Clauses (State.Clause_Count).Head_Name :=
              Extract_Name (Source, Tokens (Tree (Curr).Token_Index));
            Next_Print := Tree (Curr).Left_Child;
            while Next_Print /= 0 loop
               exit when State.Clauses (State.Clause_Count).Arg_Count = Max_Logic_Args;
               State.Clauses (State.Clause_Count).Arg_Count :=
                 State.Clauses (State.Clause_Count).Arg_Count + 1;
               State.Clauses (State.Clause_Count).Args (State.Clauses (State.Clause_Count).Arg_Count).Is_Var :=
                 Tree (Next_Print).Kind = AST_Logic_Var;
               State.Clauses (State.Clause_Count).Args (State.Clauses (State.Clause_Count).Arg_Count).Name :=
                 Extract_Name (Source, Tokens (Tree (Next_Print).Token_Index));
               Next_Print := Tree (Next_Print).Next_Sibling;
            end loop;
            Success := True;

         when AST_Assert_Stmt =>
            if State.Clause_Count = Max_Clauses then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            State.Clause_Count := State.Clause_Count + 1;
            State.Clauses (State.Clause_Count).Active := True;
            State.Clauses (State.Clause_Count).Head_Name :=
              Extract_Name (Source, Tokens (Tree (Root).Token_Index));
            if Tree (Root).Left_Child /= 0 then
               State.Clauses (State.Clause_Count).Arg_Count := 1;
               State.Clauses (State.Clause_Count).Args (1).Name :=
                 Make_Name (Token_Lexeme (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index)));
            end if;
            Success := True;

         when AST_Retract_Stmt =>
            Call_Name := Extract_Name (Source, Tokens (Tree (Root).Token_Index));
            for I in reverse 1 .. State.Clause_Count loop
               if State.Clauses (I).Active and then State.Clauses (I).Head_Name = Call_Name then
                  State.Clauses (I).Active := False;
                  exit;
               end if;
            end loop;
            Success := True;

         when AST_Update_Stmt =>
            Success := True;

         when AST_Findall_Query =>
            if Tree (Root).Right_Child /= 0 and then Tree (Tree (Root).Right_Child).Kind = AST_Var_Expr then
               V_Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Right_Child).Token_Index));
               Arr_Slot := Find_Array (State, V_Name);
               if Arr_Slot /= 0 then
                  for I in 1 .. State.Arrays (Arr_Slot).Active_Length loop
                     State.Array_Cells (State.Arrays (Arr_Slot).Base + I - 1) := (Tag => Type_U32, Val_U32 => 0);
                  end loop;
               end if;
            end if;
            Success := True;

         when AST_On_Block =>
            case Tokens (Tree (Root).Token_Index).Kind is
               when Tok_Tick =>
                  State.On_Tick_Node := Tree (Root).Left_Child;
               when Tok_Paint =>
                  State.On_Paint_Node := Tree (Root).Left_Child;
               when Tok_Key =>
                  State.On_Key_Node := Tree (Root).Left_Child;
               when others =>
                  null;
            end case;
            Success := True;

         when AST_Knows_Change =>
            Success := True;

         when AST_Import =>
            Success := True;

         when AST_Import_C =>
            if Tree (Root).Left_Child /= 0 then
               Execute (Source, Tokens, Tree, Tree (Root).Left_Child, State, Success, 1.0);
            else
               Success := True;
            end if;

         when AST_Knows_Fact | AST_Knows_Query | AST_Predicate_Decl =>
            Success := True;

         when AST_SwapPop_Stmt =>
            if Tree (Root).Left_Child = 0 or else Tree (Tree (Root).Left_Child).Kind /= AST_Var_Expr then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            V_Name := Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            V_Name := Resolve_Scoped_Parallel_Name (State, V_Name);
            Parallel_Slot := Find_Parallel (State, V_Name);
            if Parallel_Slot = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Evaluate_Index_List
              (Source,
               Tokens,
               Tree,
               Tree (Tree (Root).Left_Child).Left_Child,
               State,
               Dims,
               Dim_Count,
               Success);
            if not Success or else Dim_Count = 0 then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;
            Try_As_Integer (State, Res, Active_Val, Success);
            if not Success
              or else Active_Val < 1
              or else Active_Val > Long_Integer (State.Parallels (Parallel_Slot).Capacity)
              or else Long_Integer (Dims (1)) > Active_Val
            then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            if Long_Integer (Dims (1)) < Active_Val then
               for I in 1 .. State.Parallels (Parallel_Slot).Field_Count loop
                  if State.Parallels (Parallel_Slot).Fields (I).Active then
                     Arr_Slot := Find_Array (State, State.Parallels (Parallel_Slot).Fields (I).Array_Name);
                     if Arr_Slot /= 0 then
                        if Dims (1) = 0
                          or else Dims (1) > State.Arrays (Arr_Slot).Active_Length
                          or else Natural (Active_Val) > State.Arrays (Arr_Slot).Active_Length
                          or else State.Arrays (Arr_Slot).Base + Dims (1) - 1 > Max_Array_Cells
                          or else State.Arrays (Arr_Slot).Base + Natural (Active_Val) - 1 > Max_Array_Cells
                        then
                           Set_Failure (Root, Err_Type_Conflict, Success);
                           return;
                        end if;
                        State.Array_Cells (State.Arrays (Arr_Slot).Base + Dims (1) - 1) :=
                          State.Array_Cells (State.Arrays (Arr_Slot).Base + Natural (Active_Val) - 1);
                     end if;
                  end if;
               end loop;
            end if;

            if Tree (Root).Right_Child /= 0 and then Tree (Tree (Root).Right_Child).Kind in AST_Var_Expr | AST_Member_Expr then
               Write_Target
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Root).Right_Child,
                  State,
                  (Tag => Type_U16, Val_U16 => U16 (Active_Val - 1)),
                  Success);
            else
               Success := True;
            end if;
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
            end if;

         when AST_Listen =>
            State.Stop_Listen := False;
            if not ALB_Graphics.Window_Open then
               if State.On_Tick_Node /= 0 then
                  Execute (Source, Tokens, Tree, State.On_Tick_Node, State, Success, 1.0);
                  if not Success then
                     return;
                  end if;
               end if;
               if not State.Stop_Listen and then State.On_Paint_Node /= 0 then
                  Execute (Source, Tokens, Tree, State.On_Paint_Node, State, Success, 1.0);
               end if;
            else
               declare
                  Frame_Length_Ms : constant Natural :=
                    (if State.Tick_Length_Ms > 0 then State.Tick_Length_Ms else 16);
                  Next_Frame_At : Natural := ALB_Graphics.Monotonic_Millis;
               begin
                  while not State.Stop_Listen and then ALB_Graphics.Window_Open loop
                     ALB_Graphics.Process_Events;
                     exit when State.Stop_Listen or else not ALB_Graphics.Window_Open;

                     if State.On_Key_Node /= 0 and then ALB_Graphics.Pending_Key_Event then
                        Execute (Source, Tokens, Tree, State.On_Key_Node, State, Success, 1.0);
                        if not Success then
                           return;
                        end if;
                     end if;

                     declare
                        Now_Ms : constant Natural := ALB_Graphics.Monotonic_Millis;
                     begin
                        if Now_Ms < Next_Frame_At then
                           ALB_Graphics.Pause_For
                             (Natural'Min (Frame_Length_Ms, Next_Frame_At - Now_Ms));
                        else
                           if State.On_Tick_Node /= 0 then
                              Execute (Source, Tokens, Tree, State.On_Tick_Node, State, Success, 1.0);
                              if not Success then
                                 return;
                              end if;
                           end if;

                           exit when State.Stop_Listen or else not ALB_Graphics.Window_Open;

                           if State.On_Paint_Node /= 0 then
                              Execute (Source, Tokens, Tree, State.On_Paint_Node, State, Success, 1.0);
                              if not Success then
                                 return;
                              end if;
                           end if;

                           ALB_Graphics.Present;

                           if Now_Ms > Next_Frame_At + Frame_Length_Ms then
                              Next_Frame_At := Now_Ms + Frame_Length_Ms;
                           else
                              Next_Frame_At := Next_Frame_At + Frame_Length_Ms;
                           end if;
                        end if;
                     end;
                  end loop;
               end;
               ALB_Graphics.Shutdown;
            end if;
            Success := True;

         when AST_Cease =>
            State.Stop_Listen := True;
            ALB_Graphics.Request_Close;
            Success := True;

         when AST_Create_Window =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
            else
               Make_Binary_Value (State, "AdaLogic BASIC", Res, Success);
               if not Success then
                  return;
               end if;
            end if;
            Tmp := Res;

            if Tree (Root).Right_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Tree (Root).Right_Child).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Try_As_Integer (State, Res, Max_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               State.Window_Width := Natural (Long_Integer'Max (1, Max_Val));

               Evaluate_Expr (Source, Tokens, Tree, Tree (Tree (Root).Right_Child).Right_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Try_As_Integer (State, Res, Max_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               State.Window_Height := Natural (Long_Integer'Max (1, Max_Val));
            end if;

            declare
               Title_Text : constant String := Value_To_String (State, Tmp);
               Window_Ok  : Boolean := False;
            begin
               ALB_Graphics.Initialize
                 ((if Title_Text'Length = 0 then "AdaLogic BASIC" else Title_Text),
                  State.Window_Width,
                  State.Window_Height,
                  Window_Ok);
               Success := Window_Ok;
            end;

         when AST_Tick =>
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
            if Success then
               Try_As_Integer (State, Res, Max_Val, Success);
            end if;
            if Success and then Max_Val >= 0 then
               State.Tick_Length_Ms := Natural (Max_Val);
            else
               Set_Failure (Root, Err_Type_Conflict, Success);
            end if;

         when AST_Delay_Stmt =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Try_As_Integer (State, Res, Max_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               if Max_Val < 0 then
                  Max_Val := 0;
               end if;
               ALB_Graphics.Pause_For (Natural (Max_Val));
            end if;
            Success := True;

         when AST_Color =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Try_As_Integer (State, Res, Max_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               if Max_Val < 0 then
                  Max_Val := 0;
               end if;
               ALB_Graphics.Set_Color (Natural (Max_Val));
            end if;
            Success := True;

         when AST_Clear =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Try_As_Integer (State, Res, Max_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               if Max_Val < 0 then
                  Max_Val := 0;
               end if;
               ALB_Graphics.Clear (Natural (Max_Val));
            end if;
            Success := True;

         when AST_Draw | AST_FILL | AST_Plot =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Graphics_Argument_Integers
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Root).Left_Child).Left_Child,
                  State,
                  Arg_Ints,
                  Arg_Count,
                  Success);
            else
               Arg_Ints := (others => 0);
               Arg_Count := 0;
               Success := True;
            end if;
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            if Tree (Root).Kind = AST_Plot then
               if Arg_Count >= 2 then
                  ALB_Graphics.Plot (Integer (Arg_Ints (1)), Integer (Arg_Ints (2)));
               end if;
            elsif Tree (Root).Kind = AST_Draw then
               if Tree (Root).Token_Index /= 0 then
                  case Tokens (Tree (Root).Token_Index).Kind is
                     when Tok_Rect =>
                        if Arg_Count >= 4 then
                           ALB_Graphics.Draw_Rect
                             (Integer (Arg_Ints (1)),
                              Integer (Arg_Ints (2)),
                              Integer (Arg_Ints (3)),
                              Integer (Arg_Ints (4)));
                        end if;
                     when Tok_Line =>
                        if Arg_Count >= 4 then
                           ALB_Graphics.Draw_Line
                             (Integer (Arg_Ints (1)),
                              Integer (Arg_Ints (2)),
                              Integer (Arg_Ints (3)),
                              Integer (Arg_Ints (4)));
                        end if;
                     when Tok_Circle =>
                        if Arg_Count >= 3 then
                           ALB_Graphics.Draw_Circle
                             (Integer (Arg_Ints (1)),
                              Integer (Arg_Ints (2)),
                              Integer (Arg_Ints (3)));
                        end if;
                     when Tok_Triangle =>
                        if Arg_Count >= 6 then
                           ALB_Graphics.Draw_Triangle
                             (Integer (Arg_Ints (1)),
                              Integer (Arg_Ints (2)),
                              Integer (Arg_Ints (3)),
                              Integer (Arg_Ints (4)),
                              Integer (Arg_Ints (5)),
                              Integer (Arg_Ints (6)));
                        end if;
                     when others =>
                        null;
                  end case;
               end if;
            else
               if Tree (Root).Token_Index /= 0 then
                  case Tokens (Tree (Root).Token_Index).Kind is
                     when Tok_Rect =>
                        if Arg_Count >= 4 then
                           ALB_Graphics.Fill_Rect
                             (Integer (Arg_Ints (1)),
                              Integer (Arg_Ints (2)),
                              Integer (Arg_Ints (3)),
                              Integer (Arg_Ints (4)));
                        end if;
                     when Tok_Circle =>
                        if Arg_Count >= 3 then
                           ALB_Graphics.Fill_Circle
                             (Integer (Arg_Ints (1)),
                              Integer (Arg_Ints (2)),
                              Integer (Arg_Ints (3)));
                        end if;
                     when Tok_Triangle =>
                        if Arg_Count >= 6 then
                           ALB_Graphics.Fill_Triangle
                             (Integer (Arg_Ints (1)),
                              Integer (Arg_Ints (2)),
                              Integer (Arg_Ints (3)),
                              Integer (Arg_Ints (4)),
                              Integer (Arg_Ints (5)),
                              Integer (Arg_Ints (6)));
                        end if;
                     when others =>
                        null;
                  end case;
               end if;
            end if;
            Success := True;

         when AST_Text =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Arguments
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Root).Left_Child).Left_Child,
                  State,
                  Arg_Values,
                  Arg_Count,
                  Success);
            else
               Arg_Values := (others => (Tag => Type_None));
               Arg_Count := 0;
               Success := True;
            end if;
            if not Success then
               Set_Failure (Root, Err_Type_Conflict, Success);
               return;
            end if;

            if Arg_Count >= 3 then
               Evaluate_Graphics_Integer_Expr
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Root).Left_Child).Left_Child,
                  State,
                  Arg_Ints (1),
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Evaluate_Graphics_Integer_Expr
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Tree (Root).Left_Child).Left_Child).Next_Sibling,
                  State,
                  Arg_Ints (2),
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               ALB_Graphics.Draw_Text
                 (Integer (Arg_Ints (1)),
                  Integer (Arg_Ints (2)),
                  Value_To_String (State, Arg_Values (3)));
            end if;
            Success := True;

         when AST_SET_ALPHA =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Argument_Integers
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Root).Left_Child).Left_Child,
                  State,
                  Arg_Ints,
                  Arg_Count,
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               if Arg_Count >= 2 then
                  ALB_Graphics.Set_Alpha (Integer (Arg_Ints (1)), Integer (Arg_Ints (2)));
               end if;
            end if;
            Success := True;

         when AST_SET_CLIP =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Graphics_Argument_Integers
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Root).Left_Child).Left_Child,
                  State,
                  Arg_Ints,
                  Arg_Count,
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               if Arg_Count >= 4 then
                  ALB_Graphics.Set_Clip
                    (Integer (Arg_Ints (1)),
                     Integer (Arg_Ints (2)),
                     Integer (Arg_Ints (3)),
                     Integer (Arg_Ints (4)));
               end if;
            end if;
            Success := True;

         when AST_SET_ORIGIN =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Graphics_Argument_Integers
                 (Source,
                  Tokens,
                  Tree,
                  Tree (Tree (Root).Left_Child).Left_Child,
                  State,
                  Arg_Ints,
                  Arg_Count,
                  Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               if Arg_Count >= 2 then
                  ALB_Graphics.Set_Origin (Integer (Arg_Ints (1)), Integer (Arg_Ints (2)));
               end if;
            end if;
            Success := True;

         when AST_Set_Fullscreen | AST_Set_Resizable | AST_Set_Stretchy =>
            Success := True;

         when AST_Play_Music =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               ALB_Audio.Play_Music (Value_To_String (State, Res));
            end if;
            Success := True;

         when AST_Play_Music_From =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               ALB_Audio.Play_Music_From (Value_To_String (State, Res));
            end if;
            Success := True;

         when AST_File_Write =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Runtime_Write_File (State, L_Val, R_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
            end if;

         when AST_File_Close =>
            if Tree (Root).Left_Child = 0 then
               Set_Failure (Root, Err_Runtime_Invalid_Handle, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_Invalid_Handle, Success);
               return;
            end if;
            Runtime_Close_File (State, L_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_Invalid_Handle, Success);
            end if;

         when AST_Load_Stmt =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Runtime_Load_File (State, Value_To_String (State, Res), Max_Binary_Length, L_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Write_Target (Source, Tokens, Tree, Tree (Root).Right_Child, State, L_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
            end if;

         when AST_Flush_Stmt =>
            if Tree (Root).Left_Child = 0 or else Tree (Root).Right_Child = 0 then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
               return;
            end if;
            Runtime_Flush_File (Value_To_String (State, L_Val), Value_To_String (State, R_Val), Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_IO_Failure, Success);
            end if;

         when AST_Save_State =>
            Save_Temporal_State (State, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_Unsupported, Success);
            end if;

         when AST_Load_State =>
            Load_Temporal_State (State, Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_Unsupported, Success);
            end if;

         when AST_Advance_Stmt =>
            Max_Val := 1;
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, Res, Success);
               if not Success then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
               Try_As_Integer (State, Res, Max_Val, Success);
               if not Success or else Max_Val < 0 then
                  Set_Failure (Root, Err_Type_Conflict, Success);
                  return;
               end if;
            end if;
            Advance_Temporal_State
              (State,
               (if Max_Val > Long_Integer (Max_Temporal_History)
                then Max_Temporal_History
                else Natural (Max_Val)),
               Success);
            if not Success then
               Set_Failure (Root, Err_Runtime_Unsupported, Success);
            end if;

         when AST_Locate_Stmt | AST_Play_Sound |
              AST_SYS_RENDERER |
              AST_Poke_Stmt | AST_Claim_Stmt | AST_Bind_Stmt | AST_Drop_Stmt |
              AST_Sweep_Stmt | AST_Spawn_Stmt | AST_Sync_Stmt | AST_Rev_Add_Stmt |
              AST_Rev_Sub_Stmt | AST_Rev_Xor_Stmt | AST_Rev_Rol_Stmt |
              AST_Rev_Ror_Stmt | AST_Rev_Swap_Stmt | AST_Rev_Not_Stmt |
              AST_Rev_Neg_Stmt | AST_Throw_Stmt =>
            Success := True;

         when AST_Try_Stmt =>
            if Tree (Root).Left_Child /= 0 then
               Execute (Source, Tokens, Tree, Tree (Root).Left_Child, State, Success, 1.0);
            else
               Success := True;
            end if;

         when AST_Msg_Box =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, L_Val, Success);
               if not Success then
                  Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                  return;
               end if;
               if Tree (Root).Right_Child /= 0 then
                  Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Right_Child, State, R_Val, Success);
                  if not Success then
                     Set_Failure (Root, Err_Runtime_IO_Failure, Success);
                     return;
                  end if;
                  Put_Line ("ALB-MSG> [" & Value_To_String (State, R_Val) & "] " & Value_To_String (State, L_Val));
               else
                  Put_Line ("ALB-MSG> " & Value_To_String (State, L_Val));
               end if;
            end if;
            Success := True;

         --  when AST_Module | AST_DeclareModule =>
         --     declare
         --        Prev_Module : constant Var_Name := State.Current_Module;
         --     begin
         --        if Tree (Root).Left_Child /= 0
         --          and then Tree (Tree (Root).Left_Child).Kind = AST_Var_Expr
         --        then
         --           State.Current_Module :=
         --             Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
         --        end if;
         --
         --        if Tree (Root).Right_Child /= 0 then
         --           Execute (Source, Tokens, Tree, Tree (Root).Right_Child, State, Success, 1.0);
         --        else
         --           Success := True;
         --        end if;

         when AST_Module | AST_DeclareModule =>
            if Tree (Root).Left_Child /= 0
              and then Tree (Tree (Root).Left_Child).Kind = AST_Var_Expr
            then
               State.Current_Module :=
                 Extract_Name (Source, Tokens (Tree (Tree (Root).Left_Child).Token_Index));
            else
               -- An END MODULE directive (no name provided) clears the persistent scope
               State.Current_Module := (others => ' ');
            end if;

            if Tree (Root).Right_Child /= 0 then
               declare
                  Prev_Module : constant Var_Name := State.Current_Module;
               begin
                  Execute (Source, Tokens, Tree, Tree (Root).Right_Child, State, Success, 1.0);
                  State.Current_Module := Prev_Module;
               end;
            else
               Success := True;
               -- Intentionally DO NOT restore Prev_Module if there is no Right_Child body.
               -- This allows the module scope to persist for flat sibling declarations!
            end if;

         when AST_Comptime_Block | AST_Temporal_Block | AST_Reversible_Block | AST_Atomic_Block =>
            if Tree (Root).Left_Child /= 0 then
               Execute (Source, Tokens, Tree, Tree (Root).Left_Child, State, Success, 1.0);
            else
               Success := True;
            end if;

         when AST_Return_Stmt =>
            if Tree (Root).Left_Child /= 0 then
               Evaluate_Expr (Source, Tokens, Tree, Tree (Root).Left_Child, State, State.Return_Value, Success);
            else
               State.Return_Value := (Tag => Type_None);
               Success := True;
            end if;
            if Success then
               State.Return_Pending := True;
            end if;

         when AST_Break_Stmt =>
            State.Break_Pending := True;
            Success := True;

         when AST_Continue_Stmt =>
            State.Continue_Pending := True;
            Success := True;

         when others =>
            Set_Failure (Root, Err_Compiler_AST_Mismatch, Success);
      end case;
   exception
      when others =>
         Set_Failure (Root, Err_Runtime_Unsupported, Success);
   end Execute;

end Interpreter;
