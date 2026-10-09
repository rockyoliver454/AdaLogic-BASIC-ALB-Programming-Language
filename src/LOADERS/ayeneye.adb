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
-- Project: AyeNEye - The 100-Year Configuration Vault
-- Description: Formally Verified INI Parser in SPARK/Ada 2012
--
-- Author: Rocky L. Oliver
-- Copyright: (c) 2026 Rocky L. Oliver
-- All rights reserved.
-- 
-- License: Dual-licensed under MIT and BSD 3-Clause
--          This software is provided "AS IS" without warranty.
--          See the root LICENSE file for full terms and conditions.
--
-- Documentation: https://rockyoliver.itch.io/ayeneye-ini-parser
--------------------------------------------------------------------------------
-- BODY FILE: AyeNEye.adb

pragma Ada_2012;
-- The package body is On by default, matching the spec.
pragma SPARK_Mode (On); 

with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Characters.Handling;

package body AyeNEye is

   use Ada.Strings.Fixed;
   use Ada.Characters.Handling;

   -----------------------------------------------------------------------------
   -- UTILS: SAFE TRIM & UPPERCASE (Verified)
   -----------------------------------------------------------------------------
   function Normalize (Input : String) return String is
   begin
      return To_Lower (Trim (Input, Ada.Strings.Both));
   end Normalize;

   -----------------------------------------------------------------------------
   -- LOAD INI (Unverified - IO & Exceptions)
   -----------------------------------------------------------------------------
   procedure Load_INI 
     (Filename : in String;
      Config   : out Config_Data;
      Result   : out Load_Result) 
   with SPARK_Mode => Off -- Explicitly opt-out of proof for this body
   is
      File : Ada.Text_IO.File_Type;
      Line : String (1 .. Max_Line_Len + 1); 
      Last : Natural;
      
      Current_Section : Section_ID := 0; 
      Eq_Index : Natural;
   begin
      Config.Num_Sections := 0;
      Config.Num_Keys     := 0;
      
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Filename);
      exception
         when others =>
            Result := File_Not_Found;
            return;
      end;

      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line, Last);

         if Last > Max_Line_Len then
            Last := Max_Line_Len; 
         end if;

         declare
            Raw_Content : constant String := Trim(Line(1 .. Last), Ada.Strings.Both);
         begin
            if Raw_Content'Length > 0 and then
               (Raw_Content(1) /= ';' and Raw_Content(1) /= '#') 
            then
               -- A. DETECT SECTION
               if Raw_Content(1) = '[' and then Raw_Content(Raw_Content'Last) = ']' then
                  declare
                     S_Name : constant String := Trim(Raw_Content(2 .. Raw_Content'Last - 1), Ada.Strings.Both);
                     Found  : Boolean := False;
                  begin
                     for I in 1 .. Config.Num_Sections loop
                        declare
                           Existing : constant String := Normalize(Config.Sections(Natural(I)).Name(1 .. Config.Sections(Natural(I)).Name_Len));
                        begin
                           if Existing = Normalize(S_Name) then
                              Current_Section := I;
                              Found := True;
                              exit;
                           end if;
                        end;
                     end loop;

                     if not Found then
                        if Config.Num_Sections < Max_Sections then
                           Config.Num_Sections := Config.Num_Sections + 1;
                           Current_Section := Config.Num_Sections;
                           
                           Config.Sections(Natural(Current_Section)).Name(1 .. S_Name'Length) := S_Name;
                           Config.Sections(Natural(Current_Section)).Name_Len := S_Name'Length;
                        else
                           Result := Buffer_Overflow;
                           Ada.Text_IO.Close(File);
                           return;
                        end if;
                     end if;
                  end;

               -- B. DETECT KEY
               else
                  Eq_Index := Index(Raw_Content, "=");
                  if Eq_Index > 0 then
                     if Config.Num_Keys < Max_Keys then
                        Config.Num_Keys := Config.Num_Keys + 1;
                        
                        declare
                           Raw_K : constant String := Trim(Raw_Content(1 .. Eq_Index - 1), Ada.Strings.Both);
                           Raw_V : constant String := Trim(Raw_Content(Eq_Index + 1 .. Raw_Content'Last), Ada.Strings.Both);
                           Idx   : constant Natural := Natural(Config.Num_Keys);
                        begin
                           Config.Keys(Idx).Key(1 .. Raw_K'Length) := Raw_K;
                           Config.Keys(Idx).Key_Len := Raw_K'Length;
                           
                           Config.Keys(Idx).Value(1 .. Raw_V'Length) := Raw_V;
                           Config.Keys(Idx).Value_Len := Raw_V'Length;
                           
                           Config.Keys(Idx).Section_Ref := Current_Section;
                        end;
                     else
                        Result := Buffer_Overflow;
                        Ada.Text_IO.Close(File);
                        return;
                     end if;
                  end if;
               end if;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      Result := Success;

   exception
      when others =>
         if Ada.Text_IO.Is_Open(File) then
            Ada.Text_IO.Close(File);
         end if;
         Result := Parse_Error;
   end Load_INI;

   -----------------------------------------------------------------------------
   -- FIND HELPERS (Verified)
   -----------------------------------------------------------------------------
   function Find_Section_ID (Config : Config_Data; Name : String) return Section_ID is
      Clean_Name : constant String := Normalize(Name);
   begin
      for I in 1 .. Config.Num_Sections loop
         declare
            Stored_Name : constant String := Normalize(Config.Sections(Natural(I)).Name(1 .. Config.Sections(Natural(I)).Name_Len));
         begin
            if Stored_Name = Clean_Name then
               return I;
            end if;
         end;
      end loop;
      return 0; 
   end Find_Section_ID;

   -----------------------------------------------------------------------------
   -- GET STRING (Verified)
   -----------------------------------------------------------------------------
   function Get_String
     (Config  : Config_Data;
      Section : String;
      Key     : String;
      Default : String := "") return String 
   is
      Sec_ID : constant Section_ID := Find_Section_ID(Config, Section);
      Clean_Key : constant String := Normalize(Key);
   begin
      for I in 1 .. Config.Num_Keys loop
         if Config.Keys(Natural(I)).Section_Ref = Sec_ID then
            declare
               Stored_Key : constant String := Normalize(Config.Keys(Natural(I)).Key(1 .. Config.Keys(Natural(I)).Key_Len));
            begin
               if Stored_Key = Clean_Key then
                  return Config.Keys(Natural(I)).Value(1 .. Config.Keys(Natural(I)).Value_Len);
               end if;
            end;
         end if;
      end loop;
      return Default;
   end Get_String;

   -----------------------------------------------------------------------------
   -- GET INTEGER (Unverified - Exceptions)
   -----------------------------------------------------------------------------
   function Get_Integer
     (Config  : Config_Data;
      Section : String;
      Key     : String;
      Default : Integer := 0) return Integer 
   with SPARK_Mode => Off
   is
      Val_Str : constant String := Get_String(Config, Section, Key, "");
   begin
      if Val_Str = "" then
         return Default;
      end if;
      return Integer'Value(Val_Str);
   exception
      when others => return Default;
   end Get_Integer;

   -----------------------------------------------------------------------------
   -- GET BOOLEAN (Verified)
   -----------------------------------------------------------------------------
   function Get_Boolean
     (Config  : Config_Data;
      Section : String;
      Key     : String;
      Default : Boolean := False) return Boolean 
   is
      Val_Str : constant String := Normalize(Get_String(Config, Section, Key, ""));
   begin
      if Val_Str = "true" or Val_Str = "yes" or Val_Str = "1" or Val_Str = "on" then
         return True;
      elsif Val_Str = "false" or Val_Str = "no" or Val_Str = "0" or Val_Str = "off" then
         return False;
      else
         return Default;
      end if;
   end Get_Boolean;

end AyeNEye;
