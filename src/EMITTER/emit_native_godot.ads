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

with Tokenizer;      use Tokenizer;
with AST;            use AST;
with Compiler_State; use Compiler_State;

package Emit_Native_Godot is

   type Godot_API_Target is
     (Godot_46);

   procedure Initialize_Output
     (Output_Directory : in String;
      Source_Name      : in String;
      Class_Name       : in String;
      Base_Class       : in String;
      Resource_Base    : in String;
      API_Target       : in Godot_API_Target;
      Build_Mode       : in Boolean;
      Diagnostic       : in out Emitter_Diagnostic_Log);

   procedure Emit_Program
     (Tokens      : in Token_Array;
      Tree        : in Node_Array;
      Root        : in Node_Index;
      Diagnostic  : in out Emitter_Diagnostic_Log);

end Emit_Native_Godot;
