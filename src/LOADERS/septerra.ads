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

generic
   Max_Rows      : Positive;
   Max_Columns   : Positive;
   Max_Field_Len : Positive;
   Max_Line_Len  : Positive;

package Septerra is

   type Delimiter_Kind is (CSV, PSV, TSV);
   type Table_Result is (Success, File_Not_Found, Buffer_Overflow, Parse_Error);

   subtype Safe_String is String (1 .. Max_Field_Len);

   type Table_Data is private;

   procedure Clear (Table : out Table_Data);

   procedure Load_String
     (Input  : String;
      Kind   : Delimiter_Kind;
      Table  : out Table_Data;
      Result : out Table_Result);

   procedure Load_File
     (Filename : String;
      Kind     : Delimiter_Kind;
      Table    : out Table_Data;
      Result   : out Table_Result)
   with SPARK_Mode => Off;

   procedure Save_File
     (Filename : String;
      Kind     : Delimiter_Kind;
      Table    : Table_Data;
      Result   : out Table_Result)
   with SPARK_Mode => Off;

   function Row_Count (Table : Table_Data) return Natural;
   function Column_Count (Table : Table_Data; Row : Positive) return Natural;

   function Get_Field
     (Table   : Table_Data;
      Row     : Positive;
      Column  : Positive;
      Default : String := "") return String;

   procedure Set_Field
     (Table   : in out Table_Data;
      Row     : Positive;
      Column  : Positive;
      Value   : String;
      Result  : out Table_Result);

   function Delimiter_Char (Kind : Delimiter_Kind) return Character;

private

   type Field_Record is record
      Text   : Safe_String := (others => ' ');
      Length : Natural range 0 .. Max_Field_Len := 0;
   end record;

   type Field_Array is array (Positive range 1 .. Max_Columns) of Field_Record;

   type Row_Record is record
      Fields      : Field_Array;
      Num_Columns : Natural range 0 .. Max_Columns := 0;
   end record;

   type Row_Array is array (Positive range 1 .. Max_Rows) of Row_Record;

   type Table_Data is record
      Rows     : Row_Array;
      Num_Rows : Natural range 0 .. Max_Rows := 0;
   end record;

end Septerra;
