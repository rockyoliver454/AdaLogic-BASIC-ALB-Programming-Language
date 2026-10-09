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

pragma Ada_2012;
pragma SPARK_Mode (On);

with Ada.Text_IO;

package body Septerra is

   type Parser_State is record
      Row_Index : Natural range 1 .. Max_Rows + 1 := 1;
      Col_Index : Natural range 1 .. Max_Columns + 1 := 1;
      In_Quotes : Boolean := False;
      Seen_Any  : Boolean := False;
   end record;

   procedure Clear_Field (Field : out Field_Record) is
   begin
      Field.Text := (others => ' ');
      Field.Length := 0;
   end Clear_Field;

   procedure Clear_Row (Row : out Row_Record) is
   begin
      Row.Num_Columns := 0;
      for I in Row.Fields'Range loop
         Clear_Field (Row.Fields (I));
      end loop;
   end Clear_Row;

   procedure Clear (Table : out Table_Data) is
   begin
      Table.Num_Rows := 0;
      for I in Table.Rows'Range loop
         Clear_Row (Table.Rows (I));
      end loop;
   end Clear;

   function Delimiter_Char (Kind : Delimiter_Kind) return Character is
   begin
      case Kind is
         when CSV =>
            return ',';
         when PSV =>
            return '|';
         when TSV =>
            return ASCII.HT;
      end case;
   end Delimiter_Char;

   function Field_Length
     (Table : Table_Data;
      State : Parser_State) return Natural is
   begin
      if State.Row_Index in Table.Rows'Range
        and then State.Col_Index in Table.Rows (State.Row_Index).Fields'Range
      then
         return Table.Rows (State.Row_Index).Fields (State.Col_Index).Length;
      else
         return 0;
      end if;
   end Field_Length;

   procedure Append_Char
     (Table  : in out Table_Data;
      State  : Parser_State;
      Char   : Character;
      Result : in out Table_Result) is
   begin
      if Result /= Success then
         return;
      end if;

      if State.Row_Index not in Table.Rows'Range
        or else State.Col_Index not in Table.Rows (State.Row_Index).Fields'Range
      then
         Result := Buffer_Overflow;
         return;
      end if;

      declare
         Field : Field_Record renames
           Table.Rows (State.Row_Index).Fields (State.Col_Index);
      begin
         if Field.Length >= Max_Field_Len then
            Result := Buffer_Overflow;
         else
            Field.Length := Field.Length + 1;
            Field.Text (Field.Length) := Char;
         end if;
      end;
   end Append_Char;

   procedure Finalize_Field
     (Table  : in out Table_Data;
      State  : in out Parser_State;
      Result : in out Table_Result) is
   begin
      if Result /= Success then
         return;
      end if;

      if State.Row_Index not in Table.Rows'Range
        or else State.Col_Index not in Table.Rows (State.Row_Index).Fields'Range
      then
         Result := Buffer_Overflow;
         return;
      end if;

      if Table.Rows (State.Row_Index).Num_Columns < State.Col_Index then
         Table.Rows (State.Row_Index).Num_Columns := State.Col_Index;
      end if;
      State.Seen_Any := True;
   end Finalize_Field;

   procedure Finish_Row
     (Table  : in out Table_Data;
      State  : in out Parser_State;
      Result : in out Table_Result) is
   begin
      if Result /= Success then
         return;
      end if;

      if State.Row_Index in Table.Rows'Range
        and then Table.Rows (State.Row_Index).Num_Columns > 0
      then
         Table.Num_Rows := State.Row_Index;

         if State.Row_Index < Max_Rows then
            State.Row_Index := State.Row_Index + 1;
            State.Col_Index := 1;
            State.Seen_Any := False;
            Clear_Row (Table.Rows (State.Row_Index));
         else
            State.Row_Index := Max_Rows + 1;
            State.Col_Index := 1;
            State.Seen_Any := False;
         end if;
      else
         State.Col_Index := 1;
         State.Seen_Any := False;
      end if;
   end Finish_Row;

   procedure Finish_Field_And_Row
     (Table  : in out Table_Data;
      State  : in out Parser_State;
      Result : in out Table_Result) is
   begin
      if Result /= Success then
         return;
      end if;

      if State.Seen_Any
        or else State.Col_Index > 1
        or else Field_Length (Table, State) > 0
      then
         Finalize_Field (Table, State, Result);
         Finish_Row (Table, State, Result);
      end if;
   end Finish_Field_And_Row;

   procedure Parse_Chunk
     (Input         : String;
      Kind          : Delimiter_Kind;
      Table         : in out Table_Data;
      State         : in out Parser_State;
      Result        : in out Table_Result;
      End_Of_Stream : Boolean := False) is
      Sep : constant Character := Delimiter_Char (Kind);
      I   : Natural := Input'First;
   begin
      while I <= Input'Last loop
         exit when Result /= Success;

         declare
            C : constant Character := Input (I);
         begin
            if State.In_Quotes then
               if C = '"' then
                  if I < Input'Last and then Input (I + 1) = '"' then
                     Append_Char (Table, State, '"', Result);
                     I := I + 1;
                  else
                     State.In_Quotes := False;
                  end if;
               else
                  Append_Char (Table, State, C, Result);
               end if;
            else
               if C = '"' and then Field_Length (Table, State) = 0 then
                  State.In_Quotes := True;
               elsif C = Sep then
                  Finalize_Field (Table, State, Result);
                  if Result = Success then
                     if State.Col_Index < Max_Columns then
                        State.Col_Index := State.Col_Index + 1;
                     else
                        Result := Buffer_Overflow;
                     end if;
                  end if;
               elsif C = ASCII.LF then
                  Finish_Field_And_Row (Table, State, Result);
               elsif C = ASCII.CR then
                  null;
               else
                  Append_Char (Table, State, C, Result);
               end if;
            end if;
         end;

         I := I + 1;
      end loop;

      if Result = Success and then End_Of_Stream then
         if State.In_Quotes then
            Result := Parse_Error;
         else
            Finish_Field_And_Row (Table, State, Result);
         end if;
      end if;
   end Parse_Chunk;

   procedure Load_String
     (Input  : String;
      Kind   : Delimiter_Kind;
      Table  : out Table_Data;
      Result : out Table_Result) is
      State : Parser_State;
   begin
      Clear (Table);
      Result := Success;
      State := (others => <>);

      if Input'Length = 0 then
         return;
      end if;

      Parse_Chunk (Input, Kind, Table, State, Result, End_Of_Stream => True);
   end Load_String;

   procedure Load_File
     (Filename : String;
      Kind     : Delimiter_Kind;
      Table    : out Table_Data;
      Result   : out Table_Result)
   with SPARK_Mode => Off
   is
      File_Handle : Ada.Text_IO.File_Type;
      Line        : String (1 .. Max_Line_Len + 1);
      Last        : Natural := 0;
      State       : Parser_State;
   begin
      Clear (Table);
      Result := Success;
      State := (others => <>);

      begin
         Ada.Text_IO.Open (File_Handle, Ada.Text_IO.In_File, Filename);
      exception
         when others =>
            Result := File_Not_Found;
            return;
      end;

      while not Ada.Text_IO.End_Of_File (File_Handle) loop
         Ada.Text_IO.Get_Line (File_Handle, Line, Last);
         if Last > Max_Line_Len then
            Result := Buffer_Overflow;
            exit;
         end if;

         if Last > 0 then
            Parse_Chunk
              (Line (1 .. Last), Kind, Table, State, Result, End_Of_Stream => False);
         end if;

         if Result = Success then
            Parse_Chunk
              (String'(1 => ASCII.LF),
               Kind,
               Table,
               State,
               Result,
               End_Of_Stream => False);
         end if;
      end loop;

      if Result = Success then
         Parse_Chunk ("", Kind, Table, State, Result, End_Of_Stream => True);
      end if;

      Ada.Text_IO.Close (File_Handle);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File_Handle) then
            Ada.Text_IO.Close (File_Handle);
         end if;
         Result := Parse_Error;
   end Load_File;

   function Needs_Quoting
     (Value : String;
      Kind  : Delimiter_Kind) return Boolean is
      Sep : constant Character := Delimiter_Char (Kind);
   begin
      for C of Value loop
         if C = Sep or else C = '"' or else C = ASCII.LF or else C = ASCII.CR then
            return True;
         end if;
      end loop;
      return False;
   end Needs_Quoting;

   procedure Save_File
     (Filename : String;
      Kind     : Delimiter_Kind;
      Table    : Table_Data;
      Result   : out Table_Result)
   with SPARK_Mode => Off
   is
      File_Handle : Ada.Text_IO.File_Type;
   begin
      Result := Success;
      Ada.Text_IO.Create (File_Handle, Ada.Text_IO.Out_File, Filename);

      if Table.Num_Rows > 0 then
         for Row in 1 .. Table.Num_Rows loop
            if Table.Rows (Row).Num_Columns > 0 then
               for Col in 1 .. Table.Rows (Row).Num_Columns loop
                  declare
                     Value : constant String :=
                       Table.Rows (Row).Fields (Col).Text
                         (1 .. Table.Rows (Row).Fields (Col).Length);
                  begin
                     if Col > 1 then
                        Ada.Text_IO.Put (File_Handle, Delimiter_Char (Kind));
                     end if;

                     if Needs_Quoting (Value, Kind) then
                        Ada.Text_IO.Put (File_Handle, '"');
                        for C of Value loop
                           if C = '"' then
                              Ada.Text_IO.Put (File_Handle, """""");
                           else
                              Ada.Text_IO.Put (File_Handle, C);
                           end if;
                        end loop;
                        Ada.Text_IO.Put (File_Handle, '"');
                     else
                        Ada.Text_IO.Put (File_Handle, Value);
                     end if;
                  end;
               end loop;
            end if;
            Ada.Text_IO.New_Line (File_Handle);
         end loop;
      end if;

      Ada.Text_IO.Close (File_Handle);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File_Handle) then
            Ada.Text_IO.Close (File_Handle);
         end if;
         Result := Parse_Error;
   end Save_File;

   function Row_Count (Table : Table_Data) return Natural is
   begin
      return Table.Num_Rows;
   end Row_Count;

   function Column_Count (Table : Table_Data; Row : Positive) return Natural is
   begin
      if Row in Table.Rows'Range and then Row <= Table.Num_Rows then
         return Table.Rows (Row).Num_Columns;
      else
         return 0;
      end if;
   end Column_Count;

   function Get_Field
     (Table   : Table_Data;
      Row     : Positive;
      Column  : Positive;
      Default : String := "") return String is
   begin
      if Row in Table.Rows'Range
        and then Column in Table.Rows (Row).Fields'Range
        and then Row <= Table.Num_Rows
        and then Column <= Table.Rows (Row).Num_Columns
      then
         return Table.Rows (Row).Fields (Column).Text
           (1 .. Table.Rows (Row).Fields (Column).Length);
      else
         return Default;
      end if;
   end Get_Field;

   procedure Set_Field
     (Table   : in out Table_Data;
      Row     : Positive;
      Column  : Positive;
      Value   : String;
      Result  : out Table_Result) is
   begin
      Result := Success;

      if Row not in Table.Rows'Range
        or else Column not in Table.Rows (Row).Fields'Range
        or else Value'Length > Max_Field_Len
      then
         Result := Buffer_Overflow;
         return;
      end if;

      if Row > Table.Num_Rows then
         for I in Table.Num_Rows + 1 .. Row loop
            Clear_Row (Table.Rows (I));
         end loop;
         Table.Num_Rows := Row;
      end if;

      Clear_Field (Table.Rows (Row).Fields (Column));
      if Value'Length > 0 then
         Table.Rows (Row).Fields (Column).Text (1 .. Value'Length) := Value;
         Table.Rows (Row).Fields (Column).Length := Value'Length;
      end if;

      if Column > Table.Rows (Row).Num_Columns then
         Table.Rows (Row).Num_Columns := Column;
      end if;
   end Set_Field;

end Septerra;
