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

with AST; use AST;

--  Micro ALB native Rust (rustc) backend.
--  Target: #![no_std] / embedded / any rustc-supported target.
--  Driver: malbr.exe (weave -> tokenize -> parse -> Compile_To_File -> rustc).
package Emit_Native_Micro_Rust with SPARK_Mode => On is

   procedure Set_No_Console_Overlay (Enabled : in Boolean);

   procedure Set_Entry_Mode (Use_Custom_Entry : in Boolean;
                             Entry_Name       : in String);

   procedure Set_Target_Triple (Triple : in String);

   --  Size of the static string/scratch arena emitted into the generated
   --  preamble (bytes).  Default 4096.
   procedure Set_Arena_Size (Bytes : in Natural);

   procedure Compile_To_File
     (Root_Index      : in Node_Index;
      Output_Filename : in String);

end Emit_Native_Micro_Rust;
