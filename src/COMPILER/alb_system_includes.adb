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

with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;

package body ALB_System_Includes is

   Gfx_Name : String (1 .. 32) := (others => ' ');
   Gfx_Len  : Natural := 0;
   Gfx_Used : Boolean := False;

   function Parent_Directory (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '\' or else Path (I) = '/' then
            if I > Path'First then
               return Path (Path'First .. I - 1);
            end if;
            return "";
         end if;
      end loop;
      return "";
   end Parent_Directory;

   function Fold_Lower (S : String) return String is
      R : String (S'Range);
   begin
      for I in S'Range loop
         if S (I) in 'A' .. 'Z' then
            R (I) := Character'Val (Character'Pos (S (I)) + 32);
         else
            R (I) := S (I);
         end if;
      end loop;
      return R;
   end Fold_Lower;

   function Leaf_Stem (Leaf : String) return String is
   begin
      for I in reverse Leaf'Range loop
         if Leaf (I) = '.' then
            if I > Leaf'First then
               return Leaf (Leaf'First .. I - 1);
            end if;
            exit;
         elsif Leaf (I) = '\' or else Leaf (I) = '/' then
            exit;
         end if;
      end loop;
      return Leaf;
   end Leaf_Stem;

   function SDK_Root return String is
      Env_Root : constant String :=
        (if Ada.Environment_Variables.Exists ("ALB_SDK_ROOT")
         then Ada.Environment_Variables.Value ("ALB_SDK_ROOT")
         else "");
      Cmd_Dir  : constant String :=
        Parent_Directory (Ada.Command_Line.Command_Name);
      Raw_Root : constant String :=
        (if Cmd_Dir'Length > 0 then Parent_Directory (Cmd_Dir) else "");
      Release_Root : constant String :=
        (if Raw_Root'Length > 0
         then Ada.Directories.Compose (Raw_Root, "release")
         else "");
   begin
      if Env_Root'Length > 0 and then Ada.Directories.Exists (Env_Root) then
         return Env_Root;
      end if;
      if Raw_Root'Length > 0
        and then Ada.Directories.Exists
          (Ada.Directories.Compose (Raw_Root, "deps"))
      then
         return Raw_Root;
      end if;
      if Release_Root'Length > 0
        and then Ada.Directories.Exists
          (Ada.Directories.Compose (Release_Root, "deps"))
      then
         return Release_Root;
      end if;
      if Raw_Root'Length > 0 then
         return Raw_Root;
      end if;
      return Ada.Directories.Current_Directory;
   exception
      when others =>
         return Ada.Directories.Current_Directory;
   end SDK_Root;

   function Vendor_Root return String is
      Root : constant String := SDK_Root;
      V1   : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Compose (Root, "stdlib"), "vendor");
      V2   : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Compose
             (Ada.Directories.Compose (Root, "src"), "stdlib"),
           "vendor");
      V3   : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Compose
             (Ada.Directories.Compose (Root, "release"), "stdlib"),
           "vendor");
   begin
      if Ada.Directories.Exists (V1) then
         return V1;
      elsif Ada.Directories.Exists (V2) then
         return V2;
      elsif Ada.Directories.Exists (V3) then
         return V3;
      else
         return V1;
      end if;
   end Vendor_Root;

   function Resolve_System_Include (Leaf : String) return String is
      Vendor : constant String := Vendor_Root;
      Direct : constant String := Ada.Directories.Compose (Vendor, Leaf);
      Stem   : constant String := Leaf_Stem (Leaf);
      Nested : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Compose (Vendor, Stem), Leaf);
      -- alb_openblas.albi -> openblas/, alb_nuklear.albi -> nuklear/, alb_gfx.albi -> alb_gfx/
      Stripped : constant String :=
        (if Stem'Length > 4
           and then Fold_Lower (Stem (Stem'First .. Stem'First + 3)) = "alb_"
         then Stem (Stem'First + 4 .. Stem'Last)
         else Stem);
      Nested2 : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Compose (Vendor, Stripped), Leaf);
      Search : Ada.Directories.Search_Type;
      Ent    : Ada.Directories.Directory_Entry_Type;
      Filter : constant Ada.Directories.Filter_Type :=
        (Ada.Directories.Directory => True, others => False);
   begin
      if Leaf'Length = 0 then
         return Leaf;
      end if;
      if Ada.Directories.Exists (Direct) then
         return Direct;
      end if;
      if Ada.Directories.Exists (Nested) then
         return Nested;
      end if;
      if Ada.Directories.Exists (Nested2) then
         return Nested2;
      end if;
      if Ada.Directories.Exists (Vendor) then
         begin
            Ada.Directories.Start_Search (Search, Vendor, "", Filter);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Ent);
               declare
                  Cand : constant String :=
                    Ada.Directories.Compose
                      (Ada.Directories.Full_Name (Ent), Leaf);
               begin
                  if Ada.Directories.Exists (Cand) then
                     Ada.Directories.End_Search (Search);
                     return Cand;
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         exception
            when others =>
               null;
         end;
      end if;
      return Leaf;
   end Resolve_System_Include;

   function System_Include_Exists (Leaf : String) return Boolean is
      Resolved : constant String := Resolve_System_Include (Leaf);
   begin
      return Resolved'Length > 0 and then Ada.Directories.Exists (Resolved);
   exception
      when others =>
         return False;
   end System_Include_Exists;

   procedure Clear_Gfx_Backend is
   begin
      Gfx_Name := (others => ' ');
      Gfx_Len := 0;
      Gfx_Used := False;
   end Clear_Gfx_Backend;

   procedure Set_Gfx_Backend (Name : String; OK : out Boolean) is
      Val : constant String := Fold_Lower (Name);
   begin
      OK := False;
      if Val = "opengl" or else Val = "vulkan"
        or else Val = "d3d6" or else Val = "d3d7" or else Val = "d3d8"
        or else Val = "d3d9" or else Val = "d3d10" or else Val = "d3d11"
        or else Val = "d3d12"
      then
         if Val'Length <= Gfx_Name'Length then
            Gfx_Name := (others => ' ');
            Gfx_Name (1 .. Val'Length) := Val;
            Gfx_Len := Val'Length;
            OK := True;
         end if;
      end if;
   end Set_Gfx_Backend;

   function Gfx_Backend return String is
   begin
      return Gfx_Name (1 .. Gfx_Len);
   end Gfx_Backend;

   function Gfx_Is_Set return Boolean is
   begin
      return Gfx_Len > 0;
   end Gfx_Is_Set;

   function Gfx_Runtime_Used return Boolean is
   begin
      return Gfx_Used;
   end Gfx_Runtime_Used;

   function Remap_Gfx_Library (Lib : String) return String is
      Simple : constant String := Ada.Directories.Simple_Name (Lib);
      Low    : constant String := Fold_Lower (Simple);
   begin
      if Low = "alb_gfx.dll" and then Gfx_Len > 0 then
         Gfx_Used := True;
         return "alb_gfx_" & Gfx_Name (1 .. Gfx_Len) & ".dll";
      elsif Low'Length >= 8
        and then Low (Low'First .. Low'First + 7) = "alb_gfx_"
      then
         Gfx_Used := True;
      elsif Low = "alb_gfx.dll" then
         Gfx_Used := True;
      end if;
      return Simple;
   end Remap_Gfx_Library;

   function Resolve_Vendor_Dll (Lib : String) return String is
      Mapped  : constant String := Remap_Gfx_Library (Lib);
      Vendor  : constant String := Vendor_Root;
      Gfx_Bin : constant String :=
        Ada.Directories.Compose
          (Ada.Directories.Compose
             (Ada.Directories.Compose (Vendor, "alb_gfx"), "bin"),
           Mapped);

      function Normalize_Slashes (Path : String) return String is
         Result : String (1 .. Path'Length);
      begin
         for I in Path'Range loop
            Result (I - Path'First + 1) :=
              (if Path (I) = '\' then '/' else Path (I));
         end loop;
         return Result;
      end Normalize_Slashes;

      function Vendor_Pkg_From_Dll (Name : String) return String is
         Low : constant String := Fold_Lower (Name);
      begin
         -- alb_openblas.dll -> openblas, alb_nuklear.dll -> nuklear, etc.
         if Low'Length > 8
           and then Low (Low'First .. Low'First + 3) = "alb_"
           and then Low (Low'Last - 3 .. Low'Last) = ".dll"
         then
            return Low (Low'First + 4 .. Low'Last - 4);
         end if;
         return Leaf_Stem (Name);
      end Vendor_Pkg_From_Dll;
   begin
      if Mapped'Length = 0 then
         return Mapped;
      end if;
      if Ada.Directories.Exists (Mapped) then
         return Normalize_Slashes (Mapped);
      end if;
      -- Only use alb_gfx/bin for RHI DLLs (not staged companions like openblas).
      declare
         Low_Mapped : constant String := Fold_Lower (Mapped);
      begin
         if Low_Mapped'Length >= 7
           and then Low_Mapped (Low_Mapped'First .. Low_Mapped'First + 6) = "alb_gfx"
           and then Ada.Directories.Exists (Gfx_Bin)
         then
            return Normalize_Slashes (Gfx_Bin);
         end if;
      end;
      declare
         Stem   : constant String := Leaf_Stem (Mapped);
         Nested : constant String :=
           Ada.Directories.Compose
             (Ada.Directories.Compose
                (Ada.Directories.Compose (Vendor, Stem), "bin"),
              Mapped);
         Pkg    : constant String := Vendor_Pkg_From_Dll (Mapped);
         Pkg_Bin : constant String :=
           Ada.Directories.Compose
             (Ada.Directories.Compose
                (Ada.Directories.Compose (Vendor, Pkg), "bin"),
              Mapped);
      begin
         if Ada.Directories.Exists (Nested) then
            return Normalize_Slashes (Nested);
         end if;
         if Ada.Directories.Exists (Pkg_Bin) then
            return Normalize_Slashes (Pkg_Bin);
         end if;
      end;
      -- One-level scan: vendor/*/bin/Mapped
      if Ada.Directories.Exists (Vendor) then
         declare
            Search : Ada.Directories.Search_Type;
            Ent    : Ada.Directories.Directory_Entry_Type;
            Filter : constant Ada.Directories.Filter_Type :=
              (Ada.Directories.Directory => True, others => False);
         begin
            Ada.Directories.Start_Search (Search, Vendor, "", Filter);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Ent);
               declare
                  Cand : constant String :=
                    Ada.Directories.Compose
                      (Ada.Directories.Compose
                         (Ada.Directories.Full_Name (Ent), "bin"),
                       Mapped);
               begin
                  if Ada.Directories.Exists (Cand) then
                     Ada.Directories.End_Search (Search);
                     return Normalize_Slashes (Cand);
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         exception
            when others =>
               null;
         end;
      end if;
      return Mapped;
   end Resolve_Vendor_Dll;

   function Try_Parse_Gfx_Arg
     (Arg       : String;
      Next_Arg  : String;
      Has_Next  : Boolean;
      Skip_Next : out Boolean;
      Error     : out Boolean) return Boolean
   is
      OK : Boolean;
   begin
      Skip_Next := False;
      Error := False;

      if Arg'Length >= 6 and then Arg (Arg'First .. Arg'First + 5) = "--gfx=" then
         Set_Gfx_Backend (Arg (Arg'First + 6 .. Arg'Last), OK);
         if not OK then
            Error := True;
         end if;
         return True;
      elsif Arg = "--gfx" then
         if Has_Next then
            Set_Gfx_Backend (Next_Arg, OK);
            if not OK then
               Error := True;
            end if;
            Skip_Next := True;
            return True;
         else
            Error := True;
            return True;
         end if;
      end if;

      return False;
   end Try_Parse_Gfx_Arg;

end ALB_System_Includes;
