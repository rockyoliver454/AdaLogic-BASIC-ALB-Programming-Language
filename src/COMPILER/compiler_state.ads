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
with Tokenizer; use Tokenizer;
with AST;       use AST;

package Compiler_State is
   -- By placing these here, they go straight tae the .bss segment!
   -- Nae heap, nae stack overflow! Pure static allocation.

   Max_Diagnostic_Message_Len : constant Natural := 256;
   Max_Diagnostic_Path_Len    : constant Natural := 512;
   Max_Weaver_Diagnostics     : constant Natural := 128;
   Max_Emitter_Diagnostics    : constant Natural := 256;

   type Diagnostic_Message_Buffer is
     array (1 .. Max_Diagnostic_Message_Len) of Character;
   type Diagnostic_Path_Buffer is
     array (1 .. Max_Diagnostic_Path_Len) of Character;

   type Weaver_Diagnostic_Category is
     (Weaver_None,
      Weaver_Path_Parse_Failure,
      Weaver_Path_Too_Long,
      Weaver_Missing_Include,
      Weaver_File_Open_Failure,
      Weaver_File_Read_Failure,
      Weaver_Include_Limit_Reached,
      Weaver_Buffer_Overflow,
      Weaver_Output_Path_Failure);

   type Weaver_Diagnostic_Entry is record
      Active      : Boolean := False;
      File_Path   : Diagnostic_Path_Buffer := (others => ' ');
      File_Len    : Natural := 0;
      Line        : Natural := 0;
      Category    : Weaver_Diagnostic_Category := Weaver_None;
      Message     : Diagnostic_Message_Buffer := (others => ' ');
      Message_Len : Natural := 0;
   end record;

   type Weaver_Diagnostic_Array is
     array (1 .. Max_Weaver_Diagnostics) of Weaver_Diagnostic_Entry;

   type Weaver_Diagnostic_Log is record
      Had_Warnings   : Boolean := False;
      Had_Fatal_Error : Boolean := False;
      Warning_Count  : Natural := 0;
      Stored_Count   : Natural := 0;
      Entries        : Weaver_Diagnostic_Array :=
        (others =>
           (Active      => False,
            File_Path   => (others => ' '),
            File_Len    => 0,
            Line        => 0,
            Category    => Weaver_None,
            Message     => (others => ' '),
            Message_Len => 0));
   end record;

   type Emitter_Diagnostic_Category is
     (Emitter_None,
      Emitter_Output_Path_Invalid,
      Emitter_Output_Create_Failure,
      Emitter_Output_Write_Failure,
      Emitter_Unsupported_Statement_Node,
      Emitter_Unsupported_Expression_Node,
      Emitter_Unsupported_Feature,
      Emitter_Internal_Fallback);

   type Emitter_Diagnostic_Entry is record
      Active      : Boolean := False;
      Node        : Node_Index := 0;
      Token_Index : Natural := 0;
      Line        : Natural := 0;
      Column      : Natural := 0;
      Category    : Emitter_Diagnostic_Category := Emitter_None;
      Message     : Diagnostic_Message_Buffer := (others => ' ');
      Message_Len : Natural := 0;
   end record;

   type Emitter_Diagnostic_Array is
     array (1 .. Max_Emitter_Diagnostics) of Emitter_Diagnostic_Entry;

   type Emitter_Diagnostic_Log is record
      Had_Warnings    : Boolean := False;
      Had_Fatal_Error : Boolean := False;
      Warning_Count   : Natural := 0;
      Stored_Count    : Natural := 0;
      Entries         : Emitter_Diagnostic_Array :=
        (others =>
           (Active      => False,
            Node        => 0,
            Token_Index => 0,
            Line        => 0,
            Column      => 0,
            Category    => Emitter_None,
            Message     => (others => ' '),
            Message_Len => 0));
   end record;

   Compilation_Had_Warnings : Boolean := False;

   Input_Buffer : String (1 .. 4194304) := (others => ' ');
   Temp_Buffer  : String (1 .. 4194304) := (others => ' ');

   Tokens       : Token_Array;
   Tree         : Node_Array;

end Compiler_State;
