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
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Streams.Stream_IO;
with Ada.Text_IO; use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with Parser;         use Parser;
with AST;            use AST;
with Emit_Native_Lua;
with Code_Information;
with GNAT.OS_Lib;    use GNAT.OS_Lib;
with ALB_System_Includes;


procedure ALBL is

   Max_Path_Len   : constant := 512;
   Max_Includes   : constant := 2048;
   Max_Input_Size : constant := Input_Buffer'Length;
   Max_Stage_Assets : constant := 256;

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
   Stage_Assets  : array (1 .. Max_Stage_Assets) of String (1 .. Max_Path_Len) :=
     (others => (others => ' '));
   Stage_Asset_Lens : array (1 .. Max_Stage_Assets) of Natural := (others => 0);
   Stage_Asset_Count : Natural := 0;
   Module_Aware_Output : Boolean := False;
   Exit_Failed         : Boolean := False;

   Quiet_Mode     : Boolean := False;
   Metrics_Mode   : Boolean := False;
   Walker_Mode    : Boolean := False;
   Build_Mode     : Boolean := False;
   Run_Mode       : Boolean := False;
   Out_Dir        : String (1 .. Max_Path_Len) := (others => ' ');
   Out_Dir_Len    : Natural := 0;

   Source_File    : String (1 .. Max_Path_Len) := (others => ' ');
   Source_Len     : Natural := 0;
   Output_File    : String (1 .. Max_Path_Len) := (others => ' ');
   Output_Len     : Natural := 0;

   type Arg_List is array (Positive range <>) of String_Access;

   procedure Free (Args : in out Arg_List) is
   begin
      for I in Args'Range loop
         Free (Args (I));
      end loop;
   end Free;

   function To_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      end if;
      return Ch;
   end To_Upper;

   function Trim_Image (N : Integer) return String is
      S : constant String := Integer'Image (N);
      F : Positive := S'First;
   begin
      while F < S'Last and then S (F) = ' ' loop
         F := F + 1;
      end loop;
      return S (F .. S'Last);
   end Trim_Image;

    function Safe_Identifier (Name : String) return String is
       Result : String (1 .. Name'Length) := Name;
    begin
       for I in Result'Range loop
          if Result (I) = '.' then
             Result (I) := '_';
          end if;
       end loop;
       return Result;
    end Safe_Identifier;

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
          Raw  : constant String := Ada.Directories.Base_Name (Path);
          Dot  : Natural := 0;
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

   function Default_Output_Name (Input : String) return String is
   begin
      return Base_Name (Input) & ".lua";
   end Default_Output_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "lua_" & Base_Name (Input);
   end Default_Out_Dir;

   procedure Print_Help is
   begin
      Put_Line ("ALBL: AdaLogic BASIC Lua transpiler (SDL3 via LuaJIT FFI)");
      Put_Line ("Usage: albl [options] <input.alb> [output.lua]");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  -o <file>        Output .lua file (default: derived from input name)");
      Put_Line ("  --outdir <dir>   Output directory (default: current dir, or lua_<name> with --build)");
      Put_Line ("  --metrics, -m    Show code metrics after compilation");
      Put_Line ("  --walker, -w     Show AST structure and token information");
      Put_Line ("  --quiet, -q      Suppress informational messages");
      Put_Line ("  --build, -b      Transpile and stage SDL3.dll + run.bat beside the .lua");
      Put_Line ("  --run, -r        After emit, run with LuaJIT (needs SDL3.dll on PATH/cwd)");
      Put_Line ("  --help, -h       Show this help");
      New_Line;
      Put_Line ("Runtime: LuaJIT + SDL3.dll (same graphics model as FASM/C backends).");
   end Print_Help;

   function Spawn_And_Check
     (Working_Dir : String;
      Program     : String;
      Args        : Arg_List) return Boolean
   is
      Original_Dir : constant String := Ada.Directories.Current_Directory;
      Exit_Code    : Integer := -1;
      Ada_Args     : GNAT.OS_Lib.Argument_List (1 .. Args'Length);
   begin
      for I in Args'Range loop
         Ada_Args (I) := Args (I);
      end loop;
      Ada.Directories.Set_Directory (Working_Dir);
      Exit_Code := GNAT.OS_Lib.Spawn (Program, Ada_Args);
      Ada.Directories.Set_Directory (Original_Dir);
      return Exit_Code = 0;
   exception
      when others =>
         begin
            Ada.Directories.Set_Directory (Original_Dir);
         exception
            when others => null;
         end;
         return False;
   end Spawn_And_Check;

    procedure Write_Index_HTML
      (Dir          : String;
       Title        : String;
       JS_Name      : String;
       Module_Aware : Boolean)
    is
       HTML_Path : constant String := Ada.Directories.Compose (Dir, "index.html");
       File      : Ada.Text_IO.File_Type;
    begin
       Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, HTML_Path);
       Ada.Text_IO.Put_Line (File, "<!doctype html>");
       Ada.Text_IO.Put_Line (File, "<html lang=""en"">");
       Ada.Text_IO.Put_Line (File, "<head>");
       Ada.Text_IO.Put_Line (File, "  <meta charset=""utf-8"">");
       Ada.Text_IO.Put_Line (File, "  <meta name=""viewport"" content=""width=device-width, initial-scale=1"">");
       Ada.Text_IO.Put_Line (File, "  <title>" & Title & "</title>");
       Ada.Text_IO.Put_Line (File, "  <style>");
       Ada.Text_IO.Put_Line (File, "    html, body { margin: 0; padding: 0; width: 100%; min-height: 100%; background: #050511; color: #fff; font-family: Consolas, monospace; }");
       Ada.Text_IO.Put_Line (File, "    body { position: relative; }");
       Ada.Text_IO.Put_Line (File, "  </style>");
       Ada.Text_IO.Put_Line (File, "</head>");
       Ada.Text_IO.Put_Line (File, "<body>");
       Ada.Text_IO.Put_Line (File, "  <script>");
       Ada.Text_IO.Put_Line (File, "    (function () {");
       Ada.Text_IO.Put_Line (File, "      function launch() {");
       Ada.Text_IO.Put_Line (File, "        var script = document.createElement('script');");
       if Module_Aware then
          Ada.Text_IO.Put_Line (File, "        script.type = 'module';");
       end if;
       Ada.Text_IO.Put_Line (File, "        script.src = './" & JS_Name & "';");
       Ada.Text_IO.Put_Line (File, "        document.body.appendChild(script);");
       Ada.Text_IO.Put_Line (File, "      }");
       Ada.Text_IO.Put_Line (File, "      if (document.readyState === 'complete') {");
       Ada.Text_IO.Put_Line (File, "        setTimeout(launch, 0);");
       Ada.Text_IO.Put_Line (File, "      } else {");
       Ada.Text_IO.Put_Line (File, "        window.addEventListener('load', function () { setTimeout(launch, 0); }, { once: true });");
       Ada.Text_IO.Put_Line (File, "      }");
       Ada.Text_IO.Put_Line (File, "    }());");
       Ada.Text_IO.Put_Line (File, "  </script>");
       Ada.Text_IO.Put_Line (File, "</body>");
       Ada.Text_IO.Put_Line (File, "</html>");
       Ada.Text_IO.Close (File);
    end Write_Index_HTML;

    procedure Write_Tsconfig
      (Dir          : String;
       TS_Name      : String;
       JS_Name      : String;
       Target       : String;
       Module_Aware : Boolean)
    is
       Config_Path : constant String := Ada.Directories.Compose (Dir, "tsconfig.json");
       File        : Ada.Text_IO.File_Type;
       TS_Target   : String (1 .. 16) := (others => ' ');
       TS_TLen     : Natural := Target'Length;
    begin
       if TS_TLen = 0 then
          TS_TLen := 6;
          TS_Target (1 .. 6) := "es2020";
       else
          TS_Target (1 .. TS_TLen) := Target;
       end if;
       Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Config_Path);
       Ada.Text_IO.Put_Line (File, "{");
       Ada.Text_IO.Put_Line (File, "  ""compilerOptions"": {");
       Ada.Text_IO.Put_Line (File, "    ""target"": """ & TS_Target (1 .. TS_TLen) & """,");
       if Module_Aware then
          Ada.Text_IO.Put_Line (File, "    ""module"": ""es2020"",");
          Ada.Text_IO.Put_Line (File, "    ""moduleResolution"": ""node"",");
       else
          Ada.Text_IO.Put_Line (File, "    ""module"": ""none"",");
          Ada.Text_IO.Put_Line (File, "    ""outFile"": """ & JS_Name & """,");
       end if;
       Ada.Text_IO.Put_Line (File, "    ""strict"": false,");
       Ada.Text_IO.Put_Line (File, "    ""noImplicitAny"": false,");
       Ada.Text_IO.Put_Line (File, "    ""noCheck"": true,");
       Ada.Text_IO.Put_Line (File, "    ""ignoreDeprecations"": ""6.0"",");
       Ada.Text_IO.Put_Line (File, "    ""lib"": [""es2020"", ""dom""]");
       Ada.Text_IO.Put_Line (File, "  },");
       Ada.Text_IO.Put_Line (File, "  ""files"": [""" & TS_Name & """]");
       Ada.Text_IO.Put_Line (File, "}");
       Ada.Text_IO.Close (File);
    end Write_Tsconfig;

   procedure Print_Walker_Info is
   begin
      New_Line;
      Put_Line ("=== ALBL Walker ===");
      Put_Line ("Token count : " & Trim_Image (Token_Count));
      Put_Line ("Source size : " & Trim_Image (Input_Len) & " bytes");
      Put_Line ("Include count: " & Trim_Image (Include_Count));
      New_Line;
      for I in 1 .. Include_Count loop
         Put_Line ("  included: " & Include_Vault (I) (1 .. Include_Lens (I)));
      end loop;
      New_Line;
      Put_Line ("=== AST Root ===");
      if Root > 0 then
         Put_Line ("  Kind   : " & Node_Kind'Image (Tree (Root).Kind));
         Put_Line ("  Token  : " & Trim_Image (Tree (Root).Token_Index));
         Put_Line ("  Left   : " & Trim_Image (Tree (Root).Left_Child));
         Put_Line ("  Right  : " & Trim_Image (Tree (Root).Right_Child));
         Put_Line ("  Sibling: " & Trim_Image (Tree (Root).Next_Sibling));
      else
         Put_Line ("  (null)");
      end if;
      New_Line;
   end Print_Walker_Info;

   function Resolve_Local_Asset_Path
     (Raw_Path : String;
      Base_Dir   : String) return String;

   procedure Log (Msg : String) is
   begin
      if not Quiet_Mode then
         Put_Line (Msg);
      end if;
   end Log;

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
                          ("ALBL: FATAL: System include not found: <"
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
                       Resolve_Local_Asset_Path (Raw_Include, File_Dir);
                  begin
                     if Resolved_Path'Length = 0
                       or else Resolved_Path'Length > Max_Path_Len
                     then
                        Put_Line
                          ("ALBL: include not found: " & Raw_Include & " (from "
                           & File_Name & ")");
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
         Ada.Streams.Stream_IO.Open
           (File,
            Ada.Streams.Stream_IO.In_File,
            File_Name);
         Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);
      exception
         when E : others =>
            Put_Line ("ALBL: could not open source file: " & File_Name & " - " &
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
         Put_Line ("ALBL: weave failure in " & File_Name & " - " &
           Ada.Exceptions.Exception_Message (E));
         Success := False;
         begin
            Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               null;
         end;
   end Weave_File;

   function Strip_String_Node (Idx : Node_Index) return String is
      Tok : Token := Tokens (Tree (Idx).Token_Index);
   begin
      if Tok.Length >= 2 then
         return Input_Buffer (Tok.Start + 1 .. Tok.Start + Tok.Length - 2);
      else
         return "";
      end if;
   end Strip_String_Node;

   function Path_Exists (Path : String) return Boolean is
   begin
      return Path'Length > 0 and then Ada.Directories.Exists (Path);
   exception
      when others =>
         return False;
   end Path_Exists;

   function Resolve_Local_Asset_Path
     (Raw_Path : String;
      Base_Dir : String) return String
   is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);
      function Join_Base_Path (Dir : String; Leaf : String) return String is
      begin
         if Leaf'Length = 0 then
            return Dir;
         elsif Dir'Length = 0 then
            return Leaf;
         elsif Leaf (Leaf'First) = '\' or else Leaf (Leaf'First) = '/' then
            return Leaf;
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
         else
            for I in Leaf'Range loop
               if Leaf (I) = '\' or else Leaf (I) = '/' then
                  if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
                     return Dir & Leaf;
                  else
                     return Dir & "\" & Leaf;
                  end if;
               end if;
            end loop;
            return Ada.Directories.Compose (Dir, Leaf);
         end if;
      end Join_Base_Path;
   begin
      if Trimmed'Length = 0 then
         return "";
      elsif Path_Exists (Trimmed) then
         return Trimmed;
      elsif Base_Dir'Length > 0 then
         declare
            Candidate : constant String := Join_Base_Path (Base_Dir, Trimmed);
         begin
            if Path_Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end if;

      declare
         Candidate : constant String := Join_Base_Path
           (Ada.Directories.Current_Directory, Trimmed);
      begin
         if Path_Exists (Candidate) then
            return Candidate;
         end if;
      end;

      return "";
   end Resolve_Local_Asset_Path;

   procedure Register_Stage_Asset (File_Name : String) is
   begin
      if File_Name'Length = 0 or else File_Name'Length > Max_Path_Len then
         return;
      end if;

      for I in 1 .. Stage_Asset_Count loop
         if Stage_Asset_Lens (I) = File_Name'Length
           and then Stage_Assets (I) (1 .. File_Name'Length) = File_Name
         then
            return;
         end if;
      end loop;

      if Stage_Asset_Count < Max_Stage_Assets then
         Stage_Asset_Count := Stage_Asset_Count + 1;
         Stage_Asset_Lens (Stage_Asset_Count) := File_Name'Length;
         Stage_Assets (Stage_Asset_Count) := (others => ' ');
         Stage_Assets (Stage_Asset_Count) (1 .. File_Name'Length) := File_Name;
      end if;
   end Register_Stage_Asset;

   procedure Scan_Web_Features (First : Node_Index) is
      Curr     : Node_Index := First;
      Source_Dir : constant String := Parent_Directory (Source_File (1 .. Source_Len));
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Import_ES | AST_Import_WASM =>
               Module_Aware_Output := True;
               if Tree (Curr).Right_Child > 0 then
                  declare
                     Resolved : constant String :=
                       Resolve_Local_Asset_Path
                         (Strip_String_Node (Tree (Curr).Right_Child),
                          Source_Dir);
                  begin
                     if Resolved'Length > 0 then
                        Register_Stage_Asset (Resolved);
                     end if;
                  end;
               end if;

            when AST_Export_ES | AST_Export_WASM =>
               Module_Aware_Output := True;

            when others =>
               null;
         end case;

         if Tree (Curr).Left_Child > 0 then
            Scan_Web_Features (Tree (Curr).Left_Child);
         end if;
         if Tree (Curr).Right_Child > 0 then
            Scan_Web_Features (Tree (Curr).Right_Child);
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Scan_Web_Features;

   function Source_Wants_No_Console return Boolean is
      Sample : constant String := Input_Buffer (1 .. Input_Len);
   begin
      return Ada.Strings.Fixed.Index (Sample, "NO CONSOLE") > 0
        or else Ada.Strings.Fixed.Index (Sample, "MODE NO CONSOLE") > 0;
   end Source_Wants_No_Console;

   procedure Copy_Stage_Assets (Dest_Dir : String) is
   begin
      for I in 1 .. Stage_Asset_Count loop
         declare
            Source_Path : constant String := Stage_Assets (I) (1 .. Stage_Asset_Lens (I));
            Dest_Path   : constant String := Ada.Directories.Compose
              (Dest_Dir,
               Ada.Directories.Base_Name (Source_Path));
         begin
            if Source_Path /= Dest_Path then
               Ada.Directories.Copy_File (Source_Path, Dest_Path);
            end if;
         exception
            when others =>
               Put_Line ("ALBL: failed to stage asset " & Source_Path);
         end;
      end loop;
   end Copy_Stage_Assets;


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

   function Find_SDL3_DLL return String is
      Root : constant String := SDK_Root;
   begin
      declare
         A : constant String := Ada.Directories.Compose
           (Ada.Directories.Compose (Root, "bin"), "SDL3.dll");
         B : constant String := Ada.Directories.Compose
           (Ada.Directories.Compose (Root, "support"), "SDL3.dll");
         C : constant String := Ada.Directories.Compose
           (Ada.Directories.Compose
              (Ada.Directories.Compose (Root, "deps"), "fasm"), "SDL3.dll");
      begin
         if Ada.Directories.Exists (A) then
            return A;
         elsif Ada.Directories.Exists (B) then
            return B;
         elsif Ada.Directories.Exists (C) then
            return C;
         end if;
      end;
      return "";
   end Find_SDL3_DLL;

   function Find_LuaJIT return String is
      Root : constant String := SDK_Root;
      A : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose
           (Ada.Directories.Compose (Root, "deps"), "luajit"), "luajit.exe");
      B : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose
           (Ada.Directories.Compose (Root, "deps"), "luajit"), "lua.exe");
      C : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose (Root, "bin"), "luajit.exe");
      D : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose (Root, "bin"), "lua.exe");
   begin
      if Ada.Directories.Exists (A) then
         return A;
      elsif Ada.Directories.Exists (B) then
         return B;
      elsif Ada.Directories.Exists (C) then
         return C;
      elsif Ada.Directories.Exists (D) then
         return D;
      elsif Locate_Exec_On_Path ("luajit.exe") /= null then
         declare
            P : String_Access := Locate_Exec_On_Path ("luajit.exe");
            R : constant String := P.all;
         begin
            Free (P);
            return R;
         end;
      elsif Locate_Exec_On_Path ("lua.exe") /= null then
         declare
            P : String_Access := Locate_Exec_On_Path ("lua.exe");
            R : constant String := P.all;
         begin
            Free (P);
            return R;
         end;
      end if;
      return "";
   end Find_LuaJIT;

   procedure Stage_SDL3_Runtime (Lua_Path : String) is
      Dir : constant String := Ada.Directories.Containing_Directory (Lua_Path);
      Src : constant String := Find_SDL3_DLL;
      Dest : constant String := Ada.Directories.Compose (Dir, "SDL3.dll");
      Bat  : constant String := Ada.Directories.Compose (Dir, "run.bat");
      File : Ada.Text_IO.File_Type;
      LJ   : constant String := Find_LuaJIT;
      Lua_Name : constant String := Ada.Directories.Simple_Name (Lua_Path);
      Root : constant String := SDK_Root;
      Lua_Deps : constant String := Ada.Directories.Compose
        (Ada.Directories.Compose (Root, "deps"), "luajit");

      procedure Stage_One (Name : String) is
         From : constant String := Ada.Directories.Compose (Lua_Deps, Name);
         To   : constant String := Ada.Directories.Compose (Dir, Name);
      begin
         if Ada.Directories.Exists (From) then
            Ada.Directories.Copy_File (From, To);
            Log ("ALBL: staged " & Name);
         end if;
      exception
         when others =>
            Put_Line ("ALBL: could not stage " & Name);
      end Stage_One;
   begin
      if Src'Length > 0 then
         begin
            Ada.Directories.Copy_File (Src, Dest);
            Log ("ALBL: staged SDL3.dll");
         exception
            when others =>
               Put_Line ("ALBL: could not stage SDL3.dll from " & Src);
         end;
      else
         Put_Line ("ALBL: warning: SDL3.dll not found under SDK; copy it beside the .lua before running");
      end if;

      Stage_One ("alb_sdl3.dll");
      Stage_One ("lua54.dll");
      Stage_One ("lua.exe");
      Stage_One ("luajit.exe");

      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Bat);
      Ada.Text_IO.Put_Line (File, "@echo off");
      Ada.Text_IO.Put_Line (File, "setlocal");
      Ada.Text_IO.Put_Line (File, "cd /d ""%~dp0""");
      if LJ'Length > 0 then
         Ada.Text_IO.Put_Line (File, """" & LJ & """ """ & Lua_Name & """ %*");
      else
         Ada.Text_IO.Put_Line (File, "lua """ & Lua_Name & """ %*");
      end if;
      Ada.Text_IO.Close (File);
      Log ("ALBL: wrote " & Bat);
   end Stage_SDL3_Runtime;

   function Run_With_LuaJIT (Lua_Path : String) return Boolean is
      LJ : constant String := Find_LuaJIT;
      Dir : constant String := Ada.Directories.Containing_Directory (Lua_Path);
      Name : constant String := Ada.Directories.Simple_Name (Lua_Path);
      Args : Arg_List (1 .. 1);
      OK : Boolean;
   begin
      if LJ'Length = 0 then
         Put_Line ("ALBL: luajit.exe not found (expected deps\\luajit\\luajit.exe or PATH)");
         return False;
      end if;
      -- Ensure SDL3 is beside the script for LoadLibrary
      declare
         Dest : constant String := Ada.Directories.Compose (Dir, "SDL3.dll");
         Src  : constant String := Find_SDL3_DLL;
      begin
         if not Ada.Directories.Exists (Dest) and then Src'Length > 0 then
            Ada.Directories.Copy_File (Src, Dest);
         end if;
      exception
         when others => null;
      end;
      Args (1) := new String'(Name);
      OK := Spawn_And_Check (Dir, LJ, Args);
      Free (Args);
      return OK;
   end Run_With_LuaJIT;

   procedure Parse_Args is
      Skip_Next : Boolean := False;
   begin
      for I in 1 .. Ada.Command_Line.Argument_Count loop
         if Skip_Next then
            Skip_Next := False;
         else
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
                       ("ALBL: FATAL: Unknown --gfx backend (use opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12).");
                     return;
                  end if;
                  if Gfx_Skip then
                     Skip_Next := True;
                  end if;
               elsif Arg = "-o" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Output_Len := N'Length;
                        Output_File (1 .. Output_Len) := N;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBL: '-o' requires a filename.");
                     return;
                  end if;
               elsif Arg = "--outdir" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Out_Dir_Len := N'Length;
                        Out_Dir (1 .. Out_Dir_Len) := N;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBL: '--outdir' requires a directory.");
                     return;
                  end if;
               elsif Arg = "--metrics" or else Arg = "-m" then
                  Metrics_Mode := True;
               elsif Arg = "--walker" or else Arg = "-w" then
                  Walker_Mode := True;
               elsif Arg = "--quiet" or else Arg = "-q" then
                  Quiet_Mode := True;
               elsif Arg = "--build" or else Arg = "-b" then
                  Build_Mode := True;
               elsif Arg = "--run" or else Arg = "-r" then
                  Run_Mode := True;
               elsif Arg = "--help" or else Arg = "-h" then
                  Print_Help;
                  return;
               elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
                  Put_Line ("ALBL: unknown option " & Arg);
                  return;
               else
                  if Source_Len = 0 then
                     Source_Len := Arg'Length;
                     Source_File (1 .. Source_Len) := Arg;
                  elsif Output_Len = 0 then
                     Output_Len := Arg'Length;
                     Output_File (1 .. Output_Len) := Arg;
                  else
                     Put_Line ("ALBL: unexpected extra argument " & Arg);
                     return;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Parse_Args;

    TS_Path       : String (1 .. Max_Path_Len) := (others => ' ');
   TS_Len        : Natural := 0;
   Final_Dir     : String (1 .. Max_Path_Len) := (others => ' ');
   Final_Dir_Len : Natural := 0;
   Final_Title   : String (1 .. Max_Path_Len) := (others => ' ');
   Final_Title_Len : Natural := 0;
   Success       : Boolean := True;

begin
   Parse_Args;

   if Source_Len = 0 then
      Put_Line ("ALBL: no input file specified.");
      Print_Help;
      return;
   end if;

   declare
      T : constant String := Base_Name (Source_File (1 .. Source_Len));
   begin
      Final_Title_Len := T'Length;
      Final_Title (1 .. Final_Title_Len) := T;
   end;

   -- Determine output .ts path
   if Output_Len = 0 then
      if Build_Mode then
         if Out_Dir_Len = 0 then
            Out_Dir_Len := Default_Out_Dir (Source_File (1 .. Source_Len))'Length;
            Out_Dir (1 .. Out_Dir_Len) := Default_Out_Dir (Source_File (1 .. Source_Len));
         end if;
         Final_Dir_Len := Out_Dir_Len;
         Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
         declare
            N : constant String := Ada.Directories.Compose
              (Final_Dir (1 .. Final_Dir_Len), Default_Output_Name (Source_File (1 .. Source_Len)));
         begin
            TS_Len := N'Length;
            TS_Path (1 .. TS_Len) := N;
         end;
      else
         if Out_Dir_Len > 0 then
            declare
               N : constant String := Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Default_Output_Name (Source_File (1 .. Source_Len)));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end;
         else
            declare
               N : constant String := Default_Output_Name (Source_File (1 .. Source_Len));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
            end;
         end if;
      end if;
   else
      --  Relative -o names must always land under --outdir when set.
      --  Do not trust Containing_Directory("") / "." quirks for bare filenames.
      declare
         Has_Dir_Sep : Boolean := False;
      begin
         for I in 1 .. Output_Len loop
            if Output_File (I) = '\' or else Output_File (I) = '/' then
               Has_Dir_Sep := True;
               exit;
            end if;
         end loop;

         if Out_Dir_Len > 0 and then not Has_Dir_Sep then
            declare
               N : constant String := Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Output_File (1 .. Output_Len));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end;
         elsif Out_Dir_Len > 0
           and then Ada.Directories.Containing_Directory (Output_File (1 .. Output_Len)) = ""
         then
            declare
               N : constant String := Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Output_File (1 .. Output_Len));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end;
         else
            TS_Len := Output_Len;
            TS_Path (1 .. TS_Len) := Output_File (1 .. Output_Len);
            if Ada.Directories.Containing_Directory (TS_Path (1 .. TS_Len))'Length > 0 then
               Final_Dir_Len := Ada.Directories.Containing_Directory (TS_Path (1 .. TS_Len))'Length;
               Final_Dir (1 .. Final_Dir_Len) :=
                 Ada.Directories.Containing_Directory (TS_Path (1 .. TS_Len));
            elsif Build_Mode and Out_Dir_Len = 0 then
               Final_Dir_Len := Default_Out_Dir (Source_File (1 .. Source_Len))'Length;
               Final_Dir (1 .. Final_Dir_Len) := Default_Out_Dir (Source_File (1 .. Source_Len));
            elsif Out_Dir_Len > 0 then
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end if;
         end if;
      end;
   end if;

   Log ("ALBL: transpiling " & Source_File (1 .. Source_Len));

   Input_Buffer := (others => ' ');
   Temp_Buffer := (others => ' ');
   Tokens := (others => (Kind => Tok_Error, Start => 1, Length => 0, Line => 1, Column => 1));
   Tree := (others => (Kind => AST_Null, Token_Index => 0, Left_Child => 0, Right_Child => 0, Next_Sibling => 0));

   Weave_File (Source_File (1 .. Source_Len), Success);
   if not Success or else Input_Len = 0 then
      Put_Line
        ("ALBL: failed to read or weave source file. success=" &
         Boolean'Image (Success) &
         " input_len=" &
         Trim_Image (Integer (Input_Len)) &
         " includes=" &
         Trim_Image (Integer (Include_Count)));
      return;
   end if;

   Tokenize
     (Input_Buffer (1 .. Input_Len),
      Tokens,
      Token_Count,
      Lex_Diag);

   if not Lex_Diag.Success then
      Put_Line
        ("ALBL lexer error at " &
         Trim_Image (Integer (Lex_Diag.Error_Line)) &
         ":" &
         Trim_Image (Integer (Lex_Diag.Error_Col)));
      return;
   end if;

   Parse
     (Tokens,
      Token_Count,
      Tree,
      Root,
      Parse_Success,
      Parse_Diag);

   if not Parse_Success or else not Parse_Diag.Success or else Root = 0 then
      Put_Line
        ("ALBL parser error at " &
         Trim_Image (Integer (Parse_Diag.Error_Line)) &
         ":" &
         Trim_Image (Integer (Parse_Diag.Error_Col)));
      return;
   end if;

   Module_Aware_Output := False;
   Stage_Asset_Count := 0;
   if Root > 0 then
      Scan_Web_Features (Root);
   end if;

   if Walker_Mode then
      Print_Walker_Info;
   end if;

    if Final_Dir_Len > 0 then
       begin
          Ada.Directories.Create_Path (Final_Dir (1 .. Final_Dir_Len));
       exception
          when E : others =>
             Put_Line ("ALBL: could not create output directory: " &
               Ada.Exceptions.Exception_Message (E));
             return;
       end;
   end if;

    if Source_Wants_No_Console then
       Emit_Native_Lua.Set_No_Console_Overlay (True);
    end if;

    Emit_Native_Lua.Compile_To_File (Tree (Root), TS_Path (1 .. TS_Len));
   Log ("ALBL: emitted " & TS_Path (1 .. TS_Len));

   -- Metrics requested: scan all included files
   if Metrics_Mode then
      Code_Information.Reset_Metrics;
      for I in 1 .. Include_Count loop
         Code_Information.Scan_Target (Include_Vault (I) (1 .. Include_Lens (I)));
      end loop;
      Code_Information.Print_Metrics;
   end if;

   if Build_Mode and then Final_Dir_Len > 0 and then Stage_Asset_Count > 0 then
      Copy_Stage_Assets (Final_Dir (1 .. Final_Dir_Len));
   end if;

   if Build_Mode then
      Stage_SDL3_Runtime (TS_Path (1 .. TS_Len));
   end if;

   if Run_Mode then
      declare
         OK : Boolean;
      begin
         OK := Run_With_LuaJIT (TS_Path (1 .. TS_Len));
         if not OK then
            Put_Line ("ALBL: LuaJIT run failed.");
            Exit_Failed := True;
         end if;
      end;
   end if;

   Log ("ALBL: done.");

   if Exit_Failed then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;

exception
   when E : others =>
      Put_Line ("ALBL fatal: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end ALBL;
