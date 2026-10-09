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
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with AST;            use AST;

package body Emit_Native_Python is

   Max_Symbols   : constant Natural := 32_768;
   Max_Structs   : constant Natural := 1024;
   Max_Fields    : constant Natural := 8192;
   Max_Routines  : constant Natural := 4096;
   Max_Params    : constant Natural := 64;
   Max_Firewalls : constant Natural := 256;
   Max_Local_Names : constant Natural := 512;

   type Value_Kind is
     (VK_Unknown,
      VK_Number,
      VK_Boolean,
      VK_String,
      VK_Binary,
      VK_Pure,
      VK_U8,
      VK_U16,
      VK_S8,
      VK_S16,
      VK_U32,
      VK_U64,
      VK_S32,
      VK_S64,
      VK_F64,
      VK_F32,
      VK_HW8,
      VK_HW16,
      VK_HW32,
      VK_Struct);

   type Symbol_Kind is
     (Sym_Scalar,
      Sym_Strict_Array,
      Sym_Slide_Array,
      Sym_Parallel_Field,
      Sym_Temporal,
      Sym_Struct_Var,
      Sym_Const,
      Sym_Param,
      Sym_Firewall,
      Sym_Network,
      Sym_Markov,
      Sym_Neural);

   type Param_Mode_Kind is (Param_In, Param_Out);
   type Dim_List is array (1 .. 4) of Integer;
   type Param_Mode_List is array (1 .. Max_Params) of Param_Mode_Kind;

   type Symbol_Record is record
      Active       : Boolean := False;
      Name         : Unbounded_String := To_Unbounded_String ("");
      Scope        : Unbounded_String := To_Unbounded_String ("");
      Py_Name      : Unbounded_String := To_Unbounded_String ("");
      Struct_Name  : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
      Kind         : Symbol_Kind := Sym_Scalar;
      Rank         : Natural := 0;
      Dims         : Dim_List := (others => 0);
      Capacity     : Integer := 0;
      Active_Size  : Integer := 0;
      History_Size : Integer := 0;
   end record;

   type Struct_Record is record
      Active : Boolean := False;
      Name   : Unbounded_String := To_Unbounded_String ("");
   end record;

   type Field_Record is record
      Active       : Boolean := False;
      Struct_Name  : Unbounded_String := To_Unbounded_String ("");
      Field_Name   : Unbounded_String := To_Unbounded_String ("");
      Py_Field     : Unbounded_String := To_Unbounded_String ("");
      Type_Name    : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
   end record;

   type Routine_Record is record
      Active      : Boolean := False;
      Name        : Unbounded_String := To_Unbounded_String ("");
      Py_Name     : Unbounded_String := To_Unbounded_String ("");
      Param_Count : Natural := 0;
      Param_Modes : Param_Mode_List := (others => Param_In);
   end record;

   type Firewall_Record is record
      Active      : Boolean := False;
      Name        : Unbounded_String := To_Unbounded_String ("");
      Py_Name     : Unbounded_String := To_Unbounded_String ("");
      Reads       : Unbounded_String := To_Unbounded_String ("");
      Writes      : Unbounded_String := To_Unbounded_String ("");
      Deny_All    : Boolean := False;
   end record;

   type Name_List is array (1 .. Max_Local_Names) of Unbounded_String;

   Symbols   : array (1 .. Max_Symbols) of Symbol_Record;
   Structs   : array (1 .. Max_Structs) of Struct_Record;
   Fields    : array (1 .. Max_Fields) of Field_Record;
   Routines  : array (1 .. Max_Routines) of Routine_Record;
   Firewalls : array (1 .. Max_Firewalls) of Firewall_Record;

   Symbol_Count   : Natural := 0;
   Struct_Count   : Natural := 0;
   Field_Count    : Natural := 0;
   Routine_Count  : Natural := 0;
   Firewall_Count : Natural := 0;

   Out_File      : Ada.Text_IO.File_Type;
   File_Open     : Boolean := False;
   Indent_Level  : Natural := 0;
   Current_Module  : Unbounded_String := To_Unbounded_String ("");
   Current_Routine : Unbounded_String := To_Unbounded_String ("");
   Need_Network_Runtime : Boolean := False;
   Need_Pure_Runtime    : Boolean := False;
   Tick_Block    : Node_Index := 0;
   Paint_Block   : Node_Index := 0;
   Key_Block     : Node_Index := 0;

   function Expr (Node_Index_Value : Node_Index) return String;
   function Infer_Expr_Kind (Index : Node_Index) return Value_Kind;
   function Predicate_Name_Expr (Pred_Node : Node_Index) return String;
   function Predicate_Arg1_Expr (Pred_Node : Node_Index) return String;
   procedure Emit_Node (Index : Node_Index);
   procedure Emit_Block (Block_Node : Node_Index);
   procedure Register_Routine_Signature (Index : Node_Index);
   procedure Scan_Features (First : Node_Index);

   function U (S : String) return Unbounded_String renames To_Unbounded_String;

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

   function String_Literal_Value (Token_Index : Natural) return String is
      Raw : constant String := Raw_Lexeme (Token_Index);
   begin
      if Raw'Length >= 2
        and then ((Raw (Raw'First) = '"' and then Raw (Raw'Last) = '"')
                  or else (Raw (Raw'First) = '`' and then Raw (Raw'Last) = '`'))
      then
         return Raw (Raw'First + 1 .. Raw'Last - 1);
      end if;
      return Raw;
   end String_Literal_Value;

   function Upper_Text (S : String) return String is
      R : String (S'Range);
   begin
      for I in S'Range loop
         R (I) := Ada.Characters.Handling.To_Upper (S (I));
      end loop;
      return R;
   end Upper_Text;

   function Safe_Py_Name (Name : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("");
      Text   : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);

      function Reserved (Value : String) return Boolean is
         Upper : constant String := Upper_Text (Value);
      begin
         return
           Upper = "FALSE" or else
           Upper = "NONE" or else
           Upper = "TRUE" or else
           Upper = "AND" or else
           Upper = "AS" or else
           Upper = "ASSERT" or else
           Upper = "BREAK" or else
           Upper = "CLASS" or else
           Upper = "CONTINUE" or else
           Upper = "DEF" or else
           Upper = "DEL" or else
           Upper = "ELIF" or else
           Upper = "ELSE" or else
           Upper = "EXCEPT" or else
           Upper = "FINALLY" or else
           Upper = "FOR" or else
           Upper = "FROM" or else
           Upper = "GLOBAL" or else
           Upper = "IF" or else
           Upper = "IMPORT" or else
           Upper = "IN" or else
           Upper = "IS" or else
           Upper = "LAMBDA" or else
           Upper = "NONLOCAL" or else
           Upper = "NOT" or else
           Upper = "OR" or else
           Upper = "PASS" or else
           Upper = "PRINT" or else
           Upper = "RAISE" or else
           Upper = "RETURN" or else
           Upper = "TRY" or else
           Upper = "WHILE" or else
           Upper = "WITH" or else
           Upper = "YIELD";
      end Reserved;
   begin
      if Text'Length = 0 then
         return "alb_anon";
      end if;

      if Text (Text'First) in '0' .. '9' then
         Append (Result, "alb_");
      end if;

      for I in Text'Range loop
         declare
            Ch : constant Character := Text (I);
         begin
            if (Ch in 'a' .. 'z') or else (Ch in 'A' .. 'Z')
              or else (Ch in '0' .. '9') or else Ch = '_'
            then
               Append (Result, Ch);
            elsif Ch = '.' or else Ch = '#' then
               Append (Result, "_");
            else
               Append (Result, "_");
            end if;
         end;
      end loop;

      declare
         Candidate : constant String := To_String (Result);
      begin
         if Reserved (Candidate) then
            return "alb_" & Candidate;
         end if;
         return Candidate;
      end;
   end Safe_Py_Name;

   function Escape_Py_String (Text : String) return String is
      R : Unbounded_String := U ("'");
   begin
      for I in Text'Range loop
         case Text (I) is
            when ''' =>
               Append (R, "\'");
            when '\' =>
               Append (R, "\\");
            when ASCII.LF =>
               Append (R, "\n");
            when ASCII.CR =>
               null;
            when ASCII.HT =>
               Append (R, "\t");
            when others =>
               Append (R, Text (I));
         end case;
      end loop;
      Append (R, "'");
      return To_String (R);
   end Escape_Py_String;

   function Scoped_Name (Name : String) return String is
   begin
      if Length (Current_Module) = 0 then
         return Safe_Py_Name (Name);
      else
         return Safe_Py_Name (To_String (Current_Module) & "_" & Name);
      end if;
   end Scoped_Name;

   procedure Emit_Indent is
   begin
      for I in 1 .. Indent_Level loop
         Ada.Text_IO.Put (Out_File, "    ");
      end loop;
   end Emit_Indent;

   procedure Line (Text : String := "") is
   begin
      if Text'Length > 0 then
         Emit_Indent;
         Ada.Text_IO.Put_Line (Out_File, Text);
      else
         Ada.Text_IO.New_Line (Out_File);
      end if;
   end Line;

   procedure New_Line_Emit is
   begin
      Ada.Text_IO.New_Line (Out_File);
   end New_Line_Emit;

   procedure Reset_State is
   begin
      for I in Symbols'Range loop
         Symbols (I) := (others => <>);
      end loop;
      for I in Structs'Range loop
         Structs (I) := (others => <>);
      end loop;
      for I in Fields'Range loop
         Fields (I) := (others => <>);
      end loop;
      for I in Routines'Range loop
         Routines (I) := (others => <>);
      end loop;
      for I in Firewalls'Range loop
         Firewalls (I) := (others => <>);
      end loop;

      Symbol_Count := 0;
      Struct_Count := 0;
      Field_Count := 0;
      Routine_Count := 0;
      Firewall_Count := 0;
      Indent_Level := 0;
      Current_Module := U ("");
      Current_Routine := U ("");
      Need_Network_Runtime := False;
      Need_Pure_Runtime := False;
      Tick_Block := 0;
      Paint_Block := 0;
      Key_Block := 0;
   end Reset_State;

   function Type_From_Name (Name : String) return Value_Kind is
      Upper : constant String := Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
   begin
      if Upper = "STRING" then
         return VK_String;
      elsif Upper = "PURE" or else Upper = "RATIONAL" then
         Need_Pure_Runtime := True;
         return VK_Pure;
      elsif Upper = "BOOLEAN" or else Upper = "BOOL" then
         return VK_Boolean;
      elsif Upper = "BINARY" then
         return VK_Binary;
      elsif Upper = "U8" then
         return VK_U8;
      elsif Upper = "U16" then
         return VK_U16;
      elsif Upper = "U32" then
         return VK_U32;
      elsif Upper = "U64" then
         return VK_U64;
      elsif Upper = "U128" or else Upper = "S128" then
         -- Soft: Python int is unbounded; keep as S64 lane metadata.
         return VK_S64;
      elsif Upper = "S8" or else Upper = "I8" or else Upper = "INT8" then
         return VK_S8;
      elsif Upper = "S16" or else Upper = "I16" or else Upper = "INT16" then
         return VK_S16;
      elsif Upper = "S32" or else Upper = "I32" or else Upper = "INT32" then
         return VK_S32;
      elsif Upper = "S64" or else Upper = "I64" or else Upper = "INT64" then
         return VK_S64;
      elsif Upper = "F32" or else Upper = "SINGLE" or else Upper = "FLOAT" then
         return VK_F32;
      elsif Upper = "F64" or else Upper = "REAL" or else Upper = "DOUBLE"
        or else Upper = "NUMBER"
      then
         return VK_F64;
      elsif Upper = "FLOAT2" or else Upper = "F32X2" or else
        Upper = "FLOAT4" or else Upper = "F32X4" or else
        Upper = "MAT2" or else Upper = "MAT2X2" or else
        Upper = "MAT3" or else Upper = "MAT3X3" or else
        Upper = "MAT4" or else Upper = "MAT4X4"
      then
         return VK_Struct;
      elsif Upper = "HW8" then
         return VK_HW8;
      elsif Upper = "HW16" then
         return VK_HW16;
      elsif Upper = "HW32" then
         return VK_HW32;
      elsif Upper = "HW64" then
         return VK_S64;
      elsif Upper = "CHAR" then
         return VK_U8;
      else
         return VK_Unknown;
      end if;
   end Type_From_Name;

   function Type_From_Token (Token_Index : Natural) return Value_Kind is
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return VK_Unknown;
      end if;

      case Tokens (Token_Index).Kind is
         when Tok_I8 =>
            return VK_S8;
         when Tok_I16 =>
            return VK_S16;
         when Tok_I32 =>
            return VK_S32;
         when Tok_I64 =>
            return VK_S64;
         when Tok_String_Type =>
            return VK_String;
         when others =>
            return Type_From_Name (Raw_Lexeme (Token_Index));
      end case;
   end Type_From_Token;

   function Element_Bytes (Kind : Value_Kind) return Integer is
   begin
      case Kind is
         when VK_U8 | VK_S8 | VK_HW8 | VK_Boolean =>
            return 1;
         when VK_U16 | VK_S16 | VK_HW16 =>
            return 2;
         when VK_U32 | VK_S32 | VK_HW32 | VK_F32 =>
            return 4;
         when VK_U64 | VK_S64 | VK_F64 | VK_Pure =>
            return 8;
         when others =>
            return 0;
      end case;
   end Element_Bytes;

   function Default_Value (Kind : Value_Kind; Struct_Name : String := "") return String is
   begin
      case Kind is
         when VK_String | VK_Binary =>
            return "''";
         when VK_Boolean =>
            return "False";
         when VK_Pure =>
            Need_Pure_Runtime := True;
            return "ALB_pure_make(0, 1)";
         when VK_F64 | VK_F32 =>
            return "0.0";
         when VK_Struct =>
            if Struct_Name'Length > 0 then
               declare
                  Shape_Name : constant String :=
                    Upper_Text (Ada.Strings.Fixed.Trim (Struct_Name, Ada.Strings.Both));
               begin
                  if Shape_Name = "FLOAT2" or else Shape_Name = "F32X2" then
                     return "[0.0, 0.0]";
                  elsif Shape_Name = "FLOAT4" or else Shape_Name = "F32X4" then
                     return "[0.0, 0.0, 0.0, 0.0]";
                  elsif Shape_Name = "MAT2" or else Shape_Name = "MAT2X2" then
                     return "[[0.0, 0.0], [0.0, 0.0]]";
                  elsif Shape_Name = "MAT3" or else Shape_Name = "MAT3X3" then
                     return "[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]";
                  elsif Shape_Name = "MAT4" or else Shape_Name = "MAT4X4" then
                     return "[[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]";
                  else
                     return Safe_Py_Name (Struct_Name) & "()";
                  end if;
               end;
            else
               return "None";
            end if;
         when others =>
            return "0";
      end case;
   end Default_Value;

   function Cast_Expr (Kind : Value_Kind; Value_Text : String) return String is
   begin
      case Kind is
         when VK_String | VK_Binary =>
            return "str(" & Value_Text & ")";
         when VK_Boolean =>
            return "bool(" & Value_Text & ")";
         when VK_U8 =>
            return "ALB_u8(" & Value_Text & ")";
         when VK_U16 =>
            return "ALB_u16(" & Value_Text & ")";
         when VK_U32 =>
            return "ALB_u32(" & Value_Text & ")";
         when VK_U64 =>
            return "ALB_u64(" & Value_Text & ")";
         when VK_S8 =>
            return "ALB_i8(" & Value_Text & ")";
         when VK_S16 =>
            return "ALB_i16(" & Value_Text & ")";
         when VK_S32 =>
            return "ALB_i32(" & Value_Text & ")";
         when VK_S64 =>
            return "ALB_i64(" & Value_Text & ")";
         when VK_F64 | VK_F32 =>
            return "float(" & Value_Text & ")";
         when VK_HW8 =>
            return "ALB_hw8(" & Value_Text & ")";
         when VK_HW16 =>
            return "ALB_hw16(" & Value_Text & ")";
         when VK_HW32 =>
            return "ALB_hw32(" & Value_Text & ")";
         when VK_Pure =>
            Need_Pure_Runtime := True;
            return Value_Text;
         when VK_Struct =>
            return Value_Text;
         when VK_Number | VK_Unknown =>
            return "int(" & Value_Text & ")";
      end case;
   end Cast_Expr;

   function Find_Struct (Name : String) return Natural is
   begin
      for I in 1 .. Struct_Count loop
         if Structs (I).Active and then To_String (Structs (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Struct;

   function Find_Field
     (Struct_Name : String;
      Field_Name  : String) return Natural is
   begin
      for I in 1 .. Field_Count loop
         if Fields (I).Active
           and then To_String (Fields (I).Struct_Name) = Struct_Name
           and then To_String (Fields (I).Field_Name) = Field_Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Field;

   function Find_Symbol
     (Scope : String;
      Name  : String) return Natural is
   begin
      for I in reverse 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = Scope
           and then To_String (Symbols (I).Name) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Symbol;

   function Find_Routine (Py_Name : String) return Natural is
   begin
      for I in 1 .. Routine_Count loop
         if Routines (I).Active and then To_String (Routines (I).Py_Name) = Py_Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Routine;

   function Find_Firewall (Name : String) return Natural is
   begin
      for I in 1 .. Firewall_Count loop
         if Firewalls (I).Active and then To_String (Firewalls (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Firewall;

   procedure Register_Symbol
     (Scope       : String;
      Name        : String;
      Py_Name     : String;
      Tag         : Value_Kind;
      Kind        : Symbol_Kind;
      Rank        : Natural := 0;
      Dims        : Dim_List := (others => 0);
      Capacity    : Integer := 0;
      Active_Size : Integer := 0;
      History_Size : Integer := 0;
      Struct_Name : String := "") is
      Existing : constant Natural := Find_Symbol (Scope, Name);
   begin
      if Existing /= 0 then
         return;
      end if;

      if Symbol_Count < Max_Symbols then
         Symbol_Count := Symbol_Count + 1;
         Symbols (Symbol_Count).Active := True;
         Symbols (Symbol_Count).Scope := U (Scope);
         Symbols (Symbol_Count).Name := U (Name);
         Symbols (Symbol_Count).Py_Name := U (Py_Name);
         Symbols (Symbol_Count).Tag := Tag;
         Symbols (Symbol_Count).Kind := Kind;
         Symbols (Symbol_Count).Rank := Rank;
         Symbols (Symbol_Count).Dims := Dims;
         Symbols (Symbol_Count).Capacity := Capacity;
         Symbols (Symbol_Count).Active_Size := Active_Size;
         Symbols (Symbol_Count).History_Size := History_Size;
         Symbols (Symbol_Count).Struct_Name := U (Struct_Name);
      end if;
   end Register_Symbol;

   procedure Register_Struct_From_Node (Index : Node_Index) is
      Node        : constant AST_Node := Tree (Index);
      Name_Node   : constant Node_Index := Node.Left_Child;
      Block_Node  : constant Node_Index := Node.Right_Child;
      Struct_Name : constant String := Safe_Py_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
      Curr        : Node_Index := 0;
   begin
      if Name_Node = 0 or else Find_Struct (Struct_Name) /= 0 then
         return;
      end if;

      if Struct_Count < Max_Structs then
         Struct_Count := Struct_Count + 1;
         Structs (Struct_Count).Active := True;
         Structs (Struct_Count).Name := U (Struct_Name);
      end if;

      if Block_Node > 0 then
         Curr := Tree (Block_Node).Left_Child;
         while Curr > 0 loop
            declare
               Field_Node : constant AST_Node := Tree (Curr);
               Field_Name_Node : constant Node_Index := Field_Node.Left_Child;
               Field_Name : constant String :=
                 (if Field_Name_Node > 0
                  then Safe_Py_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index))
                  else "alb_missing_field");
               Kind : Value_Kind := VK_Number;
            begin
               if Field_Node.Token_Index > 0 then
                  Kind := Type_From_Name (Raw_Lexeme (Field_Node.Token_Index));
               end if;
               if Field_Count < Max_Fields then
                  Field_Count := Field_Count + 1;
                  Fields (Field_Count).Active := True;
                  Fields (Field_Count).Struct_Name := U (Struct_Name);
                  Fields (Field_Count).Field_Name := U (Field_Name);
                  Fields (Field_Count).Py_Field := U (Field_Name);
                  Fields (Field_Count).Type_Name :=
                    (if Field_Node.Token_Index > 0
                     then U (Raw_Lexeme (Field_Node.Token_Index))
                     else U (""));
                  Fields (Field_Count).Tag := Kind;
               end if;
            end;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;
   end Register_Struct_From_Node;

   procedure Register_Routine
     (Name        : String;
      Py_Name     : String;
      Param_Count : Natural;
      Modes       : Param_Mode_List) is
   begin
      if Find_Routine (Py_Name) /= 0 then
         return;
      end if;

      if Routine_Count < Max_Routines then
         Routine_Count := Routine_Count + 1;
         Routines (Routine_Count).Active := True;
         Routines (Routine_Count).Name := U (Name);
         Routines (Routine_Count).Py_Name := U (Py_Name);
         Routines (Routine_Count).Param_Count := Param_Count;
         Routines (Routine_Count).Param_Modes := Modes;
      end if;
   end Register_Routine;

   procedure Register_Routine_Signature (Index : Node_Index) is
      Node        : constant AST_Node := Tree (Index);
      Name_Node   : constant Node_Index := Node.Left_Child;
      Param_Count : Natural := 0;
      Modes       : Param_Mode_List := (others => Param_In);
      Curr_Param  : Node_Index := 0;
      List_Node   : Node_Index := 0;
   begin
      if Name_Node = 0 or else Tree (Name_Node).Token_Index = 0 then
         return;
      end if;

      List_Node := Tree (Name_Node).Right_Child;
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               Param_Count := Param_Count + 1;
               if Param_Count <= Max_Params
                 and then Tree (Curr_Param).Token_Index > 0
                 and then Tokens (Tree (Curr_Param).Token_Index).Kind = Tok_Out
               then
                  Modes (Param_Count) := Param_Out;
               end if;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      declare
         Func_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
         Py_Name   : constant String := Scoped_Name (Func_Name);
      begin
         Register_Routine (Func_Name, Py_Name, Param_Count, Modes);
      end;
   end Register_Routine_Signature;

   function Resolve_Routine_Name (Raw : String) return String is
      Scoped_Py : constant String := Scoped_Name (Raw);
      Plain_Py  : constant String := Safe_Py_Name (Raw);
   begin
      if Find_Routine (Scoped_Py) /= 0 then
         return Scoped_Py;
      elsif Find_Routine (Plain_Py) /= 0 then
         return Plain_Py;
      else
         return "";
      end if;
   end Resolve_Routine_Name;

   function Resolve_Var_Name (Raw : String) return String is
      Idx : Natural := 0;
      Scoped : constant String := Scoped_Name (Raw);
   begin
      if Length (Current_Routine) > 0 then
         Idx := Find_Symbol (To_String (Current_Routine), Raw);
         if Idx /= 0 then
            return To_String (Symbols (Idx).Py_Name);
         end if;
      end if;

      Idx := Find_Symbol ("", Scoped);
      if Idx /= 0 then
         return To_String (Symbols (Idx).Py_Name);
      end if;

      Idx := Find_Symbol ("", Safe_Py_Name (Raw));
      if Idx /= 0 then
         return To_String (Symbols (Idx).Py_Name);
      end if;

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return To_String (Symbols (Idx).Py_Name);
      end if;

      return Safe_Py_Name (Raw);
   end Resolve_Var_Name;

   function Resolve_Symbol (Raw : String) return Symbol_Record is
      Idx : Natural := 0;
      Dummy : Symbol_Record;
   begin
      if Length (Current_Routine) > 0 then
         Idx := Find_Symbol (To_String (Current_Routine), Raw);
         if Idx /= 0 then
            return Symbols (Idx);
         end if;
      end if;

      Idx := Find_Symbol ("", Scoped_Name (Raw));
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      Idx := Find_Symbol ("", Safe_Py_Name (Raw));
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      return Dummy;
   end Resolve_Symbol;

   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String is
      Node       : constant AST_Node := Tree (Node_Index_Value);
      Left_Node  : constant Node_Index := Node.Left_Child;
      Right_Node : constant Node_Index := Node.Right_Child;
   begin
      if Left_Node = 0 or else Right_Node = 0 then
         return "alb_missing_member";
      end if;

      return Safe_Py_Name (Raw_Lexeme (Tree (Left_Node).Token_Index)) & "." &
             Safe_Py_Name (Raw_Lexeme (Tree (Right_Node).Token_Index));
   end Collect_Module_Member_Name;

   function Eval_Static_Int (Index : Node_Index) return Integer is
      Node : AST_Node;
      Tok_Kind : Token_Kind := Tok_Error;
      Left_Val : Integer := 0;
      Right_Val : Integer := 0;
      Text : Unbounded_String := U ("");
   begin
      if Index = 0 then
         return 0;
      end if;

      Node := Tree (Index);
      if Node.Token_Index > 0 then
         Tok_Kind := Tokens (Node.Token_Index).Kind;
         Text := U (Raw_Lexeme (Node.Token_Index));
      end if;

      case Node.Kind is
         when AST_Number_Expr =>
            return Integer'Value (Ada.Strings.Fixed.Trim (To_String (Text), Ada.Strings.Both));
         when AST_Hex_Expr =>
            declare
               T : constant String := To_String (Text);
            begin
               return Integer'Value ("16#" & T (T'First + 1 .. T'Last) & "#");
            end;
         when AST_Bin_Expr =>
            declare
               T : constant String := To_String (Text);
            begin
               return Integer'Value ("2#" & T (T'First + 1 .. T'Last) & "#");
            end;
         when AST_Octal_Expr =>
            declare
               T : constant String := To_String (Text);
            begin
               return Integer'Value ("8#" & T (T'First + 1 .. T'Last) & "#");
            end;
         when AST_Const_Ref =>
            declare
               T    : constant String := To_String (Text);
               Name : constant String := Safe_Py_Name (T (T'First + 1 .. T'Last));
               Idx  : constant Natural := Find_Symbol ("", Name);
            begin
               if Idx /= 0 then
                  return Symbols (Idx).Capacity;
               end if;
               return 0;
            end;
         when AST_Unary_Minus =>
            return -Eval_Static_Int (Node.Left_Child);
         when AST_BinOp =>
            Left_Val := Eval_Static_Int (Node.Left_Child);
            Right_Val := Eval_Static_Int (Node.Right_Child);
            case Tok_Kind is
               when Tok_Plus =>
                  return Left_Val + Right_Val;
               when Tok_Minus =>
                  return Left_Val - Right_Val;
               when Tok_Mul =>
                  return Left_Val * Right_Val;
               when Tok_Div =>
                  if Right_Val = 0 then
                     return 0;
                  end if;
                  return Left_Val / Right_Val;
               when Tok_Mod =>
                  if Right_Val = 0 then
                     return 0;
                  end if;
                  return Left_Val mod Right_Val;
               when Tok_Shl =>
                  return Left_Val * (2 ** Right_Val);
               when Tok_Shr =>
                  return Left_Val / (2 ** Right_Val);
               when others =>
                  return 0;
            end case;
         when others =>
            return 0;
      end case;
   exception
      when others =>
         return 0;
   end Eval_Static_Int;

   function Build_Array_Index
     (Dims       : Dim_List;
      Rank       : Natural;
      Bound_Node : Node_Index) return String
   is
      Bounds : array (1 .. 4) of Unbounded_String := (others => U ("1"));
      Count  : Natural := 0;
      Curr   : Node_Index := Bound_Node;
      Expr_Builder : Unbounded_String := U ("");
   begin
      while Curr > 0 and then Count < 4 loop
         Count := Count + 1;
         Bounds (Count) := U (Expr (Curr));
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      if Rank = 0 then
         return "0";
      elsif Rank = 1 then
         return "(" & To_String (Bounds (1)) & ")";
      else
         Append (Expr_Builder, "(((" & To_String (Bounds (1)) & ") - 1)");
         for I in 2 .. Rank loop
            Append
              (Expr_Builder,
               " * " & Trim_Image (Dims (I)) & " + ((" &
               To_String (Bounds (I)) & ") - 1)");
         end loop;
         Append (Expr_Builder, " + 1)");
         return To_String (Expr_Builder);
      end if;
   end Build_Array_Index;

   function Firewall_Key_For_Node (Target_Node : Node_Index) return String is
      function Symbol_Key (Sym : Symbol_Record; Fallback : String := "") return String is
      begin
         if not Sym.Active then
            return Fallback;
         elsif Sym.Kind = Sym_Param or else To_String (Sym.Scope) /= "" then
            return "";
         else
            return To_String (Sym.Name);
         end if;
      end Symbol_Key;

      Node : constant AST_Node := Tree (Target_Node);
   begin
      if Target_Node = 0 then
         return "";
      elsif Node.Kind = AST_Var_Expr then
         declare
            Raw : constant String := (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
            Sym : constant Symbol_Record := Resolve_Symbol (Raw);
         begin
            return Symbol_Key (Sym, Raw);
         end;
      elsif Node.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (Node.Left_Child);
            Right_Node : constant AST_Node := Tree (Node.Right_Child);
            Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
            Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
         begin
            if Group_Sym.Active then
               return Symbol_Key (Group_Sym, Left_Name & "." & Right_Name);
            elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               return To_String (Left_Sym.Name) & "." & Safe_Py_Name (Right_Name);
            else
               return "";
            end if;
         end;
      else
         return "";
      end if;
   end Firewall_Key_For_Node;

   function Wrap_Firewall_Read
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return Value_Text;
      else
         return "ALB_firewall_read(" & Escape_Py_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Read;

   function Wrap_Firewall_Write
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return Value_Text;
      else
         return "ALB_firewall_write(" & Escape_Py_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Write;

   function Statement_Target_Name
     (Target_Node : Node_Index;
      Assign_Kind : Value_Kind := VK_Unknown) return String is
      pragma Unreferenced (Assign_Kind);
      Node : constant AST_Node := Tree (Target_Node);
      Raw  : constant String := (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
      Sym  : constant Symbol_Record := Resolve_Symbol (Raw);
   begin
      if Target_Node = 0 then
         return "alb_missing_target";
      elsif Node.Kind = AST_Var_Expr then
         if Node.Left_Child > 0
           and then Sym.Active
           and then Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
         then
            return To_String (Sym.Py_Name) &
              "[" & Build_Array_Index (Sym.Dims, Sym.Rank, Node.Left_Child) & "]";
         else
            return Resolve_Var_Name (Raw);
         end if;
      elsif Node.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (Node.Left_Child);
            Right_Node : constant AST_Node := Tree (Node.Right_Child);
            Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
            Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
         begin
            if Left_Node.Kind = AST_Var_Expr and then Left_Node.Left_Child > 0 then
               declare
                  Scoped_Field : constant String := Scoped_Name (Left_Name) & "." & Right_Name;
                  Field_Sym_Id : Natural := Find_Symbol ("", Scoped_Field);
               begin
                  if Field_Sym_Id = 0 then
                     Field_Sym_Id := Find_Symbol ("", Left_Name & "." & Right_Name);
                  end if;

                  if Field_Sym_Id /= 0 then
                     return To_String (Symbols (Field_Sym_Id).Py_Name) &
                       "[" &
                       Build_Array_Index
                         (Symbols (Field_Sym_Id).Dims,
                          Symbols (Field_Sym_Id).Rank,
                          Left_Node.Left_Child) &
                       "]";
                  end if;
               end;
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               return To_String (Left_Sym.Py_Name) & "." & Safe_Py_Name (Right_Name);
            elsif Group_Sym.Active then
               return To_String (Group_Sym.Py_Name);
            else
               return Collect_Module_Member_Name (Target_Node);
            end if;
         end;
      else
         return Expr (Target_Node);
      end if;
   end Statement_Target_Name;

   function Join_Arg_List (Arg_List : Node_Index) return String is
      Args  : Unbounded_String := U ("");
      Curr  : Node_Index := 0;
      First : Boolean := True;
   begin
      if Arg_List > 0 then
         if Tree (Arg_List).Kind = AST_Null then
            return "";
         elsif Tree (Arg_List).Kind = AST_Arg_List then
            Curr := Tree (Arg_List).Left_Child;
         else
            Curr := Arg_List;
         end if;

         while Curr > 0 loop
            if not First then
               Append (Args, ", ");
            end if;
            Append (Args, Expr (Curr));
            First := False;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;

      return To_String (Args);
   end Join_Arg_List;

   function As_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      return "ALB_text(" & Expr (Node_Index_Value) & ")";
   end As_Text_Expr;

   function Predicate_Name_From_Node (Pred_Node : Node_Index) return String is
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
            if Node.Token_Index > 0
              and then Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND"
              and then Node.Left_Child > 0
            then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return Raw_Lexeme (Node.Token_Index);
         when AST_Knows_Fact =>
            if Node.Left_Child > 0 then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return Raw_Lexeme (Node.Token_Index);
         when AST_Func_Call =>
            if Node.Left_Child > 0 then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return "";
         when AST_Var_Expr | AST_Atom | AST_Logic_Var =>
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

   function Predicate_First_Arg_Node (Pred_Node : Node_Index) return Node_Index is
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
         if Node.Token_Index > 0
           and then Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND"
           and then Node.Left_Child > 0
         then
            return Predicate_First_Arg_Node (Node.Left_Child);
         end if;
         return Node.Left_Child;
      elsif Node.Kind in AST_Assert_Stmt | AST_Retract_Stmt then
         return Node.Left_Child;
      elsif Node.Kind = AST_Knows_Fact then
         return 0;
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

   function Predicate_Name_Expr (Pred_Node : Node_Index) return String is
   begin
      return Escape_Py_String (Predicate_Name_From_Node (Pred_Node));
   end Predicate_Name_Expr;

   function Predicate_Arg1_Expr (Pred_Node : Node_Index) return String is
      Arg_Node : constant Node_Index := Predicate_First_Arg_Node (Pred_Node);
   begin
      if Arg_Node > 0 then
         return Expr (Arg_Node);
      else
         return "0";
      end if;
   end Predicate_Arg1_Expr;

   function Infer_Expr_Kind (Index : Node_Index) return Value_Kind is
      Node : AST_Node;
      Sym  : Symbol_Record;
   begin
      if Index = 0 then
         return VK_Unknown;
      end if;

      Node := Tree (Index);
      case Node.Kind is
         when AST_String_Expr =>
            return VK_String;
         when AST_True | AST_False =>
            return VK_Boolean;
         when AST_Var_Expr =>
            if Node.Token_Index > 0 then
               Sym := Resolve_Symbol (Raw_Lexeme (Node.Token_Index));
               if Sym.Active then
                  return Sym.Tag;
               end if;
            end if;
            return VK_Unknown;
         when AST_Temporal_Ref =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               Sym := Resolve_Symbol (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
               if Sym.Active then
                  return Sym.Tag;
               end if;
            end if;
            return VK_Unknown;
         when AST_Cast_Expr | AST_Constructor =>
            if Node.Token_Index > 0 then
               declare
                  Kind : constant Value_Kind := Type_From_Token (Node.Token_Index);
               begin
                  if Kind /= VK_Unknown then
                     return Kind;
                  elsif Find_Struct (Safe_Py_Name (Raw_Lexeme (Node.Token_Index))) /= 0 then
                     return VK_Struct;
                  end if;
               end;
            end if;
            return VK_Unknown;
         when AST_Func_Call =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               declare
                  Raw : constant String := Upper_Text (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
               begin
                  if Raw = "LEFT" or else Raw = "LEFT$"
                    or else Raw = "RIGHT" or else Raw = "RIGHT$"
                    or else Raw = "MID" or else Raw = "MID$"
                    or else Raw = "CONCAT" or else Raw = "TYPEOF"
                    or else Raw = "CHR"
                  then
                     return VK_String;
                  elsif Raw = "PURE" or else Raw = "PURE_ADD" or else Raw = "PURE_SUB"
                    or else Raw = "PURE_MUL" or else Raw = "PURE_DIV"
                  then
                     Need_Pure_Runtime := True;
                     return VK_Pure;
                  elsif Raw = "PURE_NUM" or else Raw = "PURE_DEN" then
                     return VK_S64;
                  elsif Type_From_Name (Raw) /= VK_Unknown then
                     return Type_From_Name (Raw);
                  end if;
               end;
            end if;
            return VK_Unknown;
         when others =>
            return VK_Unknown;
      end case;
   end Infer_Expr_Kind;

   function Expr (Node_Index_Value : Node_Index) return String is
      Node       : AST_Node;
      Tok_Text   : Unbounded_String := U ("");
      Tok_Kind   : Token_Kind := Tok_Error;
      Sym        : Symbol_Record;
   begin
      if Node_Index_Value = 0 then
         return "0";
      end if;

      Node := Tree (Node_Index_Value);
      if Node.Token_Index > 0 then
         Tok_Text := U (Raw_Lexeme (Node.Token_Index));
         Tok_Kind := Tokens (Node.Token_Index).Kind;
      end if;

      case Node.Kind is
         when AST_Number_Expr =>
            return To_String (Tok_Text);
         when AST_Hex_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return "0x" & T (T'First + 1 .. T'Last);
            end;
         when AST_Bin_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return "0b" & T (T'First + 1 .. T'Last);
            end;
         when AST_Octal_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return "0o" & T (T'First + 1 .. T'Last);
            end;
         when AST_String_Expr =>
            return Escape_Py_String (String_Literal_Value (Node.Token_Index));
         when AST_True =>
            return "True";
         when AST_False =>
            return "False";
         when AST_Const_Ref =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return Safe_Py_Name (T (T'First + 1 .. T'Last));
            end;
         when AST_Var_Expr =>
            if Node.Left_Child > 0 then
               Sym := Resolve_Symbol (Raw_Lexeme (Node.Token_Index));
               if Sym.Active
                 and then Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
               then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Sym.Py_Name) &
                     "[" & Build_Array_Index (Sym.Dims, Sym.Rank, Node.Left_Child) & "]");
               end if;
            end if;
            return Wrap_Firewall_Read
              (Node_Index_Value,
               Resolve_Var_Name (Raw_Lexeme (Node.Token_Index)));
         when AST_Member_Expr =>
            declare
               Left_Node  : constant AST_Node := Tree (Node.Left_Child);
               Right_Node : constant AST_Node := Tree (Node.Right_Child);
               Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
               Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
               Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
               Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
            begin
               if Left_Node.Kind = AST_Var_Expr and then Left_Node.Left_Child > 0 then
                  declare
                     Scoped_Field : constant String := Scoped_Name (Left_Name) & "." & Right_Name;
                     Field_Sym_Id : Natural := Find_Symbol ("", Scoped_Field);
                  begin
                     if Field_Sym_Id = 0 then
                        Field_Sym_Id := Find_Symbol ("", Left_Name & "." & Right_Name);
                     end if;

                     if Field_Sym_Id /= 0 then
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           To_String (Symbols (Field_Sym_Id).Py_Name) &
                           "[" &
                           Build_Array_Index
                             (Symbols (Field_Sym_Id).Dims,
                              Symbols (Field_Sym_Id).Rank,
                              Left_Node.Left_Child) &
                           "]");
                     end if;
                  end;
               end if;

               if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Left_Sym.Py_Name) & "." & Safe_Py_Name (Right_Name));
               elsif Group_Sym.Active then
                  return Wrap_Firewall_Read (Node_Index_Value, To_String (Group_Sym.Py_Name));
               else
                  return Collect_Module_Member_Name (Node_Index_Value);
               end if;
            end;
         when AST_Unary_Minus =>
            return "(-(" & Expr (Node.Left_Child) & "))";
         when AST_Not =>
            return "(not (" & Expr (Node.Left_Child) & "))";
         when AST_Key_State =>
            return "ALB_key(" & Expr (Node.Left_Child) & ")";
         when AST_Mouse_X =>
            return "ALB_mouse_x()";
         when AST_Mouse_Y =>
            return "ALB_mouse_y()";
         when AST_Mouse_Wheel =>
            return "0";
         when AST_Mouse_Click =>
            return "ALB_mouse_click(" &
              (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "0") & ")";
         when AST_VMouse_X =>
            return "ALB_mouse_x()";
         when AST_VMouse_Y =>
            return "ALB_mouse_y()";
         when AST_SCREEN_WIDTH =>
            return "ALB_screen_width()";
         when AST_SCREEN_HEIGHT =>
            return "ALB_screen_height()";
         when AST_VIRTUAL_WIDTH =>
            return "ALB_virtual_width()";
         when AST_VIRTUAL_HEIGHT =>
            return "ALB_virtual_height()";
         when AST_Read_Pixel =>
            declare
               X_Node : Node_Index := Node.Left_Child;
               Y_Node : Node_Index := Node.Right_Child;
            begin
               if X_Node > 0 and then Tree (X_Node).Kind = AST_Arg_List then
                  X_Node := Tree (X_Node).Left_Child;
                  Y_Node := (if X_Node > 0 then Tree (X_Node).Next_Sibling else 0);
               end if;
               return "ALB_read_pixel(" & Expr (X_Node) & ", " &
                 (if Y_Node > 0 then Expr (Y_Node) else "0") & ")";
            end;
         when AST_Rnd_Expr =>
            return "ALB_rnd(" & Expr (Node.Left_Child) & ")";
         when AST_Str_Len =>
            return "ALB_len(" & Expr (Node.Left_Child) & ")";
         when AST_Str_Left =>
            return "ALB_left(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")";
         when AST_Str_Right =>
            return "ALB_right(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")";
         when AST_Str_Mid =>
            declare
               Start_Node : constant Node_Index :=
                 (if Node.Right_Child > 0 and then Tree (Node.Right_Child).Kind = AST_Arg_List
                  then Tree (Node.Right_Child).Left_Child
                  else Node.Right_Child);
               Count_Node : constant Node_Index :=
                 (if Start_Node > 0 then Tree (Start_Node).Next_Sibling else 0);
            begin
               return "ALB_mid(" & Expr (Node.Left_Child) & ", " &
                 (if Start_Node > 0 then Expr (Start_Node) else "1") & ", " &
                 (if Count_Node > 0 then Expr (Count_Node) else "0") & ")";
            end;
         when AST_BinOp =>
            declare
               Left_Text  : constant String := Expr (Node.Left_Child);
               Right_Text : constant String := Expr (Node.Right_Child);
            begin
               case Tok_Kind is
                  when Tok_Plus =>
                     return "((" & Left_Text & ") + (" & Right_Text & "))";
                  when Tok_Minus =>
                     return "((" & Left_Text & ") - (" & Right_Text & "))";
                  when Tok_Mul =>
                     return "((" & Left_Text & ") * (" & Right_Text & "))";
                  when Tok_Div =>
                     declare
                        Res_Kind : constant Value_Kind := Infer_Expr_Kind (Node_Index_Value);
                     begin
                        if Res_Kind in VK_F64 | VK_F32 then
                           return "float((" & Left_Text & ") / (" & Right_Text & "))";
                        else
                           return "ALB_div((" & Left_Text & "), (" & Right_Text & "))";
                        end if;
                     end;
                  when Tok_Mod =>
                     return "ALB_mod((" & Left_Text & "), (" & Right_Text & "))";
                  when Tok_Pipe | Tok_Ampersand =>
                     return "ALB_concat(ALB_text(" & Left_Text & "), ALB_text(" & Right_Text & "))";
                  when Tok_Equal | Tok_Assign =>
                     return "((" & Left_Text & ") == (" & Right_Text & "))";
                  when Tok_Not_Equal =>
                     return "((" & Left_Text & ") != (" & Right_Text & "))";
                  when TOK_LESS =>
                     return "((" & Left_Text & ") < (" & Right_Text & "))";
                  when TOK_LESS_EQUAL =>
                     return "((" & Left_Text & ") <= (" & Right_Text & "))";
                  when TOK_GREATER =>
                     return "((" & Left_Text & ") > (" & Right_Text & "))";
                  when TOK_GREATER_EQUAL =>
                     return "((" & Left_Text & ") >= (" & Right_Text & "))";
                  when Tok_And =>
                     return "(int(" & Left_Text & ") & int(" & Right_Text & "))";
                  when Tok_Or =>
                     return "(int(" & Left_Text & ") | int(" & Right_Text & "))";
                  when Tok_Xor =>
                     return "(int(" & Left_Text & ") ^ int(" & Right_Text & "))";
                  when Tok_Shl =>
                     return "(int(" & Left_Text & ") << int(" & Right_Text & "))";
                  when Tok_Shr =>
                     return "(int(" & Left_Text & ") >> int(" & Right_Text & "))";
                  when others =>
                     raise Program_Error with
                       "ALBP: unsupported binary operator " & Token_Kind'Image (Tok_Kind);
               end case;
            end;
         when AST_Temporal_Ref =>
            declare
               Base_Name : constant String := Raw_Lexeme (Tree (Node.Left_Child).Token_Index);
               Py_Base   : constant String := Resolve_Var_Name (Base_Name);
               Sel       : constant Token_Kind := Tokens (Node.Token_Index).Kind;
               TSym      : constant Symbol_Record := Resolve_Symbol (Base_Name);
               Hist      : constant String := Trim_Image (Integer'Max (1, TSym.History_Size));
            begin
               case Sel is
                  when Tok_Now =>
                     return Py_Base;
                  when Tok_Past =>
                     return Py_Base & "_history[(((" & Py_Base & "_head + " & Hist & " - 2) % " & Hist & ") + 1)]";
                  when Tok_Future =>
                     return Py_Base & "_history[(((" & Py_Base & "_head) % " & Hist & ") + 1)]";
                  when Tok_Timeline =>
                     return Py_Base & "_history";
                  when others =>
                     return Py_Base;
               end case;
            end;
         when AST_Cast_Expr =>
            declare
               Kind : constant Value_Kind := Type_From_Token (Node.Token_Index);
            begin
               if Kind = VK_Unknown then
                  return Expr (Node.Left_Child);
               end if;
               return Cast_Expr (Kind, Expr (Node.Left_Child));
            end;
         when AST_Constructor =>
            declare
               Raw  : constant String := Raw_Lexeme (Node.Token_Index);
               Kind : constant Value_Kind := Type_From_Token (Node.Token_Index);
            begin
               if Upper_Text (Raw) = "PURE" or else Upper_Text (Raw) = "RATIONAL" then
                  declare
                     First_Arg : constant Node_Index := Node.Left_Child;
                     Next_Node : constant Node_Index := (if First_Arg /= 0 then Tree (First_Arg).Next_Sibling else 0);
                  begin
                     Need_Pure_Runtime := True;
                     return "ALB_pure_make(" &
                       (if First_Arg /= 0 then Expr (First_Arg) else "0") &
                       ", " &
                       (if Next_Node /= 0 then Expr (Next_Node) else "1") &
                       ")";
                  end;
               elsif Kind /= VK_Unknown then
                  return Cast_Expr (Kind, Expr (Node.Left_Child));
               elsif Find_Struct (Safe_Py_Name (Raw)) /= 0 then
                  return Safe_Py_Name (Raw) & "()";
               else
                  return Expr (Node.Left_Child);
               end if;
            end;
         when AST_Func_Call =>
            declare
               Target_Node : constant Node_Index := Node.Left_Child;
               Arg_List    : constant Node_Index := Node.Right_Child;
               Args_Text   : constant String := Join_Arg_List (Arg_List);
               Target_Name : Unbounded_String := U ("alb_missing_call");
               TNode       : AST_Node;
               Raw         : Unbounded_String := U ("");
               Raw_Upper   : Unbounded_String := U ("");
               Routine_Name : Unbounded_String := U ("");
            begin
               if Target_Node > 0 then
                  TNode := Tree (Target_Node);
                  if TNode.Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
                     Raw := U (Raw_Lexeme (TNode.Token_Index));
                     Raw_Upper := U (Upper_Text (To_String (Raw)));
                     Routine_Name := U (Resolve_Routine_Name (To_String (Raw)));

                     if To_String (Raw_Upper) = "PROVE" then
                        declare
                           First_Arg : Node_Index := 0;
                        begin
                           if Arg_List > 0 and then Tree (Arg_List).Kind = AST_Arg_List then
                              First_Arg := Tree (Arg_List).Left_Child;
                           else
                              First_Arg := Arg_List;
                           end if;
                           return "ALB_rel_has(" & Predicate_Name_Expr (First_Arg) & ", " &
                             Predicate_Arg1_Expr (First_Arg) & ")";
                        end;
                     elsif To_String (Raw_Upper) = "LEFT" or else To_String (Raw_Upper) = "LEFT$" then
                        Target_Name := U ("ALB_left");
                     elsif To_String (Raw_Upper) = "RIGHT" or else To_String (Raw_Upper) = "RIGHT$" then
                        Target_Name := U ("ALB_right");
                     elsif To_String (Raw_Upper) = "MID" or else To_String (Raw_Upper) = "MID$" then
                        Target_Name := U ("ALB_mid");
                     elsif To_String (Raw_Upper) = "LEN" then
                        Target_Name := U ("ALB_len");
                     elsif To_String (Raw_Upper) = "CHR" then
                        Target_Name := U ("ALB_chr");
                     elsif To_String (Raw_Upper) = "ASC" then
                        Target_Name := U ("ALB_asc");
                     elsif To_String (Raw_Upper) = "CONCAT" then
                        Target_Name := U ("ALB_concat");
                     elsif To_String (Raw_Upper) = "RND" then
                        Target_Name := U ("ALB_rnd");
                     elsif To_String (Raw_Upper) = "COLLIDE_RECT" then
                        Target_Name := U ("ALB_collide_rect");
                     elsif To_String (Raw_Upper) = "SIN" then
                        Target_Name := U ("ALB_sin");
                     elsif To_String (Raw_Upper) = "COS" then
                        Target_Name := U ("ALB_cos");
                     elsif To_String (Raw_Upper) = "SQRT" then
                        Target_Name := U ("ALB_sqrt");
                     elsif To_String (Raw_Upper) = "EXP" then
                        Target_Name := U ("ALB_exp");
                     elsif To_String (Raw_Upper) = "PURE" or else To_String (Raw_Upper) = "RATIONAL" then
                        Need_Pure_Runtime := True;
                        Target_Name := U ("ALB_pure_make");
                     elsif To_String (Raw_Upper) = "PURE_NUM" then
                        Need_Pure_Runtime := True;
                        Target_Name := U ("ALB_pure_num");
                     elsif To_String (Raw_Upper) = "PURE_DEN" then
                        Need_Pure_Runtime := True;
                        Target_Name := U ("ALB_pure_den");
                     elsif To_String (Raw_Upper) = "PURE_ADD" then
                        Need_Pure_Runtime := True;
                        Target_Name := U ("ALB_pure_add");
                     elsif To_String (Raw_Upper) = "PURE_SUB" then
                        Need_Pure_Runtime := True;
                        Target_Name := U ("ALB_pure_sub");
                     elsif To_String (Raw_Upper) = "PURE_MUL" then
                        Need_Pure_Runtime := True;
                        Target_Name := U ("ALB_pure_mul");
                     elsif To_String (Raw_Upper) = "PURE_DIV" then
                        Need_Pure_Runtime := True;
                        Target_Name := U ("ALB_pure_div");
                     elsif Type_From_Name (To_String (Raw_Upper)) /= VK_Unknown then
                        Target_Name := U
                          ((case Type_From_Name (To_String (Raw_Upper)) is
                              when VK_U8  => "ALB_u8",
                              when VK_U16 => "ALB_u16",
                              when VK_U32 => "ALB_u32",
                              when VK_U64 => "ALB_u64",
                              when VK_S8  => "ALB_i8",
                              when VK_S16 => "ALB_i16",
                              when VK_S32 => "ALB_i32",
                              when VK_S64 => "ALB_i64",
                              when VK_F64 => "float",
                              when VK_HW8 => "ALB_hw8",
                              when VK_HW16 => "ALB_hw16",
                              when VK_HW32 => "ALB_hw32",
                              when VK_String => "str",
                              when VK_Pure => "ALB_pure_make",
                              when others => Safe_Py_Name (To_String (Raw))));
                     elsif Length (Routine_Name) > 0 then
                        Target_Name := Routine_Name;
                     else
                        Target_Name := U (Safe_Py_Name (To_String (Raw)));
                     end if;
                  elsif TNode.Kind = AST_Member_Expr then
                     Target_Name := U (Collect_Module_Member_Name (Target_Node));
                  else
                     Target_Name := U (Expr (Target_Node));
                  end if;
               end if;
               return To_String (Target_Name) & "(" & Args_Text & ")";
            end;
         when AST_Knows_Query | AST_Query =>
            return "ALB_rel_has(" & Predicate_Name_Expr (Node_Index_Value) & ", " &
              Predicate_Arg1_Expr (Node_Index_Value) & ")";
         when AST_Find_Query =>
            if Node.Token_Index > 0
              and then Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND"
            then
               if Node.Left_Child > 0 then
                  return "ALB_rel_find1(" & Predicate_Name_Expr (Node.Left_Child) & ")";
               else
                  return "0";
               end if;
            else
               return "ALB_rel_has(" & Predicate_Name_Expr (Node_Index_Value) & ", " &
                 Predicate_Arg1_Expr (Node_Index_Value) & ")";
            end if;
         when AST_Findall_Query =>
            return "ALB_rel_findall1(" & Predicate_Name_Expr (Node.Left_Child) & ", " &
              Statement_Target_Name (Node.Right_Child) & ")";
         when AST_File_Open =>
            return "ALB_file_open(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Len =>
            return "ALB_file_len(" & Expr (Node.Left_Child) & ")";
         when AST_File_Seek =>
            return "ALB_file_seek(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Read =>
            return "ALB_file_read(" & Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when others =>
            raise Program_Error with "ALBP: unsupported expression node " & Node_Kind'Image (Node.Kind);
      end case;
   end Expr;

   procedure Emit_Runtime is
   begin
      Line ("# Generated by ALBP - AdaLogic BASIC to Python");
      Line ("# This file is intentionally self-contained for portability.");
      Line ("import copy");
      Line ("import ctypes");
      Line ("import math");
      Line ("import pathlib");
      Line ("import random");
      Line ("import socket");
      Line ("import time");
      New_Line_Emit;

      Line ("ALB_STATE_STACK = []");
      Line ("ALB_FIREWALLS = {}");
      Line ("ALB_FIREWALL_CURRENT = None");
      Line ("ALB_RELATIONS = {}");
      Line ("ALB_RULES = []");
      Line ("ALB_RUNNING = True");
      Line ("ALB_WINDOW_TITLE = ''");
      Line ("ALB_SCREEN_W = 0");
      Line ("ALB_SCREEN_H = 0");
      Line ("ALB_VIRTUAL_W = 0");
      Line ("ALB_VIRTUAL_H = 0");
      Line ("ALB_FRAME_MS = 16");
      Line ("ALB_COLOR_VALUE = 0xFFFFFFFF");
      Line ("ALB_CLEAR_COLOR = 0");
      Line ("ALB_PIXELS = {}");
      Line ("ALB_TEXT_OPS = []");
      Line ("ALB_MOUSE_X_VALUE = 0");
      Line ("ALB_MOUSE_Y_VALUE = 0");
      Line ("ALB_MOUSE_BUTTONS = {}");
      Line ("ALB_KEY_STATES = {}");
      Line ("ALB_ORIGIN_X = 0");
      Line ("ALB_ORIGIN_Y = 0");
      Line ("ALB_ALPHA_CHANNEL = 0");
      Line ("ALB_ALPHA_VALUE = 255");
      Line ("ALB_CLIP_RECT = None");
      Line ("ALB_TK_ROOT = None");
      Line ("ALB_TK_CANVAS = None");
      Line ("ALB_TK_ENABLED = False");
      Line ("ALB_DLL_LIBS = {}");
      Line ("ALB_DLL_FUNCS = {}");
      Line ("def ALB_LOAD_DLL(path):");
      Indent_Level := Indent_Level + 1;
      Line ("candidate = pathlib.Path(path)");
      Line ("if not candidate.is_absolute():");
      Indent_Level := Indent_Level + 1;
      Line ("candidate = pathlib.Path(__file__).resolve().parent / candidate");
      Indent_Level := Indent_Level - 1;
      Line ("key = str(candidate.resolve())");
      Line ("if key not in ALB_DLL_LIBS:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_DLL_LIBS[key] = ctypes.CDLL(key)");
      Indent_Level := Indent_Level - 1;
      Line ("return ALB_DLL_LIBS[key]");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_DLL_FUNC(path, name, arg_count):");
      Indent_Level := Indent_Level + 1;
      Line ("key = (path, name, int(arg_count))");
      Line ("if key not in ALB_DLL_FUNCS:");
      Indent_Level := Indent_Level + 1;
      Line ("func = getattr(ALB_LOAD_DLL(path), name)");
      Line ("func.restype = ctypes.c_int32");
      Line ("func.argtypes = [ctypes.c_int32] * int(arg_count)");
      Line ("ALB_DLL_FUNCS[key] = func");
      Indent_Level := Indent_Level - 1;
      Line ("return ALB_DLL_FUNCS[key]");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_OnTick():");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_OnPaint():");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_OnKey():");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_u8(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(value) & 0xFF");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_u16(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(value) & 0xFFFF");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_u32(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(value) & 0xFFFFFFFF");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_u64(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(value) & 0xFFFFFFFFFFFFFFFF");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_i8(value):");
      Indent_Level := Indent_Level + 1;
      Line ("value = int(value) & 0xFF");
      Line ("return value - 0x100 if value >= 0x80 else value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_i16(value):");
      Indent_Level := Indent_Level + 1;
      Line ("value = int(value) & 0xFFFF");
      Line ("return value - 0x10000 if value >= 0x8000 else value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_i32(value):");
      Indent_Level := Indent_Level + 1;
      Line ("value = int(value) & 0xFFFFFFFF");
      Line ("return value - 0x100000000 if value >= 0x80000000 else value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_i64(value):");
      Indent_Level := Indent_Level + 1;
      Line ("value = int(value) & 0xFFFFFFFFFFFFFFFF");
      Line ("return value - 0x10000000000000000 if value >= 0x8000000000000000 else value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_hw8(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_i8(value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_hw16(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_i16(value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_hw32(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_i32(value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_div(left, right):");
      Indent_Level := Indent_Level + 1;
      Line ("if int(right) == 0:");
      Indent_Level := Indent_Level + 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("if isinstance(left, float) or isinstance(right, float):");
      Indent_Level := Indent_Level + 1;
      Line ("return left / right");
      Indent_Level := Indent_Level - 1;
      Line ("return int(int(left) / int(right))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_mod(left, right):");
      Indent_Level := Indent_Level + 1;
      Line ("if int(right) == 0:");
      Indent_Level := Indent_Level + 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("return int(left) % int(right)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_text(value):");
      Indent_Level := Indent_Level + 1;
      Line ("if value is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return ''");
      Indent_Level := Indent_Level - 1;
      Line ("if isinstance(value, bool):");
      Indent_Level := Indent_Level + 1;
      Line ("return '1' if value else '0'");
      Indent_Level := Indent_Level - 1;
      Line ("if isinstance(value, float) and value.is_integer():");
      Indent_Level := Indent_Level + 1;
      Line ("return str(int(value))");
      Indent_Level := Indent_Level - 1;
      Line ("if isinstance(value, tuple) and len(value) == 2:");
      Indent_Level := Indent_Level + 1;
      Line ("return str(value[0]) + '/' + str(value[1])");
      Indent_Level := Indent_Level - 1;
      Line ("return str(value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_concat(*parts):");
      Indent_Level := Indent_Level + 1;
      Line ("return ''.join(ALB_text(part) for part in parts)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_left(text, count):");
      Indent_Level := Indent_Level + 1;
      Line ("return str(text)[:max(0, int(count))]");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_right(text, count):");
      Indent_Level := Indent_Level + 1;
      Line ("text = str(text)");
      Line ("count = max(0, int(count))");
      Line ("return text[-count:] if count > 0 else ''");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_mid(text, start_pos, count):");
      Indent_Level := Indent_Level + 1;
      Line ("text = str(text)");
      Line ("start_index = max(0, int(start_pos) - 1)");
      Line ("count = max(0, int(count))");
      Line ("return text[start_index:start_index + count]");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_len(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return len(str(value))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_chr(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return chr(int(value) & 0xFF)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_asc(value):");
      Indent_Level := Indent_Level + 1;
      Line ("s = str(value)");
      Line ("return ord(s[0]) & 0xFF if s else 0");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rnd(limit):");
      Indent_Level := Indent_Level + 1;
      Line ("limit = max(1, int(limit))");
      Line ("return random.randrange(limit)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_collide_rect(ax, ay, aw, ah, bx, by, bw, bh):");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if int(ax) < int(bx) + int(bw) and int(ax) + int(aw) > int(bx) and int(ay) < int(by) + int(bh) and int(ay) + int(ah) > int(by) else 0");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_sin(degrees):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(round(math.sin(math.radians(float(degrees))) * 1024))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_cos(degrees):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(round(math.cos(math.radians(float(degrees))) * 1024))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_sqrt(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(math.sqrt(max(0, float(value))))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_exp(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(math.exp(float(value)))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def RND(limit):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_rnd(limit)");
      Indent_Level := Indent_Level - 1;
      Line ("def COLLIDE_RECT(ax, ay, aw, ah, bx, by, bw, bh):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_collide_rect(ax, ay, aw, ah, bx, by, bw, bh)");
      Indent_Level := Indent_Level - 1;
      Line ("def SIN(degrees):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_sin(degrees)");
      Indent_Level := Indent_Level - 1;
      Line ("def COS(degrees):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_cos(degrees)");
      Indent_Level := Indent_Level - 1;
      Line ("def SQRT(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_sqrt(value)");
      Indent_Level := Indent_Level - 1;
      Line ("def EXP(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_exp(value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_color_hex(value=None):");
      Indent_Level := Indent_Level + 1;
      Line ("v = ALB_COLOR_VALUE if value is None else (int(value) & 0xFFFFFFFF)");
      Line ("return '#%06X' % (v & 0xFFFFFF)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_tk_key_code(event):");
      Indent_Level := Indent_Level + 1;
      Line ("key = str(getattr(event, 'keysym', '')).lower()");
      Line ("char = str(getattr(event, 'char', '')).lower()");
      Line ("codes = {'a': 4, 'b': 5, 'c': 6, 'd': 7, 'e': 8, 'f': 9, 'g': 10, 'h': 11, 'i': 12, 'j': 13, 'k': 14, 'l': 15, 'm': 16, 'n': 17, 'o': 18, 'p': 19, 'q': 20, 'r': 21, 's': 22, 't': 23, 'u': 24, 'v': 25, 'w': 26, 'x': 27, 'y': 28, 'z': 29, '1': 30, '2': 31, '3': 32, '4': 33, '5': 34, '6': 35, '7': 36, '8': 37, '9': 38, '0': 39, 'return': 40, 'escape': 41, 'backspace': 42, 'tab': 43, 'space': 44, 'minus': 45, 'equal': 46, 'bracketleft': 47, 'bracketright': 48, 'semicolon': 51, 'quoteleft': 53, 'comma': 54, 'period': 55, 'slash': 56, 'right': 79, 'left': 80, 'down': 81, 'up': 82}");
      Line ("if char in codes:");
      Indent_Level := Indent_Level + 1;
      Line ("return codes[char]");
      Indent_Level := Indent_Level - 1;
      Line ("return codes.get(key, 0)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_tk_bind_events():");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_TK_ROOT is None or ALB_TK_CANVAS is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("def on_key(event, down):");
      Indent_Level := Indent_Level + 1;
      Line ("code = ALB_tk_key_code(event)");
      Line ("if code:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_KEY_STATES[code] = 1 if down else 0");
      Line ("if down:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_OnKey()");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 2;
      Line ("def on_motion(event):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_MOUSE_X_VALUE, ALB_MOUSE_Y_VALUE");
      Line ("ALB_MOUSE_X_VALUE = int(event.x)");
      Line ("ALB_MOUSE_Y_VALUE = int(event.y)");
      Indent_Level := Indent_Level - 1;
      Line ("def on_button(event, down):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_MOUSE_BUTTONS[max(0, int(event.num) - 1)] = 1 if down else 0");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_TK_ROOT.bind('<KeyPress>', lambda event: on_key(event, True))");
      Line ("ALB_TK_ROOT.bind('<KeyRelease>', lambda event: on_key(event, False))");
      Line ("ALB_TK_CANVAS.bind('<Motion>', on_motion)");
      Line ("ALB_TK_CANVAS.bind('<ButtonPress>', lambda event: on_button(event, True))");
      Line ("ALB_TK_CANVAS.bind('<ButtonRelease>', lambda event: on_button(event, False))");
      Line ("ALB_TK_CANVAS.focus_set()");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_tk_close():");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_RUNNING, ALB_TK_ROOT, ALB_TK_CANVAS, ALB_TK_ENABLED");
      Line ("ALB_RUNNING = False");
      Line ("try:");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_TK_ROOT is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_ROOT.destroy()");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("except Exception:");
      Indent_Level := Indent_Level + 1;
      Line ("pass");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_TK_ROOT = None");
      Line ("ALB_TK_CANVAS = None");
      Line ("ALB_TK_ENABLED = False");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_tk_refresh():");
      Indent_Level := Indent_Level + 1;
      Line ("if not ALB_TK_ENABLED or ALB_TK_ROOT is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("try:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_ROOT.update_idletasks()");
      Line ("ALB_TK_ROOT.update()");
      Indent_Level := Indent_Level - 1;
      Line ("except Exception:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_tk_close()");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_create_window(title, width, height):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_WINDOW_TITLE, ALB_SCREEN_W, ALB_SCREEN_H, ALB_VIRTUAL_W, ALB_VIRTUAL_H, ALB_TK_ROOT, ALB_TK_CANVAS, ALB_TK_ENABLED");
      Line ("ALB_WINDOW_TITLE = str(title)");
      Line ("ALB_SCREEN_W = max(1, int(width))");
      Line ("ALB_SCREEN_H = max(1, int(height))");
      Line ("ALB_VIRTUAL_W = ALB_SCREEN_W");
      Line ("ALB_VIRTUAL_H = ALB_SCREEN_H");
      Line ("ALB_PIXELS.clear()");
      Line ("try:");
      Indent_Level := Indent_Level + 1;
      Line ("import tkinter as tk");
      Line ("if ALB_TK_ROOT is None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_ROOT = tk.Tk()");
      Line ("ALB_TK_ROOT.title(ALB_WINDOW_TITLE)");
      Line ("ALB_TK_ROOT.resizable(False, False)");
      Line ("ALB_TK_ROOT.protocol('WM_DELETE_WINDOW', ALB_tk_close)");
      Indent_Level := Indent_Level - 1;
      Line ("else:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_ROOT.title(ALB_WINDOW_TITLE)");
      Indent_Level := Indent_Level - 1;
      Line ("if ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.destroy()");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_TK_CANVAS = tk.Canvas(ALB_TK_ROOT, width=ALB_SCREEN_W, height=ALB_SCREEN_H, bg=ALB_color_hex(ALB_CLEAR_COLOR), highlightthickness=0)");
      Line ("ALB_TK_CANVAS.pack()");
      Line ("ALB_TK_ENABLED = True");
      Line ("ALB_tk_bind_events()");
      Line ("ALB_tk_refresh()");
      Indent_Level := Indent_Level - 1;
      Line ("except Exception:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_ENABLED = False");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_set_fullscreen(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return bool(value)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_set_resizable(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return bool(value)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_set_stretchy(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return bool(value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_tick(milliseconds):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_FRAME_MS");
      Line ("ALB_FRAME_MS = max(1, int(milliseconds))");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_delay(milliseconds):");
      Indent_Level := Indent_Level + 1;
      Line ("ms = max(0, int(milliseconds))");
      Line ("if ms > 0:");
      Indent_Level := Indent_Level + 1;
      Line ("end_time = time.time() + (ms / 1000.0)");
      Line ("while time.time() < end_time:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_tk_refresh()");
      Line ("time.sleep(min(0.03, max(0.0, end_time - time.time())))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_color(value):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_COLOR_VALUE");
      Line ("ALB_COLOR_VALUE = int(value) & 0xFFFFFFFF");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_clear(value):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_CLEAR_COLOR");
      Line ("ALB_CLEAR_COLOR = int(value) & 0xFFFFFFFF");
      Line ("ALB_PIXELS.clear()");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.delete('all')");
      Line ("ALB_TK_CANVAS.configure(bg=ALB_color_hex(ALB_CLEAR_COLOR))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_inside_clip(x, y):");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_CLIP_RECT is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return True");
      Indent_Level := Indent_Level - 1;
      Line ("cx, cy, cw, ch = ALB_CLIP_RECT");
      Line ("return x >= cx and y >= cy and x < cx + cw and y < cy + ch");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_put_pixel(x, y, color=None):");
      Indent_Level := Indent_Level + 1;
      Line ("x = int(x) + ALB_ORIGIN_X");
      Line ("y = int(y) + ALB_ORIGIN_Y");
      Line ("if ALB_SCREEN_W > 0 and (x < 0 or y < 0 or x >= ALB_SCREEN_W or y >= ALB_SCREEN_H):");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("if not ALB_inside_clip(x, y):");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_PIXELS[(x, y)] = ALB_COLOR_VALUE if color is None else (int(color) & 0xFFFFFFFF)");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_rectangle(x, y, x + 1, y + 1, outline='', fill=ALB_color_hex(color))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_read_pixel(x, y):");
      Indent_Level := Indent_Level + 1;
      Line ("x = int(x) + ALB_ORIGIN_X");
      Line ("y = int(y) + ALB_ORIGIN_Y");
      Line ("return int(ALB_PIXELS.get((x, y), ALB_CLEAR_COLOR)) & 0xFFFFFFFF");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_fill_rect(x, y, w, h):");
      Indent_Level := Indent_Level + 1;
      Line ("x = int(x); y = int(y); w = max(0, int(w)); h = max(0, int(h))");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None and w > 0 and h > 0:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_rectangle(x + ALB_ORIGIN_X, y + ALB_ORIGIN_Y, x + ALB_ORIGIN_X + w, y + ALB_ORIGIN_Y + h, outline='', fill=ALB_color_hex())");
      Indent_Level := Indent_Level - 1;
      Line ("for yy in range(y, y + h):");
      Indent_Level := Indent_Level + 1;
      Line ("for xx in range(x, x + w):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(xx, yy)");
      Indent_Level := Indent_Level - 2;
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_draw_rect(x, y, w, h):");
      Indent_Level := Indent_Level + 1;
      Line ("x = int(x); y = int(y); w = max(0, int(w)); h = max(0, int(h))");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None and w > 0 and h > 0:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_rectangle(x + ALB_ORIGIN_X, y + ALB_ORIGIN_Y, x + ALB_ORIGIN_X + w, y + ALB_ORIGIN_Y + h, outline=ALB_color_hex(), fill='')");
      Indent_Level := Indent_Level - 1;
      Line ("for xx in range(x, x + w):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(xx, y)");
      Line ("ALB_put_pixel(xx, y + h - 1)");
      Indent_Level := Indent_Level - 1;
      Line ("for yy in range(y, y + h):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(x, yy)");
      Line ("ALB_put_pixel(x + w - 1, yy)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_draw_line(x1, y1, x2, y2):");
      Indent_Level := Indent_Level + 1;
      Line ("x1 = int(x1); y1 = int(y1); x2 = int(x2); y2 = int(y2)");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_line(x1 + ALB_ORIGIN_X, y1 + ALB_ORIGIN_Y, x2 + ALB_ORIGIN_X, y2 + ALB_ORIGIN_Y, fill=ALB_color_hex())");
      Indent_Level := Indent_Level - 1;
      Line ("dx = abs(x2 - x1); dy = -abs(y2 - y1)");
      Line ("sx = 1 if x1 < x2 else -1");
      Line ("sy = 1 if y1 < y2 else -1");
      Line ("err = dx + dy");
      Line ("while True:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(x1, y1)");
      Line ("if x1 == x2 and y1 == y2:");
      Indent_Level := Indent_Level + 1;
      Line ("break");
      Indent_Level := Indent_Level - 1;
      Line ("e2 = 2 * err");
      Line ("if e2 >= dy:");
      Indent_Level := Indent_Level + 1;
      Line ("err += dy");
      Line ("x1 += sx");
      Indent_Level := Indent_Level - 1;
      Line ("if e2 <= dx:");
      Indent_Level := Indent_Level + 1;
      Line ("err += dx");
      Line ("y1 += sy");
      Indent_Level := Indent_Level - 2;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_draw_circle(x, y, radius):");
      Indent_Level := Indent_Level + 1;
      Line ("x = int(x); y = int(y); radius = max(0, int(radius))");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_oval(x + ALB_ORIGIN_X - radius, y + ALB_ORIGIN_Y - radius, x + ALB_ORIGIN_X + radius, y + ALB_ORIGIN_Y + radius, outline=ALB_color_hex(), fill='')");
      Indent_Level := Indent_Level - 1;
      Line ("cx = radius; cy = 0; err = 0");
      Line ("while cx >= cy:");
      Indent_Level := Indent_Level + 1;
      Line ("for px, py in ((cx, cy), (cy, cx), (-cy, cx), (-cx, cy), (-cx, -cy), (-cy, -cx), (cy, -cx), (cx, -cy)):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(x + px, y + py)");
      Indent_Level := Indent_Level - 1;
      Line ("cy += 1");
      Line ("if err <= 0:");
      Indent_Level := Indent_Level + 1;
      Line ("err += 2 * cy + 1");
      Indent_Level := Indent_Level - 1;
      Line ("if err > 0:");
      Indent_Level := Indent_Level + 1;
      Line ("cx -= 1");
      Line ("err -= 2 * cx + 1");
      Indent_Level := Indent_Level - 2;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_fill_circle(x, y, radius):");
      Indent_Level := Indent_Level + 1;
      Line ("x = int(x); y = int(y); radius = max(0, int(radius))");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_oval(x + ALB_ORIGIN_X - radius, y + ALB_ORIGIN_Y - radius, x + ALB_ORIGIN_X + radius, y + ALB_ORIGIN_Y + radius, outline='', fill=ALB_color_hex())");
      Indent_Level := Indent_Level - 1;
      Line ("r2 = radius * radius");
      Line ("for yy in range(y - radius, y + radius + 1):");
      Indent_Level := Indent_Level + 1;
      Line ("for xx in range(x - radius, x + radius + 1):");
      Indent_Level := Indent_Level + 1;
      Line ("if (xx - x) * (xx - x) + (yy - y) * (yy - y) <= r2:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(xx, yy)");
      Indent_Level := Indent_Level - 3;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_draw_triangle(x1, y1, x2, y2, x3, y3):");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_polygon(int(x1) + ALB_ORIGIN_X, int(y1) + ALB_ORIGIN_Y, int(x2) + ALB_ORIGIN_X, int(y2) + ALB_ORIGIN_Y, int(x3) + ALB_ORIGIN_X, int(y3) + ALB_ORIGIN_Y, outline=ALB_color_hex(), fill='')");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_draw_line(x1, y1, x2, y2)");
      Line ("ALB_draw_line(x2, y2, x3, y3)");
      Line ("ALB_draw_line(x3, y3, x1, y1)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_fill_triangle(x1, y1, x2, y2, x3, y3):");
      Indent_Level := Indent_Level + 1;
      Line ("x1 = int(x1); y1 = int(y1); x2 = int(x2); y2 = int(y2); x3 = int(x3); y3 = int(y3)");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_polygon(x1 + ALB_ORIGIN_X, y1 + ALB_ORIGIN_Y, x2 + ALB_ORIGIN_X, y2 + ALB_ORIGIN_Y, x3 + ALB_ORIGIN_X, y3 + ALB_ORIGIN_Y, outline='', fill=ALB_color_hex())");
      Indent_Level := Indent_Level - 1;
      Line ("min_x = min(x1, x2, x3); max_x = max(x1, x2, x3)");
      Line ("min_y = min(y1, y2, y3); max_y = max(y1, y2, y3)");
      Line ("area = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1)");
      Line ("if area == 0:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_draw_triangle(x1, y1, x2, y2, x3, y3)");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("for yy in range(min_y, max_y + 1):");
      Indent_Level := Indent_Level + 1;
      Line ("for xx in range(min_x, max_x + 1):");
      Indent_Level := Indent_Level + 1;
      Line ("w1 = (x2 - x1) * (yy - y1) - (y2 - y1) * (xx - x1)");
      Line ("w2 = (x3 - x2) * (yy - y2) - (y3 - y2) * (xx - x2)");
      Line ("w3 = (x1 - x3) * (yy - y3) - (y1 - y3) * (xx - x3)");
      Line ("if (w1 >= 0 and w2 >= 0 and w3 >= 0) or (w1 <= 0 and w2 <= 0 and w3 <= 0):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(xx, yy)");
      Indent_Level := Indent_Level - 3;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_plot(x, y):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_put_pixel(x, y)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_draw_text(x, y, text):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TEXT_OPS.append((int(x), int(y), str(text), ALB_COLOR_VALUE))");
      Line ("if ALB_TK_ENABLED and ALB_TK_CANVAS is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_TK_CANVAS.create_text(int(x) + ALB_ORIGIN_X, int(y) + ALB_ORIGIN_Y, text=str(text), fill=ALB_color_hex(), anchor='nw', font=('Consolas', 12, 'bold'))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_set_alpha(channel, value):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_ALPHA_CHANNEL, ALB_ALPHA_VALUE");
      Line ("ALB_ALPHA_CHANNEL = int(channel)");
      Line ("ALB_ALPHA_VALUE = max(0, min(255, int(value)))");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_set_clip(x, y, w, h):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_CLIP_RECT");
      Line ("ALB_CLIP_RECT = (int(x), int(y), max(0, int(w)), max(0, int(h)))");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_set_origin(x, y):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_ORIGIN_X, ALB_ORIGIN_Y");
      Line ("ALB_ORIGIN_X = int(x)");
      Line ("ALB_ORIGIN_Y = int(y)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_poll_console_keys():");
      Indent_Level := Indent_Level + 1;
      Line ("try:");
      Indent_Level := Indent_Level + 1;
      Line ("import msvcrt");
      Indent_Level := Indent_Level - 1;
      Line ("except Exception:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("char_map = {'a': 4, 'b': 5, 'c': 6, 'd': 7, 'e': 8, 'f': 9, 'g': 10, 'h': 11, 'i': 12, 'j': 13, 'k': 14, 'l': 15, 'm': 16, 'n': 17, 'o': 18, 'p': 19, 'q': 20, 'r': 21, 's': 22, 't': 23, 'u': 24, 'v': 25, 'w': 26, 'x': 27, 'y': 28, 'z': 29, '1': 30, '2': 31, '3': 32, '4': 33, '5': 34, '6': 35, '7': 36, '8': 37, '9': 38, '0': 39, ' ': 44, '-': 45, '=': 46, '[': 47, ']': 48, ';': 51, '`': 53, ',': 54, '.': 55, '/': 56}");
      Line ("char_map.update({chr(13): 40, chr(27): 41, chr(8): 42, chr(9): 43, chr(92): 49, chr(39): 52})");
      Line ("while msvcrt.kbhit():");
      Indent_Level := Indent_Level + 1;
      Line ("ch = msvcrt.getwch().lower()");
      Line ("code = char_map.get(ch, 0)");
      Line ("if code:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_KEY_STATES[code] = 1");
      Indent_Level := Indent_Level - 2;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_key(code):");
      Indent_Level := Indent_Level + 1;
      Line ("code = int(code)");
      Line ("ALB_poll_console_keys()");
      Line ("value = int(ALB_KEY_STATES.get(code, 0))");
      Line ("ALB_KEY_STATES[code] = 0");
      Line ("return value");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_mouse_x():");
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_MOUSE_X_VALUE)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_mouse_y():");
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_MOUSE_Y_VALUE)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_mouse_click(button):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_MOUSE_BUTTONS.get(int(button), 0))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_screen_width():");
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_SCREEN_W)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_screen_height():");
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_SCREEN_H)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_virtual_width():");
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_VIRTUAL_W)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_virtual_height():");
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_VIRTUAL_H)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_input(prompt=''):");
      Indent_Level := Indent_Level + 1;
      Line ("try:");
      Indent_Level := Indent_Level + 1;
      Line ("return input(str(prompt))");
      Indent_Level := Indent_Level - 1;
      Line ("except EOFError:");
      Indent_Level := Indent_Level + 1;
      Line ("return ''");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_msg_box(message, title=''):");
      Indent_Level := Indent_Level + 1;
      Line ("text = (str(title) + ': ' if str(title) else '') + str(message)");
      Line ("print(text)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_cease():");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_RUNNING");
      Line ("ALB_RUNNING = False");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_listen():");
      Indent_Level := Indent_Level + 1;
      Line ("if not ALB_TK_ENABLED or ALB_TK_ROOT is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_RUNNING");
      Indent_Level := Indent_Level - 1;
      Line ("while ALB_RUNNING:");
      Indent_Level := Indent_Level + 1;
      Line ("frame_start = time.time()");
      Line ("ALB_tk_refresh()");
      Line ("if not ALB_RUNNING:");
      Indent_Level := Indent_Level + 1;
      Line ("break");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_OnTick()");
      Line ("if not ALB_RUNNING:");
      Indent_Level := Indent_Level + 1;
      Line ("break");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_OnPaint()");
      Line ("ALB_tk_refresh()");
      Line ("sleep_seconds = (max(1, int(ALB_FRAME_MS)) / 1000.0) - (time.time() - frame_start)");
      Line ("if sleep_seconds > 0.0:");
      Indent_Level := Indent_Level + 1;
      Line ("time.sleep(sleep_seconds)");
      Indent_Level := Indent_Level - 2;
      Line ("return ALB_RUNNING");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_play_sound(path):");
      Indent_Level := Indent_Level + 1;
      Line ("return str(path)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_play_music(mml):");
      Indent_Level := Indent_Level + 1;
      Line ("return str(mml)");
      Indent_Level := Indent_Level - 1;
      Line ("def ALB_play_music_from(path):");
      Indent_Level := Indent_Level + 1;
      Line ("p = pathlib.Path(str(path))");
      Line ("return p.read_text(encoding='utf-8') if p.exists() else ''");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_pure_make(num, den):");
      Indent_Level := Indent_Level + 1;
      Line ("num = int(num)");
      Line ("den = int(den)");
      Line ("if den == 0:");
      Indent_Level := Indent_Level + 1;
      Line ("den = 1");
      Indent_Level := Indent_Level - 1;
      Line ("if den < 0:");
      Indent_Level := Indent_Level + 1;
      Line ("num = -num");
      Line ("den = -den");
      Indent_Level := Indent_Level - 1;
      Line ("g = math.gcd(num, den)");
      Line ("if g == 0:");
      Indent_Level := Indent_Level + 1;
      Line ("g = 1");
      Indent_Level := Indent_Level - 1;
      Line ("return (num // g, den // g)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_pure_num(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(value[0])");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_pure_den(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return int(value[1])");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_pure_add(left, right):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_pure_make(left[0] * right[1] + right[0] * left[1], left[1] * right[1])");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_pure_sub(left, right):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_pure_make(left[0] * right[1] - right[0] * left[1], left[1] * right[1])");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_pure_mul(left, right):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_pure_make(left[0] * right[0], left[1] * right[1])");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_pure_div(left, right):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_pure_make(left[0] * right[1], left[1] * right[0])");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_for_range(start_value, end_value, step_value):");
      Indent_Level := Indent_Level + 1;
      Line ("start_value = int(start_value)");
      Line ("end_value = int(end_value)");
      Line ("step_value = int(step_value)");
      Line ("if step_value == 0:");
      Indent_Level := Indent_Level + 1;
      Line ("step_value = 1");
      Indent_Level := Indent_Level - 1;
      Line ("if step_value > 0:");
      Indent_Level := Indent_Level + 1;
      Line ("return range(start_value, end_value + 1, step_value)");
      Indent_Level := Indent_Level - 1;
      Line ("return range(start_value, end_value - 1, step_value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_type_info(tag):");
      Indent_Level := Indent_Level + 1;
      Line ("if tag == 'U8': return (1, False, ALB_u8)");
      Line ("if tag == 'U16': return (2, False, ALB_u16)");
      Line ("if tag == 'U32': return (4, False, ALB_u32)");
      Line ("if tag == 'U64': return (8, False, ALB_u64)");
      Line ("if tag == 'S8': return (1, True, ALB_i8)");
      Line ("if tag == 'S16': return (2, True, ALB_i16)");
      Line ("if tag == 'S32': return (4, True, ALB_i32)");
      Line ("if tag == 'S64': return (8, True, ALB_i64)");
      Line ("if tag == 'HW8': return (1, True, ALB_hw8)");
      Line ("if tag == 'HW16': return (2, True, ALB_hw16)");
      Line ("if tag == 'HW32': return (4, True, ALB_hw32)");
      Line ("raise RuntimeError('Unsupported ALB array type: ' + str(tag))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_write_bytes(path_text, payload):");
      Indent_Level := Indent_Level + 1;
      Line ("path_obj = pathlib.Path(str(path_text))");
      Line ("if path_obj.parent and not path_obj.parent.exists():");
      Indent_Level := Indent_Level + 1;
      Line ("path_obj.parent.mkdir(parents=True, exist_ok=True)");
      Indent_Level := Indent_Level - 1;
      Line ("path_obj.write_bytes(payload)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_flush_text(value, path_text):");
      Indent_Level := Indent_Level + 1;
      Line ("path_obj = pathlib.Path(str(path_text))");
      Line ("if path_obj.parent and not path_obj.parent.exists():");
      Indent_Level := Indent_Level + 1;
      Line ("path_obj.parent.mkdir(parents=True, exist_ok=True)");
      Indent_Level := Indent_Level - 1;
      Line ("with open(path_obj, 'w', encoding='utf-8', newline='') as handle:");
      Indent_Level := Indent_Level + 1;
      Line ("handle.write(str(value))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_load_text(path_text):");
      Indent_Level := Indent_Level + 1;
      Line ("path_obj = pathlib.Path(str(path_text))");
      Line ("if not path_obj.exists():");
      Indent_Level := Indent_Level + 1;
      Line ("return ''");
      Indent_Level := Indent_Level - 1;
      Line ("return path_obj.read_text(encoding='utf-8')");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_flush_array(values, count, path_text, tag):");
      Indent_Level := Indent_Level + 1;
      Line ("size_bytes, signed_value, caster = ALB_type_info(tag)");
      Line ("payload = bytearray()");
      Line ("for index_value in range(1, int(count) + 1):");
      Indent_Level := Indent_Level + 1;
      Line ("payload.extend(int(caster(values[index_value])).to_bytes(size_bytes, 'little', signed=signed_value))");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_write_bytes(path_text, bytes(payload))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_load_array(path_text, values, count, tag):");
      Indent_Level := Indent_Level + 1;
      Line ("size_bytes, signed_value, caster = ALB_type_info(tag)");
      Line ("path_obj = pathlib.Path(str(path_text))");
      Line ("payload = path_obj.read_bytes() if path_obj.exists() else b''");
      Line ("for index_value in range(1, int(count) + 1):");
      Indent_Level := Indent_Level + 1;
      Line ("start = (index_value - 1) * size_bytes");
      Line ("chunk = payload[start:start + size_bytes]");
      Line ("if len(chunk) < size_bytes:");
      Indent_Level := Indent_Level + 1;
      Line ("chunk = chunk + (b'\\x00' * (size_bytes - len(chunk)))");
      Indent_Level := Indent_Level - 1;
      Line ("values[index_value] = caster(int.from_bytes(chunk, 'little', signed=signed_value))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("_ALB_OPEN_FILES = {}");
      Line ("_ALB_FILE_NEXT = 1");
      New_Line_Emit;

      Line ("def ALB_file_open(path_text, mode_text):");
      Indent_Level := Indent_Level + 1;
      Line ("global _ALB_FILE_NEXT");
      Line ("mode_name = str(mode_text).strip().lower()");
      Line ("python_mode = 'rb'");
      Line ("if mode_name in ('write', 'w', 'output'):");
      Indent_Level := Indent_Level + 1;
      Line ("python_mode = 'w+b'");
      Indent_Level := Indent_Level - 1;
      Line ("elif mode_name in ('append', 'a'):");
      Indent_Level := Indent_Level + 1;
      Line ("python_mode = 'a+b'");
      Indent_Level := Indent_Level - 1;
      Line ("path_obj = pathlib.Path(str(path_text))");
      Line ("if path_obj.parent and not path_obj.parent.exists():");
      Indent_Level := Indent_Level + 1;
      Line ("path_obj.parent.mkdir(parents=True, exist_ok=True)");
      Indent_Level := Indent_Level - 1;
      Line ("handle = open(path_obj, python_mode)");
      Line ("file_id = _ALB_FILE_NEXT");
      Line ("_ALB_FILE_NEXT += 1");
      Line ("_ALB_OPEN_FILES[file_id] = handle");
      Line ("return file_id");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_file_len(path_text):");
      Indent_Level := Indent_Level + 1;
      Line ("path_obj = pathlib.Path(str(path_text))");
      Line ("if not path_obj.is_file():");
      Indent_Level := Indent_Level + 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("return path_obj.stat().st_size");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_file_seek(file_id, offset):");
      Indent_Level := Indent_Level + 1;
      Line ("handle = _ALB_OPEN_FILES.get(int(file_id))");
      Line ("if handle is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("handle.seek(int(offset))");
      Line ("return handle.tell()");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_file_read(file_id, count=0):");
      Indent_Level := Indent_Level + 1;
      Line ("handle = _ALB_OPEN_FILES.get(int(file_id))");
      Line ("if handle is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return ''");
      Indent_Level := Indent_Level - 1;
      Line ("amount = int(count)");
      Line ("data = handle.read(amount) if amount > 0 else handle.read()");
      Line ("if isinstance(data, bytes):");
      Indent_Level := Indent_Level + 1;
      Line ("return data.decode('latin1')");
      Indent_Level := Indent_Level - 1;
      Line ("return str(data)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_file_write(file_id, value):");
      Indent_Level := Indent_Level + 1;
      Line ("handle = _ALB_OPEN_FILES.get(int(file_id))");
      Line ("if handle is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("payload = str(value).encode('utf-8')");
      Line ("handle.write(payload)");
      Line ("handle.flush()");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_file_close(file_id):");
      Indent_Level := Indent_Level + 1;
      Line ("handle = _ALB_OPEN_FILES.pop(int(file_id), None)");
      Line ("if handle is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("handle.close()");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_markov_define(states, matrix):");
      Indent_Level := Indent_Level + 1;
      Line ("return {'states': int(states), 'matrix': matrix}");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_markov_predict(model, current_state):");
      Indent_Level := Indent_Level + 1;
      Line ("states = max(1, int(model.get('states', 1)))");
      Line ("matrix = model.get('matrix', [])");
      Line ("index_value = max(1, min(states, int(current_state))) - 1");
      Line ("if index_value >= len(matrix):");
      Indent_Level := Indent_Level + 1;
      Line ("return 1");
      Indent_Level := Indent_Level - 1;
      Line ("row = matrix[index_value]");
      Line ("if not row:");
      Indent_Level := Indent_Level + 1;
      Line ("return 1");
      Indent_Level := Indent_Level - 1;
      Line ("best_index = 0");
      Line ("best_value = float(row[0])");
      Line ("for idx_value in range(1, len(row)):");
      Indent_Level := Indent_Level + 1;
      Line ("if float(row[idx_value]) > best_value:");
      Indent_Level := Indent_Level + 1;
      Line ("best_index = idx_value");
      Line ("best_value = float(row[idx_value])");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return best_index + 1");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_sigmoid(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return 1.0 / (1.0 + math.exp(-float(value)))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_nn_create(name, sizes, activations):");
      Indent_Level := Indent_Level + 1;
      Line ("weights = []");
      Line ("biases = []");
      Line ("for layer_index in range(1, len(sizes)):");
      Indent_Level := Indent_Level + 1;
      Line ("previous_size = int(sizes[layer_index - 1])");
      Line ("current_size = int(sizes[layer_index])");
      Line ("weights.append([[1.0 for _ in range(previous_size)] for _ in range(current_size)])");
      Line ("biases.append([0.0 for _ in range(current_size)])");
      Indent_Level := Indent_Level - 1;
      Line ("return {'name': str(name), 'sizes': list(sizes), 'activations': list(activations), 'weights': weights, 'biases': biases}");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_nn_forward(net, inputs):");
      Indent_Level := Indent_Level + 1;
      Line ("values = [float(item) for item in inputs]");
      Line ("for layer_index in range(len(net['weights'])):");
      Indent_Level := Indent_Level + 1;
      Line ("next_values = []");
      Line ("for neuron_index, weights in enumerate(net['weights'][layer_index]):");
      Indent_Level := Indent_Level + 1;
      Line ("total = net['biases'][layer_index][neuron_index]");
      Line ("for weight_index, weight_value in enumerate(weights):");
      Indent_Level := Indent_Level + 1;
      Line ("total += float(weight_value) * float(values[weight_index])");
      Indent_Level := Indent_Level - 1;
      Line ("if layer_index < len(net['activations']) and str(net['activations'][layer_index]).lower() == 'sigmoid':");
      Indent_Level := Indent_Level + 1;
      Line ("next_values.append(ALB_sigmoid(total))");
      Indent_Level := Indent_Level - 1;
      Line ("else:");
      Indent_Level := Indent_Level + 1;
      Line ("next_values.append(total)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("values = next_values");
      Indent_Level := Indent_Level - 1;
      Line ("return values");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_nn_infer(net, input_values, output_values):");
      Indent_Level := Indent_Level + 1;
      Line ("inputs = [input_values[index_value] for index_value in range(1, len(input_values))]");
      Line ("values = ALB_nn_forward(net, inputs)");
      Line ("for index_value in range(1, min(len(output_values), len(values) + 1)):");
      Indent_Level := Indent_Level + 1;
      Line ("output_values[index_value] = ALB_i64(round(values[index_value - 1]))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_nn_train(net, input_values, target_values, epochs):");
      Indent_Level := Indent_Level + 1;
      Line ("inputs = [float(input_values[index_value]) for index_value in range(1, len(input_values))]");
      Line ("targets = [float(target_values[index_value]) for index_value in range(1, len(target_values))]");
      Line ("for _ in range(max(1, int(epochs))):");
      Indent_Level := Indent_Level + 1;
      Line ("outputs = ALB_nn_forward(net, inputs)");
      Line ("if not outputs:");
      Indent_Level := Indent_Level + 1;
      Line ("continue");
      Indent_Level := Indent_Level - 1;
      Line ("error_value = (targets[0] if targets else 0.0) - outputs[0]");
      Line ("for neuron_index in range(len(net['weights'][-1])):");
      Indent_Level := Indent_Level + 1;
      Line ("for weight_index in range(len(net['weights'][-1][neuron_index])):");
      Indent_Level := Indent_Level + 1;
      Line ("net['weights'][-1][neuron_index][weight_index] += error_value * 0.01 * inputs[weight_index]");
      Indent_Level := Indent_Level - 1;
      Line ("net['biases'][-1][neuron_index] += error_value * 0.01");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_firewall_define(name, reads, writes, deny_all):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_FIREWALLS[str(name)] = {'reads': set(reads), 'writes': set(writes), 'deny_all': bool(deny_all)}");
      Line ("return str(name)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_firewall_enter(name):");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_FIREWALL_CURRENT");
      Line ("ALB_FIREWALL_CURRENT = str(name)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_firewall_leave():");
      Indent_Level := Indent_Level + 1;
      Line ("global ALB_FIREWALL_CURRENT");
      Line ("ALB_FIREWALL_CURRENT = None");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_firewall_check(mode_name, key_name):");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_FIREWALL_CURRENT is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("rules = ALB_FIREWALLS.get(ALB_FIREWALL_CURRENT)");
      Line ("if not rules:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("allowed = rules[mode_name]");
      Line ("if rules['deny_all'] and key_name not in allowed:");
      Indent_Level := Indent_Level + 1;
      Line ("raise RuntimeError('ALB firewall denied ' + mode_name + ' on ' + str(key_name))");
      Indent_Level := Indent_Level - 1;
      Line ("if (not rules['deny_all']) and allowed and key_name not in allowed:");
      Indent_Level := Indent_Level + 1;
      Line ("raise RuntimeError('ALB firewall denied ' + mode_name + ' on ' + str(key_name))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_firewall_read(key_name, value):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_firewall_check('reads', str(key_name))");
      Line ("return value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_firewall_write(key_name, value):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_firewall_check('writes', str(key_name))");
      Line ("return value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_key(value):");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_text(value)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_set(pred, arg1, value=1):");
      Indent_Level := Indent_Level + 1;
      Line ("bucket = ALB_RELATIONS.setdefault(str(pred), {})");
      Line ("bucket[ALB_rel_key(arg1)] = value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_retract(pred, arg1):");
      Indent_Level := Indent_Level + 1;
      Line ("bucket = ALB_RELATIONS.get(str(pred), {})");
      Line ("bucket.pop(ALB_rel_key(arg1), None)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_fact_has(pred, arg1):");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if ALB_rel_key(arg1) in ALB_RELATIONS.get(str(pred), {}) else 0");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_rule_add(head_pred, body_terms):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_RULES.append((str(head_pred), list(body_terms)))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_has(pred, arg1):");
      Indent_Level := Indent_Level + 1;
      Line ("pred = str(pred)");
      Line ("if ALB_rel_fact_has(pred, arg1):");
      Indent_Level := Indent_Level + 1;
      Line ("return 1");
      Indent_Level := Indent_Level - 1;
      Line ("for head_pred, body_terms in ALB_RULES:");
      Indent_Level := Indent_Level + 1;
      Line ("if head_pred != pred:");
      Indent_Level := Indent_Level + 1;
      Line ("continue");
      Indent_Level := Indent_Level - 1;
      Line ("ok = True");
      Line ("for body_pred, use_query_arg, const_arg in body_terms:");
      Indent_Level := Indent_Level + 1;
      Line ("want = arg1 if use_query_arg else const_arg");
      Line ("if not ALB_rel_fact_has(body_pred, want):");
      Indent_Level := Indent_Level + 1;
      Line ("ok = False");
      Line ("break");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("if ok:");
      Indent_Level := Indent_Level + 1;
      Line ("return 1");
      Indent_Level := Indent_Level - 2;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_find1(pred):");
      Indent_Level := Indent_Level + 1;
      Line ("bucket = ALB_RELATIONS.get(str(pred), {})");
      Line ("for key in bucket.keys():");
      Indent_Level := Indent_Level + 1;
      Line ("try:");
      Indent_Level := Indent_Level + 1;
      Line ("return int(key)");
      Indent_Level := Indent_Level - 1;
      Line ("except ValueError:");
      Indent_Level := Indent_Level + 1;
      Line ("return key");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_rel_findall1(pred, target_values):");
      Indent_Level := Indent_Level + 1;
      Line ("bucket = ALB_RELATIONS.get(str(pred), {})");
      Line ("out = 0");
      Line ("for index_value in range(1, len(target_values)):");
      Indent_Level := Indent_Level + 1;
      Line ("target_values[index_value] = 0");
      Indent_Level := Indent_Level - 1;
      Line ("for key in bucket.keys():");
      Indent_Level := Indent_Level + 1;
      Line ("out += 1");
      Line ("if out >= len(target_values):");
      Indent_Level := Indent_Level + 1;
      Line ("break");
      Indent_Level := Indent_Level - 1;
      Line ("try:");
      Indent_Level := Indent_Level + 1;
      Line ("target_values[out] = int(key)");
      Indent_Level := Indent_Level - 1;
      Line ("except ValueError:");
      Indent_Level := Indent_Level + 1;
      Line ("target_values[out] = key");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return out");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_net_define(protocol_name, port_value, buffer_size):");
      Indent_Level := Indent_Level + 1;
      Line ("return {'protocol': str(protocol_name).upper(), 'port': int(port_value), 'buffer_size': int(buffer_size), 'socket': None, 'remote': None}");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_net_listen(link):");
      Indent_Level := Indent_Level + 1;
      Line ("if link.get('socket') is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("if link.get('protocol') != 'UDP':");
      Indent_Level := Indent_Level + 1;
      Line ("raise RuntimeError('ALBP console slice currently supports UDP sockets only.')");
      Indent_Level := Indent_Level - 1;
      Line ("sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)");
      Line ("sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)");
      Line ("sock.bind(('127.0.0.1', int(link['port'])))");
      Line ("sock.settimeout(5.0)");
      Line ("link['socket'] = sock");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_net_receive(link, target_values):");
      Indent_Level := Indent_Level + 1;
      Line ("sock = link.get('socket')");
      Line ("if sock is None:");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_net_listen(link)");
      Line ("sock = link.get('socket')");
      Indent_Level := Indent_Level - 1;
      Line ("payload, remote_addr = sock.recvfrom(int(link.get('buffer_size', 64)))");
      Line ("link['remote'] = remote_addr");
      Line ("for index_value in range(1, len(target_values)):");
      Indent_Level := Indent_Level + 1;
      Line ("target_values[index_value] = payload[index_value - 1] if index_value - 1 < len(payload) else 0");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_net_accept(link):");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_net_listen(link)");
      Line ("return link");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_net_send(link, source_values):");
      Indent_Level := Indent_Level + 1;
      Line ("sock = link.get('socket')");
      Line ("remote_addr = link.get('remote')");
      Line ("if sock is None or remote_addr is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("payload = bytes(ALB_u8(source_values[index_value]) for index_value in range(1, len(source_values)))");
      Line ("sock.sendto(payload, remote_addr)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_net_close(link):");
      Indent_Level := Indent_Level + 1;
      Line ("sock = link.get('socket')");
      Line ("if sock is not None:");
      Indent_Level := Indent_Level + 1;
      Line ("sock.close()");
      Indent_Level := Indent_Level - 1;
      Line ("link['socket'] = None");
      Line ("link['remote'] = None");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
   end Emit_Runtime;

   procedure Emit_Struct_Definitions is
   begin
      for I in 1 .. Struct_Count loop
         if Structs (I).Active then
            declare
               Struct_Name : constant String := To_String (Structs (I).Name);
            begin
               Line ("class " & Struct_Name & ":");
               Indent_Level := Indent_Level + 1;
               Line ("def __init__(self):");
               Indent_Level := Indent_Level + 1;
               for F in 1 .. Field_Count loop
                  if Fields (F).Active and then To_String (Fields (F).Struct_Name) = Struct_Name then
                     Line ("self." & To_String (Fields (F).Py_Field) & " = " &
                           Default_Value
                             (Fields (F).Tag,
                              To_String (Fields (F).Type_Name)));
                  end if;
               end loop;
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
               New_Line_Emit;
            end;
         end if;
      end loop;
   end Emit_Struct_Definitions;

   procedure Emit_State_Routines is
      Any_Global : Boolean := False;
      Globals_Text : Unbounded_String := U ("");
      First_Global : Boolean := True;
   begin
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
         then
            Any_Global := True;
            if not First_Global then
               Append (Globals_Text, ", ");
            end if;
            Append (Globals_Text, To_String (Symbols (I).Py_Name));
            if Symbols (I).Kind = Sym_Slide_Array then
               Append (Globals_Text, ", " & To_String (Symbols (I).Py_Name) & "_active");
            elsif Symbols (I).Kind = Sym_Temporal then
               Append (Globals_Text, ", " & To_String (Symbols (I).Py_Name) & "_history, " &
                       To_String (Symbols (I).Py_Name) & "_head");
            end if;
            First_Global := False;
         end if;
      end loop;

      Line ("def ALB_CAPTURE_STATE():");
      Indent_Level := Indent_Level + 1;
      Line ("state = {}");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
         then
            declare
               Name : constant String := To_String (Symbols (I).Py_Name);
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar | Sym_Struct_Var | Sym_Firewall | Sym_Network | Sym_Markov | Sym_Neural =>
                     Line ("state[" & Escape_Py_String (Name) & "] = copy.deepcopy(" & Name & ")");
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("state[" & Escape_Py_String (Name) & "] = list(" & Name & ")");
                     if Symbols (I).Kind = Sym_Slide_Array then
                        Line ("state[" & Escape_Py_String (Name & "_active") & "] = " & Name & "_active");
                     end if;
                  when Sym_Temporal =>
                     Line ("state[" & Escape_Py_String (Name) & "] = copy.deepcopy(" & Name & ")");
                     Line ("state[" & Escape_Py_String (Name & "_history") & "] = list(" & Name & "_history)");
                     Line ("state[" & Escape_Py_String (Name & "_head") & "] = " & Name & "_head");
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Line ("return state");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("def ALB_RESTORE_STATE(state):");
      Indent_Level := Indent_Level + 1;
      Line ("if state is None:");
      Indent_Level := Indent_Level + 1;
      Line ("return");
      Indent_Level := Indent_Level - 1;
      if Any_Global then
         Line ("global " & To_String (Globals_Text));
      end if;
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
         then
            declare
               Name : constant String := To_String (Symbols (I).Py_Name);
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar | Sym_Struct_Var | Sym_Firewall | Sym_Network | Sym_Markov | Sym_Neural =>
                     Line ("if " & Escape_Py_String (Name) & " in state: " & Name & " = copy.deepcopy(state[" & Escape_Py_String (Name) & "])");
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("if " & Escape_Py_String (Name) & " in state: " & Name & "[:] = list(state[" & Escape_Py_String (Name) & "])");
                     if Symbols (I).Kind = Sym_Slide_Array then
                        Line ("if " & Escape_Py_String (Name & "_active") & " in state: " & Name & "_active = int(state[" & Escape_Py_String (Name & "_active") & "])");
                     end if;
                  when Sym_Temporal =>
                     Line ("if " & Escape_Py_String (Name) & " in state: " & Name & " = copy.deepcopy(state[" & Escape_Py_String (Name) & "])");
                     Line ("if " & Escape_Py_String (Name & "_history") & " in state: " & Name & "_history[:] = list(state[" & Escape_Py_String (Name & "_history") & "])");
                     Line ("if " & Escape_Py_String (Name & "_head") & " in state: " & Name & "_head = int(state[" & Escape_Py_String (Name & "_head") & "])");
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
   end Emit_State_Routines;

   procedure Add_Name
     (Names : in out Name_List;
      Count : in out Natural;
      Name  : String) is
   begin
      if Name'Length = 0 then
         return;
      end if;
      for I in 1 .. Count loop
         if To_String (Names (I)) = Name then
            return;
         end if;
      end loop;
      if Count < Max_Local_Names then
         Count := Count + 1;
         Names (Count) := U (Name);
      end if;
   end Add_Name;

   function Name_In_List
     (Names : Name_List;
      Count : Natural;
      Name  : String) return Boolean is
   begin
      for I in 1 .. Count loop
         if To_String (Names (I)) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Name_In_List;

   procedure Collect_Local_Symbols
     (First : Node_Index;
      Names : in out Name_List;
      Count : in out Natural) is
      Curr : Node_Index := First;
   begin
      while Curr > 0 loop
         declare
            Node : constant AST_Node := Tree (Curr);
         begin
            case Node.Kind is
               when AST_Let_Stmt =>
                  if Node.Left_Child > 0
                    and then Tree (Node.Left_Child).Kind = AST_Var_Expr
                    and then Tree (Node.Left_Child).Left_Child = 0
                    and then Node.Token_Index > 0
                    and then Tree (Node.Left_Child).Token_Index > 0
                  then
                     Add_Name (Names, Count, Safe_Py_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)));
                  end if;
               when AST_Strict_Stmt | AST_Slide_Stmt | AST_Parallel_Decl | AST_Temporal_Decl =>
                  if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
                     Add_Name (Names, Count, Safe_Py_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)));
                  end if;
               when AST_For_Stmt =>
                  if Node.Token_Index > 0 then
                     Add_Name (Names, Count, Safe_Py_Name (Raw_Lexeme (Node.Token_Index)));
                  end if;
                  if Node.Right_Child > 0 and then Tree (Node.Right_Child).Kind = AST_Block_Stmt then
                     Collect_Local_Symbols (Tree (Node.Right_Child).Left_Child, Names, Count);
                  end if;
               when AST_Procedure_Decl | AST_Function_Decl | AST_Module =>
                  null;
               when others =>
                  if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Block_Stmt then
                     Collect_Local_Symbols (Tree (Node.Left_Child).Left_Child, Names, Count);
                  end if;
                  if Node.Right_Child > 0 and then Tree (Node.Right_Child).Kind = AST_Block_Stmt then
                     Collect_Local_Symbols (Tree (Node.Right_Child).Left_Child, Names, Count);
                  end if;
            end case;
         end;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Collect_Local_Symbols;

   procedure Emit_Module_Class (Module_Name : String; Body_Node : Node_Index) is
      Curr : Node_Index := (if Body_Node > 0 then Tree (Body_Node).Left_Child else 0);
      Any  : Boolean := False;
      Saved_Module : constant Unbounded_String := Current_Module;
   begin
      Current_Module := U (Safe_Py_Name (Module_Name));
      Line ("class " & Safe_Py_Name (Module_Name) & ":");
      Indent_Level := Indent_Level + 1;
      while Curr > 0 loop
         if Tree (Curr).Kind in AST_Procedure_Decl | AST_Function_Decl then
            declare
               Name_Node : constant Node_Index := Tree (Curr).Left_Child;
               Member    : constant String := Safe_Py_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Target    : constant String := Resolve_Routine_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
            begin
               Line (Member & " = staticmethod(" & Target & ")");
               Any := True;
            end;
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
      if not Any then
         Line ("pass");
      end if;
      Indent_Level := Indent_Level - 1;
      Current_Module := Saved_Module;
      New_Line_Emit;
   end Emit_Module_Class;

   procedure Emit_Event_Method
     (Name  : String;
      Block : Node_Index) is
      Old_Routine : constant Unbounded_String := Current_Routine;
      Local_Names : Name_List := (others => U (""));
      Local_Count : Natural := 0;
      Globals_Text : Unbounded_String := U ("");
      First_Global : Boolean := True;
   begin
      Current_Routine := U (Name);
      Line ("def " & Name & "():");
      Indent_Level := Indent_Level + 1;

      if Block > 0 and then Tree (Block).Kind = AST_Block_Stmt then
         Collect_Local_Symbols (Tree (Block).Left_Child, Local_Names, Local_Count);
      end if;

      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
           and then not Name_In_List (Local_Names, Local_Count, To_String (Symbols (I).Py_Name))
         then
            if not First_Global then
               Append (Globals_Text, ", ");
            end if;
            Append (Globals_Text, To_String (Symbols (I).Py_Name));
            if Symbols (I).Kind = Sym_Slide_Array then
               Append (Globals_Text, ", " & To_String (Symbols (I).Py_Name) & "_active");
            elsif Symbols (I).Kind = Sym_Temporal then
               Append (Globals_Text, ", " & To_String (Symbols (I).Py_Name) & "_history, " &
                       To_String (Symbols (I).Py_Name) & "_head");
            end if;
            First_Global := False;
         end if;
      end loop;

      if Length (Globals_Text) > 0 then
         Line ("global " & To_String (Globals_Text));
      end if;

      if Block > 0 then
         Emit_Block (Block);
      end if;

      Line ("return");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Current_Routine := Old_Routine;
   end Emit_Event_Method;

   procedure Emit_Event_Methods is
   begin
      Emit_Event_Method ("ALB_OnTick", Tick_Block);
      Emit_Event_Method ("ALB_OnPaint", Paint_Block);
      Emit_Event_Method ("ALB_OnKey", Key_Block);
   end Emit_Event_Methods;

   procedure Emit_Function_Decl
     (Index       : Node_Index;
      Is_Function : Boolean) is
      Node         : constant AST_Node := Tree (Index);
      Name_Node    : constant Node_Index := Node.Left_Child;
      Body_Node    : constant Node_Index := Node.Right_Child;
      Func_Name    : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
      Py_Name      : constant String := Scoped_Name (Func_Name);
      Old_Routine  : constant Unbounded_String := Current_Routine;
      Param_Count  : Natural := 0;
      Modes        : Param_Mode_List := (others => Param_In);
      Curr_Param   : Node_Index := 0;
      First_Param  : Boolean := True;
      List_Node    : Node_Index := 0;
      Bound_Node   : Node_Index := 0;
      Param_Local_Names : Name_List := (others => U (""));
      Param_Local_Count : Natural := 0;
      Local_Names  : Name_List := (others => U (""));
      Local_Count  : Natural := 0;
      Globals_Text : Unbounded_String := U ("");
      First_Global : Boolean := True;
   begin
      if Name_Node = 0 then
         return;
      end if;

      Current_Routine := U (Py_Name);

      Emit_Indent;
      Ada.Text_IO.Put (Out_File, "def " & Py_Name & "(");

      List_Node := Tree (Name_Node).Right_Child;
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Param_Name      : constant String := Raw_Lexeme (Tree (Param_Name_Node).Token_Index);
                  Mode            : constant Param_Mode_Kind :=
                    (if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then Param_Out else Param_In);
                  Decl_Name       : constant String :=
                    (if Mode = Param_Out then "__out_" & Safe_Py_Name (Param_Name) else Safe_Py_Name (Param_Name));
               begin
                  if not First_Param then
                     Ada.Text_IO.Put (Out_File, ", ");
                  end if;
                  Ada.Text_IO.Put (Out_File, Decl_Name);
                  First_Param := False;
                  Param_Count := Param_Count + 1;
                  if Param_Count <= Max_Params then
                     Modes (Param_Count) := Mode;
                  end if;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;
      Ada.Text_IO.Put (Out_File, "):");
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;

      Register_Routine (Func_Name, Py_Name, Param_Count, Modes);

      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         Param_Count := 0;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               Param_Count := Param_Count + 1;
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Type_Node       : constant Node_Index := Tree (Curr_Param).Right_Child;
                  Param_Name      : constant String := Raw_Lexeme (Tree (Param_Name_Node).Token_Index);
                  Param_Kind      : constant Value_Kind :=
                    (if Type_Node > 0 then Type_From_Name (Raw_Lexeme (Tree (Type_Node).Token_Index)) else VK_Number);
                  Mode            : constant Param_Mode_Kind :=
                    (if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then Param_Out else Param_In);
                  Decl_Name       : constant String := Safe_Py_Name (Param_Name);
               begin
                  Add_Name (Param_Local_Names, Param_Local_Count, Decl_Name);
                  Register_Symbol
                    (Scope => Py_Name,
                     Name => Param_Name,
                     Py_Name => Decl_Name,
                     Tag => Param_Kind,
                     Kind => Sym_Param);
                  if Mode = Param_Out then
                     Line (Decl_Name & " = __out_" & Decl_Name & "['value']");
                  end if;
               end;
            elsif Tree (Curr_Param).Kind = AST_Bound_To_Clause then
               Bound_Node := Curr_Param;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Body_Node > 0 and then Tree (Body_Node).Kind = AST_Block_Stmt then
         Collect_Local_Symbols (Tree (Body_Node).Left_Child, Local_Names, Local_Count);
      end if;

      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
           and then not Name_In_List (Local_Names, Local_Count, To_String (Symbols (I).Py_Name))
           and then not Name_In_List (Param_Local_Names, Param_Local_Count, To_String (Symbols (I).Py_Name))
         then
            if not First_Global then
               Append (Globals_Text, ", ");
            end if;
            Append (Globals_Text, To_String (Symbols (I).Py_Name));
            if Symbols (I).Kind = Sym_Slide_Array then
               Append (Globals_Text, ", " & To_String (Symbols (I).Py_Name) & "_active");
            elsif Symbols (I).Kind = Sym_Temporal then
               Append (Globals_Text, ", " & To_String (Symbols (I).Py_Name) & "_history, " &
                       To_String (Symbols (I).Py_Name) & "_head");
            end if;
            First_Global := False;
         end if;
      end loop;

      if Length (Globals_Text) > 0 then
         Line ("global " & To_String (Globals_Text));
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Line ("ALB_firewall_enter(" & Expr (Tree (Bound_Node).Left_Child) & ")");
         Line ("try:");
         Indent_Level := Indent_Level + 1;
      end if;

      Emit_Block (Body_Node);

      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Param_Name : constant String := Safe_Py_Name (Raw_Lexeme (Tree (Param_Name_Node).Token_Index));
               begin
                  if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then
                     Line ("__out_" & Param_Name & "['value'] = " & Param_Name);
                  end if;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if not Is_Function then
         Line ("return");
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Indent_Level := Indent_Level - 1;
         Line ("finally:");
         Indent_Level := Indent_Level + 1;
         Line ("ALB_firewall_leave()");
         Indent_Level := Indent_Level - 1;
      end if;

      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Current_Routine := Old_Routine;
   end Emit_Function_Decl;

   procedure Emit_Call_With_Out
     (Target_Name : String;
      Arg_List    : Node_Index) is
      Routine_Id : constant Natural := Find_Routine (Target_Name);
      Curr       : Node_Index := 0;
      Param_No   : Natural := 0;
      Has_Out    : Boolean := False;
      Args       : array (1 .. Max_Params) of Unbounded_String := (others => U (""));
      Targets    : array (1 .. Max_Params) of Unbounded_String := (others => U (""));
      Call_Text  : Unbounded_String := U ("");
   begin
      if Routine_Id = 0 or else Arg_List = 0 or else Tree (Arg_List).Kind /= AST_Arg_List then
         Line (Target_Name & "(" & Join_Arg_List (Arg_List) & ")");
         return;
      end if;

      Curr := Tree (Arg_List).Left_Child;
      while Curr > 0 and then Param_No < Max_Params loop
         Param_No := Param_No + 1;
         if Routines (Routine_Id).Param_Modes (Param_No) = Param_Out then
            Has_Out := True;
            Args (Param_No) := U ("{'value': None}");
            Targets (Param_No) := U (Statement_Target_Name (Curr));
         else
            Args (Param_No) := U (Expr (Curr));
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      if not Has_Out then
         Line (Target_Name & "(" & Join_Arg_List (Arg_List) & ")");
         return;
      end if;

      for I in 1 .. Param_No loop
         if I > 1 then
            Append (Call_Text, ", ");
         end if;
         Append (Call_Text, To_String (Args (I)));
      end loop;
      Line (Target_Name & "(" & To_String (Call_Text) & ")");

      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line (To_String (Targets (I)) & " = " & To_String (Args (I)) & "['value']");
         end if;
      end loop;
   end Emit_Call_With_Out;

   procedure Emit_Switch_Stmt
     (Expr_Node  : Node_Index;
      First_Case : Node_Index) is
      Switch_Value : constant String := Safe_Py_Name ("alb_switch_" & Trim_Image (Integer (Expr_Node)));
      Curr_Case : Node_Index := First_Case;
      First : Boolean := True;
   begin
      Line (Switch_Value & " = " & Expr (Expr_Node));
      while Curr_Case > 0 loop
         if Tree (Curr_Case).Left_Child = 0 then
            if First then
               Line ("if True:");
            else
               Line ("else:");
            end if;
         else
            declare
               Prefix : constant String := (if First then "if " else "elif ");
            begin
               Line (Prefix & Switch_Value & " == " & Expr (Tree (Curr_Case).Left_Child) & ":");
            end;
         end if;
         Indent_Level := Indent_Level + 1;
         Emit_Block (Tree (Curr_Case).Right_Child);
         Indent_Level := Indent_Level - 1;
         Curr_Case := Tree (Curr_Case).Next_Sibling;
         First := False;
      end loop;
   end Emit_Switch_Stmt;

   procedure Emit_SwapPop
     (Target_Node : Node_Index;
      Count_Node  : Node_Index) is
      Target_AST   : constant AST_Node := Tree (Target_Node);
      Raw_Name     : constant String :=
        (if Target_AST.Token_Index > 0 then Raw_Lexeme (Target_AST.Token_Index) else "");
      Target_Sym   : constant Symbol_Record := Resolve_Symbol (Raw_Name);
      Count_Name   : constant String := Statement_Target_Name (Count_Node);
      Target_Index : constant String :=
        (if Target_AST.Left_Child > 0
         then Build_Array_Index ((others => 0), 1, Target_AST.Left_Child)
         else "1");
      Last_Index   : constant String := Safe_Py_Name ("alb_last_swap_" & Trim_Image (Integer (Target_Node)));
      Emitted_Field : Boolean := False;

      function Matches_Parallel_Group (Full_Name : String) return Boolean is
         Dot_Pos : Natural := 0;
      begin
         if Raw_Name'Length = 0 then
            return False;
         end if;

         for I in reverse Full_Name'Range loop
            if Full_Name (I) = '.' then
               Dot_Pos := I;
               exit;
            end if;
         end loop;

         if Dot_Pos = 0 or else Dot_Pos = Full_Name'First then
            return False;
         end if;

         declare
            Group_Name : constant String := Full_Name (Full_Name'First .. Dot_Pos - 1);
         begin
            return
              Group_Name = Raw_Name
              or else
                (Group_Name'Length > Raw_Name'Length
                 and then
                   Group_Name
                     (Group_Name'Last - Raw_Name'Length + 1 .. Group_Name'Last) =
                   Raw_Name
                 and then
                   Group_Name (Group_Name'Last - Raw_Name'Length) = '_');
         end;
      end Matches_Parallel_Group;
   begin
      Line ("if " & Count_Name & " > 0:");
      Indent_Level := Indent_Level + 1;
      Line (Last_Index & " = " & Count_Name);
      Line ("if " & Target_Index & " != " & Last_Index & ":");
      Indent_Level := Indent_Level + 1;

      if Target_AST.Kind = AST_Var_Expr and then Target_AST.Left_Child > 0 then
         if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array then
            Line (To_String (Target_Sym.Py_Name) & "[" & Target_Index & "] = " &
                  To_String (Target_Sym.Py_Name) & "[" & Last_Index & "]");
            Emitted_Field := True;
         else
            for I in 1 .. Symbol_Count loop
               if Symbols (I).Active and then Symbols (I).Kind = Sym_Parallel_Field then
                  declare
                     Full_Name : constant String := To_String (Symbols (I).Name);
                  begin
                     if Matches_Parallel_Group (Full_Name) then
                        Line (To_String (Symbols (I).Py_Name) & "[" & Target_Index & "] = " &
                              To_String (Symbols (I).Py_Name) & "[" & Last_Index & "]");
                        Emitted_Field := True;
                     end if;
                  end;
               end if;
            end loop;
         end if;
      end if;

      if not Emitted_Field then
         Line ("pass");
      end if;

      Indent_Level := Indent_Level - 1;
      Line (Count_Name & " = " & Count_Name & " - 1");
      Indent_Level := Indent_Level - 1;
   end Emit_SwapPop;

   procedure Emit_Assignment
     (Target_Node : Node_Index;
      Value_Node  : Node_Index;
      Decl_Tag    : Value_Kind;
      Declare_New : Boolean) is
      function Target_Kind return Value_Kind is
         Node : constant AST_Node := Tree (Target_Node);
      begin
         if Target_Node = 0 then
            return Decl_Tag;
         elsif Node.Kind = AST_Var_Expr then
            if Node.Token_Index > 0 then
               declare
                  Sym : constant Symbol_Record := Resolve_Symbol (Raw_Lexeme (Node.Token_Index));
               begin
                  if Sym.Active then
                     return Sym.Tag;
                  end if;
               end;
            end if;
            return Decl_Tag;
         elsif Node.Kind = AST_Member_Expr then
            declare
               Left_Node  : constant AST_Node := Tree (Node.Left_Child);
               Right_Node : constant AST_Node := Tree (Node.Right_Child);
               Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
               Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
               Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
               Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
            begin
               if Group_Sym.Active then
                  return Group_Sym.Tag;
               elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                  declare
                     Field_Id : constant Natural := Find_Field (To_String (Left_Sym.Struct_Name), Safe_Py_Name (Right_Name));
                  begin
                     if Field_Id /= 0 then
                        return Fields (Field_Id).Tag;
                     end if;
                  end;
               end if;
            end;
            return Decl_Tag;
         else
            return Decl_Tag;
         end if;
      end Target_Kind;

      Actual_Tag   : constant Value_Kind := Target_Kind;
      Target_Name  : constant String := Statement_Target_Name (Target_Node, Actual_Tag);
      Base_Value   : constant String :=
        (if Value_Node > 0 then Cast_Expr (Actual_Tag, Expr (Value_Node))
         else Default_Value (Actual_Tag));
      Value_Text   : constant String := Wrap_Firewall_Write (Target_Node, Base_Value);
   begin
      if Declare_New then
         Line (Target_Name & " = " & Value_Text);
      else
         Line (Target_Name & " = " & Value_Text);
      end if;
   end Emit_Assignment;

   procedure Emit_Block (Block_Node : Node_Index) is
      Curr : Node_Index := 0;
   begin
      if Block_Node = 0 then
         return;
      elsif Tree (Block_Node).Kind = AST_Block_Stmt then
         Curr := Tree (Block_Node).Left_Child;
      else
         Curr := Block_Node;
      end if;

      declare
         Pass_Curr : Node_Index := Curr;
      begin
         while Pass_Curr > 0 loop
            if Tree (Pass_Curr).Kind = AST_Procedure_Decl then
               Emit_Function_Decl (Pass_Curr, False);
            elsif Tree (Pass_Curr).Kind = AST_Function_Decl then
               Emit_Function_Decl (Pass_Curr, True);
            end if;
            Pass_Curr := Tree (Pass_Curr).Next_Sibling;
         end loop;
      end;

      while Curr > 0 loop
         if Tree (Curr).Kind not in AST_Procedure_Decl | AST_Function_Decl then
            Emit_Node (Curr);
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Block;

   procedure Scan_Features (First : Node_Index) is
      Curr : Node_Index := First;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Struct_Decl =>
               Register_Struct_From_Node (Curr);
            when AST_Const_Decl =>
               declare
                  Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                  Value_Node : constant Node_Index := Tree (Curr).Right_Child;
                  Raw_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
                  Py_Name : constant String := Safe_Py_Name (Raw_Name (Raw_Name'First + 1 .. Raw_Name'Last));
               begin
                  Register_Symbol ("", Py_Name, Py_Name, VK_Number, Sym_Const,
                                   Capacity => Eval_Static_Int (Value_Node));
               end;
            when AST_Module =>
               declare
                  Name_Node    : constant Node_Index := Tree (Curr).Left_Child;
                  Saved_Module : constant Unbounded_String := Current_Module;
               begin
                  if Name_Node > 0 and then Tree (Name_Node).Token_Index > 0 then
                     Current_Module := U (Safe_Py_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Scan_Features (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;
            when AST_On_Block =>
               if Tree (Curr).Token_Index > 0 then
                  case Tokens (Tree (Curr).Token_Index).Kind is
                     when Tok_Tick =>
                        Tick_Block := Tree (Curr).Left_Child;
                     when Tok_Paint =>
                        Paint_Block := Tree (Curr).Left_Child;
                     when Tok_Key =>
                        Key_Block := Tree (Curr).Left_Child;
                     when others =>
                        null;
                  end case;
               end if;
               Scan_Features (Tree (Curr).Left_Child);
            when AST_Procedure_Decl | AST_Function_Decl =>
               Register_Routine_Signature (Curr);
            when AST_Import_DLL =>
               if Tree (Curr).Left_Child > 0 then
                  Register_Routine_Signature (Tree (Curr).Left_Child);
               end if;
            when AST_Strict_Stmt =>
               declare
                  Target_Node : constant Node_Index := Tree (Curr).Left_Child;
                  Rank        : Natural := 0;
                  Dims        : Dim_List := (others => 0);
                  Capacity    : Integer := 1;
                  Dim_Node    : Node_Index := Tree (Curr).Right_Child;
               begin
                  if Target_Node > 0 and then Tree (Target_Node).Token_Index > 0 then
                     while Dim_Node > 0 and then Rank < 4 loop
                        Rank := Rank + 1;
                        Dims (Rank) := Eval_Static_Int (Dim_Node);
                        Dim_Node := Tree (Dim_Node).Next_Sibling;
                     end loop;
                     for I in 1 .. Rank loop
                        Capacity := Capacity * Integer'Max (1, Dims (I));
                     end loop;
                     declare
                        Raw_Name : constant String := Raw_Lexeme (Tree (Target_Node).Token_Index);
                        Py_Name  : constant String := Scoped_Name (Raw_Name);
                        Tag      : constant Value_Kind :=
                          (if Tree (Target_Node).Right_Child > 0
                           then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                           else VK_Number);
                     begin
                        Register_Symbol ("", Py_Name, Py_Name, Tag, Sym_Strict_Array, Rank, Dims, Capacity);
                     end;
                  end if;
               end;
            when AST_Slide_Stmt =>
               declare
                  Target_Node : constant Node_Index := Tree (Curr).Left_Child;
                  Capacity    : constant Integer := Eval_Static_Int (Tree (Curr).Right_Child);
               begin
                  if Target_Node > 0 and then Tree (Target_Node).Token_Index > 0 then
                     declare
                        Raw_Name : constant String := Raw_Lexeme (Tree (Target_Node).Token_Index);
                        Py_Name  : constant String := Scoped_Name (Raw_Name);
                        Tag      : constant Value_Kind :=
                          (if Tree (Target_Node).Right_Child > 0
                           then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                           else VK_Number);
                     begin
                         Register_Symbol
                           ("", Py_Name, Py_Name, Tag, Sym_Slide_Array, 1,
                            (1 => Capacity, others => 0), Capacity,
                            Active_Size =>
                              (if Tree (Tree (Curr).Right_Child).Next_Sibling > 0
                               then Eval_Static_Int (Tree (Tree (Curr).Right_Child).Next_Sibling)
                               else Capacity));
                     end;
                  end if;
               end;
            when AST_Parallel_Decl =>
               declare
                  Target_Node : constant Node_Index := Tree (Curr).Left_Child;
                  Rank        : Natural := 0;
                  Dims        : Dim_List := (others => 0);
                  Capacity    : Integer := 1;
                  Dim_Node    : Node_Index := 0;
                  Curr_Field  : Node_Index := 0;
               begin
                  if Target_Node > 0 and then Tree (Target_Node).Token_Index > 0 then
                     Dim_Node := Tree (Target_Node).Left_Child;
                     while Dim_Node > 0 and then Rank < 4 loop
                        Rank := Rank + 1;
                        Dims (Rank) := Eval_Static_Int (Dim_Node);
                        Dim_Node := Tree (Dim_Node).Next_Sibling;
                     end loop;
                     if Rank > 0 then
                        Capacity := Integer'Max (1, Dims (1));
                     end if;

                     declare
                        Raw_Name : constant String := Raw_Lexeme (Tree (Target_Node).Token_Index);
                        Py_Name  : constant String := Scoped_Name (Raw_Name);
                     begin
                        Curr_Field := Tree (Curr).Right_Child;
                        while Curr_Field > 0 loop
                           declare
                              Field_Name_Node : constant Node_Index := Tree (Curr_Field).Left_Child;
                              Field_Name      : constant String :=
                                (if Field_Name_Node > 0 and then Tree (Field_Name_Node).Token_Index > 0
                                 then Raw_Lexeme (Tree (Field_Name_Node).Token_Index)
                                 else "");
                              Field_Py        : constant String :=
                                Safe_Py_Name (Py_Name & "_" & Field_Name);
                              Field_Tag       : constant Value_Kind :=
                                (if Field_Name_Node > 0 and then Tree (Field_Name_Node).Right_Child > 0
                                 then Type_From_Name (Raw_Lexeme (Tree (Tree (Field_Name_Node).Right_Child).Token_Index))
                                 else VK_Number);
                           begin
                              Register_Symbol
                                ("",
                                 Py_Name & "." & Field_Name,
                                 Field_Py,
                                 Field_Tag,
                                 Sym_Parallel_Field,
                                 Rank,
                                 Dims,
                                 Capacity);
                           end;
                           Curr_Field := Tree (Curr_Field).Next_Sibling;
                        end loop;
                     end;
                  end if;
               end;
            when AST_Let_Stmt =>
               declare
                  Target_Node : constant Node_Index := Tree (Curr).Left_Child;
               begin
                  if Target_Node > 0
                    and then Tree (Target_Node).Kind = AST_Var_Expr
                    and then Tree (Target_Node).Left_Child = 0
                    and then Tree (Target_Node).Token_Index > 0
                  then
                     declare
                        Raw_Name : constant String := Raw_Lexeme (Tree (Target_Node).Token_Index);
                        Py_Name  : constant String := Scoped_Name (Raw_Name);
                        Tag      : Value_Kind := Type_From_Token (Tree (Curr).Token_Index);
                        Struct_Name_Text : constant String :=
                          (if Tree (Curr).Token_Index > 0 then Raw_Lexeme (Tree (Curr).Token_Index) else "");
                     begin
                        if Tag = VK_Unknown then
                           if Struct_Name_Text'Length > 0
                             and then Find_Struct (Safe_Py_Name (Struct_Name_Text)) /= 0
                           then
                              Tag := VK_Struct;
                           else
                              Tag := VK_Number;
                           end if;
                        end if;
                        Register_Symbol
                          ("",
                           Py_Name,
                           Py_Name,
                           Tag,
                           (if Tag = VK_Struct then Sym_Struct_Var else Sym_Scalar),
                           Struct_Name => (if Tag = VK_Struct then Struct_Name_Text else ""));
                     end;
                  end if;
               end;
            when AST_Memory_Firewall_Decl | AST_Network_Socket_Decl =>
               Need_Network_Runtime := True;
            when others =>
               if Tree (Curr).Left_Child > 0 then
                  Scan_Features (Tree (Curr).Left_Child);
               end if;
               if Tree (Curr).Right_Child > 0 then
                  Scan_Features (Tree (Curr).Right_Child);
               end if;
         end case;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Scan_Features;

   procedure Emit_Import_DLL (Index : Node_Index) is
      Node         : constant AST_Node := Tree (Index);
      Decl_Node    : constant Node_Index := Node.Left_Child;
      Name_Node    : Node_Index := 0;
      Args_Node    : Node_Index := 0;
      Curr_Param   : Node_Index := 0;
      Path_Node    : constant Node_Index := Node.Right_Child;
      Func_Name    : Unbounded_String := U ("");
      Py_Name      : Unbounded_String := U ("");
      Path_Text    : Unbounded_String := U ("");
      Call_Args    : Unbounded_String := U ("");
      Param_Count  : Natural := 0;
      First_Param  : Boolean := True;
   begin
      if Decl_Node = 0 or else Path_Node = 0 then
         return;
      end if;

      Name_Node := Tree (Decl_Node).Left_Child;
      if Name_Node = 0 then
         return;
      end if;

      Func_Name := U (Raw_Lexeme (Tree (Name_Node).Token_Index));
      Py_Name := U (Scoped_Name (To_String (Func_Name)));
      Path_Text := U (String_Literal_Value (Tree (Path_Node).Token_Index));
      Args_Node := Tree (Name_Node).Right_Child;

      Emit_Indent;
      Ada.Text_IO.Put (Out_File, "def " & To_String (Py_Name) & "(");
      if Args_Node > 0 and then Tree (Args_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (Args_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl
              and then Tree (Curr_Param).Left_Child > 0
            then
               declare
                  Param_Name : constant String :=
                    Safe_Py_Name (Raw_Lexeme (Tree (Tree (Curr_Param).Left_Child).Token_Index));
               begin
                  if not First_Param then
                     Ada.Text_IO.Put (Out_File, ", ");
                     Append (Call_Args, ", ");
                  end if;
                  Ada.Text_IO.Put (Out_File, Param_Name);
                  Append (Call_Args, "int(" & Param_Name & ")");
                  First_Param := False;
                  Param_Count := Param_Count + 1;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;
      Ada.Text_IO.Put (Out_File, "):");
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;
      Line ("return int(ALB_DLL_FUNC(" & Escape_Py_String (To_String (Path_Text)) & ", " &
            Escape_Py_String (To_String (Func_Name)) & ", " & Trim_Image (Param_Count) &
            ")(" & To_String (Call_Args) & "))");
      Indent_Level := Indent_Level - 1;
   end Emit_Import_DLL;

   procedure Emit_Node (Index : Node_Index) is
      Node        : constant AST_Node := Tree (Index);
      Target_Node : Node_Index := 0;
      Value_Node  : Node_Index := 0;
      Raw_Name    : Unbounded_String := U ("");
      Py_Name     : Unbounded_String := U ("");
      Tag         : Value_Kind := VK_Number;
      Rank        : Natural := 0;
      Dims        : Dim_List := (others => 0);
      Capacity    : Integer := 0;
   begin
      case Node.Kind is
         when AST_Block_Stmt =>
            Emit_Block (Index);
         when AST_Version | AST_DeclareModule | AST_Import | AST_Import_C | AST_Include_Stmt | AST_Range_Type_Decl =>
            null;
         when AST_Import_DLL =>
            Emit_Import_DLL (Index);
         when AST_Module =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Body_Node : constant Node_Index := Node.Right_Child;
               Saved     : constant Unbounded_String := Current_Module;
               Module_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
            begin
               Current_Module := U (Safe_Py_Name (Module_Name));
               Emit_Block (Body_Node);
               Current_Module := Saved;
               Emit_Module_Class (Module_Name, Body_Node);
            end;
         when AST_Const_Decl =>
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               declare
                  R : constant String := To_String (Raw_Name);
               begin
                  Py_Name := U (Safe_Py_Name (R (R'First + 1 .. R'Last)));
               end;
               Line (To_String (Py_Name) & " = " & Expr (Value_Node));
            end if;
         when AST_Struct_Decl =>
            null;
         when AST_Strict_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Py_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0 then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index)) else VK_Number);
               declare
                  Curr : Node_Index := Node.Right_Child;
               begin
                  while Curr > 0 and then Rank < 4 loop
                     Rank := Rank + 1;
                     Dims (Rank) := Eval_Static_Int (Curr);
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end;
               Capacity := 1;
               for I in 1 .. Rank loop
                  Capacity := Capacity * Integer'Max (1, Dims (I));
               end loop;
               Register_Symbol ("", To_String (Py_Name), To_String (Py_Name), Tag, Sym_Strict_Array, Rank, Dims, Capacity);
               Line (To_String (Py_Name) & " = [" & Default_Value (Tag) & " for _ in range(" & Trim_Image (Capacity + 1) & ")]");
            end if;
         when AST_Slide_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Py_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0 then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index)) else VK_Number);
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (Py_Name), To_String (Py_Name), Tag, Sym_Slide_Array, 1, (1 => Capacity, others => 0), Capacity,
                                Active_Size => (if Tree (Node.Right_Child).Next_Sibling > 0 then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling) else Capacity));
               Line (To_String (Py_Name) & " = [" & Default_Value (Tag) & " for _ in range(" & Trim_Image (Capacity + 1) & ")]");
               Line (To_String (Py_Name) & "_active = " & Trim_Image ((if Tree (Node.Right_Child).Next_Sibling > 0 then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling) else Capacity)));
            end if;
         when AST_Parallel_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Py_Name := U (Scoped_Name (To_String (Raw_Name)));
               declare
                  Curr_Bound : Node_Index := Tree (Target_Node).Left_Child;
               begin
                  while Curr_Bound > 0 and then Rank < 4 loop
                     Rank := Rank + 1;
                     Dims (Rank) := Eval_Static_Int (Curr_Bound);
                     Curr_Bound := Tree (Curr_Bound).Next_Sibling;
                  end loop;
               end;
               Capacity := Integer'Max (1, Dims (1));
               declare
                  Curr_Field : Node_Index := Node.Right_Child;
               begin
                  while Curr_Field > 0 loop
                     declare
                        Field_Name_Node : constant Node_Index := Tree (Curr_Field).Left_Child;
                        Field_Name      : constant String := Raw_Lexeme (Tree (Field_Name_Node).Token_Index);
                        Field_Py        : constant String := Safe_Py_Name (To_String (Py_Name) & "_" & Field_Name);
                        Field_Tag       : constant Value_Kind := (if Tree (Field_Name_Node).Right_Child > 0 then Type_From_Name (Raw_Lexeme (Tree (Tree (Field_Name_Node).Right_Child).Token_Index)) else VK_Number);
                     begin
                        Register_Symbol ("", To_String (Py_Name) & "." & Field_Name, Field_Py, Field_Tag, Sym_Parallel_Field, Rank, Dims, Capacity);
                        Line (Field_Py & " = [" & Default_Value (Field_Tag) & " for _ in range(" & Trim_Image (Capacity + 1) & ")]");
                     end;
                     Curr_Field := Tree (Curr_Field).Next_Sibling;
                  end loop;
               end;
               New_Line_Emit;
            end if;
         when AST_Temporal_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Py_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := VK_Number;
               end if;
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (Py_Name), To_String (Py_Name), Tag, Sym_Temporal, History_Size => Capacity);
               Line (To_String (Py_Name) & " = " & Cast_Expr (Tag, Expr (Tree (Node.Right_Child).Next_Sibling)));
               Line (To_String (Py_Name) & "_history = [None] + [" & To_String (Py_Name) & " for _ in range(" & Trim_Image (Capacity) & ")]");
               Line (To_String (Py_Name) & "_head = 1");
            end if;
         when AST_Markov_Model_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Model_Py  : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Setting   : Node_Index := Node.Right_Child;
               States_Text : Unbounded_String := U ("0");
               Matrix_Node  : Node_Index := 0;
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Markov_States =>
                        States_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Markov_Transition_Matrix =>
                        Matrix_Node := Tree (Setting).Left_Child;
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;
               Register_Symbol ("", Model_Py, Model_Py, VK_Number, Sym_Markov);
               Emit_Indent;
               Ada.Text_IO.Put (Out_File, Model_Py & " = ALB_markov_define(" & To_String (States_Text) & ", [");
               declare
                  Row_Node  : Node_Index := Matrix_Node;
                  First_Row : Boolean := True;
               begin
                  while Row_Node > 0 loop
                     if not First_Row then
                        Ada.Text_IO.Put (Out_File, ", ");
                     end if;
                     Ada.Text_IO.Put (Out_File, "[");
                     declare
                        Elem_Node : Node_Index := Tree (Row_Node).Left_Child;
                        First_Elem : Boolean := True;
                     begin
                        while Elem_Node > 0 loop
                           if not First_Elem then
                              Ada.Text_IO.Put (Out_File, ", ");
                           end if;
                           Ada.Text_IO.Put (Out_File, Expr (Elem_Node));
                           First_Elem := False;
                           Elem_Node := Tree (Elem_Node).Next_Sibling;
                        end loop;
                     end;
                     Ada.Text_IO.Put (Out_File, "]");
                     First_Row := False;
                     Row_Node := Tree (Row_Node).Next_Sibling;
                  end loop;
               end;
               Ada.Text_IO.Put (Out_File, "])");
               New_Line_Emit;
            end;
         when AST_Neural_Topology_Decl =>
            declare
               Name_Node  : constant Node_Index := Node.Left_Child;
               Net_Py     : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Layer_Node : Node_Index := Node.Right_Child;
               First      : Boolean := True;
               First_Act  : Boolean := True;
            begin
               Register_Symbol ("", Net_Py, Net_Py, VK_Number, Sym_Neural);
               Emit_Indent;
               Ada.Text_IO.Put (Out_File, Net_Py & " = ALB_nn_create(" & Escape_Py_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) & ", [");
               while Layer_Node > 0 loop
                  if not First then
                     Ada.Text_IO.Put (Out_File, ", ");
                  end if;
                  Ada.Text_IO.Put (Out_File, Expr (Tree (Layer_Node).Left_Child));
                  First := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Ada.Text_IO.Put (Out_File, "], [");
               Layer_Node := Node.Right_Child;
               while Layer_Node > 0 loop
                  if not First_Act then
                     Ada.Text_IO.Put (Out_File, ", ");
                  end if;
                  if Tree (Layer_Node).Right_Child > 0 then
                     Ada.Text_IO.Put (Out_File, Escape_Py_String (Raw_Lexeme (Tree (Tree (Layer_Node).Right_Child).Token_Index)));
                  else
                     Ada.Text_IO.Put (Out_File, Escape_Py_String ("linear"));
                  end if;
                  First_Act := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Ada.Text_IO.Put (Out_File, "])");
               New_Line_Emit;
            end;
         when AST_Network_Socket_Decl =>
            declare
               Name_Node     : constant Node_Index := Node.Left_Child;
               Socket_Py     : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Setting       : Node_Index := Node.Right_Child;
               Protocol_Text : Unbounded_String := U (Escape_Py_String ("UDP"));
               Port_Text     : Unbounded_String := U ("0");
               Buffer_Text   : Unbounded_String := U ("64");
            begin
               Need_Network_Runtime := True;
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Network_Protocol =>
                        Protocol_Text := U (Escape_Py_String (Raw_Lexeme (Tree (Tree (Setting).Left_Child).Token_Index)));
                     when AST_Network_Port =>
                        Port_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Network_Buffer_Size =>
                        Buffer_Text := U (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;
               Register_Symbol ("", Socket_Py, Socket_Py, VK_Number, Sym_Network);
               Line (Socket_Py & " = ALB_net_define(" & To_String (Protocol_Text) & ", " & To_String (Port_Text) & ", " & To_String (Buffer_Text) & ")");
            end;
         when AST_Memory_Firewall_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               FW_Name   : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               FW_Py     : constant String := Scoped_Name (FW_Name);
               Rule_Node : Node_Index := Node.Right_Child;
               Read_Text : Unbounded_String := U ("");
               Write_Text : Unbounded_String := U ("");
               First_Read : Boolean := True;
               First_Write : Boolean := True;
               Deny_All : Boolean := False;
            begin
               Need_Network_Runtime := True;
               while Rule_Node > 0 loop
                  case Tree (Rule_Node).Kind is
                     when AST_Firewall_Permit_Read =>
                        declare
                           Key : constant String := Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              if not First_Read then
                                 Append (Read_Text, ", ");
                              end if;
                              Append (Read_Text, Escape_Py_String (Key));
                              First_Read := False;
                           end if;
                        end;
                     when AST_Firewall_Permit_Write =>
                        declare
                           Key : constant String := Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              if not First_Write then
                                 Append (Write_Text, ", ");
                              end if;
                              Append (Write_Text, Escape_Py_String (Key));
                              First_Write := False;
                           end if;
                        end;
                     when AST_Firewall_Deny_All =>
                        Deny_All := True;
                     when others =>
                        null;
                  end case;
                  Rule_Node := Tree (Rule_Node).Next_Sibling;
               end loop;
               Register_Symbol ("", FW_Py, FW_Py, VK_String, Sym_Firewall);
               Line (FW_Py & " = ALB_firewall_define(" & Escape_Py_String (FW_Name) & ", [" &
                     To_String (Read_Text) & "], [" & To_String (Write_Text) & "], " & (if Deny_All then "True" else "False") & ")");
            end;
         when AST_Let_Stmt =>
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node = 0 then
               null;
            elsif Tree (Target_Node).Kind = AST_Var_Expr and then Tree (Target_Node).Left_Child = 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  declare
                     Struct_Maybe : constant String := (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
                  begin
                     if Struct_Maybe'Length > 0 and then Find_Struct (Safe_Py_Name (Struct_Maybe)) /= 0 then
                        Tag := VK_Struct;
                     else
                        Tag := Infer_Expr_Kind (Value_Node);
                        if Tag = VK_Unknown then
                           Tag := VK_Number;
                        end if;
                     end if;
                  end;
               end if;
               if Length (Current_Routine) > 0 then
                  declare
                     Sym_Id    : constant Natural := Find_Symbol (To_String (Current_Routine), To_String (Raw_Name));
                     Global_Id : constant Natural := Find_Symbol ("", Scoped_Name (To_String (Raw_Name)));
                     Plain_Id  : constant Natural := Find_Symbol ("", Safe_Py_Name (To_String (Raw_Name)));
                  begin
                     if Sym_Id /= 0 then
                        Emit_Assignment (Target_Node, Value_Node, Symbols (Sym_Id).Tag, False);
                     elsif Global_Id /= 0 then
                        Emit_Assignment (Target_Node, Value_Node, Symbols (Global_Id).Tag, False);
                     elsif Plain_Id /= 0 then
                        Emit_Assignment (Target_Node, Value_Node, Symbols (Plain_Id).Tag, False);
                     else
                        Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_Py_Name (To_String (Raw_Name)), Tag, (if Tag = VK_Struct then Sym_Struct_Var else Sym_Scalar),
                                         Struct_Name => (if Tag = VK_Struct and then Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else ""));
                        if Tag = VK_Struct then
                           Line (Safe_Py_Name (To_String (Raw_Name)) & " = " & Default_Value (VK_Struct, Raw_Lexeme (Node.Token_Index)));
                        else
                           Emit_Assignment (Target_Node, Value_Node, Tag, True);
                        end if;
                     end if;
                  end;
               else
                  declare
                     Sym_Id : constant Natural := Find_Symbol ("", Scoped_Name (To_String (Raw_Name)));
                  begin
                     if Sym_Id = 0 then
                        if Tag = VK_Struct then
                           Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Struct_Var,
                                            Struct_Name => (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else ""));
                           Line (Scoped_Name (To_String (Raw_Name)) & " = " & Default_Value (VK_Struct, Raw_Lexeme (Node.Token_Index)));
                        else
                           Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Scalar);
                           Emit_Assignment (Target_Node, Value_Node, Tag, True);
                        end if;
                     else
                        if Symbols (Sym_Id).Kind = Sym_Struct_Var
                          and then Node.Token_Index > 0
                          and then Value_Node = 0
                        then
                           Line (Scoped_Name (To_String (Raw_Name)) & " = " &
                                 Default_Value (VK_Struct, Raw_Lexeme (Node.Token_Index)));
                        else
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Sym_Id).Tag, False);
                        end if;
                     end if;
                  end;
               end if;
            else
               declare
                  Assign_Tag : Value_Kind := Infer_Expr_Kind (Value_Node);
               begin
                  if Assign_Tag = VK_Unknown then
                     Assign_Tag := VK_Number;
                  end if;
                  Emit_Assignment (Target_Node, Value_Node, Assign_Tag, False);
               end;
            end if;
         when AST_Procedure_Decl | AST_Function_Decl =>
            null;
         when AST_Return_Stmt =>
            if Node.Left_Child > 0 then
               Line ("return " & Expr (Node.Left_Child));
            else
               Line ("return");
            end if;
         when AST_If_Stmt =>
            declare
               Then_Block : constant Node_Index := Node.Right_Child;
               Else_Block : constant Node_Index :=
                 (if Then_Block > 0
                     and then Tree (Then_Block).Kind = AST_Block_Stmt
                     and then Tree (Then_Block).Next_Sibling > 0
                     and then Tree (Tree (Then_Block).Next_Sibling).Kind = AST_Block_Stmt
                  then Tree (Then_Block).Next_Sibling
                  else 0);
            begin
               Line ("if bool(" & Expr (Node.Left_Child) & "):");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Then_Block);
               Indent_Level := Indent_Level - 1;
               if Else_Block > 0 then
                  Line ("else:");
                  Indent_Level := Indent_Level + 1;
                  Emit_Block (Else_Block);
                  Indent_Level := Indent_Level - 1;
               end if;
            end;
         when AST_While_Stmt =>
            Line ("while bool(" & Expr (Node.Left_Child) & "):");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Right_Child);
            Indent_Level := Indent_Level - 1;
         when AST_For_Stmt =>
            declare
               Loop_Spec  : constant Node_Index := Node.Left_Child;
               Start_Node : constant Node_Index := (if Loop_Spec > 0 then Tree (Loop_Spec).Left_Child else 0);
               End_Node   : constant Node_Index :=
                 (if Loop_Spec > 0 and then Tree (Loop_Spec).Right_Child > 0
                  then
                    (if Tree (Tree (Loop_Spec).Right_Child).Kind = AST_Arg_List
                     then Tree (Tree (Loop_Spec).Right_Child).Left_Child
                     else Tree (Loop_Spec).Right_Child)
                  else 0);
               Step_Node  : constant Node_Index :=
                 (if Loop_Spec > 0 and then Tree (Loop_Spec).Right_Child > 0
                     and then Tree (Tree (Loop_Spec).Right_Child).Kind = AST_Arg_List
                     and then End_Node > 0
                  then Tree (End_Node).Next_Sibling
                  else 0);
               Start_Expr : constant String := (if Start_Node > 0 then Expr (Start_Node) else "0");
               End_Expr   : constant String := (if End_Node > 0 then Expr (End_Node) else "0");
               Step_Expr  : constant String := (if Step_Node > 0 then Expr (Step_Node) else "1");
               Var_Name   : constant String := Raw_Lexeme (Node.Token_Index);
               Var_Py     : constant String := Resolve_Var_Name (Var_Name);
            begin
               if Length (Current_Routine) > 0 then
                  if Find_Symbol (To_String (Current_Routine), Var_Name) = 0 and then Find_Symbol ("", Scoped_Name (Var_Name)) = 0 then
                     Register_Symbol (To_String (Current_Routine), Var_Name, Safe_Py_Name (Var_Name), VK_Number, Sym_Scalar);
                  end if;
               elsif Find_Symbol ("", Scoped_Name (Var_Name)) = 0 then
                  Register_Symbol ("", Scoped_Name (Var_Name), Scoped_Name (Var_Name), VK_Number, Sym_Scalar);
               end if;
               Line ("for " & Var_Py & " in ALB_for_range(" & Start_Expr & ", " & End_Expr & ", " & Step_Expr & "):");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Node.Right_Child);
               Indent_Level := Indent_Level - 1;
            end;
         when AST_Repeat_Stmt =>
            Line ("alb_repeat_guard = 0");
            Line ("while True:");
            Indent_Level := Indent_Level + 1;
            Line ("alb_repeat_guard = alb_repeat_guard + 1");
            Line ("if alb_repeat_guard > 500000:");
            Indent_Level := Indent_Level + 1;
            Line ("raise RuntimeError('ALBP repeat loop guard tripped')");
            Indent_Level := Indent_Level - 1;
            Emit_Block (Node.Left_Child);
            Line ("if bool(" & Expr (Node.Right_Child) & "):");
            Indent_Level := Indent_Level + 1;
            Line ("break");
            Indent_Level := Indent_Level - 2;
         when AST_Break_Stmt =>
            Line ("break");
         when AST_Continue_Stmt =>
            Line ("continue");
         when AST_Call_Stmt =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Func_Call then
               declare
                  Call_Node : constant AST_Node := Tree (Node.Left_Child);
                  Target    : constant String :=
                    (if Tree (Call_Node.Left_Child).Kind = AST_Member_Expr
                     then Collect_Module_Member_Name (Call_Node.Left_Child)
                     else Resolve_Routine_Name (Raw_Lexeme (Tree (Call_Node.Left_Child).Token_Index)));
               begin
                  if Target'Length > 0 then
                     Emit_Call_With_Out (Target, Call_Node.Right_Child);
                  else
                     Line (Expr (Node.Left_Child));
                  end if;
               end;
            else
               Line (Expr (Node.Left_Child));
            end if;
         when AST_Sync_Stmt =>
            Line ("pass");
         when AST_On_Block =>
            null;
         when AST_Select_Stmt | AST_Match_Stmt =>
            Emit_Switch_Stmt (Node.Left_Child, Node.Right_Child);
         when AST_SwapPop_Stmt =>
            Emit_SwapPop (Node.Left_Child, Node.Right_Child);
         when AST_Print_Stmt | AST_Print_Str_Stmt =>
            if Node.Left_Child > 0 then
               Line ("print(" & As_Text_Expr (Node.Left_Child) & ")");
            else
               Line ("print('')");
            end if;
         when AST_Create_Window =>
            declare
               Title_Node : constant Node_Index := Node.Left_Child;
               Pair_Node  : constant Node_Index := Node.Right_Child;
            begin
               Line ("ALB_create_window(" &
                     Expr (Title_Node) & ", " &
                     Expr (Tree (Pair_Node).Left_Child) & ", " &
                     Expr (Tree (Pair_Node).Right_Child) & ")");
            end;
         when AST_Set_Fullscreen =>
            Line ("ALB_set_fullscreen(" & Expr (Node.Left_Child) & ")");
         when AST_Set_Resizable =>
            Line ("ALB_set_resizable(" & Expr (Node.Left_Child) & ")");
         when AST_Set_Stretchy =>
            Line ("ALB_set_stretchy(" & Expr (Node.Left_Child) & ")");
         when AST_Tick =>
            Line ("ALB_tick(" & Expr (Node.Left_Child) & ")");
         when AST_Color =>
            Line ("ALB_color(" & Expr (Node.Left_Child) & ")");
         when AST_Clear =>
            Line ("ALB_clear(" & Expr (Node.Left_Child) & ")");
         when AST_Draw | AST_Fill | AST_Plot | AST_Text =>
            declare
               Args      : array (1 .. 8) of Unbounded_String := (others => U ("0"));
               Count     : Natural := 0;
               Curr      : Node_Index := 0;
               Call_Name : Unbounded_String := U ("");
               Arg_Text  : Unbounded_String := U ("");
            begin
               if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Arg_List then
                  Curr := Tree (Node.Left_Child).Left_Child;
                  while Curr > 0 and then Count < 8 loop
                     Count := Count + 1;
                     if Node.Kind = AST_Text and then Count = 3 then
                        Args (Count) := U (As_Text_Expr (Curr));
                     else
                        Args (Count) := U (Expr (Curr));
                     end if;
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end if;

               if Node.Kind = AST_Text then
                  if Count >= 3 then
                     Line ("ALB_draw_text(" & To_String (Args (1)) & ", " &
                           To_String (Args (2)) & ", " & To_String (Args (3)) & ")");
                  end if;
               elsif Node.Kind = AST_Plot then
                  if Count >= 2 then
                     Line ("ALB_plot(" & To_String (Args (1)) & ", " & To_String (Args (2)) & ")");
                  end if;
               else
                  case Tokens (Node.Token_Index).Kind is
                     when Tok_Rect =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_draw_rect");
                        else
                           Call_Name := U ("ALB_fill_rect");
                        end if;
                     when Tok_Line =>
                        Call_Name := U ("ALB_draw_line");
                     when Tok_Circle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_draw_circle");
                        else
                           Call_Name := U ("ALB_fill_circle");
                        end if;
                     when Tok_Triangle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_draw_triangle");
                        else
                           Call_Name := U ("ALB_fill_triangle");
                        end if;
                     when Tok_Pixel =>
                        Call_Name := U ("ALB_plot");
                     when others =>
                        Call_Name := U ("");
                  end case;

                  if Length (Call_Name) > 0 then
                     for I in 1 .. Count loop
                        if I > 1 then
                           Append (Arg_Text, ", ");
                        end if;
                        Append (Arg_Text, To_String (Args (I)));
                     end loop;
                     Line (To_String (Call_Name) & "(" & To_String (Arg_Text) & ")");
                  end if;
               end if;
            end;
         when AST_SET_ALPHA =>
            declare
               Curr : Node_Index := (if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Arg_List then Tree (Node.Left_Child).Left_Child else 0);
               A1   : Unbounded_String := U ("0");
               A2   : Unbounded_String := U ("255");
            begin
               if Curr > 0 then
                  A1 := U (Expr (Curr));
                  Curr := Tree (Curr).Next_Sibling;
               end if;
               if Curr > 0 then
                  A2 := U (Expr (Curr));
               end if;
               Line ("ALB_set_alpha(" & To_String (A1) & ", " & To_String (A2) & ")");
            end;
         when AST_SET_CLIP =>
            declare
               Curr : Node_Index := (if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Arg_List then Tree (Node.Left_Child).Left_Child else 0);
               A1, A2, A3, A4 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A3 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A4 := U (Expr (Curr)); end if;
               Line ("ALB_set_clip(" & To_String (A1) & ", " & To_String (A2) & ", " &
                     To_String (A3) & ", " & To_String (A4) & ")");
            end;
         when AST_SET_ORIGIN =>
            declare
               Curr : Node_Index := (if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Arg_List then Tree (Node.Left_Child).Left_Child else 0);
               A1, A2 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); end if;
               Line ("ALB_set_origin(" & To_String (A1) & ", " & To_String (A2) & ")");
            end;
         when AST_Delay_Stmt =>
            Line ("ALB_delay(" & Expr (Node.Left_Child) & ")");
         when AST_Input_Stmt =>
            declare
               Prompt_Text : constant String := (if Node.Left_Child > 0 then As_Text_Expr (Node.Left_Child) else "''");
               Target_Text : constant String := Statement_Target_Name (Node.Right_Child);
               Raw_Target  : constant String :=
                 (if Node.Right_Child > 0 and then Tree (Node.Right_Child).Token_Index > 0
                  then Raw_Lexeme (Tree (Node.Right_Child).Token_Index)
                  else "");
               Target_Sym  : constant Symbol_Record := Resolve_Symbol (Raw_Target);
               Value_Text  : constant String := "ALB_input(" & Prompt_Text & ")";
            begin
               if Target_Sym.Active then
                  Line (Target_Text & " = " & Cast_Expr (Target_Sym.Tag, Value_Text));
               else
                  Line (Target_Text & " = " & Value_Text);
               end if;
            end;
         when AST_Readline_Stmt =>
            if Node.Left_Child > 0 then
               declare
                  Target_Text : constant String := Statement_Target_Name (Node.Left_Child);
                  Raw_Target  : constant String :=
                    (if Tree (Node.Left_Child).Token_Index > 0
                     then Raw_Lexeme (Tree (Node.Left_Child).Token_Index)
                     else "");
                  Target_Sym  : constant Symbol_Record := Resolve_Symbol (Raw_Target);
                  Value_Text  : constant String := "ALB_input('')";
               begin
                  if Target_Sym.Active then
                     Line (Target_Text & " = " & Cast_Expr (Target_Sym.Tag, Value_Text));
                  else
                     Line (Target_Text & " = " & Value_Text);
                  end if;
               end;
            else
               Line ("ALB_input('')");
            end if;
         when AST_Msg_Box =>
            Line ("ALB_msg_box(" & Expr (Node.Left_Child) & ", " &
                  (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "''") & ")");
         when AST_Listen =>
            Line ("ALB_listen()");
         when AST_Cease =>
            Line ("ALB_cease()");
         when AST_Play_Sound =>
            Line ("ALB_play_sound(" & Expr (Node.Left_Child) & ")");
         when AST_Play_Music =>
            Line ("ALB_play_music(" & Expr (Node.Left_Child) & ")");
         when AST_Play_Music_From =>
            Line ("ALB_play_music_from(" & Expr (Node.Left_Child) & ")");
         when AST_File_Close =>
            Line ("ALB_file_close(" & Expr (Node.Left_Child) & ")");
         when AST_File_Write =>
            Line ("ALB_file_write(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");
         when AST_Load_Stmt =>
            declare
               Target_Sym : constant Symbol_Record := Resolve_Symbol ((if Tree (Node.Right_Child).Token_Index > 0 then Raw_Lexeme (Tree (Node.Right_Child).Token_Index) else ""));
            begin
               if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field then
                  declare
                     Count_Text : constant String :=
                       (if Target_Sym.Kind = Sym_Slide_Array then To_String (Target_Sym.Py_Name) & "_active" else Trim_Image (Target_Sym.Capacity));
                     Tag_Text : constant String :=
                       (case Target_Sym.Tag is
                           when VK_U8 => "U8",
                           when VK_U16 => "U16",
                           when VK_U32 => "U32",
                           when VK_U64 => "U64",
                           when VK_S8 => "S8",
                           when VK_S16 => "S16",
                           when VK_S32 => "S32",
                           when VK_S64 => "S64",
                           when VK_HW8 => "HW8",
                           when VK_HW16 => "HW16",
                           when VK_HW32 => "HW32",
                           when others => "U8");
                  begin
                     Line ("ALB_load_array(" & Expr (Node.Left_Child) & ", " & Statement_Target_Name (Node.Right_Child) & ", " & Count_Text & ", " & Escape_Py_String (Tag_Text) & ")");
                  end;
               else
                  Line (Statement_Target_Name (Node.Right_Child) & " = ALB_load_text(" & Expr (Node.Left_Child) & ")");
               end if;
            end;
         when AST_Flush_Stmt =>
            declare
               Target_Node_Value : constant Node_Index := Node.Left_Child;
               Target_AST : constant AST_Node := Tree (Target_Node_Value);
               Target_Sym : constant Symbol_Record := Resolve_Symbol ((if Target_AST.Token_Index > 0 then Raw_Lexeme (Target_AST.Token_Index) else ""));
            begin
               if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field then
                  declare
                     Count_Text : constant String :=
                       (if Target_Sym.Kind = Sym_Slide_Array then To_String (Target_Sym.Py_Name) & "_active" else Trim_Image (Target_Sym.Capacity));
                     Tag_Text : constant String :=
                       (case Target_Sym.Tag is
                           when VK_U8 => "U8",
                           when VK_U16 => "U16",
                           when VK_U32 => "U32",
                           when VK_U64 => "U64",
                           when VK_S8 => "S8",
                           when VK_S16 => "S16",
                           when VK_S32 => "S32",
                           when VK_S64 => "S64",
                           when VK_HW8 => "HW8",
                           when VK_HW16 => "HW16",
                           when VK_HW32 => "HW32",
                           when others => "U8");
                  begin
                     Line ("ALB_flush_array(" & Statement_Target_Name (Node.Left_Child) & ", " & Count_Text & ", " & Expr (Node.Right_Child) & ", " & Escape_Py_String (Tag_Text) & ")");
                  end;
               else
                  Line ("ALB_flush_text(" & Statement_Target_Name (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");
               end if;
            end;
         when AST_Save_State =>
            Line ("ALB_STATE_STACK.append(ALB_CAPTURE_STATE())");
         when AST_Load_State =>
            Line ("ALB_RESTORE_STATE(ALB_STATE_STACK[-1] if ALB_STATE_STACK else None)");
         when AST_Temporal_Block | AST_Reversible_Block | AST_Atomic_Block =>
            Emit_Block (Node.Left_Child);
         when AST_Advance_Stmt =>
            declare
               Count_Expr : constant String := (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "1");
            begin
               Line ("for alb_adv in range(max(0, int(" & Count_Expr & "))):");
               Indent_Level := Indent_Level + 1;
               for I in 1 .. Symbol_Count loop
                  if Symbols (I).Active and then Symbols (I).Kind = Sym_Temporal then
                     declare
                        Name : constant String := To_String (Symbols (I).Py_Name);
                        Hist : constant String := Trim_Image (Integer'Max (1, Symbols (I).History_Size));
                     begin
                        Line (Name & "_head = ((" & Name & "_head) % " & Hist & ") + 1");
                        Line (Name & "_history[" & Name & "_head] = copy.deepcopy(" & Name & ")");
                     end;
                  end if;
               end loop;
               Indent_Level := Indent_Level - 1;
            end;
         when AST_Network_Listen_Stmt =>
            Line ("ALB_net_listen(" & Expr (Node.Left_Child) & ")");
         when AST_Network_Accept_Stmt =>
            Line (Statement_Target_Name (Node.Right_Child) & " = ALB_net_accept(" & Expr (Node.Left_Child) & ")");
         when AST_Network_Receive_Stmt =>
            Line ("ALB_net_receive(" & Expr (Node.Left_Child) & ", " & Statement_Target_Name (Node.Right_Child) & ")");
         when AST_Network_Send_Stmt =>
            Line ("ALB_net_send(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");
         when AST_Network_Close_Stmt =>
            Line ("ALB_net_close(" & Expr (Node.Left_Child) & ")");
         when AST_Knows_Fact =>
            Line ("ALB_rel_set(" & Predicate_Name_Expr (Node.Left_Child) & ", 0, " & Expr (Node.Right_Child) & ")");
         when AST_Rule_Decl | AST_Constraint_Decl =>
            declare
               Head_Node : constant Node_Index := Node.Left_Child;
               Body_Node : constant Node_Index := Node.Right_Child;
               Curr_Body : Node_Index := (if Body_Node > 0 then Tree (Body_Node).Left_Child else 0);
               Head_Arg  : constant Node_Index := Predicate_First_Arg_Node (Head_Node);
               Head_Var  : constant String :=
                 (if Head_Arg > 0 and then Tree (Head_Arg).Token_Index > 0
                  then Upper_Text (Raw_Lexeme (Tree (Head_Arg).Token_Index))
                  else "");
               Terms     : Unbounded_String := U ("[");
               First     : Boolean := True;
            begin
               while Curr_Body > 0 loop
                  declare
                     Body_Arg : constant Node_Index := Predicate_First_Arg_Node (Curr_Body);
                     Body_Raw : constant String :=
                       (if Body_Arg > 0 and then Tree (Body_Arg).Token_Index > 0
                        then Upper_Text (Raw_Lexeme (Tree (Body_Arg).Token_Index))
                        else "");
                     Use_Head_Arg : constant Boolean :=
                       Body_Arg > 0
                       and then (Tree (Body_Arg).Kind = AST_Logic_Var or else Body_Raw = Head_Var);
                  begin
                     if not First then
                        Append (Terms, ", ");
                     end if;
                     Append
                       (Terms,
                        "(" & Predicate_Name_Expr (Curr_Body) & ", " &
                        (if Use_Head_Arg then "True" else "False") & ", " &
                        (if Use_Head_Arg then "0" else Predicate_Arg1_Expr (Curr_Body)) & ")");
                     First := False;
                  end;
                  Curr_Body := Tree (Curr_Body).Next_Sibling;
               end loop;
               Append (Terms, "]");
               Line ("ALB_rel_rule_add(" & Predicate_Name_Expr (Head_Node) & ", " & To_String (Terms) & ")");
            end;
         when AST_Assert_Stmt =>
            Line ("ALB_rel_set(" & Predicate_Name_Expr (Index) & ", " & Predicate_Arg1_Expr (Index) & ", 1)");
         when AST_Retract_Stmt =>
            Line ("ALB_rel_retract(" & Predicate_Name_Expr (Index) & ", " & Predicate_Arg1_Expr (Index) & ")");
         when AST_Update_Stmt =>
            Line ("ALB_rel_set(" & Predicate_Name_Expr (Node.Left_Child) & ", " &
                  Predicate_Arg1_Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");
         when AST_Findall_Query =>
            Line ("ALB_rel_findall1(" & Predicate_Name_Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ")");
         when AST_Predict_Markov_Stmt =>
            Line (Statement_Target_Name (Tree (Node.Right_Child).Next_Sibling) & " = ALB_markov_predict(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");
         when AST_Infer_Network_Stmt =>
            Line ("ALB_nn_infer(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ", " & Statement_Target_Name (Tree (Node.Right_Child).Next_Sibling) & ")");
         when AST_Train_Network_Stmt =>
            declare
               Train_Node  : constant Node_Index := Node.Right_Child;
               Expect_Node : constant Node_Index := (if Train_Node > 0 then Tree (Train_Node).Next_Sibling else 0);
               Epoch_Node  : constant Node_Index := (if Expect_Node > 0 then Tree (Expect_Node).Next_Sibling else 0);
            begin
               Line ("ALB_nn_train(" & Expr (Node.Left_Child) & ", " & Expr (Train_Node) & ", " & Expr (Expect_Node) & ", " & (if Epoch_Node > 0 then Expr (Epoch_Node) else "1") & ")");
            end;
         when AST_Try_Stmt =>
            Line ("try:");
            Indent_Level := Indent_Level + 1;
            if Node.Left_Child > 0 then
               Emit_Block (Node.Left_Child);
            else
               Line ("pass");
            end if;
            Indent_Level := Indent_Level - 1;
            Line ("except Exception as __alb_err:");
            Indent_Level := Indent_Level + 1;
            if Node.Token_Index > 0 then
               Line (Safe_Py_Name (Raw_Lexeme (Node.Token_Index)) & " = str(__alb_err)");
            end if;
            if Node.Right_Child > 0 then
               Emit_Block (Node.Right_Child);
            else
               Line ("pass");
            end if;
            Indent_Level := Indent_Level - 1;
         when AST_Throw_Stmt =>
            Line ("raise RuntimeError(" & As_Text_Expr (Node.Left_Child) & ")");
         when AST_Runtime_Assert =>
            Line ("if not bool(" & Expr (Node.Left_Child) & "):");
            Indent_Level := Indent_Level + 1;
            Line ("raise RuntimeError('runtime assert failed')");
            Indent_Level := Indent_Level - 1;
         when AST_Rev_Add_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = " & Statement_Target_Name (Node.Left_Child) & " + " & Expr (Node.Right_Child));
         when AST_Rev_Sub_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = " & Statement_Target_Name (Node.Left_Child) & " - " & Expr (Node.Right_Child));
         when AST_Rev_Xor_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = int(" & Statement_Target_Name (Node.Left_Child) & ") ^ int(" & Expr (Node.Right_Child) & ")");
         when AST_Rev_Swap_Stmt =>
            Line ("alb_tmp_swap = " & Statement_Target_Name (Node.Left_Child));
            Line (Statement_Target_Name (Node.Left_Child) & " = " & Statement_Target_Name (Node.Right_Child));
            Line (Statement_Target_Name (Node.Right_Child) & " = alb_tmp_swap");
         when AST_Rev_Not_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ~(" & Statement_Target_Name (Node.Left_Child) & ")");
         when AST_Rev_Neg_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = -(" & Statement_Target_Name (Node.Left_Child) & ")");
         when others =>
            raise Program_Error with "ALBP: unsupported statement node " & Node_Kind'Image (Node.Kind);
      end case;
   end Emit_Node;

   procedure Compile_To_File
     (Root            : in AST_Node;
      Output_Filename : in String) is
      function Find_Node_Index (Wanted : AST_Node) return Node_Index is
      begin
         for I in Tree'Range loop
            if Tree (I).Kind = Wanted.Kind
              and then Tree (I).Token_Index = Wanted.Token_Index
              and then Tree (I).Left_Child = Wanted.Left_Child
              and then Tree (I).Right_Child = Wanted.Right_Child
              and then Tree (I).Next_Sibling = Wanted.Next_Sibling
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Node_Index;

      procedure Emit_Top_Level (First : Node_Index) is
         Curr : Node_Index := First;

         function Is_Setup_Node (Kind : Node_Kind) return Boolean is
         begin
            return Kind in
              AST_Version |
              AST_DeclareModule |
              AST_Import |
              AST_Import_C |
              AST_Import_DLL |
              AST_Include_Stmt |
              AST_Range_Type_Decl |
              AST_Module |
              AST_Const_Decl |
              AST_Struct_Decl |
              AST_Strict_Stmt |
              AST_Slide_Stmt |
              AST_Parallel_Decl |
              AST_Temporal_Decl |
              AST_Markov_Model_Decl |
              AST_Neural_Topology_Decl |
              AST_Network_Socket_Decl |
              AST_Memory_Firewall_Decl;
         end Is_Setup_Node;
      begin
         declare
            Pass_Curr : Node_Index := Curr;
         begin
            while Pass_Curr > 0 loop
               if Tree (Pass_Curr).Kind = AST_Procedure_Decl then
                  Emit_Function_Decl (Pass_Curr, False);
               elsif Tree (Pass_Curr).Kind = AST_Function_Decl then
                  Emit_Function_Decl (Pass_Curr, True);
               end if;
               Pass_Curr := Tree (Pass_Curr).Next_Sibling;
            end loop;
         end;

         declare
            Pass_Curr : Node_Index := Curr;
         begin
            while Pass_Curr > 0 loop
               if Tree (Pass_Curr).Kind not in AST_Procedure_Decl | AST_Function_Decl
                 and then Is_Setup_Node (Tree (Pass_Curr).Kind)
               then
                  Emit_Node (Pass_Curr);
               end if;
               Pass_Curr := Tree (Pass_Curr).Next_Sibling;
            end loop;
         end;

         Emit_State_Routines;
         Emit_Event_Methods;

         while Curr > 0 loop
            if Tree (Curr).Kind not in AST_Procedure_Decl | AST_Function_Decl
              and then not Is_Setup_Node (Tree (Curr).Kind)
            then
               Emit_Node (Curr);
            end if;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Top_Level;

      Root_Index : constant Node_Index := Find_Node_Index (Root);
   begin
      Reset_State;
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Output_Filename);
      File_Open := True;

      if Root_Index > 0 then
         Current_Module := U ("");
         Scan_Features (Root_Index);
         Current_Module := U ("");
      end if;

      Emit_Runtime;
      Emit_Struct_Definitions;
      if Root_Index > 0 then
         Emit_Top_Level (Root_Index);
      elsif Root.Kind /= AST_Null then
         Line ("# ALBP warning: could not recover top-level root index for " & Node_Kind'Image (Root.Kind));
      end if;

      Ada.Text_IO.Close (Out_File);
      File_Open := False;
   exception
      when others =>
         if File_Open then
            Ada.Text_IO.Close (Out_File);
            File_Open := False;
         end if;
         raise;
   end Compile_To_File;

end Emit_Native_Python;
