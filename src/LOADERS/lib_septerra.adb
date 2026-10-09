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

with Septerra_Std;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;

package body Lib_Septerra is

   use Septerra_Std;

   function Safe_Value (Ptr : chars_ptr) return String is
   begin
      if Ptr = Null_Ptr then
         return "";
      else
         return Value (Ptr);
      end if;
   end Safe_Value;

   function To_Kind (K : int) return Delimiter_Kind is
   begin
      case K is
         when SEP_CSV => return CSV;
         when SEP_TSV => return TSV;
         when others  => return PSV;
      end case;
   end To_Kind;

   function Septerra_Table_Size return int is
   begin
      return int (Table_Data'Size / 8);
   end Septerra_Table_Size;

   function Septerra_Load_File
     (Table_Ptr : System.Address;
      Filename  : chars_ptr;
      Kind      : int) return int
   is
      T : Table_Data;
      pragma Import (Ada, T);
      for T'Address use Table_Ptr;
      Res : Table_Result;
   begin
      Load_File (Safe_Value (Filename), To_Kind (Kind), T, Res);
      case Res is
         when Success         => return SEP_SUCCESS;
         when File_Not_Found  => return SEP_FILE_NOT_FOUND;
         when Buffer_Overflow => return SEP_BUFFER_OVERFLOW;
         when Parse_Error     => return SEP_PARSE_ERROR;
      end case;
   end Septerra_Load_File;

   function Septerra_Row_Count (Table_Ptr : System.Address) return int is
      T : Table_Data;
      pragma Import (Ada, T);
      for T'Address use Table_Ptr;
   begin
      return int (Row_Count (T));
   end Septerra_Row_Count;

   function Septerra_Column_Count
     (Table_Ptr : System.Address;
      Row       : int) return int
   is
      T : Table_Data;
      pragma Import (Ada, T);
      for T'Address use Table_Ptr;
   begin
      if Row < 1 then
         return 0;
      end if;
      return int (Column_Count (T, Positive (Row)));
   end Septerra_Column_Count;

   function Septerra_Get_Field
     (Table_Ptr : System.Address;
      Row       : int;
      Column    : int;
      Dest      : System.Address;
      Dest_Len  : int) return int
   is
      T : Table_Data;
      pragma Import (Ada, T);
      for T'Address use Table_Ptr;
      Field : constant String :=
        Get_Field (T, Positive (Row), Positive (Column), "");
      Copy_Len : Natural := Field'Length;
      Dest_Arr : char_array (0 .. size_t (Dest_Len));
      for Dest_Arr'Address use Dest;
      pragma Import (Ada, Dest_Arr);
   begin
      if Dest_Len <= 0 or else Row < 1 or else Column < 1 then
         return -1;
      end if;
      if Copy_Len >= Natural (Dest_Len) then
         Copy_Len := Natural (Dest_Len) - 1;
      end if;
      for I in 1 .. Copy_Len loop
         Dest_Arr (size_t (I - 1)) := To_C (Field (I));
      end loop;
      Dest_Arr (size_t (Copy_Len)) := nul;
      return int (Field'Length);
   end Septerra_Get_Field;

end Lib_Septerra;
