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
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with AST;            use AST;

package body Emit_Native_Godot is

   Max_Path_Len      : constant Natural := 512;
   Max_Blocks        : constant Natural := 2048;
   Max_Structs       : constant Natural := 512;
   Max_Modules       : constant Natural := 512;
   Max_Locals        : constant Natural := 4096;
   Max_Buffered_Nodes : constant Natural := 4096;
   Max_Globals       : constant Natural := 4096;

   type Node_List is array (1 .. Max_Blocks) of Node_Index;
   type Name_List is array (1 .. Max_Locals) of Unbounded_String;
   type Global_Storage_Kind is
     (Global_Variant,
      Global_String,
      Global_Array,
      Global_Slide,
      Global_Temporal,
      Global_Dictionary);

   type Global_Info is record
      Name         : Unbounded_String := To_Unbounded_String ("");
      Kind         : Global_Storage_Kind := Global_Variant;
      History_Size : Natural := 0;
   end record;

   type Global_List is array (1 .. Max_Globals) of Global_Info;

   Output_Directory : Unbounded_String := To_Unbounded_String ("");
   Script_Name      : Unbounded_String := To_Unbounded_String ("");
   Generated_Class  : Unbounded_String := To_Unbounded_String ("AlbGeneratedNode");
   Generated_Base   : Unbounded_String := To_Unbounded_String ("Node2D");
   Resource_Base    : Unbounded_String := To_Unbounded_String ("res://");
   Requested_Build  : Boolean := False;
   Current_API      : Godot_API_Target := Godot_46;

   Begin_Blocks     : Node_List := (others => 0);
   Tick_Blocks      : Node_List := (others => 0);
   Paint_Blocks     : Node_List := (others => 0);
   Key_Blocks       : Node_List := (others => 0);
   Begin_Count      : Natural := 0;
   Tick_Count       : Natural := 0;
   Paint_Count      : Natural := 0;
   Key_Count        : Natural := 0;

   Struct_Names     : Name_List := (others => To_Unbounded_String (""));
   Struct_Count     : Natural := 0;
   Module_Names     : Name_List := (others => To_Unbounded_String (""));
   Module_Count     : Natural := 0;
   Local_Names      : Name_List := (others => To_Unbounded_String (""));
   Local_Count      : Natural := 0;
   Globals          : Global_List :=
     (others => (Name => To_Unbounded_String (""),
                 Kind => Global_Variant,
                 History_Size => 0));
   Global_Count     : Natural := 0;

   Global_Decls     : Unbounded_String := To_Unbounded_String ("");
   Global_Bootstrap : Unbounded_String := To_Unbounded_String ("");
   Struct_Buffer    : Unbounded_String := To_Unbounded_String ("");
   Routine_Buffer   : Unbounded_String := To_Unbounded_String ("");
   Begin_Buffer     : Unbounded_String := To_Unbounded_String ("");
   Tick_Buffer      : Unbounded_String := To_Unbounded_String ("");
   Paint_Buffer     : Unbounded_String := To_Unbounded_String ("");
   Key_Buffer       : Unbounded_String := To_Unbounded_String ("");
   Warning_Buffer   : Unbounded_String := To_Unbounded_String ("");

   Current_Module   : Unbounded_String := To_Unbounded_String ("");
   Current_Routine  : Unbounded_String := To_Unbounded_String ("");
   Current_Diagnostic : Emitter_Diagnostic_Log;

   type Buffer_Kind is
     (Buf_Global_Decls,
      Buf_Global_Bootstrap,
      Buf_Structs,
      Buf_Routines,
      Buf_Begin,
      Buf_Tick,
      Buf_Paint,
      Buf_Key,
      Buf_Warnings);

   procedure Buffer_Line
     (Kind  : in Buffer_Kind;
      Level : in Natural;
      Text  : in String);
   procedure Add_Warning
     (Node    : in Node_Index;
      Message : in String;
      Category : in Emitter_Diagnostic_Category := Emitter_Unsupported_Feature);
   function To_Godot_String (Text : String) return String;
   function Expr (Node : Node_Index) return String;
   procedure Emit_Statement
     (Node  : in Node_Index;
      Kind  : in Buffer_Kind;
      Level : in Natural);
   procedure Emit_Block
     (Block_Node : in Node_Index;
      Kind       : in Buffer_Kind;
      Level      : in Natural);
   procedure Scan_Top_Level
     (First         : in Node_Index;
      Module_Prefix : in String := "");
   procedure Emit_Top_Level_Declarations
     (First         : in Node_Index;
      Module_Prefix : in String := "");
   procedure Emit_Top_Level_Initializers
     (First         : in Node_Index;
      Module_Prefix : in String := "");
   procedure Emit_Top_Level_Routines
     (First         : in Node_Index;
      Module_Prefix : in String := "");
   procedure Reset_Globals;
   procedure Remember_Global
     (Name         : in String;
      Kind         : in Global_Storage_Kind;
      History_Size : in Natural := 0);
   function Find_Global (Name : String) return Natural;
   function Global_Kind_Of (Name : String) return Global_Storage_Kind;
   function Global_History_Of (Name : String) return Natural;
   function Load_Helper_For_Target
     (Target_Node : in Node_Index;
      Path_Expr   : in String) return String;
   function Assignment_Target_Name (Target_Node : in Node_Index) return String;
   function Firewall_Key_For_Node (Target_Node : in Node_Index) return String;
   function Predicate_Name_From_Node (Pred_Node : in Node_Index) return String;
   function Predicate_First_Arg_Node (Pred_Node : in Node_Index) return Node_Index;
   function Predicate_Name_Expr (Pred_Node : in Node_Index) return String;
   function Predicate_Arg1_Expr (Pred_Node : in Node_Index) return String;
   function Wrap_Firewall_Read
     (Node_Index_Value : in Node_Index;
      Value_Text       : in String) return String;
   function Wrap_Firewall_Write
     (Node_Index_Value : in Node_Index;
      Value_Text       : in String) return String;
   procedure Emit_Firewall_Touch
     (Node_Index_Value : in Node_Index;
      Kind             : in Buffer_Kind;
      Level            : in Natural;
      Need_Read        : in Boolean;
      Need_Write       : in Boolean);
   procedure Emit_Assignment_Text
     (Target_Node    : in Node_Index;
      Value_Expr     : in String;
      Kind           : in Buffer_Kind;
      Level          : in Natural;
      Declare_Local  : in Boolean := False);

   function Trim_Image (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return Ada.Strings.Fixed.Trim (S, Ada.Strings.Both);
   end Trim_Image;

   function Raw_Lexeme (Token_Index : Natural) return String is
      Tok : Token;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return "";
      end if;
      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         return "";
      end if;
      return Input_Buffer (Tok.Start .. Tok.Start + Tok.Length - 1);
   end Raw_Lexeme;

   function To_Upper_Text (Text : String) return String is
      Result : String (Text'Range);
   begin
      for I in Text'Range loop
         Result (I) := Ada.Characters.Handling.To_Upper (Text (I));
      end loop;
      return Result;
   end To_Upper_Text;

   function Escape_CPP_String (Text : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("");
   begin
      for Ch of Text loop
         case Ch is
            when '\' =>
               Append (Result, "\\");
            when '"' =>
               Append (Result, "\""");
            when ASCII.LF =>
               Append (Result, "\n");
            when ASCII.CR =>
               null;
            when ASCII.HT =>
               Append (Result, "\t");
            when others =>
               Append (Result, String'(1 => Ch));
         end case;
      end loop;
      return To_String (Result);
   end Escape_CPP_String;

   function Strip_String_Node (Node : Node_Index) return String is
      Tok : constant Token := Tokens (Tree (Node).Token_Index);
   begin
      if Tok.Length >= 2 then
         return Input_Buffer (Tok.Start + 1 .. Tok.Start + Tok.Length - 2);
      end if;
      return "";
   end Strip_String_Node;

   function Safe_CPP_Name (Name : String) return String is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
      Result  : Unbounded_String := To_Unbounded_String ("");
      Upper   : constant String := To_Upper_Text (Trimmed);
   begin
      if Trimmed'Length = 0 then
         return "alb_anon";
      end if;

      if Trimmed (Trimmed'First) in '0' .. '9' then
         Append (Result, "alb_");
      end if;

      for Ch of Trimmed loop
         if (Ch in 'a' .. 'z') or else
            (Ch in 'A' .. 'Z') or else
            (Ch in '0' .. '9') or else
            Ch = '_'
         then
            Append (Result, String'(1 => Ch));
         elsif Ch = '.' then
            Append (Result, "_");
         else
            Append (Result, "_");
         end if;
      end loop;

      if Upper = "CLASS" or else Upper = "NAMESPACE" or else Upper = "DELETE"
        or else Upper = "TEMPLATE" or else Upper = "PRIVATE" or else Upper = "PUBLIC"
        or else Upper = "PROTECTED" or else Upper = "VIRTUAL" or else Upper = "THIS"
        or else Upper = "NEW" or else Upper = "OPERATOR"
      then
         return "alb_" & To_String (Result);
      end if;

      return To_String (Result);
   end Safe_CPP_Name;

   function Normalize_Resource_Base (Base : String) return String is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Base, Ada.Strings.Both);
      Result  : Unbounded_String := To_Unbounded_String ("");
   begin
      if Trimmed'Length = 0 or else Trimmed = "res://" then
         return "res://";
      end if;

      for Ch of Trimmed loop
         if Ch = '\' then
            Append (Result, "/");
         else
            Append (Result, String'(1 => Ch));
         end if;
      end loop;

      while Length (Result) > 6 and then Element (Result, Length (Result)) = '/' loop
         Delete (Result, Length (Result), Length (Result));
      end loop;

      return To_String (Result);
   end Normalize_Resource_Base;

   function Join_Resource_Path (Base : String; Child : String) return String is
      Normal_Base : constant String := Normalize_Resource_Base (Base);
      Trimmed     : constant String := Ada.Strings.Fixed.Trim (Child, Ada.Strings.Both);
   begin
      if Trimmed'Length = 0 then
         return Normal_Base;
      end if;

      if Normal_Base = "res://" then
         if Trimmed (Trimmed'First) = '/' then
            if Trimmed'Length = 1 then
               return Normal_Base;
            end if;
            return Normal_Base & Trimmed (Trimmed'First + 1 .. Trimmed'Last);
         end if;
         return Normal_Base & Trimmed;
      end if;

      if Trimmed (Trimmed'First) = '/' then
         return Normal_Base & Trimmed;
      end if;
      return Normal_Base & "/" & Trimmed;
   end Join_Resource_Path;

   function Qualified_Name (Raw_Name : String) return String is
      Prefix : constant String := To_String (Current_Module);
   begin
      if Prefix'Length = 0 then
         return Safe_CPP_Name (Raw_Name);
      end if;
      return Safe_CPP_Name (Prefix & "_" & Raw_Name);
   end Qualified_Name;

   function Current_Function_Name (Raw_Name : String) return String is
   begin
      if Length (Current_Module) = 0 then
         return Safe_CPP_Name (Raw_Name);
      end if;
      return Safe_CPP_Name (To_String (Current_Module) & "_" & Raw_Name);
   end Current_Function_Name;

   procedure Reset_Locals is
   begin
      Local_Count := 0;
      for I in Local_Names'Range loop
         Local_Names (I) := To_Unbounded_String ("");
      end loop;
   end Reset_Locals;

   function Local_Seen (Name : String) return Boolean is
   begin
      for I in 1 .. Local_Count loop
         if To_String (Local_Names (I)) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Local_Seen;

   procedure Remember_Local (Name : String) is
   begin
      if Name'Length = 0 or else Local_Seen (Name) then
         return;
      end if;
      if Local_Count < Max_Locals then
         Local_Count := Local_Count + 1;
         Local_Names (Local_Count) := To_Unbounded_String (Name);
      end if;
   end Remember_Local;

   procedure Reset_Globals is
   begin
      Global_Count := 0;
      for I in Globals'Range loop
         Globals (I).Name := To_Unbounded_String ("");
         Globals (I).Kind := Global_Variant;
         Globals (I).History_Size := 0;
      end loop;
   end Reset_Globals;

   function Find_Global (Name : String) return Natural is
   begin
      for I in 1 .. Global_Count loop
         if To_String (Globals (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Global;

   procedure Remember_Global
     (Name         : in String;
      Kind         : in Global_Storage_Kind;
      History_Size : in Natural := 0)
   is
      Existing : constant Natural := Find_Global (Name);
   begin
      if Existing > 0 then
         Globals (Existing).Kind := Kind;
         Globals (Existing).History_Size := History_Size;
         return;
      end if;

      if Global_Count < Max_Globals then
         Global_Count := Global_Count + 1;
         Globals (Global_Count).Name := To_Unbounded_String (Name);
         Globals (Global_Count).Kind := Kind;
         Globals (Global_Count).History_Size := History_Size;
      end if;
   end Remember_Global;

   function Global_Kind_Of (Name : String) return Global_Storage_Kind is
      Index : constant Natural := Find_Global (Name);
   begin
      if Index = 0 then
         return Global_Variant;
      end if;
      return Globals (Index).Kind;
   end Global_Kind_Of;

   function Global_History_Of (Name : String) return Natural is
      Index : constant Natural := Find_Global (Name);
   begin
      if Index = 0 then
         return 1;
      end if;
      return Natural'Max (1, Globals (Index).History_Size);
   end Global_History_Of;

   function Assignment_Target_Name (Target_Node : in Node_Index) return String is
      Node : constant AST_Node := Tree (Target_Node);
   begin
      if Target_Node = 0 then
         return "godot::Variant()";
      elsif Node.Kind = AST_Var_Expr and then Node.Token_Index > 0 then
         return Qualified_Name (Raw_Lexeme (Node.Token_Index));
      else
         return Expr (Target_Node);
      end if;
   end Assignment_Target_Name;

   function Firewall_Key_For_Node (Target_Node : in Node_Index) return String is
      Node : constant AST_Node := Tree (Target_Node);
   begin
      if Target_Node = 0 then
         return "";
      end if;

      case Node.Kind is
         when AST_Var_Expr =>
            declare
               Raw  : constant String := (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
               Name : constant String := Qualified_Name (Raw);
            begin
               if Local_Seen (Name) then
                  return "";
               elsif Find_Global (Name) > 0 then
                  return Name;
               else
                  return "";
               end if;
            end;

         when AST_Array_Access =>
            declare
               Raw  : constant String := (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
               Name : constant String := Qualified_Name (Raw);
            begin
               if Local_Seen (Name) then
                  return "";
               elsif Find_Global (Name) > 0 then
                  return Name;
               else
                  return "";
               end if;
            end;

         when AST_Member_Expr =>
            declare
               Base_Node  : constant Node_Index := Node.Left_Child;
               Field_Node : constant Node_Index := Node.Right_Child;
               Field_Name : constant String :=
                 (if Field_Node > 0 and then Tree (Field_Node).Token_Index > 0
                  then Safe_CPP_Name (Raw_Lexeme (Tree (Field_Node).Token_Index))
                  else "field");
            begin
               if Base_Node > 0 and then Tree (Base_Node).Kind = AST_Var_Expr then
                  declare
                     Raw  : constant String := Raw_Lexeme (Tree (Base_Node).Token_Index);
                     Name : constant String := Qualified_Name (Raw);
                  begin
                     if Local_Seen (Name) then
                        return "";
                     elsif Find_Global (Name) > 0 then
                        return Name & "." & Field_Name;
                     end if;
                  end;
               elsif Base_Node > 0 and then Tree (Base_Node).Kind = AST_Array_Access then
                  declare
                     Raw  : constant String := Raw_Lexeme (Tree (Base_Node).Token_Index);
                     Name : constant String := Qualified_Name (Raw);
                  begin
                     if not Local_Seen (Name) and then Find_Global (Name) > 0 then
                        return Name & "." & Field_Name;
                     end if;
                  end;
               end if;
               return "";
            end;

         when others =>
            return "";
      end case;
   end Firewall_Key_For_Node;

   function Wrap_Firewall_Read
     (Node_Index_Value : in Node_Index;
      Value_Text       : in String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return Value_Text;
      else
         return "alb_firewall_read(" & To_Godot_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Read;

   function Wrap_Firewall_Write
     (Node_Index_Value : in Node_Index;
      Value_Text       : in String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return Value_Text;
      else
         return "alb_firewall_write(" & To_Godot_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Write;

   function Predicate_Name_From_Node (Pred_Node : in Node_Index) return String is
      Node : AST_Node;
   begin
      if Pred_Node = 0 then
         return "";
      end if;

      Node := Tree (Pred_Node);

      case Node.Kind is
         when AST_Predicate | AST_Assert_Stmt | AST_Retract_Stmt =>
            return Raw_Lexeme (Node.Token_Index);
         when AST_Update_Stmt | AST_Findall_Query | AST_Query | AST_Knows_Query =>
            if Node.Left_Child > 0 then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return "";
         when AST_Find_Query =>
            if Node.Left_Child > 0 then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return Raw_Lexeme (Node.Token_Index);
         when AST_Func_Call | AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            if Node.Token_Index > 0 then
               return Raw_Lexeme (Node.Token_Index);
            end if;
            return "";
         when others =>
            if Node.Token_Index > 0 then
               return Raw_Lexeme (Node.Token_Index);
            end if;
            return "";
      end case;
   end Predicate_Name_From_Node;

   function Predicate_First_Arg_Node (Pred_Node : in Node_Index) return Node_Index is
      Node : AST_Node;
   begin
      if Pred_Node = 0 then
         return 0;
      end if;

      Node := Tree (Pred_Node);

      if Node.Kind = AST_Predicate and then Node.Left_Child > 0 then
         if Tree (Node.Left_Child).Kind = AST_Arg_List then
            return Tree (Node.Left_Child).Left_Child;
         else
            return Node.Left_Child;
         end if;
      elsif Node.Kind in AST_Update_Stmt | AST_Findall_Query | AST_Query | AST_Knows_Query then
         return Predicate_First_Arg_Node (Node.Left_Child);
      elsif Node.Kind = AST_Find_Query then
         if Node.Left_Child > 0 then
            return Predicate_First_Arg_Node (Node.Left_Child);
         end if;
         return 0;
      elsif Node.Kind in AST_Assert_Stmt | AST_Retract_Stmt then
         return Node.Left_Child;
      elsif Node.Kind = AST_Func_Call and then Node.Right_Child > 0 then
         if Tree (Node.Right_Child).Kind = AST_Arg_List then
            return Tree (Node.Right_Child).Left_Child;
         else
            return Node.Right_Child;
         end if;
      else
         return 0;
      end if;
   end Predicate_First_Arg_Node;

   function Predicate_Name_Expr (Pred_Node : in Node_Index) return String is
   begin
      return To_Godot_String (Predicate_Name_From_Node (Pred_Node));
   end Predicate_Name_Expr;

   function Predicate_Arg1_Expr (Pred_Node : in Node_Index) return String is
      Arg_Node : constant Node_Index := Predicate_First_Arg_Node (Pred_Node);
   begin
      if Arg_Node > 0 then
         return Expr (Arg_Node);
      else
         return "godot::Variant((int64_t)0)";
      end if;
   end Predicate_Arg1_Expr;

   procedure Emit_Firewall_Touch
     (Node_Index_Value : in Node_Index;
      Kind             : in Buffer_Kind;
      Level            : in Natural;
      Need_Read        : in Boolean;
      Need_Write       : in Boolean)
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return;
      end if;

      if Need_Read then
         Buffer_Line (Kind, Level, "alb_firewall_touch_read(" & To_Godot_String (Key) & ");");
      end if;

      if Need_Write then
         Buffer_Line (Kind, Level, "alb_firewall_touch_write(" & To_Godot_String (Key) & ");");
      end if;
   end Emit_Firewall_Touch;

   function Declared_History_Size (Node : Node_Index) return Natural is
      Raw : constant String :=
        (if Node > 0 and then Tree (Node).Right_Child > 0
         then Raw_Lexeme (Tree (Tree (Node).Right_Child).Token_Index)
         else "");
   begin
      if Raw'Length = 0 then
         return 1;
      end if;
      return Natural'Max (1, Natural (Integer'Value (Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Both))));
   exception
      when others =>
         return 1;
   end Declared_History_Size;

   function Activation_Code (Text : String) return String is
      Upper : constant String := To_Upper_Text (Text);
   begin
      if Upper = "RELU" then
         return "1";
      elsif Upper = "SIGMOID" then
         return "2";
      elsif Upper = "TANH" then
         return "3";
      else
         return "0";
      end if;
   end Activation_Code;

   function Network_Protocol_Code (Text : String) return String is
      Upper : constant String := To_Upper_Text (Text);
   begin
      if Upper = "UDP" then
         return "2";
      else
         return "1";
      end if;
   end Network_Protocol_Code;

   function Is_Module_Name (Name : String) return Boolean is
      Safe : constant String := Safe_CPP_Name (Name);
   begin
      for I in 1 .. Module_Count loop
         if To_String (Module_Names (I)) = Safe then
            return True;
         end if;
      end loop;
      return False;
   end Is_Module_Name;

   procedure Remember_Module (Name : String) is
      Safe : constant String := Safe_CPP_Name (Name);
   begin
      if Safe'Length = 0 then
         return;
      end if;
      if Is_Module_Name (Safe) then
         return;
      end if;
      if Module_Count < Max_Modules then
         Module_Count := Module_Count + 1;
         Module_Names (Module_Count) := To_Unbounded_String (Safe);
      end if;
   end Remember_Module;

   function Is_Struct_Name (Name : String) return Boolean is
      Safe : constant String := Safe_CPP_Name (Name);
   begin
      for I in 1 .. Struct_Count loop
         if To_String (Struct_Names (I)) = Safe then
            return True;
         end if;
      end loop;
      return False;
   end Is_Struct_Name;

   procedure Remember_Struct (Name : String) is
      Safe : constant String := Safe_CPP_Name (Name);
   begin
      if Safe'Length = 0 then
         return;
      end if;
      if Is_Struct_Name (Safe) then
         return;
      end if;
      if Struct_Count < Max_Structs then
         Struct_Count := Struct_Count + 1;
         Struct_Names (Struct_Count) := To_Unbounded_String (Safe);
      end if;
   end Remember_Struct;

   function Node_Default_Value return String is
   begin
      return "godot::Variant()";
   end Node_Default_Value;

   procedure Buffer_Line
     (Kind  : in Buffer_Kind;
      Level : in Natural;
      Text  : in String)
   is
      Prefix : Unbounded_String := To_Unbounded_String ("");
   begin
      for I in 1 .. Level loop
         Append (Prefix, "    ");
      end loop;

      case Kind is
         when Buf_Global_Decls =>
            Append (Global_Decls, To_String (Prefix));
            Append (Global_Decls, Text);
            Append (Global_Decls, ASCII.LF & "");
         when Buf_Global_Bootstrap =>
            Append (Global_Bootstrap, To_String (Prefix));
            Append (Global_Bootstrap, Text);
            Append (Global_Bootstrap, ASCII.LF & "");
         when Buf_Structs =>
            Append (Struct_Buffer, To_String (Prefix));
            Append (Struct_Buffer, Text);
            Append (Struct_Buffer, ASCII.LF & "");
         when Buf_Routines =>
            Append (Routine_Buffer, To_String (Prefix));
            Append (Routine_Buffer, Text);
            Append (Routine_Buffer, ASCII.LF & "");
         when Buf_Begin =>
            Append (Begin_Buffer, To_String (Prefix));
            Append (Begin_Buffer, Text);
            Append (Begin_Buffer, ASCII.LF & "");
         when Buf_Tick =>
            Append (Tick_Buffer, To_String (Prefix));
            Append (Tick_Buffer, Text);
            Append (Tick_Buffer, ASCII.LF & "");
         when Buf_Paint =>
            Append (Paint_Buffer, To_String (Prefix));
            Append (Paint_Buffer, Text);
            Append (Paint_Buffer, ASCII.LF & "");
         when Buf_Key =>
            Append (Key_Buffer, To_String (Prefix));
            Append (Key_Buffer, Text);
            Append (Key_Buffer, ASCII.LF & "");
         when Buf_Warnings =>
            Append (Warning_Buffer, To_String (Prefix));
            Append (Warning_Buffer, Text);
            Append (Warning_Buffer, ASCII.LF & "");
      end case;
   end Buffer_Line;

   procedure Store_Diagnostic_Message
     (Text   : in String;
      Buffer : out Diagnostic_Message_Buffer;
      Length : out Natural)
   is
      Copy_Len : constant Natural :=
        (if Text'Length > Max_Diagnostic_Message_Len
         then Max_Diagnostic_Message_Len
         else Text'Length);
   begin
      Buffer := (others => ' ');
      Length := Copy_Len;
      for I in 1 .. Copy_Len loop
         Buffer (I) := Text (Text'First + I - 1);
      end loop;
   end Store_Diagnostic_Message;

   procedure Add_Warning
     (Node    : in Node_Index;
      Message : in String;
      Category : in Emitter_Diagnostic_Category := Emitter_Unsupported_Feature)
   is
      Slot : Natural := 0;
      Token_Index : Natural := 0;
   begin
      if Node > 0 then
         Token_Index := Tree (Node).Token_Index;
      end if;

      Buffer_Line (Buf_Warnings, 0, "// ALBGD warning: " & Message);

      if Current_Diagnostic.Had_Warnings = False then
         Current_Diagnostic.Had_Warnings := True;
      end if;
      Current_Diagnostic.Warning_Count := Current_Diagnostic.Warning_Count + 1;
      Compilation_Had_Warnings := True;

      if Current_Diagnostic.Stored_Count < Max_Emitter_Diagnostics then
         Current_Diagnostic.Stored_Count := Current_Diagnostic.Stored_Count + 1;
         Slot := Current_Diagnostic.Stored_Count;
         Current_Diagnostic.Entries (Slot).Active := True;
         Current_Diagnostic.Entries (Slot).Node := Node;
         Current_Diagnostic.Entries (Slot).Token_Index := Token_Index;
         if Token_Index > 0 and then Token_Index <= Tokens'Length then
            Current_Diagnostic.Entries (Slot).Line := Tokens (Token_Index).Line;
            Current_Diagnostic.Entries (Slot).Column := Tokens (Token_Index).Column;
         end if;
         Current_Diagnostic.Entries (Slot).Category := Category;
         Store_Diagnostic_Message
           (Message,
            Current_Diagnostic.Entries (Slot).Message,
            Current_Diagnostic.Entries (Slot).Message_Len);
      end if;
   end Add_Warning;

   function To_Godot_String (Text : String) return String is
   begin
      return "godot::String(""" & Escape_CPP_String (Text) & """)";
   end To_Godot_String;

   function Base_Include_Name (Base : String) return String is
      Upper : constant String := To_Upper_Text (Base);
   begin
      if Upper = "NODE2D" then
         return "node2d.hpp";
      elsif Upper = "CONTROL" then
         return "control.hpp";
      elsif Upper = "NODE" then
         return "node.hpp";
      elsif Upper = "CHARACTERBODY2D" then
         return "character_body2d.hpp";
      elsif Upper = "AREA2D" then
         return "area2d.hpp";
      else
         return "node2d.hpp";
      end if;
   end Base_Include_Name;

   function Is_Drawable_Base (Base : String) return Boolean is
      Upper : constant String := To_Upper_Text (Base);
   begin
      return Upper = "NODE2D" or else Upper = "CONTROL" or else Upper = "CHARACTERBODY2D" or else Upper = "AREA2D";
   end Is_Drawable_Base;

   function Default_Class_Name (Name : String) return String is
      Safe : constant String := Safe_CPP_Name (Name);
   begin
      if Safe'Length = 0 then
         return "AlbGeneratedNode";
      end if;
      return Safe;
   end Default_Class_Name;

   function Token_To_Cpp_Name (Node : Node_Index) return String is
   begin
      if Node = 0 or else Tree (Node).Token_Index = 0 then
         return "alb_missing";
      end if;
      return Safe_CPP_Name (Raw_Lexeme (Tree (Node).Token_Index));
   end Token_To_Cpp_Name;

   function Collect_Module_Member_Name (Node : Node_Index) return String is
      Left_Node  : constant Node_Index := Tree (Node).Left_Child;
      Right_Node : constant Node_Index := Tree (Node).Right_Child;
      Left_Name  : constant String := Token_To_Cpp_Name (Left_Node);
      Right_Name : constant String := Token_To_Cpp_Name (Right_Node);
   begin
      if Left_Node = 0 or else Right_Node = 0 then
         return "alb_missing_member";
      end if;
      return Safe_CPP_Name (Left_Name & "_" & Right_Name);
   end Collect_Module_Member_Name;

   function Expr_List (First : Node_Index) return String is
      Result : Unbounded_String := To_Unbounded_String ("");
      Curr   : Node_Index := First;
      First_Arg : Boolean := True;
   begin
      while Curr > 0 loop
         if not First_Arg then
            Append (Result, ", ");
         end if;
         Append (Result, Expr (Curr));
         First_Arg := False;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
      return To_String (Result);
   end Expr_List;

   function Expr (Node : Node_Index) return String is
   begin
      if Node = 0 then
         return "godot::Variant()";
      end if;

      declare
         N       : constant AST_Node := Tree (Node);
         Raw     : constant String :=
           (if N.Token_Index > 0 then Raw_Lexeme (N.Token_Index) else "");
         Op      : constant String := To_Upper_Text (Raw);
         Left    : constant Node_Index := N.Left_Child;
         Right   : constant Node_Index := N.Right_Child;
      begin
         case N.Kind is
         when AST_Number_Expr =>
            return "godot::Variant(" & Raw & ")";

         when AST_Hex_Expr =>
            if Raw'Length > 1 and then Raw (Raw'First) = '$' then
               return "godot::Variant((int64_t)0x" & Raw (Raw'First + 1 .. Raw'Last) & ")";
            end if;
            return "godot::Variant((int64_t)0)";

         when AST_Bin_Expr =>
            if Raw'Length > 1 and then Raw (Raw'First) = '%' then
               return "alb_parse_binary(" & To_Godot_String (Raw (Raw'First + 1 .. Raw'Last)) & ")";
            end if;
            return "godot::Variant((int64_t)0)";

         when AST_Octal_Expr =>
            return "alb_parse_octal(" & To_Godot_String (Raw) & ")";

         when AST_String_Expr =>
            return To_Godot_String (Strip_String_Node (Node));

         when AST_True =>
            return "godot::Variant(true)";

         when AST_False =>
            return "godot::Variant(false)";

         when AST_Var_Expr =>
            return Wrap_Firewall_Read (Node, Qualified_Name (Raw));

         when AST_Const_Ref =>
            if Raw'Length > 1 and then Raw (Raw'First) = '#' then
               return Safe_CPP_Name (Raw (Raw'First + 1 .. Raw'Last));
            end if;
            return Safe_CPP_Name (Raw);

         when AST_Member_Expr =>
            if Left > 0 and then Tree (Left).Kind = AST_Var_Expr and then Is_Module_Name (Raw_Lexeme (Tree (Left).Token_Index)) then
               return Collect_Module_Member_Name (Node);
            elsif Left > 0 and then Tree (Left).Kind = AST_Array_Access then
               return Wrap_Firewall_Read
                 (Node,
                  "alb_get_member_index(" & Token_To_Cpp_Name (Left) & ", " &
                 Expr (Tree (Left).Left_Child) & ", " &
                 To_Godot_String (Raw_Lexeme (Tree (Right).Token_Index)) & ")");
            else
               return Wrap_Firewall_Read
                 (Node,
                  "alb_get_member(" & Expr (Left) & ", " &
                  To_Godot_String (Raw_Lexeme (Tree (Right).Token_Index)) & ")");
            end if;

         when AST_Array_Access =>
            return Wrap_Firewall_Read (Node, "alb_index(" & Safe_CPP_Name (Raw) & ", " & Expr (Left) & ")");

         when AST_Str_Len =>
            return "godot::Variant((int64_t)alb_to_string(" & Expr (Left) & ").length())";

         when AST_Str_Left =>
            return "alb_left(" & Expr (Left) & ", " & Expr (Right) & ")";

         when AST_Str_Right =>
            return "alb_right(" & Expr (Left) & ", " & Expr (Right) & ")";

         when AST_Str_Mid =>
            return "alb_mid(" & Expr (Left) & ", " & Expr (Right) & ")";

         when AST_Cast_Expr =>
            if Op = "STRING" then
               return "godot::Variant(alb_to_string(" & Expr (Left) & "))";
            elsif Op = "F64" or else Op = "DOUBLE" then
               return "godot::Variant(alb_to_double(" & Expr (Left) & "))";
            elsif Op = "BOOL" or else Op = "BOOLEAN" then
               return "godot::Variant(alb_to_bool(" & Expr (Left) & "))";
            else
               return "godot::Variant(alb_to_i64(" & Expr (Left) & "))";
            end if;

         when AST_Unary_Minus =>
            return "godot::Variant(-alb_to_double(" & Expr (Left) & "))";

         when AST_Not =>
            return "godot::Variant(!alb_to_bool(" & Expr (Left) & "))";

         when AST_BinOp =>
            if Raw = "|" or else Raw = "&" then
               return "godot::Variant(alb_cat(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "+" then
               return "godot::Variant(alb_add(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "-" then
               return "godot::Variant(alb_sub(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "*" then
               return "godot::Variant(alb_mul(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "/" then
               return "godot::Variant(alb_div(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Op = "MOD" then
               return "godot::Variant(alb_mod(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Op = "AND" then
               return "godot::Variant(alb_bitand(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Op = "OR" then
               return "godot::Variant(alb_bitor(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Op = "XOR" then
               return "godot::Variant(alb_bitxor(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "=" then
               return "godot::Variant(alb_eq(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "<>" then
               return "godot::Variant(!alb_eq(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "<" then
               return "godot::Variant(alb_lt(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = ">" then
               return "godot::Variant(alb_gt(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = "<=" then
               return "godot::Variant(alb_lte(" & Expr (Left) & ", " & Expr (Right) & "))";
            elsif Raw = ">=" then
               return "godot::Variant(alb_gte(" & Expr (Left) & ", " & Expr (Right) & "))";
            else
               return "godot::Variant(alb_fallback_binop(" &
                 To_Godot_String (Raw) & ", " & Expr (Left) & ", " & Expr (Right) & "))";
            end if;

         when AST_Func_Call =>
            if Left > 0 and then Tree (Left).Kind = AST_Member_Expr
              and then Tree (Tree (Left).Left_Child).Kind = AST_Var_Expr
              and then Is_Module_Name (Raw_Lexeme (Tree (Tree (Left).Left_Child).Token_Index))
            then
               return Collect_Module_Member_Name (Left) & "(" &
                 (if Right > 0 then Expr_List (Tree (Right).Left_Child) else "") & ")";
            else
               return Safe_CPP_Name (Raw_Lexeme (Tree (Left).Token_Index)) & "(" &
                 (if Right > 0 then Expr_List (Tree (Right).Left_Child) else "") & ")";
            end if;

         when AST_Key_State =>
            return "godot::Variant(alb_key(" & Expr (Left) & "))";

         when AST_Mouse_X =>
            return "godot::Variant(alb_mouse_x())";

         when AST_Mouse_Y =>
            return "godot::Variant(alb_mouse_y())";

         when AST_Mouse_Wheel =>
            return "godot::Variant(0)";

         when AST_VMouse_X =>
            return "godot::Variant(alb_vmouse_x())";

         when AST_VMouse_y =>
            return "godot::Variant(alb_vmouse_y())";

         when AST_Mouse_Click =>
            return "godot::Variant(alb_mouse_click(" & Expr (Left) & "))";

         when AST_SCREEN_WIDTH =>
            return "godot::Variant(alb_screen_width())";

         when AST_SCREEN_HEIGHT =>
            return "godot::Variant(alb_screen_height())";

         when AST_VIRTUAL_WIDTH =>
            return "godot::Variant(alb_virtual_width())";

         when AST_VIRTUAL_HEIGHT =>
            return "godot::Variant(alb_virtual_height())";

         when AST_Rnd_Expr =>
            if Left > 0 then
               return "godot::Variant(alb_rnd(" & Expr (Left) & "))";
            else
               return "godot::Variant(alb_rnd(godot::Variant((int64_t)32767)))";
            end if;

         when AST_Read_Pixel =>
            return "godot::Variant(alb_read_pixel(" & (if Left > 0 then Expr_List (Tree (Left).Left_Child) else "") & "))";

         when AST_Temporal_Ref =>
            declare
               Base_Name : constant String :=
                 (if Left > 0 and then Tree (Left).Token_Index > 0
                  then Qualified_Name (Raw_Lexeme (Tree (Left).Token_Index))
                  else "");
               Hist      : constant String := Trim_Image (Integer (Global_History_Of (Base_Name)));
            begin
               if Base_Name'Length = 0 then
                  return "alb_temporal_ref(" & Expr (Left) & ", " & To_Godot_String (Raw) & ")";
               elsif Op = "NOW" then
                  return Base_Name;
               elsif Op = "PAST" then
                  return Base_Name & "_history[(" & Base_Name & "_head + " & Hist & " - 1) % " & Hist & "]";
               elsif Op = "FUTURE" then
                  return Base_Name & "_history[(" & Base_Name & "_head + 1) % " & Hist & "]";
               elsif Op = "TIMELINE" then
                  return "godot::Variant((int64_t)" & Hist & ")";
               else
                  return Base_Name;
               end if;
            end;

         when AST_Peek_Expr =>
            return "alb_unsupported_value(" & To_Godot_String ("PEEK") & ")";

         when AST_Predict_Markov_Stmt =>
            return "godot::Variant((int64_t)alb_markov_predict(" & Expr (Left) & ", " & Expr (Right) & "))";

         when AST_Knows_Query | AST_Query =>
            return "godot::Variant((int64_t)alb_rel_has(" & Predicate_Name_Expr (Node) & ", " & Predicate_Arg1_Expr (Node) & "))";

         when AST_File_Open =>
            return "alb_file_open(" & Expr (Left) & ", " & Expr (Right) & ")";

         when AST_File_Len =>
            return "alb_file_len(" & Expr (Left) & ")";

         when AST_File_Seek =>
            return "alb_file_seek(" & Expr (Left) & ", " & Expr (Right) & ")";

         when AST_File_Read =>
            return "alb_file_read(" & Expr (Left) & ", " & Expr (Right) & ")";

         when AST_Find_Query =>
            return "alb_rel_find1(" & Predicate_Name_Expr (Node) & ")";

         when AST_Findall_Query =>
            return "godot::Variant((int64_t)alb_rel_count(" & Predicate_Name_Expr (Node) & "))";

         when others =>
            Add_Warning (Node, "unsupported expression node " & Node_Kind'Image (N.Kind),
                         Emitter_Unsupported_Expression_Node);
            return "godot::Variant()";
         end case;
      end;
   end Expr;

   function Load_Helper_For_Target
     (Target_Node : in Node_Index;
      Path_Expr   : in String) return String
   is
      TNode : constant AST_Node := Tree (Target_Node);
      Name  : constant String :=
        (if TNode.Token_Index > 0 then Qualified_Name (Raw_Lexeme (TNode.Token_Index)) else "");
   begin
      if TNode.Kind /= AST_Var_Expr then
         return "alb_load_value(" & Path_Expr & ")";
      end if;

      case Global_Kind_Of (Name) is
         when Global_String =>
            return "alb_load_text(" & Path_Expr & ")";
         when Global_Array | Global_Slide =>
            return "alb_load_buffer(" & Path_Expr & ")";
         when others =>
            return "alb_load_value(" & Path_Expr & ")";
      end case;
   end Load_Helper_For_Target;

   procedure Emit_Assignment_Text
     (Target_Node    : in Node_Index;
      Value_Expr     : in String;
      Kind           : in Buffer_Kind;
      Level          : in Natural;
      Declare_Local  : in Boolean := False)
   is
      TNode : constant AST_Node := Tree (Target_Node);
      Name  : constant String := (if TNode.Token_Index > 0 then Raw_Lexeme (TNode.Token_Index) else "alb_target");
      Safe  : constant String := Qualified_Name (Name);
   begin
      case TNode.Kind is
         when AST_Var_Expr =>
            if Declare_Local then
               Remember_Local (Safe);
               Buffer_Line (Kind, Level, "godot::Variant " & Safe & " = " & Value_Expr & ";");
            else
               Buffer_Line (Kind, Level, Safe & " = " & Wrap_Firewall_Write (Target_Node, Value_Expr) & ";");
            end if;

         when AST_Array_Access =>
            if Firewall_Key_For_Node (Target_Node)'Length > 0 then
               Buffer_Line (Kind, Level, "alb_firewall_touch_write(" & To_Godot_String (Firewall_Key_For_Node (Target_Node)) & ");");
            end if;
            Buffer_Line
              (Kind,
               Level,
               "alb_set_index(" & Safe_CPP_Name (Name) & ", " &
               Expr (TNode.Left_Child) & ", " & Value_Expr & ");");

         when AST_Member_Expr =>
            declare
               Base_Node  : constant Node_Index := TNode.Left_Child;
               Field_Node : constant Node_Index := TNode.Right_Child;
               Field_Name : constant String :=
                 (if Field_Node > 0 then Raw_Lexeme (Tree (Field_Node).Token_Index) else "field");
            begin
               if Firewall_Key_For_Node (Target_Node)'Length > 0 then
                  Buffer_Line (Kind, Level, "alb_firewall_touch_write(" & To_Godot_String (Firewall_Key_For_Node (Target_Node)) & ");");
               end if;
               if Base_Node > 0 and then Tree (Base_Node).Kind = AST_Array_Access then
                  Buffer_Line
                    (Kind,
                     Level,
                     "alb_set_member_index(" &
                     Safe_CPP_Name (Raw_Lexeme (Tree (Base_Node).Token_Index)) & ", " &
                     Expr (Tree (Base_Node).Left_Child) & ", " &
                     To_Godot_String (Field_Name) & ", " & Value_Expr & ");");
               else
                  Buffer_Line
                    (Kind,
                     Level,
                     "alb_set_member(" & Expr (Base_Node) & ", " &
                     To_Godot_String (Field_Name) & ", " & Value_Expr & ");");
               end if;
            end;

         when others =>
            Add_Warning (Target_Node, "unsupported assignment target " & Node_Kind'Image (TNode.Kind),
                         Emitter_Unsupported_Statement_Node);
      end case;
   end Emit_Assignment_Text;

   procedure Emit_Assignment
     (Target_Node : in Node_Index;
      Value_Node  : in Node_Index;
      Kind        : in Buffer_Kind;
      Level       : in Natural;
      Declare_Local : in Boolean := False)
   is
      Init : constant String := Expr (Value_Node);
   begin
      Emit_Assignment_Text (Target_Node, Init, Kind, Level, Declare_Local);
   end Emit_Assignment;

   procedure Emit_Print
     (Node  : in Node_Index;
      Kind  : in Buffer_Kind;
      Level : in Natural)
   is
   begin
      if Tree (Node).Left_Child > 0 then
         Buffer_Line
           (Kind,
            Level,
            "alb_print(" & Expr (Tree (Node).Left_Child) & ");");
      end if;
   end Emit_Print;

   procedure Emit_Draw_Stmt
     (Node  : in Node_Index;
      Kind  : in Buffer_Kind;
      Level : in Natural)
   is
      Args  : Name_List := (others => To_Unbounded_String ("0"));
      Count : Natural := 0;
      Curr  : Node_Index := 0;
      Call_Name : Unbounded_String := To_Unbounded_String ("");
   begin
      if Tree (Node).Left_Child > 0 and then Tree (Tree (Node).Left_Child).Kind = AST_Arg_List then
         Curr := Tree (Tree (Node).Left_Child).Left_Child;
         while Curr > 0 and then Count < 8 loop
            Count := Count + 1;
            Args (Count) := To_Unbounded_String (Expr (Curr));
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;

      if Tree (Node).Kind = AST_Text then
         if Count >= 3 then
            Buffer_Line
              (Kind,
               Level,
               "alb_draw_text(" & To_String (Args (1)) & ", " &
               To_String (Args (2)) & ", alb_to_string(" & To_String (Args (3)) & "));");
         end if;
         return;
      elsif Tree (Node).Kind = AST_Plot then
         if Count >= 2 then
            Buffer_Line
              (Kind,
               Level,
               "alb_plot(" & To_String (Args (1)) & ", " & To_String (Args (2)) & ");");
         end if;
         return;
      end if;

      case Tokens (Tree (Node).Token_Index).Kind is
         when Tok_Rect =>
            if Tree (Node).Kind = AST_Draw then
               Call_Name := To_Unbounded_String ("alb_draw_rect");
            else
               Call_Name := To_Unbounded_String ("alb_fill_rect");
            end if;
         when Tok_Line =>
            Call_Name := To_Unbounded_String ("alb_draw_line");
         when Tok_Circle =>
            if Tree (Node).Kind = AST_Draw then
               Call_Name := To_Unbounded_String ("alb_draw_circle");
            else
               Call_Name := To_Unbounded_String ("alb_fill_circle");
            end if;
         when Tok_Triangle =>
            if Tree (Node).Kind = AST_Draw then
               Call_Name := To_Unbounded_String ("alb_draw_triangle");
            else
               Call_Name := To_Unbounded_String ("alb_fill_triangle");
            end if;
         when others =>
            Call_Name := To_Unbounded_String ("");
      end case;

      if Length (Call_Name) = 0 then
         Add_Warning (Node, "unsupported draw primitive", Emitter_Unsupported_Statement_Node);
         return;
      end if;

      Buffer_Line (Kind, Level, To_String (Call_Name) & "(" & Expr_List (Tree (Tree (Node).Left_Child).Left_Child) & ");");
   end Emit_Draw_Stmt;

   procedure Emit_Select
     (Node  : in Node_Index;
      Kind  : in Buffer_Kind;
      Level : in Natural)
   is
      Switch_Node : constant Node_Index := Tree (Node).Right_Child;
      Curr        : Node_Index := Switch_Node;
      Target_Expr : constant String := Expr (Tree (Node).Left_Child);
      First_Arm   : Boolean := True;
      Saw_Else    : Boolean := False;
   begin
      Buffer_Line (Kind, Level, "{");
      Buffer_Line (Kind, Level + 1, "godot::Variant alb_select_target = " & Target_Expr & ";");
      while Curr > 0 loop
         if Tree (Curr).Kind = AST_Case_Stmt then
            if Tree (Curr).Left_Child = 0 then
               -- ELSE / CASE ELSE arm
               if First_Arm then
                  Buffer_Line (Kind, Level + 1, "{");
               else
                  Buffer_Line (Kind, Level + 1, "else {");
               end if;
               Emit_Block (Tree (Curr).Right_Child, Kind, Level + 2);
               Buffer_Line (Kind, Level + 1, "}");
               First_Arm := False;
               Saw_Else := True;
            else
               if First_Arm then
                  Buffer_Line
                    (Kind, Level + 1,
                     "if (alb_eq(alb_select_target, " &
                     Expr (Tree (Curr).Left_Child) & ")) {");
               else
                  Buffer_Line
                    (Kind, Level + 1,
                     "else if (alb_eq(alb_select_target, " &
                     Expr (Tree (Curr).Left_Child) & ")) {");
               end if;
               Emit_Block (Tree (Curr).Right_Child, Kind, Level + 2);
               Buffer_Line (Kind, Level + 1, "}");
               First_Arm := False;
            end if;
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
      if not Saw_Else and then not First_Arm then
         null; -- open if-chain with no else is fine
      end if;
      Buffer_Line (Kind, Level, "}");
   end Emit_Select;

   procedure Emit_Statement
     (Node  : in Node_Index;
      Kind  : in Buffer_Kind;
      Level : in Natural)
   is
      N          : constant AST_Node := Tree (Node);
      Loop_Spec  : Node_Index := 0;
      Start_Node : Node_Index := 0;
      End_Node   : Node_Index := 0;
      Step_Node  : Node_Index := 0;
      Step_Expr  : Unbounded_String := To_Unbounded_String ("");
      Var_Name   : Unbounded_String := To_Unbounded_String ("");
      Var_Safe   : Unbounded_String := To_Unbounded_String ("");
   begin
      if Node = 0 then
         return;
      end if;

      case N.Kind is
         when AST_Block_Stmt =>
            Emit_Block (Node, Kind, Level);

         when AST_Version | AST_Const_Decl | AST_String_Decl | AST_Strict_Stmt |
              AST_Slide_Stmt | AST_Temporal_Decl | AST_Parallel_Decl |
              AST_Markov_Model_Decl | AST_Neural_Topology_Decl |
              AST_Network_Socket_Decl | AST_Memory_Firewall_Decl |
              AST_Struct_Decl | AST_Procedure_Decl | AST_Function_Decl |
              AST_Module | AST_On_Block |
              AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar |
              AST_Import_ES | AST_Import_WASM | AST_Export_DLL | AST_Export_SO |
              AST_Export_Dylib | AST_Export_Jar | AST_Export_ES | AST_Export_WASM =>
            null;

         when AST_Let_Stmt =>
            if Length (Current_Routine) = 0 and then Kind = Buf_Global_Bootstrap then
               Emit_Assignment (N.Left_Child, N.Right_Child, Kind, Level, False);
            elsif Length (Current_Routine) = 0 and then Kind = Buf_Begin then
               Emit_Assignment (N.Left_Child, N.Right_Child, Kind, Level, False);
            else
               declare
                  Target_Name : constant String :=
                    (if N.Left_Child > 0 and then Tree (N.Left_Child).Token_Index > 0
                     then Qualified_Name (Raw_Lexeme (Tree (N.Left_Child).Token_Index))
                     else "");
               begin
                  Emit_Assignment
                     (N.Left_Child,
                      N.Right_Child,
                      Kind,
                      Level,
                      Declare_Local => (Target_Name'Length > 0 and then not Local_Seen (Target_Name)));
               end;
            end if;

         when AST_Print_Stmt | AST_Print_Str_Stmt =>
            Emit_Print (Node, Kind, Level);

         when AST_Call_Stmt =>
            if N.Left_Child > 0 then
               Buffer_Line (Kind, Level, Expr (N.Left_Child) & ";");
            end if;

         when AST_Return_Stmt =>
            if N.Left_Child > 0 then
               Buffer_Line (Kind, Level, "return " & Expr (N.Left_Child) & ";");
            else
               Buffer_Line (Kind, Level, "return;");
            end if;

         when AST_If_Stmt =>
            Buffer_Line (Kind, Level, "if (alb_to_bool(" & Expr (N.Left_Child) & ")) {");
            Emit_Block (N.Right_Child, Kind, Level + 1);
            if N.Right_Child > 0 and then Tree (N.Right_Child).Next_Sibling > 0 then
               Buffer_Line (Kind, Level, "} else {");
               Emit_Block (Tree (N.Right_Child).Next_Sibling, Kind, Level + 1);
               Buffer_Line (Kind, Level, "}");
            else
               Buffer_Line (Kind, Level, "}");
            end if;

         when AST_While_Stmt =>
            Buffer_Line (Kind, Level, "while (alb_to_bool(" & Expr (N.Left_Child) & ")) {");
            Emit_Block (N.Right_Child, Kind, Level + 1);
            Buffer_Line (Kind, Level, "}");

         when AST_Repeat_Stmt =>
            Buffer_Line (Kind, Level, "do {");
            Emit_Block (N.Left_Child, Kind, Level + 1);
            Buffer_Line (Kind, Level, "} while (!alb_to_bool(" & Expr (N.Right_Child) & "));");

         when AST_For_Stmt =>
            Loop_Spec := N.Left_Child;
            if Loop_Spec > 0 then
               Start_Node := Tree (Loop_Spec).Left_Child;
               if Tree (Loop_Spec).Right_Child > 0 then
                  if Tree (Tree (Loop_Spec).Right_Child).Kind = AST_Arg_List then
                     End_Node := Tree (Tree (Loop_Spec).Right_Child).Left_Child;
                     if End_Node > 0 then
                        Step_Node := Tree (End_Node).Next_Sibling;
                     end if;
                  else
                     End_Node := Tree (Loop_Spec).Right_Child;
                  end if;
               end if;
            end if;
            Var_Name := To_Unbounded_String (Raw_Lexeme (N.Token_Index));
            Var_Safe := To_Unbounded_String (Qualified_Name (To_String (Var_Name)));
            if not Local_Seen (To_String (Var_Safe)) then
               Remember_Local (To_String (Var_Safe));
            end if;
            Step_Expr := To_Unbounded_String
              ((if Step_Node > 0 then "alb_to_i64(" & Expr (Step_Node) & ")" else "1"));
            Buffer_Line (Kind, Level, "for (" &
              "int64_t " & To_String (Var_Safe) & " = alb_to_i64(" & Expr (Start_Node) & "); " &
              "(" & To_String (Step_Expr) & " >= 0 ? " & To_String (Var_Safe) & " <= alb_to_i64(" & Expr (End_Node) & ") : " &
              To_String (Var_Safe) & " >= alb_to_i64(" & Expr (End_Node) & ")); " &
              To_String (Var_Safe) & " += " & To_String (Step_Expr) & ") {");
            Emit_Block (N.Right_Child, Kind, Level + 1);
            Buffer_Line (Kind, Level, "}");

         when AST_Foreach_Stmt =>
            Buffer_Line (Kind, Level, "{");
            Buffer_Line (Kind, Level + 1, "godot::Array alb_foreach_seq = alb_to_array(" & Expr (N.Left_Child) & ");");
            Buffer_Line (Kind, Level + 1, "for (int64_t alb_ix = 1; alb_ix <= alb_foreach_seq.size(); ++alb_ix) {");
            Var_Name := To_Unbounded_String (Qualified_Name (Raw_Lexeme (N.Token_Index)));
            Remember_Local (To_String (Var_Name));
            Buffer_Line (Kind, Level + 2, "godot::Variant " & To_String (Var_Name) & " = alb_index(alb_foreach_seq, godot::Variant(alb_ix));");
            Emit_Block (N.Right_Child, Kind, Level + 2);
            Buffer_Line (Kind, Level + 1, "}");
            Buffer_Line (Kind, Level, "}");

         when AST_Break_Stmt =>
            Buffer_Line (Kind, Level, "break;");

         when AST_Continue_Stmt =>
            Buffer_Line (Kind, Level, "continue;");

         when AST_Select_Stmt | AST_Match_Stmt =>
            Emit_Select (Node, Kind, Level);

         when AST_Create_Window =>
            Buffer_Line (Kind, Level, "alb_create_window(" &
              Expr (N.Left_Child) & ", " &
              Expr (Tree (N.Right_Child).Left_Child) & ", " &
              Expr (Tree (N.Right_Child).Right_Child) & ");");

         when AST_Set_Fullscreen =>
            Buffer_Line (Kind, Level, "alb_set_fullscreen(" & Expr (N.Left_Child) & ");");

         when AST_Set_Resizable =>
            Buffer_Line (Kind, Level, "alb_set_resizable(" & Expr (N.Left_Child) & ");");

         when AST_Set_Stretchy =>
            Buffer_Line (Kind, Level, "alb_set_stretchy(" & Expr (N.Left_Child) & ");");

         when AST_Tick =>
            Buffer_Line (Kind, Level, "g_frame_interval = alb_to_i64(" & Expr (N.Left_Child) & ");");

         when AST_Color =>
            Buffer_Line (Kind, Level, "alb_color(" & Expr (N.Left_Child) & ");");

         when AST_Clear =>
            Buffer_Line (Kind, Level, "alb_clear(" & Expr (N.Left_Child) & ");");

         when AST_Draw | AST_Fill | AST_Plot | AST_Text =>
            Emit_Draw_Stmt (Node, Kind, Level);

         when AST_Listen =>
            Buffer_Line (Kind, Level, "/* LISTEN is owned by Godot's main loop */");

         when AST_Cease =>
            Buffer_Line (Kind, Level, "alb_cease();");

         when AST_Delay_Stmt =>
            Buffer_Line (Kind, Level, "alb_delay(" & Expr (N.Left_Child) & ");");

         when AST_Load_Stmt =>
            Emit_Assignment_Text
              (N.Right_Child,
               Load_Helper_For_Target (N.Right_Child, Expr (N.Left_Child)),
               Kind,
               Level);

         when AST_Flush_Stmt =>
            Buffer_Line (Kind, Level, "alb_flush_buffer(" & Expr (N.Left_Child) & ", " &
              Expr (N.Right_Child) & ");");

         when AST_File_Open =>
            Buffer_Line (Kind, Level, "alb_file_open(" & Expr (N.Left_Child) & ", " & Expr (N.Right_Child) & ");");

         when AST_File_Read =>
            Buffer_Line (Kind, Level, "alb_file_read(" & Expr (N.Left_Child) & ", " & Expr (N.Right_Child) & ");");

         when AST_File_Write =>
            Buffer_Line (Kind, Level, "alb_file_write(" & Expr (N.Left_Child) & ", " & Expr (N.Right_Child) & ");");

         when AST_File_Close =>
            Buffer_Line (Kind, Level, "alb_file_close(" & Expr (N.Left_Child) & ");");

         when AST_Save_State =>
            Buffer_Line (Kind, Level, "alb_save_state();");

         when AST_Load_State =>
            Buffer_Line (Kind, Level, "alb_load_state();");

         when AST_Advance_Stmt =>
            declare
               Count_Expr : constant String :=
                 (if N.Left_Child > 0 then Expr (N.Left_Child) else "godot::Variant((int64_t)1)");
               Have_Temporal : Boolean := False;
            begin
               for I in 1 .. Global_Count loop
                  if Globals (I).Kind = Global_Temporal then
                     Have_Temporal := True;
                     exit;
                  end if;
               end loop;
               if Have_Temporal then
                  Buffer_Line (Kind, Level, "for (int64_t __adv = 0; __adv < MAX<int64_t>(0, alb_to_i64(" & Count_Expr & ")); ++__adv) {");
                  for I in 1 .. Global_Count loop
                     if Globals (I).Kind = Global_Temporal then
                        declare
                           GName : constant String := To_String (Globals (I).Name);
                           Hist  : constant String := Trim_Image (Integer (Natural'Max (1, Globals (I).History_Size)));
                        begin
                           Buffer_Line (Kind, Level + 1, GName & "_head = (" & GName & "_head + 1) % " & Hist & ";");
                           Buffer_Line (Kind, Level + 1, GName & "_history[" & GName & "_head] = " & GName & ";");
                        end;
                     end if;
                  end loop;
                  Buffer_Line (Kind, Level, "}");
               else
                  Buffer_Line (Kind, Level, "alb_advance_time(" & Count_Expr & ");");
               end if;
            end;

         when AST_Reversible_Block | AST_Temporal_Block | AST_Exact_Block |
              AST_Symbolic_Block | AST_Fallback_Block | AST_Atomic_Block |
              AST_Comptime_Block =>
            Emit_Block (N.Left_Child, Kind, Level);

         when AST_Rev_Add_Stmt =>
            Emit_Assignment_Text
              (N.Left_Child,
               "godot::Variant(alb_to_i64(" & Expr (N.Left_Child) & ") + alb_to_i64(" & Expr (N.Right_Child) & "))",
               Kind,
               Level,
               False);

         when AST_Rev_Sub_Stmt =>
            Emit_Assignment_Text
              (N.Left_Child,
               "godot::Variant(alb_to_i64(" & Expr (N.Left_Child) & ") - alb_to_i64(" & Expr (N.Right_Child) & "))",
               Kind,
               Level,
               False);

         when AST_Rev_Xor_Stmt =>
            Emit_Assignment_Text
              (N.Left_Child,
               "godot::Variant(alb_to_i64(" & Expr (N.Left_Child) & ") ^ alb_to_i64(" & Expr (N.Right_Child) & "))",
               Kind,
               Level,
               False);

         when AST_Rev_Rol_Stmt =>
            Emit_Assignment_Text
              (N.Left_Child,
               "alb_rol64(" & Expr (N.Left_Child) & ", " & Expr (N.Right_Child) & ")",
               Kind,
               Level,
               False);

         when AST_Rev_Ror_Stmt =>
            Emit_Assignment_Text
              (N.Left_Child,
               "alb_ror64(" & Expr (N.Left_Child) & ", " & Expr (N.Right_Child) & ")",
               Kind,
               Level,
               False);

         when AST_Rev_Swap_Stmt =>
            Buffer_Line (Kind, Level, "{");
            Buffer_Line (Kind, Level + 1, "godot::Variant __alb_rev_tmp = " & Expr (N.Left_Child) & ";");
            Emit_Assignment_Text (N.Left_Child, Expr (N.Right_Child), Kind, Level + 1, False);
            Emit_Assignment_Text (N.Right_Child, "__alb_rev_tmp", Kind, Level + 1, False);
            Buffer_Line (Kind, Level, "}");

         when AST_Rev_Not_Stmt =>
            Emit_Assignment_Text
              (N.Left_Child,
               "godot::Variant(~alb_to_i64(" & Expr (N.Left_Child) & "))",
               Kind,
               Level,
               False);

         when AST_Rev_Neg_Stmt =>
            Emit_Assignment_Text
              (N.Left_Child,
               "godot::Variant(-alb_to_i64(" & Expr (N.Left_Child) & "))",
               Kind,
               Level,
               False);

         when AST_Branchless_Predicate_Block =>
            Buffer_Line (Kind, Level, "if (alb_to_bool(" & Expr (N.Left_Child) & ")) {");
            Emit_Block (N.Right_Child, Kind, Level + 1);
            Buffer_Line (Kind, Level, "}");

         when AST_Ratio_Space_Block | AST_Stride_Block | AST_Morton_Tile_Block |
              AST_Export_PPM_Block | AST_Fits_Cube_Block | AST_Ini_Bind_Block |
              AST_Stream_Bypass_Block | AST_Synth_Bake_Block | AST_Mount_Archive_Block =>
            if N.Right_Child > 0 then
               Emit_Block (N.Right_Child, Kind, Level);
            end if;

         when AST_SwapPop_Stmt =>
            declare
               Slot_Node  : Node_Index := 0;
               Group_Name : Unbounded_String := To_Unbounded_String ("");
            begin
               if N.Left_Child > 0 then
                  if Tree (N.Left_Child).Kind = AST_Array_Access then
                     Slot_Node := Tree (N.Left_Child).Left_Child;
                     Group_Name := To_Unbounded_String (Raw_Lexeme (Tree (N.Left_Child).Token_Index));
                  elsif Tree (N.Left_Child).Left_Child > 0 and then Tree (N.Left_Child).Token_Index > 0 then
                     Slot_Node := Tree (N.Left_Child).Left_Child;
                     Group_Name := To_Unbounded_String (Raw_Lexeme (Tree (N.Left_Child).Token_Index));
                  end if;
               end if;

               if Slot_Node > 0 and then Length (Group_Name) > 0 then
                  Buffer_Line
                    (Kind,
                     Level,
                     "alb_swapnpop(" &
                     Safe_CPP_Name (To_String (Group_Name)) & ", " &
                     Expr (Slot_Node) & ", " &
                     Expr (N.Right_Child) & ");");
               else
                  Add_Warning (Node, "SWAPNPOP requires array slot target for Godot backend",
                               Emitter_Unsupported_Statement_Node);
               end if;
            end;

         when AST_Predict_Markov_Stmt =>
            if N.Right_Child > 0 and then Tree (N.Right_Child).Next_Sibling > 0 then
               Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, False);
               Emit_Firewall_Touch (N.Right_Child, Kind, Level, True, False);
               Emit_Assignment_Text
                 (Tree (N.Right_Child).Next_Sibling,
                  "godot::Variant((int64_t)alb_markov_predict(" & Expr (N.Left_Child) & ", " & Expr (N.Right_Child) & "))",
                  Kind,
                  Level,
                  False);
            else
               Buffer_Line (Kind, Level, "(void)alb_markov_predict(" & Expr (N.Left_Child) & ", " & Expr (N.Right_Child) & ");");
            end if;

         when AST_Infer_Network_Stmt =>
            if N.Right_Child > 0 and then Tree (N.Right_Child).Next_Sibling > 0 then
               declare
                  Target : constant Node_Index := Tree (N.Right_Child).Next_Sibling;
               begin
                  Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, True);
                  Emit_Firewall_Touch (N.Right_Child, Kind, Level, True, False);
                  Emit_Firewall_Touch (Target, Kind, Level, False, True);
                  Buffer_Line (Kind, Level, "alb_nn_infer(" & Assignment_Target_Name (N.Left_Child) & ", " &
                    Expr (N.Right_Child) & ", " & Assignment_Target_Name (Target) & ");");
               end;
            end if;

         when AST_Train_Network_Stmt =>
            declare
               Train_Node  : constant Node_Index := N.Right_Child;
               Expect_Node : constant Node_Index := (if Train_Node > 0 then Tree (Train_Node).Next_Sibling else 0);
               Epoch_Node  : constant Node_Index := (if Expect_Node > 0 then Tree (Expect_Node).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, True);
               Emit_Firewall_Touch (Train_Node, Kind, Level, True, False);
               Emit_Firewall_Touch (Expect_Node, Kind, Level, True, False);
               Buffer_Line (Kind, Level, "alb_nn_train(" &
                 Assignment_Target_Name (N.Left_Child) & ", " &
                 Expr (Train_Node) & ", " & Expr (Expect_Node) & ", " &
                 (if Epoch_Node > 0 then Expr (Epoch_Node) else "godot::Variant((int64_t)1)") & ");");
            end;

         when AST_Network_Listen_Stmt =>
            Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, True);
            Buffer_Line (Kind, Level, "alb_network_listen(" & Assignment_Target_Name (N.Left_Child) & ");");

         when AST_Network_Accept_Stmt =>
            Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, True);
            Emit_Firewall_Touch (N.Right_Child, Kind, Level, False, True);
            if N.Right_Child > 0 then
               Emit_Assignment_Text
                 (N.Right_Child,
                  "alb_network_accept(" & Assignment_Target_Name (N.Left_Child) & ")",
                  Kind,
                  Level,
                  False);
            else
               Buffer_Line (Kind, Level, "(void)alb_network_accept(" & Assignment_Target_Name (N.Left_Child) & ");");
            end if;

         when AST_Network_Receive_Stmt =>
            Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, True);
            Emit_Firewall_Touch (N.Right_Child, Kind, Level, False, True);
            Buffer_Line (Kind, Level, "alb_network_receive(" & Assignment_Target_Name (N.Left_Child) & ", " & Assignment_Target_Name (N.Right_Child) & ");");

         when AST_Network_Send_Stmt =>
            Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, True);
            Emit_Firewall_Touch (N.Right_Child, Kind, Level, True, False);
            Buffer_Line (Kind, Level, "alb_network_send(" & Assignment_Target_Name (N.Left_Child) & ", " & Assignment_Target_Name (N.Right_Child) & ");");

         when AST_Network_Close_Stmt =>
            Emit_Firewall_Touch (N.Left_Child, Kind, Level, True, True);
            Buffer_Line (Kind, Level, "alb_network_close(" & Assignment_Target_Name (N.Left_Child) & ");");

         when AST_Play_Sound | AST_Play_Music | AST_Play_Music_From =>
            Buffer_Line (Kind, Level, "alb_audio_event(" & Expr (N.Left_Child) & ");");

         when AST_Assert_Stmt =>
            Buffer_Line
              (Kind,
               Level,
               "alb_rel_set(" & Predicate_Name_Expr (Node) & ", " &
               Predicate_Arg1_Expr (Node) & ", godot::Variant((int64_t)1));");

         when AST_Retract_Stmt =>
            Buffer_Line
              (Kind,
               Level,
               "alb_rel_retract(" & Predicate_Name_Expr (Node) & ", " &
               Predicate_Arg1_Expr (Node) & ");");

         when AST_Update_Stmt =>
            Buffer_Line
              (Kind,
               Level,
               "alb_rel_set(" & Predicate_Name_Expr (N.Left_Child) & ", " &
               Predicate_Arg1_Expr (N.Left_Child) & ", " &
               Expr (N.Right_Child) & ");");

         when AST_Findall_Query =>
            Buffer_Line
              (Kind,
               Level,
               "alb_rel_findall1(" & Predicate_Name_Expr (N.Left_Child) & ", " &
               Assignment_Target_Name (N.Right_Child) & ");");

         when AST_Runtime_Assert =>
            Buffer_Line (Kind, Level, "alb_runtime_assert(alb_to_bool(" & Expr (N.Left_Child) & "));");

         when AST_Enable_Asm | AST_Disable_Asm | AST_Asm_Block |
              AST_Enable_Ada_Block | AST_Inline_Ada_Expr |
              AST_Enable_Java_Block | AST_Inline_Java_Expr |
              AST_Enable_Typescript_Block | AST_Inline_Typescript_Expr |
              AST_Enable_C_Block | AST_Inline_C_Expr |
              AST_Enable_CSharp_Block | AST_Inline_CSharp_Expr |
              AST_Enable_Python_Block | AST_Inline_Python_Expr |
              AST_Enable_Lua54_Block | AST_Inline_Lua_Expr |
              AST_Enable_Ruby_Block | AST_Inline_Ruby_Expr |
              AST_Enable_Javascript_Block | AST_Inline_Javascript_Expr =>
            Buffer_Line (Kind, Level, "/* inline host-language block preserved for later Godot lowering */");

         when others =>
            Add_Warning (Node, "unsupported statement node " & Node_Kind'Image (N.Kind),
                         Emitter_Unsupported_Statement_Node);
            Buffer_Line (Kind, Level, "/* unsupported statement: " & Node_Kind'Image (N.Kind) & " */");
      end case;
   end Emit_Statement;

   procedure Emit_Block
     (Block_Node : in Node_Index;
      Kind       : in Buffer_Kind;
      Level      : in Natural)
   is
      Curr : Node_Index := 0;
   begin
      if Block_Node = 0 then
         return;
      end if;

      if Tree (Block_Node).Kind = AST_Block_Stmt then
         Curr := Tree (Block_Node).Left_Child;
      else
         Curr := Block_Node;
      end if;

      while Curr > 0 loop
         Emit_Statement (Curr, Kind, Level);
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Block;

   procedure Remember_Event_Block
     (Node : in Node_Index)
   is
      Event_Kind : Token_Kind := Tok_Error;
   begin
      if Node = 0 or else Tree (Node).Token_Index = 0 then
         return;
      end if;

      Event_Kind := Tokens (Tree (Node).Token_Index).Kind;
      case Event_Kind is
         when Tok_Tick =>
            if Tick_Count < Max_Blocks then
               Tick_Count := Tick_Count + 1;
               Tick_Blocks (Tick_Count) := Tree (Node).Left_Child;
            end if;
         when Tok_Paint =>
            if Paint_Count < Max_Blocks then
               Paint_Count := Paint_Count + 1;
               Paint_Blocks (Paint_Count) := Tree (Node).Left_Child;
            end if;
         when Tok_Key =>
            if Key_Count < Max_Blocks then
               Key_Count := Key_Count + 1;
               Key_Blocks (Key_Count) := Tree (Node).Left_Child;
            end if;
         when others =>
            Add_Warning (Node, "unsupported ON event for Godot backend");
      end case;
   end Remember_Event_Block;

   procedure Register_Struct_Function
     (Node          : in Node_Index;
      Module_Prefix : in String)
   is
      Struct_Name_Node : constant Node_Index := Tree (Node).Left_Child;
      Struct_Name_Raw  : constant String := Raw_Lexeme (Tree (Struct_Name_Node).Token_Index);
      Maker_Name       : constant String := "alb_make_struct_" &
        Safe_CPP_Name ((if Module_Prefix'Length > 0 then Module_Prefix & "_" else "") & Struct_Name_Raw);
      Curr             : Node_Index := Tree (Node).Right_Child;
      Saved_Module     : constant Unbounded_String := Current_Module;
   begin
      Buffer_Line (Buf_Structs, 0, "static godot::Dictionary " & Maker_Name & "() {");
      Buffer_Line (Buf_Structs, 1, "godot::Dictionary d;");
      while Curr > 0 loop
         if Tree (Curr).Kind in AST_Struct_Field | AST_Parallel_Field then
            declare
               Field_Node : constant Node_Index := Tree (Curr).Left_Child;
               Field_Name : constant String := Raw_Lexeme (Tree (Field_Node).Token_Index);
            begin
               Buffer_Line
                 (Buf_Structs,
                  1,
                  "d[" & To_Godot_String (Field_Name) & "] = " & Node_Default_Value & ";");
            end;
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
      Buffer_Line (Buf_Structs, 1, "return d;");
      Buffer_Line (Buf_Structs, 0, "}");
      Buffer_Line (Buf_Structs, 0, "");
      Current_Module := Saved_Module;
   end Register_Struct_Function;

   procedure Scan_Top_Level
     (First         : in Node_Index;
      Module_Prefix : in String := "")
   is
      Curr         : Node_Index := First;
      Saved_Module : constant Unbounded_String := Current_Module;
      Module_Name  : Unbounded_String := To_Unbounded_String ("");
   begin
      if Module_Prefix'Length > 0 then
         Current_Module := To_Unbounded_String (Safe_CPP_Name (Module_Prefix));
      end if;

      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Module =>
               if Tree (Curr).Left_Child > 0 then
                  Module_Name := To_Unbounded_String (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                  if Module_Prefix'Length > 0 then
                     Remember_Module (Module_Prefix & "_" & To_String (Module_Name));
                     Scan_Top_Level (Tree (Tree (Curr).Right_Child).Left_Child, Module_Prefix & "_" & To_String (Module_Name));
                  else
                     Remember_Module (To_String (Module_Name));
                     Scan_Top_Level (Tree (Tree (Curr).Right_Child).Left_Child, To_String (Module_Name));
                  end if;
               end if;

            when AST_Struct_Decl =>
               if Tree (Curr).Left_Child > 0 then
                  if Module_Prefix'Length > 0 then
                     Remember_Struct (Module_Prefix & "_" & Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                  else
                     Remember_Struct (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                  end if;
               end if;

            when AST_Block_Stmt =>
               if Begin_Count < Max_Blocks then
                  Begin_Count := Begin_Count + 1;
                  Begin_Blocks (Begin_Count) := Curr;
               end if;

            when AST_On_Block =>
               Remember_Event_Block (Curr);

            when others =>
               null;
         end case;

         Curr := Tree (Curr).Next_Sibling;
      end loop;

      Current_Module := Saved_Module;
   end Scan_Top_Level;

   function Global_Decl_Name
     (Node          : in Node_Index;
      Module_Prefix : in String) return String
   is
      Raw_Name : constant String :=
        (if Tree (Node).Left_Child > 0 and then Tree (Tree (Node).Left_Child).Token_Index > 0
         then Raw_Lexeme (Tree (Tree (Node).Left_Child).Token_Index)
         elsif Tree (Node).Token_Index > 0
         then Raw_Lexeme (Tree (Node).Token_Index)
         else "alb_global");
   begin
      if Module_Prefix'Length > 0 then
         return Safe_CPP_Name (Module_Prefix & "_" & Raw_Name);
      end if;
      return Safe_CPP_Name (Raw_Name);
   end Global_Decl_Name;

   procedure Emit_Global_Decl
     (Node          : in Node_Index;
      Module_Prefix : in String)
   is
      Name : constant String := Global_Decl_Name (Node, Module_Prefix);
      Curr : Node_Index := 0;
   begin
      case Tree (Node).Kind is
         when AST_Let_Stmt =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Variant " & Name & ";");
            Remember_Global (Name, Global_Variant);

         when AST_Const_Decl =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Variant " & Name & ";");

         when AST_String_Decl =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::String " & Name & ";");
            Remember_Global (Name, Global_String);

         when AST_Strict_Stmt =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Array " & Name & ";");
            Remember_Global (Name, Global_Array);

         when AST_Slide_Stmt =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Array " & Name & ";");
            Buffer_Line (Buf_Global_Decls, 0, "static int64_t " & Name & "_active = 0;");
            Buffer_Line (Buf_Global_Decls, 0, "static int64_t " & Name & "_capacity = 0;");
            Remember_Global (Name, Global_Slide);

         when AST_Temporal_Decl =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Variant " & Name & ";");
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Array " & Name & "_history;");
            Buffer_Line (Buf_Global_Decls, 0, "static int64_t " & Name & "_head = 0;");
            Remember_Global (Name, Global_Temporal, Declared_History_Size (Node));

         when AST_Parallel_Decl =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Array " & Name & ";");
            Remember_Global (Name, Global_Array);

         when AST_Markov_Model_Decl | AST_Neural_Topology_Decl | AST_Network_Socket_Decl =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Dictionary " & Name & ";");
            Remember_Global (Name, Global_Dictionary);

         when AST_Memory_Firewall_Decl =>
            Buffer_Line (Buf_Global_Decls, 0, "static godot::Dictionary " & Name & ";");
            Remember_Global (Name, Global_Dictionary);

         when AST_Struct_Decl =>
            Register_Struct_Function (Node, Module_Prefix);

         when others =>
            null;
      end case;

      if Tree (Node).Kind = AST_Parallel_Decl then
         Curr := Tree (Node).Right_Child;
         while Curr > 0 loop
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;
   end Emit_Global_Decl;

   procedure Emit_Top_Level_Declarations
     (First         : in Node_Index;
      Module_Prefix : in String := "")
   is
      Curr        : Node_Index := First;
      Nested_Prefix : Unbounded_String := To_Unbounded_String ("");
      Decl_Node   : Node_Index := 0;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Module =>
               if Tree (Curr).Left_Child > 0 then
                  Nested_Prefix := To_Unbounded_String (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                  if Module_Prefix'Length > 0 then
                     Nested_Prefix := To_Unbounded_String (Module_Prefix & "_" & To_String (Nested_Prefix));
                  end if;
                  if Tree (Curr).Right_Child > 0 then
                     Emit_Top_Level_Declarations (Tree (Tree (Curr).Right_Child).Left_Child, To_String (Nested_Prefix));
                  end if;
               end if;

            when AST_Let_Stmt | AST_Const_Decl | AST_Strict_Stmt | AST_Slide_Stmt |
                 AST_Parallel_Decl | AST_String_Decl | AST_Temporal_Decl |
                 AST_Struct_Decl | AST_Markov_Model_Decl | AST_Neural_Topology_Decl |
                 AST_Network_Socket_Decl | AST_Memory_Firewall_Decl =>
               Emit_Global_Decl (Curr, Module_Prefix);

            when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar |
                 AST_Import_ES | AST_Import_WASM | AST_Export_DLL | AST_Export_SO |
                 AST_Export_Dylib | AST_Export_Jar | AST_Export_ES | AST_Export_WASM =>
               Decl_Node := Tree (Curr).Left_Child;
               if Decl_Node > 0 and then Tree (Decl_Node).Kind in AST_Procedure_Decl | AST_Function_Decl then
                  null;
               end if;

            when others =>
               null;
         end case;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Top_Level_Declarations;

   procedure Emit_Global_Init
     (Node          : in Node_Index;
      Module_Prefix : in String)
   is
      Name    : constant String := Global_Decl_Name (Node, Module_Prefix);
      Field_Curr : Node_Index := 0;
      Init_Var : Unbounded_String := To_Unbounded_String ("");
   begin
      case Tree (Node).Kind is
         when AST_Let_Stmt =>
            if Tree (Node).Right_Child > 0 then
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = " & Expr (Tree (Node).Right_Child) & ";");
            else
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = " & Node_Default_Value & ";");
            end if;

         when AST_Const_Decl =>
            if Tree (Node).Right_Child > 0 then
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = " & Expr (Tree (Node).Right_Child) & ";");
            else
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = " & Node_Default_Value & ";");
            end if;

         when AST_String_Decl =>
            Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = godot::String();");

         when AST_Strict_Stmt =>
            Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = alb_make_array(" & Expr (Tree (Node).Right_Child) & ");");

         when AST_Slide_Stmt =>
            Buffer_Line (Buf_Global_Bootstrap, 1, Name & "_capacity = alb_to_i64(" & Expr (Tree (Node).Right_Child) & ");");
            if Tree (Node).Right_Child > 0 and then Tree (Tree (Node).Right_Child).Next_Sibling > 0 then
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & "_active = alb_to_i64(" & Expr (Tree (Tree (Node).Right_Child).Next_Sibling) & ");");
            else
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & "_active = 0;");
            end if;
            Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = alb_make_array(godot::Variant(" & Name & "_capacity));");

         when AST_Temporal_Decl =>
            if Tree (Node).Right_Child > 0 and then Tree (Tree (Node).Right_Child).Next_Sibling > 0 then
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = " & Expr (Tree (Tree (Node).Right_Child).Next_Sibling) & ";");
            else
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & " = " & Node_Default_Value & ";");
            end if;
            if Tree (Node).Right_Child > 0 then
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & "_history = alb_make_array(" & Expr (Tree (Node).Right_Child) & ");");
               Buffer_Line (Buf_Global_Bootstrap, 1, "alb_fill_array(" & Name & "_history, " & Name & ");");
               Buffer_Line (Buf_Global_Bootstrap, 1, Name & "_head = 0;");
            end if;

         when AST_Parallel_Decl =>
            Field_Curr := Tree (Node).Right_Child;
            Init_Var := To_Unbounded_String (Name & "_fields");
            Buffer_Line (Buf_Global_Bootstrap, 1, "{");
            Buffer_Line (Buf_Global_Bootstrap, 2, "godot::Array " & To_String (Init_Var) & ";");
            while Field_Curr > 0 loop
               if Tree (Field_Curr).Left_Child > 0 then
                  Buffer_Line
                    (Buf_Global_Bootstrap,
                     2,
                     To_String (Init_Var) & ".append(" &
                     To_Godot_String (Raw_Lexeme (Tree (Tree (Field_Curr).Left_Child).Token_Index)) & ");");
               end if;
               Field_Curr := Tree (Field_Curr).Next_Sibling;
            end loop;
            Buffer_Line
              (Buf_Global_Bootstrap,
               2,
               Name & " = alb_make_parallel(" & Expr (Tree (Tree (Node).Left_Child).Left_Child) & ", " & To_String (Init_Var) & ");");
            Buffer_Line (Buf_Global_Bootstrap, 1, "}");

         when AST_Markov_Model_Decl =>
            declare
               Setting     : Node_Index := Tree (Node).Right_Child;
               States_Text : Unbounded_String := To_Unbounded_String ("0");
               Matrix_Node : Node_Index := 0;
               Row_Node    : Node_Index := 0;
               Elem_Node   : Node_Index := 0;
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Markov_States =>
                        States_Text := To_Unbounded_String (Expr (Tree (Setting).Left_Child));
                     when AST_Markov_Transition_Matrix =>
                        Matrix_Node := Tree (Setting).Left_Child;
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Buffer_Line (Buf_Global_Bootstrap, 1, "{");
               Buffer_Line (Buf_Global_Bootstrap, 2, "godot::Array " & Name & "_matrix;");
               Row_Node := Matrix_Node;
               while Row_Node > 0 loop
                  Elem_Node := Tree (Row_Node).Left_Child;
                  while Elem_Node > 0 loop
                     Buffer_Line (Buf_Global_Bootstrap, 2, Name & "_matrix.append(" & Expr (Elem_Node) & ");");
                     Elem_Node := Tree (Elem_Node).Next_Sibling;
                  end loop;
                  Row_Node := Tree (Row_Node).Next_Sibling;
               end loop;
               Buffer_Line (Buf_Global_Bootstrap, 2, Name & " = alb_make_markov_model(" & To_String (States_Text) & ", " & Name & "_matrix);");
               Buffer_Line (Buf_Global_Bootstrap, 1, "}");
            end;

         when AST_Neural_Topology_Decl =>
            declare
               Layer_Node : Node_Index := Tree (Node).Right_Child;
            begin
               Buffer_Line (Buf_Global_Bootstrap, 1, "{");
               Buffer_Line (Buf_Global_Bootstrap, 2, "godot::Array " & Name & "_sizes;");
               Buffer_Line (Buf_Global_Bootstrap, 2, "godot::Array " & Name & "_acts;");
               while Layer_Node > 0 loop
                  Buffer_Line (Buf_Global_Bootstrap, 2, Name & "_sizes.append(" & Expr (Tree (Layer_Node).Left_Child) & ");");
                  Buffer_Line
                    (Buf_Global_Bootstrap,
                     2,
                     Name & "_acts.append(godot::Variant((int64_t)" &
                     Activation_Code
                       ((if Tree (Layer_Node).Right_Child > 0
                         then Raw_Lexeme (Tree (Tree (Layer_Node).Right_Child).Token_Index)
                         else "")) &
                     "));");
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Buffer_Line (Buf_Global_Bootstrap, 2, Name & " = alb_make_neural_model(" & To_Godot_String (Name) & ", " & Name & "_sizes, " & Name & "_acts);");
               Buffer_Line (Buf_Global_Bootstrap, 1, "}");
            end;

         when AST_Network_Socket_Decl =>
            declare
               Setting       : Node_Index := Tree (Node).Right_Child;
               Protocol_Code : Unbounded_String := To_Unbounded_String ("1");
               Port_Val      : Unbounded_String := To_Unbounded_String ("0");
               Buffer_Val    : Unbounded_String := To_Unbounded_String ("64");
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Network_Protocol =>
                        Protocol_Code := To_Unbounded_String
                          (Network_Protocol_Code
                             ((if Tree (Setting).Left_Child > 0
                               then Raw_Lexeme (Tree (Tree (Setting).Left_Child).Token_Index)
                               else "")));
                     when AST_Network_Port =>
                        Port_Val := To_Unbounded_String (Expr (Tree (Setting).Left_Child));
                     when AST_Network_Buffer_Size =>
                        Buffer_Val := To_Unbounded_String (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;
               Buffer_Line
                 (Buf_Global_Bootstrap,
                  1,
                  Name & " = alb_make_network_socket(" &
                  To_String (Protocol_Code) & ", " &
                  To_String (Port_Val) & ", " &
                  To_String (Buffer_Val) & ");");
            end;

         when AST_Memory_Firewall_Decl =>
            declare
               Rule_Node    : Node_Index := Tree (Node).Right_Child;
               Read_Name    : constant String := Name & "_read";
               Write_Name   : constant String := Name & "_write";
               Deny_All     : Boolean := False;
            begin
               Buffer_Line (Buf_Global_Bootstrap, 1, "{");
               Buffer_Line (Buf_Global_Bootstrap, 2, "godot::Array " & Read_Name & ";");
               Buffer_Line (Buf_Global_Bootstrap, 2, "godot::Array " & Write_Name & ";");
               while Rule_Node > 0 loop
                  case Tree (Rule_Node).Kind is
                     when AST_Firewall_Permit_Read =>
                        declare
                           Key : constant String := Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              Buffer_Line (Buf_Global_Bootstrap, 2, Read_Name & ".append(" & To_Godot_String (Key) & ");");
                           end if;
                        end;

                     when AST_Firewall_Permit_Write =>
                        declare
                           Key : constant String := Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              Buffer_Line (Buf_Global_Bootstrap, 2, Write_Name & ".append(" & To_Godot_String (Key) & ");");
                           end if;
                        end;

                     when AST_Firewall_Deny_All =>
                        Deny_All := True;

                     when others =>
                        null;
                  end case;
                  Rule_Node := Tree (Rule_Node).Next_Sibling;
               end loop;
               Buffer_Line
                 (Buf_Global_Bootstrap,
                  2,
                  Name & " = alb_make_firewall(" & Read_Name & ", " & Write_Name & ", " &
                  (if Deny_All then "true" else "false") & ");");
               Buffer_Line (Buf_Global_Bootstrap, 1, "}");
            end;

         when AST_Struct_Decl =>
            null;

         when others =>
            null;
      end case;
   end Emit_Global_Init;

   procedure Emit_Top_Level_Initializers
     (First         : in Node_Index;
      Module_Prefix : in String := "")
   is
      Curr         : Node_Index := First;
      Nested_Prefix : Unbounded_String := To_Unbounded_String ("");
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Module =>
               if Tree (Curr).Left_Child > 0 then
                  Nested_Prefix := To_Unbounded_String (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                  if Module_Prefix'Length > 0 then
                     Nested_Prefix := To_Unbounded_String (Module_Prefix & "_" & To_String (Nested_Prefix));
                  end if;
                  if Tree (Curr).Right_Child > 0 then
                     Emit_Top_Level_Initializers (Tree (Tree (Curr).Right_Child).Left_Child, To_String (Nested_Prefix));
                  end if;
               end if;

            when AST_Let_Stmt | AST_Const_Decl | AST_Strict_Stmt | AST_Slide_Stmt |
                 AST_Parallel_Decl | AST_String_Decl | AST_Temporal_Decl |
                 AST_Markov_Model_Decl | AST_Neural_Topology_Decl |
                 AST_Network_Socket_Decl | AST_Memory_Firewall_Decl =>
               Emit_Global_Init (Curr, Module_Prefix);

            when others =>
               null;
         end case;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Top_Level_Initializers;

   procedure Emit_Routine_Def
     (Node          : in Node_Index;
      Module_Prefix : in String;
      Is_Import     : in Boolean := False)
   is
      Name_Node : constant Node_Index := Tree (Node).Left_Child;
      Body_Node : constant Node_Index := Tree (Node).Right_Child;
      Raw_Name  : constant String :=
        (if Name_Node > 0 then Raw_Lexeme (Tree (Name_Node).Token_Index) else "alb_proc");
      Full_Name : constant String :=
        (if Module_Prefix'Length > 0 then Safe_CPP_Name (Module_Prefix & "_" & Raw_Name)
         else Safe_CPP_Name (Raw_Name));
      Saved_Module : constant Unbounded_String := Current_Module;
      Saved_Routine : constant Unbounded_String := Current_Routine;
      Param_Curr : Node_Index := (if Name_Node > 0 then Tree (Name_Node).Left_Child else 0);
      Param_Text : Unbounded_String := To_Unbounded_String ("");
      First_Param : Boolean := True;
      Bound_Node : Node_Index := 0;
   begin
      Current_Routine := To_Unbounded_String (Full_Name);
      Reset_Locals;

      while Param_Curr > 0 loop
         if Tree (Param_Curr).Kind = AST_Param_Decl and then Tree (Param_Curr).Left_Child > 0 then
            declare
               Param_Name : constant String := Safe_CPP_Name (Raw_Lexeme (Tree (Tree (Param_Curr).Left_Child).Token_Index));
            begin
               if not First_Param then
                  Append (Param_Text, ", ");
               end if;
               Append (Param_Text, "godot::Variant " & Param_Name);
               Remember_Local (Param_Name);
               First_Param := False;
            end;
         elsif Tree (Param_Curr).Kind = AST_Bound_To_Clause then
            Bound_Node := Param_Curr;
         end if;
         Param_Curr := Tree (Param_Curr).Next_Sibling;
      end loop;

      if Tree (Node).Kind = AST_Function_Decl then
         Buffer_Line (Buf_Routines, 0, "static godot::Variant " & Full_Name & "(" & To_String (Param_Text) & ") {");
      else
         Buffer_Line (Buf_Routines, 0, "static void " & Full_Name & "(" & To_String (Param_Text) & ") {");
      end if;

      if Is_Import then
         Buffer_Line (Buf_Routines, 1, "/* imported foreign binding placeholder */");
         if Tree (Node).Kind = AST_Function_Decl then
            Buffer_Line (Buf_Routines, 1, "return godot::Variant();");
         end if;
      else
         if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
            Buffer_Line (Buf_Routines, 1, "AlbFirewallScope __alb_fw_scope(" & Expr (Tree (Bound_Node).Left_Child) & ");");
         end if;
         if Body_Node > 0 then
            Emit_Block (Body_Node, Buf_Routines, 1);
         end if;
         if Tree (Node).Kind = AST_Function_Decl then
            Buffer_Line (Buf_Routines, 1, "return godot::Variant();");
         end if;
      end if;

      Buffer_Line (Buf_Routines, 0, "}");
      Buffer_Line (Buf_Routines, 0, "");

      Current_Module := Saved_Module;
      Current_Routine := Saved_Routine;
   end Emit_Routine_Def;

   procedure Emit_Top_Level_Routines
     (First         : in Node_Index;
      Module_Prefix : in String := "")
   is
      Curr          : Node_Index := First;
      Nested_Prefix : Unbounded_String := To_Unbounded_String ("");
      Decl_Node     : Node_Index := 0;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Module =>
               if Tree (Curr).Left_Child > 0 then
                  Nested_Prefix := To_Unbounded_String (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index));
                  if Module_Prefix'Length > 0 then
                     Nested_Prefix := To_Unbounded_String (Module_Prefix & "_" & To_String (Nested_Prefix));
                  end if;
                  if Tree (Curr).Right_Child > 0 then
                     Emit_Top_Level_Routines (Tree (Tree (Curr).Right_Child).Left_Child, To_String (Nested_Prefix));
                  end if;
               end if;

            when AST_Procedure_Decl | AST_Function_Decl =>
               Emit_Routine_Def (Curr, Module_Prefix, False);

            when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar |
                 AST_Import_ES | AST_Import_WASM =>
               Decl_Node := Tree (Curr).Left_Child;
               if Decl_Node > 0 and then Tree (Decl_Node).Kind in AST_Procedure_Decl | AST_Function_Decl then
                  Emit_Routine_Def (Decl_Node, Module_Prefix, True);
               end if;

            when AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar |
                 AST_Export_ES | AST_Export_WASM =>
               Decl_Node := Tree (Curr).Left_Child;
               if Decl_Node > 0 and then Tree (Decl_Node).Kind in AST_Procedure_Decl | AST_Function_Decl then
                  Emit_Routine_Def (Decl_Node, Module_Prefix, False);
               end if;

            when others =>
               null;
         end case;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Top_Level_Routines;

   procedure Emit_Buffered_Block_List
     (Nodes  : in Node_List;
      Count  : in Natural;
      Kind   : in Buffer_Kind)
   is
   begin
      for I in 1 .. Count loop
         Emit_Block (Nodes (I), Kind, 1);
      end loop;
   end Emit_Buffered_Block_List;

   procedure Write_Text_File
     (Path    : in String;
      Content : in String)
   is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (File, Content);
      Ada.Text_IO.Close (File);
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         raise;
   end Write_Text_File;

   procedure Write_Runtime_Support is
      Src_Dir     : constant String := Ada.Directories.Compose (To_String (Output_Directory), "src");
      Header_Path : constant String := Ada.Directories.Compose (Src_Dir, "alb_runtime_support.hpp");
      Cpp_Path    : constant String := Ada.Directories.Compose (Src_Dir, "alb_runtime_support.cpp");
      Header_Text : Unbounded_String := To_Unbounded_String ("");
      Cpp_Text    : Unbounded_String := To_Unbounded_String ("");
   begin
      Append (Header_Text,
        "#pragma once" & ASCII.LF &
        "#include <godot_cpp/classes/canvas_item.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/file_access.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/font.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/input.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/image.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/texture2d.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/theme_db.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/viewport.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/window.hpp>" & ASCII.LF &
        "#include <godot_cpp/classes/engine.hpp>" & ASCII.LF &
        "#include <godot_cpp/variant/array.hpp>" & ASCII.LF &
        "#include <godot_cpp/variant/color.hpp>" & ASCII.LF &
        "#include <godot_cpp/variant/dictionary.hpp>" & ASCII.LF &
        "#include <godot_cpp/variant/packed_vector2_array.hpp>" & ASCII.LF &
        "#include <godot_cpp/variant/string.hpp>" & ASCII.LF &
        "#include <godot_cpp/variant/utility_functions.hpp>" & ASCII.LF &
        "#include <cstdint>" & ASCII.LF &
        "namespace alb_godot_support {" & ASCII.LF &
        "extern godot::CanvasItem *g_canvas;" & ASCII.LF &
        "extern bool g_should_cease;" & ASCII.LF &
        "extern int64_t g_frame_interval;" & ASCII.LF &
        "typedef godot::Dictionary (*AlbStateCaptureFn)();" & ASCII.LF &
        "typedef void (*AlbStateRestoreFn)(const godot::Dictionary &state);" & ASCII.LF &
        "class AlbFirewallScope { public: explicit AlbFirewallScope(const godot::Variant &fw); ~AlbFirewallScope(); };" & ASCII.LF &
        "int64_t alb_to_i64(const godot::Variant &v);" & ASCII.LF &
        "double alb_to_double(const godot::Variant &v);" & ASCII.LF &
        "bool alb_to_bool(const godot::Variant &v);" & ASCII.LF &
        "godot::String alb_to_string(const godot::Variant &v);" & ASCII.LF &
        "godot::Array alb_to_array(const godot::Variant &v);" & ASCII.LF &
        "godot::Variant alb_cat(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_add(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_sub(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_mul(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_div(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_mod(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_bitand(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_bitor(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_bitxor(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_rol64(const godot::Variant &value, const godot::Variant &count);" & ASCII.LF &
        "godot::Variant alb_ror64(const godot::Variant &value, const godot::Variant &count);" & ASCII.LF &
        "bool alb_eq(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "bool alb_lt(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "bool alb_gt(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "bool alb_lte(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "bool alb_gte(const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_unsupported_value(const godot::String &what);" & ASCII.LF &
        "godot::Variant alb_fallback_binop(const godot::String &op, const godot::Variant &a, const godot::Variant &b);" & ASCII.LF &
        "godot::Variant alb_parse_binary(const godot::String &s);" & ASCII.LF &
        "godot::Variant alb_parse_octal(const godot::String &s);" & ASCII.LF &
        "godot::Array alb_make_array(const godot::Variant &count);" & ASCII.LF &
        "void alb_fill_array(godot::Array &arr, const godot::Variant &value);" & ASCII.LF &
        "godot::Variant alb_index(const godot::Array &arr, const godot::Variant &idx);" & ASCII.LF &
        "void alb_set_index(godot::Array &arr, const godot::Variant &idx, const godot::Variant &value);" & ASCII.LF &
        "godot::Variant alb_get_member(const godot::Variant &base, const godot::String &field);" & ASCII.LF &
        "void alb_set_member(godot::Variant &base, const godot::String &field, const godot::Variant &value);" & ASCII.LF &
        "godot::Variant alb_get_member_index(const godot::Array &arr, const godot::Variant &idx, const godot::String &field);" & ASCII.LF &
        "void alb_set_member_index(godot::Array &arr, const godot::Variant &idx, const godot::String &field, const godot::Variant &value);" & ASCII.LF &
        "godot::Array alb_make_parallel(const godot::Variant &count, const godot::Array &fields);" & ASCII.LF &
        "godot::Dictionary alb_make_firewall(const godot::Array &read, const godot::Array &write, bool deny_all);" & ASCII.LF &
        "void alb_firewall_enter(const godot::Variant &fw);" & ASCII.LF &
        "void alb_firewall_leave();" & ASCII.LF &
        "void alb_firewall_touch_read(const godot::String &name);" & ASCII.LF &
        "void alb_firewall_touch_write(const godot::String &name);" & ASCII.LF &
        "godot::Variant alb_firewall_read(const godot::String &name, const godot::Variant &value);" & ASCII.LF &
        "godot::Variant alb_firewall_write(const godot::String &name, const godot::Variant &value);" & ASCII.LF &
        "godot::Dictionary alb_make_markov_model(const godot::Variant &states, const godot::Array &matrix);" & ASCII.LF &
        "int64_t alb_markov_predict(const godot::Dictionary &model, const godot::Variant &current_state);" & ASCII.LF &
        "godot::Dictionary alb_make_neural_model(const godot::String &name, const godot::Array &sizes, const godot::Array &acts);" & ASCII.LF &
        "godot::Dictionary alb_make_network_socket(const godot::Variant &protocol, const godot::Variant &port, const godot::Variant &buffer_size);" & ASCII.LF &
        "void alb_rel_set(const godot::String &pred, const godot::Variant &arg1, const godot::Variant &value);" & ASCII.LF &
        "void alb_rel_retract(const godot::String &pred, const godot::Variant &arg1);" & ASCII.LF &
        "int64_t alb_rel_has(const godot::String &pred, const godot::Variant &arg1);" & ASCII.LF &
        "int64_t alb_rel_count(const godot::String &pred);" & ASCII.LF &
        "godot::Variant alb_rel_find1(const godot::String &pred);" & ASCII.LF &
        "int64_t alb_rel_findall1(const godot::String &pred, godot::Array &target);" & ASCII.LF &
        "void alb_print(const godot::Variant &value);" & ASCII.LF &
        "void alb_runtime_assert(bool cond);" & ASCII.LF &
        "void alb_create_window(const godot::Variant &title, const godot::Variant &w, const godot::Variant &h);" & ASCII.LF &
        "void alb_set_fullscreen(const godot::Variant &v);" & ASCII.LF &
        "void alb_set_resizable(const godot::Variant &v);" & ASCII.LF &
        "void alb_set_stretchy(const godot::Variant &v);" & ASCII.LF &
        "void alb_color(const godot::Variant &v);" & ASCII.LF &
        "void alb_clear(const godot::Variant &v);" & ASCII.LF &
        "void alb_draw_rect(const godot::Variant &x, const godot::Variant &y, const godot::Variant &w, const godot::Variant &h);" & ASCII.LF &
        "void alb_fill_rect(const godot::Variant &x, const godot::Variant &y, const godot::Variant &w, const godot::Variant &h);" & ASCII.LF &
        "void alb_draw_line(const godot::Variant &x1, const godot::Variant &y1, const godot::Variant &x2, const godot::Variant &y2);" & ASCII.LF &
        "void alb_draw_circle(const godot::Variant &x, const godot::Variant &y, const godot::Variant &r);" & ASCII.LF &
        "void alb_fill_circle(const godot::Variant &x, const godot::Variant &y, const godot::Variant &r);" & ASCII.LF &
        "void alb_draw_triangle(const godot::Variant &x1, const godot::Variant &y1, const godot::Variant &x2, const godot::Variant &y2, const godot::Variant &x3, const godot::Variant &y3);" & ASCII.LF &
        "void alb_fill_triangle(const godot::Variant &x1, const godot::Variant &y1, const godot::Variant &x2, const godot::Variant &y2, const godot::Variant &x3, const godot::Variant &y3);" & ASCII.LF &
        "void alb_plot(const godot::Variant &x, const godot::Variant &y);" & ASCII.LF &
        "void alb_draw_text(const godot::Variant &x, const godot::Variant &y, const godot::String &text);" & ASCII.LF &
        "int64_t alb_key(const godot::Variant &key);" & ASCII.LF &
        "int64_t alb_mouse_x();" & ASCII.LF &
        "int64_t alb_mouse_y();" & ASCII.LF &
        "int64_t alb_vmouse_x();" & ASCII.LF &
        "int64_t alb_vmouse_y();" & ASCII.LF &
        "int64_t alb_mouse_click(const godot::Variant &button);" & ASCII.LF &
        "int64_t alb_screen_width();" & ASCII.LF &
        "int64_t alb_screen_height();" & ASCII.LF &
        "int64_t alb_virtual_width();" & ASCII.LF &
        "int64_t alb_virtual_height();" & ASCII.LF &
        "godot::Variant alb_rnd(const godot::Variant &limit);" & ASCII.LF &
        "godot::Variant alb_read_pixel(const godot::Variant &x, const godot::Variant &y);" & ASCII.LF &
        "godot::Variant alb_temporal_ref(const godot::Variant &base, const godot::String &selector);" & ASCII.LF &
        "void alb_register_state_hooks(AlbStateCaptureFn capture, AlbStateRestoreFn restore);" & ASCII.LF &
        "void alb_save_state();" & ASCII.LF &
        "void alb_load_state();" & ASCII.LF &
        "void alb_advance_time(const godot::Variant &n);" & ASCII.LF &
        "void alb_delay(const godot::Variant &n);" & ASCII.LF &
        "void alb_flush_buffer(const godot::Variant &buffer, const godot::Variant &path);" & ASCII.LF &
        "godot::Array alb_load_buffer(const godot::Variant &path);" & ASCII.LF &
        "godot::String alb_load_text(const godot::Variant &path);" & ASCII.LF &
        "godot::Variant alb_load_value(const godot::Variant &path);" & ASCII.LF &
        "void alb_file_open(const godot::Variant &path, const godot::Variant &mode);" & ASCII.LF &
        "void alb_file_read(const godot::Variant &handle, const godot::Variant &bytes);" & ASCII.LF &
        "void alb_file_write(const godot::Variant &handle, const godot::Variant &data);" & ASCII.LF &
        "void alb_file_close(const godot::Variant &handle);" & ASCII.LF &
        "void alb_network_listen(godot::Dictionary &socket);" & ASCII.LF &
        "godot::Dictionary alb_network_accept(godot::Dictionary &socket);" & ASCII.LF &
        "void alb_network_receive(godot::Dictionary &socket, godot::Array &buffer);" & ASCII.LF &
        "void alb_network_send(godot::Dictionary &socket, const godot::Array &buffer);" & ASCII.LF &
        "void alb_network_close(godot::Dictionary &socket);" & ASCII.LF &
        "void alb_nn_train(godot::Dictionary &model, const godot::Variant &input, const godot::Variant &expected, const godot::Variant &epochs);" & ASCII.LF &
        "void alb_nn_infer(godot::Dictionary &model, const godot::Variant &input, godot::Array &output);" & ASCII.LF &
        "void alb_audio_event(const godot::Variant &payload);" & ASCII.LF &
        "void alb_cease();" & ASCII.LF &
        "void alb_swapnpop(godot::Array &target, const godot::Variant &slot, const godot::Variant &live_count);" & ASCII.LF &
        "} // namespace alb_godot_support" & ASCII.LF);

      Append (Cpp_Text,
        "#include ""alb_runtime_support.hpp""" & ASCII.LF &
        "#include <godot_cpp/classes/display_server.hpp>" & ASCII.LF &
        "using namespace godot;" & ASCII.LF &
        "namespace alb_godot_support {" & ASCII.LF &
        "CanvasItem *g_canvas = nullptr;" & ASCII.LF &
        "bool g_should_cease = false;" & ASCII.LF &
        "int64_t g_frame_interval = 16;" & ASCII.LF &
        "static int64_t g_temporal_tick = 0;" & ASCII.LF &
        "static uint64_t g_rng = 0xC0DEFACE12345678ULL;" & ASCII.LF &
        "static Color g_color = Color(1.0, 1.0, 1.0, 1.0);" & ASCII.LF &
        "static int64_t g_virtual_width = 960;" & ASCII.LF &
        "static int64_t g_virtual_height = 540;" & ASCII.LF &
        "static String g_window_title = String(""ALBGD"");" & ASCII.LF &
        "static bool g_window_resizable = true;" & ASCII.LF &
        "static bool g_window_stretchy = false;" & ASCII.LF &
        "static Dictionary g_saved_state;" & ASCII.LF &
        "static AlbStateCaptureFn g_capture_state = nullptr;" & ASCII.LF &
        "static AlbStateRestoreFn g_restore_state = nullptr;" & ASCII.LF &
        "static int64_t g_next_file_handle = 1;" & ASCII.LF &
        "static Dictionary g_open_files;" & ASCII.LF &
        "static Array g_firewall_stack;" & ASCII.LF &
        "static Dictionary g_network_bus;" & ASCII.LF &
        "static Dictionary g_rel_store;" & ASCII.LF &
        "static Window *alb_window() { return g_canvas ? g_canvas->get_window() : nullptr; }" & ASCII.LF &
        "static void alb_apply_window_config() { Window *w = alb_window(); if (!w) return; w->set_title(g_window_title); if (g_virtual_width > 0 && g_virtual_height > 0) { w->set_size(Size2i((int)g_virtual_width, (int)g_virtual_height)); w->set_content_scale_size(Size2i((int)g_virtual_width, (int)g_virtual_height)); } w->set_flag(Window::FLAG_RESIZE_DISABLED, !g_window_resizable); w->set_content_scale_mode(g_window_stretchy ? Window::CONTENT_SCALE_MODE_CANVAS_ITEMS : Window::CONTENT_SCALE_MODE_DISABLED); w->set_content_scale_aspect(g_window_stretchy ? Window::CONTENT_SCALE_ASPECT_KEEP : Window::CONTENT_SCALE_ASPECT_IGNORE); w->set_content_scale_stretch(Window::CONTENT_SCALE_STRETCH_FRACTIONAL); }" & ASCII.LF &
        "static Ref<FileAccess> alb_lookup_file(const Variant &handle) { if (g_open_files.has(handle)) return g_open_files[handle]; String key = alb_to_string(handle); if (g_open_files.has(key)) return g_open_files[key]; if (g_open_files.has(String(""last""))) return g_open_files[String(""last"")]; return Ref<FileAccess>(); }" & ASCII.LF &
        "int64_t alb_to_i64(const Variant &v) { return (int64_t)v; }" & ASCII.LF &
        "double alb_to_double(const Variant &v) { return (double)v; }" & ASCII.LF &
        "bool alb_to_bool(const Variant &v) { return (bool)v; }" & ASCII.LF &
        "String alb_to_string(const Variant &v) { return v.stringify(); }" & ASCII.LF &
        "Array alb_to_array(const Variant &v) { return v.get_type() == Variant::ARRAY ? (Array)v : Array(); }" & ASCII.LF &
        "Variant alb_cat(const Variant &a, const Variant &b) { return alb_to_string(a) + alb_to_string(b); }" & ASCII.LF &
        "Variant alb_add(const Variant &a, const Variant &b) { return Variant(alb_to_double(a) + alb_to_double(b)); }" & ASCII.LF &
        "Variant alb_sub(const Variant &a, const Variant &b) { return Variant(alb_to_double(a) - alb_to_double(b)); }" & ASCII.LF &
        "Variant alb_mul(const Variant &a, const Variant &b) { return Variant(alb_to_double(a) * alb_to_double(b)); }" & ASCII.LF &
        "Variant alb_div(const Variant &a, const Variant &b) { double d = alb_to_double(b); return Variant(d == 0.0 ? 0.0 : alb_to_double(a) / d); }" & ASCII.LF &
        "Variant alb_mod(const Variant &a, const Variant &b) { int64_t d = alb_to_i64(b); return Variant(d == 0 ? (int64_t)0 : (alb_to_i64(a) % d)); }" & ASCII.LF &
        "Variant alb_bitand(const Variant &a, const Variant &b) { return Variant(alb_to_i64(a) & alb_to_i64(b)); }" & ASCII.LF &
        "Variant alb_bitor(const Variant &a, const Variant &b) { return Variant(alb_to_i64(a) | alb_to_i64(b)); }" & ASCII.LF &
        "Variant alb_bitxor(const Variant &a, const Variant &b) { return Variant(alb_to_i64(a) ^ alb_to_i64(b)); }" & ASCII.LF &
        "Variant alb_rol64(const Variant &value, const Variant &count) { const uint64_t v = (uint64_t)alb_to_i64(value); const int64_t shift = alb_to_i64(count) & 63; if (shift == 0) return Variant((int64_t)v); return Variant((int64_t)((v << shift) | (v >> (64 - shift)))); }" & ASCII.LF &
        "Variant alb_ror64(const Variant &value, const Variant &count) { const uint64_t v = (uint64_t)alb_to_i64(value); const int64_t shift = alb_to_i64(count) & 63; if (shift == 0) return Variant((int64_t)v); return Variant((int64_t)((v >> shift) | (v << (64 - shift)))); }" & ASCII.LF &
        "bool alb_eq(const Variant &a, const Variant &b) { return a == b; }" & ASCII.LF &
        "bool alb_lt(const Variant &a, const Variant &b) { return alb_to_double(a) < alb_to_double(b); }" & ASCII.LF &
        "bool alb_gt(const Variant &a, const Variant &b) { return alb_to_double(a) > alb_to_double(b); }" & ASCII.LF &
        "bool alb_lte(const Variant &a, const Variant &b) { return alb_to_double(a) <= alb_to_double(b); }" & ASCII.LF &
        "bool alb_gte(const Variant &a, const Variant &b) { return alb_to_double(a) >= alb_to_double(b); }" & ASCII.LF &
        "Variant alb_unsupported_value(const String &what) { UtilityFunctions::push_warning(String(""ALBGD unsupported runtime feature: "") + what); return Variant(); }" & ASCII.LF &
        "Variant alb_fallback_binop(const String &op, const Variant &a, const Variant &b) { const String upper = op.to_upper(); if (upper == String(""MOD"")) return alb_mod(a, b); if (upper == String(""DIV"") || op == String(""\\"")) { const int64_t d = alb_to_i64(b); return Variant(d == 0 ? (int64_t)0 : (alb_to_i64(a) / d)); } if (upper == String(""AND"")) return alb_bitand(a, b); if (upper == String(""OR"")) return alb_bitor(a, b); if (upper == String(""XOR"")) return alb_bitxor(a, b); if (upper == String(""SHL"") || op == String(""<<"")) return Variant((int64_t)((uint64_t)alb_to_i64(a) << (alb_to_i64(b) & 63))); if (upper == String(""SHR"") || op == String("">>"")) return Variant((int64_t)((uint64_t)alb_to_i64(a) >> (alb_to_i64(b) & 63))); if (upper == String(""CAT"") || upper == String(""CONCAT"")) return alb_cat(a, b); UtilityFunctions::push_warning(String(""ALBGD unhandled binary op: "") + op); return Variant(); }" & ASCII.LF &
        "Variant alb_parse_binary(const String &s) { int64_t v = 0; for (int i = 0; i < s.length(); ++i) { v = (v << 1) | (s[i] == '1' ? 1 : 0); } return Variant(v); }" & ASCII.LF &
        "Variant alb_parse_octal(const String &s) { int64_t v = 0; for (int i = 0; i < s.length(); ++i) { if (s[i] >= '0' && s[i] <= '7') v = (v * 8) + (int64_t)(s[i] - '0'); } return Variant(v); }" & ASCII.LF &
        "Array alb_make_array(const Variant &count) { Array a; int64_t n = MAX<int64_t>(0, alb_to_i64(count)); for (int64_t i = 0; i < n; ++i) a.append(Variant()); return a; }" & ASCII.LF &
        "void alb_fill_array(Array &arr, const Variant &value) { for (int64_t i = 0; i < arr.size(); ++i) arr[i] = value; }" & ASCII.LF &
        "Variant alb_index(const Array &arr, const Variant &idx) { int64_t i = alb_to_i64(idx) - 1; return (i >= 0 && i < arr.size()) ? arr[i] : Variant(); }" & ASCII.LF &
        "void alb_set_index(Array &arr, const Variant &idx, const Variant &value) { int64_t i = alb_to_i64(idx) - 1; while (i >= arr.size()) arr.append(Variant()); if (i >= 0) arr[i] = value; }" & ASCII.LF &
        "Variant alb_get_member(const Variant &base, const String &field) { Dictionary d = base; return d.has(field) ? d[field] : Variant(); }" & ASCII.LF &
        "void alb_set_member(Variant &base, const String &field, const Variant &value) { Dictionary d = base; d[field] = value; base = d; }" & ASCII.LF &
        "Variant alb_get_member_index(const Array &arr, const Variant &idx, const String &field) { Variant v = alb_index(arr, idx); return alb_get_member(v, field); }" & ASCII.LF &
        "void alb_set_member_index(Array &arr, const Variant &idx, const String &field, const Variant &value) { int64_t i = alb_to_i64(idx) - 1; while (i >= arr.size()) arr.append(Dictionary()); if (i >= 0) { Variant base = arr[i]; alb_set_member(base, field, value); arr[i] = base; } }" & ASCII.LF &
        "Array alb_make_parallel(const Variant &count, const Array &fields) { Array out; int64_t n = MAX<int64_t>(0, alb_to_i64(count)); for (int64_t i = 0; i < n; ++i) { Dictionary d; for (int j = 0; j < fields.size(); ++j) d[fields[j]] = Variant(); out.append(d); } return out; }" & ASCII.LF &
        "Dictionary alb_make_firewall(const Array &read, const Array &write, bool deny_all) { Dictionary fw; fw[String(""read"")] = read; fw[String(""write"")] = write; fw[String(""deny_all"")] = deny_all; return fw; }" & ASCII.LF &
        "static bool alb_firewall_allows(const String &kind, const String &name) { if (name.is_empty() || g_firewall_stack.is_empty()) return true; Dictionary fw = g_firewall_stack[g_firewall_stack.size() - 1]; const bool deny_all = fw.has(String(""deny_all"")) ? (bool)fw[String(""deny_all"")] : false; if (!deny_all) return true; Array allowed = fw.has(kind) ? (Array)fw[kind] : Array(); for (int i = 0; i < allowed.size(); ++i) if (alb_to_string(allowed[i]) == name) return true; return false; }" & ASCII.LF &
        "void alb_firewall_enter(const Variant &fw) { g_firewall_stack.append(fw); }" & ASCII.LF &
        "void alb_firewall_leave() { if (!g_firewall_stack.is_empty()) g_firewall_stack.resize(g_firewall_stack.size() - 1); }" & ASCII.LF &
        "AlbFirewallScope::AlbFirewallScope(const Variant &fw) { alb_firewall_enter(fw); }" & ASCII.LF &
        "AlbFirewallScope::~AlbFirewallScope() { alb_firewall_leave(); }" & ASCII.LF &
        "void alb_firewall_touch_read(const String &name) { if (!alb_firewall_allows(String(""read""), name)) UtilityFunctions::push_warning(String(""MEMORY_FIREWALL read blocked: "") + name); }" & ASCII.LF &
        "void alb_firewall_touch_write(const String &name) { if (!alb_firewall_allows(String(""write""), name)) UtilityFunctions::push_warning(String(""MEMORY_FIREWALL write blocked: "") + name); }" & ASCII.LF &
        "Variant alb_firewall_read(const String &name, const Variant &value) { alb_firewall_touch_read(name); return value; }" & ASCII.LF &
        "Variant alb_firewall_write(const String &name, const Variant &value) { alb_firewall_touch_write(name); return value; }" & ASCII.LF &
        "Dictionary alb_make_markov_model(const Variant &states, const Array &matrix) { Dictionary model; model[String(""states"")] = alb_to_i64(states); model[String(""matrix"")] = matrix; return model; }" & ASCII.LF &
        "int64_t alb_markov_predict(const Dictionary &model, const Variant &current_state) { const int64_t states = MAX<int64_t>(1, model.has(String(""states"")) ? (int64_t)model[String(""states"")] : 1); Array matrix = model.has(String(""matrix"")) ? (Array)model[String(""matrix"")] : Array(); int64_t row = alb_to_i64(current_state) - 1; if (row < 0) row = 0; if (row >= states) row = states - 1; int64_t best_col = 0; double best_weight = matrix.is_empty() ? 0.0 : alb_to_double(matrix[row * states]); for (int64_t col = 1; col < states; ++col) { const int64_t ix = row * states + col; const double weight = ix < matrix.size() ? alb_to_double(matrix[ix]) : 0.0; if (weight > best_weight) { best_weight = weight; best_col = col; } } return best_col + 1; }" & ASCII.LF &
        "static double alb_nn_act(int64_t code, double value) { switch (code) { case 1: return value > 0.0 ? value : 0.0; case 2: return value > 0.0 ? 1.0 : 0.0; case 3: if (value > 128.0) return 1024.0; if (value < -128.0) return -1024.0; return value * 8.0; default: return value; } }" & ASCII.LF &
        "static int64_t alb_nn_seed(int64_t prev_size, int64_t curr_size, int64_t neuron_index, int64_t input_index) { if (prev_size <= 0 || curr_size <= 0) return 0; if (curr_size == prev_size) return input_index == neuron_index ? 256 : 0; if (prev_size == curr_size * 2) { if (input_index == neuron_index * 2) return 256; if (input_index == (neuron_index * 2) + 1) return -256; return 0; } if (curr_size > prev_size) return input_index == (neuron_index % prev_size) ? 256 : 0; const int64_t input_span = MAX<int64_t>(1, prev_size / curr_size); const int64_t base_input = neuron_index * input_span; const int64_t positive_in = MIN<int64_t>(prev_size - 1, base_input); const int64_t negative_in = MIN<int64_t>(prev_size - 1, base_input + 1); if (input_span >= 2) { if (input_index == positive_in) return 256; if (input_index == negative_in) return -128; return 0; } return input_index == positive_in ? 256 : 0; }" & ASCII.LF &
        "Dictionary alb_make_neural_model(const String &name, const Array &sizes, const Array &acts) { Dictionary model; Array weights; Array biases; Array state; for (int layer = 0; layer < sizes.size(); ++layer) { const int64_t count = MAX<int64_t>(1, alb_to_i64(sizes[layer])); Array frame; for (int64_t i = 0; i < count; ++i) frame.append(0.0); state.append(frame); if (layer == 0) continue; const int64_t prev = MAX<int64_t>(1, alb_to_i64(sizes[layer - 1])); const int64_t curr = MAX<int64_t>(1, alb_to_i64(sizes[layer])); Array w; Array b; for (int64_t neuron = 0; neuron < curr; ++neuron) { b.append((int64_t)0); for (int64_t input_ix = 0; input_ix < prev; ++input_ix) w.append(alb_nn_seed(prev, curr, neuron, input_ix)); } weights.append(w); biases.append(b); } model[String(""name"")] = name; model[String(""sizes"")] = sizes; model[String(""activations"")] = acts; model[String(""weights"")] = weights; model[String(""biases"")] = biases; model[String(""state"")] = state; return model; }" & ASCII.LF &
        "void alb_nn_infer(Dictionary &model, const Variant &input, Array &output) { Array state = model.has(String(""state"")) ? (Array)model[String(""state"")] : Array(); if (state.is_empty()) return; Array input_arr = alb_to_array(input); Array first = (Array)state[0]; for (int i = 0; i < first.size(); ++i) first[i] = i < input_arr.size() ? alb_to_double(input_arr[i]) : 0.0; state[0] = first; Array weights = model.has(String(""weights"")) ? (Array)model[String(""weights"")] : Array(); Array biases = model.has(String(""biases"")) ? (Array)model[String(""biases"")] : Array(); Array acts = model.has(String(""activations"")) ? (Array)model[String(""activations"")] : Array(); for (int layer = 1; layer < state.size(); ++layer) { Array prev = (Array)state[layer - 1]; Array curr = (Array)state[layer]; Array w = layer - 1 < weights.size() ? (Array)weights[layer - 1] : Array(); Array b = layer - 1 < biases.size() ? (Array)biases[layer - 1] : Array(); const int64_t prev_size = prev.size(); for (int i = 0; i < curr.size(); ++i) { double acc = i < b.size() ? alb_to_double(b[i]) : 0.0; for (int j = 0; j < prev_size; ++j) { const int64_t wix = i * prev_size + j; acc += alb_to_double(prev[j]) * (wix < w.size() ? alb_to_double(w[wix]) : 0.0); } curr[i] = alb_nn_act(layer < acts.size() ? alb_to_i64(acts[layer]) : 0, acc); } state[layer] = curr; } model[String(""state"")] = state; Array out = (Array)state[state.size() - 1]; output.resize(out.size()); for (int i = 0; i < out.size(); ++i) { const double v = alb_to_double(out[i]); output[i] = (int64_t)(v >= 0.0 ? v + 0.5 : v - 0.5); } }" & ASCII.LF &
        "void alb_nn_train(Dictionary &model, const Variant &input, const Variant &expected, const Variant &epochs) { Array expect_arr = alb_to_array(expected); Array output; const int64_t epoch_count = MAX<int64_t>(1, alb_to_i64(epochs)); for (int64_t epoch = 0; epoch < epoch_count; ++epoch) { alb_nn_infer(model, input, output); Array sizes = model.has(String(""sizes"")) ? (Array)model[String(""sizes"")] : Array(); if (sizes.size() < 2) return; Array state = model.has(String(""state"")) ? (Array)model[String(""state"")] : Array(); Array prev = state.size() >= 2 ? (Array)state[state.size() - 2] : Array(); Array weights = model.has(String(""weights"")) ? (Array)model[String(""weights"")] : Array(); Array biases = model.has(String(""biases"")) ? (Array)model[String(""biases"")] : Array(); if (weights.is_empty() || biases.is_empty()) return; Array w = (Array)weights[weights.size() - 1]; Array b = (Array)biases[biases.size() - 1]; const int64_t prev_size = prev.size(); for (int i = 0; i < output.size(); ++i) { const double got_d = alb_to_double(output[i]); const double want_d = i < expect_arr.size() ? alb_to_double(expect_arr[i]) : 0.0; const int64_t got = (int64_t)(got_d >= 0.0 ? got_d + 0.5 : got_d - 0.5); const int64_t want = (int64_t)(want_d >= 0.0 ? want_d + 0.5 : want_d - 0.5); const int64_t delta = got > want ? -1 : (got < want ? 1 : 0); if (i < b.size()) b[i] = alb_to_i64(b[i]) + delta; for (int j = 0; j < prev_size; ++j) { const int64_t wix = i * prev_size + j; const double prev_d = alb_to_double(prev[j]); if (wix < w.size() && (prev_d >= 0.0 ? prev_d + 0.5 : prev_d - 0.5) != 0.0) w[wix] = alb_to_i64(w[wix]) + delta; } } weights[weights.size() - 1] = w; biases[biases.size() - 1] = b; model[String(""weights"")] = weights; model[String(""biases"")] = biases; } }" & ASCII.LF &
        "static String alb_network_key(const Dictionary &socket) { return String(""ALB_NET_"") + String::num_int64(socket.has(String(""protocol"")) ? (int64_t)socket[String(""protocol"")] : 0) + String(""_"") + String::num_int64(socket.has(String(""port"")) ? (int64_t)socket[String(""port"")] : 0); }" & ASCII.LF &
        "Dictionary alb_make_network_socket(const Variant &protocol, const Variant &port, const Variant &buffer_size) { Dictionary socket; const int64_t size = MAX<int64_t>(1, alb_to_i64(buffer_size)); Array zeros; zeros.resize(size); for (int64_t i = 0; i < size; ++i) zeros[i] = (int64_t)0; socket[String(""protocol"")] = alb_to_i64(protocol); socket[String(""port"")] = alb_to_i64(port); socket[String(""buffer_size"")] = size; socket[String(""queue"")] = Array(); socket[String(""last_sent"")] = zeros; socket[String(""last_received"")] = zeros; socket[String(""open"")] = true; socket[String(""listening"")] = false; return socket; }" & ASCII.LF &
        "void alb_network_listen(Dictionary &socket) { socket[String(""listening"")] = true; socket[String(""open"")] = true; if (!g_network_bus.has(alb_network_key(socket))) g_network_bus[alb_network_key(socket)] = Array(); }" & ASCII.LF &
        "Dictionary alb_network_accept(Dictionary &socket) { Dictionary child = socket.duplicate(true); child[String(""queue"")] = Array(); child[String(""open"")] = true; return child; }" & ASCII.LF &
        "void alb_network_receive(Dictionary &socket, Array &buffer) { Array packet; Array queue = socket.has(String(""queue"")) ? (Array)socket[String(""queue"")] : Array(); if (!queue.is_empty()) { packet = (Array)queue[0]; queue.remove_at(0); socket[String(""queue"")] = queue; } else { const String key = alb_network_key(socket); Array bus = g_network_bus.has(key) ? (Array)g_network_bus[key] : Array(); if (!bus.is_empty()) { packet = (Array)bus[0]; bus.remove_at(0); g_network_bus[key] = bus; } else { packet = socket.has(String(""last_received"")) ? (Array)socket[String(""last_received"")] : Array(); } } socket[String(""last_received"")] = packet; if (buffer.size() < packet.size()) buffer.resize(packet.size()); for (int i = 0; i < buffer.size(); ++i) buffer[i] = i < packet.size() ? alb_to_i64(packet[i]) & 255 : 0; }" & ASCII.LF &
        "void alb_network_send(Dictionary &socket, const Array &buffer) { Array packet; packet.resize(buffer.size()); for (int i = 0; i < buffer.size(); ++i) packet[i] = alb_to_i64(buffer[i]) & 255; socket[String(""last_sent"")] = packet; const String key = alb_network_key(socket); Array bus = g_network_bus.has(key) ? (Array)g_network_bus[key] : Array(); bus.append(packet); g_network_bus[key] = bus; }" & ASCII.LF &
        "void alb_network_close(Dictionary &socket) { socket[String(""open"")] = false; socket[String(""listening"")] = false; socket[String(""queue"")] = Array(); }" & ASCII.LF &
        "static String alb_rel_key(const String &pred, const Variant &arg1) { return pred + String(""|"") + alb_to_string(arg1); }" & ASCII.LF &
        "void alb_rel_set(const String &pred, const Variant &arg1, const Variant &value) { g_rel_store[alb_rel_key(pred, arg1)] = value; }" & ASCII.LF &
        "void alb_rel_retract(const String &pred, const Variant &arg1) { const String key = alb_rel_key(pred, arg1); if (g_rel_store.has(key)) g_rel_store.erase(key); }" & ASCII.LF &
        "int64_t alb_rel_has(const String &pred, const Variant &arg1) { return g_rel_store.has(alb_rel_key(pred, arg1)) ? 1 : 0; }" & ASCII.LF &
        "int64_t alb_rel_count(const String &pred) { Array keys = g_rel_store.keys(); const String prefix = pred + String(""|""); int64_t out = 0; for (int i = 0; i < keys.size(); ++i) { const String key = keys[i]; if (key.begins_with(prefix)) out += 1; } return out; }" & ASCII.LF &
        "Variant alb_rel_find1(const String &pred) { Array keys = g_rel_store.keys(); const String prefix = pred + String(""|""); for (int i = 0; i < keys.size(); ++i) { const String key = keys[i]; if (key.begins_with(prefix)) return key.substr(prefix.length()); } return Variant((int64_t)0); }" & ASCII.LF &
        "int64_t alb_rel_findall1(const String &pred, Array &target) { Array keys = g_rel_store.keys(); const String prefix = pred + String(""|""); int64_t out = 0; for (int i = 0; i < target.size(); ++i) target[i] = (int64_t)0; for (int i = 0; i < keys.size() && out < target.size(); ++i) { const String key = keys[i]; if (key.begins_with(prefix)) { target[(int)out] = key.substr(prefix.length()); out += 1; } } return out; }" & ASCII.LF &
        "void alb_print(const Variant &value) { UtilityFunctions::print(value); }" & ASCII.LF &
        "void alb_runtime_assert(bool cond) { if (!cond) UtilityFunctions::push_warning(String(""ALBGD runtime assert failed"")); }" & ASCII.LF &
        "void alb_create_window(const Variant &title, const Variant &w, const Variant &h) { g_window_title = alb_to_string(title); g_virtual_width = MAX<int64_t>(1, alb_to_i64(w)); g_virtual_height = MAX<int64_t>(1, alb_to_i64(h)); alb_apply_window_config(); }" & ASCII.LF &
        "void alb_set_fullscreen(const Variant &v) { Window *w = alb_window(); if (!w) return; w->set_mode(alb_to_bool(v) ? Window::MODE_FULLSCREEN : Window::MODE_WINDOWED); }" & ASCII.LF &
        "void alb_set_resizable(const Variant &v) { g_window_resizable = alb_to_bool(v); Window *w = alb_window(); if (!w) return; w->set_flag(Window::FLAG_RESIZE_DISABLED, !g_window_resizable); }" & ASCII.LF &
        "void alb_set_stretchy(const Variant &v) { g_window_stretchy = alb_to_bool(v); alb_apply_window_config(); }" & ASCII.LF &
        "void alb_color(const Variant &v) { Color c; int64_t raw = alb_to_i64(v); if (raw > 0xFFFFFF) raw &= 0xFFFFFF; c = Color::hex((uint32_t)raw); g_color = c; }" & ASCII.LF &
        "void alb_clear(const Variant &v) { if (!g_canvas) return; Color prev = g_color; alb_color(v); g_canvas->draw_rect(Rect2(0.0, 0.0, (double)alb_virtual_width(), (double)alb_virtual_height()), g_color, true); g_color = prev; }" & ASCII.LF &
        "void alb_draw_rect(const Variant &x, const Variant &y, const Variant &w, const Variant &h) { if (g_canvas) g_canvas->draw_rect(Rect2(alb_to_double(x), alb_to_double(y), alb_to_double(w), alb_to_double(h)), g_color, false, 1.0); }" & ASCII.LF &
        "void alb_fill_rect(const Variant &x, const Variant &y, const Variant &w, const Variant &h) { if (g_canvas) g_canvas->draw_rect(Rect2(alb_to_double(x), alb_to_double(y), alb_to_double(w), alb_to_double(h)), g_color, true); }" & ASCII.LF &
        "void alb_draw_line(const Variant &x1, const Variant &y1, const Variant &x2, const Variant &y2) { if (g_canvas) g_canvas->draw_line(Vector2(alb_to_double(x1), alb_to_double(y1)), Vector2(alb_to_double(x2), alb_to_double(y2)), g_color, 1.0); }" & ASCII.LF &
        "void alb_draw_circle(const Variant &x, const Variant &y, const Variant &r) { if (g_canvas) g_canvas->draw_arc(Vector2(alb_to_double(x), alb_to_double(y)), alb_to_double(r), 0.0, 6.28318530718, 48, g_color, 1.0); }" & ASCII.LF &
        "void alb_fill_circle(const Variant &x, const Variant &y, const Variant &r) { if (g_canvas) g_canvas->draw_circle(Vector2(alb_to_double(x), alb_to_double(y)), alb_to_double(r), g_color); }" & ASCII.LF &
        "void alb_draw_triangle(const Variant &x1, const Variant &y1, const Variant &x2, const Variant &y2, const Variant &x3, const Variant &y3) { if (!g_canvas) return; alb_draw_line(x1, y1, x2, y2); alb_draw_line(x2, y2, x3, y3); alb_draw_line(x3, y3, x1, y1); }" & ASCII.LF &
        "void alb_fill_triangle(const Variant &x1, const Variant &y1, const Variant &x2, const Variant &y2, const Variant &x3, const Variant &y3) { if (!g_canvas) return; PackedVector2Array pts; pts.push_back(Vector2(alb_to_double(x1), alb_to_double(y1))); pts.push_back(Vector2(alb_to_double(x2), alb_to_double(y2))); pts.push_back(Vector2(alb_to_double(x3), alb_to_double(y3))); g_canvas->draw_colored_polygon(pts, g_color); }" & ASCII.LF &
        "void alb_plot(const Variant &x, const Variant &y) { if (g_canvas) g_canvas->draw_rect(Rect2(alb_to_double(x), alb_to_double(y), 1, 1), g_color, true); }" & ASCII.LF &
        "void alb_draw_text(const Variant &x, const Variant &y, const String &text) { if (!g_canvas) return; Ref<Font> font = ThemeDB::get_singleton()->get_fallback_font(); if (font.is_null()) { UtilityFunctions::print(text); return; } g_canvas->draw_string(font, Vector2(alb_to_double(x), alb_to_double(y) + font->get_ascent(ThemeDB::get_singleton()->get_fallback_font_size())), text, 0, -1.0, ThemeDB::get_singleton()->get_fallback_font_size(), g_color); }" & ASCII.LF &
        "int64_t alb_key(const Variant &key) { return Input::get_singleton()->is_key_pressed((Key)alb_to_i64(key)) ? 1 : 0; }" & ASCII.LF &
        "int64_t alb_mouse_x() { return (int64_t)Input::get_singleton()->get_mouse_position().x; }" & ASCII.LF &
        "int64_t alb_mouse_y() { return (int64_t)Input::get_singleton()->get_mouse_position().y; }" & ASCII.LF &
        "int64_t alb_vmouse_x() { return alb_mouse_x(); }" & ASCII.LF &
        "int64_t alb_vmouse_y() { return alb_mouse_y(); }" & ASCII.LF &
        "int64_t alb_mouse_click(const Variant &button) { return Input::get_singleton()->is_mouse_button_pressed((MouseButton)alb_to_i64(button)) ? 1 : 0; }" & ASCII.LF &
        "int64_t alb_screen_width() { return DisplayServer::get_singleton()->window_get_size().x; }" & ASCII.LF &
        "int64_t alb_screen_height() { return DisplayServer::get_singleton()->window_get_size().y; }" & ASCII.LF &
        "int64_t alb_virtual_width() { return g_virtual_width > 0 ? g_virtual_width : alb_screen_width(); }" & ASCII.LF &
        "int64_t alb_virtual_height() { return g_virtual_height > 0 ? g_virtual_height : alb_screen_height(); }" & ASCII.LF &
        "Variant alb_rnd(const Variant &limit) { g_rng = g_rng * 6364136223846793005ULL + 1442695040888963407ULL; int64_t n = MAX<int64_t>(1, alb_to_i64(limit)); return Variant((int64_t)(g_rng % (uint64_t)n)); }" & ASCII.LF &
        "Variant alb_read_pixel(const Variant &x, const Variant &y) { if (!g_canvas) return Variant((int64_t)0); Viewport *vp = g_canvas->get_viewport(); if (!vp) return Variant((int64_t)0); Ref<Texture2D> tex = vp->get_texture(); if (tex.is_null()) return Variant((int64_t)0); Ref<Image> img = tex->get_image(); if (img.is_null()) return Variant((int64_t)0); int px = (int)alb_to_i64(x); int py = (int)alb_to_i64(y); if (px < 0 || py < 0 || px >= img->get_width() || py >= img->get_height()) return Variant((int64_t)0); return Variant((int64_t)(img->get_pixel(px, py).to_argb32() & 0xFFFFFF)); }" & ASCII.LF &
        "Variant alb_temporal_ref(const Variant &base, const String &selector) { const String upper = selector.to_upper(); if (upper == String(""NOW"")) return base; if (upper == String(""TIMELINE"")) { if (base.get_type() == Variant::ARRAY) return Variant((int64_t)((Array)base).size()); if (base.get_type() == Variant::DICTIONARY) { Dictionary d = base; if (d.has(String(""timeline""))) return d[String(""timeline"")]; if (d.has(String(""history""))) return Variant((int64_t)((Array)d[String(""history"")]).size()); } return Variant(g_temporal_tick); } if (base.get_type() == Variant::DICTIONARY) { Dictionary d = base; if (d.has(selector)) return d[selector]; if (d.has(upper)) return d[upper]; if (d.has(String(""history""))) { Array history = d[String(""history"")]; if (history.is_empty()) return Variant(); int64_t head = d.has(String(""head"")) ? alb_to_i64(d[String(""head"")]) : (history.size() - 1); if (upper == String(""PAST"")) { const int64_t idx = head > 0 ? head - 1 : history.size() - 1; return history[idx]; } if (upper == String(""FUTURE"")) { const int64_t idx = (head + 1) % history.size(); return history[idx]; } } if (upper == String(""PAST"") && d.has(String(""past""))) return d[String(""past"")]; if (upper == String(""FUTURE"") && d.has(String(""future""))) return d[String(""future"")]; } if (base.get_type() == Variant::ARRAY) { Array history = base; if (history.is_empty()) return Variant(); if (upper == String(""PAST"")) return history.size() >= 2 ? history[history.size() - 2] : history[history.size() - 1]; if (upper == String(""FUTURE"")) return history[0]; } return base; }" & ASCII.LF &
        "void alb_register_state_hooks(AlbStateCaptureFn capture, AlbStateRestoreFn restore) { g_capture_state = capture; g_restore_state = restore; }" & ASCII.LF &
        "void alb_save_state() { if (g_capture_state) g_saved_state = g_capture_state(); }" & ASCII.LF &
        "void alb_load_state() { if (g_restore_state && !g_saved_state.is_empty()) g_restore_state(g_saved_state); }" & ASCII.LF &
        "void alb_advance_time(const Variant &n) { const int64_t steps = MAX<int64_t>(0, alb_to_i64(n)); g_temporal_tick += steps; }" & ASCII.LF &
        "void alb_delay(const Variant &n) { const int64_t steps = MAX<int64_t>(0, alb_to_i64(n)); if (steps > 0) { g_frame_interval = steps; alb_advance_time(n); } }" & ASCII.LF &
        "void alb_flush_buffer(const Variant &buffer, const Variant &path) { Error err = OK; Ref<FileAccess> f = FileAccess::open(alb_to_string(path), FileAccess::WRITE, &err); if (f.is_null()) { UtilityFunctions::push_warning(String(""ALBGD flush failed: "") + alb_to_string(path)); return; } if (buffer.get_type() == Variant::STRING) { f->store_string((String)buffer); } else { f->store_var(buffer); } }" & ASCII.LF &
        "Array alb_load_buffer(const Variant &path) { Error err = OK; Ref<FileAccess> f = FileAccess::open(alb_to_string(path), FileAccess::READ, &err); if (f.is_null()) return Array(); Variant v = f->get_var(); return v.get_type() == Variant::ARRAY ? (Array)v : Array(); }" & ASCII.LF &
        "String alb_load_text(const Variant &path) { Error err = OK; Ref<FileAccess> f = FileAccess::open(alb_to_string(path), FileAccess::READ, &err); if (f.is_null()) return String(); return f->get_as_text(); }" & ASCII.LF &
        "Variant alb_load_value(const Variant &path) { Error err = OK; Ref<FileAccess> f = FileAccess::open(alb_to_string(path), FileAccess::READ, &err); if (f.is_null()) return Variant(); return f->get_var(); }" & ASCII.LF &
        "void alb_file_open(const Variant &path, const Variant &mode) { String smode = alb_to_string(mode).to_upper(); int flags = FileAccess::READ; const bool append_mode = smode.find(""APPEND"") >= 0 || smode == ""A""; if (smode.find(""READWRITE"") >= 0 || smode.find(""READ_WRITE"") >= 0 || smode.find(""+"") >= 0) flags = FileAccess::READ_WRITE; else if (smode.find(""WRITE"") >= 0 || smode == ""W"" || append_mode) flags = FileAccess::WRITE; Error err = OK; Ref<FileAccess> f = FileAccess::open(alb_to_string(path), flags, &err); if (f.is_null()) { UtilityFunctions::push_warning(String(""ALBGD file open failed: "") + alb_to_string(path)); return; } if (append_mode) f->seek_end(); int64_t hid = g_next_file_handle++; g_open_files[hid] = f; g_open_files[alb_to_string(path)] = f; g_open_files[String(""last"")] = f; g_open_files[String(""last_id"")] = hid; }" & ASCII.LF &
        "void alb_file_read(const Variant &handle, const Variant &bytes) { Ref<FileAccess> f = alb_lookup_file(handle); if (f.is_null()) return; const int64_t wanted = alb_to_i64(bytes); if (wanted > 0) { PackedByteArray raw = f->get_buffer((int)wanted); Array out; out.resize(raw.size()); for (int i = 0; i < raw.size(); ++i) out[i] = (int64_t)raw[i]; g_open_files[String(""last_read"")] = out; g_open_files[String(""last_read_bytes"")] = out; g_open_files[String(""last_read_size"")] = (int64_t)raw.size(); } else { String text = f->get_as_text(); g_open_files[String(""last_read"")] = text; g_open_files[String(""last_read_text"")] = text; g_open_files[String(""last_read_size"")] = (int64_t)text.length(); } }" & ASCII.LF &
        "void alb_file_write(const Variant &handle, const Variant &data) { Ref<FileAccess> f = alb_lookup_file(handle); if (f.is_null()) return; if (data.get_type() == Variant::STRING) f->store_string((String)data); else f->store_var(data); }" & ASCII.LF &
        "void alb_file_close(const Variant &handle) { if (g_open_files.has(handle)) g_open_files.erase(handle); String key = alb_to_string(handle); if (g_open_files.has(key)) g_open_files.erase(key); }" & ASCII.LF &
        "void alb_audio_event(const Variant &payload) { if (payload.get_type() == Variant::NIL) return; UtilityFunctions::print(String(""ALBGD audio event: "") + alb_to_string(payload)); }" & ASCII.LF &
        "void alb_cease() { g_should_cease = true; }" & ASCII.LF &
        "void alb_swapnpop(Array &target, const Variant &slot, const Variant &live_count) { int64_t idx = alb_to_i64(slot) - 1; int64_t live = alb_to_i64(live_count); if (idx < 0 || live <= 0 || idx >= target.size() || live > target.size()) return; int64_t last = live - 1; if (idx != last) target[idx] = target[last]; target[last] = Variant(); }" & ASCII.LF &
        "} // namespace alb_godot_support" & ASCII.LF);

      Write_Text_File (Header_Path, To_String (Header_Text));
      Write_Text_File (Cpp_Path, To_String (Cpp_Text));
   end Write_Runtime_Support;

   procedure Write_Generated_Header is
      Src_Dir      : constant String := Ada.Directories.Compose (To_String (Output_Directory), "src");
      Header_Path  : constant String := Ada.Directories.Compose (Src_Dir, To_String (Generated_Class) & ".hpp");
      Text         : Unbounded_String := To_Unbounded_String ("");
      Base_Name    : constant String := To_String (Generated_Base);
      Draw_Support : constant Boolean := Is_Drawable_Base (Base_Name);
   begin
      Append (Text,
        "#pragma once" & ASCII.LF &
        "#include <godot_cpp/" & "classes/" & Base_Include_Name (Base_Name) & ">" & ASCII.LF &
        "#include <godot_cpp/core/class_db.hpp>" & ASCII.LF &
        "namespace godot {" & ASCII.LF &
        "class " & To_String (Generated_Class) & " : public " & Base_Name & " {" & ASCII.LF &
        "    GDCLASS(" & To_String (Generated_Class) & ", " & Base_Name & ");" & ASCII.LF &
        "protected:" & ASCII.LF &
        "    static void _bind_methods();" & ASCII.LF &
        "public:" & ASCII.LF &
        "    " & To_String (Generated_Class) & "();" & ASCII.LF &
        "    ~" & To_String (Generated_Class) & "() override;" & ASCII.LF &
        "    godot::Dictionary alb_capture_snapshot() const;" & ASCII.LF &
        "    void alb_restore_snapshot(const godot::Dictionary &state);" & ASCII.LF &
        "    godot::Variant alb_last_file_read() const;" & ASCII.LF &
        "    void alb_request_cease();" & ASCII.LF &
        "    void _ready();" & ASCII.LF &
        "    void _process(double delta);" & ASCII.LF);
      if Draw_Support then
         Append (Text, "    void _draw();" & ASCII.LF);
      end if;
      Append (Text,
        "};" & ASCII.LF &
        "} // namespace godot" & ASCII.LF);
      Write_Text_File (Header_Path, To_String (Text));
   end Write_Generated_Header;

   procedure Write_Generated_CPP is
      Src_Dir      : constant String := Ada.Directories.Compose (To_String (Output_Directory), "src");
      Cpp_Path     : constant String := Ada.Directories.Compose (Src_Dir, To_String (Generated_Class) & ".cpp");
      Text         : Unbounded_String := To_Unbounded_String ("");
      Base_Name    : constant String := To_String (Generated_Base);
      Draw_Support : constant Boolean := Is_Drawable_Base (Base_Name);
   begin
      Append (Text,
        "#include """ & To_String (Generated_Class) & ".hpp""" & ASCII.LF &
        "#include ""alb_runtime_support.hpp""" & ASCII.LF &
        "#include <godot_cpp/core/class_db.hpp>" & ASCII.LF &
        "#include <godot_cpp/variant/utility_functions.hpp>" & ASCII.LF &
        "using namespace godot;" & ASCII.LF &
        "using namespace alb_godot_support;" & ASCII.LF & ASCII.LF &
        "namespace {" & ASCII.LF &
        "static bool alb_globals_initialized = false;" & ASCII.LF);
      Append (Text, To_String (Warning_Buffer));
      Append (Text, To_String (Global_Decls));
      Append (Text, ASCII.LF & "static void alb_bootstrap_globals() {" & ASCII.LF &
        "    if (alb_globals_initialized) return;" & ASCII.LF &
        "    alb_globals_initialized = true;" & ASCII.LF);
      Append (Text, To_String (Global_Bootstrap));
      Append (Text, "}" & ASCII.LF & ASCII.LF);
      Append (Text, "static Dictionary alb_capture_state() {" & ASCII.LF &
        "    Dictionary state;" & ASCII.LF);
      for I in 1 .. Global_Count loop
         declare
            GName : constant String := To_String (Globals (I).Name);
            Key   : constant String := To_Godot_String (GName);
         begin
            case Globals (I).Kind is
               when Global_Variant =>
                  Append (Text, "    state[" & Key & "] = " & GName & ";" & ASCII.LF);
               when Global_String =>
                  Append (Text, "    state[" & Key & "] = " & GName & ";" & ASCII.LF);
               when Global_Array =>
                  Append (Text, "    state[" & Key & "] = " & GName & ";" & ASCII.LF);
               when Global_Slide =>
                  Append (Text, "    state[" & Key & "] = " & GName & ";" & ASCII.LF);
                  Append (Text, "    state[" & Key & " + String(""_active"")] = " & GName & "_active;" & ASCII.LF);
                  Append (Text, "    state[" & Key & " + String(""_capacity"")] = " & GName & "_capacity;" & ASCII.LF);
               when Global_Temporal =>
                  Append (Text, "    state[" & Key & "] = " & GName & ";" & ASCII.LF);
                  Append (Text, "    state[" & Key & " + String(""_history"")] = " & GName & "_history;" & ASCII.LF);
                  Append (Text, "    state[" & Key & " + String(""_head"")] = " & GName & "_head;" & ASCII.LF);
               when Global_Dictionary =>
                  Append (Text, "    state[" & Key & "] = " & GName & ";" & ASCII.LF);
            end case;
         end;
      end loop;
      Append (Text, "    return state;" & ASCII.LF &
        "}" & ASCII.LF & ASCII.LF &
        "static void alb_restore_state(const Dictionary &state) {" & ASCII.LF);
      for I in 1 .. Global_Count loop
         declare
            GName : constant String := To_String (Globals (I).Name);
            Key   : constant String := To_Godot_String (GName);
         begin
            case Globals (I).Kind is
               when Global_Variant =>
                  Append (Text, "    if (state.has(" & Key & ")) " & GName & " = state[" & Key & "];" & ASCII.LF);
               when Global_String =>
                  Append (Text, "    if (state.has(" & Key & ")) " & GName & " = (String)state[" & Key & "];" & ASCII.LF);
               when Global_Array =>
                  Append (Text, "    if (state.has(" & Key & ")) " & GName & " = (Array)state[" & Key & "];" & ASCII.LF);
               when Global_Slide =>
                  Append (Text, "    if (state.has(" & Key & ")) " & GName & " = (Array)state[" & Key & "];" & ASCII.LF);
                  Append (Text, "    if (state.has(" & Key & " + String(""_active""))) " & GName & "_active = (int64_t)state[" & Key & " + String(""_active"")];" & ASCII.LF);
                  Append (Text, "    if (state.has(" & Key & " + String(""_capacity""))) " & GName & "_capacity = (int64_t)state[" & Key & " + String(""_capacity"")];" & ASCII.LF);
               when Global_Temporal =>
                  Append (Text, "    if (state.has(" & Key & ")) " & GName & " = state[" & Key & "];" & ASCII.LF);
                  Append (Text, "    if (state.has(" & Key & " + String(""_history""))) " & GName & "_history = (Array)state[" & Key & " + String(""_history"")];" & ASCII.LF);
                  Append (Text, "    if (state.has(" & Key & " + String(""_head""))) " & GName & "_head = (int64_t)state[" & Key & " + String(""_head"")];" & ASCII.LF);
               when Global_Dictionary =>
                  Append (Text, "    if (state.has(" & Key & ")) " & GName & " = (Dictionary)state[" & Key & "];" & ASCII.LF);
            end case;
         end;
      end loop;
      Append (Text, "}" & ASCII.LF & ASCII.LF);
      Append (Text, To_String (Struct_Buffer));
      Append (Text, To_String (Routine_Buffer));
      Append (Text, "static void alb_begin() {" & ASCII.LF);
      Append (Text, To_String (Begin_Buffer));
      Append (Text, "}" & ASCII.LF & ASCII.LF);
      Append (Text, "static void alb_on_tick() {" & ASCII.LF);
      Append (Text, To_String (Tick_Buffer));
      Append (Text, "}" & ASCII.LF & ASCII.LF);
      if Draw_Support then
         Append (Text, "static void alb_on_paint() {" & ASCII.LF);
         Append (Text, To_String (Paint_Buffer));
         Append (Text, "}" & ASCII.LF & ASCII.LF);
      end if;
      if Length (Key_Buffer) > 0 then
         Append (Text, "static void alb_on_key() {" & ASCII.LF);
         Append (Text, To_String (Key_Buffer));
         Append (Text, "}" & ASCII.LF & ASCII.LF);
      end if;
      Append (Text, "} // namespace" & ASCII.LF & ASCII.LF);
      Append (Text,
        "void " & To_String (Generated_Class) & "::_bind_methods() {" & ASCII.LF &
        "    ClassDB::bind_method(D_METHOD(""alb_capture_snapshot""), &" & To_String (Generated_Class) & "::alb_capture_snapshot);" & ASCII.LF &
        "    ClassDB::bind_method(D_METHOD(""alb_restore_snapshot"", ""state""), &" & To_String (Generated_Class) & "::alb_restore_snapshot);" & ASCII.LF &
        "    ClassDB::bind_method(D_METHOD(""alb_last_file_read""), &" & To_String (Generated_Class) & "::alb_last_file_read);" & ASCII.LF &
        "    ClassDB::bind_method(D_METHOD(""alb_request_cease""), &" & To_String (Generated_Class) & "::alb_request_cease);" & ASCII.LF &
        "}" & ASCII.LF &
        To_String (Generated_Class) & "::" & To_String (Generated_Class) & "() = default;" & ASCII.LF &
        To_String (Generated_Class) & "::~" & To_String (Generated_Class) & "() = default;" & ASCII.LF &
        "Dictionary " & To_String (Generated_Class) & "::alb_capture_snapshot() const { return alb_capture_state(); }" & ASCII.LF &
        "void " & To_String (Generated_Class) & "::alb_restore_snapshot(const Dictionary &state) { alb_restore_state(state); if (CanvasItem *item = Object::cast_to<CanvasItem>(const_cast<" & To_String (Generated_Class) & "*>(this))) item->queue_redraw(); }" & ASCII.LF &
        "Variant " & To_String (Generated_Class) & "::alb_last_file_read() const { return g_open_files.has(String(""last_read"")) ? g_open_files[String(""last_read"")] : Variant(); }" & ASCII.LF &
        "void " & To_String (Generated_Class) & "::alb_request_cease() { alb_cease(); }" & ASCII.LF &
        "void " & To_String (Generated_Class) & "::_ready() {" & ASCII.LF &
        "    alb_bootstrap_globals();" & ASCII.LF);
      if Draw_Support then
         Append (Text, "    g_canvas = this;" & ASCII.LF);
      else
         Append (Text, "    g_canvas = Object::cast_to<CanvasItem>(this);" & ASCII.LF);
      end if;
      Append (Text,
        "    g_should_cease = false;" & ASCII.LF &
        "    alb_register_state_hooks(&alb_capture_state, &alb_restore_state);" & ASCII.LF &
        "    set_process(true);" & ASCII.LF &
        "    alb_begin();" & ASCII.LF);
      if Draw_Support then
         Append (Text, "    queue_redraw();" & ASCII.LF);
      end if;
      Append (Text, "}" & ASCII.LF &
        "void " & To_String (Generated_Class) & "::_process(double delta) {" & ASCII.LF &
        "    if (g_should_cease) { set_process(false); queue_free(); return; }" & ASCII.LF &
        "    alb_on_tick();" & ASCII.LF);
      if Draw_Support then
         Append (Text, "    queue_redraw();" & ASCII.LF);
      end if;
      Append (Text, "    (void)delta;" & ASCII.LF &
        "}" & ASCII.LF);
      if Draw_Support then
         Append (Text,
           "void " & To_String (Generated_Class) & "::_draw() {" & ASCII.LF &
           "    g_canvas = this;" & ASCII.LF &
           "    alb_on_paint();" & ASCII.LF &
           "}" & ASCII.LF);
      end if;
      Write_Text_File (Cpp_Path, To_String (Text));
   end Write_Generated_CPP;

   procedure Write_Entry_CPP is
      Src_Dir : constant String := Ada.Directories.Compose (To_String (Output_Directory), "src");
      Path    : constant String := Ada.Directories.Compose (Src_Dir, "alb_entry.cpp");
      Text    : constant String :=
        "#include <godot_cpp/godot.hpp>" & ASCII.LF &
        "#include <godot_cpp/core/class_db.hpp>" & ASCII.LF &
        "#include """ & To_String (Generated_Class) & ".hpp""" & ASCII.LF &
        "using namespace godot;" & ASCII.LF &
        "void initialize_alb_module(ModuleInitializationLevel p_level) {" & ASCII.LF &
        "    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;" & ASCII.LF &
        "    ClassDB::register_class<" & To_String (Generated_Class) & ">();" & ASCII.LF &
        "}" & ASCII.LF &
        "void uninitialize_alb_module(ModuleInitializationLevel p_level) {" & ASCII.LF &
        "    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;" & ASCII.LF &
        "}" & ASCII.LF &
        "extern ""C"" {" & ASCII.LF &
        "GDExtensionBool GDE_EXPORT alb_entry_init(" & ASCII.LF &
        "    GDExtensionInterfaceGetProcAddress p_get_proc_address," & ASCII.LF &
        "    const GDExtensionClassLibraryPtr p_library," & ASCII.LF &
        "    GDExtensionInitialization *r_initialization) {" & ASCII.LF &
        "    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);" & ASCII.LF &
        "    init_obj.register_initializer(initialize_alb_module);" & ASCII.LF &
        "    init_obj.register_terminator(uninitialize_alb_module);" & ASCII.LF &
        "    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);" & ASCII.LF &
        "    return init_obj.init();" & ASCII.LF &
        "}" & ASCII.LF &
        "}" & ASCII.LF;
   begin
      Write_Text_File (Path, Text);
   end Write_Entry_CPP;

   procedure Write_GDExtension_File is
      Path : constant String := Ada.Directories.Compose (To_String (Output_Directory), "extension.gdextension");
      Library_Base : constant String := Normalize_Resource_Base (To_String (Resource_Base));
      Text : constant String :=
        "[configuration]" & ASCII.LF &
        "entry_symbol = ""alb_entry_init""" & ASCII.LF &
        "reloadable = true" & ASCII.LF &
        "compatibility_minimum = ""4.6""" & ASCII.LF &
        ASCII.LF &
        "[libraries]" & ASCII.LF &
        "windows.debug.x86_64 = """ &
        Join_Resource_Path
          (Library_Base,
           "bin/" & Safe_CPP_Name (To_String (Generated_Class)) &
             ".windows.template_debug.x86_64.dll") & """" & ASCII.LF &
        "windows.release.x86_64 = """ &
        Join_Resource_Path
          (Library_Base,
           "bin/" & Safe_CPP_Name (To_String (Generated_Class)) &
             ".windows.template_release.x86_64.dll") & """" & ASCII.LF;
   begin
      Write_Text_File (Path, Text);
   end Write_GDExtension_File;

   procedure Write_SConstruct is
      Path : constant String := Ada.Directories.Compose (To_String (Output_Directory), "SConstruct");
      Text : constant String :=
        "import os" & ASCII.LF &
        "from SCons.Script import DefaultEnvironment, Variables, EnumVariable, SConscript, Exit, Glob, Default" & ASCII.LF &
        "vars = Variables()" & ASCII.LF &
        "vars.Add(EnumVariable('target', 'target', 'template_debug', allowed_values=('template_debug', 'template_release', 'editor')))" & ASCII.LF &
        "vars.Add(EnumVariable('platform', 'platform', 'windows', allowed_values=('windows', 'linux', 'macos')))" & ASCII.LF &
        "vars.Add(EnumVariable('arch', 'arch', 'x86_64', allowed_values=('x86_64', 'x86_32', 'arm64', 'arm32')))" & ASCII.LF &
        "env = DefaultEnvironment(variables=vars)" & ASCII.LF &
        "godot_cpp_path = os.environ.get('GODOT_CPP_PATH', 'godot-cpp')" & ASCII.LF &
        "if not os.path.isdir(godot_cpp_path):" & ASCII.LF &
        "    print('ALBGD: missing godot-cpp checkout. Set GODOT_CPP_PATH or place godot-cpp next to this SConstruct.')" & ASCII.LF &
        "    Exit(1)" & ASCII.LF &
        "env = SConscript(os.path.join(godot_cpp_path, 'SConstruct'), {'env': env})" & ASCII.LF &
        "env.Append(CPPPATH=['src'])" & ASCII.LF &
        "sources = Glob('src/*.cpp')" & ASCII.LF &
        "library = env.SharedLibrary(target=os.path.join('bin', '" &
          Safe_CPP_Name (To_String (Generated_Class)) &
          "' + env['suffix'] + env['SHLIBSUFFIX']), source=sources)" & ASCII.LF &
        "Default(library)" & ASCII.LF;
   begin
      Write_Text_File (Path, Text);
   end Write_SConstruct;

   procedure Write_Build_Readme is
      Path : constant String := Ada.Directories.Compose (To_String (Output_Directory), "ALBGD_BUILD_NOTES.txt");
      Text : constant String :=
        "ALBGD GENERATED GODOT PROJECT" & ASCII.LF &
        "=============================" & ASCII.LF &
        ASCII.LF &
        "Source   : " & To_String (Script_Name) & ASCII.LF &
        "Class    : " & To_String (Generated_Class) & ASCII.LF &
        "Base     : " & To_String (Generated_Base) & ASCII.LF &
        "API      : Godot 4.6 GDExtension contract" & ASCII.LF &
        ASCII.LF &
        "Native build prerequisites:" & ASCII.LF &
        "  1. A local godot-cpp checkout or generated bindings tree." & ASCII.LF &
        "  2. Set GODOT_CPP_PATH to that checkout, or place godot-cpp next to this SConstruct." & ASCII.LF &
        "  3. Python + SCons available on PATH." & ASCII.LF &
        ASCII.LF &
        "Typical builds:" & ASCII.LF &
        "  python -m SCons target=template_debug platform=windows arch=x86_64" & ASCII.LF &
        "  python -m SCons target=template_release platform=windows arch=x86_64" & ASCII.LF &
        ASCII.LF &
        "Expected outputs:" & ASCII.LF &
        "  bin/" & Safe_CPP_Name (To_String (Generated_Class)) & ".windows.template_debug.x86_64.dll" & ASCII.LF &
        "  bin/" & Safe_CPP_Name (To_String (Generated_Class)) & ".windows.template_release.x86_64.dll" & ASCII.LF &
        ASCII.LF &
        "ALBGD verification currently measures successful ALB-to-Godot translation." & ASCII.LF &
        "This project shape is emitted to match a normal godot-cpp GDExtension workflow." & ASCII.LF;
   begin
      Write_Text_File (Path, Text);
   end Write_Build_Readme;

   procedure Write_Manifest is
      Path : constant String := Ada.Directories.Compose (To_String (Output_Directory), "albgd_manifest.txt");
      Res_Base : constant String := Normalize_Resource_Base (To_String (Resource_Base));
      Text : constant String :=
        "source=" & To_String (Script_Name) & ASCII.LF &
        "class=" & To_String (Generated_Class) & ASCII.LF &
        "base=" & To_String (Generated_Base) & ASCII.LF &
        "resource_base=" & Res_Base & ASCII.LF &
        "extension_res_path=" & Join_Resource_Path (Res_Base, "extension.gdextension") & ASCII.LF &
        "extension_file=extension.gdextension" & ASCII.LF &
        "bin_dir=bin" & ASCII.LF;
   begin
      Write_Text_File (Path, Text);
   end Write_Manifest;

   procedure Initialize_Output
     (Output_Directory : in String;
      Source_Name      : in String;
      Class_Name       : in String;
      Base_Class       : in String;
      Resource_Base    : in String;
      API_Target       : in Godot_API_Target;
      Build_Mode       : in Boolean;
      Diagnostic       : in out Emitter_Diagnostic_Log)
   is
      Final_Class : constant String :=
        (if Class_Name'Length = 0 then Default_Class_Name (Source_Name) else Safe_CPP_Name (Class_Name));
      Final_Base  : constant String :=
        (if Base_Class'Length = 0 then "Node2D" else Safe_CPP_Name (Base_Class));
   begin
      Emit_Native_Godot.Output_Directory := To_Unbounded_String (Output_Directory);
      Script_Name := To_Unbounded_String (Source_Name);
      Generated_Class := To_Unbounded_String (Final_Class);
      Generated_Base := To_Unbounded_String (Final_Base);
      Emit_Native_Godot.Resource_Base := To_Unbounded_String (Normalize_Resource_Base (Resource_Base));
      Requested_Build := Build_Mode;
      Current_API := API_Target;

      Begin_Count := 0;
      Tick_Count := 0;
      Paint_Count := 0;
      Key_Count := 0;
      Struct_Count := 0;
      Module_Count := 0;
      Reset_Locals;
      Reset_Globals;
      Global_Decls := To_Unbounded_String ("");
      Global_Bootstrap := To_Unbounded_String ("");
      Struct_Buffer := To_Unbounded_String ("");
      Routine_Buffer := To_Unbounded_String ("");
      Begin_Buffer := To_Unbounded_String ("");
      Tick_Buffer := To_Unbounded_String ("");
      Paint_Buffer := To_Unbounded_String ("");
      Key_Buffer := To_Unbounded_String ("");
      Warning_Buffer := To_Unbounded_String ("");
      Current_Diagnostic := Diagnostic;

      Ada.Directories.Create_Path (Output_Directory);
      Ada.Directories.Create_Path (Ada.Directories.Compose (Output_Directory, "src"));
      Ada.Directories.Create_Path (Ada.Directories.Compose (Output_Directory, "bin"));
   exception
      when others =>
         Diagnostic.Had_Fatal_Error := True;
         Diagnostic.Had_Warnings := True;
   end Initialize_Output;

   procedure Emit_Program
     (Tokens      : in Token_Array;
      Tree        : in Node_Array;
      Root        : in Node_Index;
      Diagnostic  : in out Emitter_Diagnostic_Log)
   is
      pragma Unreferenced (Tokens);
      First : Node_Index := Root;
   begin
      if Root = 0 then
         Add_Warning (0, "null root passed to Emit_Native_Godot", Emitter_Internal_Fallback);
         Diagnostic := Current_Diagnostic;
         return;
      end if;

      Scan_Top_Level (First);
      Emit_Top_Level_Declarations (First);
      Emit_Top_Level_Initializers (First);
      Emit_Top_Level_Routines (First);
      Emit_Buffered_Block_List (Begin_Blocks, Begin_Count, Buf_Begin);
      Emit_Buffered_Block_List (Tick_Blocks, Tick_Count, Buf_Tick);
      Emit_Buffered_Block_List (Paint_Blocks, Paint_Count, Buf_Paint);
      Emit_Buffered_Block_List (Key_Blocks, Key_Count, Buf_Key);

      Write_Runtime_Support;
      Write_Generated_Header;
      Write_Generated_CPP;
      Write_Entry_CPP;
      Write_GDExtension_File;
      Write_SConstruct;
      Write_Build_Readme;
      Write_Manifest;

      Diagnostic := Current_Diagnostic;
   exception
      when E : others =>
         Add_Warning (0, "ALBGD emitter failure: " & Ada.Exceptions.Exception_Message (E),
                      Emitter_Internal_Fallback);
         Current_Diagnostic.Had_Fatal_Error := True;
         Diagnostic := Current_Diagnostic;
   end Emit_Program;

end Emit_Native_Godot;
