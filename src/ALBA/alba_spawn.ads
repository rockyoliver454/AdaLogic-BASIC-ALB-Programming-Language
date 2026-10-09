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

pragma SPARK_Mode (Off);

-- Purpose: bounded OS process spawn for ALBA build driver (GNAT.OS_Lib glue).
-- Safety role: isolated non-SPARK boundary; no use in generated programs.

package ALBA_Spawn is

   Max_Arg_Len : constant := 512;
   Max_Args    : constant := 12;

   function Run_Gprbuild
     (Working_Directory : String;
      Builder_Command   : String;
      Project_File      : String) return Boolean;

   function Run_Gnatmake
     (Working_Directory : String;
      Builder_Command   : String;
      Source_Dir        : String;
      Support_Dir       : String;
      Runtime_Root      : String;
      Types_Dir         : String;
      Core_Dir          : String;
      Main_Source       : String;
      Output_Exe        : String) return Boolean;

end ALBA_Spawn;
