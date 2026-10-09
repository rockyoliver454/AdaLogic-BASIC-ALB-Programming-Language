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

with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with Parser;         use Parser;
with AST;            use AST;
with Emit_Native_Rust;
with Code_Information;
with ALB_System_Includes;
with GNAT.OS_Lib;    use GNAT.OS_Lib;


procedure ALBR is

   Max_Path_Len   : constant Natural := 512;
   Max_Includes   : constant Natural := 256;
   Max_Input_Size : constant Natural := Input_Buffer'Length;

   Input_Len     : Natural := 0;
   Token_Count   : Natural := 0;
   Root          : Node_Index := 0;
   Parse_Success : Boolean := False;

   Lex_Diag   : Lexer_Diagnostic;
   Parse_Diag : Parser_Diagnostic;

   Include_Vault : array (1 .. Max_Includes) of String (1 .. Max_Path_Len) :=
     (others => (others => ' '));
   Include_Lens  : array (1 .. Max_Includes) of Natural := (others => 0);
   Include_Count : Natural := 0;

   Quiet_Mode   : Boolean := False;
   Walker_Mode  : Boolean := False;
   Metrics_Mode : Boolean := False;
   Build_Mode   : Boolean := False;
   Run_Mode     : Boolean := False;

   Source_File : String (1 .. Max_Path_Len) := (others => ' ');
   Source_Len  : Natural := 0;
   Output_File : String (1 .. Max_Path_Len) := (others => ' ');
   Output_Len  : Natural := 0;
   Out_Dir     : String (1 .. Max_Path_Len) := (others => ' ');
   Out_Dir_Len : Natural := 0;

   function To_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      end if;
      return Ch;
   end To_Upper;

   function Trim_Image (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return Ada.Strings.Fixed.Trim (S, Ada.Strings.Both);
   end Trim_Image;

   procedure Log (Msg : String) is
   begin
      if not Quiet_Mode then
         Put_Line (Msg);
      end if;
   end Log;

   function Parent_Directory (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '\' or else Path (I) = '/' then
            return Path (Path'First .. I);
         end if;
      end loop;
      return "";
   end Parent_Directory;

   function Base_Name (Path : String) return String is
   begin
      if Path'Length = 0 then
         return "output";
      end if;

      declare
         Raw : constant String := Ada.Directories.Base_Name (Path);
         Dot : Natural := 0;
      begin
         for I in reverse Raw'Range loop
            exit when Raw (I) = '\' or else Raw (I) = '/';
            if Raw (I) = '.' then
               Dot := I;
               exit;
            end if;
         end loop;

         if Dot > Raw'First then
            return Raw (Raw'First .. Dot - 1);
         end if;
         return Raw;
      end;
   exception
      when others =>
         return "output";
   end Base_Name;

   function Is_Absolute_Path (Path : String) return Boolean is
   begin
      if Path'Length = 0 then
         return False;
      end if;

      if Path (Path'First) = '/' or else Path (Path'First) = '\' then
         return True;
      end if;

      return Path'Length >= 2 and then Path (Path'First + 1) = ':';
   end Is_Absolute_Path;

   function Default_Output_Name (Input : String) return String is
   begin
      return Base_Name (Input) & ".rs";
   end Default_Output_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "rust_" & Base_Name (Input);
   end Default_Out_Dir;

   function Is_Already_Included (File_Name : String) return Boolean is
   begin
      for I in 1 .. Include_Count loop
         if Include_Lens (I) = File_Name'Length
           and then Include_Vault (I) (1 .. File_Name'Length) = File_Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Already_Included;

   procedure Register_Include
     (File_Name : String;
      Success   : in out Boolean) is
   begin
      if Include_Count >= Max_Includes or else File_Name'Length > Max_Path_Len then
         Success := False;
         return;
      end if;

      Include_Count := Include_Count + 1;
      Include_Lens (Include_Count) := File_Name'Length;
      Include_Vault (Include_Count) := (others => ' ');
      Include_Vault (Include_Count) (1 .. File_Name'Length) := File_Name;
   end Register_Include;

   procedure Append_Source
     (Text    : String;
      Success : in out Boolean) is
   begin
      if not Success then
         return;
      end if;

      if Input_Len + Text'Length > Max_Input_Size then
         Success := False;
         return;
      end if;

      Input_Buffer (Input_Len + 1 .. Input_Len + Text'Length) := Text;
      Input_Len := Input_Len + Text'Length;
   end Append_Source;

   procedure Parse_Include_Line
     (Line_Text : String;
      Line_Len  : Natural;
      Match     : out Boolean;
      Is_System : out Boolean;
      File_Name : out String;
      File_Len  : out Natural)
   is
      P       : Natural := 1;
      Start   : Natural := 0;
      Stop    : Natural := 0;
      Keyword : constant String := "INCLUDE";
   begin
      Match := False;
      Is_System := False;
      File_Len := 0;
      File_Name := (others => ' ');

      while P <= Line_Len and then
        (Line_Text (P) = ' ' or else Line_Text (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P + Keyword'Length - 1 > Line_Len then
         return;
      end if;

      for I in Keyword'Range loop
         if To_Upper (Line_Text (P + (I - Keyword'First))) /= Keyword (I) then
            return;
         end if;
      end loop;

      P := P + Keyword'Length;
      while P <= Line_Len and then
        (Line_Text (P) = ' ' or else Line_Text (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P > Line_Len then
         return;
      end if;

      if Line_Text (P) = '"' then
         Is_System := False;
         Start := P + 1;
         Stop := Start;
         while Stop <= Line_Len and then Line_Text (Stop) /= '"' loop
            Stop := Stop + 1;
         end loop;

         if Stop <= Line_Len and then Stop > Start then
            File_Len := Stop - Start;
            if File_Len <= File_Name'Length then
               File_Name
                 (File_Name'First .. File_Name'First + File_Len - 1) :=
                   Line_Text (Start .. Stop - 1);
               Match := True;
            end if;
         end if;
      elsif Line_Text (P) = '<' then
         Is_System := True;
         Start := P + 1;
         Stop := Start;
         while Stop <= Line_Len and then Line_Text (Stop) /= '>' loop
            Stop := Stop + 1;
         end loop;

         if Stop <= Line_Len and then Stop > Start then
            File_Len := Stop - Start;
            if File_Len <= File_Name'Length then
               File_Name
                 (File_Name'First .. File_Name'First + File_Len - 1) :=
                   Line_Text (Start .. Stop - 1);
               Match := True;
            end if;
         end if;
      end if;
   end Parse_Include_Line;

   function Path_Exists (Path : String) return Boolean is
   begin
      return Path'Length > 0 and then Ada.Directories.Exists (Path);
   exception
      when others =>
         return False;
   end Path_Exists;

   function Resolve_Local_Path
     (Raw_Path : String;
      Base_Dir : String) return String
   is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);

      function Join_Base (Dir : String; Leaf : String) return String is
         function Has_Separator (Text : String) return Boolean is
         begin
            for I in Text'Range loop
               if Text (I) = '\' or else Text (I) = '/' then
                  return True;
               end if;
            end loop;
            return False;
         end Has_Separator;
      begin
         if Leaf'Length = 0 then
            return Dir;
         elsif Dir'Length = 0 then
            return Leaf;
         elsif Leaf (Leaf'First) = '\' or else Leaf (Leaf'First) = '/' then
            return Leaf;
         elsif Leaf'Length >= 3
           and then Leaf (Leaf'First) = '.'
           and then Leaf (Leaf'First + 1) = '.'
           and then (Leaf (Leaf'First + 2) = '\' or else Leaf (Leaf'First + 2) = '/')
         then
            if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf;
            else
               return Dir & "\" & Leaf;
            end if;
         elsif Leaf'Length >= 2
           and then Leaf (Leaf'First) = '.'
           and then (Leaf (Leaf'First + 1) = '\' or else Leaf (Leaf'First + 1) = '/')
         then
            if Leaf'Length = 2 then
               return Dir;
            elsif Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf (Leaf'First + 2 .. Leaf'Last);
            else
               return Dir & "\" & Leaf (Leaf'First + 2 .. Leaf'Last);
            end if;
         elsif Has_Separator (Leaf) then
            if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf;
            else
               return Dir & "\" & Leaf;
            end if;
         else
            return Ada.Directories.Compose (Dir, Leaf);
         end if;
      end Join_Base;
   begin
      if Trimmed'Length = 0 then
         return "";
      elsif Path_Exists (Trimmed) then
         return Trimmed;
      elsif Base_Dir'Length > 0 then
         declare
            Candidate : constant String := Join_Base (Base_Dir, Trimmed);
         begin
            if Path_Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end if;
      return "";
   end Resolve_Local_Path;

   procedure Weave_File
     (File_Name : String;
      Success   : in out Boolean)
   is
      File        : Ada.Streams.Stream_IO.File_Type;
      Stream_Ptr  : Ada.Streams.Stream_IO.Stream_Access;
      Ch          : Character;
      Line_Buffer : String (1 .. 2048) := (others => ' ');
      Line_Len    : Natural := 0;
      File_Dir    : constant String := Parent_Directory (File_Name);

      procedure Flush_Line is
         Include_Match  : Boolean := False;
         Include_System : Boolean := False;
         Include_Name   : String (1 .. Max_Path_Len) := (others => ' ');
         Include_Len    : Natural := 0;
         Resolved       : String (1 .. Max_Path_Len) := (others => ' ');
         Resolved_Len   : Natural := 0;
      begin
         Parse_Include_Line
           (Line_Buffer,
            Line_Len,
            Include_Match,
            Include_System,
            Include_Name,
            Include_Len);

         if Include_Match then
            declare
               Raw_Include : constant String := Include_Name (1 .. Include_Len);
            begin
               if Include_System then
                  declare
                     Sys : constant String :=
                       ALB_System_Includes.Resolve_System_Include (Raw_Include);
                  begin
                     if not Ada.Directories.Exists (Sys) then
                        Put_Line
                          ("ALBR: FATAL: System include not found: <"
                           & Raw_Include & "> (searched under "
                           & ALB_System_Includes.Vendor_Root & ")");
                        Success := False;
                     elsif Sys'Length <= Max_Path_Len then
                        Resolved_Len := Sys'Length;
                        Resolved (1 .. Resolved_Len) := Sys;
                     else
                        Success := False;
                     end if;
                  end;
               else
                  declare
                     Resolved_Path : constant String :=
                       Resolve_Local_Path (Raw_Include, File_Dir);
                  begin
                     if Resolved_Path'Length = 0
                       or else Resolved_Path'Length > Max_Path_Len
                     then
                        Put_Line
                          ("ALBR: include not found: " & Raw_Include
                           & " (from " & File_Name & ")");
                        Success := False;
                     else
                        Resolved_Len := Resolved_Path'Length;
                        Resolved (1 .. Resolved_Len) := Resolved_Path;
                     end if;
                  end;
               end if;

               if Success and then Resolved_Len > 0 then
                  Weave_File (Resolved (1 .. Resolved_Len), Success);
               end if;
            end;
         else
            if Line_Len > 0 then
               Append_Source (Line_Buffer (1 .. Line_Len), Success);
            end if;
            Append_Source (ASCII.LF & "", Success);
         end if;

         Line_Len := 0;
      end Flush_Line;
   begin
      if not Success or else Is_Already_Included (File_Name) then
         return;
      end if;

      Register_Include (File_Name, Success);
      if not Success then
         return;
      end if;

      Log ("  weaving: " & File_Name);

      begin
         Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, File_Name);
         Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);
      exception
         when E : others =>
            Put_Line ("ALBR: could not open source file: " & File_Name & " - " &
              Ada.Exceptions.Exception_Message (E));
            Success := False;
            return;
      end;

      while not Ada.Streams.Stream_IO.End_Of_File (File) loop
         Character'Read (Stream_Ptr, Ch);
         if Ch = ASCII.CR then
            null;
         elsif Ch = ASCII.LF then
            Flush_Line;
            exit when not Success;
         else
            if Line_Len < Line_Buffer'Length then
               Line_Len := Line_Len + 1;
               Line_Buffer (Line_Len) := Ch;
            else
               Success := False;
               exit;
            end if;
         end if;
      end loop;

      if Success and then Line_Len > 0 then
         Flush_Line;
      end if;

      Ada.Streams.Stream_IO.Close (File);
   exception
      when E : others =>
         Put_Line ("ALBR: weave failure in " & File_Name & " - " &
           Ada.Exceptions.Exception_Message (E));
         Success := False;
         begin
            Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               null;
         end;
   end Weave_File;

   function Source_Wants_No_Console return Boolean is
      Sample : constant String := Input_Buffer (1 .. Input_Len);
   begin
      return Ada.Strings.Fixed.Index (Sample, "NO CONSOLE") > 0
        or else Ada.Strings.Fixed.Index (Sample, "MODE NO CONSOLE") > 0;
   end Source_Wants_No_Console;

   function SDK_Root return String is
      Cmd : constant String := Ada.Command_Line.Command_Name;
      Bin_Dir : constant String := Ada.Directories.Containing_Directory (Cmd);
      Raw_Root : constant String := Ada.Directories.Containing_Directory (Bin_Dir);
      Release_Root : constant String := Ada.Directories.Compose (Raw_Root, "release");
   begin
      if Ada.Directories.Exists (Ada.Directories.Compose (Raw_Root, "deps")) then
         return Raw_Root;
      elsif Ada.Directories.Exists (Ada.Directories.Compose (Release_Root, "deps")) then
         return Release_Root;
      elsif Ada.Directories.Exists (Ada.Directories.Compose (Raw_Root, "bin")) then
         return Raw_Root;
      end if;
      return Ada.Directories.Current_Directory;
   exception
      when others =>
         return Ada.Directories.Current_Directory;
   end SDK_Root;

   function Find_Rustc return String is
      Root : constant String := SDK_Root;

      function Join4 (A, B, C, D : String) return String is
      begin
         return Ada.Directories.Compose
           (Ada.Directories.Compose
              (Ada.Directories.Compose
                 (Ada.Directories.Compose (Root, A), B), C), D);
      end Join4;

      function Join5 (A, B, C, D, E : String) return String is
      begin
         return Ada.Directories.Compose (Join4 (A, B, C, D), E);
      end Join5;

      Cand_1 : constant String := Join4 ("deps", "rust", "bin", "rustc.exe");
      Cand_2 : constant String := Join5 ("release", "deps", "rust", "bin", "rustc.exe");
      --  When SDK_Root already points at release/, still check deps/rust.
      Cand_3 : constant String := Join4 ("deps", "rust", "bin", "rustc.exe");
   begin
      if Path_Exists (Cand_1) then
         return Cand_1;
      elsif Path_Exists (Cand_2) then
         return Cand_2;
      elsif Path_Exists (Cand_3) then
         return Cand_3;
      elsif Locate_Exec_On_Path ("rustc.exe") /= null then
         declare
            P : String_Access := Locate_Exec_On_Path ("rustc.exe");
            R : constant String := P.all;
         begin
            Free (P);
            return R;
         end;
      elsif Locate_Exec_On_Path ("rustc") /= null then
         declare
            P : String_Access := Locate_Exec_On_Path ("rustc");
            R : constant String := P.all;
         begin
            Free (P);
            return R;
         end;
      end if;
      return "";
   end Find_Rustc;

   function Find_SDL3_DLL return String is
      Root : constant String := SDK_Root;
      A : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose (Root, "bin"), "SDL3.dll");
      B : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose (Root, "support"), "SDL3.dll");
      C : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose
           (Ada.Directories.Compose (Root, "release"), "support"), "SDL3.dll");
      D : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose
           (Ada.Directories.Compose (Root, "deps"), "fasm"), "SDL3.dll");
      E : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose (Root, "obj"), "SDL3.dll");
   begin
      if Path_Exists (A) then
         return A;
      elsif Path_Exists (B) then
         return B;
      elsif Path_Exists (C) then
         return C;
      elsif Path_Exists (D) then
         return D;
      elsif Path_Exists (E) then
         return E;
      end if;
      return "";
   end Find_SDL3_DLL;

   function Find_SDL3_Lib_Dir return String is
      Root : constant String := SDK_Root;
      A : constant String := Ada.Directories.Compose (Root, "support");
      B : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose (Root, "release"), "support");
      function Has_Lib (Dir : String) return Boolean is
      begin
         return Path_Exists (Ada.Directories.Compose (Dir, "libSDL3.a"))
           or else Path_Exists (Ada.Directories.Compose (Dir, "libSDL3.dll.a"));
      end Has_Lib;
   begin
      if Has_Lib (A) then
         return A;
      elsif Has_Lib (B) then
         return B;
      end if;
      return "";
   end Find_SDL3_Lib_Dir;

   procedure Stage_SDL3_Runtime (Rs_Path : String) is
      Dir  : constant String := Ada.Directories.Containing_Directory (Rs_Path);
      Src  : constant String := Find_SDL3_DLL;
      Dest : constant String := Ada.Directories.Compose (Dir, "SDL3.dll");
   begin
      if Src'Length > 0 then
         begin
            Ada.Directories.Copy_File (Src, Dest);
            Log ("ALBR: staged SDL3.dll");
         exception
            when others =>
               Put_Line ("ALBR: could not stage SDL3.dll from " & Src);
         end;
      else
         Put_Line
           ("ALBR: warning: SDL3.dll not found under SDK; copy it beside the .exe before running");
      end if;
   end Stage_SDL3_Runtime;

   procedure Stage_Vendor_Runtime (Rs_Path : String) is
      Dir         : constant String := Ada.Directories.Containing_Directory (Rs_Path);
      Vendor_Root : constant String := ALB_System_Includes.Vendor_Root;
      Backend     : constant String :=
        (if ALB_System_Includes.Gfx_Is_Set
         then ALB_System_Includes.Gfx_Backend
         else "opengl");
      Gfx_Dll     : constant String := "alb_gfx_" & Backend & ".dll";
      Thin_Dll    : constant String :=
        (if Backend = "opengl" then "alb_opengl.dll"
         elsif Backend = "vulkan" then "alb_vulkan.dll"
         elsif Backend = "d3d11" then "alb_d3d11.dll"
         else "alb_opengl.dll");

      procedure Stage_One (Src : String; Leaf : String) is
         Dest : constant String := Ada.Directories.Compose (Dir, Leaf);
      begin
         if Src'Length > 0 and then Ada.Directories.Exists (Src) then
            begin
               Ada.Directories.Copy_File (Src, Dest);
               Log ("ALBR: staged " & Leaf);
            exception
               when others =>
                  Put_Line ("ALBR: could not stage " & Leaf & " from " & Src);
            end;
         end if;
      end Stage_One;

      procedure Stage_Vendor_Bin (Pkg : String; Leaf : String) is
         Src : constant String :=
           Ada.Directories.Compose
             (Ada.Directories.Compose
                (Ada.Directories.Compose (Vendor_Root, Pkg), "bin"),
              Leaf);
      begin
         Stage_One (Src, Leaf);
      end Stage_Vendor_Bin;
   begin
      Stage_Vendor_Bin ("alb_gfx", Gfx_Dll);
      Stage_One
        (Ada.Directories.Compose
           (Ada.Directories.Compose
              (Ada.Directories.Compose (Vendor_Root, "alb_gfx"), "bin"),
            Gfx_Dll),
         "alb_gfx.dll");
      Stage_Vendor_Bin ("alb_gfx", Thin_Dll);
      if not Ada.Directories.Exists
        (Ada.Directories.Compose (Dir, Thin_Dll))
      then
         Stage_Vendor_Bin (Backend, Thin_Dll);
      end if;
      Stage_Vendor_Bin ("openblas", "alb_openblas.dll");
      Stage_Vendor_Bin ("openblas", "libopenblas.dll");
      Stage_Vendor_Bin ("nuklear", "alb_nuklear.dll");
      Stage_Vendor_Bin ("nuklear", "alb_glfw.dll");
      Stage_Vendor_Bin ("nuklear", "glfw3.dll");
   end Stage_Vendor_Runtime;

   function Exe_Name_From_Rs (Rs_Path : String) return String is
      Leaf : constant String := Ada.Directories.Simple_Name (Rs_Path);
      Dot  : Natural := 0;
   begin
      for I in reverse Leaf'Range loop
         if Leaf (I) = '.' then
            Dot := I;
            exit;
         end if;
      end loop;
      if Dot > Leaf'First then
         return Leaf (Leaf'First .. Dot - 1) & ".exe";
      end if;
      return Leaf & ".exe";
   end Exe_Name_From_Rs;

   procedure Write_Run_Bat (Dir : String; Exe_Leaf : String) is
      Bat  : constant String := Ada.Directories.Compose (Dir, "run.bat");
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Bat);
      Ada.Text_IO.Put_Line (File, "@echo off");
      Ada.Text_IO.Put_Line (File, "setlocal");
      Ada.Text_IO.Put_Line (File, "cd /d ""%~dp0""");
      Ada.Text_IO.Put_Line (File, """" & Exe_Leaf & """ %*");
      Ada.Text_IO.Close (File);
      Log ("ALBR: wrote " & Bat);
   exception
      when others =>
         Put_Line ("ALBR: failed to write run.bat");
   end Write_Run_Bat;

   function Spawn_And_Check
     (Working_Dir : String;
      Program     : String;
      Args        : GNAT.OS_Lib.Argument_List) return Boolean
   is
      Original_Dir : constant String := Ada.Directories.Current_Directory;
      Exit_Code    : Integer := -1;
   begin
      Ada.Directories.Set_Directory (Working_Dir);
      Exit_Code := GNAT.OS_Lib.Spawn (Program, Args);
      Ada.Directories.Set_Directory (Original_Dir);
      return Exit_Code = 0;
   exception
      when others =>
         begin
            Ada.Directories.Set_Directory (Original_Dir);
         exception
            when others =>
               null;
         end;
         return False;
   end Spawn_And_Check;

   function Rustc_Build (Rs_Path : String) return Boolean is
      Rustc : constant String := Find_Rustc;
      Dir   : constant String := Ada.Directories.Containing_Directory (Rs_Path);
      Rs_Leaf : constant String := Ada.Directories.Simple_Name (Rs_Path);
      Exe_Leaf : constant String := Exe_Name_From_Rs (Rs_Path);
      OK    : Boolean;

      procedure Ensure_Link_Path is
         Root : constant String := SDK_Root;
         Mingw : constant String := Ada.Directories.Compose
           (Ada.Directories.Compose
              (Ada.Directories.Compose
                 (Ada.Directories.Compose (Root, "release"), "deps"),
               "w64devkit"),
            "bin");
         Mingw2 : constant String := Ada.Directories.Compose
           (Ada.Directories.Compose
              (Ada.Directories.Compose (Root, "deps"), "w64devkit"), "bin");
         Rust_Bin : constant String := Ada.Directories.Containing_Directory (Rustc);
         Old_Path : constant String :=
           (if Ada.Environment_Variables.Exists ("PATH")
            then Ada.Environment_Variables.Value ("PATH") else "");
         Prefix : constant String :=
           Rust_Bin & ";" &
           (if Path_Exists (Mingw) then Mingw & ";"
            elsif Path_Exists (Mingw2) then Mingw2 & ";"
            else "") &
           Old_Path;
      begin
         Ada.Environment_Variables.Set ("PATH", Prefix);
         --  Bundled rustup home (deps/rust) when present.
         declare
            Rust_Home : constant String :=
              Ada.Directories.Containing_Directory (Rust_Bin);
         begin
            if Path_Exists
                 (Ada.Directories.Compose (Rust_Home, "toolchains"))
            then
               Ada.Environment_Variables.Set ("RUSTUP_HOME", Rust_Home);
            elsif Path_Exists
                 (Ada.Directories.Compose
                    (Ada.Directories.Containing_Directory (Rust_Home),
                     "toolchains"))
            then
               Ada.Environment_Variables.Set
                 ("RUSTUP_HOME",
                  Ada.Directories.Containing_Directory (Rust_Home));
            end if;
         exception
            when others =>
               null;
         end;
      end Ensure_Link_Path;
   begin
      if Rustc'Length = 0 then
         Put_Line ("ALBR: rustc.exe not found (expected deps\\rust\\bin\\rustc.exe or PATH)");
         return False;
      end if;

      Ensure_Link_Path;
      Log ("ALBR: rustc -> " & Rustc);
      Stage_SDL3_Runtime (Rs_Path);
      Stage_Vendor_Runtime (Rs_Path);
      declare
         Lib_Dir : constant String := Find_SDL3_Lib_Dir;
         OK_Build : Boolean;
      begin
         if Lib_Dir'Length > 0 then
            declare
               Args : GNAT.OS_Lib.Argument_List :=
                 (1 => new String'("--edition"),
                  2 => new String'("2021"),
                  3 => new String'("-O"),
                  4 => new String'("-C"),
                  5 => new String'("link-self-contained=yes"),
                  6 => new String'("-L"),
                  7 => new String'(Lib_Dir),
                  8 => new String'("-l"),
                  9 => new String'("SDL3"),
                  10 => new String'("-o"),
                  11 => new String'(Exe_Leaf),
                  12 => new String'(Rs_Leaf));
            begin
               Log ("ALBR: rustc link -L " & Lib_Dir & " -l SDL3");
               OK_Build := Spawn_And_Check (Dir, Rustc, Args);
               for I in Args'Range loop
                  Free (Args (I));
               end loop;
            end;
         else
            declare
               Args : GNAT.OS_Lib.Argument_List :=
                 (1 => new String'("--edition"),
                  2 => new String'("2021"),
                  3 => new String'("-O"),
                  4 => new String'("-C"),
                  5 => new String'("link-self-contained=yes"),
                  6 => new String'("-o"),
                  7 => new String'(Exe_Leaf),
                  8 => new String'(Rs_Leaf));
            begin
               Put_Line
                 ("ALBR: warning: libSDL3.a not found; linking without -lSDL3");
               OK_Build := Spawn_And_Check (Dir, Rustc, Args);
               for I in Args'Range loop
                  Free (Args (I));
               end loop;
            end;
         end if;
         OK := OK_Build;
      end;

      if OK then
         Write_Run_Bat (Dir, Exe_Leaf);
         Log ("ALBR: rustc build produced " & Ada.Directories.Compose (Dir, Exe_Leaf));
      else
         Put_Line ("ALBR: rustc build failed for " & Rs_Path);
      end if;
      return OK;
   end Rustc_Build;

   function Run_Exe (Rs_Path : String) return Boolean is
      Dir      : constant String := Ada.Directories.Containing_Directory (Rs_Path);
      Exe_Leaf : constant String := Exe_Name_From_Rs (Rs_Path);
      Exe_Path : constant String := Ada.Directories.Compose (Dir, Exe_Leaf);
      Empty    : GNAT.OS_Lib.Argument_List (1 .. 0);
   begin
      if not Path_Exists (Exe_Path) then
         Put_Line ("ALBR: executable not found: " & Exe_Path);
         return False;
      end if;
      return Spawn_And_Check (Dir, Exe_Path, Empty);
   end Run_Exe;

   procedure Print_Help is
   begin
      Put_Line ("ALBR: AdaLogic BASIC Rust (rustc) transpiler");
      Put_Line ("Usage: albr [options] <input.alb> [output.rs]");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  -o <file>        Output .rs file (default: derived from input name)");
      Put_Line ("  --outdir <dir>   Output directory (default: current dir, or rust_<name> with --build)");
      Put_Line ("  --build, -b      Emit .rs then compile with rustc to .exe + stage SDL3.dll + run.bat");
      Put_Line ("  --run, -r        Build (if needed) then run the generated .exe");
      Put_Line ("  --metrics, -m    Show code metrics after compilation");
      Put_Line ("  --walker, -w     Show AST structure and token information");
      Put_Line ("  --quiet, -q      Suppress informational messages");
      Put_Line ("  --gfx=<backend>  Remap alb_gfx.dll -> alb_gfx_<backend>.dll (opengl|vulkan|d3d*)");
      Put_Line ("  --help, -h       Show this help");
      Put_Line ("Runtime: rustc + SDL3.dll + vendor RHIs (same --gfx model as FASM/Odin).");
   end Print_Help;

   procedure Print_Walker_Info is
   begin
      New_Line;
      Put_Line ("=== ALBR Walker ===");
      Put_Line ("Token count : " & Trim_Image (Integer (Token_Count)));
      Put_Line ("Source size : " & Trim_Image (Integer (Input_Len)) & " bytes");
      Put_Line ("Include count: " & Trim_Image (Integer (Include_Count)));
      Put_Line ("Root kind   : " & Node_Kind'Image (Tree (Root).Kind));
      New_Line;
   end Print_Walker_Info;

   procedure Parse_Args is
      I : Natural := 1;
   begin
      while I <= Ada.Command_Line.Argument_Count loop
         declare
            Arg      : constant String := Ada.Command_Line.Argument (I);
            Gfx_Err  : Boolean;
            Gfx_Skip : Boolean;
         begin
            if ALB_System_Includes.Try_Parse_Gfx_Arg
              (Arg,
               (if I < Ada.Command_Line.Argument_Count
                then Ada.Command_Line.Argument (I + 1)
                else ""),
               I < Ada.Command_Line.Argument_Count,
               Gfx_Skip,
               Gfx_Err)
            then
               if Gfx_Err then
                  Put_Line
                    ("ALBR: FATAL: Unknown --gfx backend (use opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12).");
                  raise Program_Error;
               end if;
               if Gfx_Skip then
                  I := I + 1;
               end if;
            elsif Arg = "--help" or else Arg = "-h" then
               Print_Help;
               raise Program_Error;
            elsif Arg = "--quiet" or else Arg = "-q" then
               Quiet_Mode := True;
            elsif Arg = "--walker" or else Arg = "-w" then
               Walker_Mode := True;
            elsif Arg = "--metrics" or else Arg = "-m" then
               Metrics_Mode := True;
            elsif Arg = "--build" or else Arg = "-b" then
               Build_Mode := True;
            elsif Arg = "--run" or else Arg = "-r" then
               Run_Mode := True;
               Build_Mode := True;
            elsif Arg = "-o" and then I < Ada.Command_Line.Argument_Count then
               I := I + 1;
               declare
                  V : constant String := Ada.Command_Line.Argument (I);
               begin
                  Output_Len := Natural'Min (V'Length, Max_Path_Len);
                  Output_File := (others => ' ');
                  Output_File (1 .. Output_Len) := V (V'First .. V'First + Output_Len - 1);
               end;
            elsif Arg = "--outdir" and then I < Ada.Command_Line.Argument_Count then
               I := I + 1;
               declare
                  V : constant String := Ada.Command_Line.Argument (I);
               begin
                  Out_Dir_Len := Natural'Min (V'Length, Max_Path_Len);
                  Out_Dir := (others => ' ');
                  Out_Dir (1 .. Out_Dir_Len) := V (V'First .. V'First + Out_Dir_Len - 1);
               end;
            elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
               Put_Line ("ALBR: unknown option " & Arg);
               Print_Help;
               raise Program_Error;
            else
               if Source_Len = 0 then
                  Source_Len := Natural'Min (Arg'Length, Max_Path_Len);
                  Source_File := (others => ' ');
                  Source_File (1 .. Source_Len) := Arg (Arg'First .. Arg'First + Source_Len - 1);
               elsif Output_Len = 0 then
                  Output_Len := Natural'Min (Arg'Length, Max_Path_Len);
                  Output_File := (others => ' ');
                  Output_File (1 .. Output_Len) := Arg (Arg'First .. Arg'First + Output_Len - 1);
               else
                  Put_Line ("ALBR: unexpected argument: " & Arg);
                  Print_Help;
                  raise Program_Error;
               end if;
            end if;
         end;
         I := I + 1;
      end loop;
   end Parse_Args;

begin
   Parse_Args;

   if Source_Len = 0 then
      Print_Help;
      return;
   end if;

   if Build_Mode and then Out_Dir_Len = 0 then
      declare
         D : constant String := Default_Out_Dir (Source_File (1 .. Source_Len));
      begin
         Out_Dir_Len := Natural'Min (D'Length, Max_Path_Len);
         Out_Dir (1 .. Out_Dir_Len) := D;
      end;
   end if;

   declare
      Success : Boolean := True;
   begin
      Weave_File (Source_File (1 .. Source_Len), Success);
      if not Success then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
   end;

   Log ("Step 1: Tokenizing");
   Tokenizer.Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, Lex_Diag);
   if not Lex_Diag.Success then
      Put_Line
        ("ALBR lexer failure at line " &
         Trim_Image (Integer (Lex_Diag.Error_Line)) &
         ", col " &
         Trim_Image (Integer (Lex_Diag.Error_Col)));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Log ("Step 2: Parsing");
   Parser.Parse (Tokens, Token_Count, Tree, Root, Parse_Success, Parse_Diag);
   if not Parse_Success or else not Parse_Diag.Success or else Root = 0 then
      Put_Line
        ("ALBR parser failure at line " &
         Trim_Image (Integer (Parse_Diag.Error_Line)) &
         ", col " &
         Trim_Image (Integer (Parse_Diag.Error_Col)));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   if Walker_Mode then
      Print_Walker_Info;
   end if;

   declare
      Final_Out_Dir : constant String :=
        (if Out_Dir_Len > 0 then Out_Dir (1 .. Out_Dir_Len) else "");
      Final_Output : constant String :=
        (if Output_Len > 0 then
           (if Final_Out_Dir'Length > 0
              and then not Is_Absolute_Path (Output_File (1 .. Output_Len))
            then Ada.Directories.Compose (Final_Out_Dir, Output_File (1 .. Output_Len))
            else Output_File (1 .. Output_Len))
         elsif Final_Out_Dir'Length > 0 then
           Ada.Directories.Compose
             (Final_Out_Dir, Default_Output_Name (Source_File (1 .. Source_Len)))
         else Default_Output_Name (Source_File (1 .. Source_Len)));
      Build_OK : Boolean := True;
   begin
      if Final_Out_Dir'Length > 0 then
         Ada.Directories.Create_Path (Final_Out_Dir);
      end if;

      if Source_Wants_No_Console then
         Emit_Native_Rust.Set_No_Console_Overlay (True);
      end if;

      Log ("Step 3: Emitting Rust");
      Emit_Native_Rust.Compile_To_File (Tree (Root), Final_Output);
      Log ("ALBR: emitted " & Final_Output);

      if Build_Mode then
         Build_OK := Rustc_Build (Final_Output);
         if not Build_OK then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end if;

      if Metrics_Mode then
         Code_Information.Reset_Metrics;
         for I in 1 .. Include_Count loop
            Code_Information.Scan_Target (Include_Vault (I) (1 .. Include_Lens (I)));
         end loop;
         Code_Information.Print_Metrics;
      end if;

      if Run_Mode then
         if not Build_OK then
            Put_Line ("ALBR: skipping --run because rustc build failed.");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         elsif not Run_Exe (Final_Output) then
            Put_Line ("ALBR: failed to run generated executable.");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end if;
   end;

exception
   when E : Program_Error =>
      declare
         Msg : constant String := Ada.Exceptions.Exception_Message (E);
      begin
         if Msg'Length > 0 then
            Put_Line ("ALBR: " & Msg);
         end if;
      end;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   when E : others =>
      Put_Line ("ALBR: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end ALBR;
