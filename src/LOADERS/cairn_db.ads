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
pragma SPARK_Mode (On); -- Turn on formal verification

with System;
with Interfaces; use Interfaces;

-- Cairn_DB: A Fixed-Bound, Indexed Binary Database.
-- "Static storage for dynamic worlds."
generic
   Max_Entries   : Positive; -- Max number of items (IDs)
   Max_Blob_Size : Positive; -- Max size of the raw data area in bytes

package Cairn_DB is

   -- Standard Types
   type ID_Type    is new Unsigned_32;
   type Tag_Type   is new Unsigned_16;
   type Size_Type  is new Unsigned_32;
   
   -- Error States
   type Cairn_Result is (Success, File_Not_Found, Database_Full, ID_Not_Found, IO_Error);

   -----------------------------------------------------------------------------
   -- LIFECYCLE (Unverified - IO)
   -----------------------------------------------------------------------------
   -- Loads the Index and Blob files into the static memory buffer.
   procedure Load_Cairn 
     (Index_File : String; 
      Blob_File  : String;
      Result     : out Cairn_Result)
   with SPARK_Mode => Off; -- IO cannot be proven

   -----------------------------------------------------------------------------
   -- QUERY (O(log n) or O(1))
   -----------------------------------------------------------------------------
   -- Returns the address of the raw data.
   -- We mark this 'Off' because returning pointers to internal state 
   -- creates aliasing, which SPARK restricts.
   function Get_Address (ID : ID_Type) return System.Address
   with SPARK_Mode => Off;
   
   -- Returns the Tag (e.g., Type_ID) for this entry.
   -- Fully Verified.
   function Get_Tag (ID : ID_Type) return Tag_Type;

   -- Returns the Size of the stored data chunk.
   -- Fully Verified.
   function Get_Size (ID : ID_Type) return Size_Type;

private
   
   -- The Internal Index Entry (Packed)
   type Index_Entry is record
      ID          : ID_Type;
      Tag         : Tag_Type;
      Blob_Offset : Unsigned_32;
      Data_Size   : Size_Type;
   end record;
   pragma Pack (Index_Entry);

   -- FIXED MEMORY BUFFERS (JPL Rule: No Heap)
   type Index_Array is array (1 .. Max_Entries) of Index_Entry;
   type Blob_Array  is array (1 .. Max_Blob_Size) of Unsigned_8;

   type Database_State is record
      Index       : Index_Array;
      Blob        : Blob_Array;
      Entry_Count : Natural := 0;
   end record;
   
   -- The State Instance
   State : Database_State;

end Cairn_DB;
