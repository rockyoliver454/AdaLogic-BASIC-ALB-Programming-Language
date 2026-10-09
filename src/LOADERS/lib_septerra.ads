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

--------------------------------------------------------------------------------
-- Lib_Septerra — C ABI for Septerra delimited tables (PSV/CSV/TSV catalogs)
--------------------------------------------------------------------------------
pragma Ada_2012;

with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;

package Lib_Septerra is

   SEP_SUCCESS         : constant int := 0;
   SEP_FILE_NOT_FOUND  : constant int := 1;
   SEP_BUFFER_OVERFLOW : constant int := 2;
   SEP_PARSE_ERROR     : constant int := 3;

   SEP_CSV : constant int := 0;
   SEP_PSV : constant int := 1;
   SEP_TSV : constant int := 2;

   function Septerra_Table_Size return int;
   pragma Export (C, Septerra_Table_Size, "Septerra_Table_Size");

   function Septerra_Load_File
     (Table_Ptr : System.Address;
      Filename  : chars_ptr;
      Kind      : int) return int;
   pragma Export (C, Septerra_Load_File, "Septerra_Load_File");

   function Septerra_Row_Count (Table_Ptr : System.Address) return int;
   pragma Export (C, Septerra_Row_Count, "Septerra_Row_Count");

   function Septerra_Column_Count
     (Table_Ptr : System.Address;
      Row       : int) return int;
   pragma Export (C, Septerra_Column_Count, "Septerra_Column_Count");

   -- Copy field text into Dest (NUL-terminated). Returns written length
   -- (excluding NUL), or -1 if missing.
   function Septerra_Get_Field
     (Table_Ptr : System.Address;
      Row       : int;
      Column    : int;
      Dest      : System.Address;
      Dest_Len  : int) return int;
   pragma Export (C, Septerra_Get_Field, "Septerra_Get_Field");

end Lib_Septerra;
