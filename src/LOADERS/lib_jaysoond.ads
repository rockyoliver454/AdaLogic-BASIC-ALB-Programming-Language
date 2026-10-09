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
-- Lib_JaySoond — C ABI for the JaySoond JSON streamer (primary manifest walker)
--------------------------------------------------------------------------------
pragma Ada_2012;

with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;

package Lib_JaySoond is

   -- Token kind codes (keep in sync with jaysoond.h)
   JAY_NONE         : constant int := 0;
   JAY_START_OBJECT : constant int := 1;
   JAY_END_OBJECT   : constant int := 2;
   JAY_START_ARRAY  : constant int := 3;
   JAY_END_ARRAY    : constant int := 4;
   JAY_KEY          : constant int := 5;
   JAY_STRING       : constant int := 6;
   JAY_INTEGER      : constant int := 7;
   JAY_FLOAT        : constant int := 8;
   JAY_BOOLEAN      : constant int := 9;
   JAY_NULL         : constant int := 10;
   JAY_ERROR        : constant int := 11;
   JAY_EOF          : constant int := 12;

   -- Opaque parser size (bytes) for C alloca / malloc of the parser object.
   function JaySoond_Parser_Size return int;
   pragma Export (C, JaySoond_Parser_Size, "JaySoond_Parser_Size");

   -- Open a JSON file. Returns 1 on success, 0 on failure.
   function JaySoond_Init_File
     (Parser_Ptr : System.Address;
      Filename   : chars_ptr) return int;
   pragma Export (C, JaySoond_Init_File, "JaySoond_Init_File");

   -- Init from a NUL-terminated C string (must fit Buffer_Size).
   function JaySoond_Init_String
     (Parser_Ptr : System.Address;
      Input      : chars_ptr) return int;
   pragma Export (C, JaySoond_Init_String, "JaySoond_Init_String");

   -- Advance one token. Writes kind + text into Dest (NUL-terminated).
   -- Returns the token kind code.
   function JaySoond_Next
     (Parser_Ptr : System.Address;
      Dest       : System.Address;
      Dest_Len   : int;
      Out_Line   : access int;
      Out_Col    : access int) return int;
   pragma Export (C, JaySoond_Next, "JaySoond_Next");

   function JaySoond_Has_More (Parser_Ptr : System.Address) return int;
   pragma Export (C, JaySoond_Has_More, "JaySoond_Has_More");

   procedure JaySoond_Close (Parser_Ptr : System.Address);
   pragma Export (C, JaySoond_Close, "JaySoond_Close");

end Lib_JaySoond;
