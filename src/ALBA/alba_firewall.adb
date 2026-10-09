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

package body ALBA_Firewall is

   Firewalls          : array (1 .. Max_Firewalls) of Firewall_Record;
   Rules              : array (1 .. Max_Firewall_Rules) of Rule_Record;
   Firewall_Count     : Natural := 0;
   Rule_Count         : Natural := 0;
   Stack              : array (1 .. Max_Stack_Depth) of Natural := (others => 0);
   Stack_Top          : Natural := 0;

   procedure Copy_Name
     (Into : out Name_Buffer;
      Len  : out Name_Index;
      From : String)
   is
   begin
      Len := Name_Index (From'Length);
      for I in 1 .. Len loop
         Into (I) := From (From'First + I - 1);
      end loop;
      for I in Len + 1 .. Max_Name_Length loop
         Into (I) := ' ';
      end loop;
   end Copy_Name;

   function Names_Equal
     (Left     : Name_Buffer;
      Left_Len : Name_Index;
      Right    : String) return Boolean
   is
   begin
      if Left_Len /= Right'Length then
         return False;
      end if;
      for I in 1 .. Left_Len loop
         if Left (I) /= Right (Right'First + I - 1) then
            return False;
         end if;
      end loop;
      return True;
   end Names_Equal;

   procedure Clear_All is
   begin
      Firewall_Count := 0;
      Rule_Count := 0;
      Stack_Top := 0;
      Firewalls := (others => <>);
      Rules := (others => <>);
      Stack := (others => 0);
   end Clear_All;

   function Register_Firewall (Name : String; Deny_All : Boolean) return Natural is
   begin
      pragma Assert (Firewall_Count < Max_Firewalls);
      if Firewall_Count >= Max_Firewalls then
         return 0;
      end if;

      Firewall_Count := Firewall_Count + 1;
      Firewalls (Firewall_Count).Active := True;
      Copy_Name (Firewalls (Firewall_Count).Name, Firewalls (Firewall_Count).Name_Len, Name);
      Firewalls (Firewall_Count).Deny_All := Deny_All;
      Firewalls (Firewall_Count).Rule_First := Rule_Count + 1;
      Firewalls (Firewall_Count).Rule_Count := 0;
      return Firewall_Count;
   end Register_Firewall;

   procedure Add_Rule
     (Firewall_Id : Natural;
      Target      : String;
      Allow_Read  : Boolean;
      Allow_Write : Boolean)
   is
   begin
      pragma Assert (Rule_Count < Max_Firewall_Rules);
      if Rule_Count >= Max_Firewall_Rules
        or else Firewall_Id = 0
        or else Firewall_Id > Firewall_Count
      then
         return;
      end if;

      Rule_Count := Rule_Count + 1;
      Rules (Rule_Count).Active := True;
      Copy_Name (Rules (Rule_Count).Target, Rules (Rule_Count).Target_Len, Target);
      Rules (Rule_Count).Allow_Read := Allow_Read;
      Rules (Rule_Count).Allow_Write := Allow_Write;
      Firewalls (Firewall_Id).Rule_Count :=
        Firewalls (Firewall_Id).Rule_Count + 1;
   end Add_Rule;

   procedure Add_Permit_Read (Firewall_Id : Natural; Target : String) is
   begin
      Add_Rule (Firewall_Id, Target, True, False);
   end Add_Permit_Read;

   procedure Add_Permit_Write (Firewall_Id : Natural; Target : String) is
   begin
      Add_Rule (Firewall_Id, Target, False, True);
   end Add_Permit_Write;

   procedure Enter (Firewall_Id : Natural) is
   begin
      pragma Assert (Stack_Top < Max_Stack_Depth);
      if Stack_Top >= Max_Stack_Depth then
         raise Firewall_Violation;
      end if;
      Stack_Top := Stack_Top + 1;
      Stack (Stack_Top) := Firewall_Id;
   end Enter;

   procedure Leave is
   begin
      if Stack_Top = 0 then
         return;
      end if;
      Stack (Stack_Top) := 0;
      Stack_Top := Stack_Top - 1;
   end Leave;

   function Rule_Allows
     (Firewall_Id : Natural;
      Target      : String;
      Need_Read   : Boolean;
      Need_Write  : Boolean) return Boolean
   is
      Allowed_Read  : Boolean := False;
      Allowed_Write : Boolean := False;
      First_Rule    : Natural;
      Last_Rule     : Natural;
   begin
      if Firewall_Id = 0 or else Firewall_Id > Firewall_Count then
         return True;
      end if;

      if Firewalls (Firewall_Id).Deny_All then
         return False;
      end if;

      if Firewalls (Firewall_Id).Rule_Count = 0 then
         return True;
      end if;

      First_Rule := Firewalls (Firewall_Id).Rule_First;
      Last_Rule := First_Rule + Firewalls (Firewall_Id).Rule_Count - 1;

      for I in First_Rule .. Last_Rule loop
         if Rules (I).Active
           and then Names_Equal (Rules (I).Target, Rules (I).Target_Len, Target)
         then
            Allowed_Read := Allowed_Read or Rules (I).Allow_Read;
            Allowed_Write := Allowed_Write or Rules (I).Allow_Write;
         end if;
      end loop;

      if Need_Read and then not Allowed_Read then
         return False;
      end if;

      if Need_Write and then not Allowed_Write then
         return False;
      end if;

      return True;
   end Rule_Allows;

   procedure Assert_Access
     (Target : String;
      Need_Read  : Boolean;
      Need_Write : Boolean)
   is
   begin
      if Target'Length = 0 then
         return;
      end if;

      for S in 1 .. Stack_Top loop
         if not Rule_Allows (Stack (S), Target, Need_Read, Need_Write) then
            raise Firewall_Violation;
         end if;
      end loop;
   end Assert_Access;

end ALBA_Firewall;
