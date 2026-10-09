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

with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Environment_Variables;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with GNAT.OS_Lib;
with AyeNEye;
with Alb_MSVC;


procedure ALB is
   use type GNAT.OS_Lib.String_Access;

   Version : constant String := "0.2.0";

   package Dependency_INI is new AyeNEye
     (Max_Sections => 8,
      Max_Keys     => 32,
      Max_Line_Len => 512);
   use type Dependency_INI.Load_Result;

   Dependency_Config : Dependency_INI.Config_Data;
   Dependency_Result : Dependency_INI.Load_Result;
   Allow_System_Fallback : Boolean := False;

   type Backend_Record is record
      Name        : String (1 .. 12);
      Name_Len    : Natural;
      Executable  : String (1 .. 24);
      Exec_Len    : Natural;
      Description : String (1 .. 52);
      Desc_Len    : Natural;
   end record;

   type Backend_Array is array (Positive range <>) of Backend_Record;

   function Padded (Text : String; Size : Positive) return String is
      Result : String (1 .. Size) := (others => ' ');
   begin
      Result (1 .. Text'Length) := Text;
      return Result;
   end Padded;

   Backends : constant Backend_Array :=
     ((Padded ("native", 12), 6, Padded ("albt.exe", 24), 8, Padded ("Universal compiler: FASM, FASM16, C, Ada and more", 52), 52),
      (Padded ("brainfuck", 12), 9, Padded ("albf.exe", 24), 8, Padded ("Brainfuck (ALBB) native emitter", 52), 31),
      (Padded ("web", 12), 3, Padded ("albw.exe", 24), 8, Padded ("TypeScript and browser/Node compiler", 52), 36),
      (Padded ("java", 12), 4, Padded ("albj.exe", 24), 8, Padded ("Java and FlatJVM compiler", 52), 26),
      (Padded ("dotnet", 12), 6, Padded ("albn.exe", 24), 8, Padded (".NET and C# compiler", 52), 20),
      (Padded ("ada", 12), 3, Padded ("alba.exe", 24), 8, Padded ("Native Ada compiler", 52), 19),
      (Padded ("python", 12), 6, Padded ("albp.exe", 24), 8, Padded ("Python compiler", 52), 15),
      (Padded ("c64", 12), 3, Padded ("alb_65.exe", 24), 10, Padded ("Commodore 64 / 6502 compiler", 52), 30),
      (Padded ("godot", 12), 5, Padded ("albgd.exe", 24), 9, Padded ("Godot compiler", 52), 14),
      (Padded ("player", 12), 6, Padded ("alb_player.exe", 24), 14, Padded ("ALB program player", 52), 18),
      (Padded ("agent", 12), 5, Padded ("veronica_main.exe", 24), 17, Padded ("Veronica coding agent", 52), 21),
      (Padded ("prompt", 12), 6, Padded ("alb_prompt.exe", 24), 14, Padded ("Prompt and model utility", 52), 24),
      (Padded ("lua", 12), 3, Padded ("albl.exe", 24), 8, Padded ("Lua transpiler with SDL3 graphics", 52), 34),
      (Padded ("moon", 12), 4, Padded ("albm.exe", 24), 8, Padded ("MoonScript transpiler with SDL3 graphics", 52), 40),
      (Padded ("rust", 12), 4, Padded ("albr.exe", 24), 8, Padded ("Rust (rustc) transpiler", 52), 23),
      (Padded ("haskell", 12), 7, Padded ("albh.exe", 24), 8, Padded ("Haskell (GHC) transpiler with SDL3", 52), 35),
      (Padded ("odin", 12), 4, Padded ("albo.exe", 24), 8, Padded ("Odin transpiler with SDL3 graphics", 52), 35),
      (Padded ("nasm", 12), 4, Padded ("albnasm.exe", 24), 11, Padded ("NASM assembler backend (win64)", 52), 30));

   function Lower (Text : String) return String is
   begin
      return Ada.Characters.Handling.To_Lower (Text);
   end Lower;

   function Executable_Directory return String is
      Command : constant String := Ada.Command_Line.Command_Name;
   begin
      for I in reverse Command'Range loop
         if Command (I) = '\' or else Command (I) = '/' then
            return Command (Command'First .. I);
         end if;
      end loop;
      return Ada.Directories.Current_Directory & "\";
   end Executable_Directory;

   function SDK_Root return String is
      Bin_Dir : constant String := Ada.Directories.Containing_Directory
        (Ada.Command_Line.Command_Name);
      Raw_Root : constant String := Ada.Directories.Containing_Directory (Bin_Dir);
      Release_Root : constant String := Ada.Directories.Compose (Raw_Root, "release");
   begin
      if Ada.Directories.Exists (Ada.Directories.Compose (Raw_Root, "deps")) then
         return Raw_Root;
      elsif Ada.Directories.Exists (Ada.Directories.Compose (Release_Root, "deps")) then
         return Release_Root;
      end if;
      return Raw_Root;
   exception
      when others =>
         return Ada.Directories.Current_Directory;
   end SDK_Root;

   function Config_Path return String is
   begin
      return Ada.Directories.Compose
        (Ada.Directories.Compose (SDK_Root, "config"), "dependencies.ini");
   end Config_Path;

   procedure Load_Dependency_Config is
   begin
      Dependency_INI.Load_INI
        (Config_Path, Dependency_Config, Dependency_Result);
      if Dependency_Result = Dependency_INI.Success then
         Allow_System_Fallback := Dependency_INI.Get_Boolean
           (Dependency_Config, "dependencies", "allow_system_fallback", False);
      else
         Allow_System_Fallback := False;
      end if;
   end Load_Dependency_Config;

   function Join_Path (Root : String; Relative_Path : String) return String is
   begin
      if Root'Length > 0 and then
        (Root (Root'Last) = '\' or else Root (Root'Last) = '/')
      then
         return Root & Relative_Path;
      end if;
      return Root & "\" & Relative_Path;
   end Join_Path;

   procedure Configure_Dependency_Environment is
      Root : constant String := SDK_Root;
      Deps : constant String := Ada.Directories.Compose (Root, "deps");
      Bundled_Path : constant String :=
        Executable_Directory & ";" &
        Join_Path (Deps, "fasm") & ";" &
        Join_Path (Deps, "asm6f") & ";" &
        Join_Path (Deps, "NASM") & ";" &
        Join_Path (Deps, "w64devkit\bin") & ";" &
        Join_Path (Deps, "gnat_native_15.2.1\bin") & ";" &
        Join_Path (Deps, "gprbuild_25.0.1\bin") & ";" &
        Join_Path (Deps, "node") & ";" &
        Join_Path (Deps, "dotnet") & ";" &
        Join_Path (Deps, "graalvm\bin") & ";" &
        Join_Path (Deps, "jdk\bin") & ";" &
        Join_Path (Deps, "python") & ";" &
        Join_Path (Deps, "rust\bin") & ";" &
        Join_Path (Deps, "odin\dist") & ";" &
        Join_Path (Deps, "odin") & ";" &
        Join_Path (Deps, "sdl3\bin");
      Old_Path : constant String :=
        (if Ada.Environment_Variables.Exists ("PATH")
         then Ada.Environment_Variables.Value ("PATH") else "");
      System_Root : constant String :=
        (if Ada.Environment_Variables.Exists ("SystemRoot")
         then Ada.Environment_Variables.Value ("SystemRoot") else "C:\Windows");
      Base_System_Path : constant String :=
        System_Root & "\System32;" & System_Root;
   begin
      Ada.Environment_Variables.Set ("ALB_SDK_ROOT", Root);
      Ada.Environment_Variables.Set
        ("JAVA_HOME", Join_Path (Deps, "graalvm"));
      Ada.Environment_Variables.Set
        ("GRAALVM_HOME", Join_Path (Deps, "graalvm"));
      Ada.Environment_Variables.Set
        ("DOTNET_ROOT", Join_Path (Deps, "dotnet"));
      Ada.Environment_Variables.Set
        ("PYTHONHOME", Join_Path (Deps, "python"));
      Ada.Environment_Variables.Set
        ("PATH",
         Bundled_Path & ";" & Base_System_Path &
         (if Allow_System_Fallback and then Old_Path'Length > 0
          then ";" & Old_Path else ""));
   end Configure_Dependency_Environment;

   function Tool_Path (Name : String) return String is
      Key  : constant String := Lower (Name);
      Deps : constant String := Join_Path (SDK_Root, "deps");
   begin
      if Key = "fasm" then return Join_Path (Deps, "fasm\FASM.EXE"); end if;
      if Key = "asm6f" or else Key = "asm6f64" then return Join_Path (Deps, "asm6f\asm6f_64.exe"); end if;
      if Key = "asm6f32" then return Join_Path (Deps, "asm6f\asm6f_32.exe"); end if;
      if Key = "nasm" then return Join_Path (Deps, "NASM\nasm.exe"); end if;
      if Key = "ndisasm" then return Join_Path (Deps, "NASM\ndisasm.exe"); end if;
      if Key = "gcc" then return Join_Path (Deps, "w64devkit\bin\gcc.exe"); end if;
      if Key = "gprbuild" then return Join_Path (Deps, "gprbuild_25.0.1\bin\gprbuild.exe"); end if;
      if Key = "gnatmake" then return Join_Path (Deps, "gnat_native_15.2.1\bin\gnatmake.exe"); end if;
      if Key = "node" then return Join_Path (Deps, "node\node.exe"); end if;
      if Key = "tsc" then return Join_Path (Deps, "node\tsc.cmd"); end if;
      if Key = "dotnet" then return Join_Path (Deps, "dotnet\dotnet.exe"); end if;
      if Key = "java" then return Join_Path (Deps, "graalvm\bin\java.exe"); end if;
      if Key = "javac" then return Join_Path (Deps, "graalvm\bin\javac.exe"); end if;
      if Key = "native-image" then return Join_Path (Deps, "graalvm\bin\native-image.cmd"); end if;
      if Key = "python" or else Key = "py" then return Join_Path (Deps, "python\python.exe"); end if;
      if Key = "rustc" then return Join_Path (Deps, "rust\bin\rustc.exe"); end if;
      return "";
   end Tool_Path;

   procedure Run_Tool (Name : String; First : Positive) is
      Program : constant String := Tool_Path (Name);
      Count   : constant Natural := Ada.Command_Line.Argument_Count - First + 1;
      Args    : GNAT.OS_Lib.Argument_List (1 .. Count);
      Result  : Integer := -1;
   begin
      if Program'Length = 0 or else not Ada.Directories.Exists (Program) then
         Put_Line ("alb: unknown or missing bundled tool '" & Name & "'");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      for I in 1 .. Count loop
         Args (I) := new String'(Ada.Command_Line.Argument (First + I - 1));
      end loop;
      Result := GNAT.OS_Lib.Spawn (Program, Args);
      for I in Args'Range loop GNAT.OS_Lib.Free (Args (I)); end loop;
      if Result = 0 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      elsif Result in 1 .. 255 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Result));
      else
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   exception
      when E : others =>
         for I in Args'Range loop
            if Args (I) /= null then GNAT.OS_Lib.Free (Args (I)); end if;
         end loop;
         Put_Line ("alb: bundled tool failed: " & Ada.Exceptions.Exception_Message (E));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Run_Tool;

   procedure Run_Polyglot is
      Program : constant String := Tool_Path ("python");
      Script  : constant String := Join_Path (SDK_Root, "tools\alb_polyglot.py");
      Count   : constant Natural := Ada.Command_Line.Argument_Count;
      Args    : GNAT.OS_Lib.Argument_List (1 .. Count);
      Result  : Integer := -1;
   begin
      if not Ada.Directories.Exists (Program) or else not Ada.Directories.Exists (Script) then
         Put_Line ("alb: polyglot tool or bundled Python is missing");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      Args (1) := new String'(Script);
      for I in 2 .. Count loop
         Args (I) := new String'(Ada.Command_Line.Argument (I));
      end loop;
      Result := GNAT.OS_Lib.Spawn (Program, Args);
      for I in Args'Range loop GNAT.OS_Lib.Free (Args (I)); end loop;
      if Result = 0 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      elsif Result in 1 .. 255 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Result));
      else
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   exception
      when E : others =>
         for I in Args'Range loop
            if Args (I) /= null then GNAT.OS_Lib.Free (Args (I)); end if;
         end loop;
         Put_Line ("alb: polyglot tool failed: " & Ada.Exceptions.Exception_Message (E));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Run_Polyglot;

   procedure Run_Enable_Build
     (Child_Args   : GNAT.OS_Lib.Argument_List;
      Backend_Name : String;
      Verbose      : Boolean;
      Dry_Run      : Boolean) is
      Program : constant String := Tool_Path ("python");
      Script  : constant String := Join_Path (SDK_Root, "tools\alb_enable.py");
      Args    : GNAT.OS_Lib.Argument_List (1 .. Child_Args'Length + 4);
      Result  : Integer := -1;
   begin
      if not Ada.Directories.Exists (Program) or else not Ada.Directories.Exists (Script) then
         Put_Line ("alb: ENABLE build tool or bundled Python is missing");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      Args (1) := new String'(Script);
      Args (2) := new String'("enable-build");
      Args (3) := new String'("--enable-backend");
      Args (4) := new String'(Backend_Name);
      for I in Child_Args'Range loop
         Args (I - Child_Args'First + 5) := new String'(Child_Args (I).all);
      end loop;
      if Verbose or else Dry_Run then
         Put ("alb: " & Program);
         for I in Args'Range loop
            Put (" " & Args (I).all);
         end loop;
         New_Line;
      end if;
      if Dry_Run then
         for I in Args'Range loop GNAT.OS_Lib.Free (Args (I)); end loop;
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
         return;
      end if;
      Result := GNAT.OS_Lib.Spawn (Program, Args);
      for I in Args'Range loop GNAT.OS_Lib.Free (Args (I)); end loop;
      if Result = 0 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      elsif Result in 1 .. 255 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Result));
      else
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   exception
      when E : others =>
         for I in Args'Range loop
            if Args (I) /= null then GNAT.OS_Lib.Free (Args (I)); end if;
         end loop;
         Put_Line ("alb: ENABLE build failed: " & Ada.Exceptions.Exception_Message (E));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Run_Enable_Build;

   function Backend_Index (Text : String) return Natural is
      Key : constant String := Lower (Text);
   begin
      for I in Backends'Range loop
         if Key = Backends (I).Name (1 .. Backends (I).Name_Len)
           or else Key = Lower (Backends (I).Executable (1 .. Backends (I).Exec_Len))
         then
            return I;
         end if;
      end loop;
      if Key = "albt" or else Key = "fasm" or else Key = "fasm16" or else Key = "c" then return 1; end if;
      if Key = "brainfuck" or else Key = "bf" or else Key = "albf" or else Key = "albb" then return 2; end if;
      if Key = "albw" or else Key = "typescript" or else Key = "ts" then return 3; end if;
      if Key = "albl" or else Key = "lua" then return Backends'Last - 5; end if;
      if Key = "albm" or else Key = "moon" or else Key = "moonscript"
        or else Key = "alb-moon"
      then
         return Backends'Last - 4;
      end if;
      if Key = "albr" or else Key = "rust" or else Key = "rs" then
         return Backends'Last - 3;
      end if;
      if Key = "albh" or else Key = "haskell" or else Key = "hs" then
         return Backends'Last - 2;
      end if;
      if Key = "albo" or else Key = "odin" then
         return Backends'Last - 1;
      end if;
      if Key = "nasm" or else Key = "albnasm" or else Key = "alb-nasm" then
         return Backends'Last;
      end if;
      if Key = "albj" then return 4; end if;
      if Key = "albn" or else Key = "csharp" or else Key = "cs" then return 5; end if;
      if Key = "alba" then return 6; end if;
      if Key = "albp" or else Key = "py" then return 7; end if;
      if Key = "alb_65" or else Key = "6502" then return 8; end if;
      if Key = "albgd" then return 9; end if;
      return 0;
   end Backend_Index;

   procedure Print_Backends is
   begin
      Put_Line ("Available commands and managed executables:");
      for I in Backends'Range loop
         Put_Line
           ("  " & Backends (I).Name (1 .. Backends (I).Name_Len) &
            "  [" & Backends (I).Executable (1 .. Backends (I).Exec_Len) & "]  " &
            Backends (I).Description (1 .. Backends (I).Desc_Len));
      end loop;
   end Print_Backends;

   procedure Print_Help is
   begin
      Put_Line ("AdaLogic BASIC Master Compiler and Command Director");
      Put_Line ("alb.exe " & Version);
      New_Line;
      Put_Line ("USAGE");
      Put_Line ("  alb <backend> [backend options...] <source.alb>");
      Put_Line ("  alb compile --backend <backend> [backend options...] <source.alb>");
      Put_Line ("  alb help <backend>");
      Put_Line ("  alb doctor");
      Put_Line ("  alb deps");
      Put_Line ("  alb pkg <alb-pkg command...>");
      Put_Line ("  alb tool <name> [tool options...]");
      Put_Line ("  alb polyglot <inspect|build|run> <entry.alb> [options]");
      Put_Line ("  alb list");
      New_Line;
      Put_Line ("MASTER OPTIONS");
      Put_Line ("  --help, -h                 Show this comprehensive help");
      Put_Line ("  --version, -V              Show master-driver version");
      Put_Line ("  --list-backends, list      List managed compiler executables");
      Put_Line ("  --doctor, doctor           Check compilers and bundled dependencies");
      Put_Line ("  --deps, deps               Show version-locked dependency bundle status");
      Put_Line ("  pkg <cmd> [args]           Package manager (alb-pkg.exe)");
      Put_Line ("  tool <name> [args]         Run an exact bundled dependency executable");
      Put_Line ("  polyglot inspect <entry>   Show typed language modules");
      Put_Line ("  polyglot build <entry>     Build modules and the ALB host");
      Put_Line ("  polyglot run <entry>       Build and run the all-language program");
      Put_Line ("  --backend, -B <name>       Select backend in 'compile' form");
      Put_Line ("  --verbose                   Print the child command before execution");
      Put_Line ("  --dry-run                   Print routing without executing the child");
      Put_Line ("  --                          Pass every remaining argument to the child");
      New_Line;
      Put_Line ("COMPILER ROUTING");
      Put_Line ("  native, albt, fasm, fasm16, c   -> albt.exe");
      Put_Line ("  brainfuck, bf, albf, albb       -> albf.exe");
      Put_Line ("  web, albw, typescript, ts       -> albw.exe");
      Put_Line ("  lua, albl                      -> albl.exe");
      Put_Line ("  moon, moonscript, albm, alb-moon -> albm.exe");
      Put_Line ("  rust, albr, rs                   -> albr.exe");
      Put_Line ("  haskell, albh, hs                -> albh.exe");
      Put_Line ("  odin, albo                       -> albo.exe");
      Put_Line ("  nasm, albnasm, alb-nasm         -> albnasm.exe");
      Put_Line ("  java, albj                      -> albj.exe");
      Put_Line ("  dotnet, albn, csharp, cs        -> albn.exe");
      Put_Line ("  ada, alba                       -> alba.exe");
      Put_Line ("  python, albp, py                -> albp.exe");
      Put_Line ("  c64, alb_65, 6502               -> alb_65.exe");
      Put_Line ("  godot, albgd                    -> albgd.exe");
      Put_Line ("  player                          -> alb_player.exe");
      Put_Line ("  agent                           -> veronica_main.exe");
      Put_Line ("  prompt                          -> alb_prompt.exe");
      New_Line;
      Put_Line ("ENABLE RUNTIME BLOCKS");
      Put_Line ("  native/python/java/dotnet/ada   Build ENABLEC/ADA/ASM/PYTHON/JAVA/CSHARP/TS modules");
      Put_Line ("  web                             Build ENABLETYPESCRIPT/ENABLEJAVASCRIPT modules");
      Put_Line ("  .alb and .albi                  Foreign blocks may appear in entry or INCLUDE files");
      New_Line;
      Put_Line ("COMMON FORWARDED OPTIONS");
      Put_Line ("  -o <file>                  Output filename");
      Put_Line ("  --outdir <dir>             Output/build directory");
      Put_Line ("  --build, -b                Build or package after transpilation");
      Put_Line ("  --run                       Run when supported by the child compiler");
      Put_Line ("  --quiet, -q                Suppress child informational output");
      Put_Line ("  --metrics, -m              Print child compiler metrics");
      Put_Line ("  --walker, -w               Print AST/token diagnostics where supported");
      Put_Line ("  -t <target>                Select an albt native target");
      Put_Line ("  --dll                      Request albt shared-library output");
      Put_Line ("  --library                  Request a backend library build");
      Put_Line ("  --target <version>         TypeScript target for albw");
      Put_Line ("  --framework <tfm>          .NET target framework for albn");
      Put_Line ("  --langversion <version>    C# language version for albn");
      Put_Line ("  --gprbuild                  Build ALBA output with gprbuild");
      Put_Line ("  --gnatmake                  Build ALBA output with gnatmake");
      Put_Line ("  --emit-only                Emit assembly without assembling on alb_65");
      Put_Line ("  --parse-only               Stop after parsing on alb_65");
      Put_Line ("  --lex-only                 Stop after tokenization on alb_65");
      Put_Line ("  --gfx=<opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12>");
      Put_Line ("                             Select alb_gfx RHI backend DLL at compile time");
      New_Line;
      Put_Line ("SYSTEM INCLUDES");
      Put_Line ("  INCLUDE ""local.albi""       Relative/quoted include (source-local)");
      Put_Line ("  INCLUDE <alb_gfx.albi>     System/stdlib include under SDK stdlib/vendor/");
      New_Line;
      Put_Line ("HELP AND DISCOVERY");
      Put_Line ("  alb help native            Run albt.exe with its help request");
      Put_Line ("  alb help web               Run albw.exe --help");
      Put_Line ("  alb doctor                 Verify compilers and offline dependencies");
      Put_Line ("  alb deps                   Show bundled tool locations and fallback policy");
      Put_Line ("  alb pkg install core       Install lean toolchain packs (alb-pkg)");
      Put_Line ("  alb pkg install --project game.albproj");
      Put_Line ("  alb pkg list               List known packs");
      Put_Line ("  alb tool gcc --version     Run the bundled GCC directly");
      Put_Line ("  alb tool dotnet build      Build a generated C# project offline");
      Put_Line ("  alb tool node app.js       Run generated JavaScript offline");
      Put_Line ("  alb list                   Show aliases, executables, and roles");
      New_Line;
      Put_Line ("EXAMPLES");
      Put_Line ("  alb native game.alb -t fasm --build --outdir build/game");
      Put_Line ("  alb brainfuck foo.alb -o foo.bf");
      Put_Line ("  alb albt game.alb -t c -o game.c");
      Put_Line ("  alb web game.alb --build --target es2020");
      Put_Line ("  alb dotnet tool.alb --build --framework net8.0");
      Put_Line ("  alb ada simulation.alb --build --gprbuild");
      Put_Line ("  alb python report.alb --run");
      Put_Line ("  alb c64 demo.alb --build --outdir build/c64");
      Put_Line ("  alb compile --backend native game.alb -t fasm --build");
      Put_Line ("  alb --verbose native game.alb -t fasm --build");
      Put_Line ("  alb --dry-run web game.alb --build");
      Put_Line ("  alb nasm demo.alb --gfx=opengl --build --outdir _build");
      Put_Line ("  alb nasm demo.alb --gfx=vulkan --build");
      New_Line;
      Print_Backends;
      New_Line;
      Put_Line ("All unrecognized options after backend selection are forwarded unchanged.");
      Put_Line ("Use 'alb help <backend>' for the selected compiler's authoritative options.");
   end Print_Help;

   function Resolve_Executable (Index : Positive) return String is
      Leaf      : constant String := Backends (Index).Executable (1 .. Backends (Index).Exec_Len);
      Candidate : constant String := Executable_Directory & Leaf;
   begin
      if Ada.Directories.Exists (Candidate) then
         return Candidate;
      end if;
      return Leaf;
   exception
      when others =>
         return Leaf;
   end Resolve_Executable;

   procedure Print_Dependency_Status is
      Root : constant String := Ada.Directories.Compose (SDK_Root, "deps");
      procedure Show (Name : String; Relative_Path : String) is
         Full : constant String := Join_Path (Root, Relative_Path);
      begin
         Put_Line ("  " & Name & ": " &
           (if Ada.Directories.Exists (Full) then "ready" else "missing") &
           " (" & Full & ")");
      end Show;

      procedure Show_MSVC (Candidate : String) is
      begin
         Put_Line ("  MSVC environment: ready (" & Candidate & ")");
      end Show_MSVC;
   begin
      Put_Line ("ALB SDK dependency bundle");
      Put_Line ("  root: " & Root);
      Put_Line ("  manifest: " & Ada.Directories.Compose (Root, "manifest.ini"));
      Put_Line ("  system fallback: " & Boolean'Image (Allow_System_Fallback));
      Show ("FASM", "fasm\FASM.EXE");
      Show ("asm6f x64", "asm6f\asm6f_64.exe");
      Show ("NASM", "NASM\nasm.exe");
      Show ("GCC", "w64devkit\bin\gcc.exe");
      Show ("GNAT", "gnat_native_15.2.1\bin\gnat.exe");
      Show ("GPRbuild", "gprbuild_25.0.1\bin\gprbuild.exe");
      Show ("Node", "node\node.exe");
      Show ("TypeScript", "node\tsc.cmd");
      Show (".NET", "dotnet\dotnet.exe");
      Show ("Java", "graalvm\bin\java.exe");
      Show ("javac", "graalvm\bin\javac.exe");
      Show ("native-image", "graalvm\bin\native-image.cmd");
      declare
         VCVars64 : constant String := Alb_MSVC.Find_VCVars64_Bat;
      begin
         if VCVars64'Length > 0 then
            Show_MSVC (VCVars64);
         else
            Put_Line ("  MSVC environment: not bundled; install Microsoft C++ Build Tools");
            Put_Line ("    " & Alb_MSVC.Official_Build_Tools_URL);
         end if;
      end;
      Show ("Python", "python\python.exe");
      Show ("Rust", "rust\bin\rustc.exe");
      Show ("SDL3", "..\support\SDL3.dll");
   end Print_Dependency_Status;

   procedure Print_Doctor is
      Found : Boolean;
   begin
      Put_Line ("ALB master compiler doctor");
      Put_Line ("  master: " & Ada.Command_Line.Command_Name);
      Put_Line ("  directory: " & Executable_Directory);
      Put_Line ("  sdk root: " & SDK_Root);
      Put_Line ("  config: " & Config_Path);
      Put_Line ("  system fallback: " & Boolean'Image (Allow_System_Fallback));
      for I in Backends'Range loop
         declare
            Leaf      : constant String := Backends (I).Executable (1 .. Backends (I).Exec_Len);
            Candidate : constant String := Executable_Directory & Leaf;
            Located   : GNAT.OS_Lib.String_Access := null;
         begin
            Found := Ada.Directories.Exists (Candidate);
            if not Found then
               Located := GNAT.OS_Lib.Locate_Exec_On_Path (Leaf);
               Found := Located /= null;
            end if;
            Put_Line
              ("  " & Backends (I).Name (1 .. Backends (I).Name_Len) & ": " &
               (if I = 8 and then Found then "executable only; dependencies unbundled"
                elsif Found then "ready" else "missing") & " (" & Leaf & ")");
            if Located /= null then
               GNAT.OS_Lib.Free (Located);
            end if;
         end;
      end loop;
      New_Line;
      Print_Dependency_Status;
   end Print_Doctor;

   procedure Free is new Ada.Unchecked_Deallocation
     (String, GNAT.OS_Lib.String_Access);

   procedure Run_Child
     (Backend : Positive;
      First   : Positive;
      Skip_Backend_Option : Boolean;
      Verbose : Boolean;
      Dry_Run : Boolean)
   is
      Max_Args : constant Natural := Ada.Command_Line.Argument_Count;
      Args     : GNAT.OS_Lib.Argument_List (1 .. Max_Args);
      Count    : Natural := 0;
      Skip_Next : Boolean := False;
      Program  : constant String := Resolve_Executable (Backend);
      Exit_Code : Integer;
   begin
      for I in First .. Ada.Command_Line.Argument_Count loop
         if Skip_Next then
            Skip_Next := False;
         elsif Skip_Backend_Option and then
           (Lower (Ada.Command_Line.Argument (I)) = "--backend" or else
            Ada.Command_Line.Argument (I) = "-B")
         then
            Skip_Next := True;
         elsif Lower (Ada.Command_Line.Argument (I)) = "--verbose" or else
               Lower (Ada.Command_Line.Argument (I)) = "--dry-run"
         then
            null;
         else
            Count := Count + 1;
            Args (Count) := new String'(Ada.Command_Line.Argument (I));
         end if;
      end loop;

      if Verbose or else Dry_Run then
         Put ("alb: " & Program);
         for I in 1 .. Count loop
            Put (" " & Args (I).all);
         end loop;
         New_Line;
      end if;

      if Dry_Run then
         for I in 1 .. Count loop Free (Args (I)); end loop;
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
         return;
      end if;

      -- ENABLE foreign-block host path: native/web/java/dotnet/ada/python.
      -- brainfuck (2), c64 (8), godot (9), and utility backends spawn the
      -- child compiler directly — they do not support ENABLE modules.
      if Backend in 1 | 3 | 4 | 5 | 6 | 7 then
         for I in 1 .. Count loop
            declare
               Arg : constant String := Lower (Args (I).all);
            begin
               if ((Arg'Length >= 4
                    and then Arg (Arg'Last - 3 .. Arg'Last) = ".alb")
                   or else
                   (Arg'Length >= 5
                    and then Arg (Arg'Last - 4 .. Arg'Last) = ".albi"))
                 and then Ada.Directories.Exists (Args (I).all)
               then
                  Run_Enable_Build
                    (Args (1 .. Count),
                     Backends (Backend).Name (1 .. Backends (Backend).Name_Len),
                     Verbose,
                     Dry_Run);
                  for J in 1 .. Count loop Free (Args (J)); end loop;
                  return;
               end if;
            end;
         end loop;
      end if;

      Exit_Code := GNAT.OS_Lib.Spawn (Program, Args (1 .. Count));
      for I in 1 .. Count loop Free (Args (I)); end loop;
      if Exit_Code = 0 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      else
         Put_Line ("alb: child exited with status" & Integer'Image (Exit_Code));
         if Exit_Code in 1 .. 255 then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Exit_Code));
         else
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end if;
   exception
      when E : others =>
         for I in 1 .. Count loop
            if Args (I) /= null then Free (Args (I)); end if;
         end loop;
         Put_Line ("alb: failed to start child: " & Ada.Exceptions.Exception_Message (E));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Run_Child;

   Count   : constant Natural := Ada.Command_Line.Argument_Count;
   Backend : Natural := 0;
   First   : Positive := 1;
   Verbose : Boolean := False;
   Dry_Run : Boolean := False;
   Compile_Form : Boolean := False;
begin
   Load_Dependency_Config;
   Configure_Dependency_Environment;

   if Count = 0 then
      Print_Help;
      return;
   end if;

   for I in 1 .. Count loop
      if Lower (Ada.Command_Line.Argument (I)) = "--verbose" then Verbose := True; end if;
      if Lower (Ada.Command_Line.Argument (I)) = "--dry-run" then Dry_Run := True; end if;
   end loop;

   declare
      Command : constant String := Lower (Ada.Command_Line.Argument (1));
   begin
      if Command = "--help" or else Command = "-h" or else (Command = "help" and then Count = 1) then
         Print_Help;
         return;
      elsif Command = "--version" or else Command = "-v" then
         Put_Line ("alb.exe " & Version);
         return;
      elsif Command = "list" or else Command = "--list-backends" then
         Print_Backends;
         return;
      elsif Command = "doctor" or else Command = "--doctor" then
         Print_Doctor;
         return;
      elsif Command = "deps" or else Command = "--deps" then
         Print_Dependency_Status;
         return;
      elsif Command = "pkg" or else Command = "alb-pkg" then
         declare
            Pkg : constant String := Executable_Directory & "alb-pkg.exe";
            N   : constant Natural := Count - 1;
            Args : GNAT.OS_Lib.Argument_List (1 .. Natural'Max (N, 1));
            Result : Integer := -1;
            Used : Natural := 0;
         begin
            if not Ada.Directories.Exists (Pkg) then
               Put_Line ("alb: missing alb-pkg.exe next to alb.exe");
               Put_Line ("Expected: " & Pkg);
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
               return;
            end if;
            if N = 0 then
               Args (1) := new String'("help");
               Used := 1;
            else
               for I in 2 .. Count loop
                  Used := Used + 1;
                  Args (Used) := new String'(Ada.Command_Line.Argument (I));
               end loop;
            end if;
            if Verbose or else Dry_Run then
               Put ("alb: " & Pkg);
               for I in 1 .. Used loop
                  Put (" " & Args (I).all);
               end loop;
               New_Line;
            end if;
            if Dry_Run then
               for I in 1 .. Used loop Free (Args (I)); end loop;
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
               return;
            end if;
            Result := GNAT.OS_Lib.Spawn (Pkg, Args (1 .. Used));
            for I in 1 .. Used loop Free (Args (I)); end loop;
            if Result = 0 then
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
            elsif Result in 1 .. 255 then
               Ada.Command_Line.Set_Exit_Status
                 (Ada.Command_Line.Exit_Status (Result));
            else
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            end if;
         end;
         return;
      elsif Command = "tool" and then Count >= 2 then
         Run_Tool (Ada.Command_Line.Argument (2), 3);
         return;
      elsif Command = "polyglot" and then Count >= 3 then
         Run_Polyglot;
         return;
      elsif Command = "help" and then Count >= 2 then
         Backend := Backend_Index (Ada.Command_Line.Argument (2));
         if Backend = 0 then
            Put_Line ("alb: unknown backend '" & Ada.Command_Line.Argument (2) & "'");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;
         declare
            Help_Args : GNAT.OS_Lib.Argument_List (1 .. 1) := (1 => new String'("--help"));
            Result    : constant Integer := GNAT.OS_Lib.Spawn (Resolve_Executable (Backend), Help_Args);
         begin
            Free (Help_Args (1));
            if Result /= 0 then Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure); end if;
         end;
         return;
      elsif Command = "compile" then
         Compile_Form := True;
         First := 2;
         for I in 2 .. Count - 1 loop
            if Lower (Ada.Command_Line.Argument (I)) = "--backend" or else
              Ada.Command_Line.Argument (I) = "-B"
            then
               Backend := Backend_Index (Ada.Command_Line.Argument (I + 1));
               exit;
            end if;
         end loop;
      else
         Backend := Backend_Index (Ada.Command_Line.Argument (1));
         First := 2;
         if Backend = 0 and then (Command = "--verbose" or else Command = "--dry-run") and then Count >= 2 then
            Backend := Backend_Index (Ada.Command_Line.Argument (2));
            First := 3;
         end if;
      end if;
   end;

   if Backend = 0 then
      Put_Line ("alb: no valid backend selected");
      Put_Line ("Run 'alb --help' or 'alb list' for available routes.");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Run_Child (Backend, First, Compile_Form, Verbose, Dry_Run);
end ALB;
