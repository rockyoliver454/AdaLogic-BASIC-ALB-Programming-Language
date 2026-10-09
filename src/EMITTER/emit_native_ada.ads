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

package Emit_Native_Ada is

   ALBA_Emitter_Ready : Boolean := False;
   Indent_Level       : Natural := 0;

   procedure Init_Emitter
     (Success : out Boolean);

   procedure Emit_Raw
     (Text    : String;
      Success : out Boolean)
   with Pre => ALBA_Emitter_Ready = True;

   procedure Emit_Newline
     (Success : out Boolean)
   with Pre => ALBA_Emitter_Ready = True;

   procedure Emit_Indent
     (Success : out Boolean)
   with Pre => ALBA_Emitter_Ready = True;

   procedure Emit_Line
     (Text    : String;
      Success : out Boolean)
   with Pre => ALBA_Emitter_Ready = True;

   procedure Increase_Indent;

   procedure Decrease_Indent
   with Pre => Indent_Level > 0;

   procedure Flush_To_File
     (File_Path : String;
      Success   : out Boolean)
   with Pre => ALBA_Emitter_Ready = True;

   procedure Emit_Program
     (Source       : String;
      Tokens       : Token_Array;
      Token_Count  : Natural;
      Tree         : Node_Array;
      Root         : Node_Index;
      Program_Name : String;
      Output_Path  : String;
      Success      : out Boolean);

end Emit_Native_Ada;
