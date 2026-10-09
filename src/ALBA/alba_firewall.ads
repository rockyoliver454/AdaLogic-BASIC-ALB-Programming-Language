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

-- Purpose: bounded MEMORY_FIREWALL enforcement for ALBA-generated programs.
-- Safety role: zero-trust I/O boundary (CODING_RULES §8.1–8.2).
-- Assumptions: rule/target names fit in Max_Name_Length; registration at init only.

package ALBA_Firewall is

   Max_Firewalls      : constant := 64;
   Max_Firewall_Rules : constant := 512;
   Max_Name_Length    : constant := 128;
   Max_Stack_Depth    : constant := 16;

   subtype Name_Index is Natural range 0 .. Max_Name_Length;

   type Name_Buffer is array (1 .. Max_Name_Length) of Character;

   type Rule_Record is record
      Active      : Boolean := False;
      Target      : Name_Buffer := (others => ' ');
      Target_Len  : Name_Index := 0;
      Allow_Read  : Boolean := False;
      Allow_Write : Boolean := False;
   end record;

   type Firewall_Record is record
      Active     : Boolean := False;
      Name       : Name_Buffer := (others => ' ');
      Name_Len   : Name_Index := 0;
      Deny_All   : Boolean := False;
      Rule_First : Natural := 0;
      Rule_Count : Natural := 0;
   end record;

   Firewall_Violation : exception;

   procedure Clear_All;

   function Register_Firewall (Name : String; Deny_All : Boolean) return Natural
     with Pre => Name'Length > 0 and then Name'Length <= Max_Name_Length;

   procedure Add_Permit_Read (Firewall_Id : Natural; Target : String)
     with Pre =>
       Firewall_Id > 0
       and then Firewall_Id <= Max_Firewalls
       and then Target'Length > 0
       and then Target'Length <= Max_Name_Length;

   procedure Add_Permit_Write (Firewall_Id : Natural; Target : String)
     with Pre =>
       Firewall_Id > 0
       and then Firewall_Id <= Max_Firewalls
       and then Target'Length > 0
       and then Target'Length <= Max_Name_Length;

   procedure Enter (Firewall_Id : Natural)
     with Pre => Firewall_Id > 0 and then Firewall_Id <= Max_Firewalls;

   procedure Leave;

   procedure Assert_Access
     (Target : String;
      Need_Read  : Boolean;
      Need_Write : Boolean)
     with Pre => Target'Length <= Max_Name_Length;

end ALBA_Firewall;
