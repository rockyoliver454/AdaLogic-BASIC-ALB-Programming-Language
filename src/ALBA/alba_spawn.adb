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

with Ada.Directories;
with Ada.IO_Exceptions;
with GNAT.OS_Lib;

package body ALBA_Spawn is

   function Spawn_And_Check
     (Working_Directory : String;
      Program_Name      : String;
      Args              : GNAT.OS_Lib.Argument_List) return Boolean
   is
      Original_Directory : constant String := Ada.Directories.Current_Directory;
      Exit_Code          : Integer := -1;

      procedure Restore_Original_Directory is
      begin
         Ada.Directories.Set_Directory (Original_Directory);
      exception
         when Ada.IO_Exceptions.Name_Error |
              Ada.IO_Exceptions.Use_Error |
              Ada.IO_Exceptions.Device_Error =>
            null;
      end Restore_Original_Directory;
   begin
      Ada.Directories.Set_Directory (Working_Directory);
      Exit_Code := GNAT.OS_Lib.Spawn (Program_Name, Args);
      Restore_Original_Directory;
      return Exit_Code = 0;
   exception
      when Ada.IO_Exceptions.Name_Error |
           Ada.IO_Exceptions.Use_Error |
           Ada.IO_Exceptions.Device_Error =>
         Restore_Original_Directory;
         return False;
   end Spawn_And_Check;

   function Run_Gprbuild
     (Working_Directory : String;
      Builder_Command   : String;
      Project_File      : String) return Boolean
   is
      Args : GNAT.OS_Lib.Argument_List (1 .. 3);
   begin
      Args (1) := new String'("-p");
      Args (2) := new String'("-P");
      Args (3) := new String'(Ada.Directories.Full_Name (Project_File));
      return Spawn_And_Check (Working_Directory, Builder_Command, Args);
   end Run_Gprbuild;

   function Run_Gnatmake
     (Working_Directory : String;
      Builder_Command   : String;
      Source_Dir        : String;
      Support_Dir       : String;
      Runtime_Root      : String;
      Types_Dir         : String;
      Core_Dir          : String;
      Main_Source       : String;
      Output_Exe        : String) return Boolean
   is
      Args : GNAT.OS_Lib.Argument_List (1 .. 9);
   begin
      Args (1) := new String'("-aI" & Source_Dir);
      Args (2) := new String'("-aI" & Support_Dir);
      Args (3) := new String'("-aI" & Runtime_Root);
      Args (4) := new String'("-aI" & Types_Dir);
      Args (5) := new String'("-aI" & Core_Dir);
      Args (6) := new String'("-aO" & Support_Dir);
      Args (7) := new String'(Main_Source);
      Args (8) := new String'("-o");
      Args (9) := new String'(Output_Exe);
      return Spawn_And_Check (Working_Directory, Builder_Command, Args);
   end Run_Gnatmake;

end ALBA_Spawn;
