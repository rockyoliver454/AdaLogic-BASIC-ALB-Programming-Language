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

with ALB_System_Includes;
with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with AST;            use AST;

--  ALBR native Rust (rustc) emitter. Mirrors TypeScript AST coverage +
--  FASM feature surface. Mutability via RefCell/mut; ALB | => format! concat.
--  Target: rustc / std (MIT OR Apache-2.0). Not wired yet.
package body Emit_Native_Rust is

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
      VK_F32,
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
      Rust_Name   : Unbounded_String := To_Unbounded_String ("");
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
      Rust_Name      : Unbounded_String := To_Unbounded_String ("");
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
      JS_Field     : Unbounded_String := To_Unbounded_String ("");
      Type_Name    : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
      Offset_Bytes : Integer := 0;
      Bit_Width    : Integer := 0;
      Bit_Shift    : Integer := 0;
   end record;

   type Routine_Record is record
      Active      : Boolean := False;
      Name        : Unbounded_String := To_Unbounded_String ("");
      Rust_Name     : Unbounded_String := To_Unbounded_String ("");
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
   function Escape_Rust_String (Text : String) return String;
   function Resolve_Symbol (Raw : String) return Symbol_Record;
   function Target_Symbol (Target_Node : Node_Index) return Symbol_Record;
   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String;

   function Safe_Rust_Name (Name : String) return String is
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
        Upper = "BREAK" or else
        Upper = "CASE" or else
        Upper = "CATCH" or else
        Upper = "CLASS" or else
        Upper = "CONST" or else
        Upper = "CONTINUE" or else
        Upper = "DEFAULT" or else
        Upper = "DELETE" or else
        Upper = "DO" or else
        Upper = "ELSE" or else
        Upper = "EXPORT" or else
        Upper = "FUNCTION" or else
        Upper = "IF" or else
        Upper = "IMPORT" or else
        Upper = "LET" or else
        Upper = "RETURN" or else
        Upper = "SWITCH" or else
        Upper = "WHILE" or else
        Upper = "WORKER";

      if Needs_Prefix then
         return "alb_" & To_String (Result);
      end if;

      return To_String (Result);
   end Safe_Rust_Name;

   function Scoped_Name (Name : String) return String is
   begin
      if Length (Current_Module) = 0 then
         return Safe_Rust_Name (Name);
      else
         return Safe_Rust_Name (To_String (Current_Module) & "_" & Name);
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
      return "__alb_" & Safe_Rust_Name (Prefix) & "_" & Trim_Image (Integer (Temp_Name_Counter));
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
         when VK_F32 =>
            return 4;
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
      elsif T = "F32" or else T = "SINGLE" or else T = "FLOAT" then
         return VK_F32;
      elsif T = "F64" or else T = "REAL" or else T = "DOUBLE" or else T = "NUMBER" then
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
      elsif T = "HW64" then
         -- Soft: host has no HW64 register; keep as i64 lane.
         return VK_Number;
      elsif T = "CHAR" then
         -- Soft: single-byte character as U8.
         return VK_U8;
      elsif T = "U128" then
         return VK_U128;
      elsif T = "S128" then
         -- Soft: signed 128 via i128 host type.
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

   function Primitive_Rust_Type (Kind : Value_Kind) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "bool";
         when VK_String | VK_Binary =>
            return "String";
         when VK_F32 =>
            return "f32";
         when VK_F64 =>
            --  Explicit REAL/F64 stays floating; all other numeric kinds unify to i64.
            return "f64";
         when VK_U128 =>
            return "i128";
         when VK_U8 | VK_U16 | VK_U32 | VK_U64
            | VK_S8 | VK_S16 | VK_S32
            | VK_HW8 | VK_HW16 | VK_HW32
            | VK_Number | VK_Pure | VK_Unknown =>
            return "i64";
         when others =>
            return "i64";
      end case;
   end Primitive_Rust_Type;

   function Default_Value
     (Kind        : Value_Kind;
      Struct_Name : String := "") return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "false";
         when VK_String | VK_Binary =>
            return """""";
         when VK_F32 | VK_F64 =>
            return "0.0";
         when VK_U128 =>
            return "0i128";
         when VK_Struct =>
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
               elsif Struct_Name'Length > 0 then
                  return Safe_Rust_Name (Struct_Name) & "::default()";
               else
                  return "{}";
               end if;
            end;
         when others =>
            return "0";
      end case;
   end Default_Value;

   function Type_Annotation_From_Name (Name : String) return String is
      Upper : constant String := Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
      Kind  : constant Value_Kind := Type_From_Name (Name);
   begin
      if Upper = "FLOAT2" or else Upper = "F32X2" or else
        Upper = "FLOAT4" or else Upper = "F32X4" or else
        Upper = "MAT2" or else Upper = "MAT2X2" or else
        Upper = "MAT3" or else Upper = "MAT3X3" or else
        Upper = "MAT4" or else Upper = "MAT4X4"
      then
         return "Vec<f64>";
      elsif Kind = VK_Struct then
         return Safe_Rust_Name (Name);
      else
         return Primitive_Rust_Type (Kind);
      end if;
   end Type_Annotation_From_Name;

   function Cast_Expr (Kind : Value_Kind; Expr : String) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "alb_truthy(" & Expr & ")";
         when VK_String | VK_Binary =>
            return "alb_text(" & Expr & ")";
         when VK_U8 =>
            return "albU8(" & Expr & ")";
         when VK_U16 =>
            return "albU16(" & Expr & ")";
         when VK_S8 =>
            return "albI8(" & Expr & ")";
         when VK_S16 =>
            return "albI16(" & Expr & ")";
         when VK_U32 | VK_U64 =>
            return "albU32(" & Expr & ")";
         when VK_S32 | VK_HW8 | VK_HW16 | VK_HW32 =>
            return "albI32(" & Expr & ")";
         when VK_F32 =>
            return "(alb_num(" & Expr & ") as f32)";
         when VK_F64 =>
            return "alb_num(" & Expr & ")";
         when VK_Number | VK_Pure | VK_Unknown =>
            --  Unified i64 numeric lane (PURE packs already return i64).
            return "alb_i64(" & Expr & ")";
         when VK_U128 =>
            return "alb_i128(" & Expr & ")";
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
      if Kind = VK_F64 or else Kind = VK_F32 then
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
                  return Raw = "F64" or else Raw = "REAL" or else Raw = "DOUBLE"
                    or else Raw = "NUMBER" or else Raw = "F32" or else Raw = "SINGLE"
                    or else Raw = "FLOAT";
               end;
            end if;
         when others =>
            null;
      end case;

      return False;
   end Uses_Real_Power;

   function Typed_Array_Name (Kind : Value_Kind) return String is
   begin
      --  Legacy name kept for call sites; emission now uses Vec helpers.
      case Kind is
         when VK_String | VK_Binary =>
            return "String";
         when VK_F32 =>
            return "f32";
         when VK_F64 =>
            return "f64";
         when others =>
            return "i64";
      end case;
   end Typed_Array_Name;

   function Vec_Decl_Line
     (Name          : String;
      Kind          : Value_Kind;
      Capacity_Text : String) return String is
   begin
      --  Module/top-level arrays live in thread-local maps so nested `fn`
      --  items (INCLUDE modules) can read/write them without capturing.
      if Kind in VK_String | VK_Binary then
         return "alb_gstrarr_init(" & Escape_Rust_String (Name) & ", " &
           Capacity_Text & ");";
      else
         return "alb_garr_init(" & Escape_Rust_String (Name) & ", " &
           Capacity_Text & ");";
      end if;
   end Vec_Decl_Line;

   function Is_Global_Storage_Sym (Sym : Symbol_Record) return Boolean is
   begin
      return Sym.Active
        and then Length (Sym.Scope) = 0
        and then Sym.Kind in Sym_Scalar | Sym_Const | Sym_Strict_Array
          | Sym_Slide_Array | Sym_Parallel_Field | Sym_Temporal;
   end Is_Global_Storage_Sym;

   function Global_Array_Get
     (Name : String;
      Kind : Value_Kind;
      Idx  : String) return String is
   begin
      if Kind in VK_String | VK_Binary then
         return "alb_gstrarr_get(" & Escape_Rust_String (Name) & ", " & Idx & ")";
      else
         return "alb_garr_get(" & Escape_Rust_String (Name) & ", " & Idx & ")";
      end if;
   end Global_Array_Get;

   function Global_Array_Set
     (Name  : String;
      Kind  : Value_Kind;
      Idx   : String;
      Value : String) return String is
   begin
      if Kind in VK_String | VK_Binary then
         return "alb_gstrarr_set(" & Escape_Rust_String (Name) & ", " & Idx &
           ", " & Value & ")";
      else
         return "alb_garr_set(" & Escape_Rust_String (Name) & ", " & Idx &
           ", " & Value & ")";
      end if;
   end Global_Array_Set;

   function Global_Scalar_Get (Name : String; Kind : Value_Kind) return String is
   begin
      if Kind in VK_String | VK_Binary then
         return "alb_gstr_get(" & Escape_Rust_String (Name) & ")";
      elsif Kind = VK_F32 then
         return "(alb_gscal_get_f(" & Escape_Rust_String (Name) & ") as f32)";
      elsif Kind = VK_F64 then
         return "alb_gscal_get_f(" & Escape_Rust_String (Name) & ")";
      else
         return "alb_gscal_get(" & Escape_Rust_String (Name) & ")";
      end if;
   end Global_Scalar_Get;

   function Global_Scalar_Set
     (Name  : String;
      Kind  : Value_Kind;
      Value : String) return String is
   begin
      if Kind in VK_String | VK_Binary then
         return "alb_gstr_set(" & Escape_Rust_String (Name) & ", " & Value & ")";
      elsif Kind = VK_F32 then
         return "alb_gscal_set_f(" & Escape_Rust_String (Name) & ", (" & Value & ") as f64)";
      elsif Kind = VK_F64 then
         return "alb_gscal_set_f(" & Escape_Rust_String (Name) & ", " & Value & ")";
      else
         return "alb_gscal_set(" & Escape_Rust_String (Name) & ", " & Value & ")";
      end if;
   end Global_Scalar_Set;

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
         return "((" & Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
           " >> " & Trim_Image (Fields (Field_Id).Bit_Shift) & ") & " &
           Trim_Image (Mask) & ")";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).JS_Field);
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
         return Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
           " = ((" & Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
           " & ~(" & Trim_Image (Mask) & " << " & Trim_Image (Fields (Field_Id).Bit_Shift) &
           ")) | ((alb_i64(" & Value_Expr & ") & " & Trim_Image (Mask) & ") << " &
           Trim_Image (Fields (Field_Id).Bit_Shift) & "))";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
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

   function Find_Routine (Rust_Name : String) return Natural is
   begin
      for I in 1 .. Routine_Count loop
         if Routines (I).Active and then To_String (Routines (I).Rust_Name) = Rust_Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Routine;

   procedure Register_Symbol
     (Scope        : String;
      Name         : String;
      Rust_Name      : String;
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
         Symbols (Symbol_Count).Rust_Name := U (Rust_Name);
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
      Rust_Name     : String;
      Param_Count : Natural;
      Param_Modes : Param_Mode_List) is
      Existing : constant Natural := Find_Routine (Rust_Name);
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
         Routines (Routine_Count).Rust_Name := U (Rust_Name);
         Routines (Routine_Count).Param_Count := Param_Count;
         Routines (Routine_Count).Param_Modes := Param_Modes;
      end if;
   end Register_Routine;

   procedure Emit_Current_Out_Writebacks is
   begin
      for I in 1 .. Current_Routine_Out_Count loop
         Line
           ("__out_" & To_String (Current_Routine_Out_Names (I)) &
              ".value = " & To_String (Current_Routine_Out_Names (I)) & ";");
      end loop;
   end Emit_Current_Out_Writebacks;

   function Push_Shadow_Symbol
     (Scope   : String;
      Name    : String;
      Rust_Name : String;
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
      Symbols (Symbol_Count).Rust_Name := U (Rust_Name);
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
            return To_String (Symbols (Idx).Rust_Name);
         end if;
      end if;

      Idx := Find_Symbol ("", Scoped);
      if Idx /= 0 then
         return To_String (Symbols (Idx).Rust_Name);
      end if;

      Idx := Find_Symbol ("", Safe_Rust_Name (Raw));
      if Idx /= 0 then
         return To_String (Symbols (Idx).Rust_Name);
      end if;

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return To_String (Symbols (Idx).Rust_Name);
      end if;

      return Safe_Rust_Name (Raw);
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
      Scoped_JS : constant String := Scoped_Name (Raw);
      Plain_JS  : constant String := Safe_Rust_Name (Raw);
   begin
      if Find_Routine (Scoped_JS) /= 0 then
         return Scoped_JS;
      elsif Find_Routine (Plain_JS) /= 0 then
         return Plain_JS;
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
               return Safe_Rust_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
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
           and then To_String (Routines (I).Rust_Name) = Target_Name
         then
            return I;
         end if;
      end loop;

      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then Ada.Strings.Fixed.Index (Target_Name, To_String (Routines (I).Rust_Name)) > 0
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
              ("const __out_" & Trim_Image (Integer (Param_No)) &
                 " = { value: " & Out_Arg_Name (Curr) & " };");
            if Length (Writes) > 0 then
               Writes := Writes & " ";
            end if;
            Writes :=
              Writes &
              (Out_Arg_Name (Curr) &
                 " = __out_" & Trim_Image (Integer (Param_No)) & ".value;");
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
        "(() => { " & To_String (Decls) &
        " const __ret = " & Target_Name & "(" & To_String (Call_Args) & "); " &
        To_String (Writes) & " return __ret; })()";
   exception
      when others =>
         return Target_Name & "(" & Join_Arg_List (Arg_List) & ")";
   end Emit_Call_Expr_With_Out;

   function Predicate_Key_Expr (Pred_Node : Node_Index) return String is
      Node : constant AST_Node := Tree (Pred_Node);
   begin
      if Pred_Node = 0 then
         return Escape_Rust_String ("");
      end if;

      case Node.Kind is
         when AST_Assert_Stmt | AST_Retract_Stmt =>
            return "ALB_PRED(" &
              Escape_Rust_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Expr (Node.Left_Child) else "") &
              ")";
         when AST_Predicate =>
            return "ALB_PRED(" &
              Escape_Rust_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Join_Arg_List (Node.Left_Child) else "") &
              ")";
         when AST_Func_Call =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               return "ALB_PRED(" &
                 Escape_Rust_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                 (if Node.Right_Child > 0 then ", " & Join_Arg_List (Node.Right_Child) else "") &
                 ")";
            end if;
            return Expr (Pred_Node);
         when AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            return Escape_Rust_String (Raw_Lexeme (Node.Token_Index));
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
               Name : constant String := Safe_Rust_Name (T (T'First + 1 .. T'Last));
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

   function Escape_Rust_String (Text : String) return String is
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
               null;
            when ASCII.HT =>
               Append (R, "\t");
            when others =>
               Append (R, C);
         end case;
      end loop;
      Append (R, """");
      return To_String (R);
   end Escape_Rust_String;

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

   function RustImport_Specifier (Raw_Path : String) return String is
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
         return "./" & Safe_Rust_Name (Trimmed);
   end RustImport_Specifier;

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
      Rust_Name    : constant String :=
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
      Foreign_Imports (Foreign_Import_Count).Rust_Name := U (Rust_Name);
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
      Rust_Name    : constant String :=
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
      Foreign_Exports (Foreign_Export_Count).Rust_Name := U (Rust_Name);
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
                     Current_Module := U (Safe_Rust_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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
                     Current_Module := U (Safe_Rust_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Scan_Features (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;

            when AST_Procedure_Decl | AST_Function_Decl =>
               Register_Routine_Signature (Curr);
               Scan_Features (Tree (Curr).Right_Child);

            when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar =>
               Register_Foreign_Import (Curr);

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

      return Safe_Rust_Name (Raw_Lexeme (Tree (Left_Node).Token_Index) & "_" &
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
         return "alb_idx(0)";
      elsif Rank = 1 then
         return "alb_idx((" & To_String (Bounds (1)) & ") - 1)";
      else
         Append (Expr_Builder, "((" & To_String (Bounds (1)) & ") - 1)");
         for I in 2 .. Rank loop
            Append
              (Expr_Builder,
               " * " & Trim_Image (Dims (I)) & " + ((" &
               To_String (Bounds (I)) & ") - 1)");
         end loop;
         return "alb_idx(" & To_String (Expr_Builder) & ")";
      end if;
   end Build_Array_Index;

   function Field_Offset_Expr
     (Struct_Name : String;
      Field_Name  : String) return String is
      Field_Id : constant Natural := Find_Field (Struct_Name, Safe_Rust_Name (Field_Name));
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
      return "ALB_Text(" & Expr (Node_Index_Value) & ")";
   end As_Text_Expr;

   function Feature_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      if Node_Index_Value = 0 then
         return Escape_Rust_String ("");
      elsif Tree (Node_Index_Value).Kind = AST_String_Expr then
         return Expr (Node_Index_Value);
      elsif Tree (Node_Index_Value).Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
         return Escape_Rust_String (Raw_Feature_Atom (Node_Index_Value));
      else
         return As_Text_Expr (Node_Index_Value);
      end if;
   end Feature_Text_Expr;

   procedure Emit_Warn_Once
     (Key     : String;
      Message : String) is
   begin
      Line ("ALB_WARN_ONCE(" & Escape_Rust_String (Key) & ", " &
            Escape_Rust_String (Message) & ");");
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
      Plain_JS     : constant String := Safe_Rust_Name (Raw_Name);
      Scoped_JS    : constant String := Scoped_Name (Raw_Name);
   begin
      if Routine_Name'Length > 0 then
         if Find_Symbol (Routine_Name, Raw_Name) = 0 then
            Register_Symbol (Routine_Name, Raw_Name, Plain_JS, Tag, Sym_Scalar);
            Line ("let mut " & Plain_JS & ": " & Primitive_Rust_Type (Tag) &
                  " = " & Default_Value (Tag) & ";");
         end if;
      elsif Find_Symbol ("", Scoped_JS) = 0 and then Find_Symbol ("", Raw_Name) = 0 then
         Register_Symbol ("", Scoped_JS, Scoped_JS, Tag, Sym_Scalar);
         Line (Global_Scalar_Set (Scoped_JS, Tag, Default_Value (Tag)) & ";");
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
               return "0b" & T (T'First + 1 .. T'Last);
            end;
         when AST_Octal_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return "0o" & T (T'First + 1 .. T'Last);
            end;
         when AST_String_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               if T'Length >= 2 and then T (T'First) = '"' then
                  return T;
               else
                  return Escape_Rust_String (T);
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
               return Safe_Rust_Name (T (T'First + 1 .. T'Last));
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
                  declare
                     Idx_Expr : constant String :=
                       Build_Array_Index (S.Dims, S.Rank, Node.Left_Child);
                  begin
                     if Is_Global_Storage_Sym (S) then
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           Global_Array_Get (To_String (S.Rust_Name), S.Tag, Idx_Expr));
                     else
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           To_String (S.Rust_Name) & "[" & Idx_Expr & "]");
                     end if;
                  end;
               elsif S.Active
                 and then Is_Global_Storage_Sym (S)
                 and then S.Kind in Sym_Scalar | Sym_Const | Sym_Temporal
               then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     Global_Scalar_Get (To_String (S.Rust_Name), S.Tag));
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
                        declare
                           Idx_Expr : constant String :=
                             Build_Array_Index
                               (Symbols (Field_Sym_Id).Dims,
                                Symbols (Field_Sym_Id).Rank,
                                Left_Node.Left_Child);
                        begin
                           if Is_Global_Storage_Sym (Symbols (Field_Sym_Id)) then
                              return Wrap_Firewall_Read
                                (Node_Index_Value,
                                 Global_Array_Get
                                   (To_String (Symbols (Field_Sym_Id).Rust_Name),
                                    Symbols (Field_Sym_Id).Tag,
                                    Idx_Expr));
                           else
                              return Wrap_Firewall_Read
                                (Node_Index_Value,
                                 To_String (Symbols (Field_Sym_Id).Rust_Name) &
                                   "[" & Idx_Expr & "]");
                           end if;
                        end;
                     end if;
                  end;
               end if;

               if Right_Node.Kind = AST_Var_Expr
                 and then Right_Node.Left_Child > 0
                 and then Group_Sym.Active
                 and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
               then
                  declare
                     Idx_Expr : constant String :=
                       Build_Array_Index
                         (Group_Sym.Dims, Group_Sym.Rank, Right_Node.Left_Child);
                  begin
                     if Is_Global_Storage_Sym (Group_Sym) then
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           Global_Array_Get
                             (To_String (Group_Sym.Rust_Name), Group_Sym.Tag, Idx_Expr));
                     else
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           To_String (Group_Sym.Rust_Name) & "[" & Idx_Expr & "]");
                     end if;
                  end;
               end if;

               if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                  declare
                     Field_Id : constant Natural :=
                       Find_Field (To_String (Left_Sym.Struct_Name), Safe_Rust_Name (Right_Name));
                  begin
                     return Wrap_Firewall_Read
                       (Node_Index_Value,
                        Field_Read_Expr (To_String (Left_Sym.Rust_Name), Field_Id));
                  end;
               elsif Group_Sym.Active then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Group_Sym.Rust_Name));
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
               Realish : constant Boolean :=
                 Uses_Real_Power (Node.Left_Child)
                 or else Uses_Real_Power (Node.Right_Child);
            begin
               case Tok_Kind is
                  when Tok_Pipe =>
                     -- ALB | is string concat, NOT bitwise OR (OR keyword -> Rust |).
                     return "ALB_concat(" & As_Text_Expr (Node.Left_Child) &
                       ", " & As_Text_Expr (Node.Right_Child) & ")";
                  when Tok_Plus =>
                     if Realish then
                        return "(alb_num(" & L & ") + alb_num(" & R & "))";
                     end if;
                     return "(" & L & " + " & R & ")";
                  when Tok_Minus =>
                     if Realish then
                        return "(alb_num(" & L & ") - alb_num(" & R & "))";
                     end if;
                     return "(" & L & " - " & R & ")";
                  when Tok_Mul =>
                     if Realish then
                        return "(alb_num(" & L & ") * alb_num(" & R & "))";
                     end if;
                     return "(" & L & " * " & R & ")";
                  when Tok_Div =>
                     if Realish then
                        return "(alb_num(" & L & ") / alb_num(" & R & "))";
                     end if;
                     return "albDiv(" & L & ", " & R & ")";
                  when Tok_Mod =>
                     return "albMod(" & L & ", " & R & ")";
                  when Tok_Pow =>
                     if Realish then
                        return "alb_powf(alb_num(" & L & "), alb_num(" & R & "))";
                     end if;
                     return "ALB_POW(" & L & ", " & R & ")";
                  when Tok_Less =>
                     return "(if " & L & " < " & R & " { 1 } else { 0 })";
                  when Tok_Greater =>
                     return "(if " & L & " > " & R & " { 1 } else { 0 })";
                  when Tok_Less_Equal =>
                     return "(if " & L & " <= " & R & " { 1 } else { 0 })";
                  when Tok_Greater_Equal =>
                     return "(if " & L & " >= " & R & " { 1 } else { 0 })";
                  when Tok_Equal | Tok_Assign =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(if alb_truthy(" & R & ") { 1 } else { 0 })";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(if alb_truthy(" & L & ") { 1 } else { 0 })";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(if alb_truthy(" & R & ") { 0 } else { 1 })";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(if alb_truthy(" & L & ") { 0 } else { 1 })";
                     end if;
                     return "(if " & L & " == " & R & " { 1 } else { 0 })";
                  when Tok_Not_Equal =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(if alb_truthy(" & R & ") { 0 } else { 1 })";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(if alb_truthy(" & L & ") { 0 } else { 1 })";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(if alb_truthy(" & R & ") { 1 } else { 0 })";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(if alb_truthy(" & L & ") { 1 } else { 0 })";
                     end if;
                     return "(if " & L & " != " & R & " { 1 } else { 0 })";
                  when Tok_And =>
                     -- ALB AND/OR are bitwise (same as FASM/C/Python). Logical
                     -- short-circuit is ORELSE when implemented. Emit Rust & / |
                     -- (never confuse with ALB pipe concat).
                     return "((" & L & ") & (" & R & "))";
                  when Tok_Or =>
                     return "((" & L & ") | (" & R & "))";
                  when Tok_Xor =>
                     return "(" & L & " ^ " & R & ")";
                  when Tok_Shl =>
                     return "(" & L & " << " & R & ")";
                  when Tok_Shr =>
                     return "(" & L & " >> " & R & ")";
                  when others =>
                     return "(" & L & " + " & R & ")";
               end case;
            end;
         when AST_Unary_Minus =>
            return "(-" & Expr (Node.Left_Child) & ")";
         when AST_Not =>
            return "(if alb_truthy(" & Expr (Node.Left_Child) & ") { 0 } else { 1 })";
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
               elsif Ctor_Name = "F32" or else Ctor_Name = "SINGLE"
                 or else Ctor_Name = "FLOAT"
               then
                  return Cast_Expr (VK_F32, Expr (A1));
               elsif Ctor_Name = "F64" or else Ctor_Name = "REAL"
                 or else Ctor_Name = "DOUBLE" or else Ctor_Name = "NUMBER"
               then
                  return Cast_Expr (VK_F64, Expr (A1));
               elsif Ctor_Name = "HW8" then
                  return Cast_Expr (VK_HW8, Expr (A1));
               elsif Ctor_Name = "HW16" then
                  return Cast_Expr (VK_HW16, Expr (A1));
               elsif Ctor_Name = "HW32" then
                  return Cast_Expr (VK_HW32, Expr (A1));
               elsif Ctor_Name = "HW64" then
                  return Cast_Expr (VK_Number, Expr (A1));
               elsif Ctor_Name = "CHAR" then
                  return Cast_Expr (VK_U8, Expr (A1));
               elsif Ctor_Name = "S128" or else Ctor_Name = "U128" then
                  return Cast_Expr (VK_U128, Expr (A1));
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
                             Escape_Rust_String (To_String (Raw)) &
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
                 (Safe_Rust_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)),
                  Raw_Lexeme (Tree (Node.Right_Child).Token_Index));
            else
               return "0";
            end if;
         when AST_TypeOf_Expr =>
            return Escape_Rust_String ("i64");
         when AST_Temporal_Ref =>
            declare
               Base_Name : constant String := Raw_Lexeme (Tree (Node.Left_Child).Token_Index);
               Rust_Base   : constant String := Resolve_Var_Name (Base_Name);
               Sel       : constant Token_Kind := Tokens (Node.Token_Index).Kind;
               TSym      : constant Symbol_Record := Resolve_Symbol (Base_Name);
               Hist      : constant String := Trim_Image (Integer'Max (1, TSym.History_Size));
            begin
               case Sel is
                  when Tok_Now =>
                     return Rust_Base;
                  when Tok_Past =>
                     return "alb_temp_past(&" & Rust_Base & "_history, " & Rust_Base & "_head, " & Hist & ")";
                  when Tok_Future =>
                     return "alb_temp_future(&" & Rust_Base & "_history, " & Rust_Base & "_head, " & Hist & ")";
                  when Tok_Timeline =>
                     return Trim_Image (TSym.Aux_Offset);
                  when others =>
                     return Rust_Base;
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
      Line ("// ALBR — generated by AdaLogic BASIC → Rust (rustc)");
      Line ("// Target: rustc / std (MIT OR Apache-2.0). Safe to bundle/link.");
      Line ("#![allow(dead_code, unused_mut, unused_variables, non_snake_case, unused_assignments)]");
      Line ("#![allow(clippy::all)]");
      Line ("use std::cell::RefCell;");
      Line ("use std::collections::{HashMap, HashSet};");
      Line ("use std::ffi::{CStr, CString};");
      Line ("use std::fs;");
      Line ("use std::io::{self, Write};");
      Line ("use std::os::raw::{c_char, c_int, c_void};");
      Line ("use std::ptr;");
      Line ("use std::sync::atomic::{AtomicBool, AtomicI64, AtomicPtr, Ordering};");
      Line ("use std::time::{SystemTime, UNIX_EPOCH};");
      New_Line_Emit;
      if Need_Compat_Runtime then
         Line ("#[link(name = ""kernel32"")]");
         Line ("extern ""C"" {");
         Line ("  fn LoadLibraryA(lp: *const i8) -> *mut c_void;");
         Line ("  fn GetProcAddress(m: *mut c_void, n: *const i8) -> *mut c_void;");
         Line ("}");
         Line ("thread_local! {");
         Line ("  static ALB_FFI_LIBS: RefCell<HashMap<String, *mut c_void>> = RefCell::new(HashMap::new());");
         Line ("}");
         Line ("fn alb_load_sym(lib_name: &str, sym_name: &str) -> *mut c_void {");
         Line ("  ALB_FFI_LIBS.with(|libs| {");
         Line ("    let mut map = libs.borrow_mut();");
         Line ("    let mod_handle = if let Some(&h) = map.get(lib_name) { h } else {");
         Line ("      let lib_c = match CString::new(lib_name) { Ok(c) => c, Err(_) => return ptr::null_mut() };");
         Line ("      let h = unsafe { LoadLibraryA(lib_c.as_ptr()) };");
         Line ("      if h.is_null() {");
         Line ("        eprintln!(""ALBR FFI: cannot load {}"", lib_name);");
         Line ("        return ptr::null_mut();");
         Line ("      }");
         Line ("      map.insert(lib_name.to_string(), h);");
         Line ("      h");
         Line ("    };");
         Line ("    let sym_c = match CString::new(sym_name) { Ok(c) => c, Err(_) => return ptr::null_mut() };");
         Line ("    let addr = unsafe { GetProcAddress(mod_handle, sym_c.as_ptr()) };");
         Line ("    if addr.is_null() {");
         Line ("      eprintln!(""ALBR FFI: missing symbol {} in {}"", sym_name, lib_name);");
         Line ("    }");
         Line ("    addr");
         Line ("  })");
         Line ("}");
         New_Line_Emit;
      end if;
      Line ("const SDL_INIT_VIDEO: u32 = 0x0000_0020;");
      Line ("const SDL_EVENT_QUIT: u32 = 0x100;");
      Line ("const SDL_EVENT_KEY_DOWN: u32 = 0x300;");
      Line ("const SDL_EVENT_KEY_UP: u32 = 0x301;");
      Line ("const SDL_EVENT_MOUSE_MOTION: u32 = 0x400;");
      Line ("const SDL_EVENT_MOUSE_BUTTON_DOWN: u32 = 0x401;");
      Line ("const SDL_EVENT_MOUSE_BUTTON_UP: u32 = 0x402;");
      Line ("const SDL_EVENT_MOUSE_WHEEL: u32 = 0x403;");
      Line ("#[repr(C)] #[derive(Clone, Copy)] struct SDL_FRect { x: f32, y: f32, w: f32, h: f32 }");
      Line ("#[repr(C)] #[derive(Clone, Copy)] struct SDL_FPoint { x: f32, y: f32 }");
      Line ("#[repr(C)] #[derive(Clone, Copy)] struct SDL_FColor { r: f32, g: f32, b: f32, a: f32 }");
      Line ("#[repr(C)] #[derive(Clone, Copy)] struct SDL_Vertex { position: SDL_FPoint, color: SDL_FColor, tex_coord: SDL_FPoint }");
      Line ("#[link(name = ""SDL3"")]");
      Line ("extern ""C"" {");
      Line ("  fn SDL_Init(flags: u32) -> bool;");
      Line ("  fn SDL_Quit();");
      Line ("  fn SDL_CreateWindowAndRenderer(title: *const c_char, w: c_int, h: c_int, window_flags: u64, window: *mut *mut c_void, renderer: *mut *mut c_void) -> bool;");
      Line ("  fn SDL_DestroyWindow(window: *mut c_void);");
      Line ("  fn SDL_DestroyRenderer(renderer: *mut c_void);");
      Line ("  fn SDL_SetRenderVSync(renderer: *mut c_void, vsync: c_int) -> bool;");
      Line ("  fn SDL_SetRenderDrawColor(renderer: *mut c_void, r: u8, g: u8, b: u8, a: u8) -> bool;");
      Line ("  fn SDL_RenderClear(renderer: *mut c_void) -> bool;");
      Line ("  fn SDL_RenderPresent(renderer: *mut c_void) -> bool;");
      Line ("  fn SDL_RenderFillRect(renderer: *mut c_void, rect: *const SDL_FRect) -> bool;");
      Line ("  fn SDL_RenderRect(renderer: *mut c_void, rect: *const SDL_FRect) -> bool;");
      Line ("  fn SDL_RenderLine(renderer: *mut c_void, x1: f32, y1: f32, x2: f32, y2: f32) -> bool;");
      Line ("  fn SDL_RenderPoint(renderer: *mut c_void, x: f32, y: f32) -> bool;");
      Line ("  fn SDL_RenderPoints(renderer: *mut c_void, points: *const SDL_FPoint, count: c_int) -> bool;");
      Line ("  fn SDL_RenderGeometry(renderer: *mut c_void, texture: *mut c_void, vertices: *const SDL_Vertex, num_vertices: c_int, indices: *const c_int, num_indices: c_int) -> bool;");
      Line ("  fn SDL_PollEvent(event: *mut u8) -> bool;");
      Line ("  fn SDL_GetTicks() -> u64;");
      Line ("  fn SDL_Delay(ms: u32);");
      Line ("  fn SDL_GetError() -> *const c_char;");
      Line ("}");
      Line ("static mut ALB_SDL_WINDOW: *mut c_void = ptr::null_mut();");
      Line ("static mut ALB_SDL_RENDERER: *mut c_void = ptr::null_mut();");
      Line ("static ALB_SDL_READY: AtomicBool = AtomicBool::new(false);");
      New_Line_Emit;
      Line ("#[derive(Clone, Debug)]");
      Line ("enum AlbrVal { Num(i64), Real(f64), Bool(bool), Str(String), Big(i128) }");
      Line ("impl Default for AlbrVal { fn default() -> Self { AlbrVal::Num(0) } }");
      Line ("#[derive(Clone, Debug, Default)]");
      Line ("struct AlbrStruct { fields: HashMap<String, AlbrVal> }");
      Line ("#[derive(Debug)]");
      Line ("enum AlbrError { Fatal(String), Require(String), Ensure(String), Firewall(String) }");
      New_Line_Emit;
      Line ("fn alb_text(v: impl ToString) -> String { v.to_string() }");
      Line ("trait AlbNum { fn alb_to_f64(self) -> f64; }");
      Line ("impl AlbNum for f64 { fn alb_to_f64(self) -> f64 { self } }");
      Line ("impl AlbNum for i64 { fn alb_to_f64(self) -> f64 { self as f64 } }");
      Line ("impl AlbNum for i32 { fn alb_to_f64(self) -> f64 { self as f64 } }");
      Line ("impl AlbNum for u64 { fn alb_to_f64(self) -> f64 { self as f64 } }");
      Line ("impl AlbNum for &str { fn alb_to_f64(self) -> f64 { self.parse::<f64>().unwrap_or(0.0) } }");
      Line ("impl AlbNum for String { fn alb_to_f64(self) -> f64 { self.parse::<f64>().unwrap_or(0.0) } }");
      Line ("fn alb_num<T: AlbNum>(v: T) -> f64 { v.alb_to_f64() }");
      Line ("fn alb_num_ts(v: impl ToString) -> f64 { v.to_string().parse::<f64>().unwrap_or(0.0) }");
      Line ("fn alb_i64(v: impl ToString) -> i64 { alb_num_ts(v) as i64 }");
      Line ("fn alb_idx(i: impl ToString) -> usize { let n = alb_i64(i); if n < 0 { 0 } else { n as usize } }");
      Line ("fn alb_i128(v: impl ToString) -> i128 { v.to_string().parse::<i128>().unwrap_or(0) }");
      New_Line_Emit;
      Line ("thread_local! {");
      Line ("  static ALB_GARR: RefCell<HashMap<String, Vec<i64>>> = RefCell::new(HashMap::new());");
      Line ("  static ALB_GSTRARR: RefCell<HashMap<String, Vec<String>>> = RefCell::new(HashMap::new());");
      Line ("  static ALB_GSCAL: RefCell<HashMap<String, i64>> = RefCell::new(HashMap::new());");
      Line ("  static ALB_GSTR: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());");
      Line ("}");
      Line ("fn alb_garr_init(name: &str, n: usize) {");
      Line ("  ALB_GARR.with(|m| { m.borrow_mut().entry(name.to_string()).or_insert_with(|| vec![0i64; n]); });");
      Line ("}");
      Line ("fn alb_gstrarr_init(name: &str, n: usize) {");
      Line ("  ALB_GSTRARR.with(|m| { m.borrow_mut().entry(name.to_string()).or_insert_with(|| vec![String::new(); n]); });");
      Line ("}");
      Line ("fn alb_garr_get(name: &str, idx: usize) -> i64 {");
      Line ("  ALB_GARR.with(|m| m.borrow().get(name).and_then(|v| v.get(idx).copied()).unwrap_or(0))");
      Line ("}");
      Line ("fn alb_garr_set(name: &str, idx: usize, val: i64) {");
      Line ("  ALB_GARR.with(|m| { if let Some(v) = m.borrow_mut().get_mut(name) { if idx < v.len() { v[idx] = val; } } });");
      Line ("}");
      Line ("fn alb_garr_len(name: &str) -> i64 {");
      Line ("  ALB_GARR.with(|m| m.borrow().get(name).map(|v| v.len() as i64).unwrap_or(0))");
      Line ("}");
      Line ("fn alb_gstrarr_get(name: &str, idx: usize) -> String {");
      Line ("  ALB_GSTRARR.with(|m| m.borrow().get(name).and_then(|v| v.get(idx).cloned()).unwrap_or_default())");
      Line ("}");
      Line ("fn alb_gstrarr_set(name: &str, idx: usize, val: impl ToString) {");
      Line ("  ALB_GSTRARR.with(|m| { if let Some(v) = m.borrow_mut().get_mut(name) { if idx < v.len() { v[idx] = val.to_string(); } } });");
      Line ("}");
      Line ("fn alb_gscal_get(name: &str) -> i64 {");
      Line ("  ALB_GSCAL.with(|m| m.borrow().get(name).copied().unwrap_or(0))");
      Line ("}");
      Line ("fn alb_gscal_set(name: &str, val: i64) {");
      Line ("  ALB_GSCAL.with(|m| { m.borrow_mut().insert(name.to_string(), val); });");
      Line ("}");
      Line ("fn alb_gscal_get_f(name: &str) -> f64 {");
      Line ("  f64::from_bits(alb_gscal_get(name) as u64)");
      Line ("}");
      Line ("fn alb_gscal_set_f(name: &str, val: f64) {");
      Line ("  alb_gscal_set(name, val.to_bits() as i64);");
      Line ("}");
      Line ("fn alb_gstr_get(name: &str) -> String {");
      Line ("  ALB_GSTR.with(|m| m.borrow().get(name).cloned().unwrap_or_default())");
      Line ("}");
      Line ("fn alb_gstr_set(name: &str, val: impl ToString) {");
      Line ("  ALB_GSTR.with(|m| { m.borrow_mut().insert(name.to_string(), val.to_string()); });");
      Line ("}");
      Line ("fn alb_truthy(v: impl ToString) -> bool {");
      Line ("  let s = v.to_string();");
      Line ("  !(s == ""0"" || s == ""false"" || s.is_empty() || s == ""0.0"")");
      Line ("}");
      Line ("fn ALB_Text(v: impl ToString) -> String { alb_text(v) }");
      Line ("fn ALB_concat(a: impl ToString, b: impl ToString) -> String { format!(""{}{}"", a.to_string(), b.to_string()) }");
      Line ("fn alb_max(a: i64, b: i64) -> i64 { if a > b { a } else { b } }");
      Line ("fn alb_min(a: i64, b: i64) -> i64 { if a < b { a } else { b } }");
      Line ("fn alb_trunc(v: f64) -> i64 { v.trunc() as i64 }");
      Line ("fn alb_floor(v: f64) -> i64 { v.floor() as i64 }");
      Line ("fn alb_round(v: f64) -> i64 { v.round() as i64 }");
      Line ("fn alb_powf(a: f64, b: f64) -> f64 { a.powf(b) }");
      Line ("static ALB_RND_STATE: AtomicI64 = AtomicI64::new(0xC0FFEE);");
      Line ("fn alb_random() -> f64 {");
      Line ("  let mut x = ALB_RND_STATE.load(Ordering::Relaxed);");
      Line ("  x ^= x << 13; x ^= x >> 7; x ^= x << 17;");
      Line ("  ALB_RND_STATE.store(x, Ordering::Relaxed);");
      Line ("  ((x as u64) as f64) / (u64::MAX as f64)");
      Line ("}");
      New_Line_Emit;
      Line ("static ALB_CONSOLE_DISABLED: AtomicBool = AtomicBool::new(" &
            (if No_Console_Overlay then "true" else "false") & ");");
      New_Line_Emit;
      Line ("thread_local! {");
      Line ("  static ALB_TEXT_ROWS: RefCell<Vec<String>> = RefCell::new(vec![String::new()]);");
      Line ("  static ALB_TEXT_CX: RefCell<i64> = RefCell::new(1);");
      Line ("  static ALB_TEXT_CY: RefCell<i64> = RefCell::new(1);");
      Line ("  static ALB_WARNED: RefCell<HashSet<String>> = RefCell::new(HashSet::new());");
      Line ("  static ALB_SAVE_STORE: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());");
      Line ("  static ALB_KEYS: RefCell<[u8; 512]> = RefCell::new([0; 512]);");
      Line ("  static ALB_MOUSE_BTNS: RefCell<[u8; 8]> = RefCell::new([0; 8]);");
      Line ("  static ALB_VAS: RefCell<Vec<i32>> = RefCell::new(vec![0; 65536]);");
      Line ("  static ALB_MOUSE_X_CELL: RefCell<i64> = RefCell::new(0);");
      Line ("  static ALB_MOUSE_Y_CELL: RefCell<i64> = RefCell::new(0);");
      Line ("  static ALB_MOUSE_WHEEL_CELL: RefCell<i64> = RefCell::new(0);");
      Line ("  static ALB_BASE_W: RefCell<i64> = RefCell::new(320);");
      Line ("  static ALB_BASE_H: RefCell<i64> = RefCell::new(200);");
      Line ("  static ALB_WIN_W: RefCell<i64> = RefCell::new(320);");
      Line ("  static ALB_WIN_H: RefCell<i64> = RefCell::new(200);");
      Line ("  static ALB_VIRT_W: RefCell<i64> = RefCell::new(320);");
      Line ("  static ALB_VIRT_H: RefCell<i64> = RefCell::new(200);");
      Line ("  static ALB_COLOR_CELL: RefCell<u32> = RefCell::new(0xffffffff);");
      Line ("  static ALB_ORIGIN_X: RefCell<i64> = RefCell::new(0);");
      Line ("  static ALB_ORIGIN_Y: RefCell<i64> = RefCell::new(0);");
      Line ("  static ALB_RUNNING: RefCell<bool> = RefCell::new(true);");
      Line ("  static ALB_SHUTDOWN: RefCell<bool> = RefCell::new(false);");
      Line ("  static ALB_DELAY_UNTIL: RefCell<i64> = RefCell::new(0);");
      Line ("  static ALB_FRAME_INTERVAL: RefCell<i64> = RefCell::new(16);");
      Line ("  static ALB_LAST_FRAME: RefCell<i64> = RefCell::new(0);");
      Line ("  static ALB_FIREWALL_STACK: RefCell<Vec<AlbrFirewall>> = RefCell::new(Vec::new());");
      Line ("  static ALB_FACT_LIVE: RefCell<Vec<u8>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_FACT_KEY: RefCell<Vec<String>> = RefCell::new(vec![String::new(); 1024]);");
      Line ("  static ALB_FACT_VAL: RefCell<Vec<String>> = RefCell::new(vec![String::new(); 1024]);");
      Line ("  static ALB_REL_LIVE: RefCell<Vec<u8>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_REL_PRED: RefCell<Vec<u16>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_REL_ARITY: RefCell<Vec<u8>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_REL_ARG1: RefCell<Vec<i32>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_REL_ARG2: RefCell<Vec<i32>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_REL_ARG3: RefCell<Vec<i32>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_REL_ARG4: RefCell<Vec<i32>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_REL_VALUE: RefCell<Vec<i32>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_RULE_COUNT: RefCell<usize> = RefCell::new(0);");
      Line ("  static ALB_RULE_HEAD: RefCell<Vec<u16>> = RefCell::new(vec![0; 128]);");
      Line ("  static ALB_RULE_BODY_LEN: RefCell<Vec<u8>> = RefCell::new(vec![0; 128]);");
      Line ("  static ALB_RULE_BODY_PRED: RefCell<Vec<u16>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_RULE_BODY_MODE: RefCell<Vec<u8>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_RULE_BODY_CONST: RefCell<Vec<i32>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_GC_ALIVE: RefCell<Vec<u8>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_GC_REFS: RefCell<Vec<u16>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_GC_CA: RefCell<Vec<u16>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_GC_CB: RefCell<Vec<u16>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_GC_CC: RefCell<Vec<u16>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_GC_CD: RefCell<Vec<u16>> = RefCell::new(vec![0; 1024]);");
      Line ("  static ALB_FILE_LIVE: RefCell<Vec<u8>> = RefCell::new(vec![0; 64]);");
      Line ("  static ALB_FILE_MODE: RefCell<Vec<String>> = RefCell::new(vec![String::new(); 64]);");
      Line ("  static ALB_FILE_NAME: RefCell<Vec<String>> = RefCell::new(vec![String::new(); 64]);");
      Line ("  static ALB_FILE_BUF: RefCell<Vec<String>> = RefCell::new(vec![String::new(); 64]);");
      Line ("  static ALB_FILE_CUR: RefCell<Vec<i32>> = RefCell::new(vec![0; 64]);");
      Line ("  static ALB_ON_TICK: RefCell<fn()> = RefCell::new(|| {});");
      Line ("  static ALB_ON_PAINT: RefCell<fn()> = RefCell::new(|| {});");
      Line ("  static ALB_ON_KEY: RefCell<fn()> = RefCell::new(|| {});");
      Line ("  static ALB_COMPAT_TICK: RefCell<u32> = RefCell::new(0);");
      Line ("  static ALB_NET_NEXT: RefCell<i64> = RefCell::new(1);");
      Line ("  static ALB_PROC_NEXT: RefCell<i64> = RefCell::new(1);");
      Line ("  static ALB_NET_TABLE: RefCell<HashMap<i64, AlbrNetSock>> = RefCell::new(HashMap::new());");
      Line ("  static ALB_PROC_TABLE: RefCell<HashMap<i64, AlbrProcess>> = RefCell::new(HashMap::new());");
      Line ("  static ALB_REV_STACK: RefCell<Vec<AlbrRevFrame>> = RefCell::new(Vec::new());");
      Line ("}");
      New_Line_Emit;
      Line ("#[derive(Clone, Debug, Default)]");
      Line ("struct AlbrFirewall { name: String, deny_all: bool, read: HashSet<String>, write: HashSet<String> }");
      Line ("struct AlbrFwGuard;");
      Line ("impl Drop for AlbrFwGuard { fn drop(&mut self) { ALB_FIREWALL_LEAVE(); } }");
      Line ("#[derive(Clone, Debug, Default)]");
      Line ("struct AlbrNetSock { handle: i64, protocol: i64, port: i64, buffer_size: i64, listening: bool, open: bool, last_sent: Vec<u8>, last_recv: Vec<u8> }");
      Line ("#[derive(Clone, Debug, Default)]");
      Line ("struct AlbrProcess { handle: i64, image: String, alive: bool, elevated: bool, pid: i64 }");
      Line ("#[derive(Clone, Debug)]");
      Line ("enum AlbrRevOp { Add(String, i64), Sub(String, i64), Xor(String, i64), Not(String), Neg(String), Swap(String, String) }");
      Line ("#[derive(Clone, Debug, Default)]");
      Line ("struct AlbrRevFrame { ops: Vec<AlbrRevOp> }");
      New_Line_Emit;
      Line ("fn ALB_FATAL(msg: impl ToString) -> ! {");
      Line ("  ALB_RUNNING.with(|r| { *r.borrow_mut() = false; });");
      Line ("  eprintln!(""ALBR fatal: {}"", msg.to_string());");
      Line ("  panic!(""{}"", msg.to_string());");
      Line ("}");
      Line ("fn ALB_WARN_ONCE(key: &str, message: &str) {");
      Line ("  ALB_WARNED.with(|w| { let mut set = w.borrow_mut(); if set.insert(key.to_string()) { eprintln!(""ALBR: {}"", message); } });");
      Line ("}");
      Line ("fn alb_console_write(text: &str, newline: bool) {");
      Line ("  if ALB_CONSOLE_DISABLED.load(Ordering::Relaxed) { return; }");
      Line ("  ALB_TEXT_ROWS.with(|rows| {");
      Line ("    let mut rows = rows.borrow_mut();");
      Line ("    ALB_TEXT_CY.with(|cy| ALB_TEXT_CX.with(|cx| {");
      Line ("      let mut y = *cy.borrow(); let mut x = *cx.borrow();");
      Line ("      for ch in text.chars() {");
      Line ("        if ch == '\r' { continue; }");
      Line ("        if ch == '\n' { y += 1; x = 1; while rows.len() < y as usize { rows.push(String::new()); } continue; }");
      Line ("        while rows.len() < y as usize { rows.push(String::new()); }");
      Line ("        let row = (y - 1) as usize; let col = alb_max(1, x) as usize - 1;");
      Line ("        let mut line = rows[row].clone();");
      Line ("        if col > line.len() { line.push_str(&"" "".repeat(col - line.len())); }");
      Line ("        if col < line.len() { line.replace_range(col..col+1, &ch.to_string()); } else { line.push(ch); }");
      Line ("        rows[row] = line; x = (col as i64) + 2;");
      Line ("      }");
      Line ("      if newline { y += 1; x = 1; while rows.len() < y as usize { rows.push(String::new()); } }");
      Line ("      *cy.borrow_mut() = y; *cx.borrow_mut() = x;");
      Line ("    }));");
      Line ("  });");
      Line ("}");
      Line ("fn ALB_PRINT(v: impl ToString) {");
      Line ("  if ALB_CONSOLE_DISABLED.load(Ordering::Relaxed) { return; }");
      Line ("  let text = v.to_string(); println!(""{}"", text); alb_console_write(&text, true);");
      Line ("}");
      Line ("fn ALB_PRINT_RAW(v: impl ToString) {");
      Line ("  if ALB_CONSOLE_DISABLED.load(Ordering::Relaxed) { return; }");
      Line ("  let text = v.to_string(); print!(""{}"", text); let _ = io::stdout().flush(); alb_console_write(&text, false);");
      Line ("}");
      Line ("fn ALB_PROMPT_TEXT(prompt: impl ToString) -> String {");
      Line ("  let p = prompt.to_string(); if !p.is_empty() { ALB_PRINT(&p); }");
      Line ("  let mut buf = String::new(); let _ = io::stdin().read_line(&mut buf);");
      Line ("  while buf.ends_with('\n') || buf.ends_with('\r') { buf.pop(); }");
      Line ("  ALB_PRINT(format!(""> {}"", buf)); buf");
      Line ("}");
      Line ("fn ALB_READLINE_TEXT() -> String { ALB_PROMPT_TEXT("""") }");
      Line ("fn ALB_LOCATE(x: i64, y: i64) {");
      Line ("  ALB_TEXT_CX.with(|c| { *c.borrow_mut() = alb_max(1, x); });");
      Line ("  ALB_TEXT_CY.with(|c| { *c.borrow_mut() = alb_max(1, y); });");
      Line ("}");
      New_Line_Emit;
      Line ("fn albU8(v: impl ToString) -> i64 { (alb_i64(v) as u8) as i64 }");
      Line ("fn albU16(v: impl ToString) -> i64 { (alb_i64(v) as u16) as i64 }");
      Line ("fn albU32(v: impl ToString) -> i64 { (alb_i64(v) as u32) as i64 }");
      Line ("fn albI8(v: impl ToString) -> i64 { (alb_i64(v) as i8) as i64 }");
      Line ("fn albI16(v: impl ToString) -> i64 { (alb_i64(v) as i16) as i64 }");
      Line ("fn albI32(v: impl ToString) -> i64 { alb_i64(v) as i32 as i64 }");
      Line ("fn U8(v: impl ToString) -> i64 { albU8(v) }");
      Line ("fn U16(v: impl ToString) -> i64 { albU16(v) }");
      Line ("fn S8(v: impl ToString) -> i64 { albI8(v) }");
      Line ("fn I8(v: impl ToString) -> i64 { albI8(v) }");
      Line ("fn S16(v: impl ToString) -> i64 { albI16(v) }");
      Line ("fn I16(v: impl ToString) -> i64 { albI16(v) }");
      Line ("fn U32(v: impl ToString) -> i64 { albU32(v) }");
      Line ("fn U64(v: impl ToString) -> i64 { albU32(v) }");
      Line ("fn U128(v: impl ToString) -> i128 { alb_i128(v) }");
      Line ("fn S32(v: impl ToString) -> i64 { albI32(v) }");
      Line ("fn I32(v: impl ToString) -> i64 { albI32(v) }");
      Line ("fn HW8(v: impl ToString) -> i64 { albI32(v) }");
      Line ("fn HW16(v: impl ToString) -> i64 { albI32(v) }");
      Line ("fn HW32(v: impl ToString) -> i64 { albI32(v) }");
      Line ("fn F64(v: impl ToString) -> f64 { alb_num_ts(v) }");
      New_Line_Emit;
      Line ("const ALB_PURE_NUM_BITS: i64 = 21;");
      Line ("const ALB_PURE_NUM_MOD: i64 = 1 << ALB_PURE_NUM_BITS;");
      Line ("const ALB_PURE_NUM_SIGN: i64 = 1 << (ALB_PURE_NUM_BITS - 1);");
      Line ("const ALB_PURE_DEN_LIMIT: i64 = 0x7fffffff;");
      Line ("fn alb_pure_abs(v: i64) -> i64 { if v < 0 { -v } else { v } }");
      Line ("fn alb_pure_gcd(a: i64, b: i64) -> i64 {");
      Line ("  let mut x = alb_pure_abs(a); let mut y = alb_pure_abs(b);");
      Line ("  while y != 0 { let t = x % y; x = y; y = t; }");
      Line ("  if x == 0 { 1 } else { x }");
      Line ("}");
      Line ("fn alb_pure_pack(num: i64, den: i64) -> i64 {");
      Line ("  let mut n = num; let mut d = den;");
      Line ("  if d == 0 { return ALB_PURE_NUM_MOD; }");
      Line ("  if d < 0 { n = -n; d = -d; }");
      Line ("  if n == 0 { return ALB_PURE_NUM_MOD; }");
      Line ("  let mut g = alb_pure_gcd(n, d); n /= g; d /= g;");
      Line ("  let max_num = ALB_PURE_NUM_SIGN - 1;");
      Line ("  while (alb_pure_abs(n) > max_num || d > ALB_PURE_DEN_LIMIT) && d > 1 {");
      Line ("    n /= 2; d = alb_max(1, d / 2); g = alb_pure_gcd(n, d); n /= g; d /= g;");
      Line ("  }");
      Line ("  let enc = if n < 0 { ALB_PURE_NUM_MOD + n } else { n };");
      Line ("  d * ALB_PURE_NUM_MOD + enc");
      Line ("}");
      Line ("fn PURE(num: impl ToString, den: impl ToString) -> i64 { alb_pure_pack(alb_i64(num), alb_i64(den)) }");
      Line ("fn PURE_NUM(v: impl ToString) -> i64 {");
      Line ("  let pv = alb_i64(v); if pv < ALB_PURE_NUM_MOD { return pv; }");
      Line ("  let enc = pv % ALB_PURE_NUM_MOD; if enc >= ALB_PURE_NUM_SIGN { enc - ALB_PURE_NUM_MOD } else { enc }");
      Line ("}");
      Line ("fn PURE_DEN(v: impl ToString) -> i64 {");
      Line ("  let pv = alb_i64(v); if pv < ALB_PURE_NUM_MOD { return 1; }");
      Line ("  let den = pv / ALB_PURE_NUM_MOD; if den <= 0 { 1 } else { den }");
      Line ("}");
      Line ("fn PURE_ADD(a: impl ToString, b: impl ToString) -> i64 {");
      Line ("  let a = a.to_string(); let b = b.to_string();");
      Line ("  let an = PURE_NUM(&a); let ad = PURE_DEN(&a); let bn = PURE_NUM(&b); let bd = PURE_DEN(&b);");
      Line ("  let g = alb_pure_gcd(ad, bd); alb_pure_pack(an * (bd / g) + bn * (ad / g), ad * (bd / g))");
      Line ("}");
      Line ("fn PURE_SUB(a: impl ToString, b: impl ToString) -> i64 {");
      Line ("  let a = a.to_string(); let b = b.to_string();");
      Line ("  let an = PURE_NUM(&a); let ad = PURE_DEN(&a); let bn = PURE_NUM(&b); let bd = PURE_DEN(&b);");
      Line ("  let g = alb_pure_gcd(ad, bd); alb_pure_pack(an * (bd / g) - bn * (ad / g), ad * (bd / g))");
      Line ("}");
      Line ("fn PURE_MUL(a: impl ToString, b: impl ToString) -> i64 {");
      Line ("  let a = a.to_string(); let b = b.to_string();");
      Line ("  let mut an = PURE_NUM(&a); let mut ad = PURE_DEN(&a); let mut bn = PURE_NUM(&b); let mut bd = PURE_DEN(&b);");
      Line ("  let g1 = alb_pure_gcd(an, bd); an /= g1; bd /= g1; let g2 = alb_pure_gcd(bn, ad); bn /= g2; ad /= g2;");
      Line ("  alb_pure_pack(an * bn, ad * bd)");
      Line ("}");
      Line ("fn PURE_DIV(a: impl ToString, b: impl ToString) -> i64 {");
      Line ("  let a = a.to_string(); let b = b.to_string();");
      Line ("  let mut an = PURE_NUM(&a); let mut ad = PURE_DEN(&a); let mut bn = PURE_NUM(&b); let mut bd = PURE_DEN(&b);");
      Line ("  if bn == 0 { return ALB_PURE_NUM_MOD; }");
      Line ("  if bn < 0 { bn = -bn; bd = -bd; }");
      Line ("  let g1 = alb_pure_gcd(an, bn); an /= g1; bn /= g1; let g2 = alb_pure_gcd(bd, ad); bd /= g2; ad /= g2;");
      Line ("  alb_pure_pack(an * bd, ad * bn)");
      Line ("}");
      Line ("fn PURE_POW(a: impl ToString, b: impl ToString) -> i64 {");
      Line ("  let a = a.to_string(); let b = b.to_string();");
      Line ("  let exp_num = PURE_NUM(&b); let exp_den = PURE_DEN(&b);");
      Line ("  if exp_den != 1 {");
      Line ("    let av = PURE_NUM(&a) as f64 / PURE_DEN(&a) as f64;");
      Line ("    let bv = exp_num as f64 / exp_den as f64;");
      Line ("    return alb_pure_pack(alb_round(av.powf(bv) * 1_000_000.0), 1_000_000);");
      Line ("  }");
      Line ("  if exp_num == 0 { return PURE(1, 1); }");
      Line ("  let mut factor = a; let mut power = exp_num; let mut result = PURE(1, 1);");
      Line ("  if power < 0 {");
      Line ("    if PURE_NUM(&factor) == 0 { return PURE(0, 1); }");
      Line ("    factor = PURE_DIV(PURE(1, 1), &factor).to_string(); power = -power;");
      Line ("  }");
      Line ("  while power > 0 {");
      Line ("    if (power & 1) != 0 { result = PURE_MUL(result, &factor); }");
      Line ("    power /= 2; if power > 0 { factor = PURE_MUL(&factor, &factor).to_string(); }");
      Line ("  }");
      Line ("  result");
      Line ("}");
      Line ("fn albPowInt(base: i64, exp: i64) -> i64 {");
      Line ("  let mut result: i64 = 1; let mut factor = base; let mut power = exp;");
      Line ("  if power < 0 {");
      Line ("    if factor == 1 { return 1; }");
      Line ("    if factor == -1 { return if (power & 1) != 0 { -1 } else { 1 }; }");
      Line ("    return 0;");
      Line ("  }");
      Line ("  while power > 0 {");
      Line ("    if (power & 1) != 0 { result = result.wrapping_mul(factor); }");
      Line ("    power /= 2; if power > 0 { factor = factor.wrapping_mul(factor); }");
      Line ("  }");
      Line ("  result");
      Line ("}");
      Line ("fn ALB_POW(a: impl ToString, b: impl ToString) -> f64 {");
      Line ("  let base = alb_num_ts(a); let exp = alb_num_ts(b);");
      Line ("  if base.fract() == 0.0 && exp.fract() == 0.0 { return albPowInt(base as i64, exp as i64) as f64; }");
      Line ("  base.powf(exp)");
      Line ("}");
      Line ("fn albDiv(a: impl ToString, b: impl ToString) -> i64 { let dv = alb_num_ts(b); if dv == 0.0 { 0 } else { alb_trunc(alb_num_ts(a) / dv) } }");
      Line ("fn albMod(a: impl ToString, b: impl ToString) -> i64 { let dv = alb_i64(b); if dv == 0 { 0 } else { alb_i64(a) % dv } }");
      New_Line_Emit;
      Line ("fn LEFT(s: impl ToString, n: impl ToString) -> String { let t = s.to_string(); t.chars().take(alb_max(0, alb_i64(n)) as usize).collect() }");
      Line ("fn RIGHT(s: impl ToString, n: impl ToString) -> String {");
      Line ("  let t = s.to_string(); let c = alb_max(0, alb_i64(n)) as usize;");
      Line ("  if c >= t.chars().count() { t } else { t.chars().rev().take(c).collect::<String>().chars().rev().collect() }");
      Line ("}");
      Line ("fn MID(s: impl ToString, start_at: impl ToString, n: impl ToString) -> String {");
      Line ("  let t = s.to_string(); let start_ix = alb_max(0, alb_i64(start_at) - 1) as usize;");
      Line ("  t.chars().skip(start_ix).take(alb_max(0, alb_i64(n)) as usize).collect()");
      Line ("}");
      Line ("fn LEN(v: impl ToString) -> i64 { v.to_string().chars().count() as i64 }");
      Line ("fn CHR(v: impl ToString) -> String { char::from_u32((alb_i64(v) as u8) as u32).unwrap_or('\0').to_string() }");
      Line ("fn ASC(v: impl ToString) -> i64 { v.to_string().chars().next().map(|c| c as i64 & 255).unwrap_or(0) }");
      Line ("fn CONCAT(a: impl ToString, b: impl ToString) -> String { ALB_concat(a, b) }");
      Line ("fn PRINT_PURE(v: impl ToString) { ALB_PRINT(v); }");
      New_Line_Emit;
      Line ("fn ALB_GetTickCount() -> i64 {");
      Line ("  if ALB_SDL_READY.load(Ordering::Relaxed) { unsafe { SDL_GetTicks() as i64 } }");
      Line ("  else { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0) }");
      Line ("}");
      Line ("fn ALB_RND(limit: i64) -> i64 { let n = alb_max(1, limit); alb_floor(alb_random() * (n as f64)) }");
      Line ("fn RND(limit: i64) -> i64 { ALB_RND(limit) }");
      Line ("fn ALB_COLLIDE_RECT(ax: i64, ay: i64, aw: i64, ah: i64, bx: i64, by: i64, bw: i64, bh: i64) -> i64 {");
      Line ("  if ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by { 1 } else { 0 }");
      Line ("}");
      Line ("fn COLLIDE_RECT(ax: i64, ay: i64, aw: i64, ah: i64, bx: i64, by: i64, bw: i64, bh: i64) -> i64 { ALB_COLLIDE_RECT(ax, ay, aw, ah, bx, by, bw, bh) }");
      Line ("fn ALB_SIN(x: f64) -> f64 { x.sin() }");
      Line ("fn ALB_COS(x: f64) -> f64 { x.cos() }");
      Line ("fn ALB_SQRT(v: f64) -> f64 { if v >= 0.0 { v.sqrt() } else { 0.0 } }");
      Line ("fn ALB_EXP(v: i64) -> i64 { alb_trunc((v as f64).exp()) }");
      Line ("fn SIN(x: f64) -> f64 { ALB_SIN(x) }");
      Line ("fn COS(x: f64) -> f64 { ALB_COS(x) }");
      Line ("fn SQRT(v: f64) -> f64 { ALB_SQRT(v) }");
      Line ("fn EXP(v: i64) -> i64 { ALB_EXP(v) }");
      Line ("fn ALB_Delay(ms: i64) {");
      Line ("  let m = alb_max(0, ms);");
      Line ("  if ALB_SDL_READY.load(Ordering::Relaxed) { unsafe { SDL_Delay(m as u32); } }");
      Line ("  else { ALB_DELAY_UNTIL.with(|d| { *d.borrow_mut() = ALB_GetTickCount() + m; }); }");
      Line ("}");
      Line ("fn ALB_CEASE() { ALB_RUNNING.with(|r| { *r.borrow_mut() = false; }); ALB_ProgramShutdown(); }");
      New_Line_Emit;
      Line ("fn alb_sdl_renderer() -> *mut c_void { unsafe { ALB_SDL_RENDERER } }");
      Line ("fn alb_sdl_apply_color() {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let c = ALB_COLOR_CELL.with(|c| *c.borrow());");
      Line ("  let mut a = ((c >> 24) & 0xff) as u8; if a == 0 { a = 255; }");
      Line ("  unsafe { let _ = SDL_SetRenderDrawColor(rdr, ((c >> 16) & 0xff) as u8, ((c >> 8) & 0xff) as u8, (c & 0xff) as u8, a); }");
      Line ("}");
      Line ("fn alb_sdl_color_to_fcolor(c: u32) -> SDL_FColor {");
      Line ("  let mut a = ((c >> 24) & 0xff) as f32 / 255.0; if ((c >> 24) & 0xff) == 0 { a = 1.0; }");
      Line ("  SDL_FColor { r: ((c >> 16) & 0xff) as f32 / 255.0, g: ((c >> 8) & 0xff) as f32 / 255.0, b: (c & 0xff) as f32 / 255.0, a }");
      Line ("}");
      Line ("fn alb_sdl_read_u32(buf: &[u8], off: usize) -> u32 { u32::from_le_bytes([buf[off], buf[off+1], buf[off+2], buf[off+3]]) }");
      Line ("fn alb_sdl_read_f32(buf: &[u8], off: usize) -> f32 { f32::from_le_bytes([buf[off], buf[off+1], buf[off+2], buf[off+3]]) }");
      Line ("fn ALB_Poll_Events() -> bool {");
      Line ("  let mut ev = [0u8; 128];");
      Line ("  unsafe {");
      Line ("    while SDL_PollEvent(ev.as_mut_ptr()) {");
      Line ("      let ty = alb_sdl_read_u32(&ev, 0);");
      Line ("      if ty == SDL_EVENT_QUIT { ALB_RUNNING.with(|r| { *r.borrow_mut() = false; }); }");
      Line ("      else if ty == SDL_EVENT_KEY_DOWN || ty == SDL_EVENT_KEY_UP {");
      Line ("        let sc = alb_sdl_read_u32(&ev, 24) as usize;");
      Line ("        if sc < 512 { ALB_KEYS.with(|k| { k.borrow_mut()[sc] = if ty == SDL_EVENT_KEY_DOWN { 1 } else { 0 }; }); }");
      Line ("      } else if ty == SDL_EVENT_MOUSE_MOTION {");
      Line ("        ALB_MOUSE_X_CELL.with(|v| { *v.borrow_mut() = alb_sdl_read_f32(&ev, 28) as i64; });");
      Line ("        ALB_MOUSE_Y_CELL.with(|v| { *v.borrow_mut() = alb_sdl_read_f32(&ev, 32) as i64; });");
      Line ("      } else if ty == SDL_EVENT_MOUSE_BUTTON_DOWN || ty == SDL_EVENT_MOUSE_BUTTON_UP {");
      Line ("        let button = ev[24] as usize;");
      Line ("        if button >= 1 && button <= 8 {");
      Line ("          ALB_MOUSE_BTNS.with(|b| { b.borrow_mut()[button - 1] = if ty == SDL_EVENT_MOUSE_BUTTON_DOWN { 1 } else { 0 }; });");
      Line ("        }");
      Line ("      } else if ty == SDL_EVENT_MOUSE_WHEEL {");
      Line ("        ALB_MOUSE_WHEEL_CELL.with(|w| { *w.borrow_mut() += alb_sdl_read_f32(&ev, 28) as i64; });");
      Line ("      }");
      Line ("    }");
      Line ("  }");
      Line ("  ALB_RUNNING.with(|r| *r.borrow())");
      Line ("}");
      Line ("fn ALB_PRESENT() { let rdr = alb_sdl_renderer(); if !rdr.is_null() { unsafe { let _ = SDL_RenderPresent(rdr); } } }");
      Line ("fn ALB_SDL_Shutdown() {");
      Line ("  unsafe {");
      Line ("    if !ALB_SDL_RENDERER.is_null() { SDL_DestroyRenderer(ALB_SDL_RENDERER); ALB_SDL_RENDERER = ptr::null_mut(); }");
      Line ("    if !ALB_SDL_WINDOW.is_null() { SDL_DestroyWindow(ALB_SDL_WINDOW); ALB_SDL_WINDOW = ptr::null_mut(); }");
      Line ("    if ALB_SDL_READY.swap(false, Ordering::Relaxed) { SDL_Quit(); }");
      Line ("  }");
      Line ("}");
      Line ("fn ALB_CREATE_WINDOW(title: impl ToString, width: i64, height: i64) {");
      Line ("  let w = alb_max(1, width); let h = alb_max(1, height);");
      Line ("  ALB_BASE_W.with(|c| { *c.borrow_mut() = w; }); ALB_BASE_H.with(|c| { *c.borrow_mut() = h; });");
      Line ("  ALB_VIRT_W.with(|c| { *c.borrow_mut() = w; }); ALB_VIRT_H.with(|c| { *c.borrow_mut() = h; });");
      Line ("  ALB_WIN_W.with(|c| { *c.borrow_mut() = w; }); ALB_WIN_H.with(|c| { *c.borrow_mut() = h; });");
      Line ("  let ctitle = CString::new(title.to_string()).unwrap_or_else(|_| CString::new(""ALBR"").unwrap());");
      Line ("  unsafe {");
      Line ("    if ALB_SDL_WINDOW.is_null() {");
      Line ("      if !SDL_Init(SDL_INIT_VIDEO) {");
      Line ("        let e = SDL_GetError();");
      Line ("        let msg = if e.is_null() { ""SDL_Init failed"".to_string() } else { CStr::from_ptr(e).to_string_lossy().into_owned() };");
      Line ("        ALB_FATAL(format!(""SDL_Init: {}"", msg));");
      Line ("      }");
      Line ("      let mut win: *mut c_void = ptr::null_mut(); let mut rdr: *mut c_void = ptr::null_mut();");
      Line ("      if !SDL_CreateWindowAndRenderer(ctitle.as_ptr(), w as c_int, h as c_int, 0, &mut win, &mut rdr) {");
      Line ("        let e = SDL_GetError();");
      Line ("        let msg = if e.is_null() { ""SDL_CreateWindowAndRenderer failed"".to_string() } else { CStr::from_ptr(e).to_string_lossy().into_owned() };");
      Line ("        ALB_FATAL(format!(""SDL_CreateWindowAndRenderer: {}"", msg));");
      Line ("      }");
      Line ("      ALB_SDL_WINDOW = win; ALB_SDL_RENDERER = rdr; let _ = SDL_SetRenderVSync(rdr, 1);");
      Line ("      ALB_SDL_READY.store(true, Ordering::Relaxed);");
      Line ("    }");
      Line ("  }");
      Line ("  ALB_KEYS.with(|k| { k.borrow_mut().fill(0); });");
      Line ("}");
      Line ("fn ALB_SET_FULLSCREEN(_v: bool) {}");
      Line ("fn ALB_SET_RESIZABLE(_v: bool) {}");
      Line ("fn ALB_SET_STRETCHY(_v: bool) {}");
      Line ("fn ALB_PREPARE_FRAME() { alb_sdl_apply_color(); }");
      Line ("fn ALB_COLOR(v: i64) { ALB_COLOR_CELL.with(|c| { *c.borrow_mut() = v as u32; }); alb_sdl_apply_color(); }");
      Line ("fn ALB_CLEAR(v: i64) { ALB_COLOR(v); let rdr = alb_sdl_renderer(); if !rdr.is_null() { unsafe { let _ = SDL_RenderClear(rdr); } } }");
      Line ("fn ALB_DRAW_RECT(x: i64, y: i64, w: i64, h: i64) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()); let oy = ALB_ORIGIN_Y.with(|o| *o.borrow());");
      Line ("  let rect = SDL_FRect { x: (x + ox) as f32, y: (y + oy) as f32, w: w as f32, h: h as f32 };");
      Line ("  alb_sdl_apply_color(); unsafe { let _ = SDL_RenderRect(rdr, &rect); }");
      Line ("}");
      Line ("fn ALB_FILL_RECT(x: i64, y: i64, w: i64, h: i64) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()); let oy = ALB_ORIGIN_Y.with(|o| *o.borrow());");
      Line ("  let rect = SDL_FRect { x: (x + ox) as f32, y: (y + oy) as f32, w: w as f32, h: h as f32 };");
      Line ("  alb_sdl_apply_color(); unsafe { let _ = SDL_RenderFillRect(rdr, &rect); }");
      Line ("}");
      Line ("fn ALB_DRAW_LINE(x1: i64, y1: i64, x2: i64, y2: i64) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()) as f32; let oy = ALB_ORIGIN_Y.with(|o| *o.borrow()) as f32;");
      Line ("  alb_sdl_apply_color(); unsafe { let _ = SDL_RenderLine(rdr, x1 as f32 + ox, y1 as f32 + oy, x2 as f32 + ox, y2 as f32 + oy); }");
      Line ("}");
      Line ("fn ALB_DRAW_CIRCLE(x: i64, y: i64, r: i64) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()); let oy = ALB_ORIGIN_Y.with(|o| *o.borrow());");
      Line ("  let cx = (x + ox) as f32; let cy = (y + oy) as f32; let rad = alb_max(0, r) as i32;");
      Line ("  alb_sdl_apply_color();");
      Line ("  for yy in -rad..=rad { for xx in -rad..=rad {");
      Line ("    let d = xx * xx + yy * yy; let outer = rad * rad; let inner = (rad - 1) * (rad - 1);");
      Line ("    if d <= outer && d >= inner { unsafe { let _ = SDL_RenderPoint(rdr, cx + xx as f32, cy + yy as f32); } }");
      Line ("  } }");
      Line ("}");
      Line ("fn ALB_FILL_CIRCLE(x: i64, y: i64, r: i64) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()); let oy = ALB_ORIGIN_Y.with(|o| *o.borrow());");
      Line ("  let cx = (x + ox) as f32; let cy = (y + oy) as f32; let rad = alb_max(0, r) as i32;");
      Line ("  alb_sdl_apply_color();");
      Line ("  for yy in -rad..=rad { for xx in -rad..=rad {");
      Line ("    if xx * xx + yy * yy <= rad * rad { unsafe { let _ = SDL_RenderPoint(rdr, cx + xx as f32, cy + yy as f32); } }");
      Line ("  } }");
      Line ("}");
      Line ("fn ALB_DRAW_TRIANGLE(x1: i64, y1: i64, x2: i64, y2: i64, x3: i64, y3: i64) {");
      Line ("  ALB_DRAW_LINE(x1, y1, x2, y2); ALB_DRAW_LINE(x2, y2, x3, y3); ALB_DRAW_LINE(x3, y3, x1, y1);");
      Line ("}");
      Line ("fn ALB_FILL_TRIANGLE(x1: i64, y1: i64, x2: i64, y2: i64, x3: i64, y3: i64) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()) as f32; let oy = ALB_ORIGIN_Y.with(|o| *o.borrow()) as f32;");
      Line ("  let c = alb_sdl_color_to_fcolor(ALB_COLOR_CELL.with(|c| *c.borrow()));");
      Line ("  let verts = [");
      Line ("    SDL_Vertex { position: SDL_FPoint { x: x1 as f32 + ox, y: y1 as f32 + oy }, color: c, tex_coord: SDL_FPoint { x: 0.0, y: 0.0 } },");
      Line ("    SDL_Vertex { position: SDL_FPoint { x: x2 as f32 + ox, y: y2 as f32 + oy }, color: c, tex_coord: SDL_FPoint { x: 0.0, y: 0.0 } },");
      Line ("    SDL_Vertex { position: SDL_FPoint { x: x3 as f32 + ox, y: y3 as f32 + oy }, color: c, tex_coord: SDL_FPoint { x: 0.0, y: 0.0 } },");
      Line ("  ];");
      Line ("  unsafe { let _ = SDL_RenderGeometry(rdr, ptr::null_mut(), verts.as_ptr(), 3, ptr::null(), 0); }");
      Line ("}");
      Line ("fn ALB_PLOT(x: i64, y: i64) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()) as f32; let oy = ALB_ORIGIN_Y.with(|o| *o.borrow()) as f32;");
      Line ("  alb_sdl_apply_color(); unsafe { let _ = SDL_RenderPoint(rdr, x as f32 + ox, y as f32 + oy); }");
      Line ("}");
      -- 8x8 terminal font (ASCII 32-127), same glyph table as alb_sdl3 / emit_native_c
      Line ("static ALB_FONT8X8: [[u8; 8]; 96] = [");
      Line ("  [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00], [0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00],");
      Line ("  [0x6C,0x6C,0x6C,0x00,0x00,0x00,0x00,0x00], [0x6C,0x6C,0xFE,0x6C,0xFE,0x6C,0x6C,0x00],");
      Line ("  [0x18,0x3E,0x60,0x3C,0x06,0x7C,0x18,0x00], [0x00,0xC6,0xCC,0x18,0x30,0x66,0xC6,0x00],");
      Line ("  [0x38,0x6C,0x6C,0x38,0x6D,0x66,0x3B,0x00], [0x0C,0x18,0x30,0x00,0x00,0x00,0x00,0x00],");
      Line ("  [0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00], [0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00],");
      Line ("  [0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00], [0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00],");
      Line ("  [0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30], [0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00],");
      Line ("  [0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00], [0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00],");
      Line ("  [0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00], [0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00],");
      Line ("  [0x3C,0x66,0x06,0x0C,0x30,0x60,0x7E,0x00], [0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00],");
      Line ("  [0x0C,0x1C,0x3C,0x6C,0xFE,0x0C,0x0C,0x00], [0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00],");
      Line ("  [0x3C,0x66,0x60,0x7C,0x66,0x66,0x3C,0x00], [0x7E,0x66,0x06,0x0C,0x18,0x18,0x18,0x00],");
      Line ("  [0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00], [0x3C,0x66,0x66,0x3E,0x06,0x66,0x3C,0x00],");
      Line ("  [0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00], [0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30],");
      Line ("  [0x0C,0x18,0x30,0x60,0x30,0x18,0x0C,0x00], [0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00],");
      Line ("  [0x30,0x18,0x0C,0x06,0x0C,0x18,0x30,0x00], [0x3C,0x66,0x06,0x18,0x18,0x00,0x18,0x00],");
      Line ("  [0x3C,0x66,0x6E,0x6E,0x60,0x66,0x3C,0x00], [0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00],");
      Line ("  [0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00], [0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00],");
      Line ("  [0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00], [0x7E,0x60,0x60,0x78,0x60,0x60,0x7E,0x00],");
      Line ("  [0x7E,0x60,0x60,0x78,0x60,0x60,0x60,0x00], [0x3C,0x66,0x60,0x6E,0x66,0x66,0x3E,0x00],");
      Line ("  [0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00], [0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00],");
      Line ("  [0x1E,0x0C,0x0C,0x0C,0x0C,0x6C,0x38,0x00], [0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00],");
      Line ("  [0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00], [0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00],");
      Line ("  [0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00], [0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00],");
      Line ("  [0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00], [0x3C,0x66,0x66,0x66,0x6A,0x6C,0x36,0x00],");
      Line ("  [0x7C,0x66,0x66,0x7C,0x6C,0x66,0x66,0x00], [0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00],");
      Line ("  [0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00], [0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00],");
      Line ("  [0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00], [0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00],");
      Line ("  [0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00], [0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00],");
      Line ("  [0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00], [0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00],");
      Line ("  [0x80,0xC0,0x60,0x30,0x18,0x0C,0x06,0x00], [0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00],");
      Line ("  [0x18,0x3C,0x66,0x00,0x00,0x00,0x00,0x00], [0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0x00],");
      Line ("  [0x30,0x30,0x18,0x00,0x00,0x00,0x00,0x00], [0x00,0x00,0x3C,0x06,0x3E,0x66,0x3E,0x00],");
      Line ("  [0x60,0x60,0x7C,0x66,0x66,0x66,0x7C,0x00], [0x00,0x00,0x3C,0x60,0x60,0x60,0x3C,0x00],");
      Line ("  [0x06,0x06,0x3E,0x66,0x66,0x66,0x3E,0x00], [0x00,0x00,0x3C,0x66,0x7E,0x60,0x3C,0x00],");
      Line ("  [0x1C,0x30,0x7C,0x30,0x30,0x30,0x30,0x00], [0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x3C],");
      Line ("  [0x60,0x60,0x7C,0x66,0x66,0x66,0x66,0x00], [0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00],");
      Line ("  [0x0C,0x00,0x0C,0x0C,0x0C,0x0C,0x0C,0x38], [0x60,0x60,0x66,0x6C,0x78,0x6C,0x66,0x00],");
      Line ("  [0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00], [0x00,0x00,0x76,0x7F,0x6B,0x6B,0x6B,0x00],");
      Line ("  [0x00,0x00,0x7C,0x66,0x66,0x66,0x66,0x00], [0x00,0x00,0x3C,0x66,0x66,0x66,0x3C,0x00],");
      Line ("  [0x00,0x00,0x7C,0x66,0x66,0x7C,0x60,0x60], [0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x06],");
      Line ("  [0x00,0x00,0x7C,0x66,0x60,0x60,0x60,0x00], [0x00,0x00,0x3E,0x60,0x3C,0x06,0x3C,0x00],");
      Line ("  [0x30,0x30,0x7C,0x30,0x30,0x34,0x18,0x00], [0x00,0x00,0x66,0x66,0x66,0x66,0x3E,0x00],");
      Line ("  [0x00,0x00,0x66,0x66,0x66,0x3C,0x18,0x00], [0x00,0x00,0x63,0x6B,0x6B,0x7F,0x36,0x00],");
      Line ("  [0x00,0x00,0x66,0x3C,0x18,0x3C,0x66,0x00], [0x00,0x00,0x66,0x66,0x66,0x3E,0x06,0x3C],");
      Line ("  [0x00,0x00,0x7E,0x0C,0x18,0x30,0x7E,0x00], [0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00],");
      Line ("  [0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18], [0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00],");
      Line ("  [0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00], [0x00,0x10,0x38,0x54,0x10,0x10,0x10,0x00]");
      Line ("];");
      Line ("fn ALB_DRAW_TEXT(x: i64, y: i64, t: impl ToString) {");
      Line ("  let rdr = alb_sdl_renderer(); if rdr.is_null() { return; }");
      Line ("  let ox = ALB_ORIGIN_X.with(|o| *o.borrow()) as f32;");
      Line ("  let oy = ALB_ORIGIN_Y.with(|o| *o.borrow()) as f32;");
      Line ("  let s = t.to_string();");
      Line ("  let x0 = x as f32 + ox;");
      Line ("  let mut cursor_x = x0;");
      Line ("  let mut cursor_y = y as f32 + oy;");
      Line ("  let mut pts = [SDL_FPoint { x: 0.0, y: 0.0 }; 512];");
      Line ("  let mut npts: usize = 0;");
      Line ("  alb_sdl_apply_color();");
      Line ("  for ch in s.bytes() {");
      Line ("    if ch == b'\n' {");
      Line ("      if npts > 0 { unsafe { let _ = SDL_RenderPoints(rdr, pts.as_ptr(), npts as c_int); } npts = 0; }");
      Line ("      cursor_x = x0; cursor_y += 10.0; continue;");
      Line ("    }");
      Line ("    if ch < 32 || ch > 127 { cursor_x += 8.0; continue; }");
      Line ("    let char_idx = (ch - 32) as usize;");
      Line ("    for row in 0..8 {");
      Line ("      let row_data = ALB_FONT8X8[char_idx][row];");
      Line ("      if row_data == 0 { continue; }");
      Line ("      for col in 0..8 {");
      Line ("        if (row_data & (0x80u8 >> col)) != 0 {");
      Line ("          if npts >= pts.len() { unsafe { let _ = SDL_RenderPoints(rdr, pts.as_ptr(), npts as c_int); } npts = 0; }");
      Line ("          pts[npts] = SDL_FPoint { x: cursor_x + col as f32, y: cursor_y + row as f32 };");
      Line ("          npts += 1;");
      Line ("        }");
      Line ("      }");
      Line ("    }");
      Line ("    cursor_x += 8.0;");
      Line ("  }");
      Line ("  if npts > 0 { unsafe { let _ = SDL_RenderPoints(rdr, pts.as_ptr(), npts as c_int); } }");
      Line ("}");
      Line ("fn ALB_PAINTER_MESH(vx: &str, vy: &str, vz: &str, p1: &str, p2: &str, p3: &str, col: &str,");
      Line ("  vc: i64, fc: i64, yaw: i64, pitch: i64, cam_z: i64, scale: i64, cx: i64, cy: i64, seed_max: i64) {");
      Line ("  let mut vcount = vc; let mut fcount = fc;");
      Line ("  if vcount < 1 || fcount < 1 { return; }");
      Line ("  if vcount > 256 { vcount = 256; }");
      Line ("  if fcount > 256 { fcount = 256; }");
      Line ("  let (av_x, av_y, av_z, af_p1, af_p2, af_p3, af_col) = ALB_GARR.with(|m| {");
      Line ("    let map = m.borrow();");
      Line ("    let take = |n: &str| map.get(n).cloned().unwrap_or_default();");
      Line ("    (take(vx), take(vy), take(vz), take(p1), take(p2), take(p3), take(col))");
      Line ("  });");
      Line ("  let mut yd = yaw % 360; if yd < 0 { yd += 360; }");
      Line ("  let mut pd = pitch % 360; if pd < 0 { pd += 360; }");
      Line ("  let yaw_r = (yd as f64) * (std::f64::consts::PI / 180.0);");
      Line ("  let pitch_r = (pd as f64) * (std::f64::consts::PI / 180.0);");
      Line ("  let ysn = yaw_r.sin(); let ycn = yaw_r.cos();");
      Line ("  let psn = pitch_r.sin(); let pcn = pitch_r.cos();");
      Line ("  let mut proj_x = vec![0i64; vcount as usize];");
      Line ("  let mut proj_y = vec![0i64; vcount as usize];");
      Line ("  let mut proj_z = vec![0i64; vcount as usize];");
      Line ("  for i in 0..vcount as usize {");
      Line ("    let x = *av_x.get(i).unwrap_or(&0) as f64;");
      Line ("    let y = *av_y.get(i).unwrap_or(&0) as f64;");
      Line ("    let z = *av_z.get(i).unwrap_or(&0) as f64;");
      Line ("    let tx = x * ycn - z * ysn;");
      Line ("    let tz = x * ysn + z * ycn;");
      Line ("    let ty = y;");
      Line ("    let rx = tx;");
      Line ("    let rz = ty * psn + tz * pcn;");
      Line ("    let ry = ty * pcn - tz * psn;");
      Line ("    proj_z[i] = rz as i64;");
      Line ("    let mut z_depth = (rz as i64) + cam_z;");
      Line ("    if z_depth < 1 { z_depth = 1; }");
      Line ("    proj_x[i] = cx + ((rx * (scale as f64)) / (z_depth as f64)) as i64;");
      Line ("    proj_y[i] = cy + ((ry * (scale as f64)) / (z_depth as f64)) as i64;");
      Line ("  }");
      Line ("  let mut faces: Vec<(i64, usize)> = Vec::with_capacity(fcount as usize);");
      Line ("  for f in 0..fcount as usize {");
      Line ("    let mut v1 = (*af_p1.get(f).unwrap_or(&1) - 1) as i64;");
      Line ("    let mut v2 = (*af_p2.get(f).unwrap_or(&1) - 1) as i64;");
      Line ("    let mut v3 = (*af_p3.get(f).unwrap_or(&1) - 1) as i64;");
      Line ("    if v1 < 0 { v1 = 0; } if v1 >= vcount { v1 = vcount - 1; }");
      Line ("    if v2 < 0 { v2 = 0; } if v2 >= vcount { v2 = vcount - 1; }");
      Line ("    if v3 < 0 { v3 = 0; } if v3 >= vcount { v3 = vcount - 1; }");
      Line ("    let avg_z = (proj_z[v1 as usize] + proj_z[v2 as usize] + proj_z[v3 as usize]) / 3;");
      Line ("    faces.push((avg_z, f));");
      Line ("  }");
      Line ("  faces.sort_by_key(|&(z, _)| z);");
      Line ("  for &(avg_z, real_id) in &faces {");
      Line ("    let mut v1 = (*af_p1.get(real_id).unwrap_or(&1) - 1) as i64;");
      Line ("    let mut v2 = (*af_p2.get(real_id).unwrap_or(&1) - 1) as i64;");
      Line ("    let mut v3 = (*af_p3.get(real_id).unwrap_or(&1) - 1) as i64;");
      Line ("    if v1 < 0 { v1 = 0; } if v1 >= vcount { v1 = vcount - 1; }");
      Line ("    if v2 < 0 { v2 = 0; } if v2 >= vcount { v2 = vcount - 1; }");
      Line ("    if v3 < 0 { v3 = 0; } if v3 >= vcount { v3 = vcount - 1; }");
      Line ("    let face_col = *af_col.get(real_id).unwrap_or(&0);");
      Line ("    let px1 = proj_x[v1 as usize]; let py1 = proj_y[v1 as usize];");
      Line ("    let px2 = proj_x[v2 as usize]; let py2 = proj_y[v2 as usize];");
      Line ("    let px3 = proj_x[v3 as usize]; let py3 = proj_y[v3 as usize];");
      Line ("    ALB_COLOR(face_col);");
      Line ("    ALB_FILL_TRIANGLE(px1, py1, px2, py2, px3, py3);");
      Line ("    if seed_max > 0 && ((real_id as i64) + 1) <= seed_max && avg_z < 10 {");
      Line ("      let scx = (px1 + px2 + px3) / 3;");
      Line ("      let scy = (py1 + py2 + py3) / 3;");
      Line ("      ALB_COLOR(0xFFDD00);");
      Line ("      ALB_FILL_RECT(scx - 1, scy - 1, 2, 3);");
      Line ("    }");
      Line ("  }");
      Line ("}");
      Line ("fn ALB_SET_ALPHA(_channel: i64, _value: i64) {}");
      Line ("fn ALB_SET_CLIP(_x: i64, _y: i64, _w: i64, _h: i64) {}");
      Line ("fn ALB_SET_ORIGIN(x: i64, y: i64) { ALB_ORIGIN_X.with(|o| { *o.borrow_mut() = x; }); ALB_ORIGIN_Y.with(|o| { *o.borrow_mut() = y; }); }");
      Line ("fn ALB_READ_PIXEL(_x: i64, _y: i64) -> i64 { 0 }");
      Line ("fn ALB_KEY(code: i64) -> i64 {");
      Line ("  ALB_KEYS.with(|k| {");
      Line ("    let keys = k.borrow(); let c = code as usize;");
      Line ("    if c >= keys.len() { return 0; }");
      Line ("    let mut v = keys[c] as i64;");
      Line ("    if c == 4 { v = (keys[4] | keys[80]) as i64; }");
      Line ("    else if c == 7 { v = (keys[7] | keys[79]) as i64; }");
      Line ("    else if c == 22 { v = (keys[22] | keys[81]) as i64; }");
      Line ("    else if c == 26 { v = (keys[26] | keys[82]) as i64; }");
      Line ("    else if c == 44 { v = (keys[44] | keys[40]) as i64; }");
      Line ("    if v != 0 { 1 } else { 0 }");
      Line ("  })");
      Line ("}");
      Line ("fn ALB_MOUSE_X() -> i64 { ALB_MOUSE_X_CELL.with(|v| *v.borrow()) }");
      Line ("fn ALB_MOUSE_Y() -> i64 { ALB_MOUSE_Y_CELL.with(|v| *v.borrow()) }");
      Line ("fn ALB_MOUSE_WHEEL() -> i64 { ALB_MOUSE_WHEEL_CELL.with(|v| *v.borrow()) }");
      Line ("fn ALB_VMOUSE_X() -> i64 { ALB_MOUSE_X() }");
      Line ("fn ALB_VMOUSE_Y() -> i64 { ALB_MOUSE_Y() }");
      Line ("fn ALB_MOUSE_CLICK(button: i64) -> i64 { ALB_MOUSE_BTNS.with(|b| { let bt = b.borrow(); let i = button as usize; if i < bt.len() { bt[i] as i64 } else { 0 } }) }");
      Line ("fn ALB_SCREEN_WIDTH() -> i64 { ALB_WIN_W.with(|v| *v.borrow()) }");
      Line ("fn ALB_SCREEN_HEIGHT() -> i64 { ALB_WIN_H.with(|v| *v.borrow()) }");
      Line ("fn ALB_VIRTUAL_WIDTH() -> i64 { ALB_VIRT_W.with(|v| *v.borrow()) }");
      Line ("fn ALB_VIRTUAL_HEIGHT() -> i64 { ALB_VIRT_H.with(|v| *v.borrow()) }");
      Line ("fn ALB_PLAY_SOUND(_path: impl ToString) {}");
      Line ("fn ALB_PLAY_MUSIC(_mml: impl ToString) {}");
      Line ("fn ALB_PLAY_MUSIC_FROM(_path: impl ToString) {}");
      Line ("fn ALB_MSG_BOX(msg: impl ToString, title: impl ToString) { ALB_PRINT(format!(""{}\n{}"", title.to_string(), msg.to_string())); }");
      Line ("fn ALB_SET_FONT(_font: AlbrVal) {}");
      Line ("fn ALB_DEFINE_SYSTEM_FONT(name: impl ToString, size: i64, weight: impl ToString, _aa: bool, _cs: i64, _ce: i64) -> AlbrVal { AlbrVal::Str(format!(""systemFont:{}:{}:{}"", name.to_string(), size, weight.to_string())) }");
      Line ("fn ALB_DEFINE_BITMAP_FONT(name: impl ToString, _src: impl ToString, _fmt: impl ToString, _gw: i64, _gh: i64, _fc: i64, _sp: i64) -> AlbrVal { AlbrVal::Str(format!(""bitmapFont:{}"", name.to_string())) }");
      New_Line_Emit;
      Line ("fn ALB_PEEK(addr: i64) -> i64 { ALB_VAS.with(|v| { let vas = v.borrow(); let a = addr as usize; if a < vas.len() { vas[a] as i64 } else { 0 } }) }");
      Line ("fn ALB_POKE(addr: i64, value: impl ToString) { ALB_VAS.with(|v| { let mut vas = v.borrow_mut(); let a = addr as usize; if a < vas.len() { vas[a] = alb_i64(value) as i32; } }); }");
      Line ("fn ALB_DEREF(addr: i64) -> i64 { ALB_PEEK(addr) }");
      New_Line_Emit;
      Line ("fn alb_temp_past(history: &[i64], head: i64, hist: i64) -> i64 {");
      Line ("  if history.is_empty() || hist <= 0 { return 0; }");
      Line ("  history.get((((head + hist - 1) % hist) as usize)).copied().unwrap_or(0)");
      Line ("}");
      Line ("fn alb_temp_future(history: &[i64], head: i64, hist: i64) -> i64 {");
      Line ("  if history.is_empty() || hist <= 0 { return 0; }");
      Line ("  history.get((((head + 1) % hist) as usize)).copied().unwrap_or(0)");
      Line ("}");
      Line ("fn alb_temp_record(history: &mut Vec<i64>, head: &mut i64, value: i64, hist: i64) {");
      Line ("  let h = alb_max(1, hist) as usize; if history.len() < h { history.resize(h, 0); }");
      Line ("  history[(*head as usize) % h] = value; *head = (*head + 1) % (h as i64);");
      Line ("}");
      Line ("fn alb_slide_rotate_left(arr: &mut [i64]) { if arr.len() < 2 { return; } let first = arr[0]; for i in 0..arr.len()-1 { arr[i] = arr[i+1]; } arr[arr.len()-1] = first; }");
      Line ("fn alb_slide_rotate_right(arr: &mut [i64]) { if arr.len() < 2 { return; } let last = arr[arr.len()-1]; for i in (1..arr.len()).rev() { arr[i] = arr[i-1]; } arr[0] = last; }");
      New_Line_Emit;
      Line ("fn alb_gc_dec(handle: i64) { ALB_GC_REFS.with(|r| { let mut refs = r.borrow_mut(); let h = handle as usize; if h > 0 && h < refs.len() && refs[h] > 0 { refs[h] -= 1; } }); }");
      Line ("fn alb_gc_clear_children(parent: usize) {");
      Line ("  ALB_GC_CA.with(|a| ALB_GC_CB.with(|b| ALB_GC_CC.with(|c| ALB_GC_CD.with(|d| {");
      Line ("    let mut ca = a.borrow_mut(); let mut cb = b.borrow_mut(); let mut cc = c.borrow_mut(); let mut cd = d.borrow_mut();");
      Line ("    if ca[parent] != 0 { alb_gc_dec(ca[parent] as i64); } if cb[parent] != 0 { alb_gc_dec(cb[parent] as i64); }");
      Line ("    if cc[parent] != 0 { alb_gc_dec(cc[parent] as i64); } if cd[parent] != 0 { alb_gc_dec(cd[parent] as i64); }");
      Line ("    ca[parent] = 0; cb[parent] = 0; cc[parent] = 0; cd[parent] = 0;");
      Line ("  }))));");
      Line ("}");
      Line ("fn ALB_CLAIM() -> i64 {");
      Line ("  ALB_GC_ALIVE.with(|alive| ALB_GC_REFS.with(|refs| {");
      Line ("    let mut alive = alive.borrow_mut(); let mut refs = refs.borrow_mut();");
      Line ("    for i in 1..alive.len() { if alive[i] == 0 { alive[i] = 1; refs[i] = 1; alb_gc_clear_children(i); return i as i64; } }");
      Line ("    0");
      Line ("  }))");
      Line ("}");
      Line ("fn ALB_BIND(parent: i64, child1: i64, child2: i64, child3: i64, child4: i64) {");
      Line ("  let p = parent as usize;");
      Line ("  let alive_ok = ALB_GC_ALIVE.with(|alive| { let a = alive.borrow(); p > 0 && p < a.len() && a[p] != 0 });");
      Line ("  if !alive_ok { return; }");
      Line ("  alb_gc_clear_children(p);");
      Line ("  ALB_GC_REFS.with(|refs| {");
      Line ("    let mut refs = refs.borrow_mut();");
      Line ("    ALB_GC_CA.with(|a| { if child1 > 0 { a.borrow_mut()[p] = child1 as u16; refs[child1 as usize] = refs[child1 as usize].saturating_add(1); } });");
      Line ("    ALB_GC_CB.with(|b| { if child2 > 0 { b.borrow_mut()[p] = child2 as u16; refs[child2 as usize] = refs[child2 as usize].saturating_add(1); } });");
      Line ("    ALB_GC_CC.with(|c| { if child3 > 0 { c.borrow_mut()[p] = child3 as u16; refs[child3 as usize] = refs[child3 as usize].saturating_add(1); } });");
      Line ("    ALB_GC_CD.with(|d| { if child4 > 0 { d.borrow_mut()[p] = child4 as u16; refs[child4 as usize] = refs[child4 as usize].saturating_add(1); } });");
      Line ("  });");
      Line ("}");
      Line ("fn ALB_DROP(handle: i64) { alb_gc_dec(handle); }");
      Line ("fn ALB_SWEEP(chunk: i64) {");
      Line ("  let mut budget = if chunk > 0 { chunk } else { 1024 }; let mut changed = true;");
      Line ("  while changed && budget > 0 {");
      Line ("    changed = false;");
      Line ("    ALB_GC_ALIVE.with(|alive| ALB_GC_REFS.with(|refs| {");
      Line ("      let mut alive = alive.borrow_mut(); let refs = refs.borrow();");
      Line ("      for i in 1..alive.len() { if budget <= 0 { break; } if alive[i] != 0 && refs[i] == 0 { alive[i] = 0; alb_gc_clear_children(i); changed = true; budget -= 1; } }");
      Line ("    }));");
      Line ("  }");
      Line ("}");
      New_Line_Emit;
      Line ("fn ALB_KNOWS_SET(key: impl ToString, value: impl ToString) {");
      Line ("  let k = key.to_string(); let val = value.to_string();");
      Line ("  ALB_FACT_LIVE.with(|live| ALB_FACT_KEY.with(|keys| ALB_FACT_VAL.with(|vals| {");
      Line ("    let mut live = live.borrow_mut(); let mut keys = keys.borrow_mut(); let mut vals = vals.borrow_mut();");
      Line ("    for i in 0..live.len() { if live[i] != 0 && keys[i] == k { vals[i] = val.clone(); return; } }");
      Line ("    for i in 0..live.len() { if live[i] == 0 { live[i] = 1; keys[i] = k; vals[i] = val; return; } }");
      Line ("  })));");
      Line ("}");
      Line ("fn ALB_KNOWS_GET(key: impl ToString) -> String {");
      Line ("  let k = key.to_string();");
      Line ("  ALB_FACT_LIVE.with(|live| ALB_FACT_KEY.with(|keys| ALB_FACT_VAL.with(|vals| {");
      Line ("    let live = live.borrow(); let keys = keys.borrow(); let vals = vals.borrow();");
      Line ("    for i in 0..live.len() { if live[i] != 0 && keys[i] == k { return vals[i].clone(); } }");
      Line ("    ""0"".to_string()");
      Line ("  })))");
      Line ("}");
      Line ("fn ALB_KNOWS_HAS(key: impl ToString) -> i64 {");
      Line ("  let k = key.to_string();");
      Line ("  ALB_FACT_LIVE.with(|live| ALB_FACT_KEY.with(|keys| {");
      Line ("    let live = live.borrow(); let keys = keys.borrow();");
      Line ("    for i in 0..live.len() { if live[i] != 0 && keys[i] == k { return 1; } } 0");
      Line ("  }))");
      Line ("}");
      Line ("fn ALB_NOTIFY_KNOWS_CHANGE(_pred: i64, _a1: i64, _a2: i64, _a3: i64, _a4: i64) {}");
      Line ("fn ALB_REL_FACT_MATCH(slot: usize, pred: i64, arity: i64, a1: i64, a2: i64, a3: i64, a4: i64) -> bool {");
      Line ("  ALB_REL_LIVE.with(|live| {");
      Line ("    if slot >= live.borrow().len() || live.borrow()[slot] == 0 { return false; }");
      Line ("    ALB_REL_PRED.with(|p| ALB_REL_ARITY.with(|ar| ALB_REL_ARG1.with(|x1| ALB_REL_ARG2.with(|x2| ALB_REL_ARG3.with(|x3| ALB_REL_ARG4.with(|x4| {");
      Line ("      p.borrow()[slot] as i64 == pred && ar.borrow()[slot] as i64 == arity");
      Line ("        && x1.borrow()[slot] as i64 == a1 && x2.borrow()[slot] as i64 == a2 && x3.borrow()[slot] as i64 == a3 && x4.borrow()[slot] as i64 == a4");
      Line ("    }))))))");
      Line ("  })");
      Line ("}");
      Line ("fn ALB_REL_FACT_HAS(pred: i64, arity: i64, a1: i64, a2: i64, a3: i64, a4: i64) -> i64 {");
      Line ("  for i in 0..1024 { if ALB_REL_FACT_MATCH(i, pred, arity, a1, a2, a3, a4) { return 1; } } 0");
      Line ("}");
      Line ("fn ALB_REL_RULE_HAS(pred: i64, arg1: i64) -> i64 {");
      Line ("  let rc = ALB_RULE_COUNT.with(|c| *c.borrow());");
      Line ("  for r in 0..rc {");
      Line ("    if ALB_RULE_HEAD.with(|h| h.borrow()[r]) as i64 != pred { continue; }");
      Line ("    let mut ok = true; let base = r * 8; let blen = ALB_RULE_BODY_LEN.with(|b| b.borrow()[r]) as usize;");
      Line ("    for j in 0..blen {");
      Line ("      let ix = base + j; let body_pred = ALB_RULE_BODY_PRED.with(|p| p.borrow()[ix]) as i64;");
      Line ("      let mode = ALB_RULE_BODY_MODE.with(|m| m.borrow()[ix]);");
      Line ("      let want = if mode == 1 { arg1 } else { ALB_RULE_BODY_CONST.with(|c| c.borrow()[ix]) as i64 };");
      Line ("      if ALB_REL_FACT_HAS(body_pred, 1, want, 0, 0, 0) == 0 { ok = false; break; }");
      Line ("    }");
      Line ("    if ok { return 1; }");
      Line ("  }");
      Line ("  0");
      Line ("}");
      Line ("fn ALB_REL_HAS(pred: i64, arity: i64, a1: i64, a2: i64, a3: i64, a4: i64) -> i64 {");
      Line ("  if ALB_REL_FACT_HAS(pred, arity, a1, a2, a3, a4) != 0 { return 1; }");
      Line ("  if arity == 1 { return ALB_REL_RULE_HAS(pred, a1); } 0");
      Line ("}");
      Line ("fn ALB_REL_SET(pred: i64, arity: i64, a1: i64, a2: i64, a3: i64, a4: i64, value: i64) {");
      Line ("  for i in 0..1024 {");
      Line ("    if ALB_REL_FACT_MATCH(i, pred, arity, a1, a2, a3, a4) {");
      Line ("      ALB_REL_VALUE.with(|v| v.borrow_mut()[i] = value as i32); ALB_NOTIFY_KNOWS_CHANGE(pred, a1, a2, a3, a4); return;");
      Line ("    }");
      Line ("  }");
      Line ("  for i in 0..1024 {");
      Line ("    if ALB_REL_LIVE.with(|l| l.borrow()[i]) == 0 {");
      Line ("      ALB_REL_LIVE.with(|l| l.borrow_mut()[i] = 1);");
      Line ("      ALB_REL_PRED.with(|p| p.borrow_mut()[i] = pred as u16);");
      Line ("      ALB_REL_ARITY.with(|a| a.borrow_mut()[i] = arity as u8);");
      Line ("      ALB_REL_ARG1.with(|a| a.borrow_mut()[i] = a1 as i32);");
      Line ("      ALB_REL_ARG2.with(|a| a.borrow_mut()[i] = a2 as i32);");
      Line ("      ALB_REL_ARG3.with(|a| a.borrow_mut()[i] = a3 as i32);");
      Line ("      ALB_REL_ARG4.with(|a| a.borrow_mut()[i] = a4 as i32);");
      Line ("      ALB_REL_VALUE.with(|v| v.borrow_mut()[i] = value as i32);");
      Line ("      ALB_NOTIFY_KNOWS_CHANGE(pred, a1, a2, a3, a4); return;");
      Line ("    }");
      Line ("  }");
      Line ("}");
      Line ("fn ALB_REL_RETRACT(pred: i64, arity: i64, a1: i64, a2: i64, a3: i64, a4: i64) {");
      Line ("  for i in 0..1024 {");
      Line ("    if ALB_REL_FACT_MATCH(i, pred, arity, a1, a2, a3, a4) {");
      Line ("      ALB_REL_LIVE.with(|l| l.borrow_mut()[i] = 0);");
      Line ("      ALB_REL_PRED.with(|p| p.borrow_mut()[i] = 0); ALB_REL_ARITY.with(|a| a.borrow_mut()[i] = 0);");
      Line ("      ALB_REL_ARG1.with(|a| a.borrow_mut()[i] = 0); ALB_REL_ARG2.with(|a| a.borrow_mut()[i] = 0);");
      Line ("      ALB_REL_ARG3.with(|a| a.borrow_mut()[i] = 0); ALB_REL_ARG4.with(|a| a.borrow_mut()[i] = 0);");
      Line ("      ALB_REL_VALUE.with(|v| v.borrow_mut()[i] = 0); ALB_NOTIFY_KNOWS_CHANGE(pred, a1, a2, a3, a4);");
      Line ("    }");
      Line ("  }");
      Line ("}");
      Line ("fn ALB_REL_GET_VALUE(pred: i64, arity: i64, a1: i64, a2: i64, a3: i64, a4: i64) -> i64 {");
      Line ("  for i in 0..1024 { if ALB_REL_FACT_MATCH(i, pred, arity, a1, a2, a3, a4) { return ALB_REL_VALUE.with(|v| v.borrow()[i]) as i64; } }");
      Line ("  ALB_REL_HAS(pred, arity, a1, a2, a3, a4)");
      Line ("}");
      Line ("fn ALB_REL_FIND1(pred: i64) -> i64 {");
      Line ("  for i in 0..1024 {");
      Line ("    if ALB_REL_LIVE.with(|l| l.borrow()[i]) != 0 && ALB_REL_PRED.with(|p| p.borrow()[i]) as i64 == pred {");
      Line ("      return ALB_REL_ARG1.with(|a| a.borrow()[i]) as i64;");
      Line ("    }");
      Line ("  }");
      Line ("  0");
      Line ("}");
      Line ("fn ALB_REL_FINDALL1(pred: i64, target: &mut [i64]) -> i64 {");
      Line ("  for t in target.iter_mut() { *t = 0; } let mut out = 0usize;");
      Line ("  for i in 0..1024 {");
      Line ("    if out >= target.len() { break; }");
      Line ("    if ALB_REL_LIVE.with(|l| l.borrow()[i]) != 0 && ALB_REL_PRED.with(|p| p.borrow()[i]) as i64 == pred {");
      Line ("      target[out] = ALB_REL_ARG1.with(|a| a.borrow()[i]) as i64; out += 1;");
      Line ("    }");
      Line ("  }");
      Line ("  out as i64");
      Line ("}");
      Line ("fn ALB_ASSERT(key: impl ToString, value: impl ToString) { ALB_KNOWS_SET(key, value); }");
      Line ("fn ALB_RETRACT(key: impl ToString) {");
      Line ("  let k = key.to_string();");
      Line ("  ALB_FACT_LIVE.with(|live| ALB_FACT_KEY.with(|keys| ALB_FACT_VAL.with(|vals| {");
      Line ("    let mut live = live.borrow_mut(); let mut keys = keys.borrow_mut(); let mut vals = vals.borrow_mut();");
      Line ("    for i in 0..live.len() { if live[i] != 0 && keys[i] == k { live[i] = 0; keys[i].clear(); vals[i].clear(); } }");
      Line ("  })));");
      Line ("}");
      Line ("fn ALB_UPDATE(key: impl ToString, value: impl ToString) { ALB_KNOWS_SET(key, value); }");
      Line ("fn ALB_PROVE(key: impl ToString) -> i64 { ALB_KNOWS_HAS(key) }");
      Line ("fn ALB_PRED(name: impl ToString, a: Option<String>, b: Option<String>, c: Option<String>, d: Option<String>) -> String {");
      Line ("  let mut s = format!(""{}("", name.to_string()); let mut first = true;");
      Line ("  for opt in [a, b, c, d] { if let Some(v) = opt { if !first { s.push(','); } s.push_str(&v); first = false; } }");
      Line ("  s.push(')'); s");
      Line ("}");
      New_Line_Emit;
      Line ("fn ALB_Open(path: impl ToString, mode: impl ToString) -> i64 {");
      Line ("  let path = path.to_string(); let mode = mode.to_string();");
      Line ("  ALB_FILE_LIVE.with(|live| ALB_FILE_MODE.with(|modes| ALB_FILE_NAME.with(|names| ALB_FILE_BUF.with(|bufs| ALB_FILE_CUR.with(|curs| ALB_SAVE_STORE.with(|store| {");
      Line ("    let mut live = live.borrow_mut(); let mut modes = modes.borrow_mut(); let mut names = names.borrow_mut();");
      Line ("    let mut bufs = bufs.borrow_mut(); let mut curs = curs.borrow_mut(); let store = store.borrow();");
      Line ("    for i in 1..live.len() {");
      Line ("      if live[i] == 0 {");
      Line ("        live[i] = 1; modes[i] = mode.clone(); names[i] = path.clone(); curs[i] = 0;");
      Line ("        let mut buf = store.get(&path).cloned().unwrap_or_default();");
      Line ("        if buf.is_empty() { if let Ok(t) = fs::read_to_string(&path) { buf = t; } }");
      Line ("        bufs[i] = buf; return i as i64;");
      Line ("      }");
      Line ("    }");
      Line ("    0");
      Line ("  }))))))");
      Line ("}");
      Line ("fn ALB_FileLen(path: impl ToString) -> i64 {");
      Line ("  let path = path.to_string();");
      Line ("  if let Ok(meta) = fs::metadata(&path) { return meta.len() as i64; }");
      Line ("  ALB_SAVE_STORE.with(|s| s.borrow().get(&path).map(|t| t.len() as i64).unwrap_or(0))");
      Line ("}");
      Line ("fn ALB_Seek(handle: i64, offset: i64) -> i64 {");
      Line ("  ALB_FILE_LIVE.with(|live| ALB_FILE_CUR.with(|curs| {");
      Line ("    let h = handle as usize; if h >= live.borrow().len() || live.borrow()[h] == 0 { return 0; }");
      Line ("    let off = alb_max(0, offset) as i32; curs.borrow_mut()[h] = off; off as i64");
      Line ("  }))");
      Line ("}");
      Line ("fn ALB_Read(handle: i64, count: i64) -> String {");
      Line ("  ALB_FILE_LIVE.with(|live| ALB_FILE_BUF.with(|bufs| ALB_FILE_CUR.with(|curs| {");
      Line ("    let h = handle as usize; if h >= live.borrow().len() || live.borrow()[h] == 0 { return String::new(); }");
      Line ("    let buf = bufs.borrow()[h].clone(); if count <= 0 { return buf; }");
      Line ("    let start = curs.borrow()[h] as usize; let end = alb_min(buf.len() as i64, (start as i64) + count) as usize;");
      Line ("    let chunk = buf.get(start..end).unwrap_or("""").to_string(); curs.borrow_mut()[h] = end as i32; chunk");
      Line ("  })))");
      Line ("}");
      Line ("fn ALB_Write(handle: i64, data: impl ToString) {");
      Line ("  ALB_FILE_LIVE.with(|live| ALB_FILE_BUF.with(|bufs| {");
      Line ("    let h = handle as usize; if h < live.borrow().len() && live.borrow()[h] != 0 { bufs.borrow_mut()[h].push_str(&data.to_string()); }");
      Line ("  }));");
      Line ("}");
      Line ("fn ALB_Close(handle: i64) {");
      Line ("  ALB_FILE_LIVE.with(|live| ALB_FILE_NAME.with(|names| ALB_FILE_BUF.with(|bufs| ALB_FILE_CUR.with(|curs| ALB_SAVE_STORE.with(|store| {");
      Line ("    let h = handle as usize; if h >= live.borrow().len() || live.borrow()[h] == 0 { return; }");
      Line ("    store.borrow_mut().insert(names.borrow()[h].clone(), bufs.borrow()[h].clone());");
      Line ("    live.borrow_mut()[h] = 0; names.borrow_mut()[h].clear(); bufs.borrow_mut()[h].clear(); curs.borrow_mut()[h] = 0;");
      Line ("  })))));");
      Line ("}");
      Line ("fn ALB_LoadTextBuffer(path: impl ToString) -> String {");
      Line ("  let path = path.to_string();");
      Line ("  if let Some(t) = ALB_SAVE_STORE.with(|s| s.borrow().get(&path).cloned()) { return t; }");
      Line ("  fs::read_to_string(&path).unwrap_or_default()");
      Line ("}");
      Line ("fn ALB_LoadBuffer(path: impl ToString, target: &mut [i64]) {");
      Line ("  let raw = ALB_LoadTextBuffer(path);");
      Line ("  for (i, part) in raw.split(',').enumerate() { if i >= target.len() { break; } target[i] = part.trim().parse::<i64>().unwrap_or(0); }");
      Line ("}");
      Line ("fn ALB_FlushBuffer_text(target: &str, path: impl ToString) {");
      Line ("  let path = path.to_string(); ALB_SAVE_STORE.with(|s| { s.borrow_mut().insert(path.clone(), target.to_string()); }); let _ = fs::write(&path, target);");
      Line ("}");
      Line ("fn ALB_FILE_XOR(source_path: impl ToString, key: impl ToString, out_path: impl ToString) {");
      Line ("  let src = ALB_LoadTextBuffer(source_path);");
      Line ("  let key_text = { let k = key.to_string(); if k.is_empty() { ""0"".to_string() } else { k } };");
      Line ("  let kb = key_text.as_bytes();");
      Line ("  let out: String = src.bytes().enumerate().map(|(i, b)| char::from(b ^ kb[i % kb.len()])).collect();");
      Line ("  ALB_FlushBuffer_text(&out, out_path);");
      Line ("}");
      New_Line_Emit;
      Line ("fn alb_firewall_current() -> Option<AlbrFirewall> { ALB_FIREWALL_STACK.with(|s| s.borrow().last().cloned()) }");
      Line ("fn alb_firewall_allows(kind: &str, name: &str) -> bool {");
      Line ("  match alb_firewall_current() {");
      Line ("    None => true,");
      Line ("    Some(fw) => { if !fw.deny_all || name.is_empty() { return true; } if kind == ""write"" { fw.write.contains(name) } else { fw.read.contains(name) } }");
      Line ("  }");
      Line ("}");
      Line ("fn ALB_FIREWALL_TOUCH_READ(name: &str) { if !alb_firewall_allows(""read"", name) { ALB_FATAL(format!(""MEMORY_FIREWALL read blocked: {}"", name)); } }");
      Line ("fn ALB_FIREWALL_TOUCH_WRITE(name: &str) { if !alb_firewall_allows(""write"", name) { ALB_FATAL(format!(""MEMORY_FIREWALL write blocked: {}"", name)); } }");
      Line ("fn ALB_FIREWALL_READ<T>(name: &str, value: T) -> T { ALB_FIREWALL_TOUCH_READ(name); value }");
      Line ("fn ALB_FIREWALL_WRITE<T>(name: &str, value: T) -> T { ALB_FIREWALL_TOUCH_WRITE(name); value }");
      Line ("fn ALB_FIREWALL_ENTER(fw: AlbrFirewall) { ALB_FIREWALL_STACK.with(|s| s.borrow_mut().push(fw)); }");
      Line ("fn ALB_FIREWALL_LEAVE() { ALB_FIREWALL_STACK.with(|s| { s.borrow_mut().pop(); }); }");
      Line ("fn ALB_REQUIRE(cond: bool, msg: &str) { if !cond { ALB_FATAL(format!(""REQUIRE failed: {}"", msg)); } }");
      Line ("fn ALB_ENSURE(cond: bool, msg: &str) { if !cond { ALB_FATAL(format!(""ENSURE failed: {}"", msg)); } }");
      Line ("fn ALB_ASSERT_RT(cond: bool, msg: &str) { if !cond { ALB_FATAL(format!(""ASSERT failed: {}"", msg)); } }");
      New_Line_Emit;
      Line ("fn ALB_REV_PUSH() { ALB_REV_STACK.with(|s| s.borrow_mut().push(AlbrRevFrame::default())); }");
      Line ("fn ALB_REV_POP_UNDO(state: &mut HashMap<String, i64>) {");
      Line ("  if let Some(frame) = ALB_REV_STACK.with(|s| s.borrow_mut().pop()) {");
      Line ("    for op in frame.ops.into_iter().rev() {");
      Line ("      match op {");
      Line ("        AlbrRevOp::Add(n, v) => { *state.entry(n).or_insert(0) -= v; }");
      Line ("        AlbrRevOp::Sub(n, v) => { *state.entry(n).or_insert(0) += v; }");
      Line ("        AlbrRevOp::Xor(n, v) => { *state.entry(n).or_insert(0) ^= v; }");
      Line ("        AlbrRevOp::Not(n) => { let e = state.entry(n).or_insert(0); *e = !*e; }");
      Line ("        AlbrRevOp::Neg(n) => { let e = state.entry(n).or_insert(0); *e = -*e; }");
      Line ("        AlbrRevOp::Swap(a, b) => { let va = *state.get(&a).unwrap_or(&0); let vb = *state.get(&b).unwrap_or(&0); state.insert(a, vb); state.insert(b, va); }");
      Line ("      }");
      Line ("    }");
      Line ("  }");
      Line ("}");
      Line ("fn ALB_REV_NOTE(op: AlbrRevOp) { ALB_REV_STACK.with(|s| { if let Some(f) = s.borrow_mut().last_mut() { f.ops.push(op); } }); }");
      New_Line_Emit;
      Line ("// Foreign / ENABLE* : rustc FFI is MIT/Apache-safe to declare; stubs until wired.");
      Line ("fn ALB_COMPAT_IMPORT(lib: &str, symbol: &str, args: &[i64]) -> i64 {");
      Line ("  let key = symbol.to_uppercase();");
      Line ("  if key == ""GETTICKCOUNT64"" || key == ""GETTICKCOUNT"" {");
      Line ("    ALB_COMPAT_TICK.with(|t| { let mut v = t.borrow_mut(); *v = v.wrapping_add(16); *v as i64 })");
      Line ("  } else if key == ""MESSAGEBEEP"" { 1 }");
      Line ("  else if key.contains(""CLOCK"") { ALB_COMPAT_TICK.with(|t| { let mut v = t.borrow_mut(); *v = v.wrapping_add(17); *v as i64 }) }");
      Line ("  else { let _ = (lib, args); 0 }");
      Line ("}");
      Line ("fn ALB_MAKE_CELL(initial: i64) -> i64 { initial }");
      New_Line_Emit;
      Line ("fn ALB_NET_DEFINE(protocol: i64, port: i64, buffer_size: i64) -> i64 {");
      Line ("  ALB_NET_NEXT.with(|n| ALB_NET_TABLE.with(|t| {");
      Line ("    let handle = *n.borrow(); *n.borrow_mut() = handle + 1;");
      Line ("    t.borrow_mut().insert(handle, AlbrNetSock {");
      Line ("      handle, protocol, port, buffer_size: alb_max(1, buffer_size), listening: false, open: true,");
      Line ("      last_sent: vec![0; alb_max(1, buffer_size) as usize], last_recv: vec![0; alb_max(1, buffer_size) as usize],");
      Line ("    });");
      Line ("    handle");
      Line ("  }))");
      Line ("}");
      Line ("fn ALB_NET_LISTEN(handle: i64) { ALB_NET_TABLE.with(|t| { if let Some(s) = t.borrow_mut().get_mut(&handle) { s.listening = true; s.open = true; } }); }");
      Line ("fn ALB_NET_ACCEPT(handle: i64) -> i64 {");
      Line ("  ALB_NET_TABLE.with(|t| {");
      Line ("    let parent = t.borrow().get(&handle).cloned();");
      Line ("    if let Some(sock) = parent { ALB_NET_DEFINE(sock.protocol, sock.port, sock.buffer_size) } else { ALB_FATAL(""NETWORK_ACCEPT on unknown socket""); }");
      Line ("  })");
      Line ("}");
      Line ("fn ALB_NET_RECEIVE(handle: i64, dest: &mut [i64]) {");
      Line ("  ALB_NET_TABLE.with(|t| {");
      Line ("    if let Some(sock) = t.borrow().get(&handle) { for (i, d) in dest.iter_mut().enumerate() { *d = sock.last_recv.get(i).copied().unwrap_or(0) as i64; } }");
      Line ("    else { ALB_FATAL(""NETWORK_RECEIVE on closed socket""); }");
      Line ("  });");
      Line ("}");
      Line ("fn ALB_NET_SEND(handle: i64, src: &[i64]) {");
      Line ("  ALB_NET_TABLE.with(|t| {");
      Line ("    if let Some(sock) = t.borrow_mut().get_mut(&handle) { sock.last_sent = src.iter().map(|v| *v as u8).collect(); }");
      Line ("    else { ALB_FATAL(""NETWORK_SEND on closed socket""); }");
      Line ("  });");
      Line ("}");
      Line ("fn ALB_NET_CLOSE(handle: i64) { ALB_NET_TABLE.with(|t| { if let Some(s) = t.borrow_mut().get_mut(&handle) { s.open = false; s.listening = false; } }); }");
      Line ("fn ALB_PROCESS_DEFINE(image: impl ToString, _rights: &[String], pid: i64) -> i64 {");
      Line ("  ALB_PROC_NEXT.with(|n| ALB_PROC_TABLE.with(|t| {");
      Line ("    let handle = *n.borrow(); *n.borrow_mut() = handle + 1;");
      Line ("    t.borrow_mut().insert(handle, AlbrProcess { handle, image: image.to_string(), alive: true, elevated: false, pid });");
      Line ("    handle");
      Line ("  }))");
      Line ("}");
      Line ("fn ALB_PROCESS_CREATE(image: impl ToString, _args: impl ToString) -> i64 { ALB_PROCESS_DEFINE(image, &[], 0) }");
      Line ("fn ALB_PROCESS_READ_SCALAR(handle: i64, addr: i64) -> i64 {");
      Line ("  ALB_PROC_TABLE.with(|t| { if t.borrow().get(&handle).map(|p| p.alive).unwrap_or(false) { ALB_PEEK(addr) } else { 0 } })");
      Line ("}");
      Line ("fn ALB_PROCESS_WRITE_SCALAR(handle: i64, addr: i64, value: impl ToString) {");
      Line ("  ALB_PROC_TABLE.with(|t| {");
      Line ("    if !t.borrow().get(&handle).map(|p| p.alive).unwrap_or(false) { ALB_FATAL(""WRITE_PROCESS_MEMORY on invalid handle""); }");
      Line ("    ALB_POKE(addr, value);");
      Line ("  });");
      Line ("}");
      Line ("fn ALB_PROCESS_ELEVATE(handle: i64) { ALB_PROC_TABLE.with(|t| { if let Some(p) = t.borrow_mut().get_mut(&handle) { p.elevated = true; } }); }");
      New_Line_Emit;
      Line ("fn ALB_STATIC_SURFACE(width: i64, height: i64) -> AlbrVal { AlbrVal::Str(format!(""surface:{}x{}"", alb_max(1, width), alb_max(1, height))) }");
      Line ("fn ALB_STATIC_VIEWPORT(x: i64, y: i64, w: i64, h: i64) -> AlbrVal { AlbrVal::Str(format!(""viewport:{},{},{},{}"", x, y, w, h)) }");
      Line ("fn ALB_STATIC_EMPTY_SPRITE(fw: i64, fh: i64, frames: i64) -> AlbrVal { AlbrVal::Str(format!(""sprite:{}x{}x{}"", fw, fh, frames)) }");
      Line ("fn ALB_STATIC_SPRITE_FROM_BMP(_bytes: &[u8], fw: i64, fh: i64, frames: i64) -> AlbrVal {");
      Line ("  ALB_WARN_ONCE(""static-sprite-stub"", ""STATIC_SPRITE approximated on ALBR""); ALB_STATIC_EMPTY_SPRITE(fw, fh, frames)");
      Line ("}");
      Line ("fn ALB_STATIC_APPLY_LUT(_lut: &[u32], _visual: &AlbrVal, _ctx: &AlbrVal, _used: bool) {}");
      Line ("fn ALB_STATIC_BLIT(_visual: &AlbrVal, _ctx: &AlbrVal, _used: bool, _target: &AlbrVal, _x: i64, _y: i64, _vp: &AlbrVal, _alpha: bool) {}");
      Line ("fn ALB_MARKOV_PREDICT(_model: &AlbrVal, current: i64) -> i64 { current }");
      Line ("fn ALB_NN_CREATE(name: impl ToString, _sizes: &[i64], _acts: &[i64]) -> AlbrVal { AlbrVal::Str(format!(""nn:{}"", name.to_string())) }");
      Line ("fn ALB_NN_INFER(_model: &AlbrVal, _input: &[i64], output: &mut [i64]) { for o in output.iter_mut() { *o = 0; } }");
      Line ("fn ALB_NN_TRAIN(_model: &mut AlbrVal, _train: &[i64], _expect: &[i64], _epochs: i64) {}");
      Line ("fn ALB_EXPORT_PPM(_surface: &AlbrVal, path: impl ToString, _format: impl ToString) -> i64 { ALB_FlushBuffer_text(""P6\n1 1\n255\n\0\0\0"", path); 1 }");
      New_Line_Emit;
      Line ("fn ALB_RunFrame_once() {");
      Line ("  if !ALB_RUNNING.with(|r| *r.borrow()) { ALB_ProgramShutdown(); return; }");
      Line ("  if !ALB_Poll_Events() { ALB_ProgramShutdown(); return; }");
      Line ("  let now = ALB_GetTickCount();");
      Line ("  if now < ALB_DELAY_UNTIL.with(|d| *d.borrow()) { return; }");
      Line ("  if now - ALB_LAST_FRAME.with(|l| *l.borrow()) < ALB_FRAME_INTERVAL.with(|f| *f.borrow()) { return; }");
      Line ("  ALB_LAST_FRAME.with(|l| { *l.borrow_mut() = now; });");
      Line ("  ALB_PREPARE_FRAME(); ALB_ON_TICK.with(|f| (f.borrow())());");
      Line ("  ALB_MOUSE_WHEEL_CELL.with(|w| { *w.borrow_mut() = 0; }); ALB_ON_PAINT.with(|f| (f.borrow())());");
      Line ("  ALB_ON_KEY.with(|f| (f.borrow())());");
      Line ("  ALB_PRESENT();");
      Line ("}");
      Line ("fn ALB_RunFrame_loop() {");
      Line ("  while ALB_RUNNING.with(|r| *r.borrow()) {");
      Line ("    ALB_RunFrame_once();");
      Line ("    let rem = ALB_FRAME_INTERVAL.with(|f| *f.borrow()) - (ALB_GetTickCount() - ALB_LAST_FRAME.with(|l| *l.borrow()));");
      Line ("    if rem > 1 {");
      Line ("      if ALB_SDL_READY.load(Ordering::Relaxed) { unsafe { SDL_Delay(rem as u32); } }");
      Line ("      else { ALB_DELAY_UNTIL.with(|d| { *d.borrow_mut() = ALB_GetTickCount() + rem; }); }");
      Line ("    }");
      Line ("  }");
      Line ("  ALB_ProgramShutdown();");
      Line ("}");
      --  ALB_ProgramShutdown body is emitted once at end of Compile_To_File
      --  (may include post-LISTEN cleanup). Forward refs are fine in Rust.
      --  ON handlers are nested fns registered into ALB_ON_* RefCells from main.
      Line ("fn alb_module_import_stub(_path: &str) {}");
      Line ("fn alb_wasm_loader_stub(_path: &str) { ALB_WARN_ONCE(""wasm-stub"", ""WASM loaders are stubs on ALBR; use rustc FFI instead""); }");
      Line ("fn ALB_REV_ADD(name: &str, delta: i64) { ALB_REV_NOTE(AlbrRevOp::Add(name.to_string(), delta)); }");
      Line ("fn ALB_REV_SUB(name: &str, delta: i64) { ALB_REV_NOTE(AlbrRevOp::Sub(name.to_string(), delta)); }");
      Line ("fn ALB_REV_XOR(name: &str, delta: i64) { ALB_REV_NOTE(AlbrRevOp::Xor(name.to_string(), delta)); }");
      Line ("fn ALB_REV_NOT(name: &str) { ALB_REV_NOTE(AlbrRevOp::Not(name.to_string())); }");
      Line ("fn ALB_REV_NEG(name: &str) { ALB_REV_NOTE(AlbrRevOp::Neg(name.to_string())); }");
      Line ("fn ALB_REV_SWAP(a: &str, b: &str) { ALB_REV_NOTE(AlbrRevOp::Swap(a.to_string(), b.to_string())); }");
      Line ("fn ALB_REV_ROL(name: &str, bits: i64) { let _ = (name, bits); ALB_WARN_ONCE(""rev-rol"", ""ROL approximated on ALBR""); }");
      Line ("fn ALB_REV_ROR(name: &str, bits: i64) { let _ = (name, bits); ALB_WARN_ONCE(""rev-ror"", ""ROR approximated on ALBR""); }");
      Line ("fn alb_vec_i8(n: usize) -> Vec<i8> { vec![0 as i8; n] }");
      Line ("fn alb_vec_u8(n: usize) -> Vec<u8> { vec![0 as u8; n] }");
      Line ("fn alb_vec_i16(n: usize) -> Vec<i16> { vec![0 as i16; n] }");
      Line ("fn alb_vec_u16(n: usize) -> Vec<u16> { vec![0 as u16; n] }");
      Line ("fn alb_vec_i32(n: usize) -> Vec<i32> { vec![0 as i32; n] }");
      Line ("fn alb_vec_u32(n: usize) -> Vec<u32> { vec![0 as u32; n] }");
      Line ("fn alb_vec_f64(n: usize) -> Vec<f64> { vec![0 as f64; n] }");
      Line ("fn alb_parallel_field_1(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_2(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_3(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_4(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_5(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_6(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_7(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_8(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_9(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_10(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_11(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_12(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_13(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_14(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_15(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_16(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_17(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_18(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_19(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_20(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_21(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_22(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_23(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_24(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_25(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_26(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_27(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_28(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_29(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_30(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_31(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_parallel_field_32(base: &mut [i64], idx: usize, val: i64) { if idx < base.len() { base[idx] = val; } }");
      Line ("fn alb_event_slot_1() {}");
      Line ("fn alb_event_slot_2() {}");
      Line ("fn alb_event_slot_3() {}");
      Line ("fn alb_event_slot_4() {}");
      Line ("fn alb_event_slot_5() {}");
      Line ("fn alb_event_slot_6() {}");
      Line ("fn alb_event_slot_7() {}");
      Line ("fn alb_event_slot_8() {}");
      Line ("fn alb_event_slot_9() {}");
      Line ("fn alb_event_slot_10() {}");
      Line ("fn alb_event_slot_11() {}");
      Line ("fn alb_event_slot_12() {}");
      Line ("fn alb_event_slot_13() {}");
      Line ("fn alb_event_slot_14() {}");
      Line ("fn alb_event_slot_15() {}");
      Line ("fn alb_event_slot_16() {}");
      Line ("fn alb_event_slot_17() {}");
      Line ("fn alb_event_slot_18() {}");
      Line ("fn alb_event_slot_19() {}");
      Line ("fn alb_event_slot_20() {}");
      Line ("fn alb_event_slot_21() {}");
      Line ("fn alb_event_slot_22() {}");
      Line ("fn alb_event_slot_23() {}");
      Line ("fn alb_event_slot_24() {}");
      Line ("fn alb_event_slot_25() {}");
      Line ("fn alb_event_slot_26() {}");
      Line ("fn alb_event_slot_27() {}");
      Line ("fn alb_event_slot_28() {}");
      Line ("fn alb_event_slot_29() {}");
      Line ("fn alb_event_slot_30() {}");
      Line ("fn alb_event_slot_31() {}");
      Line ("fn alb_event_slot_32() {}");
      Line ("fn alb_event_slot_33() {}");
      Line ("fn alb_event_slot_34() {}");
      Line ("fn alb_event_slot_35() {}");
      Line ("fn alb_event_slot_36() {}");
      Line ("fn alb_event_slot_37() {}");
      Line ("fn alb_event_slot_38() {}");
      Line ("fn alb_event_slot_39() {}");
      Line ("fn alb_event_slot_40() {}");
      Line ("fn alb_event_slot_41() {}");
      Line ("fn alb_event_slot_42() {}");
      Line ("fn alb_event_slot_43() {}");
      Line ("fn alb_event_slot_44() {}");
      Line ("fn alb_event_slot_45() {}");
      Line ("fn alb_event_slot_46() {}");
      Line ("fn alb_event_slot_47() {}");
      Line ("fn alb_event_slot_48() {}");
      Line ("fn alb_event_slot_49() {}");
      Line ("fn alb_event_slot_50() {}");
      Line ("fn alb_event_slot_51() {}");
      Line ("fn alb_event_slot_52() {}");
      Line ("fn alb_event_slot_53() {}");
      Line ("fn alb_event_slot_54() {}");
      Line ("fn alb_event_slot_55() {}");
      Line ("fn alb_event_slot_56() {}");
      Line ("fn alb_event_slot_57() {}");
      Line ("fn alb_event_slot_58() {}");
      Line ("fn alb_event_slot_59() {}");
      Line ("fn alb_event_slot_60() {}");
      Line ("fn alb_event_slot_61() {}");
      Line ("fn alb_event_slot_62() {}");
      Line ("fn alb_event_slot_63() {}");
      Line ("fn alb_event_slot_64() {}");
      New_Line_Emit;
   end Emit_Runtime;


   function RustImport_Alias (Binding : Foreign_Binding_Record) return String is
   begin
      return "__alb_imp_" & Safe_Rust_Name (To_String (Binding.Rust_Name));
   end RustImport_Alias;

   procedure Emit_Module_Imports is
   begin
      if not Need_Module_Support then
         return;
      end if;

      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Link_Kind = Foreign_ES then
            Line ("import { " & To_String (Foreign_Imports (I).Name) &
                  " as " & RustImport_Alias (Foreign_Imports (I)) &
                  " } from " &
                  Escape_Rust_String (RustImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                  ";");
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
            Line ("albWasmLoaders.push((async () => {");
            Indent_Level := Indent_Level + 1;
            Line ("let response = await fetch(" &
                  Escape_Rust_String (RustImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                  ");");
            Line ("if (!response.ok) ALB_FATAL(`WASM fetch failed for " &
                  To_String (Foreign_Imports (I).Name) & ": ${response.status}`);");
            Line ("let bytes = await response.arrayBuffer();");
            Line ("let result = await WebAssembly.instantiate(bytes, ALB_WASM_HOST_IMPORTS as WebAssembly.Imports);");
            Line ("let exportsTable = result.instance.exports as Record<string, unknown>;");
            Line ("let fn = exportsTable[" &
                  Escape_Rust_String (To_String (Foreign_Imports (I).Name)) & "];");
            Line ("if (/*tyof*/ fn != 'function') ALB_FATAL('Missing WASM export: " &
                  To_String (Foreign_Imports (I).Name) & "');");
            Line ("albWasmBindings[" &
                  Escape_Rust_String (To_String (Foreign_Imports (I).Rust_Name)) &
                  "] = fn as (...args: AlbrVal[]) => any;");
            Indent_Level := Indent_Level - 1;
            Line ("})());");
         end if;
      end loop;

      New_Line_Emit;
   end Emit_Foreign_Loaders;

   procedure Emit_Module_Exports is
      Any_ES_Exports     : Boolean := False;
      Any_WASM_Exports   : Boolean := False;
      Any_Compat_Exports : Boolean := False;
   begin
      for I in 1 .. Foreign_Export_Count loop
         if Foreign_Exports (I).Active then
            case Foreign_Exports (I).Link_Kind is
               when Foreign_ES =>
                  Any_ES_Exports := True;
               when Foreign_WASM =>
                  Any_WASM_Exports := True;
               when Foreign_Compat =>
                  Any_Compat_Exports := True;
               when others =>
                  null;
            end case;
         end if;
      end loop;

      if Any_WASM_Exports then
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_WASM then
               Line ("ALB_WASM_HOST_IMPORTS.alb[" &
                     Escape_Rust_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args: AlbrVal[]) => (" &
                     To_String (Foreign_Exports (I).Rust_Name) &
                     " as any)(...args);");
            end if;
         end loop;
         Line ("export { ALB_WASM_HOST_IMPORTS };");
         New_Line_Emit;
      end if;

      if Any_Compat_Exports then
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_Compat then
               Line ("albCompatExports[" &
                     Escape_Rust_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args: AlbrVal[]) => (" &
                     To_String (Foreign_Exports (I).Rust_Name) &
                     " as any)(...args);");
            end if;
         end loop;
         Line ("Object.assign(globalThis as Record<string, unknown>, albCompatExports);");
         New_Line_Emit;
      end if;

      if Any_ES_Exports then
         --  Emit one export per line so full-engine libraries (~1k+ symbols)
         --  do not produce a single multi-megabyte export { … } statement.
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_ES then
               Line ("export { " &
                     To_String (Foreign_Exports (I).Rust_Name) & " as " &
                     To_String (Foreign_Exports (I).Name) & " };");
            end if;
         end loop;
         New_Line_Emit;
      end if;
   end Emit_Module_Exports;

   --  Native DLL/SO/Dylib/Jar imports via LoadLibrary/GetProcAddress (Win64 C ABI).
   procedure Emit_Dll_Import_Node (Index : Node_Index) is
      Binding    : Foreign_Binding_Record;
      Decl_Node  : constant Node_Index := Tree (Index).Left_Child;
      Name_Node  : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      List_Node  : constant Node_Index := (if Name_Node > 0 then Tree (Name_Node).Right_Child else 0);
      Param_Node : Node_Index := 0;
      First      : Boolean := True;
      Path_Text  : constant String :=
        (if Tree (Index).Right_Child > 0
         then Strip_String_Node (Tree (Index).Right_Child)
         else "");
      Resolved   : constant String :=
        ALB_System_Includes.Resolve_Vendor_Dll
          (ALB_System_Includes.Remap_Gfx_Library (Path_Text));

      function Is_Float_Tag (Tag : Value_Kind) return Boolean is
      begin
         return Tag = VK_F64 or else Tag = VK_F32;
      end Is_Float_Tag;

      function Looks_Like_CString_Param
        (Param_Name : String;
         Tag        : Value_Kind) return Boolean
      is
         U : constant String := Upper_Text (Param_Name);
      begin
         if Tag /= VK_Number and then Tag /= VK_U64 and then Tag /= VK_Unknown then
            return False;
         end if;
         return U = "TITLE" or else U = "NAME" or else U = "MSG"
           or else U = "LABEL" or else U = "ITEMS_PIPE" or else U = "SELECTED"
           or else U = "PATH" or else U = "TEXT" or else U = "CAPTION"
           or else U = "FILENAME" or else U = "FILE" or else U = "URL";
      end Looks_Like_CString_Param;

      function Effective_Param_Tag
        (Param_Name : String;
         Tag        : Value_Kind) return Value_Kind is
      begin
         if Tag = VK_String or else Tag = VK_Binary then
            return Tag;
         elsif Looks_Like_CString_Param (Param_Name, Tag) then
            return VK_String;
         else
            return Tag;
         end if;
      end Effective_Param_Tag;

      function Is_Wide_Int_Tag (Tag : Value_Kind) return Boolean is
      begin
         case Tag is
            when VK_Number | VK_U64 | VK_U32 | VK_U16 | VK_U8
               | VK_S8 | VK_S16 | VK_HW8 | VK_HW16 | VK_HW32
               | VK_Pure | VK_Unknown =>
               return True;
            when others =>
               return False;
         end case;
      end Is_Wide_Int_Tag;

      function C_Foreign_Param_Type (Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return "f32";
         elsif Tag = VK_S32 then
            return "i32";
         elsif Tag = VK_String or else Tag = VK_Binary then
            return "*const c_char";
         elsif Is_Wide_Int_Tag (Tag) then
            return "*mut c_void";
         else
            return "i64";
         end if;
      end C_Foreign_Param_Type;

      function C_Foreign_Return_Type (Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return "f64";
         elsif Tag = VK_S32 then
            return "i32";
         elsif Tag = VK_String or else Tag = VK_Binary then
            return "*const c_char";
         elsif Is_Wide_Int_Tag (Tag) then
            return "*mut c_void";
         else
            return "i64";
         end if;
      end C_Foreign_Return_Type;

      function Cast_Arg_To_C (Param_Name : String; Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return Param_Name & " as f32";
         elsif Tag = VK_S32 then
            return Param_Name & " as i32";
         elsif Tag = VK_String or else Tag = VK_Binary then
            return "__c_" & Param_Name & ".as_ptr()";
         elsif Is_Wide_Int_Tag (Tag) then
            return Param_Name & " as *mut c_void";
         else
            return Param_Name;
         end if;
      end Cast_Arg_To_C;

      function Wrap_C_Return (Call_Expr : String; Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return Call_Expr;
         elsif Tag = VK_S32 then
            return Call_Expr & " as i64";
         elsif Tag = VK_String or else Tag = VK_Binary then
            return "unsafe { CStr::from_ptr(" & Call_Expr &
              ").to_string_lossy().into_owned() }";
         elsif Is_Wide_Int_Tag (Tag) then
            return "(" & Call_Expr & " as usize as i64)";
         else
            return Call_Expr;
         end if;
      end Wrap_C_Return;

      function Rust_Wrapper_Param_Type (Tag : Value_Kind) return String is
      begin
         if Tag in VK_String | VK_Binary then
            return "impl ToString";
         else
            return Primitive_Rust_Type (Tag);
         end if;
      end Rust_Wrapper_Param_Type;
   begin
      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Node = Index then
            Binding := Foreign_Imports (I);
            exit;
         end if;
      end loop;

      if Name_Node = 0 then
         return;
      end if;

      if not Binding.Active then
         Binding.Active := True;
         Binding.Name := U (Raw_Lexeme (Tree (Name_Node).Token_Index));
         Binding.Rust_Name := U (Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
         Binding.Is_Function := Tree (Decl_Node).Kind = AST_Function_Decl;
         Binding.Return_Tag := Type_From_Token (Tree (Decl_Node).Token_Index);
      end if;

      declare
         Wrapper_Name : constant String := To_String (Binding.Rust_Name);
         Sym_Name     : constant String := To_String (Binding.Name);
         Ret_Rust     : constant String := Primitive_Rust_Type (Binding.Return_Tag);
         Nil_Ret      : constant String := Default_Value (Binding.Return_Tag);
         Param_Sig    : Unbounded_String := U ("");
         C_Param_Sig  : Unbounded_String := U ("");
         Call_Args    : Unbounded_String := U ("");
      begin
         if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
            Param_Node := Tree (List_Node).Left_Child;
            First := True;
            while Param_Node > 0 loop
               if Tree (Param_Node).Kind = AST_Param_Decl then
                  declare
                     Param_Name : constant String :=
                       Safe_Rust_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
                     Raw_Tag    : constant Value_Kind :=
                       (if Tree (Param_Node).Right_Child > 0
                        then Type_From_Token (Tree (Tree (Param_Node).Right_Child).Token_Index)
                        else VK_Number);
                     Param_Tag  : constant Value_Kind :=
                       Effective_Param_Tag (Param_Name, Raw_Tag);
                  begin
                     if not First then
                        Append (Param_Sig, ", ");
                        Append (C_Param_Sig, ", ");
                        Append (Call_Args, ", ");
                     end if;
                     Append (Param_Sig, Param_Name & ": " & Rust_Wrapper_Param_Type (Param_Tag));
                     Append (C_Param_Sig, Param_Name & ": " & C_Foreign_Param_Type (Param_Tag));
                     Append (Call_Args, Cast_Arg_To_C (Param_Name, Param_Tag));
                     First := False;
                  end;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         Emit_Indent;
         if Binding.Is_Function then
            Emit ("fn " & Wrapper_Name & "(" & To_String (Param_Sig) & ") -> " & Ret_Rust & " {");
         else
            Emit ("fn " & Wrapper_Name & "(" & To_String (Param_Sig) & ") {");
         end if;
         New_Line_Emit;
         Indent_Level := Indent_Level + 1;

         if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
            Param_Node := Tree (List_Node).Left_Child;
            while Param_Node > 0 loop
               if Tree (Param_Node).Kind = AST_Param_Decl then
                  declare
                     Param_Name : constant String :=
                       Safe_Rust_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
                     Raw_Tag    : constant Value_Kind :=
                       (if Tree (Param_Node).Right_Child > 0
                        then Type_From_Token (Tree (Tree (Param_Node).Right_Child).Token_Index)
                        else VK_Number);
                     Param_Tag  : constant Value_Kind :=
                       Effective_Param_Tag (Param_Name, Raw_Tag);
                  begin
                     if Param_Tag in VK_String | VK_Binary then
                        Line ("let __c_" & Param_Name & " = match CString::new(alb_text(" &
                              Param_Name & ")) { Ok(c) => c, Err(_) => CString::new("""").unwrap() };");
                     end if;
                  end;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         Line ("static FN: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());");
         Line ("let mut f = FN.load(Ordering::Relaxed);");
         Line ("if f.is_null() {");
         Indent_Level := Indent_Level + 1;
         Line ("f = alb_load_sym(" & Escape_Rust_String (Resolved) & ", " &
               Escape_Rust_String (Sym_Name) & ");");
         Line ("FN.store(f, Ordering::Relaxed);");
         if Binding.Is_Function then
            Line ("if f.is_null() { return " & Nil_Ret & "; }");
         else
            Line ("if f.is_null() { return; }");
         end if;
         Indent_Level := Indent_Level - 1;
         Line ("}");

         if Binding.Is_Function then
            Line ("let p: unsafe extern ""C"" fn(" & To_String (C_Param_Sig) & ") -> " &
                  C_Foreign_Return_Type (Binding.Return_Tag) &
                  " = unsafe { std::mem::transmute(f) };");
            Line ("return " & Wrap_C_Return ("unsafe { p(" & To_String (Call_Args) & ") }",
                  Binding.Return_Tag) & ";");
         else
            Line ("let p: unsafe extern ""C"" fn(" & To_String (C_Param_Sig) &
                  ") = unsafe { std::mem::transmute(f) };");
            Line ("unsafe { p(" & To_String (Call_Args) & "); }");
         end if;

         Indent_Level := Indent_Level - 1;
         Line ("}");
         New_Line_Emit;
      end;
   end Emit_Dll_Import_Node;

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
      Emit ("function " & To_String (Binding.Rust_Name) & "(");
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Param_Node := Tree (List_Node).Left_Child;
         while Param_Node > 0 loop
            if Tree (Param_Node).Kind = AST_Param_Decl then
               declare
                  Param_Name : constant String := Safe_Rust_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
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
                     Emit (Param_Name & ": { value: " & Primitive_Rust_Type (Param_Tag) & " }");
                     Has_Out := True;
                  else
                     Emit (Param_Name & ": " & Primitive_Rust_Type (Param_Tag));
                  end if;
                  First := False;
               end;
            end if;
            Param_Node := Tree (Param_Node).Next_Sibling;
         end loop;
      end if;

      if Binding.Is_Function then
         Emit ("): " & Primitive_Rust_Type (Binding.Return_Tag) & " {");
      else
         Emit (") {");
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
                          Safe_Rust_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index)));
                  First := False;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         if Has_Out then
            Line ("ALB_WARN_ONCE(" &
                  Escape_Rust_String ("foreign-out-" & To_String (Binding.Name)) & ", " &
                  Escape_Rust_String ("ALBR passes OUT parameters to foreign imports as { value } boxes; the callee must mutate .value to write back") &
                  ");");
         end if;

         if Binding.Link_Kind = Foreign_ES then
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     RustImport_Alias (Binding) & "(" & To_String (Call_Args) & ")") & ";");
            else
               Line (RustImport_Alias (Binding) & "(" & To_String (Call_Args) & ");");
            end if;
         elsif Binding.Link_Kind = Foreign_WASM then
            Line ("let __alb_wasm_fn = albWasmBindings[" &
                  Escape_Rust_String (To_String (Binding.Rust_Name)) & "];");
            Line ("if (/*tyof*/ __alb_wasm_fn != 'function') ALB_FATAL('WASM import not ready: " &
                  To_String (Binding.Name) & "');");
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "__alb_wasm_fn(" & To_String (Call_Args) & ")") & ";");
            else
               Line ("__alb_wasm_fn(" & To_String (Call_Args) & ");");
            end if;
         else
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "ALB_COMPAT_IMPORT(" &
                     Escape_Rust_String (To_String (Binding.Path)) & ", " &
                     Escape_Rust_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ")") & ";");
            else
               Line ("ALB_COMPAT_IMPORT(" &
                     Escape_Rust_String (To_String (Binding.Path)) & ", " &
                     Escape_Rust_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ");");
            end if;
         end if;
      end;

      if not Binding.Is_Function then
         Line ("return;");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
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
            Line ("const " & Const_Name & ": Vec<u8> = vec![0];");
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
            Emit ("const " & Const_Name & ": Vec<u8> = vec![");
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
            Emit ("];");
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
         Line ("const " & Const_Name & ": Vec<u8> = vec![0];");
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
      Line ("const " & Const_Name & " = " &
            Escape_Rust_String (To_String (Content)) & ";");
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
         Line ("const " & Const_Name & " = """";");
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
            declare
               Idx_Expr : constant String :=
                 Build_Array_Index (Sym.Dims, Sym.Rank, Node.Left_Child);
            begin
               if Is_Global_Storage_Sym (Sym) then
                  --  Placeholder: Emit_Assignment rewrites global array stores.
                  return "__alb_garr:" & To_String (Sym.Rust_Name) & ":" & Idx_Expr;
               else
                  return To_String (Sym.Rust_Name) & "[" & Idx_Expr & "]";
               end if;
            end;
         elsif Sym.Active
           and then Is_Global_Storage_Sym (Sym)
           and then Sym.Kind in Sym_Scalar | Sym_Const | Sym_Temporal
         then
            return "__alb_gscal:" & To_String (Sym.Rust_Name);
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
                     declare
                        Idx_Expr : constant String :=
                          Build_Array_Index
                            (Symbols (Field_Sym_Id).Dims,
                             Symbols (Field_Sym_Id).Rank,
                             Left_Node.Left_Child);
                     begin
                        if Is_Global_Storage_Sym (Symbols (Field_Sym_Id)) then
                           return "__alb_garr:" &
                             To_String (Symbols (Field_Sym_Id).Rust_Name) & ":" & Idx_Expr;
                        else
                           return To_String (Symbols (Field_Sym_Id).Rust_Name) &
                             "[" & Idx_Expr & "]";
                        end if;
                     end;
                  end if;
               end;
            end if;

            if Right_Node.Kind = AST_Var_Expr
              and then Right_Node.Left_Child > 0
              and then Group_Sym.Active
              and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               declare
                  Idx_Expr : constant String :=
                    Build_Array_Index (Group_Sym.Dims, Group_Sym.Rank, Right_Node.Left_Child);
               begin
                  if Is_Global_Storage_Sym (Group_Sym) then
                     return "__alb_garr:" & To_String (Group_Sym.Rust_Name) & ":" & Idx_Expr;
                  else
                     return To_String (Group_Sym.Rust_Name) & "[" & Idx_Expr & "]";
                  end if;
               end;
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               return To_String (Left_Sym.Rust_Name) & "." & Safe_Rust_Name (Right_Name);
            elsif Group_Sym.Active then
               if Is_Global_Storage_Sym (Group_Sym)
                 and then Group_Sym.Kind in Sym_Scalar | Sym_Const | Sym_Temporal
               then
                  return "__alb_gscal:" & To_String (Group_Sym.Rust_Name);
               end if;
               return To_String (Group_Sym.Rust_Name);
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
            return To_String (Sym.Rust_Name);
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
               return Firewall_Key_For_Symbol (Sym, To_String (Sym.Rust_Name));
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
               return Firewall_Key_For_Symbol (Group_Sym, To_String (Group_Sym.Rust_Name));
            elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               if To_String (Left_Sym.Scope) /= "" then
                  return "";
               else
                  return To_String (Left_Sym.Rust_Name) & "." & Safe_Rust_Name (Right_Name);
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
      -- Skip wraps when the program never declares MEMORY_FIREWALL.
      -- FruitFractals-style hot loops otherwise pay a call per R/W.
      if not Need_Firewall_Runtime or else Key'Length = 0 then
         return Value_Text;
      else
         return "ALB_FIREWALL_READ(" & Escape_Rust_String (Key) & ", " & Value_Text & ")";
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
         return "ALB_FIREWALL_WRITE(" & Escape_Rust_String (Key) & ", " & Value_Text & ")";
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
         Line ("ALB_FIREWALL_TOUCH_READ(" & Escape_Rust_String (Key) & ");");
      end if;

      if Need_Write then
         Line ("ALB_FIREWALL_TOUCH_WRITE(" & Escape_Rust_String (Key) & ");");
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
      --  Nested inside main so INCLUDE module procs are in scope; register into
      --  the thread-local RefCell used by ALB_RunFrame_once.
      Line ("fn " & Name & "_HANDLER() {");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Count loop
         Emit_Block (Blocks (I));
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line (Name & ".with(|f| { *f.borrow_mut() = " & Name & "_HANDLER; });");
      New_Line_Emit;
      Current_Routine := Old_Routine;
   end Emit_Event_Handler;

   procedure Emit_Address_Routines is
   begin
      --  Runtime already provides ALB_PEEK/POKE/DEREF. Skip TS leftover override.
      null;
   end Emit_Address_Routines;

   procedure Emit_State_Routines is
   begin
      New_Line_Emit;
      Line ("fn ALB_SAVE_STATE() {");
      Line ("  // ALBR stub: full snapshot serialization not yet ported from TS");
      Line ("}");
      Line ("fn ALB_LOAD_STATE() {");
      Line ("  // ALBR stub: full snapshot restore not yet ported from TS");
      Line ("}");
      New_Line_Emit;
   end Emit_State_Routines;

   procedure Emit_Logic_Setup is
   begin
      if Rule_Node_Count = 0 and Watch_Node_Count = 0 then
         return;
      end if;

      Line ("fn ALB_INIT_LOGIC() {");
      Indent_Level := Indent_Level + 1;
      Line ("albRuleCount = 0;");

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
                  Predicate_Id_Expr (Head_Node) & ";");
            Line ("albRuleFlags[" & Trim_Image (Rule_Offset) & "] = " &
                  (if Rule_AST.Kind = AST_Constraint_Decl then "1" else "0") & ";");

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
                     Predicate_Id_Expr (Curr_Body) & ";");
               Line ("albRuleBodyArgMode[" & Trim_Image (Base_Index) & "] = " &
                     Trim_Image (Mode_Value) & ";");
               Line ("albRuleBodyArgConst[" & Trim_Image (Base_Index) & "] = " &
                     (if Body_Arg > 0 and then Mode_Value = 0 then Expr (Body_Arg) else "0") & ";");

               Body_Count := Body_Count + 1;
               Curr_Body := Tree (Curr_Body).Next_Sibling;
            end loop;

            Line ("albRuleBodyLen[" & Trim_Image (Rule_Offset) & "] = " &
                  Trim_Image (Integer (Body_Count)) & ";");
            Line ("albRuleCount = " & Trim_Image (Integer (I)) & ";");
         end;
      end loop;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;

      Line ("ALB_NOTIFY_KNOWS_CHANGE = (pred: i64, arg1: i64, arg2: i64, arg3: i64, arg4: i64) => {");
      Indent_Level := Indent_Level + 1;

      if Watch_Node_Count = 0 then
         Line ("return;");
      else
         Line ("switch (pred) {");
         Indent_Level := Indent_Level + 1;

         for I in 1 .. Watch_Node_Count loop
            declare
               Watch_Node : constant Node_Index := Watch_Nodes (I);
               Watch_AST  : constant AST_Node := Tree (Watch_Node);
               Pred_Node  : constant Node_Index := Watch_AST.Right_Child;
               Body_Node  : constant Node_Index := Watch_AST.Left_Child;
               Var_Name   : constant String := Logic_Var_Name_From_Node (Pred_Node);
               Var_JS     : constant String := Safe_Rust_Name (Var_Name);
               Shadow_Id  : Natural := 0;
            begin
               Line ("case " & Predicate_Id_Expr (Pred_Node) & ": {");
               Indent_Level := Indent_Level + 1;
               if Var_Name'Length > 0 then
                  Line ("const " & Var_JS & " = arg1 | 0;");
                  Shadow_Id :=
                    Push_Shadow_Symbol
                      (Scope   => "",
                       Name    => Var_Name,
                       Rust_Name => Var_JS,
                       Tag     => VK_Number);
               end if;
               Emit_Block (Body_Node);
               if Shadow_Id > 0 then
                  Pop_Shadow_Symbol (Shadow_Id);
               end if;
               Line ("break;");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;
         end loop;

         Line ("default:");
         Indent_Level := Indent_Level + 1;
         Line ("break;");
         Indent_Level := Indent_Level - 1;
         Indent_Level := Indent_Level - 1;
         Line ("}");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("};");
      New_Line_Emit;
      Line ("ALB_INIT_LOGIC();");
      New_Line_Emit;
   end Emit_Logic_Setup;

   procedure Emit_Switch_Stmt
     (Expr_Node      : Node_Index;
      First_Case     : Node_Index) is
      Switch_Value : constant String := Next_Temp_Name ("switch_value");
      Curr_Case    : Node_Index := First_Case;
      Saw_Else     : Boolean := False;
   begin
      Line ("{");
      Indent_Level := Indent_Level + 1;
      Line ("let " & Switch_Value & " = " & Expr (Expr_Node) & ";");
      Line ("match " & Switch_Value & " {");
      Indent_Level := Indent_Level + 1;

      while Curr_Case > 0 loop
         if Tree (Curr_Case).Left_Child = 0 then
            Line ("_ => {");
            Saw_Else := True;
         else
            Line (Expr (Tree (Curr_Case).Left_Child) & " => {");
         end if;
         Indent_Level := Indent_Level + 1;
         Emit_Block (Tree (Curr_Case).Right_Child);
         Indent_Level := Indent_Level - 1;
         Line ("}");
         Curr_Case := Tree (Curr_Case).Next_Sibling;
      end loop;

      -- Rust match must be exhaustive.
      if not Saw_Else then
         Line ("_ => {}");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      Indent_Level := Indent_Level - 1;
      Line ("}");
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
      Line ("if (" & Count_Name & " > 0) {");
      Indent_Level := Indent_Level + 1;
      Line ("const " & Swap_Index & " = " & Target_Index & ";");
      Line ("const " & Last_Index & " = (" & Count_Name & " - 1);");
      Line ("if (" & Swap_Index & " != " & Last_Index & ") {");
      Indent_Level := Indent_Level + 1;

      if Target_AST.Kind = AST_Var_Expr and then Target_AST.Left_Child > 0 then
         if Target_Sym.Active
           and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
         then
            Line (To_String (Target_Sym.Rust_Name) & "[" & Swap_Index & "] = " &
                  To_String (Target_Sym.Rust_Name) & "[" & Last_Index & "];");
            Found_Field := True;
         else
            for I in 1 .. Symbol_Count loop
               if Symbols (I).Active
                 and then Symbols (I).Kind = Sym_Parallel_Field
                 and then
                   (Starts_With (To_String (Symbols (I).Name), Scoped_Group & ".")
                    or else Starts_With (To_String (Symbols (I).Name), Raw_Name & "."))
               then
                  Line
                    (Global_Array_Set
                       (To_String (Symbols (I).Rust_Name),
                        Symbols (I).Tag,
                        Swap_Index,
                        Global_Array_Get
                          (To_String (Symbols (I).Rust_Name),
                           Symbols (I).Tag,
                           Last_Index)) & ";");
                  Found_Field := True;
               end if;
            end loop;
         end if;
      end if;

      if not Found_Field then
         Line ("/* SWAPPOP target could not be resolved statically */");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line (Count_Name & " -= 1;");
      Indent_Level := Indent_Level - 1;
      Line ("}");
   end Emit_SwapPop;

   procedure Emit_Store_To_Target
     (Target_Name : String;
      Value_Text  : String;
      Tag         : Value_Kind) is
   begin
      if Target_Name'Length >= 11
        and then Target_Name (Target_Name'First .. Target_Name'First + 10) = "__alb_garr:"
      then
         declare
            Rest  : constant String :=
              Target_Name (Target_Name'First + 11 .. Target_Name'Last);
            Colon : Natural := 0;
         begin
            for I in Rest'Range loop
               if Rest (I) = ':' then
                  Colon := I;
                  exit;
               end if;
            end loop;
            if Colon = 0 then
               Line ("/* bad global array target */");
            else
               Line
                 (Global_Array_Set
                    (Rest (Rest'First .. Colon - 1),
                     Tag,
                     Rest (Colon + 1 .. Rest'Last),
                     Value_Text) & ";");
            end if;
         end;
      elsif Target_Name'Length >= 12
        and then Target_Name (Target_Name'First .. Target_Name'First + 11) = "__alb_gscal:"
      then
         Line
           (Global_Scalar_Set
              (Target_Name (Target_Name'First + 12 .. Target_Name'Last),
               Tag,
               Value_Text) & ";");
      else
         Line (Target_Name & " = " & Value_Text & ";");
      end if;
   end Emit_Store_To_Target;

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
      TSym            : constant Symbol_Record := Target_Symbol (Target_Node);
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
               then Find_Field (To_String (Left_Sym.Struct_Name), Safe_Rust_Name (Raw_Lexeme (Right_Node.Token_Index)))
               else 0);
         begin
            if Field_Id /= 0 and then Fields (Field_Id).Bit_Width > 0 then
               Line (Field_Write_Expr (To_String (Left_Sym.Rust_Name), Field_Id, Value_Text) & ";");
               return;
            end if;
         end;
      end if;

      if Declare_New then
         if Length (Current_Routine) = 0
           and then TSym.Active
           and then Is_Global_Storage_Sym (TSym)
         then
            Line
              (Global_Scalar_Set (To_String (TSym.Rust_Name), Decl_Tag, Value_Text) & ";");
         elsif Target_Name'Length >= 12
           and then Target_Name (Target_Name'First .. Target_Name'First + 11) = "__alb_gscal:"
         then
            Line
              (Global_Scalar_Set
                 (Target_Name (Target_Name'First + 12 .. Target_Name'Last),
                  Decl_Tag,
                  Value_Text) & ";");
         else
            --  Routine-scoped locals.
            Line ("let mut " & Target_Name & ": " & Primitive_Rust_Type (Decl_Tag) &
                  " = " & Value_Text & ";");
         end if;
      else
         Emit_Store_To_Target (Target_Name, Value_Text, Decl_Tag);
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
      Struct_Name : constant String := Safe_Rust_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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
                     Field_Name := U (Safe_Rust_Name (Raw_Lexeme (Tree (Field_Node.Left_Child).Token_Index)));
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
                        Field_Name := U (Safe_Rust_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)));
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
                  Fields (Field_Count).JS_Field := Field_Name;
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
         Rust_Name   : constant String :=
           (if Upper_Text (Func_Name) = "GETTICKCOUNT"
            then "ALB_User_GetTickCount"
            else Scoped_Name (Func_Name));
      begin
         Register_Routine (Func_Name, Rust_Name, Param_Count, Modes);
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
                     Current_Module := U (Safe_Rust_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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
      Rust_Name      : constant String :=
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

      Current_Routine := U (Rust_Name);
      Current_Routine_Out_Count := 0;

      if Is_Function and then Node.Token_Index > 0 then
         Return_Type := Type_From_Token (Node.Token_Index);
         if Return_Type = VK_Unknown then
            Return_Type := VK_Number;
         end if;
      end if;

      Emit_Indent;
      Emit ("fn " & Rust_Name & "(");

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
                     then "__out_" & Safe_Rust_Name (Param_Name)
                     else Safe_Rust_Name (Param_Name));
               begin
                  if not First_Param then
                     Emit (", ");
                  end if;
                  if Mode = Param_Out then
                     Emit (Decl_Name & ": &mut " & Primitive_Rust_Type (Param_Kind));
                     if Current_Routine_Out_Count < Max_Params then
                        Current_Routine_Out_Count := Current_Routine_Out_Count + 1;
                        Current_Routine_Out_Names (Current_Routine_Out_Count) :=
                          U (Safe_Rust_Name (Param_Name));
                     end if;
                  else
                     Emit (Decl_Name & ": " & Primitive_Rust_Type (Param_Kind));
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
         Emit (") -> " & Primitive_Rust_Type (Return_Type) & " {");
      else
         Emit (") {");
      end if;
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;

      Register_Routine (Func_Name, Rust_Name, Param_Count, Modes);

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
                  Decl_Name       : constant String := Safe_Rust_Name (Param_Name);
               begin
                  Register_Symbol
                    (Scope => Rust_Name,
                     Name => Param_Name,
                     Rust_Name => Decl_Name,
                     Tag => Param_Kind,
                     Kind => Sym_Param);
                  if Mode = Param_Out then
                     Line ("let mut " & Decl_Name & ": " & Primitive_Rust_Type (Param_Kind) &
                           " = *__out_" & Decl_Name & ";");
                  end if;
               end;
            elsif Tree (Curr_Param).Kind = AST_Require_Clause then
               Line ("if (!alb_truthy(" & Expr (Tree (Curr_Param).Left_Child) &
                     ")) { ALB_FATAL('REQUIRE failed'); }");
            elsif Tree (Curr_Param).Kind = AST_Bound_To_Clause then
               Bound_Node := Curr_Param;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Line ("ALB_FIREWALL_ENTER(" & Expr (Tree (Bound_Node).Left_Child) & ");");
         Line ("try {");
         Indent_Level := Indent_Level + 1;
      end if;

      -- ALBR hot path: mesh FillTriangle/Render are far too slow as bubble-sort
      -- + per-access garr/firewall. Route through ALB_PAINTER_MESH / FILL_TRIANGLE.
      if Rust_Name'Length >= 13
        and then Rust_Name (Rust_Name'Last - 12 .. Rust_Name'Last) = "_FillTriangle"
      then
         Line ("ALB_COLOR(ccol);");
         Line ("ALB_FILL_TRIANGLE(x1, y1, x2, y2, x3, y3);");
      elsif Rust_Name = "StrawBerry_Render" then
         Line ("ALB_PAINTER_MESH(""StrawBerry_SB_v_x"", ""StrawBerry_SB_v_y"", ""StrawBerry_SB_v_z"", " &
               """StrawBerry_SB_f_p1"", ""StrawBerry_SB_f_p2"", ""StrawBerry_SB_f_p3"", ""StrawBerry_SB_f_col"", " &
               "alb_gscal_get(""StrawBerry_SB_v_count""), alb_gscal_get(""StrawBerry_SB_f_count""), " &
               "rot_yaw, rot_pitch, cam_z, scale, cx, cy, 144);");
      elsif Rust_Name = "Ant_Render" then
         Line ("ALB_PAINTER_MESH(""Ant_ANT_v_x"", ""Ant_ANT_v_y"", ""Ant_ANT_v_z"", " &
               """Ant_ANT_f_p1"", ""Ant_ANT_f_p2"", ""Ant_ANT_f_p3"", ""Ant_ANT_f_col"", " &
               "alb_gscal_get(""Ant_ANT_v_count""), alb_gscal_get(""Ant_ANT_f_count""), " &
               "rot_yaw, rot_pitch, cam_z, scale, cx, cy, 0);");
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
                  Param_Name : constant String := Safe_Rust_Name (Raw_Lexeme (Tree (Param_Name_Node).Token_Index));
               begin
                  if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then
                     Line ("*__out_" & Param_Name & " = " & Param_Name & ";");
                  end if;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if not Is_Function then
         Line ("return;");
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Indent_Level := Indent_Level - 1;
         Line ("} finally {");
         Indent_Level := Indent_Level + 1;
         Line ("ALB_FIREWALL_LEAVE();");
         Indent_Level := Indent_Level - 1;
         Line ("}");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
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
          Line (Target_Name & "(" & Join_Arg_List (Arg_List) & ");");
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
            Line (Target_Name & "(" & To_String (Call_Args) & ");");
         end;
         return;
      end if;

      Line ("{");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line ("const __out_" & Trim_Image (Integer (I)) & " = { value: " &
                  To_String (Targets (I)) & " };");
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
         Line (Target_Name & "(" & To_String (Call_Args) & ");");
      end;

      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line (To_String (Targets (I)) & " = __out_" & Trim_Image (Integer (I)) & ".value;");
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("}");
   end Emit_Call_With_Out;

   procedure Emit_Node (Index : Node_Index) is
      Node : constant AST_Node := Tree (Index);
      Target_Node : Node_Index := 0;
      Value_Node  : Node_Index := 0;
      Raw_Name    : Unbounded_String := U ("");
      Rust_Name     : Unbounded_String := U ("");
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
                  Current_Module := U (Safe_Rust_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
               end if;
               Emit_Block (Body_Node);
               Current_Module := Saved;
            end;

         when AST_DeclareModule | AST_Import | AST_Import_C | AST_Include_Stmt | AST_Version |
              AST_Range_Type_Decl =>
            null;

         when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar =>
            Emit_Dll_Import_Node (Index);

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
               Sprite_RS    : constant String := Scoped_Name (Sprite_Name);
               Setting      : Node_Index := Node.Right_Child;
               Source_Path  : Unbounded_String := U ("");
               Frame_Width  : Integer := 1;
               Frame_Height : Integer := 1;
               Frame_Count  : Integer := 1;
               Format_Text  : Unbounded_String := U ("INDEXED8BIT");
               Saw_Format   : Boolean := False;
               Embed_Name   : constant String := "__alb_bmp_" & Safe_Rust_Name (Sprite_RS);
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

               Register_Symbol ("", Sprite_RS, Sprite_RS, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-sprite-default-format",
                                  "STATIC_SPRITE without FORMAT defaults to INDEXED8BIT on ALBR");
               elsif To_String (Format_Text) /= "INDEXED8BIT" then
                  Emit_Warn_Once ("static-sprite-format-" & Safe_Rust_Name (To_String (Format_Text)),
                                  "STATIC_SPRITE format " & To_String (Format_Text) &
                                  " is approximated as INDEXED8BIT on ALBR");
               end if;
               if Length (Source_Path) > 0 then
                  Emit_Embedded_File_Bytes (Embed_Name, To_String (Source_Path));
               else
                  Emit_Warn_Once ("static-sprite-missing-source-" & Safe_Rust_Name (Sprite_RS),
                                  "STATIC_SPRITE without SOURCE becomes a blank sprite on ALBR");
                  Line ("const " & Embed_Name & ": Vec<u8> = vec![0];");
               end if;
               Line ("let " & Sprite_RS & ": AlbrVal = ALB_STATIC_SPRITE_FROM_BMP(" &
                     Embed_Name & ", " & Trim_Image (Frame_Width) & ", " &
                     Trim_Image (Frame_Height) & ", " & Trim_Image (Frame_Count) & ");");
               New_Line_Emit;
            end;

         when AST_Static_Surface_Decl =>
            declare
               Name_Node   : constant Node_Index := Node.Left_Child;
               Surface_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Surface_RS   : constant String := Scoped_Name (Surface_Name);
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

               Register_Symbol ("", Surface_RS, Surface_RS, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-surface-default-format",
                                  "STATIC_SURFACE without FORMAT defaults to RGB565 on ALBR");
               elsif To_String (Format_Text) /= "RGB565" then
                  Emit_Warn_Once ("static-surface-format-" & Safe_Rust_Name (To_String (Format_Text)),
                                  "STATIC_SURFACE format " & To_String (Format_Text) &
                                  " is approximated as RGB565 on ALBR");
               end if;
               Line ("let " & Surface_RS & ": AlbrVal = ALB_STATIC_SURFACE(" &
                     Trim_Image (Width_Val) & ", " & Trim_Image (Height_Val) & ");");
               New_Line_Emit;
            end;

         when AST_Color_Lut_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               LUT_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               LUT_RS    : constant String := Scoped_Name (LUT_Name);
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

               Register_Symbol ("", LUT_RS, LUT_RS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ("let " & LUT_RS & ": Vec<u32> = vec![");
               for I in Values'Range loop
                  if not First then
                     Emit (", ");
                  end if;
                  Emit (Trim_Image (Values (I)));
                  First := False;
               end loop;
               Emit ("];");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Visual_Rule_Decl =>
            declare
               Name_Node  : constant Node_Index := Node.Left_Child;
               Rule_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Rule_RS    : constant String := Scoped_Name (Rule_Name);
               Param_List : constant Node_Index := Tree (Name_Node).Right_Child;
               Param_Node : constant Node_Index :=
                 (if Param_List > 0 and then Tree (Param_List).Kind = AST_Arg_List
                  then Tree (Param_List).Left_Child
                  else 0);
               Param_Name : constant String :=
                 (if Param_Node > 0 then Safe_Rust_Name (Raw_Feature_Atom (Param_Node)) else "_alb_context");
               Clause     : Node_Index := Node.Right_Child;
            begin
               Register_Symbol ("", Rule_RS, Rule_RS, VK_Number, Sym_Scalar);
               Line ("let " & Rule_RS & ": AlbrVal = {");
               Indent_Level := Indent_Level + 1;
               Line ("kind: 'visualRule',");
               Line ("name: " & Escape_Rust_String (Rule_Name) & ",");
               Line ("resolve: (" & Param_Name & ": AlbrVal) => {");
               Indent_Level := Indent_Level + 1;
               while Clause > 0 loop
                  if Tree (Clause).Kind = AST_Visual_When_Clause then
                     Line ("if (alb_truthy(" & Expr (Tree (Clause).Left_Child) & ")) {");
                     Indent_Level := Indent_Level + 1;
                     Line ("return { sprite: " & Expr (Tree (Clause).Right_Child) &
                           ", frame: " & Expr (Tree (Tree (Clause).Right_Child).Next_Sibling) & " };");
                     Indent_Level := Indent_Level - 1;
                     Line ("}");
                  elsif Tree (Clause).Kind = AST_Visual_Default_Clause then
                     Line ("return { sprite: " & Expr (Tree (Clause).Left_Child) &
                           ", frame: " & Expr (Tree (Clause).Right_Child) & " };");
                  end if;
                  Clause := Tree (Clause).Next_Sibling;
               end loop;
               Line ("return { sprite: 0, frame: 0 };");
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("};");
               New_Line_Emit;
            end;

         when AST_Render_Viewport_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               View_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               View_RS   : constant String := Scoped_Name (View_Name);
               Setting   : constant Node_Index := Node.Right_Child;
               X_Node    : constant Node_Index := Tree (Setting).Left_Child;
               Y_Node    : constant Node_Index := Tree (Setting).Right_Child;
               W_Node    : constant Node_Index := (if Y_Node > 0 then Tree (Y_Node).Next_Sibling else 0);
               H_Node    : constant Node_Index := (if W_Node > 0 then Tree (W_Node).Next_Sibling else 0);
            begin
               Register_Symbol ("", View_RS, View_RS, VK_Number, Sym_Scalar);
               Line ("let " & View_RS & ": AlbrVal = ALB_STATIC_VIEWPORT(" &
                     Expr (X_Node) & ", " & Expr (Y_Node) & ", " &
                     Expr (W_Node) & ", " & Expr (H_Node) & ");");
               New_Line_Emit;
            end;

         when AST_Bitmap_Font_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Font_Name      : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Font_RS        : constant String := Scoped_Name (Font_Name);
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

               Register_Symbol ("", Font_RS, Font_RS, VK_U64, Sym_Scalar);
               if Length (Descriptor_Text) > 0 then
                  Emit_Warn_Once ("bitmap-font-descriptor-" & Safe_Rust_Name (Font_RS),
                                  "BITMAP_FONT descriptor metadata is accepted but canvas text remains an approximation on ALBR");
               end if;
               Line ("let " & Font_RS & ": AlbrVal = ALB_DEFINE_BITMAP_FONT(" &
                     Escape_Rust_String (Font_Name) & ", " &
                     (if Length (Source_Text) > 0 then To_String (Source_Text) else Escape_Rust_String ("")) & ", " &
                     To_String (Format_Text) & ", " &
                     To_String (Glyph_Width) & ", " &
                     To_String (Glyph_Height) & ", " &
                     To_String (First_Char) & ", " &
                     To_String (Spacing_Text) & ");");
               New_Line_Emit;
            end;

         when AST_System_Font_Decl =>
            declare
               Name_Node       : constant Node_Index := Node.Left_Child;
               Font_Name       : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Font_RS         : constant String := Scoped_Name (Font_Name);
               Setting         : Node_Index := Node.Right_Child;
               Family_Text     : Unbounded_String := U (Escape_Rust_String (Font_Name));
               Size_Text       : Unbounded_String := U ("16");
               Weight_Text     : Unbounded_String := U (Escape_Rust_String ("normal"));
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

               Register_Symbol ("", Font_RS, Font_RS, VK_U64, Sym_Scalar);
               Line ("let " & Font_RS & ": AlbrVal = ALB_DEFINE_SYSTEM_FONT(" &
                     To_String (Family_Text) & ", " &
                     To_String (Size_Text) & ", " &
                     To_String (Weight_Text) & ", " &
                     "(alb_truthy(" & To_String (Anti_Alias_Text) & "))" & ", " &
                     To_String (Charset_Start) & ", " &
                     To_String (Charset_End) & ");");
               New_Line_Emit;
            end;

         when AST_Memory_Firewall_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               FW_RS     : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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
                              Append (Read_Text, Escape_Rust_String (Key));
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
                              Append (Write_Text, Escape_Rust_String (Key));
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

               Register_Symbol ("", FW_RS, FW_RS, VK_Number, Sym_Scalar);
               Line ("let " & FW_RS & ": AlbrVal = { kind: 'firewall', name: " &
                     Escape_Rust_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
                     ", denyAll: " & (if Deny_All then "true" else "false") &
                     ", read: new Set<string>([" & To_String (Read_Text) &
                     "]), write: new Set<string>([" & To_String (Write_Text) & "]) };");
               New_Line_Emit;
            end;

         when AST_Process_Handle_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Proc_JS   : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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
                              Append (Rights_Text, Escape_Rust_String (Raw_Feature_Atom (Right_Node)));
                              First_Right := False;
                              Right_Node := Tree (Right_Node).Next_Sibling;
                           end loop;
                        end;
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Proc_JS, Proc_JS, VK_U64, Sym_Scalar);
               Line ("let " & Proc_JS & ": i64 = ALB_PROCESS_DEFINE(" &
                     To_String (Image_Text) & ", [" &
                     To_String (Rights_Text) & "], " & To_String (Pid_Text) & ");");
               New_Line_Emit;
            end;

         when AST_Network_Sniffer_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Sniffer_Name   : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Sniffer_JS     : constant String := Scoped_Name (Sniffer_Name);
               Error_JS       : constant String := Scoped_Name (Sniffer_Name & "_ERROR");
               Setting        : Node_Index := Node.Right_Child;
               Interface_Text : Unbounded_String := U (Escape_Rust_String ("any"));
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

               Register_Symbol ("", Sniffer_JS, Sniffer_JS, VK_U64, Sym_Scalar);
               Register_Symbol ("", Error_JS, Error_JS, VK_U64, Sym_Scalar);
               Emit_Warn_Once ("network-sniffer-albr",
                               "NETWORK_SNIFFER is simulated on ALBR with deterministic sample packets");
               Line ("let " & Error_JS & ": AlbrVal = ALB_MAKE_CELL(0);");
               Line ("let " & Sniffer_JS & ": AlbrVal = ALB_SNIFFER_DEFINE(" &
                     To_String (Interface_Text) & ", " &
                     To_String (Protocol_Text) & ", " &
                     To_String (Port_Text) & ", " &
                     To_String (Buffer_Text) & ");");
               Line (Sniffer_JS & ".errorCell = " & Error_JS & ";");
               New_Line_Emit;
            end;

         when AST_Network_Socket_Decl =>
            declare
               Name_Node    : constant Node_Index := Node.Left_Child;
               Socket_JS    : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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

               Register_Symbol ("", Socket_JS, Socket_JS, VK_U64, Sym_Scalar);
               Line ("let " & Socket_JS & ": i64 = ALB_NET_DEFINE(" &
                     To_String (Protocol_Code) & ", " & To_String (Port_Val) & ", " &
                     To_String (Buffer_Val) & ");");
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
               Emit ("let " & Model_JS & ": AlbrVal = { states: " & To_String (States_Text) & ", matrix: [");
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
               Emit ("] };");
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
               Emit ("let " & Net_JS & ": AlbrVal = ALB_NN_CREATE(" &
                     Escape_Rust_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
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
               Emit ("]);");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Const_Decl =>
            --  Module-level `const NAME: i64 = N` is emitted by
            --  Emit_Package_Consts_Walk before fn main so #CONST refs resolve.
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               declare
                  R : constant String := To_String (Raw_Name);
                  Existing : Natural;
                  Const_RS : constant String :=
                    (if R'Length > 0 and then R (R'First) = '#'
                     then Safe_Rust_Name (R (R'First + 1 .. R'Last))
                     else Safe_Rust_Name (R));
               begin
                  Capacity := Eval_Static_Int (Value_Node);
                  Existing := Find_Symbol ("", Const_RS);
                  if Existing = 0 then
                     Register_Symbol
                       ("", Const_RS, Const_RS,
                        VK_Number, Sym_Const, Capacity => Capacity);
                  else
                     Symbols (Existing).Capacity := Capacity;
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
                  Rust_Name := U (Safe_Rust_Name (To_String (Raw_Name)));
                  declare
                     Existing : constant Natural :=
                       Find_Symbol ("", To_String (Rust_Name));
                  begin
                     if Existing = 0 then
                        Register_Symbol
                          ("", To_String (Rust_Name), To_String (Rust_Name),
                           VK_Number, Sym_Const, Capacity => Value);
                     else
                        Symbols (Existing).Capacity := Value;
                     end if;
                  end;
                  Value := Value + 1;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            end;

         when AST_Struct_Decl =>
            Register_Struct_From_Node (Index);
            declare
               Struct_Name : constant String := Safe_Rust_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
               Curr        : Node_Index := Tree (Node.Right_Child).Left_Child;
               First       : Boolean := True;
            begin
               Emit_Indent;
               Emit ("type " & Struct_Name & " = {");
               while Curr > 0 loop
                  if not First then
                     Emit ("; ");
                  end if;
                  declare
                     Field_Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                  begin
                     if Field_Name_Node > 0 then
                        Emit
                          (Safe_Rust_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)) &
                           ": " &
                           (if Tree (Curr).Token_Index > 0
                            then Type_Annotation_From_Name (Raw_Lexeme (Tree (Curr).Token_Index))
                            else "number"));
                     else
                        Emit ("alb_missing_field: i64");
                     end if;
                  end;
                  First := False;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
               Emit (" };");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Strict_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Rust_Name := U (Scoped_Name (To_String (Raw_Name)));
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
               Register_Symbol ("", To_String (Rust_Name), To_String (Rust_Name), Tag, Sym_Strict_Array, Rank, Dims, Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               Line (Vec_Decl_Line (To_String (Rust_Name), Tag, Trim_Image (Capacity)));
            end if;

         when AST_Slide_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Rust_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0
                       then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                       else VK_Number);
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (Rust_Name), To_String (Rust_Name), Tag, Sym_Slide_Array, 1, (1 => Capacity, others => 0), Capacity,
                                Active_Size => (if Tree (Node.Right_Child).Next_Sibling > 0 then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling) else Capacity),
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               Line (Vec_Decl_Line (To_String (Rust_Name), Tag, Trim_Image (Capacity)));
               Line ("alb_gscal_set(" & Escape_Rust_String (To_String (Rust_Name) & "_active") &
                     ", " &
                     Trim_Image ((if Tree (Node.Right_Child).Next_Sibling > 0
                                  then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling)
                                  else Capacity)) & ");");
            end if;

         when AST_Parallel_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Rust_Name := U (Scoped_Name (To_String (Raw_Name)));
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
                        Field_JS        : constant String := Safe_Rust_Name (To_String (Raw_Name) & "_" & Field_Name);
                        Field_Tag       : constant Value_Kind :=
                          (if Tree (Field_Name_Node).Right_Child > 0
                           then Type_From_Name (Raw_Lexeme (Tree (Tree (Field_Name_Node).Right_Child).Token_Index))
                           else VK_Number);
                     begin
                        Register_Symbol ("", To_String (Rust_Name) & "." & Field_Name, Field_JS, Field_Tag,
                                         Sym_Parallel_Field, Rank, Dims, Capacity,
                                         Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Field_Tag)));
                        Line (Vec_Decl_Line (Field_JS, Field_Tag, Trim_Image (Capacity)));
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
               Rust_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := VK_Number;
               end if;
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (Rust_Name), To_String (Rust_Name), Tag, Sym_Temporal,
                                History_Size => Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (Tag)));
               declare
                  TId : constant Natural := Find_Symbol ("", To_String (Rust_Name));
               begin
                  if TId /= 0 then
                     Symbols (TId).Aux_Offset := Allocate_Address_Bytes (Capacity * Element_Bytes (Tag));
                  end if;
               end;
               Line (Global_Scalar_Set
                       (To_String (Rust_Name), Tag,
                        Cast_Expr (Tag, Expr (Tree (Node.Right_Child).Next_Sibling))) & ";");
               if Tag in VK_String | VK_Binary then
                  Line ("alb_gstrarr_init(" & Escape_Rust_String (To_String (Rust_Name) & "_history") &
                        ", " & Trim_Image (Capacity) & ");");
               else
                  Line ("alb_garr_init(" & Escape_Rust_String (To_String (Rust_Name) & "_history") &
                        ", " & Trim_Image (Capacity) & ");");
               end if;
               Line ("alb_gscal_set(" & Escape_Rust_String (To_String (Rust_Name) & "_head") &
                     ", 0);");
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
                        Plain_Id  : constant Natural := Find_Symbol ("", Safe_Rust_Name (To_String (Raw_Name)));
                     begin
                        if Global_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Global_Id).Tag, False);
                        elsif Plain_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Plain_Id).Tag, False);
                        else
                           Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_Rust_Name (To_String (Raw_Name)), Tag, Sym_Scalar);
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
                           Struct_Name : constant String := Safe_Rust_Name (Raw_Lexeme (Node.Token_Index));
                           SIdx : constant Natural := Find_Struct (Struct_Name);
                        begin
                           Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Struct_Var,
                                            Struct_Name => Raw_Lexeme (Node.Token_Index),
                                            Offset_Bytes => (if SIdx /= 0 then Allocate_Address_Bytes (Structs (SIdx).Size_Bytes) else 0));
                        end;
                        declare
                           Struct_Name : constant String := Safe_Rust_Name (Raw_Lexeme (Node.Token_Index));
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
                                            To_String (Fields (I).JS_Field) & ": " &
                                            Default_Value
                                              (Fields (I).Tag,
                                               To_String (Fields (I).Type_Name)));
                                    Curr := Curr + 1;
                                 end if;
                              end loop;
                           end if;
                           Line
                             ("let mut " & Scoped_Name (To_String (Raw_Name)) &
                              ": " & Type_Annotation_From_Name (Raw_Lexeme (Node.Token_Index)) &
                              " = {" & To_String (Field_Text) & "};");
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
               Line ("return " & Expr (Node.Left_Child) & ";");
            else
               Line ("return;");
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
               Line ("if (alb_truthy(" & Expr (Node.Left_Child) & ")) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("} else {");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
                  Line ("}");
               else
                  Line ("}");
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
                                  "STRIDE nesting beyond 32 levels falls back to normal FOR stepping on ALBR");
                  Emit_Block (Body_Node);
               end if;
            end;

         when AST_Ratio_Space_Block =>
            Emit_Warn_Once ("ratio-space-albr",
                            "RATIO_SPACE pinning is approximated as ordinary Rust evaluation on ALBR");
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
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("let " & Width_Name & ": i64 = alb_max(1, alb_i64(" & To_String (Width_Text) & "));");
               Line ("let " & Height_Name & ": i64 = alb_max(1, alb_i64(" & To_String (Height_Text) & "));");
               Line ("let " & Limit_Name & ": i64 = alb_max(" & Width_Name & ", " & Height_Name & ");");
               Line ("let mut " & Code_Name & ": i64 = 0;");
               Line ("let mut " & Seen_Name & ": i64 = 0;");
               Line ("while " & Seen_Name & " < (" & Width_Name & " * " & Height_Name & ") {");
               Indent_Level := Indent_Level + 1;
               Line ("let mut " & X_Name & ": i64 = 0;");
               Line ("let mut " & Y_Name & ": i64 = 0;");
               Line ("let mut " & Bits_Name & ": i64 = " & Code_Name & ";");
               Line ("let mut " & Shift_Name & ": i64 = 0;");
               Line ("while " & Shift_Name & " < 16 {");
               Indent_Level := Indent_Level + 1;
               Line (X_Name & " |= (" & Bits_Name & " & 1) << " & Shift_Name & ";");
               Line (Bits_Name & " = " & Bits_Name & " >> 1;");
               Line (Y_Name & " |= (" & Bits_Name & " & 1) << " & Shift_Name & ";");
               Line (Bits_Name & " = " & Bits_Name & " >> 1;");
               Line ("if ((1i64 << (" & Shift_Name & " + 1)) > " & Limit_Name & " && " & Bits_Name & " == 0) { break; }");
               Line (Shift_Name & " += 1;");
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Line ("if " & X_Name & " >= " & Width_Name & " || " & Y_Name & " >= " & Height_Name & " { " &
                     Code_Name & " += 1; continue; }");
               Line ("MTX = " & X_Name & ";");
               Line ("MTY = " & Y_Name & ";");
               Line (Seen_Name & " += 1;");
               Line (Code_Name & " += 1;");
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
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
               Line ("if (alb_truthy(" & Expr (Node.Left_Child) & ")) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Then_Block);
               Indent_Level := Indent_Level - 1;
               if Else_Block > 0 then
                  Line ("} else {");
                  Indent_Level := Indent_Level + 1;
                  Emit_Block (Else_Block);
                  Indent_Level := Indent_Level - 1;
                  Line ("}");
               else
                  Line ("}");
               end if;
            end;

         when AST_While_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
            begin
               Line ("let mut " & Guard_Name & " = 0;");
               Line ("while alb_truthy(" & Expr (Node.Left_Child) & ") {");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " += 1; if " & Guard_Name & " > 500000 { break; }");
               Emit_Block (Node.Right_Child);
               Indent_Level := Indent_Level - 1;
               Line ("}");
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
               Var_Sym    : Symbol_Record := Resolve_Symbol (Var_Name);
               Var_JS     : constant String := Resolve_Var_Name (Var_Name);
               Step_Name  : constant String := Next_Temp_Name ("for_step");
               End_Name   : constant String := Next_Temp_Name ("for_end");
               Use_Gscal  : Boolean := False;
               Iter_Get   : Unbounded_String := U ("");
            begin
               Raw_Name := U (Var_Name);
               if Find_Symbol (To_String (Current_Routine), To_String (Raw_Name)) = 0
                 and then Find_Symbol ("", Scoped_Name (To_String (Raw_Name))) = 0
               then
                  if Length (Current_Routine) > 0 then
                     Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_Rust_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line ("let mut " & Safe_Rust_Name (To_String (Raw_Name)) & ": i64 = " & Cast_Expr (VK_Number, Start_Expr) & ";");
                     Var_Sym := Resolve_Symbol (Var_Name);
                  else
                     Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Var_Sym := Resolve_Symbol (Var_Name);
                  end if;
               end if;

               Use_Gscal := Var_Sym.Active and then Is_Global_Storage_Sym (Var_Sym)
                 and then Var_Sym.Kind in Sym_Scalar | Sym_Const | Sym_Temporal;
               if Use_Gscal then
                  Iter_Get := U (Global_Scalar_Get (To_String (Var_Sym.Rust_Name), Var_Sym.Tag));
               else
                  Iter_Get := U (Var_JS);
               end if;

               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("let " & Step_Name & ": i64 = alb_i64(" & Step_Expr & ");");
               Line ("let " & End_Name & ": i64 = alb_i64(" & End_Expr & ");");
               if Use_Gscal then
                  Line (Global_Scalar_Set
                          (To_String (Var_Sym.Rust_Name), Var_Sym.Tag,
                           Cast_Expr (Var_Sym.Tag, Start_Expr)) & ";");
               else
                  Line (Var_JS & " = alb_i64(" & Start_Expr & ");");
               end if;
               Line ("loop {");
               Indent_Level := Indent_Level + 1;
               Line ("if (if " & Step_Name & " >= 0 { " & To_String (Iter_Get) & " <= " & End_Name &
                     " } else { " & To_String (Iter_Get) & " >= " & End_Name & " }) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Node.Right_Child);
               if Use_Gscal then
                  Line (Global_Scalar_Set
                          (To_String (Var_Sym.Rust_Name), Var_Sym.Tag,
                           "(" & To_String (Iter_Get) & " + " & Step_Name & ")") & ";");
               else
                  Line (Var_JS & " += " & Step_Name & ";");
               end if;
               Indent_Level := Indent_Level - 1;
               Line ("} else { break; }");
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Foreach_Stmt =>
            declare
               Iterator_Raw  : constant String := Raw_Lexeme (Node.Token_Index);
               Iterator_JS   : constant String := Safe_Rust_Name (Iterator_Raw);
               Iterator_Scope : constant String :=
                 (if Length (Current_Routine) > 0 then To_String (Current_Routine) else "");
               Seq_Name      : constant String := Next_Temp_Name ("foreach_seq");
               Index_Name    : constant String := Next_Temp_Name ("foreach_ix");
               Length_Name   : constant String := Next_Temp_Name ("foreach_len");
               Guard_Name    : constant String := Next_Temp_Name ("guard");
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
                  then "alb_gscal_get(" & Escape_Rust_String (To_String (Sequence_Sym.Rust_Name) & "_active") & ")"
                  elsif Sequence_Sym.Active
                  then "alb_garr_len(" & Escape_Rust_String (To_String (Sequence_Sym.Rust_Name)) & ")"
                  else "0");
               Seq_Rust      : constant String :=
                 (if Sequence_Sym.Active then To_String (Sequence_Sym.Rust_Name)
                  else Expr (Sequence_Node));
            begin
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("let " & Length_Name & ": i64 = " & Sequence_Len & ";");
               Line ("let mut " & Guard_Name & " = 0;");
               Line ("let mut " & Index_Name & ": i64 = 0;");
               Line ("while " & Index_Name & " < " & Length_Name & " {");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " += 1; if " & Guard_Name & " > 500000 { break; }");
               Line ("let mut " & Iterator_JS & ": " & Primitive_Rust_Type (Item_Tag) & " = " &
                     Cast_Expr
                       (Item_Tag,
                        Global_Array_Get
                          (Seq_Rust, Item_Tag, "alb_idx(" & Index_Name & ")")) &
                     ";");
               Shadow_Id :=
                 Push_Shadow_Symbol
                   (Scope   => Iterator_Scope,
                    Name    => Iterator_Raw,
                    Rust_Name => Iterator_JS,
                    Tag     => Item_Tag);
               Emit_Block (Node.Right_Child);
               Pop_Shadow_Symbol (Shadow_Id);
               Line (Index_Name & " += 1;");
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Repeat_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
            begin
               Line ("let mut " & Guard_Name & " = 0;");
               Line ("loop {");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " += 1; if " & Guard_Name & " > 500000 { break; }");
               Emit_Block (Node.Left_Child);
               Line ("if alb_truthy(" & Expr (Node.Right_Child) & ") { break; }");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Break_Stmt =>
            Line ("break;");

         when AST_Continue_Stmt =>
            Line ("continue;");

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
                Line (Expr (Node.Left_Child) & ";");
             end if;

         when AST_On_Block =>
            --  Handlers are collected by Collect_Event_Blocks before main();
            --  do not emit or re-register here.
            null;

         when AST_Match_Stmt =>
            Emit_Switch_Stmt (Node.Left_Child, Node.Right_Child);

         when AST_Select_Stmt =>
            Emit_Switch_Stmt (Node.Left_Child, Node.Right_Child);

         when AST_SwapPop_Stmt =>
            Emit_SwapPop (Node.Left_Child, Node.Right_Child);

         when AST_Comptime_Block =>
            Line ("/* COMPTIME lowered to eager module-initialization code */");
            Line ("{");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            Line ("}");

         when AST_Find_Query | AST_Query | AST_Knows_Query =>
            Line (Expr (Index) & ";");

         when AST_Create_Window =>
            Saw_Create := True;
            declare
               Title_Node : constant Node_Index := Node.Left_Child;
               Pair_Node  : constant Node_Index := Node.Right_Child;
            begin
               Line ("ALB_CREATE_WINDOW(" &
                     Expr (Title_Node) & ", " &
                     Expr (Tree (Pair_Node).Left_Child) & ", " &
                     Expr (Tree (Pair_Node).Right_Child) & ");");
            end;

         when AST_Set_Fullscreen =>
            Line ("ALB_SET_FULLSCREEN(alb_truthy(" & Expr (Node.Left_Child) & "));");

         when AST_Set_Resizable =>
            Line ("ALB_SET_RESIZABLE(alb_truthy(" & Expr (Node.Left_Child) & "));");

         when AST_Set_Stretchy =>
            Line ("ALB_SET_STRETCHY(alb_truthy(" & Expr (Node.Left_Child) & "));");

         when AST_Tick =>
            Line ("albFrameInterval = alb_max(1, " & Expr (Node.Left_Child) & ");");

         when AST_Color =>
            Line ("ALB_COLOR(" & Expr (Node.Left_Child) & ");");

         when AST_Clear =>
            Line ("ALB_CLEAR(" & Expr (Node.Left_Child) & ");");

         when AST_Use_Font_Stmt =>
            Line ("ALB_SET_FONT(" & Expr (Node.Left_Child) & ");");

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
                     (if With_Node > 0 then "true" else "false") & ");");
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
                     (if Alpha_Mask then "true" else "false") & ");");
            end;

         when AST_Predict_Markov_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, False);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Emit_Firewall_Touch (Tree (Node.Right_Child).Next_Sibling, False, True);
            Line (Statement_Target_Name (Tree (Node.Right_Child).Next_Sibling) &
                  " = ALB_MARKOV_PREDICT(" &
                  Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Infer_Network_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, False);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Emit_Firewall_Touch (Tree (Node.Right_Child).Next_Sibling, False, True);
            Line ("ALB_NN_INFER(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ", " &
                  Statement_Target_Name (Tree (Node.Right_Child).Next_Sibling) & ");");

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
                     (if Epoch_Node > 0 then Expr (Epoch_Node) else "1") & ");");
            end;

         when AST_Export_PPM_Block =>
            declare
               Path_Node     : constant Node_Index := Node.Right_Child;
               Format_Node   : constant Node_Index := (if Path_Node > 0 then Tree (Path_Node).Next_Sibling else 0);
               Body_Node     : constant Node_Index := (if Format_Node > 0 then Tree (Format_Node).Next_Sibling else 0);
               Fallback_Node : constant Node_Index := (if Body_Node > 0 then Tree (Body_Node).Next_Sibling else 0);
               Status_Name   : constant String := Next_Temp_Name ("export_ppm");
            begin
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("const " & Status_Name & " = ALB_EXPORT_PPM(" &
                     Expr (Node.Left_Child) & ", " &
                     As_Text_Expr (Path_Node) & ", " &
                     Feature_Text_Expr (Format_Node) & ");");
               Line ("if (" & Status_Name & " != 0) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("} else {");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
                  Line ("}");
               else
                  Line ("}");
               end if;
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Fits_Cube_Block =>
            Emit_Warn_Once ("fits-cube-albr",
                            "FITS_CUBE is not implemented on ALBR yet; running FALLBACK when present");
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
                  Line ("const " & Embed_Name & ": String | null = null;");
               end if;

               Line ("{");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Line ("const " & Table_Name & ": Array<{ key: String; apply: (value: i64) => void }> = [");
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
                        Line ("{ key: " & Escape_Rust_String (Lower_Key) &
                              ", apply: (value: i64) => { " &
                              Statement_Target_Name (Target_Var) &
                              " = value; } },");
                     end;
                  end if;
                  Entry_Node := Tree (Entry_Node).Next_Sibling;
               end loop;
               Indent_Level := Indent_Level - 1;
               Line ("];");
               Line ("if (ALB_INI_BIND(" & As_Text_Expr (Path_Node) & ", " & Embed_Name & ", " & Table_Name & ") == 0) {");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Emit_Fallback_Body (Fallback_Node);
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Stream_Bypass_Block =>
            Emit_Warn_Once ("stream-bypass-albr",
                            "STREAM_BYPASS is ignored on ALBR; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
              and then Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body
                 (Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling);
            end if;

         when AST_Synth_Bake_Block =>
            Emit_Warn_Once ("synth-bake-albr",
                            "SYNTH_BAKE is not implemented on ALBR yet; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Mount_Archive_Block =>
            Emit_Warn_Once ("mount-archive-albr",
                            "MOUNT_ARCHIVE is not available on ALBR; running FALLBACK when present");
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
                  Statement_Target_Name (Node.Right_Child) & ");");

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
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 0, 6);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 6, 6);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 12, 2);");
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
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 26, 4);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 30, 4);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 23, 1);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 16, 2);");
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
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 34, 2);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 36, 2);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 38, 4);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 42, 4);");
               end if;
            end;

         when AST_Network_Listen_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("ALB_NET_LISTEN(" & Expr (Node.Left_Child) & ");");

         when AST_Network_Accept_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line (Statement_Target_Name (Node.Right_Child) &
                  " = ALB_NET_ACCEPT(" & Expr (Node.Left_Child) & ");");

         when AST_Network_Receive_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("ALB_NET_RECEIVE(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Network_Send_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Line ("ALB_NET_SEND(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_Network_Close_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("ALB_NET_CLOSE(" & Expr (Node.Left_Child) & ");");

         when AST_Read_Process_Memory_Stmt =>
            declare
               Addr_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Raw  : constant String := Raw_Feature_Atom (Target_Node);
               Target_Sym  : constant Symbol_Record := Resolve_Symbol (Target_Raw);
            begin
               if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field then
                  Line ("ALB_PROCESS_READ_BUFFER(" & Expr (Node.Left_Child) & ", " &
                        Expr (Addr_Node) & ", " & Statement_Target_Name (Target_Node) & ");");
               else
                  Line (Statement_Target_Name (Target_Node) & " = ALB_PROCESS_READ_SCALAR(" &
                        Expr (Node.Left_Child) & ", " & Expr (Addr_Node) & ");");
               end if;
            end;

         when AST_Write_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_WRITE_SCALAR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ");");
            end;

         when AST_Monitor_Process_Memory_Stmt =>
            declare
               Addr_Node    : constant Node_Index := Node.Right_Child;
               Type_Node    : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Node  : constant Node_Index := (if Type_Node > 0 then Tree (Type_Node).Next_Sibling else 0);
               Change_Node  : constant Node_Index := (if Target_Node > 0 then Tree (Target_Node).Next_Sibling else 0);
            begin
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("let __alb_monitor_value = { value: Number(" & Expr (Target_Node) & ") };");
               Line ("let __alb_monitor_change = { value: Number(" & Expr (Change_Node) & ") };");
               Line ("ALB_PROCESS_MONITOR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", __alb_monitor_value, __alb_monitor_change);");
               Line (Statement_Target_Name (Target_Node) & " = __alb_monitor_value.value;");
               Line (Statement_Target_Name (Change_Node) & " = __alb_monitor_change.value;");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Dump_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Size_Node  : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Path_Node  : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_DUMP(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Size_Node) & ", " &
                     Expr (Path_Node) & ");");
            end;

         when AST_Terminate_Process_Stmt =>
            Line ("if (albProcessTable[" & Expr (Node.Left_Child) &
                  " | 0]) albProcessTable[" & Expr (Node.Left_Child) & " | 0].alive = false;");

         when AST_Create_Process_Stmt =>
            declare
               Args_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Args_Node > 0 then Tree (Args_Node).Next_Sibling else 0);
            begin
               Line (Statement_Target_Name (Target_Node) &
                     " = ALB_PROCESS_CREATE(" & Expr (Node.Left_Child) & ", " &
                     (if Args_Node > 0 then Expr (Args_Node) else """""") & ");");
            end;

         when AST_Elevate_Privileges_Stmt =>
            Line ("ALB_PROCESS_ELEVATE(" & Expr (Node.Left_Child) & ");");

         when AST_Hack_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_WRITE_SCALAR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ");");
            end;

         when AST_Inject_Code_Memory_Stmt | AST_Inject_Code_Stmt =>
            declare
               Payload_Node : constant Node_Index := Node.Right_Child;
               Target_Node  : constant Node_Index := (if Payload_Node > 0 then Tree (Payload_Node).Next_Sibling else 0);
            begin
               if Target_Node > 0 then
                  Line (Statement_Target_Name (Target_Node) & " = 0;");
               end if;
            end;

         when AST_Hijack_Process_Memory_Stmt =>
            declare
               Addr_Node    : constant Node_Index := Node.Right_Child;
               Detour_Node  : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Node  : constant Node_Index := (if Detour_Node > 0 then Tree (Detour_Node).Next_Sibling else 0);
            begin
               if Target_Node > 0 then
                  Line (Statement_Target_Name (Target_Node) & " = 0;");
               end if;
            end;

         when AST_Sniff_Network_Stmt =>
            Line ("ALB_PROCESS_SNIFF(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Encrypt_File_Stmt | AST_Decrypt_File_Stmt =>
            declare
               Key_Node  : constant Node_Index := Node.Right_Child;
               Path_Node : constant Node_Index := (if Key_Node > 0 then Tree (Key_Node).Next_Sibling else 0);
            begin
               Line ("ALB_FILE_XOR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Key_Node) & ", " & Expr (Path_Node) & ");");
            end;

         when AST_Print_Stmt =>
            if Node.Left_Child > 0 then
               Line ("ALB_PRINT(" & As_Text_Expr (Node.Left_Child) & ");");
            else
               Line ("ALB_PRINT("""");");
            end if;

         when AST_Locate_Stmt =>
            Line ("ALB_LOCATE(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_Print_Str_Stmt =>
            if Node.Left_Child > 0 then
               Line ("ALB_PRINT_RAW(" & As_Text_Expr (Node.Left_Child) & ");");
            else
               Line ("ALB_PRINT_RAW("""");");
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
                           To_String (Args (2)) & ", " & To_String (Args (3)) & ");");
                  end if;
               elsif Node.Kind = AST_Plot then
                  if Count >= 2 then
                     Line ("ALB_PLOT(" & To_String (Args (1)) & ", " & To_String (Args (2)) & ");");
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
                        Call_Name := U ("/* unsupported draw primitive */");
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
                        Line (Call_Text & "(" & To_String (Arg_Text) & ");");
                     end;
                  else
                     Line (To_String (Call_Name));
                  end if;
               end if;
            end;

         when AST_Msg_Box =>
            Line ("ALB_MSG_BOX(" & Expr (Node.Left_Child) &
                  (if Node.Right_Child > 0 then ", " & Expr (Node.Right_Child) else "") &
                  ");");

         when AST_Listen =>
            Saw_Listen := True;

         when AST_Cease =>
            Line ("ALB_CEASE();");

         when AST_Play_Sound =>
            Line ("ALB_PLAY_SOUND(" & Expr (Node.Left_Child) & ");");

         when AST_Play_Music =>
            Line ("ALB_PLAY_MUSIC(" & Expr (Node.Left_Child) & ");");

         when AST_Play_Music_From =>
            Line ("void ALB_PLAY_MUSIC_FROM(" & Expr (Node.Left_Child) & ");");

         when AST_Input_Stmt =>
            Line (Statement_Target_Name (Node.Right_Child) & " = ALB_PROMPT_TEXT(" &
                  (if Node.Left_Child > 0 then Expr (Node.Left_Child) else """""") &
                  ");");

         when AST_Readline_Stmt =>
            if Node.Left_Child > 0 then
               Line (Statement_Target_Name (Node.Left_Child) &
                     " = ALB_READLINE_TEXT();");
            else
               Line ("ALB_READLINE_TEXT();");
            end if;

         when AST_File_Open =>
            Line ("/* file open expression should be used in LET/assignment context */");

         when AST_File_Close =>
            Line ("ALB_Close(" & Expr (Node.Left_Child) & ");");

         when AST_File_Write =>
            Line ("ALB_Write(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Load_Stmt =>
            declare
               Target_Sym : constant Symbol_Record := Target_Symbol (Node.Right_Child);
            begin
               if Target_Sym.Active
                 and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
               then
                  Line ("ALB_LoadBuffer(" & Expr (Node.Left_Child) & ", " &
                        Statement_Target_Name (Node.Right_Child) & ");");
               else
                  Line (Statement_Target_Name (Node.Right_Child) & " = ALB_LoadTextBuffer(" &
                        Expr (Node.Left_Child) & ");");
               end if;
            end;

         when AST_Flush_Stmt =>
            if Tree (Node.Left_Child).Next_Sibling > 0 then
               Line ("ALB_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ", " &
                     Expr (Tree (Node.Left_Child).Next_Sibling) & ");");
            else
               Line ("ALB_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ");");
            end if;

         when AST_Poke_Stmt =>
            Line ("ALB_POKE(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Save_State =>
            Line ("ALB_SAVE_STATE();");

         when AST_Load_State =>
            Line ("ALB_LOAD_STATE();");

         when AST_Claim_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ALB_CLAIM();");

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
               Line ("ALB_BIND(" & To_String (Args) & ");");
            end;

         when AST_Drop_Stmt =>
            Line ("ALB_DROP(" & Expr (Node.Left_Child) & ");");

         when AST_Sweep_Stmt =>
            Line ("ALB_SWEEP(" & Expr (Node.Left_Child) & ");");

         when AST_Knows_Fact =>
            Line ("ALB_KNOWS_SET(" &
                  Escape_Rust_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                  ", " & Expr (Node.Right_Child) & ");");

         when AST_Assert_Stmt =>
            Line
              ("ALB_REL_SET(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0, 1);");

         when AST_Retract_Stmt =>
            Line
              ("ALB_REL_RETRACT(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0);");

         when AST_Update_Stmt =>
            Line ("ALB_REL_SET(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Predicate_Arity_Expr (Node.Left_Child) & ", " &
                  Predicate_Arg1_Expr (Node.Left_Child) &
                  ", 0, 0, 0, " & Expr (Node.Right_Child) & ");");

         when AST_Findall_Query =>
            Line ("ALB_REL_FINDALL1(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

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
                     Line ("{ let mut __adv: i64 = 0; while __adv < (" & Count_Expr & ") {");
                     Indent_Level := Indent_Level + 1;
                     Line ("alb_gscal_set(" & Escape_Rust_String (To_String (Symbols (I).Rust_Name) & "_head") &
                           ", (alb_gscal_get(" & Escape_Rust_String (To_String (Symbols (I).Rust_Name) & "_head") &
                           ") + 1) % " & Trim_Image (Symbols (I).History_Size) & ");");
                     Line ("let __hix = alb_idx(alb_gscal_get(" &
                           Escape_Rust_String (To_String (Symbols (I).Rust_Name) & "_head") & "));");
                     Line (Global_Array_Set
                             (To_String (Symbols (I).Rust_Name) & "_history",
                              Symbols (I).Tag,
                              "__hix",
                              Global_Scalar_Get
                                (To_String (Symbols (I).Rust_Name), Symbols (I).Tag)) & ";");
                     Line ("__adv += 1;");
                     Indent_Level := Indent_Level - 1;
                     Line ("} }");
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
                  Line ("ALB_SET_ALPHA(" & A1 & ", " & To_String (A2) & ");");
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
               Line ("ALB_SET_CLIP(" & To_String (A1) & ", " & To_String (A2) & ", " & To_String (A3) & ", " & To_String (A4) & ");");
            end;

         when AST_Set_Origin =>
            declare
               Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
               A1, A2 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); end if;
               Line ("ALB_SET_ORIGIN(" & To_String (A1) & ", " & To_String (A2) & ");");
            end;

         when AST_Delay_Stmt =>
            Line ("ALB_Delay(" & Expr (Node.Left_Child) & ");");

         when AST_Try_Stmt =>
            Line ("try {");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            if Node.Right_Child > 0 then
               Line ("} catch (__alb_err) {");
               Indent_Level := Indent_Level + 1;
               declare
                  Catch_Name : constant String :=
                    (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
                  Catch_JS   : constant String := Safe_Rust_Name (Catch_Name);
                  Catch_Id   : Natural := 0;
               begin
                  if Catch_Name'Length > 0 then
                     Line ("const " & Catch_JS &
                           ": String = String((__alb_err instanceof Error) ? __alb_err.message : __alb_err);");
                     Catch_Id :=
                       Push_Shadow_Symbol
                         (Scope   => To_String (Current_Routine),
                          Name    => Catch_Name,
                          Rust_Name => Catch_JS,
                          Tag     => VK_String);
                  end if;
                  Emit_Block (Node.Right_Child);
                  Pop_Shadow_Symbol (Catch_Id);
               end;
               Indent_Level := Indent_Level - 1;
               Line ("}");
            else
               Line ("} catch (_e) {}");
            end if;

         when AST_Throw_Stmt =>
            Line ("panic!(""{}"", " & Expr (Node.Left_Child) & ");");

         when AST_Runtime_Assert =>
            Line ("if !alb_truthy(" & Expr (Node.Left_Child) &
                  ") { ALB_FATAL(&format!(""runtime assert failed"")); }");

         when AST_Reversible_Block | AST_Atomic_Block =>
            Emit_Block (Node.Left_Child);

         when AST_Rev_Add_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " += " & Expr (Node.Right_Child) & ";");
         when AST_Rev_Sub_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " -= " & Expr (Node.Right_Child) & ";");
         when AST_Rev_Xor_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " ^= " & Expr (Node.Right_Child) & ";");
         when AST_Rev_Rol_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ((" & Statement_Target_Name (Node.Left_Child) &
                  " << " & Expr (Node.Right_Child) & ") | (" & Statement_Target_Name (Node.Left_Child) &
                  " >> (32 - (" & Expr (Node.Right_Child) & ")))) as i64;");
         when AST_Rev_Ror_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ((" & Statement_Target_Name (Node.Left_Child) &
                  " >> " & Expr (Node.Right_Child) & ") | (" & Statement_Target_Name (Node.Left_Child) &
                  " << (32 - (" & Expr (Node.Right_Child) & ")))) as i64;");
         when AST_Rev_Swap_Stmt =>
            Line ("{ let __tmp = " & Statement_Target_Name (Node.Left_Child) & "; " &
                  Statement_Target_Name (Node.Left_Child) & " = " & Statement_Target_Name (Node.Right_Child) &
                  "; " & Statement_Target_Name (Node.Right_Child) & " = __tmp; }");
         when AST_Rev_Not_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ~" & Statement_Target_Name (Node.Left_Child) & ";");
         when AST_Rev_Neg_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = -" & Statement_Target_Name (Node.Left_Child) & ";");

         when AST_Spawn_Stmt =>
            if Node.Left_Child > 0 then
               Line (Expr (Node.Left_Child) & ";");
            end if;
         when AST_Sync_Stmt =>
            null;

         when AST_BinOp =>
            Line (Expr (Index) & ";");

         when AST_Enable_Typescript_Block =>
            Line (Raw_Lexeme (Node.Token_Index));

         when AST_Enable_Ada_Block | AST_Enable_Java_Block | AST_Enable_Asm | AST_Disable_Asm | AST_Asm_Block | AST_Predicate_Decl | AST_Case_Stmt | AST_Horn_Clause | AST_Fact | AST_Predicate | AST_Logic_Var | AST_Inline_Asm_Expr | AST_Inline_Ada_Expr | AST_Inline_Java_Expr | AST_Read_Pixel | AST_Array_Assign | AST_Array_Access | AST_Simd_Intrinsic | AST_Cut_Stmt | AST_Str_Concat | AST_Param_Decl | AST_Require_Clause | AST_Ensure_Clause | AST_String_Decl | AST_Bitfield_Decl | AST_SYS_RENDERER | AST_Atom | AST_FILE_READ =>
            Line ("// unsupported or backend-specific node: " & Node_Kind'Image (Node.Kind));

         when others =>
            Line ("// TODO node: " & Node_Kind'Image (Node.Kind));
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

      procedure Emit_One_Package_Const (Const_Name : String; Value : Integer) is
         Existing     : constant Natural := Find_Symbol ("", Const_Name);
         Saved_Indent : constant Natural := Indent_Level;
      begin
         Indent_Level := 0;
         if Existing = 0 then
            Register_Symbol
              ("", Const_Name, Const_Name, VK_Number, Sym_Const, Capacity => Value);
            Line ("const " & Const_Name & ": i64 = " & Trim_Image (Value) & ";");
         else
            Symbols (Existing).Capacity := Value;
         end if;
         Indent_Level := Saved_Indent;
      end Emit_One_Package_Const;

      procedure Emit_Package_Consts_Walk (First : Node_Index) is
         Curr : Node_Index := First;
      begin
         while Curr > 0 loop
            case Tree (Curr).Kind is
               when AST_Program | AST_Block_Stmt =>
                  Emit_Package_Consts_Walk (Tree (Curr).Left_Child);
               when AST_Module | AST_DeclareModule =>
                  Emit_Package_Consts_Walk (Tree (Curr).Right_Child);
               when AST_Const_Decl =>
                  declare
                     Target_Node : constant Node_Index := Tree (Curr).Left_Child;
                     Value_Node  : constant Node_Index := Tree (Curr).Right_Child;
                  begin
                     if Target_Node > 0 and then Tree (Target_Node).Token_Index > 0 then
                        declare
                           R : constant String :=
                             Raw_Lexeme (Tree (Target_Node).Token_Index);
                           Const_RS : constant String :=
                             (if R'Length > 0 and then R (R'First) = '#'
                              then Safe_Rust_Name (R (R'First + 1 .. R'Last))
                              else Safe_Rust_Name (R));
                        begin
                           Emit_One_Package_Const
                             (Const_RS, Eval_Static_Int (Value_Node));
                        end;
                     end if;
                  end;
               when AST_Enum_Decl =>
                  declare
                     Member : Node_Index := Tree (Curr).Left_Child;
                     Value  : Integer := 0;
                  begin
                     while Member > 0 loop
                        if Tree (Member).Token_Index > 0 then
                           Emit_One_Package_Const
                             (Safe_Rust_Name (Raw_Lexeme (Tree (Member).Token_Index)),
                              Value);
                        end if;
                        Value := Value + 1;
                        Member := Tree (Member).Next_Sibling;
                     end loop;
                  end;
               when AST_Procedure_Decl | AST_Function_Decl =>
                  null;
               when others =>
                  null;
            end case;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Package_Consts_Walk;

      procedure Collect_Event_Blocks
        (First       : Node_Index;
         Stop_Before : Node_Index)
      is
         Curr : Node_Index := First;
      begin
         while Curr > 0 loop
            exit when Stop_Before /= 0 and then Curr = Stop_Before;
            if Tree (Curr).Kind = AST_On_Block
              and then Tree (Curr).Token_Index > 0
            then
               Remember_Event_Block
                 (Tokens (Tree (Curr).Token_Index).Kind,
                  Tree (Curr).Left_Child);
            end if;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Collect_Event_Blocks;

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
         --  #CONST / ENUM must be module-level Rust `const` before fn main.
         Emit_Package_Consts_Walk (Root_Index);
         New_Line_Emit;
         Stmt_First := Statement_List_First (Root_Index);
         Listen_Idx := Find_Listen_Stmt (Stmt_First);
         --  Defer executable top-level into fn main below. Emit procedure /
         --  function decls now so they remain at module scope.
         declare
            Curr : Node_Index := Stmt_First;
         begin
            while Curr > 0 loop
               exit when Listen_Idx /= 0 and then Curr = Listen_Idx;
               if Tree (Curr).Kind = AST_Procedure_Decl
                 or else Tree (Curr).Kind = AST_Function_Decl
                 or else Tree (Curr).Kind = AST_Import_DLL
                 or else Tree (Curr).Kind = AST_Import_SO
                 or else Tree (Curr).Kind = AST_Import_Dylib
                 or else Tree (Curr).Kind = AST_Import_Jar
               then
                  Emit_Node (Curr);
               end if;
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         end;
         Collect_Event_Blocks (Stmt_First, Listen_Idx);
      elsif Root.Kind /= AST_Null then
         Line ("// ALBR warning: could not recover top-level root index for " &
               Node_Kind'Image (Root.Kind));
      end if;

      Emit_Address_Routines;
      Emit_State_Routines;
      Emit_Logic_Setup;
      --  Event handlers emitted inside main() after INCLUDE module procs so
      --  nested Rust fns (StrawBerry_Render, etc.) are in scope.
      Emit_Module_Exports;
      Emit_Foreign_Loaders;

      New_Line_Emit;
      Line ("fn ALB_ProgramShutdown() {");
      Indent_Level := Indent_Level + 1;
      Line ("if ALB_SHUTDOWN.with(|s| *s.borrow()) { return; }");
      Line ("ALB_SHUTDOWN.with(|s| { *s.borrow_mut() = true; });");
      Line ("ALB_RUNNING.with(|r| { *r.borrow_mut() = false; });");
      if Listen_Idx > 0 then
         Emit_Top_Level_Range (Tree (Listen_Idx).Next_Sibling, 0);
      end if;
      Line ("ALB_SDL_Shutdown();");
      Indent_Level := Indent_Level - 1;
      Line ("}");

      New_Line_Emit;
      Line ("fn main() {");
      Indent_Level := Indent_Level + 1;
      if Root_Index > 0 and then Stmt_First > 0 then
         declare
            Curr : Node_Index := Stmt_First;
         begin
            while Curr > 0 loop
               exit when Listen_Idx /= 0 and then Curr = Listen_Idx;
               if Tree (Curr).Kind /= AST_Procedure_Decl
                 and then Tree (Curr).Kind /= AST_Function_Decl
                 and then Tree (Curr).Kind /= AST_Import_DLL
                 and then Tree (Curr).Kind /= AST_Import_SO
                 and then Tree (Curr).Kind /= AST_Import_Dylib
                 and then Tree (Curr).Kind /= AST_Import_Jar
               then
                  Emit_Node (Curr);
               end if;
               Curr := Tree (Curr).Next_Sibling;
            end loop;
         end;
      end if;
      Emit_Event_Handler ("ALB_ON_TICK", Tick_Blocks, Tick_Block_Count);
      Emit_Event_Handler ("ALB_ON_PAINT", Paint_Blocks, Paint_Block_Count);
      Emit_Event_Handler ("ALB_ON_KEY", Key_Blocks, Key_Block_Count);
      if Saw_Create or else Saw_Listen or else Tick_Block_Count > 0
        or else Paint_Block_Count > 0 or else Key_Block_Count > 0
      then
         Line ("ALB_PREPARE_FRAME();");
         Line ("ALB_RunFrame_loop();");
      elsif Need_Wasm_Loaders then
         Line ("// WASM loaders stubbed on ALBR");
      end if;
      Indent_Level := Indent_Level - 1;
      Line ("}");

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

end Emit_Native_Rust;
