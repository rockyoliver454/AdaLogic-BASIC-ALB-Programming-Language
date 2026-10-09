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
-- Project: AyeNEye - The 100-Year Configuration Vault
-- Description: Formally Verified INI Parser in SPARK/Ada 2012
--
-- Author: Rocky L. Oliver
-- Copyright: (c) 2026 Rocky L. Oliver
-- All rights reserved.
-- 
-- License: Dual-licensed under MIT and BSD 3-Clause
--          This software is provided "AS IS" without warranty.
--          See the root LICENSE file for full terms and conditions.
--
-- Documentation: https://rockyoliver.itch.io/ayeneye-ini-parser
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- PACKAGE DOCUMENTATION: AyeNEye
--------------------------------------------------------------------------------
-- PURPOSE:
--   AyeNEye provides a formally verified, high-integrity INI parser for 
--   embedded systems, game engines, and long-term archival software. It is 
--   designed to be "Ready for Use" in environments where reliability and 
--   predictability are paramount.
--
-- DESIGN PHILOSOPHY:
--   1. Zero Heap: No dynamic memory allocation is performed after 
--      initialization. All structures are stored in a static "Big Bucket" 
--      buffer.
--   2. SPARK Verified: The core retrieval logic is marked with 
--      'pragma SPARK_Mode (On)' and is formally proven to be free from 
--      runtime errors (no out-of-bounds, no overflows).
--   3. Deterministic: All operations have fixed resource bounds defined at 
--      compile-time via generic parameters.
--
-- GENERIC PARAMETERS:
--   Max_Sections : Total number of [Section] headers permitted.
--   Max_Keys     : Total number of Key=Value pairs across the whole file.
--   Max_Line_Len : Maximum length of any single line in the input file.
--
-- ARCHITECTURAL USAGE:
--   This is a "Bucket" model parser. The 'Config_Data' record acts as a 
--   self-contained database of the configuration state. Once loaded, the 
--   data is immutable and can be queried safely across different language 
--   bindings (C, C++, Zig, etc.) through the C-ABI bridge.
--
-- ERROR HANDLING:
--   - Success: Parse completed and data is ready.
--   - File_Not_Found: The physical .ini file could not be accessed.
--   - Buffer_Overflow: The file contains more sections or keys than the 
--     generic bounds allow.
--   - Parse_Error: The file format is malformed (e.g., missing '=').
--------------------------------------------------------------------------------


pragma Ada_2012;
pragma SPARK_Mode (On); -- Turn on the formal verification engine

generic
   Max_Sections : Positive;
   Max_Keys     : Positive;
   Max_Line_Len : Positive;

package AyeNEye is

   -- TYPES
   subtype Safe_String is String (1 .. Max_Line_Len);
   
   type Config_Data is private;

   type Load_Result is (Success, File_Not_Found, Buffer_Overflow, Parse_Error);

   -- PROCEDURES
   
   -- We mark this "Off" in the spec because its implementation relies on 
   -- OS-level Exceptions (Text_IO), which SPARK does not support validating.
   procedure Load_INI 
     (Filename : in String;
      Config   : out Config_Data;
      Result   : out Load_Result)
   with SPARK_Mode => Off; 

   -- GETTERS
   
   -- These are Pure logic. SPARK will verify them fully.
   function Get_String
     (Config  : Config_Data;
      Section : String;
      Key     : String;
      Default : String := "") return String;

   -- We mark "Off" here because Integer'Value raises exceptions on failure.
   function Get_Integer
     (Config  : Config_Data;
      Section : String;
      Key     : String;
      Default : Integer := 0) return Integer
   with SPARK_Mode => Off;

   function Get_Boolean
     (Config  : Config_Data;
      Section : String;
      Key     : String;
      Default : Boolean := False) return Boolean;

private

   subtype Section_ID is Integer range 0 .. Max_Sections;
   subtype Key_ID     is Integer range 0 .. Max_Keys;

   type KV_Pair is record
      Section_Ref : Section_ID;
      Key         : Safe_String;
      Key_Len     : Natural;
      Value       : Safe_String;
      Value_Len   : Natural;
   end record;

   type Section_Record is record
      Name     : Safe_String;
      Name_Len : Natural;
   end record;

   type Section_Array is array (1 .. Max_Sections) of Section_Record;
   type Key_Array     is array (1 .. Max_Keys) of KV_Pair;

   type Config_Data is record
      Sections     : Section_Array;
      Num_Sections : Section_ID := 0;
      
      Keys         : Key_Array;
      Num_Keys     : Key_ID := 0;
   end record;

end AyeNEye;
