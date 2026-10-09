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

-- =============================================================================
-- Emit_Native_Ada — ALB to SPARK-oriented Ada 2012 code generator
-- Purpose: emit proof-friendly Ada with bounded runtime checks and contracts.
-- Safety role: encodes CODING_RULES §3.5, §5.2, §8.1–8.4 in generated programs.
-- Assumptions: AST node counts <= Max_Nodes; symbol tables statically bounded.
-- Boundedness: sibling walks use Max_Nodes guards; no unbounded recursion.
-- =============================================================================
pragma SPARK_Mode (On);

with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with ALBA_Runtime;   use ALBA_Runtime;
with ALB_Types;      use ALB_Types;
with Numerus_Magnus; use Numerus_Magnus;

package body Emit_Native_Ada is

   Max_Buffer_Size : constant Natural := 33_554_432;

   type Output_Sink_Kind is (Sink_Main, Sink_User_Spec, Sink_User_Body);

   Output_Buffer     : String (1 .. Max_Buffer_Size) := (others => ' ');
   Output_Len          : Natural := 0;
   User_Spec_Buffer    : String (1 .. Max_Buffer_Size) := (others => ' ');
   User_Spec_Len        : Natural := 0;
   User_Body_Buffer    : String (1 .. Max_Buffer_Size) := (others => ' ');
   User_Body_Len        : Natural := 0;
   Current_Output_Sink : Output_Sink_Kind := Sink_Main;
   Buffer_Saturated    : Boolean := False;
   Body_Streaming      : Boolean := False;
   Body_Stream_File    : Ada.Text_IO.File_Type;
   Body_Stream_Len     : Natural := 0;

   Active_User_Unit_Name     : String (1 .. 128) := (others => ' ');
   Active_User_Unit_Name_Len : Natural := 0;

   procedure Append_To_Buffer
     (Buffer : in out String;
      Len    : in out Natural;
      Text   : String;
      Success : out Boolean)
   is
   begin
      if Len + Text'Length <= Buffer'Length then
         Buffer (Len + 1 .. Len + Text'Length) := Text;
         Len := Len + Text'Length;
         Success := True;
      else
         if not Buffer_Saturated then
            Ada.Text_IO.Put_Line
              ("ALBA: Ada emit buffer full (" &
               Natural'Image (Len) &
               " + " &
               Natural'Image (Text'Length) &
               " >" &
               Natural'Image (Buffer'Length) &
               ").");
         end if;
         Buffer_Saturated := True;
         Success := False;
      end if;
   end Append_To_Buffer;

   procedure Append
     (Text    : String;
      Success : out Boolean)
   is
   begin
      case Current_Output_Sink is
         when Sink_Main =>
            Append_To_Buffer (Output_Buffer, Output_Len, Text, Success);
         when Sink_User_Spec =>
            Append_To_Buffer (User_Spec_Buffer, User_Spec_Len, Text, Success);
         when Sink_User_Body =>
            if Body_Streaming and then Ada.Text_IO.Is_Open (Body_Stream_File) then
               begin
                  Ada.Text_IO.Put (Body_Stream_File, Text);
                  Body_Stream_Len := Body_Stream_Len + Text'Length;
                  Success := True;
               exception
                  when Ada.IO_Exceptions.Name_Error |
                       Ada.IO_Exceptions.Use_Error |
                       Ada.IO_Exceptions.Status_Error |
                       Ada.IO_Exceptions.Device_Error =>
                     Buffer_Saturated := True;
                     Success := False;
               end;
            else
               Append_To_Buffer (User_Body_Buffer, User_Body_Len, Text, Success);
            end if;
      end case;
   end Append;

   procedure Close_Body_Stream is
   begin
      if Ada.Text_IO.Is_Open (Body_Stream_File) then
         Ada.Text_IO.Close (Body_Stream_File);
      end if;
      Body_Streaming := False;
   end Close_Body_Stream;

   procedure Start_Body_Stream
     (File_Path : String;
      Success   : out Boolean)
   is
   begin
      Close_Body_Stream;
      Body_Stream_Len := 0;
      begin
         Ada.Text_IO.Create (Body_Stream_File, Ada.Text_IO.Out_File, File_Path);
         Body_Streaming := True;
         Success := True;
      exception
         when Ada.IO_Exceptions.Name_Error |
              Ada.IO_Exceptions.Use_Error |
              Ada.IO_Exceptions.Status_Error |
              Ada.IO_Exceptions.Device_Error =>
            Body_Streaming := False;
            Success := False;
            Ada.Text_IO.Put_Line
              ("ALBA: could not open Ada user body stream " & File_Path);
      end;
   end Start_Body_Stream;

   procedure Reset_Output_Buffer
     (Sink : Output_Sink_Kind)
   is
   begin
      case Sink is
         when Sink_Main =>
            Output_Len := 0;
         when Sink_User_Spec =>
            User_Spec_Len := 0;
         when Sink_User_Body =>
            User_Body_Len := 0;
      end case;
   end Reset_Output_Buffer;

   procedure Flush_Buffer_To_File
     (Buffer : String;
      Len    : Natural;
      File_Path : String;
      Success   : out Boolean)
   is
      Output_File : Ada.Text_IO.File_Type;
   begin
      Success := True;
      begin
         Ada.Text_IO.Create (Output_File, Ada.Text_IO.Out_File, File_Path);
         if Len > 0 then
            Ada.Text_IO.Put
              (Output_File, Buffer (Buffer'First .. Buffer'First + Len - 1));
         end if;
         Ada.Text_IO.Close (Output_File);
      exception
         when Ada.IO_Exceptions.Name_Error |
              Ada.IO_Exceptions.Use_Error |
              Ada.IO_Exceptions.Status_Error |
              Ada.IO_Exceptions.Device_Error =>
            if Ada.Text_IO.Is_Open (Output_File) then
               Ada.Text_IO.Close (Output_File);
            end if;
            Success := False;
      end;
   end Flush_Buffer_To_File;

   procedure Init_Emitter
     (Success : out Boolean)
   is
   begin
      Reset_Output_Buffer (Sink_Main);
      Reset_Output_Buffer (Sink_User_Spec);
      Reset_Output_Buffer (Sink_User_Body);
      Current_Output_Sink := Sink_Main;
      Active_User_Unit_Name := (others => ' ');
      Active_User_Unit_Name_Len := 0;
      Indent_Level := 0;
      Buffer_Saturated := False;
      Close_Body_Stream;
      Body_Stream_Len := 0;
      ALBA_Emitter_Ready := True;
      Success := True;
   end Init_Emitter;

   procedure Emit_Raw
     (Text    : String;
      Success : out Boolean)
   is
   begin
      Append (Text, Success);
   end Emit_Raw;

   procedure Emit_Newline
     (Success : out Boolean)
   is
   begin
      Append (ASCII.LF & "", Success);
   end Emit_Newline;

   procedure Emit_Indent
     (Success : out Boolean)
   is
      S : Boolean := True;
   begin
      for I in 1 .. Indent_Level loop
         Append ("   ", S);
         exit when not S;
      end loop;
      Success := S;
   end Emit_Indent;

   procedure Emit_Line
     (Text    : String;
      Success : out Boolean)
   is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      if S then
         Append (Text, S);
      end if;
      if S then
         Emit_Newline (S);
      end if;
      Success := S;
   end Emit_Line;

   procedure Increase_Indent is
   begin
      Indent_Level := Indent_Level + 1;
   end Increase_Indent;

   procedure Decrease_Indent is
   begin
      Indent_Level := Indent_Level - 1;
   end Decrease_Indent;

   procedure Flush_To_File
     (File_Path : String;
      Success   : out Boolean)
   is
   begin
      Flush_Buffer_To_File (Output_Buffer, Output_Len, File_Path, Success);
   end Flush_To_File;

   procedure Emit_Program
     (Source       : String;
      Tokens       : Token_Array;
      Token_Count  : Natural;
      Tree         : Node_Array;
      Root         : Node_Index;
      Program_Name : String;
      Output_Path  : String;
      Success      : out Boolean)
   is
      Max_Symbols         : constant Natural := 16_384;
      Max_Modules         : constant Natural := 1024;
      Max_Fields          : constant Natural := 512;
      Max_Structs         : constant Natural := 128;
      Max_Routines        : constant Natural := 8192;
      Max_Params          : constant Natural := 64;
      Max_Aliases         : constant Natural := 1024;
      Max_Consts          : constant Natural := 2048;
      Max_Temporals       : constant Natural := 256;
      Max_Knows_Hooks     : constant Natural := 64;
      Max_Advanced_Nodes  : constant Natural := 128;
      Max_Field_Work      : constant Natural := Max_Fields * 16;
      Max_Loop_Depth      : constant Natural := 64;
      Max_Name_Length     : constant Natural := 128;

      type Name_Buffer is array (1 .. Max_Name_Length) of Character;
      type Dim_Array is array (1 .. 4) of Natural;

      type Alias_Record is record
         Active    : Boolean := False;
         Name      : Name_Buffer := (others => ' ');
         Name_Len  : Natural := 0;
         Tag       : ALB_Type_Tag := Type_None;
         Has_Range : Boolean := False;
         Range_Low : S64 := 0;
         Range_High : S64 := 0;
      end record;

      type Const_Record is record
         Active          : Boolean := False;
         Name            : Name_Buffer := (others => ' ');
         Name_Len        : Natural := 0;
         Module_Name     : Name_Buffer := (others => ' ');
         Module_Name_Len : Natural := 0;
         Scope_Name      : Name_Buffer := (others => ' ');
         Scope_Name_Len  : Natural := 0;
         Expr_Node       : Node_Index := 0;
         Static_Value    : S64 := 0;
         Has_Static_Value : Boolean := False;
      end record;

      type Symbol_Kind is
        (Sym_Scalar,
         Sym_Array,
         Sym_Struct,
         Sym_Temporal,
         Sym_Enum_Const);

      type Symbol_Record is record
         Active           : Boolean := False;
         Name             : Name_Buffer := (others => ' ');
         Name_Len         : Natural := 0;
         Raw_Name         : Name_Buffer := (others => ' ');
         Raw_Name_Len     : Natural := 0;
         Module_Name      : Name_Buffer := (others => ' ');
         Module_Name_Len  : Natural := 0;
         Scope_Name       : Name_Buffer := (others => ' ');
         Scope_Name_Len   : Natural := 0;
         Tag              : ALB_Type_Tag := Type_None;
         Kind             : Symbol_Kind := Sym_Scalar;
         Rank             : Natural range 0 .. 4 := 0;
         Dims             : Dim_Array := (others => 0);
         Struct_Name      : Name_Buffer := (others => ' ');
         Struct_Name_Len  : Natural := 0;
         History_Size     : Natural := 0;
         Timeline_Offset  : Natural := 0;
         VAS_Offset       : Natural := 0;
         Alias_Idx        : Natural := 0;
      end record;

      type Module_Record is record
         Active   : Boolean := False;
         Name     : Name_Buffer := (others => ' ');
         Name_Len : Natural := 0;
      end record;

      type Parallel_Field_Record is record
         Active           : Boolean := False;
         Group_Name       : Name_Buffer := (others => ' ');
         Group_Name_Len   : Natural := 0;
         Field_Name       : Name_Buffer := (others => ' ');
         Field_Name_Len   : Natural := 0;
         Backing_Name     : Name_Buffer := (others => ' ');
         Backing_Name_Len : Natural := 0;
         Tag              : ALB_Type_Tag := Type_None;
         Capacity         : Natural := 0;
      end record;

      type Struct_Field_Record is record
         Active           : Boolean := False;
         Struct_Name      : Name_Buffer := (others => ' ');
         Struct_Name_Len  : Natural := 0;
         Field_Name       : Name_Buffer := (others => ' ');
         Field_Name_Len   : Natural := 0;
         Tag              : ALB_Type_Tag := Type_None;
         Offset_Bytes     : Natural := 0;
      end record;

      type Routine_Record is record
         Active          : Boolean := False;
         Node            : Node_Index := 0;
         Module_Name     : Name_Buffer := (others => ' ');
         Module_Name_Len : Natural := 0;
      end record;

      type Named_Node_Record is record
         Active   : Boolean := False;
         Name     : Name_Buffer := (others => ' ');
         Name_Len : Natural := 0;
         Node     : Node_Index := 0;
      end record;

      type Field_Work_Array is array (1 .. Max_Field_Work) of Node_Index;

      type Param_Record is record
         Active          : Boolean := False;
         Name            : Name_Buffer := (others => ' ');
         Name_Len        : Natural := 0;
         Formal_Name     : Name_Buffer := (others => ' ');
         Formal_Name_Len : Natural := 0;
         Tag             : ALB_Type_Tag := Type_None;
         Struct_Name     : Name_Buffer := (others => ' ');
         Struct_Name_Len : Natural := 0;
         Is_Ref          : Boolean := False;
         VAS_Offset      : Natural := 0;
      end record;

      type Knows_Hook_Record is record
         Active             : Boolean := False;
         Predicate_Name     : Name_Buffer := (others => ' ');
         Predicate_Name_Len : Natural := 0;
         Handler_Name       : Name_Buffer := (others => ' ');
         Handler_Name_Len   : Natural := 0;
         Param_Name         : Name_Buffer := (others => ' ');
         Param_Name_Len     : Natural := 0;
         Node               : Node_Index := 0;
      end record;

      Symbols         : array (1 .. Max_Symbols) of Symbol_Record;
      Symbol_Count    : Natural := 0;
      Modules         : array (1 .. Max_Modules) of Module_Record;
      Module_Count    : Natural := 0;
      Consts          : array (1 .. Max_Consts) of Const_Record;
      Const_Count     : Natural := 0;
      Parallel_Fields : array (1 .. Max_Fields) of Parallel_Field_Record;
      Parallel_Count  : Natural := 0;
      Struct_Fields   : array (1 .. Max_Fields) of Struct_Field_Record;
      Struct_Count    : Natural := 0;
      Struct_Memory_Helper_Needed : array (1 .. Max_Structs) of Boolean :=
        (others => False);
      Routines        : array (1 .. Max_Routines) of Routine_Record;
      Routine_Count   : Natural := 0;

      type Ada_Rename_Record is record
         Active   : Boolean := False;
         From_Len : Natural := 0;
         From     : Name_Buffer := (others => ' ');
         To_Len   : Natural := 0;
         To       : Name_Buffer := (others => ' ');
      end record;

      Ada_Renames      : array (1 .. Max_Symbols) of Ada_Rename_Record;
      Ada_Rename_Count : Natural := 0;
      Network_Sockets : array (1 .. Max_Advanced_Nodes) of Named_Node_Record;
      Network_Socket_Count : Natural := 0;

      Max_Firewalls      : constant := 64;
      Max_Firewall_Rules : constant := 512;

      type Firewall_Rule_Record is record
         Active      : Boolean := False;
         Target_Name : Name_Buffer := (others => ' ');
         Target_Len  : Natural := 0;
         Allow_Read  : Boolean := False;
         Allow_Write : Boolean := False;
      end record;

      type Firewall_Record is record
         Active     : Boolean := False;
         Name       : Name_Buffer := (others => ' ');
         Name_Len   : Natural := 0;
         Deny_All   : Boolean := False;
         Rule_First : Natural := 0;
         Rule_Count : Natural := 0;
      end record;

      Firewalls          : array (1 .. Max_Firewalls) of Firewall_Record;
      Firewall_Rules     : array (1 .. Max_Firewall_Rules) of Firewall_Rule_Record;
      Firewall_Count     : Natural := 0;
      Firewall_Rule_Count : Natural := 0;
      Current_Params  : array (1 .. Max_Params) of Param_Record;
      Current_Param_Count : Natural := 0;
      Current_Routine_Scope : Name_Buffer := (others => ' ');
      Current_Routine_Scope_Len : Natural := 0;
      Current_Return_Tag : ALB_Type_Tag := Type_None;
      Current_Frame_Active : Boolean := False;
      Current_Frame_Size   : Natural := 0;
      Current_Routine_Uses_Poke : Boolean := False;
      Current_Routine_Body_Node : Node_Index := 0;
      Current_Routine_Module    : Name_Buffer := (others => ' ');
      Current_Routine_Module_Len : Natural := 0;
      Aliases         : array (1 .. Max_Aliases) of Alias_Record;
      Alias_Count     : Natural := 0;
      Knows_Hooks     : array (1 .. Max_Knows_Hooks) of Knows_Hook_Record;
      Knows_Hook_Count : Natural := 0;
      Loop_Continue_Label_Lens : array (1 .. Max_Loop_Depth) of Natural := (others => 0);
      Loop_Continue_Labels : array (1 .. Max_Loop_Depth) of Name_Buffer := (others => (others => ' '));
      Loop_Depth : Natural := 0;
      Next_Loop_Label_Id : Natural := 0;

      Window_Title : Name_Buffer := (others => ' ');
      Window_Title_Len : Natural := 0;
      Window_Width  : Natural := 320;
      Window_Height : Natural := 200;
      Has_Window    : Boolean := False;
      On_Tick_Node  : Node_Index := 0;
      On_Paint_Node : Node_Index := 0;
      On_Key_Node   : Node_Index := 0;
      Has_Listen    : Boolean := False;
      Need_F64_Runtime   : Boolean := False;
      Need_NN_Runtime    : Boolean := False;
      Need_Markov_Runtime : Boolean := False;
      Need_Net_Runtime   : Boolean := False;
      Need_Rnd_Runtime   : Boolean := False;
      Need_Pow_Runtime   : Boolean := False;
      Need_Numerus_Runtime : Boolean := False;
      Contract_Use_Formal_Names : Boolean := False;
      Critical_Mode          : Boolean := True;
      Critical_Violations    : Natural := 0;
      Need_User_Exception    : Boolean := False;
      Need_Save_State        : Boolean := False;
      Need_Address_Helpers   : Boolean := False;
      Need_User_Unit_Use     : Boolean := False;
      Move_Globals_To_User_Unit : Boolean := False;
      Need_Strings_Unit      : Boolean := False;
      User_Unit_Name         : String (1 .. 128) := (others => ' ');
      User_Unit_Name_Len     : Natural := 0;
      Next_Timeline_Offset : Natural := ALB_VAS_Temp_Base;
      Next_Static_VAS_Offset : Natural := ALB_VAS_Global_Base;

      function User_Unit_Name_Text return String is
      begin
         if User_Unit_Name_Len = 0 then
            return "";
         end if;
         return User_Unit_Name (1 .. User_Unit_Name_Len);
      end User_Unit_Name_Text;

      function User_Sibling_Unit_Path
        (Output_Path : String;
         Extension   : String) return String
      is
         Dir_End : Natural := Output_Path'Last;
         Base    : constant String := User_Unit_Name_Text & Extension;
      begin
         while Dir_End >= Output_Path'First loop
            if Output_Path (Dir_End) = '\' or else Output_Path (Dir_End) = '/' then
               return Output_Path (Output_Path'First .. Dir_End) & Base;
            end if;
            if Dir_End = Output_Path'First then
               exit;
            end if;
            Dir_End := Dir_End - 1;
         end loop;
         return Base;
      end User_Sibling_Unit_Path;

      procedure Detect_Emission_Mode (Text : String) is
      begin
         if Text'Length = 0 then
            return;
         end if;
         if Ada.Strings.Fixed.Index (Text, "MODE FULL") > 0
           or else Ada.Strings.Fixed.Index (Text, "mode full") > 0
         then
            Critical_Mode := False;
         end if;
      end Detect_Emission_Mode;

      procedure Record_Critical_Violation (Feature : String) is
      begin
         if Critical_Mode then
            Critical_Violations := Critical_Violations + 1;
            Ada.Text_IO.Put_Line
              ("ALBA CRITICAL MODE: forbidden feature """ & Feature & """");
         end if;
      end Record_Critical_Violation;

      function Raw_Lexeme (Token_Index : Natural) return String is
         Tok  : Token;
         Last : Natural := 0;
      begin
         if Token_Index = 0 or else Token_Index > Token_Count then
            return "";
         end if;

         Tok := Tokens (Token_Index);
         if Tok.Length = 0 then
            return "";
         end if;

         Last := Tok.Start + Tok.Length - 1;
         if Tok.Start not in Source'Range or else Last not in Source'Range then
            return "";
         end if;

         return Source (Tok.Start .. Last);
      end Raw_Lexeme;

      function Trim_Image (N : Integer) return String is
         S : constant String := Integer'Image (N);
         F : Positive := S'First;
      begin
         while F < S'Last and then S (F) = ' ' loop
            F := F + 1;
         end loop;
         return S (F .. S'Last);
      end Trim_Image;

      function Sanitize_Ada_Ident (Text : String) return String is
         Temp : String (1 .. Max_Name_Length) := (others => '_');
         Len  : Natural := 0;
         Ch   : Character;
         function Is_Ada_Reserved (Name : String) return Boolean is
            Upper : String (1 .. Name'Length);
         begin
            for I in Name'Range loop
               if Name (I) in 'a' .. 'z' then
                  Upper (I - Name'First + 1) :=
                    Character'Val (Character'Pos (Name (I)) - 32);
               else
                  Upper (I - Name'First + 1) := Name (I);
               end if;
            end loop;
            return
              Upper = "ABORT" or else
              Upper = "ABS" or else
              Upper = "ABSTRACT" or else
              Upper = "ACCEPT" or else
              Upper = "ACCESS" or else
              Upper = "ALIASED" or else
              Upper = "ALL" or else
              Upper = "AND" or else
              Upper = "ARRAY" or else
              Upper = "AT" or else
              Upper = "BEGIN" or else
              Upper = "BODY" or else
              Upper = "CASE" or else
              Upper = "CONSTANT" or else
              Upper = "DECLARE" or else
              Upper = "DELAY" or else
              Upper = "DELTA" or else
              Upper = "DIGITS" or else
              Upper = "DO" or else
              Upper = "ELSE" or else
              Upper = "ELSIF" or else
              Upper = "END" or else
              Upper = "ENTRY" or else
              Upper = "EXCEPTION" or else
              Upper = "EXIT" or else
              Upper = "FOR" or else
              Upper = "FUNCTION" or else
              Upper = "GENERIC" or else
              Upper = "GOTO" or else
              Upper = "IF" or else
              Upper = "IN" or else
              Upper = "INTERFACE" or else
              Upper = "IS" or else
              Upper = "LIMITED" or else
              Upper = "LOOP" or else
              Upper = "MOD" or else
              Upper = "NEW" or else
              Upper = "NOT" or else
              Upper = "NULL" or else
              Upper = "OF" or else
              Upper = "OR" or else
              Upper = "OTHERS" or else
              Upper = "OUT" or else
              Upper = "OVERRIDING" or else
              Upper = "PACKAGE" or else
              Upper = "PARALLEL" or else
              Upper = "PRAGMA" or else
              Upper = "PRIVATE" or else
              Upper = "PROCEDURE" or else
              Upper = "PROTECTED" or else
              Upper = "RAISE" or else
              Upper = "RANGE" or else
              Upper = "RECORD" or else
              Upper = "REM" or else
              Upper = "RENAMES" or else
              Upper = "REQUEUE" or else
              Upper = "RETURN" or else
              Upper = "REVERSE" or else
              Upper = "SELECT" or else
              Upper = "SEPARATE" or else
              Upper = "SOME" or else
              Upper = "SUBTYPE" or else
              Upper = "SYNCHRONIZED" or else
              Upper = "TAGGED" or else
              Upper = "TASK" or else
              Upper = "TERMINATE" or else
              Upper = "THEN" or else
              Upper = "TYPE" or else
              Upper = "UNTIL" or else
              Upper = "USE" or else
              Upper = "WHEN" or else
              Upper = "WHILE" or else
              Upper = "WITH" or else
              Upper = "XOR";
         end Is_Ada_Reserved;
      begin
         for I in Text'Range loop
            Ch := Text (I);
            if (Ch in 'A' .. 'Z') or else (Ch in 'a' .. 'z') or else
              (Ch in '0' .. '9') or else Ch = '_'
            then
               if Len < Temp'Length then
                  Len := Len + 1;
                  Temp (Len) := Ch;
               end if;
            else
               if Len < Temp'Length then
                  Len := Len + 1;
                  Temp (Len) := '_';
               end if;
            end if;
         end loop;

         if Len = 0 then
            return "ALB_Name";
         end if;

         if not (Temp (1) in 'A' .. 'Z' or else Temp (1) in 'a' .. 'z') then
            if Len < Temp'Length then
               for I in reverse 1 .. Len loop
                  Temp (I + 1) := Temp (I);
               end loop;
               Temp (1) := 'A';
               Len := Len + 1;
            else
               Temp (1) := 'A';
            end if;
         end if;

         if Is_Ada_Reserved (Temp (1 .. Len)) then
            if Len + 2 <= Temp'Length then
               for I in reverse 1 .. Len loop
                  Temp (I + 2) := Temp (I);
               end loop;
               Temp (1) := 'A';
               Temp (2) := '_';
               Len := Len + 2;
            else
               Temp (1) := 'A';
            end if;
         end if;

         return Temp (1 .. Len);
      end Sanitize_Ada_Ident;

      function Fold_Ada_Ident (Text : String) return String is
         Result : String (1 .. Text'Length);
         Ch     : Character;
      begin
         for I in Text'Range loop
            Ch := Text (I);
            if Ch in 'a' .. 'z' then
               Result (I - Text'First + 1) :=
                 Character'Val (Character'Pos (Ch) - 32);
            else
               Result (I - Text'First + 1) := Ch;
            end if;
         end loop;
         return Result;
      end Fold_Ada_Ident;

      function Slice_Name (Buffer : Name_Buffer; Len : Natural) return String is
         Result : String (1 .. Len);
      begin
         for I in 1 .. Len loop
            Result (I) := Buffer (I);
         end loop;
         return Result;
      end Slice_Name;

      function Apply_Ada_Rename (Text : String) return String is
      begin
         for I in 1 .. Ada_Rename_Count loop
            if Ada_Renames (I).Active
              and then Ada_Renames (I).From_Len = Text'Length
              and then Slice_Name (Ada_Renames (I).From, Ada_Renames (I).From_Len) = Text
            then
               return Slice_Name (Ada_Renames (I).To, Ada_Renames (I).To_Len);
            end if;
         end loop;
         return Text;
      end Apply_Ada_Rename;

      function Safe_Name (Text : String) return String is
      begin
         return Apply_Ada_Rename (Sanitize_Ada_Ident (Text));
      end Safe_Name;

      function Safe_Name_Length (Text : String) return Natural is
         Value : constant String := Safe_Name (Text);
      begin
         return Value'Length;
      end Safe_Name_Length;

      function Upper_Safe_Name (Text : String) return String is
         Value  : constant String := Safe_Name (Text);
         Result : String (1 .. Value'Length);
         Ch     : Character;
      begin
         for I in Value'Range loop
            Ch := Value (I);
            if Ch in 'a' .. 'z' then
               Result (I - Value'First + 1) :=
                 Character'Val (Character'Pos (Ch) - 32);
            else
               Result (I - Value'First + 1) := Ch;
            end if;
         end loop;
         return Result;
      end Upper_Safe_Name;

      function Upper_Safe_Name_Length (Text : String) return Natural is
         Value : constant String := Upper_Safe_Name (Text);
      begin
         return Value'Length;
      end Upper_Safe_Name_Length;

      function Normalize_Const_Name (Text : String) return String is
      begin
         if Text'Length > 0 and then Text (Text'First) = '#' then
            return Safe_Name (Text (Text'First + 1 .. Text'Last));
         end if;
         return Safe_Name (Text);
      end Normalize_Const_Name;

      function Compose_Field_Backing_Name
        (Group_Name : String;
         Field_Name : String) return String
      is
      begin
         return Group_Name & "_" & Safe_Name (Field_Name);
      end Compose_Field_Backing_Name;

      function Compose_Field_Backing_Name_Length
        (Group_Name : String;
         Field_Name : String) return Natural
      is
         Value : constant String := Compose_Field_Backing_Name (Group_Name, Field_Name);
      begin
         return Value'Length;
      end Compose_Field_Backing_Name_Length;

      function Copy_Name (Text : String) return Name_Buffer is
         Result : Name_Buffer := (others => ' ');
      begin
         if Text'Length > 0 then
            for I in 1 .. Text'Length loop
               Result (I) := Text (Text'First + I - 1);
            end loop;
         end if;
         return Result;
      end Copy_Name;

      function Name_Text (Buffer : Name_Buffer; Length : Natural) return String is
         Result : String (1 .. Length);
      begin
         if Length = 0 then
            return "";
         end if;
         for I in Result'Range loop
            Result (I) := Buffer (I);
         end loop;
         return Result;
      end Name_Text;

      function Qualify_Name
        (Module_Name : String;
         Raw_Name    : String) return String
      is
      begin
         if Module_Name'Length = 0 then
            return Apply_Ada_Rename (Sanitize_Ada_Ident (Raw_Name));
         end if;
         return Apply_Ada_Rename
           (Sanitize_Ada_Ident (Module_Name) & "_" & Sanitize_Ada_Ident (Raw_Name));
      end Qualify_Name;

      function Qualify_Local_Name
        (Module_Name  : String;
         Routine_Name : String;
         Raw_Name     : String) return String
      is
      begin
         if Routine_Name'Length = 0 then
            return Qualify_Name (Module_Name, Raw_Name);
         elsif Module_Name'Length = 0 then
            return Apply_Ada_Rename
              (Sanitize_Ada_Ident (Routine_Name) & "_" & Sanitize_Ada_Ident (Raw_Name));
         else
            return Apply_Ada_Rename
              (Sanitize_Ada_Ident (Module_Name) & "_" &
               Sanitize_Ada_Ident (Routine_Name) & "_" &
               Sanitize_Ada_Ident (Raw_Name));
         end if;
      end Qualify_Local_Name;

      function Scoped_Symbol_Name
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "") return String
      is
      begin
         if Routine_Name'Length > 0 then
            return Qualify_Local_Name (Module_Name, Routine_Name, Raw_Name);
         else
            return Qualify_Name (Module_Name, Raw_Name);
         end if;
      end Scoped_Symbol_Name;

      function Find_Symbol (Emit_Name : String) return Natural;

      function Find_Const_Expr
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "") return Node_Index;

      procedure Register_Const
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "";
         Expr_Node    : Node_Index := 0;
         Static_Value : S64 := 0;
         Has_Static   : Boolean := False);

      procedure Lookup_Const_Static_Value
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "";
         Value        : out S64;
         Found        : out Boolean);

      function Registration_Name
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "") return String
      is
         Local_Candidate  : constant String := Qualify_Local_Name (Module_Name, Routine_Name, Raw_Name);
         Global_Candidate : constant String := Qualify_Name (Module_Name, Raw_Name);
         Safe_Raw         : constant String := Safe_Name (Raw_Name);
      begin
         if Routine_Name'Length > 0 then
            if Find_Symbol (Local_Candidate) > 0 then
               return Local_Candidate;
            elsif Find_Symbol (Global_Candidate) > 0 then
               return Global_Candidate;
            elsif Find_Symbol (Safe_Raw) > 0 then
               return Safe_Raw;
            else
               return Local_Candidate;
            end if;
         else
            if Find_Symbol (Global_Candidate) > 0 then
               return Global_Candidate;
            elsif Find_Symbol (Safe_Raw) > 0 then
               return Safe_Raw;
            else
               return Global_Candidate;
            end if;
         end if;
      end Registration_Name;

      function Is_Module_Name (Text : String) return Boolean is
      begin
         for I in 1 .. Module_Count loop
            if Modules (I).Active
              and then Modules (I).Name_Len = Text'Length
              and then Name_Text (Modules (I).Name, Modules (I).Name_Len) = Text
            then
               return True;
            end if;
         end loop;
         return False;
      end Is_Module_Name;

      function Find_Alias (Text : String) return Natural is
         Key : constant String := Upper_Safe_Name (Text);
      begin
         for I in 1 .. Alias_Count loop
            if Aliases (I).Active
              and then Aliases (I).Name_Len = Key'Length
              and then Name_Text (Aliases (I).Name, Aliases (I).Name_Len) = Key
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Alias;

      function Tag_From_Name (Text : String) return ALB_Type_Tag is
         Name      : constant String := Upper_Safe_Name (Text);
         Alias_Idx : constant Natural := Find_Alias (Name);
      begin
         if Name = "U8" then
            return Type_U8;
         elsif Name = "U16" then
            return Type_U16;
         elsif Name = "U32" then
            return Type_U32;
         elsif Name = "U64" then
            return Type_U64;
         elsif Name = "U128" then
            return Type_U128;
         elsif Name = "S8" or else Name = "I8" or else Name = "INT8" then
            return Type_S8;
         elsif Name = "S16" or else Name = "I16" or else Name = "INT16" then
            return Type_S16;
         elsif Name = "S32" or else Name = "I32" or else Name = "INT32" then
            return Type_S32;
         elsif Name = "S64" or else Name = "I64" or else Name = "INT64" then
            return Type_S64;
         elsif Name = "S128" then
            return Type_S128;
         elsif Name = "F32" or else Name = "SINGLE" or else Name = "FLOAT" then
            return Type_F32;
         elsif Name = "F64" or else Name = "REAL" or else Name = "DOUBLE"
           or else Name = "NUMBER"
         then
            return Type_F64;
         elsif Name = "F128" then
            -- Soft: Ada host has no native F128; keep tagged Soft lane.
            return Type_F128;
         elsif Name = "FLOAT2" or else Name = "F32X2" then
            return Type_F32x2;
         elsif Name = "FLOAT4" or else Name = "F32X4" then
            return Type_F32x4;
         elsif Name = "MAT2" or else Name = "MAT2X2" then
            return Type_Mat2x2;
         elsif Name = "MAT3" or else Name = "MAT3X3" then
            return Type_Mat3x3;
         elsif Name = "MAT4" or else Name = "MAT4X4" then
            return Type_Mat4x4;
         elsif Name = "HW8" then
            return Type_HW8;
         elsif Name = "HW16" then
            return Type_HW16;
         elsif Name = "HW32" then
            return Type_HW32;
         elsif Name = "HW64" then
            return Type_HW64;
         elsif Name = "BOOL" or else Name = "BOOLEAN" then
            return Type_Boolean;
         elsif Name = "STRING" or else Name = "BINARY" then
            return Type_Binary;
         elsif Name = "CHAR" then
            return Type_Char;
         elsif Name = "PURE" or else Name = "RATIONAL" then
            return Type_Pure;
         elsif Alias_Idx > 0 then
            return Aliases (Alias_Idx).Tag;
         end if;
         return Type_None;
      end Tag_From_Name;

      function Unbounded_String (Text : String) return String is
      begin
         return "" & Text;
      end Unbounded_String;

      function Ada_Type_Name
        (Tag        : ALB_Type_Tag;
         Struct_Tag : String := "") return String is
      begin
         if Struct_Tag'Length > 0 then
            return Struct_Tag;
         end if;

         case Tag is
            when Type_U8      => return "U8";
            when Type_U16     => return "U16";
            when Type_U32     => return "U32";
            when Type_U64     => return "U64";
            when Type_U128    => return "Numerus_Magnus.U128";
            when Type_S8      => return "S8";
            when Type_S16     => return "S16";
            when Type_S32     => return "S32";
            when Type_S64     => return "S64";
            when Type_S128    => return "Numerus_Magnus.S128";
            when Type_F32     => return "F32";
            when Type_F64     => return "F64";
            when Type_F128    => return "Numerus_Magnus.F128";  -- Soft
            when Type_F32x2   => return "Numerus_Magnus.F32x2";
            when Type_F32x4   => return "Numerus_Magnus.F32x4";
            when Type_Mat2x2  => return "Numerus_Magnus.Mat2x2";
            when Type_Mat3x3  => return "Numerus_Magnus.Mat3x3";
            when Type_Mat4x4  => return "Numerus_Magnus.Mat4x4";
            when Type_Boolean => return "Boolean";
            when Type_Binary  => return "ALB_Text";
            when Type_Char    => return "Character";
            -- Soft HW*: integer lanes (bitset records need separate op wiring).
            when Type_HW8     => return "U8";
            when Type_HW16    => return "U16";
            when Type_HW32    => return "U32";
            when Type_HW64    => return "U64";
            when Type_Pure    => return "Pure_Rational";
            when others       => return "U64";
         end case;
      end Ada_Type_Name;

      function Alias_Type_Name (Alias_Idx : Natural) return String is
      begin
         if Alias_Idx = 0
           or else not Aliases (Alias_Idx).Active
         then
            return "";
         end if;
         return Name_Text (Aliases (Alias_Idx).Name, Aliases (Alias_Idx).Name_Len);
      end Alias_Type_Name;

      function Symbol_Type_Name (Sym_Idx : Natural) return String is
         Struct_Name : constant String :=
           Name_Text (Symbols (Sym_Idx).Struct_Name, Symbols (Sym_Idx).Struct_Name_Len);
      begin
         if Sym_Idx > 0
           and then Symbols (Sym_Idx).Alias_Idx > 0
         then
            return Alias_Type_Name (Symbols (Sym_Idx).Alias_Idx);
         end if;
         return Ada_Type_Name (Symbols (Sym_Idx).Tag, Struct_Name);
      end Symbol_Type_Name;

      function Range_Bound_Image (Bound : S64) return String is
      begin
         if Bound >= S64 (Integer'First) and then Bound <= S64 (Integer'Last) then
            return Trim_Image (Integer (Bound));
         end if;
         return Long_Long_Integer'Image (Long_Long_Integer (Bound));
      end Range_Bound_Image;

      function Ada_Array_Type_Name
        (Tag : ALB_Type_Tag) return String is
      begin
         case Tag is
            when Type_U8      => return "ALB_U8_Array";
            when Type_U16     => return "ALB_U16_Array";
            when Type_U32     => return "ALB_U32_Array";
            when Type_U64     => return "ALB_U64_Array";
            when Type_S8      => return "ALB_I8_Array";
            when Type_S16     => return "ALB_I16_Array";
            when Type_S32     => return "ALB_I32_Array";
            when Type_S64     => return "ALB_I64_Array";
            when others       => return "";
         end case;
      end Ada_Array_Type_Name;

      function Array_Row_Type_Name (Symbol_Name : String) return String is
      begin
         return Symbol_Name & "_t";
      end Array_Row_Type_Name;

      function Is_Numeric_Tag (Tag : ALB_Type_Tag) return Boolean is
      begin
         return Tag in Type_U8 | Type_U16 | Type_U32 | Type_U64 |
                       Type_S8 | Type_S16 | Type_S32 | Type_S64 |
                       Type_F32 | Type_F64;
      end Is_Numeric_Tag;

      function Needs_Numeric_Cast
        (Expected : ALB_Type_Tag;
         Actual   : ALB_Type_Tag) return Boolean is
      begin
         return
           Expected /= Type_None
           and then Expected /= Actual
           and then Is_Numeric_Tag (Expected)
           and then Is_Numeric_Tag (Actual);
      end Needs_Numeric_Cast;

      function Default_Value_Text
        (Tag        : ALB_Type_Tag;
         Struct_Tag : String := "") return String is
      begin
         if Struct_Tag'Length > 0 then
            return "(others => <>)";
         end if;

         case Tag is
            when Type_Boolean =>
               return "False";
            when Type_Binary =>
               return "ALB_STR("""")";
            when Type_Pure =>
               return "ALB_PURE(Long_Integer(0), Long_Integer(1))";
            when Type_F32 | Type_F64 =>
               return "0.0";
            when Type_F32x2 | Type_F32x4 =>
               return "(others => 0.0)";
            when Type_Mat2x2 | Type_Mat3x3 | Type_Mat4x4 =>
               return "(others => (others => 0.0))";
            when others =>
               return "0";
         end case;
      end Default_Value_Text;

      function Alias_Default_Value_Text
        (Alias_Idx    : Natural;
         Fallback_Tag : ALB_Type_Tag := Type_U64) return String is
      begin
         if Alias_Idx > 0 and then Aliases (Alias_Idx).Active then
            if Aliases (Alias_Idx).Has_Range then
               return Range_Bound_Image (Aliases (Alias_Idx).Range_Low);
            end if;
            return Default_Value_Text (Aliases (Alias_Idx).Tag);
         end if;
         return Default_Value_Text (Fallback_Tag);
      end Alias_Default_Value_Text;

      function Symbol_Default_Value_Text (Sym_Idx : Natural) return String is
         Struct_Name : constant String :=
           Name_Text (Symbols (Sym_Idx).Struct_Name, Symbols (Sym_Idx).Struct_Name_Len);
      begin
         if Sym_Idx > 0 and then Symbols (Sym_Idx).Alias_Idx > 0 then
            return Alias_Default_Value_Text
              (Symbols (Sym_Idx).Alias_Idx, Symbols (Sym_Idx).Tag);
         end if;
         return Default_Value_Text (Symbols (Sym_Idx).Tag, Struct_Name);
      end Symbol_Default_Value_Text;

      function Return_Type_Name_Text
        (Routine_Node : Node_Index;
         Return_Tag   : ALB_Type_Tag) return String is
         Return_Type_Text : constant String :=
           (if Tree (Routine_Node).Token_Index > 0
            then Upper_Safe_Name (Raw_Lexeme (Tree (Routine_Node).Token_Index))
            else "");
         Return_Alias : constant Natural := Find_Alias (Return_Type_Text);
      begin
         if Return_Alias > 0 then
            return Alias_Type_Name (Return_Alias);
         end if;
         return Ada_Type_Name (Return_Tag);
      end Return_Type_Name_Text;

      function Value_To_U64_Text
        (Expr : String;
         Tag  : ALB_Type_Tag) return String is
      begin
         case Tag is
            when Type_Boolean =>
               return "ALB_BOOL_TO_U64(" & Expr & ")";
            when Type_S8 =>
               return "ALB_S8_TO_U64(" & Expr & ")";
            when Type_S16 =>
               return "ALB_S16_TO_U64(" & Expr & ")";
            when Type_S32 =>
               return "ALB_S32_TO_U64(" & Expr & ")";
            when Type_S64 =>
               return "ALB_S64_TO_U64(" & Expr & ")";
            when Type_F32 | Type_F64 | Type_Binary | Type_Pure =>
               return "0";
            when Type_U64 =>
               return Expr;
            when others =>
               return "U64(" & Expr & ")";
         end case;
      end Value_To_U64_Text;

      function VAS_Store_Value_Text
        (Tag        : ALB_Type_Tag;
         Value_Text : String) return String is
      begin
         case Tag is
            when Type_Boolean | Type_U8 | Type_U16 | Type_U32 | Type_U64 =>
               return Value_Text;
            when Type_S8 =>
               return "ALB_I8(" & Value_Text & ")";
            when Type_S16 =>
               return "ALB_I16(" & Value_Text & ")";
            when Type_S32 =>
               return "ALB_I32(" & Value_Text & ")";
            when Type_S64 =>
               return "ALB_I64(" & Value_Text & ")";
            when others =>
               return Value_Text;
         end case;
      end VAS_Store_Value_Text;

      function U64_To_Value_Text
        (Expr : String;
         Tag  : ALB_Type_Tag) return String is
      begin
         case Tag is
            when Type_Boolean =>
               return "(" & Expr & " /= 0)";
            when Type_U8 =>
               return "ALB_U64_TO_U8(" & Expr & ")";
            when Type_U16 =>
               return "ALB_U64_TO_U16(" & Expr & ")";
            when Type_U32 =>
               return "ALB_U64_TO_U32(" & Expr & ")";
            when Type_S8 =>
               return "ALB_U64_TO_S8(" & Expr & ")";
            when Type_S16 =>
               return "ALB_U64_TO_S16(" & Expr & ")";
            when Type_S32 =>
               return "ALB_U64_TO_S32(" & Expr & ")";
            when Type_S64 =>
               return "ALB_U64_TO_S64(" & Expr & ")";
            when Type_F32 | Type_F64 | Type_Binary | Type_Pure =>
               return Default_Value_Text (Tag);
            when Type_U64 =>
               return Expr;
            when others =>
               return Ada_Type_Name (Tag) & "(" & Expr & ")";
         end case;
      end U64_To_Value_Text;

      function Tree_Contains_Kind
        (Idx               : Node_Index;
         Target            : Node_Kind;
         Skip_Nested_Loops : Boolean) return Boolean is
      begin
         if Idx = 0 then
            return False;
         end if;

         if Tree (Idx).Kind = Target then
            return True;
         end if;

         if Skip_Nested_Loops
           and then Tree (Idx).Kind in
                 AST_While_Stmt | AST_Repeat_Stmt | AST_For_Stmt | AST_Foreach_Stmt
         then
            return False;
         end if;

         if Tree (Idx).Kind = AST_If_Stmt then
            if Tree (Idx).Right_Child /= 0
              and then Tree (Tree (Idx).Right_Child).Next_Sibling /= 0
              and then Tree_Contains_Kind
                     (Tree (Tree (Idx).Right_Child).Next_Sibling,
                      Target,
                      Skip_Nested_Loops)
            then
               return True;
            end if;
         end if;

         return Tree_Contains_Kind (Tree (Idx).Left_Child, Target, Skip_Nested_Loops)
           or else Tree_Contains_Kind (Tree (Idx).Right_Child, Target, Skip_Nested_Loops)
           or else Tree_Contains_Kind (Tree (Idx).Next_Sibling, Target, Skip_Nested_Loops);
      end Tree_Contains_Kind;

      type Static_S64_Result is record
         Value   : S64 := 0;
         Success : Boolean := False;
      end record;

      function Static_Result
        (Value   : S64 := 0;
         Success : Boolean := False) return Static_S64_Result is
      begin
         return (Value => Value, Success => Success);
      end Static_Result;

      function Has_Real_Number_Marker (Value : String) return Boolean is
      begin
         for Ch of Value loop
            if Ch = '.' or else Ch = 'e' or else Ch = 'E' then
               return True;
            end if;
         end loop;
         return False;
      end Has_Real_Number_Marker;

      function Positive_S64_Limit return U64 is
      begin
         return U64 (S64'Last);
      end Positive_S64_Limit;

      function Negative_S64_Limit return U64 is
      begin
         return U64 (S64'Last) + 1;
      end Negative_S64_Limit;

      type U64_Accum_Result is record
         Value   : U64 := 0;
         Success : Boolean := False;
      end record;

      function Checked_Accumulate_U64
        (Current : U64;
         Base    : U64;
         Digit   : U64;
         Limit   : U64) return U64_Accum_Result
      is
      begin
         if Base = 0 or else Digit > Limit then
            return (Value => Current, Success => False);
         end if;

         if Current > (Limit - Digit) / Base then
            return (Value => Current, Success => False);
         end if;

         return (Value => (Current * Base) + Digit, Success => True);
      end Checked_Accumulate_U64;

      function Magnitude_To_Static_Result
        (Magnitude : U64;
         Negative  : Boolean) return Static_S64_Result is
      begin
         if Negative then
            if Magnitude = Negative_S64_Limit then
               return Static_Result (S64'First, True);
            elsif Magnitude <= Positive_S64_Limit then
               return Static_Result (-S64 (Magnitude), True);
            end if;
         elsif Magnitude <= Positive_S64_Limit then
            return Static_Result (S64 (Magnitude), True);
         end if;

         return Static_Result;
      end Magnitude_To_Static_Result;

      function Absolute_Magnitude (Value : S64) return U64 is
      begin
         if Value = S64'First then
            return Negative_S64_Limit;
         elsif Value < 0 then
            return U64 (-Value);
         end if;

         return U64 (Value);
      end Absolute_Magnitude;

      function Checked_Add_S64
        (Left  : S64;
         Right : S64) return Static_S64_Result is
      begin
         if Right > 0 and then Left > S64'Last - Right then
            return Static_Result;
         elsif Right < 0 and then Left < S64'First - Right then
            return Static_Result;
         end if;

         return Static_Result (Left + Right, True);
      end Checked_Add_S64;

      function Checked_Subtract_S64
        (Left  : S64;
         Right : S64) return Static_S64_Result is
      begin
         if Right = S64'First then
            if Left < 0 then
               return Static_Result (S64'Last + (Left + 1), True);
            end if;
            return Static_Result;
         end if;

         return Checked_Add_S64 (Left, -Right);
      end Checked_Subtract_S64;

      function Checked_Multiply_S64
        (Left  : S64;
         Right : S64) return Static_S64_Result is
         Negative  : constant Boolean := (Left < 0) xor (Right < 0);
         Limit     : constant U64 :=
           (if Negative then Negative_S64_Limit else Positive_S64_Limit);
         Left_Mag  : constant U64 := Absolute_Magnitude (Left);
         Right_Mag : constant U64 := Absolute_Magnitude (Right);
         Product   : U64 := 0;
      begin
         if Left = 0 or else Right = 0 then
            return Static_Result (0, True);
         end if;

         if Right_Mag /= 0 and then Left_Mag > Limit / Right_Mag then
            return Static_Result;
         end if;

         Product := Left_Mag * Right_Mag;
         return Magnitude_To_Static_Result (Product, Negative);
      end Checked_Multiply_S64;

      function Checked_Divide_S64
        (Left  : S64;
         Right : S64) return Static_S64_Result is
      begin
         if Right = 0 then
            return Static_Result;
         elsif Left = S64'First and then Right = -1 then
            return Static_Result;
         end if;

         return Static_Result (Left / Right, True);
      end Checked_Divide_S64;

      function Checked_Mod_S64
        (Left  : S64;
         Right : S64) return Static_S64_Result is
      begin
         if Right = 0 then
            return Static_Result;
         elsif Right = -1 then
            return Static_Result (0, True);
         end if;

         return Static_Result (Left mod Right, True);
      end Checked_Mod_S64;

      function Checked_Power_S64
        (Base_Value : S64;
         Exponent   : S64) return Static_S64_Result is
         Result_Value : Static_S64_Result := Static_Result (1, True);
         Factor       : Static_S64_Result := Static_Result (Base_Value, True);
         Power        : S64 := Exponent;
      begin
         if Exponent < 0 then
            return Static_Result;
         end if;

         for Iter in 1 .. 63 loop
            exit when Power = 0;

            if (Power mod 2) /= 0 then
               Result_Value :=
                 Checked_Multiply_S64 (Result_Value.Value, Factor.Value);
               if not Result_Value.Success then
                  return Static_Result;
               end if;
            end if;

            Power := Power / 2;
            exit when Power = 0;

            Factor := Checked_Multiply_S64 (Factor.Value, Factor.Value);
            if not Factor.Success then
               return Static_Result;
            end if;
         end loop;

         if Power /= 0 then
            return Static_Result;
         end if;

         return Result_Value;
      end Checked_Power_S64;

      function Try_Parse_Integer_Text
        (Text : String) return Static_S64_Result is
         Negative : Boolean := False;
         Start_At : Positive := Text'First;
         Magnitude : U64 := 0;
         Digit     : U64 := 0;
         Limit     : U64 := Positive_S64_Limit;
         Step      : U64_Accum_Result := (Value => 0, Success => False);
      begin
         if Text'Length = 0 then
            return Static_Result;
         end if;

         if Has_Real_Number_Marker (Text) then
            return Static_Result;
         end if;

         if Text (Start_At) = '-' then
            Negative := True;
            Limit := Negative_S64_Limit;
            if Start_At = Text'Last then
               return Static_Result;
            end if;
            Start_At := Start_At + 1;
         end if;

         for I in Start_At .. Text'Last loop
            if Text (I) = '_' then
               null;
            elsif Text (I) not in '0' .. '9' then
               return Static_Result;
            else
               Digit := U64 (Character'Pos (Text (I)) - Character'Pos ('0'));
               Step :=
                 Checked_Accumulate_U64
                   (Current => Magnitude,
                    Base    => 10,
                    Digit   => Digit,
                    Limit   => Limit);
               if not Step.Success then
                  return Static_Result;
               end if;
               Magnitude := Step.Value;
            end if;
         end loop;

         return Magnitude_To_Static_Result (Magnitude, Negative);
      end Try_Parse_Integer_Text;

      function Ada_F64_Literal (Text : String) return String is
         Has_Dot : Boolean := False;
         Exp_Pos : Natural := 0;
      begin
         for I in Text'Range loop
            if Text (I) = '.' then
               Has_Dot := True;
            elsif Text (I) = 'e' or else Text (I) = 'E' then
               Exp_Pos := I;
               exit;
            end if;
         end loop;

         if Exp_Pos /= 0 and then not Has_Dot then
            return Text (Text'First .. Exp_Pos - 1) & ".0" &
              Text (Exp_Pos .. Text'Last);
         end if;

         return Text;
      end Ada_F64_Literal;

      function Try_Parse_Based_Text
        (Text    : String;
         Base    : Positive) return Static_S64_Result is
         Magnitude : U64 := 0;
         Digit     : U64 := 0;
         Ch        : Character;
         Step      : U64_Accum_Result := (Value => 0, Success => False);
      begin
         if Text'Length <= 1 then
            return Static_Result;
         end if;

         for I in Text'First + 1 .. Text'Last loop
            Ch := Text (I);
            if Ch in '0' .. '9' then
               Digit := U64 (Character'Pos (Ch) - Character'Pos ('0'));
            elsif Ch in 'A' .. 'F' then
               Digit := U64 (10 + Character'Pos (Ch) - Character'Pos ('A'));
            elsif Ch in 'a' .. 'f' then
               Digit := U64 (10 + Character'Pos (Ch) - Character'Pos ('a'));
            else
               return Static_Result;
            end if;

            if Digit >= U64 (Base) then
                return Static_Result;
            end if;

            Step :=
              Checked_Accumulate_U64
                (Current => Magnitude,
                 Base    => U64 (Base),
                 Digit   => Digit,
                 Limit   => Positive_S64_Limit);
            if not Step.Success then
               return Static_Result;
            end if;
            Magnitude := Step.Value;
         end loop;

         return Magnitude_To_Static_Result (Magnitude, False);
      end Try_Parse_Based_Text;

      function Try_Eval_Static_S64
        (Node         : Node_Index;
         Module_Name  : String := "";
         Routine_Name : String := "") return Static_S64_Result is
         Tok_Kind   : Token_Kind;
         Left_Res   : Static_S64_Result := Static_Result;
         Right_Res  : Static_S64_Result := Static_Result;
         Const_Node : Node_Index := 0;
         Const_Val  : S64 := 0;
         Const_Found : Boolean := False;
         Lex        : constant String :=
           (if Node /= 0 and then Tree (Node).Token_Index > 0
            then Raw_Lexeme (Tree (Node).Token_Index)
            else "");
      begin
         if Node = 0 then
            return Static_Result;
         end if;

         case Tree (Node).Kind is
            when AST_Number_Expr =>
               if Has_Real_Number_Marker (Lex) then
                  return Static_Result;
               end if;
               return Try_Parse_Integer_Text (Lex);

            when AST_Hex_Expr =>
               return Try_Parse_Based_Text (Lex, 16);

            when AST_Bin_Expr =>
               return Try_Parse_Based_Text (Lex, 2);

            when AST_Octal_Expr =>
               return Try_Parse_Based_Text (Lex, 8);

            when AST_Const_Ref =>
               Const_Node := Find_Const_Expr (Lex, Module_Name, Routine_Name);
               if Const_Node /= 0 then
                  return Try_Eval_Static_S64 (Const_Node, Module_Name, Routine_Name);
               end if;
               Lookup_Const_Static_Value (Lex, Module_Name, Routine_Name, Const_Val, Const_Found);
               if Const_Found then
                  return Static_Result (Const_Val, True);
               end if;
               return Static_Result;

            when AST_Var_Expr | AST_Logic_Var =>
               Const_Node := Find_Const_Expr (Lex, Module_Name, Routine_Name);
               if Const_Node /= 0 then
                  return Try_Eval_Static_S64 (Const_Node, Module_Name, Routine_Name);
               end if;
               Lookup_Const_Static_Value (Lex, Module_Name, Routine_Name, Const_Val, Const_Found);
               if Const_Found then
                  return Static_Result (Const_Val, True);
               end if;
               return Static_Result;

            when AST_Cast_Expr =>
               if Tree (Node).Left_Child /= 0 then
                  return Try_Eval_Static_S64 (Tree (Node).Left_Child, Module_Name, Routine_Name);
               end if;
               return Static_Result;

            when AST_BinOp =>
               if Tree (Node).Token_Index = 0 then
                  return Static_Result;
               end if;
               Tok_Kind := Tokens (Tree (Node).Token_Index).Kind;
               Left_Res := Try_Eval_Static_S64 (Tree (Node).Left_Child, Module_Name, Routine_Name);
               Right_Res := Try_Eval_Static_S64 (Tree (Node).Right_Child, Module_Name, Routine_Name);
               if not Left_Res.Success or else not Right_Res.Success then
                  return Static_Result;
               end if;

               case Tok_Kind is
                  when TOK_PLUS =>
                     return Checked_Add_S64 (Left_Res.Value, Right_Res.Value);
                  when TOK_MINUS =>
                     return Checked_Subtract_S64 (Left_Res.Value, Right_Res.Value);
                  when TOK_MUL =>
                     return Checked_Multiply_S64 (Left_Res.Value, Right_Res.Value);
                  when TOK_DIV =>
                     return Checked_Divide_S64 (Left_Res.Value, Right_Res.Value);
                  when TOK_MOD =>
                     return Checked_Mod_S64 (Left_Res.Value, Right_Res.Value);
                  when TOK_POW =>
                     return Checked_Power_S64 (Left_Res.Value, Right_Res.Value);
                  when others =>
                     return Static_Result;
               end case;

            when others =>
               return Static_Result;
         end case;
      end Try_Eval_Static_S64;

      function Try_Parse_Natural
        (Node         : Node_Index;
         Default      : Natural := 1;
         Module_Name  : String := "";
         Routine_Name : String := "") return Natural is
         Result : constant Static_S64_Result :=
           Try_Eval_Static_S64 (Node, Module_Name, Routine_Name);
      begin
         if not Result.Success or else Result.Value < 0 then
            return Default;
         end if;
         if Result.Value > S64 (Natural'Last) then
            return Default;
         end if;
         return Natural (Result.Value);
      end Try_Parse_Natural;

      procedure Register_Source_Const_Declarations (Text : String) is
         procedure Process_Line (Line_Text : String) is
            Line_First   : Natural := Line_Text'First;
            Line_Last    : Natural := Line_Text'Last;
            Name_Start   : Natural := 0;
            Name_Stop    : Natural := 0;
            Eq_Pos       : Natural := 0;
            Expr_Start   : Natural := 0;
            Expr_Stop    : Natural := 0;
            Static_Res   : Static_S64_Result := Static_Result;
            Static_Value : S64 := 0;
            Static_Found : Boolean := False;
         begin
            while Line_First <= Line_Last
              and then (Line_Text (Line_First) = ' ' or else Line_Text (Line_First) = ASCII.HT)
            loop
               Line_First := Line_First + 1;
            end loop;

            if Line_First > Line_Last or else Line_Text (Line_First) /= '#' then
               return;
            end if;

            Name_Start := Line_First + 1;
            Name_Stop := Name_Start;
            while Name_Stop <= Line_Last
              and then Line_Text (Name_Stop) /= ' '
              and then Line_Text (Name_Stop) /= ASCII.HT
              and then Line_Text (Name_Stop) /= '='
            loop
               Name_Stop := Name_Stop + 1;
            end loop;

            Eq_Pos := Name_Stop;
            while Eq_Pos <= Line_Last and then Line_Text (Eq_Pos) /= '=' loop
               Eq_Pos := Eq_Pos + 1;
            end loop;
            if Eq_Pos > Line_Last then
               return;
            end if;

            Expr_Start := Eq_Pos + 1;
            while Expr_Start <= Line_Last
              and then (Line_Text (Expr_Start) = ' ' or else Line_Text (Expr_Start) = ASCII.HT)
            loop
               Expr_Start := Expr_Start + 1;
            end loop;
            if Expr_Start > Line_Last then
               return;
            end if;

            Expr_Stop := Line_Last;
            for I in Expr_Start .. Natural'Max (Expr_Start, Line_Last - 1) loop
               exit when I >= Line_Last;
               if Line_Text (I) = '-' and then Line_Text (I + 1) = '-' then
                  Expr_Stop := I - 1;
                  exit;
               end if;
            end loop;

            while Expr_Stop >= Expr_Start
              and then (Line_Text (Expr_Stop) = ' ' or else Line_Text (Expr_Stop) = ASCII.HT)
            loop
               exit when Expr_Stop = 0;
               Expr_Stop := Expr_Stop - 1;
            end loop;

            if Expr_Stop < Expr_Start or else Name_Stop <= Name_Start then
               return;
            end if;

            declare
               Raw_Name  : constant String := Line_Text (Line_First .. Name_Stop - 1);
               Expr_Text : constant String := Line_Text (Expr_Start .. Expr_Stop);
            begin
               if Expr_Text'Length > 0 and then Expr_Text (Expr_Text'First) = '$' then
                  Static_Res := Try_Parse_Based_Text (Expr_Text, 16);
               elsif Expr_Text'Length > 0 and then Expr_Text (Expr_Text'First) = '%' then
                  Static_Res := Try_Parse_Based_Text (Expr_Text, 2);
               elsif Expr_Text'Length > 0 and then Expr_Text (Expr_Text'First) = '#' then
                  Lookup_Const_Static_Value (Expr_Text, "", "", Static_Value, Static_Found);
                  Static_Res := Static_Result (Static_Value, Static_Found);
               else
                  Lookup_Const_Static_Value (Expr_Text, "", "", Static_Value, Static_Found);
                  if Static_Found then
                     Static_Res := Static_Result (Static_Value, True);
                  else
                     Static_Res := Try_Parse_Integer_Text (Expr_Text);
                  end if;
               end if;

               Register_Const
                 (Raw_Name,
                  "",
                  "",
                  0,
                  Static_Res.Value,
                  Static_Res.Success);
            end;
         end Process_Line;

         Line_Start : Natural := Text'First;
         Line_Stop  : Natural := Text'First;
      begin
         if Text'Length = 0 then
            return;
         end if;

         while Line_Start <= Text'Last loop
            Line_Stop := Line_Start;
            while Line_Stop <= Text'Last and then Text (Line_Stop) /= ASCII.LF loop
               Line_Stop := Line_Stop + 1;
            end loop;

            if Line_Stop > Line_Start then
               if Text (Line_Stop - 1) = ASCII.CR then
                  Process_Line (Text (Line_Start .. Line_Stop - 2));
               else
                  Process_Line (Text (Line_Start .. Line_Stop - 1));
               end if;
            elsif Line_Stop = Line_Start then
               null;
            end if;

            Line_Start := Line_Stop + 1;
         end loop;
      end Register_Source_Const_Declarations;

      function Strip_String_Literal (Text : String) return String is
      begin
         if Text'Length >= 2
           and then (Text (Text'First) = '"' or else Text (Text'First) = '`')
           and then Text (Text'Last) = Text (Text'First)
         then
            if Text'Length = 2 then
               return "";
            end if;
            return Text (Text'First + 1 .. Text'Last - 1);
         end if;
         return Text;
      end Strip_String_Literal;

      function Extract_Ada_Block_Body (Block_Text : String) return String is
         Start_At        : Natural := Block_Text'First;
         End_At          : Natural := Block_Text'Last;
         Last_Line_Start : Natural := Block_Text'Last;
      begin
         while Start_At <= Block_Text'Last and then Block_Text (Start_At) /= ASCII.LF loop
            Start_At := Start_At + 1;
         end loop;

         if Start_At > Block_Text'Last then
            return "";
         end if;

         Start_At := Start_At + 1;
         Last_Line_Start := Block_Text'Last;
         while Last_Line_Start > Start_At
           and then Block_Text (Last_Line_Start - 1) /= ASCII.LF
         loop
            Last_Line_Start := Last_Line_Start - 1;
         end loop;

         End_At := Last_Line_Start - 1;
         if End_At < Start_At then
            return "";
         end if;

         return Block_Text (Start_At .. End_At);
      end Extract_Ada_Block_Body;

      function Struct_Size_Bytes (Struct_Name : String) return Natural;

      function Type_Size_Bytes
        (Tag : ALB_Type_Tag) return Natural is
      begin
         case Tag is
            when Type_U8 | Type_S8 =>
               return 1;
            when Type_U16 | Type_S16 =>
               return 2;
            when Type_U32 | Type_S32 | Type_F32 =>
               return 4;
            when Type_U64 | Type_S64 | Type_F64 =>
               return 8;
            when Type_Pure =>
               return 16;
            when Type_F32x2 =>
               return 8;
            when Type_F32x4 | Type_Mat2x2 =>
               return 16;
            when Type_Mat3x3 =>
               return 48;
            when Type_Mat4x4 =>
               return 64;
            when Type_Boolean =>
               return 1;
            when Type_Binary =>
               return 4 + Max_Text_Length;
            when others =>
               return 8;
         end case;
      end Type_Size_Bytes;

      function Symbol_Element_Size_Bytes (Sym_Idx : Natural) return Natural is
      begin
         if Sym_Idx = 0 then
            return 0;
         elsif Symbols (Sym_Idx).Struct_Name_Len > 0 then
            return Struct_Size_Bytes
              (Name_Text
                 (Symbols (Sym_Idx).Struct_Name,
                  Symbols (Sym_Idx).Struct_Name_Len));
         else
            return Type_Size_Bytes (Symbols (Sym_Idx).Tag);
         end if;
      end Symbol_Element_Size_Bytes;

      function Param_Size_Bytes (Param_Idx : Natural) return Natural is
      begin
         if Param_Idx = 0 then
            return 0;
         elsif Current_Params (Param_Idx).Struct_Name_Len > 0 then
            return Struct_Size_Bytes
              (Name_Text
                 (Current_Params (Param_Idx).Struct_Name,
                  Current_Params (Param_Idx).Struct_Name_Len));
         else
            return Type_Size_Bytes (Current_Params (Param_Idx).Tag);
         end if;
      end Param_Size_Bytes;

      function Type_Name_Text
        (Tag : ALB_Type_Tag) return String is
      begin
         case Tag is
            when Type_U8      => return "U8";
            when Type_U16     => return "U16";
            when Type_U32     => return "U32";
            when Type_U64     => return "U64";
            when Type_S8      => return "S8";
            when Type_S16     => return "S16";
            when Type_S32     => return "S32";
            when Type_S64     => return "S64";
            when Type_F32     => return "F32";
            when Type_F64     => return "F64";
            when Type_Boolean => return "BOOL";
            when Type_Binary  => return "STRING";
            when Type_Pure    => return "PURE";
            when others       => return "U64";
         end case;
      end Type_Name_Text;

      procedure Register_Module (Text : String) is
      begin
         if Text'Length = 0 or else Module_Count >= Max_Modules then
            return;
         end if;
         if Is_Module_Name (Safe_Name (Text)) then
            return;
         end if;
         Module_Count := Module_Count + 1;
         Modules (Module_Count).Active := True;
         Modules (Module_Count).Name_Len := Safe_Name_Length (Text);
         Modules (Module_Count).Name := Copy_Name (Safe_Name (Text));
      end Register_Module;

      function Find_Symbol (Emit_Name : String) return Natural is
      begin
         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then Symbols (I).Name_Len = Emit_Name'Length
              and then Name_Text (Symbols (I).Name, Symbols (I).Name_Len) = Emit_Name
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Symbol;

      procedure Register_Alias (Name : String; Tag : ALB_Type_Tag) is
      begin
         if Tag = Type_None or else Alias_Count >= Max_Aliases then
            return;
         end if;
         if Find_Alias (Name) > 0 then
            return;
         end if;
         Alias_Count := Alias_Count + 1;
         Aliases (Alias_Count).Active := True;
         Aliases (Alias_Count).Name_Len := Upper_Safe_Name_Length (Name);
         Aliases (Alias_Count).Name := Copy_Name (Upper_Safe_Name (Name));
         Aliases (Alias_Count).Tag := Tag;
      end Register_Alias;

      procedure Register_Range_Alias
        (Name     : String;
         Tag      : ALB_Type_Tag;
         Low_Res  : Static_S64_Result;
         High_Res : Static_S64_Result) is
         Idx : Natural := Find_Alias (Name);
      begin
         if Tag = Type_None then
            return;
         end if;
         if Idx = 0 then
            Register_Alias (Name, Tag);
            Idx := Find_Alias (Name);
         end if;
         if Idx = 0 then
            return;
         end if;
         Aliases (Idx).Tag := Tag;
         if Low_Res.Success and then High_Res.Success then
            Aliases (Idx).Has_Range := True;
            Aliases (Idx).Range_Low := Low_Res.Value;
            Aliases (Idx).Range_High := High_Res.Value;
         end if;
      end Register_Range_Alias;

      procedure Register_Symbol
        (Emit_Name      : String;
         Raw_Name       : String;
         Module_Name    : String;
         Scope_Name     : String;
         Tag            : ALB_Type_Tag;
         Kind           : Symbol_Kind := Sym_Scalar;
         Rank           : Natural := 0;
         Dims           : Dim_Array := (others => 0);
         Struct_Name    : String := "";
         History_Size   : Natural := 0;
         Timeline_Off   : Natural := 0;
         Alias_Idx      : Natural := 0) is
         Idx : Natural := 0;
      begin
         if Emit_Name'Length = 0 or else Symbol_Count >= Max_Symbols then
            return;
         end if;
         Idx := Find_Symbol (Emit_Name);
         if Idx > 0 then
            return;
         end if;
         Symbol_Count := Symbol_Count + 1;
         Symbols (Symbol_Count).Active := True;
         Symbols (Symbol_Count).Name_Len := Emit_Name'Length;
         Symbols (Symbol_Count).Name := Copy_Name (Emit_Name);
         Symbols (Symbol_Count).Raw_Name_Len := Raw_Name'Length;
         Symbols (Symbol_Count).Raw_Name := Copy_Name (Raw_Name);
         Symbols (Symbol_Count).Module_Name_Len := Module_Name'Length;
         Symbols (Symbol_Count).Module_Name := Copy_Name (Module_Name);
         Symbols (Symbol_Count).Scope_Name_Len := Scope_Name'Length;
         Symbols (Symbol_Count).Scope_Name := Copy_Name (Scope_Name);
         Symbols (Symbol_Count).Tag := Tag;
         Symbols (Symbol_Count).Kind := Kind;
         Symbols (Symbol_Count).Rank := Natural'Min (Rank, 4);
         Symbols (Symbol_Count).Dims := Dims;
         Symbols (Symbol_Count).Struct_Name_Len := Struct_Name'Length;
         Symbols (Symbol_Count).Struct_Name := Copy_Name (Struct_Name);
         Symbols (Symbol_Count).History_Size := History_Size;
         Symbols (Symbol_Count).Timeline_Offset := Timeline_Off;
         Symbols (Symbol_Count).Alias_Idx := Alias_Idx;
      end Register_Symbol;

      procedure Register_Const
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "";
         Expr_Node    : Node_Index := 0;
         Static_Value : S64 := 0;
         Has_Static   : Boolean := False) is
         Key          : constant String := Normalize_Const_Name (Raw_Name);
         Scope_Text   : constant String :=
           (if Routine_Name'Length > 0 then Safe_Name (Routine_Name) else "");
      begin
         for I in 1 .. Const_Count loop
            if Consts (I).Active
              and then Consts (I).Name_Len = Key'Length
              and then Name_Text (Consts (I).Name, Consts (I).Name_Len) = Key
              and then Consts (I).Module_Name_Len = Module_Name'Length
              and then Name_Text (Consts (I).Module_Name, Consts (I).Module_Name_Len) = Module_Name
              and then Consts (I).Scope_Name_Len = Scope_Text'Length
              and then Name_Text (Consts (I).Scope_Name, Consts (I).Scope_Name_Len) = Scope_Text
            then
               Consts (I).Expr_Node := Expr_Node;
               if Has_Static then
                  Consts (I).Static_Value := Static_Value;
                  Consts (I).Has_Static_Value := True;
               end if;
               return;
            end if;
         end loop;

         if Const_Count < Max_Consts then
            Const_Count := Const_Count + 1;
            Consts (Const_Count).Active := True;
            Consts (Const_Count).Name_Len := Key'Length;
            Consts (Const_Count).Name := Copy_Name (Key);
            Consts (Const_Count).Module_Name_Len := Module_Name'Length;
            Consts (Const_Count).Module_Name := Copy_Name (Module_Name);
            Consts (Const_Count).Scope_Name_Len := Scope_Text'Length;
            Consts (Const_Count).Scope_Name := Copy_Name (Scope_Text);
            Consts (Const_Count).Expr_Node := Expr_Node;
            Consts (Const_Count).Static_Value := Static_Value;
            Consts (Const_Count).Has_Static_Value := Has_Static;
         end if;
      end Register_Const;

      function Find_Const_Expr
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "") return Node_Index is
         Key           : constant String := Normalize_Const_Name (Raw_Name);
         Scope_Text    : constant String :=
           (if Routine_Name'Length > 0
            then Safe_Name (Routine_Name)
            elsif Current_Routine_Scope_Len > 0
            then Name_Text (Current_Routine_Scope, Current_Routine_Scope_Len)
            else "");
      begin
         if Scope_Text'Length > 0 then
            for I in 1 .. Const_Count loop
               if Consts (I).Active
                 and then Consts (I).Name_Len = Key'Length
                 and then Name_Text (Consts (I).Name, Consts (I).Name_Len) = Key
                 and then Consts (I).Module_Name_Len = Module_Name'Length
                 and then Name_Text (Consts (I).Module_Name, Consts (I).Module_Name_Len) = Module_Name
                 and then Consts (I).Scope_Name_Len = Scope_Text'Length
                 and then Name_Text (Consts (I).Scope_Name, Consts (I).Scope_Name_Len) = Scope_Text
               then
                  return Consts (I).Expr_Node;
               end if;
            end loop;
         end if;

         for I in 1 .. Const_Count loop
            if Consts (I).Active
              and then Consts (I).Name_Len = Key'Length
              and then Name_Text (Consts (I).Name, Consts (I).Name_Len) = Key
              and then Consts (I).Module_Name_Len = Module_Name'Length
              and then Name_Text (Consts (I).Module_Name, Consts (I).Module_Name_Len) = Module_Name
              and then Consts (I).Scope_Name_Len = 0
            then
               return Consts (I).Expr_Node;
            end if;
         end loop;

         for I in 1 .. Const_Count loop
            if Consts (I).Active
              and then Consts (I).Name_Len = Key'Length
              and then Name_Text (Consts (I).Name, Consts (I).Name_Len) = Key
              and then Consts (I).Module_Name_Len = 0
              and then Consts (I).Scope_Name_Len = 0
            then
               return Consts (I).Expr_Node;
            end if;
         end loop;

         return 0;
      end Find_Const_Expr;

      procedure Lookup_Const_Static_Value
        (Raw_Name     : String;
         Module_Name  : String := "";
         Routine_Name : String := "";
         Value        : out S64;
         Found        : out Boolean) is
         Key        : constant String := Normalize_Const_Name (Raw_Name);
         Scope_Text : constant String :=
           (if Routine_Name'Length > 0
            then Safe_Name (Routine_Name)
            elsif Current_Routine_Scope_Len > 0
            then Name_Text (Current_Routine_Scope, Current_Routine_Scope_Len)
            else "");
      begin
         Value := 0;
         Found := False;

         if Scope_Text'Length > 0 then
            for I in 1 .. Const_Count loop
               if Consts (I).Active
                 and then Consts (I).Has_Static_Value
                 and then Consts (I).Name_Len = Key'Length
                 and then Name_Text (Consts (I).Name, Consts (I).Name_Len) = Key
                 and then Consts (I).Module_Name_Len = Module_Name'Length
                 and then Name_Text (Consts (I).Module_Name, Consts (I).Module_Name_Len) = Module_Name
                 and then Consts (I).Scope_Name_Len = Scope_Text'Length
                 and then Name_Text (Consts (I).Scope_Name, Consts (I).Scope_Name_Len) = Scope_Text
               then
                  Value := Consts (I).Static_Value;
                  Found := True;
                  return;
               end if;
            end loop;
         end if;

         for I in 1 .. Const_Count loop
            if Consts (I).Active
              and then Consts (I).Has_Static_Value
              and then Consts (I).Name_Len = Key'Length
              and then Name_Text (Consts (I).Name, Consts (I).Name_Len) = Key
              and then Consts (I).Module_Name_Len = Module_Name'Length
              and then Name_Text (Consts (I).Module_Name, Consts (I).Module_Name_Len) = Module_Name
              and then Consts (I).Scope_Name_Len = 0
            then
               Value := Consts (I).Static_Value;
               Found := True;
               return;
            end if;
         end loop;

         for I in 1 .. Const_Count loop
            if Consts (I).Active
              and then Consts (I).Has_Static_Value
              and then Consts (I).Name_Len = Key'Length
              and then Name_Text (Consts (I).Name, Consts (I).Name_Len) = Key
              and then Consts (I).Module_Name_Len = 0
              and then Consts (I).Scope_Name_Len = 0
            then
               Value := Consts (I).Static_Value;
               Found := True;
               return;
            end if;
         end loop;
      end Lookup_Const_Static_Value;

      procedure Register_Routine
        (Node        : Node_Index;
         Module_Name : String) is
      begin
         if Node = 0 or else Routine_Count >= Max_Routines then
            return;
         end if;
         Routine_Count := Routine_Count + 1;
         Routines (Routine_Count).Active := True;
         Routines (Routine_Count).Node := Node;
         Routines (Routine_Count).Module_Name_Len := Module_Name'Length;
         Routines (Routine_Count).Module_Name := Copy_Name (Module_Name);
      end Register_Routine;

      function Routine_Ada_Name (Idx : Natural) return String is
         Name_Node : Node_Index := 0;
      begin
         if Idx < 1 or else Idx > Routine_Count or else not Routines (Idx).Active then
            return "";
         end if;
         if Routines (Idx).Node = 0 then
            return "";
         end if;
         Name_Node := Tree (Routines (Idx).Node).Left_Child;
         if Name_Node = 0 then
            return "";
         end if;
         declare
            Raw_Name : constant String :=
              Sanitize_Ada_Ident (Raw_Lexeme (Tree (Name_Node).Token_Index));
         begin
            if Routines (Idx).Module_Name_Len = 0 then
               return Raw_Name;
            end if;
            return Sanitize_Ada_Ident
              (Name_Text (Routines (Idx).Module_Name, Routines (Idx).Module_Name_Len)) &
              "_" & Raw_Name;
         end;
      end Routine_Ada_Name;

      procedure Build_Ada_Case_Renames is
         Old_Name : String (1 .. Max_Name_Length) := (others => ' ');
         Old_Len  : Natural := 0;
         New_Name : String (1 .. Max_Name_Length) := (others => ' ');
         New_Len  : Natural := 0;
      begin
         Ada_Rename_Count := 0;
         for R in 1 .. Routine_Count loop
            declare
               Qual_Text : constant String := Routine_Ada_Name (R);
            begin
               if Qual_Text'Length > 0 then
                  for S in 1 .. Symbol_Count loop
                     if Symbols (S).Active
                       and then Symbols (S).Scope_Name_Len = 0
                       and then Symbols (S).Name_Len > 0
                       and then Fold_Ada_Ident (Qual_Text) =
                                Fold_Ada_Ident
                                  (Slice_Name (Symbols (S).Name, Symbols (S).Name_Len))
                       and then Qual_Text /=
                                Slice_Name (Symbols (S).Name, Symbols (S).Name_Len)
                     then
                        Old_Len := Symbols (S).Name_Len;
                        declare
                           Current : constant String :=
                             Slice_Name (Symbols (S).Name, Symbols (S).Name_Len);
                        begin
                           Old_Name (1 .. Old_Len) := Current;
                        end;
                        New_Len := Old_Len + 2;
                        if New_Len <= Max_Name_Length
                          and then Ada_Rename_Count < Max_Symbols
                        then
                           New_Name (1 .. Old_Len) := Old_Name (1 .. Old_Len);
                           New_Name (Old_Len + 1) := '_';
                           New_Name (Old_Len + 2) := 'D';
                           Ada_Rename_Count := Ada_Rename_Count + 1;
                           Ada_Renames (Ada_Rename_Count).Active := True;
                           Ada_Renames (Ada_Rename_Count).From_Len := Old_Len;
                           for C in 1 .. Old_Len loop
                              Ada_Renames (Ada_Rename_Count).From (C) := Old_Name (C);
                           end loop;
                           Ada_Renames (Ada_Rename_Count).To_Len := New_Len;
                           for C in 1 .. New_Len loop
                              Ada_Renames (Ada_Rename_Count).To (C) := New_Name (C);
                           end loop;
                           Symbols (S).Name_Len := New_Len;
                           for C in 1 .. New_Len loop
                              Symbols (S).Name (C) := New_Name (C);
                           end loop;
                        end if;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
      end Build_Ada_Case_Renames;

      procedure Register_Network_Socket
        (Name : String;
         Node : Node_Index) is
      begin
         if Name'Length = 0 or else Name'Length > Max_Name_Length then
            return;
         end if;

         for I in 1 .. Network_Socket_Count loop
            if Network_Sockets (I).Active
              and then Network_Sockets (I).Name_Len = Name'Length
              and then Name_Text (Network_Sockets (I).Name, Network_Sockets (I).Name_Len) = Name
            then
               Network_Sockets (I).Node := Node;
               return;
            end if;
         end loop;

         if Network_Socket_Count < Max_Advanced_Nodes then
            Network_Socket_Count := Network_Socket_Count + 1;
            Network_Sockets (Network_Socket_Count).Active := True;
            Network_Sockets (Network_Socket_Count).Name_Len := Name'Length;
            Network_Sockets (Network_Socket_Count).Name := Copy_Name (Name);
            Network_Sockets (Network_Socket_Count).Node := Node;
         end if;
      end Register_Network_Socket;

      function Find_Network_Socket (Name : String) return Natural is
      begin
         for I in 1 .. Network_Socket_Count loop
            if Network_Sockets (I).Active
              and then Network_Sockets (I).Name_Len = Name'Length
              and then Name_Text (Network_Sockets (I).Name, Network_Sockets (I).Name_Len) = Name
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Network_Socket;

      function Firewall_Target_Image (Node : Node_Index) return String is
      begin
         if Node = 0 then
            return "";
         end if;
         if Tree (Node).Kind /= AST_Var_Expr then
            return "";
         end if;
         if Tree (Node).Left_Child /= 0 then
            if Tree (Tree (Node).Left_Child).Token_Index = 0 then
               return "";
            end if;
            return Safe_Name
              (Raw_Lexeme (Tree (Tree (Node).Left_Child).Token_Index));
         end if;
         if Tree (Node).Token_Index = 0 then
            return "";
         end if;
         return Safe_Name (Raw_Lexeme (Tree (Node).Token_Index));
      end Firewall_Target_Image;

      procedure Register_Firewall_Decl (Idx : Node_Index) is
         Name_Node : constant Node_Index := Tree (Idx).Left_Child;
         Rule      : Node_Index := Tree (Idx).Right_Child;
         Fw_Id     : Natural := 0;
         Target    : String := "";
      begin
         if Name_Node = 0 or else Firewall_Count >= Max_Firewalls then
            return;
         end if;

         Firewall_Count := Firewall_Count + 1;
         Fw_Id := Firewall_Count;
         Firewalls (Fw_Id).Active := True;
         Firewalls (Fw_Id).Name_Len :=
           Safe_Name_Length (Raw_Lexeme (Tree (Name_Node).Token_Index));
         Firewalls (Fw_Id).Name :=
           Copy_Name (Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
         Firewalls (Fw_Id).Rule_First := Firewall_Rule_Count + 1;
         Firewalls (Fw_Id).Rule_Count := 0;
         Firewalls (Fw_Id).Deny_All := False;

         while Rule /= 0 loop
            case Tree (Rule).Kind is
               when AST_Firewall_Permit_Read =>
                  Target := Firewall_Target_Image (Tree (Rule).Left_Child);
                  if Target'Length > 0
                    and then Target'Length <= Max_Name_Length
                    and then Firewall_Rule_Count < Max_Firewall_Rules
                  then
                     Firewall_Rule_Count := Firewall_Rule_Count + 1;
                     Firewall_Rules (Firewall_Rule_Count).Active := True;
                     Firewall_Rules (Firewall_Rule_Count).Target_Len := Target'Length;
                     Firewall_Rules (Firewall_Rule_Count).Target_Name := Copy_Name (Target);
                     Firewall_Rules (Firewall_Rule_Count).Allow_Read := True;
                     Firewalls (Fw_Id).Rule_Count := Firewalls (Fw_Id).Rule_Count + 1;
                  end if;

               when AST_Firewall_Permit_Write =>
                  Target := Firewall_Target_Image (Tree (Rule).Left_Child);
                  if Target'Length > 0
                    and then Target'Length <= Max_Name_Length
                    and then Firewall_Rule_Count < Max_Firewall_Rules
                  then
                     Firewall_Rule_Count := Firewall_Rule_Count + 1;
                     Firewall_Rules (Firewall_Rule_Count).Active := True;
                     Firewall_Rules (Firewall_Rule_Count).Target_Len := Target'Length;
                     Firewall_Rules (Firewall_Rule_Count).Target_Name := Copy_Name (Target);
                     Firewall_Rules (Firewall_Rule_Count).Allow_Write := True;
                     Firewalls (Fw_Id).Rule_Count := Firewalls (Fw_Id).Rule_Count + 1;
                  end if;

               when AST_Firewall_Deny_All =>
                  Firewalls (Fw_Id).Deny_All := True;

               when others =>
                  null;
            end case;
            Rule := Tree (Rule).Next_Sibling;
         end loop;
      end Register_Firewall_Decl;

      function Firewall_Constant_Name (Fw_Index : Natural) return String is
      begin
         if Fw_Index = 0 or else Fw_Index > Firewall_Count then
            return "ALBA_Fw_Unknown";
         end if;
         return
           "ALBA_Fw_" &
           Name_Text (Firewalls (Fw_Index).Name, Firewalls (Fw_Index).Name_Len);
      end Firewall_Constant_Name;

      function Find_Firewall (Name : String) return Natural is
      begin
         for I in 1 .. Firewall_Count loop
            if Firewalls (I).Active
              and then Firewalls (I).Name_Len = Name'Length
              and then Name_Text (Firewalls (I).Name, Firewalls (I).Name_Len) = Name
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Firewall;

      function Find_Bound_Firewall_On_Params (Param_List : Node_Index) return Natural is
         Curr : Node_Index := Param_List;
      begin
         if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
            Curr := Tree (Param_List).Next_Sibling;
         end if;
         while Curr /= 0 loop
            if Tree (Curr).Kind = AST_Bound_To_Clause
              and then Tree (Curr).Left_Child /= 0
            then
               return Find_Firewall
                 (Safe_Name
                    (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index)));
            end if;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
         return 0;
      end Find_Bound_Firewall_On_Params;

      procedure Emit_Firewall_Assert
        (Target_Node : Node_Index;
         Need_Read   : Boolean;
         Need_Write  : Boolean;
         Ok          : in out Boolean) is
         Target : constant String := Firewall_Target_Image (Target_Node);
      begin
         if Firewall_Count = 0 or else Target'Length = 0 then
            return;
         end if;
         Emit_Indent (Ok);
         Emit_Raw
           ("ALBA_Firewall.Assert_Access (""" & Target & """, " &
            (if Need_Read then "True" else "False") & ", " &
            (if Need_Write then "True" else "False") & ");",
            Ok);
         Emit_Newline (Ok);
      end Emit_Firewall_Assert;

      procedure Emit_Firewall_Constant_Declarations (Ok : in out Boolean) is
      begin
         if Firewall_Count = 0 then
            return;
         end if;
         for F in 1 .. Firewall_Count loop
            exit when not Ok;
            if not Firewalls (F).Active then
               goto Next_Fw_Const;
            end if;
            Emit_Line
              (Firewall_Constant_Name (F) & " : Natural := 0;",
               Ok);
            <<Next_Fw_Const>>
            null;
         end loop;
         Emit_Newline (Ok);
      end Emit_Firewall_Constant_Declarations;

      procedure Emit_Firewall_Program_Init (Ok : in out Boolean) is
      begin
         if Firewall_Count = 0 then
            return;
         end if;

         Emit_Line ("ALBA_Firewall.Clear_All;", Ok);
         for F in 1 .. Firewall_Count loop
            exit when not Ok;
            if not Firewalls (F).Active then
               goto Next_Firewall;
            end if;
            Emit_Line
              (Firewall_Constant_Name (F) & " := ALBA_Firewall.Register_Firewall (""" &
               Name_Text (Firewalls (F).Name, Firewalls (F).Name_Len) &
               """, " &
               (if Firewalls (F).Deny_All then "True" else "False") &
               ");",
               Ok);
            if Firewalls (F).Rule_Count > 0 then
               for R in
                 Firewalls (F).Rule_First ..
                 Firewalls (F).Rule_First + Firewalls (F).Rule_Count - 1
               loop
                  exit when not Ok;
                  if not Firewall_Rules (R).Active then
                     goto Next_Rule;
                  end if;
                  if Firewall_Rules (R).Allow_Read then
                     Emit_Line
                       ("ALBA_Firewall.Add_Permit_Read (" &
                        Firewall_Constant_Name (F) & ", """ &
                        Name_Text
                          (Firewall_Rules (R).Target_Name,
                           Firewall_Rules (R).Target_Len) &
                        """);",
                        Ok);
                  end if;
                  if Firewall_Rules (R).Allow_Write then
                     Emit_Line
                       ("ALBA_Firewall.Add_Permit_Write (" &
                        Firewall_Constant_Name (F) & ", """ &
                        Name_Text
                          (Firewall_Rules (R).Target_Name,
                           Firewall_Rules (R).Target_Len) &
                        """);",
                        Ok);
                  end if;
                  <<Next_Rule>>
                  null;
               end loop;
            end if;
            <<Next_Firewall>>
            null;
         end loop;
      end Emit_Firewall_Program_Init;

      function Resolve_Routine_Node
        (Name_Node    : Node_Index;
         Module_Name  : String := "") return Node_Index
      is
         Call_Name   : Name_Buffer := (others => ' ');
         Call_Name_Len : Natural := 0;
         Call_Module : Name_Buffer := (others => ' ');
         Call_Module_Len : Natural := 0;
      begin
         if Name_Node = 0 then
            return 0;
         end if;

         if Tree (Name_Node).Kind = AST_Var_Expr then
            Call_Name_Len := Safe_Name_Length (Raw_Lexeme (Tree (Name_Node).Token_Index));
            Call_Name := Copy_Name (Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
            Call_Module_Len := Module_Name'Length;
            Call_Module := Copy_Name (Module_Name);
         elsif Tree (Name_Node).Kind = AST_Member_Expr
            and then Tree (Name_Node).Left_Child /= 0
            and then Tree (Name_Node).Right_Child /= 0
            and then Tree (Tree (Name_Node).Left_Child).Kind = AST_Var_Expr
            and then Tree (Tree (Name_Node).Right_Child).Kind = AST_Var_Expr
         then
            Call_Module_Len :=
              Safe_Name_Length (Raw_Lexeme (Tree (Tree (Name_Node).Left_Child).Token_Index));
            Call_Module :=
              Copy_Name
                (Safe_Name (Raw_Lexeme (Tree (Tree (Name_Node).Left_Child).Token_Index)));
            Call_Name_Len :=
              Safe_Name_Length (Raw_Lexeme (Tree (Tree (Name_Node).Right_Child).Token_Index));
            Call_Name :=
               Copy_Name
                 (Safe_Name (Raw_Lexeme (Tree (Tree (Name_Node).Right_Child).Token_Index)));
         else
            return 0;
         end if;

         for Pass in 1 .. 2 loop
            for I in 1 .. Routine_Count loop
               if Routines (I).Active
                 and then Routines (I).Node /= 0
                then
                  declare
                     Routine_Name_Node : constant Node_Index :=
                        Tree (Routines (I).Node).Left_Child;
                  begin
                     if Routine_Name_Node /= 0
                       and then Call_Name_Len =
                         Safe_Name_Length (Raw_Lexeme (Tree (Routine_Name_Node).Token_Index))
                       and then Name_Text (Call_Name, Call_Name_Len) =
                         Safe_Name (Raw_Lexeme (Tree (Routine_Name_Node).Token_Index))
                     then
                        declare
                           Routine_Module : constant String :=
                             Name_Text (Routines (I).Module_Name, Routines (I).Module_Name_Len);
                        begin
                           if (Pass = 1
                               and then Routine_Module = Name_Text (Call_Module, Call_Module_Len))
                             or else
                              (Pass = 2
                               and then Routine_Module'Length = 0)
                           then
                              return Routines (I).Node;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end loop;
         end loop;

         return 0;
      end Resolve_Routine_Node;

      function Resolve_Routine_Return_Tag
        (Name_Node    : Node_Index;
         Module_Name  : String := "") return ALB_Type_Tag
      is
         Routine_Node : constant Node_Index :=
           Resolve_Routine_Node (Name_Node, Module_Name);
         Return_Tag   : ALB_Type_Tag := Type_None;
      begin
         if Routine_Node = 0 or else Tree (Routine_Node).Kind /= AST_Function_Decl then
            return Type_None;
         end if;

         Return_Tag := Tag_From_Name (Raw_Lexeme (Tree (Routine_Node).Token_Index));
         if Return_Tag = Type_None then
            Return_Tag := Type_U64;
         end if;
         return Return_Tag;
      end Resolve_Routine_Return_Tag;

      function Resolve_Routine_Param_Tag
        (Name_Node    : Node_Index;
         Module_Name  : String := "";
         Param_Pos    : Positive) return ALB_Type_Tag
      is
         Routine_Node : constant Node_Index :=
           Resolve_Routine_Node (Name_Node, Module_Name);
         Param_List   : Node_Index := 0;
         Curr         : Node_Index := 0;
         Index        : Positive := 1;
      begin
         if Routine_Node = 0 or else Tree (Routine_Node).Left_Child = 0 then
            return Type_None;
         end if;

         Param_List := Tree (Tree (Routine_Node).Left_Child).Right_Child;
         if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
            Curr := Tree (Param_List).Left_Child;
         else
            Curr := Param_List;
         end if;

         while Curr /= 0 loop
            if Index = Param_Pos then
               if Tree (Curr).Right_Child /= 0 then
                  declare
                     Param_Type_Name : constant String :=
                       Raw_Lexeme (Tree (Tree (Curr).Right_Child).Token_Index);
                     Param_Tag       : constant ALB_Type_Tag :=
                       Tag_From_Name (Param_Type_Name);
                  begin
                     return Param_Tag;
                  end;
               else
                  return Type_None;
               end if;
            end if;
            Curr := Tree (Curr).Next_Sibling;
            Index := Index + 1;
         end loop;

         return Type_None;
      end Resolve_Routine_Param_Tag;

      function Find_Parallel_Field
        (Group_Name : String;
         Field_Name : String) return Natural is
      begin
         for I in 1 .. Parallel_Count loop
            if Parallel_Fields (I).Active
              and then Name_Text (Parallel_Fields (I).Group_Name, Parallel_Fields (I).Group_Name_Len) = Group_Name
              and then Name_Text (Parallel_Fields (I).Field_Name, Parallel_Fields (I).Field_Name_Len) = Safe_Name (Field_Name)
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Parallel_Field;

      function Has_Parallel_Group (Group_Name : String) return Boolean is
      begin
         for I in 1 .. Parallel_Count loop
            if Parallel_Fields (I).Active
              and then Name_Text (Parallel_Fields (I).Group_Name, Parallel_Fields (I).Group_Name_Len) = Group_Name
            then
               return True;
            end if;
         end loop;
         return False;
      end Has_Parallel_Group;

      function Find_Struct_Field
        (Struct_Name : String;
         Field_Name  : String) return Natural is
      begin
         for I in 1 .. Struct_Count loop
            if Struct_Fields (I).Active
              and then Name_Text (Struct_Fields (I).Struct_Name, Struct_Fields (I).Struct_Name_Len) = Safe_Name (Struct_Name)
              and then Name_Text (Struct_Fields (I).Field_Name, Struct_Fields (I).Field_Name_Len) = Safe_Name (Field_Name)
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Struct_Field;

      function Resolve_Name
        (Raw_Name     : String;
         Module_Name  : String := "") return String;

      function Is_Struct_Name (Text : String) return Boolean is
         Name : constant String := Safe_Name (Text);
      begin
         for I in 1 .. Struct_Count loop
            if Struct_Fields (I).Active
              and then Name_Text (Struct_Fields (I).Struct_Name, Struct_Fields (I).Struct_Name_Len) = Name
            then
               return True;
            end if;
         end loop;
         return False;
      end Is_Struct_Name;

      function Struct_Size_Bytes (Struct_Name : String) return Natural is
         Name : constant String := Safe_Name (Struct_Name);
         Size : Natural := 0;
      begin
         for I in 1 .. Struct_Count loop
            if Struct_Fields (I).Active
              and then Name_Text (Struct_Fields (I).Struct_Name, Struct_Fields (I).Struct_Name_Len) = Name
            then
               Size :=
                 Natural'Max
                   (Size,
                    Struct_Fields (I).Offset_Bytes + Type_Size_Bytes (Struct_Fields (I).Tag));
            end if;
         end loop;
         return Size;
      end Struct_Size_Bytes;

      function Align_Up
        (Value     : Natural;
         Alignment : Natural) return Natural is
      begin
         if Alignment <= 1 then
            return Value;
         elsif Value mod Alignment = 0 then
            return Value;
         else
            return Value + (Alignment - (Value mod Alignment));
         end if;
      end Align_Up;

      function Symbol_Size_Bytes (Sym_Idx : Natural) return Natural is
         Total : Natural := 1;
      begin
         if Sym_Idx = 0 then
            return 0;
         end if;

         case Symbols (Sym_Idx).Kind is
            when Sym_Array =>
               for D in 1 .. Natural'Max (1, Symbols (Sym_Idx).Rank) loop
                  Total :=
                    Total *
                    Natural'Max
                      (1,
                       (if Symbols (Sym_Idx).Dims (D) = 0
                        then 1
                        else Symbols (Sym_Idx).Dims (D)));
               end loop;
               return Total * Natural'Max (1, Symbol_Element_Size_Bytes (Sym_Idx));

            when Sym_Temporal =>
               return Natural'Max (1, Symbol_Element_Size_Bytes (Sym_Idx));

            when others =>
               return Natural'Max (1, Symbol_Element_Size_Bytes (Sym_Idx));
         end case;
      end Symbol_Size_Bytes;

      function Total_Array_Element_Count (Sym_Idx : Natural) return Natural is
         Total : Natural := 1;
      begin
         if Sym_Idx = 0 or else not Symbols (Sym_Idx).Active then
            return 1;
         end if;

         for D in 1 .. Natural'Max (1, Symbols (Sym_Idx).Rank) loop
            Total :=
              Total *
              Natural'Max
                (1,
                 (if Symbols (Sym_Idx).Dims (D) = 0
                  then 1
                  else Symbols (Sym_Idx).Dims (D)));
         end loop;

         return Natural'Max (1, Total);
      end Total_Array_Element_Count;

      function Supports_VAS_View
        (Tag             : ALB_Type_Tag;
         Struct_Name_Len : Natural := 0) return Boolean is
      begin
         if Struct_Name_Len > 0 then
            return True;
         end if;

         return Tag not in Type_F32x2 | Type_F32x4 | Type_Mat2x2 |
                           Type_Mat3x3 | Type_Mat4x4;
      end Supports_VAS_View;

      function Symbol_Is_Static_Addressable (Sym_Idx : Natural) return Boolean is
      begin
         return
           Sym_Idx > 0
           and then Symbols (Sym_Idx).Active
           and then Symbols (Sym_Idx).Scope_Name_Len = 0
           and then Symbols (Sym_Idx).Kind in Sym_Scalar | Sym_Array | Sym_Temporal
           and then Supports_VAS_View
             (Symbols (Sym_Idx).Tag, Symbols (Sym_Idx).Struct_Name_Len);
      end Symbol_Is_Static_Addressable;

      procedure Assign_Static_VAS_Offsets is
         Size_Bytes : Natural := 0;
         Align_Bytes : Natural := 1;
      begin
         Next_Static_VAS_Offset := ALB_VAS_Global_Base;
         for I in 1 .. Symbol_Count loop
            if Symbol_Is_Static_Addressable (I) then
               Size_Bytes := Symbol_Size_Bytes (I);
               Align_Bytes :=
                 Natural'Min
                   (8,
                    Natural'Max (1, Type_Size_Bytes (Symbols (I).Tag)));
               if Symbols (I).Struct_Name_Len > 0 then
                  Align_Bytes := 8;
               end if;
               Symbols (I).VAS_Offset :=
                 Align_Up (Next_Static_VAS_Offset, Align_Bytes);
               Next_Static_VAS_Offset :=
                 Symbols (I).VAS_Offset + Natural'Max (1, Size_Bytes);
            end if;
         end loop;
      end Assign_Static_VAS_Offsets;

      function Struct_Name_Of_Node
        (Idx         : Node_Index;
         Module_Name : String := "") return String is
         Sym_Idx : Natural := 0;
      begin
         if Idx = 0 then
            return "";
         end if;

         case Tree (Idx).Kind is
            when AST_Var_Expr | AST_Logic_Var =>
               for I in 1 .. Current_Param_Count loop
                  if Current_Params (I).Active
                    and then Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len) =
                      Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index))
                  then
                     return Name_Text
                       (Current_Params (I).Struct_Name,
                        Current_Params (I).Struct_Name_Len);
                  end if;
               end loop;

               Sym_Idx :=
                 Find_Symbol
                   (Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name));
               if Sym_Idx > 0 then
                  return Name_Text
                    (Symbols (Sym_Idx).Struct_Name,
                     Symbols (Sym_Idx).Struct_Name_Len);
               end if;
               return "";

            when others =>
               return "";
         end case;
      end Struct_Name_Of_Node;

      function Resolve_Name
        (Raw_Name     : String;
         Module_Name  : String := "") return String is
         Candidate : constant String := Qualify_Name (Module_Name, Raw_Name);
         Local_Candidate : constant String :=
           (if Current_Routine_Scope_Len > 0
            then Qualify_Local_Name
                   (Module_Name,
                    Name_Text (Current_Routine_Scope, Current_Routine_Scope_Len),
                    Raw_Name)
            else "");
         Safe_Raw  : constant String := Safe_Name (Raw_Name);
      begin
         for I in 1 .. Current_Param_Count loop
            if Current_Params (I).Active
              and then Current_Params (I).Name_Len = Safe_Raw'Length
              and then Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len) = Safe_Raw
            then
               if Contract_Use_Formal_Names then
                  return
                    Name_Text
                      (Current_Params (I).Formal_Name,
                       Current_Params (I).Formal_Name_Len);
               end if;
               return Safe_Raw;
            end if;
         end loop;

         if Local_Candidate'Length > 0 and then Find_Symbol (Local_Candidate) > 0 then
            return Local_Candidate;
         elsif Find_Symbol (Candidate) > 0 then
            return Candidate;
         elsif Find_Symbol (Safe_Raw) > 0 then
            return Safe_Raw;
         else
            return Candidate;
         end if;
      end Resolve_Name;

      function Tree_Assigns_Target
        (Idx         : Node_Index;
         Target_Name : String;
         Module_Name : String) return Boolean is
      begin
         if Idx = 0 then
            return False;
         end if;

         if Tree (Idx).Kind = AST_Let_Stmt
           and then Tree (Idx).Left_Child /= 0
           and then Tree (Tree (Idx).Left_Child).Kind = AST_Var_Expr
         then
            if Resolve_Name
                 (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                  Module_Name) = Target_Name
            then
               return True;
            end if;
         end if;

         return Tree_Assigns_Target (Tree (Idx).Left_Child, Target_Name, Module_Name)
           or else Tree_Assigns_Target (Tree (Idx).Right_Child, Target_Name, Module_Name)
           or else Tree_Assigns_Target (Tree (Idx).Next_Sibling, Target_Name, Module_Name);
      end Tree_Assigns_Target;

      function Resolve_Parallel_Group_Name
        (Raw_Name     : String;
         Module_Name  : String := "") return String is
         Candidate : constant String := Qualify_Name (Module_Name, Raw_Name);
         Local_Candidate : constant String :=
           (if Current_Routine_Scope_Len > 0
            then Qualify_Local_Name
                   (Module_Name,
                    Name_Text (Current_Routine_Scope, Current_Routine_Scope_Len),
                    Raw_Name)
            else "");
         Safe_Raw : constant String := Safe_Name (Raw_Name);
      begin
         if Local_Candidate'Length > 0 and then Has_Parallel_Group (Local_Candidate) then
            return Local_Candidate;
         elsif Has_Parallel_Group (Candidate) then
            return Candidate;
         elsif Has_Parallel_Group (Safe_Raw) then
            return Safe_Raw;
         else
            return Resolve_Name (Raw_Name, Module_Name);
         end if;
      end Resolve_Parallel_Group_Name;

      function Is_Var_Like_Node (Idx : Node_Index) return Boolean is
      begin
         return
           Idx /= 0
           and then (Tree (Idx).Kind = AST_Var_Expr or else Tree (Idx).Kind = AST_Null)
           and then Tree (Idx).Token_Index > 0;
      end Is_Var_Like_Node;

      function Current_Param_Index (Raw_Name : String) return Natural is
         Safe_Raw : constant String := Safe_Name (Raw_Name);
      begin
         for I in 1 .. Current_Param_Count loop
            if Current_Params (I).Active
              and then Current_Params (I).Name_Len = Safe_Raw'Length
              and then Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len) = Safe_Raw
            then
               return I;
            end if;
         end loop;
         return 0;
      end Current_Param_Index;

      function Predicate_Name_Of (Idx : Node_Index) return String is
      begin
         if Idx = 0 then
            return "";
         end if;

         case Tree (Idx).Kind is
            when AST_Assert_Stmt | AST_Retract_Stmt =>
               if Tree (Idx).Token_Index > 0 then
                  return Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index));
               end if;

            when AST_Query | AST_Findall_Query | AST_Knows_Query | AST_Find_Query =>
               return Predicate_Name_Of (Tree (Idx).Left_Child);

            when AST_Predicate | AST_Atom | AST_Var_Expr | AST_Logic_Var =>
               if Tree (Idx).Token_Index > 0 then
                  return Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index));
               end if;

            when AST_Func_Call =>
               if Tree (Idx).Left_Child /= 0 then
                  return Predicate_Name_Of (Tree (Idx).Left_Child);
               end if;

            when others =>
               null;
         end case;

         return "";
      end Predicate_Name_Of;

      function Predicate_Arg_Node (Idx : Node_Index) return Node_Index is
         Arg_List : Node_Index := 0;
      begin
         if Idx = 0 then
            return 0;
         end if;

         case Tree (Idx).Kind is
            when AST_Assert_Stmt | AST_Retract_Stmt =>
               return Tree (Idx).Left_Child;

            when AST_Query | AST_Findall_Query | AST_Knows_Query | AST_Find_Query =>
               return Predicate_Arg_Node (Tree (Idx).Left_Child);

            when AST_Predicate =>
               return Tree (Idx).Left_Child;

            when AST_Func_Call =>
               Arg_List := Tree (Idx).Right_Child;
               if Arg_List /= 0 and then Tree (Arg_List).Kind = AST_Arg_List then
                  return Tree (Arg_List).Left_Child;
               end if;
               return Arg_List;

            when others =>
               return 0;
         end case;
      end Predicate_Arg_Node;

      function Next_Continue_Label return String is
      begin
         Next_Loop_Label_Id := Next_Loop_Label_Id + 1;
         return "ALBA_CONTINUE_" & Trim_Image (Integer (Next_Loop_Label_Id));
      end Next_Continue_Label;

      procedure Push_Continue_Label (Label_Name : String) is
      begin
         if Loop_Depth < Max_Loop_Depth then
            Loop_Depth := Loop_Depth + 1;
            Loop_Continue_Label_Lens (Loop_Depth) := Label_Name'Length;
            Loop_Continue_Labels (Loop_Depth) := Copy_Name (Label_Name);
         end if;
      end Push_Continue_Label;

      procedure Pop_Continue_Label is
      begin
         if Loop_Depth > 0 then
            Loop_Continue_Label_Lens (Loop_Depth) := 0;
            Loop_Continue_Labels (Loop_Depth) := (others => ' ');
            Loop_Depth := Loop_Depth - 1;
         end if;
      end Pop_Continue_Label;

      function Current_Continue_Label return String is
      begin
         if Loop_Depth = 0 or else Loop_Continue_Label_Lens (Loop_Depth) = 0 then
            return "";
         end if;
         return
           Name_Text
             (Loop_Continue_Labels (Loop_Depth),
              Loop_Continue_Label_Lens (Loop_Depth));
      end Current_Continue_Label;

      procedure Register_Knows_Hook
        (Predicate_Name : String;
         Handler_Name   : String;
         Param_Name     : String;
         Node           : Node_Index) is
      begin
         if Predicate_Name'Length = 0
           or else Handler_Name'Length = 0
           or else Knows_Hook_Count >= Max_Knows_Hooks
         then
            return;
         end if;

         Knows_Hook_Count := Knows_Hook_Count + 1;
         Knows_Hooks (Knows_Hook_Count).Active := True;
         Knows_Hooks (Knows_Hook_Count).Predicate_Name_Len := Predicate_Name'Length;
         Knows_Hooks (Knows_Hook_Count).Predicate_Name := Copy_Name (Predicate_Name);
         Knows_Hooks (Knows_Hook_Count).Handler_Name_Len := Handler_Name'Length;
         Knows_Hooks (Knows_Hook_Count).Handler_Name := Copy_Name (Handler_Name);
         Knows_Hooks (Knows_Hook_Count).Param_Name_Len := Param_Name'Length;
         Knows_Hooks (Knows_Hook_Count).Param_Name := Copy_Name (Param_Name);
         Knows_Hooks (Knows_Hook_Count).Node := Node;
      end Register_Knows_Hook;

      function Infer_Type (Idx : Node_Index; Module_Name : String := "") return ALB_Type_Tag;

      function Is_Signed_Integer_Tag (Tag : ALB_Type_Tag) return Boolean is
      begin
         return Tag in Type_S8 | Type_S16 | Type_S32 | Type_S64 |
           Type_HW8 | Type_HW16 | Type_HW32 | Type_HW64;
      end Is_Signed_Integer_Tag;

      function Promote_Numeric_Tag
        (Left_Tag  : ALB_Type_Tag;
         Right_Tag : ALB_Type_Tag) return ALB_Type_Tag is
      begin
         if Left_Tag = Type_Pure or else Right_Tag = Type_Pure then
            return Type_Pure;
         elsif Left_Tag in Type_F32 | Type_F64 | Type_F128
           or else Right_Tag in Type_F32 | Type_F64 | Type_F128
         then
            return Type_F64;
         elsif Left_Tag = Type_S64 or else Right_Tag = Type_S64
           or else ((Left_Tag = Type_U64 or else Right_Tag = Type_U64)
                    and then (Is_Signed_Integer_Tag (Left_Tag)
                              or else Is_Signed_Integer_Tag (Right_Tag)))
         then
            return Type_S64;
         elsif Is_Signed_Integer_Tag (Left_Tag)
           or else Is_Signed_Integer_Tag (Right_Tag)
         then
            return Type_S32;
         elsif Left_Tag = Type_U64 or else Right_Tag = Type_U64 then
            return Type_U64;
         elsif Left_Tag = Type_U32 or else Right_Tag = Type_U32 then
            return Type_U32;
         elsif Left_Tag = Type_U16 or else Right_Tag = Type_U16 then
            return Type_U16;
         elsif Left_Tag = Type_U8 or else Right_Tag = Type_U8 then
            return Type_U8;
         else
            return Left_Tag;
         end if;
      end Promote_Numeric_Tag;

      function Infer_Type (Idx : Node_Index; Module_Name : String := "") return ALB_Type_Tag is
         function Is_Real_Number_Text (Value : String) return Boolean is
         begin
            for Ch of Value loop
               if Ch = '.' or else Ch = 'e' or else Ch = 'E' then
                  return True;
               end if;
            end loop;
            return False;
         end Is_Real_Number_Text;

         Tok : Token;
         Name_Node : Node_Index := 0;
         Field_Idx : Natural := 0;
         Sym_Idx   : Natural := 0;
         Left_Tag  : ALB_Type_Tag := Type_None;
         Right_Tag : ALB_Type_Tag := Type_None;
      begin
         if Idx = 0 then
            return Type_None;
         end if;

         case Tree (Idx).Kind is
            when AST_Number_Expr =>
               if Is_Real_Number_Text (Raw_Lexeme (Tree (Idx).Token_Index)) then
                  return Type_F64;
               end if;
               return Type_S32;
            when AST_Not =>
               -- Logical NOT always yields Boolean; emission uses Ada "not".
               return Type_Boolean;
            when AST_Unary_Minus =>
               Left_Tag := Infer_Type (Tree (Idx).Left_Child, Module_Name);
               if Left_Tag in Type_F32 | Type_F64 | Type_F128 then
                  return Type_F64;
               end if;
               return Type_S32;
            when AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
               return Type_S32;
            when AST_String_Expr =>
               return Type_Binary;
            when AST_True | AST_False =>
               return Type_Boolean;
            when AST_Const_Ref =>
               declare
                  Const_Node : constant Node_Index :=
                    Find_Const_Expr (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
                  Static_Value : S64 := 0;
                  Static_Found : Boolean := False;
               begin
                  if Const_Node /= 0 then
                     return Infer_Type (Const_Node, Module_Name);
                  end if;
                  Lookup_Const_Static_Value
                    (Raw_Lexeme (Tree (Idx).Token_Index),
                     Module_Name,
                     "",
                     Static_Value,
                     Static_Found);
                  if Static_Found then
                     return Type_S32;
                  end if;
                  return Type_S32;
               end;
            when AST_Var_Expr | AST_Logic_Var =>
               for I in 1 .. Current_Param_Count loop
                  if Current_Params (I).Active
                    and then Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len) =
                      Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index))
                  then
                     return Current_Params (I).Tag;
                  end if;
               end loop;
               Sym_Idx := Find_Symbol (Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name));
               if Sym_Idx > 0 then
                  return Symbols (Sym_Idx).Tag;
               end if;
               declare
                  Const_Node : constant Node_Index :=
                    Find_Const_Expr (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
                  Static_Value : S64 := 0;
                  Static_Found : Boolean := False;
               begin
                  if Const_Node /= 0 then
                     return Infer_Type (Const_Node, Module_Name);
                  end if;
                  Lookup_Const_Static_Value
                    (Raw_Lexeme (Tree (Idx).Token_Index),
                     Module_Name,
                     "",
                     Static_Value,
                     Static_Found);
                  if Static_Found then
                     return Type_S32;
                  end if;
               end;
               return Type_U64;
            when AST_Member_Expr =>
               if Is_Var_Like_Node (Tree (Idx).Left_Child) then
                  Field_Idx := Find_Parallel_Field
                    (Resolve_Parallel_Group_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index), Module_Name),
                     Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                  if Field_Idx > 0 then
                     return Parallel_Fields (Field_Idx).Tag;
                  end if;
               end if;
               declare
                  Struct_Name : constant String :=
                    Struct_Name_Of_Node (Tree (Idx).Left_Child, Module_Name);
               begin
                  if Struct_Name'Length > 0 then
                     Field_Idx :=
                       Find_Struct_Field
                         (Struct_Name,
                          Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                     if Field_Idx > 0 then
                        return Struct_Fields (Field_Idx).Tag;
                     end if;
                  end if;
               end;
               return Type_S32;
            when AST_Cast_Expr =>
               return Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
            when AST_Constructor =>
               if Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index)) = Type_Pure then
                  return Type_Pure;
               end if;
               return Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
            when AST_Temporal_Ref =>
               if Tree (Idx).Left_Child /= 0 then
                  if Tokens (Tree (Idx).Token_Index).Kind = Tok_Timeline then
                     return Type_U64;
                  end if;
                  return Infer_Type (Tree (Idx).Left_Child, Module_Name);
               end if;
               return Type_U64;
            when AST_Rnd_Expr =>
               return Type_U64;
            when AST_Choose =>
               if Tree (Idx).Right_Child /= 0 and then Tree (Tree (Idx).Right_Child).Left_Child /= 0 then
                  return Infer_Type (Tree (Tree (Idx).Right_Child).Left_Child, Module_Name);
               end if;
               return Type_U64;
            when AST_Peek_Expr | AST_Deref_Expr | AST_AddressOf | AST_Ref_Expr =>
               return Type_U64;
            when AST_Inline_Ada_Expr =>
               return Type_U64;
            when AST_Key_State | AST_Mouse_Click | AST_READ_PIXEL =>
               return Type_U32;
            when AST_Mouse_X | AST_Mouse_Y | AST_Mouse_Wheel | AST_VMouse_X | AST_VMouse_y |
                 AST_SCREEN_WIDTH | AST_SCREEN_HEIGHT | AST_VIRTUAL_WIDTH | AST_VIRTUAL_HEIGHT =>
               return Type_S32;
            when AST_Str_Len =>
               return Type_U32;
            when AST_Str_Left | AST_Str_Right | AST_Str_Mid | AST_Str_Concat =>
               return Type_Binary;
            when AST_File_Open | AST_File_Len | AST_File_Seek =>
               return Type_U64;
            when AST_File_Read =>
               return Type_Binary;
            when AST_SizeOf_Expr | AST_OffsetOf_Expr =>
               return Type_U32;
            when AST_TypeOf_Expr =>
               return Type_Binary;
            when AST_Knows_Query =>
               return Type_Boolean;
            when AST_Find_Query | AST_Query =>
               if Tree (Idx).Token_Index > 0
                 and then Tokens (Tree (Idx).Token_Index).Kind = Tok_Find
               then
                  return Type_U64;
               end if;
               return Type_Boolean;
            when AST_Func_Call =>
               Name_Node := Tree (Idx).Left_Child;
               if Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Var_Expr then
                  declare
                     Call_Name : constant String := Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
                  begin
                     if Call_Name = "LEN" then
                        return Type_U32;
                     elsif Call_Name = "PURE_NUM" or else Call_Name = "PURE_DEN" then
                        return Type_S32;
                     elsif Call_Name = "PURE_ADD" or else Call_Name = "PURE_SUB"
                       or else Call_Name = "PURE_MUL" or else Call_Name = "PURE_DIV"
                       or else Call_Name = "PURE_POW"
                     then
                        return Type_Pure;
                     elsif Call_Name = "OPEN" then
                        return Type_U64;
                     elsif Call_Name = "READ" or else Call_Name = "LEFT" or else
                       Call_Name = "RIGHT" or else Call_Name = "MID" or else
                       Call_Name = "CHR" or else
                       Call_Name = "CONCAT" or else Call_Name = "READLINE" then
                        return Type_Binary;
                     elsif Call_Name = "COLLIDE_RECT" or else Call_Name = "PROVE" then
                        return Type_Boolean;
                     elsif Call_Name = "SIN" or else Call_Name = "COS" or else
                       Call_Name = "SQRT" or else Call_Name = "EXP"
                     then
                        return Type_S32;
                     elsif Tag_From_Name (Call_Name) /= Type_None then
                        return Tag_From_Name (Call_Name);
                     elsif Call_Name = "HW8" then
                        return Type_S8;
                     elsif Call_Name = "HW16" then
                        return Type_S16;
                     elsif Call_Name = "HW32" then
                        return Type_S32;
                     elsif Call_Name = "RND" or else Call_Name = "CHOOSE" or else
                       Call_Name = "FIND" or else Call_Name = "SIZEOF" or else
                       Call_Name = "OFFSETOF" then
                        return Type_U64;
                     end if;
                  end;
               end if;
               declare
                  Return_Tag : constant ALB_Type_Tag :=
                    Resolve_Routine_Return_Tag (Name_Node, Module_Name);
               begin
                  if Return_Tag /= Type_None then
                     return Return_Tag;
                  end if;
               end;
               return Type_U64;
            when AST_BinOp =>
               Tok := Tokens (Tree (Idx).Token_Index);
               Left_Tag := Infer_Type (Tree (Idx).Left_Child, Module_Name);
               Right_Tag := Infer_Type (Tree (Idx).Right_Child, Module_Name);
               if Tok.Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL |
                              TOK_LESS | TOK_GREATER | TOK_LESS_EQUAL | TOK_GREATER_EQUAL
               then
                  return Type_Boolean;
               elsif Tok.Kind in TOK_AND | TOK_OR | TOK_XOR then
                  if Left_Tag = Type_Boolean and then Right_Tag = Type_Boolean then
                     return Type_Boolean;
                  end if;
                  return Promote_Numeric_Tag (Left_Tag, Right_Tag);
               elsif Tok.Kind = TOK_PIPE then
                  return Type_Binary;
               else
                  return Promote_Numeric_Tag (Left_Tag, Right_Tag);
               end if;
            when others =>
               return Type_U64;
         end case;
      end Infer_Type;

      function Create_Window_Width_Node (Idx : Node_Index) return Node_Index;
      function Create_Window_Height_Node (Idx : Node_Index) return Node_Index;
      procedure Scan_Expr_Features (Idx : Node_Index);
      procedure Scan_Node
        (Idx         : Node_Index;
         Module_Name : String := "";
         Routine_Name : String := "");

      procedure Scan_Parallel_Decl_Node
        (Idx          : Node_Index;
         Module_Name  : String;
         Routine_Name : String) is
         Curr      : Node_Index := 0;
         Dims      : Dim_Array := (others => 0);
         Name_Node : Node_Index := Tree (Idx).Left_Child;
      begin
         if Name_Node /= 0 then
            declare
               Group_Name : constant String :=
                 Registration_Name
                   (Raw_Lexeme (Tree (Name_Node).Token_Index),
                    Module_Name,
                    Routine_Name);
            begin
               Dims := (others => 0);
               Dims (1) :=
                 Try_Parse_Natural
                   (Tree (Name_Node).Left_Child,
                    1,
                    Module_Name,
                    Routine_Name);
               Curr := Tree (Idx).Right_Child;
               for Guard in 1 .. Max_Nodes loop
                  exit when Curr = 0;
                  if Tree (Curr).Kind = AST_Parallel_Field
                    and then Tree (Curr).Left_Child /= 0
                  then
                     Parallel_Count := Parallel_Count + 1;
                     Parallel_Fields (Parallel_Count).Active := True;
                     Parallel_Fields (Parallel_Count).Group_Name_Len :=
                       Group_Name'Length;
                     Parallel_Fields (Parallel_Count).Group_Name :=
                       Copy_Name (Group_Name);
                     Parallel_Fields (Parallel_Count).Field_Name_Len :=
                       Safe_Name_Length
                         (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                     Parallel_Fields (Parallel_Count).Field_Name :=
                       Copy_Name
                         (Safe_Name
                            (Raw_Lexeme
                               (Tree (Tree (Curr).Left_Child).Token_Index)));
                     Parallel_Fields (Parallel_Count).Tag :=
                       (if Tree (Tree (Curr).Left_Child).Right_Child /= 0
                        then Tag_From_Name
                          (Raw_Lexeme
                             (Tree
                                (Tree (Tree (Curr).Left_Child).Right_Child)
                                .Token_Index))
                        else Type_U64);
                     Parallel_Fields (Parallel_Count).Backing_Name_Len :=
                       Compose_Field_Backing_Name_Length
                         (Group_Name,
                          Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                     Parallel_Fields (Parallel_Count).Backing_Name :=
                       Copy_Name
                         (Compose_Field_Backing_Name
                            (Group_Name,
                             Raw_Lexeme
                               (Tree (Tree (Curr).Left_Child).Token_Index)));
                     Parallel_Fields (Parallel_Count).Capacity := Dims (1);
                     Register_Symbol
                       (Name_Text
                          (Parallel_Fields (Parallel_Count).Backing_Name,
                           Parallel_Fields (Parallel_Count).Backing_Name_Len),
                        Safe_Name
                          (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index)),
                        Module_Name,
                        Routine_Name,
                        Parallel_Fields (Parallel_Count).Tag,
                        Sym_Array,
                        1,
                        Dims);
                  end if;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            end;
         end if;
      end Scan_Parallel_Decl_Node;

      procedure Scan_Struct_Decl_Node
        (Idx : Node_Index) is
      begin
         if Tree (Idx).Left_Child /= 0 then
            declare
               Struct_Name  : constant String :=
                 Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
               Offset_Bytes : Natural := 0;
               Work         : Field_Work_Array := (others => 0);
               Work_Top     : Natural := 0;

               procedure Push_Field_Node (Node : Node_Index) is
               begin
                  if Node = 0 then
                     return;
                  end if;

                  pragma Assert (Work_Top < Work'Last);
                  if Work_Top >= Work'Last then
                     return;
                  end if;

                  Work_Top := Work_Top + 1;
                  Work (Work_Top) := Node;
               end Push_Field_Node;

               procedure Register_Field_Node (Node : Node_Index) is
                  Field_Name_Node : Node_Index := 0;
               begin
                  if Tree (Node).Kind = AST_Bitfield_Decl
                    and then Tree (Node).Left_Child /= 0
                  then
                     Field_Name_Node := Tree (Node).Left_Child;
                     if Tree (Field_Name_Node).Kind /= AST_Var_Expr then
                        return;
                     end if;
                     Struct_Count := Struct_Count + 1;
                     Struct_Fields (Struct_Count).Active := True;
                     Struct_Fields (Struct_Count).Struct_Name_Len :=
                       Struct_Name'Length;
                     Struct_Fields (Struct_Count).Struct_Name :=
                       Copy_Name (Struct_Name);
                     Struct_Fields (Struct_Count).Field_Name_Len :=
                       Safe_Name_Length
                         (Raw_Lexeme (Tree (Field_Name_Node).Token_Index));
                     Struct_Fields (Struct_Count).Field_Name :=
                       Copy_Name
                         (Safe_Name
                            (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)));
                     Struct_Fields (Struct_Count).Tag := Type_U64;
                     Struct_Fields (Struct_Count).Offset_Bytes := Offset_Bytes;
                     Offset_Bytes :=
                       Offset_Bytes +
                       Type_Size_Bytes (Struct_Fields (Struct_Count).Tag);
                  elsif Tree (Node).Kind in AST_Struct_Field | AST_Null
                    and then Tree (Node).Left_Child /= 0
                    and then Tree (Tree (Node).Left_Child).Kind = AST_Var_Expr
                  then
                     Struct_Count := Struct_Count + 1;
                     Struct_Fields (Struct_Count).Active := True;
                     Struct_Fields (Struct_Count).Struct_Name_Len :=
                       Struct_Name'Length;
                     Struct_Fields (Struct_Count).Struct_Name :=
                       Copy_Name (Struct_Name);
                     Struct_Fields (Struct_Count).Field_Name_Len :=
                       Safe_Name_Length
                         (Raw_Lexeme (Tree (Tree (Node).Left_Child).Token_Index));
                     Struct_Fields (Struct_Count).Field_Name :=
                       Copy_Name
                         (Safe_Name
                            (Raw_Lexeme (Tree (Tree (Node).Left_Child).Token_Index)));
                     Struct_Fields (Struct_Count).Tag :=
                       (if Tree (Node).Kind = AST_Struct_Field
                           and then Tree (Tree (Node).Left_Child).Right_Child /= 0
                        then Tag_From_Name
                          (Raw_Lexeme
                             (Tree
                                (Tree (Tree (Node).Left_Child).Right_Child)
                                .Token_Index))
                        elsif Tree (Node).Kind = AST_Null
                          and then Tree (Node).Token_Index > 0
                        then Tag_From_Name (Raw_Lexeme (Tree (Node).Token_Index))
                        else Type_U64);
                     Struct_Fields (Struct_Count).Offset_Bytes := Offset_Bytes;
                     Offset_Bytes :=
                       Offset_Bytes +
                       Type_Size_Bytes (Struct_Fields (Struct_Count).Tag);
                  end if;
               end Register_Field_Node;
            begin
               Push_Field_Node (Tree (Idx).Right_Child);

               for Guard in 1 .. Max_Field_Work loop
                  exit when Work_Top = 0;
                  declare
                     Current_Node : constant Node_Index := Work (Work_Top);
                     Is_Field_Node : constant Boolean :=
                       Current_Node /= 0
                       and then
                         (Tree (Current_Node).Kind = AST_Bitfield_Decl
                          or else
                            (Tree (Current_Node).Kind in AST_Struct_Field | AST_Null
                             and then Tree (Current_Node).Left_Child /= 0
                             and then
                               Tree (Tree (Current_Node).Left_Child).Kind =
                                 AST_Var_Expr));
                  begin
                     Work_Top := Work_Top - 1;
                     if Current_Node /= 0 then
                        if Is_Field_Node then
                           Register_Field_Node (Current_Node);
                           Push_Field_Node (Tree (Current_Node).Next_Sibling);
                        else
                           Push_Field_Node (Tree (Current_Node).Next_Sibling);
                           Push_Field_Node (Tree (Current_Node).Right_Child);
                           Push_Field_Node (Tree (Current_Node).Left_Child);
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end if;
      end Scan_Struct_Decl_Node;

      procedure Scan_On_Block_Node
        (Idx          : Node_Index;
         Module_Name  : String;
         Routine_Name : String) is
         Curr : Node_Index := Tree (Idx).Left_Child;
      begin
         if Tree (Idx).Token_Index > 0 then
            case Tokens (Tree (Idx).Token_Index).Kind is
               when TOK_TICK  => On_Tick_Node := Tree (Idx).Left_Child;
               when TOK_PAINT => On_Paint_Node := Tree (Idx).Left_Child;
               when TOK_KEY   => On_Key_Node := Tree (Idx).Left_Child;
               when others    => null;
            end case;
         end if;

         if Curr = 0 then
            return;
         end if;

         if Tree (Idx).Token_Index > 0
           and then Tokens (Tree (Idx).Token_Index).Kind = TOK_TICK
         then
            for Guard in 1 .. Max_Nodes loop
               exit when Curr = 0;
               Scan_Node (Curr, Module_Name, "ALB_On_Tick");
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         elsif Tree (Idx).Token_Index > 0
           and then Tokens (Tree (Idx).Token_Index).Kind = TOK_PAINT
         then
            for Guard in 1 .. Max_Nodes loop
               exit when Curr = 0;
               Scan_Node (Curr, Module_Name, "ALB_On_Paint");
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         elsif Tree (Idx).Token_Index > 0
           and then Tokens (Tree (Idx).Token_Index).Kind = TOK_KEY
         then
            for Guard in 1 .. Max_Nodes loop
               exit when Curr = 0;
               Scan_Node (Curr, Module_Name, "ALB_On_Key");
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         else
            for Guard in 1 .. Max_Nodes loop
               exit when Curr = 0;
               Scan_Node (Curr, Module_Name, Routine_Name);
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         end if;
      end Scan_On_Block_Node;

      procedure Scan_Node
        (Idx         : Node_Index;
         Module_Name : String := "";
         Routine_Name : String := "") is
         Dims : Dim_Array := (others => 0);
         Rank : Natural := 0;
         Elem : Node_Index := 0;
         Tag  : ALB_Type_Tag := Type_None;
         History : Natural := 0;

         procedure Scan_Sibling_List
           (First_Node          : Node_Index;
            Effective_Module    : String := Module_Name;
            Effective_Routine   : String := Routine_Name)
         is
            Sibling : Node_Index := First_Node;
         begin
            for Guard in 1 .. Max_Nodes loop
               exit when Sibling = 0;
               Scan_Node (Sibling, Effective_Module, Effective_Routine);
               Sibling := Tree (Sibling).Next_Sibling;
            end loop;
         end Scan_Sibling_List;

         procedure Read_Bounded_Dimensions
           (First_Node        : Node_Index;
            Effective_Module  : String;
            Effective_Routine : String;
            Out_Rank          : out Natural;
            Out_Dims          : out Dim_Array)
         is
            Bound : Node_Index := First_Node;
         begin
            Out_Rank := 0;
            Out_Dims := (others => 0);

            for Guard in 1 .. 4 loop
               exit when Bound = 0;
               Out_Rank := Out_Rank + 1;
               Out_Dims (Out_Rank) :=
                 Try_Parse_Natural (Bound, 1, Effective_Module, Effective_Routine);
               Bound := Tree (Bound).Next_Sibling;
            end loop;
         end Read_Bounded_Dimensions;
      begin
         if Idx = 0 then
            return;
         end if;

         case Tree (Idx).Kind is
           when AST_Program | AST_Block_Stmt =>
               Scan_Sibling_List (Tree (Idx).Left_Child);

            when AST_Module =>
               if Tree (Idx).Left_Child /= 0 then
                  Register_Module (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
                  Scan_Node
                    (Tree (Idx).Right_Child,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                     "");
               end if;

            when AST_DeclareModule =>
               if Tree (Idx).Left_Child /= 0 then
                  Register_Module (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
               end if;

            when AST_Import_C | AST_Import_DLL =>
               null;

            when AST_Memory_Firewall_Decl =>
               Register_Firewall_Decl (Idx);

            when AST_Markov_Model_Decl =>
               Need_Markov_Runtime := True;
               Record_Critical_Violation ("MARKOV");

            when AST_Neural_Topology_Decl =>
               Need_NN_Runtime := True;
               Record_Critical_Violation ("NEURAL");

            when AST_Network_Socket_Decl =>
               if Tree (Idx).Left_Child /= 0 then
                  declare
                     Emit_Name : constant String :=
                       Registration_Name
                         (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                          Module_Name,
                          Routine_Name);
                  begin
                     Register_Symbol
                       (Emit_Name,
                        Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                        Module_Name,
                        Routine_Name,
                        Type_U64);
                     Register_Network_Socket (Emit_Name, Idx);
                  end;
               end if;

            when AST_Procedure_Decl | AST_Function_Decl =>
               Register_Routine (Idx, Module_Name);
               if Tree (Idx).Right_Child /= 0 then
                  Scan_Node
                    (Tree (Idx).Right_Child,
                     Module_Name,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)));
               end if;

            when AST_Let_Stmt =>
               if Tree (Idx).Left_Child /= 0
                 and then not
                   (Tree (Idx).Right_Child = 0
                    and then Tree (Idx).Token_Index > 0
                    and then Tokens (Tree (Idx).Token_Index).Kind = Tok_U0)
               then
                  if Tree (Tree (Idx).Left_Child).Kind = AST_Var_Expr then
                     declare
                        Raw_Target    : constant String :=
                          Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index);
                        Emit_Name     : constant String :=
                          Registration_Name
                            (Raw_Target,
                             Module_Name,
                             Routine_Name);
                        Is_Parallel_Target : constant Boolean :=
                          Has_Parallel_Group (Resolve_Parallel_Group_Name (Raw_Target, Module_Name));
                        Explicit_Type : constant String := Raw_Lexeme (Tree (Idx).Token_Index);
                        Struct_Name   : constant String :=
                          (if Tag_From_Name (Explicit_Type) = Type_None
                              and then Is_Struct_Name (Explicit_Type)
                           then Safe_Name (Explicit_Type)
                           else "");
                        Kind          : Symbol_Kind := Sym_Scalar;
                        Rank          : Natural := 0;
                        Dims          : Dim_Array := (others => 0);
                        Alias_Idx     : Natural := 0;
                     begin
                        if Is_Parallel_Target then
                           null;
                        else
                        if Explicit_Type'Length > 0 then
                           Alias_Idx := Find_Alias (Upper_Safe_Name (Explicit_Type));
                        end if;
                        Tag := Tag_From_Name (Explicit_Type);
                        if Tag = Type_None then
                           Tag := Infer_Type (Tree (Idx).Right_Child, Module_Name);
                        end if;
                        if Tag = Type_None and then Struct_Name'Length = 0 then
                           Tag := Type_U64;
                        end if;
                        if Tree (Tree (Idx).Left_Child).Left_Child /= 0 then
                           Kind := Sym_Array;
                           Read_Bounded_Dimensions
                             (Tree (Tree (Idx).Left_Child).Left_Child,
                              Module_Name,
                              Routine_Name,
                              Rank,
                              Dims);
                        end if;
                        Register_Symbol
                           (Emit_Name,
                            Safe_Name (Raw_Target),
                            Module_Name,
                            Routine_Name,
                            Tag,
                            Kind,
                            Rank,
                            Dims,
                            Struct_Name => Struct_Name,
                            Alias_Idx   => Alias_Idx);
                        end if;
                     end;
                  end if;
               end if;
               Scan_Expr_Features (Tree (Idx).Right_Child);

            when AST_Foreach_Stmt =>
               declare
                  Iter_Name : constant String :=
                    Registration_Name
                      (Raw_Lexeme (Tree (Idx).Token_Index),
                       Module_Name,
                       Routine_Name);
                  Source_Sym : Natural := 0;
                  Elem_Tag   : ALB_Type_Tag := Type_U64;
               begin
                  if Tree (Idx).Left_Child /= 0
                    and then Tree (Tree (Idx).Left_Child).Kind = AST_Var_Expr
                  then
                     Source_Sym :=
                       Find_Symbol
                         (Resolve_Name
                            (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                             Module_Name));
                     if Source_Sym > 0 then
                        Elem_Tag := Symbols (Source_Sym).Tag;
                     end if;
                  end if;
                  Register_Symbol
                    (Iter_Name,
                     Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index)),
                     Module_Name,
                     Routine_Name,
                     Elem_Tag);
               end;

            when AST_For_Stmt =>
               -- Implicit FOR iterators must be locals (FOR slot = 1 TO N).
               if Tree (Idx).Token_Index > 0 then
                  declare
                     Iter_Raw  : constant String :=
                       Raw_Lexeme (Tree (Idx).Token_Index);
                     Iter_Name : constant String :=
                       Registration_Name (Iter_Raw, Module_Name, Routine_Name);
                  begin
                     Register_Symbol
                       (Iter_Name,
                        Safe_Name (Iter_Raw),
                        Module_Name,
                        Routine_Name,
                        Type_S32);
                  end;
               end if;
               Scan_Sibling_List (Tree (Idx).Left_Child);
               Scan_Sibling_List (Tree (Idx).Right_Child);

            when AST_Enum_Decl =>
               declare
                  Enum_Curr  : Node_Index := Tree (Idx).Left_Child;
                  Enum_Value : S64 := 0;
               begin
                  while Enum_Curr /= 0 loop
                     if Tree (Enum_Curr).Token_Index > 0 then
                        Register_Const
                          (Raw_Lexeme (Tree (Enum_Curr).Token_Index),
                           Module_Name,
                           Routine_Name,
                           0,
                           Enum_Value,
                           True);
                        Enum_Value := Enum_Value + 1;
                     end if;
                     Enum_Curr := Tree (Enum_Curr).Next_Sibling;
                  end loop;
               end;

            when AST_Strict_Stmt | AST_Slide_Stmt =>
               if Tree (Idx).Left_Child /= 0 then
                  declare
                     Emit_Name : constant String :=
                       Registration_Name
                         (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                          Module_Name,
                          Routine_Name);
                  begin
                     if Tree (Tree (Idx).Left_Child).Right_Child /= 0 then
                        Tag := Tag_From_Name (Raw_Lexeme (Tree (Tree (Tree (Idx).Left_Child).Right_Child).Token_Index));
                     else
                        Tag := Type_U64;
                     end if;
                     Elem := Tree (Idx).Right_Child;
                     Rank := 0;
                     Dims := (others => 0);
                     if Tree (Idx).Kind = AST_Slide_Stmt then
                        Rank := 1;
                        Dims (1) := Try_Parse_Natural (Elem, 1, Module_Name, Routine_Name);
                     else
                        Read_Bounded_Dimensions
                          (Elem,
                           Module_Name,
                           Routine_Name,
                           Rank,
                           Dims);
                     end if;
                     Register_Symbol
                       (Emit_Name,
                        Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                        Module_Name,
                        Routine_Name,
                        Tag,
                        Sym_Array,
                        Rank,
                        Dims);
                  end;
               end if;

            when AST_Parallel_Decl =>
               Scan_Parallel_Decl_Node (Idx, Module_Name, Routine_Name);

            when AST_Struct_Decl =>
               Scan_Struct_Decl_Node (Idx);

            when AST_Range_Type_Decl =>
               if Tree (Idx).Left_Child /= 0 and then Tree (Idx).Right_Child /= 0 then
                  declare
                     Base_Node : constant Node_Index := Tree (Idx).Right_Child;
                     Low_Node  : constant Node_Index := Tree (Base_Node).Left_Child;
                     High_Node : constant Node_Index := Tree (Low_Node).Next_Sibling;
                     Low_Res   : constant Static_S64_Result :=
                       Try_Eval_Static_S64 (Low_Node, Module_Name, Routine_Name);
                     High_Res  : constant Static_S64_Result :=
                       Try_Eval_Static_S64 (High_Node, Module_Name, Routine_Name);
                     Base_Tag  : constant ALB_Type_Tag :=
                       Tag_From_Name (Raw_Lexeme (Tree (Base_Node).Token_Index));
                  begin
                     Register_Range_Alias
                       (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                        Base_Tag,
                        Low_Res,
                        High_Res);
                  end;
               end if;

            when AST_Temporal_Decl =>
               if Tree (Idx).Left_Child /= 0 then
                  declare
                     Emit_Name : constant String :=
                       Registration_Name
                         (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                          Module_Name,
                          Routine_Name);
                  begin
                     Tag := (if Tree (Idx).Token_Index > 0
                             then Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index))
                             else Type_S32);
                     History := Try_Parse_Natural (Tree (Idx).Right_Child, 8, Module_Name, Routine_Name);
                     Register_Symbol
                       (Emit_Name,
                        Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                        Module_Name,
                        Routine_Name,
                        Tag,
                        Sym_Temporal,
                        0,
                        (others => 0),
                        "",
                        History,
                        Next_Timeline_Offset);
                     Next_Timeline_Offset := Next_Timeline_Offset + History * 8;
                  end;
               end if;

            when AST_Const_Decl =>
               if Tree (Idx).Left_Child /= 0 then
                  Register_Const
                    (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                     Module_Name,
                     Routine_Name,
                     Tree (Idx).Right_Child);
               end if;
               if Tree (Idx).Right_Child /= 0 then
                  Scan_Node (Tree (Idx).Right_Child, Module_Name, Routine_Name);
               end if;

            when AST_Try_Stmt =>
               if Tree (Idx).Token_Index > 0 and then Routine_Name'Length > 0 then
                  Register_Symbol
                    (Registration_Name
                       (Raw_Lexeme (Tree (Idx).Token_Index),
                        Module_Name,
                        Routine_Name),
                     Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index)),
                     Module_Name,
                     Routine_Name,
                     Type_Binary);
               end if;

            when AST_Create_Window =>
               Has_Window := True;
               if Tree (Idx).Left_Child /= 0 then
                  declare
                     Title : constant String := Strip_String_Literal (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
                  begin
                     Window_Title_Len := Title'Length;
                     Window_Title := Copy_Name (Title);
                  end;
               end if;
               if Tree (Idx).Right_Child /= 0 then
                  Window_Width :=
                    Try_Parse_Natural
                      (Create_Window_Width_Node (Idx),
                       320,
                       Module_Name,
                       Routine_Name);
                  Window_Height :=
                    Try_Parse_Natural
                      (Create_Window_Height_Node (Idx),
                       200,
                       Module_Name,
                       Routine_Name);
               end if;

            when AST_On_Block =>
               Scan_On_Block_Node (Idx, Module_Name, Routine_Name);

            when AST_Knows_Change =>
               declare
                  Watched_Node : constant Node_Index := Tree (Idx).Right_Child;
                  Pred_Name    : constant String := Predicate_Name_Of (Watched_Node);
                  Arg_Node     : constant Node_Index := Predicate_Arg_Node (Watched_Node);
                  Param_Name   : constant String :=
                    (if Arg_Node /= 0 and then Tree (Arg_Node).Token_Index > 0
                     then Safe_Name (Raw_Lexeme (Tree (Arg_Node).Token_Index))
                     else "Change_Value");
                  Handler_Name : constant String :=
                    "ALB_On_Knows_Change_" &
                    Pred_Name &
                    "_" &
                    Trim_Image (Integer (Idx));
               begin
                  Register_Knows_Hook (Pred_Name, Handler_Name, Param_Name, Idx);
                  if Tree (Idx).Left_Child /= 0 then
                     Scan_Node (Tree (Idx).Left_Child, Module_Name, Handler_Name);
                  end if;
               end;

            when AST_Listen =>
               Has_Listen := True;

            when AST_Poke_Stmt =>
               Need_Address_Helpers := True;
               Scan_Expr_Features (Tree (Idx).Left_Child);
               Scan_Expr_Features (Tree (Idx).Right_Child);

            when AST_Save_State | AST_Load_State =>
               Need_Save_State := True;

            when AST_Comptime_Block =>
               null;

            when others =>
               Scan_Expr_Features (Idx);
               Scan_Sibling_List (Tree (Idx).Left_Child);
               Scan_Sibling_List (Tree (Idx).Right_Child);
         end case;
      end Scan_Node;

      function Has_Program_Global_Symbols return Boolean is
      begin
         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then Symbols (I).Scope_Name_Len = 0
              and then Symbols (I).Kind in Sym_Scalar | Sym_Array | Sym_Temporal
            then
               return True;
            end if;
         end loop;
         return False;
      end Has_Program_Global_Symbols;

      function Main_Needs_User_Unit_Use return Boolean is
      begin
         if Routine_Count = 0 then
            return False;
         end if;
         if Move_Globals_To_User_Unit then
            return True;
         end if;
         if Alias_Count = 0 and then Struct_Count = 0 then
            return False;
         end if;
         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then Symbols (I).Scope_Name_Len = 0
              and then Symbols (I).Kind in Sym_Scalar | Sym_Array
            then
               return True;
            end if;
         end loop;
         return False;
      end Main_Needs_User_Unit_Use;

      procedure Finalize_Runtime_Needs is
      begin
         if Network_Socket_Count > 0 or else Has_Listen then
            Need_Net_Runtime := True;
         end if;

         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active then
               if Symbols (I).Tag in Type_F32 | Type_F64 then
                  Need_F64_Runtime := True;
                  if Critical_Mode then
                     Record_Critical_Violation ("FLOAT_TYPE");
                  end if;
               elsif Symbols (I).Tag in Type_F32x2 | Type_F32x4 | Type_Mat2x2 |
                     Type_Mat3x3 | Type_Mat4x4 | Type_U128 | Type_S128 | Type_F128
               then
                  Need_Numerus_Runtime := True;
               end if;
               if Symbols (I).Tag = Type_Binary then
                  Need_Strings_Unit := True;
               end if;
               if Symbols (I).Alias_Idx > 0
                 and then Aliases (Symbols (I).Alias_Idx).Active
               then
                  if Aliases (Symbols (I).Alias_Idx).Tag in Type_F32 | Type_F64 then
                     Need_F64_Runtime := True;
                     if Critical_Mode then
                        Record_Critical_Violation ("FLOAT_TYPE");
                     end if;
                  end if;
               end if;
            end if;
         end loop;

         if Critical_Mode and then Need_Net_Runtime then
            Record_Critical_Violation ("NETWORK");
         end if;
         if Critical_Mode and then Need_NN_Runtime then
            Record_Critical_Violation ("NEURAL");
         end if;
         if Critical_Mode and then Need_Markov_Runtime then
            Record_Critical_Violation ("MARKOV");
         end if;
      end Finalize_Runtime_Needs;

      procedure Emit_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Expected    : ALB_Type_Tag := Type_None;
         As_Text     : Boolean := False;
         Ok          : in out Boolean);

      procedure Emit_Assigned_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Target_Tag  : ALB_Type_Tag := Type_None;
         Ok          : in out Boolean);

      procedure Emit_Condition_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean);

      procedure Emit_Converted_Expression
        (Idx         : Node_Index;
         Module_Name : String;
         Source_Tag  : ALB_Type_Tag;
         Target_Tag  : ALB_Type_Tag;
         Ok          : in out Boolean);

      procedure Emit_Load_From_Address_Expr
        (Address_Idx  : Node_Index;
         Module_Name  : String;
         Tag          : ALB_Type_Tag;
         Struct_Name  : String := "";
         Ok           : in out Boolean);

      function Comptime_Text
        (Idx         : Node_Index;
         Module_Name : String := "") return String;

      function Comptime_Text
        (Idx         : Node_Index;
         Module_Name : String := "") return String is
      begin
         if Idx = 0 then
            return "";
         end if;

         case Tree (Idx).Kind is
            when AST_String_Expr =>
               return Strip_String_Literal (Raw_Lexeme (Tree (Idx).Token_Index));
            when AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
               return Trim_Image (Integer (Try_Parse_Natural (Idx, 0, Module_Name)));
            when AST_Const_Ref =>
               declare
                  Const_Node : constant Node_Index :=
                    Find_Const_Expr (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
               begin
                  if Const_Node /= 0 then
                     return Comptime_Text (Const_Node, Module_Name);
                  end if;
                  return "";
               end;
            when AST_True =>
               return "TRUE";
            when AST_False =>
               return "FALSE";
            when AST_Var_Expr =>
               return Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
            when AST_BinOp =>
               if Tree (Idx).Token_Index > 0
                 and then Tokens (Tree (Idx).Token_Index).Kind = Tok_Pipe
               then
                  return
                    Comptime_Text (Tree (Idx).Left_Child, Module_Name) &
                    Comptime_Text (Tree (Idx).Right_Child, Module_Name);
               end if;
               return "";
            when others =>
               return "";
         end case;
      end Comptime_Text;

      function Create_Window_Width_Node (Idx : Node_Index) return Node_Index is
         Args_Node : constant Node_Index :=
           (if Idx /= 0 then Tree (Idx).Right_Child else 0);
      begin
         if Args_Node = 0 then
            return 0;
         elsif Tree (Args_Node).Left_Child /= 0 then
            return Tree (Args_Node).Left_Child;
         else
            return Args_Node;
         end if;
      end Create_Window_Width_Node;

      function Create_Window_Height_Node (Idx : Node_Index) return Node_Index is
         Args_Node  : constant Node_Index :=
           (if Idx /= 0 then Tree (Idx).Right_Child else 0);
         Width_Node : constant Node_Index := Create_Window_Width_Node (Idx);
      begin
         if Args_Node = 0 then
            return 0;
         elsif Tree (Args_Node).Right_Child /= 0 then
            return Tree (Args_Node).Right_Child;
         elsif Width_Node /= 0 then
            return Tree (Width_Node).Next_Sibling;
         else
            return 0;
         end if;
      end Create_Window_Height_Node;

      procedure Execute_Comptime_Node
        (Idx         : Node_Index;
         Module_Name : String := "") is
         Curr : Node_Index := 0;
      begin
         if Idx = 0 then
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Block_Stmt | AST_Program =>
               Curr := Tree (Idx).Left_Child;
               while Curr /= 0 loop
                  Execute_Comptime_Node (Curr, Module_Name);
                  Curr := Tree (Curr).Next_Sibling;
               end loop;

            when AST_Module =>
               if Tree (Idx).Left_Child /= 0 then
                  Execute_Comptime_Node
                    (Tree (Idx).Right_Child,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)));
               end if;

            when AST_Comptime_Block =>
               Execute_Comptime_Node (Tree (Idx).Left_Child, Module_Name);

            when AST_Print_Stmt | AST_Print_Str_Stmt =>
               declare
                  Part : Node_Index := Tree (Idx).Left_Child;
               begin
                  if Part /= 0 and then Tree (Part).Kind = AST_Arg_List then
                     Part := Tree (Part).Left_Child;
                  end if;
                  while Part /= 0 loop
                     Ada.Text_IO.Put (Comptime_Text (Part, Module_Name));
                     Part := Tree (Part).Next_Sibling;
                  end loop;
                  Ada.Text_IO.New_Line;
               end;

            when others =>
               null;
         end case;
      end Execute_Comptime_Node;

      procedure Emit_Logic_Hash
        (Predicate_Name : String;
         Ok             : in out Boolean) is
      begin
         Emit_Raw ("ALBA_Logic.Hash_Name(""" & Predicate_Name & """)", Ok);
      end Emit_Logic_Hash;

      procedure Emit_Knows_Change_Notify
        (Predicate_Name : String;
         Value_Node     : Node_Index;
         Module_Name    : String;
         Ok             : in out Boolean) is
      begin
         for I in 1 .. Knows_Hook_Count loop
            exit when not Ok;
            if Knows_Hooks (I).Active
              and then Name_Text (Knows_Hooks (I).Predicate_Name, Knows_Hooks (I).Predicate_Name_Len) = Predicate_Name
            then
               Emit_Indent (Ok);
               Emit_Raw
                 (Name_Text (Knows_Hooks (I).Handler_Name, Knows_Hooks (I).Handler_Name_Len) & "(",
                  Ok);
               if Value_Node /= 0 then
                  Emit_Assigned_Expression (Value_Node, Module_Name, Type_S32, Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);
            end if;
         end loop;
      end Emit_Knows_Change_Notify;

      procedure Emit_Rule_Registration
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Max_Rule_Vars : constant Natural := 16;
         type Rule_Name_Array is array (1 .. Max_Rule_Vars) of Name_Buffer;
         Rule_Vars      : Rule_Name_Array := (others => (others => ' '));
         Rule_Var_Lens  : array (1 .. Max_Rule_Vars) of Natural := (others => 0);
         Rule_Var_Count : Natural := 0;
         Head_Node      : constant Node_Index := Tree (Idx).Left_Child;
         Body_Node      : constant Node_Index := Tree (Idx).Right_Child;
         Rule_Name      : constant String := "alba_rule_" & Trim_Image (Integer (Idx));

         function Register_Var (Arg_Node : Node_Index) return Natural is
            Name : constant String := Predicate_Name_Of (Arg_Node);
            Raw  : constant String :=
              (if Arg_Node /= 0 and then Tree (Arg_Node).Token_Index > 0
               then Raw_Lexeme (Tree (Arg_Node).Token_Index)
               else "");
          begin
            if Arg_Node = 0
              or else
                (Tree (Arg_Node).Kind /= AST_Logic_Var
                 and then
                   (Tree (Arg_Node).Token_Index = 0
                    or else
                      (Tokens (Tree (Arg_Node).Token_Index).Kind /= Tok_Logic_Var
                       and then
                         (Raw'Length = 0 or else Raw (Raw'First) not in 'A' .. 'Z'))))
            then
               return 0;
            end if;

            for I in 1 .. Rule_Var_Count loop
               if Rule_Var_Lens (I) = Name'Length
                 and then Name_Text (Rule_Vars (I), Rule_Var_Lens (I)) = Name
               then
                  return I;
               end if;
            end loop;

            if Rule_Var_Count < Max_Rule_Vars then
               Rule_Var_Count := Rule_Var_Count + 1;
               Rule_Var_Lens (Rule_Var_Count) := Name'Length;
               Rule_Vars (Rule_Var_Count) := Copy_Name (Name);
               return Rule_Var_Count;
            end if;
            return 0;
         end Register_Var;

         procedure Scan_Arg (Arg_Node : Node_Index) is
            Dummy_Id : Natural := 0;
            Raw      : constant String :=
              (if Arg_Node /= 0 and then Tree (Arg_Node).Token_Index > 0
               then Raw_Lexeme (Tree (Arg_Node).Token_Index)
               else "");
         begin
            if Arg_Node /= 0
              and then
                (Tree (Arg_Node).Kind = AST_Logic_Var
                 or else
                   (Tree (Arg_Node).Token_Index > 0
                    and then
                      (Tokens (Tree (Arg_Node).Token_Index).Kind = Tok_Logic_Var
                       or else (Raw'Length > 0 and then Raw (Raw'First) in 'A' .. 'Z'))))
            then
               Dummy_Id := Register_Var (Arg_Node);
            end if;
         end Scan_Arg;

         procedure Emit_Arg_Mode_Value
           (Arg_Node : Node_Index;
            Ok       : in out Boolean) is
         begin
            if Arg_Node = 0 then
               Emit_Raw ("0, 0", Ok);
            elsif Tree (Arg_Node).Kind = AST_Logic_Var
              or else
                (Tree (Arg_Node).Token_Index > 0
                 and then
                   (Tokens (Tree (Arg_Node).Token_Index).Kind = Tok_Logic_Var
                    or else
                      (Raw_Lexeme (Tree (Arg_Node).Token_Index)'Length > 0
                       and then Raw_Lexeme (Tree (Arg_Node).Token_Index)
                         (Raw_Lexeme (Tree (Arg_Node).Token_Index)'First) in 'A' .. 'Z')))
            then
               Emit_Raw
                 ("2, " & Trim_Image (Integer (Register_Var (Arg_Node))),
                  Ok);
            else
               Emit_Raw ("1, ", Ok);
               Emit_Assigned_Expression (Arg_Node, Module_Name, Type_S32, Ok);
            end if;
         end Emit_Arg_Mode_Value;

         Body_Curr : Node_Index := 0;
         Arg_Node  : Node_Index := 0;
      begin
         if Head_Node = 0 then
            return;
         end if;

         Scan_Arg (Predicate_Arg_Node (Head_Node));
         if Body_Node /= 0 then
            Body_Curr := Tree (Body_Node).Left_Child;
            while Body_Curr /= 0 loop
               Scan_Arg (Predicate_Arg_Node (Body_Curr));
               Body_Curr := Tree (Body_Curr).Next_Sibling;
            end loop;
         end if;

         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Indent (Ok);
         Emit_Raw (Rule_Name & " : Natural := ALBA_Logic.Register_Rule(", Ok);
         Emit_Logic_Hash (Predicate_Name_Of (Head_Node), Ok);
         Emit_Raw (", ", Ok);
         Emit_Arg_Mode_Value (Predicate_Arg_Node (Head_Node), Ok);
         Emit_Raw (", " & Trim_Image (Integer (Rule_Var_Count)) & ");", Ok);
         Emit_Newline (Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;

         if Body_Node /= 0 then
            Body_Curr := Tree (Body_Node).Left_Child;
            while Body_Curr /= 0 and then Ok loop
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Logic.Add_Rule_Term(" & Rule_Name & ", ", Ok);
               Emit_Logic_Hash (Predicate_Name_Of (Body_Curr), Ok);
               Emit_Raw (", ", Ok);
               Arg_Node := Predicate_Arg_Node (Body_Curr);
               Emit_Arg_Mode_Value (Arg_Node, Ok);
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);
               Body_Curr := Tree (Body_Curr).Next_Sibling;
            end loop;
         end if;
         Decrease_Indent;
         Emit_Line ("end;", Ok);
      end Emit_Rule_Registration;

      procedure Emit_Comment (Text : String; Ok : in out Boolean) is
      begin
         Emit_Line ("-- " & Text, Ok);
      end Emit_Comment;

      procedure Emit_Target
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean);

      procedure Emit_Text_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean) is
      begin
         case Infer_Type (Idx, Module_Name) is
            when Type_Binary =>
               Emit_Expression (Idx, Module_Name, Type_Binary, True, Ok);
            when Type_Boolean =>
               Emit_Raw ("ALB_IMAGE(", Ok);
               Emit_Expression (Idx, Module_Name, Type_Boolean, False, Ok);
               Emit_Raw (")", Ok);
            when Type_F32 | Type_F64 =>
               Emit_Raw ("ALB_IMAGE_F64(F64(", Ok);
               Emit_Expression (Idx, Module_Name, Type_F64, False, Ok);
               Emit_Raw ("))", Ok);
            when Type_S32 =>
               Emit_Raw ("ALB_IMAGE(S32(", Ok);
               Emit_Expression (Idx, Module_Name, Type_S32, False, Ok);
               Emit_Raw ("))", Ok);
            when Type_S8 | Type_S16 =>
               Emit_Raw ("ALB_IMAGE(S32(", Ok);
               Emit_Expression (Idx, Module_Name, Type_S32, False, Ok);
               Emit_Raw ("))", Ok);
            when Type_Pure =>
               Emit_Raw ("ALB_IMAGE(", Ok);
               Emit_Expression (Idx, Module_Name, Type_Pure, False, Ok);
               Emit_Raw (")", Ok);
            when Type_U64 =>
               Emit_Raw ("ALB_IMAGE(", Ok);
               Emit_Expression (Idx, Module_Name, Type_U64, False, Ok);
               Emit_Raw (")", Ok);
            when others =>
               Emit_Raw ("ALB_IMAGE(U64(", Ok);
               Emit_Expression (Idx, Module_Name, Type_U64, False, Ok);
               Emit_Raw ("))", Ok);
         end case;
      end Emit_Text_Expression;

      procedure Emit_Assigned_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Target_Tag  : ALB_Type_Tag := Type_None;
         Ok          : in out Boolean) is
         Source_Tag : constant ALB_Type_Tag := Infer_Type (Idx, Module_Name);
      begin
         if Target_Tag = Type_Binary then
            Emit_Text_Expression (Idx, Module_Name, Ok);
         elsif Target_Tag = Type_U64
           and then Idx /= 0
           and then
             (Tree (Idx).Kind = AST_AddressOf
              or else Tree (Idx).Kind = AST_Ref_Expr
              or else
                (Tree (Idx).Kind = AST_Temporal_Ref
                 and then Tree (Idx).Token_Index > 0
                 and then Tokens (Tree (Idx).Token_Index).Kind = Tok_Timeline))
         then
            if Source_Tag = Type_U64 then
               Emit_Expression (Idx, Module_Name, Type_U64, False, Ok);
            else
               Emit_Raw ("U64(", Ok);
               Emit_Expression (Idx, Module_Name, Type_U64, False, Ok);
               Emit_Raw (")", Ok);
            end if;
         elsif Idx /= 0
           and then
             (Tree (Idx).Kind = AST_Deref_Expr
              or else Tree (Idx).Kind = AST_Peek_Expr)
           and then Target_Tag /= Type_None
           and then Target_Tag /= Type_U64
         then
            Emit_Load_From_Address_Expr
              (Tree (Idx).Left_Child,
               Module_Name,
               Target_Tag,
               "",
               Ok);
         elsif Target_Tag = Type_U64 and then Source_Tag = Type_S32 then
            if Idx /= 0
              and then Tree (Idx).Kind = AST_BinOp
              and then Tree (Idx).Token_Index > 0
              and then Tokens (Tree (Idx).Token_Index).Kind = TOK_MINUS
              and then Tree (Idx).Left_Child /= 0
              and then Tree (Tree (Idx).Left_Child).Kind = AST_Number_Expr
              and then Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index) = "0"
            then
               Emit_Raw ("ALB_ABS_S32_TO_U64(", Ok);
               Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_S32, False, Ok);
               Emit_Raw (")", Ok);
            else
               Emit_Converted_Expression
                 (Idx, Module_Name, Source_Tag, Target_Tag, Ok);
            end if;
         elsif Target_Tag = Type_S32 and then Source_Tag = Type_U64 then
            Emit_Raw ("S32(", Ok);
            Emit_Expression (Idx, Module_Name, Type_U64, False, Ok);
            Emit_Raw (")", Ok);
         elsif Target_Tag /= Type_None
           and then Source_Tag /= Type_None
           and then Target_Tag /= Source_Tag
           and then Target_Tag /= Type_Boolean
           and then Source_Tag /= Type_Boolean
           and then Target_Tag /= Type_Binary
           and then Source_Tag /= Type_Binary
           and then Target_Tag /= Type_Pure
           and then Source_Tag /= Type_Pure
         then
            Emit_Converted_Expression
              (Idx, Module_Name, Source_Tag, Target_Tag, Ok);
         else
            Emit_Expression
              (Idx,
               Module_Name,
               (if Target_Tag /= Type_None then Target_Tag else Source_Tag),
               False,
               Ok);
         end if;
      end Emit_Assigned_Expression;

      procedure Emit_Condition_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean) is
          Cond_Tag : constant ALB_Type_Tag := Infer_Type (Idx, Module_Name);
          Tok      : Token;
          Left_Tag : ALB_Type_Tag;
          Right_Tag : ALB_Type_Tag;
      begin
          if Idx /= 0
            and then Tree (Idx).Kind = AST_BinOp
            and then Tree (Idx).Token_Index > 0
          then
             Tok := Tokens (Tree (Idx).Token_Index);
             if Tok.Kind in TOK_AND | TOK_OR | TOK_XOR then
                Left_Tag := Infer_Type (Tree (Idx).Left_Child, Module_Name);
                Right_Tag := Infer_Type (Tree (Idx).Right_Child, Module_Name);
                if Left_Tag = Type_Boolean and then Right_Tag = Type_Boolean then
                   Emit_Raw ("(", Ok);
                   Emit_Condition_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                   case Tok.Kind is
                      when TOK_AND   => Emit_Raw (" and ", Ok);
                      when TOK_OR    => Emit_Raw (" or ", Ok);
                      when TOK_XOR   => Emit_Raw (" xor ", Ok);
                      when others    => null;
                   end case;
                   Emit_Condition_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
                   Emit_Raw (")", Ok);
                else
                   Emit_Raw ("(", Ok);
                   Emit_Expression
                     (Idx,
                      Module_Name,
                      Promote_Numeric_Tag
                        ((if Left_Tag /= Type_None then Left_Tag else Type_U64),
                         (if Right_Tag /= Type_None then Right_Tag else Type_U64)),
                      False,
                      Ok);
                   Emit_Raw (") /= 0", Ok);
                end if;
                return;
             end if;
          end if;

          if Cond_Tag = Type_Boolean then
             Emit_Expression (Idx, Module_Name, Type_Boolean, False, Ok);
          elsif Cond_Tag = Type_Binary then
            Emit_Raw ("(ALB_TEXT_LENGTH(", Ok);
            Emit_Text_Expression (Idx, Module_Name, Ok);
            Emit_Raw (") /= 0)", Ok);
         elsif Cond_Tag = Type_Pure then
            Emit_Raw ("(ALB_PURE_NUM(", Ok);
            Emit_Expression (Idx, Module_Name, Type_Pure, False, Ok);
            Emit_Raw (") /= 0)", Ok);
         else
            Emit_Raw ("(", Ok);
            Emit_Expression
              (Idx,
               Module_Name,
               (if Cond_Tag /= Type_None then Cond_Tag else Type_U64),
               False,
               Ok);
            Emit_Raw (") /= 0", Ok);
         end if;
      end Emit_Condition_Expression;

      procedure Emit_Converted_Expression
        (Idx         : Node_Index;
         Module_Name : String;
         Source_Tag  : ALB_Type_Tag;
         Target_Tag  : ALB_Type_Tag;
         Ok          : in out Boolean)
      is
         Inner_Tag : constant ALB_Type_Tag :=
           (if Source_Tag /= Type_None then Source_Tag else Target_Tag);

         function BinOp_Has_U64_Operand return Boolean is
            Left_Tag  : ALB_Type_Tag;
            Right_Tag : ALB_Type_Tag;
         begin
            if Idx = 0 or else Tree (Idx).Kind /= AST_BinOp then
               return False;
            end if;
            Left_Tag := Infer_Type (Tree (Idx).Left_Child, Module_Name);
            Right_Tag := Infer_Type (Tree (Idx).Right_Child, Module_Name);
            return Left_Tag = Type_U64 or else Right_Tag = Type_U64;
         end BinOp_Has_U64_Operand;
      begin
         if Source_Tag /= Type_None and then Target_Tag = Source_Tag then
            Emit_Expression (Idx, Module_Name, Inner_Tag, False, Ok);
            return;
         end if;

         -- Ada rejects bare U64(negative_signed). Keep pure signed arithmetic
         -- in the source type, then convert with the ALBA helpers.
         if Target_Tag = Type_U64 and then Is_Signed_Integer_Tag (Source_Tag) then
            if Source_Tag = Type_S64 and then BinOp_Has_U64_Operand then
               -- Mixed U64/signed promote-to-S64: evaluate as U64 for U64 targets
               -- (e.g. 15 + RND(20) used as a U64 lifetime).
               Emit_Expression (Idx, Module_Name, Type_U64, False, Ok);
            else
               case Source_Tag is
                  when Type_S8 | Type_HW8 =>
                     Emit_Raw ("ALB_S8_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S8, False, Ok);
                  when Type_S16 | Type_HW16 =>
                     Emit_Raw ("ALB_S16_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S16, False, Ok);
                  when Type_S64 | Type_HW64 =>
                     Emit_Raw ("ALB_S64_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S64, False, Ok);
                  when others =>
                     Emit_Raw ("ALB_S32_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S32, False, Ok);
               end case;
               Emit_Raw (")", Ok);
            end if;
         elsif Target_Tag in Type_U8 | Type_U16 | Type_U32
           and then Source_Tag /= Type_None
           and then Source_Tag /= Target_Tag
           and then Source_Tag /= Type_Boolean
           and then Source_Tag /= Type_Binary
           and then Source_Tag /= Type_Pure
         then
            -- Narrowing to a small modular type must not use bare U16(N) for
            -- values outside the static subtype (e.g. timeline VAS offsets).
            case Target_Tag is
               when Type_U8 =>
                  Emit_Raw ("ALB_U64_TO_U8(", Ok);
               when Type_U16 =>
                  Emit_Raw ("ALB_U64_TO_U16(", Ok);
               when others =>
                  Emit_Raw ("ALB_U64_TO_U32(", Ok);
            end case;
            if Source_Tag = Type_U64 then
               Emit_Expression (Idx, Module_Name, Type_U64, False, Ok);
            elsif Is_Signed_Integer_Tag (Source_Tag) then
               case Source_Tag is
                  when Type_S8 | Type_HW8 =>
                     Emit_Raw ("ALB_S8_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S8, False, Ok);
                  when Type_S16 | Type_HW16 =>
                     Emit_Raw ("ALB_S16_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S16, False, Ok);
                  when Type_S64 | Type_HW64 =>
                     Emit_Raw ("ALB_S64_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S64, False, Ok);
                  when others =>
                     Emit_Raw ("ALB_S32_TO_U64(", Ok);
                     Emit_Expression (Idx, Module_Name, Type_S32, False, Ok);
               end case;
               Emit_Raw (")", Ok);
            else
               Emit_Raw ("U64(", Ok);
               Emit_Expression (Idx, Module_Name, Source_Tag, False, Ok);
               Emit_Raw (")", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Target_Tag /= Type_None
           and then Source_Tag /= Type_None
           and then Target_Tag /= Source_Tag
           and then Target_Tag /= Type_Boolean
           and then Source_Tag /= Type_Boolean
           and then Target_Tag /= Type_Binary
           and then Source_Tag /= Type_Binary
           and then Target_Tag /= Type_Pure
           and then Source_Tag /= Type_Pure
         then
            Emit_Raw (Ada_Type_Name (Target_Tag) & "(", Ok);
            Emit_Expression (Idx, Module_Name, Inner_Tag, False, Ok);
            Emit_Raw (")", Ok);
         else
            Emit_Expression (Idx, Module_Name, Inner_Tag, False, Ok);
         end if;
      end Emit_Converted_Expression;

      procedure Emit_Flat_Index
        (Sym_Idx : Natural;
         Idx     : Node_Index;
         Module_Name : String;
         Ok      : in out Boolean) is
         Curr   : Node_Index := Idx;
         Factor : Natural := 1;
      begin
         if Sym_Idx = 0 or else Symbols (Sym_Idx).Rank <= 1 then
            Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            return;
         end if;

         Emit_Raw ("(", Ok);
         for D in 1 .. Symbols (Sym_Idx).Rank loop
            Factor := 1;
            for Next_D in D + 1 .. Symbols (Sym_Idx).Rank loop
               if Symbols (Sym_Idx).Dims (Next_D) > 0 then
                  Factor := Factor * Symbols (Sym_Idx).Dims (Next_D);
               end if;
            end loop;

            if D < Symbols (Sym_Idx).Rank then
               Emit_Raw ("((", Ok);
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
               Emit_Raw (") - 1) * " & Trim_Image (Integer (Factor)) & " + ", Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            end if;
         end loop;
         Emit_Raw (")", Ok);
      end Emit_Flat_Index;

      procedure Emit_Address_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean) is
         Sym_Idx   : Natural := 0;
         Param_Idx : Natural := 0;
         Field_Idx : Natural := 0;
      begin
         if Idx = 0 then
            Emit_Raw ("0", Ok);
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Var_Expr | AST_Logic_Var =>
               declare
                  Name      : constant String :=
                    Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
                  Elem_Size : Natural := 0;
               begin
                  Param_Idx := Current_Param_Index (Raw_Lexeme (Tree (Idx).Token_Index));
                  if Param_Idx > 0
                    and then Current_Frame_Active
                    and then Current_Params (Param_Idx).VAS_Offset > 0
                  then
                     Emit_Raw
                       ("(ALBA_Frame_Base + " &
                        Trim_Image (Integer (Current_Params (Param_Idx).VAS_Offset)) &
                        ")",
                        Ok);
                  else
                     Sym_Idx := Find_Symbol (Name);
                  end if;

                  if Ok and then Param_Idx = 0
                    and then Sym_Idx > 0
                    and then Symbols (Sym_Idx).VAS_Offset > 0
                  then
                     if Tree (Idx).Left_Child /= 0
                       and then Symbols (Sym_Idx).Kind = Sym_Array
                     then
                        Elem_Size := Natural'Max (1, Symbol_Element_Size_Bytes (Sym_Idx));
                        Emit_Raw
                          ("(" &
                           (if Symbols (Sym_Idx).Scope_Name_Len = 0
                            then Trim_Image (Integer (Symbols (Sym_Idx).VAS_Offset))
                            else "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Sym_Idx).VAS_Offset))) &
                           " + ((",
                           Ok);
                        Emit_Flat_Index (Sym_Idx, Tree (Idx).Left_Child, Module_Name, Ok);
                        Emit_Raw
                          (" - 1) * " &
                           Trim_Image (Integer (Elem_Size)) &
                           "))",
                           Ok);
                     else
                        Emit_Raw
                          ((if Symbols (Sym_Idx).Scope_Name_Len = 0
                            then Trim_Image (Integer (Symbols (Sym_Idx).VAS_Offset))
                            else "(ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Sym_Idx).VAS_Offset)) & ")"),
                           Ok);
                     end if;
                  elsif Param_Idx = 0 then
                     Emit_Raw ("0", Ok);
                  end if;
               end;

            when AST_Member_Expr =>
               if Is_Var_Like_Node (Tree (Idx).Left_Child) then
                  declare
                     Name : constant String :=
                        Resolve_Name
                         (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                          Module_Name);
                  begin
                     Param_Idx := Current_Param_Index (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
                     Sym_Idx := Find_Symbol (Name);
                     if Param_Idx > 0
                       and then Current_Frame_Active
                       and then Current_Params (Param_Idx).VAS_Offset > 0
                       and then Current_Params (Param_Idx).Struct_Name_Len > 0
                     then
                        declare
                           Struct_Name : constant String :=
                             Name_Text
                               (Current_Params (Param_Idx).Struct_Name,
                                Current_Params (Param_Idx).Struct_Name_Len);
                        begin
                           Field_Idx :=
                             Find_Struct_Field
                               (Struct_Name,
                                Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                           if Field_Idx > 0 then
                              Emit_Raw
                                ("(" &
                                 "ALBA_Frame_Base + " &
                                 Trim_Image (Integer (Current_Params (Param_Idx).VAS_Offset)) &
                                 " + " &
                                 Trim_Image (Integer (Struct_Fields (Field_Idx).Offset_Bytes)) &
                                 ")",
                                 Ok);
                           else
                              Emit_Raw ("0", Ok);
                           end if;
                        end;
                     elsif Sym_Idx > 0
                       and then Symbols (Sym_Idx).VAS_Offset > 0
                       and then Symbols (Sym_Idx).Struct_Name_Len > 0
                     then
                        declare
                           Struct_Name : constant String :=
                             Name_Text
                               (Symbols (Sym_Idx).Struct_Name,
                                Symbols (Sym_Idx).Struct_Name_Len);
                        begin
                           Field_Idx :=
                             Find_Struct_Field
                               (Struct_Name,
                                Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                           if Field_Idx > 0 then
                              Emit_Raw
                                ("(" &
                                 (if Symbols (Sym_Idx).Scope_Name_Len = 0
                                  then Trim_Image (Integer (Symbols (Sym_Idx).VAS_Offset))
                                  else "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Sym_Idx).VAS_Offset))) &
                                 " + " &
                                 Trim_Image (Integer (Struct_Fields (Field_Idx).Offset_Bytes)) &
                                 ")",
                                 Ok);
                           else
                              Emit_Raw ("0", Ok);
                           end if;
                        end;
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                  end;
               else
                  Emit_Raw ("0", Ok);
               end if;

            when others =>
               Emit_Raw ("0", Ok);
         end case;
      end Emit_Address_Expression;

      function Struct_Store_Helper_Name (Struct_Name : String) return String is
      begin
         return "ALBA_Store_" & Safe_Name (Struct_Name) & "_VAS";
      end Struct_Store_Helper_Name;

      function Struct_Load_Helper_Name (Struct_Name : String) return String is
      begin
         return "ALBA_Load_" & Safe_Name (Struct_Name) & "_VAS";
      end Struct_Load_Helper_Name;

      function Load_From_VAS_Text
        (Address_Text : String;
         Tag          : ALB_Type_Tag;
         Struct_Name  : String := "") return String is
      begin
         if Struct_Name'Length > 0 then
            return
              Struct_Load_Helper_Name (Struct_Name) &
              "(Positive(" & Address_Text & "))";
         end if;

         case Tag is
            when Type_Boolean =>
               return "ALB_LOAD_BOOL(Positive(" & Address_Text & "))";
            when Type_U8 =>
               return "U8(ALB_LOAD_U8(Positive(" & Address_Text & ")))";
            when Type_U16 =>
               return "U16(ALB_LOAD_U16(Positive(" & Address_Text & ")))";
            when Type_U32 =>
               return "U32(ALB_LOAD_U32(Positive(" & Address_Text & ")))";
            when Type_U64 =>
               return "ALB_LOAD_U64(Positive(" & Address_Text & "))";
            when Type_S8 =>
               return "S8(ALB_LOAD_I8(Positive(" & Address_Text & ")))";
            when Type_S16 =>
               return "S16(ALB_LOAD_I16(Positive(" & Address_Text & ")))";
            when Type_S32 =>
               return "S32(ALB_LOAD_I32(Positive(" & Address_Text & ")))";
            when Type_S64 =>
               return "S64(ALB_LOAD_I64(Positive(" & Address_Text & ")))";
            when Type_F32 =>
               return "ALB_LOAD_F32(Positive(" & Address_Text & "))";
            when Type_F64 =>
               return "ALB_LOAD_F64(Positive(" & Address_Text & "))";
            when Type_Binary =>
               return "ALB_LOAD_TEXT(Positive(" & Address_Text & "))";
            when Type_Pure =>
               return "ALB_LOAD_PURE(Positive(" & Address_Text & "))";
            when Type_F32x2 | Type_F32x4 =>
               return "(others => 0.0)";
            when Type_Mat2x2 | Type_Mat3x3 | Type_Mat4x4 =>
               return "(others => (others => 0.0))";
            when others =>
               return "ALB_LOAD_U64(Positive(" & Address_Text & "))";
         end case;
      end Load_From_VAS_Text;

      procedure Emit_Load_From_Address_Expr
        (Address_Idx  : Node_Index;
         Module_Name  : String;
         Tag          : ALB_Type_Tag;
         Struct_Name  : String := "";
         Ok           : in out Boolean) is
      begin
         if Struct_Name'Length > 0 then
            Emit_Raw (Struct_Load_Helper_Name (Struct_Name) & "(Positive(", Ok);
            Emit_Expression (Address_Idx, Module_Name, Type_U64, False, Ok);
            Emit_Raw ("))", Ok);
            return;
         end if;

         case Tag is
            when Type_Boolean =>
               Emit_Raw ("ALB_LOAD_BOOL(Positive(", Ok);
            when Type_U8 =>
               Emit_Raw ("U8(ALB_LOAD_U8(Positive(", Ok);
            when Type_U16 =>
               Emit_Raw ("U16(ALB_LOAD_U16(Positive(", Ok);
            when Type_U32 =>
               Emit_Raw ("U32(ALB_LOAD_U32(Positive(", Ok);
            when Type_U64 =>
               Emit_Raw ("ALB_LOAD_U64(Positive(", Ok);
            when Type_S8 =>
               Emit_Raw ("S8(ALB_LOAD_I8(Positive(", Ok);
            when Type_S16 =>
               Emit_Raw ("S16(ALB_LOAD_I16(Positive(", Ok);
            when Type_S32 =>
               Emit_Raw ("S32(ALB_LOAD_I32(Positive(", Ok);
            when Type_S64 =>
               Emit_Raw ("S64(ALB_LOAD_I64(Positive(", Ok);
            when Type_F32 =>
               Emit_Raw ("ALB_LOAD_F32(Positive(", Ok);
            when Type_F64 =>
               Emit_Raw ("ALB_LOAD_F64(Positive(", Ok);
            when Type_Binary =>
               Emit_Raw ("ALB_LOAD_TEXT(Positive(", Ok);
            when Type_Pure =>
               Emit_Raw ("ALB_LOAD_PURE(Positive(", Ok);
            when others =>
               Emit_Raw ("ALB_LOAD_U64(Positive(", Ok);
         end case;

         Emit_Expression (Address_Idx, Module_Name, Type_U64, False, Ok);

         case Tag is
            when Type_U64 | Type_Boolean | Type_F32 | Type_F64 | Type_Binary | Type_Pure | Type_None =>
               Emit_Raw ("))", Ok);
            when others =>
               Emit_Raw (")))", Ok);
         end case;
      end Emit_Load_From_Address_Expr;

      procedure Emit_Assign_From_VAS_Text
        (Target_Text  : String;
         Address_Text : String;
         Tag          : ALB_Type_Tag;
         Struct_Name  : String := "";
         Ok           : in out Boolean) is
      begin
         Emit_Line
           (Target_Text & " := " &
            Load_From_VAS_Text (Address_Text, Tag, Struct_Name) &
            ";",
            Ok);
      end Emit_Assign_From_VAS_Text;

      procedure Emit_Store_To_VAS_Text
        (Address_Text : String;
         Value_Text   : String;
         Tag          : ALB_Type_Tag;
         Struct_Name  : String := "";
         Ok           : in out Boolean) is
      begin
         if Struct_Name'Length > 0 then
            Emit_Line
              (Struct_Store_Helper_Name (Struct_Name) &
               "(Positive(" & Address_Text & "), " & Value_Text & ");",
               Ok);
         else
            case Tag is
               when Type_Boolean =>
                  Emit_Line
                    ("ALB_STORE_BOOL(Positive(" & Address_Text & "), " &
                     Value_Text & ");",
                     Ok);
               when Type_Binary =>
                  Emit_Line
                    ("ALB_STORE_TEXT(Positive(" & Address_Text & "), " &
                     Value_Text & ");",
                     Ok);
               when Type_Pure =>
                  Emit_Line
                    ("ALB_STORE_PURE(Positive(" & Address_Text & "), " &
                     Value_Text & ");",
                     Ok);
               when Type_F32 =>
                  Emit_Line
                    ("ALB_STORE_F32(Positive(" & Address_Text & "), " &
                     Value_Text & ");",
                     Ok);
               when Type_F64 =>
                  Emit_Line
                    ("ALB_STORE_F64(Positive(" & Address_Text & "), " &
                     Value_Text & ");",
                     Ok);
               when Type_U8 =>
                  Emit_Line
                    ("ALB_STORE_U8(Positive(" & Address_Text & "), ALB_U8(" &
                     Value_Text & "));",
                     Ok);
               when Type_U16 =>
                  Emit_Line
                    ("ALB_STORE_U16(Positive(" & Address_Text & "), ALB_U16(" &
                     Value_Text & "));",
                     Ok);
               when Type_U32 =>
                  Emit_Line
                    ("ALB_STORE_U32(Positive(" & Address_Text & "), ALB_U32(" &
                     Value_Text & "));",
                     Ok);
               when Type_U64 =>
                  Emit_Line
                    ("ALB_STORE_U64(Positive(" & Address_Text & "), " &
                     VAS_Store_Value_Text (Tag, Value_Text) &
                     ");",
                     Ok);
               when Type_S8 =>
                  Emit_Line
                    ("ALB_STORE_I8(Positive(" & Address_Text & "), ALB_I8(" &
                     Value_Text & "));",
                     Ok);
               when Type_S16 =>
                  Emit_Line
                    ("ALB_STORE_I16(Positive(" & Address_Text & "), ALB_I16(" &
                     Value_Text & "));",
                     Ok);
               when Type_S32 =>
                  Emit_Line
                    ("ALB_STORE_I32(Positive(" & Address_Text & "), ALB_I32(" &
                     Value_Text & "));",
                     Ok);
               when Type_S64 =>
                  Emit_Line
                    ("ALB_STORE_I64(Positive(" & Address_Text & "), ALB_I64(" &
                     Value_Text & "));",
                     Ok);
               when others =>
                  Emit_Line ("null;", Ok);
            end case;
         end if;
      end Emit_Store_To_VAS_Text;

      procedure Emit_Sync_Target_To_VAS
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean) is
         Sym_Idx         : Natural := 0;
         Param_Idx       : Natural := 0;
         Field_Idx       : Natural := 0;
         Struct_Name     : Name_Buffer := (others => ' ');
         Struct_Name_Len : Natural := 0;
      begin
         if Idx = 0 or else not Ok then
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Var_Expr | AST_Logic_Var =>
               Param_Idx := Current_Param_Index (Raw_Lexeme (Tree (Idx).Token_Index));
               if Param_Idx > 0
                 and then Current_Frame_Active
                 and then Current_Params (Param_Idx).VAS_Offset > 0
               then
                  Struct_Name := Current_Params (Param_Idx).Struct_Name;
                  Struct_Name_Len := Current_Params (Param_Idx).Struct_Name_Len;
                  Emit_Indent (Ok);
                  if Struct_Name_Len > 0 then
                     Emit_Raw
                       (Struct_Store_Helper_Name
                          (Name_Text (Struct_Name, Struct_Name_Len)) &
                         "(Positive(",
                         Ok);
                     Emit_Address_Expression (Idx, Module_Name, Ok);
                     Emit_Raw ("), ", Ok);
                     Emit_Target (Idx, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                  elsif Current_Params (Param_Idx).Tag = Type_Boolean then
                     Emit_Raw ("ALB_STORE_BOOL(Positive(", Ok);
                     Emit_Address_Expression (Idx, Module_Name, Ok);
                     Emit_Raw ("), ", Ok);
                     Emit_Target (Idx, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                  elsif Current_Params (Param_Idx).Tag = Type_Binary then
                     Emit_Raw ("ALB_STORE_TEXT(Positive(", Ok);
                     Emit_Address_Expression (Idx, Module_Name, Ok);
                     Emit_Raw ("), ", Ok);
                     Emit_Target (Idx, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                  elsif Current_Params (Param_Idx).Tag = Type_Pure then
                     Emit_Raw ("ALB_STORE_PURE(Positive(", Ok);
                     Emit_Address_Expression (Idx, Module_Name, Ok);
                     Emit_Raw ("), ", Ok);
                     Emit_Target (Idx, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                  elsif Current_Params (Param_Idx).Tag = Type_F32 then
                     Emit_Raw ("ALB_STORE_F32(Positive(", Ok);
                     Emit_Address_Expression (Idx, Module_Name, Ok);
                     Emit_Raw ("), ", Ok);
                     Emit_Target (Idx, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                  elsif Current_Params (Param_Idx).Tag = Type_F64 then
                     Emit_Raw ("ALB_STORE_F64(Positive(", Ok);
                     Emit_Address_Expression (Idx, Module_Name, Ok);
                     Emit_Raw ("), ", Ok);
                     Emit_Target (Idx, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                  else
                     case Current_Params (Param_Idx).Tag is
                        when Type_U8 =>
                           Emit_Raw ("ALB_STORE_U8(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ALB_U8(", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw ("));", Ok);
                        when Type_U16 =>
                           Emit_Raw ("ALB_STORE_U16(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ALB_U16(", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw ("));", Ok);
                        when Type_U32 =>
                           Emit_Raw ("ALB_STORE_U32(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ALB_U32(", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw ("));", Ok);
                        when Type_U64 =>
                           Emit_Raw ("ALB_STORE_U64(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw (");", Ok);
                        when Type_S8 =>
                           Emit_Raw ("ALB_STORE_I8(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ALB_I8(", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw ("));", Ok);
                        when Type_S16 =>
                           Emit_Raw ("ALB_STORE_I16(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ALB_I16(", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw ("));", Ok);
                        when Type_S32 =>
                           Emit_Raw ("ALB_STORE_I32(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ALB_I32(", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw ("));", Ok);
                        when Type_S64 =>
                           Emit_Raw ("ALB_STORE_I64(Positive(", Ok);
                           Emit_Address_Expression (Idx, Module_Name, Ok);
                           Emit_Raw ("), ALB_I64(", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw ("));", Ok);
                        when others =>
                           Emit_Raw ("null;", Ok);
                     end case;
                  end if;
                  Emit_Newline (Ok);
                  return;
               end if;

               Sym_Idx := Find_Symbol (Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name));
               if Sym_Idx = 0 or else Symbols (Sym_Idx).VAS_Offset = 0 then
                  return;
               end if;

               Struct_Name := Symbols (Sym_Idx).Struct_Name;
               Struct_Name_Len := Symbols (Sym_Idx).Struct_Name_Len;
               Emit_Indent (Ok);
               if Tree (Idx).Left_Child /= 0 and then Symbols (Sym_Idx).Kind = Sym_Array then
                  declare
                     Elem_Struct_Name : constant String :=
                       Name_Text (Struct_Name, Struct_Name_Len);
                  begin
                     if Elem_Struct_Name'Length > 0 then
                        Emit_Raw
                          (Struct_Store_Helper_Name (Elem_Struct_Name) &
                           "(Positive(",
                           Ok);
                     elsif Symbols (Sym_Idx).Tag = Type_Boolean then
                        Emit_Raw ("ALB_STORE_BOOL(Positive(", Ok);
                     elsif Symbols (Sym_Idx).Tag = Type_Binary then
                        Emit_Raw ("ALB_STORE_TEXT(Positive(", Ok);
                     elsif Symbols (Sym_Idx).Tag = Type_Pure then
                        Emit_Raw ("ALB_STORE_PURE(Positive(", Ok);
                     elsif Symbols (Sym_Idx).Tag = Type_F32 then
                        Emit_Raw ("ALB_STORE_F32(Positive(", Ok);
                     elsif Symbols (Sym_Idx).Tag = Type_F64 then
                        Emit_Raw ("ALB_STORE_F64(Positive(", Ok);
                     else
                        case Symbols (Sym_Idx).Tag is
                           when Type_U8  => Emit_Raw ("ALB_STORE_U8(Positive(", Ok);
                           when Type_U16 => Emit_Raw ("ALB_STORE_U16(Positive(", Ok);
                           when Type_U32 => Emit_Raw ("ALB_STORE_U32(Positive(", Ok);
                           when Type_U64 => Emit_Raw ("ALB_STORE_U64(Positive(", Ok);
                           when Type_S8  => Emit_Raw ("ALB_STORE_I8(Positive(", Ok);
                           when Type_S16 => Emit_Raw ("ALB_STORE_I16(Positive(", Ok);
                           when Type_S32 => Emit_Raw ("ALB_STORE_I32(Positive(", Ok);
                           when Type_S64 => Emit_Raw ("ALB_STORE_I64(Positive(", Ok);
                           when others   => Emit_Raw ("null; -- unsupported array sync", Ok);
                        end case;
                     end if;
                     if Ok then
                        Emit_Address_Expression (Idx, Module_Name, Ok);
                        if Elem_Struct_Name'Length > 0 then
                           Emit_Raw ("), ", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw (");", Ok);
                        elsif Symbols (Sym_Idx).Tag = Type_Boolean
                          or else Symbols (Sym_Idx).Tag = Type_Binary
                          or else Symbols (Sym_Idx).Tag = Type_Pure
                          or else Symbols (Sym_Idx).Tag = Type_F32
                          or else Symbols (Sym_Idx).Tag = Type_F64
                        then
                           Emit_Raw ("), ", Ok);
                           Emit_Target (Idx, Module_Name, Ok);
                           Emit_Raw (");", Ok);
                        else
                           case Symbols (Sym_Idx).Tag is
                              when Type_U8  => Emit_Raw ("), ALB_U8(", Ok);
                              when Type_U16 => Emit_Raw ("), ALB_U16(", Ok);
                              when Type_U32 => Emit_Raw ("), ALB_U32(", Ok);
                              when Type_U64 => Emit_Raw ("), ", Ok);
                              when Type_S8  => Emit_Raw ("), ALB_I8(", Ok);
                              when Type_S16 => Emit_Raw ("), ALB_I16(", Ok);
                              when Type_S32 => Emit_Raw ("), ALB_I32(", Ok);
                              when Type_S64 => Emit_Raw ("), ALB_I64(", Ok);
                              when others   => null;
                           end case;
                           Emit_Target (Idx, Module_Name, Ok);
                           if Symbols (Sym_Idx).Tag /= Type_U64 then
                              Emit_Raw (")", Ok);
                           end if;
                           Emit_Raw (");", Ok);
                        end if;
                     end if;
                  end;
               elsif Struct_Name_Len > 0 then
                  Emit_Raw
                    (Struct_Store_Helper_Name
                       (Name_Text (Struct_Name, Struct_Name_Len)) &
                     "(Positive(",
                     Ok);
                  Emit_Address_Expression (Idx, Module_Name, Ok);
                  Emit_Raw ("), ", Ok);
                  Emit_Target (Idx, Module_Name, Ok);
                  Emit_Raw (");", Ok);
               elsif Symbols (Sym_Idx).Tag = Type_Boolean then
                  Emit_Raw ("ALB_STORE_BOOL(Positive(", Ok);
                  Emit_Address_Expression (Idx, Module_Name, Ok);
                  Emit_Raw ("), ", Ok);
                  Emit_Target (Idx, Module_Name, Ok);
                  Emit_Raw (");", Ok);
               elsif Symbols (Sym_Idx).Tag = Type_Binary then
                  Emit_Raw ("ALB_STORE_TEXT(Positive(", Ok);
                  Emit_Address_Expression (Idx, Module_Name, Ok);
                  Emit_Raw ("), ", Ok);
                  Emit_Target (Idx, Module_Name, Ok);
                  Emit_Raw (");", Ok);
               elsif Symbols (Sym_Idx).Tag = Type_Pure then
                  Emit_Raw ("ALB_STORE_PURE(Positive(", Ok);
                  Emit_Address_Expression (Idx, Module_Name, Ok);
                  Emit_Raw ("), ", Ok);
                  Emit_Target (Idx, Module_Name, Ok);
                  Emit_Raw (");", Ok);
               elsif Symbols (Sym_Idx).Tag = Type_F32 then
                  Emit_Raw ("ALB_STORE_F32(Positive(", Ok);
                  Emit_Address_Expression (Idx, Module_Name, Ok);
                  Emit_Raw ("), ", Ok);
                  Emit_Target (Idx, Module_Name, Ok);
                  Emit_Raw (");", Ok);
               elsif Symbols (Sym_Idx).Tag = Type_F64 then
                  Emit_Raw ("ALB_STORE_F64(Positive(", Ok);
                  Emit_Address_Expression (Idx, Module_Name, Ok);
                  Emit_Raw ("), ", Ok);
                  Emit_Target (Idx, Module_Name, Ok);
                  Emit_Raw (");", Ok);
               else
                  case Symbols (Sym_Idx).Tag is
                     when Type_U8  => Emit_Raw ("ALB_STORE_U8(Positive(", Ok);
                     when Type_U16 => Emit_Raw ("ALB_STORE_U16(Positive(", Ok);
                     when Type_U32 => Emit_Raw ("ALB_STORE_U32(Positive(", Ok);
                     when Type_U64 => Emit_Raw ("ALB_STORE_U64(Positive(", Ok);
                     when Type_S8  => Emit_Raw ("ALB_STORE_I8(Positive(", Ok);
                     when Type_S16 => Emit_Raw ("ALB_STORE_I16(Positive(", Ok);
                     when Type_S32 => Emit_Raw ("ALB_STORE_I32(Positive(", Ok);
                     when Type_S64 => Emit_Raw ("ALB_STORE_I64(Positive(", Ok);
                     when others   => Emit_Raw ("null;", Ok);
                  end case;
                  if Ok then
                     Emit_Address_Expression (Idx, Module_Name, Ok);
                     case Symbols (Sym_Idx).Tag is
                        when Type_U8  => Emit_Raw ("), ALB_U8(", Ok);
                        when Type_U16 => Emit_Raw ("), ALB_U16(", Ok);
                        when Type_U32 => Emit_Raw ("), ALB_U32(", Ok);
                        when Type_U64 => Emit_Raw ("), ", Ok);
                        when Type_S8  => Emit_Raw ("), ALB_I8(", Ok);
                        when Type_S16 => Emit_Raw ("), ALB_I16(", Ok);
                        when Type_S32 => Emit_Raw ("), ALB_I32(", Ok);
                        when Type_S64 => Emit_Raw ("), ALB_I64(", Ok);
                        when others   => null;
                     end case;
                     Emit_Target (Idx, Module_Name, Ok);
                     if Symbols (Sym_Idx).Tag /= Type_U64 then
                        Emit_Raw (")", Ok);
                     end if;
                     Emit_Raw (");", Ok);
                  end if;
               end if;
               Emit_Newline (Ok);

            when AST_Member_Expr =>
               declare
                  Current_Struct_Name : constant String :=
                    Struct_Name_Of_Node (Tree (Idx).Left_Child, Module_Name);
               begin
                  Field_Idx :=
                    Find_Struct_Field
                      (Current_Struct_Name,
                       Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                  if Field_Idx > 0 then
                     Emit_Indent (Ok);
                     case Struct_Fields (Field_Idx).Tag is
                        when Type_Boolean =>
                           Emit_Raw ("ALB_STORE_BOOL(Positive(", Ok);
                        when Type_Binary =>
                           Emit_Raw ("ALB_STORE_TEXT(Positive(", Ok);
                        when Type_Pure =>
                           Emit_Raw ("ALB_STORE_PURE(Positive(", Ok);
                        when Type_F32 =>
                           Emit_Raw ("ALB_STORE_F32(Positive(", Ok);
                        when Type_F64 =>
                           Emit_Raw ("ALB_STORE_F64(Positive(", Ok);
                        when Type_U8 =>
                           Emit_Raw ("ALB_STORE_U8(Positive(", Ok);
                        when Type_U16 =>
                           Emit_Raw ("ALB_STORE_U16(Positive(", Ok);
                        when Type_U32 =>
                           Emit_Raw ("ALB_STORE_U32(Positive(", Ok);
                        when Type_U64 =>
                           Emit_Raw ("ALB_STORE_U64(Positive(", Ok);
                        when Type_S8 =>
                           Emit_Raw ("ALB_STORE_I8(Positive(", Ok);
                        when Type_S16 =>
                           Emit_Raw ("ALB_STORE_I16(Positive(", Ok);
                        when Type_S32 =>
                           Emit_Raw ("ALB_STORE_I32(Positive(", Ok);
                        when Type_S64 =>
                           Emit_Raw ("ALB_STORE_I64(Positive(", Ok);
                        when others =>
                           Emit_Raw ("null;", Ok);
                     end case;
                     if Ok then
                        Emit_Address_Expression (Idx, Module_Name, Ok);
                        if Struct_Fields (Field_Idx).Tag = Type_Boolean
                          or else Struct_Fields (Field_Idx).Tag = Type_Binary
                          or else Struct_Fields (Field_Idx).Tag = Type_Pure
                          or else Struct_Fields (Field_Idx).Tag = Type_F32
                          or else Struct_Fields (Field_Idx).Tag = Type_F64
                        then
                           Emit_Raw ("), ", Ok);
                        else
                           case Struct_Fields (Field_Idx).Tag is
                              when Type_U8  => Emit_Raw ("), ALB_U8(", Ok);
                              when Type_U16 => Emit_Raw ("), ALB_U16(", Ok);
                              when Type_U32 => Emit_Raw ("), ALB_U32(", Ok);
                              when Type_U64 => Emit_Raw ("), ", Ok);
                              when Type_S8  => Emit_Raw ("), ALB_I8(", Ok);
                              when Type_S16 => Emit_Raw ("), ALB_I16(", Ok);
                              when Type_S32 => Emit_Raw ("), ALB_I32(", Ok);
                              when Type_S64 => Emit_Raw ("), ALB_I64(", Ok);
                              when others   => null;
                           end case;
                        end if;
                        Emit_Target (Idx, Module_Name, Ok);
                        if Struct_Fields (Field_Idx).Tag = Type_Boolean
                          or else Struct_Fields (Field_Idx).Tag = Type_Binary
                          or else Struct_Fields (Field_Idx).Tag = Type_Pure
                          or else Struct_Fields (Field_Idx).Tag = Type_F32
                          or else Struct_Fields (Field_Idx).Tag = Type_F64
                          or else Struct_Fields (Field_Idx).Tag = Type_U64
                        then
                           Emit_Raw (");", Ok);
                        else
                           Emit_Raw ("));", Ok);
                        end if;
                        Emit_Newline (Ok);
                     end if;
                  end if;
               end;

            when others =>
               null;
         end case;
      end Emit_Sync_Target_To_VAS;

      procedure Emit_Address_Helpers
        (Ok           : in out Boolean;
         Sync_Globals : Boolean := True)
      is
      begin
         if not Need_Address_Helpers then
            return;
         end if;
         Emit_Line ("function ALBA_Deref_Address (Address : Positive) return U64 is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("return ALB_DEREF(Address);", Ok);
         Decrease_Indent;
         Emit_Line ("end ALBA_Deref_Address;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("function ALBA_Peek_Address (Address : Positive) return U64 is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("return ALB_PEEK(Address);", Ok);
         Decrease_Indent;
         Emit_Line ("end ALBA_Peek_Address;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALBA_Poke_Address (Address : Positive; Raw_Value : U64) is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         if Sync_Globals then
         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Symbol_Is_Static_Addressable (I)
              and then Symbols (I).VAS_Offset > 0
            then
               declare
                  Name        : constant String :=
                    Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
                  Base        : constant Natural := Symbols (I).VAS_Offset;
                  Elem_Size   : constant Natural :=
                    Natural'Max (1, Symbol_Element_Size_Bytes (I));
                  Total       : constant Natural := Symbol_Size_Bytes (I);
                  Struct_Name : constant String :=
                    Name_Text (Symbols (I).Struct_Name, Symbols (I).Struct_Name_Len);
                  Elem_Count  : constant Natural :=
                    (if Elem_Size = 0 then 0 else Natural'Max (1, Total / Elem_Size));
               begin
                  Emit_Line
                    ("if Address < " &
                     Trim_Image (Integer (Base + Total)) &
                     " and then (Address + 7) >= " &
                     Trim_Image (Integer (Base)) &
                     " then",
                     Ok);
                  Increase_Indent;
                        Emit_Line ("ALB_POKE(Address, Raw_Value);", Ok);
                  if Symbols (I).Kind = Sym_Array then
                     Emit_Line
                       ("for ALBA_Reload_Elem_" & Trim_Image (Integer (I)) &
                        " in 0 .. " & Trim_Image (Integer (Elem_Count - 1)) & " loop",
                        Ok);
                     Increase_Indent;
                     Emit_Line ("declare", Ok);
                     Increase_Indent;
                     Emit_Line
                       ("Element_Base : constant Natural := " &
                        Trim_Image (Integer (Base)) & " + (ALBA_Reload_Elem_" &
                        Trim_Image (Integer (I)) & " * " &
                        Trim_Image (Integer (Elem_Size)) & ");",
                        Ok);
                     Decrease_Indent;
                     Emit_Line ("begin", Ok);
                     Increase_Indent;
                     Emit_Line
                       ("if Address < Element_Base + " &
                        Trim_Image (Integer (Elem_Size)) &
                        " and then (Address + 7) >= Element_Base then",
                        Ok);
                     Increase_Indent;
                     Emit_Assign_From_VAS_Text
                       (Name & "(Positive(ALBA_Reload_Elem_" &
                        Trim_Image (Integer (I)) & " + 1))",
                        "Element_Base",
                        Symbols (I).Tag,
                        Struct_Name,
                        Ok);
                     Decrease_Indent;
                     Emit_Line ("end if;", Ok);
                     Decrease_Indent;
                     Emit_Line ("end;", Ok);
                     Decrease_Indent;
                     Emit_Line ("end loop;", Ok);
                  else
                     Emit_Assign_From_VAS_Text
                       (Name,
                        Trim_Image (Integer (Base)),
                        Symbols (I).Tag,
                        Struct_Name,
                        Ok);
                  end if;
                  Emit_Line ("return;", Ok);
                  Decrease_Indent;
                  Emit_Line ("end if;", Ok);
               end;
            end if;
         end loop;
         end if;
         Emit_Line ("ALB_POKE(Address, Raw_Value);", Ok);
         Decrease_Indent;
         Emit_Line ("end ALBA_Poke_Address;", Ok);
         Emit_Newline (Ok);
      end Emit_Address_Helpers;

      function User_Routine_Call_Prefix
        (Name_Node   : Node_Index;
         Module_Name : String) return String
      is
      begin
         if Routine_Count > 0
           and then User_Unit_Name_Len > 0
           and then Resolve_Routine_Node (Name_Node, Module_Name) /= 0
         then
            return User_Unit_Name_Text & ".";
         end if;
         return "";
      end User_Routine_Call_Prefix;

      procedure Scan_Expr_Features (Idx : Node_Index) is
         Tok : Token;
      begin
         if Idx = 0 then
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Rnd_Expr =>
               Need_Rnd_Runtime := True;
               Record_Critical_Violation ("RND");

            when AST_Predict_Markov_Stmt =>
               Need_Markov_Runtime := True;
               Record_Critical_Violation ("MARKOV");

            when AST_Infer_Network_Stmt =>
               Need_NN_Runtime := True;

            when AST_Train_Network_Stmt =>
               Need_NN_Runtime := True;
               Record_Critical_Violation ("NEURAL_TRAIN");

            when AST_Network_Listen_Stmt | AST_Network_Receive_Stmt |
                 AST_Network_Send_Stmt | AST_Network_Close_Stmt =>
               Need_Net_Runtime := True;

            when AST_Try_Stmt | AST_Throw_Stmt =>
               Need_User_Exception := True;

            when AST_BinOp =>
               if Tree (Idx).Token_Index > 0 then
                  Tok := Tokens (Tree (Idx).Token_Index);
                  if Tok.Kind = TOK_POW then
                     Need_Pow_Runtime := True;
                  end if;
               end if;
               Scan_Expr_Features (Tree (Idx).Left_Child);
               Scan_Expr_Features (Tree (Idx).Right_Child);

            when AST_Not | AST_Unary_Minus =>
               Scan_Expr_Features (Tree (Idx).Left_Child);

            when AST_Func_Call =>
               if Tree (Idx).Left_Child /= 0
                 and then Tree (Tree (Idx).Left_Child).Kind = AST_Var_Expr
                 and then Tree (Tree (Idx).Left_Child).Token_Index > 0
               then
                  declare
                     Call_Name : constant String :=
                       Upper_Safe_Name
                         (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
                  begin
                     if Call_Name in "SIN" | "COS" | "SQRT" | "EXP" | "LOG" then
                        Need_F64_Runtime := True;
                        Record_Critical_Violation ("FLOAT_MATH");
                     elsif Call_Name = "RND" or else Call_Name = "CHOOSE" then
                        Need_Rnd_Runtime := True;
                        Record_Critical_Violation ("RND");
                     end if;
                  end;
               end if;
               Scan_Expr_Features (Tree (Idx).Right_Child);

            when AST_Let_Stmt =>
               Scan_Expr_Features (Tree (Idx).Right_Child);

            when AST_Peek_Expr | AST_Deref_Expr | AST_AddressOf | AST_Ref_Expr =>
               Need_Address_Helpers := True;

            when others =>
               declare
                  Curr : Node_Index := Tree (Idx).Left_Child;
               begin
                  while Curr /= 0 loop
                     Scan_Expr_Features (Curr);
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
                  Curr := Tree (Idx).Right_Child;
                  while Curr /= 0 loop
                     Scan_Expr_Features (Curr);
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end;
         end case;
      end Scan_Expr_Features;

      function Resolve_Call_Name
        (Name_Node   : Node_Index;
         Module_Name : String) return String
      is
      begin
         if Name_Node = 0 then
            return "";
         elsif Tree (Name_Node).Kind = AST_Var_Expr then
            declare
               Raw_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Safe_Call : constant String := Safe_Name (Raw_Name);
               Upper_Call : constant String := Upper_Safe_Name (Raw_Name);
            begin
               if Tag_From_Name (Upper_Call) /= Type_None
                 or else Upper_Call = "PURE"
                 or else Upper_Call = "LEN"
                 or else Upper_Call = "OPEN"
                 or else Upper_Call = "READ"
                 or else Upper_Call = "READLINE"
                 or else Upper_Call = "LEFT"
                 or else Upper_Call = "RIGHT"
                 or else Upper_Call = "MID"
                 or else Upper_Call = "CHR"
                 or else Upper_Call = "CONCAT"
                 or else Upper_Call = "PURE_ADD"
                 or else Upper_Call = "PURE_SUB"
                 or else Upper_Call = "PURE_MUL"
                 or else Upper_Call = "PURE_DIV"
                 or else Upper_Call = "PURE_POW"
                 or else Upper_Call = "PURE_NUM"
                 or else Upper_Call = "PURE_DEN"
                 or else Upper_Call = "PRINT_PURE"
                 or else Upper_Call = "COLLIDE_RECT"
                 or else Upper_Call = "PROVE"
                 or else Upper_Call = "RND"
                 or else Upper_Call = "CHOOSE"
                 or else Upper_Call = "FIND"
                 or else Upper_Call = "SIZEOF"
                 or else Upper_Call = "OFFSETOF"
                 or else Upper_Call = "TYPEOF"
                 or else Upper_Call = "SIN"
                 or else Upper_Call = "COS"
                 or else Upper_Call = "SQRT"
                 or else Upper_Call = "EXP"
                 or else Upper_Call = "HW8"
                 or else Upper_Call = "HW16"
                 or else Upper_Call = "HW32"
                 or else Upper_Call = "U128"
               then
                  return Safe_Call;
               else
                  return Resolve_Name (Raw_Name, Module_Name);
               end if;
            end;
         elsif Tree (Name_Node).Kind = AST_Member_Expr
           and then Tree (Tree (Name_Node).Left_Child).Kind = AST_Var_Expr
           and then Is_Module_Name (Safe_Name (Raw_Lexeme (Tree (Tree (Name_Node).Left_Child).Token_Index)))
         then
            return Qualify_Name
              (Safe_Name (Raw_Lexeme (Tree (Tree (Name_Node).Left_Child).Token_Index)),
               Raw_Lexeme (Tree (Tree (Name_Node).Right_Child).Token_Index));
         else
            return Resolve_Name (Raw_Lexeme (Tree (Name_Node).Token_Index), Module_Name);
         end if;
      end Resolve_Call_Name;

      procedure Emit_Generic_Function_Call
        (Call_Name   : String;
         Name_Node   : Node_Index;
         First_Arg   : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Curr      : Node_Index := First_Arg;
         First     : Boolean := True;
         Param_Pos : Positive := 1;
      begin
         if Curr = 0 then
            Emit_Raw (User_Routine_Call_Prefix (Name_Node, Module_Name) & Call_Name, Ok);
            return;
         end if;

         Emit_Raw (User_Routine_Call_Prefix (Name_Node, Module_Name) & Call_Name & "(", Ok);
         for Guard in 1 .. Max_Params loop
            exit when Curr = 0;
            if not First then
               Emit_Raw (", ", Ok);
            end if;

            declare
               Param_Tag : constant ALB_Type_Tag :=
                 Resolve_Routine_Param_Tag (Name_Node, Module_Name, Param_Pos);
            begin
               if Param_Tag = Type_Binary then
                  Emit_Text_Expression (Curr, Module_Name, Ok);
               elsif Param_Tag /= Type_None then
                  Emit_Assigned_Expression (Curr, Module_Name, Param_Tag, Ok);
               elsif Infer_Type (Curr, Module_Name) = Type_Binary then
                  Emit_Text_Expression (Curr, Module_Name, Ok);
               else
                  Emit_Expression (Curr, Module_Name, Type_None, False, Ok);
               end if;
            end;

            Curr := Tree (Curr).Next_Sibling;
            First := False;
            Param_Pos := Param_Pos + 1;
         end loop;
         Emit_Raw (")", Ok);
      end Emit_Generic_Function_Call;

      procedure Emit_Builtin_Function_Call
        (Builtin_Name : String;
         Name_Node    : Node_Index;
         Curr         : in out Node_Index;
         Module_Name  : String;
         Expected     : ALB_Type_Tag;
         Ok           : in out Boolean;
         Handled      : out Boolean) is
      begin
         Handled := True;

         if Builtin_Name = "PURE" or else Builtin_Name = "RATIONAL" then
            Emit_Raw ("ALB_PURE(Long_Integer(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw ("), Long_Integer(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            else
               Emit_Raw ("1", Ok);
            end if;
            Emit_Raw ("))", Ok);
         elsif Builtin_Name = "LEN" then
            Emit_Raw ("ALB_TEXT_LENGTH(", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
            else
               Emit_Raw ("ALB_STR("""")", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "OPEN" then
            Emit_Raw ("ALBA_IO.File_Open(", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("ALB_STR("""")", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
            else
               Emit_Raw ("ALB_STR(""r"")", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "READ" then
            Emit_Raw ("ALBA_IO.File_Read(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U64, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U64, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "READLINE" then
            Emit_Raw ("ALBA_IO.Readline", Ok);
         elsif Builtin_Name = "LEFT" then
            Emit_Raw ("ALB_LEFT(", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("ALB_STR("""")", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "RIGHT" then
            Emit_Raw ("ALB_RIGHT(", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("ALB_STR("""")", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "MID" then
            Emit_Raw ("ALB_MID(", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("ALB_STR("""")", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U32, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("1", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "CHR" then
            Emit_Raw ("ALB_STR ((1 => Character'Val (Integer (", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (" mod 256))))", Ok);
         elsif Builtin_Name = "CONCAT" then
            Emit_Raw ("ALB_CONCAT(", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("ALB_STR("""")", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Text_Expression (Curr, Module_Name, Ok);
            else
               Emit_Raw ("ALB_STR("""")", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PURE_ADD" then
            Emit_Raw ("ALB_PURE_ADD(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(0), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PURE_SUB" then
            Emit_Raw ("ALB_PURE_SUB(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(0), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PURE_MUL" then
            Emit_Raw ("ALB_PURE_MUL(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(0), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PURE_DIV" then
            Emit_Raw ("ALB_PURE_DIV(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(1), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PURE_POW" then
            Emit_Raw ("ALB_PURE_POW(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("ALB_PURE(Long_Integer(0), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(1), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PURE_NUM" then
            Emit_Raw ("ALB_PURE_NUM(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(0), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PURE_DEN" then
            Emit_Raw ("ALB_PURE_DEN(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(1), Long_Integer(1))", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PRINT_PURE" then
            Emit_Raw ("ALBA_IO.Print_Text(ALB_IMAGE(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_Pure, False, Ok);
            else
               Emit_Raw ("ALB_PURE(Long_Integer(0), Long_Integer(1))", Ok);
            end if;
            Emit_Raw ("), True)", Ok);
         elsif Builtin_Name = "COLLIDE_RECT" then
            Emit_Raw ("ALB_COLLIDE_RECT(", Ok);
            for I in 1 .. 8 loop
               if Curr /= 0 then
                  Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
                  Curr := Tree (Curr).Next_Sibling;
               else
                  Emit_Raw ("0", Ok);
               end if;
               if I < 8 then
                  Emit_Raw (", ", Ok);
               end if;
            end loop;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "PROVE" then
            Emit_Raw ("False", Ok);
         elsif Builtin_Name = "RND" then
            Emit_Raw ("ALB_RND(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U64, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "CHOOSE" then
            Emit_Raw ("ALB_CHOOSE(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U64, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U64, False, Ok);
               Curr := Tree (Curr).Next_Sibling;
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (", ", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U64, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "FIND" then
            Emit_Raw ("0", Ok);
         elsif Builtin_Name = "SIZEOF" then
            if Curr /= 0 then
               Emit_Raw
                 (Trim_Image
                    (Integer (Type_Size_Bytes (Infer_Type (Curr, Module_Name)))),
                  Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
         elsif Builtin_Name = "OFFSETOF" then
            declare
               Struct_Name : constant String :=
                 (if Curr /= 0 and then Tree (Curr).Token_Index > 0
                  then Raw_Lexeme (Tree (Curr).Token_Index)
                  else "");
               Field_Node  : constant Node_Index :=
                 (if Curr /= 0 then Tree (Curr).Next_Sibling else 0);
               Field_Name  : constant String :=
                 (if Field_Node /= 0 and then Tree (Field_Node).Token_Index > 0
                  then Raw_Lexeme (Tree (Field_Node).Token_Index)
                  else "");
               Field_Idx   : constant Natural :=
                 Find_Struct_Field (Struct_Name, Field_Name);
            begin
               if Field_Idx > 0 then
                  Emit_Raw
                    (Trim_Image (Integer (Struct_Fields (Field_Idx).Offset_Bytes)),
                     Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
            end;
         elsif Builtin_Name = "TYPEOF" then
            Emit_Raw
              ("ALB_STR(""" &
               (if Curr /= 0
                then Type_Name_Text (Infer_Type (Curr, Module_Name))
                else "U64") &
               """)",
               Ok);
         elsif Builtin_Name = "SIN" then
            Emit_Raw ("ALB_SIN(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "COS" then
            Emit_Raw ("ALB_COS(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "SQRT" then
            Emit_Raw ("ALB_SQRT(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "EXP" then
            Emit_Raw ("ALB_EXP(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Tag_From_Name (Builtin_Name) /= Type_None then
            declare
               Target_Tag : constant ALB_Type_Tag := Tag_From_Name (Builtin_Name);
               Source_Tag : constant ALB_Type_Tag :=
                 (if Curr /= 0 then Infer_Type (Curr, Module_Name) else Type_None);
               Needs_Cast : constant Boolean :=
                 Needs_Numeric_Cast (Expected, Target_Tag);
            begin
               if Needs_Cast then
                  Emit_Raw (Ada_Type_Name (Expected) & "(", Ok);
               end if;
               if Curr /= 0 then
                  Emit_Converted_Expression
                    (Curr, Module_Name, Source_Tag, Target_Tag, Ok);
               else
                  Emit_Raw (Ada_Type_Name (Target_Tag) & "(0)", Ok);
               end if;
               if Needs_Cast then
                  Emit_Raw (")", Ok);
               end if;
            end;
         elsif Builtin_Name = "HW8" then
            Emit_Raw ("S8(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S8, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "HW16" then
            Emit_Raw ("S16(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S16, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "HW32" then
            Emit_Raw ("S32(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         elsif Builtin_Name = "U128" then
            Emit_Raw ("U64(", Ok);
            if Curr /= 0 then
               Emit_Expression (Curr, Module_Name, Type_U64, False, Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            Emit_Raw (")", Ok);
         else
            Handled := False;
         end if;
      end Emit_Builtin_Function_Call;

      procedure Emit_Function_Call
        (Idx         : Node_Index;
         Module_Name : String := "";
         Expected    : ALB_Type_Tag := Type_None;
         As_Text     : Boolean := False;
         Ok          : in out Boolean) is
         Name_Node : constant Node_Index := Tree (Idx).Left_Child;
         Arg_Node  : Node_Index := Tree (Idx).Right_Child;
         Curr      : Node_Index := 0;
         First     : Boolean := True;
      begin
         if Name_Node = 0 then
            Emit_Raw ("0", Ok);
            return;
         end if;

         if Arg_Node /= 0 and then Tree (Arg_Node).Kind = AST_Arg_List then
            Curr := Tree (Arg_Node).Left_Child;
         else
            Curr := Arg_Node;
         end if;

         declare
            Call_Name    : constant String := Resolve_Call_Name (Name_Node, Module_Name);
            Builtin_Name : constant String := Upper_Safe_Name (Call_Name);
            Handled      : Boolean := False;
         begin
            Emit_Builtin_Function_Call
              (Builtin_Name,
               Name_Node,
               Curr,
               Module_Name,
               Expected,
               Ok,
               Handled);
            if not Handled then
               Emit_Generic_Function_Call
                 (Call_Name,
                  Name_Node,
                  Curr,
                  Module_Name,
                  Ok);
            end if;
         end;
      end Emit_Function_Call;

      function Pure_Graphics_Source
        (Idx         : Node_Index;
         Module_Name : String) return Node_Index
      is
         Name_Node : Node_Index := 0;
         Arg_Node  : Node_Index := 0;
      begin
         if Idx = 0 then
            return 0;
         end if;

         if Infer_Type (Idx, Module_Name) = Type_Pure then
            return Idx;
         end if;

         if Tree (Idx).Kind /= AST_Func_Call then
            return 0;
         end if;

         Name_Node := Tree (Idx).Left_Child;
         if Name_Node = 0 or else Tree (Name_Node).Kind /= AST_Var_Expr then
            return 0;
         end if;

         if Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)) /= "PURE_NUM" then
            return 0;
         end if;

         Arg_Node := Tree (Idx).Right_Child;
         if Arg_Node > 0 and then Tree (Arg_Node).Kind = AST_Arg_List then
            Arg_Node := Tree (Arg_Node).Left_Child;
         end if;

         if Arg_Node = 0 or else Infer_Type (Arg_Node, Module_Name) /= Type_Pure then
            return 0;
         end if;

         return Arg_Node;
      end Pure_Graphics_Source;

      procedure Emit_Pure_Integer_Value
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
      begin
         -- Screen coordinates need the integer value of a PURE fraction,
         -- not the raw numerator returned by ALB_PURE_NUM.
         Emit_Raw ("S32(Long_Integer(ALB_PURE_NUM(", Ok);
         Emit_Expression (Idx, Module_Name, Type_Pure, False, Ok);
         Emit_Raw (")) / Long_Integer(ALB_PURE_DEN(", Ok);
         Emit_Expression (Idx, Module_Name, Type_Pure, False, Ok);
         Emit_Raw (")))", Ok);
      end Emit_Pure_Integer_Value;

      procedure Emit_Graphics_Coordinate
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Pure_Node : constant Node_Index := Pure_Graphics_Source (Idx, Module_Name);
         Tok       : Token;
      begin
         if not Ok then
            return;
         end if;

         if Pure_Node /= 0 then
            Emit_Pure_Integer_Value (Pure_Node, Module_Name, Ok);
         elsif Idx /= 0
           and then Tree (Idx).Kind = AST_BinOp
           and then Tree (Idx).Token_Index > 0
         then
            Tok := Tokens (Tree (Idx).Token_Index);
            if Tok.Kind = TOK_MINUS and then Tree (Idx).Left_Child = 0 then
               Emit_Raw ("(-", Ok);
               Emit_Graphics_Coordinate (Tree (Idx).Right_Child, Module_Name, Ok);
               Emit_Raw (")", Ok);
            else
               Emit_Raw ("(", Ok);
               Emit_Graphics_Coordinate (Tree (Idx).Left_Child, Module_Name, Ok);
               case Tok.Kind is
                  when TOK_PLUS  => Emit_Raw (" + ", Ok);
                  when TOK_MINUS => Emit_Raw (" - ", Ok);
                  when TOK_MUL   => Emit_Raw (" * ", Ok);
                  when TOK_DIV   => Emit_Raw (" / ", Ok);
                  when others    => Emit_Raw (" + ", Ok);
               end case;
               Emit_Graphics_Coordinate (Tree (Idx).Right_Child, Module_Name, Ok);
               Emit_Raw (")", Ok);
            end if;
         else
            Emit_Expression (Idx, Module_Name, Type_S32, False, Ok);
         end if;
      end Emit_Graphics_Coordinate;

      procedure Emit_Expression
        (Idx         : Node_Index;
         Module_Name : String := "";
         Expected    : ALB_Type_Tag := Type_None;
         As_Text     : Boolean := False;
         Ok          : in out Boolean) is
         Tok     : Token;
         Sym_Idx : Natural := 0;
         PF_Idx  : Natural := 0;
         Curr    : Node_Index := 0;
      begin
         if not Ok then
            return;
         end if;

         if Idx = 0 then
            if As_Text or else Expected = Type_Binary then
               Emit_Raw ("ALB_STR("""")", Ok);
            elsif Expected = Type_Boolean then
               Emit_Raw ("False", Ok);
            else
               Emit_Raw ("0", Ok);
            end if;
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Const_Ref =>
               declare
                  Const_Node : constant Node_Index :=
                    Find_Const_Expr (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
                  Static_Value : S64 := 0;
                  Static_Found : Boolean := False;
               begin
                  if Const_Node /= 0 then
                     Emit_Expression (Const_Node, Module_Name, Expected, As_Text, Ok);
                  else
                     Lookup_Const_Static_Value
                       (Raw_Lexeme (Tree (Idx).Token_Index),
                        Module_Name,
                        "",
                        Static_Value,
                        Static_Found);
                     if Static_Found then
                        Emit_Raw (Trim_Image (Integer (Static_Value)), Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                  end if;
               end;

            when AST_Number_Expr =>
               if Infer_Type (Idx, Module_Name) = Type_F64 then
                  if As_Text or else Expected = Type_Binary then
                     Emit_Raw
                       ("ALB_IMAGE_F64(F64(" &
                        Ada_F64_Literal (Raw_Lexeme (Tree (Idx).Token_Index)) &
                        "))",
                        Ok);
                  else
                     Emit_Raw
                       (Ada_F64_Literal (Raw_Lexeme (Tree (Idx).Token_Index)),
                        Ok);
                  end if;
               elsif As_Text or else Expected = Type_Binary then
                  Emit_Raw
                    ("ALB_IMAGE(Integer(" & Raw_Lexeme (Tree (Idx).Token_Index) & "))",
                     Ok);
               else
                  Emit_Raw (Raw_Lexeme (Tree (Idx).Token_Index), Ok);
               end if;

            when AST_Hex_Expr =>
               declare
                  Lex : constant String := Raw_Lexeme (Tree (Idx).Token_Index);
               begin
                  if Lex'Length > 1 then
                     if As_Text or else Expected = Type_Binary then
                        Emit_Raw
                          ("ALB_IMAGE(U64(16#" & Lex (Lex'First + 1 .. Lex'Last) & "#))",
                           Ok);
                     else
                        Emit_Raw ("16#" & Lex (Lex'First + 1 .. Lex'Last) & "#", Ok);
                     end if;
                  else
                     if As_Text or else Expected = Type_Binary then
                        Emit_Raw ("ALB_IMAGE(Integer(0))", Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                  end if;
               end;

            when AST_Bin_Expr =>
               declare
                  Lex : constant String := Raw_Lexeme (Tree (Idx).Token_Index);
               begin
                  if Lex'Length > 1 then
                     if As_Text or else Expected = Type_Binary then
                        Emit_Raw
                          ("ALB_IMAGE(U64(2#" & Lex (Lex'First + 1 .. Lex'Last) & "#))",
                           Ok);
                     else
                        Emit_Raw ("2#" & Lex (Lex'First + 1 .. Lex'Last) & "#", Ok);
                     end if;
                  else
                     if As_Text or else Expected = Type_Binary then
                        Emit_Raw ("ALB_IMAGE(Integer(0))", Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                  end if;
               end;

            when AST_Octal_Expr =>
               declare
                  Lex : constant String := Raw_Lexeme (Tree (Idx).Token_Index);
               begin
                  if Lex'Length > 1 then
                     if As_Text or else Expected = Type_Binary then
                        Emit_Raw
                          ("ALB_IMAGE(U64(8#" & Lex (Lex'First + 1 .. Lex'Last) & "#))",
                           Ok);
                     else
                        Emit_Raw ("8#" & Lex (Lex'First + 1 .. Lex'Last) & "#", Ok);
                     end if;
                  else
                     if As_Text or else Expected = Type_Binary then
                        Emit_Raw ("ALB_IMAGE(Integer(0))", Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                  end if;
               end;

            when AST_String_Expr =>
               if As_Text or else Expected = Type_Binary then
                  Emit_Raw ("ALB_STR(""" & Strip_String_Literal (Raw_Lexeme (Tree (Idx).Token_Index)) & """)", Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;

            when AST_True =>
               if As_Text or else Expected = Type_Binary then
                  Emit_Raw ("ALB_IMAGE(True)", Ok);
               else
                  Emit_Raw ("True", Ok);
               end if;

            when AST_False =>
               if As_Text or else Expected = Type_Binary then
                  Emit_Raw ("ALB_IMAGE(False)", Ok);
               else
                  Emit_Raw ("False", Ok);
               end if;

            when AST_Var_Expr | AST_Logic_Var =>
               declare
                  Raw_Name : constant String := Raw_Lexeme (Tree (Idx).Token_Index);
                  Lex : constant String :=
                    Resolve_Name (Raw_Name, Module_Name);
                  Const_Node : constant Node_Index :=
                    Find_Const_Expr (Raw_Name, Module_Name);
                  Static_Value : S64 := 0;
                  Static_Found : Boolean := False;
                  Actual_Tag : ALB_Type_Tag := Type_None;
               begin
                  Sym_Idx := Find_Symbol (Lex);
                  for I in 1 .. Current_Param_Count loop
                     if Current_Params (I).Active
                       and then Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len) = Safe_Name (Raw_Name)
                     then
                        Actual_Tag := Current_Params (I).Tag;
                     end if;
                  end loop;
                  if Actual_Tag = Type_None and then Sym_Idx > 0 then
                     Actual_Tag := Symbols (Sym_Idx).Tag;
                  end if;
                  if Actual_Tag = Type_None and then Sym_Idx = 0 and then Const_Node /= 0 then
                     Emit_Expression (Const_Node, Module_Name, Expected, As_Text, Ok);
                  elsif Actual_Tag = Type_None and then Sym_Idx = 0 then
                     Lookup_Const_Static_Value
                       (Raw_Name,
                        Module_Name,
                        "",
                        Static_Value,
                        Static_Found);
                     if Static_Found then
                        Emit_Raw (Trim_Image (Integer (Static_Value)), Ok);
                     else
                        Emit_Raw (Lex, Ok);
                     end if;
                  elsif Tree (Idx).Left_Child /= 0 and then Sym_Idx > 0 and then Symbols (Sym_Idx).Kind = Sym_Array then
                     declare
                        Needs_Cast : constant Boolean :=
                          Actual_Tag /= Type_None
                          and then Expected /= Type_None
                          and then Expected /= Actual_Tag
                          and then Expected /= Type_Boolean
                          and then Actual_Tag /= Type_Boolean
                          and then Expected /= Type_Binary
                          and then Actual_Tag /= Type_Binary
                          and then Expected /= Type_Pure
                          and then Actual_Tag /= Type_Pure;
                     begin
                        if Needs_Cast then
                           Emit_Raw (Ada_Type_Name (Expected) & "(", Ok);
                        end if;
                     Emit_Raw (Lex & " (Positive(", Ok);
                     Emit_Flat_Index (Sym_Idx, Tree (Idx).Left_Child, Module_Name, Ok);
                     Emit_Raw ("))", Ok);
                        if Needs_Cast then
                           Emit_Raw (")", Ok);
                        end if;
                     end;
                  else
                     if As_Text and then Sym_Idx > 0 and then Symbols (Sym_Idx).Tag /= Type_Binary then
                        case Symbols (Sym_Idx).Tag is
                           when Type_Boolean =>
                              Emit_Raw ("ALB_IMAGE(" & Lex & ")", Ok);
                           when Type_S32 =>
                              Emit_Raw ("ALB_IMAGE(" & Lex & ")", Ok);
                           when others =>
                              Emit_Raw ("ALB_IMAGE(U64(" & Lex & "))", Ok);
                        end case;
                     elsif Actual_Tag /= Type_None
                       and then Expected /= Type_None
                       and then Expected /= Actual_Tag
                       and then Expected /= Type_Boolean
                       and then Actual_Tag /= Type_Boolean
                       and then Expected /= Type_Binary
                       and then Actual_Tag /= Type_Binary
                       and then Expected /= Type_Pure
                       and then Actual_Tag /= Type_Pure
                     then
                        if Expected = Type_U64
                          and then Is_Signed_Integer_Tag (Actual_Tag)
                        then
                           case Actual_Tag is
                              when Type_S8 | Type_HW8 =>
                                 Emit_Raw ("ALB_S8_TO_U64(" & Lex & ")", Ok);
                              when Type_S16 | Type_HW16 =>
                                 Emit_Raw ("ALB_S16_TO_U64(" & Lex & ")", Ok);
                              when Type_S64 | Type_HW64 =>
                                 Emit_Raw ("ALB_S64_TO_U64(" & Lex & ")", Ok);
                              when others =>
                                 Emit_Raw ("ALB_S32_TO_U64(" & Lex & ")", Ok);
                           end case;
                        else
                           Emit_Raw (Ada_Type_Name (Expected) & "(" & Lex & ")", Ok);
                        end if;
                     else
                        Emit_Raw (Lex, Ok);
                     end if;
                  end if;
               end;

            when AST_Member_Expr =>
               declare
                  Actual_Tag : constant ALB_Type_Tag := Infer_Type (Idx, Module_Name);
                  Needs_Cast : constant Boolean := Needs_Numeric_Cast (Expected, Actual_Tag);
               begin
                  if Needs_Cast then
                     Emit_Raw (Ada_Type_Name (Expected) & "(", Ok);
                  end if;

                  if Is_Var_Like_Node (Tree (Idx).Left_Child) then
                     declare
                        Left_Name : constant String :=
                          Resolve_Parallel_Group_Name
                            (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                             Module_Name);
                     begin
                        PF_Idx := Find_Parallel_Field
                          (Left_Name,
                           Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                        if PF_Idx > 0 and then Tree (Tree (Idx).Left_Child).Left_Child /= 0 then
                           Emit_Raw
                             (Name_Text
                                (Parallel_Fields (PF_Idx).Backing_Name,
                                 Parallel_Fields (PF_Idx).Backing_Name_Len) &
                              " (Positive(",
                              Ok);
                           Emit_Expression (Tree (Tree (Idx).Left_Child).Left_Child, Module_Name, Type_S32, False, Ok);
                           Emit_Raw ("))", Ok);
                        elsif Tree (Idx).Right_Child /= 0
                          and then Tree (Tree (Idx).Right_Child).Kind = AST_Var_Expr
                          and then Tree (Tree (Idx).Right_Child).Left_Child /= 0
                          and then Is_Module_Name
                            (Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)))
                        then
                           declare
                              Module_Text : constant String :=
                                Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
                              Member_Name : constant String :=
                                Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index);
                              Qualified   : constant String :=
                                Qualify_Name (Module_Text, Member_Name);
                              Array_Sym   : constant Natural := Find_Symbol (Qualified);
                           begin
                              if Array_Sym > 0 and then Symbols (Array_Sym).Kind = Sym_Array then
                                 Emit_Raw (Qualified & " (Positive(", Ok);
                                 Emit_Flat_Index
                                   (Array_Sym,
                                    Tree (Tree (Idx).Right_Child).Left_Child,
                                    Module_Name,
                                    Ok);
                                 Emit_Raw ("))", Ok);
                              else
                                 Emit_Raw (Qualified, Ok);
                              end if;
                           end;
                        elsif Is_Module_Name (Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index))) then
                           Emit_Raw
                             (Qualify_Name
                                (Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                                 Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index)),
                              Ok);
                        else
                           Emit_Raw
                             (Left_Name & "." &
                              Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index)),
                              Ok);
                        end if;
                     end;
                  else
                     Emit_Raw ("0", Ok);
                  end if;

                  if Needs_Cast then
                     Emit_Raw (")", Ok);
                  end if;
               end;

            when AST_Cast_Expr =>
               if Expected = Type_Binary or else As_Text then
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               else
                  declare
                     Target_Tag : constant ALB_Type_Tag :=
                       Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
                     Source_Tag : constant ALB_Type_Tag :=
                       Infer_Type (Tree (Idx).Left_Child, Module_Name);
                     Needs_Cast : constant Boolean :=
                       Needs_Numeric_Cast (Expected, Target_Tag);
                  begin
                     if Needs_Cast then
                        Emit_Raw (Ada_Type_Name (Expected) & "(", Ok);
                     end if;
                     Emit_Converted_Expression
                       (Tree (Idx).Left_Child,
                        Module_Name,
                        Source_Tag,
                        Target_Tag,
                        Ok);
                     if Needs_Cast then
                        Emit_Raw (")", Ok);
                     end if;
                  end;
               end if;

            when AST_Constructor =>
               if Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index)) = Type_Pure then
                  Emit_Raw ("ALB_PURE(Long_Integer(", Ok);
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
                  Emit_Raw ("), Long_Integer(", Ok);
                  if Tree (Tree (Idx).Left_Child).Next_Sibling /= 0 then
                     Emit_Expression (Tree (Tree (Idx).Left_Child).Next_Sibling, Module_Name, Type_S32, False, Ok);
                  else
                     Emit_Raw ("1", Ok);
                  end if;
                  Emit_Raw ("))", Ok);
               elsif Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index)) /= Type_None then
                  declare
                     Target_Tag : constant ALB_Type_Tag :=
                       Tag_From_Name (Raw_Lexeme (Tree (Idx).Token_Index));
                     Source_Tag : constant ALB_Type_Tag :=
                       Infer_Type (Tree (Idx).Left_Child, Module_Name);
                     Needs_Cast : constant Boolean :=
                       Needs_Numeric_Cast (Expected, Target_Tag);
                  begin
                     if Needs_Cast then
                        Emit_Raw (Ada_Type_Name (Expected) & "(", Ok);
                     end if;
                     Emit_Converted_Expression
                       (Tree (Idx).Left_Child,
                        Module_Name,
                        Source_Tag,
                        Target_Tag,
                        Ok);
                     if Needs_Cast then
                        Emit_Raw (")", Ok);
                     end if;
                  end;
               else
                  Emit_Raw ("0", Ok);
               end if;

            when AST_Func_Call =>
               Emit_Function_Call (Idx, Module_Name, Expected, As_Text, Ok);

            when AST_Inline_Ada_Expr =>
               Emit_Raw
                 (Extract_Ada_Block_Body (Raw_Lexeme (Tree (Idx).Token_Index)),
                  Ok);

            when AST_Rnd_Expr =>
               declare
                  Needs_Cast : constant Boolean :=
                    Expected /= Type_None
                    and then Expected /= Type_U64
                    and then Expected /= Type_Boolean
                    and then Expected /= Type_Binary
                    and then Expected /= Type_Pure;
               begin
                  if Needs_Cast then
                     Emit_Raw (Ada_Type_Name (Expected) & "(", Ok);
                  end if;
                  Emit_Raw ("ALB_RND(", Ok);
                  if Tree (Idx).Left_Child /= 0 then
                     Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
                  else
                     Emit_Raw ("0", Ok);
                  end if;
                  Emit_Raw (")", Ok);
                  if Needs_Cast then
                     Emit_Raw (")", Ok);
                  end if;
               end;

            when AST_Choose =>
               declare
                  Cond_Node   : constant Node_Index := Tree (Idx).Left_Child;
                  Pair_Node   : constant Node_Index := Tree (Idx).Right_Child;
                  True_Node   : constant Node_Index :=
                    (if Pair_Node /= 0 then Tree (Pair_Node).Left_Child else 0);
                  False_Node  : constant Node_Index :=
                    (if Pair_Node /= 0 then Tree (Pair_Node).Right_Child else 0);
                  Branch_Tag  : constant ALB_Type_Tag :=
                    (if True_Node /= 0 then Infer_Type (True_Node, Module_Name) else Type_U64);
               begin
                  Emit_Raw ("(if ", Ok);
                  if Cond_Node /= 0 then
                     Emit_Condition_Expression (Cond_Node, Module_Name, Ok);
                  else
                     Emit_Raw ("False", Ok);
                  end if;
                  Emit_Raw (" then ", Ok);
                  if As_Text or else Expected = Type_Binary or else Branch_Tag = Type_Binary then
                     if True_Node /= 0 then
                        Emit_Text_Expression (True_Node, Module_Name, Ok);
                     else
                        Emit_Raw ("ALB_STR("""")", Ok);
                     end if;
                     Emit_Raw (" else ", Ok);
                     if False_Node /= 0 then
                        Emit_Text_Expression (False_Node, Module_Name, Ok);
                     else
                        Emit_Raw ("ALB_STR("""")", Ok);
                     end if;
                  else
                     if True_Node /= 0 then
                        Emit_Expression (True_Node, Module_Name, Branch_Tag, False, Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                     Emit_Raw (" else ", Ok);
                     if False_Node /= 0 then
                        Emit_Expression (False_Node, Module_Name, Branch_Tag, False, Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                  end if;
                  Emit_Raw (")", Ok);
               end;

            when AST_Str_Len | AST_Str_Left | AST_Str_Right | AST_Str_Mid | AST_Str_Concat =>
               if Tree (Idx).Kind = AST_Str_Len then
                  Emit_Raw ("ALB_TEXT_LENGTH(", Ok);
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (")", Ok);
               elsif Tree (Idx).Kind = AST_Str_Left then
                  Emit_Raw ("ALB_LEFT(", Ok);
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (", ", Ok);
                  Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U32, False, Ok);
                  Emit_Raw (")", Ok);
               elsif Tree (Idx).Kind = AST_Str_Right then
                  Emit_Raw ("ALB_RIGHT(", Ok);
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (", ", Ok);
                  Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U32, False, Ok);
                  Emit_Raw (")", Ok);
               elsif Tree (Idx).Kind = AST_Str_Mid then
                  Emit_Raw ("ALB_MID(", Ok);
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (", ", Ok);
                  if Tree (Idx).Right_Child /= 0 then
                     Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U32, False, Ok);
                     Emit_Raw (", ", Ok);
                     if Tree (Tree (Idx).Right_Child).Next_Sibling /= 0 then
                        Emit_Expression (Tree (Tree (Idx).Right_Child).Next_Sibling, Module_Name, Type_U32, False, Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                  else
                     Emit_Raw ("1, 0", Ok);
                  end if;
                  Emit_Raw (")", Ok);
               else
                  Emit_Raw ("ALB_CONCAT(", Ok);
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (", ", Ok);
                  Emit_Text_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
                  Emit_Raw (")", Ok);
               end if;

            when AST_File_Open =>
               Emit_Raw ("ALBA_IO.File_Open(", Ok);
               Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw (", ", Ok);
               Emit_Text_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
               Emit_Raw (")", Ok);

            when AST_File_Len =>
               Emit_Raw ("ALBA_IO.File_Len(", Ok);
               Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw (")", Ok);

            when AST_File_Seek =>
               Emit_Raw ("ALBA_IO.File_Seek(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (", ", Ok);
               Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (")", Ok);

            when AST_File_Read =>
               Emit_Raw ("ALBA_IO.File_Read(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (", ", Ok);
               Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (")", Ok);

            when AST_SizeOf_Expr =>
               Emit_Raw (Trim_Image (Integer (Type_Size_Bytes (Infer_Type (Tree (Idx).Left_Child, Module_Name)))), Ok);

            when AST_OffsetOf_Expr =>
               declare
                  Struct_Name : constant String :=
                    (if Tree (Idx).Left_Child /= 0 and then Tree (Tree (Idx).Left_Child).Token_Index > 0
                     then Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)
                     else "");
                  Field_Name  : constant String :=
                    (if Tree (Idx).Right_Child /= 0 and then Tree (Tree (Idx).Right_Child).Token_Index > 0
                     then Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index)
                     else "");
                  Field_Idx   : constant Natural := Find_Struct_Field (Struct_Name, Field_Name);
               begin
                  if Field_Idx > 0 then
                     Emit_Raw (Trim_Image (Integer (Struct_Fields (Field_Idx).Offset_Bytes)), Ok);
                  else
                     Emit_Raw ("0", Ok);
                  end if;
               end;

            when AST_TypeOf_Expr =>
               Emit_Raw
                 ("ALB_STR(""" &
                  Type_Name_Text (Infer_Type (Tree (Idx).Left_Child, Module_Name)) &
                  """)",
                  Ok);

            when AST_Knows_Query =>
               if Expected = Type_Boolean then
                  Emit_Raw ("ALBA_Logic.Prove(", Ok);
                  Emit_Logic_Hash (Predicate_Name_Of (Tree (Idx).Left_Child), Ok);
                  Emit_Raw (", ", Ok);
                  if Predicate_Arg_Node (Tree (Idx).Left_Child) /= 0 then
                     Emit_Assigned_Expression
                       (Predicate_Arg_Node (Tree (Idx).Left_Child),
                        Module_Name,
                        Type_S32,
                        Ok);
                  else
                     Emit_Raw ("0", Ok);
                  end if;
                  Emit_Raw (")", Ok);
               else
                  Emit_Raw ("ALB_BOOL_TO_U64(ALBA_Logic.Prove(", Ok);
                  Emit_Logic_Hash (Predicate_Name_Of (Tree (Idx).Left_Child), Ok);
                  Emit_Raw (", ", Ok);
                  if Predicate_Arg_Node (Tree (Idx).Left_Child) /= 0 then
                     Emit_Assigned_Expression
                       (Predicate_Arg_Node (Tree (Idx).Left_Child),
                        Module_Name,
                        Type_S32,
                        Ok);
                  else
                     Emit_Raw ("0", Ok);
                  end if;
                  Emit_Raw ("))", Ok);
               end if;

            when AST_Find_Query | AST_Query =>
               if Tree (Idx).Token_Index > 0
                 and then Tokens (Tree (Idx).Token_Index).Kind = Tok_Find
               then
                  Emit_Raw ("U64(ALBA_Logic.Find_First(", Ok);
                  Emit_Logic_Hash (Predicate_Name_Of (Tree (Idx).Left_Child), Ok);
                  Emit_Raw ("))", Ok);
               else
                  if Expected = Type_Boolean then
                     Emit_Raw ("ALBA_Logic.Prove(", Ok);
                     Emit_Logic_Hash (Predicate_Name_Of (Tree (Idx).Left_Child), Ok);
                     Emit_Raw (", ", Ok);
                     if Predicate_Arg_Node (Tree (Idx).Left_Child) /= 0 then
                        Emit_Assigned_Expression
                          (Predicate_Arg_Node (Tree (Idx).Left_Child),
                           Module_Name,
                           Type_S32,
                           Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                     Emit_Raw (")", Ok);
                  else
                     Emit_Raw ("ALB_BOOL_TO_U64(ALBA_Logic.Prove(", Ok);
                     Emit_Logic_Hash (Predicate_Name_Of (Tree (Idx).Left_Child), Ok);
                     Emit_Raw (", ", Ok);
                     if Predicate_Arg_Node (Tree (Idx).Left_Child) /= 0 then
                        Emit_Assigned_Expression
                          (Predicate_Arg_Node (Tree (Idx).Left_Child),
                           Module_Name,
                           Type_S32,
                           Ok);
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                     Emit_Raw ("))", Ok);
                  end if;
               end if;

            when AST_Peek_Expr =>
               Emit_Raw ("ALBA_Peek_Address(Positive(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw ("))", Ok);

            when AST_Deref_Expr =>
               Emit_Raw ("ALBA_Deref_Address(Positive(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw ("))", Ok);

            when AST_AddressOf | AST_Ref_Expr =>
               Emit_Address_Expression (Tree (Idx).Left_Child, Module_Name, Ok);

            when AST_Temporal_Ref =>
               Sym_Idx := Find_Symbol (Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index), Module_Name));
               if Sym_Idx > 0 and then Symbols (Sym_Idx).Kind = Sym_Temporal then
                  case Tokens (Tree (Idx).Token_Index).Kind is
                     when Tok_Now =>
                        Emit_Raw (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len), Ok);
                     when Tok_Past =>
                        Emit_Raw
                          (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len) &
                           "_timeline(((" &
                           Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len) &
                           "_head + " &
                           Trim_Image (Integer (Symbols (Sym_Idx).History_Size)) &
                           " - 1) mod " &
                           Trim_Image (Integer (Symbols (Sym_Idx).History_Size)) &
                           "))",
                           Ok);
                     when Tok_Future =>
                        Emit_Raw (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len), Ok);
                     when Tok_Timeline =>
                        Emit_Raw (Trim_Image (Integer (Symbols (Sym_Idx).Timeline_Offset)), Ok);
                     when others =>
                        Emit_Raw (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len), Ok);
                  end case;
               else
                  Emit_Raw ("0", Ok);
               end if;

            when AST_READ_PIXEL =>
               Curr := Tree (Idx).Left_Child;
               if Curr /= 0 and then Tree (Curr).Kind = AST_Arg_List then
                  Curr := Tree (Curr).Left_Child;
               end if;
               Emit_Raw ("U32(ALBA_Graphics.Read_Pixel(Integer(", Ok);
               if Curr /= 0 then
                  Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
                  Curr := Tree (Curr).Next_Sibling;
               else
                  Emit_Raw ("0", Ok);
               end if;
               Emit_Raw ("), Integer(", Ok);
               if Curr /= 0 then
                  Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
               Emit_Raw (")))", Ok);

            when AST_Key_State =>
               if Expected = Type_Boolean then
                  Emit_Raw ("ALBA_Graphics.Key_Down(Integer(", Ok);
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
                  Emit_Raw ("))", Ok);
               else
                  declare
                     Numeric_Tag : constant ALB_Type_Tag :=
                       (if Expected /= Type_None
                          and then Expected /= Type_Binary
                          and then Expected /= Type_Pure
                          and then Expected /= Type_Boolean
                        then Expected
                        else Type_U32);
                  begin
                     Emit_Raw (Ada_Type_Name (Numeric_Tag) & "((if ALBA_Graphics.Key_Down(Integer(", Ok);
                     Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
                     Emit_Raw (")) then 1 else 0))", Ok);
                  end;
               end if;
            when AST_Mouse_X =>
               Emit_Raw ("S32(ALBA_Graphics.Mouse_X)", Ok);
            when AST_Mouse_Y =>
               Emit_Raw ("S32(ALBA_Graphics.Mouse_Y)", Ok);
            when AST_Mouse_Wheel =>
               Emit_Raw ("S32(0)", Ok);
            when AST_VMouse_X =>
               Emit_Raw ("S32(ALBA_Graphics.VMouse_X)", Ok);
            when AST_VMouse_y =>
               Emit_Raw ("S32(ALBA_Graphics.VMouse_Y)", Ok);
            when AST_Mouse_Click =>
               Emit_Raw ("U32(ALBA_Graphics.Mouse_Click(Integer(", Ok);
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
               Emit_Raw (")))", Ok);
            when AST_SCREEN_WIDTH =>
               Emit_Raw (Trim_Image (Integer (Window_Width)), Ok);
            when AST_SCREEN_HEIGHT =>
               Emit_Raw (Trim_Image (Integer (Window_Height)), Ok);
            when AST_VIRTUAL_WIDTH =>
               Emit_Raw ("S32(ALBA_Graphics.Virtual_Width)", Ok);
            when AST_VIRTUAL_HEIGHT =>
               Emit_Raw ("S32(ALBA_Graphics.Virtual_Height)", Ok);

            when AST_Not =>
               Emit_Raw ("not (", Ok);
               Emit_Condition_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw (")", Ok);

            when AST_Unary_Minus =>
               Emit_Raw ("(-", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Expected, False, Ok);
               Emit_Raw (")", Ok);

            when AST_BinOp =>
               Tok := Tokens (Tree (Idx).Token_Index);
               if Tok.Kind = TOK_PIPE then
                  Emit_Raw ("ALB_CAT(", Ok);
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (", ", Ok);
                  Emit_Text_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
                  Emit_Raw (")", Ok);
               elsif Tok.Kind = TOK_PLUS
                 and then
                   (As_Text
                    or else Expected = Type_Binary
                    or else Infer_Type (Tree (Idx).Left_Child, Module_Name) = Type_Binary
                    or else Infer_Type (Tree (Idx).Right_Child, Module_Name) = Type_Binary)
               then
                  Emit_Raw ("ALB_CAT(", Ok);
                  Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (", ", Ok);
                  Emit_Text_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
                  Emit_Raw (")", Ok);
               elsif Tok.Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL |
                                  TOK_LESS | TOK_GREATER |
                                  TOK_LESS_EQUAL | TOK_GREATER_EQUAL
                 and then Tree (Idx).Right_Child /= 0
                 and then Tree (Tree (Idx).Right_Child).Kind = AST_BinOp
                 and then Tokens (Tree (Tree (Idx).Right_Child).Token_Index).Kind in TOK_AND | TOK_OR | TOK_XOR
               then
                  declare
                     Compare_Tag : constant ALB_Type_Tag :=
                       Promote_Numeric_Tag
                         (Infer_Type (Tree (Idx).Left_Child, Module_Name),
                          Infer_Type (Tree (Tree (Idx).Right_Child).Left_Child, Module_Name));
                  begin
                     Emit_Raw ("((", Ok);
                     Emit_Expression
                       (Tree (Idx).Left_Child,
                        Module_Name,
                        Compare_Tag,
                        False,
                        Ok);
                     case Tok.Kind is
                        when TOK_ASSIGN | TOK_EQUAL       => Emit_Raw (" = ", Ok);
                        when TOK_NOT_EQUAL                => Emit_Raw (" /= ", Ok);
                        when TOK_LESS                     => Emit_Raw (" < ", Ok);
                        when TOK_GREATER                  => Emit_Raw (" > ", Ok);
                        when TOK_LESS_EQUAL               => Emit_Raw (" <= ", Ok);
                        when TOK_GREATER_EQUAL            => Emit_Raw (" >= ", Ok);
                        when others                       => null;
                     end case;
                     Emit_Expression
                       (Tree (Tree (Idx).Right_Child).Left_Child,
                        Module_Name,
                        Compare_Tag,
                        False,
                        Ok);
                     Emit_Raw (") ", Ok);
                     case Tokens (Tree (Tree (Idx).Right_Child).Token_Index).Kind is
                        when TOK_AND   => Emit_Raw ("and ", Ok);
                        when TOK_OR    => Emit_Raw ("or ", Ok);
                        when TOK_XOR   => Emit_Raw ("xor ", Ok);
                        when others    => null;
                     end case;
                     Emit_Expression (Tree (Tree (Idx).Right_Child).Right_Child, Module_Name, Type_Boolean, False, Ok);
                     Emit_Raw (")", Ok);
                  end;
               elsif Tok.Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL |
                                  TOK_LESS | TOK_GREATER |
                                  TOK_LESS_EQUAL | TOK_GREATER_EQUAL
               then
                  declare
                     Left_Tag  : constant ALB_Type_Tag :=
                       Infer_Type (Tree (Idx).Left_Child, Module_Name);
                     Right_Tag : constant ALB_Type_Tag :=
                       Infer_Type (Tree (Idx).Right_Child, Module_Name);
                     Compare_Tag : constant ALB_Type_Tag :=
                       Promote_Numeric_Tag (Left_Tag, Right_Tag);
                     Right_Static : constant Static_S64_Result :=
                       Try_Eval_Static_S64
                         (Tree (Idx).Right_Child, Module_Name);
                     Left_Static : constant Static_S64_Result :=
                       Try_Eval_Static_S64
                         (Tree (Idx).Left_Child, Module_Name);

                     procedure Emit_Boolean_Test
                       (Bool_Node : Node_Index;
                        Negated   : Boolean) is
                     begin
                        if Negated then
                           Emit_Raw ("(not ", Ok);
                        else
                           Emit_Raw ("(", Ok);
                        end if;
                        Emit_Expression (Bool_Node, Module_Name, Type_Boolean, False, Ok);
                        Emit_Raw (")", Ok);
                     end Emit_Boolean_Test;
                  begin
                     if Left_Tag = Type_Boolean and then Right_Tag /= Type_Boolean
                       and then Right_Static.Success
                       and then Right_Static.Value in 0 .. 1
                       and then Tok.Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL
                     then
                        Emit_Boolean_Test
                          (Tree (Idx).Left_Child,
                           ((Right_Static.Value = 0) = (Tok.Kind = TOK_EQUAL)));
                     elsif Right_Tag = Type_Boolean and then Left_Tag /= Type_Boolean
                       and then Left_Static.Success
                       and then Left_Static.Value in 0 .. 1
                       and then Tok.Kind in TOK_ASSIGN | TOK_EQUAL | TOK_NOT_EQUAL
                     then
                        Emit_Boolean_Test
                          (Tree (Idx).Right_Child,
                           ((Left_Static.Value = 0) = (Tok.Kind = TOK_EQUAL)));
                     else
                        Emit_Raw ("(", Ok);
                        Emit_Converted_Expression
                          (Tree (Idx).Left_Child,
                           Module_Name,
                           Left_Tag,
                           Compare_Tag,
                           Ok);
                        case Tok.Kind is
                           when TOK_ASSIGN | TOK_EQUAL       => Emit_Raw (" = ", Ok);
                           when TOK_NOT_EQUAL                => Emit_Raw (" /= ", Ok);
                           when TOK_LESS                     => Emit_Raw (" < ", Ok);
                           when TOK_GREATER                  => Emit_Raw (" > ", Ok);
                           when TOK_LESS_EQUAL               => Emit_Raw (" <= ", Ok);
                           when TOK_GREATER_EQUAL            => Emit_Raw (" >= ", Ok);
                           when others                       => null;
                        end case;
                        Emit_Converted_Expression
                          (Tree (Idx).Right_Child,
                           Module_Name,
                           Right_Tag,
                           Compare_Tag,
                           Ok);
                        Emit_Raw (")", Ok);
                     end if;
                  end;
               elsif Tok.Kind = TOK_POW then
                  declare
                     Result_Tag : constant ALB_Type_Tag := Infer_Type (Idx, Module_Name);
                  begin
                     if Result_Tag = Type_F64 or else Result_Tag = Type_F32 then
                        Emit_Raw ("ALB_POW_F64(F64(", Ok);
                        Emit_Expression
                          (Tree (Idx).Left_Child,
                           Module_Name,
                           Type_F64,
                           False,
                           Ok);
                        Emit_Raw ("), F64(", Ok);
                        Emit_Expression
                          (Tree (Idx).Right_Child,
                           Module_Name,
                           Type_F64,
                           False,
                           Ok);
                        Emit_Raw ("))", Ok);
                     else
                        Emit_Raw (Ada_Type_Name (Result_Tag) & "(ALB_POW_S64(S64(", Ok);
                        Emit_Expression
                          (Tree (Idx).Left_Child,
                           Module_Name,
                           Type_S64,
                           False,
                           Ok);
                        Emit_Raw ("), S64(", Ok);
                        Emit_Expression
                          (Tree (Idx).Right_Child,
                           Module_Name,
                           Type_S64,
                           False,
                           Ok);
                        Emit_Raw (")))", Ok);
                     end if;
                  end;
               else
                  declare
                     Native_Tag : constant ALB_Type_Tag :=
                       Infer_Type (Idx, Module_Name);
                     -- Keep S8/S16/S32 arithmetic signed under unsigned Expected
                     -- (e.g. angle normalize). Do not force S64-from-U64-mix that
                     -- way; U64 targets should evaluate mixed ops as U64.
                     Op_Expected : constant ALB_Type_Tag :=
                       (if Native_Tag in Type_S8 | Type_S16 | Type_S32 |
                                         Type_HW8 | Type_HW16 | Type_HW32
                           and then Expected in Type_U8 | Type_U16 | Type_U32 | Type_U64
                        then Native_Tag
                        elsif Expected /= Type_None then Expected
                        else Native_Tag);
                  begin
                     declare
                        Left_Tag : constant ALB_Type_Tag :=
                          Infer_Type (Tree (Idx).Left_Child, Module_Name);
                        Right_Tag : constant ALB_Type_Tag :=
                          Infer_Type (Tree (Idx).Right_Child, Module_Name);
                     begin
                        Emit_Raw ("(", Ok);
                        Emit_Converted_Expression
                          (Tree (Idx).Left_Child,
                           Module_Name,
                           Left_Tag,
                           Op_Expected,
                           Ok);
                        case Tok.Kind is
                           when TOK_PLUS  => Emit_Raw (" + ", Ok);
                           when TOK_MINUS => Emit_Raw (" - ", Ok);
                           when TOK_MUL   => Emit_Raw (" * ", Ok);
                           when TOK_DIV   => Emit_Raw (" / ", Ok);
                           when TOK_MOD   => Emit_Raw (" mod ", Ok);
                           when TOK_AND   => Emit_Raw (" and ", Ok);
                           when TOK_OR    => Emit_Raw (" or ", Ok);
                           when TOK_XOR   => Emit_Raw (" xor ", Ok);
                           when TOK_SHL   => Emit_Raw (" * 2 ** ", Ok);
                           when TOK_SHR   => Emit_Raw (" / 2 ** ", Ok);
                           when others    => Emit_Raw (" + ", Ok);
                        end case;
                        Emit_Converted_Expression
                          (Tree (Idx).Right_Child,
                           Module_Name,
                           Right_Tag,
                           Op_Expected,
                           Ok);
                        Emit_Raw (")", Ok);
                     end;
                  end;
               end if;

            when others =>
               if As_Text or else Expected = Type_Binary then
                  Emit_Raw ("ALB_STR("""")", Ok);
               elsif Expected = Type_Boolean then
                  Emit_Raw ("False", Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
         end case;
      exception
         when others =>
            Ada.Text_IO.Put_Line
              ("Emit_Expression failure at node" &
               Trim_Image (Integer (Idx)) &
               " kind " &
               Node_Kind'Image (Tree (Idx).Kind) &
               " token " &
               Trim_Image (Integer (Tree (Idx).Token_Index)));
            raise;
      end Emit_Expression;

      procedure Emit_Target
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean) is
         Sym_Idx : Natural := 0;
         PF_Idx  : Natural := 0;
      begin
         if Idx = 0 or else not Ok then
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Var_Expr | AST_Logic_Var =>
               declare
                  Name : constant String :=
                    Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
               begin
                  Sym_Idx := Find_Symbol (Name);
                  if Tree (Idx).Left_Child /= 0 and then Sym_Idx > 0 and then Symbols (Sym_Idx).Kind = Sym_Array then
                     Emit_Raw (Name & " (Positive(", Ok);
                     Emit_Flat_Index (Sym_Idx, Tree (Idx).Left_Child, Module_Name, Ok);
                     Emit_Raw ("))", Ok);
                  else
                     Emit_Raw (Name, Ok);
                  end if;
               end;

            when AST_Member_Expr =>
               if Is_Var_Like_Node (Tree (Idx).Left_Child) then
                  declare
                     Name : constant String :=
                       Resolve_Parallel_Group_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index), Module_Name);
                  begin
                     PF_Idx := Find_Parallel_Field (Name, Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index));
                     if PF_Idx > 0 and then Tree (Tree (Idx).Left_Child).Left_Child /= 0 then
                        Emit_Raw
                          (Name_Text (Parallel_Fields (PF_Idx).Backing_Name, Parallel_Fields (PF_Idx).Backing_Name_Len) &
                           " (Positive(",
                           Ok);
                        Emit_Expression (Tree (Tree (Idx).Left_Child).Left_Child, Module_Name, Type_S32, False, Ok);
                        Emit_Raw ("))", Ok);
                     elsif Tree (Idx).Right_Child /= 0
                       and then Tree (Tree (Idx).Right_Child).Kind = AST_Var_Expr
                       and then Tree (Tree (Idx).Right_Child).Left_Child /= 0
                       and then Is_Module_Name
                         (Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)))
                     then
                        declare
                           Module_Text : constant String :=
                             Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index));
                           Member_Name : constant String :=
                             Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index);
                           Qualified   : constant String :=
                             Qualify_Name (Module_Text, Member_Name);
                           Array_Sym   : constant Natural := Find_Symbol (Qualified);
                        begin
                           if Array_Sym > 0 and then Symbols (Array_Sym).Kind = Sym_Array then
                              Emit_Raw (Qualified & " (Positive(", Ok);
                              Emit_Flat_Index
                                (Array_Sym,
                                 Tree (Tree (Idx).Right_Child).Left_Child,
                                 Module_Name,
                                 Ok);
                              Emit_Raw ("))", Ok);
                           else
                              Emit_Raw (Qualified, Ok);
                           end if;
                        end;
                     else
                        Emit_Raw
                          (Name & "." & Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index)),
                           Ok);
                     end if;
                  end;
               else
                  Emit_Raw ("null", Ok);
               end if;

            when others =>
               Emit_Raw ("null", Ok);
         end case;
      end Emit_Target;

      procedure Emit_Node
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean);

      procedure Emit_Block
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean) is
         Curr : Node_Index := 0;
      begin
         if Idx = 0 or else not Ok then
            return;
         end if;
         if Tree (Idx).Kind = AST_Block_Stmt then
            Curr := Tree (Idx).Left_Child;
         else
            Curr := Idx;
         end if;
         for Guard in 1 .. Max_Nodes loop
            exit when Curr = 0;
            Emit_Node (Curr, Module_Name, Ok);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Block;

      procedure Emit_Node
        (Idx         : Node_Index;
         Module_Name : String := "";
         Ok          : in out Boolean) is
         Tok : Token;
         Step_Node : Node_Index := 0;
         End_Node  : Node_Index := 0;
         Dummy     : Node_Index := 0;
         Name_Node : Node_Index := 0;
         Body_Node : Node_Index := 0;
         Curr      : Node_Index := 0;
         Sym_Idx   : Natural := 0;
      begin
         if not Ok or else Idx = 0 then
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Block_Stmt =>
               Emit_Block (Idx, Module_Name, Ok);

            when AST_Let_Stmt =>
               if Tree (Idx).Right_Child /= 0 then
                  Emit_Firewall_Assert (Tree (Idx).Left_Child, False, True, Ok);
                  Emit_Firewall_Assert (Tree (Idx).Right_Child, True, False, Ok);
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" := ", Ok);
                  Emit_Assigned_Expression
                    (Tree (Idx).Right_Child,
                     Module_Name,
                     Infer_Type (Tree (Idx).Left_Child, Module_Name),
                     Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  Emit_Sync_Target_To_VAS (Tree (Idx).Left_Child, Module_Name, Ok);
               end if;

            when AST_BinOp =>
               Tok := Tokens (Tree (Idx).Token_Index);
               if Tok.Kind = TOK_ASSIGN then
                  declare
                     Target_Tag : constant ALB_Type_Tag :=
                       Infer_Type (Tree (Idx).Left_Child, Module_Name);
                     Source_Tag : constant ALB_Type_Tag :=
                       Infer_Type (Tree (Idx).Right_Child, Module_Name);
                     RHS_Node : constant Node_Index := Tree (Idx).Right_Child;
                  begin
                     Emit_Firewall_Assert (Tree (Idx).Left_Child, False, True, Ok);
                     Emit_Firewall_Assert (Tree (Idx).Right_Child, True, False, Ok);
                     Emit_Indent (Ok);
                     Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                     Emit_Raw (" := ", Ok);
                     if Target_Tag = Type_U64 and then Source_Tag = Type_S32 then
                        if RHS_Node /= 0
                          and then Tree (RHS_Node).Kind = AST_BinOp
                          and then Tree (RHS_Node).Token_Index > 0
                          and then Tokens (Tree (RHS_Node).Token_Index).Kind = TOK_MINUS
                          and then Tree (RHS_Node).Left_Child /= 0
                          and then Tree (Tree (RHS_Node).Left_Child).Kind = AST_Number_Expr
                          and then Raw_Lexeme (Tree (Tree (RHS_Node).Left_Child).Token_Index) = "0"
                        then
                           Emit_Raw ("ALB_ABS_S32_TO_U64(", Ok);
                           Emit_Expression
                             (Tree (RHS_Node).Right_Child,
                              Module_Name,
                              Type_S32,
                              False,
                              Ok);
                           Emit_Raw (")", Ok);
                        else
                           Emit_Raw ("ALB_S32_TO_U64(", Ok);
                           Emit_Expression
                             (RHS_Node,
                              Module_Name,
                              Type_S32,
                              False,
                              Ok);
                           Emit_Raw (")", Ok);
                        end if;
                     else
                        Emit_Assigned_Expression
                          (RHS_Node,
                           Module_Name,
                           Target_Tag,
                           Ok);
                     end if;
                     Emit_Raw (";", Ok);
                     Emit_Newline (Ok);
                     Emit_Sync_Target_To_VAS (Tree (Idx).Left_Child, Module_Name, Ok);
                  end;
               else
                  Emit_Comment ("expression statement elided", Ok);
               end if;

            when AST_If_Stmt =>
               Emit_Line ("if ", Ok);
               Decrease_Indent;
               Emit_Indent (Ok);
               Increase_Indent;
               Emit_Condition_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw (" then", Ok);
               Emit_Newline (Ok);
               Increase_Indent;
               Emit_Block (Tree (Idx).Right_Child, Module_Name, Ok);
               Decrease_Indent;
               if Tree (Idx).Right_Child /= 0 and then Tree (Tree (Idx).Right_Child).Next_Sibling /= 0 then
                  Emit_Line ("else", Ok);
                  Increase_Indent;
                  Emit_Block (Tree (Tree (Idx).Right_Child).Next_Sibling, Module_Name, Ok);
                  Decrease_Indent;
               end if;
               Emit_Line ("end if;", Ok);

            when AST_While_Stmt =>
               declare
                  Uses_Continue : constant Boolean :=
                    Tree_Contains_Kind (Tree (Idx).Right_Child, AST_Continue_Stmt, True);
                  Continue_Label : constant String :=
                    (if Uses_Continue then Next_Continue_Label else "");
               begin
                  Push_Continue_Label (Continue_Label);
                  Emit_Indent (Ok);
                  Emit_Raw ("while ", Ok);
                  Emit_Condition_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" loop", Ok);
                  Emit_Newline (Ok);
                  Increase_Indent;
                  Emit_Block (Tree (Idx).Right_Child, Module_Name, Ok);
                  if Uses_Continue then
                     Emit_Line ("<<" & Continue_Label & ">>", Ok);
                     Emit_Line ("null;", Ok);
                  end if;
                  Decrease_Indent;
                  Emit_Line ("end loop;", Ok);
                  Pop_Continue_Label;
               end;

            when AST_Repeat_Stmt =>
               declare
                  Uses_Continue : constant Boolean :=
                    Tree_Contains_Kind (Tree (Idx).Left_Child, AST_Continue_Stmt, True);
                  Continue_Label : constant String :=
                    (if Uses_Continue then Next_Continue_Label else "");
               begin
                  Push_Continue_Label (Continue_Label);
                  Emit_Line ("loop", Ok);
                  Increase_Indent;
                  Emit_Block (Tree (Idx).Left_Child, Module_Name, Ok);
                  if Uses_Continue then
                     Emit_Line ("<<" & Continue_Label & ">>", Ok);
                  end if;
                  Emit_Indent (Ok);
                  Emit_Raw ("exit when ", Ok);
                  Emit_Condition_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  Decrease_Indent;
                  Emit_Line ("end loop;", Ok);
                  Pop_Continue_Label;
               end;

            when AST_For_Stmt =>
               declare
                  Loop_Name : constant String :=
                    Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
                  Loop_Tag  : ALB_Type_Tag := Type_S32;
                  Loop_Sym  : Natural := 0;
                  Uses_Continue : constant Boolean :=
                    Tree_Contains_Kind (Tree (Idx).Right_Child, AST_Continue_Stmt, True);
                  Continue_Label : constant String :=
                    (if Uses_Continue then Next_Continue_Label else "");
                begin
                  Loop_Sym := Find_Symbol (Loop_Name);
                  if Loop_Sym > 0 then
                     Loop_Tag := Symbols (Loop_Sym).Tag;
                  end if;
                  Dummy := Tree (Idx).Left_Child;
                  if Dummy /= 0 then
                     End_Node := Tree (Dummy).Right_Child;
                     if End_Node /= 0 and then Tree (End_Node).Kind = AST_Arg_List then
                        End_Node := Tree (End_Node).Left_Child;
                     end if;
                     if End_Node /= 0 then
                        Step_Node := Tree (End_Node).Next_Sibling;
                     end if;
                  end if;
                  Emit_Indent (Ok);
                  Emit_Raw (Loop_Name & " := ", Ok);
                  Emit_Assigned_Expression (Tree (Dummy).Left_Child, Module_Name, Loop_Tag, Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  declare
                     Loop_Node : Natural := Find_Symbol (Loop_Name);
                  begin
                     if Loop_Node > 0 and then Symbols (Loop_Node).VAS_Offset > 0 then
                        Emit_Indent (Ok);
                        case Loop_Tag is
                           when Type_S32 =>
                              Emit_Raw
                                ("ALB_STORE_I32(Positive(" &
                                 (if Symbols (Loop_Node).Scope_Name_Len = 0
                                  then Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))
                                  else "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))) &
                                 "), ALB_I32(" & Loop_Name & "));",
                                 Ok);
                           when others =>
                              Emit_Raw
                                ("ALB_STORE_U64(Positive(" &
                                 (if Symbols (Loop_Node).Scope_Name_Len = 0
                                  then Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))
                                  else "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))) &
                                 "), " &
                                 VAS_Store_Value_Text (Loop_Tag, Loop_Name) &
                                 ");",
                                 Ok);
                        end case;
                        Emit_Newline (Ok);
                     end if;
                  end;
                  Emit_Indent (Ok);
                  Emit_Raw ("while " & Loop_Name & " <= ", Ok);
                  Emit_Assigned_Expression (End_Node, Module_Name, Loop_Tag, Ok);
                  Emit_Raw (" loop", Ok);
                  Emit_Newline (Ok);
                  Push_Continue_Label (Continue_Label);
                  Increase_Indent;
                  Emit_Block (Tree (Idx).Right_Child, Module_Name, Ok);
                  if Uses_Continue then
                     Emit_Line ("<<" & Continue_Label & ">>", Ok);
                  end if;
                  Emit_Indent (Ok);
                  Emit_Raw (Loop_Name & " := " & Loop_Name & " + ", Ok);
                  if Step_Node /= 0 then
                     Emit_Assigned_Expression (Step_Node, Module_Name, Loop_Tag, Ok);
                  else
                     Emit_Raw ("1", Ok);
                  end if;
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  declare
                     Loop_Node : Natural := Find_Symbol (Loop_Name);
                  begin
                     if Loop_Node > 0 and then Symbols (Loop_Node).VAS_Offset > 0 then
                        Emit_Indent (Ok);
                        case Loop_Tag is
                           when Type_S32 =>
                              Emit_Raw
                                ("ALB_STORE_I32(Positive(" &
                                 (if Symbols (Loop_Node).Scope_Name_Len = 0
                                  then Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))
                                  else "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))) &
                                 "), ALB_I32(" & Loop_Name & "));",
                                 Ok);
                           when others =>
                              Emit_Raw
                                ("ALB_STORE_U64(Positive(" &
                                 (if Symbols (Loop_Node).Scope_Name_Len = 0
                                  then Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))
                                  else "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Loop_Node).VAS_Offset))) &
                                 "), " &
                                 VAS_Store_Value_Text (Loop_Tag, Loop_Name) &
                                 ");",
                                 Ok);
                        end case;
                        Emit_Newline (Ok);
                     end if;
                  end;
                  Decrease_Indent;
                  Emit_Line ("end loop;", Ok);
                  Pop_Continue_Label;
               end;

            when AST_Foreach_Stmt =>
               declare
                  Loop_Name : constant String :=
                    Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name);
                  Uses_Continue : constant Boolean :=
                    Tree_Contains_Kind (Tree (Idx).Right_Child, AST_Continue_Stmt, True);
                  Continue_Label : constant String :=
                    (if Uses_Continue then Next_Continue_Label else "");
               begin
                  Name_Node := Tree (Idx).Left_Child;
                  if Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Var_Expr then
                     Sym_Idx := Find_Symbol (Resolve_Name (Raw_Lexeme (Tree (Name_Node).Token_Index), Module_Name));
                     if Sym_Idx > 0 then
                        Emit_Indent (Ok);
                        Emit_Raw
                          ("for alba_each_" & Trim_Image (Integer (Idx)) &
                           " in 1 .. " &
                           Trim_Image (Integer (Symbols (Sym_Idx).Dims (1))) &
                           " loop",
                           Ok);
                        Emit_Newline (Ok);
                        Push_Continue_Label (Continue_Label);
                        Increase_Indent;
                        Emit_Line
                          (Loop_Name & " := " &
                           Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len) &
                           "(alba_each_" & Trim_Image (Integer (Idx)) & ");",
                           Ok);
                        declare
                           Loop_Local_Idx : constant Natural := Find_Symbol (Loop_Name);
                        begin
                           if Loop_Local_Idx > 0 and then Symbols (Loop_Local_Idx).VAS_Offset > 0 then
                              Emit_Indent (Ok);
                              Emit_Raw
                                ("ALB_STORE_U64(Positive(" &
                                 (if Symbols (Loop_Local_Idx).Scope_Name_Len = 0
                                  then Trim_Image (Integer (Symbols (Loop_Local_Idx).VAS_Offset))
                                  else "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (Loop_Local_Idx).VAS_Offset))) &
                                 "), " &
                                 VAS_Store_Value_Text
                                   (Symbols (Loop_Local_Idx).Tag, Loop_Name) &
                                 ");",
                                 Ok);
                              Emit_Newline (Ok);
                           end if;
                        end;
                        Emit_Block (Tree (Idx).Right_Child, Module_Name, Ok);
                        if Uses_Continue then
                           Emit_Line ("<<" & Continue_Label & ">>", Ok);
                           Emit_Line ("null;", Ok);
                        end if;
                        Decrease_Indent;
                        Emit_Line ("end loop;", Ok);
                        Pop_Continue_Label;
                     end if;
                  end if;
               end;

            when AST_Call_Stmt =>
               if Tree (Idx).Left_Child /= 0 and then Tree (Tree (Idx).Left_Child).Kind = AST_Func_Call then
                  declare
                     Call_Node   : constant Node_Index := Tree (Idx).Left_Child;
                     Return_Tag  : constant ALB_Type_Tag :=
                       Resolve_Routine_Return_Tag (Tree (Call_Node).Left_Child, Module_Name);
                     Ignore_Name : constant String :=
                       "ALBA_Ignored_" & Trim_Image (Integer (Call_Node));
                  begin
                     if Return_Tag /= Type_None then
                        Emit_Line ("declare", Ok);
                        Increase_Indent;
                        Emit_Indent (Ok);
                        Emit_Raw
                          (Ignore_Name & " : constant " & Ada_Type_Name (Return_Tag) & " := ",
                           Ok);
                        Emit_Function_Call (Call_Node, Module_Name, Return_Tag, False, Ok);
                        Emit_Raw (";", Ok);
                        Emit_Newline (Ok);
                        Decrease_Indent;
                        Emit_Line ("begin", Ok);
                        Increase_Indent;
                        Emit_Line ("null;", Ok);
                        Decrease_Indent;
                        Emit_Line ("end;", Ok);
                     else
                        Emit_Indent (Ok);
                        Emit_Function_Call (Call_Node, Module_Name, Type_None, False, Ok);
                        Emit_Raw (";", Ok);
                        Emit_Newline (Ok);
                     end if;
                  end;
               elsif Tree (Idx).Left_Child /= 0 then
                  Emit_Indent (Ok);
                  Emit_Raw (Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index), Module_Name), Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                else
                  Emit_Indent (Ok);
                  Emit_Raw ("null", Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                end if;

            when AST_Func_Call =>
               declare
                  Return_Tag  : constant ALB_Type_Tag :=
                    Resolve_Routine_Return_Tag (Tree (Idx).Left_Child, Module_Name);
                  Ignore_Name : constant String :=
                    "ALBA_Ignored_" & Trim_Image (Integer (Idx));
               begin
                  if Return_Tag /= Type_None then
                     Emit_Line ("declare", Ok);
                     Increase_Indent;
                     Emit_Indent (Ok);
                     Emit_Raw
                       (Ignore_Name & " : constant " & Ada_Type_Name (Return_Tag) & " := ",
                        Ok);
                     Emit_Function_Call (Idx, Module_Name, Return_Tag, False, Ok);
                     Emit_Raw (";", Ok);
                     Emit_Newline (Ok);
                     Decrease_Indent;
                     Emit_Line ("begin", Ok);
                     Increase_Indent;
                     Emit_Line ("null;", Ok);
                     Decrease_Indent;
                     Emit_Line ("end;", Ok);
                  else
                     Emit_Indent (Ok);
                     Emit_Function_Call (Idx, Module_Name, Type_None, False, Ok);
                     Emit_Raw (";", Ok);
                     Emit_Newline (Ok);
                  end if;
               end;

            when AST_Return_Stmt =>
               Emit_Indent (Ok);
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Raw ("ALBA_Return_Value := ", Ok);
                  Emit_Assigned_Expression
                    (Tree (Idx).Left_Child,
                     Module_Name,
                     Current_Return_Tag,
                     Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  Emit_Indent (Ok);
                  Emit_Raw ("return;", Ok);
               else
                  Emit_Raw ("return;", Ok);
               end if;
               Emit_Newline (Ok);

            when AST_Create_Window | AST_On_Block | AST_Version | AST_Import | AST_Include_Stmt |
                 AST_Module | AST_DeclareModule | AST_Procedure_Decl | AST_Function_Decl |
                 AST_Struct_Decl | AST_Range_Type_Decl | AST_Parallel_Decl | AST_Strict_Stmt |
                 AST_Slide_Stmt | AST_Temporal_Decl | AST_Const_Decl | AST_Enum_Decl |
                 AST_Markov_Model_Decl | AST_Neural_Topology_Decl |
                 AST_Memory_Firewall_Decl | AST_Network_Socket_Decl |
                 AST_Import_C | AST_Import_DLL | AST_Export_DLL | AST_Export_ES |
                 AST_Export_WASM | AST_Import_ES | AST_Import_WASM =>
               null;

            when AST_Predict_Markov_Stmt =>
               Emit_Indent (Ok);
               Emit_Target (Tree (Tree (Idx).Right_Child).Next_Sibling, Module_Name, Ok);
               Emit_Raw (" := ALB_MARKOV_PREDICT(ALB_MARKOV_" &
                 Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)) &
                 ", ALB_MARKOV_" &
                 Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)) &
                 "_STATES, ",
                 Ok);
               Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Infer_Network_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALB_NN_INFER(ALB_NN_" &
                 Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)) &
                 ", " &
                 Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index), Module_Name) &
                 ", " &
                 Resolve_Name (Raw_Lexeme (Tree (Tree (Tree (Idx).Right_Child).Next_Sibling).Token_Index), Module_Name) &
                 ");",
                 Ok);
               Emit_Newline (Ok);

            when AST_Train_Network_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALB_NN_TRAIN(ALB_NN_" &
                 Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)) &
                 ", " &
                 Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index), Module_Name) &
                 ", " &
                 Resolve_Name (Raw_Lexeme (Tree (Tree (Tree (Idx).Right_Child).Next_Sibling).Token_Index), Module_Name) &
                 ", ",
                 Ok);
               if Tree (Tree (Tree (Idx).Right_Child).Next_Sibling).Next_Sibling /= 0 then
                  Emit_Expression (Tree (Tree (Tree (Idx).Right_Child).Next_Sibling).Next_Sibling, Module_Name, Type_U64, False, Ok);
               else
                  Emit_Raw ("1", Ok);
               end if;
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Network_Listen_Stmt =>
               declare
                  Socket_Node   : constant Node_Index := Tree (Idx).Left_Child;
                  Socket_Name   : constant String := Resolve_Name (Raw_Lexeme (Tree (Socket_Node).Token_Index), Module_Name);
                  Socket_Id     : constant Natural := Find_Network_Socket (Socket_Name);
                  Decl_Node     : constant Node_Index := (if Socket_Id > 0 then Network_Sockets (Socket_Id).Node else 0);
                  Setting_Node  : Node_Index := (if Decl_Node /= 0 then Tree (Decl_Node).Right_Child else 0);
                  Protocol_Code : Natural := 1;
                  Port_Node     : Node_Index := 0;
                  Size_Node     : Node_Index := 0;
               begin
                  while Setting_Node /= 0 loop
                     case Tree (Setting_Node).Kind is
                        when AST_Network_Protocol =>
                           if Tree (Setting_Node).Left_Child /= 0
                             and then Upper_Safe_Name (Raw_Lexeme (Tree (Tree (Setting_Node).Left_Child).Token_Index)) = "UDP"
                           then
                              Protocol_Code := 2;
                           else
                              Protocol_Code := 1;
                           end if;
                        when AST_Network_Port =>
                           Port_Node := Tree (Setting_Node).Left_Child;
                        when AST_Network_Buffer_Size =>
                           Size_Node := Tree (Setting_Node).Left_Child;
                        when others =>
                           null;
                     end case;
                     Setting_Node := Tree (Setting_Node).Next_Sibling;
                  end loop;

                  Emit_Firewall_Assert (Socket_Node, True, False, Ok);
                  Emit_Indent (Ok);
                  Emit_Target (Socket_Node, Module_Name, Ok);
                  Emit_Raw (" := ALB_NET_LISTEN_SOCKET(" & Socket_Name & ", " &
                    Trim_Image (Integer (Protocol_Code)) & ", ", Ok);
                  if Port_Node /= 0 then
                     Emit_Expression (Port_Node, Module_Name, Type_S32, False, Ok);
                  else
                     Emit_Raw ("0", Ok);
                  end if;
                  Emit_Raw (", ", Ok);
                  if Size_Node /= 0 then
                     Emit_Expression (Size_Node, Module_Name, Type_S32, False, Ok);
                  else
                     Emit_Raw ("1", Ok);
                  end if;
                  Emit_Raw (");", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Network_Receive_Stmt =>
               Emit_Firewall_Assert (Tree (Idx).Left_Child, True, False, Ok);
               Emit_Firewall_Assert (Tree (Idx).Right_Child, False, True, Ok);
               Emit_Indent (Ok);
               Emit_Raw ("ALB_NET_RECEIVE(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (", " & Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index), Module_Name) & ");", Ok);
               Emit_Newline (Ok);

            when AST_Network_Send_Stmt =>
               Emit_Firewall_Assert (Tree (Idx).Left_Child, True, False, Ok);
               Emit_Firewall_Assert (Tree (Idx).Right_Child, True, False, Ok);
               Emit_Indent (Ok);
               Emit_Raw ("ALB_NET_SEND(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (", " & Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index), Module_Name) & ");", Ok);
               Emit_Newline (Ok);

            when AST_Network_Close_Stmt =>
               Emit_Firewall_Assert (Tree (Idx).Left_Child, True, True, Ok);
               Emit_Indent (Ok);
               Emit_Raw ("ALB_NET_CLOSE(" & Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index), Module_Name) & ");", Ok);
               Emit_Newline (Ok);

            when AST_Set_Fullscreen | AST_Set_Resizable | AST_Set_Stretchy =>
               Emit_Indent (Ok);
               if Tree (Idx).Kind = AST_Set_Fullscreen then
                  Emit_Raw ("ALBA_Graphics.Set_Fullscreen(", Ok);
               elsif Tree (Idx).Kind = AST_Set_Resizable then
                  Emit_Raw ("ALBA_Graphics.Set_Resizable(", Ok);
               else
                  Emit_Raw ("ALBA_Graphics.Set_Stretchy(", Ok);
               end if;
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_Boolean, False, Ok);
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Color =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Graphics.Set_Color(Integer(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Clear =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Graphics.Clear(Integer(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Draw | AST_FILL =>
               if Tree (Idx).Token_Index > 0 then
                  Tok := Tokens (Tree (Idx).Token_Index);
                  Curr := Tree (Idx).Left_Child;
                  if Curr /= 0 and then Tree (Curr).Kind = AST_Arg_List then
                     Curr := Tree (Curr).Left_Child;
                  end if;
                  Emit_Indent (Ok);
                  case Tok.Kind is
                     when TOK_TEXT =>
                        Emit_Raw ("ALBA_Graphics.Draw_Text(Integer(", Ok);
                        Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                        Emit_Raw ("), Integer(", Ok);
                        if Curr /= 0 then Curr := Tree (Curr).Next_Sibling; end if;
                        Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                        Emit_Raw ("), ALB_TO_STRING(", Ok);
                        if Curr /= 0 then Curr := Tree (Curr).Next_Sibling; end if;
                        Emit_Text_Expression (Curr, Module_Name, Ok);
                        Emit_Raw ("));", Ok);
                     when TOK_LINE =>
                        Emit_Raw ("ALBA_Graphics.Draw_Line(", Ok);
                        for I in 1 .. 4 loop
                           Emit_Raw ("Integer(", Ok);
                           Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                           Emit_Raw (")", Ok);
                           if I < 4 then
                              Emit_Raw (", ", Ok);
                           end if;
                           if Curr /= 0 then Curr := Tree (Curr).Next_Sibling; end if;
                        end loop;
                        Emit_Raw (");", Ok);
                     when TOK_RECT =>
                        if Tree (Idx).Kind = AST_FILL then
                           Emit_Raw ("ALBA_Graphics.Fill_Rect(", Ok);
                        else
                           Emit_Raw ("ALBA_Graphics.Draw_Rect(", Ok);
                        end if;
                        for I in 1 .. 4 loop
                           Emit_Raw ("Integer(", Ok);
                           Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                           Emit_Raw (")", Ok);
                           if I < 4 then
                              Emit_Raw (", ", Ok);
                           end if;
                           if Curr /= 0 then Curr := Tree (Curr).Next_Sibling; end if;
                        end loop;
                        Emit_Raw (");", Ok);
                     when TOK_CIRCLE =>
                        if Tree (Idx).Kind = AST_FILL then
                           Emit_Raw ("ALBA_Graphics.Fill_Circle(", Ok);
                        else
                           Emit_Raw ("ALBA_Graphics.Draw_Circle(", Ok);
                        end if;
                        for I in 1 .. 3 loop
                           Emit_Raw ("Integer(", Ok);
                           Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                           Emit_Raw (")", Ok);
                           if I < 3 then
                              Emit_Raw (", ", Ok);
                           end if;
                           if Curr /= 0 then Curr := Tree (Curr).Next_Sibling; end if;
                        end loop;
                        Emit_Raw (");", Ok);
                     when TOK_TRIANGLE =>
                        if Tree (Idx).Kind = AST_FILL then
                           Emit_Raw ("ALBA_Graphics.Fill_Triangle(", Ok);
                        else
                           Emit_Raw ("ALBA_Graphics.Draw_Triangle(", Ok);
                        end if;
                        for I in 1 .. 6 loop
                           Emit_Raw ("Integer(", Ok);
                           Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                           Emit_Raw (")", Ok);
                           if I < 6 then
                              Emit_Raw (", ", Ok);
                           end if;
                           if Curr /= 0 then Curr := Tree (Curr).Next_Sibling; end if;
                        end loop;
                        Emit_Raw (");", Ok);
                     when others =>
                        Emit_Raw ("null;", Ok);
                  end case;
                  Emit_Newline (Ok);
               end if;

            when AST_Plot =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Graphics.Plot(Integer(", Ok);
               if Tree (Idx).Left_Child /= 0 and then Tree (Tree (Idx).Left_Child).Kind = AST_Arg_List then
                  Curr := Tree (Tree (Idx).Left_Child).Left_Child;
               else
                  Curr := Tree (Idx).Left_Child;
               end if;
               Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
               Emit_Raw ("), Integer(", Ok);
               if Curr /= 0 then Curr := Tree (Curr).Next_Sibling; end if;
               Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Play_Music =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Audio.Play_Music(ALB_TO_STRING(", Ok);
               Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Text =>
               Emit_Indent (Ok);
               Curr := Tree (Idx).Left_Child;
               if Curr /= 0 and then Tree (Curr).Kind = AST_Arg_List then
                  Curr := Tree (Curr).Left_Child;
               end if;
               Emit_Raw ("ALBA_Graphics.Draw_Text(Integer(", Ok);
               Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
               Emit_Raw ("), Integer(", Ok);
               if Curr /= 0 then
                  Curr := Tree (Curr).Next_Sibling;
               end if;
               Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
               Emit_Raw ("), ALB_TO_STRING(", Ok);
               if Curr /= 0 then
                  Curr := Tree (Curr).Next_Sibling;
               end if;
               Emit_Text_Expression (Curr, Module_Name, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Play_Music_From =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Audio.Play_Music_From(ALB_TO_STRING(", Ok);
               Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Play_Sound =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Audio.Play_Sound(ALB_TO_STRING(", Ok);
               Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Set_Alpha | AST_Set_Clip | AST_Set_Origin =>
               Curr := Tree (Idx).Left_Child;
               if Curr /= 0 and then Tree (Curr).Kind = AST_Arg_List then
                  Curr := Tree (Curr).Left_Child;
               end if;
               Emit_Indent (Ok);
               if Tree (Idx).Kind = AST_Set_Alpha then
                  Emit_Raw ("ALBA_Graphics.Set_Alpha(", Ok);
                  for I in 1 .. 2 loop
                     if Curr /= 0 then
                        Emit_Raw ("Integer(", Ok);
                        Emit_Expression (Curr, Module_Name, Type_S32, False, Ok);
                        Emit_Raw (")", Ok);
                        Curr := Tree (Curr).Next_Sibling;
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                     if I < 2 then
                        Emit_Raw (", ", Ok);
                     end if;
                  end loop;
               elsif Tree (Idx).Kind = AST_Set_Clip then
                  Emit_Raw ("ALBA_Graphics.Set_Clip(", Ok);
                  for I in 1 .. 4 loop
                     if Curr /= 0 then
                        Emit_Raw ("Integer(", Ok);
                        Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                        Emit_Raw (")", Ok);
                        Curr := Tree (Curr).Next_Sibling;
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                     if I < 4 then
                        Emit_Raw (", ", Ok);
                     end if;
                  end loop;
               else
                  Emit_Raw ("ALBA_Graphics.Set_Origin(", Ok);
                  for I in 1 .. 2 loop
                     if Curr /= 0 then
                        Emit_Raw ("Integer(", Ok);
                        Emit_Graphics_Coordinate (Curr, Module_Name, Ok);
                        Emit_Raw (")", Ok);
                        Curr := Tree (Curr).Next_Sibling;
                     else
                        Emit_Raw ("0", Ok);
                     end if;
                     if I < 2 then
                        Emit_Raw (", ", Ok);
                     end if;
                  end loop;
               end if;
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Poke_Stmt =>
               Emit_Indent (Ok);
               if Current_Frame_Active then
                  Emit_Raw ("ALBA_Routine_Poke_Address(Positive(", Ok);
               else
                  Emit_Raw ("ALBA_Poke_Address(Positive(", Ok);
               end if;
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw ("), ", Ok);
               if Infer_Type (Tree (Idx).Right_Child, Module_Name) /= Type_U64 then
                  Emit_Raw ("U64(", Ok);
               end if;
               Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U64, False, Ok);
               if Infer_Type (Tree (Idx).Right_Child, Module_Name) /= Type_U64 then
                  Emit_Raw (")", Ok);
               end if;
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Print_Stmt | AST_Print_Str_Stmt =>
               Curr := Idx;
               while Curr /= 0 loop
                  Emit_Indent (Ok);
                  Emit_Raw ("ALBA_IO.Print_Text(", Ok);
                  Emit_Text_Expression (Tree (Curr).Left_Child, Module_Name, Ok);
                  Emit_Raw
                    (", " &
                     (if Tree (Curr).Right_Child = 0 and then Tree (Idx).Kind = AST_Print_Stmt
                      then "True"
                      else "False") &
                     ");",
                     Ok);
                  Emit_Newline (Ok);
                  Curr := Tree (Curr).Right_Child;
               end loop;

            when AST_Input_Stmt =>
               declare
                  Prompt_Node : Node_Index := Tree (Idx).Left_Child;
                  Target_Node : Node_Index := Tree (Idx).Right_Child;
                  Target_Tag  : ALB_Type_Tag := Type_Binary;
                  Sym_Idx     : Natural := 0;

                  procedure Emit_Input_Prompt is
                  begin
                     if Prompt_Node /= 0 then
                        Emit_Text_Expression (Prompt_Node, Module_Name, Ok);
                     else
                        Emit_Raw ("ALB_STR("""")", Ok);
                     end if;
                  end Emit_Input_Prompt;

                  procedure Emit_Safe_Numeric_Input is
                  begin
                     if Sym_Idx > 0 and then Symbols (Sym_Idx).Alias_Idx > 0 then
                        declare
                           Alias_Idx : constant Natural := Symbols (Sym_Idx).Alias_Idx;
                           Cast_Type : constant String :=
                             Unbounded_String (Alias_Type_Name (Alias_Idx));
                        begin
                           if Aliases (Alias_Idx).Has_Range then
                              Emit_Indent (Ok);
                              Emit_Target (Target_Node, Module_Name, Ok);
                              Emit_Raw (" := ", Ok);
                              Emit_Raw
                                (Cast_Type & "(ALBA_IO.Read_Integer_In_Range (",
                                 Ok);
                              Emit_Input_Prompt;
                              Emit_Raw
                                (", " &
                                 Range_Bound_Image (Aliases (Alias_Idx).Range_Low) &
                                 ", " &
                                 Range_Bound_Image (Aliases (Alias_Idx).Range_High) &
                                 ", " &
                                 Range_Bound_Image (Aliases (Alias_Idx).Range_Low) &
                                 "));",
                                 Ok);
                              Emit_Newline (Ok);
                              Emit_Sync_Target_To_VAS (Target_Node, Module_Name, Ok);
                              return;
                           end if;
                        end;
                     end if;

                     Emit_Indent (Ok);
                     Emit_Target (Target_Node, Module_Name, Ok);
                     Emit_Raw (" := ", Ok);
                     case Target_Tag is
                        when Type_U8 =>
                           Emit_Raw ("U8 (ALBA_IO.Read_Integer (", Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                        when Type_U16 =>
                           Emit_Raw ("U16 (ALBA_IO.Read_Integer (", Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                        when Type_U32 =>
                           Emit_Raw ("U32 (ALBA_IO.Read_Integer (", Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                        when Type_U64 =>
                           Emit_Raw
                             ("U64 (S64 (ALBA_IO.Read_Integer (",
                              Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0)));", Ok);
                        when Type_S8 =>
                           Emit_Raw ("S8 (ALBA_IO.Read_Integer (", Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                        when Type_S16 =>
                           Emit_Raw ("S16 (ALBA_IO.Read_Integer (", Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                        when Type_S32 =>
                           Emit_Raw ("S32 (ALBA_IO.Read_Integer (", Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                        when Type_S64 =>
                           Emit_Raw
                             ("S64 (ALBA_IO.Read_Integer (",
                              Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                        when others =>
                           Emit_Raw ("S32 (ALBA_IO.Read_Integer (", Ok);
                           Emit_Input_Prompt;
                           Emit_Raw (", 0));", Ok);
                     end case;
                     Emit_Newline (Ok);
                     Emit_Sync_Target_To_VAS (Target_Node, Module_Name, Ok);
                  end Emit_Safe_Numeric_Input;
               begin
                  if Target_Node = 0 then
                     Target_Node := Prompt_Node;
                     Prompt_Node := 0;
                  end if;
                  if Target_Node /= 0 then
                     Target_Tag := Infer_Type (Target_Node, Module_Name);
                     Sym_Idx := 0;
                     if Tree (Target_Node).Kind in AST_Var_Expr | AST_Logic_Var then
                        Sym_Idx :=
                          Find_Symbol
                            (Resolve_Name
                               (Raw_Lexeme (Tree (Target_Node).Token_Index),
                                Module_Name));
                        if Sym_Idx > 0 and then Target_Tag = Type_None then
                           Target_Tag := Symbols (Sym_Idx).Tag;
                        end if;
                     end if;
                     if Target_Tag = Type_Binary then
                        Emit_Indent (Ok);
                        Emit_Target (Target_Node, Module_Name, Ok);
                        Emit_Raw (" := ALBA_IO.Input(", Ok);
                        Emit_Input_Prompt;
                        Emit_Raw (");", Ok);
                        Emit_Newline (Ok);
                        Emit_Sync_Target_To_VAS (Target_Node, Module_Name, Ok);
                     elsif Target_Tag in Type_U8 | Type_U16 | Type_U32 | Type_U64
                       | Type_S8 | Type_S16 | Type_S32 | Type_S64
                     then
                        Emit_Safe_Numeric_Input;
                     else
                        Emit_Indent (Ok);
                        Emit_Target (Target_Node, Module_Name, Ok);
                        Emit_Raw (" := ALBA_IO.Input(", Ok);
                        Emit_Input_Prompt;
                        Emit_Raw (");", Ok);
                        Emit_Newline (Ok);
                        Emit_Sync_Target_To_VAS (Target_Node, Module_Name, Ok);
                     end if;
                  end if;
               end;

            when AST_Readline_Stmt =>
               declare
                  Target_Node : Node_Index := Tree (Idx).Right_Child;
               begin
                  if Target_Node = 0 then
                     Target_Node := Tree (Idx).Left_Child;
                  end if;
                  if Target_Node /= 0 then
                     Emit_Indent (Ok);
                     Emit_Target (Target_Node, Module_Name, Ok);
                     Emit_Raw (" := ALBA_IO.Readline;", Ok);
                     Emit_Newline (Ok);
                     Emit_Sync_Target_To_VAS (Target_Node, Module_Name, Ok);
                  else
                     Emit_Line ("null;", Ok);
                  end if;
               end;

            when AST_Locate_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_IO.Locate(Integer(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
               Emit_Raw ("), Integer(", Ok);
               if Tree (Idx).Right_Child /= 0 then
                  Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_S32, False, Ok);
               else
                  Emit_Raw ("1", Ok);
               end if;
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Msg_Box =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_IO.Message_Box(", Ok);
               Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw (", ", Ok);
               if Tree (Idx).Right_Child /= 0 then
                  Emit_Text_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
               else
                  Emit_Raw ("ALB_STR("""")", Ok);
               end if;
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Delay_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Graphics.Pause_For(Natural(Integer(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, False, Ok);
               Emit_Raw (")));", Ok);
               Emit_Newline (Ok);

            when AST_Break_Stmt =>
               Emit_Line ("exit;", Ok);

            when AST_Cls_Stmt =>
               Emit_Line ("ALBA_IO.Clear_Screen;", Ok);

            when AST_Continue_Stmt =>
               if Current_Continue_Label'Length > 0 then
                  Emit_Line ("goto " & Current_Continue_Label & ";", Ok);
               else
                  Emit_Line ("null;", Ok);
               end if;

            when AST_Temporal_Block | AST_Atomic_Block | AST_Reversible_Block =>
               Emit_Block (Tree (Idx).Left_Child, Module_Name, Ok);

            when AST_Select_Stmt | AST_Match_Stmt =>
               declare
                  Case_Node : Node_Index := Tree (Idx).Right_Child;
                  First_Arm : Boolean := True;
                  Match_Var : constant String := "alb_match_" & Trim_Image (Integer (Idx));
               begin
                  Emit_Line ("declare", Ok);
                  Increase_Indent;
                  Emit_Indent (Ok);
                  Emit_Raw (Match_Var & " : constant U64 := ", Ok);
                  Emit_Assigned_Expression
                    (Tree (Idx).Left_Child, Module_Name, Type_U64, Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  Decrease_Indent;
                  Emit_Line ("begin", Ok);
                  Increase_Indent;
                  while Case_Node /= 0 loop
                     if Tree (Case_Node).Left_Child = 0 then
                        if First_Arm then
                           Emit_Line ("if True then", Ok);
                        else
                           Emit_Line ("else", Ok);
                        end if;
                     else
                        Emit_Indent (Ok);
                        if First_Arm then
                           Emit_Raw ("if " & Match_Var & " = ", Ok);
                        else
                           Emit_Raw ("elsif " & Match_Var & " = ", Ok);
                        end if;
                        Emit_Assigned_Expression
                          (Tree (Case_Node).Left_Child, Module_Name, Type_U64, Ok);
                        Emit_Raw (" then", Ok);
                        Emit_Newline (Ok);
                     end if;
                     Increase_Indent;
                     Emit_Block (Tree (Case_Node).Right_Child, Module_Name, Ok);
                     Decrease_Indent;
                     First_Arm := False;
                     Case_Node := Tree (Case_Node).Next_Sibling;
                  end loop;
                  Emit_Line ("end if;", Ok);
                  Decrease_Indent;
                  Emit_Line ("end;", Ok);
               end;

            when AST_SwapPop_Stmt =>
               if Tree (Idx).Left_Child /= 0
                 and then Tree (Tree (Idx).Left_Child).Kind = AST_Var_Expr
                 and then Tree (Tree (Idx).Left_Child).Left_Child /= 0
               then
                  declare
                     Group_Name : constant String :=
                       Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index), Module_Name);
                  begin
                     for I in 1 .. Parallel_Count loop
                        if Parallel_Fields (I).Active
                          and then Name_Text (Parallel_Fields (I).Group_Name, Parallel_Fields (I).Group_Name_Len) = Group_Name
                        then
                           Emit_Indent (Ok);
                           Emit_Raw
                             (Name_Text (Parallel_Fields (I).Backing_Name, Parallel_Fields (I).Backing_Name_Len) &
                              "(Positive(",
                              Ok);
                           Emit_Expression (Tree (Tree (Idx).Left_Child).Left_Child, Module_Name, Type_S32, False, Ok);
                           Emit_Raw (")) := " &
                             Name_Text (Parallel_Fields (I).Backing_Name, Parallel_Fields (I).Backing_Name_Len) &
                             "(Positive(",
                             Ok);
                           Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_S32, False, Ok);
                           Emit_Raw ("));", Ok);
                           Emit_Newline (Ok);
                        end if;
                     end loop;
                     Emit_Indent (Ok);
                     Emit_Target (Tree (Idx).Right_Child, Module_Name, Ok);
                     Emit_Raw (" := ", Ok);
                     Emit_Raw
                       (Ada_Type_Name (Infer_Type (Tree (Idx).Right_Child, Module_Name)) & "(",
                        Ok);
                     Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_S32, False, Ok);
                     Emit_Raw (" - 1);", Ok);
                     Emit_Newline (Ok);
                  end;
               else
                  Emit_Line ("null;", Ok);
               end if;

            when AST_File_Write =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_IO.File_Write(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (", ", Ok);
               Emit_Text_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_File_Close =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_IO.File_Close(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Load_Stmt =>
               declare
                  Target_Sym : constant Natural :=
                    (if Tree (Idx).Right_Child /= 0
                        and then Tree (Tree (Idx).Right_Child).Kind = AST_Var_Expr
                        and then Tree (Tree (Idx).Right_Child).Left_Child = 0
                     then Find_Symbol
                       (Resolve_Name
                          (Raw_Lexeme (Tree (Tree (Idx).Right_Child).Token_Index),
                           Module_Name))
                     else 0);
               begin
                  Emit_Indent (Ok);
                  if Target_Sym > 0 and then Symbols (Target_Sym).Kind = Sym_Array then
                     Emit_Raw ("ALBA_IO.Load_File(", Ok);
                     Emit_Target (Tree (Idx).Right_Child, Module_Name, Ok);
                     Emit_Raw (", ", Ok);
                     Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                     Emit_Newline (Ok);
                  else
                     Emit_Target (Tree (Idx).Right_Child, Module_Name, Ok);
                     Emit_Raw (" := ALBA_IO.Load_File(", Ok);
                     Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                     Emit_Raw (");", Ok);
                     Emit_Newline (Ok);
                     Emit_Sync_Target_To_VAS (Tree (Idx).Right_Child, Module_Name, Ok);
                  end if;
               end;

            when AST_Flush_Stmt =>
               declare
                  Source_Sym : constant Natural :=
                    (if Tree (Idx).Left_Child /= 0
                        and then Tree (Tree (Idx).Left_Child).Kind = AST_Var_Expr
                        and then Tree (Tree (Idx).Left_Child).Left_Child = 0
                     then Find_Symbol
                       (Resolve_Name
                          (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                           Module_Name))
                     else 0);
               begin
                  Emit_Indent (Ok);
                  Emit_Raw ("ALBA_IO.Flush_File(", Ok);
                  if Source_Sym > 0 and then Symbols (Source_Sym).Kind = Sym_Array then
                     Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  else
                     Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
                  end if;
                  Emit_Raw (", ", Ok);
                  Emit_Text_Expression (Tree (Idx).Right_Child, Module_Name, Ok);
                  Emit_Raw (");", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Spawn_Stmt =>
               if Tree (Idx).Left_Child /= 0 then
                  if Tree (Tree (Idx).Left_Child).Kind = AST_Func_Call then
                     Emit_Indent (Ok);
                     Emit_Function_Call (Tree (Idx).Left_Child, Module_Name, Type_None, False, Ok);
                     Emit_Raw (";", Ok);
                     Emit_Newline (Ok);
                  else
                     Emit_Line ("null;", Ok);
                  end if;
               else
                  Emit_Line ("null;", Ok);
               end if;

            when AST_Sync_Stmt =>
               Emit_Line ("ALBA_Graphics.Pause_For(16);", Ok);

            when AST_Save_State =>
               Emit_Line ("ALBA_Save_State;", Ok);

            when AST_Load_State =>
               Emit_Line ("ALBA_Load_State;", Ok);

            when AST_Claim_Stmt =>
               declare
                  Target_Tag : constant ALB_Type_Tag :=
                    Infer_Type (Tree (Idx).Left_Child, Module_Name);
               begin
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" := ", Ok);
                  if Target_Tag = Type_U64 then
                     Emit_Raw ("ALBA_GC.Claim", Ok);
                  else
                     Emit_Raw (Ada_Type_Name (Target_Tag) & "(ALBA_GC.Claim)", Ok);
                  end if;
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Drop_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_GC.Drop(U64(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Sweep_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_GC.Sweep(U64(", Ok);
               Emit_Expression (Tree (Idx).Left_Child, Module_Name, Type_U64, False, Ok);
               Emit_Raw ("));", Ok);
               Emit_Newline (Ok);

            when AST_Bind_Stmt =>
               declare
                  Parent_Node : constant Node_Index := Tree (Idx).Left_Child;
                  Arg_List    : Node_Index := Tree (Idx).Right_Child;
                  Child_1     : Node_Index := 0;
                  Child_2     : Node_Index := 0;
               begin
                  if Arg_List /= 0 and then Tree (Arg_List).Kind = AST_Arg_List then
                     Child_1 := Tree (Arg_List).Left_Child;
                  else
                     Child_1 := Arg_List;
                  end if;
                  if Child_1 /= 0 then
                     Child_2 := Tree (Child_1).Next_Sibling;
                  end if;

                  Emit_Indent (Ok);
                  Emit_Raw ("ALBA_GC.Bind(U64(", Ok);
                  Emit_Expression (Parent_Node, Module_Name, Type_U64, False, Ok);
                  Emit_Raw ("), U64(", Ok);
                  if Child_1 /= 0 then
                     Emit_Expression (Child_1, Module_Name, Type_U64, False, Ok);
                  else
                     Emit_Raw ("0", Ok);
                  end if;
                  Emit_Raw ("), U64(", Ok);
                  if Child_2 /= 0 then
                     Emit_Expression (Child_2, Module_Name, Type_U64, False, Ok);
                  else
                     Emit_Raw ("0", Ok);
                  end if;
                  Emit_Raw ("));", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Rev_Add_Stmt | AST_Rev_Sub_Stmt | AST_Rev_Xor_Stmt =>
               declare
                  Target_Tag : constant ALB_Type_Tag :=
                    Infer_Type (Tree (Idx).Left_Child, Module_Name);
               begin
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" := " & Ada_Type_Name (Target_Tag) & "(", Ok);
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Target_Tag, False, Ok);
                  case Tree (Idx).Kind is
                     when AST_Rev_Add_Stmt =>
                        Emit_Raw (" + ", Ok);
                     when AST_Rev_Sub_Stmt =>
                        Emit_Raw (" - ", Ok);
                     when others =>
                        Emit_Raw (" xor ", Ok);
                  end case;
                  Emit_Assigned_Expression (Tree (Idx).Right_Child, Module_Name, Target_Tag, Ok);
                  Emit_Raw (");", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Rev_Rol_Stmt | AST_Rev_Ror_Stmt =>
               declare
                  Target_Tag : constant ALB_Type_Tag :=
                    Infer_Type (Tree (Idx).Left_Child, Module_Name);
                  Width_Bits : constant Natural :=
                    (case Target_Tag is
                        when Type_U8  => 8,
                        when Type_U16 => 16,
                        when Type_U32 | Type_S32 => 32,
                        when others => 64);
               begin
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" := " & Ada_Type_Name (Target_Tag) & "(", Ok);
                  if Tree (Idx).Kind = AST_Rev_Rol_Stmt then
                     Emit_Raw ("ALB_ROL(U64(", Ok);
                  else
                     Emit_Raw ("ALB_ROR(U64(", Ok);
                  end if;
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Target_Tag, False, Ok);
                  Emit_Raw ("), U32(", Ok);
                  Emit_Expression (Tree (Idx).Right_Child, Module_Name, Type_U32, False, Ok);
                  Emit_Raw ("), " & Trim_Image (Integer (Width_Bits)) & "))", Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Rev_Swap_Stmt =>
               declare
                  Target_Tag : constant ALB_Type_Tag :=
                    Infer_Type (Tree (Idx).Left_Child, Module_Name);
               begin
                  Emit_Line ("declare", Ok);
                  Increase_Indent;
                  Emit_Indent (Ok);
                  Emit_Raw ("alba_swap_tmp_" & Trim_Image (Integer (Idx)) & " : constant " &
                            Ada_Type_Name (Target_Tag) & " := ", Ok);
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Target_Tag, False, Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  Decrease_Indent;
                  Emit_Line ("begin", Ok);
                  Increase_Indent;
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" := ", Ok);
                  Emit_Assigned_Expression (Tree (Idx).Right_Child, Module_Name, Target_Tag, Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Right_Child, Module_Name, Ok);
                  Emit_Raw (" := alba_swap_tmp_" & Trim_Image (Integer (Idx)) & ";", Ok);
                  Emit_Newline (Ok);
                  Decrease_Indent;
                  Emit_Line ("end;", Ok);
               end;

            when AST_Rev_Not_Stmt =>
               declare
                  Target_Tag : constant ALB_Type_Tag :=
                    Infer_Type (Tree (Idx).Left_Child, Module_Name);
               begin
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" := not ", Ok);
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Target_Tag, False, Ok);
                  Emit_Raw (";", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Rev_Neg_Stmt =>
               declare
                  Target_Tag : constant ALB_Type_Tag :=
                    Infer_Type (Tree (Idx).Left_Child, Module_Name);
               begin
                  Emit_Indent (Ok);
                  Emit_Target (Tree (Idx).Left_Child, Module_Name, Ok);
                  Emit_Raw (" := " & Ada_Type_Name (Target_Tag) & "(0 - ", Ok);
                  Emit_Expression (Tree (Idx).Left_Child, Module_Name, Target_Tag, False, Ok);
                  Emit_Raw (");", Ok);
                  Emit_Newline (Ok);
               end;

            when AST_Assert_Stmt | AST_Retract_Stmt =>
               Emit_Indent (Ok);
               if Tree (Idx).Kind = AST_Assert_Stmt then
                  Emit_Raw ("ALBA_Logic.Assert_Fact(", Ok);
               else
                  Emit_Raw ("ALBA_Logic.Retract_Fact(", Ok);
               end if;
               Emit_Logic_Hash (Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index)), Ok);
               Emit_Raw (", ", Ok);
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Assigned_Expression (Tree (Idx).Left_Child, Module_Name, Type_S32, Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);
               Emit_Knows_Change_Notify
                 (Safe_Name (Raw_Lexeme (Tree (Idx).Token_Index)),
                  Tree (Idx).Left_Child,
                  Module_Name,
                  Ok);

            when AST_Knows_Fact =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Logic.Assert_Fact(", Ok);
               Emit_Logic_Hash (Predicate_Name_Of (Tree (Idx).Left_Child), Ok);
               Emit_Raw (", ", Ok);
               if Tree (Idx).Right_Child /= 0 then
                  Emit_Assigned_Expression (Tree (Idx).Right_Child, Module_Name, Type_S32, Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);

            when AST_Update_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Logic.Update_Fact(", Ok);
               Emit_Logic_Hash (Predicate_Name_Of (Tree (Idx).Left_Child), Ok);
               Emit_Raw (", ", Ok);
               if Predicate_Arg_Node (Tree (Idx).Left_Child) /= 0 then
                  Emit_Assigned_Expression
                    (Predicate_Arg_Node (Tree (Idx).Left_Child),
                     Module_Name,
                     Type_S32,
                     Ok);
               else
                  Emit_Raw ("0", Ok);
               end if;
               Emit_Raw (", ", Ok);
               Emit_Assigned_Expression (Tree (Idx).Right_Child, Module_Name, Type_S32, Ok);
               Emit_Raw (");", Ok);
               Emit_Newline (Ok);
               Emit_Knows_Change_Notify
                 (Predicate_Name_Of (Tree (Idx).Left_Child),
                  Tree (Idx).Right_Child,
                  Module_Name,
                  Ok);

            when AST_Findall_Query =>
               declare
                  Pred_Node  : constant Node_Index := Tree (Idx).Left_Child;
                  Target_Node : constant Node_Index := Tree (Idx).Right_Child;
                  Target_Name : constant String :=
                    Resolve_Name (Raw_Lexeme (Tree (Target_Node).Token_Index), Module_Name);
                  Target_Sym : constant Natural := Find_Symbol (Target_Name);
                  Target_Tag : constant ALB_Type_Tag :=
                    (if Target_Sym > 0 then Symbols (Target_Sym).Tag else Type_U16);
                  Limit_Text : constant String :=
                    (if Target_Sym > 0 and then Symbols (Target_Sym).Dims (1) > 0
                     then Trim_Image (Integer (Symbols (Target_Sym).Dims (1)))
                     else "1");
               begin
                  Emit_Line ("declare", Ok);
                  Increase_Indent;
                  Emit_Line
                    ("alba_find_count_" & Trim_Image (Integer (Idx)) &
                     " : Natural := 0;",
                     Ok);
                  Decrease_Indent;
                  Emit_Line ("begin", Ok);
                  Increase_Indent;
                  Emit_Indent (Ok);
                  Emit_Raw ("ALBA_Logic.Find_All(", Ok);
                  Emit_Logic_Hash (Predicate_Name_Of (Pred_Node), Ok);
                  Emit_Raw (");", Ok);
                  Emit_Newline (Ok);
                  Emit_Line
                    ("alba_find_count_" & Trim_Image (Integer (Idx)) &
                     " := Natural'Min(ALBA_Logic.Find_Result_Count, " &
                     Limit_Text &
                     ");",
                     Ok);
                  Emit_Line
                    ("for alba_find_i_" & Trim_Image (Integer (Idx)) &
                     " in 1 .. alba_find_count_" & Trim_Image (Integer (Idx)) &
                     " loop",
                     Ok);
                  Increase_Indent;
                  Emit_Indent (Ok);
                  Emit_Raw (Target_Name & "(Positive(alba_find_i_" & Trim_Image (Integer (Idx)) & ")) := ", Ok);
                  Emit_Raw (Ada_Type_Name (Target_Tag) & "(ALBA_Logic.Find_Result(Positive(alba_find_i_" &
                            Trim_Image (Integer (Idx)) & ")));", Ok);
                  Emit_Newline (Ok);
                  Decrease_Indent;
                  Emit_Line ("end loop;", Ok);
                  Decrease_Indent;
                  Emit_Line ("end;", Ok);
               end;

            when AST_Rule_Decl | AST_Constraint_Decl =>
               Emit_Rule_Registration (Idx, Module_Name, Ok);

            when AST_Predicate_Decl | AST_Knows_Change | AST_Comptime_Block =>
               null;

            when AST_Try_Stmt =>
               Emit_Line ("begin", Ok);
               Increase_Indent;
               Emit_Block (Tree (Idx).Left_Child, Module_Name, Ok);
               Decrease_Indent;
               Emit_Line ("exception", Ok);
               Increase_Indent;
               Emit_Line ("when ALBA_User_Error =>", Ok);
               Increase_Indent;
               if Tree (Idx).Token_Index > 0 then
                  Emit_Indent (Ok);
                  Emit_Raw (Resolve_Name (Raw_Lexeme (Tree (Idx).Token_Index), Module_Name) & " := ALBA_Last_Error;", Ok);
                  Emit_Newline (Ok);
               end if;
               Emit_Block (Tree (Idx).Right_Child, Module_Name, Ok);
               Decrease_Indent;
               Decrease_Indent;
               Emit_Line ("end;", Ok);

            when AST_Throw_Stmt =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Last_Error := ", Ok);
               Emit_Text_Expression (Tree (Idx).Left_Child, Module_Name, Ok);
               Emit_Raw (";", Ok);
               Emit_Newline (Ok);
               Emit_Line ("raise ALBA_User_Error;", Ok);

            when AST_Enable_Ada_Block =>
               Emit_Line ("declare", Ok);
               Increase_Indent;
               Emit_Line
                 ("procedure ALBA_Unsafe_Block_" &
                  Trim_Image (Integer (Idx)) &
                  " is",
                  Ok);
               Increase_Indent;
               Emit_Line ("pragma SPARK_Mode (Off);", Ok);
               Decrease_Indent;
               Emit_Line ("begin", Ok);
               Increase_Indent;
               Emit_Line (Extract_Ada_Block_Body (Raw_Lexeme (Tree (Idx).Token_Index)), Ok);
               Decrease_Indent;
               Emit_Line
                 ("end ALBA_Unsafe_Block_" &
                  Trim_Image (Integer (Idx)) &
                  ";",
                  Ok);
               Decrease_Indent;
               Emit_Line ("begin", Ok);
               Increase_Indent;
               Emit_Line
                 ("ALBA_Unsafe_Block_" &
                  Trim_Image (Integer (Idx)) &
                  ";",
                  Ok);
               Decrease_Indent;
               Emit_Line ("end;", Ok);

            when AST_Advance_Stmt =>
               Emit_Line ("for alba_advance in 1 .. 1 loop", Ok);
               Increase_Indent;
               for I in 1 .. Symbol_Count loop
                  if Symbols (I).Active and then Symbols (I).Kind = Sym_Temporal then
                     Emit_Line
                       (Name_Text (Symbols (I).Name, Symbols (I).Name_Len) &
                        "_head := (" &
                        Name_Text (Symbols (I).Name, Symbols (I).Name_Len) &
                        "_head + 1) mod " &
                        Trim_Image (Integer (Symbols (I).History_Size)) &
                        ";",
                        Ok);
                     Emit_Line
                       (Name_Text (Symbols (I).Name, Symbols (I).Name_Len) &
                        "_timeline(" &
                        Name_Text (Symbols (I).Name, Symbols (I).Name_Len) &
                        "_head) := " &
                        Name_Text (Symbols (I).Name, Symbols (I).Name_Len) &
                        ";",
                        Ok);
                     Emit_Indent (Ok);
                     Emit_Raw
                       ("ALB_STORE_U64(Positive(" &
                        Trim_Image (Integer (Symbols (I).Timeline_Offset)) &
                        " + (" &
                        Name_Text (Symbols (I).Name, Symbols (I).Name_Len) &
                        "_head * 8)), ",
                        Ok);
                     case Symbols (I).Tag is
                        when Type_Boolean =>
                           Emit_Raw
                             ("ALB_BOOL_TO_U64(" &
                              Name_Text (Symbols (I).Name, Symbols (I).Name_Len) &
                              ")",
                              Ok);
                        when others =>
                           Emit_Raw
                             (Value_To_U64_Text
                                (Name_Text (Symbols (I).Name, Symbols (I).Name_Len),
                                 Symbols (I).Tag),
                              Ok);
                     end case;
                     Emit_Raw (");", Ok);
                     Emit_Newline (Ok);
                  end if;
               end loop;
               Decrease_Indent;
               Emit_Line ("end loop;", Ok);

            when AST_Runtime_Assert =>
               Emit_Line ("null;", Ok);

            when AST_Cease =>
               Emit_Line ("ALBA_Graphics.Request_Close;", Ok);

            when AST_Listen =>
               null;

            when others =>
               Emit_Line ("null; -- UNSUPPORTED " & Node_Kind'Image (Tree (Idx).Kind), Ok);
         end case;
      end Emit_Node;

      function Symbol_Matches_Scope
        (Sym_Idx     : Natural;
         Module_Name : String;
         Scope_Name  : String) return Boolean is
      begin
         if not Symbols (Sym_Idx).Active then
            return False;
         end if;

         if Name_Text (Symbols (Sym_Idx).Module_Name, Symbols (Sym_Idx).Module_Name_Len) /= Module_Name then
            return False;
         end if;

         if Name_Text (Symbols (Sym_Idx).Scope_Name, Symbols (Sym_Idx).Scope_Name_Len) /= Scope_Name then
            return False;
         end if;

         return True;
      end Symbol_Matches_Scope;

      procedure Emit_Symbol_Declaration
        (Sym_Idx : Natural;
         Ok      : in out Boolean) is
      begin
         case Symbols (Sym_Idx).Kind is
            when Sym_Scalar =>
               Emit_Line
                 (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len) &
                  " : " &
                  Symbol_Type_Name (Sym_Idx) &
                  " := " &
                  Symbol_Default_Value_Text (Sym_Idx) &
                  ";",
                  Ok);
            when Sym_Array =>
               declare
                  Elem_Count : constant Natural := Total_Array_Element_Count (Sym_Idx);
                  Array_Type : constant String := Ada_Array_Type_Name (Symbols (Sym_Idx).Tag);
                  Sym_Name   : constant String :=
                    Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len);
                  Row_Type   : constant String := Array_Row_Type_Name (Sym_Name);
               begin
                  if Array_Type'Length > 0 then
                     Emit_Line
                       (Sym_Name &
                        " : " & Array_Type &
                        " (Positive range 1 .. " &
                        Trim_Image (Integer (Elem_Count)) &
                        ") := (others => " &
                        Default_Value_Text (Symbols (Sym_Idx).Tag) & ");",
                        Ok);
                  else
                     -- Named row type so SAVE/RESTORE whole-array assigns type-check.
                     Emit_Line
                       ("type " & Row_Type &
                        " is array (Positive range 1 .. " &
                        Trim_Image (Integer (Elem_Count)) &
                        ") of " &
                        Ada_Type_Name (Symbols (Sym_Idx).Tag) &
                        ";",
                        Ok);
                     Emit_Line
                       (Sym_Name &
                        " : " & Row_Type &
                        " := (others => " &
                        Default_Value_Text (Symbols (Sym_Idx).Tag) & ");",
                        Ok);
                  end if;
               end;
            when Sym_Temporal =>
               Emit_Line
                 (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len) &
                  " : " & Ada_Type_Name (Symbols (Sym_Idx).Tag) &
                  " := " & Default_Value_Text (Symbols (Sym_Idx).Tag) & ";",
                  Ok);
               Emit_Line
                 (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len) &
                  "_head : Natural := 0;",
                  Ok);
               Emit_Line
                 (Name_Text (Symbols (Sym_Idx).Name, Symbols (Sym_Idx).Name_Len) &
                  "_timeline : array (Natural range 0 .. " &
                  Trim_Image (Integer (Natural'Max (1, Symbols (Sym_Idx).History_Size) - 1)) &
                  ") of " & Ada_Type_Name (Symbols (Sym_Idx).Tag) &
                  " := (others => " & Default_Value_Text (Symbols (Sym_Idx).Tag) & ");",
                  Ok);
            when Sym_Struct =>
               null;
            when Sym_Enum_Const =>
               null;
         end case;
      end Emit_Symbol_Declaration;

      procedure Emit_Global_Declarations (Ok : in out Boolean) is
      begin
         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Symbols (I).Active and then Symbols (I).Scope_Name_Len = 0 then
               Emit_Symbol_Declaration (I, Ok);
            end if;
         end loop;
      end Emit_Global_Declarations;

      procedure Emit_Advanced_Runtime_Support (Ok : in out Boolean) is
      begin
         if not (Need_F64_Runtime
                 or else Need_Pow_Runtime
                 or else Need_NN_Runtime
                 or else Need_Markov_Runtime
                 or else Need_Net_Runtime)
         then
            return;
         end if;

         Emit_Line ("-- ALBA non-SPARK runtime glue (CODING_RULES deterministic subset omitted when unused)", Ok);
         Emit_Newline (Ok);

         if Need_F64_Runtime or else Need_Pow_Runtime then
            if Need_F64_Runtime then
               Emit_Line
                 ("package ALB_F64_Math is new Ada.Numerics.Generic_Elementary_Functions (F64);",
                  Ok);
               Emit_Line ("function ALB_IMAGE_F64 (Value : F64) return ALB_Text is", Ok);
               Emit_Line ("begin", Ok);
               Increase_Indent;
               Emit_Line
                 ("return ALB_STR (Ada.Strings.Fixed.Trim (F64'Image (Value), Ada.Strings.Both));",
                  Ok);
               Decrease_Indent;
               Emit_Line ("end ALB_IMAGE_F64;", Ok);
               Emit_Newline (Ok);
            end if;
            Emit_Line ("function ALB_POW_S64 (Base : S64; Exponent : S64) return S64 is", Ok);
         Increase_Indent;
         Emit_Line ("Result : S64 := 1;", Ok);
         Emit_Line ("Factor : S64 := Base;", Ok);
         Emit_Line ("Power  : U64 := 0;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Exponent < 0 then", Ok);
         Increase_Indent;
         Emit_Line ("if Base = 1 then", Ok);
         Increase_Indent;
         Emit_Line ("return 1;", Ok);
         Decrease_Indent;
         Emit_Line ("elsif Base = -1 then", Ok);
         Increase_Indent;
         Emit_Line ("return (if (abs Exponent mod 2) = 0 then 1 else -1);", Ok);
         Decrease_Indent;
         Emit_Line ("else", Ok);
         Increase_Indent;
         Emit_Line ("return 0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("Power := U64 (Exponent);", Ok);
         Emit_Line ("while Power > 0 loop", Ok);
         Increase_Indent;
         Emit_Line ("if (Power mod 2) /= 0 then", Ok);
         Increase_Indent;
         Emit_Line ("Result := Result * Factor;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("Power := Power / 2;", Ok);
         Emit_Line ("if Power > 0 then", Ok);
         Increase_Indent;
         Emit_Line ("Factor := Factor * Factor;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Emit_Line ("return Result;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_POW_S64;", Ok);
         Emit_Newline (Ok);
            if Need_F64_Runtime then
         Emit_Line ("function ALB_POW_F64 (Base : F64; Exponent : F64) return F64 is", Ok);
         Increase_Indent;
         Emit_Line ("Int_Exponent : constant Long_Long_Integer := Long_Long_Integer (Exponent);", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Exponent = F64 (Int_Exponent)", Ok);
         Increase_Indent;
         Emit_Line ("and then abs Exponent <= F64 (Integer'Last) then", Ok);
         Increase_Indent;
         Emit_Line ("return Base ** Integer (Int_Exponent);", Ok);
         Decrease_Indent;
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("if Exponent = 0.5 and then Base >= 0.0 then", Ok);
         Increase_Indent;
         Emit_Line ("return ALB_F64_Math.Sqrt (Base);", Ok);
         Decrease_Indent;
         Emit_Line ("elsif Exponent = -0.5 and then Base > 0.0 then", Ok);
         Increase_Indent;
         Emit_Line ("return 1.0 / ALB_F64_Math.Sqrt (Base);", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("if Base = 0.0 then", Ok);
         Increase_Indent;
         Emit_Line ("return 0.0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("return ALB_F64_Math.Exp (Exponent * ALB_F64_Math.Log (Base));", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_POW_F64;", Ok);
         Emit_Newline (Ok);
            end if;
         end if;

         if Need_Markov_Runtime then
            Emit_Line ("type ALBA_F64_Array is array (Positive range <>) of F64;", Ok);
            Emit_Newline (Ok);

            Emit_Line ("function ALB_MARKOV_PREDICT (Matrix : ALBA_F64_Array; States : Positive; Current_State : U64) return U64 is", Ok);
         Increase_Indent;
         Emit_Line ("Row : Positive := 1;", Ok);
         Emit_Line ("Best_Col : Positive := 1;", Ok);
         Emit_Line ("Best_Weight : F64 := 0.0;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Matrix'Length = 0 or else Current_State = 0 then", Ok);
         Increase_Indent;
         Emit_Line ("return 0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("Row := Positive'Min(States, Positive(Integer(Current_State)));", Ok);
         Emit_Line ("Best_Weight := Matrix(((Row - 1) * States) + 1);", Ok);
         Emit_Line ("for Col in 2 .. States loop", Ok);
         Increase_Indent;
         Emit_Line ("if Matrix(((Row - 1) * States) + Col) > Best_Weight then", Ok);
         Increase_Indent;
         Emit_Line ("Best_Weight := Matrix(((Row - 1) * States) + Col);", Ok);
         Emit_Line ("Best_Col := Col;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Emit_Line ("return U64(Best_Col);", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_MARKOV_PREDICT;", Ok);
         Emit_Newline (Ok);
         end if;

         if Need_NN_Runtime then
         Emit_Line ("type ALBA_Int_Array is array (Positive range <>) of Integer;", Ok);
         Emit_Line ("type ALBA_Int_Array_Access is access all ALBA_Int_Array;", Ok);
         Emit_Line ("type ALBA_I64_Array_Access is access all ALB_I64_Array;", Ok);
         Emit_Line ("type ALBA_I64_Array_Access_Array is array (Positive range <>) of ALBA_I64_Array_Access;", Ok);
         Emit_Line ("type ALBA_I64_Array_Access_Array_Access is access all ALBA_I64_Array_Access_Array;", Ok);
         Emit_Line ("type ALBA_NN_Model is record", Ok);
         Increase_Indent;
         Emit_Line ("Sizes : ALBA_Int_Array_Access := null;", Ok);
         Emit_Line ("Activations : ALBA_Int_Array_Access := null;", Ok);
         Emit_Line ("Weights : ALBA_I64_Array_Access_Array_Access := null;", Ok);
         Emit_Line ("Biases : ALBA_I64_Array_Access_Array_Access := null;", Ok);
         Emit_Line ("State : ALBA_I64_Array_Access_Array_Access := null;", Ok);
         Decrease_Indent;
         Emit_Line ("end record;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("function ALB_NN_ACT (Code : Integer; Value : ALB_I64) return ALB_I64 is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("case Code is", Ok);
         Increase_Indent;
         Emit_Line ("when 1 => return (if Value > 0 then Value else 0);", Ok);
         Emit_Line ("when 2 => return (if Value > 0 then 1 else 0);", Ok);
         Emit_Line ("when 3 =>", Ok);
         Increase_Indent;
         Emit_Line ("if Value > 128 then return 1024; end if;", Ok);
         Emit_Line ("if Value < -128 then return -1024; end if;", Ok);
         Emit_Line ("return Value * 8;", Ok);
         Decrease_Indent;
         Emit_Line ("when others => return Value;", Ok);
         Decrease_Indent;
         Emit_Line ("end case;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_NN_ACT;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("function ALB_NN_SEED (Prev_Size : Integer; Curr_Size : Integer; Neuron_Index : Integer; Input_Index : Integer) return ALB_I64 is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Prev_Size <= 0 or else Curr_Size <= 0 then return 0; end if;", Ok);
         Emit_Line ("if Curr_Size = Prev_Size then return (if Input_Index = Neuron_Index then 256 else 0); end if;", Ok);
         Emit_Line ("if Prev_Size = Curr_Size * 2 then", Ok);
         Increase_Indent;
         Emit_Line ("if Input_Index = (Neuron_Index * 2) - 1 then return 256; end if;", Ok);
         Emit_Line ("if Input_Index = (Neuron_Index * 2) then return -256; end if;", Ok);
         Emit_Line ("return 0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("if Curr_Size > Prev_Size then return (if Input_Index = (((Neuron_Index - 1) mod Prev_Size) + 1) then 256 else 0); end if;", Ok);
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Input_Span : constant Integer := Integer'Max(1, Prev_Size / Curr_Size);", Ok);
         Emit_Line ("Base_Input : constant Integer := ((Neuron_Index - 1) * Input_Span) + 1;", Ok);
         Emit_Line ("Positive_In : constant Integer := Integer'Min(Prev_Size, Base_Input);", Ok);
         Emit_Line ("Negative_In : constant Integer := Integer'Min(Prev_Size, Base_Input + 1);", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Input_Span >= 2 then", Ok);
         Increase_Indent;
         Emit_Line ("if Input_Index = Positive_In then return 256; end if;", Ok);
         Emit_Line ("if Input_Index = Negative_In then return -128; end if;", Ok);
         Emit_Line ("return 0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("return (if Input_Index = Positive_In then 256 else 0);", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_NN_SEED;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("function ALB_NN_CREATE (Sizes : ALBA_Int_Array; Activations : ALBA_Int_Array) return ALBA_NN_Model is", Ok);
         Increase_Indent;
         Emit_Line ("Model : ALBA_NN_Model;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("Model.Sizes := new ALBA_Int_Array'(Sizes);", Ok);
         Emit_Line ("Model.Activations := new ALBA_Int_Array'(Activations);", Ok);
         Emit_Line ("Model.State := new ALBA_I64_Array_Access_Array(1 .. Sizes'Length);", Ok);
         Emit_Line ("for Layer in Sizes'Range loop", Ok);
         Increase_Indent;
         Emit_Line ("Model.State(Layer) := new ALB_I64_Array'(1 .. Positive'Max(1, Sizes(Layer)) => 0);", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Emit_Line ("if Sizes'Length > 1 then", Ok);
         Increase_Indent;
         Emit_Line ("Model.Weights := new ALBA_I64_Array_Access_Array(1 .. Sizes'Length - 1);", Ok);
         Emit_Line ("Model.Biases := new ALBA_I64_Array_Access_Array(1 .. Sizes'Length - 1);", Ok);
         Emit_Line ("for Layer in 2 .. Sizes'Length loop", Ok);
         Increase_Indent;
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Prev : constant Positive := Positive'Max(1, Sizes(Layer - 1));", Ok);
         Emit_Line ("Curr : constant Positive := Positive'Max(1, Sizes(Layer));", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("Model.Weights(Layer - 1) := new ALB_I64_Array'(1 .. Prev * Curr => 0);", Ok);
         Emit_Line ("Model.Biases(Layer - 1) := new ALB_I64_Array'(1 .. Curr => 0);", Ok);
         Emit_Line ("for Neuron in 1 .. Curr loop", Ok);
         Increase_Indent;
         Emit_Line ("for Input_Index in 1 .. Prev loop", Ok);
         Increase_Indent;
         Emit_Line ("Model.Weights(Layer - 1).all(((Neuron - 1) * Prev) + Input_Index) := ALB_NN_SEED(Prev, Curr, Neuron, Input_Index);", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("return Model;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_NN_CREATE;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALB_NN_INFER (Model : in out ALBA_NN_Model; Input : ALB_I64_Array; Output : in out ALB_I64_Array) is", Ok);
         Increase_Indent;
         Emit_Line ("Last_Layer : Positive := 1;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Model.State = null or else Model.Sizes = null or else Model.State'Length = 0 then", Ok);
         Increase_Indent;
         Emit_Line ("return;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("for I in Model.State(1).all'Range loop", Ok);
         Increase_Indent;
         Emit_Line ("Model.State(1).all(I) := (if I <= Input'Length then Input(I) else 0);", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Emit_Line ("for Layer in 2 .. Model.State'Length loop", Ok);
         Increase_Indent;
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Prev : ALBA_I64_Array_Access := Model.State(Layer - 1);", Ok);
         Emit_Line ("Curr : ALBA_I64_Array_Access := Model.State(Layer);", Ok);
         Emit_Line ("Weights : ALBA_I64_Array_Access := Model.Weights(Layer - 1);", Ok);
         Emit_Line ("Biases : ALBA_I64_Array_Access := Model.Biases(Layer - 1);", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("for I in Curr.all'Range loop", Ok);
         Increase_Indent;
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Acc : ALB_I64 := Biases.all(I);", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("for J in Prev.all'Range loop", Ok);
         Increase_Indent;
         Emit_Line ("Acc := Acc + (Prev.all(J) * Weights.all(((I - 1) * Prev.all'Length) + J));", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Emit_Line ("Curr.all(I) := ALB_NN_ACT((if Layer <= Model.Activations'Length then Model.Activations(Layer) else 0), Acc);", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Emit_Line ("Last_Layer := Model.State'Last;", Ok);
         Emit_Line ("for I in Output'Range loop", Ok);
         Increase_Indent;
         Emit_Line ("Output(I) := (if I <= Model.State(Last_Layer).all'Length then Model.State(Last_Layer).all(I) else 0);", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_NN_INFER;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALB_NN_TRAIN (Model : in out ALBA_NN_Model; Train_Data : ALB_I64_Array; Expect_Data : ALB_I64_Array; Epochs : U64) is", Ok);
         Increase_Indent;
         Emit_Line ("Epoch_Limit : constant Natural := Natural'Max(1, Natural(Integer(Epochs)));", Ok);
         Emit_Line ("Out_Size : constant Positive := (if Model.Sizes = null then 1 else Positive'Max(1, Model.Sizes(Model.Sizes'Last)));", Ok);
         Emit_Line ("Prev_Size : constant Positive := (if Model.Sizes = null or else Model.Sizes'Length < 2 then 1 else Positive'Max(1, Model.Sizes(Model.Sizes'Last - 1)));", Ok);
         Emit_Line ("Output : ALB_I64_Array(1 .. Out_Size) := (others => 0);", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Model.Weights = null or else Model.Biases = null or else Model.State = null then", Ok);
         Increase_Indent;
         Emit_Line ("return;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("for Epoch in 1 .. Epoch_Limit loop", Ok);
         Increase_Indent;
         Emit_Line ("ALB_NN_INFER(Model, Train_Data, Output);", Ok);
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Prev : ALBA_I64_Array_Access := Model.State(Model.State'Last - 1);", Ok);
         Emit_Line ("Weights : ALBA_I64_Array_Access := Model.Weights(Model.Weights'Last);", Ok);
         Emit_Line ("Biases : ALBA_I64_Array_Access := Model.Biases(Model.Biases'Last);", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("for I in 1 .. Out_Size loop", Ok);
         Increase_Indent;
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Got : constant ALB_I64 := Output(I);", Ok);
         Emit_Line ("Want : constant ALB_I64 := (if I <= Expect_Data'Length then Expect_Data(I) else 0);", Ok);
         Emit_Line ("ALBA_Delta : constant ALB_I64 := (if Got > Want then -1 elsif Got < Want then 1 else 0);", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("Biases.all(I) := Biases.all(I) + ALBA_Delta;", Ok);
         Emit_Line ("for J in 1 .. Prev_Size loop", Ok);
         Increase_Indent;
         Emit_Line ("if Prev.all(J) /= 0 then", Ok);
         Increase_Indent;
         Emit_Line ("Weights.all(((I - 1) * Prev_Size) + J) := Weights.all(((I - 1) * Prev_Size) + J) + ALBA_Delta;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_NN_TRAIN;", Ok);
         Emit_Newline (Ok);
         end if;

         if Need_Net_Runtime then
         Emit_Line ("type ALBA_Net_Socket is record", Ok);
         Increase_Indent;
         Emit_Line ("Active : Boolean := False;", Ok);
         Emit_Line ("Protocol : Natural := 1;", Ok);
         Emit_Line ("Port : Natural := 0;", Ok);
         Emit_Line ("Buffer_Size : Natural := 1;", Ok);
         Emit_Line ("Socket : Socket_Type := No_Socket;", Ok);
         Emit_Line ("Last_Peer : Sock_Addr_Type := No_Sock_Addr;", Ok);
         Emit_Line ("Has_Peer : Boolean := False;", Ok);
         Decrease_Indent;
         Emit_Line ("end record;", Ok);
         Emit_Line ("ALBA_Net_Table_Size : constant Positive := 32;", Ok);
         Emit_Line ("type ALBA_Net_Table is array (Positive range 1 .. ALBA_Net_Table_Size) of ALBA_Net_Socket;", Ok);
         Emit_Line ("ALBA_Net_Sockets : ALBA_Net_Table := (others => (Active => False, Protocol => 1, Port => 0, Buffer_Size => 1, Socket => No_Socket, Last_Peer => No_Sock_Addr, Has_Peer => False));", Ok);
         Emit_Line ("ALBA_Sockets_Ready : Boolean := False;", Ok);
         Emit_Line ("ALBA_Next_Net_Handle : Natural := 1;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALB_NET_ENSURE is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if not ALBA_Sockets_Ready then", Ok);
         Increase_Indent;
         Emit_Line ("GNAT.Sockets.Initialize;", Ok);
         Emit_Line ("ALBA_Sockets_Ready := True;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_NET_ENSURE;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("function ALB_NET_DEFINE (Protocol : Natural; Port : Natural; Buffer_Size : Natural) return U64 is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if ALBA_Next_Net_Handle > ALBA_Net_Table_Size then", Ok);
         Increase_Indent;
         Emit_Line ("return 0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("ALBA_Net_Sockets(ALBA_Next_Net_Handle) := (Active => True, Protocol => Protocol, Port => Port, Buffer_Size => Natural'Max(1, Buffer_Size), Socket => No_Socket, Last_Peer => No_Sock_Addr, Has_Peer => False);", Ok);
         Emit_Line ("ALBA_Next_Net_Handle := ALBA_Next_Net_Handle + 1;", Ok);
         Emit_Line ("return U64(ALBA_Next_Net_Handle - 1);", Ok);
         Decrease_Indent;
         Emit_Line ("end ALB_NET_DEFINE;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("function ALB_NET_LISTEN_SOCKET (Handle : U64; Protocol : Natural; Port : Natural; Buffer_Size : Natural) return U64 is", Ok);
         Increase_Indent;
         Emit_Line ("Use_Handle : U64 := Handle;", Ok);
         Emit_Line ("Slot : Positive := 1;", Ok);
         Emit_Line ("Address : Sock_Addr_Type := No_Sock_Addr;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("ALB_NET_ENSURE;", Ok);
         Emit_Line ("if Use_Handle = 0 or else Use_Handle > U64(ALBA_Net_Table_Size) or else not ALBA_Net_Sockets(Positive(Integer(Use_Handle))).Active then", Ok);
         Increase_Indent;
         Emit_Line ("Use_Handle := ALB_NET_DEFINE(Protocol, Port, Buffer_Size);", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("if Use_Handle = 0 then", Ok);
         Increase_Indent;
         Emit_Line ("return 0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("Slot := Positive(Integer(Use_Handle));", Ok);
         Emit_Line ("if ALBA_Net_Sockets(Slot).Socket = No_Socket then", Ok);
         Increase_Indent;
         Emit_Line ("Create_Socket(ALBA_Net_Sockets(Slot).Socket, Family_Inet, Socket_Datagram);", Ok);
         Emit_Line ("Address.Addr := Any_Inet_Addr;", Ok);
         Emit_Line ("Address.Port := Port_Type(ALBA_Net_Sockets(Slot).Port);", Ok);
         Emit_Line ("Bind_Socket(ALBA_Net_Sockets(Slot).Socket, Address);", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("return Use_Handle;", Ok);
         Decrease_Indent;
         Emit_Line ("exception", Ok);
         Increase_Indent;
         Emit_Line ("when others =>", Ok);
         Increase_Indent;
         Emit_Line ("return 0;", Ok);
         Decrease_Indent;
         Decrease_Indent;
         Emit_Line ("end ALB_NET_LISTEN_SOCKET;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALB_NET_RECEIVE (Handle : U64; Dest : in out ALB_U8_Array) is", Ok);
         Increase_Indent;
         Emit_Line ("Slot : Positive := 1;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("for I in Dest'Range loop Dest(I) := 0; end loop;", Ok);
         Emit_Line ("if Handle = 0 or else Handle > U64(ALBA_Net_Table_Size) then", Ok);
         Increase_Indent;
         Emit_Line ("return;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("Slot := Positive(Integer(Handle));", Ok);
         Emit_Line ("if not ALBA_Net_Sockets(Slot).Active or else ALBA_Net_Sockets(Slot).Socket = No_Socket then", Ok);
         Increase_Indent;
         Emit_Line ("return;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Packet : Stream_Element_Array(1 .. Stream_Element_Offset(Natural'Max(1, ALBA_Net_Sockets(Slot).Buffer_Size)));", Ok);
         Emit_Line ("Last : Stream_Element_Offset := 0;", Ok);
         Emit_Line ("Peer : Sock_Addr_Type := No_Sock_Addr;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("Receive_Socket(ALBA_Net_Sockets(Slot).Socket, Packet, Last, Peer);", Ok);
         Emit_Line ("ALBA_Net_Sockets(Slot).Last_Peer := Peer;", Ok);
         Emit_Line ("ALBA_Net_Sockets(Slot).Has_Peer := True;", Ok);
         Emit_Line ("for I in Dest'Range loop", Ok);
         Increase_Indent;
         Emit_Line ("if Stream_Element_Offset(I) <= Last then", Ok);
         Increase_Indent;
         Emit_Line ("Dest(I) := ALB_U8(Packet(Stream_Element_Offset(I)));", Ok);
         Decrease_Indent;
         Emit_Line ("else", Ok);
         Increase_Indent;
         Emit_Line ("Dest(I) := 0;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("exception", Ok);
         Increase_Indent;
         Emit_Line ("when others =>", Ok);
         Increase_Indent;
         Emit_Line ("null;", Ok);
         Decrease_Indent;
         Decrease_Indent;
         Emit_Line ("end ALB_NET_RECEIVE;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALB_NET_SEND (Handle : U64; Src : ALB_U8_Array) is", Ok);
         Increase_Indent;
         Emit_Line ("Slot : Positive := 1;", Ok);
         Emit_Line ("Sent_Last : Stream_Element_Offset := 0;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Handle = 0 or else Handle > U64(ALBA_Net_Table_Size) then", Ok);
         Increase_Indent;
         Emit_Line ("return;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("Slot := Positive(Integer(Handle));", Ok);
         Emit_Line ("if not ALBA_Net_Sockets(Slot).Active or else ALBA_Net_Sockets(Slot).Socket = No_Socket or else not ALBA_Net_Sockets(Slot).Has_Peer then", Ok);
         Increase_Indent;
         Emit_Line ("return;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("Count : constant Natural := Natural'Min(Src'Length, Natural'Max(1, ALBA_Net_Sockets(Slot).Buffer_Size));", Ok);
         Emit_Line ("Packet : Stream_Element_Array(1 .. Stream_Element_Offset(Natural'Max(1, Count)));", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("for I in 1 .. Count loop", Ok);
         Increase_Indent;
         Emit_Line ("Packet(Stream_Element_Offset(I)) := Stream_Element(Src(I));", Ok);
         Decrease_Indent;
         Emit_Line ("end loop;", Ok);
         Emit_Line ("Send_Socket(ALBA_Net_Sockets(Slot).Socket, Packet(1 .. Stream_Element_Offset(Count)), Sent_Last, ALBA_Net_Sockets(Slot).Last_Peer);", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Decrease_Indent;
         Emit_Line ("exception", Ok);
         Increase_Indent;
         Emit_Line ("when others =>", Ok);
         Increase_Indent;
         Emit_Line ("null;", Ok);
         Decrease_Indent;
         Decrease_Indent;
         Emit_Line ("end ALB_NET_SEND;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALB_NET_CLOSE (Handle : in out U64) is", Ok);
         Increase_Indent;
         Emit_Line ("Slot : Positive := 1;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if Handle = 0 or else Handle > U64(ALBA_Net_Table_Size) then", Ok);
         Increase_Indent;
         Emit_Line ("Handle := 0;", Ok);
         Emit_Line ("return;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("Slot := Positive(Integer(Handle));", Ok);
         Emit_Line ("if ALBA_Net_Sockets(Slot).Socket /= No_Socket then", Ok);
         Increase_Indent;
         Emit_Line ("Close_Socket(ALBA_Net_Sockets(Slot).Socket);", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Emit_Line ("ALBA_Net_Sockets(Slot) := (Active => False, Protocol => 1, Port => 0, Buffer_Size => 1, Socket => No_Socket, Last_Peer => No_Sock_Addr, Has_Peer => False);", Ok);
         Emit_Line ("Handle := 0;", Ok);
         Decrease_Indent;
         Emit_Line ("exception", Ok);
         Increase_Indent;
         Emit_Line ("when others =>", Ok);
         Increase_Indent;
         Emit_Line ("Handle := 0;", Ok);
         Decrease_Indent;
         Decrease_Indent;
         Emit_Line ("end ALB_NET_CLOSE;", Ok);
         Emit_Newline (Ok);
         end if;
      end Emit_Advanced_Runtime_Support;

      procedure Emit_Advanced_Declarations_From
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Curr : Node_Index := 0;
      begin
         if Idx = 0 or else not Ok then
            return;
         end if;

         case Tree (Idx).Kind is
            when AST_Program | AST_Block_Stmt =>
               Curr := Tree (Idx).Left_Child;
               while Curr /= 0 loop
                  Emit_Advanced_Declarations_From (Curr, Module_Name, Ok);
                  Curr := Tree (Curr).Next_Sibling;
               end loop;

            when AST_Module =>
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Advanced_Declarations_From
                    (Tree (Idx).Right_Child,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                     Ok);
               end if;

            when AST_Markov_Model_Decl =>
               declare
                  Name_Node   : constant Node_Index := Tree (Idx).Left_Child;
                  Model_Name  : constant String :=
                    (if Name_Node /= 0 and then Tree (Name_Node).Token_Index > 0
                     then Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index))
                     else "alb_markov");
                  Curr_Setting : Node_Index := Tree (Idx).Right_Child;
                  States_Node  : Node_Index := 0;
                  Matrix_Node  : Node_Index := 0;
                  Row_Node     : Node_Index := 0;
                  Elem_Node    : Node_Index := 0;
                  Line_Text    : String (1 .. 4096) := (others => ' ');
                  Line_Len     : Natural := 0;
                  First_Value  : Boolean := True;

                  procedure Append_Text (Text : String) is
                  begin
                     if Line_Len + Text'Length <= Line_Text'Length then
                        Line_Text (Line_Len + 1 .. Line_Len + Text'Length) := Text;
                        Line_Len := Line_Len + Text'Length;
                     else
                        Ok := False;
                     end if;
                  end Append_Text;
               begin
                  while Curr_Setting /= 0 loop
                     case Tree (Curr_Setting).Kind is
                        when AST_Markov_States =>
                           States_Node := Tree (Curr_Setting).Left_Child;
                        when AST_Markov_Transition_Matrix =>
                           Matrix_Node := Curr_Setting;
                        when others =>
                           null;
                     end case;
                     Curr_Setting := Tree (Curr_Setting).Next_Sibling;
                  end loop;

                  Emit_Line
                    ("ALB_MARKOV_" & Model_Name & "_STATES : constant Positive := " &
                     (if States_Node /= 0 and then Tree (States_Node).Token_Index > 0
                      then Raw_Lexeme (Tree (States_Node).Token_Index)
                      else "1") & ";",
                     Ok);

                  Line_Len := 0;
                  Append_Text ("ALB_MARKOV_" & Model_Name & " : constant ALBA_F64_Array := (");
                  if Matrix_Node /= 0 then
                     Row_Node := Tree (Matrix_Node).Left_Child;
                     while Row_Node /= 0 loop
                        Elem_Node := Tree (Row_Node).Left_Child;
                        while Elem_Node /= 0 loop
                           if not First_Value then
                              Append_Text (", ");
                           end if;
                           Append_Text (Raw_Lexeme (Tree (Elem_Node).Token_Index));
                           First_Value := False;
                           Elem_Node := Tree (Elem_Node).Next_Sibling;
                        end loop;
                        Row_Node := Tree (Row_Node).Next_Sibling;
                     end loop;
                  end if;
                  Append_Text (");");
                  if Ok then
                     Emit_Line (Line_Text (1 .. Line_Len), Ok);
                  end if;
                  Emit_Newline (Ok);
               end;

            when AST_Neural_Topology_Decl =>
               declare
                  Name_Node  : constant Node_Index := Tree (Idx).Left_Child;
                  Model_Name : constant String :=
                    (if Name_Node /= 0 and then Tree (Name_Node).Token_Index > 0
                     then Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index))
                     else "alb_nn");
                  Layer_Node : Node_Index := Tree (Idx).Right_Child;
                  Line_Text  : String (1 .. 4096) := (others => ' ');
                  Line_Len   : Natural := 0;

                  procedure Append_Text (Text : String) is
                  begin
                     if Line_Len + Text'Length <= Line_Text'Length then
                        Line_Text (Line_Len + 1 .. Line_Len + Text'Length) := Text;
                        Line_Len := Line_Len + Text'Length;
                     else
                        Ok := False;
                     end if;
                  end Append_Text;

                  function Activation_Code (Node : Node_Index) return String is
                  begin
                     if Node = 0 or else Tree (Node).Token_Index = 0 then
                        return "0";
                     elsif Upper_Safe_Name (Raw_Lexeme (Tree (Node).Token_Index)) = "RELU" then
                        return "1";
                     elsif Upper_Safe_Name (Raw_Lexeme (Tree (Node).Token_Index)) = "SIGMOID" then
                        return "2";
                     elsif Upper_Safe_Name (Raw_Lexeme (Tree (Node).Token_Index)) = "TANH" then
                        return "3";
                     else
                        return "0";
                     end if;
                  end Activation_Code;

                  First_Item : Boolean := True;
                  Layer_Pos   : Natural := 0;
               begin
                  Append_Text ("ALB_NN_" & Model_Name & " : ALBA_NN_Model := ALB_NN_CREATE((");
                  while Layer_Node /= 0 loop
                     Layer_Pos := Layer_Pos + 1;
                     if not First_Item then
                        Append_Text (", ");
                     end if;
                     Append_Text (Trim_Image (Integer (Layer_Pos)) & " => ");
                     if Tree (Layer_Node).Left_Child /= 0 and then Tree (Tree (Layer_Node).Left_Child).Token_Index > 0 then
                        Append_Text (Raw_Lexeme (Tree (Tree (Layer_Node).Left_Child).Token_Index));
                     else
                        Append_Text ("1");
                     end if;
                     First_Item := False;
                     Layer_Node := Tree (Layer_Node).Next_Sibling;
                  end loop;
                  Append_Text ("), (");
                  Layer_Node := Tree (Idx).Right_Child;
                  First_Item := True;
                  Layer_Pos := 0;
                  while Layer_Node /= 0 loop
                     Layer_Pos := Layer_Pos + 1;
                     if not First_Item then
                        Append_Text (", ");
                     end if;
                     Append_Text (Trim_Image (Integer (Layer_Pos)) & " => " & Activation_Code (Tree (Layer_Node).Right_Child));
                     First_Item := False;
                     Layer_Node := Tree (Layer_Node).Next_Sibling;
                  end loop;
                  Append_Text ("));");
                  if Ok then
                     Emit_Line (Line_Text (1 .. Line_Len), Ok);
                  end if;
                  Emit_Newline (Ok);
               end;

            when others =>
               null;
         end case;
      end Emit_Advanced_Declarations_From;

      function Has_Global_Temporals return Boolean is
      begin
         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then Symbols (I).Kind = Sym_Temporal
              and then Symbols (I).Scope_Name_Len = 0
            then
               return True;
            end if;
         end loop;
         return False;
      end Has_Global_Temporals;

      function Is_Global_Saveable_Symbol (Sym_Idx : Natural) return Boolean is
      begin
         return
           Symbols (Sym_Idx).Active
           and then Symbols (Sym_Idx).Scope_Name_Len = 0
           and then Symbols (Sym_Idx).Kind in Sym_Scalar | Sym_Array;
      end Is_Global_Saveable_Symbol;

      function Has_Global_Saveables return Boolean is
      begin
         for I in 1 .. Symbol_Count loop
            if Is_Global_Saveable_Symbol (I) then
               return True;
            end if;
         end loop;
         return False;
      end Has_Global_Saveables;

      procedure Emit_Save_State_Declarations (Ok : in out Boolean) is
      begin
         if not Need_Save_State then
            return;
         end if;
         Emit_Line ("ALBA_Save_Max : constant Natural := 16;", Ok);
         Emit_Line ("ALBA_Save_Top : Natural := 0;", Ok);
         if not Has_Global_Saveables and then not Has_Global_Temporals then
            return;
         end if;

         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Is_Global_Saveable_Symbol (I) then
               declare
                  Name : constant String :=
                    Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
               begin
                  if Symbols (I).Kind = Sym_Scalar then
                     Emit_Line
                       (Name & "_saved : array (Positive range 1 .. ALBA_Save_Max) of " &
                        Ada_Type_Name
                          (Symbols (I).Tag,
                           Name_Text
                             (Symbols (I).Struct_Name,
                              Symbols (I).Struct_Name_Len)) &
                        " := (others => " &
                        Default_Value_Text
                          (Symbols (I).Tag,
                           Name_Text
                             (Symbols (I).Struct_Name,
                              Symbols (I).Struct_Name_Len)) &
                        ");",
                        Ok);
                  else
                     declare
                        Elem_Count : constant Natural := Total_Array_Element_Count (I);
                        Row_Type   : constant String := Array_Row_Type_Name (Name);
                        Array_Type : constant String :=
                          Ada_Array_Type_Name (Symbols (I).Tag);
                     begin
                        if Array_Type'Length > 0 then
                           Emit_Line
                             (Name & "_saved : array (Positive range 1 .. ALBA_Save_Max) of " &
                              Array_Type &
                              " (Positive range 1 .. " &
                              Trim_Image (Integer (Elem_Count)) &
                              ") := (others => (others => " &
                              Default_Value_Text
                                (Symbols (I).Tag,
                                 Name_Text
                                   (Symbols (I).Struct_Name,
                                    Symbols (I).Struct_Name_Len)) &
                              "));",
                              Ok);
                        else
                           -- Reuse the live array's named row type (Name_t).
                           Emit_Line
                             (Name & "_saved : array (Positive range 1 .. ALBA_Save_Max) of " &
                              Row_Type &
                              " := (others => (others => " &
                              Default_Value_Text
                                (Symbols (I).Tag,
                                 Name_Text
                                   (Symbols (I).Struct_Name,
                                    Symbols (I).Struct_Name_Len)) &
                              "));",
                              Ok);
                        end if;
                     end;
                  end if;
               end;
            elsif Symbols (I).Active
              and then Symbols (I).Kind = Sym_Temporal
              and then Symbols (I).Scope_Name_Len = 0
            then
               declare
                  Name : constant String :=
                    Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
                  Hist : constant Natural :=
                    Natural'Max (1, Symbols (I).History_Size);
               begin
                  Emit_Line
                    (Name & "_saved : array (Positive range 1 .. ALBA_Save_Max) of " &
                     Ada_Type_Name (Symbols (I).Tag) &
                     " := (others => " & Default_Value_Text (Symbols (I).Tag) & ");",
                     Ok);
                  Emit_Line
                    (Name & "_saved_head : array (Positive range 1 .. ALBA_Save_Max) of Natural := (others => 0);",
                     Ok);
                  Emit_Line
                    (Name & "_saved_timeline : array (Positive range 1 .. ALBA_Save_Max, Natural range 0 .. " &
                     Trim_Image (Integer (Hist - 1)) &
                     ") of " &
                     Ada_Type_Name (Symbols (I).Tag) &
                     " := (others => (others => " & Default_Value_Text (Symbols (I).Tag) & "));",
                     Ok);
               end;
            end if;
         end loop;
      end Emit_Save_State_Declarations;

      procedure Emit_Save_State_Procedures (Ok : in out Boolean) is
      begin
         if not Need_Save_State then
            return;
         end if;
         Emit_Line ("procedure ALBA_Save_State is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if ALBA_Save_Top < ALBA_Save_Max then", Ok);
         Increase_Indent;
         Emit_Line ("ALBA_Save_Top := ALBA_Save_Top + 1;", Ok);
         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Is_Global_Saveable_Symbol (I) then
               declare
                  Name : constant String :=
                    Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
               begin
                  Emit_Line (Name & "_saved(ALBA_Save_Top) := " & Name & ";", Ok);
               end;
            elsif Symbols (I).Active
              and then Symbols (I).Kind = Sym_Temporal
              and then Symbols (I).Scope_Name_Len = 0
            then
               declare
                  Name : constant String :=
                    Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
                  Hist : constant Natural :=
                    Natural'Max (1, Symbols (I).History_Size);
               begin
                  Emit_Line (Name & "_saved(ALBA_Save_Top) := " & Name & ";", Ok);
                  Emit_Line (Name & "_saved_head(ALBA_Save_Top) := " & Name & "_head;", Ok);
                  Emit_Line
                    ("for alba_save_slot_" & Trim_Image (Integer (I)) &
                     " in 0 .. " & Trim_Image (Integer (Hist - 1)) & " loop",
                     Ok);
                  Increase_Indent;
                  Emit_Line
                    (Name & "_saved_timeline(ALBA_Save_Top, alba_save_slot_" &
                     Trim_Image (Integer (I)) & ") := " &
                     Name & "_timeline(alba_save_slot_" &
                     Trim_Image (Integer (I)) & ");",
                     Ok);
                  Decrease_Indent;
                  Emit_Line ("end loop;", Ok);
               end;
            end if;
         end loop;
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALBA_Save_State;", Ok);
         Emit_Newline (Ok);

         Emit_Line ("procedure ALBA_Load_State is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("if ALBA_Save_Top > 0 then", Ok);
         Increase_Indent;
         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Is_Global_Saveable_Symbol (I) then
               declare
                  Name        : constant String :=
                    Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
                  Struct_Name : constant String :=
                    Name_Text
                      (Symbols (I).Struct_Name,
                       Symbols (I).Struct_Name_Len);
                  Elem_Size   : constant Natural :=
                    Natural'Max (1, Symbol_Element_Size_Bytes (I));
                  Elem_Count  : constant Natural :=
                    (if Symbols (I).Kind = Sym_Array
                     then Total_Array_Element_Count (I)
                     else 1);
               begin
                  Emit_Line (Name & " := " & Name & "_saved(ALBA_Save_Top);", Ok);
                  if Symbols (I).VAS_Offset > 0 then
                     if Symbols (I).Kind = Sym_Array then
                        Emit_Line
                          ("for ALBA_Restore_Elem_" & Trim_Image (Integer (I)) &
                           " in 0 .. " & Trim_Image (Integer (Elem_Count - 1)) &
                           " loop",
                           Ok);
                        Increase_Indent;
                        Emit_Store_To_VAS_Text
                          (Trim_Image (Integer (Symbols (I).VAS_Offset)) &
                           " + (ALBA_Restore_Elem_" & Trim_Image (Integer (I)) &
                           " * " & Trim_Image (Integer (Elem_Size)) & ")",
                           Name & "(Positive(ALBA_Restore_Elem_" &
                           Trim_Image (Integer (I)) & " + 1))",
                           Symbols (I).Tag,
                           Struct_Name,
                           Ok);
                        Decrease_Indent;
                        Emit_Line ("end loop;", Ok);
                     else
                        Emit_Store_To_VAS_Text
                          (Trim_Image (Integer (Symbols (I).VAS_Offset)),
                           Name,
                           Symbols (I).Tag,
                           Struct_Name,
                           Ok);
                     end if;
                  end if;
               end;
            elsif Symbols (I).Active
              and then Symbols (I).Kind = Sym_Temporal
              and then Symbols (I).Scope_Name_Len = 0
            then
               declare
                  Name : constant String :=
                    Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
                  Hist : constant Natural :=
                    Natural'Max (1, Symbols (I).History_Size);
               begin
                  Emit_Line (Name & " := " & Name & "_saved(ALBA_Save_Top);", Ok);
                  Emit_Line (Name & "_head := " & Name & "_saved_head(ALBA_Save_Top);", Ok);
                  Emit_Line
                    ("for alba_load_slot_" & Trim_Image (Integer (I)) &
                     " in 0 .. " & Trim_Image (Integer (Hist - 1)) & " loop",
                     Ok);
                  Increase_Indent;
                  Emit_Line
                    (Name & "_timeline(alba_load_slot_" &
                     Trim_Image (Integer (I)) & ") := " &
                     Name & "_saved_timeline(ALBA_Save_Top, alba_load_slot_" &
                     Trim_Image (Integer (I)) & ");",
                     Ok);
                  Emit_Indent (Ok);
                  Emit_Raw
                    ("ALB_STORE_U64(Positive(" &
                     Trim_Image (Integer (Symbols (I).Timeline_Offset)) &
                     " + (alba_load_slot_" & Trim_Image (Integer (I)) &
                     " * 8)), ",
                     Ok);
                  if Symbols (I).Tag = Type_Boolean then
                     Emit_Raw
                       ("ALB_BOOL_TO_U64(" &
                        Name & "_timeline(alba_load_slot_" &
                        Trim_Image (Integer (I)) & "))",
                        Ok);
                  else
                     Emit_Raw
                       (Value_To_U64_Text
                          (Name & "_timeline(alba_load_slot_" &
                           Trim_Image (Integer (I)) & ")",
                           Symbols (I).Tag),
                        Ok);
                  end if;
                  Emit_Raw (");", Ok);
                  Emit_Newline (Ok);
                  Decrease_Indent;
                  Emit_Line ("end loop;", Ok);
               end;
            end if;
         end loop;
         Emit_Line ("ALBA_Save_Top := ALBA_Save_Top - 1;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
         Decrease_Indent;
         Emit_Line ("end ALBA_Load_State;", Ok);
         Emit_Newline (Ok);
      end Emit_Save_State_Procedures;

      procedure Emit_Local_Declarations
        (Module_Name : String;
         Scope_Name  : String;
         Ok          : in out Boolean) is
         Emitted_Any : Boolean := False;
      begin
         if Scope_Name'Length = 0 then
            return;
         end if;

         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Symbol_Matches_Scope (I, Module_Name, Scope_Name) then
               Emit_Symbol_Declaration (I, Ok);
               Emitted_Any := True;
            end if;
         end loop;

         if Emitted_Any then
            Emit_Newline (Ok);
         end if;
      end Emit_Local_Declarations;

      procedure Emit_Param_Local_Declarations (Ok : in out Boolean) is
         Emitted_Any : Boolean := False;
      begin
         for I in 1 .. Current_Param_Count loop
            exit when not Ok;
            if Current_Params (I).Active then
               Emit_Line
                 (Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len) &
                  " : " &
                  (if Current_Params (I).VAS_Offset > 0
                     and then not Current_Routine_Uses_Poke
                     and then not Tree_Assigns_Target
                           (Current_Routine_Body_Node,
                            Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len),
                            Name_Text (Current_Routine_Module, Current_Routine_Module_Len))
                   then "constant "
                   else "") &
                  Ada_Type_Name
                    (Current_Params (I).Tag,
                     Name_Text
                       (Current_Params (I).Struct_Name,
                        Current_Params (I).Struct_Name_Len)) &
                  " := " &
                  Name_Text
                    (Current_Params (I).Formal_Name,
                     Current_Params (I).Formal_Name_Len) &
                  ";",
                  Ok);
               Emitted_Any := True;
            end if;
         end loop;

         if Emitted_Any then
            Emit_Newline (Ok);
         end if;
      end Emit_Param_Local_Declarations;

      procedure Emit_Frame_Helper_Declarations
        (Module_Name : String;
         Scope_Name  : String;
         Ok          : in out Boolean) is
      begin
         if Current_Frame_Size = 0 then
            return;
         end if;

         Emit_Line ("procedure ALBA_Sync_Frame_To_VAS is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         for I in 1 .. Current_Param_Count loop
            exit when not Ok;
            if Current_Params (I).Active and then Current_Params (I).VAS_Offset > 0 then
               Emit_Store_To_VAS_Text
                 ("ALBA_Frame_Base + " & Trim_Image (Integer (Current_Params (I).VAS_Offset)),
                  Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len),
                  Current_Params (I).Tag,
                  Name_Text
                    (Current_Params (I).Struct_Name,
                     Current_Params (I).Struct_Name_Len),
                  Ok);
            end if;
         end loop;

         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Symbol_Matches_Scope (I, Module_Name, Scope_Name)
              and then Symbols (I).VAS_Offset > 0
            then
               declare
                  Name        : constant String := Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
                  Struct_Name : constant String :=
                    Name_Text (Symbols (I).Struct_Name, Symbols (I).Struct_Name_Len);
                  Elem_Size   : constant Natural := Natural'Max (1, Symbol_Element_Size_Bytes (I));
                  Elem_Count  : constant Natural :=
                    (if Elem_Size = 0 then 0 else Natural'Max (1, Symbol_Size_Bytes (I) / Elem_Size));
               begin
                  if Symbols (I).Kind = Sym_Array then
                     Emit_Line
                       ("for ALBA_Sync_Elem_" & Trim_Image (Integer (I)) &
                        " in 0 .. " & Trim_Image (Integer (Elem_Count - 1)) & " loop",
                        Ok);
                     Increase_Indent;
                     Emit_Store_To_VAS_Text
                       ("ALBA_Frame_Base + " &
                        Trim_Image (Integer (Symbols (I).VAS_Offset)) &
                        " + (ALBA_Sync_Elem_" & Trim_Image (Integer (I)) &
                        " * " & Trim_Image (Integer (Elem_Size)) & ")",
                        Name & "(Positive(ALBA_Sync_Elem_" & Trim_Image (Integer (I)) & " + 1))",
                        Symbols (I).Tag,
                        Struct_Name,
                        Ok);
                     Decrease_Indent;
                     Emit_Line ("end loop;", Ok);
                  else
                     Emit_Store_To_VAS_Text
                       ("ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (I).VAS_Offset)),
                        Name,
                        Symbols (I).Tag,
                        Struct_Name,
                        Ok);
                  end if;
               end;
            end if;
         end loop;
         Decrease_Indent;
         Emit_Line ("end ALBA_Sync_Frame_To_VAS;", Ok);
         Emit_Newline (Ok);

         if Current_Routine_Uses_Poke then
            Emit_Line ("procedure ALBA_Routine_Poke_Address (Address : Positive; Raw_Value : U64) is", Ok);
         Emit_Line ("begin", Ok);
         Increase_Indent;
         for I in 1 .. Current_Param_Count loop
            exit when not Ok;
            if Current_Params (I).Active and then Current_Params (I).VAS_Offset > 0 then
               declare
                  Name        : constant String := Name_Text (Current_Params (I).Name, Current_Params (I).Name_Len);
                  Struct_Name : constant String :=
                    Name_Text (Current_Params (I).Struct_Name, Current_Params (I).Struct_Name_Len);
                  Size_Bytes  : constant Natural := Natural'Max (1, Param_Size_Bytes (I));
               begin
                  Emit_Line
                    ("if Address < ALBA_Frame_Base + " &
                     Trim_Image (Integer (Current_Params (I).VAS_Offset + Size_Bytes)) &
                     " and then (Address + 7) >= ALBA_Frame_Base + " &
                     Trim_Image (Integer (Current_Params (I).VAS_Offset)) &
                     " then",
                     Ok);
                  Increase_Indent;
                   Emit_Line ("ALB_POKE(Address, Raw_Value);", Ok);
                  Emit_Assign_From_VAS_Text
                    (Name,
                     "ALBA_Frame_Base + " & Trim_Image (Integer (Current_Params (I).VAS_Offset)),
                     Current_Params (I).Tag,
                     Struct_Name,
                     Ok);
                  Emit_Line ("return;", Ok);
                  Decrease_Indent;
                  Emit_Line ("end if;", Ok);
               end;
            end if;
         end loop;

         for I in 1 .. Symbol_Count loop
            exit when not Ok;
            if Symbol_Matches_Scope (I, Module_Name, Scope_Name)
              and then Symbols (I).VAS_Offset > 0
            then
               declare
                  Name        : constant String := Name_Text (Symbols (I).Name, Symbols (I).Name_Len);
                  Struct_Name : constant String :=
                    Name_Text (Symbols (I).Struct_Name, Symbols (I).Struct_Name_Len);
                  Elem_Size   : constant Natural := Natural'Max (1, Symbol_Element_Size_Bytes (I));
                  Total       : constant Natural := Symbol_Size_Bytes (I);
                  Elem_Count  : constant Natural :=
                    (if Elem_Size = 0 then 0 else Natural'Max (1, Total / Elem_Size));
               begin
                  Emit_Line
                    ("if Address < ALBA_Frame_Base + " &
                     Trim_Image (Integer (Symbols (I).VAS_Offset + Total)) &
                     " and then (Address + 7) >= ALBA_Frame_Base + " &
                     Trim_Image (Integer (Symbols (I).VAS_Offset)) &
                     " then",
                     Ok);
                  Increase_Indent;
                   Emit_Line ("ALB_POKE(Address, Raw_Value);", Ok);
                  if Symbols (I).Kind = Sym_Array then
                     Emit_Line
                       ("for ALBA_Reload_Elem_" & Trim_Image (Integer (I)) &
                        " in 0 .. " & Trim_Image (Integer (Elem_Count - 1)) & " loop",
                        Ok);
                     Increase_Indent;
                     Emit_Line ("declare", Ok);
                     Increase_Indent;
                     Emit_Line
                       ("Element_Base : constant Natural := ALBA_Frame_Base + " &
                        Trim_Image (Integer (Symbols (I).VAS_Offset)) &
                        " + (ALBA_Reload_Elem_" & Trim_Image (Integer (I)) &
                        " * " & Trim_Image (Integer (Elem_Size)) & ");",
                        Ok);
                     Decrease_Indent;
                     Emit_Line ("begin", Ok);
                     Increase_Indent;
                     Emit_Line
                       ("if Address < Element_Base + " &
                        Trim_Image (Integer (Elem_Size)) &
                        " and then (Address + 7) >= Element_Base then",
                        Ok);
                     Increase_Indent;
                     Emit_Assign_From_VAS_Text
                       (Name & "(Positive(ALBA_Reload_Elem_" &
                        Trim_Image (Integer (I)) & " + 1))",
                        "Element_Base",
                        Symbols (I).Tag,
                        Struct_Name,
                        Ok);
                     Decrease_Indent;
                     Emit_Line ("end if;", Ok);
                     Decrease_Indent;
                     Emit_Line ("end;", Ok);
                     Decrease_Indent;
                     Emit_Line ("end loop;", Ok);
                  else
                     Emit_Assign_From_VAS_Text
                       (Name,
                        "ALBA_Frame_Base + " & Trim_Image (Integer (Symbols (I).VAS_Offset)),
                        Symbols (I).Tag,
                        Struct_Name,
                        Ok);
                  end if;
                  Emit_Line ("return;", Ok);
                  Decrease_Indent;
                  Emit_Line ("end if;", Ok);
               end;
            end if;
         end loop;
         Emit_Line ("ALB_POKE(Address, Raw_Value);", Ok);
         Decrease_Indent;
         Emit_Line ("end ALBA_Routine_Poke_Address;", Ok);
         Emit_Newline (Ok);
         end if;
      end Emit_Frame_Helper_Declarations;

      procedure Emit_Struct_Declarations (Ok : in out Boolean) is
         Last_Struct     : Name_Buffer := (others => ' ');
         Last_Struct_Len : Natural := 0;
      begin
         for I in 1 .. Struct_Count loop
            exit when not Ok;
            if Struct_Fields (I).Active then
               declare
                  Current_Struct : constant String :=
                    Name_Text (Struct_Fields (I).Struct_Name, Struct_Fields (I).Struct_Name_Len);
               begin
                  if Last_Struct_Len /= Current_Struct'Length
                    or else Name_Text (Last_Struct, Last_Struct_Len) /= Current_Struct
                  then
                     if Last_Struct_Len > 0 then
                        Decrease_Indent;
                        Emit_Line ("end record;", Ok);
                        Emit_Newline (Ok);
                     end if;
                     Last_Struct_Len := Current_Struct'Length;
                     Last_Struct := Copy_Name (Current_Struct);
                     Emit_Line ("type " & Current_Struct & " is record", Ok);
                     Increase_Indent;
                  end if;
               end;
               Emit_Line
                 (Name_Text (Struct_Fields (I).Field_Name, Struct_Fields (I).Field_Name_Len) &
                  " : " & Ada_Type_Name (Struct_Fields (I).Tag) &
                  " := " & Default_Value_Text (Struct_Fields (I).Tag) & ";",
                  Ok);
            end if;
         end loop;
         if Last_Struct_Len > 0 then
            Decrease_Indent;
            Emit_Line ("end record;", Ok);
            Emit_Newline (Ok);
         end if;
      end Emit_Struct_Declarations;

      procedure Emit_Struct_Memory_Helpers (Ok : in out Boolean) is
         Last_Struct     : Name_Buffer := (others => ' ');
         Last_Struct_Len : Natural := 0;

         function Struct_Type_Needs_Helper (Struct_Name : String) return Boolean is
         begin
            for I in 1 .. Struct_Count loop
               if Struct_Fields (I).Active
                 and then Name_Text
                       (Struct_Fields (I).Struct_Name,
                        Struct_Fields (I).Struct_Name_Len) = Struct_Name
                 and then Struct_Memory_Helper_Needed (I)
               then
                  return True;
               end if;
            end loop;
            return False;
         end Struct_Type_Needs_Helper;

      begin
         for I in 1 .. Struct_Count loop
            exit when not Ok;
            if Struct_Fields (I).Active then
               declare
                  Current_Struct : constant String :=
                    Name_Text (Struct_Fields (I).Struct_Name, Struct_Fields (I).Struct_Name_Len);
               begin
                  if Last_Struct_Len /= Current_Struct'Length
                    or else Name_Text (Last_Struct, Last_Struct_Len) /= Current_Struct
                  then
                     Last_Struct_Len := Current_Struct'Length;
                     Last_Struct := Copy_Name (Current_Struct);

                     if Struct_Type_Needs_Helper (Current_Struct) then
                     Emit_Line
                       ("procedure " & Struct_Store_Helper_Name (Current_Struct) &
                        " (Base : Positive; Value : " & Current_Struct & ") is",
                        Ok);
                     Emit_Line ("begin", Ok);
                     Increase_Indent;
                     for J in 1 .. Struct_Count loop
                        exit when not Ok;
                        if Struct_Fields (J).Active
                          and then Name_Text (Struct_Fields (J).Struct_Name, Struct_Fields (J).Struct_Name_Len) = Current_Struct
                        then
                           declare
                              Field_Name  : constant String :=
                                Name_Text (Struct_Fields (J).Field_Name, Struct_Fields (J).Field_Name_Len);
                              Offset_Text : constant String :=
                                Trim_Image (Integer (Struct_Fields (J).Offset_Bytes));
                           begin
                              case Struct_Fields (J).Tag is
                                 when Type_Boolean =>
                                    Emit_Line
                                      ("ALB_STORE_BOOL(Positive(Base + " & Offset_Text &
                                       "), Value." & Field_Name & ");",
                                       Ok);
                                 when Type_Binary =>
                                    Emit_Line
                                      ("ALB_STORE_TEXT(Positive(Base + " & Offset_Text &
                                       "), Value." & Field_Name & ");",
                                       Ok);
                                 when Type_Pure =>
                                    Emit_Line
                                      ("ALB_STORE_PURE(Positive(Base + " & Offset_Text &
                                       "), Value." & Field_Name & ");",
                                       Ok);
                                 when Type_F32 =>
                                    Emit_Line
                                      ("ALB_STORE_F32(Positive(Base + " & Offset_Text &
                                       "), Value." & Field_Name & ");",
                                       Ok);
                                 when Type_F64 =>
                                    Emit_Line
                                      ("ALB_STORE_F64(Positive(Base + " & Offset_Text &
                                       "), Value." & Field_Name & ");",
                                       Ok);
                                 when Type_U8 =>
                                    Emit_Line
                                      ("ALB_STORE_U8(Positive(Base + " & Offset_Text &
                                       "), ALB_U8(Value." & Field_Name & "));",
                                       Ok);
                                 when Type_U16 =>
                                    Emit_Line
                                      ("ALB_STORE_U16(Positive(Base + " & Offset_Text &
                                       "), ALB_U16(Value." & Field_Name & "));",
                                       Ok);
                                 when Type_U32 =>
                                    Emit_Line
                                      ("ALB_STORE_U32(Positive(Base + " & Offset_Text &
                                       "), ALB_U32(Value." & Field_Name & "));",
                                       Ok);
                                 when Type_U64 =>
                                    Emit_Line
                                      ("ALB_STORE_U64(Positive(Base + " & Offset_Text &
                                       "), Value." & Field_Name & ");",
                                       Ok);
                                 when Type_S8 =>
                                    Emit_Line
                                      ("ALB_STORE_I8(Positive(Base + " & Offset_Text &
                                       "), ALB_I8(Value." & Field_Name & "));",
                                       Ok);
                                 when Type_S16 =>
                                    Emit_Line
                                      ("ALB_STORE_I16(Positive(Base + " & Offset_Text &
                                       "), ALB_I16(Value." & Field_Name & "));",
                                       Ok);
                                 when Type_S32 =>
                                    Emit_Line
                                      ("ALB_STORE_I32(Positive(Base + " & Offset_Text &
                                       "), ALB_I32(Value." & Field_Name & "));",
                                       Ok);
                                 when Type_S64 =>
                                    Emit_Line
                                      ("ALB_STORE_I64(Positive(Base + " & Offset_Text &
                                       "), ALB_I64(Value." & Field_Name & "));",
                                       Ok);
                                 when Type_F32x2 | Type_F32x4 |
                                      Type_Mat2x2 | Type_Mat3x3 |
                                      Type_Mat4x4 =>
                                    Emit_Line ("null;", Ok);
                                 when others =>
                                    Emit_Line ("null;", Ok);
                              end case;
                           end;
                        end if;
                     end loop;
                     Decrease_Indent;
                     Emit_Line ("end " & Struct_Store_Helper_Name (Current_Struct) & ";", Ok);
                     Emit_Newline (Ok);

                     Emit_Line
                       ("function " & Struct_Load_Helper_Name (Current_Struct) &
                        " (Base : Positive) return " & Current_Struct & " is",
                        Ok);
                     Increase_Indent;
                     Emit_Line
                       ("Result : " & Current_Struct & " := (others => <>);",
                        Ok);
                     Decrease_Indent;
                     Emit_Line ("begin", Ok);
                     Increase_Indent;
                     for J in 1 .. Struct_Count loop
                        exit when not Ok;
                        if Struct_Fields (J).Active
                          and then Name_Text (Struct_Fields (J).Struct_Name, Struct_Fields (J).Struct_Name_Len) = Current_Struct
                        then
                           Emit_Line
                             ("Result." &
                              Name_Text (Struct_Fields (J).Field_Name, Struct_Fields (J).Field_Name_Len) &
                              " := " &
                              Load_From_VAS_Text
                                ("Base + " & Trim_Image (Integer (Struct_Fields (J).Offset_Bytes)),
                                 Struct_Fields (J).Tag) &
                              ";",
                              Ok);
                        end if;
                     end loop;
                     Emit_Line ("return Result;", Ok);
                     Decrease_Indent;
                     Emit_Line ("end " & Struct_Load_Helper_Name (Current_Struct) & ";", Ok);
                     Emit_Newline (Ok);
                     end if;
                  end if;
               end;
            end if;
         end loop;
      end Emit_Struct_Memory_Helpers;

      procedure Emit_Range_Declarations (Ok : in out Boolean) is
      begin
         for I in 1 .. Alias_Count loop
            if Aliases (I).Active then
               if Aliases (I).Has_Range then
                  Emit_Line
                    ("subtype " & Name_Text (Aliases (I).Name, Aliases (I).Name_Len) &
                     " is " & Ada_Type_Name (Aliases (I).Tag) &
                     " range " & Range_Bound_Image (Aliases (I).Range_Low) &
                     " .. " & Range_Bound_Image (Aliases (I).Range_High) & ";",
                     Ok);
               else
                  Emit_Line
                    ("subtype " & Name_Text (Aliases (I).Name, Aliases (I).Name_Len) &
                     " is " & Ada_Type_Name (Aliases (I).Tag) & ";",
                     Ok);
               end if;
            end if;
         end loop;
         if Alias_Count > 0 then
            Emit_Newline (Ok);
         end if;
      end Emit_Range_Declarations;

      procedure Load_Current_Params (Routine_Node : Node_Index) is
         Param_List : Node_Index := 0;
         Curr       : Node_Index := 0;
      begin
         Current_Param_Count := 0;
         if Routine_Node = 0 or else Tree (Routine_Node).Left_Child = 0 then
            return;
         end if;
         Param_List := Tree (Tree (Routine_Node).Left_Child).Right_Child;
         if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
            Curr := Tree (Param_List).Left_Child;
         else
            Curr := Param_List;
         end if;
         while Curr /= 0 and then Current_Param_Count < Max_Params loop
            exit when Tree (Curr).Kind /= AST_Param_Decl;
            Current_Param_Count := Current_Param_Count + 1;
            Current_Params (Current_Param_Count).Active := True;
            Current_Params (Current_Param_Count).Name_Len :=
              Safe_Name_Length (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
            Current_Params (Current_Param_Count).Name :=
              Copy_Name (Safe_Name (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index)));
            declare
               Formal_Name : constant String :=
                 "ALBA_Formal_" &
                 Safe_Name (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
            begin
               Current_Params (Current_Param_Count).Formal_Name_Len := Formal_Name'Length;
               Current_Params (Current_Param_Count).Formal_Name := Copy_Name (Formal_Name);
            end;
            declare
               Param_Type_Name : constant String :=
                 (if Tree (Curr).Right_Child /= 0
                  then Raw_Lexeme (Tree (Tree (Curr).Right_Child).Token_Index)
                  else "");
               Param_Tag : constant ALB_Type_Tag := Tag_From_Name (Param_Type_Name);
               Param_Struct_Name : constant String :=
                 (if Param_Tag = Type_None and then Is_Struct_Name (Param_Type_Name)
                  then Safe_Name (Param_Type_Name)
                  else "");
            begin
               Current_Params (Current_Param_Count).Tag :=
                 (if Param_Tag /= Type_None then Param_Tag else Type_None);
               Current_Params (Current_Param_Count).Struct_Name_Len :=
                 Param_Struct_Name'Length;
               Current_Params (Current_Param_Count).Struct_Name :=
                 Copy_Name (Param_Struct_Name);
            end;
            Current_Params (Current_Param_Count).Is_Ref :=
              Tree (Curr).Token_Index > 0
              and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Out;
            Current_Params (Current_Param_Count).VAS_Offset := 0;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Load_Current_Params;

      procedure Emit_Contract_Aspect
        (Clause_Node : Node_Index;
         Aspect_Name : String;
         Module_Name : String;
         Ok          : in out Boolean) is
         Saved_Formal_Mode : constant Boolean := Contract_Use_Formal_Names;
      begin
         if Clause_Node = 0 or else Tree (Clause_Node).Left_Child = 0 then
            return;
         end if;
         Contract_Use_Formal_Names := True;
         Emit_Raw (Aspect_Name & " => (", Ok);
         Emit_Expression
           (Tree (Clause_Node).Left_Child,
            Module_Name,
            Type_Boolean,
            False,
            Ok);
         Emit_Raw (")", Ok);
         Contract_Use_Formal_Names := Saved_Formal_Mode;
      end Emit_Contract_Aspect;

      procedure Emit_Contract_Check
        (Clause_Node : Node_Index;
         Label       : String;
         Module_Name : String;
         Ok          : in out Boolean) is
      begin
         if Clause_Node = 0 or else Tree (Clause_Node).Left_Child = 0 then
            return;
         end if;
         Emit_Indent (Ok);
         Emit_Raw ("if not (", Ok);
         Emit_Expression
           (Tree (Clause_Node).Left_Child,
            Module_Name,
            Type_Boolean,
            False,
            Ok);
         Emit_Raw (") then", Ok);
         Emit_Newline (Ok);
         Increase_Indent;
         Emit_Line
           ("ALBA_IO.Print_Text (ALB_STR (""" & Label &
            " contract violation""), True);",
            Ok);
         Emit_Line ("raise Program_Error;", Ok);
         Decrease_Indent;
         Emit_Line ("end if;", Ok);
      end Emit_Contract_Check;

      procedure Assign_Frame_Offsets
        (Module_Name : String;
         Scope_Name  : String) is
         Next_Offset : Natural := 8;
         Size_Bytes  : Natural := 0;
         Align_Bytes : Natural := 1;
      begin
         Current_Frame_Size := 0;

         for I in 1 .. Current_Param_Count loop
            if Current_Params (I).Active then
               if Supports_VAS_View
                 (Current_Params (I).Tag, Current_Params (I).Struct_Name_Len)
               then
                  Size_Bytes := Param_Size_Bytes (I);
                  Align_Bytes := Natural'Min (8, Natural'Max (1, Size_Bytes));
                  Current_Params (I).VAS_Offset := Align_Up (Next_Offset, Align_Bytes);
                  Next_Offset := Current_Params (I).VAS_Offset + Natural'Max (1, Size_Bytes);
               else
                  Current_Params (I).VAS_Offset := 0;
               end if;
            end if;
         end loop;

         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then Name_Text (Symbols (I).Module_Name, Symbols (I).Module_Name_Len) = Module_Name
              and then Name_Text (Symbols (I).Scope_Name, Symbols (I).Scope_Name_Len) = Scope_Name
            then
               if Supports_VAS_View
                 (Symbols (I).Tag, Symbols (I).Struct_Name_Len)
               then
                  Size_Bytes := Symbol_Size_Bytes (I);
                  Align_Bytes :=
                    Natural'Min
                      (8,
                       Natural'Max
                         (1,
                          (if Symbols (I).Kind = Sym_Array
                           then Symbol_Element_Size_Bytes (I)
                           else Size_Bytes)));
                  Symbols (I).VAS_Offset := Align_Up (Next_Offset, Align_Bytes);
                  Next_Offset := Symbols (I).VAS_Offset + Natural'Max (1, Size_Bytes);
               else
                  Symbols (I).VAS_Offset := 0;
               end if;
            end if;
         end loop;

         if Next_Offset = 8 then
            Current_Frame_Size := 0;
         else
            Current_Frame_Size := Next_Offset;
         end if;
      end Assign_Frame_Offsets;

      procedure Compute_Struct_Memory_Helper_Needs is
         procedure Mark_Struct_By_Name (Struct_Name : String) is
         begin
            for I in 1 .. Struct_Count loop
               if Struct_Fields (I).Active
                 and then Name_Text
                       (Struct_Fields (I).Struct_Name,
                        Struct_Fields (I).Struct_Name_Len) = Struct_Name
               then
                  Struct_Memory_Helper_Needed (I) := True;
                  return;
               end if;
            end loop;
         end Mark_Struct_By_Name;

         procedure Scan_Routine_For_Struct_Usage
           (Routine_Node : Node_Index;
            Module_Name  : String) is
            Name_Node     : constant Node_Index := Tree (Routine_Node).Left_Child;
            Routine_Scope : constant String :=
              Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
            Saved_Param_Count : constant Natural := Current_Param_Count;
         begin
            Load_Current_Params (Routine_Node);
            Assign_Frame_Offsets (Module_Name, Routine_Scope);
            for I in 1 .. Current_Param_Count loop
               if Current_Params (I).Active
                 and then Current_Params (I).VAS_Offset > 0
                 and then Current_Params (I).Struct_Name_Len > 0
               then
                  Mark_Struct_By_Name
                    (Name_Text
                       (Current_Params (I).Struct_Name,
                        Current_Params (I).Struct_Name_Len));
               end if;
            end loop;
            for I in 1 .. Symbol_Count loop
               if Symbol_Matches_Scope (I, Module_Name, Routine_Scope)
                 and then Symbols (I).VAS_Offset > 0
                 and then Symbols (I).Struct_Name_Len > 0
               then
                  Mark_Struct_By_Name
                    (Name_Text
                       (Symbols (I).Struct_Name, Symbols (I).Struct_Name_Len));
               end if;
            end loop;
            Current_Param_Count := Saved_Param_Count;
         end Scan_Routine_For_Struct_Usage;

         procedure Scan_Routines_For_Struct_Usage
           (Idx         : Node_Index;
            Module_Name : String) is
         begin
            if Idx = 0 then
               return;
            end if;
            case Tree (Idx).Kind is
               when AST_Program | AST_Block_Stmt =>
                  declare
                     Curr : Node_Index := Tree (Idx).Left_Child;
                  begin
                     while Curr /= 0 loop
                        Scan_Routines_For_Struct_Usage (Curr, Module_Name);
                        Curr := Tree (Curr).Next_Sibling;
                     end loop;
                  end;
               when AST_Module =>
                  if Tree (Idx).Left_Child /= 0 then
                     Scan_Routines_For_Struct_Usage
                       (Tree (Idx).Right_Child,
                        Safe_Name
                          (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)));
                  end if;
               when AST_Procedure_Decl | AST_Function_Decl =>
                  Scan_Routine_For_Struct_Usage (Idx, Module_Name);
               when others =>
                  null;
            end case;
         end Scan_Routines_For_Struct_Usage;

      begin
         Struct_Memory_Helper_Needed := (others => False);
         Scan_Routines_For_Struct_Usage (Root, "");
      end Compute_Struct_Memory_Helper_Needs;

      procedure Emit_Routine
        (Routine_Node : Node_Index;
         Module_Name  : String;
         Ok           : in out Boolean) is
         Name_Node  : constant Node_Index := Tree (Routine_Node).Left_Child;
         Body_Node  : constant Node_Index := Tree (Routine_Node).Right_Child;
         Param_List : Node_Index := 0;
         Curr       : Node_Index := 0;
         First      : Boolean := True;
         Has_Params : Boolean := False;
         Param_Pos  : Natural := 0;
         Routine_Scope : constant String :=
           Safe_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
         Routine_Name : constant String :=
           Qualify_Name
             (Module_Name,
              Raw_Lexeme (Tree (Name_Node).Token_Index));
         Return_Tag : ALB_Type_Tag := Type_None;
         Require_Node : Node_Index := 0;
         Ensure_Node  : Node_Index := 0;
         Contract_Curr : Node_Index := 0;
         Bound_Firewall_Id : Natural := 0;
      begin
         Load_Current_Params (Routine_Node);
         Assign_Frame_Offsets (Module_Name, Routine_Scope);
         Current_Routine_Uses_Poke :=
           Tree_Contains_Kind (Body_Node, AST_Poke_Stmt, False);
         Current_Routine_Body_Node := Body_Node;
         Current_Routine_Module_Len := Module_Name'Length;
         Current_Routine_Module := Copy_Name (Module_Name);
         Param_List := Tree (Name_Node).Right_Child;
         if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
            Curr := Tree (Param_List).Left_Child;
         else
            Curr := Param_List;
         end if;
         Contract_Curr := Curr;
         while Contract_Curr /= 0 loop
            case Tree (Contract_Curr).Kind is
               when AST_Require_Clause =>
                  Require_Node := Contract_Curr;
               when AST_Ensure_Clause =>
                  Ensure_Node := Contract_Curr;
               when others =>
                  null;
            end case;
            Contract_Curr := Tree (Contract_Curr).Next_Sibling;
         end loop;
         if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
            Contract_Curr := Tree (Param_List).Next_Sibling;
            while Contract_Curr /= 0 loop
               case Tree (Contract_Curr).Kind is
                  when AST_Require_Clause =>
                     Require_Node := Contract_Curr;
                  when AST_Ensure_Clause =>
                     Ensure_Node := Contract_Curr;
                  when others =>
                     null;
               end case;
               Contract_Curr := Tree (Contract_Curr).Next_Sibling;
            end loop;
         end if;
         Bound_Firewall_Id := Find_Bound_Firewall_On_Params (Param_List);
         Has_Params := Curr /= 0 and then Tree (Curr).Kind = AST_Param_Decl;

         if Tree (Routine_Node).Kind = AST_Function_Decl then
            Return_Tag := Tag_From_Name (Raw_Lexeme (Tree (Routine_Node).Token_Index));
            if Return_Tag = Type_None then
               Return_Tag := Type_U64;
            end if;
            Emit_Indent (Ok);
            if Has_Params then
               Emit_Raw ("function " & Routine_Name & " (", Ok);
            else
               Emit_Raw ("function " & Routine_Name, Ok);
            end if;
         else
            Emit_Indent (Ok);
            if Has_Params then
               Emit_Raw ("procedure " & Routine_Name & " (", Ok);
            else
               Emit_Raw ("procedure " & Routine_Name, Ok);
            end if;
         end if;

         while Curr /= 0 and then Tree (Curr).Kind = AST_Param_Decl loop
            if not First then
               Emit_Raw ("; ", Ok);
            end if;
            Param_Pos := Param_Pos + 1;
            declare
               Param_Type_Name : constant String :=
                 (if Tree (Curr).Right_Child /= 0
                  then Raw_Lexeme (Tree (Tree (Curr).Right_Child).Token_Index)
                  else "");
               Param_Tag : constant ALB_Type_Tag := Tag_From_Name (Param_Type_Name);
               Param_Struct_Name : constant String :=
                  (if Param_Tag = Type_None and then Is_Struct_Name (Param_Type_Name)
                   then Safe_Name (Param_Type_Name)
                   else "");
            begin
               Emit_Raw
                 (Name_Text
                    (Current_Params (Param_Pos).Formal_Name,
                     Current_Params (Param_Pos).Formal_Name_Len) &
                  " : " &
                  (if Tree (Curr).Token_Index > 0
                      and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Out
                   then "in out "
                   else "in ") &
                  Ada_Type_Name
                    ((if Param_Tag /= Type_None then Param_Tag else Type_U64),
                     Param_Struct_Name),
                  Ok);
            end;
            First := False;
            Curr := Tree (Curr).Next_Sibling;
         end loop;

         if Tree (Routine_Node).Kind = AST_Function_Decl then
            if Has_Params then
               Emit_Raw
                 (") return " &
                  Return_Type_Name_Text (Routine_Node, Return_Tag) &
                  " is",
                  Ok);
            else
               Emit_Raw
                 (" return " &
                  Return_Type_Name_Text (Routine_Node, Return_Tag) &
                  " is",
                  Ok);
            end if;
         else
            if Has_Params then
               Emit_Raw (") is", Ok);
            else
               Emit_Raw (" is", Ok);
            end if;
         end if;
         Emit_Newline (Ok);
         Increase_Indent;
         if Current_Frame_Size > 0 then
            Emit_Line ("ALBA_Frame_Base : constant Positive := ALB_Frame_SP;", Ok);
         end if;
         if Tree (Routine_Node).Kind = AST_Function_Decl then
            Emit_Line
              ("ALBA_Return_Value : " &
               Return_Type_Name_Text (Routine_Node, Return_Tag) &
               " := " &
               Alias_Default_Value_Text
                 (Find_Alias
                    (if Tree (Routine_Node).Token_Index > 0
                     then Upper_Safe_Name
                            (Raw_Lexeme (Tree (Routine_Node).Token_Index))
                     else ""),
                  Return_Tag) &
               ";",
               Ok);
         end if;
         Emit_Param_Local_Declarations (Ok);
         Emit_Local_Declarations (Module_Name, Routine_Scope, Ok);
         Emit_Frame_Helper_Declarations (Module_Name, Routine_Scope, Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Current_Routine_Scope_Len := Routine_Scope'Length;
         Current_Routine_Scope := Copy_Name (Routine_Scope);
         Current_Return_Tag := Return_Tag;
         Current_Frame_Active := Current_Frame_Size > 0;
         Increase_Indent;
         if Current_Frame_Size > 0 then
            Emit_Line
              ("ALB_Frame_SP := ALBA_Frame_Base + " &
               Trim_Image (Integer (Current_Frame_Size)) & ";",
               Ok);
            Emit_Line ("ALBA_Sync_Frame_To_VAS;", Ok);
         end if;
         Emit_Contract_Check (Require_Node, "REQUIRE", Module_Name, Ok);
         if Bound_Firewall_Id > 0 then
            Emit_Line
              ("ALBA_Firewall.Enter (" & Firewall_Constant_Name (Bound_Firewall_Id) & ");",
               Ok);
         end if;
         Emit_Line ("declare", Ok);
         Increase_Indent;
         Emit_Line ("procedure ALBA_Routine_Core is", Ok);
         Increase_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Block (Body_Node, Module_Name, Ok);
         Decrease_Indent;
         Emit_Line ("end ALBA_Routine_Core;", Ok);
         Decrease_Indent;
         Emit_Line ("begin", Ok);
         Increase_Indent;
         Emit_Line ("ALBA_Routine_Core;", Ok);
         Decrease_Indent;
         Emit_Line ("end;", Ok);
         Emit_Contract_Check (Ensure_Node, "ENSURE", Module_Name, Ok);
         if Current_Frame_Size > 0 then
            for I in 1 .. Current_Param_Count loop
               exit when not Ok;
               if Current_Params (I).Active and then Current_Params (I).Is_Ref then
                  Emit_Line
                    (Name_Text
                       (Current_Params (I).Formal_Name,
                        Current_Params (I).Formal_Name_Len) &
                     " := " &
                     Name_Text
                       (Current_Params (I).Name,
                        Current_Params (I).Name_Len) &
                     ";",
                     Ok);
               end if;
            end loop;
            Emit_Line ("ALB_Frame_SP := ALBA_Frame_Base;", Ok);
         end if;
         if Bound_Firewall_Id > 0 then
            Emit_Line ("ALBA_Firewall.Leave;", Ok);
         end if;
         if Tree (Routine_Node).Kind = AST_Function_Decl then
            Emit_Line ("return ALBA_Return_Value;", Ok);
         else
            Emit_Line ("return;", Ok);
         end if;
         Decrease_Indent;
         Current_Routine_Scope_Len := 0;
         Current_Routine_Scope := (others => ' ');
         Current_Return_Tag := Type_None;
         Current_Frame_Active := False;
         Current_Frame_Size := 0;
         Current_Routine_Uses_Poke := False;
         Current_Routine_Body_Node := 0;
         Current_Routine_Module_Len := 0;
         Current_Routine_Module := (others => ' ');
         Emit_Line ("end " & Routine_Name & ";", Ok);
         Emit_Newline (Ok);
         Current_Param_Count := 0;
      end Emit_Routine;

      procedure Emit_Routine_Spec
        (Routine_Node : Node_Index;
         Module_Name  : String;
         Ok           : in out Boolean) is
         Name_Node  : constant Node_Index := Tree (Routine_Node).Left_Child;
         Param_List : Node_Index := 0;
         Curr       : Node_Index := 0;
         First      : Boolean := True;
         Has_Params : Boolean := False;
         Param_Pos  : Natural := 0;
         Routine_Name : constant String :=
           Qualify_Name
             (Module_Name,
              Raw_Lexeme (Tree (Name_Node).Token_Index));
         Return_Tag : ALB_Type_Tag := Type_None;
         Require_Node : Node_Index := 0;
         Ensure_Node  : Node_Index := 0;
         Contract_Curr : Node_Index := 0;
         Has_Contracts : Boolean := False;
      begin
         Load_Current_Params (Routine_Node);
         Param_List := Tree (Name_Node).Right_Child;
         if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
            Curr := Tree (Param_List).Left_Child;
         else
            Curr := Param_List;
         end if;
         Contract_Curr := Curr;
         while Contract_Curr /= 0 loop
            case Tree (Contract_Curr).Kind is
               when AST_Require_Clause =>
                  Require_Node := Contract_Curr;
               when AST_Ensure_Clause =>
                  Ensure_Node := Contract_Curr;
               when others =>
                  null;
            end case;
            Contract_Curr := Tree (Contract_Curr).Next_Sibling;
         end loop;
         if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
            Contract_Curr := Tree (Param_List).Next_Sibling;
            while Contract_Curr /= 0 loop
               case Tree (Contract_Curr).Kind is
                  when AST_Require_Clause =>
                     Require_Node := Contract_Curr;
                  when AST_Ensure_Clause =>
                     Ensure_Node := Contract_Curr;
                  when others =>
                     null;
               end case;
               Contract_Curr := Tree (Contract_Curr).Next_Sibling;
            end loop;
         end if;
         Has_Contracts := Require_Node /= 0 or else Ensure_Node /= 0;
         Has_Params := Curr /= 0 and then Tree (Curr).Kind = AST_Param_Decl;

         if Tree (Routine_Node).Kind = AST_Function_Decl then
            Return_Tag := Tag_From_Name (Raw_Lexeme (Tree (Routine_Node).Token_Index));
            if Return_Tag = Type_None then
               Return_Tag := Type_U64;
            end if;
            Emit_Indent (Ok);
            if Has_Params then
               Emit_Raw ("function " & Routine_Name & " (", Ok);
            else
               Emit_Raw ("function " & Routine_Name, Ok);
            end if;
         else
            Emit_Indent (Ok);
            if Has_Params then
               Emit_Raw ("procedure " & Routine_Name & " (", Ok);
            else
               Emit_Raw ("procedure " & Routine_Name, Ok);
            end if;
         end if;

         while Curr /= 0 and then Tree (Curr).Kind = AST_Param_Decl loop
            if not First then
               Emit_Raw ("; ", Ok);
            end if;
            Param_Pos := Param_Pos + 1;
            declare
               Param_Type_Name : constant String :=
                 (if Tree (Curr).Right_Child /= 0
                  then Raw_Lexeme (Tree (Tree (Curr).Right_Child).Token_Index)
                  else "");
               Param_Tag : constant ALB_Type_Tag := Tag_From_Name (Param_Type_Name);
               Param_Struct_Name : constant String :=
                 (if Param_Tag = Type_None and then Is_Struct_Name (Param_Type_Name)
                  then Safe_Name (Param_Type_Name)
                  else "");
            begin
               Emit_Raw
                 (Name_Text
                    (Current_Params (Param_Pos).Formal_Name,
                     Current_Params (Param_Pos).Formal_Name_Len) &
                  " : " &
                  (if Tree (Curr).Token_Index > 0
                      and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Out
                   then "in out "
                   else "in ") &
                  Ada_Type_Name
                    ((if Param_Tag /= Type_None then Param_Tag else Type_U64),
                     Param_Struct_Name),
                  Ok);
            end;
            First := False;
            Curr := Tree (Curr).Next_Sibling;
         end loop;

         if Tree (Routine_Node).Kind = AST_Function_Decl then
            if Has_Params then
               Emit_Raw (") return " & Return_Type_Name_Text (Routine_Node, Return_Tag), Ok);
            else
               Emit_Raw (" return " & Return_Type_Name_Text (Routine_Node, Return_Tag), Ok);
            end if;
         else
            if Has_Params then
               Emit_Raw (")", Ok);
            else
               null;
            end if;
         end if;
         if Has_Contracts then
            Emit_Raw (" with", Ok);
            if Require_Node /= 0 then
               Emit_Newline (Ok);
               Emit_Indent (Ok);
               Emit_Contract_Aspect (Require_Node, "Pre", Module_Name, Ok);
            end if;
            if Ensure_Node /= 0 then
               if Require_Node /= 0 then
                  Emit_Raw (",", Ok);
               end if;
               Emit_Newline (Ok);
               Emit_Indent (Ok);
               Emit_Contract_Aspect (Ensure_Node, "Post", Module_Name, Ok);
            end if;
         end if;
         Emit_Raw (";", Ok);
         Emit_Newline (Ok);
         Current_Param_Count := 0;
      end Emit_Routine_Spec;

      procedure Emit_Import_C_Declaration
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Routine_Node : constant Node_Index := Tree (Idx).Left_Child;
         Name_Node    : Node_Index := 0;
         Param_List   : Node_Index := 0;
         Curr         : Node_Index := 0;
         First        : Boolean := True;
         Has_Params   : Boolean := False;
         Return_Tag   : ALB_Type_Tag := Type_None;
      begin
         if Routine_Node = 0 then
            return;
         end if;

         Name_Node := Tree (Routine_Node).Left_Child;
         if Name_Node = 0 then
            return;
         end if;

         declare
            Routine_Name  : constant String :=
              Qualify_Name (Module_Name, Raw_Lexeme (Tree (Name_Node).Token_Index));
            External_Name : constant String :=
              Raw_Lexeme (Tree (Name_Node).Token_Index);
         begin
            Param_List := Tree (Name_Node).Right_Child;
            if Param_List /= 0 and then Tree (Param_List).Kind = AST_Arg_List then
               Curr := Tree (Param_List).Left_Child;
            else
               Curr := Param_List;
            end if;
            Has_Params := Curr /= 0;

            if Tree (Routine_Node).Kind = AST_Function_Decl then
               Return_Tag := Tag_From_Name (Raw_Lexeme (Tree (Routine_Node).Token_Index));
               if Return_Tag = Type_None then
                  Return_Tag := Type_U64;
               end if;
               Emit_Indent (Ok);
               if Has_Params then
                  Emit_Raw ("function " & Routine_Name & " (", Ok);
               else
                  Emit_Raw ("function " & Routine_Name, Ok);
               end if;
            else
               Emit_Indent (Ok);
               if Has_Params then
                  Emit_Raw ("procedure " & Routine_Name & " (", Ok);
               else
                  Emit_Raw ("procedure " & Routine_Name, Ok);
               end if;
            end if;

            while Curr /= 0 loop
               if not First then
                  Emit_Raw ("; ", Ok);
               end if;
               Emit_Raw
                 (Safe_Name (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index)) &
                  " : " &
                  (if Tree (Curr).Token_Index > 0
                      and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Out
                   then "in out "
                   else "in ") &
                  Ada_Type_Name
                    ((if Tree (Curr).Right_Child /= 0
                      then Tag_From_Name (Raw_Lexeme (Tree (Tree (Curr).Right_Child).Token_Index))
                      else Type_U64)),
                  Ok);
               First := False;
               Curr := Tree (Curr).Next_Sibling;
            end loop;

            if Tree (Routine_Node).Kind = AST_Function_Decl then
               if Has_Params then
                  Emit_Raw (") return " & Ada_Type_Name (Return_Tag) & ";", Ok);
               else
                  Emit_Raw (" return " & Ada_Type_Name (Return_Tag) & ";", Ok);
               end if;
            else
               if Has_Params then
                  Emit_Raw (");", Ok);
               else
                  Emit_Raw (";", Ok);
               end if;
            end if;
            Emit_Newline (Ok);
            Emit_Line
              ("pragma Import (C, " & Routine_Name & ", """ & External_Name & """);",
               Ok);
         end;
      end Emit_Import_C_Declaration;

      procedure Emit_Import_C_Declarations_From
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Curr : Node_Index := 0;
      begin
         if Idx = 0 then
            return;
         end if;
         case Tree (Idx).Kind is
            when AST_Program | AST_Block_Stmt =>
               Curr := Tree (Idx).Left_Child;
               while Curr /= 0 loop
                  Emit_Import_C_Declarations_From (Curr, Module_Name, Ok);
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            when AST_Module =>
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Import_C_Declarations_From
                    (Tree (Idx).Right_Child,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                     Ok);
               end if;
            when AST_Import_C | AST_Import_DLL =>
               Emit_Import_C_Declaration (Idx, Module_Name, Ok);
            when others =>
               null;
         end case;
      end Emit_Import_C_Declarations_From;

      procedure Emit_Routine_Specs_From
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Curr : Node_Index := 0;
      begin
         if Idx = 0 then
            return;
         end if;
         case Tree (Idx).Kind is
            when AST_Program | AST_Block_Stmt =>
               Curr := Tree (Idx).Left_Child;
               while Curr /= 0 loop
                  Emit_Routine_Specs_From (Curr, Module_Name, Ok);
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            when AST_Module =>
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Routine_Specs_From
                    (Tree (Idx).Right_Child,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                     Ok);
               end if;
            when AST_DeclareModule =>
               null;
            when AST_Procedure_Decl | AST_Function_Decl =>
               Emit_Routine_Spec (Idx, Module_Name, Ok);
            when others =>
               null;
         end case;
      end Emit_Routine_Specs_From;

      procedure Emit_Routines_From
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Curr : Node_Index := 0;
      begin
         if Idx = 0 then
            return;
         end if;
         case Tree (Idx).Kind is
            when AST_Program | AST_Block_Stmt =>
               Curr := Tree (Idx).Left_Child;
               while Curr /= 0 loop
                  Emit_Routines_From (Curr, Module_Name, Ok);
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            when AST_Module =>
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Routines_From
                    (Tree (Idx).Right_Child,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                     Ok);
               end if;
            when AST_DeclareModule =>
               null;
            when AST_Procedure_Decl | AST_Function_Decl =>
               Emit_Routine (Idx, Module_Name, Ok);
            when others =>
               null;
         end case;
      end Emit_Routines_From;

      procedure Emit_User_Unit_Spec (Ok : in out Boolean) is
         Spark_Mode_Text : constant String :=
           (if Move_Globals_To_User_Unit then "Off" else "On");
      begin
         if Routine_Count = 0 then
            return;
         end if;

         Emit_Line ("pragma SPARK_Mode (" & Spark_Mode_Text & ");", Ok);
         Emit_Newline (Ok);
         Emit_Line ("with ALBA_API;", Ok);
         Emit_Newline (Ok);
         Emit_Line
           ("package " & User_Unit_Name_Text & " with SPARK_Mode => " &
              Spark_Mode_Text & " is",
            Ok);
         Emit_Line ("   use ALBA_API;", Ok);
         Emit_Newline (Ok);
         Increase_Indent;
         Emit_Range_Declarations (Ok);
         Emit_Struct_Declarations (Ok);
         if Move_Globals_To_User_Unit then
            Emit_Global_Declarations (Ok);
         end if;
         declare
            Curr : Node_Index := Root;
         begin
            while Curr /= 0 loop
               Emit_Routine_Specs_From (Curr, "", Ok);
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         end;
         Decrease_Indent;
         Emit_Line ("end " & User_Unit_Name_Text & ";", Ok);
         Emit_Newline (Ok);
      end Emit_User_Unit_Spec;

      procedure Emit_User_Unit_Body (Ok : in out Boolean) is
         Spark_Mode_Text : constant String :=
           (if Move_Globals_To_User_Unit then "Off" else "On");
      begin
         if Routine_Count = 0 then
            return;
         end if;

         Emit_Line ("pragma SPARK_Mode (" & Spark_Mode_Text & ");", Ok);
         Emit_Newline (Ok);
         Emit_Line ("with ALBA_API; use ALBA_API;", Ok);
         Emit_Newline (Ok);
         Emit_Line ("package body " & User_Unit_Name_Text & " is", Ok);
         Increase_Indent;
         Compute_Struct_Memory_Helper_Needs;
         if Move_Globals_To_User_Unit then
            Emit_Struct_Memory_Helpers (Ok);
         end if;
         Emit_Address_Helpers (Ok, Sync_Globals => False);
         declare
            Curr : Node_Index := Root;
         begin
            while Curr /= 0 loop
               Emit_Routines_From (Curr, "", Ok);
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         end;
         Decrease_Indent;
         Emit_Line ("end " & User_Unit_Name_Text & ";", Ok);
         Emit_Newline (Ok);
      end Emit_User_Unit_Body;

      procedure Emit_Main_Imports (Ok : in out Boolean) is
      begin
         if Need_F64_Runtime then
            Emit_Line ("with Ada.Strings;", Ok);
            Emit_Line ("with Ada.Strings.Fixed;", Ok);
            Emit_Line ("with Ada.Numerics.Generic_Elementary_Functions;", Ok);
         end if;
         if Need_Net_Runtime then
            Emit_Line ("with Ada.Streams; use Ada.Streams;", Ok);
            Emit_Line ("with GNAT.Sockets; use GNAT.Sockets;", Ok);
         end if;
         if Firewall_Count > 0 then
            Emit_Line ("with ALBA_Firewall; use ALBA_Firewall;", Ok);
         end if;
         Emit_Line ("with ALBA_API; use ALBA_API;", Ok);
         if Routine_Count > 0 then
            Emit_Line ("with " & User_Unit_Name_Text & ";", Ok);
            Need_User_Unit_Use := Main_Needs_User_Unit_Use;
            if Need_User_Unit_Use then
               Emit_Line ("use " & User_Unit_Name_Text & ";", Ok);
            end if;
         end if;
         if Need_Numerus_Runtime then
            Emit_Line ("with Numerus_Magnus;", Ok);
         end if;
         Emit_Newline (Ok);
      end Emit_Main_Imports;

      procedure Emit_Top_Level_Init
        (Idx         : Node_Index;
         Module_Name : String;
         Ok          : in out Boolean) is
         Curr : Node_Index := 0;
         Sym_Idx : Natural := 0;
         Init_Node : Node_Index := 0;
         Hist_Count : Natural := 0;
      begin
         if Idx = 0 then
            return;
         end if;
         case Tree (Idx).Kind is
            when AST_Program | AST_Block_Stmt =>
               Curr := Tree (Idx).Left_Child;
               while Curr /= 0 loop
                  Emit_Top_Level_Init (Curr, Module_Name, Ok);
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            when AST_Module =>
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Top_Level_Init
                    (Tree (Idx).Right_Child,
                     Safe_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index)),
                     Ok);
               end if;
            when AST_Temporal_Decl =>
               if Tree (Idx).Left_Child /= 0 then
                  declare
                     Target_Name : constant String :=
                       Resolve_Name (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index), Module_Name);
                  begin
                     Sym_Idx := Find_Symbol (Target_Name);
                     if Tree (Idx).Right_Child /= 0 then
                        Init_Node := Tree (Tree (Idx).Right_Child).Next_Sibling;
                     end if;
                     if Sym_Idx > 0 and then Init_Node /= 0 then
                        Hist_Count := Natural'Max (1, Symbols (Sym_Idx).History_Size);
                        Emit_Indent (Ok);
                        Emit_Raw (Target_Name & " := ", Ok);
                        Emit_Assigned_Expression (Init_Node, Module_Name, Symbols (Sym_Idx).Tag, Ok);
                        Emit_Raw (";", Ok);
                        Emit_Newline (Ok);
                        Emit_Line (Target_Name & "_head := 0;", Ok);
                        Emit_Line
                          ("for alba_timeline_init_" & Trim_Image (Integer (Idx)) &
                           " in 0 .. " & Trim_Image (Integer (Hist_Count - 1)) &
                           " loop",
                           Ok);
                        Increase_Indent;
                        Emit_Line
                          (Target_Name & "_timeline(alba_timeline_init_" &
                           Trim_Image (Integer (Idx)) & ") := " & Target_Name & ";",
                           Ok);
                        Emit_Indent (Ok);
                        Emit_Raw
                          ("ALB_STORE_U64(Positive(" &
                           Trim_Image (Integer (Symbols (Sym_Idx).Timeline_Offset)) &
                           " + (alba_timeline_init_" & Trim_Image (Integer (Idx)) &
                           " * 8)), ",
                           Ok);
                        if Symbols (Sym_Idx).Tag = Type_Boolean then
                           Emit_Raw ("ALB_BOOL_TO_U64(" & Target_Name & ")", Ok);
                        else
                           Emit_Raw
                             (Value_To_U64_Text (Target_Name, Symbols (Sym_Idx).Tag),
                              Ok);
                        end if;
                        Emit_Raw (");", Ok);
                        Emit_Newline (Ok);
                        Decrease_Indent;
                        Emit_Line ("end loop;", Ok);
                     end if;
                  end;
               end if;
            when AST_Comptime_Block =>
               Execute_Comptime_Node (Idx, Module_Name);
            when AST_DeclareModule | AST_Procedure_Decl | AST_Function_Decl | AST_Import_C |
                 AST_On_Block | AST_Import | AST_Include_Stmt |
                 AST_Version | AST_Struct_Decl | AST_Range_Type_Decl | AST_Parallel_Decl |
                 AST_Strict_Stmt | AST_Slide_Stmt | AST_Const_Decl |
                 AST_Enum_Decl | AST_Markov_Model_Decl | AST_Neural_Topology_Decl |
                 AST_Memory_Firewall_Decl | AST_Network_Socket_Decl |
                 AST_Import_DLL | AST_Export_DLL | AST_Export_ES |
                 AST_Export_WASM | AST_Import_ES | AST_Import_WASM =>
               null;
            when AST_Create_Window =>
               Emit_Indent (Ok);
               Emit_Raw ("ALBA_Graphics.Initialize(", Ok);
               if Tree (Idx).Left_Child /= 0 then
                  Emit_Raw
                    (Raw_Lexeme (Tree (Tree (Idx).Left_Child).Token_Index),
                     Ok);
               else
                  Emit_Raw ("""ALBA_WINDOW""", Ok);
               end if;
               Emit_Raw (", Natural(Integer(", Ok);
               if Create_Window_Width_Node (Idx) /= 0 then
                  Emit_Expression
                    (Create_Window_Width_Node (Idx),
                     Module_Name,
                     Type_S32,
                     False,
                     Ok);
               else
                  Emit_Raw ("320", Ok);
               end if;
               Emit_Raw (")), Natural(Integer(", Ok);
               if Create_Window_Height_Node (Idx) /= 0 then
                  Emit_Expression
                    (Create_Window_Height_Node (Idx),
                     Module_Name,
                     Type_S32,
                     False,
                     Ok);
               else
                  Emit_Raw ("200", Ok);
               end if;
               Emit_Raw (")), Graphics_OK);", Ok);
               Emit_Newline (Ok);
            when others =>
               Emit_Node (Idx, Module_Name, Ok);
         end case;
      end Emit_Top_Level_Init;

   begin
      Init_Emitter (Success);
      if not Success then
         return;
      end if;

      declare
         Unit_Name : constant String := Safe_Name (Program_Name) & "_User";
      begin
         User_Unit_Name_Len := Unit_Name'Length;
         if User_Unit_Name_Len > User_Unit_Name'Length then
            User_Unit_Name_Len := User_Unit_Name'Length;
         end if;
         User_Unit_Name (1 .. User_Unit_Name_Len) := Unit_Name (1 .. User_Unit_Name_Len);
      end;

      Detect_Emission_Mode (Source);
      Register_Source_Const_Declarations (Source);

      declare
         Curr : Node_Index := Root;
      begin
         while Curr /= 0 loop
            Scan_Node (Curr);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end;

      Build_Ada_Case_Renames;
      Finalize_Runtime_Needs;

      if Need_Save_State
        and then not Has_Global_Saveables
        and then not Has_Global_Temporals
      then
         Ada.Text_IO.Put_Line
           ("ALBA: SAVE/RESTORE used but no global saveable state exists.");
         Success := False;
         return;
      end if;

      if Critical_Mode and then Critical_Violations > 0 then
         Ada.Text_IO.Put_Line
           ("ALBA: emission failed: " &
            Trim_Image (Integer (Critical_Violations)) &
            " CRITICAL-mode feature violation(s). Add MODE FULL to opt into full tier.");
         Success := False;
         return;
      end if;

      Assign_Static_VAS_Offsets;

      Move_Globals_To_User_Unit :=
        Routine_Count > 0 and then Has_Program_Global_Symbols;

      if Routine_Count > 0 then
         Current_Output_Sink := Sink_User_Spec;
         Reset_Output_Buffer (Sink_User_Spec);
         Emit_User_Unit_Spec (Success);

         Current_Output_Sink := Sink_User_Body;
         Reset_Output_Buffer (Sink_User_Body);
         if Success then
            Start_Body_Stream
              (User_Sibling_Unit_Path (Output_Path, ".adb"),
               Success);
         end if;
         if Success then
            Emit_User_Unit_Body (Success);
         end if;
         Close_Body_Stream;
      end if;

      Current_Output_Sink := Sink_Main;
      Reset_Output_Buffer (Sink_Main);

      Emit_Line ("pragma SPARK_Mode (Off);", Success);
      Emit_Newline (Success);
      Emit_Main_Imports (Success);
      Emit_Line ("procedure " & Safe_Name (Program_Name) & " is", Success);
      Increase_Indent;
      if Has_Window or else On_Tick_Node /= 0 or else On_Paint_Node /= 0
        or else On_Key_Node /= 0 or else Has_Listen
      then
         Emit_Line ("Graphics_OK : Boolean := False;", Success);
      end if;
      if Need_User_Exception then
         Emit_Line ("ALBA_User_Error : exception;", Success);
         Emit_Line ("ALBA_Last_Error : ALB_Text := ALB_STR("""");", Success);
      end if;
      Emit_Firewall_Constant_Declarations (Success);
      if Routine_Count = 0 then
         Emit_Range_Declarations (Success);
         Emit_Struct_Declarations (Success);
      end if;
      if not Move_Globals_To_User_Unit then
         Compute_Struct_Memory_Helper_Needs;
         Emit_Struct_Memory_Helpers (Success);
      end if;
      Emit_Advanced_Runtime_Support (Success);
      if not Move_Globals_To_User_Unit then
         Emit_Global_Declarations (Success);
      end if;
      declare
         Curr : Node_Index := Root;
      begin
         while Curr /= 0 loop
            Emit_Advanced_Declarations_From (Curr, "", Success);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end;
      Emit_Save_State_Declarations (Success);
      declare
         Curr : Node_Index := Root;
      begin
         while Curr /= 0 loop
            Emit_Import_C_Declarations_From (Curr, "", Success);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end;
      Emit_Save_State_Procedures (Success);
      Emit_Address_Helpers (Success);

      if On_Tick_Node /= 0 then
         Emit_Line ("procedure ALB_On_Tick is", Success);
         Emit_Local_Declarations ("", "ALB_On_Tick", Success);
         Emit_Line ("begin", Success);
         Current_Routine_Scope_Len := 11;
         Current_Routine_Scope := Copy_Name ("ALB_On_Tick");
         Increase_Indent;
         Emit_Block (On_Tick_Node, "", Success);
         Decrease_Indent;
         Current_Routine_Scope_Len := 0;
         Current_Routine_Scope := (others => ' ');
         Emit_Line ("end ALB_On_Tick;", Success);
         Emit_Newline (Success);
      end if;

      if On_Paint_Node /= 0 then
         Emit_Line ("procedure ALB_On_Paint is", Success);
         Emit_Local_Declarations ("", "ALB_On_Paint", Success);
         Emit_Line ("begin", Success);
         Current_Routine_Scope_Len := 12;
         Current_Routine_Scope := Copy_Name ("ALB_On_Paint");
         Increase_Indent;
         Emit_Block (On_Paint_Node, "", Success);
         Decrease_Indent;
         Current_Routine_Scope_Len := 0;
         Current_Routine_Scope := (others => ' ');
         Emit_Line ("end ALB_On_Paint;", Success);
         Emit_Newline (Success);
      end if;

      if On_Key_Node /= 0 then
         Emit_Line ("procedure ALB_On_Key is", Success);
         Emit_Local_Declarations ("", "ALB_On_Key", Success);
         Emit_Line ("begin", Success);
         Current_Routine_Scope_Len := 10;
         Current_Routine_Scope := Copy_Name ("ALB_On_Key");
         Increase_Indent;
         Emit_Block (On_Key_Node, "", Success);
         Decrease_Indent;
         Current_Routine_Scope_Len := 0;
         Current_Routine_Scope := (others => ' ');
         Emit_Line ("end ALB_On_Key;", Success);
         Emit_Newline (Success);
      end if;

      if Knows_Hook_Count > 0 then
         for I in 1 .. Knows_Hook_Count loop
            exit when not Success;
            if Knows_Hooks (I).Active then
               Emit_Line
                 ("procedure " &
                  Name_Text (Knows_Hooks (I).Handler_Name, Knows_Hooks (I).Handler_Name_Len) &
                  " (" &
                  Name_Text (Knows_Hooks (I).Param_Name, Knows_Hooks (I).Param_Name_Len) &
                  " : in S32) is",
                  Success);
               Emit_Local_Declarations
                 ("",
                  Name_Text (Knows_Hooks (I).Handler_Name, Knows_Hooks (I).Handler_Name_Len),
                  Success);
               Emit_Line ("begin", Success);
               Current_Param_Count := 1;
               Current_Params (1).Active := True;
               Current_Params (1).Name_Len := Knows_Hooks (I).Param_Name_Len;
               Current_Params (1).Name := Knows_Hooks (I).Param_Name;
               Current_Params (1).Tag := Type_S32;
               Current_Params (1).Is_Ref := False;
               Current_Routine_Scope_Len := Knows_Hooks (I).Handler_Name_Len;
               Current_Routine_Scope := Knows_Hooks (I).Handler_Name;
               Increase_Indent;
               Emit_Block (Tree (Knows_Hooks (I).Node).Left_Child, "", Success);
               Decrease_Indent;
               Current_Routine_Scope_Len := 0;
               Current_Routine_Scope := (others => ' ');
               Current_Param_Count := 0;
               Emit_Line
                 ("end " &
                  Name_Text (Knows_Hooks (I).Handler_Name, Knows_Hooks (I).Handler_Name_Len) &
                  ";",
                  Success);
               Emit_Newline (Success);
            end if;
         end loop;
      end if;

      Decrease_Indent;
      Emit_Line ("begin", Success);
      Increase_Indent;
      Emit_Firewall_Program_Init (Success);
      declare
         Stmt_Curr    : Node_Index := Root;
         Listen_Idx   : Node_Index := 0;
         After_Curr   : Node_Index := 0;
      begin
         if Stmt_Curr /= 0
           and then (Tree (Stmt_Curr).Kind = AST_Program
                     or else Tree (Stmt_Curr).Kind = AST_Block_Stmt)
         then
            Stmt_Curr := Tree (Stmt_Curr).Left_Child;
         end if;

         After_Curr := Stmt_Curr;
         while After_Curr /= 0 loop
            if Tree (After_Curr).Kind = AST_Listen then
               Listen_Idx := After_Curr;
               exit;
            end if;
            After_Curr := Tree (After_Curr).Next_Sibling;
         end loop;

         After_Curr := Stmt_Curr;
         while After_Curr /= 0 loop
            exit when After_Curr = Listen_Idx;
            Emit_Top_Level_Init (After_Curr, "", Success);
            exit when not Success;
            After_Curr := Tree (After_Curr).Next_Sibling;
         end loop;

         if Has_Window or else Has_Listen or else On_Tick_Node /= 0 or else On_Paint_Node /= 0 then
            Emit_Line ("while ALBA_Graphics.Window_Open loop", Success);
            Increase_Indent;
            Emit_Line ("ALBA_Graphics.Process_Events;", Success);
            if On_Key_Node /= 0 then
               Emit_Line ("if ALBA_Graphics.Pending_Key_Event then", Success);
               Increase_Indent;
               Emit_Line ("ALB_On_Key;", Success);
               Decrease_Indent;
               Emit_Line ("end if;", Success);
            end if;
            if On_Tick_Node /= 0 then
               Emit_Line ("ALB_On_Tick;", Success);
            end if;
            if On_Paint_Node /= 0 then
               Emit_Line ("ALB_On_Paint;", Success);
               Emit_Line ("ALBA_Graphics.Present;", Success);
            end if;
            Decrease_Indent;
            Emit_Line ("end loop;", Success);
            Emit_Line ("ALBA_Graphics.Shutdown;", Success);
         end if;

         if Listen_Idx /= 0 then
            After_Curr := Tree (Listen_Idx).Next_Sibling;
            while After_Curr /= 0 loop
               Emit_Top_Level_Init (After_Curr, "", Success);
               exit when not Success;
               After_Curr := Tree (After_Curr).Next_Sibling;
            end loop;
         end if;
      end;
      Emit_Line ("ALBA_Audio.Shutdown;", Success);
      Decrease_Indent;
      Emit_Line ("end " & Safe_Name (Program_Name) & ";", Success);

      if Buffer_Saturated then
         Success := False;
      end if;

      if Success then
         Flush_To_File (Output_Path, Success);
         if not Success then
            Ada.Text_IO.Put_Line
              ("ALBA: failed to write Ada main unit " & Output_Path);
         elsif Routine_Count > 0 then
            Flush_Buffer_To_File
              (User_Spec_Buffer,
               User_Spec_Len,
               User_Sibling_Unit_Path (Output_Path, ".ads"),
               Success);
            if not Success then
               Ada.Text_IO.Put_Line
                 ("ALBA: failed to write Ada user spec.");
            elsif User_Body_Len > 0 then
               Flush_Buffer_To_File
                 (User_Body_Buffer,
                  User_Body_Len,
                  User_Sibling_Unit_Path (Output_Path, ".adb"),
                  Success);
               if not Success then
                  Ada.Text_IO.Put_Line
                    ("ALBA: failed to write Ada user body.");
               end if;
            end if;
         end if;
      else
         Ada.Text_IO.Put_Line
           ("ALBA: emit aborted (main" &
            Natural'Image (Output_Len) &
            " spec" &
            Natural'Image (User_Spec_Len) &
            " body" &
            Natural'Image (User_Body_Len) &
            " streamed" &
            Natural'Image (Body_Stream_Len) &
            " routines" &
            Natural'Image (Routine_Count) &
            ").");
      end if;
   end Emit_Program;

end Emit_Native_Ada;
