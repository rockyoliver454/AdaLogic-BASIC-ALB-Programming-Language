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
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with AST;            use AST;

package body Emit_Native_MoonScript is

   Max_Symbols       : constant Natural := 32_768;
   Max_Structs       : constant Natural := 1024;
   Max_Fields        : constant Natural := 8192;
   Max_Routines      : constant Natural := 8192;
   Max_Params        : constant Natural := 64;
   Max_Event_Blocks  : constant Natural := 1024;
   Max_Predicates    : constant Natural := 2048;
   Max_Logic_Rules   : constant Natural := 2048;
   Max_Logic_Watches : constant Natural := 512;
   Max_Rule_Body_Terms : constant Natural := 16;
   --  Match albt Max_Foreign_Exports so full-engine libgamedeck EXPORT_ES
   --  (+ optional EXPORT_WASM) façades fit in one web library weave.
   Max_Foreign_Bindings : constant Natural := 8192;

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
      VK_F64,
      VK_HW8,
      VK_HW16,
      VK_HW32,
      VK_U128,
      VK_Struct);

   type Symbol_Kind is
     (Sym_Scalar,
      Sym_Strict_Array,
      Sym_Slide_Array,
      Sym_Parallel_Field,
      Sym_Temporal,
      Sym_Struct_Var,
      Sym_Const,
      Sym_Param);

   type Param_Mode_Kind is (Param_In, Param_Out);
   type Foreign_Link_Kind is
     (Foreign_None,
      Foreign_Compat,
      Foreign_ES,
      Foreign_WASM);
   type Dim_List is array (1 .. 4) of Integer;
   type Param_Mode_List is array (1 .. Max_Params) of Param_Mode_Kind;
   type Node_Index_List is array (1 .. Max_Event_Blocks) of Node_Index;
   type Rule_Node_List is array (1 .. Max_Logic_Rules) of Node_Index;
   type Watch_Node_List is array (1 .. Max_Logic_Watches) of Node_Index;

   type Foreign_Binding_Record is record
      Active    : Boolean := False;
      Node      : Node_Index := 0;
      Link_Kind : Foreign_Link_Kind := Foreign_None;
      Name      : Unbounded_String := To_Unbounded_String ("");
      Moon_Name   : Unbounded_String := To_Unbounded_String ("");
      Path      : Unbounded_String := To_Unbounded_String ("");
      Is_Function : Boolean := False;
      Return_Tag  : Value_Kind := VK_Number;
   end record;

   type Predicate_Record is record
      Active : Boolean := False;
      Name   : Unbounded_String := To_Unbounded_String ("");
      Id     : Natural := 0;
   end record;

   type Symbol_Record is record
      Active       : Boolean := False;
      Name         : Unbounded_String := To_Unbounded_String ("");
      Scope        : Unbounded_String := To_Unbounded_String ("");
      Moon_Name      : Unbounded_String := To_Unbounded_String ("");
      Struct_Name  : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
      Kind         : Symbol_Kind := Sym_Scalar;
      Rank         : Natural := 0;
      Dims         : Dim_List := (others => 0);
      Capacity     : Integer := 0;
      Active_Size  : Integer := 0;
      History_Size : Integer := 0;
      Offset_Bytes : Integer := 0;
      Aux_Offset   : Integer := 0;
   end record;

   type Struct_Record is record
      Active     : Boolean := False;
      Name       : Unbounded_String := To_Unbounded_String ("");
      Size_Bytes : Integer := 0;
   end record;

   type Field_Record is record
      Active       : Boolean := False;
      Struct_Name  : Unbounded_String := To_Unbounded_String ("");
      Field_Name   : Unbounded_String := To_Unbounded_String ("");
      Moon_Field     : Unbounded_String := To_Unbounded_String ("");
      Type_Name    : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
      Offset_Bytes : Integer := 0;
      Bit_Width    : Integer := 0;
      Bit_Shift    : Integer := 0;
   end record;

   type Routine_Record is record
      Active      : Boolean := False;
      Name        : Unbounded_String := To_Unbounded_String ("");
      Moon_Name     : Unbounded_String := To_Unbounded_String ("");
      Param_Count : Natural := 0;
      Param_Modes : Param_Mode_List := (others => Param_In);
   end record;

   Symbols  : array (1 .. Max_Symbols) of Symbol_Record;
   Structs  : array (1 .. Max_Structs) of Struct_Record;
   Fields   : array (1 .. Max_Fields) of Field_Record;
   Routines : array (1 .. Max_Routines) of Routine_Record;
   Predicates : array (1 .. Max_Predicates) of Predicate_Record;
   Foreign_Imports : array (1 .. Max_Foreign_Bindings) of Foreign_Binding_Record;
   Foreign_Exports : array (1 .. Max_Foreign_Bindings) of Foreign_Binding_Record;

   Symbol_Count  : Natural := 0;
   Struct_Count  : Natural := 0;
   Field_Count   : Natural := 0;
   Routine_Count : Natural := 0;
   Predicate_Count : Natural := 0;
   Foreign_Import_Count : Natural := 0;
   Foreign_Export_Count : Natural := 0;

   Out_File     : Ada.Text_IO.File_Type;
   File_Open    : Boolean := False;
   Indent_Level : Natural := 0;

   Current_Module  : Unbounded_String := To_Unbounded_String ("");
   Current_Routine : Unbounded_String := To_Unbounded_String ("");
   Current_Routine_Out_Count : Natural := 0;
   Current_Routine_Out_Names : array (1 .. Max_Params) of Unbounded_String :=
     (others => To_Unbounded_String (""));
   Saw_Create      : Boolean := False;
   Saw_Listen      : Boolean := False;
   No_Console_Overlay : Boolean := False;
   Tick_Blocks     : Node_Index_List := (others => 0);
   Paint_Blocks    : Node_Index_List := (others => 0);
   Key_Blocks      : Node_Index_List := (others => 0);
   Rule_Nodes      : Rule_Node_List := (others => 0);
   Watch_Nodes     : Watch_Node_List := (others => 0);
   Tick_Block_Count  : Natural := 0;
   Paint_Block_Count : Natural := 0;
   Key_Block_Count   : Natural := 0;
   Rule_Node_Count   : Natural := 0;
   Watch_Node_Count  : Natural := 0;
   Temp_Name_Counter : Natural := 0;
   Next_Address_Byte : Integer := 1;
   Need_Module_Support : Boolean := False;
   Need_Static_Graphics_Runtime : Boolean := False;
   Need_Markov_Runtime : Boolean := False;
   Need_Neural_Runtime : Boolean := False;
   Need_Network_Runtime : Boolean := False;
   Need_Firewall_Runtime : Boolean := False;
   Need_Process_Runtime : Boolean := False;
   Need_Compat_Runtime : Boolean := False;
   Need_Wasm_Loaders : Boolean := False;
   Shoebox_Root : Unbounded_String := To_Unbounded_String ("");
   Max_Mode_Nesting : constant Natural := 32;
   type Mode_Text_Stack is array (1 .. Max_Mode_Nesting) of Unbounded_String;
   Stride_Depth : Natural := 0;
   Stride_Step_Stack : Mode_Text_Stack := (others => To_Unbounded_String (""));
   Symbolic_Depth : Natural := 0;
   Exact_Depth : Natural := 0;

   function Expr (Node_Index_Value : Node_Index) return String;
   function Raw_Feature_Atom (Index : Node_Index) return String;
   procedure Register_Routine_Signature (Index : Node_Index);
   procedure Emit_Block (Block_Node : Node_Index);
   function Statement_Target_Name
     (Target_Node : Node_Index;
      Assign_Kind : Value_Kind := VK_Unknown) return String;
   function Emit_Call_Expr_With_Out
     (Target_Name : String;
      Arg_List    : Node_Index) return String;
   function Out_Arg_Name (Arg_Node : Node_Index) return String;

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

   function Upper_Text (S : String) return String is
      R : String (S'Range);
   begin
      for I in S'Range loop
         R (I) := Ada.Characters.Handling.To_Upper (S (I));
      end loop;
      return R;
   end Upper_Text;

   function U (S : String) return Unbounded_String renames To_Unbounded_String;
   function Escape_Moon_String (Text : String) return String;
   function Resolve_Symbol (Raw : String) return Symbol_Record;
   function Target_Symbol (Target_Node : Node_Index) return Symbol_Record;
   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String;

   function Safe_Moon_Name (Name : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("");
      C      : Character;
      Text   : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
      Upper  : constant String := Upper_Text (Text);
      Needs_Prefix : Boolean := False;
   begin
      if Text'Length = 0 then
         return "alb_anon";
      end if;

      if Text (Text'First) in '0' .. '9' then
         Append (Result, "alb_");
      end if;

      for I in Text'Range loop
         C := Text (I);
         if (C in 'a' .. 'z') or else (C in 'A' .. 'Z')
           or else (C in '0' .. '9') or else C = '_'
         then
            Append (Result, C);
         elsif C = '.' then
            Append (Result, "_");
         else
            Append (Result, "_");
         end if;
      end loop;

      Needs_Prefix :=
        Upper = "AND" or else
        Upper = "BREAK" or else
        Upper = "CLASS" or else
        Upper = "CONTINUE" or else
        Upper = "DO" or else
        Upper = "ELSE" or else
        Upper = "ELSEIF" or else
        Upper = "EXPORT" or else
        Upper = "EXTENDS" or else
        Upper = "FALSE" or else
        Upper = "FOR" or else
        Upper = "FROM" or else
        Upper = "IF" or else
        Upper = "IMPORT" or else
        Upper = "IN" or else
        Upper = "LOCAL" or else
        Upper = "NIL" or else
        Upper = "NOT" or else
        Upper = "OR" or else
        Upper = "RETURN" or else
        Upper = "SUPER" or else
        Upper = "SWITCH" or else
        Upper = "THEN" or else
        Upper = "TRUE" or else
        Upper = "UNLESS" or else
        Upper = "UNTIL" or else
        Upper = "USING" or else
        Upper = "WHEN" or else
        Upper = "WHILE" or else
        Upper = "WITH";

      if Needs_Prefix then
         return "alb_" & To_String (Result);
      end if;

      return To_String (Result);
   end Safe_Moon_Name;

   function Scoped_Name (Name : String) return String is
   begin
      if Length (Current_Module) = 0 then
         return Safe_Moon_Name (Name);
      else
         return Safe_Moon_Name (To_String (Current_Module) & "_" & Name);
      end if;
   end Scoped_Name;

   function Starts_With (Text : String; Prefix : String) return Boolean is
   begin
      return Prefix'Length <= Text'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Next_Temp_Name (Prefix : String) return String is
   begin
      Temp_Name_Counter := Temp_Name_Counter + 1;
      return "__alb_" & Safe_Moon_Name (Prefix) & "_" & Trim_Image (Integer (Temp_Name_Counter));
   end Next_Temp_Name;

   function Ensure_Predicate_Id (Name : String) return Natural is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
   begin
      if Trimmed'Length = 0 then
         return 0;
      end if;

      for I in 1 .. Predicate_Count loop
         if Predicates (I).Active
           and then To_String (Predicates (I).Name) = Trimmed
         then
            return Predicates (I).Id;
         end if;
      end loop;

      if Predicate_Count < Max_Predicates then
         Predicate_Count := Predicate_Count + 1;
         Predicates (Predicate_Count).Active := True;
         Predicates (Predicate_Count).Name := U (Trimmed);
         Predicates (Predicate_Count).Id := Predicate_Count;
         return Predicate_Count;
      end if;

      return 0;
   end Ensure_Predicate_Id;

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
         when AST_Update_Stmt | AST_Findall_Query | AST_Query | AST_Knows_Query
           | AST_Rule_Decl | AST_Constraint_Decl =>
            if Node.Left_Child > 0 then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return "";
         when AST_Knows_Change =>
            if Node.Right_Child > 0 then
               return Predicate_Name_From_Node (Node.Right_Child);
            end if;
            return "";
         when AST_Find_Query =>
            if Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND"
              and then Node.Left_Child > 0
            then
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
      elsif Node.Kind in AST_Update_Stmt | AST_Findall_Query | AST_Query
        | AST_Knows_Query | AST_Rule_Decl | AST_Constraint_Decl
      then
         return Predicate_First_Arg_Node (Node.Left_Child);
      elsif Node.Kind = AST_Knows_Change and then Node.Right_Child > 0 then
         return Predicate_First_Arg_Node (Node.Right_Child);
      elsif Node.Kind = AST_Find_Query then
         if Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND"
           and then Node.Left_Child > 0
         then
            return Predicate_First_Arg_Node (Node.Left_Child);
         end if;
         return Node.Left_Child;
      elsif Node.Kind in AST_Assert_Stmt | AST_Retract_Stmt | AST_Find_Query then
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

   function Predicate_Id_Expr (Pred_Node : Node_Index) return String is
   begin
      return Trim_Image (Integer (Ensure_Predicate_Id (Predicate_Name_From_Node (Pred_Node))));
   end Predicate_Id_Expr;

   function Predicate_Arg1_Expr (Pred_Node : Node_Index) return String is
      Arg_Node : constant Node_Index := Predicate_First_Arg_Node (Pred_Node);
   begin
      if Arg_Node > 0 then
         return Expr (Arg_Node);
      else
         return "0";
      end if;
   end Predicate_Arg1_Expr;

   function Predicate_Arity_Expr (Pred_Node : Node_Index) return String is
   begin
      if Predicate_First_Arg_Node (Pred_Node) > 0 then
         return "1";
      else
         return "0";
      end if;
   end Predicate_Arity_Expr;

   function Logic_Var_Name_From_Node (Pred_Node : Node_Index) return String is
      Arg_Node : constant Node_Index := Predicate_First_Arg_Node (Pred_Node);
   begin
      if Arg_Node > 0 and then Tree (Arg_Node).Kind = AST_Logic_Var then
         return Raw_Lexeme (Tree (Arg_Node).Token_Index);
      end if;
      return "";
   end Logic_Var_Name_From_Node;

   procedure Remember_Rule_Node (Rule_Node : Node_Index) is
   begin
      if Rule_Node > 0 and then Rule_Node_Count < Max_Logic_Rules then
         Rule_Node_Count := Rule_Node_Count + 1;
         Rule_Nodes (Rule_Node_Count) := Rule_Node;
      end if;
   end Remember_Rule_Node;

   procedure Remember_Watch_Node (Watch_Node : Node_Index) is
   begin
      if Watch_Node > 0 and then Watch_Node_Count < Max_Logic_Watches then
         Watch_Node_Count := Watch_Node_Count + 1;
         Watch_Nodes (Watch_Node_Count) := Watch_Node;
      end if;
   end Remember_Watch_Node;

   procedure Emit (Text : String) is
   begin
      Ada.Text_IO.Put (Out_File, Text);
   end Emit;

   procedure New_Line_Emit is
   begin
      Ada.Text_IO.New_Line (Out_File);
   end New_Line_Emit;

   procedure Emit_Indent is
   begin
      for I in 1 .. Indent_Level loop
         Emit ("    ");
      end loop;
   end Emit_Indent;

   procedure Line (Text : String) is
   begin
      Emit_Indent;
      Emit (Text);
      New_Line_Emit;
   end Line;

   procedure Reset_State is
   begin
      Symbols := (others => (others => <>));
      Structs := (others => (others => <>));
      Fields := (others => (others => <>));
      Routines := (others => (others => <>));
      Predicates := (others => (others => <>));
      Foreign_Imports := (others => (others => <>));
      Foreign_Exports := (others => (others => <>));
      Symbol_Count := 0;
      Struct_Count := 0;
      Field_Count := 0;
      Routine_Count := 0;
      Predicate_Count := 0;
      Foreign_Import_Count := 0;
      Foreign_Export_Count := 0;
      Indent_Level := 0;
      Current_Module := U ("");
      Current_Routine := U ("");
      Saw_Create := False;
      Saw_Listen := False;
      Tick_Blocks := (others => 0);
      Paint_Blocks := (others => 0);
      Key_Blocks := (others => 0);
      Rule_Nodes := (others => 0);
      Watch_Nodes := (others => 0);
      Tick_Block_Count := 0;
      Paint_Block_Count := 0;
      Key_Block_Count := 0;
      Rule_Node_Count := 0;
      Watch_Node_Count := 0;
      Temp_Name_Counter := 0;
      Next_Address_Byte := 1;
      Need_Module_Support := False;
      Need_Static_Graphics_Runtime := False;
      Need_Markov_Runtime := False;
      Need_Neural_Runtime := False;
      Need_Network_Runtime := False;
      Need_Firewall_Runtime := False;
      Need_Process_Runtime := False;
      Need_Compat_Runtime := False;
      Need_Wasm_Loaders := False;
      Shoebox_Root := U ("");
      Stride_Depth := 0;
      Stride_Step_Stack := (others => U (""));
      Symbolic_Depth := 0;
      Exact_Depth := 0;
   end Reset_State;

   function Element_Bytes (Kind : Value_Kind) return Integer is
   begin
      case Kind is
         when VK_U8 | VK_S8 | VK_HW8 | VK_Boolean =>
            return 1;
         when VK_U16 | VK_S16 | VK_HW16 =>
            return 2;
         when VK_U32 | VK_U64 | VK_S32 | VK_HW32 | VK_Pure | VK_Number | VK_F64 =>
            return 4;
         when others =>
            return 4;
      end case;
   end Element_Bytes;

   function Allocate_Address_Bytes (Bytes : Integer) return Integer is
      Size : constant Integer := Integer'Max (1, Bytes);
      Base : constant Integer := Next_Address_Byte;
   begin
      Next_Address_Byte := Next_Address_Byte + Size;
      return Base;
   end Allocate_Address_Bytes;

   function Type_From_Name (Name : String) return Value_Kind is
      T : constant String := Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
   begin
      if T = "BOOL" or else T = "BOOLEAN" then
         return VK_Boolean;
      elsif T = "STRING" then
         return VK_String;
      elsif T = "BINARY" then
         return VK_Binary;
      elsif T = "PURE" or else T = "RATIONAL" then
         return VK_Pure;
      elsif T = "U8" then
         return VK_U8;
      elsif T = "U16" then
         return VK_U16;
      elsif T = "S8" or else T = "I8" or else T = "INT8" then
         return VK_S8;
      elsif T = "S16" or else T = "I16" or else T = "INT16" then
         return VK_S16;
      elsif T = "U32" then
         return VK_U32;
      elsif T = "U64" then
         return VK_U64;
      elsif T = "S64" or else T = "I64" or else T = "INT64" then
         return VK_Number;
      elsif T = "S32" or else T = "I32" or else T = "INT32" then
         return VK_S32;
      elsif T = "F64" or else T = "REAL" then
         return VK_F64;
      elsif T = "FLOAT2" or else T = "F32X2" or else
        T = "FLOAT4" or else T = "F32X4" or else
        T = "MAT2" or else T = "MAT2X2" or else
        T = "MAT3" or else T = "MAT3X3" or else
        T = "MAT4" or else T = "MAT4X4"
      then
         return VK_Struct;
      elsif T = "BOOLEAN" or else T = "BOOL" then
         return VK_Boolean;
      elsif T = "STRING" then
         return VK_String;
      elsif T = "BINARY" then
         return VK_Binary;
      elsif T = "HW8" then
         return VK_HW8;
      elsif T = "HW16" then
         return VK_HW16;
      elsif T = "HW32" then
         return VK_HW32;
      elsif T = "U128" then
         return VK_U128;
      else
         return VK_Struct;
      end if;
   end Type_From_Name;

   function Type_From_Token (Token_Index : Natural) return Value_Kind is
   begin
      if Token_Index = 0 then
         return VK_Unknown;
      end if;
      return Type_From_Name (Raw_Lexeme (Token_Index));
   end Type_From_Token;

   function Primitive_Moon_Type (Kind : Value_Kind) return String is
   begin
      -- Lua has no static type annotations; keep a name for rare diagnostics only.
      case Kind is
         when VK_Boolean =>
            return "boolean";
         when VK_String | VK_Binary =>
            return "string";
         when VK_U128 =>
            return "number";
         when others =>
            return "number";
      end case;
   end Primitive_Moon_Type;

   function Default_Value
     (Kind        : Value_Kind;
      Struct_Name : String := "") return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "false";
         when VK_String | VK_Binary =>
            return """""";
         when VK_U128 =>
            return "0";
         when VK_Struct =>
            declare
               Shape_Name : constant String :=
                 Upper_Text (Ada.Strings.Fixed.Trim (Struct_Name, Ada.Strings.Both));
            begin
               if Shape_Name = "FLOAT2" or else Shape_Name = "F32X2" then
                  return "{0.0, 0.0}";
               elsif Shape_Name = "FLOAT4" or else Shape_Name = "F32X4" then
                  return "{0.0, 0.0, 0.0, 0.0}";
               elsif Shape_Name = "MAT2" or else Shape_Name = "MAT2X2" then
                  return "{{0.0, 0.0}, {0.0, 0.0}}";
               elsif Shape_Name = "MAT3" or else Shape_Name = "MAT3X3" then
                  return "{{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}";
               elsif Shape_Name = "MAT4" or else Shape_Name = "MAT4X4" then
                  return "{{0.0, 0.0, 0.0, 0.0}, {0.0, 0.0, 0.0, 0.0}, {0.0, 0.0, 0.0, 0.0}, {0.0, 0.0, 0.0, 0.0}}";
               elsif Struct_Name'Length > 0 then
                  return "{}";
               else
                  return "{}";
               end if;
            end;
         when others =>
            return "0";
      end case;
   end Default_Value;

   function Type_Annotation_From_Name (Name : String) return String is
      pragma Unreferenced (Name);
   begin
      -- Lua emission does not use TypeScript-style annotations.
      return "";
   end Type_Annotation_From_Name;

   function Cast_Expr (Kind : Value_Kind; Expr : String) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "ALB_truthy(" & Expr & ")";
         when VK_String | VK_Binary =>
            return "tostring(" & Expr & ")";
         when VK_U8 =>
            return "albU8(" & Expr & ")";
         when VK_U16 =>
            return "albU16(" & Expr & ")";
         when VK_S8 =>
            return "albI8(" & Expr & ")";
         when VK_S16 =>
            return "albI16(" & Expr & ")";
         when VK_U32 =>
            return "albU32(" & Expr & ")";
         when VK_U64 =>
            return "albU32(" & Expr & ")";
         when VK_S32 | VK_HW8 | VK_HW16 | VK_HW32 =>
            return "albI32(" & Expr & ")";
         when VK_F64 | VK_Number | VK_Pure | VK_Unknown =>
            return "ALB_num(" & Expr & ")";
         when VK_U128 =>
            return "ALB_num(" & Expr & ")";
         when VK_Struct =>
            return Expr;
      end case;
   end Cast_Expr;

   function Infer_Expr_Kind (Index : Node_Index) return Value_Kind is
      Node : AST_Node;
      Sym  : Symbol_Record;
   begin
      if Index = 0 then
         return VK_Unknown;
      end if;

      Node := Tree (Index);
      case Node.Kind is
         when AST_String_Expr | AST_TypeOf_Expr =>
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
               return Type_From_Token (Node.Token_Index);
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
                  then
                     return VK_String;
                  elsif Raw = "CHOOSE" and then Node.Right_Child > 0 then
                     declare
                        Arg1 : constant Node_Index := Tree (Node.Right_Child).Left_Child;
                        Arg2 : constant Node_Index := (if Arg1 > 0 then Tree (Arg1).Next_Sibling else 0);
                     begin
                        if Arg2 > 0 then
                           return Infer_Expr_Kind (Arg2);
                        end if;
                     end;
                  end if;
               end;
            end if;
            return VK_Unknown;
         when others =>
            return VK_Unknown;
      end case;
   end Infer_Expr_Kind;

   function Is_Real_Number_Text (Text : String) return Boolean is
   begin
      for Ch of Text loop
         if Ch = '.' or else Ch = 'e' or else Ch = 'E' then
            return True;
         end if;
      end loop;
      return False;
   end Is_Real_Number_Text;

   function Uses_Real_Power (Index : Node_Index) return Boolean is
      Node : AST_Node;
      Kind : Value_Kind;
   begin
      if Index = 0 then
         return False;
      end if;

      Kind := Infer_Expr_Kind (Index);
      if Kind = VK_F64 then
         return True;
      end if;

      Node := Tree (Index);
      case Node.Kind is
         when AST_Number_Expr =>
            if Node.Token_Index > 0 then
               return Is_Real_Number_Text (Raw_Lexeme (Node.Token_Index));
            end if;
         when AST_Unary_Minus =>
            return Uses_Real_Power (Node.Left_Child);
         when AST_Cast_Expr | AST_Constructor =>
            if Node.Token_Index > 0 then
               declare
                  Raw : constant String := Upper_Text (Raw_Lexeme (Node.Token_Index));
               begin
                  return Raw = "F64" or else Raw = "REAL";
               end;
            end if;
         when others =>
            null;
      end case;

      return False;
   end Uses_Real_Power;

   function Typed_Array_Name (Kind : Value_Kind) return String is
      pragma Unreferenced (Kind);
   begin
      --  Lua uses plain tables; Typed_Array_Name kept for call-site shape.
      return "ALB_new_array";
   end Typed_Array_Name;

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

   function Field_Read_Expr
     (Base_Expr : String;
      Field_Id  : Natural) return String is
      Mask : Integer := 0;
   begin
      if Field_Id = 0 or else Field_Id > Field_Count then
         return Base_Expr & ".alb_missing_field";
      end if;

      if Fields (Field_Id).Bit_Width > 0 then
         Mask := 2 ** Integer'Min (30, Fields (Field_Id).Bit_Width) - 1;
         return "ALB_band(ALB_shr(" & Base_Expr & "." & To_String (Fields (Field_Id).Moon_Field) &
           ", " & Trim_Image (Fields (Field_Id).Bit_Shift) & "), " &
           Trim_Image (Mask) & ")";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).Moon_Field);
      end if;
   end Field_Read_Expr;

   function Field_Write_Expr
     (Base_Expr   : String;
      Field_Id    : Natural;
      Value_Expr  : String) return String is
      Mask : Integer := 0;
   begin
      if Field_Id = 0 or else Field_Id > Field_Count then
         return Base_Expr & ".alb_missing_field = " & Value_Expr;
      end if;

      if Fields (Field_Id).Bit_Width > 0 then
         Mask := 2 ** Integer'Min (30, Fields (Field_Id).Bit_Width) - 1;
         return Base_Expr & "." & To_String (Fields (Field_Id).Moon_Field) &
           " = ALB_bor(ALB_band(" & Base_Expr & "." & To_String (Fields (Field_Id).Moon_Field) &
           ", ALB_bnot(ALB_shl(" & Trim_Image (Mask) & ", " & Trim_Image (Fields (Field_Id).Bit_Shift) &
           "))), ALB_shl(ALB_band(ALB_num(" & Value_Expr & "), " & Trim_Image (Mask) & "), " &
           Trim_Image (Fields (Field_Id).Bit_Shift) & "))";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).Moon_Field) &
           " = " & Value_Expr;
      end if;
   end Field_Write_Expr;

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

   function Find_Routine (Moon_Name : String) return Natural is
   begin
      for I in 1 .. Routine_Count loop
         if Routines (I).Active and then To_String (Routines (I).Moon_Name) = Moon_Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Routine;

   procedure Register_Symbol
     (Scope        : String;
      Name         : String;
      Moon_Name      : String;
      Tag          : Value_Kind;
      Kind         : Symbol_Kind;
      Rank         : Natural := 0;
      Dims         : Dim_List := (others => 0);
      Capacity     : Integer := 0;
      Active_Size  : Integer := 0;
      History_Size : Integer := 0;
      Struct_Name  : String := "";
      Offset_Bytes : Integer := 0) is
   begin
      if Find_Symbol (Scope, Name) /= 0 then
         return;
      end if;

      if Symbol_Count < Max_Symbols then
         Symbol_Count := Symbol_Count + 1;
         Symbols (Symbol_Count).Active := True;
         Symbols (Symbol_Count).Scope := U (Scope);
         Symbols (Symbol_Count).Name := U (Name);
         Symbols (Symbol_Count).Moon_Name := U (Moon_Name);
         Symbols (Symbol_Count).Tag := Tag;
         Symbols (Symbol_Count).Kind := Kind;
         Symbols (Symbol_Count).Rank := Rank;
         Symbols (Symbol_Count).Dims := Dims;
         Symbols (Symbol_Count).Capacity := Capacity;
         Symbols (Symbol_Count).Active_Size := Active_Size;
         Symbols (Symbol_Count).History_Size := History_Size;
         Symbols (Symbol_Count).Struct_Name := U (Struct_Name);
         Symbols (Symbol_Count).Offset_Bytes := Offset_Bytes;
         Symbols (Symbol_Count).Aux_Offset := 0;
      end if;
   end Register_Symbol;

   procedure Register_Routine
     (Name        : String;
      Moon_Name     : String;
      Param_Count : Natural;
      Param_Modes : Param_Mode_List) is
      Existing : constant Natural := Find_Routine (Moon_Name);
   begin
      if Existing /= 0 then
         Routines (Existing).Param_Count := Param_Count;
         Routines (Existing).Param_Modes := Param_Modes;
         return;
      end if;

      if Routine_Count < Max_Routines then
         Routine_Count := Routine_Count + 1;
         Routines (Routine_Count).Active := True;
         Routines (Routine_Count).Name := U (Name);
         Routines (Routine_Count).Moon_Name := U (Moon_Name);
         Routines (Routine_Count).Param_Count := Param_Count;
         Routines (Routine_Count).Param_Modes := Param_Modes;
      end if;
   end Register_Routine;

   procedure Emit_Current_Out_Writebacks is
   begin
      for I in 1 .. Current_Routine_Out_Count loop
         Line
           ("__out_" & To_String (Current_Routine_Out_Names (I)) &
              ".value = " & To_String (Current_Routine_Out_Names (I)));
      end loop;
   end Emit_Current_Out_Writebacks;

   function Push_Shadow_Symbol
     (Scope   : String;
      Name    : String;
      Moon_Name : String;
      Tag     : Value_Kind;
      Kind    : Symbol_Kind := Sym_Scalar) return Natural
   is
   begin
      if Symbol_Count >= Max_Symbols then
         return 0;
      end if;

      Symbol_Count := Symbol_Count + 1;
      Symbols (Symbol_Count).Active := True;
      Symbols (Symbol_Count).Name := U (Name);
      Symbols (Symbol_Count).Scope := U (Scope);
      Symbols (Symbol_Count).Moon_Name := U (Moon_Name);
      Symbols (Symbol_Count).Struct_Name := U ("");
      Symbols (Symbol_Count).Tag := Tag;
      Symbols (Symbol_Count).Kind := Kind;
      Symbols (Symbol_Count).Rank := 0;
      Symbols (Symbol_Count).Dims := (others => 0);
      Symbols (Symbol_Count).Capacity := 0;
      Symbols (Symbol_Count).Active_Size := 0;
      Symbols (Symbol_Count).History_Size := 0;
      Symbols (Symbol_Count).Offset_Bytes := 0;
      Symbols (Symbol_Count).Aux_Offset := 0;
      return Symbol_Count;
   end Push_Shadow_Symbol;

   procedure Pop_Shadow_Symbol (Id : Natural) is
   begin
      if Id in 1 .. Symbol_Count then
         Symbols (Id).Active := False;
      end if;
   end Pop_Shadow_Symbol;

   function Resolve_Var_Name (Raw : String) return String is
      Idx : Natural := 0;
      Scoped : constant String := Scoped_Name (Raw);
   begin
      if Length (Current_Routine) > 0 then
         Idx := Find_Symbol (To_String (Current_Routine), Raw);
         if Idx /= 0 then
            return To_String (Symbols (Idx).Moon_Name);
         end if;
      end if;

      Idx := Find_Symbol ("", Scoped);
      if Idx /= 0 then
         return To_String (Symbols (Idx).Moon_Name);
      end if;

      Idx := Find_Symbol ("", Safe_Moon_Name (Raw));
      if Idx /= 0 then
         return To_String (Symbols (Idx).Moon_Name);
      end if;

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return To_String (Symbols (Idx).Moon_Name);
      end if;

      return Safe_Moon_Name (Raw);
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

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      return Dummy;
   end Resolve_Symbol;

   function Target_Symbol (Target_Node : Node_Index) return Symbol_Record is
      Node  : constant AST_Node := Tree (Target_Node);
      Dummy : Symbol_Record;
   begin
      if Target_Node = 0 then
         return Dummy;
      elsif Node.Kind = AST_Var_Expr then
         return Resolve_Symbol
           ((if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else ""));
      elsif Node.Kind = AST_Temporal_Ref then
         if Node.Left_Child > 0 then
            return Target_Symbol (Node.Left_Child);
         end if;
         return Dummy;
      elsif Node.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (Node.Left_Child);
            Right_Node : constant AST_Node := Tree (Node.Right_Child);
            Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
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
                     return Symbols (Field_Sym_Id);
                  end if;
               end;
            end if;

            if Group_Sym.Active then
               return Group_Sym;
            end if;

            return Resolve_Symbol (Collect_Module_Member_Name (Target_Node));
         end;
      end if;

      return Dummy;
   end Target_Symbol;

   function Resolve_Routine_Name (Raw : String) return String is
      Scoped_Moon : constant String := Scoped_Name (Raw);
      Plain_Moon  : constant String := Safe_Moon_Name (Raw);
   begin
      if Find_Routine (Scoped_Moon) /= 0 then
         return Scoped_Moon;
      elsif Find_Routine (Plain_Moon) /= 0 then
         return Plain_Moon;
      else
         return "";
      end if;
   end Resolve_Routine_Name;

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

   function Routine_Has_Out (Routine_Id : Natural) return Boolean is
   begin
      if Routine_Id = 0 then
         return False;
      end if;
      for I in 1 .. Routines (Routine_Id).Param_Count loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            return True;
         end if;
      end loop;
      return False;
   end Routine_Has_Out;

   function Peel_To_Func_Call (Node : Node_Index) return Node_Index is
      Curr : Node_Index := Node;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Cast_Expr | AST_Constructor =>
               Curr := Tree (Curr).Left_Child;

            when AST_BinOp =>
               if Tree (Curr).Token_Index > 0
                 and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Assign
               then
                  Curr := Tree (Curr).Right_Child;
               else
                  exit;
               end if;

            when AST_Func_Call =>
               return Curr;

            when others =>
               exit;
         end case;
      end loop;
      return 0;
   end Peel_To_Func_Call;

   function Find_Func_Call_In_Expr (Node : Node_Index) return Node_Index is
      Peeled : constant Node_Index := Peel_To_Func_Call (Node);
   begin
      if Peeled /= 0 then
         return Peeled;
      end if;

      if Node = 0 then
         return 0;
      elsif Tree (Node).Kind = AST_BinOp then
         declare
            Right_Call : constant Node_Index :=
              Find_Func_Call_In_Expr (Tree (Node).Right_Child);
         begin
            if Right_Call /= 0 then
               return Right_Call;
            end if;
            return Find_Func_Call_In_Expr (Tree (Node).Left_Child);
         end;
      else
         return 0;
      end if;
   end Find_Func_Call_In_Expr;

   function Func_Call_Target_Name (Call_Node : Node_Index) return String is
      Target_Node : constant Node_Index := Tree (Call_Node).Left_Child;
   begin
      if Target_Node = 0 then
         return "";
      elsif Tree (Target_Node).Kind = AST_Member_Expr then
         return Collect_Module_Member_Name (Target_Node);
      elsif Tree (Target_Node).Token_Index > 0 then
         declare
            Resolved : constant String :=
              Resolve_Routine_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
         begin
            if Resolved'Length > 0 then
               return Resolved;
            else
               return Safe_Moon_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
            end if;
         end;
      else
         return "";
      end if;
   end Func_Call_Target_Name;

   function Find_Routine_For_Call (Target_Name : String) return Natural is
      Id : Natural := Find_Routine (Target_Name);
   begin
      if Id /= 0 then
         return Id;
      end if;

      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then To_String (Routines (I).Moon_Name) = Target_Name
         then
            return I;
         end if;
      end loop;

      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then Ada.Strings.Fixed.Index (Target_Name, To_String (Routines (I).Moon_Name)) > 0
         then
            return I;
         end if;
      end loop;

      if Ada.Strings.Fixed.Index (Target_Name, "VecU32At") > 0 then
         Id := Find_Routine ("ALBVector_VecU32At");
         if Id /= 0 then
            return Id;
         end if;
      end if;

      return 0;
   end Find_Routine_For_Call;

   function Emit_Value_Expr_With_Out (Value_Node : Node_Index) return String is
      Call_Node   : Node_Index := 0;
      Target_Name : String := "";
      Routine_Id  : Natural := 0;
   begin
      Call_Node := Find_Func_Call_In_Expr (Value_Node);
      if Call_Node = 0 then
         return Expr (Value_Node);
      end if;

      Target_Name := Func_Call_Target_Name (Call_Node);
      if Target_Name'Length = 0 then
         return Expr (Value_Node);
      end if;

      Routine_Id := Find_Routine_For_Call (Target_Name);
      if Routine_Has_Out (Routine_Id)
        or else Ada.Strings.Fixed.Index (Target_Name, "VecU32At") > 0
      then
         return Emit_Call_Expr_With_Out
           (Target_Name, Tree (Call_Node).Right_Child);
      end if;

      return Expr (Value_Node);
   exception
      when others =>
         return Expr (Value_Node);
   end Emit_Value_Expr_With_Out;

   function Out_Arg_Name (Arg_Node : Node_Index) return String is
   begin
      if Arg_Node > 0
        and then Tree (Arg_Node).Kind = AST_Var_Expr
        and then Tree (Arg_Node).Left_Child = 0
        and then Tree (Arg_Node).Token_Index > 0
      then
         return Resolve_Var_Name (Raw_Lexeme (Tree (Arg_Node).Token_Index));
      else
         return Statement_Target_Name (Arg_Node);
      end if;
   end Out_Arg_Name;

   function Join_Arg_List_For_Call
     (Arg_List   : Node_Index;
      Routine_Id : Natural) return String is
      Args     : Unbounded_String := U ("");
      Curr     : Node_Index := 0;
      First    : Boolean := True;
      Param_No : Natural := 0;
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
            Param_No := Param_No + 1;
            if not First then
               Append (Args, ", ");
            end if;
            if Routine_Id > 0
              and then Param_No <= Routines (Routine_Id).Param_Count
              and then Routines (Routine_Id).Param_Modes (Param_No) = Param_Out
            then
               Args := Args & ("{ value: " & Out_Arg_Name (Curr) & " }");
            else
               Args := Args & Expr (Curr);
            end if;
            First := False;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;

      return To_String (Args);
   end Join_Arg_List_For_Call;

   function Emit_Call_Expr_With_Out
     (Target_Name : String;
      Arg_List    : Node_Index) return String is
      Routine_Id : constant Natural := Find_Routine_For_Call (Target_Name);
      Curr       : Node_Index := 0;
      Param_No   : Natural := 0;
      Decls      : Unbounded_String := U ("");
      Writes     : Unbounded_String := U ("");
      Call_Args  : Unbounded_String := U ("");
      First      : Boolean := True;
   begin
      if Routine_Id = 0 then
         return Target_Name & "(" & Join_Arg_List (Arg_List) & ")";
      end if;

      if Arg_List > 0 and then Tree (Arg_List).Kind = AST_Arg_List then
         Curr := Tree (Arg_List).Left_Child;
      else
         Curr := Arg_List;
      end if;

      while Curr > 0 and then Param_No < Max_Params loop
         Param_No := Param_No + 1;
         if Routines (Routine_Id).Param_Modes (Param_No) = Param_Out then
            if Length (Decls) > 0 then
               Decls := Decls & " ";
            end if;
            Decls :=
              Decls &
              ("__out_ = nil" & Trim_Image (Integer (Param_No)) &
                 " = { value: " & Out_Arg_Name (Curr) & " }");
            if Length (Writes) > 0 then
               Writes := Writes & " ";
            end if;
            Writes :=
              Writes &
              (Out_Arg_Name (Curr) &
                 " = __out_" & Trim_Image (Integer (Param_No)) & ".value");
            if not First then
               Call_Args := Call_Args & ", ";
            end if;
            Call_Args := Call_Args & ("__out_" & Trim_Image (Integer (Param_No)));
         else
            if not First then
               Call_Args := Call_Args & ", ";
            end if;
            Call_Args := Call_Args & Expr (Curr);
         end if;
         First := False;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      return
        "(-> " & To_String (Decls) &
        " __ret = " & Target_Name & "(" & To_String (Call_Args) & "); " &
        To_String (Writes) & " return __ret)()";
   exception
      when others =>
         return Target_Name & "(" & Join_Arg_List (Arg_List) & ")";
   end Emit_Call_Expr_With_Out;

   function Predicate_Key_Expr (Pred_Node : Node_Index) return String is
      Node : constant AST_Node := Tree (Pred_Node);
   begin
      if Pred_Node = 0 then
         return Escape_Moon_String ("");
      end if;

      case Node.Kind is
         when AST_Assert_Stmt | AST_Retract_Stmt =>
            return "ALB_PRED(" &
              Escape_Moon_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Expr (Node.Left_Child) else "") &
              ")";
         when AST_Predicate =>
            return "ALB_PRED(" &
              Escape_Moon_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Join_Arg_List (Node.Left_Child) else "") &
              ")";
         when AST_Func_Call =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               return "ALB_PRED(" &
                 Escape_Moon_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                 (if Node.Right_Child > 0 then ", " & Join_Arg_List (Node.Right_Child) else "") &
                 ")";
            end if;
            return Expr (Pred_Node);
         when AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            return Escape_Moon_String (Raw_Lexeme (Node.Token_Index));
         when others =>
            return Expr (Pred_Node);
      end case;
   end Predicate_Key_Expr;

   function Static_Int_Pow
     (Base     : Integer;
      Exponent : Integer) return Integer is
      Result : Integer := 1;
   begin
      if Exponent < 0 then
         return 0;
      end if;

      for I in 1 .. Exponent loop
         Result := Result * Base;
      end loop;

      return Result;
   exception
      when others =>
         return 0;
   end Static_Int_Pow;

   function Eval_Static_Int (Index : Node_Index) return Integer;

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
               Name : constant String := Safe_Moon_Name (T (T'First + 1 .. T'Last));
               Idx  : constant Natural := Find_Symbol ("", Name);
            begin
               if Idx /= 0 then
                  return Symbols (Idx).Capacity;
               end if;
            end;
            return 0;
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
               when Tok_Pow =>
                  return Static_Int_Pow (Left_Val, Right_Val);
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

   function Escape_Moon_String (Text : String) return String is
      R : Unbounded_String := U ("""");
      C : Character;
   begin
      for I in Text'Range loop
         C := Text (I);
         case C is
            when '"' =>
               Append (R, "\" & """");
            when '\' =>
               Append (R, "\\");
            when ASCII.LF =>
               Append (R, "\n");
            when ASCII.CR =>
               Append (R, "\r");
            when ASCII.HT =>
               Append (R, "\t");
            when others =>
               Append (R, C);
         end case;
      end loop;
      Append (R, """");
      return To_String (R);
   end Escape_Moon_String;

   function Strip_String_Node (Idx : Node_Index) return String is
      Tok : Token;
   begin
      if Idx = 0 or else Tree (Idx).Token_Index = 0 then
         return "";
      end if;

      Tok := Tokens (Tree (Idx).Token_Index);
      if Tok.Length >= 2 then
         return Input_Buffer (Tok.Start + 1 .. Tok.Start + Tok.Length - 2);
      else
         return "";
      end if;
   end Strip_String_Node;

   function Foreign_Link_From_Kind (Kind : Node_Kind) return Foreign_Link_Kind is
   begin
      case Kind is
         when AST_Import_ES | AST_Export_ES =>
            return Foreign_ES;
         when AST_Import_WASM | AST_Export_WASM =>
            return Foreign_WASM;
         when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar |
              AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar =>
            return Foreign_Compat;
         when others =>
            return Foreign_None;
      end case;
   end Foreign_Link_From_Kind;

   function MoonImport_Specifier (Raw_Path : String) return String is
      use type Ada.Directories.File_Kind;
      Trimmed : constant String :=
        Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);
      function Normalize_Module_Path (Text : String) return String is
         Result : String (1 .. Text'Length) := Text;
      begin
         for I in Result'Range loop
            if Result (I) = '\' then
               Result (I) := '/';
            end if;
         end loop;
         return Result;
      end Normalize_Module_Path;
   begin
      if Trimmed'Length = 0 then
         return "./missing.js";
      end if;

      if Trimmed'Length >= 5
        and then Trimmed (Trimmed'First .. Trimmed'First + 4) = "data:"
      then
         return Trimmed;
      end if;

      for I in Trimmed'First + 1 .. Trimmed'Last loop
         if Trimmed (I) = ':' then
            return Trimmed;
         elsif Trimmed (I) = '/' or else Trimmed (I) = '\' then
            exit;
         end if;
      end loop;

      if Trimmed (Trimmed'First) = '.' then
         return Normalize_Module_Path (Trimmed);
      end if;

      for I in Trimmed'Range loop
         if Trimmed (I) = '/' or else Trimmed (I) = '\' then
            return "./" & Ada.Directories.Base_Name (Trimmed);
         end if;
      end loop;

      if Trimmed (Trimmed'First) = '.'
        or else Trimmed (Trimmed'First) = '/'
        or else Trimmed (Trimmed'First) = '\'
      then
         return "./" & Ada.Directories.Base_Name (Trimmed);
      end if;

      return Trimmed;
   exception
      when others =>
         return "./" & Safe_Moon_Name (Trimmed);
   end MoonImport_Specifier;

   function Resolve_Static_Asset_Path (Raw_Path : String) return String is
      Trimmed : constant String :=
        Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);
      CWD     : constant String := Ada.Directories.Current_Directory;
      Direct  : constant String :=
        (if Length (Shoebox_Root) > 0
         then Ada.Directories.Compose (To_String (Shoebox_Root), Trimmed)
         else Trimmed);
   begin
      if Trimmed'Length = 0 then
         return "";
      end if;

      if Ada.Directories.Exists (Trimmed) then
         return Trimmed;
      elsif Length (Shoebox_Root) > 0 and then Ada.Directories.Exists (Direct) then
         return Direct;
      else
         declare
            Fallback : constant String := Ada.Directories.Compose (CWD, Trimmed);
         begin
            if Ada.Directories.Exists (Fallback) then
               return Fallback;
            elsif Length (Shoebox_Root) > 0 then
               return Direct;
            else
               return Fallback;
            end if;
         end;
      end if;
   exception
      when others =>
         return Trimmed;
   end Resolve_Static_Asset_Path;

   procedure Register_Foreign_Import (Binding_Node : Node_Index) is
      Decl_Node  : constant Node_Index := Tree (Binding_Node).Left_Child;
      Name_Node  : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      Raw_Name   : constant String := (if Name_Node > 0 then Raw_Lexeme (Tree (Name_Node).Token_Index) else "");
      Link_Kind  : constant Foreign_Link_Kind := Foreign_Link_From_Kind (Tree (Binding_Node).Kind);
      Moon_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "ALB_User_GetTickCount"
         else Scoped_Name (Raw_Name));
      Path_Text  : constant String :=
        (if Tree (Binding_Node).Right_Child > 0
         then Strip_String_Node (Tree (Binding_Node).Right_Child)
         else "");
   begin
      if Foreign_Import_Count >= Max_Foreign_Bindings or else Raw_Name'Length = 0 then
         return;
      end if;

      Foreign_Import_Count := Foreign_Import_Count + 1;
      Foreign_Imports (Foreign_Import_Count).Active := True;
      Foreign_Imports (Foreign_Import_Count).Node := Binding_Node;
      Foreign_Imports (Foreign_Import_Count).Link_Kind := Link_Kind;
      Foreign_Imports (Foreign_Import_Count).Name := U (Raw_Name);
      Foreign_Imports (Foreign_Import_Count).Moon_Name := U (Moon_Name);
      Foreign_Imports (Foreign_Import_Count).Path := U (Path_Text);
      Foreign_Imports (Foreign_Import_Count).Is_Function := Tree (Decl_Node).Kind = AST_Function_Decl;
      Foreign_Imports (Foreign_Import_Count).Return_Tag := Type_From_Token (Tree (Decl_Node).Token_Index);

      Register_Routine_Signature (Decl_Node);
      if Link_Kind = Foreign_ES or else Link_Kind = Foreign_WASM then
         Need_Module_Support := True;
      end if;
      if Link_Kind = Foreign_WASM then
         Need_Wasm_Loaders := True;
      elsif Link_Kind = Foreign_Compat then
         Need_Compat_Runtime := True;
      end if;
   end Register_Foreign_Import;

   procedure Register_Foreign_Export (Binding_Node : Node_Index) is
      Decl_Node  : constant Node_Index := Tree (Binding_Node).Left_Child;
      Name_Node  : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      Raw_Name   : constant String := (if Name_Node > 0 then Raw_Lexeme (Tree (Name_Node).Token_Index) else "");
      Link_Kind  : constant Foreign_Link_Kind := Foreign_Link_From_Kind (Tree (Binding_Node).Kind);
      Moon_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "ALB_User_GetTickCount"
         else Scoped_Name (Raw_Name));
   begin
      if Foreign_Export_Count >= Max_Foreign_Bindings or else Raw_Name'Length = 0 then
         return;
      end if;

      Foreign_Export_Count := Foreign_Export_Count + 1;
      Foreign_Exports (Foreign_Export_Count).Active := True;
      Foreign_Exports (Foreign_Export_Count).Node := Binding_Node;
      Foreign_Exports (Foreign_Export_Count).Link_Kind := Link_Kind;
      Foreign_Exports (Foreign_Export_Count).Name := U (Raw_Name);
      Foreign_Exports (Foreign_Export_Count).Moon_Name := U (Moon_Name);
      Foreign_Exports (Foreign_Export_Count).Is_Function := Tree (Decl_Node).Kind = AST_Function_Decl;
      Foreign_Exports (Foreign_Export_Count).Return_Tag := Type_From_Token (Tree (Decl_Node).Token_Index);

      if Link_Kind = Foreign_ES or else Link_Kind = Foreign_WASM then
         Need_Module_Support := True;
      elsif Link_Kind = Foreign_Compat then
         Need_Compat_Runtime := True;
      end if;
   end Register_Foreign_Export;

   procedure Scan_Features (First : Node_Index) is
      Curr : Node_Index := First;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Program | AST_Block_Stmt =>
               Scan_Features (Tree (Curr).Left_Child);

            when AST_Module =>
               declare
                  Name_Node    : constant Node_Index := Tree (Curr).Left_Child;
                  Saved_Module : constant Unbounded_String := Current_Module;
               begin
                  if Name_Node > 0 and then Tree (Name_Node).Token_Index > 0 then
                     Current_Module := U (Safe_Moon_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Scan_Features (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;

            when AST_DeclareModule =>
               declare
                  Name_Node    : constant Node_Index := Tree (Curr).Left_Child;
                  Saved_Module : constant Unbounded_String := Current_Module;
               begin
                  if Name_Node > 0 and then Tree (Name_Node).Token_Index > 0 then
                     Current_Module := U (Safe_Moon_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Scan_Features (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;

            when AST_Procedure_Decl | AST_Function_Decl =>
               Register_Routine_Signature (Curr);
               Scan_Features (Tree (Curr).Right_Child);

            when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar =>
               --  DLL/SO imports are native-facing declarations. On the web backend
               --  we keep only the routine signature so separately loaded scripts can
               --  provide the implementation without generating compat shims.
               if Tree (Curr).Left_Child > 0 then
                  Register_Routine_Signature (Tree (Curr).Left_Child);
               end if;

            when AST_Import_ES | AST_Import_WASM =>
               Register_Foreign_Import (Curr);

            when AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar =>
               null;

            when AST_Export_ES | AST_Export_WASM =>
               Register_Foreign_Export (Curr);

            when AST_Static_Sprite_Decl | AST_Static_Surface_Decl | AST_Color_Lut_Decl |
                 AST_Visual_Rule_Decl | AST_Render_Viewport_Decl | AST_Apply_Lut_Stmt |
                 AST_Blit_Safe_Stmt | AST_Set_Shoebox_Stmt =>
               Need_Static_Graphics_Runtime := True;

            when AST_Markov_Model_Decl | AST_Predict_Markov_Stmt =>
               Need_Markov_Runtime := True;

            when AST_Neural_Topology_Decl | AST_Infer_Network_Stmt | AST_Train_Network_Stmt =>
               Need_Neural_Runtime := True;

            when AST_Memory_Firewall_Decl =>
               Need_Firewall_Runtime := True;
               Need_Network_Runtime := True;

            when AST_Network_Socket_Decl |
                 AST_Network_Listen_Stmt | AST_Network_Accept_Stmt |
                 AST_Network_Receive_Stmt | AST_Network_Send_Stmt |
                 AST_Network_Close_Stmt =>
               Need_Network_Runtime := True;

            when AST_Process_Handle_Decl | AST_Read_Process_Memory_Expr |
                 AST_Read_Process_Memory_Stmt | AST_Write_Process_Memory_Stmt |
                 AST_Monitor_Process_Memory_Stmt | AST_Dump_Process_Memory_Stmt |
                 AST_Terminate_Process_Stmt | AST_Create_Process_Stmt |
                 AST_Elevate_Privileges_Stmt | AST_Hack_Memory_Stmt |
                 AST_Inject_Code_Memory_Stmt | AST_Inject_Code_Stmt |
                 AST_Hijack_Process_Memory_Stmt | AST_Sniff_Network_Stmt |
                 AST_Encrypt_File_Stmt | AST_Decrypt_File_Stmt =>
               Need_Process_Runtime := True;

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

   function As_Text_Expr (Node_Index_Value : Node_Index) return String;
   function Firewall_Key_For_Node (Target_Node : Node_Index) return String;
   function Wrap_Firewall_Read
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String;
   function Wrap_Firewall_Write
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String;
   procedure Emit_Firewall_Touch
     (Node_Index_Value : Node_Index;
      Need_Read        : Boolean;
      Need_Write       : Boolean);

   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String is
      Node       : constant AST_Node := Tree (Node_Index_Value);
      Left_Node  : constant Node_Index := Node.Left_Child;
      Right_Node : constant Node_Index := Node.Right_Child;
   begin
      if Left_Node = 0 or else Right_Node = 0 then
         return "alb_missing_member";
      end if;

      return Safe_Moon_Name (Raw_Lexeme (Tree (Left_Node).Token_Index) & "_" &
                           Raw_Lexeme (Tree (Right_Node).Token_Index));
   end Collect_Module_Member_Name;

   function Build_Array_Index
     (Dims       : Dim_List;
      Rank       : Natural;
      Bound_Node : Node_Index) return String
   is
      Bounds : array (1 .. 4) of Unbounded_String := (others => U ("0"));
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
         return "((" & To_String (Bounds (1)) & ") - 1)";
      else
         Append (Expr_Builder, "((" & To_String (Bounds (1)) & ") - 1)");
         for I in 2 .. Rank loop
            Append
              (Expr_Builder,
               " * " & Trim_Image (Dims (I)) & " + ((" &
               To_String (Bounds (I)) & ") - 1)");
         end loop;
         return "(" & To_String (Expr_Builder) & ")";
      end if;
   end Build_Array_Index;

   function Field_Offset_Expr
     (Struct_Name : String;
      Field_Name  : String) return String is
      Field_Id : constant Natural := Find_Field (Struct_Name, Safe_Moon_Name (Field_Name));
   begin
      if Field_Id /= 0 then
         return Trim_Image (Fields (Field_Id).Offset_Bytes);
      else
         return "0";
      end if;
   end Field_Offset_Expr;

   function Address_Expr_For (Target_Node : Node_Index) return String is
      TNode : constant AST_Node := Tree (Target_Node);
   begin
      if Target_Node = 0 then
         return "0";
      elsif TNode.Kind = AST_Var_Expr then
         declare
            Raw_Name : constant String := Raw_Lexeme (TNode.Token_Index);
            S        : constant Symbol_Record := Resolve_Symbol (Raw_Name);
            Elem     : constant Integer := Element_Bytes (S.Tag);
         begin
            if not S.Active or else S.Offset_Bytes <= 0 then
               return "0";
            elsif TNode.Left_Child > 0
              and then S.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               return "(" & Trim_Image (S.Offset_Bytes) & " + (" &
                 Build_Array_Index (S.Dims, S.Rank, TNode.Left_Child) & ") * " &
                 Trim_Image (Elem) & ")";
            else
               return Trim_Image (S.Offset_Bytes);
            end if;
         end;
      elsif TNode.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (TNode.Left_Child);
            Right_Node : constant AST_Node := Tree (TNode.Right_Child);
            Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
            Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
         begin
            if Left_Node.Kind = AST_Var_Expr and then Left_Node.Left_Child > 0 then
               declare
                  Field_Id : Natural := Find_Symbol ("", Scoped_Name (Left_Name) & "." & Right_Name);
               begin
                  if Field_Id = 0 then
                     Field_Id := Find_Symbol ("", Left_Name & "." & Right_Name);
                  end if;
                  if Field_Id /= 0 and then Symbols (Field_Id).Offset_Bytes > 0 then
                     return "(" & Trim_Image (Symbols (Field_Id).Offset_Bytes) & " + (" &
                       Build_Array_Index (Symbols (Field_Id).Dims, Symbols (Field_Id).Rank, Left_Node.Left_Child) &
                       ") * " & Trim_Image (Element_Bytes (Symbols (Field_Id).Tag)) & ")";
                  end if;
               end;
            end if;

            if Right_Node.Kind = AST_Var_Expr
              and then Right_Node.Left_Child > 0
              and then Group_Sym.Active
              and then Group_Sym.Offset_Bytes > 0
              and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               return "(" & Trim_Image (Group_Sym.Offset_Bytes) & " + (" &
                 Build_Array_Index (Group_Sym.Dims, Group_Sym.Rank, Right_Node.Left_Child) &
                 ") * " & Trim_Image (Element_Bytes (Group_Sym.Tag)) & ")";
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var and then Left_Sym.Offset_Bytes > 0 then
               return "(" & Trim_Image (Left_Sym.Offset_Bytes) & " + " &
                 Field_Offset_Expr (To_String (Left_Sym.Struct_Name), Right_Name) & ")";
            end if;
            return "0";
         end;
      else
         return "0";
      end if;
   end Address_Expr_For;

   function As_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      return "ALB_text(" & Expr (Node_Index_Value) & ")";
   end As_Text_Expr;

   function Feature_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      if Node_Index_Value = 0 then
         return Escape_Moon_String ("");
      elsif Tree (Node_Index_Value).Kind = AST_String_Expr then
         return Expr (Node_Index_Value);
      elsif Tree (Node_Index_Value).Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
         return Escape_Moon_String (Raw_Feature_Atom (Node_Index_Value));
      else
         return As_Text_Expr (Node_Index_Value);
      end if;
   end Feature_Text_Expr;

   procedure Emit_Warn_Once
     (Key     : String;
      Message : String) is
   begin
      Line ("ALB_WARN_ONCE(" & Escape_Moon_String (Key) & ", " &
            Escape_Moon_String (Message) & ")");
   end Emit_Warn_Once;

   procedure Emit_Fallback_Body (Fallback_Node : Node_Index) is
   begin
      if Fallback_Node = 0 then
         return;
      elsif Tree (Fallback_Node).Kind = AST_Fallback_Block then
         Emit_Block (Tree (Fallback_Node).Left_Child);
      else
         Emit_Block (Fallback_Node);
      end if;
   end Emit_Fallback_Body;

   procedure Ensure_Special_Scalar
     (Raw_Name : String;
      Tag      : Value_Kind := VK_U64) is
      Routine_Name : constant String := To_String (Current_Routine);
      Plain_Moon     : constant String := Safe_Moon_Name (Raw_Name);
      Scoped_Moon    : constant String := Scoped_Name (Raw_Name);
   begin
      if Routine_Name'Length > 0 then
         if Find_Symbol (Routine_Name, Raw_Name) = 0 then
            Register_Symbol (Routine_Name, Raw_Name, Plain_Moon, Tag, Sym_Scalar);
            Line (Plain_Moon & " = " & Default_Value (Tag));
         end if;
      elsif Find_Symbol ("", Scoped_Moon) = 0 and then Find_Symbol ("", Raw_Name) = 0 then
         Register_Symbol ("", Scoped_Moon, Scoped_Moon, Tag, Sym_Scalar);
         Line (Scoped_Moon & " = " & Default_Value (Tag));
      end if;
   end Ensure_Special_Scalar;

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
               return "tonumber(" & Escape_Moon_String ("0b" & T (T'First + 1 .. T'Last)) & ")";
            end;
         when AST_Octal_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return "tonumber(" & Escape_Moon_String ("0" & T (T'First + 1 .. T'Last)) & ", 8)";
            end;
         when AST_String_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               if T'Length >= 2 and then T (T'First) = '"' then
                  return T;
               else
                  return Escape_Moon_String (T);
               end if;
            end;
         when AST_True =>
            return "true";
         when AST_False =>
            return "false";
         when AST_Const_Ref =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return Safe_Moon_Name (T (T'First + 1 .. T'Last));
            end;
         when AST_Var_Expr =>
            declare
               Raw_Name : constant String := To_String (Tok_Text);
               S        : constant Symbol_Record := Resolve_Symbol (Raw_Name);
            begin
               if Node.Left_Child > 0
                 and then S.Active
                 and then S.Kind in Sym_Strict_Array | Sym_Slide_Array
               then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (S.Moon_Name) &
                       "[" & Build_Array_Index (S.Dims, S.Rank, Node.Left_Child) & "]");
               else
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     Resolve_Var_Name (Raw_Name));
               end if;
            end;
         when AST_Member_Expr =>
            declare
               Left_Node  : constant AST_Node := Tree (Node.Left_Child);
               Right_Node : constant AST_Node := Tree (Node.Right_Child);
               Left_Name  : constant String := Raw_Lexeme (Left_Node.Token_Index);
               Right_Name : constant String := Raw_Lexeme (Right_Node.Token_Index);
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
                           To_String (Symbols (Field_Sym_Id).Moon_Name) &
                             "[" &
                             Build_Array_Index
                               (Symbols (Field_Sym_Id).Dims,
                                Symbols (Field_Sym_Id).Rank,
                                Left_Node.Left_Child) &
                             "]");
                     end if;
                  end;
               end if;

               if Right_Node.Kind = AST_Var_Expr
                 and then Right_Node.Left_Child > 0
                 and then Group_Sym.Active
                 and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
               then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Group_Sym.Moon_Name) &
                       "[" &
                       Build_Array_Index
                         (Group_Sym.Dims,
                          Group_Sym.Rank,
                          Right_Node.Left_Child) &
                       "]");
               end if;

               if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                  declare
                     Field_Id : constant Natural :=
                       Find_Field (To_String (Left_Sym.Struct_Name), Safe_Moon_Name (Right_Name));
                  begin
                     return Wrap_Firewall_Read
                       (Node_Index_Value,
                        Field_Read_Expr (To_String (Left_Sym.Moon_Name), Field_Id));
                  end;
               elsif Group_Sym.Active then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Group_Sym.Moon_Name));
               else
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     Collect_Module_Member_Name (Node_Index_Value));
               end if;
            end;
         when AST_BinOp =>
            declare
               L : constant String := Expr (Node.Left_Child);
               R : constant String := Expr (Node.Right_Child);
            begin
               case Tok_Kind is
                  when Tok_Pipe =>
                     return "ALB_concat(" & As_Text_Expr (Node.Left_Child) & ", " &
                       As_Text_Expr (Node.Right_Child) & ")";
                  when Tok_Plus =>
                     return "(" & L & " + " & R & ")";
                  when Tok_Minus =>
                     return "(" & L & " - " & R & ")";
                  when Tok_Mul =>
                     return "(" & L & " * " & R & ")";
                  when Tok_Div =>
                     return "albDiv(" & L & ", " & R & ")";
                  when Tok_Mod =>
                     return "albMod(" & L & ", " & R & ")";
                  when Tok_Pow =>
                     if Uses_Real_Power (Node.Left_Child)
                       or else Uses_Real_Power (Node.Right_Child)
                     then
                        return "math.pow(" & L & ", " & R & ")";
                     end if;
                     return "ALB_POW(" & L & ", " & R & ")";
                  when Tok_Less =>
                     return "((" & L & " < " & R & ") and 1 or 0)";
                  when Tok_Greater =>
                     return "((" & L & " > " & R & ") and 1 or 0)";
                  when Tok_Less_Equal =>
                     return "((" & L & " <= " & R & ") and 1 or 0)";
                  when Tok_Greater_Equal =>
                     return "((" & L & " >= " & R & ") and 1 or 0)";
                  when Tok_Equal | Tok_Assign =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(ALB_truthy(" & R & ") and 1 or 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(ALB_truthy(" & L & ") and 1 or 0)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(ALB_truthy(" & R & ") and 0 or 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(ALB_truthy(" & L & ") and 0 or 1)";
                     end if;
                     return "((" & L & " == " & R & ") and 1 or 0)";
                  when Tok_Not_Equal =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(ALB_truthy(" & R & ") and 0 or 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(ALB_truthy(" & L & ") and 0 or 1)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(ALB_truthy(" & R & ") and 1 or 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(ALB_truthy(" & L & ") and 1 or 0)";
                     end if;
                     return "((" & L & " ~= " & R & ") and 1 or 0)";
                  when Tok_And =>
                     -- ALB AND/OR are bitwise (same as FASM/C/Python). Logical
                     -- short-circuit is ORELSE when implemented. Do not emit JS
                     -- and / or here; that breaks UTF-8, inflate, and JSON masks.
                     return "ALB_band(" & L & ", " & R & ")";
                  when Tok_Or =>
                     return "ALB_bor(" & L & ", " & R & ")";
                  when Tok_Xor =>
                     return "ALB_bxor(" & L & ", " & R & ")";
                  when Tok_Shl =>
                     return "ALB_shl(" & L & ", " & R & ")";
                  when Tok_Shr =>
                     return "ALB_shr(" & L & ", " & R & ")";
                  when others =>
                     return "(" & L & " + " & R & ")";
               end case;
            end;
         when AST_Unary_Minus =>
            return "(-" & Expr (Node.Left_Child) & ")";
         when AST_Not =>
            return "(ALB_truthy(" & Expr (Node.Left_Child) & ") and 0 or 1)";
         when AST_Cast_Expr =>
            return Cast_Expr (Type_From_Token (Node.Token_Index), Expr (Node.Left_Child));
         when AST_Str_Len =>
            return "LEN(" & Expr (Node.Left_Child) & ")";
         when AST_Str_Left =>
            return "LEFT(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Str_Right =>
            return "RIGHT(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Str_Mid =>
            declare
               Start_Node : constant Node_Index :=
                 (if Node.Right_Child > 0
                    and then Tree (Node.Right_Child).Kind = AST_Arg_List
                  then Tree (Node.Right_Child).Left_Child
                  else Node.Right_Child);
               Count_Node : constant Node_Index :=
                 (if Start_Node > 0 then Tree (Start_Node).Next_Sibling else 0);
            begin
               return "MID(" & Expr (Node.Left_Child) & ", " &
                 (if Start_Node > 0 then Expr (Start_Node) else "1") & ", " &
                 (if Count_Node > 0 then Expr (Count_Node) else "0") & ")";
            end;
         when AST_Constructor =>
            declare
               Ctor_Name : constant String := Upper_Text (To_String (Tok_Text));
               A1        : Node_Index := Node.Left_Child;
               A2        : Node_Index := 0;
            begin
               if A1 > 0 then
                  A2 := Tree (A1).Next_Sibling;
               end if;

               if Ctor_Name = "PURE" or else Ctor_Name = "RATIONAL" then
                  return "PURE(" &
                    (if A1 > 0 then Expr (A1) else "0") &
                    ", " &
                    (if A2 > 0 then Expr (A2) else "1") &
                    ")";
               elsif Ctor_Name = "U8" then
                  return Cast_Expr (VK_U8, Expr (A1));
               elsif Ctor_Name = "U16" then
                  return Cast_Expr (VK_U16, Expr (A1));
                elsif Ctor_Name = "U32" then
                   return Cast_Expr (VK_U32, Expr (A1));
                elsif Ctor_Name = "U64" then
                   return Cast_Expr (VK_U64, Expr (A1));
                elsif Ctor_Name = "S8" or else Ctor_Name = "I8" or else Ctor_Name = "INT8" then
                   return Cast_Expr (VK_S8, Expr (A1));
                elsif Ctor_Name = "S16" or else Ctor_Name = "I16" or else Ctor_Name = "INT16" then
                   return Cast_Expr (VK_S16, Expr (A1));
                elsif Ctor_Name = "S32" or else Ctor_Name = "I32" or else Ctor_Name = "INT32" then
                   return Cast_Expr (VK_S32, Expr (A1));
                elsif Ctor_Name = "S64" or else Ctor_Name = "I64" or else Ctor_Name = "INT64" then
                   return Cast_Expr (VK_Number, Expr (A1));
               elsif Ctor_Name = "F64" or else Ctor_Name = "REAL" then
                  return Cast_Expr (VK_F64, Expr (A1));
               elsif Ctor_Name = "HW8" then
                  return Cast_Expr (VK_HW8, Expr (A1));
               elsif Ctor_Name = "HW16" then
                  return Cast_Expr (VK_HW16, Expr (A1));
               elsif Ctor_Name = "HW32" then
                  return Cast_Expr (VK_HW32, Expr (A1));
               else
                  return Expr (A1);
               end if;
            end;
         when AST_Func_Call =>
            declare
               Target_Node : constant Node_Index := Node.Left_Child;
               Arg_List    : constant Node_Index := Node.Right_Child;
               Target_Name : Unbounded_String := U ("alb_missing_call");
               TNode       : AST_Node;
               Raw         : Unbounded_String := U ("");
               Raw_Upper    : Unbounded_String := U ("");
               Routine_Name : Unbounded_String := U ("");
               Args_Text    : constant String := Join_Arg_List (Arg_List);
            begin
               if Target_Node > 0 then
                  TNode := Tree (Target_Node);
                  if TNode.Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
                     Raw := U (Raw_Lexeme (TNode.Token_Index));
                     Raw_Upper := U (Upper_Text (To_String (Raw)));
                     Routine_Name := U (Resolve_Routine_Name (To_String (Raw)));
                     if To_String (Raw_Upper) = "LEFT" or else To_String (Raw_Upper) = "LEFT$" then
                        Target_Name := U ("LEFT");
                     elsif To_String (Raw_Upper) = "RIGHT" or else To_String (Raw_Upper) = "RIGHT$" then
                        Target_Name := U ("RIGHT");
                     elsif To_String (Raw_Upper) = "MID" or else To_String (Raw_Upper) = "MID$" then
                        Target_Name := U ("MID");
                     elsif To_String (Raw_Upper) = "LEN" then
                        Target_Name := U ("LEN");
                     elsif To_String (Raw_Upper) = "CHR" then
                        Target_Name := U ("CHR");
                     elsif To_String (Raw_Upper) = "ASC" then
                        Target_Name := U ("ASC");
                     elsif To_String (Raw_Upper) = "CONCAT" then
                        Target_Name := U ("CONCAT");
                     elsif To_String (Raw_Upper) = "PRINT_PURE" then
                        Target_Name := U ("PRINT_PURE");
                     elsif To_String (Raw_Upper) = "RATIONAL" then
                        Target_Name := U ("PURE");
                     elsif To_String (Raw_Upper) = "REAL" then
                        Target_Name := U ("F64");
                     elsif To_String (Raw_Upper) = "GETTICKCOUNT" then
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           Target_Name := U ("ALB_GetTickCount");
                        end if;
                      elsif To_String (Raw_Upper) = "U8"
                        or else To_String (Raw_Upper) = "U16"
                        or else To_String (Raw_Upper) = "S8"
                        or else To_String (Raw_Upper) = "S16"
                        or else To_String (Raw_Upper) = "I8"
                        or else To_String (Raw_Upper) = "I16"
                        or else To_String (Raw_Upper) = "INT8"
                        or else To_String (Raw_Upper) = "INT16"
                        or else To_String (Raw_Upper) = "U32"
                        or else To_String (Raw_Upper) = "U64"
                        or else To_String (Raw_Upper) = "S64"
                        or else To_String (Raw_Upper) = "I32"
                        or else To_String (Raw_Upper) = "INT32"
                        or else To_String (Raw_Upper) = "I64"
                        or else To_String (Raw_Upper) = "INT64"
                        or else To_String (Raw_Upper) = "U128"
                        or else To_String (Raw_Upper) = "S32"
                       or else To_String (Raw_Upper) = "F64"
                       or else To_String (Raw_Upper) = "REAL"
                       or else To_String (Raw_Upper) = "HW8"
                       or else To_String (Raw_Upper) = "HW16"
                       or else To_String (Raw_Upper) = "HW32"
                       or else To_String (Raw_Upper) = "SIN"
                       or else To_String (Raw_Upper) = "COS"
                       or else To_String (Raw_Upper) = "SQRT"
                       or else To_String (Raw_Upper) = "EXP"
                       or else To_String (Raw_Upper) = "RND"
                       or else To_String (Raw_Upper) = "COLLIDE_RECT"
                       or else To_String (Raw_Upper) = "PURE"
                       or else To_String (Raw_Upper) = "RATIONAL"
                       or else To_String (Raw_Upper) = "PURE_NUM"
                       or else To_String (Raw_Upper) = "PURE_DEN"
                       or else To_String (Raw_Upper) = "PURE_ADD"
                       or else To_String (Raw_Upper) = "PURE_SUB"
                       or else To_String (Raw_Upper) = "PURE_MUL"
                       or else To_String (Raw_Upper) = "PURE_DIV"
                       or else To_String (Raw_Upper) = "PURE_POW"
                     then
                        Target_Name := Raw_Upper;
                     else
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           Target_Name := U ("ALB_PRED(" &
                             Escape_Moon_String (To_String (Raw)) &
                             (if Args_Text'Length > 0 then ", " & Args_Text else "") &
                             ")");
                        end if;
                     end if;
                  elsif TNode.Kind = AST_Member_Expr then
                     Target_Name := U (Collect_Module_Member_Name (Target_Node));
                  else
                     Target_Name := U (Expr (Target_Node));
                  end if;
               end if;

               if Starts_With (To_String (Target_Name), "ALB_PRED(") then
                  return To_String (Target_Name);
               end if;

               declare
                  Routine_Id : constant Natural :=
                    Find_Routine_For_Call (To_String (Target_Name));
               begin
                  if Routine_Has_Out (Routine_Id)
                    or else Ada.Strings.Fixed.Index (To_String (Target_Name), "VecU32At") > 0
                  then
                     return Emit_Call_Expr_With_Out
                       (To_String (Target_Name), Arg_List);
                  end if;
               end;

               declare
                  Routine_Id : constant Natural :=
                    Find_Routine_For_Call (To_String (Target_Name));
               begin
                  return
                    To_String (Target_Name) & "(" &
                    Join_Arg_List_For_Call (Arg_List, Routine_Id) & ")";
               end;
            end;
         when AST_Key_State =>
            return "ALB_KEY(" & Expr (Node.Left_Child) & ")";
         when AST_Mouse_X =>
            return "ALB_MOUSE_X()";
         when AST_Mouse_Y =>
            return "ALB_MOUSE_Y()";
         when AST_Mouse_Wheel =>
            return "ALB_MOUSE_WHEEL()";
         when AST_Mouse_Click =>
            return "ALB_MOUSE_CLICK(" &
              (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "0") & ")";
         when AST_VMouse_X =>
            return "ALB_VMOUSE_X()";
         when AST_VMouse_y =>
            return "ALB_VMOUSE_Y()";
         when AST_SCREEN_WIDTH =>
            return "ALB_SCREEN_WIDTH()";
         when AST_SCREEN_HEIGHT =>
            return "ALB_SCREEN_HEIGHT()";
         when AST_VIRTUAL_WIDTH =>
            return "ALB_VIRTUAL_WIDTH()";
         when AST_VIRTUAL_HEIGHT =>
            return "ALB_VIRTUAL_HEIGHT()";
         when AST_Peek_Expr =>
            return "ALB_PEEK(" & Expr (Node.Left_Child) & ")";
         when AST_Deref_Expr =>
            return "ALB_DEREF(" & Expr (Node.Left_Child) & ")";
         when AST_AddressOf | AST_Ref_Expr =>
            return Address_Expr_For (Node.Left_Child);
         when AST_Read_Process_Memory_Expr =>
            return "ALB_PROCESS_READ_SCALAR(" &
              Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Read_Pixel =>
            return "ALB_READ_PIXEL(" & Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Rnd_Expr =>
            return "ALB_RND(" & Expr (Node.Left_Child) & ")";
         when AST_SizeOf_Expr =>
            declare
               Size_Sym : Symbol_Record;
            begin
               if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
                  Size_Sym := Resolve_Symbol (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
                  if Size_Sym.Active then
                     return Trim_Image (Element_Bytes (Size_Sym.Tag));
                  end if;
               end if;
               return "4";
            end;
         when AST_OffsetOf_Expr =>
            if Node.Left_Child > 0 and then Node.Right_Child > 0 then
               return Field_Offset_Expr
                 (Safe_Moon_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)),
                  Raw_Lexeme (Tree (Node.Right_Child).Token_Index));
            else
               return "0";
            end if;
         when AST_TypeOf_Expr =>
            return Escape_Moon_String ("number");
         when AST_Temporal_Ref =>
            declare
               Base_Name : constant String := Raw_Lexeme (Tree (Node.Left_Child).Token_Index);
               Lua_Base   : constant String := Resolve_Var_Name (Base_Name);
               Sel       : constant Token_Kind := Tokens (Node.Token_Index).Kind;
               TSym      : constant Symbol_Record := Resolve_Symbol (Base_Name);
               Hist      : constant String := Trim_Image (Integer'Max (1, TSym.History_Size));
            begin
               case Sel is
                  when Tok_Now =>
                     return Lua_Base;
                  when Tok_Past =>
                     return Lua_Base & "_history[(" & Lua_Base & "_head + " & Hist & " - 1) % " & Hist & "]";
                  when Tok_Future =>
                     return Lua_Base & "_history[(" & Lua_Base & "_head + 1) % " & Hist & "]";
                  when Tok_Timeline =>
                     return Trim_Image (TSym.Aux_Offset);
                  when others =>
                     return Lua_Base;
               end case;
            end;
         when AST_Find_Query =>
            if Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND" then
               if Node.Left_Child > 0 then
                  return "ALB_REL_FIND1(" & Predicate_Id_Expr (Node.Left_Child) & ")";
               else
                  return "0";
               end if;
            else
               return "ALB_REL_HAS(" &
                 Predicate_Id_Expr (Node_Index_Value) & ", " &
                 Predicate_Arity_Expr (Node_Index_Value) & ", " &
                 Predicate_Arg1_Expr (Node_Index_Value) &
                 ", 0, 0, 0)";
            end if;
         when AST_Query =>
            if Node.Left_Child > 0 then
               return "ALB_REL_HAS(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_Knows_Query =>
            if Node.Left_Child > 0 then
               return "ALB_REL_HAS(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_File_Open =>
            return "ALB_Open(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Len =>
            return "ALB_FileLen(" & Expr (Node.Left_Child) & ")";
         when AST_File_Seek =>
            return "ALB_Seek(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Read =>
            return "ALB_Read(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Inline_Typescript_Expr =>
            return Raw_Lexeme (Node.Token_Index);
         when others =>
            return "0";
      end case;
   end Expr;

   procedure Emit_Runtime is
   begin
      Line ("-- Generated by ALBM - AdaLogic BASIC to MoonScript");
      Line ("-- Self-contained MoonScript runtime (compiles to Lua)");
      New_Line_Emit;
      Line ("albWarnedKeys = {}");
      Line ("albSaveStore = {}");
      Line ("albKeys = {}");
      Line ("albMouseButtons = {}");
      Line ("albVas = {}");
      Line ("albGcAlive = {}");
      Line ("albGcRefs = {}");
      Line ("albGcChildA = {}");
      Line ("albGcChildB = {}");
      Line ("albGcChildC = {}");
      Line ("albGcChildD = {}");
      Line ("albFactLive = {}");
      Line ("albFactKey = {}");
      Line ("albFactValue = {}");
      Line ("albRelLive = {}");
      Line ("albRelPred = {}");
      Line ("albRelArity = {}");
      Line ("albRelArg1 = {}");
      Line ("albRelArg2 = {}");
      Line ("albRelArg3 = {}");
      Line ("albRelArg4 = {}");
      Line ("albRelValue = {}");
      Line ("albRuleHeadPred = {}");
      Line ("albRuleFlags = {}");
      Line ("albRuleBodyLen = {}");
      Line ("albRuleBodyPred = {}");
      Line ("albRuleBodyArgMode = {}");
      Line ("albRuleBodyArgConst = {}");
      Line ("albRuleCount = 0");
      Line ("albFileLive = {}");
      Line ("albFileMode = {}");
      Line ("albFileName = {}");
      Line ("albFileBuffer = {}");
      Line ("albFileCursor = {}");
      Line ("albTextRows = {""""}");
      Line ("albTextCursorX = 1");
      Line ("albTextCursorY = 1");
      Line ("albConsoleDisabled = " &
            (if No_Console_Overlay then "true" else "false"));
      Line ("albCurrentColor = 0xffffffff");
      Line ("albColorValue = 0xffffffff");
      Line ("albBaseWidth = 320");
      Line ("albBaseHeight = 200");
      Line ("albWindowWidth = 320");
      Line ("albWindowHeight = 200");
      Line ("albVirtualWidth = 320");
      Line ("albVirtualHeight = 200");
      Line ("albOriginX = 0");
      Line ("albOriginY = 0");
      Line ("albAlphaChannel = 0");
      Line ("albAlphaValue = 255");
      Line ("albStretchy = false");
      Line ("albResizable = true");
      Line ("albRunning = true");
      Line ("albShutdownDone = false");
      Line ("albMouseX = 0");
      Line ("albMouseY = 0");
      Line ("albMouseWheel = 0");
      Line ("albDelayUntil = 0");
      Line ("albFrameInterval = 16");
      Line ("albLastFrame = 0");
      Line ("albCompatTick = 0");
      Line ("albNextProcessHandle = 1");
      Line ("albProcessTable = {}");
      Line ("albProcessMonitor = {}");
      Line ("albNextNetworkHandle = 1");
      Line ("albNetworkTable = {}");
      Line ("albNextSnifferHandle = 1");
      Line ("albSnifferTable = {}");
      Line ("albNetworkBus = {}");
      Line ("albFirewallStack = {}");
      Line ("albClipRect = nil");
      Line ("albCurrentFont = {name: ""monospace"", size: 16}");
      Line ("ALB_STATIC_Active_Lut = nil");
      Line ("ALB_STATIC_Active_Visual = nil");
      Line ("ALB_STATIC_Active_Context = nil");
      Line ("ALB_STATIC_Active_Context_Used = false");
      Line ("albWasmBindings = {}");
      Line ("albWasmLoaders = {}");
      Line ("ALB_WASM_HOST_IMPORTS = {alb: {}}");
      Line ("albCompatExports = {}");
      Line ("ALB_ON_TICK = ->");
      Line ("ALB_ON_PAINT = ->");
      Line ("ALB_ON_KEY = ->");
      Line ("ALB_NOTIFY_KNOWS_CHANGE = (pred, a1, a2, a3, a4) ->");
      Line ("ALB_ProgramShutdown = nil");
      New_Line_Emit;
      Line ("albSDL = nil");
      Line ("albEnsureSDL = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("return albSDL if albSDL ~= nil");
      Line ("ok, mod = pcall(require, ""alb_sdl3"")");
      Line ("if not ok");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_FATAL(""ALBM requires alb_sdl3.dll next to the .moon/.lua (and Lua 5.4). "" .. tostring(mod))");
      Indent_Level := Indent_Level - 1;
      Line ("albSDL = mod");
      Line ("albSDL.init()");
      Line ("return albSDL");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("ALB_now_ms = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("return albSDL.ticks() if albSDL ~= nil");
      Line ("if type(os) == ""table"" and type(os.clock) == ""function""");
      Indent_Level := Indent_Level + 1;
      Line ("return math.floor(os.clock() * 1000)");
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_new_array = (n, fill) ->");
      Indent_Level := Indent_Level + 1;
      Line ("t = {}");
      Line ("v = fill or 0");
      Line ("for i = 0, math.max(0, (n or 0) - 1)");
      Indent_Level := Indent_Level + 1;
      Line ("t[i] = v");
      Indent_Level := Indent_Level - 1;
      Line ("return t");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_filled = (n, fill) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_new_array(n, fill)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_num = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("n = tonumber(v)");
      Line ("return 0 if n == nil");
      Line ("return n");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_truthy = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return false if v == nil or v == false or v == 0 or v == """"");
      Line ("return true");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_band = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(a))");
      Line ("b = math.floor(ALB_num(b))");
      Line ("return bit32.band(a, b) if bit32 and bit32.band");
      Line ("return bit.band(a, b) if bit and bit.band");
      Line ("r, p = 0, 1");
      Line ("while a ~= 0 and b ~= 0");
      Indent_Level := Indent_Level + 1;
      Line ("aa, bb = a % 2, b % 2");
      Line ("r = r + p if aa == 1 and bb == 1");
      Line ("a = math.floor(a / 2)");
      Line ("b = math.floor(b / 2)");
      Line ("p = p * 2");
      Indent_Level := Indent_Level - 1;
      Line ("return r");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_bor = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(a))");
      Line ("b = math.floor(ALB_num(b))");
      Line ("return bit32.bor(a, b) if bit32 and bit32.bor");
      Line ("return bit.bor(a, b) if bit and bit.bor");
      Line ("r, p = 0, 1");
      Line ("while a ~= 0 or b ~= 0");
      Indent_Level := Indent_Level + 1;
      Line ("aa, bb = a % 2, b % 2");
      Line ("r = r + p if aa == 1 or bb == 1");
      Line ("a = math.floor(a / 2)");
      Line ("b = math.floor(b / 2)");
      Line ("p = p * 2");
      Indent_Level := Indent_Level - 1;
      Line ("return r");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_bxor = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(a))");
      Line ("b = math.floor(ALB_num(b))");
      Line ("return bit32.bxor(a, b) if bit32 and bit32.bxor");
      Line ("return bit.bxor(a, b) if bit and bit.bxor");
      Line ("r, p = 0, 1");
      Line ("while a ~= 0 or b ~= 0");
      Indent_Level := Indent_Level + 1;
      Line ("aa, bb = a % 2, b % 2");
      Line ("r = r + p if aa ~= bb");
      Line ("a = math.floor(a / 2)");
      Line ("b = math.floor(b / 2)");
      Line ("p = p * 2");
      Indent_Level := Indent_Level - 1;
      Line ("return r");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_bnot = (a) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(a))");
      Line ("return bit32.bnot(a) if bit32 and bit32.bnot");
      Line ("return bit.bnot(a) if bit and bit.bnot");
      Line ("return (-1 - a)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_shl = (a, n) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(a))");
      Line ("n = math.floor(ALB_num(n))");
      Line ("return bit32.lshift(a, n) if bit32 and bit32.lshift");
      Line ("return bit.lshift(a, n) if bit and bit.lshift");
      Line ("return math.floor(a * (2 ^ n))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_shr = (a, n) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(a))");
      Line ("n = math.floor(ALB_num(n))");
      Line ("return bit32.rshift(a, n) if bit32 and bit32.rshift");
      Line ("return bit.rshift(a, n) if bit and bit.rshift");
      Line ("return math.floor(a / (2 ^ n))");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_FATAL = (err) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albRunning = false");
      Line ("message = tostring(err)");
      Line ("io.stderr\write(""ALBM fatal: "" .. message .. ""\n"")");
      Line ("error(message, 0)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_WARN_ONCE = (key, message) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albWarnedKeys[key]");
      Line ("albWarnedKeys[key] = true");
      Line ("io.stderr\write(""ALBM: "" .. tostring(message) .. ""\n"")");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_text = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return """" if v == nil");
      Line ("return v and ""1"" or ""0"" if type(v) == ""boolean""");
      Line ("return tostring(v)");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_Text = ALB_text");
      New_Line_Emit;
      Line ("export ALB_concat = (...) ->");
      Indent_Level := Indent_Level + 1;
      Line ("parts = {...}");
      Line ("out = {}");
      Line ("for i = 1, #parts");
      Indent_Level := Indent_Level + 1;
      Line ("out[i] = ALB_text(parts[i])");
      Indent_Level := Indent_Level - 1;
      Line ("return table.concat(out)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("albEnsureTextRow = (row) ->");
      Indent_Level := Indent_Level + 1;
      Line ("while #albTextRows < row");
      Indent_Level := Indent_Level + 1;
      Line ("albTextRows[#albTextRows + 1] = """"");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("albWriteText = (text) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 1, #text");
      Indent_Level := Indent_Level + 1;
      Line ("ch = text\sub(i, i)");
      Line ("if ch == ""\r""");
      Indent_Level := Indent_Level + 1;
      Line ("nil");
      Indent_Level := Indent_Level - 1;
      Line ("elseif ch == ""\n""");
      Indent_Level := Indent_Level + 1;
      Line ("albTextCursorY = albTextCursorY + 1");
      Line ("albTextCursorX = 1");
      Line ("albEnsureTextRow(albTextCursorY)");
      Indent_Level := Indent_Level - 1;
      Line ("else");
      Indent_Level := Indent_Level + 1;
      Line ("albEnsureTextRow(albTextCursorY)");
      Line ("row = albTextCursorY");
      Line ("col = math.max(1, math.floor(albTextCursorX))");
      Line ("line = albTextRows[row] or """"");
      Line ("if col > #line + 1");
      Indent_Level := Indent_Level + 1;
      Line ("line = line .. string.rep("" "", col - #line - 1)");
      Indent_Level := Indent_Level - 1;
      Line ("albTextRows[row] = line\sub(1, col - 1) .. ch .. line\sub(col + 1)");
      Line ("albTextCursorX = col + 1");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_PRINT = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albConsoleDisabled");
      Line ("text = ALB_text(v)");
      Line ("print(text)");
      Line ("albWriteText(text)");
      Line ("albTextCursorY = albTextCursorY + 1");
      Line ("albTextCursorX = 1");
      Line ("albEnsureTextRow(albTextCursorY)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_PRINT_RAW = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albConsoleDisabled");
      Line ("text = ALB_text(v)");
      Line ("io.write(text)");
      Line ("io.flush()");
      Line ("albWriteText(text)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_PROMPT_TEXT = (promptText) ->");
      Indent_Level := Indent_Level + 1;
      Line ("prompt = ALB_text(promptText or """")");
      Line ("ALB_PRINT(prompt) if #prompt > 0");
      Line ("ok, line = pcall -> io.read(""*l"")");
      Line ("return """" if not ok or line == nil");
      Line ("ALB_PRINT(""> "" .. line)");
      Line ("return line");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_READLINE_TEXT = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("return ALB_PROMPT_TEXT("""")");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_LOCATE = (x, y) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albConsoleDisabled");
      Line ("albTextCursorX = math.max(1, math.floor(ALB_num(x)))");
      Line ("albTextCursorY = math.max(1, math.floor(ALB_num(y)))");
      Line ("albEnsureTextRow(albTextCursorY)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("albU8 = (v) -> return ALB_band(ALB_num(v), 0xff)");
      Line ("albU16 = (v) -> return ALB_band(ALB_num(v), 0xffff)");
      Line ("albU32 = (v) -> return ALB_band(ALB_num(v), 0xffffffff)");
      Line ("albI8 = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("n = albU8(v)");
      Line ("return n - 0x100 if n >= 0x80");
      Line ("return n");
      Indent_Level := Indent_Level - 1;
      Line ("albI16 = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("n = albU16(v)");
      Line ("return n - 0x10000 if n >= 0x8000");
      Line ("return n");
      Indent_Level := Indent_Level - 1;
      Line ("albI32 = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("n = albU32(v)");
      Line ("return n - 0x100000000 if n >= 0x80000000");
      Line ("return n");
      Indent_Level := Indent_Level - 1;
      Line ("U8 = (v) -> return albU8(v)");
      Line ("U16 = (v) -> return albU16(v)");
      Line ("S8 = (v) -> return albI8(v)");
      Line ("I8 = (v) -> return albI8(v)");
      Line ("S16 = (v) -> return albI16(v)");
      Line ("I16 = (v) -> return albI16(v)");
      Line ("U32 = (v) -> return albU32(v)");
      Line ("U64 = (v) -> return albU32(v)");
      Line ("U128 = (v) -> return math.floor(ALB_num(v))");
      Line ("S32 = (v) -> return albI32(v)");
      Line ("I32 = (v) -> return albI32(v)");
      Line ("HW8 = (v) -> return albI32(v)");
      Line ("HW16 = (v) -> return albI32(v)");
      Line ("HW32 = (v) -> return albI32(v)");
      Line ("F64 = (v) -> return ALB_num(v)");
      New_Line_Emit;
      Line ("ALB_PURE_NUM_BITS = 21");
      Line ("ALB_PURE_NUM_MOD = ALB_shl(1, ALB_PURE_NUM_BITS)");
      Line ("ALB_PURE_NUM_SIGN = ALB_shl(1, ALB_PURE_NUM_BITS - 1)");
      Line ("ALB_PURE_DEN_LIMIT = 0x7fffffff");
      New_Line_Emit;
      Line ("albPureAbs = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 - v if v < 0");
      Line ("return v");
      Indent_Level := Indent_Level - 1;
      Line ("albPureIsPacked = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("v = math.floor(ALB_num(v))");
      Line ("return v >= ALB_PURE_NUM_MOD");
      Indent_Level := Indent_Level - 1;
      Line ("albPureGcd = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("x = math.floor(albPureAbs(a))");
      Line ("y = math.floor(albPureAbs(b))");
      Line ("while y ~= 0");
      Indent_Level := Indent_Level + 1;
      Line ("t = x % y");
      Line ("x = y");
      Line ("y = t");
      Indent_Level := Indent_Level - 1;
      Line ("return 1 if x == 0");
      Line ("return x");
      Indent_Level := Indent_Level - 1;
      Line ("albPurePack = (num, den) ->");
      Indent_Level := Indent_Level + 1;
      Line ("n = math.floor(num)");
      Line ("d = math.floor(den)");
      Line ("return ALB_PURE_NUM_MOD if d == 0");
      Line ("if d < 0");
      Indent_Level := Indent_Level + 1;
      Line ("n = 0 - n");
      Line ("d = 0 - d");
      Indent_Level := Indent_Level - 1;
      Line ("return ALB_PURE_NUM_MOD if n == 0");
      Line ("g = albPureGcd(n, d)");
      Line ("n = math.floor(n / g)");
      Line ("d = math.floor(d / g)");
      Line ("maxNum = ALB_PURE_NUM_SIGN - 1");
      Line ("while (albPureAbs(n) > maxNum or d > ALB_PURE_DEN_LIMIT) and d > 1");
      Indent_Level := Indent_Level + 1;
      Line ("n = math.floor(n / 2)");
      Line ("d = math.max(1, math.floor(d / 2))");
      Line ("g = albPureGcd(n, d)");
      Line ("n = math.floor(n / g)");
      Line ("d = math.floor(d / g)");
      Indent_Level := Indent_Level - 1;
      Line ("enc = n");
      Line ("enc = ALB_PURE_NUM_MOD + n if n < 0");
      Line ("return d * ALB_PURE_NUM_MOD + enc");
      Indent_Level := Indent_Level - 1;
      Line ("PURE = (num, den) -> return albPurePack(ALB_num(num), ALB_num(den or 1))");
      Line ("export PURE_NUM = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("pv = math.floor(ALB_num(v))");
      Line ("return pv if not albPureIsPacked(pv)");
      Line ("enc = pv % ALB_PURE_NUM_MOD");
      Line ("return enc - ALB_PURE_NUM_MOD if enc >= ALB_PURE_NUM_SIGN");
      Line ("return enc");
      Indent_Level := Indent_Level - 1;
      Line ("export PURE_DEN = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("pv = math.floor(ALB_num(v))");
      Line ("return 1 if not albPureIsPacked(pv)");
      Line ("den = math.floor(pv / ALB_PURE_NUM_MOD)");
      Line ("return 1 if den <= 0");
      Line ("return den");
      Indent_Level := Indent_Level - 1;
      Line ("export PURE_ADD = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("an, ad, bn, bd = PURE_NUM(a), PURE_DEN(a), PURE_NUM(b), PURE_DEN(b)");
      Line ("g = albPureGcd(ad, bd)");
      Line ("leftMul = math.floor(bd / g)");
      Line ("rightMul = math.floor(ad / g)");
      Line ("return albPurePack(an * leftMul + bn * rightMul, ad * leftMul)");
      Indent_Level := Indent_Level - 1;
      Line ("export PURE_SUB = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("an, ad, bn, bd = PURE_NUM(a), PURE_DEN(a), PURE_NUM(b), PURE_DEN(b)");
      Line ("g = albPureGcd(ad, bd)");
      Line ("leftMul = math.floor(bd / g)");
      Line ("rightMul = math.floor(ad / g)");
      Line ("return albPurePack(an * leftMul - bn * rightMul, ad * leftMul)");
      Indent_Level := Indent_Level - 1;
      Line ("export PURE_MUL = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("an, ad, bn, bd = PURE_NUM(a), PURE_DEN(a), PURE_NUM(b), PURE_DEN(b)");
      Line ("g1 = albPureGcd(an, bd)");
      Line ("an = math.floor(an / g1)");
      Line ("bd = math.floor(bd / g1)");
      Line ("g2 = albPureGcd(bn, ad)");
      Line ("bn = math.floor(bn / g2)");
      Line ("ad = math.floor(ad / g2)");
      Line ("return albPurePack(an * bn, ad * bd)");
      Indent_Level := Indent_Level - 1;
      Line ("export PURE_DIV = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("an, ad, bn, bd = PURE_NUM(a), PURE_DEN(a), PURE_NUM(b), PURE_DEN(b)");
      Line ("return ALB_PURE_NUM_MOD if bn == 0");
      Line ("if bn < 0");
      Indent_Level := Indent_Level + 1;
      Line ("bn = 0 - bn");
      Line ("bd = 0 - bd");
      Indent_Level := Indent_Level - 1;
      Line ("g1 = albPureGcd(an, bn)");
      Line ("an = math.floor(an / g1)");
      Line ("bn = math.floor(bn / g1)");
      Line ("g2 = albPureGcd(bd, ad)");
      Line ("bd = math.floor(bd / g2)");
      Line ("ad = math.floor(ad / g2)");
      Line ("return albPurePack(an * bd, ad * bn)");
      Indent_Level := Indent_Level - 1;
      Line ("export PURE_POW = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("expNum, expDen = PURE_NUM(b), PURE_DEN(b)");
      Line ("if expDen == 1");
      Indent_Level := Indent_Level + 1;
      Line ("return PURE(1, 1) if expNum == 0");
      Line ("factor, power, result = a, expNum, PURE(1, 1)");
      Line ("if power < 0");
      Indent_Level := Indent_Level + 1;
      Line ("return PURE(0, 1) if PURE_NUM(a) == 0");
      Line ("factor = PURE_DIV(PURE(1, 1), a)");
      Line ("power = 0 - power");
      Indent_Level := Indent_Level - 1;
      Line ("while power > 0");
      Indent_Level := Indent_Level + 1;
      Line ("result = PURE_MUL(result, factor) if ALB_band(power, 1) ~= 0");
      Line ("power = math.floor(power / 2)");
      Line ("factor = PURE_MUL(factor, factor) if power > 0");
      Indent_Level := Indent_Level - 1;
      Line ("return result");
      Indent_Level := Indent_Level - 1;
      Line ("av = PURE_NUM(a) / PURE_DEN(a)");
      Line ("bv = expNum / expDen");
      Line ("return albPurePack(math.floor(math.pow(av, bv) * 1000000 + 0.5), 1000000)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("albPowInt = (base, exp) ->");
      Indent_Level := Indent_Level + 1;
      Line ("result, factor, power = 1, math.floor(base), math.floor(exp)");
      Line ("if power < 0");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if factor == 1");
      Line ("if factor == -1");
      Indent_Level := Indent_Level + 1;
      Line ("return -1 if ALB_band(power, 1) ~= 0");
      Line ("return 1");
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("while power > 0");
      Indent_Level := Indent_Level + 1;
      Line ("result = result * factor if ALB_band(power, 1) ~= 0");
      Line ("power = math.floor(power / 2)");
      Line ("factor = factor * factor if power > 0");
      Indent_Level := Indent_Level - 1;
      Line ("return result");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_POW = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("base, exp = ALB_num(a), ALB_num(b)");
      Line ("if math.floor(base) == base and math.floor(exp) == exp");
      Indent_Level := Indent_Level + 1;
      Line ("return albPowInt(base, exp)");
      Indent_Level := Indent_Level - 1;
      Line ("return math.pow(base, exp)");
      Indent_Level := Indent_Level - 1;
      Line ("albDiv = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("dv = ALB_num(b)");
      Line ("return 0 if dv == 0");
      Line ("return math.floor(ALB_num(a) / dv)");
      Indent_Level := Indent_Level - 1;
      Line ("albMod = (a, b) ->");
      Indent_Level := Indent_Level + 1;
      Line ("dv = ALB_num(b)");
      Line ("return 0 if dv == 0");
      Line ("return math.floor(ALB_num(a)) % math.floor(dv)");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export LEFT = (s, n) ->");
      Indent_Level := Indent_Level + 1;
      Line ("t = ALB_text(s)");
      Line ("c = math.max(0, math.floor(ALB_num(n)))");
      Line ("return t\sub(1, c)");
      Indent_Level := Indent_Level - 1;
      Line ("export RIGHT = (s, n) ->");
      Indent_Level := Indent_Level + 1;
      Line ("t = ALB_text(s)");
      Line ("c = math.max(0, math.floor(ALB_num(n)))");
      Line ("return t if c >= #t");
      Line ("return t\sub(#t - c + 1)");
      Indent_Level := Indent_Level - 1;
      Line ("export MID = (s, startAt, n) ->");
      Indent_Level := Indent_Level + 1;
      Line ("t = ALB_text(s)");
      Line ("startIx = math.max(0, math.floor(ALB_num(startAt)) - 1)");
      Line ("c = math.max(0, math.floor(ALB_num(n)))");
      Line ("return t\sub(startIx + 1, startIx + c)");
      Indent_Level := Indent_Level - 1;
      Line ("LEN = (v) -> return #ALB_text(v)");
      Line ("CHR = (v) -> return string.char(ALB_band(ALB_num(v), 255))");
      Line ("export ASC = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("t = ALB_text(v)");
      Line ("return 0 if #t == 0");
      Line ("return string.byte(t, 1)");
      Indent_Level := Indent_Level - 1;
      Line ("CONCAT = (a, b) -> return ALB_concat(a, b)");
      Line ("PRINT_PURE = (v) -> ALB_PRINT(v)");
      New_Line_Emit;
      Line ("export ALB_RND = (limit) ->");
      Indent_Level := Indent_Level + 1;
      Line ("n = math.max(1, math.floor(ALB_num(limit)))");
      Line ("return math.floor(math.random() * n)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_COLLIDE_RECT = (ax, ay, aw, ah, bx, by, bw, bh) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by");
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SIN = (deg) -> return math.floor(math.sin(deg * math.pi / 180) * 1024 + 0.5)");
      Line ("export ALB_COS = (deg) -> return math.floor(math.cos(deg * math.pi / 180) * 1024 + 0.5)");
      Line ("export ALB_SQRT = (v) -> return math.floor(math.sqrt(math.max(0, ALB_num(v))))");
      Line ("export ALB_EXP = (v) -> return math.floor(math.exp(ALB_num(v)))");
      Line ("RND = (limit) -> return ALB_RND(limit)");
      Line ("COLLIDE_RECT = (ax, ay, aw, ah, bx, by, bw, bh) -> return ALB_COLLIDE_RECT(ax, ay, aw, ah, bx, by, bw, bh)");
      Line ("SIN = (deg) -> return ALB_SIN(deg)");
      Line ("COS = (deg) -> return ALB_COS(deg)");
      Line ("SQRT = (v) -> return ALB_SQRT(v)");
      Line ("EXP = (v) -> return ALB_EXP(v)");
      New_Line_Emit;
      Line ("export ALB_GetTickCount = -> return ALB_now_ms()");
      Line ("export ALB_PRED = (name, a, b, c, d) ->");
      Indent_Level := Indent_Level + 1;
      Line ("s = tostring(name) .. ""(""");
      Line ("first = true");
      Line ("add = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if v == nil");
      Line ("s = s .. "","" if not first");
      Line ("s = s .. tostring(v)");
      Line ("first = false");
      Indent_Level := Indent_Level - 1;
      Line ("add(a)");
      Line ("add(b)");
      Line ("add(c)");
      Line ("add(d)");
      Line ("return s .. "")""");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_CREATE_WINDOW = (title, width, height) ->");
      Indent_Level := Indent_Level + 1;
      Line ("sdl = albEnsureSDL()");
      Line ("albBaseWidth = math.max(1, math.floor(ALB_num(width)))");
      Line ("albBaseHeight = math.max(1, math.floor(ALB_num(height)))");
      Line ("albVirtualWidth = albBaseWidth");
      Line ("albVirtualHeight = albBaseHeight");
      Line ("albWindowWidth = albBaseWidth");
      Line ("albWindowHeight = albBaseHeight");
      Line ("sdl.create_window(tostring(title or ""ALBM""), albBaseWidth, albBaseHeight)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SET_FULLSCREEN = (v) ->");
      Line ("export ALB_SET_RESIZABLE = (v) -> albResizable = ALB_truthy(v)");
      Line ("export ALB_SET_STRETCHY = (v) -> albStretchy = ALB_truthy(v)");
      Line ("export ALB_PREPARE_FRAME = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("albSDL.prepare_frame() if albSDL ~= nil");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_COLOR = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albColorValue = albU32(v)");
      Line ("albCurrentColor = albColorValue");
      Line ("albSDL.color(albColorValue) if albSDL ~= nil");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_CLEAR = (v) ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_COLOR(v)");
      Line ("albSDL.clear(albColorValue) if albSDL ~= nil");
      Indent_Level := Indent_Level - 1;
      Line ("albInsideClip = (x, y) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return true if not albClipRect");
      Line ("return x >= albClipRect.x and y >= albClipRect.y and x < albClipRect.x + albClipRect.w and y < albClipRect.y + albClipRect.h");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PLOT = (x, y) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albSDL == nil");
      Line ("albSDL.plot(ALB_num(x), ALB_num(y))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DRAW_RECT = (x, y, w, h) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albSDL == nil");
      Line ("albSDL.draw_rect(ALB_num(x), ALB_num(y), ALB_num(w), ALB_num(h))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FILL_RECT = (x, y, w, h) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albSDL == nil");
      Line ("albSDL.fill_rect(ALB_num(x), ALB_num(y), ALB_num(w), ALB_num(h))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DRAW_LINE = (x1, y1, x2, y2) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albSDL == nil");
      Line ("albSDL.draw_line(ALB_num(x1), ALB_num(y1), ALB_num(x2), ALB_num(y2))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DRAW_CIRCLE = (x, y, r) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albSDL == nil");
      Line ("albSDL.draw_circle(ALB_num(x), ALB_num(y), ALB_num(r), false)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FILL_CIRCLE = (x, y, r) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albSDL == nil");
      Line ("albSDL.draw_circle(ALB_num(x), ALB_num(y), ALB_num(r), true)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DRAW_TRIANGLE = (x1, y1, x2, y2, x3, y3) ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_DRAW_LINE(x1, y1, x2, y2)");
      Line ("ALB_DRAW_LINE(x2, y2, x3, y3)");
      Line ("ALB_DRAW_LINE(x3, y3, x1, y1)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FILL_TRIANGLE = (x1, y1, x2, y2, x3, y3) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albEnsureSDL() if albSDL == nil");
      Line ("if albSDL ~= nil");
      Indent_Level := Indent_Level + 1;
      Line ("albSDL.fill_triangle(ALB_num(x1), ALB_num(y1), ALB_num(x2), ALB_num(y2), ALB_num(x3), ALB_num(y3))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PAINTER_MESH = (vx, vy, vz, p1, p2, p3, col, vc, fc, yaw, pitch, cam_z, scale, cx, cy, seed_max) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albEnsureSDL() if albSDL == nil");
      Line ("if albSDL ~= nil");
      Indent_Level := Indent_Level + 1;
      Line ("albSDL.painter_mesh(vx, vy, vz, p1, p2, p3, col, ALB_num(vc), ALB_num(fc), ALB_num(yaw), ALB_num(pitch), ALB_num(cam_z), ALB_num(scale), ALB_num(cx), ALB_num(cy), ALB_num(seed_max or 0))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DRAW_TEXT = (x, y, t) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albSDL == nil");
      Line ("albSDL.draw_text(ALB_num(x), ALB_num(y), tostring(t or """"))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SET_ALPHA = (channel, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albAlphaChannel = math.floor(ALB_num(channel))");
      Line ("albAlphaValue = math.max(0, math.min(255, math.floor(ALB_num(value))))");
      Line ("ALB_COLOR(albColorValue)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SET_CLIP = (x, y, w, h) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albClipRect = {x: math.floor(ALB_num(x)), y: math.floor(ALB_num(y)), w: math.floor(ALB_num(w)), h: math.floor(ALB_num(h))}");
      Line ("albSDL.set_clip(albClipRect.x, albClipRect.y, albClipRect.w, albClipRect.h) if albSDL ~= nil");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SET_ORIGIN = (x, y) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albOriginX = math.floor(ALB_num(x))");
      Line ("albOriginY = math.floor(ALB_num(y))");
      Line ("albSDL.set_origin(albOriginX, albOriginY) if albSDL ~= nil");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_READ_PIXEL = (x, y) -> return 0");
      Line ("export ALB_KEY = (code) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if albSDL == nil");
      Line ("return albSDL.key(math.floor(ALB_num(code)))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_MOUSE_X = ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if albSDL == nil");
      Line ("return albSDL.mouse_x()");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_MOUSE_Y = ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if albSDL == nil");
      Line ("return albSDL.mouse_y()");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_MOUSE_WHEEL = ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if albSDL == nil");
      Line ("return albSDL.mouse_wheel()");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_VMOUSE_X = -> return ALB_MOUSE_X()");
      Line ("export ALB_VMOUSE_Y = -> return ALB_MOUSE_Y()");
      Line ("export ALB_MOUSE_CLICK = (button) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if albSDL == nil");
      Line ("return albSDL.mouse_click(math.floor(ALB_num(button)))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SCREEN_WIDTH = -> return albWindowWidth");
      Line ("export ALB_SCREEN_HEIGHT = -> return albWindowHeight");
      Line ("export ALB_VIRTUAL_WIDTH = -> return albVirtualWidth");
      Line ("export ALB_VIRTUAL_HEIGHT = -> return albVirtualHeight");
      New_Line_Emit;
      Line ("export ALB_PLAY_SOUND = (path) -> ALB_WARN_ONCE(""play-sound"", ""PLAY_SOUND is a no-op stub on ALBM"")");
      Line ("export ALB_PLAY_MUSIC = (mml) -> ALB_WARN_ONCE(""play-music"", ""PLAY_MUSIC is a no-op stub on ALBM"")");
      Line ("export ALB_PLAY_MUSIC_FROM = (path) -> ALB_PLAY_MUSIC(path)");
      Line ("export ALB_MSG_BOX = (msg, title) ->");
      Indent_Level := Indent_Level + 1;
      Line ("t = ALB_text(title or """")");
      Line ("ALB_PRINT(t) if #t > 0");
      Line ("ALB_PRINT(msg)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_Delay = (ms) ->");
      Indent_Level := Indent_Level + 1;
      Line ("if albSDL ~= nil");
      Indent_Level := Indent_Level + 1;
      Line ("albSDL.delay(math.max(0, math.floor(ALB_num(ms))))");
      Indent_Level := Indent_Level - 1;
      Line ("else");
      Indent_Level := Indent_Level + 1;
      Line ("albDelayUntil = ALB_now_ms() + math.max(0, math.floor(ALB_num(ms)))");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_CEASE = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("albRunning = false");
      Line ("albSDL.cease() if albSDL ~= nil");
      Line ("ALB_ProgramShutdown() if ALB_ProgramShutdown");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("albGcDec = (handle) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = math.floor(ALB_num(handle))");
      Line ("if handle > 0 and (albGcRefs[handle] or 0) > 0");
      Indent_Level := Indent_Level + 1;
      Line ("albGcRefs[handle] = albGcRefs[handle] - 1");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("albGcClearChildren = (parent) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = albGcChildA[parent] or 0");
      Line ("b = albGcChildB[parent] or 0");
      Line ("c = albGcChildC[parent] or 0");
      Line ("d = albGcChildD[parent] or 0");
      Line ("albGcDec(a) if a ~= 0");
      Line ("albGcDec(b) if b ~= 0");
      Line ("albGcDec(c) if c ~= 0");
      Line ("albGcDec(d) if d ~= 0");
      Line ("albGcChildA[parent] = 0");
      Line ("albGcChildB[parent] = 0");
      Line ("albGcChildC[parent] = 0");
      Line ("albGcChildD[parent] = 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_CLAIM = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 1, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if not albGcAlive[i]");
      Indent_Level := Indent_Level + 1;
      Line ("albGcAlive[i] = 1");
      Line ("albGcRefs[i] = 1");
      Line ("albGcChildA[i] = 0");
      Line ("albGcChildB[i] = 0");
      Line ("albGcChildC[i] = 0");
      Line ("albGcChildD[i] = 0");
      Line ("return i");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_BIND = (parent, child1, child2, child3, child4) ->");
      Indent_Level := Indent_Level + 1;
      Line ("parent = math.floor(ALB_num(parent))");
      Line ("return if parent <= 0 or not albGcAlive[parent]");
      Line ("albGcClearChildren(parent)");
      Line ("child1 = math.floor(ALB_num(child1 or 0))");
      Line ("child2 = math.floor(ALB_num(child2 or 0))");
      Line ("child3 = math.floor(ALB_num(child3 or 0))");
      Line ("child4 = math.floor(ALB_num(child4 or 0))");
      Line ("if child1 > 0");
      Indent_Level := Indent_Level + 1;
      Line ("albGcChildA[parent] = child1");
      Line ("albGcRefs[child1] = (albGcRefs[child1] or 0) + 1");
      Indent_Level := Indent_Level - 1;
      Line ("if child2 > 0");
      Indent_Level := Indent_Level + 1;
      Line ("albGcChildB[parent] = child2");
      Line ("albGcRefs[child2] = (albGcRefs[child2] or 0) + 1");
      Indent_Level := Indent_Level - 1;
      Line ("if child3 > 0");
      Indent_Level := Indent_Level + 1;
      Line ("albGcChildC[parent] = child3");
      Line ("albGcRefs[child3] = (albGcRefs[child3] or 0) + 1");
      Indent_Level := Indent_Level - 1;
      Line ("if child4 > 0");
      Indent_Level := Indent_Level + 1;
      Line ("albGcChildD[parent] = child4");
      Line ("albGcRefs[child4] = (albGcRefs[child4] or 0) + 1");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DROP = (handle) -> albGcDec(handle)");
      Line ("export ALB_SWEEP = (chunk) ->");
      Indent_Level := Indent_Level + 1;
      Line ("budget = math.floor(ALB_num(chunk))");
      Line ("budget = 1024 if budget <= 0");
      Line ("changed = true");
      Line ("while changed and budget > 0");
      Indent_Level := Indent_Level + 1;
      Line ("changed = false");
      Line ("for i = 1, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("break if budget <= 0");
      Line ("if albGcAlive[i] and (albGcRefs[i] or 0) == 0");
      Indent_Level := Indent_Level + 1;
      Line ("albGcAlive[i] = nil");
      Line ("albGcClearChildren(i)");
      Line ("changed = true");
      Line ("budget = budget - 1");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_KNOWS_SET = (key, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if albFactLive[i] and albFactKey[i] == key");
      Indent_Level := Indent_Level + 1;
      Line ("albFactValue[i] = value");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if not albFactLive[i]");
      Indent_Level := Indent_Level + 1;
      Line ("albFactLive[i] = 1");
      Line ("albFactKey[i] = key");
      Line ("albFactValue[i] = value");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_KNOWS_GET = (key) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("return albFactValue[i] if albFactLive[i] and albFactKey[i] == key");
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_KNOWS_HAS = (key) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if albFactLive[i] and albFactKey[i] == key");
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_REL_FACT_MATCH = (slot, pred, arity, arg1, arg2, arg3, arg4) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return albRelLive[slot] and albRelPred[slot] == pred and albRelArity[slot] == arity and albRelArg1[slot] == math.floor(ALB_num(arg1)) and albRelArg2[slot] == math.floor(ALB_num(arg2)) and albRelArg3[slot] == math.floor(ALB_num(arg3)) and albRelArg4[slot] == math.floor(ALB_num(arg4))");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_REL_FACT_HAS = (pred, arity, arg1, arg2, arg3, arg4) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)");
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_REL_RULE_HAS = (pred, arg1) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for r = 0, albRuleCount - 1");
      Indent_Level := Indent_Level + 1;
      Line ("if albRuleHeadPred[r] == pred");
      Indent_Level := Indent_Level + 1;
      Line ("ok = true");
      Line ("base = r * 8");
      Line ("for j = 0, (albRuleBodyLen[r] or 0) - 1");
      Indent_Level := Indent_Level + 1;
      Line ("ix = base + j");
      Line ("bodyPred = albRuleBodyPred[ix]");
      Line ("mode = albRuleBodyArgMode[ix]");
      Line ("want = (mode == 1) and math.floor(ALB_num(arg1)) or albRuleBodyArgConst[ix]");
      Line ("if ALB_REL_FACT_HAS(bodyPred, 1, want, 0, 0, 0) == 0");
      Indent_Level := Indent_Level + 1;
      Line ("ok = false");
      Line ("break");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return 1 if ok");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_REL_HAS = (pred, arity, arg1, arg2, arg3, arg4) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if ALB_REL_FACT_HAS(pred, arity, arg1, arg2, arg3, arg4) == 1");
      Line ("return ALB_REL_RULE_HAS(pred, arg1) if math.floor(ALB_num(arity)) == 1");
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_REL_SET = (pred, arity, arg1, arg2, arg3, arg4, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)");
      Indent_Level := Indent_Level + 1;
      Line ("albRelValue[i] = math.floor(ALB_num(value))");
      Line ("ALB_NOTIFY_KNOWS_CHANGE(pred, arg1, arg2, arg3, arg4)");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if not albRelLive[i]");
      Indent_Level := Indent_Level + 1;
      Line ("albRelLive[i] = 1");
      Line ("albRelPred[i] = pred");
      Line ("albRelArity[i] = arity");
      Line ("albRelArg1[i] = math.floor(ALB_num(arg1))");
      Line ("albRelArg2[i] = math.floor(ALB_num(arg2))");
      Line ("albRelArg3[i] = math.floor(ALB_num(arg3))");
      Line ("albRelArg4[i] = math.floor(ALB_num(arg4))");
      Line ("albRelValue[i] = math.floor(ALB_num(value))");
      Line ("ALB_NOTIFY_KNOWS_CHANGE(pred, arg1, arg2, arg3, arg4)");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_REL_RETRACT = (pred, arity, arg1, arg2, arg3, arg4) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)");
      Indent_Level := Indent_Level + 1;
      Line ("albRelLive[i] = nil");
      Line ("albRelPred[i] = 0");
      Line ("albRelArity[i] = 0");
      Line ("albRelArg1[i] = 0");
      Line ("albRelArg2[i] = 0");
      Line ("albRelArg3[i] = 0");
      Line ("albRelArg4[i] = 0");
      Line ("albRelValue[i] = 0");
      Line ("ALB_NOTIFY_KNOWS_CHANGE(pred, arg1, arg2, arg3, arg4)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_REL_GET_VALUE = (pred, arity, arg1, arg2, arg3, arg4) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)");
      Indent_Level := Indent_Level + 1;
      Line ("return albRelValue[i] or 0");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return ALB_REL_HAS(pred, arity, arg1, arg2, arg3, arg4)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_REL_FIND1 = (pred) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("return albRelArg1[i] or 0 if albRelLive[i] and albRelPred[i] == pred");
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_REL_FINDALL1 = (pred, target) ->");
      Indent_Level := Indent_Level + 1;
      Line ("out = 0");
      Line ("len = 0");
      Line ("if type(target) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("for k, _ in pairs(target)");
      Indent_Level := Indent_Level + 1;
      Line ("len = k + 1 if type(k) == ""number"" and k + 1 > len");
      Indent_Level := Indent_Level - 1;
      Line ("for i = 0, len - 1 do target[i] = 0");
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("break if out >= len");
      Line ("if albRelLive[i] and albRelPred[i] == pred");
      Indent_Level := Indent_Level + 1;
      Line ("target[out] = albRelArg1[i] or 0");
      Line ("out = out + 1");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return out");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_ASSERT = (key, value) -> ALB_KNOWS_SET(key, value)");
      Line ("export ALB_RETRACT = (key) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("if albFactLive[i] and albFactKey[i] == key");
      Indent_Level := Indent_Level + 1;
      Line ("albFactLive[i] = nil");
      Line ("albFactKey[i] = """"");
      Line ("albFactValue[i] = 0");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_UPDATE = (key, value) -> ALB_KNOWS_SET(key, value)");
      Line ("export ALB_PROVE = (key) -> return ALB_KNOWS_HAS(key)");
      New_Line_Emit;
      Line ("export ALB_Open = (path, mode) ->");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 1, 63");
      Indent_Level := Indent_Level + 1;
      Line ("if not albFileLive[i]");
      Indent_Level := Indent_Level + 1;
      Line ("albFileLive[i] = 1");
      Line ("albFileMode[i] = mode");
      Line ("albFileName[i] = path");
      Line ("albFileCursor[i] = 0");
      Line ("buf = albSaveStore[path] or """"");
      Line ("if buf == """"");
      Indent_Level := Indent_Level + 1;
      Line ("f = io.open(path, ""rb"")");
      Line ("if f");
      Indent_Level := Indent_Level + 1;
      Line ("buf = f\read(""*a"") or """"");
      Line ("f\close()");
      Line ("albSaveStore[path] = buf");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("albFileBuffer[i] = buf");
      Line ("return i");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FileLen = (path) ->");
      Indent_Level := Indent_Level + 1;
      Line ("f = io.open(path, ""rb"")");
      Line ("if f");
      Indent_Level := Indent_Level + 1;
      Line ("sz = f\seek(""end"")");
      Line ("f\close()");
      Line ("return sz or 0");
      Indent_Level := Indent_Level - 1;
      Line ("t = albSaveStore[path] or """"");
      Line ("return #t");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_Seek = (handle, offset) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = math.floor(ALB_num(handle))");
      Line ("return 0 if not albFileLive[handle]");
      Line ("albFileCursor[handle] = math.max(0, math.floor(ALB_num(offset)))");
      Line ("return albFileCursor[handle]");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_Read = (handle, count) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = math.floor(ALB_num(handle))");
      Line ("return """" if not albFileLive[handle]");
      Line ("count = math.floor(ALB_num(count or 0))");
      Line ("return albFileBuffer[handle] or """" if count <= 0");
      Line ("start = albFileCursor[handle] or 0");
      Line ("buf = albFileBuffer[handle] or """"");
      Line ("chunk = buf\sub(start + 1, start + count)");
      Line ("albFileCursor[handle] = start + #chunk");
      Line ("return chunk");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_Write = (handle, data) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = math.floor(ALB_num(handle))");
      Line ("return if not albFileLive[handle]");
      Line ("albFileBuffer[handle] = (albFileBuffer[handle] or """") .. ALB_text(data)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_Close = (handle) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = math.floor(ALB_num(handle))");
      Line ("return if not albFileLive[handle]");
      Line ("albSaveStore[albFileName[handle]] = albFileBuffer[handle] or """"");
      Line ("f = io.open(albFileName[handle], ""wb"")");
      Line ("f\write(albFileBuffer[handle] or """") if f");
      Line ("f\close() if f");
      Line ("albFileLive[handle] = nil");
      Line ("albFileName[handle] = """"");
      Line ("albFileBuffer[handle] = """"");
      Line ("albFileCursor[handle] = 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_LoadTextBuffer = (path) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return albSaveStore[path] if albSaveStore[path] ~= nil");
      Line ("f = io.open(path, ""r"")");
      Line ("if f");
      Indent_Level := Indent_Level + 1;
      Line ("text = f\read(""*a"") or """"");
      Line ("f\close()");
      Line ("albSaveStore[path] = text");
      Line ("return text");
      Indent_Level := Indent_Level - 1;
      Line ("return """"");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_LoadBuffer = (path, target) ->");
      Indent_Level := Indent_Level + 1;
      Line ("raw = ALB_LoadTextBuffer(path)");
      Line ("return if raw == """" or type(target) ~= ""table""");
      Line ("i = 0");
      Line ("for item in string.gmatch(raw, ""[^,]+"")");
      Indent_Level := Indent_Level + 1;
      Line ("target[i] = ALB_num(item)");
      Line ("i = i + 1");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FlushBuffer = (target, path, byteCount) ->");
      Indent_Level := Indent_Level + 1;
      Line ("if type(target) == ""string""");
      Indent_Level := Indent_Level + 1;
      Line ("albSaveStore[path] = target");
      Line ("f = io.open(path, ""w"")");
      Line ("f\write(target) if f");
      Line ("f\close() if f");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("if type(target) == ""table"" and byteCount ~= nil");
      Indent_Level := Indent_Level + 1;
      Line ("count = math.max(0, math.floor(ALB_num(byteCount)))");
      Line ("bytes = {}");
      Line ("for i = 0, count - 1");
      Indent_Level := Indent_Level + 1;
      Line ("bytes[#bytes + 1] = string.char(ALB_band(ALB_num(target[i] or 0), 255))");
      Indent_Level := Indent_Level - 1;
      Line ("data = table.concat(bytes)");
      Line ("albSaveStore[path] = data");
      Line ("f = io.open(path, ""wb"")");
      Line ("f\write(data) if f");
      Line ("f\close() if f");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("if type(target) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("parts = {}");
      Line ("maxi = -1");
      Line ("for k, _ in pairs(target)");
      Indent_Level := Indent_Level + 1;
      Line ("maxi = k if type(k) == ""number"" and k > maxi");
      Indent_Level := Indent_Level - 1;
      Line ("for i = 0, maxi do parts[#parts + 1] = tostring(target[i] or 0)");
      Line ("albSaveStore[path] = table.concat(parts, "","")");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("albFirewallCurrent = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("return albFirewallStack[#albFirewallStack]");
      Indent_Level := Indent_Level - 1;
      Line ("albFirewallAllows = (kind, name) ->");
      Indent_Level := Indent_Level + 1;
      Line ("fw = albFirewallCurrent()");
      Line ("return true if not fw or not fw.denyAll or not name or name == """"");
      Line ("table = (kind == ""write"") and fw.write or fw.read");
      Line ("return table[name] == true if type(table) == ""table""");
      Line ("return true");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FIREWALL_TOUCH_READ = (name) ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_FATAL(""MEMORY_FIREWALL read blocked: "" .. tostring(name)) if not albFirewallAllows(""read"", name)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FIREWALL_TOUCH_WRITE = (name) ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_FATAL(""MEMORY_FIREWALL write blocked: "" .. tostring(name)) if not albFirewallAllows(""write"", name)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FIREWALL_READ = (name, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_FIREWALL_TOUCH_READ(name)");
      Line ("return value");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FIREWALL_WRITE = (name, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_FIREWALL_TOUCH_WRITE(name)");
      Line ("return value");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FIREWALL_ENTER = (fw) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albFirewallStack[#albFirewallStack + 1] = fw");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FIREWALL_LEAVE = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("albFirewallStack[#albFirewallStack] = nil");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_COMPAT_IMPORT = (lib, symbol, ...) ->");
      Indent_Level := Indent_Level + 1;
      Line ("key = string.upper(tostring(symbol or """"))");
      Line ("args = {...}");
      Line ("if key == ""GETTICKCOUNT64"" or key == ""GETTICKCOUNT""");
      Indent_Level := Indent_Level + 1;
      Line ("albCompatTick = albCompatTick + 16");
      Line ("return albU32(albCompatTick)");
      Indent_Level := Indent_Level - 1;
      Line ("return 1 if key == ""MESSAGEBEEP""");
      Line ("if string.find(key, ""SQUADCOLOR"", 1, true)");
      Indent_Level := Indent_Level + 1;
      Line ("return albU32((ALB_num(args[1] or 0) * 73) + (ALB_num(args[2] or 0) * 41) + 0x224466)");
      Indent_Level := Indent_Level - 1;
      Line ("if string.find(key, ""SQUADBIAS"", 1, true)");
      Indent_Level := Indent_Level + 1;
      Line ("return albI32((ALB_num(args[1] or 0) * 5) - (ALB_num(args[2] or 0) * 3))");
      Indent_Level := Indent_Level - 1;
      Line ("if string.find(key, ""SQUADTRAININGBOOST"", 1, true)");
      Indent_Level := Indent_Level + 1;
      Line ("return albU8(ALB_num(args[1] or 0) + ALB_num(args[2] or 0) + 1)");
      Indent_Level := Indent_Level - 1;
      Line ("if string.find(key, ""CLOCK"", 1, true)");
      Indent_Level := Indent_Level + 1;
      Line ("albCompatTick = albCompatTick + 17");
      Line ("return albU32(albCompatTick)");
      Indent_Level := Indent_Level - 1;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_MAKE_CELL = (initialValue) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return {value: math.floor(ALB_num(initialValue or 0))}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_BUFFER_BYTE = (buf, index) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if type(buf) ~= ""table""");
      Line ("return ALB_band(ALB_num(buf[math.floor(ALB_num(index))] or 0), 255)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_BUFFER_PACK_LE = (buf, start, size) ->");
      Indent_Level := Indent_Level + 1;
      Line ("value, scale = 0, 1");
      Line ("for i = 0, math.floor(ALB_num(size)) - 1");
      Indent_Level := Indent_Level + 1;
      Line ("value = value + ALB_BUFFER_BYTE(buf, math.floor(ALB_num(start)) + i) * scale");
      Line ("scale = scale * 256");
      Indent_Level := Indent_Level - 1;
      Line ("return math.floor(value)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DEFINE_SYSTEM_FONT = (name, size, weight, antiAlias, charsetStart, charsetEnd) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return {kind: ""systemFont"", name: name, size: math.max(1, math.floor(ALB_num(size))), weight: weight, antiAlias: ALB_truthy(antiAlias), charsetStart: math.floor(ALB_num(charsetStart)), charsetEnd: math.floor(ALB_num(charsetEnd))}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DEFINE_BITMAP_FONT = (name, source, format, glyphWidth, glyphHeight, firstChar, spacing) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return {kind: ""bitmapFont"", name: name, source: source, format: format, glyphWidth: math.max(1, math.floor(ALB_num(glyphWidth))), glyphHeight: math.max(1, math.floor(ALB_num(glyphHeight))), firstChar: math.floor(ALB_num(firstChar)), spacing: math.floor(ALB_num(spacing))}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SET_FONT = (font) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if not font");
      Line ("if font.kind == ""bitmapFont""");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_WARN_ONCE(""bitmap-font-approx"", ""BITMAP_FONT uses text approximation on ALBM"")");
      Indent_Level := Indent_Level - 1;
      Line ("albCurrentFont = font");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_INI_BIND = (path, embeddedText, tableRows) ->");
      Indent_Level := Indent_Level + 1;
      Line ("source = (embeddedText and #embeddedText > 0) and embeddedText or (albSaveStore[path] or """")");
      Line ("return 0 if source == """"");
      Line ("matched = 0");
      Line ("for rawLine in string.gmatch(source .. ""\n"", ""(.-)\r?\n"")");
      Indent_Level := Indent_Level + 1;
      Line ("line = rawLine\match(""^%s*(.-)%s*$"") or """"");
      Line ("if line ~= """" and not line\match(""^[#;%[]"")");
      Indent_Level := Indent_Level + 1;
      Line ("key, valueText = line\match(""^([^=]+)=(.*)$"")");
      Line ("if key");
      Indent_Level := Indent_Level + 1;
      Line ("key = string.lower((key\match(""^%s*(.-)%s*$"") or """"))");
      Line ("value = tonumber((valueText\match(""^%s*(.-)%s*$"") or """"))");
      Line ("if value and type(tableRows) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("for _, row in ipairs(tableRows)");
      Indent_Level := Indent_Level + 1;
      Line ("if row.key == key");
      Indent_Level := Indent_Level + 1;
      Line ("row.apply(math.floor(value)) if type(row.apply) == ""function""");
      Line ("matched = matched + 1");
      Line ("break");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return 1 if matched > 0");
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_EXPORT_PPM = (surface, path, format) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if not surface or not surface.pixels or not surface.width or not surface.height");
      Line ("fmt = string.upper(tostring(format or ""P6""))");
      Line ("ALB_WARN_ONCE(""export-ppm-format"", ""EXPORT_PPM format approximated as P6 on ALBM"") if fmt ~= ""P6""");
      Line ("width = math.max(1, math.floor(ALB_num(surface.width)))");
      Line ("height = math.max(1, math.floor(ALB_num(surface.height)))");
      Line ("out = {""P6\n"", tostring(width), "" "", tostring(height), ""\n255\n""}");
      Line ("for i = 0, width * height - 1");
      Indent_Level := Indent_Level + 1;
      Line ("rgb565 = ALB_band(ALB_num(surface.pixels[i] or 0), 0xffff)");
      Line ("r = math.floor(((ALB_shr(rgb565, 11) % 32) * 255) / 31)");
      Line ("g = math.floor(((ALB_shr(rgb565, 5) % 64) * 255) / 63)");
      Line ("b = math.floor((rgb565 % 32) * 255 / 31)");
      Line ("out[#out + 1] = string.char(r, g, b)");
      Indent_Level := Indent_Level - 1;
      Line ("data = table.concat(out)");
      Line ("albSaveStore[path] = data");
      Line ("f = io.open(path, ""wb"")");
      Line ("f\write(data) if f");
      Line ("f\close() if f");
      Line ("return 1");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_SNIFFER_DEFINE = (interfaceName, protocol, port, bufferSize) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = albNextSnifferHandle");
      Line ("albNextSnifferHandle = albNextSnifferHandle + 1");
      Line ("sniffer = {kind: ""sniffer"", handle: handle, interfaceName: interfaceName, protocol: math.floor(ALB_num(protocol)), port: math.floor(ALB_num(port)), bufferSize: math.max(64, math.floor(ALB_num(bufferSize))), sample: 0, value: 0, errorCell: ALB_MAKE_CELL(0)}");
      Line ("albSnifferTable[handle] = sniffer");
      Line ("return sniffer");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_SNIFFER_CAPTURE = (sniffer, dest) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if not sniffer or type(dest) ~= ""table""");
      Line ("sniffer.sample = math.floor(ALB_num(sniffer.sample or 0)) + 1");
      Line ("sniffer.errorCell.value = 0");
      Line ("bytes = {0x10,0x20,0x30,0x40,0x50,0x60,0xaa,0xbb,0xcc,0xdd,0xee,0xff,0x08,0x00}");
      Line ("total = math.min(64, math.max(54, math.floor(ALB_num(sniffer.bufferSize))))");
      Line ("for i = 0, 255 do dest[i] = 0");
      Line ("for i = 0, math.min(total, #bytes) - 1 do dest[i] = bytes[i + 1]");
      Line ("sniffer.value = math.min(total, #bytes)");
      Line ("return sniffer.value");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_STATIC_RGB565 = (rgb) ->");
      Indent_Level := Indent_Level + 1;
      Line ("v = albU32(rgb)");
      Line ("return ALB_band(ALB_bor(ALB_bor(ALB_shl(ALB_shr(ALB_band(ALB_shr(v, 16), 255), 3), 11), ALB_shl(ALB_shr(ALB_band(ALB_shr(v, 8), 255), 2), 5)), ALB_shr(ALB_band(v, 255), 3)), 0xffff)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_STATIC_SURFACE = (width, height) ->");
      Indent_Level := Indent_Level + 1;
      Line ("w = math.max(1, math.floor(ALB_num(width)))");
      Line ("h = math.max(1, math.floor(ALB_num(height)))");
      Line ("return {kind: ""surface"", width: w, height: h, pitch: w * 2, pixels: ALB_new_array(w * h, 0)}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_STATIC_VIEWPORT = (x, y, width, height) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return {kind: ""viewport"", x: math.floor(ALB_num(x)), y: math.floor(ALB_num(y)), width: math.max(1, math.floor(ALB_num(width))), height: math.max(1, math.floor(ALB_num(height)))}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_STATIC_EMPTY_SPRITE = (frameWidth, frameHeight, frames) ->");
      Indent_Level := Indent_Level + 1;
      Line ("fw = math.max(1, math.floor(ALB_num(frameWidth)))");
      Line ("fh = math.max(1, math.floor(ALB_num(frameHeight)))");
      Line ("count = math.max(1, math.floor(ALB_num(frames)))");
      Line ("return {kind: ""sprite"", pixels: ALB_new_array(fw * fh * count, 0), palette: ALB_new_array(256, 0), frameWidth: fw, frameHeight: fh, frames: count, sheetWidth: fw * count, sheetHeight: fh}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_STATIC_SPRITE_FROM_BMP = (bytes, frameWidth, frameHeight, frames) ->");
      Indent_Level := Indent_Level + 1;
      Line ("if type(bytes) ~= ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_WARN_ONCE(""static-sprite-payload"", ""STATIC_SPRITE source is not a usable BMP on ALBM; using a blank sprite"")");
      Line ("return ALB_STATIC_EMPTY_SPRITE(frameWidth, frameHeight, frames)");
      Indent_Level := Indent_Level - 1;
      Line ("u8 = (i) -> return ALB_band(ALB_num(bytes[i] or 0), 255)");
      Line ("u16 = (i) -> return ALB_bor(u8(i), ALB_shl(u8(i + 1), 8))");
      Line ("u32 = (i) -> return ALB_bor(ALB_bor(u8(i), ALB_shl(u8(i + 1), 8)), ALB_bor(ALB_shl(u8(i + 2), 16), ALB_shl(u8(i + 3), 24)))");
      Line ("i32 = (i) ->");
      Indent_Level := Indent_Level + 1;
      Line ("v = u32(i)");
      Line ("return v - 0x100000000 if v >= 0x80000000");
      Line ("return v");
      Indent_Level := Indent_Level - 1;
      Line ("if u8(0) ~= 0x42 or u8(1) ~= 0x4d");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_WARN_ONCE(""static-sprite-payload"", ""STATIC_SPRITE source is not a usable BMP on ALBM; using a blank sprite"")");
      Line ("return ALB_STATIC_EMPTY_SPRITE(frameWidth, frameHeight, frames)");
      Indent_Level := Indent_Level - 1;
      Line ("pixelOffset = u32(10)");
      Line ("dibSize = u32(14)");
      Line ("bmpWidth = i32(18)");
      Line ("bmpHeight = i32(22)");
      Line ("planes = u16(26)");
      Line ("bits = u16(28)");
      Line ("compression = u32(30)");
      Line ("if planes ~= 1 or bits ~= 8 or compression ~= 0");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_WARN_ONCE(""static-sprite-format"", ""STATIC_SPRITE currently approximates unsupported BMP layouts as a blank sprite on ALBM"")");
      Line ("return ALB_STATIC_EMPTY_SPRITE(frameWidth, frameHeight, frames)");
      Indent_Level := Indent_Level - 1;
      Line ("width = math.max(1, math.abs(bmpWidth))");
      Line ("height = math.max(1, math.abs(bmpHeight))");
      Line ("bottomUp = bmpHeight > 0");
      Line ("paletteOffset = 14 + dibSize");
      Line ("rowStride = ALB_band(width + 3, ALB_bnot(3))");
      Line ("palette = ALB_new_array(256, 0)");
      Line ("for i = 0, 255");
      Indent_Level := Indent_Level + 1;
      Line ("off = paletteOffset + i * 4");
      Line ("palette[i] = ALB_bor(ALB_bor(ALB_shl(u8(off + 2), 16), ALB_shl(u8(off + 1), 8)), u8(off))");
      Indent_Level := Indent_Level - 1;
      Line ("pixels = ALB_new_array(width * height, 0)");
      Line ("for row = 0, height - 1");
      Indent_Level := Indent_Level + 1;
      Line ("srcRow = bottomUp and (height - 1 - row) or row");
      Line ("src = pixelOffset + srcRow * rowStride");
      Line ("dst = row * width");
      Line ("for col = 0, width - 1 do pixels[dst + col] = u8(src + col)");
      Indent_Level := Indent_Level - 1;
      Line ("return {kind: ""sprite"", pixels: pixels, palette: palette, frameWidth: math.max(1, math.floor(ALB_num(frameWidth))), frameHeight: math.max(1, math.floor(ALB_num(frameHeight))), frames: math.max(1, math.floor(ALB_num(frames))), sheetWidth: width, sheetHeight: height}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_STATIC_APPLY_LUT = (lut, visual, context, contextUsed) ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_STATIC_Active_Lut = lut");
      Line ("ALB_STATIC_Active_Visual = visual");
      Line ("ALB_STATIC_Active_Context = context");
      Line ("ALB_STATIC_Active_Context_Used = contextUsed and true or false");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_STATIC_RESOLVE_VISUAL = (visual, context) ->");
      Indent_Level := Indent_Level + 1;
      Line ("if type(visual) == ""table"" and visual.kind == ""visualRule"" and type(visual.resolve) == ""function""");
      Indent_Level := Indent_Level + 1;
      Line ("return visual.resolve(context)");
      Indent_Level := Indent_Level - 1;
      Line ("return {sprite: visual, frame: 0}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_STATIC_BLIT = (visual, context, contextUsed, target, x, y, viewport, alphaMask) ->");
      Indent_Level := Indent_Level + 1;
      Line ("resolved = ALB_STATIC_RESOLVE_VISUAL(visual, contextUsed and context or nil)");
      Line ("sprite = resolved and resolved.sprite");
      Line ("ALB_FATAL(""ALB STATIC BLIT FAILED"") if not sprite or not target or not target.pixels");
      Line ("frameW = math.max(1, math.floor(ALB_num(sprite.frameWidth)))");
      Line ("frameH = math.max(1, math.floor(ALB_num(sprite.frameHeight)))");
      Line ("sheetW = math.max(frameW, math.floor(ALB_num(sprite.sheetWidth or frameW)))");
      Line ("totalFrames = math.max(1, math.floor(ALB_num(sprite.frames or 1)))");
      Line ("frame = math.floor(ALB_num(resolved.frame or 0)) % totalFrames");
      Line ("frame = frame + totalFrames if frame < 0");
      Line ("useActive = ALB_STATIC_Active_Visual == visual and ALB_STATIC_Active_Context_Used == (contextUsed and true or false) and ((not contextUsed) or ALB_STATIC_Active_Context == context)");
      Line ("palette = (useActive and ALB_STATIC_Active_Lut) or sprite.palette");
      Line ("x = math.floor(ALB_num(x))");
      Line ("y = math.floor(ALB_num(y))");
      Line ("for row = 0, frameH - 1");
      Indent_Level := Indent_Level + 1;
      Line ("for col = 0, frameW - 1");
      Indent_Level := Indent_Level + 1;
      Line ("dx = x + col");
      Line ("dy = y + row");
      Line ("if dx >= 0 and dy >= 0 and dx < target.width and dy < target.height");
      Indent_Level := Indent_Level + 1;
      Line ("ok = true");
      Line ("if viewport");
      Indent_Level := Indent_Level + 1;
      Line ("vr = (viewport.x or 0) + (viewport.width or 0)");
      Line ("vb = (viewport.y or 0) + (viewport.height or 0)");
      Line ("ok = false if dx < (viewport.x or 0) or dy < (viewport.y or 0) or dx >= vr or dy >= vb");
      Indent_Level := Indent_Level - 1;
      Line ("if ok");
      Indent_Level := Indent_Level + 1;
      Line ("src = frame * frameW + col + row * sheetW");
      Line ("index = math.floor(ALB_num(sprite.pixels[src] or 0))");
      Line ("if not (alphaMask and index == 0)");
      Indent_Level := Indent_Level + 1;
      Line ("rgb = ALB_num(palette[index] or 0)");
      Line ("target.pixels[dy * target.width + dx] = ALB_STATIC_RGB565(rgb)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_MARKOV_PREDICT = (model, currentState) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if not model or not model.states or not model.matrix");
      Line ("row = math.floor(ALB_num(currentState)) - 1");
      Line ("row = 0 if row < 0");
      Line ("row = model.states - 1 if row >= model.states");
      Line ("bestCol, bestWeight = 0, ALB_num(model.matrix[row * model.states] or 0)");
      Line ("for col = 1, model.states - 1");
      Indent_Level := Indent_Level + 1;
      Line ("weight = ALB_num(model.matrix[row * model.states + col] or 0)");
      Line ("if weight > bestWeight");
      Indent_Level := Indent_Level + 1;
      Line ("bestWeight = weight");
      Line ("bestCol = col");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return bestCol + 1");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_NN_ACT = (code, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("code = math.floor(ALB_num(code))");
      Line ("if code == 1");
      Indent_Level := Indent_Level + 1;
      Line ("return value if value > 0");
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("if code == 2");
      Indent_Level := Indent_Level + 1;
      Line ("return 1 if value > 0");
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("if code == 3");
      Indent_Level := Indent_Level + 1;
      Line ("return 1024 if value > 128");
      Line ("return -1024 if value < -128");
      Line ("return value * 8");
      Indent_Level := Indent_Level - 1;
      Line ("return value");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_NN_SEED = (prevSize, currSize, neuronIndex, inputIndex) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return 0 if prevSize <= 0 or currSize <= 0");
      Line ("return inputIndex == neuronIndex and 256 or 0 if currSize == prevSize");
      Line ("if prevSize == currSize * 2");
      Indent_Level := Indent_Level + 1;
      Line ("return 256 if inputIndex == neuronIndex * 2");
      Line ("return -256 if inputIndex == neuronIndex * 2 + 1");
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("return inputIndex == (neuronIndex % prevSize) and 256 or 0 if currSize > prevSize");
      Line ("inputSpan = math.max(1, math.floor(prevSize / currSize))");
      Line ("baseInput = neuronIndex * inputSpan");
      Line ("positiveIn = math.min(prevSize - 1, baseInput)");
      Line ("negativeIn = math.min(prevSize - 1, baseInput + 1)");
      Line ("if inputSpan >= 2");
      Indent_Level := Indent_Level + 1;
      Line ("return 256 if inputIndex == positiveIn");
      Line ("return -128 if inputIndex == negativeIn");
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("return inputIndex == positiveIn and 256 or 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NN_CREATE = (name, sizes, acts) ->");
      Indent_Level := Indent_Level + 1;
      Line ("weights, biases, state = {}, {}, {}");
      Line ("for layer = 2, #sizes");
      Indent_Level := Indent_Level + 1;
      Line ("prev = math.max(1, math.floor(ALB_num(sizes[layer - 1])))");
      Line ("curr = math.max(1, math.floor(ALB_num(sizes[layer])))");
      Line ("w = ALB_new_array(prev * curr, 0)");
      Line ("b = ALB_new_array(curr, 0)");
      Line ("for neuron = 0, curr - 1");
      Indent_Level := Indent_Level + 1;
      Line ("for inputIndex = 0, prev - 1");
      Indent_Level := Indent_Level + 1;
      Line ("w[neuron * prev + inputIndex] = ALB_NN_SEED(prev, curr, neuron, inputIndex)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("weights[#weights + 1] = w");
      Line ("biases[#biases + 1] = b");
      Indent_Level := Indent_Level - 1;
      Line ("for i = 1, #sizes do state[i] = ALB_new_array(math.max(1, math.floor(ALB_num(sizes[i]))), 0)");
      Line ("return {name: name, sizes: sizes, activations: acts, weights: weights, biases: biases, state: state}");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NN_INFER = (model, input, output) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if not model or not model.state");
      Line ("state = model.state");
      Line ("s0 = state[1]");
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("break if s0[i] == nil and (type(input) ~= ""table"" or input[i] == nil)");
      Line ("s0[i] = ALB_num((type(input) == ""table"" and input[i]) or 0)");
      Indent_Level := Indent_Level - 1;
      Line ("for layer = 2, #state");
      Indent_Level := Indent_Level + 1;
      Line ("prev = state[layer - 1]");
      Line ("curr = state[layer]");
      Line ("w = model.weights[layer - 1]");
      Line ("b = model.biases[layer - 1]");
      Line ("prevLen, currLen = 0, 0");
      Line ("for k, _ in pairs(prev)");
      Indent_Level := Indent_Level + 1;
      Line ("prevLen = k + 1 if type(k) == ""number"" and k + 1 > prevLen");
      Indent_Level := Indent_Level - 1;
      Line ("for k, _ in pairs(curr)");
      Indent_Level := Indent_Level + 1;
      Line ("currLen = k + 1 if type(k) == ""number"" and k + 1 > currLen");
      Indent_Level := Indent_Level - 1;
      Line ("for i = 0, currLen - 1");
      Indent_Level := Indent_Level + 1;
      Line ("acc = ALB_num(b[i] or 0)");
      Line ("for j = 0, prevLen - 1");
      Indent_Level := Indent_Level + 1;
      Line ("acc = acc + ALB_num(prev[j] or 0) * ALB_num(w[i * prevLen + j] or 0)");
      Indent_Level := Indent_Level - 1;
      Line ("curr[i] = ALB_NN_ACT(ALB_num((model.activations and model.activations[layer]) or 0), acc)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("out = state[#state]");
      Line ("if type(output) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("break if out[i] == nil and output[i] == nil");
      Line ("output[i] = out[i] and math.floor(out[i] + 0.5) or 0");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NN_TRAIN = (model, trainData, expectData, epochs) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if not model or not model.weights or #model.weights == 0");
      Line ("outSize = math.max(1, math.floor(ALB_num(model.sizes[#model.sizes])))");
      Line ("prevSize = math.max(1, math.floor(ALB_num(model.sizes[#model.sizes - 1])))");
      Line ("output = ALB_new_array(outSize, 0)");
      Line ("for epoch = 1, math.max(1, math.floor(ALB_num(epochs)))");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_NN_INFER(model, trainData, output)");
      Line ("prev = model.state[#model.state - 1]");
      Line ("weights = model.weights[#model.weights]");
      Line ("biases = model.biases[#model.biases]");
      Line ("for i = 0, outSize - 1");
      Indent_Level := Indent_Level + 1;
      Line ("got = math.floor(ALB_num(output[i] or 0) + 0.5)");
      Line ("want = math.floor(ALB_num((type(expectData) == ""table"" and expectData[i]) or 0) + 0.5)");
      Line ("delta = 0");
      Line ("if got > want");
      Indent_Level := Indent_Level + 1;
      Line ("delta = -1");
      Indent_Level := Indent_Level - 1;
      Line ("elseif got < want");
      Indent_Level := Indent_Level + 1;
      Line ("delta = 1");
      Indent_Level := Indent_Level - 1;
      Line ("biases[i] = math.floor(ALB_num(biases[i] or 0)) + delta");
      Line ("for j = 0, prevSize - 1");
      Indent_Level := Indent_Level + 1;
      Line ("if math.floor(ALB_num(prev[j] or 0) + 0.5) ~= 0");
      Indent_Level := Indent_Level + 1;
      Line ("weights[i * prevSize + j] = math.floor(ALB_num(weights[i * prevSize + j] or 0)) + delta");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("albNetChannelKey = (sock) ->");
      Indent_Level := Indent_Level + 1;
      Line ("return ""ALB_NET_"" .. tostring(sock.protocol or 0) .. ""_"" .. tostring(sock.port or 0)");
      Indent_Level := Indent_Level - 1;
      Line ("albNetEnsure = (sock) ->");
      Indent_Level := Indent_Level + 1;
      Line ("sock.queue = {} if not sock.queue");
      Indent_Level := Indent_Level - 1;
      Line ("albNetPull = (sock) ->");
      Indent_Level := Indent_Level + 1;
      Line ("albNetEnsure(sock)");
      Line ("if sock.queue and #sock.queue > 0");
      Indent_Level := Indent_Level + 1;
      Line ("p = table.remove(sock.queue, 1)");
      Line ("return p");
      Indent_Level := Indent_Level - 1;
      Line ("key = albNetChannelKey(sock)");
      Line ("bus = albNetworkBus[key]");
      Line ("return table.remove(bus, 1) if bus and #bus > 0");
      Line ("return nil");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NET_DEFINE = (protocol, port, bufferSize) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = albNextNetworkHandle");
      Line ("albNextNetworkHandle = albNextNetworkHandle + 1");
      Line ("size = math.max(1, math.floor(ALB_num(bufferSize)))");
      Line ("albNetworkTable[handle] = {handle: handle, protocol: protocol, port: port, bufferSize: size, listening: false, open: true, queue: {}, lastSent: ALB_new_array(size, 0), lastReceived: ALB_new_array(size, 0)}");
      Line ("return handle");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NET_LISTEN = (handle) ->");
      Indent_Level := Indent_Level + 1;
      Line ("sock = albNetworkTable[math.floor(ALB_num(handle))]");
      Line ("ALB_FATAL(""NETWORK_LISTEN on unknown socket"") if not sock");
      Line ("sock.listening = true");
      Line ("sock.open = true");
      Line ("albNetEnsure(sock)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NET_ACCEPT = (handle) ->");
      Indent_Level := Indent_Level + 1;
      Line ("sock = albNetworkTable[math.floor(ALB_num(handle))]");
      Line ("ALB_FATAL(""NETWORK_ACCEPT on unknown socket"") if not sock");
      Line ("child = albNextNetworkHandle");
      Line ("albNextNetworkHandle = albNextNetworkHandle + 1");
      Line ("albNetworkTable[child] = {handle: child, protocol: sock.protocol, port: sock.port, bufferSize: sock.bufferSize, listening: sock.listening, open: true, queue: {}, parent: math.floor(ALB_num(handle)), lastSent: ALB_new_array(sock.bufferSize, 0), lastReceived: ALB_new_array(sock.bufferSize, 0)}");
      Line ("return child");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NET_RECEIVE = (handle, dest) ->");
      Indent_Level := Indent_Level + 1;
      Line ("sock = albNetworkTable[math.floor(ALB_num(handle))]");
      Line ("ALB_FATAL(""NETWORK_RECEIVE on closed socket"") if not sock or not sock.open");
      Line ("packet = albNetPull(sock) or sock.lastReceived or ALB_new_array(sock.bufferSize, 0)");
      Line ("sock.lastReceived = packet");
      Line ("if type(dest) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("break if packet[i] == nil and dest[i] == nil");
      Line ("dest[i] = ALB_band(ALB_num(packet[i] or 0), 255)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NET_SEND = (handle, src) ->");
      Indent_Level := Indent_Level + 1;
      Line ("sock = albNetworkTable[math.floor(ALB_num(handle))]");
      Line ("ALB_FATAL(""NETWORK_SEND on closed socket"") if not sock or not sock.open");
      Line ("payload = ALB_new_array(sock.bufferSize, 0)");
      Line ("if type(src) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("for i = 0, sock.bufferSize - 1 do payload[i] = ALB_band(ALB_num(src[i] or 0), 255)");
      Indent_Level := Indent_Level - 1;
      Line ("sock.lastSent = payload");
      Line ("albNetEnsure(sock)");
      Line ("key = albNetChannelKey(sock)");
      Line ("albNetworkBus[key] = {} if not albNetworkBus[key]");
      Line ("albNetworkBus[key][#albNetworkBus[key] + 1] = payload");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_NET_CLOSE = (handle) ->");
      Indent_Level := Indent_Level + 1;
      Line ("sock = albNetworkTable[math.floor(ALB_num(handle))]");
      Line ("return if not sock");
      Line ("sock.open = false");
      Line ("sock.listening = false");
      Line ("sock.queue = {}");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_PROCESS_DEFINE = (image, rights, pid) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = albNextProcessHandle");
      Line ("albNextProcessHandle = albNextProcessHandle + 1");
      Line ("albProcessTable[handle] = {handle: handle, image: image, rights: rights, pid: math.floor(ALB_num(pid or 0)), alive: true, elevated: false, mode: ""self""}");
      Line ("return handle");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_CREATE = (image, args) ->");
      Indent_Level := Indent_Level + 1;
      Line ("handle = albNextProcessHandle");
      Line ("albNextProcessHandle = albNextProcessHandle + 1");
      Line ("albProcessTable[handle] = {handle: handle, image: image, args: args, alive: true, elevated: false, mode: ""child""}");
      Line ("return handle");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_READ_SCALAR = (handle, addr) ->");
      Indent_Level := Indent_Level + 1;
      Line ("proc = albProcessTable[math.floor(ALB_num(handle))]");
      Line ("return 0 if not proc or not proc.alive");
      Line ("return ALB_PEEK(math.floor(ALB_num(addr)))");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_WRITE_SCALAR = (handle, addr, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("proc = albProcessTable[math.floor(ALB_num(handle))]");
      Line ("ALB_FATAL(""WRITE_PROCESS_MEMORY on invalid handle"") if not proc or not proc.alive");
      Line ("ALB_POKE(math.floor(ALB_num(addr)), value)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_READ_BUFFER = (handle, addr, target) ->");
      Indent_Level := Indent_Level + 1;
      Line ("value = math.max(0, math.floor(ALB_num(ALB_PROCESS_READ_SCALAR(handle, addr))))");
      Line ("return if type(target) ~= ""table""");
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("break if target[i] == nil and i > 0");
      Line ("target[i] = ALB_band(value, 255)");
      Line ("value = math.floor(value / 256)");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_MONITOR = (handle, addr, outTarget, changed) ->");
      Indent_Level := Indent_Level + 1;
      Line ("key = tostring(math.floor(ALB_num(handle))) .. "":"" .. tostring(math.floor(ALB_num(addr)))");
      Line ("value = ALB_PROCESS_READ_SCALAR(handle, addr)");
      Line ("if type(changed) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("changed.value = (albProcessMonitor[key] ~= nil and albProcessMonitor[key] ~= value) and 1 or 0");
      Indent_Level := Indent_Level - 1;
      Line ("albProcessMonitor[key] = value");
      Line ("outTarget.value = value if type(outTarget) == ""table""");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_DUMP = (handle, addr, size, outPath) ->");
      Indent_Level := Indent_Level + 1;
      Line ("bytes = ALB_new_array(math.max(1, math.floor(ALB_num(size))), 0)");
      Line ("ALB_PROCESS_READ_BUFFER(handle, addr, bytes)");
      Line ("parts = {}");
      Line ("for i = 0, math.max(1, math.floor(ALB_num(size))) - 1 do parts[#parts + 1] = tostring(bytes[i] or 0)");
      Line ("albSaveStore[outPath] = table.concat(parts, "","")");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_FILE_XOR = (sourcePath, key, outPath) ->");
      Indent_Level := Indent_Level + 1;
      Line ("src = albSaveStore[sourcePath] or """"");
      Line ("keyText = (#tostring(key or """") > 0) and tostring(key) or ""0""");
      Line ("out = {}");
      Line ("for i = 1, #src");
      Indent_Level := Indent_Level + 1;
      Line ("a = string.byte(src, i)");
      Line ("b = string.byte(keyText, ((i - 1) % #keyText) + 1)");
      Line ("out[#out + 1] = string.char(ALB_bxor(a, b))");
      Indent_Level := Indent_Level - 1;
      Line ("albSaveStore[outPath] = table.concat(out)");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_ELEVATE = (handle) ->");
      Indent_Level := Indent_Level + 1;
      Line ("proc = albProcessTable[math.floor(ALB_num(handle))]");
      Line ("proc.elevated = true if proc");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_PROCESS_SNIFF = (source, target) ->");
      Indent_Level := Indent_Level + 1;
      Line ("seed = ALB_text(source)");
      Line ("return if type(target) ~= ""table""");
      Line ("for i = 0, 1023");
      Indent_Level := Indent_Level + 1;
      Line ("break if i >= #seed and target[i] == nil");
      Line ("target[i] = (i < #seed) and string.byte(seed, i + 1) or 0");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("-- ALB_PEEK / ALB_POKE filled later by Emit_Address_Routines");
      Line ("export ALB_PEEK = (addr) -> return albVas[math.floor(ALB_num(addr))] or 0");
      Line ("export ALB_DEREF = (addr) -> return ALB_PEEK(addr)");
      Line ("export ALB_POKE = (addr, value) -> albVas[math.floor(ALB_num(addr))] = value");
      New_Line_Emit;
      Line ("export ALB_RunFrame = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("if not albRunning");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_ProgramShutdown() if ALB_ProgramShutdown");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Line ("if albSDL ~= nil");
      Indent_Level := Indent_Level + 1;
      Line ("if not albSDL.poll()");
      Indent_Level := Indent_Level + 1;
      Line ("albRunning = false");
      Line ("return");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("now = ALB_now_ms()");
      Line ("return if now < albDelayUntil");
      Line ("return if now - albLastFrame < albFrameInterval");
      Line ("albLastFrame = now");
      Line ("ok, err = pcall ->");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_PREPARE_FRAME()");
      Line ("ALB_ON_TICK()");
      Line ("albMouseWheel = 0");
      Line ("ALB_ON_PAINT()");
      Line ("albSDL.present() if albSDL ~= nil");
      Indent_Level := Indent_Level - 1;
      Line ("ALB_FATAL(err) if not ok");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("export ALB_MainLoop = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("while albRunning");
      Indent_Level := Indent_Level + 1;
      Line ("ALB_RunFrame()");
      Line ("if albSDL ~= nil");
      Indent_Level := Indent_Level + 1;
      Line ("rem = albFrameInterval - (ALB_now_ms() - albLastFrame)");
      Line ("albSDL.delay(rem) if rem > 1");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("albSDL.quit() if albSDL ~= nil");
      Line ("ALB_ProgramShutdown() if ALB_ProgramShutdown");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_copy_array = (src) ->");
      Indent_Level := Indent_Level + 1;
      Line ("out = {}");
      Line ("if type(src) == ""table""");
      Indent_Level := Indent_Level + 1;
      Line ("for k, v in pairs(src)");
      Indent_Level := Indent_Level + 1;
      Line ("out[k] = v");
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;
      Line ("return out");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_serialize_state = (state) -> return state");
      Line ("export ALB_deserialize_state = (raw) -> return raw");
      Line ("export ALB_bytes = (t) ->");
      Indent_Level := Indent_Level + 1;
      Line ("out = {}");
      Line ("for i, v in ipairs(t)");
      Indent_Level := Indent_Level + 1;
      Line ("out[i - 1] = v");
      Indent_Level := Indent_Level - 1;
      Line ("return out");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
   end Emit_Runtime;

   function MoonImport_Alias (Binding : Foreign_Binding_Record) return String is
   begin
      return "__alb_imp_" & Safe_Moon_Name (To_String (Binding.Moon_Name));
   end MoonImport_Alias;

   procedure Emit_Module_Imports is
   begin
      if not Need_Module_Support then
         return;
      end if;

      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Link_Kind = Foreign_ES then
            Line ("package.preload[" &
                  Escape_Moon_String (MoonImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                  "] = package.preload[" &
                  Escape_Moon_String (MoonImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                  "] or -> {}");
            Line (MoonImport_Alias (Foreign_Imports (I)) &
                  " = (require(" &
                  Escape_Moon_String (MoonImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                  ") or {})[" &
                  Escape_Moon_String (To_String (Foreign_Imports (I).Name)) & "]");
         end if;
      end loop;

      if Need_Module_Support then
         New_Line_Emit;
      end if;
   end Emit_Module_Imports;

   procedure Emit_Foreign_Loaders is
   begin
      if not Need_Wasm_Loaders then
         return;
      end if;

      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Link_Kind = Foreign_WASM then
            Line ("albWasmLoaders[#albWasmLoaders + 1] = ->");
            Indent_Level := Indent_Level + 1;
            Line ("ALB_WARN_ONCE(" &
                  Escape_Moon_String ("wasm-loader-" & To_String (Foreign_Imports (I).Moon_Name)) &
                  ", " &
                  Escape_Moon_String (
                    "IMPORT_WASM " & To_String (Foreign_Imports (I).Path) &
                    " is stubbed on ALBM; bind via albWasmBindings") & ")");
            Line ("albWasmBindings[" &
                  Escape_Moon_String (To_String (Foreign_Imports (I).Moon_Name)) &
                  "] = albWasmBindings[" &
                  Escape_Moon_String (To_String (Foreign_Imports (I).Moon_Name)) &
                  "] or -> 0");
            Indent_Level := Indent_Level - 1;
         end if;
      end loop;
   end Emit_Foreign_Loaders;

   procedure Emit_Module_Exports is
   begin
      if Foreign_Export_Count = 0 then
         return;
      end if;

      Line ("ALB_EXPORTS = ALB_EXPORTS or {}");
      for I in 1 .. Foreign_Export_Count loop
         if Foreign_Exports (I).Active then
            Line ("ALB_EXPORTS[" &
                  Escape_Moon_String (To_String (Foreign_Exports (I).Name)) &
                  "] = " & To_String (Foreign_Exports (I).Moon_Name));
         end if;
      end loop;
      New_Line_Emit;
   end Emit_Module_Exports;

   procedure Emit_Foreign_Import_Node (Index : Node_Index) is
      Binding   : Foreign_Binding_Record;
      Decl_Node : constant Node_Index := Tree (Index).Left_Child;
      Name_Node : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      List_Node : constant Node_Index := (if Name_Node > 0 then Tree (Name_Node).Right_Child else 0);
      Param_Node : Node_Index := 0;
      First     : Boolean := True;
      Has_Out   : Boolean := False;
   begin
      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Node = Index then
            Binding := Foreign_Imports (I);
            exit;
         end if;
      end loop;

      if not Binding.Active or else Name_Node = 0 then
         return;
      end if;

      Emit_Indent;
      Emit ("export " & To_String (Binding.Moon_Name) & " = (");
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Param_Node := Tree (List_Node).Left_Child;
         while Param_Node > 0 loop
            if Tree (Param_Node).Kind = AST_Param_Decl then
               declare
                  Param_Name : constant String := Safe_Moon_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
                  Param_Tag  : constant Value_Kind :=
                    (if Tree (Param_Node).Right_Child > 0
                     then Type_From_Token (Tree (Tree (Param_Node).Right_Child).Token_Index)
                     else VK_Number);
                  Mode_Tok   : constant Natural := Tree (Param_Node).Token_Index;
               begin
                  if not First then
                     Emit (", ");
                  end if;
                  if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then
                     Emit (Param_Name);
                     Has_Out := True;
                  else
                     Emit (Param_Name);
                  end if;
                  First := False;
               end;
            end if;
            Param_Node := Tree (Param_Node).Next_Sibling;
         end loop;
      end if;

      if Binding.Is_Function then
         Emit (") ->");
      else
         Emit (") ->");
      end if;
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;

      declare
         Call_Args : Unbounded_String := U ("");
      begin
         if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
            Param_Node := Tree (List_Node).Left_Child;
            First := True;
            while Param_Node > 0 loop
               if Tree (Param_Node).Kind = AST_Param_Decl then
                  if not First then
                     Append (Call_Args, ", ");
                  end if;
                  Append (Call_Args,
                          Safe_Moon_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index)));
                  First := False;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         if Has_Out then
            Line ("ALB_WARN_ONCE(" &
                  Escape_Moon_String ("foreign-out-" & To_String (Binding.Name)) & ", " &
                  Escape_Moon_String ("ALBM passes OUT parameters to foreign imports as { value } boxes; the callee must mutate .value to write back") &
                  ")");
         end if;

         if Binding.Link_Kind = Foreign_ES then
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     MoonImport_Alias (Binding) & "(" & To_String (Call_Args) & ")"));
            else
               Line (MoonImport_Alias (Binding) & "(" & To_String (Call_Args) & ")");
            end if;
         elsif Binding.Link_Kind = Foreign_WASM then
            Line ("__alb_wasm_fn = albWasmBindings[" &
                  Escape_Moon_String (To_String (Binding.Moon_Name)) & "]");
            Line ("if type(__alb_wasm_fn) ~= ""function"" ALB_FATAL(" &
                  Escape_Moon_String ("WASM import not ready: " & To_String (Binding.Name)) &
                  ")");
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "__alb_wasm_fn(" & To_String (Call_Args) & ")"));
            else
               Line ("__alb_wasm_fn(" & To_String (Call_Args) & ")");
            end if;
         else
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "ALB_COMPAT_IMPORT(" &
                     Escape_Moon_String (To_String (Binding.Path)) & ", " &
                     Escape_Moon_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ")"));
            else
               Line ("ALB_COMPAT_IMPORT(" &
                     Escape_Moon_String (To_String (Binding.Path)) & ", " &
                     Escape_Moon_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ")");
            end if;
         end if;
      end;

      if not Binding.Is_Function then
         Line ("return");
      end if;

      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
   end Emit_Foreign_Import_Node;

   function Raw_Feature_Atom (Index : Node_Index) return String is
   begin
      if Index = 0 then
         return "";
      elsif Tree (Index).Kind = AST_String_Expr then
         return Strip_String_Node (Index);
      elsif Tree (Index).Token_Index > 0 then
         return Raw_Lexeme (Tree (Index).Token_Index);
      else
         return "";
      end if;
   end Raw_Feature_Atom;

   function Activation_Code (Text : String) return String is
      Upper : constant String := Upper_Text (Text);
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
      Upper : constant String := Upper_Text (Text);
   begin
      if Upper = "UDP" then
         return "2";
      else
         return "1";
      end if;
   end Network_Protocol_Code;

   procedure Emit_Embedded_File_Bytes
     (Const_Name : String;
      File_Path  : String) is
      use type Ada.Streams.Stream_IO.Count;
      use type Ada.Streams.Stream_Element_Offset;

      File_Handle : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open
        (File_Handle,
         Ada.Streams.Stream_IO.In_File,
         File_Path);

      declare
         File_Size_Count : constant Ada.Streams.Stream_IO.Count :=
           Ada.Streams.Stream_IO.Size (File_Handle);
      begin
         if File_Size_Count = 0 then
            Ada.Streams.Stream_IO.Close (File_Handle);
            Line (Const_Name & " = ALB_new_array(1, 0)");
            return;
         end if;

         declare
            File_Size : constant Natural := Natural (File_Size_Count);
            Buffer    : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (File_Size));
            Last      : Ada.Streams.Stream_Element_Offset := 0;
         begin
            Ada.Streams.Stream_IO.Read (File_Handle, Buffer, Last);
            Ada.Streams.Stream_IO.Close (File_Handle);

            Emit_Indent;
            Emit ( Const_Name & " = ALB_bytes({");
            for I in Buffer'First .. Last loop
               if I > Buffer'First then
                  Emit (", ");
               end if;
               Emit (Trim_Image (Integer (Buffer (I))));
               if ((Integer (I) - Integer (Buffer'First) + 1) mod 24) = 0
                 and then I < Last
               then
                  New_Line_Emit;
                  Emit_Indent;
                  Emit ("    ");
               end if;
            end loop;
            Emit ("])");
            New_Line_Emit;
         end;
      end;
   exception
      when others =>
         begin
            Ada.Streams.Stream_IO.Close (File_Handle);
         exception
            when others =>
               null;
         end;
         Line (Const_Name & " = ALB_new_array(1, 0)");
   end Emit_Embedded_File_Bytes;

   procedure Emit_Embedded_Text_File
     (Const_Name : String;
      File_Path  : String) is
      File_Handle : Ada.Text_IO.File_Type;
      Content     : Unbounded_String := U ("");
   begin
      Ada.Text_IO.Open (File_Handle, Ada.Text_IO.In_File, File_Path);
      while not Ada.Text_IO.End_Of_File (File_Handle) loop
         declare
            Line_Text : constant String := Ada.Text_IO.Get_Line (File_Handle);
         begin
            Append (Content, Line_Text);
            if not Ada.Text_IO.End_Of_File (File_Handle) then
               Append (Content, ASCII.LF);
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File_Handle);
      Line (Const_Name & " = " &
            Escape_Moon_String (To_String (Content)));
   exception
      when others =>
         begin
            if Ada.Text_IO.Is_Open (File_Handle) then
               Ada.Text_IO.Close (File_Handle);
            end if;
         exception
            when others =>
               null;
         end;
         Line (Const_Name & " = """"");
   end Emit_Embedded_Text_File;

   function Statement_Target_Name
     (Target_Node : Node_Index;
      Assign_Kind : Value_Kind := VK_Unknown) return String is
      Node : constant AST_Node := Tree (Target_Node);
      Raw  : constant String := (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
      Sym  : constant Symbol_Record := Resolve_Symbol (Raw);
   begin
      if Target_Node = 0 then
         return "alb_missing_target";
      elsif Node.Kind = AST_Var_Expr then
         if Node.Left_Child > 0
           and then Sym.Active
           and then Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
         then
            return To_String (Sym.Moon_Name) &
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
                     return To_String (Symbols (Field_Sym_Id).Moon_Name) &
                       "[" &
                       Build_Array_Index
                         (Symbols (Field_Sym_Id).Dims,
                          Symbols (Field_Sym_Id).Rank,
                          Left_Node.Left_Child) &
                       "]";
                  end if;
               end;
            end if;

            if Right_Node.Kind = AST_Var_Expr
              and then Right_Node.Left_Child > 0
              and then Group_Sym.Active
              and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               return To_String (Group_Sym.Moon_Name) &
                 "[" & Build_Array_Index (Group_Sym.Dims, Group_Sym.Rank, Right_Node.Left_Child) & "]";
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               return To_String (Left_Sym.Moon_Name) & "." & Safe_Moon_Name (Right_Name);
            elsif Group_Sym.Active then
               return To_String (Group_Sym.Moon_Name);
            else
               return Collect_Module_Member_Name (Target_Node);
            end if;
         end;
      else
         return Expr (Target_Node);
      end if;
   end Statement_Target_Name;

   function Firewall_Key_For_Node (Target_Node : Node_Index) return String is
      function Firewall_Key_For_Symbol
        (Sym      : Symbol_Record;
         Fallback : String := "") return String
      is
      begin
         if not Sym.Active then
            return Fallback;
         elsif Sym.Kind = Sym_Param or else To_String (Sym.Scope) /= "" then
            return "";
         else
            return To_String (Sym.Moon_Name);
         end if;
      end Firewall_Key_For_Symbol;

      Node : constant AST_Node := Tree (Target_Node);
   begin
      if Target_Node = 0 then
         return "";
      elsif Node.Kind = AST_Var_Expr then
         declare
            Raw : constant String :=
              (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
            Sym : constant Symbol_Record := Resolve_Symbol (Raw);
         begin
            if Node.Left_Child > 0
              and then Sym.Active
              and then Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
            then
               return Firewall_Key_For_Symbol (Sym, To_String (Sym.Moon_Name));
            else
               return Firewall_Key_For_Symbol (Sym, Resolve_Var_Name (Raw));
            end if;
         end;
      elsif Node.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (Node.Left_Child);
            Right_Node : constant AST_Node := Tree (Node.Right_Child);
            Left_Name  : constant String :=
              (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String :=
              (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
            Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
         begin
            if Group_Sym.Active then
               return Firewall_Key_For_Symbol (Group_Sym, To_String (Group_Sym.Moon_Name));
            elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               if To_String (Left_Sym.Scope) /= "" then
                  return "";
               else
                  return To_String (Left_Sym.Moon_Name) & "." & Safe_Moon_Name (Right_Name);
               end if;
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
      if not Need_Firewall_Runtime or else Key'Length = 0 then
         return Value_Text;
      else
         return "ALB_FIREWALL_READ(" & Escape_Moon_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Read;

   function Wrap_Firewall_Write
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if not Need_Firewall_Runtime or else Key'Length = 0 then
         return Value_Text;
      else
         return "ALB_FIREWALL_WRITE(" & Escape_Moon_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Write;

   procedure Emit_Firewall_Touch
     (Node_Index_Value : Node_Index;
      Need_Read        : Boolean;
      Need_Write       : Boolean) is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if not Need_Firewall_Runtime or else Key'Length = 0 then
         return;
      end if;

      if Need_Read then
         Line ("ALB_FIREWALL_TOUCH_READ(" & Escape_Moon_String (Key) & ")");
      end if;

      if Need_Write then
         Line ("ALB_FIREWALL_TOUCH_WRITE(" & Escape_Moon_String (Key) & ")");
      end if;
   end Emit_Firewall_Touch;

   procedure Emit_Node (Index : Node_Index);

   procedure Remember_Event_Block
     (Event_Kind : Token_Kind;
      Block_Node : Node_Index) is
   begin
      case Event_Kind is
         when Tok_Tick =>
            if Tick_Block_Count < Max_Event_Blocks then
               Tick_Block_Count := Tick_Block_Count + 1;
               Tick_Blocks (Tick_Block_Count) := Block_Node;
            end if;
         when Tok_Paint =>
            if Paint_Block_Count < Max_Event_Blocks then
               Paint_Block_Count := Paint_Block_Count + 1;
               Paint_Blocks (Paint_Block_Count) := Block_Node;
            end if;
         when Tok_Key =>
            if Key_Block_Count < Max_Event_Blocks then
               Key_Block_Count := Key_Block_Count + 1;
               Key_Blocks (Key_Block_Count) := Block_Node;
            end if;
         when others =>
            null;
      end case;
   end Remember_Event_Block;

   procedure Emit_Event_Handler
     (Name   : String;
      Blocks : Node_Index_List;
      Count  : Natural) is
      Old_Routine : constant Unbounded_String := Current_Routine;
   begin
      if Count = 0 then
         return;
      end if;

      Current_Routine := U (Name);
      Line ("export " & Name & " = ->");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Count loop
         Emit_Block (Blocks (I));
      end loop;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Current_Routine := Old_Routine;
   end Emit_Event_Handler;

   procedure Emit_Address_Routines is
      procedure Emit_Struct_Field_Cases
        (Base_Moon    : String;
         Struct_Name  : String;
         Base_Offset  : Integer;
         For_Write    : Boolean) is
      begin
         for I in 1 .. Field_Count loop
            if Fields (I).Active
              and then To_String (Fields (I).Struct_Name) = Struct_Name
            then
               if For_Write then
                  Line ("if a == " &
                        Trim_Image (Base_Offset + Fields (I).Offset_Bytes));
                  Indent_Level := Indent_Level + 1;
                  Line (Field_Write_Expr (Base_Moon, I, Cast_Expr (Fields (I).Tag, "value")));
                  Line ("return");
                  Indent_Level := Indent_Level - 1;
               else
                  Line ("return " & Field_Read_Expr (Base_Moon, I) &
                        " if a == " & Trim_Image (Base_Offset + Fields (I).Offset_Bytes));
               end if;
            end if;
         end loop;
      end Emit_Struct_Field_Cases;
   begin
      New_Line_Emit;
      Line ("export ALB_PEEK = (addr) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(addr))");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Offset_Bytes > 0
         then
            declare
               Base_Moon : constant String := To_String (Symbols (I).Moon_Name);
               Base_Off  : constant Integer := Symbols (I).Offset_Bytes;
               Elem      : constant Integer := Element_Bytes (Symbols (I).Tag);
               Span      : constant Integer := Integer'Max (1, Symbols (I).Capacity) * Elem;
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line ("return " & Base_Moon & " if a == " & Trim_Image (Base_Off));
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("if a >= " & Trim_Image (Base_Off) & " and a < " &
                           Trim_Image (Base_Off + Span) & " and ((a - " &
                           Trim_Image (Base_Off) & ") % " & Trim_Image (Elem) &
                           ") == 0");
                     Indent_Level := Indent_Level + 1;
                     Line ("return " & Base_Moon & "[math.floor((a - " &
                           Trim_Image (Base_Off) & ") / " & Trim_Image (Elem) & ")]");
                     Indent_Level := Indent_Level - 1;
                  when Sym_Temporal =>
                     Line ("return " & Base_Moon & " if a == " & Trim_Image (Base_Off));
                     if Symbols (I).Aux_Offset > 0 and then Symbols (I).History_Size > 0 then
                        Line ("if a >= " & Trim_Image (Symbols (I).Aux_Offset) & " and a < " &
                              Trim_Image (Symbols (I).Aux_Offset + Symbols (I).History_Size * Elem) &
                              " and ((a - " & Trim_Image (Symbols (I).Aux_Offset) & ") % " &
                              Trim_Image (Elem) & ") == 0");
                        Indent_Level := Indent_Level + 1;
                        Line ("return " & Base_Moon &
                              "_history[math.floor((a - " & Trim_Image (Symbols (I).Aux_Offset) &
                              ") / " & Trim_Image (Elem) & ")]");
                        Indent_Level := Indent_Level - 1;
                     end if;
                  when Sym_Struct_Var =>
                     Emit_Struct_Field_Cases
                       (Base_Moon,
                        Safe_Moon_Name (To_String (Symbols (I).Struct_Name)),
                        Base_Off,
                        False);
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Line ("return 0");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_DEREF = (addr) -> return ALB_PEEK(addr)");
      Line ("export ALB_POKE = (addr, value) ->");
      Indent_Level := Indent_Level + 1;
      Line ("a = math.floor(ALB_num(addr))");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Offset_Bytes > 0
         then
            declare
               Base_Moon : constant String := To_String (Symbols (I).Moon_Name);
               Base_Off  : constant Integer := Symbols (I).Offset_Bytes;
               Elem      : constant Integer := Element_Bytes (Symbols (I).Tag);
               Span      : constant Integer := Integer'Max (1, Symbols (I).Capacity) * Elem;
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line ("if a == " & Trim_Image (Base_Off));
                     Indent_Level := Indent_Level + 1;
                     Line (Base_Moon & " = " & Cast_Expr (Symbols (I).Tag, "value"));
                     Line ("return");
                     Indent_Level := Indent_Level - 1;
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("if a >= " & Trim_Image (Base_Off) & " and a < " &
                           Trim_Image (Base_Off + Span) & " and ((a - " &
                           Trim_Image (Base_Off) & ") % " & Trim_Image (Elem) &
                           ") == 0");
                     Indent_Level := Indent_Level + 1;
                     Line (Base_Moon & "[math.floor((a - " &
                           Trim_Image (Base_Off) & ") / " & Trim_Image (Elem) &
                           ")] = " & Cast_Expr (Symbols (I).Tag, "value"));
                     Line ("return");
                     Indent_Level := Indent_Level - 1;
                  when Sym_Temporal =>
                     Line ("if a == " & Trim_Image (Base_Off));
                     Indent_Level := Indent_Level + 1;
                     Line (Base_Moon & " = " & Cast_Expr (Symbols (I).Tag, "value"));
                     Line ("return");
                     Indent_Level := Indent_Level - 1;
                     if Symbols (I).Aux_Offset > 0 and then Symbols (I).History_Size > 0 then
                        Line ("if a >= " & Trim_Image (Symbols (I).Aux_Offset) & " and a < " &
                              Trim_Image (Symbols (I).Aux_Offset + Symbols (I).History_Size * Elem) &
                              " and ((a - " & Trim_Image (Symbols (I).Aux_Offset) & ") % " &
                              Trim_Image (Elem) & ") == 0");
                        Indent_Level := Indent_Level + 1;
                        Line (Base_Moon &
                              "_history[math.floor((a - " & Trim_Image (Symbols (I).Aux_Offset) &
                              ") / " & Trim_Image (Elem) & ")] = " &
                              Cast_Expr (Symbols (I).Tag, "value"));
                        Line ("return");
                        Indent_Level := Indent_Level - 1;
                     end if;
                  when Sym_Struct_Var =>
                     Emit_Struct_Field_Cases
                       (Base_Moon,
                        Safe_Moon_Name (To_String (Symbols (I).Struct_Name)),
                        Base_Off,
                        True);
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
   end Emit_Address_Routines;

   procedure Emit_State_Routines is
      procedure Emit_String_Array_Load
        (Target_Name : String;
         Source_Expr : String) is
      begin
         Line ("if ALB_truthy(" & Source_Expr & ")");
         Indent_Level := Indent_Level + 1;
         Line ("for i = 0, (" & Target_Name &
               " 1024 and i < " & Source_Expr &
               " 1024) - 1 do " & Target_Name & "[i] = tostring(" & Source_Expr &
               "[i] or """")");
         Indent_Level := Indent_Level - 1;
      end Emit_String_Array_Load;
   begin
      New_Line_Emit;
      Line ("export ALB_SAVE_STATE = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("state = { vas: albVas }");
      Line ("albSaveStore['alb_state'] = state");
      Line ("return state");
      Indent_Level := Indent_Level - 1;
      Line ("export ALB_LOAD_STATE = (state) ->");
      Indent_Level := Indent_Level + 1;
      Line ("state = albSaveStore['alb_state'] if not state");
      Line ("return if not state");
      Line ("albVas = state.vas if state.vas");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
   end Emit_State_Routines;

   procedure Emit_Logic_Setup is
   begin
      if Rule_Node_Count = 0 and Watch_Node_Count = 0 then
         return;
      end if;

      Line ("export ALB_INIT_LOGIC = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("albRuleCount = 0");

      for I in 1 .. Rule_Node_Count loop
         declare
            Rule_Node    : constant Node_Index := Rule_Nodes (I);
            Rule_AST     : constant AST_Node := Tree (Rule_Node);
            Head_Node    : constant Node_Index := Rule_AST.Left_Child;
            Body_Query   : constant Node_Index := Rule_AST.Right_Child;
            Curr_Body    : Node_Index :=
              (if Body_Query > 0 then Tree (Body_Query).Left_Child else 0);
            Rule_Offset  : constant Integer := Integer (I - 1);
            Head_Var     : constant String := Upper_Text (Logic_Var_Name_From_Node (Head_Node));
            Body_Count   : Natural := 0;
            Base_Index   : Integer := 0;
            Body_Arg     : Node_Index := 0;
            Mode_Value   : Integer := 0;
            Body_Arg_Name : Unbounded_String := U ("");
         begin
            Line ("albRuleHeadPred[" & Trim_Image (Rule_Offset) & "] = " &
                  Predicate_Id_Expr (Head_Node));
            Line ("albRuleFlags[" & Trim_Image (Rule_Offset) & "] = " &
                  (if Rule_AST.Kind = AST_Constraint_Decl then "1" else "0"));

            while Curr_Body > 0 and then Body_Count < Max_Rule_Body_Terms loop
               Base_Index := Rule_Offset * Integer (Max_Rule_Body_Terms) + Integer (Body_Count);
               Body_Arg := Predicate_First_Arg_Node (Curr_Body);
               Body_Arg_Name := U ("");
               if Body_Arg > 0 and then Tree (Body_Arg).Token_Index > 0 then
                  Body_Arg_Name := U (Upper_Text (Raw_Lexeme (Tree (Body_Arg).Token_Index)));
               end if;
               if Body_Arg > 0
                 and then
                   (Tree (Body_Arg).Kind = AST_Logic_Var
                    or else (Head_Var'Length > 0 and then To_String (Body_Arg_Name) = Head_Var))
               then
                  Mode_Value := 1;
               else
                  Mode_Value := 0;
               end if;

               Line ("albRuleBodyPred[" & Trim_Image (Base_Index) & "] = " &
                     Predicate_Id_Expr (Curr_Body));
               Line ("albRuleBodyArgMode[" & Trim_Image (Base_Index) & "] = " &
                     Trim_Image (Mode_Value));
               Line ("albRuleBodyArgConst[" & Trim_Image (Base_Index) & "] = " &
                     (if Body_Arg > 0 and then Mode_Value = 0 then Expr (Body_Arg) else "0"));

               Body_Count := Body_Count + 1;
               Curr_Body := Tree (Curr_Body).Next_Sibling;
            end loop;

            Line ("albRuleBodyLen[" & Trim_Image (Rule_Offset) & "] = " &
                  Trim_Image (Integer (Body_Count)));
            Line ("albRuleCount = " & Trim_Image (Integer (I)));
         end;
      end loop;

      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Line ("ALB_NOTIFY_KNOWS_CHANGE = (pred, arg1, arg2, arg3, arg4) ->");
      Indent_Level := Indent_Level + 1;

      if Watch_Node_Count = 0 then
         Line ("return");
      else
         declare
            First_Watch : Boolean := True;
         begin
            for I in 1 .. Watch_Node_Count loop
               declare
                  Watch_Node : constant Node_Index := Watch_Nodes (I);
                  Watch_AST  : constant AST_Node := Tree (Watch_Node);
                  Pred_Node  : constant Node_Index := Watch_AST.Right_Child;
                  Body_Node  : constant Node_Index := Watch_AST.Left_Child;
                  Var_Name   : constant String := Logic_Var_Name_From_Node (Pred_Node);
                  Var_Moon    : constant String := Safe_Moon_Name (Var_Name);
                  Shadow_Id  : Natural := 0;
               begin
                  if First_Watch then
                     Line ("if pred == " & Predicate_Id_Expr (Pred_Node) & "");
                     First_Watch := False;
                  else
                     Line ("elseif pred == " & Predicate_Id_Expr (Pred_Node) & "");
                  end if;
                  Indent_Level := Indent_Level + 1;
                  if Var_Name'Length > 0 then
                     Line (Var_Moon & " = arg1");
                     Shadow_Id :=
                       Push_Shadow_Symbol
                         (Scope   => "",
                          Name    => Var_Name,
                          Moon_Name => Var_Moon,
                          Tag     => VK_Number);
                  end if;
                  Emit_Block (Body_Node);
                  if Shadow_Id > 0 then
                     Pop_Shadow_Symbol (Shadow_Id);
                  end if;
                  Indent_Level := Indent_Level - 1;
               end;
            end loop;
            if not First_Watch then
               null;
            end if;
         end;
      end if;

      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Line ("ALB_INIT_LOGIC()");
      New_Line_Emit;
   end Emit_Logic_Setup;

   procedure Emit_Switch_Stmt
     (Expr_Node      : Node_Index;
      First_Case     : Node_Index) is
      Switch_Value : constant String := Next_Temp_Name ("switch_value");
      Curr_Case    : Node_Index := First_Case;
      First_Branch : Boolean := True;
      Has_Default  : Boolean := False;
   begin
      Indent_Level := Indent_Level + 1;
      Line (Switch_Value & " = " & Expr (Expr_Node));
      while Curr_Case > 0 loop
         if Tree (Curr_Case).Left_Child = 0 then
            Has_Default := True;
            if First_Branch then
               Line ("if true");
            else
               Line ("else");
            end if;
         else
            if First_Branch then
               Line ("if " & Switch_Value & " == " &
                     Expr (Tree (Curr_Case).Left_Child) & " then");
            else
               Line ("elseif " & Switch_Value & " == " &
                     Expr (Tree (Curr_Case).Left_Child) & " then");
            end if;
         end if;
         First_Branch := False;
         Indent_Level := Indent_Level + 1;
         Emit_Block (Tree (Curr_Case).Right_Child);
         Indent_Level := Indent_Level - 1;
         Curr_Case := Tree (Curr_Case).Next_Sibling;
      end loop;
      if not First_Branch then
         null;
      end if;
      Indent_Level := Indent_Level - 1;
   end Emit_Switch_Stmt;

   procedure Emit_SwapPop
     (Target_Node : Node_Index;
      Count_Node  : Node_Index) is
      Target_AST    : constant AST_Node := Tree (Target_Node);
      Raw_Name      : constant String :=
        (if Target_AST.Token_Index > 0 then Raw_Lexeme (Target_AST.Token_Index) else "");
      Scoped_Group  : constant String := Scoped_Name (Raw_Name);
      Target_Sym    : constant Symbol_Record := Resolve_Symbol (Raw_Name);
      Count_Name    : constant String := Statement_Target_Name (Count_Node);
      Target_Index  : constant String :=
        (if Target_AST.Left_Child > 0
         then Build_Array_Index ((others => 0), 1, Target_AST.Left_Child)
         else "0");
      Swap_Index    : constant String := Next_Temp_Name ("swap_ix");
      Last_Index    : constant String := Next_Temp_Name ("last_ix");
      Found_Field   : Boolean := False;
   begin
      Line ("if " & Count_Name & " > 0");
      Indent_Level := Indent_Level + 1;
      Line (Swap_Index & " = " & Target_Index);
      Line (Last_Index & " = (" & Count_Name & " - 1)");
      Line ("if " & Swap_Index & " ~= " & Last_Index & "");
      Indent_Level := Indent_Level + 1;

      if Target_AST.Kind = AST_Var_Expr and then Target_AST.Left_Child > 0 then
         if Target_Sym.Active
           and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
         then
            Line (To_String (Target_Sym.Moon_Name) & "[" & Swap_Index & "] = " &
                  To_String (Target_Sym.Moon_Name) & "[" & Last_Index & "]");
            Found_Field := True;
         else
            for I in 1 .. Symbol_Count loop
               if Symbols (I).Active
                 and then Symbols (I).Kind = Sym_Parallel_Field
                 and then
                   (Starts_With (To_String (Symbols (I).Name), Scoped_Group & ".")
                    or else Starts_With (To_String (Symbols (I).Name), Raw_Name & "."))
               then
                  Line (To_String (Symbols (I).Moon_Name) & "[" & Swap_Index & "] = " &
                        To_String (Symbols (I).Moon_Name) & "[" & Last_Index & "]");
                  Found_Field := True;
               end if;
            end loop;
         end if;
      end if;

      if not Found_Field then
         Line ("-- SWAPPOP target could not be resolved statically");
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
      Target_Name : constant String := Statement_Target_Name (Target_Node, Decl_Tag);
      Base_Value_Text : constant String :=
        Cast_Expr (Decl_Tag, Emit_Value_Expr_With_Out (Value_Node));
      Value_Text      : constant String :=
        Wrap_Firewall_Write (Target_Node, Base_Value_Text);
   begin
      if Target_Node > 0 and then Tree (Target_Node).Kind = AST_Member_Expr then
         declare
            MNode      : constant AST_Node := Tree (Target_Node);
            Left_Node  : constant AST_Node := Tree (MNode.Left_Child);
            Right_Node : constant AST_Node := Tree (MNode.Right_Child);
            Left_Sym   : constant Symbol_Record :=
              (if Left_Node.Token_Index > 0 then Resolve_Symbol (Raw_Lexeme (Left_Node.Token_Index))
               else (others => <>));
            Field_Id   : constant Natural :=
              (if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var and then Right_Node.Token_Index > 0
               then Find_Field (To_String (Left_Sym.Struct_Name), Safe_Moon_Name (Raw_Lexeme (Right_Node.Token_Index)))
               else 0);
         begin
            if Field_Id /= 0 and then Fields (Field_Id).Bit_Width > 0 then
               Line (Field_Write_Expr (To_String (Left_Sym.Moon_Name), Field_Id, Value_Text));
               return;
            end if;
         end;
      end if;

      if Declare_New then
         --  ALB variables are routine-scoped; emit local Lua bindings.
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
      end if;

      if Tree (Block_Node).Kind = AST_Block_Stmt then
         Curr := Tree (Block_Node).Left_Child;
      else
         Curr := Block_Node;
      end if;

      while Curr > 0 loop
         Emit_Node (Curr);
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Block;

   procedure Register_Struct_From_Node (Index : Node_Index) is
      Node        : constant AST_Node := Tree (Index);
      Name_Node   : constant Node_Index := Node.Left_Child;
      Block_Node  : constant Node_Index := Node.Right_Child;
      Struct_Name : constant String := Safe_Moon_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
      Curr        : Node_Index := 0;
      Offset      : Integer := 0;
      Bit_Shift   : Integer := 0;
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
               Kind       : Value_Kind := VK_Number;
               Field_Name : Unbounded_String := U ("");
               Width      : Integer := 0;
               Shift      : Integer := 0;
            begin
               if Field_Node.Kind = AST_Bitfield_Decl then
                  if Field_Node.Left_Child > 0 then
                     Field_Name := U (Safe_Moon_Name (Raw_Lexeme (Tree (Field_Node.Left_Child).Token_Index)));
                  end if;
                  Width := Integer'Max (1, Eval_Static_Int (Field_Node.Right_Child));
                  Shift := Bit_Shift;
                  Kind := VK_U32;
               else
                  declare
                     Field_Name_Node : constant Node_Index := Field_Node.Left_Child;
                  begin
                     if Bit_Shift > 0 then
                        Offset := Offset + 1;
                        Bit_Shift := 0;
                     end if;
                     if Field_Name_Node > 0 then
                        Field_Name := U (Safe_Moon_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)));
                     end if;
                     if Field_Node.Token_Index > 0 then
                        Kind := Type_From_Name (Raw_Lexeme (Field_Node.Token_Index));
                     end if;
                  end;
               end if;

               if Field_Count < Max_Fields then
                  Field_Count := Field_Count + 1;
                  Fields (Field_Count).Active := True;
                  Fields (Field_Count).Struct_Name := U (Struct_Name);
                  Fields (Field_Count).Field_Name := Field_Name;
                  Fields (Field_Count).Moon_Field := Field_Name;
                  Fields (Field_Count).Type_Name :=
                    (if Field_Node.Token_Index > 0
                     then U (Raw_Lexeme (Field_Node.Token_Index))
                     else U (""));
                  Fields (Field_Count).Tag := Kind;
                  Fields (Field_Count).Offset_Bytes := Offset;
                  Fields (Field_Count).Bit_Width := Width;
                  Fields (Field_Count).Bit_Shift := Shift;
               end if;

               if Width > 0 then
                  Bit_Shift := Bit_Shift + Width;
                  while Bit_Shift >= 8 loop
                     Bit_Shift := Bit_Shift - 8;
                     Offset := Offset + 1;
                  end loop;
               else
                  Offset := Offset + Element_Bytes (Kind);
               end if;
            end;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;

      if Bit_Shift > 0 then
         Offset := Offset + 1;
      end if;
      Structs (Struct_Count).Size_Bytes := Offset;
   end Register_Struct_From_Node;

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
         Moon_Name   : constant String :=
           (if Upper_Text (Func_Name) = "GETTICKCOUNT"
            then "ALB_User_GetTickCount"
            else Scoped_Name (Func_Name));
      begin
         Register_Routine (Func_Name, Moon_Name, Param_Count, Modes);
      end;
   end Register_Routine_Signature;

   procedure Pre_Register_Routines (First : Node_Index) is
      Curr : Node_Index := First;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Program | AST_Block_Stmt =>
               Pre_Register_Routines (Tree (Curr).Left_Child);

            when AST_Module =>
               declare
                  Name_Node    : constant Node_Index := Tree (Curr).Left_Child;
                  Saved_Module : constant Unbounded_String := Current_Module;
               begin
                  if Name_Node > 0 and then Tree (Name_Node).Token_Index > 0 then
                     Current_Module := U (Safe_Moon_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Pre_Register_Routines (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;

            when AST_Procedure_Decl | AST_Function_Decl =>
               Register_Routine_Signature (Curr);
               Pre_Register_Routines (Tree (Curr).Right_Child);

            when others =>
               if Tree (Curr).Left_Child > 0 then
                  Pre_Register_Routines (Tree (Curr).Left_Child);
               end if;
               if Tree (Curr).Right_Child > 0 then
                  Pre_Register_Routines (Tree (Curr).Right_Child);
               end if;
         end case;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Pre_Register_Routines;

   procedure Emit_Function_Decl
     (Index       : Node_Index;
      Is_Function : Boolean) is
      Node         : constant AST_Node := Tree (Index);
      Name_Node    : constant Node_Index := Node.Left_Child;
      Body_Node    : constant Node_Index := Node.Right_Child;
      Func_Name    : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
      Moon_Name      : constant String :=
        (if Upper_Text (Func_Name) = "GETTICKCOUNT"
         then "ALB_User_GetTickCount"
         else Scoped_Name (Func_Name));
      Old_Routine  : constant Unbounded_String := Current_Routine;
      Param_Count  : Natural := 0;
      Modes        : Param_Mode_List := (others => Param_In);
      Curr_Param   : Node_Index := 0;
      First_Param  : Boolean := True;
      List_Node    : Node_Index := 0;
      Return_Type  : Value_Kind := VK_Number;
      Bound_Node   : Node_Index := 0;
   begin
      if Name_Node = 0 then
         return;
      end if;

      Current_Routine := U (Moon_Name);
      Current_Routine_Out_Count := 0;

      if Is_Function and then Node.Token_Index > 0 then
         Return_Type := Type_From_Token (Node.Token_Index);
         if Return_Type = VK_Unknown then
            Return_Type := VK_Number;
         end if;
      end if;

      Emit_Indent;
      Emit ("export " & Moon_Name & " = (");

      List_Node := Tree (Name_Node).Right_Child;
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Type_Node       : constant Node_Index := Tree (Curr_Param).Right_Child;
                  Param_Name      : constant String :=
                    Raw_Lexeme (Tree (Param_Name_Node).Token_Index);
                  Param_Kind      : constant Value_Kind :=
                    (if Type_Node > 0
                     then Type_From_Name (Raw_Lexeme (Tree (Type_Node).Token_Index))
                     else VK_Number);
                  Mode            : constant Param_Mode_Kind :=
                    (if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out
                     then Param_Out
                     else Param_In);
                  Decl_Name       : constant String :=
                    (if Mode = Param_Out
                     then "__out_" & Safe_Moon_Name (Param_Name)
                     else Safe_Moon_Name (Param_Name));
               begin
                  if not First_Param then
                     Emit (", ");
                  end if;
                  if Mode = Param_Out then
                     Emit (Decl_Name);
                     if Current_Routine_Out_Count < Max_Params then
                        Current_Routine_Out_Count := Current_Routine_Out_Count + 1;
                        Current_Routine_Out_Names (Current_Routine_Out_Count) :=
                          U (Safe_Moon_Name (Param_Name));
                     end if;
                  else
                     Emit (Decl_Name);
                  end if;
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

      if Is_Function then
         Emit (") ->");
      else
         Emit (") ->");
      end if;
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;

      Register_Routine (Func_Name, Moon_Name, Param_Count, Modes);

      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Type_Node       : constant Node_Index := Tree (Curr_Param).Right_Child;
                  Param_Name      : constant String :=
                    Raw_Lexeme (Tree (Param_Name_Node).Token_Index);
                  Param_Kind      : constant Value_Kind :=
                    (if Type_Node > 0
                     then Type_From_Name (Raw_Lexeme (Tree (Type_Node).Token_Index))
                     else VK_Number);
                  Mode            : constant Param_Mode_Kind :=
                    (if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out
                     then Param_Out
                     else Param_In);
                  Decl_Name       : constant String := Safe_Moon_Name (Param_Name);
               begin
                  Register_Symbol
                    (Scope => Moon_Name,
                     Name => Param_Name,
                     Moon_Name => Decl_Name,
                     Tag => Param_Kind,
                     Kind => Sym_Param);
                  if Mode = Param_Out then
                     Line (Decl_Name & " = __out_" & Decl_Name & ".value");
                  end if;
               end;
            elsif Tree (Curr_Param).Kind = AST_Require_Clause then
               Line ("ALB_FATAL(" & Escape_Moon_String ("REQUIRE failed") &
                     ") if not ALB_truthy(" & Expr (Tree (Curr_Param).Left_Child) & ")");
            elsif Tree (Curr_Param).Kind = AST_Bound_To_Clause then
               Bound_Node := Curr_Param;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Line ("ALB_FIREWALL_ENTER(" & Expr (Tree (Bound_Node).Left_Child) & ")");
         Line ("__alb_fw_ok, __alb_fw_err = pcall ->");
         Indent_Level := Indent_Level + 1;
      end if;

      -- ALBM hot path: mesh FillTriangle/Render are far too slow as interpreted
      -- MoonScript/Lua. Route them through alb_sdl3 geometry instead.
      if Moon_Name'Length >= 13
        and then Moon_Name (Moon_Name'Last - 12 .. Moon_Name'Last) = "_FillTriangle"
      then
         Line ("ALB_COLOR(ccol)");
         Line ("ALB_FILL_TRIANGLE(x1, y1, x2, y2, x3, y3)");
      elsif Moon_Name = "StrawBerry_Render" then
         Line ("ALB_PAINTER_MESH(StrawBerry_SB_v_x, StrawBerry_SB_v_y, StrawBerry_SB_v_z, " &
               "StrawBerry_SB_f_p1, StrawBerry_SB_f_p2, StrawBerry_SB_f_p3, StrawBerry_SB_f_col, " &
               "StrawBerry_SB_v_count, StrawBerry_SB_f_count, " &
               "rot_yaw, rot_pitch, cam_z, scale, cx, cy, 144)");
      elsif Moon_Name = "Ant_Render" then
         Line ("ALB_PAINTER_MESH(Ant_ANT_v_x, Ant_ANT_v_y, Ant_ANT_v_z, " &
               "Ant_ANT_f_p1, Ant_ANT_f_p2, Ant_ANT_f_p3, Ant_ANT_f_col, " &
               "Ant_ANT_v_count, Ant_ANT_f_count, " &
               "rot_yaw, rot_pitch, cam_z, scale, cx, cy, 0)");
      else
         Emit_Block (Body_Node);
      end if;

      if Param_Count > 0 then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Param_Name : constant String := Safe_Moon_Name (Raw_Lexeme (Tree (Param_Name_Node).Token_Index));
               begin
                  if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then
                     Line ("__out_" & Param_Name & ".value = " & Param_Name);
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
         Line ("ALB_FIREWALL_LEAVE()");
         Line ("ALB_FATAL(__alb_fw_err) if not __alb_fw_ok");
      end if;

      Indent_Level := Indent_Level - 1;
      New_Line_Emit;

      Current_Routine := Old_Routine;
   end Emit_Function_Decl;

   procedure Emit_Call_With_Out
     (Target_Name : String;
      Arg_List    : Node_Index) is
      Routine_Id : constant Natural := Find_Routine_For_Call (Target_Name);
      Curr       : Node_Index := 0;
      Param_No   : Natural := 0;
      Has_Out    : Boolean := False;
      Args       : array (1 .. Max_Params) of Unbounded_String := (others => U (""));
      Targets    : array (1 .. Max_Params) of Unbounded_String := (others => U (""));
   begin
       if Routine_Id = 0 then
          Line (Target_Name & "(" & Join_Arg_List (Arg_List) & ")");
          return;
      end if;

      Curr := Tree (Arg_List).Left_Child;
      while Curr > 0 and then Param_No < Max_Params loop
         Param_No := Param_No + 1;
         if Routines (Routine_Id).Param_Modes (Param_No) = Param_Out then
            Has_Out := True;
            Args (Param_No) := U ("__out_" & Trim_Image (Integer (Param_No)));
            Targets (Param_No) := U (Statement_Target_Name (Curr));
         else
            Args (Param_No) := U (Expr (Curr));
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      if not Has_Out then
         declare
            Call_Args : Unbounded_String := U ("");
         begin
            for I in 1 .. Param_No loop
               if I > 1 then
                  Append (Call_Args, ", ");
               end if;
               Append (Call_Args, To_String (Args (I)));
            end loop;
            Line (Target_Name & "(" & To_String (Call_Args) & ")");
         end;
         return;
      end if;

      Indent_Level := Indent_Level + 1;
      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line ("__out_ = nil" & Trim_Image (Integer (I)) & " = { value = " &
                  To_String (Targets (I)) & " }");
         end if;
      end loop;

      declare
         Call_Args : Unbounded_String := U ("");
      begin
         for I in 1 .. Param_No loop
            if I > 1 then
               Append (Call_Args, ", ");
            end if;
            Append (Call_Args, To_String (Args (I)));
         end loop;
         Line (Target_Name & "(" & To_String (Call_Args) & ")");
      end;

      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line (To_String (Targets (I)) & " = __out_" & Trim_Image (Integer (I)) & ".value");
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
   end Emit_Call_With_Out;

   procedure Emit_Node (Index : Node_Index) is
      Node : constant AST_Node := Tree (Index);
      Target_Node : Node_Index := 0;
      Value_Node  : Node_Index := 0;
      Raw_Name    : Unbounded_String := U ("");
      Moon_Name     : Unbounded_String := U ("");
      Sym_Id      : Natural := 0;
      Tag         : Value_Kind := VK_Number;
      Dims        : Dim_List := (others => 0);
      Rank        : Natural := 0;
      Capacity    : Integer := 0;
   begin
      case Node.Kind is
         when AST_Program =>
            Emit_Block (Node.Left_Child);

         when AST_Block_Stmt =>
            Emit_Block (Index);

         when AST_Module =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Body_Node : constant Node_Index := Node.Right_Child;
               Saved     : constant Unbounded_String := Current_Module;
            begin
               if Name_Node > 0 then
                  Current_Module := U (Safe_Moon_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
               end if;
               Emit_Block (Body_Node);
               Current_Module := Saved;
            end;

         when AST_DeclareModule | AST_Import | AST_Import_C | AST_Include_Stmt | AST_Version |
              AST_Range_Type_Decl =>
            null;

         when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar =>
            null;

         when AST_Import_ES | AST_Import_WASM =>
            Emit_Foreign_Import_Node (Index);

         when AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar |
              AST_Export_ES | AST_Export_WASM =>
            null;

         when AST_Set_Shoebox_Stmt =>
            Shoebox_Root := U (Resolve_Static_Asset_Path (Strip_String_Node (Node.Left_Child)));

         when AST_Static_Sprite_Decl =>
            declare
               Name_Node    : constant Node_Index := Node.Left_Child;
               Sprite_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Sprite_Moon    : constant String := Scoped_Name (Sprite_Name);
               Setting      : Node_Index := Node.Right_Child;
               Source_Path  : Unbounded_String := U ("");
               Frame_Width  : Integer := 1;
               Frame_Height : Integer := 1;
               Frame_Count  : Integer := 1;
               Format_Text  : Unbounded_String := U ("INDEXED8BIT");
               Saw_Format   : Boolean := False;
               Embed_Name   : constant String := "__alb_bmp_" & Safe_Moon_Name (Sprite_Moon);
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Static_Source =>
                        Source_Path := U (Resolve_Static_Asset_Path (Strip_String_Node (Tree (Setting).Left_Child)));
                     when AST_Static_Format =>
                        Format_Text := U (Upper_Text (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                        Saw_Format := True;
                     when AST_Static_Width =>
                        Frame_Width := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when AST_Static_Height =>
                        Frame_Height := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when AST_Static_Frames =>
                        Frame_Count := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Sprite_Moon, Sprite_Moon, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-sprite-default-format",
                                  "STATIC_SPRITE without FORMAT defaults to INDEXED8BIT on ALBM");
               elsif To_String (Format_Text) /= "INDEXED8BIT" then
                  Emit_Warn_Once ("static-sprite-format-" & Safe_Moon_Name (To_String (Format_Text)),
                                  "STATIC_SPRITE format " & To_String (Format_Text) &
                                  " is approximated as INDEXED8BIT on ALBM");
               end if;
               if Length (Source_Path) > 0 then
                  Emit_Embedded_File_Bytes (Embed_Name, To_String (Source_Path));
               else
                  Emit_Warn_Once ("static-sprite-missing-source-" & Safe_Moon_Name (Sprite_Moon),
                                  "STATIC_SPRITE without SOURCE becomes a blank sprite on ALBM");
                  Line (Embed_Name & " = ALB_new_array(1, 0)");
               end if;
               Line (Sprite_Moon & " = ALB_STATIC_SPRITE_FROM_BMP(" &
                     Embed_Name & ", " & Trim_Image (Frame_Width) & ", " &
                     Trim_Image (Frame_Height) & ", " & Trim_Image (Frame_Count) & ")");
               New_Line_Emit;
            end;

         when AST_Static_Surface_Decl =>
            declare
               Name_Node   : constant Node_Index := Node.Left_Child;
               Surface_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Surface_Moon   : constant String := Scoped_Name (Surface_Name);
               Setting      : Node_Index := Node.Right_Child;
               Width_Val    : Integer := 1;
               Height_Val   : Integer := 1;
               Format_Text  : Unbounded_String := U ("RGB565");
               Saw_Format   : Boolean := False;
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Static_Format =>
                        Format_Text := U (Upper_Text (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                        Saw_Format := True;
                     when AST_Static_Width =>
                        Width_Val := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when AST_Static_Height =>
                        Height_Val := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Surface_Moon, Surface_Moon, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-surface-default-format",
                                  "STATIC_SURFACE without FORMAT defaults to RGB565 on ALBM");
               elsif To_String (Format_Text) /= "RGB565" then
                  Emit_Warn_Once ("static-surface-format-" & Safe_Moon_Name (To_String (Format_Text)),
                                  "STATIC_SURFACE format " & To_String (Format_Text) &
                                  " is approximated as RGB565 on ALBM");
               end if;
               Line (Surface_Moon & " = ALB_STATIC_SURFACE(" &
                     Trim_Image (Width_Val) & ", " & Trim_Image (Height_Val) & ")");
               New_Line_Emit;
            end;

         when AST_Color_Lut_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               LUT_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               LUT_Moon    : constant String := Scoped_Name (LUT_Name);
               Entry_Node : Node_Index := Node.Right_Child;
               type LUT_Array is array (Natural range 0 .. 255) of Integer;
               Values : LUT_Array := (others => 0);
               First  : Boolean := True;
            begin
               while Entry_Node > 0 loop
                  if Tree (Entry_Node).Kind = AST_Color_Lut_Entry then
                     declare
                        Slot : constant Integer := Eval_Static_Int (Tree (Entry_Node).Left_Child);
                     begin
                        if Slot in Values'Range then
                           Values (Slot) := Eval_Static_Int (Tree (Entry_Node).Right_Child);
                        end if;
                     end;
                  end if;
                  Entry_Node := Tree (Entry_Node).Next_Sibling;
               end loop;

               Register_Symbol ("", LUT_Moon, LUT_Moon, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit (LUT_Moon & " = ALB_bytes({");
               for I in Values'Range loop
                  if not First then
                     Emit (", ");
                  end if;
                  Emit (Trim_Image (Values (I)));
                  First := False;
               end loop;
               Emit ("])");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Visual_Rule_Decl =>
            declare
               Name_Node  : constant Node_Index := Node.Left_Child;
               Rule_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Rule_Moon   : constant String := Scoped_Name (Rule_Name);
               Param_List : constant Node_Index := Tree (Name_Node).Right_Child;
               Param_Node : constant Node_Index :=
                 (if Param_List > 0 and then Tree (Param_List).Kind = AST_Arg_List
                  then Tree (Param_List).Left_Child
                  else 0);
               Param_Name : constant String :=
                 (if Param_Node > 0 then Safe_Moon_Name (Raw_Feature_Atom (Param_Node)) else "_alb_context");
               Clause     : Node_Index := Node.Right_Child;
            begin
               Register_Symbol ("", Rule_Moon, Rule_Moon, VK_Number, Sym_Scalar);
               Line (Rule_Moon & " = {");
               Indent_Level := Indent_Level + 1;
               Line ("kind: ""visualRule"",");
               Line ("name: " & Escape_Moon_String (Rule_Name) & ",");
               Line ("resolve: (" & Param_Name & ") ->");
               Indent_Level := Indent_Level + 1;
               while Clause > 0 loop
                  if Tree (Clause).Kind = AST_Visual_When_Clause then
                     Line ("if ALB_truthy(" & Expr (Tree (Clause).Left_Child) & ")");
                     Indent_Level := Indent_Level + 1;
                     Line ("return { sprite: " & Expr (Tree (Clause).Right_Child) &
                           ", frame: " & Expr (Tree (Tree (Clause).Right_Child).Next_Sibling) & " }");
                     Indent_Level := Indent_Level - 1;
                  elsif Tree (Clause).Kind = AST_Visual_Default_Clause then
                     Line ("return { sprite: " & Expr (Tree (Clause).Left_Child) &
                           ", frame: " & Expr (Tree (Clause).Right_Child) & " }");
                  end if;
                  Clause := Tree (Clause).Next_Sibling;
               end loop;
               Line ("return { sprite: 0, frame: 0 }");
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
               Line ("}");
               New_Line_Emit;
            end;

         when AST_Render_Viewport_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               View_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               View_Moon   : constant String := Scoped_Name (View_Name);
               Setting   : constant Node_Index := Node.Right_Child;
               X_Node    : constant Node_Index := Tree (Setting).Left_Child;
               Y_Node    : constant Node_Index := Tree (Setting).Right_Child;
               W_Node    : constant Node_Index := (if Y_Node > 0 then Tree (Y_Node).Next_Sibling else 0);
               H_Node    : constant Node_Index := (if W_Node > 0 then Tree (W_Node).Next_Sibling else 0);
            begin
               Register_Symbol ("", View_Moon, View_Moon, VK_Number, Sym_Scalar);
               Line (View_Moon & " = ALB_STATIC_VIEWPORT(" &
                     Expr (X_Node) & ", " & Expr (Y_Node) & ", " &
                     Expr (W_Node) & ", " & Expr (H_Node) & ")");
               New_Line_Emit;
            end;

         when AST_Bitmap_Font_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Font_Name      : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Font_Moon        : constant String := Scoped_Name (Font_Name);
               Setting        : Node_Index := Node.Right_Child;
               Source_Text    : Unbounded_String := U ("");
               Descriptor_Text : Unbounded_String := U ("");
               Format_Text    : Unbounded_String := U ("INDEXED8BIT");
               Glyph_Width    : Unbounded_String := U ("8");
               Glyph_Height   : Unbounded_String := U ("8");
               First_Char     : Unbounded_String := U ("32");
               Spacing_Text   : Unbounded_String := U ("0");
            begin
               while Setting > 0 loop
                     case Tree (Setting).Kind is
                        when AST_Static_Source =>
                        Source_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Descriptor =>
                        Descriptor_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Static_Format =>
                        Format_Text := U (Feature_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Glyph_Width =>
                        Glyph_Width := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Glyph_Height =>
                        Glyph_Height := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_First_Char =>
                        First_Char := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Spacing =>
                        Spacing_Text := U (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Font_Moon, Font_Moon, VK_U64, Sym_Scalar);
               if Length (Descriptor_Text) > 0 then
                  Emit_Warn_Once ("bitmap-font-descriptor-" & Safe_Moon_Name (Font_Moon),
                                  "BITMAP_FONT descriptor metadata is accepted but canvas text remains an approximation on ALBM");
               end if;
               Line (Font_Moon & " = ALB_DEFINE_BITMAP_FONT(" &
                     Escape_Moon_String (Font_Name) & ", " &
                     (if Length (Source_Text) > 0 then To_String (Source_Text) else Escape_Moon_String ("")) & ", " &
                     To_String (Format_Text) & ", " &
                     To_String (Glyph_Width) & ", " &
                     To_String (Glyph_Height) & ", " &
                     To_String (First_Char) & ", " &
                     To_String (Spacing_Text) & ")");
               New_Line_Emit;
            end;

         when AST_System_Font_Decl =>
            declare
               Name_Node       : constant Node_Index := Node.Left_Child;
               Font_Name       : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Font_Moon         : constant String := Scoped_Name (Font_Name);
               Setting         : Node_Index := Node.Right_Child;
               Family_Text     : Unbounded_String := U (Escape_Moon_String (Font_Name));
               Size_Text       : Unbounded_String := U ("16");
               Weight_Text     : Unbounded_String := U (Escape_Moon_String ("normal"));
               Anti_Alias_Text : Unbounded_String := U ("1");
               Charset_Start   : Unbounded_String := U ("32");
               Charset_End     : Unbounded_String := U ("126");
            begin
               while Setting > 0 loop
                     case Tree (Setting).Kind is
                     when AST_Static_Source =>
                        Family_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Size =>
                        Size_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Weight =>
                        Weight_Text := U (Feature_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Anti_Alias =>
                        Anti_Alias_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Character_Set =>
                        Charset_Start := U (Expr (Tree (Setting).Left_Child));
                        Charset_End := U ((if Tree (Setting).Right_Child > 0
                                           then Expr (Tree (Setting).Right_Child)
                                           else Expr (Tree (Setting).Left_Child)));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Font_Moon, Font_Moon, VK_U64, Sym_Scalar);
               Line (Font_Moon & " = ALB_DEFINE_SYSTEM_FONT(" &
                     To_String (Family_Text) & ", " &
                     To_String (Size_Text) & ", " &
                     To_String (Weight_Text) & ", " &
                     "(ALB_truthy(" & To_String (Anti_Alias_Text) & "))" & ", " &
                     To_String (Charset_Start) & ", " &
                     To_String (Charset_End) & ")");
               New_Line_Emit;
            end;

         when AST_Memory_Firewall_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               FW_Moon     : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Rule_Node : Node_Index := Node.Right_Child;
               Read_Text : Unbounded_String := U ("");
               Write_Text : Unbounded_String := U ("");
               First_Read : Boolean := True;
               First_Write : Boolean := True;
               Deny_All : Boolean := False;
            begin
               while Rule_Node > 0 loop
                  case Tree (Rule_Node).Kind is
                     when AST_Firewall_Permit_Read =>
                        declare
                           Key : constant String :=
                             Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              if not First_Read then
                                 Append (Read_Text, ", ");
                              end if;
                              Append (Read_Text, "[" & Escape_Moon_String (Key) & "]=true");
                              First_Read := False;
                           end if;
                        end;

                     when AST_Firewall_Permit_Write =>
                        declare
                           Key : constant String :=
                             Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              if not First_Write then
                                 Append (Write_Text, ", ");
                              end if;
                              Append (Write_Text, "[" & Escape_Moon_String (Key) & "]=true");
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

               Register_Symbol ("", FW_Moon, FW_Moon, VK_Number, Sym_Scalar);
               Line (FW_Moon & " = { kind: ""firewall"", name = " &
                     Escape_Moon_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
                     ", denyAll: " & (if Deny_All then "true" else "false") &
                     ", read = {" & To_String (Read_Text) &
                     "}, write = {" & To_String (Write_Text) & "} }");
               New_Line_Emit;
            end;

         when AST_Process_Handle_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Proc_Moon   : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Setting   : Node_Index := Node.Right_Child;
               Image_Text : Unbounded_String := U ("process");
               Rights_Text : Unbounded_String := U ("");
               Pid_Text    : Unbounded_String := U ("0");
               First_Right : Boolean := True;
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Process_Pid =>
                        Pid_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Process_Image =>
                        Image_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Process_Rights =>
                        declare
                           Right_Node : Node_Index := Tree (Setting).Left_Child;
                        begin
                           while Right_Node > 0 loop
                              if not First_Right then
                                 Append (Rights_Text, ", ");
                              end if;
                              Append (Rights_Text, Escape_Moon_String (Raw_Feature_Atom (Right_Node)));
                              First_Right := False;
                              Right_Node := Tree (Right_Node).Next_Sibling;
                           end loop;
                        end;
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Proc_Moon, Proc_Moon, VK_U64, Sym_Scalar);
               Line (Proc_Moon & " = ALB_PROCESS_DEFINE(" &
                     To_String (Image_Text) & ", [" &
                     To_String (Rights_Text) & "], " & To_String (Pid_Text) & ")");
               New_Line_Emit;
            end;

         when AST_Network_Sniffer_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Sniffer_Name   : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Sniffer_Moon     : constant String := Scoped_Name (Sniffer_Name);
               Error_Moon       : constant String := Scoped_Name (Sniffer_Name & "_ERROR");
               Setting        : Node_Index := Node.Right_Child;
               Interface_Text : Unbounded_String := U (Escape_Moon_String ("any"));
               Protocol_Text  : Unbounded_String := U ("1");
               Port_Text      : Unbounded_String := U ("0");
               Buffer_Text    : Unbounded_String := U ("1514");
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Sniffer_Interface =>
                        Interface_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Sniffer_Protocol =>
                        Protocol_Text := U (Network_Protocol_Code (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                     when AST_Sniffer_Port =>
                        Port_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Sniffer_Buffer_Size =>
                        Buffer_Text := U (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Sniffer_Moon, Sniffer_Moon, VK_U64, Sym_Scalar);
               Register_Symbol ("", Error_Moon, Error_Moon, VK_U64, Sym_Scalar);
               Emit_Warn_Once ("network-sniffer-albw",
                               "NETWORK_SNIFFER is simulated on ALBM with deterministic sample packets");
               Line (Error_Moon & " = ALB_MAKE_CELL(0)");
               Line (Sniffer_Moon & " = ALB_SNIFFER_DEFINE(" &
                     To_String (Interface_Text) & ", " &
                     To_String (Protocol_Text) & ", " &
                     To_String (Port_Text) & ", " &
                     To_String (Buffer_Text) & ")");
               Line (Sniffer_Moon & ".errorCell = " & Error_Moon);
               New_Line_Emit;
            end;

         when AST_Network_Socket_Decl =>
            declare
               Name_Node    : constant Node_Index := Node.Left_Child;
               Socket_Moon    : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Setting      : Node_Index := Node.Right_Child;
               Protocol_Code : Unbounded_String := U ("1");
               Port_Val      : Unbounded_String := U ("0");
               Buffer_Val    : Unbounded_String := U ("64");
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Network_Protocol =>
                        Protocol_Code := U (Network_Protocol_Code (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                     when AST_Network_Port =>
                        Port_Val := U (Expr (Tree (Setting).Left_Child));
                     when AST_Network_Buffer_Size =>
                        Buffer_Val := U (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Socket_Moon, Socket_Moon, VK_U64, Sym_Scalar);
               Line (Socket_Moon & " = ALB_NET_DEFINE(" &
                     To_String (Protocol_Code) & ", " & To_String (Port_Val) & ", " &
                     To_String (Buffer_Val) & ")");
               New_Line_Emit;
            end;

         when AST_Markov_Model_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Model_JS  : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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

               Register_Symbol ("", Model_JS, Model_JS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ( Model_JS & " = { states: " & To_String (States_Text) & ", matrix: [");
               declare
                  Row_Node  : Node_Index := Matrix_Node;
                  Elem_Node : Node_Index := 0;
                  First     : Boolean := True;
               begin
                  while Row_Node > 0 loop
                     Elem_Node := Tree (Row_Node).Left_Child;
                     while Elem_Node > 0 loop
                        if not First then
                           Emit (", ");
                        end if;
                        Emit (Expr (Elem_Node));
                        First := False;
                        Elem_Node := Tree (Elem_Node).Next_Sibling;
                     end loop;
                     Row_Node := Tree (Row_Node).Next_Sibling;
                  end loop;
               end;
               Emit ("] }");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Neural_Topology_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Net_JS    : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Layer_Node : Node_Index := Node.Right_Child;
               First     : Boolean := True;
               First_Act : Boolean := True;
            begin
               Register_Symbol ("", Net_JS, Net_JS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ( Net_JS & " = ALB_NN_CREATE(" &
                     Escape_Moon_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
                     ", [");
               while Layer_Node > 0 loop
                  if not First then
                     Emit (", ");
                  end if;
                  Emit (Expr (Tree (Layer_Node).Left_Child));
                  First := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Emit ("], [");
               Layer_Node := Node.Right_Child;
               while Layer_Node > 0 loop
                  if not First_Act then
                     Emit (", ");
                  end if;
                  if Tree (Layer_Node).Right_Child > 0 then
                     Emit (Activation_Code (Raw_Feature_Atom (Tree (Layer_Node).Right_Child)));
                  else
                     Emit ("0");
                  end if;
                  First_Act := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Emit ("])");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Const_Decl =>
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               declare
                  R : constant String := To_String (Raw_Name);
                  Existing : Natural;
               begin
                  Moon_Name := U (Safe_Moon_Name (R (R'First + 1 .. R'Last)));
                  Capacity := Eval_Static_Int (Value_Node);
                  Existing := Find_Symbol ("", To_String (Moon_Name));
                  if Existing = 0 then
                     --  Use let so later #CONST redefinitions (common across
                     --  engine modules) can reassign under ES module mode.
                     Register_Symbol
                       ("", To_String (Moon_Name), To_String (Moon_Name),
                        VK_Number, Sym_Const, Capacity => Capacity);
                     Line (To_String (Moon_Name) &
                           " = " & Expr (Value_Node));
                  else
                     Symbols (Existing).Capacity := Capacity;
                     Line (To_String (Moon_Name) & " = " & Expr (Value_Node));
                  end if;
               end;
            end if;

         when AST_Enum_Decl =>
            declare
               Curr  : Node_Index := Node.Left_Child;
               Value : Integer := 0;
            begin
               while Curr > 0 loop
                  Raw_Name := U (Raw_Lexeme (Tree (Curr).Token_Index));
                  Moon_Name := U (Safe_Moon_Name (To_String (Raw_Name)));
                  declare
                     Existing : constant Natural :=
                       Find_Symbol ("", To_String (Moon_Name));
                  begin
                     if Existing = 0 then
                        Register_Symbol
                          ("", To_String (Moon_Name), To_String (Moon_Name),
                           VK_Number, Sym_Const, Capacity => Value);
                        Line (To_String (Moon_Name) &
                              " = " & Trim_Image (Value));
                     else
                        Symbols (Existing).Capacity := Value;
                        Line (To_String (Moon_Name) & " = " &
                              Trim_Image (Value));
                     end if;
                  end;
                  Value := Value + 1;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
               New_Line_Emit;
            end;

         when AST_Struct_Decl =>
            Register_Struct_From_Node (Index);
            declare
               Struct_Name : constant String := Safe_Moon_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
            begin
               Line ("-- struct " & Struct_Name & " (fields accessed as table keys on ALBM)");
               New_Line_Emit;
            end;

         when AST_Strict_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Moon_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0
                       then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                       else VK_Number);
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
               Register_Symbol ("", To_String (Moon_Name), To_String (Moon_Name), Tag, Sym_Strict_Array, Rank, Dims, Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               if Tag in VK_String | VK_Binary then
                  Line (To_String (Moon_Name) &
                        " = ALB_new_array(" & Trim_Image (Capacity) & ", " & Escape_Moon_String ("") & ")");
               else
                  Line (To_String (Moon_Name) & " = " & Typed_Array_Name (Tag) &
                        "(" & Trim_Image (Capacity) & ")");
               end if;
            end if;

         when AST_Slide_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Moon_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0
                       then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                       else VK_Number);
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (Moon_Name), To_String (Moon_Name), Tag, Sym_Slide_Array, 1, (1 => Capacity, others => 0), Capacity,
                                Active_Size => (if Tree (Node.Right_Child).Next_Sibling > 0 then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling) else Capacity),
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               if Tag in VK_String | VK_Binary then
                  Line (To_String (Moon_Name) &
                        " = ALB_new_array(" & Trim_Image (Capacity) & ", " & Escape_Moon_String ("") & ")");
               else
                  Line (To_String (Moon_Name) & " = " & Typed_Array_Name (Tag) &
                        "(" & Trim_Image (Capacity) & ")");
               end if;
               Line (To_String (Moon_Name) & "_active = " &
                     Trim_Image ((if Tree (Node.Right_Child).Next_Sibling > 0
                                  then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling)
                                  else Capacity)));
            end if;

         when AST_Parallel_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Moon_Name := U (Scoped_Name (To_String (Raw_Name)));
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
                        Field_Moon        : constant String := Safe_Moon_Name (To_String (Raw_Name) & "_" & Field_Name);
                        Field_Tag       : constant Value_Kind :=
                          (if Tree (Field_Name_Node).Right_Child > 0
                           then Type_From_Name (Raw_Lexeme (Tree (Tree (Field_Name_Node).Right_Child).Token_Index))
                           else VK_Number);
                     begin
                        Register_Symbol ("", To_String (Moon_Name) & "." & Field_Name, Field_Moon, Field_Tag,
                                         Sym_Parallel_Field, Rank, Dims, Capacity,
                                         Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Field_Tag)));
                        if Field_Tag in VK_String | VK_Binary then
                           Line (Field_Moon &
                                 " = ALB_new_array(" & Trim_Image (Capacity) & ", " & Escape_Moon_String ("") & ")");
                        else
                           Line (Field_Moon & " = " & Typed_Array_Name (Field_Tag) &
                                 "(" & Trim_Image (Capacity) & ")");
                        end if;
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
               Moon_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := VK_Number;
               end if;
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (Moon_Name), To_String (Moon_Name), Tag, Sym_Temporal,
                                History_Size => Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (Tag)));
               declare
                  TId : constant Natural := Find_Symbol ("", To_String (Moon_Name));
               begin
                  if TId /= 0 then
                     Symbols (TId).Aux_Offset := Allocate_Address_Bytes (Capacity * Element_Bytes (Tag));
                  end if;
               end;
               Line (To_String (Moon_Name) & " = " &
                     Cast_Expr (Tag, Expr (Tree (Node.Right_Child).Next_Sibling)));
               if Tag in VK_String | VK_Binary then
                  Line (To_String (Moon_Name) & "_history = ALB_new_array(" &
                        Trim_Image (Capacity) & ", " & To_String (Moon_Name) & ")");
               else
                  Line (To_String (Moon_Name) & "_history = " & Typed_Array_Name (Tag) &
                        "(" & Trim_Image (Capacity) & ")");
                  Line ("for __alb_hi = 0, (" & Trim_Image (Capacity) & ") - 1 do " &
                    To_String (Moon_Name) & "_history[__alb_hi] = " &
                    To_String (Moon_Name) & "");
               end if;
               Line (To_String (Moon_Name) & "_head = 0");
            end if;

         when AST_Let_Stmt =>
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node = 0 then
               null;
            elsif Value_Node = 0
              and then Node.Token_Index > 0
              and then Tokens (Node.Token_Index).Kind = Tok_U0
            then
               null;
            elsif Tree (Target_Node).Kind = AST_Var_Expr and then Tree (Target_Node).Left_Child = 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := Infer_Expr_Kind (Value_Node);
                  if Tag = VK_Unknown then
                     Tag := VK_Number;
                  end if;
               end if;

               if Length (Current_Routine) > 0 then
                  Sym_Id := Find_Symbol (To_String (Current_Routine), To_String (Raw_Name));
                  if Sym_Id = 0 then
                     declare
                        Global_Id : constant Natural := Find_Symbol ("", Scoped_Name (To_String (Raw_Name)));
                        Plain_Id  : constant Natural := Find_Symbol ("", Safe_Moon_Name (To_String (Raw_Name)));
                     begin
                        if Global_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Global_Id).Tag, False);
                        elsif Plain_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Plain_Id).Tag, False);
                        else
                           Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_Moon_Name (To_String (Raw_Name)), Tag, Sym_Scalar);
                           Emit_Assignment (Target_Node, Value_Node, Tag, True);
                        end if;
                     end;
                  else
                     Emit_Assignment (Target_Node, Value_Node, Symbols (Sym_Id).Tag, False);
                  end if;
               else
                  Sym_Id := Find_Symbol ("", Scoped_Name (To_String (Raw_Name)));
                  if Sym_Id = 0 then
                     if Tag = VK_Struct then
                        declare
                           Struct_Name : constant String := Safe_Moon_Name (Raw_Lexeme (Node.Token_Index));
                           SIdx : constant Natural := Find_Struct (Struct_Name);
                        begin
                           Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Struct_Var,
                                            Struct_Name => Raw_Lexeme (Node.Token_Index),
                                            Offset_Bytes => (if SIdx /= 0 then Allocate_Address_Bytes (Structs (SIdx).Size_Bytes) else 0));
                        end;
                        declare
                           Struct_Name : constant String := Safe_Moon_Name (Raw_Lexeme (Node.Token_Index));
                           SIdx : constant Natural := Find_Struct (Struct_Name);
                           Curr : Natural := 1;
                           Field_Text : Unbounded_String := U ("");
                        begin
                           if SIdx /= 0 then
                              for I in 1 .. Field_Count loop
                                 if Fields (I).Active and then To_String (Fields (I).Struct_Name) = Struct_Name then
                                    if Curr > 1 then
                                       Append (Field_Text, ", ");
                                    end if;
                                    Append (Field_Text,
                                            To_String (Fields (I).Moon_Field) & " = " &
                                            Default_Value
                                              (Fields (I).Tag,
                                               To_String (Fields (I).Type_Name)));
                                    Curr := Curr + 1;
                                 end if;
                              end loop;
                           end if;
                           Line
                             ( Scoped_Name (To_String (Raw_Name)) &
                              " = {" & To_String (Field_Text) & "}");
                        end;
                     else
                        Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Scalar,
                                         Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (Tag)));
                        Emit_Assignment (Target_Node, Value_Node, Tag, True);
                     end if;
                  else
                     Emit_Assignment (Target_Node, Value_Node, Symbols (Sym_Id).Tag, False);
                  end if;
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

         when AST_Procedure_Decl =>
            Emit_Function_Decl (Index, False);

         when AST_Function_Decl =>
            Emit_Function_Decl (Index, True);

         when AST_Return_Stmt =>
            if Current_Routine_Out_Count > 0 then
               Emit_Current_Out_Writebacks;
            end if;
            if Node.Left_Child > 0 then
               Line ("return " & Expr (Node.Left_Child));
            else
               Line ("return");
            end if;

         when AST_Fallback_Block =>
            if Node.Left_Child > 0 then
               Emit_Block (Node.Left_Child);
            end if;

         when AST_Exact_Block =>
            Exact_Depth := Exact_Depth + 1;
            if Node.Left_Child > 0 then
               Emit_Block (Node.Left_Child);
            end if;
            Exact_Depth := Exact_Depth - 1;

         when AST_Symbolic_Block =>
            Symbolic_Depth := Symbolic_Depth + 1;
            if Node.Left_Child > 0 then
               Emit_Block (Node.Left_Child);
            end if;
            Symbolic_Depth := Symbolic_Depth - 1;

         when AST_Branchless_Predicate_Block =>
            declare
               Body_Node     : constant Node_Index := Node.Right_Child;
               Fallback_Node : constant Node_Index := (if Body_Node > 0 then Tree (Body_Node).Next_Sibling else 0);
            begin
               Line ("if ALB_truthy(" & Expr (Node.Left_Child) & ")");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("else");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
               else
                  null;
               end if;
            end;

         when AST_Stride_Block =>
            declare
               Body_Node : constant Node_Index := Node.Right_Child;
            begin
               if Stride_Depth < Max_Mode_Nesting then
                  Stride_Depth := Stride_Depth + 1;
                  Stride_Step_Stack (Stride_Depth) := U (Expr (Node.Left_Child));
                  Emit_Block (Body_Node);
                  Stride_Step_Stack (Stride_Depth) := U ("");
                  Stride_Depth := Stride_Depth - 1;
               else
                  Emit_Warn_Once ("stride-nesting-limit",
                                  "STRIDE nesting beyond 32 levels falls back to normal FOR stepping on ALBM");
                  Emit_Block (Body_Node);
               end if;
            end;

         when AST_Ratio_Space_Block =>
            Emit_Warn_Once ("ratio-space-albw",
                            "RATIO_SPACE pinning is approximated as ordinary JS evaluation on ALBM");
            if Node.Right_Child > 0 then
               Emit_Block (Node.Right_Child);
            end if;

         when AST_Morton_Tile_Block =>
            declare
               Size_Node      : constant Node_Index := Node.Right_Child;
               Body_Node      : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Next_Sibling else 0);
               Width_Node     : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Left_Child else 0);
               Height_Node    : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Right_Child else 0);
               Width_Text     : Unbounded_String := U ("1");
               Height_Text    : Unbounded_String := U ("1");
               Width_Name     : constant String := Next_Temp_Name ("morton_w");
               Height_Name    : constant String := Next_Temp_Name ("morton_h");
               Limit_Name     : constant String := Next_Temp_Name ("morton_limit");
               Code_Name      : constant String := Next_Temp_Name ("morton_code");
               Seen_Name      : constant String := Next_Temp_Name ("morton_seen");
               X_Name         : constant String := Next_Temp_Name ("morton_x");
               Y_Name         : constant String := Next_Temp_Name ("morton_y");
               Bits_Name      : constant String := Next_Temp_Name ("morton_bits");
               Shift_Name     : constant String := Next_Temp_Name ("morton_shift");
               Size_Text      : constant String := (if Size_Node > 0 and then Tree (Size_Node).Token_Index > 0
                                                   then Raw_Lexeme (Tree (Size_Node).Token_Index)
                                                   else "");
            begin
               if Width_Node > 0 then
                  Width_Text := U (Expr (Width_Node));
               elsif Size_Text'Length > 2 then
                  declare
                     X_Pos : Natural := 0;
                  begin
                     for I in Size_Text'Range loop
                        if Size_Text (I) = 'x' or else Size_Text (I) = 'X' then
                           X_Pos := I;
                           exit;
                        end if;
                     end loop;
                     if X_Pos > Size_Text'First + 1 then
                        Width_Text := U (Size_Text (Size_Text'First + 1 .. X_Pos - 1));
                        if X_Pos < Size_Text'Last then
                           Height_Text := U (Size_Text (X_Pos + 1 .. Size_Text'Last));
                        end if;
                     end if;
                  end;
               end if;

               if Height_Node > 0 then
                  Height_Text := U (Expr (Height_Node));
               elsif Length (Height_Text) = 0 then
                  Height_Text := Width_Text;
               end if;

               Ensure_Special_Scalar ("MTX", VK_U64);
               Ensure_Special_Scalar ("MTY", VK_U64);
               Indent_Level := Indent_Level + 1;
               Line (Width_Name & " = math.max(1, math.floor(ALB_num(" & To_String (Width_Text) & ")))");
               Line (Height_Name & " = math.max(1, math.floor(ALB_num(" & To_String (Height_Text) & ")))");
               Line (Limit_Name & " = math.max(" & Width_Name & ", " & Height_Name & ")");
               Line (Code_Name & " = 0");
               Line (Seen_Name & " = 0");
               Line ("while " & Seen_Name & " < (" & Width_Name & " * " & Height_Name & ") do");
               Indent_Level := Indent_Level + 1;
               Line (X_Name & " = 0");
               Line (Y_Name & " = 0");
               Line (Bits_Name & " = " & Code_Name);
               Line ("for " & Shift_Name & " = 0, 15 do");
               Indent_Level := Indent_Level + 1;
               Line (X_Name & " = ALB_bor(" & X_Name & ", ALB_shl(ALB_band(" & Bits_Name & ", 1), " & Shift_Name & "))");
               Line (Bits_Name & " = ALB_shr(" & Bits_Name & ", 1)");
               Line (Y_Name & " = ALB_bor(" & Y_Name & ", ALB_shl(ALB_band(" & Bits_Name & ", 1), " & Shift_Name & "))");
               Line (Bits_Name & " = ALB_shr(" & Bits_Name & ", 1)");
               Line ("break if ALB_shl(1, " & Shift_Name & " + 1) > " & Limit_Name & " and " & Bits_Name & " == 0");
               Indent_Level := Indent_Level - 1;
               Line ("if " & X_Name & " >= " & Width_Name & " or " & Y_Name & " >= " & Height_Name & "");
               Indent_Level := Indent_Level + 1;
               Line (Code_Name & " = " & Code_Name & " + 1");
               Line ("-- continue");
               Indent_Level := Indent_Level - 1;
               Line ("else");
               Indent_Level := Indent_Level + 1;
               Line ("MTX = " & X_Name);
               Line ("MTY = " & Y_Name);
               Line (Seen_Name & " = " & Seen_Name & " + 1");
               Emit_Block (Body_Node);
               Line (Code_Name & " = " & Code_Name & " + 1");
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
            end;

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
               Line ("if ALB_truthy(" & Expr (Node.Left_Child) & ")");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Then_Block);
               Indent_Level := Indent_Level - 1;
               if Else_Block > 0 then
                  Line ("else");
                  Indent_Level := Indent_Level + 1;
                  Emit_Block (Else_Block);
                  Indent_Level := Indent_Level - 1;
               else
                  null;
               end if;
            end;

         when AST_While_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
            begin
               Line (Guard_Name & " = 0");
               Line ("while ALB_truthy(" & Expr (Node.Left_Child) & ")");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " = " & Guard_Name & " + 1");
               Line ("break if " & Guard_Name & " > 500000 -- ALBM safety bailout");
               Emit_Block (Node.Right_Child);
               Indent_Level := Indent_Level - 1;
            end;

         when AST_For_Stmt =>
            declare
               Loop_Spec  : constant Node_Index := Node.Left_Child;
               Start_Node : constant Node_Index :=
                 (if Loop_Spec > 0 then Tree (Loop_Spec).Left_Child else 0);
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
               Step_Expr  : constant String :=
                 (if Step_Node > 0
                  then Expr (Step_Node)
                  elsif Stride_Depth > 0 and then Length (Stride_Step_Stack (Stride_Depth)) > 0
                  then To_String (Stride_Step_Stack (Stride_Depth))
                  else "1");
               Var_Name   : constant String := Raw_Lexeme (Node.Token_Index);
               Var_Moon    : constant String := Resolve_Var_Name (Var_Name);
               Step_Name  : constant String := Next_Temp_Name ("for_step");
               End_Name   : constant String := Next_Temp_Name ("for_end");
            begin
               Raw_Name := U (Var_Name);
               if Find_Symbol (To_String (Current_Routine), To_String (Raw_Name)) = 0
                 and then Find_Symbol ("", Scoped_Name (To_String (Raw_Name))) = 0
               then
                  if Length (Current_Routine) > 0 then
                     Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_Moon_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line (Safe_Moon_Name (To_String (Raw_Name)) & " = " & Cast_Expr (VK_Number, Start_Expr));
                  else
                     Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line (Scoped_Name (To_String (Raw_Name)) & " = " & Cast_Expr (VK_Number, Start_Expr));
                  end if;
               end if;

               Indent_Level := Indent_Level + 1;
               Line (Step_Name & " = " & Step_Expr);
               Line (End_Name & " = " & End_Expr);
               Line (Var_Moon & " = " & Start_Expr);
               Line ("while (" & Step_Name & " >= 0 and " & Var_Moon & " <= " & End_Name &
                     ") or (" & Step_Name & " < 0 and " & Var_Moon & " >= " & End_Name & ")");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Node.Right_Child);
               Line (Var_Moon & " = " & Var_Moon & " + " & Step_Name);
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
            end;

         when AST_Foreach_Stmt =>
            declare
               Iterator_Raw  : constant String := Raw_Lexeme (Node.Token_Index);
               Iterator_Moon   : constant String := Safe_Moon_Name (Iterator_Raw);
               Iterator_Scope : constant String :=
                 (if Length (Current_Routine) > 0 then To_String (Current_Routine) else "");
               Seq_Name      : constant String := Next_Temp_Name ("foreach_seq");
               Index_Name    : constant String := Next_Temp_Name ("foreach_ix");
               Length_Name   : constant String := Next_Temp_Name ("foreach_len");
               Shadow_Id     : Natural := 0;
               Sequence_Node : constant Node_Index := Node.Left_Child;
               Sequence_AST  : constant AST_Node := Tree (Sequence_Node);
               Sequence_Raw  : constant String :=
                 (if Sequence_AST.Token_Index > 0 then Raw_Lexeme (Sequence_AST.Token_Index) else "");
               Sequence_Sym  : constant Symbol_Record := Resolve_Symbol (Sequence_Raw);
               Item_Tag      : constant Value_Kind :=
                 (if Sequence_Sym.Active then Sequence_Sym.Tag else VK_Number);
               Sequence_Len  : constant String :=
                 (if Sequence_Sym.Active and then Sequence_Sym.Kind = Sym_Slide_Array
                  then To_String (Sequence_Sym.Moon_Name) & "_active"
                  else "1024");
            begin
               Indent_Level := Indent_Level + 1;
               Line (Seq_Name & " = " & Expr (Sequence_Node));
               Line (Length_Name & " = " & Sequence_Len);
               Line ("for " & Index_Name & " = 0, (" & Length_Name &
                     ") - 1");
               Indent_Level := Indent_Level + 1;
               Line (Iterator_Moon & " = " &
                     Cast_Expr (Item_Tag, Seq_Name & "[" & Index_Name & "]"));
               Shadow_Id :=
                 Push_Shadow_Symbol
                   (Scope   => Iterator_Scope,
                    Name    => Iterator_Raw,
                    Moon_Name => Iterator_Moon,
                    Tag     => Item_Tag);
               Emit_Block (Node.Right_Child);
               Pop_Shadow_Symbol (Shadow_Id);
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
            end;

         when AST_Repeat_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
            begin
               Line (Guard_Name & " = 0");
               Line ("while true");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " = " & Guard_Name & " + 1");
               Line ("break if " & Guard_Name & " > 500000 -- ALBM safety bailout");
               Emit_Block (Node.Left_Child);
               Indent_Level := Indent_Level - 1;
               Line ("break if ALB_truthy(" & Expr (Node.Right_Child) & ")");
            end;

         when AST_Break_Stmt =>
            Line ("break");

         when AST_Continue_Stmt =>
            Line ("-- continue (approximated; not supported in Lua 5.1)");

          when AST_Call_Stmt =>
             if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Func_Call then
                declare
                   Call_Node : constant AST_Node := Tree (Node.Left_Child);
                   Target    : constant String :=
                     (if Tree (Call_Node.Left_Child).Kind = AST_Member_Expr
                      then Collect_Module_Member_Name (Call_Node.Left_Child)
                      else Resolve_Var_Name (Raw_Lexeme (Tree (Call_Node.Left_Child).Token_Index)));
                   RName     : constant String :=
                     (if Tree (Call_Node.Left_Child).Kind = AST_Member_Expr
                      then ""
                      else Resolve_Routine_Name (Raw_Lexeme (Tree (Call_Node.Left_Child).Token_Index)));
                begin
                   Emit_Call_With_Out
                     ((if RName'Length > 0 then RName else Target),
                      Call_Node.Right_Child);
                end;
             else
                Line (Expr (Node.Left_Child));
             end if;

         when AST_On_Block =>
            if Node.Token_Index > 0 then
               Remember_Event_Block (Tokens (Node.Token_Index).Kind, Node.Left_Child);
               if Tokens (Node.Token_Index).Kind not in Tok_Tick | Tok_Paint | Tok_Key then
                  Line ("-- unsupported ON event for ALBM backend: " &
                        Token_Kind'Image (Tokens (Node.Token_Index).Kind) & "");
               end if;
            end if;

         when AST_Match_Stmt =>
            Emit_Switch_Stmt (Node.Left_Child, Node.Right_Child);

         when AST_Select_Stmt =>
            Emit_Switch_Stmt (Node.Left_Child, Node.Right_Child);

         when AST_SwapPop_Stmt =>
            Emit_SwapPop (Node.Left_Child, Node.Right_Child);

         when AST_Comptime_Block =>
            Line ("-- COMPTIME lowered to eager module-initialization code");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;

         when AST_Find_Query | AST_Query | AST_Knows_Query =>
            Line (Expr (Index));

         when AST_Create_Window =>
            Saw_Create := True;
            declare
               Title_Node : constant Node_Index := Node.Left_Child;
               Pair_Node  : constant Node_Index := Node.Right_Child;
            begin
               Line ("ALB_CREATE_WINDOW(" &
                     Expr (Title_Node) & ", " &
                     Expr (Tree (Pair_Node).Left_Child) & ", " &
                     Expr (Tree (Pair_Node).Right_Child) & ")");
            end;

         when AST_Set_Fullscreen =>
            Line ("ALB_SET_FULLSCREEN(ALB_truthy(" & Expr (Node.Left_Child) & "))");

         when AST_Set_Resizable =>
            Line ("ALB_SET_RESIZABLE(ALB_truthy(" & Expr (Node.Left_Child) & "))");

         when AST_Set_Stretchy =>
            Line ("ALB_SET_STRETCHY(ALB_truthy(" & Expr (Node.Left_Child) & "))");

         when AST_Tick =>
            Line ("albFrameInterval = math.max(1, " & Expr (Node.Left_Child) & ")");

         when AST_Color =>
            Line ("ALB_COLOR(" & Expr (Node.Left_Child) & ")");

         when AST_Clear =>
            Line ("ALB_CLEAR(" & Expr (Node.Left_Child) & ")");

         when AST_Use_Font_Stmt =>
            Line ("ALB_SET_FONT(" & Expr (Node.Left_Child) & ")");

         when AST_Apply_Lut_Stmt =>
            declare
               Visual_Node : constant Node_Index := Node.Right_Child;
               With_Node   : constant Node_Index :=
                 (if Visual_Node > 0 and then Tree (Visual_Node).Next_Sibling > 0
                  and then Tree (Tree (Visual_Node).Next_Sibling).Kind = AST_With_Clause
                  then Tree (Visual_Node).Next_Sibling
                  else 0);
            begin
               Line ("ALB_STATIC_APPLY_LUT(" &
                     Expr (Node.Left_Child) & ", " &
                     Expr (Visual_Node) & ", " &
                     (if With_Node > 0 then Expr (Tree (With_Node).Left_Child) else "0") & ", " &
                     (if With_Node > 0 then "true" else "false") & ")");
            end;

         when AST_Blit_Safe_Stmt =>
            declare
               Visual_Node : constant Node_Index := Node.Left_Child;
               Visual_With : constant Node_Index :=
                 (if Visual_Node > 0 and then Tree (Visual_Node).Next_Sibling > 0
                  and then Tree (Tree (Visual_Node).Next_Sibling).Kind = AST_With_Clause
                  then Tree (Visual_Node).Next_Sibling
                  else 0);
               Target_Node   : constant Node_Index := Node.Right_Child;
               Position_Node : constant Node_Index := (if Target_Node > 0 then Tree (Target_Node).Next_Sibling else 0);
               Clause_Node   : Node_Index := (if Position_Node > 0 then Tree (Position_Node).Next_Sibling else 0);
               View_Expr     : Unbounded_String := U ("0");
               Alpha_Mask    : Boolean := False;
            begin
               while Clause_Node > 0 loop
                  if Tree (Clause_Node).Kind = AST_Constrain_To_Clause then
                     View_Expr := U (Expr (Tree (Clause_Node).Left_Child));
                  elsif Tree (Clause_Node).Kind = AST_Mode_Clause then
                     Alpha_Mask := Upper_Text (Raw_Feature_Atom (Tree (Clause_Node).Left_Child)) = "ALPHAMASK";
                  end if;
                  Clause_Node := Tree (Clause_Node).Next_Sibling;
               end loop;

               Line ("ALB_STATIC_BLIT(" &
                     Expr (Visual_Node) & ", " &
                     (if Visual_With > 0 then Expr (Tree (Visual_With).Left_Child) else "0") & ", " &
                     (if Visual_With > 0 then "true" else "false") & ", " &
                     Expr (Target_Node) & ", " &
                     Expr (Tree (Position_Node).Left_Child) & ", " &
                     Expr (Tree (Position_Node).Right_Child) & ", " &
                     To_String (View_Expr) & ", " &
                     (if Alpha_Mask then "true" else "false") & ")");
            end;

         when AST_Predict_Markov_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, False);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Emit_Firewall_Touch (Tree (Node.Right_Child).Next_Sibling, False, True);
            Line (Statement_Target_Name (Tree (Node.Right_Child).Next_Sibling) &
                  " = ALB_MARKOV_PREDICT(" &
                  Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");

         when AST_Infer_Network_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, False);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Emit_Firewall_Touch (Tree (Node.Right_Child).Next_Sibling, False, True);
            Line ("ALB_NN_INFER(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ", " &
                  Statement_Target_Name (Tree (Node.Right_Child).Next_Sibling) & ")");

         when AST_Train_Network_Stmt =>
            declare
               Train_Node  : constant Node_Index := Node.Right_Child;
               Expect_Node : constant Node_Index := (if Train_Node > 0 then Tree (Train_Node).Next_Sibling else 0);
               Epoch_Node  : constant Node_Index := (if Expect_Node > 0 then Tree (Expect_Node).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Node.Left_Child, True, True);
               Emit_Firewall_Touch (Train_Node, True, False);
               Emit_Firewall_Touch (Expect_Node, True, False);
               Line ("ALB_NN_TRAIN(" & Expr (Node.Left_Child) & ", " &
                     Expr (Train_Node) & ", " & Expr (Expect_Node) & ", " &
                     (if Epoch_Node > 0 then Expr (Epoch_Node) else "1") & ")");
            end;

         when AST_Export_PPM_Block =>
            declare
               Path_Node     : constant Node_Index := Node.Right_Child;
               Format_Node   : constant Node_Index := (if Path_Node > 0 then Tree (Path_Node).Next_Sibling else 0);
               Body_Node     : constant Node_Index := (if Format_Node > 0 then Tree (Format_Node).Next_Sibling else 0);
               Fallback_Node : constant Node_Index := (if Body_Node > 0 then Tree (Body_Node).Next_Sibling else 0);
               Status_Name   : constant String := Next_Temp_Name ("export_ppm");
            begin
               Indent_Level := Indent_Level + 1;
               Line (Status_Name & " = ALB_EXPORT_PPM(" &
                     Expr (Node.Left_Child) & ", " &
                     As_Text_Expr (Path_Node) & ", " &
                     Feature_Text_Expr (Format_Node) & ")");
               Line ("if " & Status_Name & " ~= 0");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("else");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
               else
                  null;
               end if;
               Indent_Level := Indent_Level - 1;
            end;

         when AST_Fits_Cube_Block =>
            Emit_Warn_Once ("fits-cube-albw",
                            "FITS_CUBE is not implemented on ALBM yet; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Ini_Bind_Block =>
            declare
               Path_Node      : constant Node_Index := Node.Right_Child;
               Body_Node      : constant Node_Index := (if Path_Node > 0 then Tree (Path_Node).Next_Sibling else 0);
               Fallback_Node  : constant Node_Index := (if Body_Node > 0 then Tree (Body_Node).Next_Sibling else 0);
               Table_Name     : constant String := "__alb_ini_table_" & Next_Temp_Name ("bind");
               Embed_Name     : constant String := "__alb_ini_text_" & Next_Temp_Name ("bind");
               Static_Path    : Unbounded_String := U ("");
               Entry_Node     : Node_Index := 0;
            begin
               if Path_Node > 0 and then Tree (Path_Node).Kind = AST_String_Expr then
                  Static_Path := U (Resolve_Static_Asset_Path (Strip_String_Node (Path_Node)));
               end if;

               if Length (Static_Path) > 0 then
                  Emit_Embedded_Text_File (Embed_Name, To_String (Static_Path));
               else
                  Line (Embed_Name & " = nil");
               end if;

               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Line (Table_Name & " = {");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Entry_Node := Tree (Body_Node).Left_Child;
               end if;
               while Entry_Node > 0 loop
                  if Tree (Entry_Node).Kind = AST_Let_Stmt
                    and then Tree (Entry_Node).Left_Child > 0
                    and then Tree (Tree (Entry_Node).Left_Child).Kind = AST_Var_Expr
                  then
                     declare
                        Target_Var : constant Node_Index := Tree (Entry_Node).Left_Child;
                        Raw_Key    : constant String := Raw_Lexeme (Tree (Target_Var).Token_Index);
                        Lower_Key  : constant String := Ada.Characters.Handling.To_Lower (Raw_Key);
                     begin
                        Line ("{ key: " & Escape_Moon_String (Lower_Key) &
                              ", apply = (value) -> " &
                              Statement_Target_Name (Target_Var) &
                              " = value },");
                     end;
                  end if;
                  Entry_Node := Tree (Entry_Node).Next_Sibling;
               end loop;
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Line ("if ALB_INI_BIND(" & As_Text_Expr (Path_Node) & ", " & Embed_Name & ", " & Table_Name & ") == 0");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Emit_Fallback_Body (Fallback_Node);
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
            end;

         when AST_Stream_Bypass_Block =>
            Emit_Warn_Once ("stream-bypass-albw",
                            "STREAM_BYPASS is ignored on ALBM; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
              and then Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body
                 (Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling);
            end if;

         when AST_Synth_Bake_Block =>
            Emit_Warn_Once ("synth-bake-albw",
                            "SYNTH_BAKE is not implemented on ALBM yet; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Mount_Archive_Block =>
            Emit_Warn_Once ("mount-archive-albw",
                            "MOUNT_ARCHIVE is not available on ALBM; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Network_Sniff_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("ALB_SNIFFER_CAPTURE(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ")");

         when AST_Parse_Ethernet_Stmt =>
            declare
               Src_Node : constant Node_Index := Node.Left_Child;
               D1       : constant Node_Index := Node.Right_Child;
               D2       : constant Node_Index := (if D1 > 0 then Tree (D1).Next_Sibling else 0);
               D3       : constant Node_Index := (if D2 > 0 then Tree (D2).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Src_Node, True, False);
               if D1 > 0 then
                  Emit_Firewall_Touch (D1, False, True);
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 0, 6)");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 6, 6)");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 12, 2)");
               end if;
            end;

         when AST_Parse_IP_Stmt =>
            declare
               Src_Node : constant Node_Index := Node.Left_Child;
               D1       : constant Node_Index := Node.Right_Child;
               D2       : constant Node_Index := (if D1 > 0 then Tree (D1).Next_Sibling else 0);
               D3       : constant Node_Index := (if D2 > 0 then Tree (D2).Next_Sibling else 0);
               D4       : constant Node_Index := (if D3 > 0 then Tree (D3).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Src_Node, True, False);
               if D1 > 0 then
                  Emit_Firewall_Touch (D1, False, True);
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 26, 4)");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 30, 4)");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 23, 1)");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 16, 2)");
               end if;
            end;

         when AST_Parse_TCP_Stmt =>
            declare
               Src_Node : constant Node_Index := Node.Left_Child;
               D1       : constant Node_Index := Node.Right_Child;
               D2       : constant Node_Index := (if D1 > 0 then Tree (D1).Next_Sibling else 0);
               D3       : constant Node_Index := (if D2 > 0 then Tree (D2).Next_Sibling else 0);
               D4       : constant Node_Index := (if D3 > 0 then Tree (D3).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Src_Node, True, False);
               if D1 > 0 then
                  Emit_Firewall_Touch (D1, False, True);
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 34, 2)");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 36, 2)");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 38, 4)");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 42, 4)");
               end if;
            end;

         when AST_Network_Listen_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("ALB_NET_LISTEN(" & Expr (Node.Left_Child) & ")");

         when AST_Network_Accept_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line (Statement_Target_Name (Node.Right_Child) &
                  " = ALB_NET_ACCEPT(" & Expr (Node.Left_Child) & ")");

         when AST_Network_Receive_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("ALB_NET_RECEIVE(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ")");

         when AST_Network_Send_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Line ("ALB_NET_SEND(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ")");

         when AST_Network_Close_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("ALB_NET_CLOSE(" & Expr (Node.Left_Child) & ")");

         when AST_Read_Process_Memory_Stmt =>
            declare
               Addr_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Raw  : constant String := Raw_Feature_Atom (Target_Node);
               Target_Sym  : constant Symbol_Record := Resolve_Symbol (Target_Raw);
            begin
               if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field then
                  Line ("ALB_PROCESS_READ_BUFFER(" & Expr (Node.Left_Child) & ", " &
                        Expr (Addr_Node) & ", " & Statement_Target_Name (Target_Node) & ")");
               else
                  Line (Statement_Target_Name (Target_Node) & " = ALB_PROCESS_READ_SCALAR(" &
                        Expr (Node.Left_Child) & ", " & Expr (Addr_Node) & ")");
               end if;
            end;

         when AST_Write_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_WRITE_SCALAR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ")");
            end;

         when AST_Monitor_Process_Memory_Stmt =>
            declare
               Addr_Node    : constant Node_Index := Node.Right_Child;
               Type_Node    : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Node  : constant Node_Index := (if Type_Node > 0 then Tree (Type_Node).Next_Sibling else 0);
               Change_Node  : constant Node_Index := (if Target_Node > 0 then Tree (Target_Node).Next_Sibling else 0);
            begin
               Indent_Level := Indent_Level + 1;
               Line ("__alb_monitor_value = { value: ALB_num(" & Expr (Target_Node) & ") }");
               Line ("__alb_monitor_change = { value: ALB_num(" & Expr (Change_Node) & ") }");
               Line ("ALB_PROCESS_MONITOR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", __alb_monitor_value, __alb_monitor_change)");
               Line (Statement_Target_Name (Target_Node) & " = __alb_monitor_value.value");
               Line (Statement_Target_Name (Change_Node) & " = __alb_monitor_change.value");
               Indent_Level := Indent_Level - 1;
            end;

         when AST_Dump_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Size_Node  : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Path_Node  : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_DUMP(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Size_Node) & ", " &
                     Expr (Path_Node) & ")");
            end;

         when AST_Terminate_Process_Stmt =>
            Line ("__h = math.floor(ALB_num(" & Expr (Node.Left_Child) &
                  ")); albProcessTable[__h].alive = false if albProcessTable[__h]");

         when AST_Create_Process_Stmt =>
            declare
               Args_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Args_Node > 0 then Tree (Args_Node).Next_Sibling else 0);
            begin
               Line (Statement_Target_Name (Target_Node) &
                     " = ALB_PROCESS_CREATE(" & Expr (Node.Left_Child) & ", " &
                     (if Args_Node > 0 then Expr (Args_Node) else """""") & ")");
            end;

         when AST_Elevate_Privileges_Stmt =>
            Line ("ALB_PROCESS_ELEVATE(" & Expr (Node.Left_Child) & ")");

         when AST_Hack_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_WRITE_SCALAR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ")");
            end;

         when AST_Inject_Code_Memory_Stmt | AST_Inject_Code_Stmt =>
            declare
               Payload_Node : constant Node_Index := Node.Right_Child;
               Target_Node  : constant Node_Index := (if Payload_Node > 0 then Tree (Payload_Node).Next_Sibling else 0);
            begin
               if Target_Node > 0 then
                  Line (Statement_Target_Name (Target_Node) & " = 0");
               end if;
            end;

         when AST_Hijack_Process_Memory_Stmt =>
            declare
               Addr_Node    : constant Node_Index := Node.Right_Child;
               Detour_Node  : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Node  : constant Node_Index := (if Detour_Node > 0 then Tree (Detour_Node).Next_Sibling else 0);
            begin
               if Target_Node > 0 then
                  Line (Statement_Target_Name (Target_Node) & " = 0");
               end if;
            end;

         when AST_Sniff_Network_Stmt =>
            Line ("ALB_PROCESS_SNIFF(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ")");

         when AST_Encrypt_File_Stmt | AST_Decrypt_File_Stmt =>
            declare
               Key_Node  : constant Node_Index := Node.Right_Child;
               Path_Node : constant Node_Index := (if Key_Node > 0 then Tree (Key_Node).Next_Sibling else 0);
            begin
               Line ("ALB_FILE_XOR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Key_Node) & ", " & Expr (Path_Node) & ")");
            end;

         when AST_Print_Stmt =>
            if Node.Left_Child > 0 then
               Line ("ALB_PRINT(" & As_Text_Expr (Node.Left_Child) & ")");
            else
               Line ("ALB_PRINT("""")");
            end if;

         when AST_Locate_Stmt =>
            Line ("ALB_LOCATE(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ")");

         when AST_Print_Str_Stmt =>
            if Node.Left_Child > 0 then
               Line ("ALB_PRINT_RAW(" & As_Text_Expr (Node.Left_Child) & ")");
            else
               Line ("ALB_PRINT_RAW("""")");
            end if;

         when AST_Draw | AST_Fill | AST_Plot | AST_Text =>
            declare
               Args      : array (1 .. 8) of Unbounded_String := (others => U ("0"));
               Count     : Natural := 0;
               Curr      : Node_Index := 0;
               Call_Name : Unbounded_String := U ("");
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
                     Line ("ALB_DRAW_TEXT(" & To_String (Args (1)) & ", " &
                           To_String (Args (2)) & ", " & To_String (Args (3)) & ")");
                  end if;
               elsif Node.Kind = AST_Plot then
                  if Count >= 2 then
                     Line ("ALB_PLOT(" & To_String (Args (1)) & ", " & To_String (Args (2)) & ")");
                  end if;
               else
                  case Tokens (Node.Token_Index).Kind is
                     when Tok_Rect =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_DRAW_RECT");
                        else
                           Call_Name := U ("ALB_FILL_RECT");
                        end if;
                     when Tok_Line =>
                        Call_Name := U ("ALB_DRAW_LINE");
                     when Tok_Circle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_DRAW_CIRCLE");
                        else
                           Call_Name := U ("ALB_FILL_CIRCLE");
                        end if;
                     when Tok_Triangle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_DRAW_TRIANGLE");
                        else
                           Call_Name := U ("ALB_FILL_TRIANGLE");
                        end if;
                     when others =>
                        Call_Name := U ("-- unsupported draw primitive");
                  end case;

                  if Length (Call_Name) > 0 and then To_String (Call_Name) (To_String (Call_Name)'First) /= '/' then
                     declare
                        Arg_Text : Unbounded_String := U ("");
                        Call_Text : constant String := To_String (Call_Name);
                     begin
                        for I in 1 .. Count loop
                           if I > 1 then
                              Append (Arg_Text, ", ");
                           end if;
                           Append (Arg_Text, To_String (Args (I)));
                        end loop;
                        Line (Call_Text & "(" & To_String (Arg_Text) & ")");
                     end;
                  else
                     Line (To_String (Call_Name));
                  end if;
               end if;
            end;

         when AST_Msg_Box =>
            Line ("ALB_MSG_BOX(" & Expr (Node.Left_Child) &
                  (if Node.Right_Child > 0 then ", " & Expr (Node.Right_Child) else "") &
                  ")");

         when AST_Listen =>
            Saw_Listen := True;

         when AST_Cease =>
            Line ("ALB_CEASE()");

         when AST_Play_Sound =>
            Line ("ALB_PLAY_SOUND(" & Expr (Node.Left_Child) & ")");

         when AST_Play_Music =>
            Line ("ALB_PLAY_MUSIC(" & Expr (Node.Left_Child) & ")");

         when AST_Play_Music_From =>
            Line ("ALB_PLAY_MUSIC_FROM(" & Expr (Node.Left_Child) & ")");

         when AST_Input_Stmt =>
            Line (Statement_Target_Name (Node.Right_Child) & " = ALB_PROMPT_TEXT(" &
                  (if Node.Left_Child > 0 then Expr (Node.Left_Child) else """""") &
                  ")");

         when AST_Readline_Stmt =>
            if Node.Left_Child > 0 then
               Line (Statement_Target_Name (Node.Left_Child) &
                     " = ALB_READLINE_TEXT()");
            else
               Line ("ALB_READLINE_TEXT()");
            end if;

         when AST_File_Open =>
            Line ("-- file open expression should be used in LET/assignment context");

         when AST_File_Close =>
            Line ("ALB_Close(" & Expr (Node.Left_Child) & ")");

         when AST_File_Write =>
            Line ("ALB_Write(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");

         when AST_Load_Stmt =>
            declare
               Target_Sym : constant Symbol_Record := Target_Symbol (Node.Right_Child);
            begin
               if Target_Sym.Active
                 and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
               then
                  Line ("ALB_LoadBuffer(" & Expr (Node.Left_Child) & ", " &
                        Statement_Target_Name (Node.Right_Child) & ")");
               else
                  Line (Statement_Target_Name (Node.Right_Child) & " = ALB_LoadTextBuffer(" &
                        Expr (Node.Left_Child) & ")");
               end if;
            end;

         when AST_Flush_Stmt =>
            if Tree (Node.Left_Child).Next_Sibling > 0 then
               Line ("ALB_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ", " &
                     Expr (Tree (Node.Left_Child).Next_Sibling) & ")");
            else
               Line ("ALB_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ")");
            end if;

         when AST_Poke_Stmt =>
            Line ("ALB_POKE(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");

         when AST_Save_State =>
            Line ("ALB_SAVE_STATE()");

         when AST_Load_State =>
            Line ("ALB_LOAD_STATE()");

         when AST_Claim_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ALB_CLAIM()");

         when AST_Bind_Stmt =>
            declare
               Args : Unbounded_String := U ("");
               Curr : Node_Index := 0;
               First : Boolean := True;
            begin
               Append (Args, Expr (Node.Left_Child));
               Curr := Node.Right_Child;
               if Curr > 0 and then Tree (Curr).Kind = AST_Arg_List then
                  Curr := Tree (Curr).Left_Child;
                  while Curr > 0 loop
                     if First then
                        Append (Args, ", ");
                        First := False;
                     else
                        Append (Args, ", ");
                     end if;
                     Append (Args, Expr (Curr));
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end if;
               Line ("ALB_BIND(" & To_String (Args) & ")");
            end;

         when AST_Drop_Stmt =>
            Line ("ALB_DROP(" & Expr (Node.Left_Child) & ")");

         when AST_Sweep_Stmt =>
            Line ("ALB_SWEEP(" & Expr (Node.Left_Child) & ")");

         when AST_Knows_Fact =>
            Line ("ALB_KNOWS_SET(" &
                  Escape_Moon_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                  ", " & Expr (Node.Right_Child) & ")");

         when AST_Assert_Stmt =>
            Line
              ("ALB_REL_SET(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0, 1)");

         when AST_Retract_Stmt =>
            Line
              ("ALB_REL_RETRACT(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0)");

         when AST_Update_Stmt =>
            Line ("ALB_REL_SET(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Predicate_Arity_Expr (Node.Left_Child) & ", " &
                  Predicate_Arg1_Expr (Node.Left_Child) &
                  ", 0, 0, 0, " & Expr (Node.Right_Child) & ")");

         when AST_Findall_Query =>
            Line ("ALB_REL_FINDALL1(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ")");

         when AST_Knows_Change =>
            Remember_Watch_Node (Index);

         when AST_Rule_Decl | AST_Constraint_Decl =>
            Remember_Rule_Node (Index);

         when AST_Temporal_Block =>
            Emit_Block (Node.Left_Child);

         when AST_Advance_Stmt =>
            declare
               Count_Expr : constant String :=
                 (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "1");
            begin
               for I in 1 .. Symbol_Count loop
                  if Symbols (I).Active and then Symbols (I).Kind = Sym_Temporal then
                     Line ("for __adv = 0, ((" & Count_Expr & ")) - 1");
                     Indent_Level := Indent_Level + 1;
                     Line (To_String (Symbols (I).Moon_Name) & "_head = (" &
                           To_String (Symbols (I).Moon_Name) & "_head + 1) % " &
                           Trim_Image (Symbols (I).History_Size));
                     Line (To_String (Symbols (I).Moon_Name) & "_history[" &
                           To_String (Symbols (I).Moon_Name) & "_head] = " &
                           To_String (Symbols (I).Moon_Name));
                     Indent_Level := Indent_Level - 1;
                  end if;
               end loop;
            end;

         when AST_Set_Alpha =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Arg_List then
               declare
                  Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
                  A1   : constant String := (if Curr > 0 then Expr (Curr) else "0");
                  A2   : Unbounded_String := U ("255");
               begin
                  if Curr > 0 then
                     Curr := Tree (Curr).Next_Sibling;
                  end if;
                  if Curr > 0 then
                     A2 := U (Expr (Curr));
                  end if;
                  Line ("ALB_SET_ALPHA(" & A1 & ", " & To_String (A2) & ")");
               end;
            end if;

         when AST_Set_Clip =>
            declare
               Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
               A1, A2, A3, A4 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A3 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A4 := U (Expr (Curr)); end if;
               Line ("ALB_SET_CLIP(" & To_String (A1) & ", " & To_String (A2) & ", " & To_String (A3) & ", " & To_String (A4) & ")");
            end;

         when AST_Set_Origin =>
            declare
               Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
               A1, A2 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); end if;
               Line ("ALB_SET_ORIGIN(" & To_String (A1) & ", " & To_String (A2) & ")");
            end;

         when AST_Delay_Stmt =>
            Line ("ALB_Delay(" & Expr (Node.Left_Child) & ")");

         when AST_Try_Stmt =>
            Indent_Level := Indent_Level + 1;
            Line ("__alb_ok, __alb_err = pcall ->");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            if Node.Right_Child > 0 then
               Line ("if not __alb_ok");
               Indent_Level := Indent_Level + 1;
               declare
                  Catch_Node : constant AST_Node := Tree (Node.Right_Child);
                  Err_Name   : constant String :=
                    (if Catch_Node.Token_Index > 0
                     then Safe_Moon_Name (Raw_Lexeme (Catch_Node.Token_Index))
                     else "__alb_err");
               begin
                  if Err_Name /= "__alb_err" then
                     Line (Err_Name & " = __alb_err");
                  end if;
                  Emit_Block (Node.Right_Child);
               end;
               Indent_Level := Indent_Level - 1;
            else
               Line ("ALB_FATAL(__alb_err) if not __alb_ok");
            end if;
            Indent_Level := Indent_Level - 1;

         when AST_Throw_Stmt =>
            Line ("error(tostring(" & Expr (Node.Left_Child) & "), 0)");

         when AST_Runtime_Assert =>
            Line ("ALB_FATAL(" & Escape_Moon_String ("runtime assert failed") & ") if not ALB_truthy(" & Expr (Node.Left_Child) & ")");

         when AST_Reversible_Block | AST_Atomic_Block =>
            Emit_Block (Node.Left_Child);

         when AST_Rev_Add_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = " &
                  Statement_Target_Name (Node.Left_Child) & " + " & Expr (Node.Right_Child));
         when AST_Rev_Sub_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = " &
                  Statement_Target_Name (Node.Left_Child) & " - " & Expr (Node.Right_Child));
         when AST_Rev_Xor_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ALB_bxor(" &
                  Statement_Target_Name (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");
         when AST_Rev_Rol_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ALB_bor(ALB_shl(" &
                  Statement_Target_Name (Node.Left_Child) & ", " & Expr (Node.Right_Child) &
                  "), ALB_shr(" & Statement_Target_Name (Node.Left_Child) &
                  ", 32 - (" & Expr (Node.Right_Child) & ")))");
         when AST_Rev_Ror_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ALB_bor(ALB_shr(" &
                  Statement_Target_Name (Node.Left_Child) & ", " & Expr (Node.Right_Child) &
                  "), ALB_shl(" & Statement_Target_Name (Node.Left_Child) &
                  ", 32 - (" & Expr (Node.Right_Child) & ")))");
         when AST_Rev_Swap_Stmt =>
            Line ("__tmp = " & Statement_Target_Name (Node.Left_Child) & "; " &
                  Statement_Target_Name (Node.Left_Child) & " = " & Statement_Target_Name (Node.Right_Child) &
                  "; " & Statement_Target_Name (Node.Right_Child) & " = __tmp");
         when AST_Rev_Not_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ALB_bnot(" &
                  Statement_Target_Name (Node.Left_Child) & ")");
         when AST_Rev_Neg_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = -" & Statement_Target_Name (Node.Left_Child));

         when AST_Spawn_Stmt =>
            if Node.Left_Child > 0 then
               Line (Expr (Node.Left_Child));
            end if;
         when AST_Sync_Stmt =>
            null;

         when AST_BinOp =>
            Line (Expr (Index));

         when AST_Enable_Typescript_Block =>
            Line (Raw_Lexeme (Node.Token_Index));

         when AST_Enable_Ada_Block | AST_Enable_Java_Block | AST_Enable_Asm | AST_Disable_Asm | AST_Asm_Block | AST_Predicate_Decl | AST_Case_Stmt | AST_Horn_Clause | AST_Fact | AST_Predicate | AST_Logic_Var | AST_Inline_Asm_Expr | AST_Inline_Ada_Expr | AST_Inline_Java_Expr | AST_Read_Pixel | AST_Array_Assign | AST_Array_Access | AST_Simd_Intrinsic | AST_Cut_Stmt | AST_Str_Concat | AST_Param_Decl | AST_Require_Clause | AST_Ensure_Clause | AST_String_Decl | AST_Bitfield_Decl | AST_SYS_RENDERER | AST_Atom | AST_FILE_READ =>
            Line ("-- unsupported or backend-specific node: " & Node_Kind'Image (Node.Kind));

         when others =>
            Line ("-- TODO node: " & Node_Kind'Image (Node.Kind));
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
      begin
         while Curr > 0 loop
            Emit_Node (Curr);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Top_Level;

      procedure Emit_Top_Level_Range
        (First       : Node_Index;
         Stop_Before : Node_Index)
      is
         Curr : Node_Index := First;
      begin
         while Curr > 0 loop
            exit when Stop_Before /= 0 and then Curr = Stop_Before;
            Emit_Node (Curr);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Top_Level_Range;

      function Statement_List_First (Idx : Node_Index) return Node_Index is
      begin
         if Idx > 0
           and then (Tree (Idx).Kind = AST_Program
                     or else Tree (Idx).Kind = AST_Block_Stmt)
         then
            return Tree (Idx).Left_Child;
         end if;
         return Idx;
      end Statement_List_First;

      function Find_Listen_Stmt (First : Node_Index) return Node_Index is
         Curr : Node_Index := First;
      begin
         while Curr > 0 loop
            if Tree (Curr).Kind = AST_Listen then
               return Curr;
            end if;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
         return 0;
      end Find_Listen_Stmt;

      Root_Index : constant Node_Index := Find_Node_Index (Root);
      Stmt_First : Node_Index := 0;
      Listen_Idx : Node_Index := 0;
   begin
      Reset_State;
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Output_Filename);
      File_Open := True;

      if Root_Index > 0 then
         Current_Module := U ("");
         Scan_Features (Root_Index);
         Current_Module := U ("");
      end if;

      Emit_Module_Imports;
      Emit_Runtime;
      if Root_Index > 0 then
         Stmt_First := Statement_List_First (Root_Index);
         Listen_Idx := Find_Listen_Stmt (Stmt_First);
         Emit_Top_Level_Range (Stmt_First, Listen_Idx);
      elsif Root.Kind /= AST_Null then
         Line ("-- ALBM warning: could not recover top-level root index for " &
               Node_Kind'Image (Root.Kind) & "");
      end if;

      Emit_Address_Routines;
      Emit_State_Routines;
      Emit_Logic_Setup;
      Emit_Event_Handler ("ALB_ON_TICK", Tick_Blocks, Tick_Block_Count);
      Emit_Event_Handler ("ALB_ON_PAINT", Paint_Blocks, Paint_Block_Count);
      Emit_Event_Handler ("ALB_ON_KEY", Key_Blocks, Key_Block_Count);
      Emit_Module_Exports;
      Emit_Foreign_Loaders;

      New_Line_Emit;
      Line ("export ALB_ProgramShutdown = () ->");
      Indent_Level := Indent_Level + 1;
      Line ("return if albShutdownDone");
      Line ("albShutdownDone = true");
      if Listen_Idx > 0 then
         Emit_Top_Level_Range (Tree (Listen_Idx).Next_Sibling, 0);
      end if;
      Indent_Level := Indent_Level - 1;

      if Saw_Create or else Saw_Listen or else Tick_Block_Count > 0 or else Paint_Block_Count > 0 or else Key_Block_Count > 0 then
         New_Line_Emit;
         if Need_Wasm_Loaders then
            Line ("-- WASM loaders approximated via package.preload stubs on ALBM");
            Line ("for _, loader in ipairs(albWasmLoaders)");
            Indent_Level := Indent_Level + 1;
            Line ("ok, err = pcall(loader)");
            Line ("ALB_FATAL(err) if not ok");
            Indent_Level := Indent_Level - 1;
         end if;
         Line ("ALB_PREPARE_FRAME()");
         Line ("ALB_MainLoop()");
      elsif Need_Wasm_Loaders then
         New_Line_Emit;
         Line ("for _, loader in ipairs(albWasmLoaders)");
         Indent_Level := Indent_Level + 1;
         Line ("ok, err = pcall(loader)");
         Line ("ALB_FATAL(err) if not ok");
         Indent_Level := Indent_Level - 1;
      end if;

      Ada.Text_IO.Close (Out_File);
      File_Open := False;
   exception
      when others =>
         if File_Open then
            begin
               Ada.Text_IO.Close (Out_File);
            exception
               when others =>
                  null;
            end;
         end if;
         raise;
   end Compile_To_File;

   procedure Set_No_Console_Overlay (Enabled : in Boolean) is
   begin
      No_Console_Overlay := Enabled;
   end Set_No_Console_Overlay;

end Emit_Native_MoonScript;
