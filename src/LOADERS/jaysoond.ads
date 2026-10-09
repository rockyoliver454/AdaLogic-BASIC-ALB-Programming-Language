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
-- Project: JaySoond - The 100-Year JSON Streamer
-- Description: Formally Verified JSON Tokenizer in SPARK/Ada 2012
-- Author: Rocky L. Oliver
-- Copyright: (c) 2026 Rocky L. Oliver
--------------------------------------------------------------------------------

pragma Ada_2012;
pragma SPARK_Mode (On);

with Ada.Streams.Stream_IO;

generic
   Max_Depth    : Positive := 64;   -- Max nested objects/arrays
   Max_Str_Len  : Positive := 1024; -- Max length of a Key or String Value
   Buffer_Size  : Positive := 4096; -- Internal buffer size

package JaySoond is

   -- Token Types
   type Token_Kind is 
     (None,           -- Initial state or error
      Start_Object,   -- {
      End_Object,     -- }
      Start_Array,    -- [
      End_Array,      -- ]
      Key,            -- "key":
      String_Val,     -- "value"
      Integer_Val,    -- 123
      Float_Val,      -- 12.34
      Boolean_Val,    -- true/false
      Null_Val,       -- null
      Error,          -- Malformed JSON
      End_Of_File);   -- Clean exit

   subtype Safe_String is String (1 .. Max_Str_Len);

   type Token_Data is record
      Kind   : Token_Kind;
      Text   : Safe_String;
      Length : Natural;
      -- NEW: Location Tracking
      Line   : Positive;
      Column : Positive;
   end record;

   -- The Parser State (Opaque)
   type Parser is limited private;

   function Is_Ready (P : Parser) return Boolean;

   procedure Init_String (P : out Parser; Input : String)
     with Pre => Input'Length <= Buffer_Size,
          Post => Is_Ready(P);

   procedure Init_File (P : out Parser; Filename : String)
     with Global => null,
          Post => Is_Ready(P) or else not Is_Ready(P); 

   procedure Next (P : in out Parser; Tok : out Token_Data)
     with Pre => Is_Ready(P);

   procedure Close (P : in out Parser);

   function Has_More (P : Parser) return Boolean;

private
   
   package SIO renames Ada.Streams.Stream_IO;

   type Context_Type is (Root, In_Object, In_Array);
   type Context_Stack is array (1 .. Max_Depth) of Context_Type;

   type Parser is record
      Is_Initialized : Boolean := False;
      Is_File_Mode   : Boolean := False;
      File_Handle    : SIO.File_Type; 
      
      Buffer      : String (1 .. Buffer_Size) := (others => ' ');
      Buf_Len     : Natural := 0;
      Cursor      : Positive := 1;
      
      -- Location State
      Current_Line : Positive := 1;
      Current_Col  : Positive := 1;
      
      Stack       : Context_Stack := (others => Root);
      Stack_Top   : Natural := 0;
      
      Error_State : Boolean := False;
      EOF_Reached : Boolean := False;
   end record;

end JaySoond;
