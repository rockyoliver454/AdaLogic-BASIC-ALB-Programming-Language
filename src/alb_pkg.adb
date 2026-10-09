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

-- alb-pkg: ALB package / SDK manager (Alire-style, KISS).
--
--   alb-pkg install <pack> [...] | install --project <file.albproj>
--   alb-pkg update [<pack> | all] | remove <pack> | list | doctor
--   alb-pkg self-update | help
--
-- Packs come from an INI index, default
--   https://alb-lang.org/dist/index.ini
-- override with the ALB_PKG_INDEX environment variable (may be an
-- http(s) URL or a file:// URL, which curl also serves).
--
-- index.ini contract (this is what alb-lang.org/dist must host):
--   [index]
--   version=1
--   [self]
--   version=<ver> file=<rel-url> sha256=<hex> size=<bytes>
--   [pack:<id>]
--   version=<ver> file=<rel-url> sha256=<hex> size=<bytes>
--   kind=<sdk|toolchain|src|config|thirdparty|examples>
--   dest=<sdk-relative dir, "." = SDK root>
--   paths=<space-separated top-level entries owned by the pack>
--   description=<one line>
--   members=<ids, only for the "full" meta pack; no file/sha256/size>
--
-- State (config/alb-pkg.ini): [pkg] index=<url>, [installed] id=ver,
-- plus [installed.<id>] version=/dest=/paths= recorded at install time.
-- remove/doctor prefer recorded paths, falling back to the index.
-- install --project also writes alb-pkg.lock (resolved id=ver pairs)
-- next to the .albproj.
--
-- No network code is compiled in: downloads go through curl.exe,
-- hashes through certutil, extraction through tar.exe (all inbox on
-- Windows 10+). Nothing is ever written outside the SDK root:
-- dest/paths entries containing ".." or absolute paths are refused.

with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Environment_Variables;
with Ada.Characters.Handling;
with Ada.Exceptions;
with GNAT.OS_Lib;

with AyeNEye;

procedure Alb_Pkg is

   package Idx_INI is new AyeNEye
     (Max_Sections => 128,
      Max_Keys     => 1024,
      Max_Line_Len => 1024);
   use type Idx_INI.Load_Result;

   package State_INI is new AyeNEye
     (Max_Sections => 8,
      Max_Keys     => 256,
      Max_Line_Len => 1024);
   use type Idx_INI.Load_Result;
   use type State_INI.Load_Result;

   Default_Index : constant String := "https://alb-lang.org/dist/index.ini";
   Tool_Version  : constant String := "0.0.10.35";

   Max_Packs : constant := 128;

   type Pack_Rec is record
      Name    : String (1 .. 64) := (others => ' ');
      Name_L  : Natural := 0;
      Ver     : String (1 .. 32) := (others => ' ');
      Ver_L   : Natural := 0;
      Dest    : String (1 .. 128) := (others => ' ');
      Dest_L  : Natural := 0;
      Paths   : String (1 .. 1024) := (others => ' ');
      Paths_L : Natural := 0;
   end record;
   type Pack_List is array (1 .. Max_Packs) of Pack_Rec;

   function Exe_Dir return String is
      Command : constant String := Ada.Command_Line.Command_Name;
   begin
      for I in reverse Command'Range loop
         if Command (I) = '\' or else Command (I) = '/' then
            return Command (Command'First .. I);
         end if;
      end loop;
      return Ada.Directories.Current_Directory & "\";
   end Exe_Dir;

   function SDK_Root return String is
      Bin  : constant String := Exe_Dir;
      Last : Natural := Bin'Last;
   begin
      while Last >= Bin'First
        and then (Bin (Last) = '\' or else Bin (Last) = '/')
      loop
         Last := Last - 1;
      end loop;
      if Last < Bin'First then
         return Ada.Directories.Current_Directory;
      end if;
      return Ada.Directories.Containing_Directory
        (Bin (Bin'First .. Last));
   exception
      when others =>
         return Ada.Directories.Current_Directory;
   end SDK_Root;

   function Join (Root : String; Rel : String) return String is
   begin
      if Root'Length > 0
        and then (Root (Root'Last) = '\' or else Root (Root'Last) = '/')
      then
         return Root & Rel;
      end if;
      return Root & "\" & Rel;
   end Join;

   procedure Fail (Msg : String) is
   begin
      Put_Line ("alb-pkg: error: " & Msg);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Fail;

   function Lower_Char (C : Character) return Character is
   begin
      if C in 'A' .. 'Z' then
         return Character'Val (Character'Pos (C) + 32);
      end if;
      return C;
   end Lower_Char;

   function Lower_Str (S : String) return String is
      R : String (S'Range);
   begin
      for I in S'Range loop
         R (I) := Lower_Char (S (I));
      end loop;
      return R;
   end Lower_Str;

   function Trim (S : String) return String is
      A : Natural := S'First;
      B : Natural := S'Last;
   begin
      while A <= S'Last and then (S (A) = ' ' or else S (A) = ASCII.HT) loop
         A := A + 1;
      end loop;
      while B >= A and then (S (B) = ' ' or else S (B) = ASCII.HT
                             or else S (B) = ASCII.CR or else S (B) = ASCII.LF) loop
         B := B - 1;
      end loop;
      if B < A then
         return "";
      end if;
      return S (A .. B);
   end Trim;

   function Run (Prog : String; A1 : String := "";
                 A2 : String := ""; A3 : String := "";
                 A4 : String := ""; A5 : String := "";
                 A6 : String := ""; A7 : String := "") return Integer
   is
      use type GNAT.OS_Lib.String_Access;
      Args : GNAT.OS_Lib.Argument_List (1 .. 7);
      Used : Natural := 0;
      Result : Integer := -1;
      procedure Push (S : String) is
      begin
         if S'Length > 0 then
            Used := Used + 1;
            Args (Used) := new String'(S);
         end if;
      end Push;
   begin
      Push (A1); Push (A2); Push (A3); Push (A4); Push (A5); Push (A6);
      Push (A7);
      if Used = 0 then
         declare
            Empty : GNAT.OS_Lib.Argument_List (1 .. 1);
         begin
            Empty (1) := new String'("");
            Result := GNAT.OS_Lib.Spawn (Prog, Empty (1 .. 0));
            GNAT.OS_Lib.Free (Empty (1));
         end;
      else
         Result := GNAT.OS_Lib.Spawn (Prog, Args (1 .. Used));
      end if;
      for I in 1 .. Used loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Result;
   exception
      when E : others =>
         for I in 1 .. Used loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         Put_Line ("alb-pkg: spawn failed: " & Ada.Exceptions.Exception_Message (E));
         return -1;
   end Run;

   function System_Root return String is
   begin
      if Ada.Environment_Variables.Exists ("SystemRoot") then
         return Ada.Environment_Variables.Value ("SystemRoot");
      end if;
      return "C:\Windows";
   end System_Root;

   function Find_Tool (Name : String) return String is
      Candidate : constant String := Join (System_Root, "System32\" & Name);
   begin
      if Ada.Directories.Exists (Candidate) then
         return Candidate;
      end if;
      return Name;
   end Find_Tool;

   function Index_URL return String is
   begin
      if Ada.Environment_Variables.Exists ("ALB_PKG_INDEX") then
         declare
            V : constant String :=
              Ada.Environment_Variables.Value ("ALB_PKG_INDEX");
         begin
            if V'Length > 0 then
               return V;
            end if;
         end;
      end if;
      return Default_Index;
   end Index_URL;

   function Index_Base (URL : String) return String is
   begin
      for I in reverse URL'Range loop
         if URL (I) = '/' then
            return URL (URL'First .. I);
         end if;
      end loop;
      return URL & "/";
   end Index_Base;

   procedure Print_Help is
   begin
      Put_Line ("alb-pkg " & Tool_Version & " - ALB SDK package manager");
      Put_Line ("index: " & Index_URL & " (override: ALB_PKG_INDEX)");
      Put_Line ("");
      Put_Line ("  alb-pkg install <pack> [...]     fetch + verify + unpack");
      Put_Line ("  alb-pkg install all              install everything");
      Put_Line ("  alb-pkg install --project <f>    install packs a .albproj needs");
      Put_Line ("  alb-pkg update [<pack> | all]    refresh to index versions");
      Put_Line ("  alb-pkg remove <pack>            delete owned paths");
      Put_Line ("  alb-pkg list                     installed packs");
      Put_Line ("  alb-pkg packs                    list packs the index offers");
      Put_Line ("  alb-pkg doctor                   verify tools + installed packs");
      Put_Line ("  alb-pkg self-update              fetch newest alb-pkg.exe");
      Put_Line ("  alb-pkg help                     this text");
   end Print_Help;

   function Pack_Section (Id : String) return String is
   begin
      return "pack:" & Id;
   end Pack_Section;

   function Is_Safe_Rel (P : String) return Boolean is
   begin
      if P'Length = 0 or else P = "." then
         return True;
      end if;
      if P (P'First) = '/' or else P (P'First) = '\' then
         return False;
      end if;
      if P'Length >= 2 and then P (P'First + 1) = ':' then
         return False;
      end if;
      if P'Length >= 3 then
         for I in P'First .. P'Last - 2 loop
            if P (I) = '.' and then P (I + 1) = '.' then
               return False;
            end if;
         end loop;
      end if;
      return True;
   end Is_Safe_Rel;

   function Download (URL : String; Out_Path : String) return Boolean is
      Curl : constant String := Find_Tool ("curl.exe");
      Code : Integer;
   begin
      Code := Run (Curl, "-sS", "-L", "--retry", "2", "-o", Out_Path, URL);
      if Code /= 0 then
         return False;
      end if;
      return Ada.Directories.Exists (Out_Path);
   end Download;

   function File_Size (Path : String) return Long_Long_Integer is
   begin
      return Long_Long_Integer (Ada.Directories.Size (Path));
   exception
      when others =>
         return -1;
   end File_Size;

   function Sha256_Of (Path : String; Root : String) return String is
      Cert : constant String := Find_Tool ("certutil.exe");
      Tmp  : constant String := Join (Root, "tmp\alb-pkg-hash.txt");
      Code : Integer;
      F    : Ada.Text_IO.File_Type;
      Line2 : String (1 .. 256);
      Last  : Natural := 0;
      Got   : Natural := 0;
   begin
      Code := Run ("powershell.exe", "-NoProfile", "-Command",
                   "(Get-FileHash -Algorithm SHA256 -Path '" & Path
                   & "').Hash | Out-File -Encoding ascii '" & Tmp & "'");
      if Code /= 0 then
         return "";
      end if;
      begin
         Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Tmp);
      exception
         when others =>
            return "";
      end;
      while not Ada.Text_IO.End_Of_File (F) loop
         begin
            Ada.Text_IO.Get_Line (F, Line2, Last);
         exception
            when others =>
               exit;
         end;
         exit when Last > 0;
      end loop;
      Ada.Text_IO.Close (F);
      if Last = 0 then
         return "";
      end if;
      declare
         Raw : constant String := Trim (Line2 (1 .. Last));
         Clean : String (1 .. Raw'Length);
         N   : Natural := 0;
      begin
         for I in Raw'Range loop
            if Raw (I) /= ' ' then
               N := N + 1;
               Clean (N) := Lower_Char (Raw (I));
            end if;
         end loop;
         return Clean (1 .. N);
      end;
   exception
      when others =>
         return "";
   end Sha256_Of;

   function To_Long (S : String; Ok : out Boolean) return Long_Long_Integer is
   begin
      Ok := True;
      return Long_Long_Integer'Value (Trim (S));
   exception
      when others =>
         Ok := False;
         return -1;
   end To_Long;

   procedure Ensure_Dir (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   exception
      when E : others =>
         Put_Line ("alb-pkg: cannot create dir " & Path & ": "
                   & Ada.Exceptions.Exception_Message (E));
   end Ensure_Dir;

   procedure Split_Words (S : String; List : out Pack_List; N : out Natural) is
      I : Natural := S'First;
      J : Natural;
   begin
      N := 0;
      while I <= S'Last loop
         while I <= S'Last and then (S (I) = ' ' or else S (I) = ','
                                     or else S (I) = ASCII.HT) loop
            I := I + 1;
         end loop;
         exit when I > S'Last;
         J := I;
         while J <= S'Last and then S (J) /= ' ' and then S (J) /= ','
           and then S (J) /= ASCII.HT
         loop
            J := J + 1;
         end loop;
         if N < Max_Packs and then J - I <= 64 and then J - I >= 1 then
            N := N + 1;
            List (N).Name (1 .. J - I) := S (I .. J - 1);
            List (N).Name_L := J - I;
         end if;
         I := J;
      end loop;
   end Split_Words;

   function PName (P : Pack_Rec) return String is
   begin
      return P.Name (1 .. P.Name_L);
   end PName;

   -- ---- state file: <root>/config/alb-pkg.ini ----
   State_Sections : constant := 8;
   State_Keys     : constant := 256;

   procedure Load_State (Root : String;
                         Cfg  : out State_INI.Config_Data;
                         Res  : out State_INI.Load_Result) is
   begin
      State_INI.Load_INI (Join (Root, "config\alb-pkg.ini"), Cfg, Res);
   end Load_State;

   procedure Save_State (Root : String; Index : String;
                         List : Pack_List; N : Natural) is
      F : Ada.Text_IO.File_Type;
   begin
      Ensure_Dir (Join (Root, "config"));
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File,
                          Join (Root, "config\alb-pkg.ini"));
      Ada.Text_IO.Put_Line (F, "[pkg]");
      Ada.Text_IO.Put_Line (F, "index=" & Index);
      Ada.Text_IO.Put_Line (F, "");
      Ada.Text_IO.Put_Line (F, "[installed]");
      for I in 1 .. N loop
         Ada.Text_IO.Put_Line (F, PName (List (I)) & "="
                               & List (I).Ver (1 .. List (I).Ver_L));
      end loop;
      for I in 1 .. N loop
         Ada.Text_IO.Put_Line (F, "");
         Ada.Text_IO.Put_Line (F, "[installed." & PName (List (I)) & "]");
         Ada.Text_IO.Put_Line (F, "version="
                               & List (I).Ver (1 .. List (I).Ver_L));
         if List (I).Dest_L in 1 .. 128 then
            Ada.Text_IO.Put_Line (F, "dest="
                                  & List (I).Dest (1 .. List (I).Dest_L));
         end if;
         if List (I).Paths_L in 1 .. 1024 then
            Ada.Text_IO.Put_Line (F, "paths="
                                  & List (I).Paths (1 .. List (I).Paths_L));
         end if;
      end loop;
      Ada.Text_IO.Close (F);
   exception
      when E : others =>
         Put_Line ("alb-pkg: cannot write state: "
                   & Ada.Exceptions.Exception_Message (E));
   end Save_State;

   procedure Read_Installed (Root  : String;
                             List  : out Pack_List;
                             N     : out Natural;
                             Index : out String;
                             Index_L : out Natural) is
      Cfg : State_INI.Config_Data;
      Res : State_INI.Load_Result;
      Tmp : Pack_List;
      Tn  : Natural := 0;
   begin
      N := 0;
      Index := (others => ' ');
      Index_L := 0;
      Load_State (Root, Cfg, Res);
      if Res /= State_INI.Success then
         return;
      end if;
      declare
         U : constant String := State_INI.Get_String (Cfg, "pkg", "index", "");
      begin
         if U'Length > 0 and then U'Length <= 512 then
            Index (1 .. U'Length) := U;
            Index_L := U'Length;
         end if;
      end;
      -- AyeNEye is read-only: re-list by probing known ids is wrong, so
      -- instead parse the [installed] section lines directly.
      declare
         F    : Ada.Text_IO.File_Type;
         Line : String (1 .. 1024);
         Last : Natural;
         Mode : Natural := 0;
         Sec_Id : String (1 .. 64) := (others => ' ');
         Sec_L  : Natural := 0;
      begin
         Ada.Text_IO.Open (F, Ada.Text_IO.In_File,
                           Join (Root, "config\alb-pkg.ini"));
         while not Ada.Text_IO.End_Of_File (F) loop
            Ada.Text_IO.Get_Line (F, Line, Last);
            declare
               T : constant String := Trim (Line (1 .. Last));
            begin
               if T'Length > 0 and then T (T'First) = '[' then
                  declare
                     H : constant String := Trim (T);
                  begin
                     Mode := 0;
                     Sec_L := 0;
                     if H = "[installed]" then
                        Mode := 1;
                     elsif H'Length > 13
                       and then H (H'First .. H'First + 10) = "[installed."
                       and then H (H'Last) = ']'
                     then
                        declare
                           Nm : constant String :=
                             H (H'First + 11 .. H'Last - 1);
                        begin
                           if Nm'Length in 1 .. 64 then
                              Sec_Id (1 .. Nm'Length) := Nm;
                              Sec_L := Nm'Length;
                              Mode := 2;
                           end if;
                        end;
                     end if;
                  end;
               elsif Mode in 1 .. 2 and then T'Length > 0
                 and then T (T'First) /= ';' and then T (T'First) /= '#'
               then
                  for K in T'Range loop
                     if T (K) = '=' then
                        declare
                           Nm : constant String := Trim (T (T'First .. K - 1));
                           Vl : String (1 .. 1024) := (others => ' ');
                           Vl_L : Natural := 0;
                        begin
                           if K < T'Last then
                              declare
                                 Vv : constant String :=
                                   Trim (T (K + 1 .. T'Last));
                              begin
                                 if Vv'Length <= 1024 then
                                    Vl (1 .. Vv'Length) := Vv;
                                    Vl_L := Vv'Length;
                                 end if;
                              end;
                           end if;
                           if Mode = 1 then
                              if Nm'Length in 1 .. 64 and then Vl_L in 1 .. 32
                                and then Tn < Max_Packs
                              then
                                 Tn := Tn + 1;
                                 Tmp (Tn).Name (1 .. Nm'Length) := Nm;
                                 Tmp (Tn).Name_L := Nm'Length;
                                 Tmp (Tn).Ver (1 .. Vl_L) := Vl (1 .. Vl_L);
                                 Tmp (Tn).Ver_L := Vl_L;
                              end if;
                           else
                              declare
                                 Slot : Natural := 0;
                              begin
                                 for Q in 1 .. Tn loop
                                    if Tmp (Q).Name_L = Sec_L
                                      and then Tmp (Q).Name (1 .. Sec_L)
                                               = Sec_Id (1 .. Sec_L)
                                    then
                                       Slot := Q;
                                       exit;
                                    end if;
                                 end loop;
                                 if Slot = 0 and then Tn < Max_Packs then
                                    Tn := Tn + 1;
                                    Slot := Tn;
                                    Tmp (Slot).Name (1 .. Sec_L) :=
                                      Sec_Id (1 .. Sec_L);
                                    Tmp (Slot).Name_L := Sec_L;
                                 end if;
                                 if Slot > 0 then
                                    if Nm = "version" and then Vl_L in 1 .. 32 then
                                       Tmp (Slot).Ver (1 .. Vl_L) :=
                                         Vl (1 .. Vl_L);
                                       Tmp (Slot).Ver_L := Vl_L;
                                    elsif Nm = "dest" and then Vl_L <= 128 then
                                       if Vl_L > 0 then
                                          Tmp (Slot).Dest (1 .. Vl_L) :=
                                            Vl (1 .. Vl_L);
                                       end if;
                                       Tmp (Slot).Dest_L := Vl_L;
                                    elsif Nm = "paths" and then Vl_L <= 1024 then
                                       if Vl_L > 0 then
                                          Tmp (Slot).Paths (1 .. Vl_L) :=
                                            Vl (1 .. Vl_L);
                                       end if;
                                       Tmp (Slot).Paths_L := Vl_L;
                                    end if;
                                 end if;
                              end;
                           end if;
                        end;
                        exit;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (F);
      exception
         when others =>
            null;
      end;
      List := Tmp;
      N := Tn;
   end Read_Installed;

   function Find_Pack (List : Pack_List; N : Natural;
                       Id : String) return Natural is
   begin
      for I in 1 .. N loop
         if PName (List (I)) = Id then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Pack;

   procedure Set_Pack (List : in out Pack_List; N : in out Natural;
                       Id : String; Ver : String) is
      Slot : constant Natural := Find_Pack (List, N, Id);
   begin
      if Slot > 0 then
         List (Slot).Ver (1 .. Ver'Length) := Ver;
         List (Slot).Ver_L := Ver'Length;
      elsif N < Max_Packs and then Id'Length in 1 .. 64
        and then Ver'Length in 1 .. 32
      then
         N := N + 1;
         List (N).Name (1 .. Id'Length) := Id;
         List (N).Name_L := Id'Length;
         List (N).Ver (1 .. Ver'Length) := Ver;
         List (N).Ver_L := Ver'Length;
      end if;
   end Set_Pack;

   procedure Drop_Pack (List : in out Pack_List; N : in out Natural;
                        Id : String) is
      Slot : constant Natural := Find_Pack (List, N, Id);
   begin
      if Slot = 0 then
         return;
      end if;
      for I in Slot .. N - 1 loop
         List (I) := List (I + 1);
      end loop;
      N := N - 1;
   end Drop_Pack;

   -- ---- index fetch ----
   procedure Fetch_Index (URL : String; Root : String;
                          Cfg : out Idx_INI.Config_Data;
                          Ok  : out Boolean) is
      Tmp : constant String := Join (Root, "tmp\alb-pkg-index.ini");
      Res : Idx_INI.Load_Result;
   begin
      Ok := False;
      Ensure_Dir (Join (Root, "tmp"));
      if not Download (URL, Tmp) then
         Put_Line ("alb-pkg: cannot download index: " & URL);
         Put_Line ("alb-pkg: set ALB_PKG_INDEX to a reachable index.ini");
         return;
      end if;
      Idx_INI.Load_INI (Tmp, Cfg, Res);
      if Res /= Idx_INI.Success then
         Put_Line ("alb-pkg: index did not parse: " & URL);
         return;
      end if;
      Ok := True;
   end Fetch_Index;

   function Pack_Field (Cfg : Idx_INI.Config_Data; Id : String;
                        Key : String) return String is
   begin
      if Id = "self" then
         return Idx_INI.Get_String (Cfg, "self", Key, "");
      end if;
      return Idx_INI.Get_String (Cfg, Pack_Section (Id), Key, "");
   end Pack_Field;

   procedure Delete_Tree (Path : String) is
      use type Ada.Directories.File_Kind;
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;
      if Ada.Directories.Kind (Path) = Ada.Directories.Directory then
         declare
            S : Ada.Directories.Search_Type;
            E : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Start_Search (S, Path, "*");
            while Ada.Directories.More_Entries (S) loop
               Ada.Directories.Get_Next_Entry (S, E);
               declare
                  Nm : constant String :=
                    Ada.Directories.Simple_Name (E);
               begin
                  if Nm /= "." and then Nm /= ".." then
                     Delete_Tree (Ada.Directories.Compose
                                    (Path, Nm));
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (S);
         exception
            when others =>
               null;
         end;
         begin
            Ada.Directories.Delete_Directory (Path);
         exception
            when others =>
               Put_Line ("alb-pkg: warning: cannot remove dir " & Path);
         end;
      else
         begin
            Ada.Directories.Delete_File (Path);
         exception
            when others =>
               Put_Line ("alb-pkg: warning: cannot remove file " & Path);
         end;
      end if;
   end Delete_Tree;

   -- ---- install pipeline: collect -> fetch+verify all -> extract all ----
   -- every payload lands in tmp\dl-<id>.zip first; nothing is unpacked
   -- until the whole set has been downloaded and hash-verified.

   function Leaf_Zip (Root : String; Id : String) return String is
     (Join (Root, "tmp\dl-" & Id & ".zip"));

   function Human_Size (N : Long_Long_Integer) return String is
      function Img (V : Long_Long_Integer) return String is
        (Trim (Long_Long_Integer'Image (V)));
   begin
      if N >= 1_073_741_824 then
         return Img ((N + 536_870_911) / 1_073_741_824) & " GB";
      elsif N >= 1_048_576 then
         return Img ((N + 524_287) / 1_048_576) & " MB";
      elsif N >= 1_024 then
         return Img ((N + 511) / 1_024) & " KB";
      else
         return Img (N) & " B";
      end if;
   end Human_Size;

   -- resolve meta-pack members into leaf ids; dedupe; skip up-to-date.
   procedure Collect_Pack (Id : String; Cfg : Idx_INI.Config_Data;
                           List : Pack_List; N : Natural;
                           Wanted : in out Pack_List; Wanted_N : in out Natural;
                           Depth : Natural; Ok : in out Boolean) is
      Members : constant String := Pack_Field (Cfg, Id, "members");
      Ver     : constant String := Pack_Field (Cfg, Id, "version");
      File    : constant String := Pack_Field (Cfg, Id, "file");
      Sha     : constant String := Pack_Field (Cfg, Id, "sha256");
      Sub     : Pack_List;
      Sub_N   : Natural := 0;
   begin
      if Depth > 4 then
         Put_Line ("alb-pkg: pack nesting too deep at " & Id);
         Ok := False;
         return;
      end if;
      if Members'Length > 0 then
         Split_Words (Members, Sub, Sub_N);
         for I in 1 .. Sub_N loop
            Collect_Pack (PName (Sub (I)), Cfg, List, N, Wanted, Wanted_N,
                          Depth + 1, Ok);
         end loop;
         return;
      end if;
      if Ver'Length = 0 or else File'Length = 0 or else Sha'Length = 0 then
         Put_Line ("alb-pkg: pack not in index: " & Id);
         Ok := False;
         return;
      end if;
      declare
         Slot : constant Natural := Find_Pack (List, N, Id);
      begin
         if Slot > 0
           and then List (Slot).Ver (1 .. List (Slot).Ver_L) = Ver
         then
            Put_Line ("alb-pkg: " & Id & " already at " & Ver);
            return;
         end if;
      end;
      for I in 1 .. Wanted_N loop
         if PName (Wanted (I)) = Id then
            return;
         end if;
      end loop;
      if Wanted_N < Max_Packs and then Id'Length in 1 .. 64 then
         Wanted_N := Wanted_N + 1;
         Wanted (Wanted_N).Name (1 .. Id'Length) := Id;
         Wanted (Wanted_N).Name_L := Id'Length;
      else
         Put_Line ("alb-pkg: pack list full or id too long: " & Id);
         Ok := False;
      end if;
   end Collect_Pack;

   -- phase 1: download one leaf pack to its tmp slot and verify size+sha256.
   function Fetch_Pack (Id : String; Cfg : Idx_INI.Config_Data;
                        Root : String; Base : String;
                        Num : Natural; Total : Natural) return Boolean is
      Ver   : constant String := Pack_Field (Cfg, Id, "version");
      File  : constant String := Pack_Field (Cfg, Id, "file");
      Sha   : constant String := Pack_Field (Cfg, Id, "sha256");
      SizeS : constant String := Pack_Field (Cfg, Id, "size");
      Tmp   : constant String := Leaf_Zip (Root, Id);
      Ok_Size : Boolean;
      Want    : Long_Long_Integer;
      Have    : Long_Long_Integer;
      Got     : String (1 .. 64) := (others => ' ');
      Got_L   : Natural := 0;
      Tag     : constant String :=
        "[" & Trim (Natural'Image (Num)) & "/"
        & Trim (Natural'Image (Total)) & "] " & Id;
   begin
      Want := To_Long (SizeS, Ok_Size);
      if Ok_Size and then Want > 0 then
         Put_Line ("alb-pkg: " & Tag & " v" & Ver
                   & " - downloading " & Human_Size (Want) & " ...");
      else
         Put_Line ("alb-pkg: " & Tag & " v" & Ver & " - downloading ...");
      end if;
      Ensure_Dir (Join (Root, "tmp"));
      if Ada.Directories.Exists (Tmp) then
         begin
            Ada.Directories.Delete_File (Tmp);
         exception
            when others => null;
         end;
      end if;
      if not Download (Base & File, Tmp) then
         Put_Line ("alb-pkg: " & Tag & " download failed: " & Base & File);
         return False;
      end if;
      if Ok_Size and then Want > 0 then
         Have := File_Size (Tmp);
         if Have /= Want then
            Put_Line ("alb-pkg: " & Tag & " size mismatch, want"
                      & Long_Long_Integer'Image (Want) & " got"
                      & Long_Long_Integer'Image (Have));
            return False;
         end if;
      end if;
      declare
         H : constant String := Sha256_Of (Tmp, Root);
      begin
         if H'Length > 64 then
            Put_Line ("alb-pkg: " & Tag & " hash backend failed");
            return False;
         end if;
         Got (1 .. H'Length) := H;
         Got_L := H'Length;
      end;
      if Got_L = 0
        or else Lower_Str (Got (1 .. Got_L)) /= Lower_Str (Trim (Sha))
      then
         Put_Line ("alb-pkg: " & Tag & " SHA256 MISMATCH, refusing install");
         return False;
      end if;
      Put_Line ("alb-pkg: " & Tag & " verified ok");
      return True;
   end Fetch_Pack;

   -- phase 2: extract an already-verified tmp zip into dest, record state.
   function Unpack_Pack (Id : String; Cfg : Idx_INI.Config_Data;
                         Root : String;
                         List : in out Pack_List; N : in out Natural;
                         Num : Natural; Total : Natural) return Boolean is
      Ver   : constant String := Pack_Field (Cfg, Id, "version");
      Dest  : constant String := Pack_Field (Cfg, Id, "dest");
      Tmp   : constant String := Leaf_Zip (Root, Id);
      Tag   : constant String :=
        "[" & Trim (Natural'Image (Num)) & "/"
        & Trim (Natural'Image (Total)) & "] " & Id;
   begin
      if not Is_Safe_Rel (Dest) then
         Put_Line ("alb-pkg: " & Tag & " unsafe dest, refusing");
         return False;
      end if;
      declare
         Dst_Dir : constant String :=
           (if Dest = "" or else Dest = "." then Root else Join (Root, Dest));
         Tar : constant String := Find_Tool ("tar.exe");
         Code : Integer;
      begin
         Put_Line ("alb-pkg: " & Tag & " unpacking to " & Dst_Dir & " ...");
         Ensure_Dir (Dst_Dir);
         Code := Run (Tar, "-xf", Tmp, "-C", Dst_Dir);
         if Code /= 0 then
            Put_Line ("alb-pkg: " & Tag & " trying powershell extractor ...");
            Code := Run ("powershell.exe", "-NoProfile", "-Command",
                         "Expand-Archive -Force '" & Tmp & "' '" & Dst_Dir & "'");
            if Code /= 0 then
               Put_Line ("alb-pkg: " & Tag & " extraction failed");
               return False;
            end if;
         end if;
      end;
      begin
         Ada.Directories.Delete_File (Tmp);
      exception
         when others => null;
      end;
      Set_Pack (List, N, Id, Ver);
      declare
         Slot : constant Natural := Find_Pack (List, N, Id);
         Dd : constant String := Pack_Field (Cfg, Id, "dest");
         Pp : constant String := Pack_Field (Cfg, Id, "paths");
      begin
         if Slot > 0 then
            if Dd'Length in 1 .. 128 then
               List (Slot).Dest (1 .. Dd'Length) := Dd;
               List (Slot).Dest_L := Dd'Length;
            end if;
            if Pp'Length in 1 .. 1024 then
               List (Slot).Paths (1 .. Pp'Length) := Pp;
               List (Slot).Paths_L := Pp'Length;
            end if;
         end if;
      end;
      Put_Line ("alb-pkg: " & Tag & " installed v" & Ver);
      return True;
   end Unpack_Pack;

   -- full pipeline for a set of requested ids (meta-packs expand).
   -- fetch+verify everything first; only then unpack, so a bad download
   -- can never leave a half-installed set behind.
   procedure Install_Resolved (Roots : Pack_List; Roots_N : Natural;
                               Cfg : Idx_INI.Config_Data;
                               Root : String; Base : String;
                               List : in out Pack_List; N : in out Natural;
                               All_Ok : in out Boolean) is
      Wanted   : Pack_List;
      Wanted_N : Natural := 0;
      Cok      : Boolean := True;
      Total_B  : Long_Long_Integer := 0;
   begin
      for K in 1 .. Roots_N loop
         Collect_Pack (PName (Roots (K)), Cfg, List, N, Wanted, Wanted_N, 0, Cok);
      end loop;
      if not Cok then
         All_Ok := False;
         return;
      end if;
      if Wanted_N = 0 then
         Put_Line ("alb-pkg: nothing to do");
         return;
      end if;
      declare
         Ok_Size : Boolean;
      begin
         for K in 1 .. Wanted_N loop
            declare
               Sz : constant Long_Long_Integer :=
                 To_Long (Pack_Field (Cfg, PName (Wanted (K)), "size"), Ok_Size);
            begin
               if Ok_Size and then Sz > 0 then
                  Total_B := Total_B + Sz;
               end if;
            end;
         end loop;
      end;
      Put_Line ("alb-pkg: stage 1/2 - downloading "
                & Trim (Natural'Image (Wanted_N)) & " pack(s), "
                & Human_Size (Total_B) & " total");
      for K in 1 .. Wanted_N loop
         if not Fetch_Pack (PName (Wanted (K)), Cfg, Root, Base,
                            K, Wanted_N)
         then
            Put_Line ("alb-pkg: aborting - nothing was unpacked");
            for J in 1 .. Wanted_N loop
               declare
                  Z : constant String := Leaf_Zip (Root, PName (Wanted (J)));
               begin
                  if Ada.Directories.Exists (Z) then
                     Ada.Directories.Delete_File (Z);
                  end if;
               exception
                  when others => null;
               end;
            end loop;
            All_Ok := False;
            return;
         end if;
      end loop;
      Put_Line ("alb-pkg: stage 2/2 - all verified, unpacking "
                & Trim (Natural'Image (Wanted_N)) & " pack(s)");
      for K in 1 .. Wanted_N loop
         if not Unpack_Pack (PName (Wanted (K)), Cfg, Root, List, N,
                             K, Wanted_N)
         then
            All_Ok := False;
         end if;
      end loop;
      Save_State (Root, Index_URL, List, N);
      if All_Ok then
         Put_Line ("alb-pkg: done - "
                   & Trim (Natural'Image (Wanted_N)) & " pack(s) installed");
      end if;
   end Install_Resolved;

   function Install_Pack (Id : String; Cfg : Idx_INI.Config_Data;
                          Root : String; Base : String;
                          List : in out Pack_List; N : in out Natural;
                          Depth : Natural) return Boolean
   is
      pragma Unreferenced (Depth);
      Roots   : Pack_List;
      Roots_N : Natural := 0;
      All_Ok  : Boolean := True;
   begin
      if Id'Length in 1 .. 64 then
         Roots_N := 1;
         Roots (1).Name (1 .. Id'Length) := Id;
         Roots (1).Name_L := Id'Length;
      end if;
      Install_Resolved (Roots, Roots_N, Cfg, Root, Base, List, N, All_Ok);
      return All_Ok;
   end Install_Pack;

   procedure Cmd_Install (Root : String; First : Positive) is
      Cfg : Idx_INI.Config_Data;
      Ok  : Boolean;
      List : Pack_List;
      N    : Natural;
      Dummy_I : String (1 .. 512) := (others => ' ');
      Dummy_L : Natural := 0;
      Base : constant String := Index_Base (Index_URL);
      Count : constant Natural := Ada.Command_Line.Argument_Count;
      All_Ok : Boolean := True;
      Proj : String (1 .. 512) := (others => ' ');
      Proj_L : Natural := 0;
      I : Positive := First;
   begin
      while I <= Count loop
         declare
            A : constant String := Ada.Command_Line.Argument (I);
         begin
            if A = "--project" and then I < Count then
               declare
                  P : constant String := Ada.Command_Line.Argument (I + 1);
               begin
                  if P'Length <= 512 then
                     Proj (1 .. P'Length) := P;
                     Proj_L := P'Length;
                  end if;
               end;
               I := I + 2;
            else
               exit;
            end if;
         end;
      end loop;
      Fetch_Index (Index_URL, Root, Cfg, Ok);
      if not Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      Read_Installed (Root, List, N, Dummy_I, Dummy_L);
      if Proj_L > 0 then
         declare
            Pcfg : Idx_INI.Config_Data;
            Pres : Idx_INI.Load_Result;
            Need : Pack_List;
            Need_N : Natural := 0;
            Tmp  : Pack_List;
            Tmp_N : Natural := 0;
         begin
            Idx_INI.Load_INI (Proj (1 .. Proj_L), Pcfg, Pres);
            if Pres /= Idx_INI.Success then
               Fail ("cannot read project file " & Proj (1 .. Proj_L));
               return;
            end if;
            Split_Words (Idx_INI.Get_String (Pcfg, "toolchains", "require", ""), Tmp, Tmp_N);
            for K in 1 .. Tmp_N loop
               if Need_N < Max_Packs then
                  Need_N := Need_N + 1;
                  Need (Need_N) := Tmp (K);
               end if;
            end loop;
            Split_Words (Idx_INI.Get_String (Pcfg, "packs", "require", ""), Tmp, Tmp_N);
            for K in 1 .. Tmp_N loop
               if Need_N < Max_Packs then
                  Need_N := Need_N + 1;
                  Need (Need_N) := Tmp (K);
               end if;
            end loop;
            if Need_N = 0 then
               Put_Line ("alb-pkg: project lists no packs");
               return;
            end if;
            Install_Resolved (Need, Need_N, Cfg, Root, Base, List, N, All_Ok);
            declare
               Lock_Dir : String (1 .. 512) := (others => ' ');
               Lock_L   : Natural := 0;
               LF       : Ada.Text_IO.File_Type;
               Seen     : Pack_List;
               Seen_N   : Natural := 0;
               procedure Lock_Emit (Pid : String) is
                  Hit : Natural := Find_Pack (List, N, Pid);
               begin
                  if Hit = 0 or else List (Hit).Ver_L = 0 then
                     return;
                  end if;
                  for Q in 1 .. Seen_N loop
                     if PName (Seen (Q)) = Pid then
                        return;
                     end if;
                  end loop;
                  if Seen_N < Max_Packs and then Pid'Length in 1 .. 64 then
                     Seen_N := Seen_N + 1;
                     Seen (Seen_N).Name (1 .. Pid'Length) := Pid;
                     Seen (Seen_N).Name_L := Pid'Length;
                  end if;
                  Ada.Text_IO.Put_Line
                    (LF, Pid & "="
                     & List (Hit).Ver (1 .. List (Hit).Ver_L));
               end Lock_Emit;
            begin
               begin
                  declare
                     Cd : constant String :=
                       Ada.Directories.Containing_Directory
                         (Proj (1 .. Proj_L));
                  begin
                     if Cd'Length in 1 .. 512 then
                        Lock_Dir (1 .. Cd'Length) := Cd;
                        Lock_L := Cd'Length;
                     end if;
                  end;
               exception
                  when others =>
                     null;
               end;
               Ada.Text_IO.Create
                 (LF, Ada.Text_IO.Out_File,
                  (if Lock_L > 0
                   then Ada.Directories.Compose
                     (Lock_Dir (1 .. Lock_L), "alb-pkg.lock")
                   else "alb-pkg.lock"));
               Ada.Text_IO.Put_Line
                 (LF, "# Generated by alb-pkg install --project "
                  & Proj (1 .. Proj_L));
               Ada.Text_IO.Put_Line (LF, "# Do not edit by hand.");
               Ada.Text_IO.Put_Line (LF, "[packs]");
               for K in 1 .. Need_N loop
                  declare
                     Pid : constant String := PName (Need (K));
                     Mem : constant String :=
                       Pack_Field (Cfg, Pid, "members");
                  begin
                     if Mem'Length > 0 then
                        declare
                           Sub2 : Pack_List;
                           Sub2_N : Natural := 0;
                        begin
                           Split_Words (Mem, Sub2, Sub2_N);
                           for J in 1 .. Sub2_N loop
                              Lock_Emit (PName (Sub2 (J)));
                           end loop;
                        end;
                     else
                        Lock_Emit (Pid);
                     end if;
                  end;
               end loop;
               Ada.Text_IO.Close (LF);
               Put_Line ("alb-pkg: wrote lockfile alb-pkg.lock");
            exception
               when E : others =>
                  Put_Line ("alb-pkg: warning: lockfile not written: "
                            & Ada.Exceptions.Exception_Message (E));
            end;
         end;
       else
         if I > Count then
            Print_Help;
            return;
         end if;
         declare
            Roots   : Pack_List;
            Roots_N : Natural := 0;
         begin
            while I <= Count loop
               declare
                  Arg : constant String := Ada.Command_Line.Argument (I);
                  Id  : constant String :=
                    (if Lower_Str (Arg) = "all" then "full" else Arg);
               begin
                  if Roots_N < Max_Packs and then Id'Length in 1 .. 64 then
                     Roots_N := Roots_N + 1;
                     Roots (Roots_N).Name (1 .. Id'Length) := Id;
                     Roots (Roots_N).Name_L := Id'Length;
                  end if;
               end;
               I := I + 1;
            end loop;
            Install_Resolved (Roots, Roots_N, Cfg, Root, Base, List, N,
                              All_Ok);
         end;
      end if;
      if not All_Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end Cmd_Install;

   procedure Cmd_Update (Root : String; First : Positive) is
      Cfg : Idx_INI.Config_Data;
      Ok  : Boolean;
      List : Pack_List;
      N    : Natural;
      Dummy_I : String (1 .. 512) := (others => ' ');
      Dummy_L : Natural := 0;
      Base : constant String := Index_Base (Index_URL);
      Count : constant Natural := Ada.Command_Line.Argument_Count;
      All_Ok : Boolean := True;
      Roots   : Pack_List;
      Roots_N : Natural := 0;
      procedure Refresh (Id : String) is
         Slot : Natural;
      begin
         Slot := Find_Pack (List, N, Id);
         if Slot > 0 then
            Drop_Pack (List, N, Id);
         end if;
         if Roots_N < Max_Packs and then Id'Length in 1 .. 64 then
            Roots_N := Roots_N + 1;
            Roots (Roots_N).Name (1 .. Id'Length) := Id;
            Roots (Roots_N).Name_L := Id'Length;
         end if;
      end Refresh;
   begin
      Fetch_Index (Index_URL, Root, Cfg, Ok);
      if not Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      Read_Installed (Root, List, N, Dummy_I, Dummy_L);
      if First > Count then
         Put_Line ("alb-pkg: update what? try: update all");
         return;
      end if;
      declare
         What : constant String := Ada.Command_Line.Argument (First);
      begin
         if What = "all" then
            declare
               Snap : Pack_List := List;
               Snap_N : Natural := N;
            begin
               for I in 1 .. Snap_N loop
                  Refresh (PName (Snap (I)));
               end loop;
            end;
         else
            Refresh (What);
         end if;
      end;
      Install_Resolved (Roots, Roots_N, Cfg, Root, Base, List, N, All_Ok);
      if not All_Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end Cmd_Update;

   procedure Cmd_Remove (Root : String; First : Positive) is
      Cfg : Idx_INI.Config_Data;
      Ok  : Boolean;
      List : Pack_List;
      N    : Natural;
      Dummy_I : String (1 .. 512) := (others => ' ');
      Dummy_L : Natural := 0;
      Count : constant Natural := Ada.Command_Line.Argument_Count;
   begin
      if First > Count then
         Print_Help;
         return;
      end if;
      Fetch_Index (Index_URL, Root, Cfg, Ok);
      if not Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      Read_Installed (Root, List, N, Dummy_I, Dummy_L);
      for I in First .. Count loop
         declare
            Id : constant String := Ada.Command_Line.Argument (I);
            Slot : constant Natural := Find_Pack (List, N, Id);
            Ix_D : constant String := Pack_Field (Cfg, Id, "dest");
            Ix_P : constant String := Pack_Field (Cfg, Id, "paths");
            Dest : String (1 .. 128) := (others => ' ');
            Dest_L : Natural := 0;
            Paths : String (1 .. 1024) := (others => ' ');
            Paths_L : Natural := 0;
            Sub : Pack_List;
            Sub_N : Natural := 0;
         begin
            if Slot = 0 then
               Put_Line ("alb-pkg: not installed: " & Id);
            else
               if List (Slot).Dest_L in 1 .. 128 then
                  Dest (1 .. List (Slot).Dest_L) :=
                    List (Slot).Dest (1 .. List (Slot).Dest_L);
                  Dest_L := List (Slot).Dest_L;
               elsif Ix_D'Length in 1 .. 128 then
                  Dest (1 .. Ix_D'Length) := Ix_D;
                  Dest_L := Ix_D'Length;
               end if;
               if List (Slot).Paths_L in 1 .. 1024 then
                  Paths (1 .. List (Slot).Paths_L) :=
                    List (Slot).Paths (1 .. List (Slot).Paths_L);
                  Paths_L := List (Slot).Paths_L;
               elsif Ix_P'Length in 1 .. 1024 then
                  Paths (1 .. Ix_P'Length) := Ix_P;
                  Paths_L := Ix_P'Length;
               end if;
               declare
                  Base_Dir : constant String :=
                    (if Dest_L = 0 or else Dest (1 .. Dest_L) = "." then Root
                     else Join (Root, Dest (1 .. Dest_L)));
               begin
               Split_Words (Paths (1 .. Paths_L), Sub, Sub_N);
               for K in 1 .. Sub_N loop
                  declare
                     Rel : constant String := PName (Sub (K));
                  begin
                     if Is_Safe_Rel (Rel) then
                        Delete_Tree (Join (Base_Dir, Rel));
                     else
                        Put_Line ("alb-pkg: refusing unsafe path " & Rel);
                     end if;
                  end;
               end loop;
               Drop_Pack (List, N, Id);
               Save_State (Root, Index_URL, List, N);
               Put_Line ("alb-pkg: removed " & Id);
               end;
            end if;
         end;
      end loop;
   end Cmd_Remove;

   procedure Cmd_List (Root : String) is
      List : Pack_List;
      N    : Natural;
      Idx  : String (1 .. 512) := (others => ' ');
      Idx_L : Natural := 0;
   begin
      Read_Installed (Root, List, N, Idx, Idx_L);
      Put_Line ("alb-pkg " & Tool_Version & "  index: " & Index_URL);
      if N = 0 then
         Put_Line ("(nothing installed)");
         return;
      end if;
      for I in 1 .. N loop
         Put_Line ("  " & PName (List (I)) & "  "
                   & List (I).Ver (1 .. List (I).Ver_L));
      end loop;
   end Cmd_List;

   procedure Cmd_Packs (Root : String) is
      Cfg : Idx_INI.Config_Data;
      Ok  : Boolean;
      List : Pack_List;
      N    : Natural;
      Dummy_I : String (1 .. 512) := (others => ' ');
      Dummy_L : Natural := 0;
   begin
      Fetch_Index (Index_URL, Root, Cfg, Ok);
      if not Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      Read_Installed (Root, List, N, Dummy_I, Dummy_L);
      Put_Line ("alb-pkg " & Tool_Version & "  index: " & Index_URL);
      -- AyeNEye cannot enumerate sections; scan the fetched index.ini
      -- for [pack:<id>] headers the way Read_Installed scans state.
      declare
         F    : Ada.Text_IO.File_Type;
         Line : String (1 .. 1024);
         Last : Natural;
         Any  : Boolean := False;
      begin
         Ada.Text_IO.Open (F, Ada.Text_IO.In_File,
                           Join (Root, "tmp\alb-pkg-index.ini"));
         while not Ada.Text_IO.End_Of_File (F) loop
            Ada.Text_IO.Get_Line (F, Line, Last);
            declare
               T : constant String := Trim (Line (1 .. Last));
            begin
               if T'Length > 7
                 and then T (T'First .. T'First + 5) = "[pack:"
                 and then T (T'Last) = ']'
               then
                  declare
                     Nm   : constant String := T (T'First + 6 .. T'Last - 1);
                     V    : constant String := Pack_Field (Cfg, Nm, "version");
                     D    : constant String :=
                       Pack_Field (Cfg, Nm, "description");
                     Slot : constant Natural := Find_Pack (List, N, Nm);
                  begin
                     if Nm'Length in 1 .. 64 then
                        Any := True;
                        if Slot > 0 then
                           Put_Line ("  " & Nm & "  " & V
                                     & "  [installed]  " & D);
                        else
                           Put_Line ("  " & Nm & "  " & V & "  " & D);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (F);
         if not Any then
            Put_Line ("(no packs in index)");
         end if;
      end;
   end Cmd_Packs;

   procedure Cmd_Doctor (Root : String) is
      Cfg : Idx_INI.Config_Data;
      Ok  : Boolean;
      List : Pack_List;
      N    : Natural;
      Dummy_I : String (1 .. 512) := (others => ' ');
      Dummy_L : Natural := 0;
      Bad : Natural := 0;
   begin
      Put_Line ("alb-pkg doctor  sdk=" & Root);
      declare
         T1 : constant String := Find_Tool ("curl.exe");
         T2 : constant String := Find_Tool ("tar.exe");
         T3 : constant String := Find_Tool ("certutil.exe");
      begin
         if T1'Length = 0 or else not Ada.Directories.Exists (T1) then
            Put_Line ("  MISSING tool: curl.exe");
            Bad := Bad + 1;
         else
            Put_Line ("  tool ok: " & T1);
         end if;
         if T2'Length = 0 or else not Ada.Directories.Exists (T2) then
            Put_Line ("  MISSING tool: tar.exe");
            Bad := Bad + 1;
         else
            Put_Line ("  tool ok: " & T2);
         end if;
         if T3'Length = 0 or else not Ada.Directories.Exists (T3) then
            Put_Line ("  MISSING tool: certutil.exe");
            Bad := Bad + 1;
         else
            Put_Line ("  tool ok: " & T3);
         end if;
      end;
      Fetch_Index (Index_URL, Root, Cfg, Ok);
      if not Ok then
         Put_Line ("  index UNREACHABLE (offline?)");
      else
         Put_Line ("  index ok");
      end if;
      Read_Installed (Root, List, N, Dummy_I, Dummy_L);
      for I in 1 .. N loop
         declare
            Id : constant String := PName (List (I));
            Ix_D : constant String := Pack_Field (Cfg, Id, "dest");
            Ix_P : constant String := Pack_Field (Cfg, Id, "paths");
            Dest : String (1 .. 128) := (others => ' ');
            Dest_L : Natural := 0;
            Paths : String (1 .. 1024) := (others => ' ');
            Paths_L : Natural := 0;
            Sub : Pack_List;
            Sub_N : Natural := 0;
         begin
            if List (I).Dest_L in 1 .. 128 then
               Dest (1 .. List (I).Dest_L) :=
                 List (I).Dest (1 .. List (I).Dest_L);
               Dest_L := List (I).Dest_L;
            elsif Ix_D'Length in 1 .. 128 then
               Dest (1 .. Ix_D'Length) := Ix_D;
               Dest_L := Ix_D'Length;
            end if;
            if List (I).Paths_L in 1 .. 1024 then
               Paths (1 .. List (I).Paths_L) :=
                 List (I).Paths (1 .. List (I).Paths_L);
               Paths_L := List (I).Paths_L;
            elsif Ix_P'Length in 1 .. 1024 then
               Paths (1 .. Ix_P'Length) := Ix_P;
               Paths_L := Ix_P'Length;
            end if;
            declare
               Base_Dir : constant String :=
                 (if Dest_L = 0 or else Dest (1 .. Dest_L) = "." then Root
                  else Join (Root, Dest (1 .. Dest_L)));
               Miss : Natural := 0;
            begin
            Split_Words (Paths (1 .. Paths_L), Sub, Sub_N);
            for K in 1 .. Sub_N loop
               if not Ada.Directories.Exists
                 (Join (Base_Dir, PName (Sub (K))))
               then
                  Miss := Miss + 1;
               end if;
            end loop;
            if Miss = 0 then
               Put_Line ("  pack ok: " & Id);
            else
               Put_Line ("  pack BROKEN: " & Id);
               Bad := Bad + 1;
            end if;
            end;
         end;
      end loop;
      if Bad > 0 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      else
         Put_Line ("  all good");
      end if;
   end Cmd_Doctor;

   procedure Cmd_Self_Update (Root : String) is
      Cfg : Idx_INI.Config_Data;
      Ok  : Boolean;
      Base : constant String := Index_Base (Index_URL);
      Exe  : constant String := Join (Join (Root, "bin"), "alb-pkg.exe");
      New_Exe : constant String := Join (Join (Root, "bin"), "alb-pkg.new.exe");
      Bat  : constant String := Join (Join (Root, "bin"), "alb-pkg-swap.bat");
      F    : Ada.Text_IO.File_Type;
      File : String (1 .. 512) := (others => ' ');
      File_L : Natural := 0;
      Sha  : String (1 .. 128) := (others => ' ');
      Sha_L : Natural := 0;
      Ver  : String (1 .. 32) := (others => ' ');
      Ver_L : Natural := 0;
   begin
      Fetch_Index (Index_URL, Root, Cfg, Ok);
      if not Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      declare
         Ff : constant String := Pack_Field (Cfg, "self", "file");
         Ss : constant String := Pack_Field (Cfg, "self", "sha256");
         Vv : constant String := Pack_Field (Cfg, "self", "version");
      begin
         if Ff'Length in 1 .. 512 then
            File (1 .. Ff'Length) := Ff;
            File_L := Ff'Length;
         end if;
         if Ss'Length in 1 .. 128 then
            Sha (1 .. Ss'Length) := Ss;
            Sha_L := Ss'Length;
         end if;
         if Vv'Length in 1 .. 32 then
            Ver (1 .. Vv'Length) := Vv;
            Ver_L := Vv'Length;
         end if;
      end;
      if File_L = 0 or else Sha_L = 0 then
         Put_Line ("alb-pkg: no [self] entry in index");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      Put_Line ("alb-pkg: self-update to " & Ver (1 .. Ver_L) & " ...");
      Ensure_Dir (Join (Root, "tmp"));
      Ensure_Dir (Join (Root, "bin"));
      if not Download (Base & File (1 .. File_L), New_Exe) then
         Fail ("download failed");
         return;
      end if;
      declare
         H : constant String := Sha256_Of (New_Exe, Root);
      begin
         if H'Length = 0
           or else Lower_Str (H) /= Lower_Str (Trim (Sha))
         then
            Put_Line ("alb-pkg: SHA256 MISMATCH, keeping current exe");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;
      end;
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Bat);
      Ada.Text_IO.Put_Line (F, "@echo off");
      Ada.Text_IO.Put_Line (F, "ping -n 3 127.0.0.1 >nul");
      Ada.Text_IO.Put_Line (F, "move /y """ & New_Exe & """ """ & Exe & """");
      Ada.Text_IO.Put_Line (F, "del """ & Bat & """");
      Ada.Text_IO.Close (F);
      declare
         Code : Integer;
      begin
         Code := Run ("cmd.exe", "/c", "start", "/min", Bat);
         if Code /= 0 then
            Put_Line ("alb-pkg: staged " & New_Exe);
            Put_Line ("alb-pkg: close this program, then move it over alb-pkg.exe");
            return;
         end if;
      end;
      Put_Line ("alb-pkg: swap scheduled, exiting");
   end Cmd_Self_Update;

   Root : constant String := SDK_Root;
   Count : constant Natural := Ada.Command_Line.Argument_Count;
begin
   if Count = 0 then
      Print_Help;
      return;
   end if;
   declare
      Cmd : constant String := Lower_Str (Ada.Command_Line.Argument (1));
   begin
      if Cmd = "help" or else Cmd = "--help" or else Cmd = "-h" then
         Print_Help;
      elsif Cmd = "install" then
         Cmd_Install (Root, 2);
      elsif Cmd = "update" then
         Cmd_Update (Root, 2);
      elsif Cmd = "remove" then
         Cmd_Remove (Root, 2);
      elsif Cmd = "list" then
         Cmd_List (Root);
      elsif Cmd = "packs" or else Cmd = "available" then
         Cmd_Packs (Root);
      elsif Cmd = "doctor" then
         Cmd_Doctor (Root);
      elsif Cmd = "self-update" then
         Cmd_Self_Update (Root);
      else
         Put_Line ("alb-pkg: unknown command: " & Cmd);
         Print_Help;
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end;
end Alb_Pkg;
