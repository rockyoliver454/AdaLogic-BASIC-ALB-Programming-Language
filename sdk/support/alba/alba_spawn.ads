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
