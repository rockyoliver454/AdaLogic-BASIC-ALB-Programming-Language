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

with Ada.Directories;
with Ada.Environment_Variables;

package body Alb_MSVC is
   use type Ada.Directories.File_Kind;

   function Existing (Candidate : String) return String is
   begin
      if Candidate'Length > 0 and then Ada.Directories.Exists (Candidate) then
         return Ada.Directories.Full_Name (Candidate);
      end if;
      return "";
   exception
      when others =>
         return "";
   end Existing;

   function Join_Path (Parent : String; Child : String) return String is
   begin
      if Parent'Length = 0 then
         return Child;
      elsif Parent (Parent'Last) = '\' or else Parent (Parent'Last) = '/' then
         return Parent & Child;
      else
         return Parent & "\" & Child;
      end if;
   end Join_Path;

   function From_Env (Name : String; Suffix : String) return String is
   begin
      if not Ada.Environment_Variables.Exists (Name) then
         return "";
      end if;

      declare
         Root : constant String := Ada.Environment_Variables.Value (Name);
         Candidate : constant String :=
           (if Suffix'Length = 0
            then Root
            else Join_Path (Root, Suffix));
      begin
         return Existing (Candidate);
      end;
   exception
      when others =>
         return "";
   end From_Env;

   function Find_In_Version_Root (Root : String) return String is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Root)
        or else Ada.Directories.Kind (Root) /= Ada.Directories.Directory
      then
         return "";
      end if;

      Ada.Directories.Start_Search
        (Search,
         Directory => Root,
         Pattern   => "*",
         Filter    => (Ada.Directories.Directory => True,
                       others                    => False));

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);

         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name /= "." and then Name /= ".." then
               declare
                  Candidate : constant String := Existing
                    (Join_Path
                       (Ada.Directories.Full_Name (Item),
                        "VC\Auxiliary\Build\vcvars64.bat"));
               begin
                  if Candidate'Length > 0 then
                     Ada.Directories.End_Search (Search);
                     return Candidate;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      return "";
   exception
      when others =>
         return "";
   end Find_In_Version_Root;

   function Find_VCVars64_Bat return String is
   begin
      declare
         Candidate : constant String := From_Env ("ALB_VCVARS64", "");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := From_Env ("ALBJ_VCVARS64", "");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String :=
           From_Env ("VSINSTALLDIR", "VC\Auxiliary\Build\vcvars64.bat");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String :=
           From_Env ("VCINSTALLDIR", "Auxiliary\Build\vcvars64.bat");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String :=
           From_Env ("VCToolsInstallDir", "..\..\..\Auxiliary\Build\vcvars64.bat");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String :=
           From_Env ("VS170COMNTOOLS", "..\..\VC\Auxiliary\Build\vcvars64.bat");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String :=
           From_Env ("VS180COMNTOOLS", "..\..\VC\Auxiliary\Build\vcvars64.bat");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := Find_In_Version_Root
           ("C:\Program Files (x86)\Microsoft Visual Studio\18");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := Find_In_Version_Root
           ("C:\Program Files\Microsoft Visual Studio\18");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := Find_In_Version_Root
           ("C:\Program Files (x86)\Microsoft Visual Studio\2022");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := Find_In_Version_Root
           ("C:\Program Files\Microsoft Visual Studio\2022");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := Find_In_Version_Root
           ("C:\Program Files (x86)\Microsoft Visual Studio\2019");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := Find_In_Version_Root
           ("C:\Program Files\Microsoft Visual Studio\2019");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      declare
         Candidate : constant String := Find_In_Version_Root
           ("C:\Program Files (x86)\Microsoft Visual Studio\17");
      begin
         if Candidate'Length > 0 then return Candidate; end if;
      end;

      return "";
   end Find_VCVars64_Bat;
end Alb_MSVC;
