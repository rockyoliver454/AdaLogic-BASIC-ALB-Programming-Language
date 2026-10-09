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

--  ALBC3 native C3 (c3c) emitter. Mirrors TypeScript/Lua AST coverage +
--  FASM feature surface. Mutability via typed locals; ALB | => alb_concat.
--  Target: c3c / std. Brand ALBC3. Wired via albc3.adb.
package body Emit_Native_C3 is

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
   --  (+ optional EXPORT_WASM) facades fit in one web library weave.
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
      C3_Name   : Unbounded_String := To_Unbounded_String ("");
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
      C3_Name      : Unbounded_String := To_Unbounded_String ("");
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
      C3_Name     : Unbounded_String := To_Unbounded_String ("");
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
   function Escape_C3_String (Text : String) return String;
   function Resolve_Symbol (Raw : String) return Symbol_Record;
   function Target_Symbol (Target_Node : Node_Index) return Symbol_Record;
   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String;

   function Safe_C3_Name (Name : String) return String is
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
        Upper = "FN" or else
        Upper = "FUNCTION" or else
        Upper = "IF" or else
        Upper = "IMPORT" or else
        Upper = "LET" or else
        Upper = "MODULE" or else
        Upper = "RETURN" or else
        Upper = "STRUCT" or else
        Upper = "SWITCH" or else
        Upper = "TYPE" or else
        Upper = "VAR" or else
        Upper = "VOID" or else
        Upper = "WHILE" or else
        Upper = "WORKER" or else
        --  C3 reserved / stdlib collisions (fn-param aliases reject these)
        Upper = "FRICTION" or else
        Upper = "RESTITUTION" or else
        Upper = "SX" or else
        Upper = "SY" or else
        Upper = "SZ" or else
        Upper = "CX" or else
        Upper = "CY" or else
        Upper = "CZ";

      if Needs_Prefix then
         declare
            Prefixed : constant String := "alb_" & To_String (Result);
         begin
            return Ada.Characters.Handling.To_Lower (Prefixed);
         end;
      end if;

      return Ada.Characters.Handling.To_Lower (To_String (Result));
   end Safe_C3_Name;

   --  C3 type/struct names must start with an uppercase letter.
   function Safe_C3_Type_Name (Name : String) return String is
      Base : constant String := Safe_C3_Name (Name);
   begin
      if Base'Length = 0 then
         return "Alb_Anon";
      end if;
      declare
         First : constant Character := Ada.Characters.Handling.To_Upper (Base (Base'First));
      begin
         if Base'Length = 1 then
            return (1 => First);
         end if;
         return First & Base (Base'First + 1 .. Base'Last);
      end;
   end Safe_C3_Type_Name;

   function Scoped_Name (Name : String) return String is
   begin
      if Length (Current_Module) = 0 then
         return Safe_C3_Name (Name);
      else
         return Safe_C3_Name (To_String (Current_Module) & "_" & Name);
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
      return "__alb_" & Safe_C3_Name (Prefix) & "_" & Trim_Image (Integer (Temp_Name_Counter));
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
      elsif T = "F32" or else T = "SINGLE" or else T = "FLOAT" then
         --  Same storage model as F64 in the C3 runtime (alb_gf64_* /
         --  float FFI). Without this, AS F32 fell through to VK_Struct and
         --  emitted invalid `long name: F32 = {}` declarations.
         return VK_F64;
      elsif T = "FLOAT2" or else T = "F32X2" or else
        T = "FLOAT4" or else T = "F32X4" or else
        T = "MAT2" or else T = "MAT2X2" or else
        T = "MAT3" or else T = "MAT3X3" or else
        T = "MAT4" or else T = "MAT4X4"
      then
         return VK_Struct;
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

   function Primitive_C3_Type (Kind : Value_Kind) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "bool";
         when VK_String | VK_Binary =>
            return "String";
         when VK_F64 =>
            --  Explicit REAL/f64 stays floating; other numeric kinds unify to long.
            return "double";
         when VK_U128 =>
            return "long";
         when VK_U8 | VK_U16 | VK_U32 | VK_U64
            | VK_S8 | VK_S16 | VK_S32
            | VK_HW8 | VK_HW16 | VK_HW32
            | VK_Number | VK_Pure | VK_Unknown =>
            return "long";
         when others =>
            return "long";
      end case;
   end Primitive_C3_Type;

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
                  return Safe_C3_Type_Name (Struct_Name) & "{}";
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
         return "double[]";
      elsif Kind = VK_Struct then
         return Safe_C3_Type_Name (Name);
      else
         return Primitive_C3_Type (Kind);
      end if;
   end Type_Annotation_From_Name;

   function Cast_Expr
     (Kind : Value_Kind;
      Expr : String;
      From : Value_Kind := VK_Unknown) return String is
   begin
      case Kind is
         when VK_Boolean =>
            if From = VK_Boolean then
               return Expr;
            end if;
            return "alb_truthy((long)(" & Expr & "))";
         when VK_String | VK_Binary =>
            if From in VK_String | VK_Binary then
               return "alb_text_s(" & Expr & ")";
            end if;
            return "alb_text((long)(" & Expr & "))";
         when VK_U8 =>
            return "albu8(" & Expr & ")";
         when VK_U16 =>
            return "albu16(" & Expr & ")";
         when VK_S8 =>
            return "albi8(" & Expr & ")";
         when VK_S16 =>
            return "albi16(" & Expr & ")";
         when VK_U32 | VK_U64 =>
            if From in VK_String | VK_Binary then
               return "albu32(alb_i64_s(" & Expr & "))";
            end if;
            return "albu32(" & Expr & ")";
         when VK_S32 | VK_HW8 | VK_HW16 | VK_HW32 =>
            if From in VK_String | VK_Binary then
               return "albi32(alb_i64_s(" & Expr & "))";
            end if;
            return "albi32(" & Expr & ")";
         when VK_F64 =>
            if From in VK_String | VK_Binary then
               return "0.0";
            end if;
            --  Preserve floating literals / doubles; avoid long truncation.
            return "(double)(" & Expr & ")";
         when VK_Number | VK_Pure | VK_Unknown =>
            --  Unified i64 numeric lane. Macro alb_i64 casts numeric types;
            --  String sources go through alb_i64_s (compile-clean stub).
            if From in VK_String | VK_Binary then
               return "alb_i64_s(" & Expr & ")";
            end if;
            return "alb_i64(" & Expr & ")";
         when VK_U128 =>
            return "alb_i128((long)(" & Expr & "))";
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
                  if Raw = "left" or else Raw = "left$"
                    or else Raw = "right" or else Raw = "right$"
                    or else Raw = "mid" or else Raw = "mid$"
                    or else Raw = "concat" or else Raw = "TYPEOF"
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
         when AST_BinOp =>
            if Node.Token_Index > 0
              and then Tokens (Node.Token_Index).Kind = Tok_Pipe
            then
               return VK_String;
            end if;
            return VK_Unknown;
         when AST_Str_Concat | AST_Str_Left | AST_Str_Right | AST_Str_Mid =>
            return VK_String;
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
                  return Raw = "f64" or else Raw = "REAL";
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
         when VK_F64 =>
            return "f64";
         when others =>
            return "long";
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
         return "alb_gstrarr_init(" & Escape_C3_String (Name) & ", " &
           Capacity_Text & ");";
      else
         return "alb_garr_init(" & Escape_C3_String (Name) & ", " &
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
         return "alb_gstrarr_get(" & Escape_C3_String (Name) & ", " & Idx & ")";
      else
         return "alb_garr_get(" & Escape_C3_String (Name) & ", " & Idx & ")";
      end if;
   end Global_Array_Get;

   function Global_Array_Set
     (Name  : String;
      Kind  : Value_Kind;
      Idx   : String;
      Value : String) return String is
   begin
      if Kind in VK_String | VK_Binary then
         return "alb_gstrarr_set(" & Escape_C3_String (Name) & ", " & Idx &
           ", " & Value & ")";
      else
         return "alb_garr_set(" & Escape_C3_String (Name) & ", " & Idx &
           ", " & Value & ")";
      end if;
   end Global_Array_Set;

   function Global_Scalar_Get (Name : String; Kind : Value_Kind) return String is
   begin
      if Kind in VK_String | VK_Binary then
         return "alb_gstr_get(" & Escape_C3_String (Name) & ")";
      elsif Kind = VK_F64 then
         return "alb_gf64_get(" & Escape_C3_String (Name) & ")";
      else
         return "alb_gscal_get(" & Escape_C3_String (Name) & ")";
      end if;
   end Global_Scalar_Get;

   function Global_Scalar_Set
     (Name  : String;
      Kind  : Value_Kind;
      Value : String) return String is
   begin
      if Kind in VK_String | VK_Binary then
         return "alb_gstr_set(" & Escape_C3_String (Name) & ", " & Value & ")";
      elsif Kind = VK_F64 then
         return "alb_gf64_set(" & Escape_C3_String (Name) & ", " & Value & ")";
      else
         return "alb_gscal_set(" & Escape_C3_String (Name) & ", " & Value & ")";
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

   function Find_Routine (C3_Name : String) return Natural is
   begin
      for I in 1 .. Routine_Count loop
         if Routines (I).Active and then To_String (Routines (I).C3_Name) = C3_Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Routine;

   procedure Register_Symbol
     (Scope        : String;
      Name         : String;
      C3_Name      : String;
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
         Symbols (Symbol_Count).C3_Name := U (C3_Name);
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
      C3_Name     : String;
      Param_Count : Natural;
      Param_Modes : Param_Mode_List) is
      Existing : constant Natural := Find_Routine (C3_Name);
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
         Routines (Routine_Count).C3_Name := U (C3_Name);
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
      C3_Name : String;
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
      Symbols (Symbol_Count).C3_Name := U (C3_Name);
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
            return To_String (Symbols (Idx).C3_Name);
         end if;
      end if;

      Idx := Find_Symbol ("", Scoped);
      if Idx /= 0 then
         return To_String (Symbols (Idx).C3_Name);
      end if;

      Idx := Find_Symbol ("", Safe_C3_Name (Raw));
      if Idx /= 0 then
         return To_String (Symbols (Idx).C3_Name);
      end if;

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return To_String (Symbols (Idx).C3_Name);
      end if;

      return Safe_C3_Name (Raw);
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
      Plain_JS  : constant String := Safe_C3_Name (Raw);
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
               return Safe_C3_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
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
           and then To_String (Routines (I).C3_Name) = Target_Name
         then
            return I;
         end if;
      end loop;

      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then Ada.Strings.Fixed.Index (Target_Name, To_String (Routines (I).C3_Name)) > 0
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
         return Escape_C3_String ("");
      end if;

      case Node.Kind is
         when AST_Assert_Stmt | AST_Retract_Stmt =>
            return "alb_pred(" &
              Escape_C3_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Expr (Node.Left_Child) else "") &
              ")";
         when AST_Predicate =>
            return "alb_pred(" &
              Escape_C3_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Join_Arg_List (Node.Left_Child) else "") &
              ")";
         when AST_Func_Call =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               return "alb_pred(" &
                 Escape_C3_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                 (if Node.Right_Child > 0 then ", " & Join_Arg_List (Node.Right_Child) else "") &
                 ")";
            end if;
            return Expr (Pred_Node);
         when AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            return Escape_C3_String (Raw_Lexeme (Node.Token_Index));
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
               Name : constant String := Safe_C3_Name (T (T'First + 1 .. T'Last));
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

   function Escape_C3_String (Text : String) return String is
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
   end Escape_C3_String;

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

   function C3Import_Specifier (Raw_Path : String) return String is
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
         return "./" & Safe_C3_Name (Trimmed);
   end C3Import_Specifier;

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
      C3_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "alb_user_gettickcount"
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
      Foreign_Imports (Foreign_Import_Count).C3_Name := U (C3_Name);
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
      C3_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "alb_user_gettickcount"
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
      Foreign_Exports (Foreign_Export_Count).C3_Name := U (C3_Name);
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
                     Current_Module := U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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
                     Current_Module := U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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

      return Safe_C3_Name (Raw_Lexeme (Tree (Left_Node).Token_Index) & "_" &
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
      Field_Id : constant Natural := Find_Field (Struct_Name, Safe_C3_Name (Field_Name));
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
      return Cast_Expr
        (VK_String,
         Expr (Node_Index_Value),
         Infer_Expr_Kind (Node_Index_Value));
   end As_Text_Expr;

   function Feature_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      if Node_Index_Value = 0 then
         return Escape_C3_String ("");
      elsif Tree (Node_Index_Value).Kind = AST_String_Expr then
         return Expr (Node_Index_Value);
      elsif Tree (Node_Index_Value).Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
         return Escape_C3_String (Raw_Feature_Atom (Node_Index_Value));
      else
         return As_Text_Expr (Node_Index_Value);
      end if;
   end Feature_Text_Expr;

   procedure Emit_Warn_Once
     (Key     : String;
      Message : String) is
   begin
      Line ("alb_warn_once(" & Escape_C3_String (Key) & ", " &
            Escape_C3_String (Message) & ");");
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
      Plain_JS     : constant String := Safe_C3_Name (Raw_Name);
      Scoped_JS    : constant String := Scoped_Name (Raw_Name);
   begin
      if Routine_Name'Length > 0 then
         if Find_Symbol (Routine_Name, Raw_Name) = 0 then
            Register_Symbol (Routine_Name, Raw_Name, Plain_JS, Tag, Sym_Scalar);
            Line (Primitive_C3_Type (Tag) & " " & Plain_JS &
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
                  return Escape_C3_String (T);
               end if;
            end;
         when AST_True =>
            return "true";
         when AST_False =>
            return "false";
         when AST_Const_Ref =>
            declare
               T    : constant String := To_String (Tok_Text);
               Name : constant String :=
                 (if T'Length > 0 and then T (T'First) = '#'
                  then Safe_C3_Name (T (T'First + 1 .. T'Last))
                  else Safe_C3_Name (T));
               Idx  : constant Natural := Find_Symbol ("", Name);
            begin
               --  Fold #CONST to its integer Capacity (matches Eval_Static_Int).
               if Idx /= 0 then
                  return Trim_Image (Symbols (Idx).Capacity);
               end if;
               return Global_Scalar_Get (Name, VK_Number);
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
                           Global_Array_Get (To_String (S.C3_Name), S.Tag, Idx_Expr));
                     else
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           To_String (S.C3_Name) & "[" & Idx_Expr & "]");
                     end if;
                  end;
               elsif S.Active
                 and then Is_Global_Storage_Sym (S)
                 and then S.Kind in Sym_Scalar | Sym_Const | Sym_Temporal
               then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     Global_Scalar_Get (To_String (S.C3_Name), S.Tag));
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
                                   (To_String (Symbols (Field_Sym_Id).C3_Name),
                                    Symbols (Field_Sym_Id).Tag,
                                    Idx_Expr));
                           else
                              return Wrap_Firewall_Read
                                (Node_Index_Value,
                                 To_String (Symbols (Field_Sym_Id).C3_Name) &
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
                             (To_String (Group_Sym.C3_Name), Group_Sym.Tag, Idx_Expr));
                     else
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           To_String (Group_Sym.C3_Name) & "[" & Idx_Expr & "]");
                     end if;
                  end;
               end if;

               if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                  declare
                     Field_Id : constant Natural :=
                       Find_Field (To_String (Left_Sym.Struct_Name), Safe_C3_Name (Right_Name));
                  begin
                     return Wrap_Firewall_Read
                       (Node_Index_Value,
                        Field_Read_Expr (To_String (Left_Sym.C3_Name), Field_Id));
                  end;
               elsif Group_Sym.Active then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Group_Sym.C3_Name));
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

               function Looks_Floaty (S : String) return Boolean is
               begin
                  return Ada.Strings.Fixed.Index (S, ".") > 0
                    or else Ada.Strings.Fixed.Index (S, "gf64") > 0
                    or else Ada.Strings.Fixed.Index (S, "math::") > 0
                    or else Ada.Strings.Fixed.Index (S, "alb_num") > 0
                    or else Ada.Strings.Fixed.Index (S, "alb_powf") > 0
                    or else Ada.Strings.Fixed.Index (S, "(double)") > 0;
               end Looks_Floaty;

               Use_Float : constant Boolean :=
                 Looks_Floaty (L) or else Looks_Floaty (R)
                 or else Uses_Real_Power (Node.Left_Child)
                 or else Uses_Real_Power (Node.Right_Child);
            begin
               case Tok_Kind is
                  when Tok_Pipe =>
                     -- ALB | is string concat, NOT bitwise OR (OR keyword -> Rust |).
                     return "alb_concat(" & As_Text_Expr (Node.Left_Child) &
                       ", " & As_Text_Expr (Node.Right_Child) & ")";
                  when Tok_Plus =>
                     if Use_Float then
                        return "((double)(" & L & ") + (double)(" & R & "))";
                     end if;
                     return "(" & L & " + " & R & ")";
                  when Tok_Minus =>
                     if Use_Float then
                        return "((double)(" & L & ") - (double)(" & R & "))";
                     end if;
                     return "(" & L & " - " & R & ")";
                  when Tok_Mul =>
                     if Use_Float then
                        return "((double)(" & L & ") * (double)(" & R & "))";
                     end if;
                     return "(" & L & " * " & R & ")";
                  when Tok_Div =>
                     if Use_Float then
                        return "((double)(" & L & ") / (double)(" & R & "))";
                     end if;
                     return "albdiv(" & L & ", " & R & ")";
                  when Tok_Mod =>
                     return "albmod(" & L & ", " & R & ")";
                  when Tok_Pow =>
                     if Uses_Real_Power (Node.Left_Child)
                       or else Uses_Real_Power (Node.Right_Child)
                     then
                        return "alb_powf((double)(" & L & "), (double)(" & R & "))";
                     end if;
                     return "alb_pow(" & L & ", " & R & ")";
                  when Tok_Less =>
                     return "((" & L & " < " & R & ") ? 1 : 0)";
                  when Tok_Greater =>
                     return "((" & L & " > " & R & ") ? 1 : 0)";
                  when Tok_Less_Equal =>
                     return "((" & L & " <= " & R & ") ? 1 : 0)";
                  when Tok_Greater_Equal =>
                     return "((" & L & " >= " & R & ") ? 1 : 0)";
                  when Tok_Equal | Tok_Assign =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(alb_truthy(" & R & ") ? 1 : 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(alb_truthy(" & L & ") ? 1 : 0)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(alb_truthy(" & R & ") ? 0 : 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(alb_truthy(" & L & ") ? 0 : 1)";
                     end if;
                     return "((" & L & " == " & R & ") ? 1 : 0)";
                  when Tok_Not_Equal =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(alb_truthy(" & R & ") ? 0 : 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(alb_truthy(" & L & ") ? 0 : 1)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(alb_truthy(" & R & ") ? 1 : 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(alb_truthy(" & L & ") ? 1 : 0)";
                     end if;
                     return "((" & L & " != " & R & ") ? 1 : 0)";
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
            return "(alb_truthy(" & Expr (Node.Left_Child) & ") ? 0 : 1)";
         when AST_Cast_Expr =>
            return Cast_Expr
              (Type_From_Token (Node.Token_Index),
               Expr (Node.Left_Child),
               Infer_Expr_Kind (Node.Left_Child));
         when AST_Str_Len =>
            return "alb_len(" & Expr (Node.Left_Child) & ")";
         when AST_Str_Left =>
            return "left(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Str_Right =>
            return "right(" & Expr (Node.Left_Child) & ", " &
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
               return "mid(" & Expr (Node.Left_Child) & ", " &
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

               if Ctor_Name = "pure" or else Ctor_Name = "RATIONAL" then
                  return "pure(" &
                    (if A1 > 0 then Expr (A1) else "0") &
                    ", " &
                    (if A2 > 0 then Expr (A2) else "1") &
                    ")";
               elsif Ctor_Name = "u8" then
                  return Cast_Expr (VK_U8, Expr (A1), Infer_Expr_Kind (A1));
               elsif Ctor_Name = "u16" then
                  return Cast_Expr (VK_U16, Expr (A1), Infer_Expr_Kind (A1));
                elsif Ctor_Name = "u32" then
                   return Cast_Expr (VK_U32, Expr (A1), Infer_Expr_Kind (A1));
                elsif Ctor_Name = "u64" then
                   return Cast_Expr (VK_U64, Expr (A1), Infer_Expr_Kind (A1));
                elsif Ctor_Name = "s8" or else Ctor_Name = "i8" or else Ctor_Name = "INT8" then
                   return Cast_Expr (VK_S8, Expr (A1), Infer_Expr_Kind (A1));
                elsif Ctor_Name = "s16" or else Ctor_Name = "i16" or else Ctor_Name = "INT16" then
                   return Cast_Expr (VK_S16, Expr (A1), Infer_Expr_Kind (A1));
                elsif Ctor_Name = "s32" or else Ctor_Name = "i32" or else Ctor_Name = "INT32" then
                   return Cast_Expr (VK_S32, Expr (A1), Infer_Expr_Kind (A1));
                elsif Ctor_Name = "S64" or else Ctor_Name = "I64" or else Ctor_Name = "INT64" then
                   return Cast_Expr (VK_Number, Expr (A1), Infer_Expr_Kind (A1));
               elsif Ctor_Name = "f64" or else Ctor_Name = "REAL" then
                  return Cast_Expr (VK_F64, Expr (A1), Infer_Expr_Kind (A1));
               elsif Ctor_Name = "hw8" then
                  return Cast_Expr (VK_HW8, Expr (A1), Infer_Expr_Kind (A1));
               elsif Ctor_Name = "hw16" then
                  return Cast_Expr (VK_HW16, Expr (A1), Infer_Expr_Kind (A1));
               elsif Ctor_Name = "hw32" then
                  return Cast_Expr (VK_HW32, Expr (A1), Infer_Expr_Kind (A1));
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
                        Target_Name := U ("left");
                     elsif To_String (Raw_Upper) = "RIGHT" or else To_String (Raw_Upper) = "RIGHT$" then
                        Target_Name := U ("right");
                     elsif To_String (Raw_Upper) = "MID" or else To_String (Raw_Upper) = "MID$" then
                        Target_Name := U ("mid");
                     elsif To_String (Raw_Upper) = "LEN" then
                        Target_Name := U ("alb_len");
                     elsif To_String (Raw_Upper) = "CHR" then
                        Target_Name := U ("alb_chr");
                     elsif To_String (Raw_Upper) = "ASC" then
                        Target_Name := U ("alb_asc");
                     elsif To_String (Raw_Upper) = "CONCAT" then
                        Target_Name := U ("concat");
                     elsif To_String (Raw_Upper) = "PRINT_PURE" then
                        Target_Name := U ("print_pure");
                     elsif To_String (Raw_Upper) = "RATIONAL" then
                        Target_Name := U ("pure");
                     elsif To_String (Raw_Upper) = "REAL" then
                        Target_Name := U ("f64");
                     elsif To_String (Raw_Upper) = "GETTICKCOUNT" then
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           Target_Name := U ("alb_gettickcount");
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
                        if To_String (Raw_Upper) = "SIN" then
                           Target_Name := U ("math::sin");
                        elsif To_String (Raw_Upper) = "COS" then
                           Target_Name := U ("math::cos");
                        elsif To_String (Raw_Upper) = "SQRT" then
                           Target_Name := U ("math::sqrt");
                        elsif To_String (Raw_Upper) = "EXP" then
                           Target_Name := U ("math::exp");
                        else
                           Target_Name := U (Ada.Characters.Handling.To_Lower (To_String (Raw_Upper)));
                        end if;
                     else
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           Target_Name := U ("alb_pred(" &
                             Escape_C3_String (To_String (Raw)) &
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

               if Starts_With (To_String (Target_Name), "alb_pred(") then
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
            return "alb_key(" & Expr (Node.Left_Child) & ")";
         when AST_Mouse_X =>
            return "alb_mouse_x()";
         when AST_Mouse_Y =>
            return "alb_mouse_y()";
         when AST_Mouse_Wheel =>
            return "alb_mouse_wheel()";
         when AST_Mouse_Click =>
            return "alb_mouse_click(" &
              (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "0") & ")";
         when AST_VMouse_X =>
            return "alb_vmouse_x()";
         when AST_VMouse_y =>
            return "alb_vmouse_y()";
         when AST_SCREEN_WIDTH =>
            return "alb_screen_width()";
         when AST_SCREEN_HEIGHT =>
            return "alb_screen_height()";
         when AST_VIRTUAL_WIDTH =>
            return "alb_virtual_width()";
         when AST_VIRTUAL_HEIGHT =>
            return "alb_virtual_height()";
         when AST_Peek_Expr =>
            return "alb_peek(" & Expr (Node.Left_Child) & ")";
         when AST_Deref_Expr =>
            return "alb_deref(" & Expr (Node.Left_Child) & ")";
         when AST_AddressOf | AST_Ref_Expr =>
            return Address_Expr_For (Node.Left_Child);
         when AST_Read_Process_Memory_Expr =>
            return "alb_process_read_scalar(" &
              Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Read_Pixel =>
            return "alb_read_pixel(" & Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Rnd_Expr =>
            return "alb_rnd(" & Expr (Node.Left_Child) & ")";
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
                 (Safe_C3_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)),
                  Raw_Lexeme (Tree (Node.Right_Child).Token_Index));
            else
               return "0";
            end if;
         when AST_TypeOf_Expr =>
            return Escape_C3_String ("long");
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
                  return "alb_rel_find1(" & Predicate_Id_Expr (Node.Left_Child) & ")";
               else
                  return "0";
               end if;
            else
               return "alb_rel_has(" &
                 Predicate_Id_Expr (Node_Index_Value) & ", " &
                 Predicate_Arity_Expr (Node_Index_Value) & ", " &
                 Predicate_Arg1_Expr (Node_Index_Value) &
                 ", 0, 0, 0)";
            end if;
         when AST_Query =>
            if Node.Left_Child > 0 then
               return "alb_rel_has(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_Knows_Query =>
            if Node.Left_Child > 0 then
               return "alb_rel_has(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_File_Open =>
            return "alb_open(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Len =>
            return "alb_filelen(" & Expr (Node.Left_Child) & ")";
         when AST_File_Seek =>
            return "alb_seek(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Read =>
            return "alb_read(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Inline_Typescript_Expr =>
            return Raw_Lexeme (Node.Token_Index);
         when others =>
            return "0";
      end case;
   end Expr;

   procedure Emit_Runtime is
   begin
      Line ("module alb_main;");
      Line ("import std::io;");
      Line ("import std::math;");
      Line ("import std::core;");
      Line ("// Generated by ALBC3 - AdaLogic BASIC to C3 (c3c)");
      Line ("// SDL3 via extern @cname/@link; ALB | => alb_concat.");
      New_Line_Emit;
      Line ("// --- ALBC3 core runtime ---");
      Line ("struct ALBNamedLong { String name; long value; bool used; }");
      Line ("struct ALBNamedF64 { String name; double value; bool used; }");
      Line ("struct ALBNamedStr { String name; String value; bool used; }");
      Line ("struct ALBNamedArr { String name; long[] data; bool used; }");
      Line ("struct ALBNamedStrArr { String name; String[] data; bool used; }");
      New_Line_Emit;
      Line ("const ALB_NAMED_CAP = 4096;");
      New_Line_Emit;
      Line ("ALBNamedArr[ALB_NAMED_CAP] albGArr;");
      Line ("ALBNamedStrArr[ALB_NAMED_CAP] albGStrArr;");
      Line ("ALBNamedLong[ALB_NAMED_CAP] albGScal;");
      Line ("ALBNamedF64[ALB_NAMED_CAP] albGF64;");
      Line ("ALBNamedStr[ALB_NAMED_CAP] albGStr;");
      Line ("bool[ALB_NAMED_CAP] albWarnedSlot;");
      Line ("String[ALB_NAMED_CAP] albWarnedKey;");
      New_Line_Emit;
      Line ("long albBaseWidth = 320;");
      Line ("long albBaseHeight = 200;");
      Line ("long albWindowWidth = 320;");
      Line ("long albWindowHeight = 200;");
      Line ("long albVirtualWidth = 320;");
      Line ("long albVirtualHeight = 200;");
      Line ("long albOriginX = 0;");
      Line ("long albOriginY = 0;");
      Line ("long albCurrentColor = 0xffffffff;");
      Line ("long albColorValue = 0xffffffff;");
      Line ("long albAlphaChannel = 0;");
      Line ("long albAlphaValue = 255;");
      Line ("bool albStretchy = false;");
      Line ("bool albResizable = true;");
      Line ("bool albRunning = true;");
      Line ("bool albShutdownDone = false;");
      Line ("long albMouseX = 0;");
      Line ("long albMouseY = 0;");
      Line ("long albMouseWheel = 0;");
      Line ("long albFrameInterval = 16;");
      Line ("long albLastFrame = 0;");
      Line ("long albCompatTick = 0;");
      Line ("long albRndState = 0xC0FFEE;");
      Line ("bool albConsoleDisabled = " &
            (if No_Console_Overlay then "true" else "false") &
            ";");
      Line ("long albTextCursorX = 1;");
      Line ("long albTextCursorY = 1;");
      New_Line_Emit;
      Line ("alias AlbTickFn = fn void();");
      Line ("alias AlbPaintFn = fn void();");
      Line ("alias AlbKeyFn = fn void();");
      Line ("alias AlbKnowsFn = fn void(long pred, long a1, long a2, long a3, long a4);");
      Line ("AlbTickFn alb_on_tick = null;");
      Line ("AlbPaintFn alb_on_paint = null;");
      Line ("AlbKeyFn alb_on_key = null;");
      Line ("AlbKnowsFn alb_notify_knows_change = null;");
      New_Line_Emit;
      Line ("// --- SDL3 foreign decls (albc3 passes -L <SDL3 libdir>; @link pulls SDL3) ---");
      Line ("const SDL_INIT_VIDEO = 0x00000020u;");
      Line ("const SDL_EVENT_QUIT = 0x100u;");
      Line ("const SDL_EVENT_KEY_DOWN = 0x300u;");
      Line ("const SDL_EVENT_KEY_UP = 0x301u;");
      Line ("const SDL_EVENT_MOUSE_MOTION = 0x400u;");
      Line ("const SDL_EVENT_MOUSE_BUTTON_DOWN = 0x401u;");
      Line ("const SDL_EVENT_MOUSE_BUTTON_UP = 0x402u;");
      Line ("const SDL_EVENT_MOUSE_WHEEL = 0x403u;");
      Line ("struct Sdl_FRect { float x; float y; float w; float h; }");
      Line ("struct Sdl_FPoint { float x; float y; }");
      Line ("struct Sdl_FColor { float r; float g; float b; float a; }");
      Line ("struct Sdl_Vertex { Sdl_FPoint position; Sdl_FColor color; Sdl_FPoint tex_coord; }");
      Line ("extern fn bool sdl_init(uint flags) @cname(""SDL_Init"") @link(""SDL3"");");
      Line ("extern fn void sdl_quit() @cname(""SDL_Quit"");");
      Line ("extern fn bool sdl_create_window_and_renderer(char* title, int w, int h, ulong window_flags, void** window, void** renderer) @cname(""SDL_CreateWindowAndRenderer"");");
      Line ("extern fn void sdl_destroy_window(void* window) @cname(""SDL_DestroyWindow"");");
      Line ("extern fn void sdl_destroy_renderer(void* renderer) @cname(""SDL_DestroyRenderer"");");
      Line ("extern fn bool sdl_set_render_vsync(void* renderer, int vsync) @cname(""SDL_SetRenderVSync"");");
      Line ("extern fn bool sdl_set_render_draw_color(void* renderer, char r, char g, char b, char a) @cname(""SDL_SetRenderDrawColor"");");
      Line ("extern fn bool sdl_render_clear(void* renderer) @cname(""SDL_RenderClear"");");
      Line ("extern fn bool sdl_render_present(void* renderer) @cname(""SDL_RenderPresent"");");
      Line ("extern fn bool sdl_render_fill_rect(void* renderer, Sdl_FRect* rect) @cname(""SDL_RenderFillRect"");");
      Line ("extern fn bool sdl_render_rect(void* renderer, Sdl_FRect* rect) @cname(""SDL_RenderRect"");");
      Line ("extern fn bool sdl_render_line(void* renderer, float x1, float y1, float x2, float y2) @cname(""SDL_RenderLine"");");
      Line ("extern fn bool sdl_render_point(void* renderer, float x, float y) @cname(""SDL_RenderPoint"");");
      Line ("extern fn bool sdl_render_points(void* renderer, Sdl_FPoint* points, int count) @cname(""SDL_RenderPoints"");");
      Line ("extern fn bool sdl_render_geometry(void* renderer, void* texture, Sdl_Vertex* vertices, int num_vertices, int* indices, int num_indices) @cname(""SDL_RenderGeometry"");");
      Line ("extern fn bool sdl_render_debug_text(void* renderer, float x, float y, char* str) @cname(""SDL_RenderDebugText"");");
      Line ("extern fn bool sdl_poll_event(char* event) @cname(""SDL_PollEvent"");");
      Line ("extern fn ulong sdl_get_ticks() @cname(""SDL_GetTicks"");");
      Line ("extern fn void sdl_delay(uint ms) @cname(""SDL_Delay"");");
      Line ("extern fn char* sdl_get_error() @cname(""SDL_GetError"");");
      Line ("void* albSdlWindow = null;");
      Line ("void* albSdlRenderer = null;");
      Line ("bool albSdlReady = false;");
      Line ("char[512] albKeys;");
      Line ("char[8] albMouseBtns;");
      Line ("long albDelayUntil = 0;");
      New_Line_Emit;
      Line ("// --- Win64 dynload (LoadLibraryA / GetProcAddress) for IMPORT DLL ---");
      Line ("extern fn void* load_library_a(char* lp) @cname(""LoadLibraryA"");");
      Line ("extern fn void* get_proc_address(void* m, char* n) @cname(""GetProcAddress"");");
      Line ("struct AlbFfiLib { String name; void* handle; bool used; }");
      Line ("const ALB_FFI_CAP = 64;");
      Line ("AlbFfiLib[ALB_FFI_CAP] albFfiLibs;");
      --  C3 String is a slice; .ptr is the stable char* view for FFI.
      Line ("fn char* alb_cstr(String s) { return (char*)s.ptr; }");
      Line ("fn String alb_from_cstr(char* p)");
      Line ("{");
      Line ("    if (p == null) return """";");
      Line ("    usz n = 0;");
      Line ("    while (p[n] != 0) n++;");
      Line ("    return (String)p[:n];");
      Line ("}");
      Line ("fn void* alb_load_sym(String lib_name, String sym_name)");
      Line ("{");
      Line ("    void* mod_handle = null;");
      Line ("    for (ulong i = 0; i < ALB_FFI_CAP; i++)");
      Line ("    {");
      Line ("        if (albFfiLibs[i].used && albFfiLibs[i].name == lib_name)");
      Line ("        {");
      Line ("            mod_handle = albFfiLibs[i].handle;");
      Line ("            break;");
      Line ("        }");
      Line ("    }");
      Line ("    if (mod_handle == null)");
      Line ("    {");
      Line ("        mod_handle = load_library_a(alb_cstr(lib_name));");
      Line ("        if (mod_handle == null)");
      Line ("        {");
      Line ("            io::eprintn(""ALBC3 FFI: cannot load "".tconcat(lib_name));");
      Line ("            return null;");
      Line ("        }");
      Line ("        for (ulong i = 0; i < ALB_FFI_CAP; i++)");
      Line ("        {");
      Line ("            if (!albFfiLibs[i].used)");
      Line ("            {");
      Line ("                albFfiLibs[i].used = true;");
      Line ("                albFfiLibs[i].name = lib_name;");
      Line ("                albFfiLibs[i].handle = mod_handle;");
      Line ("                break;");
      Line ("            }");
      Line ("        }");
      Line ("    }");
      Line ("    void* addr = get_proc_address(mod_handle, alb_cstr(sym_name));");
      Line ("    if (addr == null)");
      Line ("    {");
      Line ("        io::eprintn(""ALBC3 FFI: missing symbol "".tconcat(sym_name).tconcat("" in "").tconcat(lib_name));");
      Line ("    }");
      Line ("    return addr;");
      Line ("}");
      New_Line_Emit;
      Line ("fn String alb_text(long v) { return string::tformat(""%d"", v); }");
      Line ("fn String alb_text_s(String v) { return v; }");
      Line ("fn double alb_num(long v) { return (double)v; }");
      --  Expression macros so double→long (and similar) cast cleanly without overloads.
      Line ("macro long alb_i64(v) => (long)v;");
      Line ("fn long alb_i64_s(String v) { return 0; }");
      Line ("fn long alb_i64_d(double v) { return (long)v; }");
      Line ("fn ulong alb_idx(long i) { return i < 0 ? 0 : (ulong)i; }");
      Line ("fn long alb_i128(long v) { return v; }");
      Line ("fn bool alb_truthy(long v) { return v != 0; }");
      Line ("fn String alb_concat(String a, String b) { return a.tconcat(b); }");
      Line ("fn String concat(String a, String b) { return alb_concat(a, b); }");
      Line ("fn long alb_max(long a, long b) { return a > b ? a : b; }");
      Line ("fn long alb_min(long a, long b) { return a < b ? a : b; }");
      Line ("fn long alb_trunc(double v) { return (long)v; }");
      Line ("fn long alb_floor(double v) { return (long)math::floor(v); }");
      Line ("fn long alb_round(double v) { return (long)math::round(v); }");
      Line ("fn double alb_powf(double a, double b) { return math::pow(a, b); }");
      Line ("fn double alb_random()");
      Line ("{");
      Line ("    // xorshift64 — same scheme as ALBO (constant stub broke RND mid-range).");
      Line ("    long x = albRndState;");
      Line ("    x ^= x << 13;");
      Line ("    x ^= x >> 7;");
      Line ("    x ^= x << 17;");
      Line ("    albRndState = x;");
      Line ("    return (double)((ulong)x) / (double)18446744073709551615.0;");
      Line ("}");
      New_Line_Emit;
      Line ("fn void alb_fatal(String msg)");
      Line ("{");
      Line ("    io::eprintn(""ALBC3 fatal: "".tconcat(msg));");
      Line ("    albRunning = false;");
      Line ("    albShutdownDone = true;");
      Line ("}");
      New_Line_Emit;
      Line ("fn void alb_warn_once(String key, String message)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albWarnedSlot[i] && albWarnedKey[i] == key) return;");
      Line ("    }");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (!albWarnedSlot[i])");
      Line ("        {");
      Line ("            albWarnedSlot[i] = true;");
      Line ("            albWarnedKey[i] = key;");
      Line ("            io::eprintn(""ALBC3: "".tconcat(message));");
      Line ("            return;");
      Line ("        }");
      Line ("    }");
      Line ("}");
      New_Line_Emit;
      Line ("fn void alb_console_write(String text, bool newline)");
      Line ("{");
      Line ("    if (albConsoleDisabled) return;");
      Line ("    if (newline) { io::printn(text); } else { io::print(text); }");
      Line ("}");
      New_Line_Emit;
      Line ("fn void alb_print(String v) { alb_console_write(v, true); }");
      Line ("fn void alb_print_raw(String v) { alb_console_write(v, false); }");
      Line ("fn String alb_prompt_text(String prompt) { io::print(prompt); return """"; }");
      Line ("fn String alb_readline_text() { return alb_prompt_text(""""); }");
      Line ("fn void alb_locate(long x, long y) { albTextCursorX = x; albTextCursorY = y; }");
      New_Line_Emit;
      Line ("fn long albu8(long v) { return v & 255; }");
      Line ("fn long albu16(long v) { return v & 65535; }");
      Line ("fn long albu32(long v) { return v & 0xffffffff; }");
      Line ("fn long albi8(long v) { return ((v + 128) & 255) - 128; }");
      Line ("fn long albi16(long v) { return ((v + 32768) & 65535) - 32768; }");
      Line ("fn long albi32(long v) { return v; }");
      Line ("fn long u8(long v) { return albu8(v); }");
      Line ("fn long u16(long v) { return albu16(v); }");
      Line ("fn long s8(long v) { return albi8(v); }");
      Line ("fn long i8(long v) { return albi8(v); }");
      Line ("fn long s16(long v) { return albi16(v); }");
      Line ("fn long i16(long v) { return albi16(v); }");
      Line ("fn long u32(long v) { return albu32(v); }");
      Line ("fn long u64(long v) { return albu32(v); }");
      Line ("fn long u128(long v) { return v; }");
      Line ("fn long s32(long v) { return albi32(v); }");
      Line ("fn long i32(long v) { return albi32(v); }");
      Line ("fn long hw8(long v) { return albi32(v); }");
      Line ("fn long hw16(long v) { return albi32(v); }");
      Line ("fn long hw32(long v) { return albi32(v); }");
      Line ("fn double f64(long v) { return (double)v; }");
      New_Line_Emit;
      Line ("fn long alb_pure_abs(long v) { return v < 0 ? -v : v; }");
      Line ("fn long alb_pure_gcd(long a, long b)");
      Line ("{");
      Line ("    long x = alb_pure_abs(a); long y = alb_pure_abs(b);");
      Line ("    while (y != 0) { long t = x % y; x = y; y = t; }");
      Line ("    return x == 0 ? 1 : x;");
      Line ("}");
      Line ("fn long alb_pure_pack(long num, long den)");
      Line ("{");
      Line ("    long d = den == 0 ? 1 : den;");
      Line ("    long g = alb_pure_gcd(num, d);");
      Line ("    long n = num / g; d = d / g;");
      Line ("    if (d < 0) { n = -n; d = -d; }");
      Line ("    return (n << 32) | (d & 0xffffffff);");
      Line ("}");
      Line ("fn long pure(long num, long den) { return alb_pure_pack(num, den); }");
      Line ("fn long pure_num(long v) { return v >> 32; }");
      Line ("fn long pure_den(long v) { long d = v & 0xffffffff; return d == 0 ? 1 : d; }");
      Line ("fn long pure_add(long a, long b)");
      Line ("{");
      Line ("    return alb_pure_pack(pure_num(a)*pure_den(b)+pure_num(b)*pure_den(a), pure_den(a)*pure_den(b));");
      Line ("}");
      Line ("fn long pure_sub(long a, long b)");
      Line ("{");
      Line ("    return alb_pure_pack(pure_num(a)*pure_den(b)-pure_num(b)*pure_den(a), pure_den(a)*pure_den(b));");
      Line ("}");
      Line ("fn long pure_mul(long a, long b) { return alb_pure_pack(pure_num(a)*pure_num(b), pure_den(a)*pure_den(b)); }");
      Line ("fn long pure_div(long a, long b) { return alb_pure_pack(pure_num(a)*pure_den(b), pure_den(a)*pure_num(b)); }");
      Line ("fn long albpowint(long base, long exp)");
      Line ("{");
      Line ("    if (exp < 0) return 0;");
      Line ("    long r = 1; long b = base; long e = exp;");
      Line ("    while (e > 0) { if ((e & 1) != 0) r *= b; b *= b; e >>= 1; }");
      Line ("    return r;");
      Line ("}");
      Line ("fn long pure_pow(long a, long b)");
      Line ("{");
      Line ("    return alb_pure_pack(albpowint(pure_num(a), pure_num(b)), albpowint(pure_den(a), pure_num(b)));");
      Line ("}");
      Line ("fn double alb_pow(long a, long b) { return alb_powf((double)a, (double)b); }");
      Line ("macro long albdiv(a, b) => ((long)(b) == 0) ? 0 : (long)((double)(a) / (double)(b));");
      Line ("macro long albmod(a, b) => ((long)(b) == 0) ? 0 : ((long)(a) % (long)(b));");
      New_Line_Emit;
      Line ("fn String left(String s, long n)");
      Line ("{");
      Line ("    long take = alb_max(0, n);");
      Line ("    if (take > (long)s.len) take = (long)s.len;");
      Line ("    return (String)s[:take];");
      Line ("}");
      Line ("fn String right(String s, long n)");
      Line ("{");
      Line ("    long take = alb_max(0, n);");
      Line ("    if (take > (long)s.len) take = (long)s.len;");
      Line ("    usz start = s.len - (usz)take;");
      Line ("    return (String)s[start:s.len];");
      Line ("}");
      Line ("fn String mid(String s, long start_at, long n)");
      Line ("{");
      Line ("    long st = alb_max(1, start_at) - 1;");
      Line ("    if (st >= (long)s.len) return """";");
      Line ("    long take = alb_max(0, n);");
      Line ("    if (st + take > (long)s.len) take = (long)s.len - st;");
      Line ("    usz a = (usz)st;");
      Line ("    usz b = (usz)(st + take);");
      Line ("    return (String)s[a:b];");
      Line ("}");
      Line ("fn long alb_len(String v) { return (long)v.len; }");
      Line ("fn String alb_chr(long v) { return string::tformat(""%c"", (int)(v & 255)); }");
      Line ("fn long alb_asc(String v) { return v.len == 0 ? 0 : ((long)v[0] & 255); }");
      Line ("fn void print_pure(long v) { alb_print(alb_text(v)); }");
      New_Line_Emit;
      Line ("fn long alb_gettickcount() { return albCompatTick; }");
      Line ("fn long alb_rnd(long limit)");
      Line ("{");
      Line ("    long n = alb_max(1, limit);");
      Line ("    return alb_floor(alb_random() * (double)n);");
      Line ("}");
      New_Line_Emit;
      Line ("fn long alb_band(long a, long b) { return a & b; }");
      Line ("fn long alb_bor(long a, long b) { return a | b; }");
      Line ("fn long alb_bxor(long a, long b) { return a ^ b; }");
      Line ("fn long alb_bnot(long a) { return ~a; }");
      Line ("fn long alb_shl(long a, long n) { return a << n; }");
      Line ("fn long alb_shr(long a, long n) { return a >> n; }");
      New_Line_Emit;
      Line ("fn long alb_named_find(String name)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGArr[i].used && albGArr[i].name == name) return (long)i;");
      Line ("    }");
      Line ("    return -1;");
      Line ("}");
      Line ("fn long alb_named_alloc(String name)");
      Line ("{");
      Line ("    long f = alb_named_find(name);");
      Line ("    if (f >= 0) return f;");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (!albGArr[i].used)");
      Line ("        {");
      Line ("            albGArr[i].used = true;");
      Line ("            albGArr[i].name = name;");
      Line ("            return (long)i;");
      Line ("        }");
      Line ("    }");
      Line ("    alb_fatal(""ALBC3 named array table full"");");
      Line ("    return -1;");
      Line ("}");
      Line ("fn void alb_garr_init(String name, ulong n)");
      Line ("{");
      Line ("    long id = alb_named_alloc(name);");
      Line ("    if (id < 0) return;");
      Line ("    albGArr[id].data = mem::new_array(long, (sz)n);");
      Line ("    for (ulong i = 0; i < n; i++) { albGArr[id].data[i] = 0; }");
      Line ("}");
      Line ("fn long alb_garr_get(String name, ulong idx)");
      Line ("{");
      Line ("    long id = alb_named_find(name);");
      Line ("    if (id < 0 || idx >= albGArr[id].data.len) return 0;");
      Line ("    return albGArr[id].data[idx];");
      Line ("}");
      Line ("fn void alb_garr_set(String name, ulong idx, long val)");
      Line ("{");
      Line ("    long id = alb_named_find(name);");
      Line ("    if (id < 0 || idx >= albGArr[id].data.len) return;");
      Line ("    albGArr[id].data[idx] = val;");
      Line ("}");
      Line ("fn long alb_garr_len(String name)");
      Line ("{");
      Line ("    long id = alb_named_find(name);");
      Line ("    if (id < 0) return 0;");
      Line ("    return (long)albGArr[id].data.len;");
      Line ("}");
      Line ("fn void alb_gstrarr_init(String name, ulong n)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (!albGStrArr[i].used)");
      Line ("        {");
      Line ("            albGStrArr[i].used = true;");
      Line ("            albGStrArr[i].name = name;");
      Line ("            albGStrArr[i].data = mem::new_array(String, (sz)n);");
      Line ("            for (ulong j = 0; j < n; j++) { albGStrArr[i].data[j] = """"; }");
      Line ("            return;");
      Line ("        }");
      Line ("        if (albGStrArr[i].name == name) return;");
      Line ("    }");
      Line ("}");
      Line ("fn String alb_gstrarr_get(String name, ulong idx)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGStrArr[i].used && albGStrArr[i].name == name)");
      Line ("        {");
      Line ("            if (idx >= albGStrArr[i].data.len) return """";");
      Line ("            return albGStrArr[i].data[idx];");
      Line ("        }");
      Line ("    }");
      Line ("    return """";");
      Line ("}");
      Line ("fn void alb_gstrarr_set(String name, ulong idx, String val)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGStrArr[i].used && albGStrArr[i].name == name)");
      Line ("        {");
      Line ("            if (idx >= albGStrArr[i].data.len) return;");
      Line ("            albGStrArr[i].data[idx] = val;");
      Line ("            return;");
      Line ("        }");
      Line ("    }");
      Line ("}");
      Line ("fn long alb_gscal_get(String name)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGScal[i].used && albGScal[i].name == name) return albGScal[i].value;");
      Line ("    }");
      Line ("    return 0;");
      Line ("}");
      Line ("fn void alb_gscal_set(String name, long val)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGScal[i].used && albGScal[i].name == name) { albGScal[i].value = val; return; }");
      Line ("    }");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (!albGScal[i].used)");
      Line ("        {");
      Line ("            albGScal[i].used = true;");
      Line ("            albGScal[i].name = name;");
      Line ("            albGScal[i].value = val;");
      Line ("            return;");
      Line ("        }");
      Line ("    }");
      Line ("}");
      Line ("fn double alb_gf64_get(String name)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGF64[i].used && albGF64[i].name == name) return albGF64[i].value;");
      Line ("    }");
      Line ("    return 0.0;");
      Line ("}");
      Line ("fn void alb_gf64_set(String name, double val)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGF64[i].used && albGF64[i].name == name) { albGF64[i].value = val; return; }");
      Line ("    }");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (!albGF64[i].used)");
      Line ("        {");
      Line ("            albGF64[i].used = true;");
      Line ("            albGF64[i].name = name;");
      Line ("            albGF64[i].value = val;");
      Line ("            return;");
      Line ("        }");
      Line ("    }");
      Line ("}");
      Line ("fn String alb_gstr_get(String name)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGStr[i].used && albGStr[i].name == name) return albGStr[i].value;");
      Line ("    }");
      Line ("    return """";");
      Line ("}");
      Line ("fn void alb_gstr_set(String name, String val)");
      Line ("{");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (albGStr[i].used && albGStr[i].name == name) { albGStr[i].value = val; return; }");
      Line ("    }");
      Line ("    for (ulong i = 0; i < ALB_NAMED_CAP; i++)");
      Line ("    {");
      Line ("        if (!albGStr[i].used)");
      Line ("        {");
      Line ("            albGStr[i].used = true;");
      Line ("            albGStr[i].name = name;");
      Line ("            albGStr[i].value = val;");
      Line ("            return;");
      Line ("        }");
      Line ("    }");
      Line ("}");
      New_Line_Emit;
      Line ("fn long[] alb_new_array(long n, long fill)");
      Line ("{");
      Line ("    ulong nn = n < 0 ? 0 : (ulong)n;");
      Line ("    long[] a = mem::new_array(long, (sz)nn);");
      Line ("    for (ulong i = 0; i < nn; i++) { a[i] = fill; }");
      Line ("    return a;");
      Line ("}");
      Line ("fn long[] alb_filled(long n, long fill) { return alb_new_array(n, fill); }");
      New_Line_Emit;
      Line ("// --- Graphics / SDL3 (ported from ALBO/ALBR) ---");
      Line ("fn uint alb_sdl_read_u32(char* buf, int off)");
      Line ("{");
      Line ("    return (uint)(buf[off] & 255) | ((uint)(buf[off + 1] & 255) << 8) | ((uint)(buf[off + 2] & 255) << 16) | ((uint)(buf[off + 3] & 255) << 24);");
      Line ("}");
      Line ("fn float alb_sdl_bits_f32(uint u)");
      Line ("{");
      Line ("    float* p = (float*)&u;");
      Line ("    return *p;");
      Line ("}");
      Line ("fn float alb_sdl_read_f32(char* buf, int off)");
      Line ("{");
      Line ("    return alb_sdl_bits_f32(alb_sdl_read_u32(buf, off));");
      Line ("}");
      Line ("fn void* alb_sdl_renderer() { return albSdlRenderer; }");
      Line ("fn void alb_sdl_apply_color()");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    long c = albCurrentColor;");
      Line ("    char a = (char)((c >> 24) & 255);");
      Line ("    if (a == 0) { a = (char)255; }");
      Line ("    sdl_set_render_draw_color(rdr, (char)((c >> 16) & 255), (char)((c >> 8) & 255), (char)(c & 255), a);");
      Line ("}");
      Line ("fn Sdl_FColor alb_sdl_color_to_fcolor(long c)");
      Line ("{");
      Line ("    float aa = ((float)((c >> 24) & 255)) / 255.0f;");
      Line ("    if (((c >> 24) & 255) == 0) { aa = 1.0f; }");
      Line ("    return { .r = ((float)((c >> 16) & 255)) / 255.0f, .g = ((float)((c >> 8) & 255)) / 255.0f, .b = ((float)(c & 255)) / 255.0f, .a = aa };");
      Line ("}");
      Line ("fn bool alb_poll_events()");
      Line ("{");
      Line ("    char[128] ev;");
      Line ("    while (sdl_poll_event(&ev))");
      Line ("    {");
      Line ("        uint ty = alb_sdl_read_u32(&ev, 0);");
      Line ("        if (ty == SDL_EVENT_QUIT)");
      Line ("        {");
      Line ("            albRunning = false;");
      Line ("        }");
      Line ("        else if (ty == SDL_EVENT_KEY_DOWN || ty == SDL_EVENT_KEY_UP)");
      Line ("        {");
      Line ("            int sc = (int)alb_sdl_read_u32(&ev, 24);");
      Line ("            if (sc >= 0 && sc < 512)");
      Line ("            {");
      Line ("                albKeys[sc] = (ty == SDL_EVENT_KEY_DOWN) ? (char)1 : (char)0;");
      Line ("            }");
      Line ("        }");
      Line ("        else if (ty == SDL_EVENT_MOUSE_MOTION)");
      Line ("        {");
      Line ("            albMouseX = (long)alb_sdl_read_f32(&ev, 28);");
      Line ("            albMouseY = (long)alb_sdl_read_f32(&ev, 32);");
      Line ("        }");
      Line ("        else if (ty == SDL_EVENT_MOUSE_BUTTON_DOWN || ty == SDL_EVENT_MOUSE_BUTTON_UP)");
      Line ("        {");
      Line ("            int button = (int)(ev[24] & 255);");
      Line ("            if (button >= 1 && button <= 8)");
      Line ("            {");
      Line ("                albMouseBtns[button - 1] = (ty == SDL_EVENT_MOUSE_BUTTON_DOWN) ? (char)1 : (char)0;");
      Line ("            }");
      Line ("        }");
      Line ("        else if (ty == SDL_EVENT_MOUSE_WHEEL)");
      Line ("        {");
      Line ("            albMouseWheel += (long)alb_sdl_read_f32(&ev, 28);");
      Line ("        }");
      Line ("    }");
      Line ("    return albRunning;");
      Line ("}");
      Line ("fn void alb_present()");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr != null) { sdl_render_present(rdr); }");
      Line ("}");
      Line ("fn void alb_sdl_shutdown()");
      Line ("{");
      Line ("    if (albSdlRenderer != null) { sdl_destroy_renderer(albSdlRenderer); albSdlRenderer = null; }");
      Line ("    if (albSdlWindow != null) { sdl_destroy_window(albSdlWindow); albSdlWindow = null; }");
      Line ("    if (albSdlReady) { albSdlReady = false; sdl_quit(); }");
      Line ("}");
      Line ("fn long alb_get_tick_count()");
      Line ("{");
      Line ("    if (albSdlReady) return (long)sdl_get_ticks();");
      Line ("    return albCompatTick;");
      Line ("}");
      Line ("fn void alb_create_window(String title, long w, long h)");
      Line ("{");
      Line ("    long ww = alb_max(1, w);");
      Line ("    long hh = alb_max(1, h);");
      Line ("    albWindowWidth = ww;");
      Line ("    albWindowHeight = hh;");
      Line ("    albBaseWidth = ww;");
      Line ("    albBaseHeight = hh;");
      Line ("    albVirtualWidth = ww;");
      Line ("    albVirtualHeight = hh;");
      Line ("    if (albSdlWindow == null)");
      Line ("    {");
      Line ("        if (!sdl_init(SDL_INIT_VIDEO))");
      Line ("        {");
      Line ("            char* e = sdl_get_error();");
      Line ("            alb_fatal(""SDL_Init failed"");");
      Line ("            return;");
      Line ("        }");
      Line ("        void* win = null;");
      Line ("        void* rdr = null;");
      Line ("        String t = (title.len > 0) ? title : ""ALBC3"";");
      Line ("        if (!sdl_create_window_and_renderer(alb_cstr(t), (int)ww, (int)hh, 0, &win, &rdr))");
      Line ("        {");
      Line ("            alb_fatal(""SDL_CreateWindowAndRenderer failed"");");
      Line ("            return;");
      Line ("        }");
      Line ("        albSdlWindow = win;");
      Line ("        albSdlRenderer = rdr;");
      Line ("        sdl_set_render_vsync(rdr, 1);");
      Line ("        albSdlReady = true;");
      Line ("    }");
      Line ("    for (int i = 0; i < 512; i++) albKeys[i] = 0;");
      Line ("    for (int i = 0; i < 8; i++) albMouseBtns[i] = 0;");
      Line ("}");
      Line ("fn void alb_clear(long rgb)");
      Line ("{");
      Line ("    alb_color(rgb);");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr != null) sdl_render_clear(rdr);");
      Line ("}");
      Line ("fn void alb_color(long rgb)");
      Line ("{");
      Line ("    albCurrentColor = rgb;");
      Line ("    albColorValue = rgb;");
      Line ("    alb_sdl_apply_color();");
      Line ("}");
      Line ("fn void alb_set_alpha(long a) { albAlphaValue = a & 255; }");
      Line ("fn void alb_set_clip(long x, long y, long w, long h) { }");
      Line ("fn void alb_set_origin(long x, long y) { albOriginX = x; albOriginY = y; }");
      Line ("fn void alb_set_stretchy(long v) { albStretchy = alb_truthy(v); }");
      Line ("fn void alb_set_resizable(long v) { albResizable = alb_truthy(v); }");
      Line ("fn void alb_set_fullscreen(long v) { }");
      Line ("fn void alb_set_font(String name, long size) { }");
      Line ("fn void alb_plot(long x, long y)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    alb_sdl_apply_color();");
      Line ("    sdl_render_point(rdr, (float)(x + albOriginX), (float)(y + albOriginY));");
      Line ("}");
      Line ("fn void alb_draw_line(long x1, long y1, long x2, long y2)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    float ox = (float)albOriginX;");
      Line ("    float oy = (float)albOriginY;");
      Line ("    alb_sdl_apply_color();");
      Line ("    sdl_render_line(rdr, (float)x1 + ox, (float)y1 + oy, (float)x2 + ox, (float)y2 + oy);");
      Line ("}");
      Line ("fn void alb_draw_rect(long x, long y, long w, long h)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    Sdl_FRect rect = { .x = (float)(x + albOriginX), .y = (float)(y + albOriginY), .w = (float)w, .h = (float)h };");
      Line ("    alb_sdl_apply_color();");
      Line ("    sdl_render_rect(rdr, &rect);");
      Line ("}");
      Line ("fn void alb_fill_rect(long x, long y, long w, long h)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    Sdl_FRect rect = { .x = (float)(x + albOriginX), .y = (float)(y + albOriginY), .w = (float)w, .h = (float)h };");
      Line ("    alb_sdl_apply_color();");
      Line ("    sdl_render_fill_rect(rdr, &rect);");
      Line ("}");
      Line ("fn void alb_draw_circle(long x, long y, long r)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    float cx = (float)(x + albOriginX);");
      Line ("    float cy = (float)(y + albOriginY);");
      Line ("    int rad = (int)alb_max(0, r);");
      Line ("    alb_sdl_apply_color();");
      Line ("    for (int yy = -rad; yy <= rad; yy++)");
      Line ("    {");
      Line ("        for (int xx = -rad; xx <= rad; xx++)");
      Line ("        {");
      Line ("            int d = xx * xx + yy * yy;");
      Line ("            int outer = rad * rad;");
      Line ("            int inner = (rad - 1) * (rad - 1);");
      Line ("            if (d <= outer && d >= inner) { sdl_render_point(rdr, cx + (float)xx, cy + (float)yy); }");
      Line ("        }");
      Line ("    }");
      Line ("}");
      Line ("fn void alb_fill_circle(long x, long y, long r)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    float cx = (float)(x + albOriginX);");
      Line ("    float cy = (float)(y + albOriginY);");
      Line ("    int rad = (int)alb_max(0, r);");
      Line ("    alb_sdl_apply_color();");
      Line ("    for (int yy = -rad; yy <= rad; yy++)");
      Line ("    {");
      Line ("        for (int xx = -rad; xx <= rad; xx++)");
      Line ("        {");
      Line ("            if (xx * xx + yy * yy <= rad * rad) { sdl_render_point(rdr, cx + (float)xx, cy + (float)yy); }");
      Line ("        }");
      Line ("    }");
      Line ("}");
      Line ("fn void alb_draw_triangle(long x1, long y1, long x2, long y2, long x3, long y3)");
      Line ("{");
      Line ("    alb_draw_line(x1, y1, x2, y2);");
      Line ("    alb_draw_line(x2, y2, x3, y3);");
      Line ("    alb_draw_line(x3, y3, x1, y1);");
      Line ("}");
      Line ("fn void alb_fill_triangle(long x1, long y1, long x2, long y2, long x3, long y3)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    float ox = (float)albOriginX;");
      Line ("    float oy = (float)albOriginY;");
      Line ("    Sdl_FColor c = alb_sdl_color_to_fcolor(albCurrentColor);");
      Line ("    Sdl_Vertex[3] verts;");
      Line ("    verts[0] = { .position = { .x = (float)x1 + ox, .y = (float)y1 + oy }, .color = c, .tex_coord = { .x = 0, .y = 0 } };");
      Line ("    verts[1] = { .position = { .x = (float)x2 + ox, .y = (float)y2 + oy }, .color = c, .tex_coord = { .x = 0, .y = 0 } };");
      Line ("    verts[2] = { .position = { .x = (float)x3 + ox, .y = (float)y3 + oy }, .color = c, .tex_coord = { .x = 0, .y = 0 } };");
      Line ("    sdl_render_geometry(rdr, null, &verts, 3, null, 0);");
      Line ("}");
      Line ("fn void alb_draw_text(long x, long y, String text)");
      Line ("{");
      Line ("    void* rdr = alb_sdl_renderer();");
      Line ("    if (rdr == null) { return; }");
      Line ("    alb_sdl_apply_color();");
      Line ("    sdl_render_debug_text(rdr, (float)(x + albOriginX), (float)(y + albOriginY), alb_cstr(text));");
      Line ("}");
      Line ("fn long alb_read_pixel(long x, long y) { return 0; }");
      Line ("fn void alb_export_ppm(String path) { }");
      Line ("fn long alb_screen_width() { return albWindowWidth; }");
      Line ("fn long alb_screen_height() { return albWindowHeight; }");
      Line ("fn long alb_virtual_width() { return albVirtualWidth; }");
      Line ("fn long alb_virtual_height() { return albVirtualHeight; }");
      Line ("fn long alb_mouse_x() { return albMouseX; }");
      Line ("fn long alb_mouse_y() { return albMouseY; }");
      Line ("fn long alb_vmouse_x() { return albMouseX; }");
      Line ("fn long alb_vmouse_y() { return albMouseY; }");
      Line ("fn long alb_mouse_wheel() { return albMouseWheel; }");
      Line ("fn long alb_mouse_click(long btn)");
      Line ("{");
      Line ("    int i = (int)btn;");
      Line ("    if (i >= 0 && i < 8) return (long)(albMouseBtns[i] & 255);");
      Line ("    return 0;");
      Line ("}");
      Line ("fn long alb_key(long code)");
      Line ("{");
      Line ("    int c = (int)code;");
      Line ("    if (c < 0 || c >= 512) return 0;");
      Line ("    long v = (long)(albKeys[c] & 255);");
      Line ("    if (c == 4) { v = (long)((albKeys[4] | albKeys[80]) & 255); }");
      Line ("    else if (c == 7) { v = (long)((albKeys[7] | albKeys[79]) & 255); }");
      Line ("    else if (c == 22) { v = (long)((albKeys[22] | albKeys[81]) & 255); }");
      Line ("    else if (c == 26) { v = (long)((albKeys[26] | albKeys[82]) & 255); }");
      Line ("    else if (c == 44) { v = (long)((albKeys[44] | albKeys[40]) & 255); }");
      Line ("    return (v != 0) ? 1 : 0;");
      Line ("}");
      Line ("fn void alb_delay(long ms)");
      Line ("{");
      Line ("    long m = alb_max(0, ms);");
      Line ("    if (albSdlReady) { sdl_delay((uint)m); }");
      Line ("    else { albDelayUntil = alb_get_tick_count() + m; }");
      Line ("    albCompatTick += m;");
      Line ("}");
      Line ("fn void alb_prepare_frame() { alb_sdl_apply_color(); }");
      Line ("fn void alb_runframe_once()");
      Line ("{");
      Line ("    if (!alb_poll_events()) { return; }");
      Line ("    long now = alb_get_tick_count();");
      Line ("    if (now < albDelayUntil) { return; }");
      Line ("    if (albLastFrame != 0 && (now - albLastFrame) < albFrameInterval) { return; }");
      Line ("    if (alb_on_tick != null) alb_on_tick();");
      Line ("    if (alb_on_key != null) alb_on_key();");
      Line ("    if (alb_on_paint != null) alb_on_paint();");
      Line ("    alb_present();");
      Line ("    albLastFrame = now;");
      Line ("    albCompatTick = now;");
      Line ("}");
      Line ("fn void alb_runframe_loop()");
      Line ("{");
      Line ("    while (albRunning && !albShutdownDone)");
      Line ("    {");
      Line ("        alb_runframe_once();");
      Line ("        if (albSdlReady) { sdl_delay(1); }");
      Line ("        else { break; }");
      Line ("    }");
      Line ("}");
      New_Line_Emit;
      Line ("// --- Feature stubs (network/process/logic/static assets) ---");
      Line ("fn void alb_init_logic() { }");
      Line ("fn void alb_save_state() { }");
      Line ("fn void alb_load_state() { }");
      Line ("fn void alb_sweep() { }");
      Line ("fn void alb_flushbuffer() { }");
      Line ("fn void alb_close() { }");
      Line ("fn void alb_cease() { }");
      Line ("fn void alb_define_system_font() { }");
      Line ("fn void alb_claim(long a) { }");
      Line ("fn void alb_drop(long a) { }");
      Line ("fn void alb_deref(long a) { }");
      Line ("fn void alb_firewall_enter(long a) { }");
      Line ("fn void alb_firewall_leave(long a) { }");
      Line ("fn void alb_firewall_touch_read(long a) { }");
      Line ("fn void alb_firewall_touch_write(long a) { }");
      Line ("fn void alb_process_monitor(long a) { }");
      Line ("fn void alb_process_dump(long a) { }");
      Line ("fn void alb_process_elevate(long a) { }");
      Line ("fn void alb_net_listen(long a) { }");
      Line ("fn void alb_net_close(long a) { }");
      Line ("fn void alb_seek(long a) { }");
      Line ("fn void alb_define_bitmap_font(long a) { }");
      Line ("fn void alb_compat_import(long a) { }");
      Line ("fn void alb_play_sound(long a) { }");
      Line ("fn void alb_play_music(long a) { }");
      Line ("fn void alb_export_ppm_i(long a) { }");
      Line ("fn long alb_peek(long addr) { return 0; }");
      Line ("fn long alb_poke(long addr, long val) { return val; }");
      Line ("fn long alb_open(String path, String mode) { return 1; }");
      Line ("fn long alb_read(long h) { return 0; }");
      Line ("fn void alb_write(long h, long v) { }");
      Line ("fn long alb_filelen(long h) { return 0; }");
      Line ("fn void alb_loadbuffer(long h, String path) { }");
      Line ("fn void alb_loadtextbuffer(long h, String path) { }");
      Line ("fn void alb_file_xor(String path, long key) { }");
      Line ("fn void alb_buffer_pack_le(long h) { }");
      Line ("fn long alb_firewall_read(String name, long v) { return v; }");
      Line ("fn long alb_firewall_write(String name, long v) { return v; }");
      Line ("fn void alb_msg_box(String title, String msg) { io::printn(title.tconcat("": "").tconcat(msg)); }");
      Line ("fn void alb_play_music_from(String path, long pos) { }");
      Line ("fn long alb_process_define(String name, String cmd) { return 1; }");
      Line ("fn long alb_process_create(long def) { return 1; }");
      Line ("fn long alb_process_read_scalar(long h, String name) { return 0; }");
      Line ("fn void alb_process_write_scalar(long h, String name, long v) { }");
      Line ("fn String alb_process_read_buffer(long h, String name) { return """"; }");
      Line ("fn long alb_process_sniff(long h) { return 0; }");
      Line ("fn long alb_net_define(String name, long proto) { return 1; }");
      Line ("fn long alb_net_accept(long h) { return 0; }");
      Line ("fn void alb_net_send(long h, String data) { }");
      Line ("fn String alb_net_receive(long h) { return """"; }");
      Line ("fn long alb_sniffer_define(String name) { return 1; }");
      Line ("fn long alb_sniffer_capture(long h) { return 0; }");
      Line ("fn long alb_nn_create(long inputs, long hidden, long outputs) { return 1; }");
      Line ("fn void alb_nn_train(long net, long epochs) { }");
      Line ("fn long alb_nn_infer(long net, long idx) { return 0; }");
      Line ("fn long alb_markov_predict(long model, long state) { return 0; }");
      Line ("fn void alb_static_surface(String name, long w, long h) { }");
      Line ("fn void alb_static_viewport(String name, long x, long y, long w, long h) { }");
      Line ("fn void alb_static_blit(String name, long x, long y) { }");
      Line ("fn void alb_static_apply_lut(String name) { }");
      Line ("fn void alb_static_sprite_from_bmp(String name, String path) { }");
      Line ("fn void alb_ini_bind(String section, String key, String target) { }");
      Line ("fn long alb_make_cell(long a, long b, long c, long d) { return 0; }");
      Line ("fn long alb_knows_set(long pred, long a1, long a2, long a3, long a4, long val) { return val; }");
      Line ("fn long alb_rel_set(long pred, long arity, long a1, long a2, long a3, long a4, long val) { return val; }");
      Line ("fn long alb_rel_has(long pred, long arity, long a1, long a2, long a3, long a4) { return 0; }");
      Line ("fn long alb_rel_find1(long pred, long arity, long a1, long a2, long a3, long a4) { return 0; }");
      Line ("fn long alb_rel_findall1(long pred, long arity, long a1, long a2, long a3, long a4) { return 0; }");
      Line ("fn void alb_rel_retract(long pred, long arity, long a1, long a2, long a3, long a4) { }");
      Line ("fn long alb_pred(String name) { return 0; }");
      Line ("fn void alb_bind(long h) { }");
      Line ("fn void alb_temp_past(String name) { }");
      Line ("fn void alb_temp_future(String name) { }");
      Line ("fn long alb_missing_call() { return 0; }");
      Line ("fn long alb_missing_field() { return 0; }");
      Line ("fn long alb_missing_member() { return 0; }");
      Line ("fn long alb_missing_target() { return 0; }");
      Line ("fn void alb_event_noop() {}");
      Line ("fn void alb_event_slot_0() {}");
      Line ("fn void alb_event_slot_1() {}");
      Line ("fn void alb_event_slot_2() {}");
      Line ("fn void alb_event_slot_3() {}");
      Line ("fn void alb_event_slot_4() {}");
      Line ("fn void alb_event_slot_5() {}");
      Line ("fn void alb_event_slot_6() {}");
      Line ("fn void alb_event_slot_7() {}");
      Line ("fn void alb_event_slot_8() {}");
      Line ("fn void alb_event_slot_9() {}");
      Line ("fn void alb_event_slot_10() {}");
      Line ("fn void alb_event_slot_11() {}");
      Line ("fn void alb_event_slot_12() {}");
      Line ("fn void alb_event_slot_13() {}");
      Line ("fn void alb_event_slot_14() {}");
      Line ("fn void alb_event_slot_15() {}");
      Line ("fn void alb_event_slot_16() {}");
      Line ("fn void alb_event_slot_17() {}");
      Line ("fn void alb_event_slot_18() {}");
      Line ("fn void alb_event_slot_19() {}");
      Line ("fn void alb_event_slot_20() {}");
      Line ("fn void alb_event_slot_21() {}");
      Line ("fn void alb_event_slot_22() {}");
      Line ("fn void alb_event_slot_23() {}");
      Line ("fn void alb_event_slot_24() {}");
      Line ("fn void alb_event_slot_25() {}");
      Line ("fn void alb_event_slot_26() {}");
      Line ("fn void alb_event_slot_27() {}");
      Line ("fn void alb_event_slot_28() {}");
      Line ("fn void alb_event_slot_29() {}");
      Line ("fn void alb_event_slot_30() {}");
      Line ("fn void alb_event_slot_31() {}");
      Line ("fn void alb_event_slot_32() {}");
      Line ("fn void alb_event_slot_33() {}");
      Line ("fn void alb_event_slot_34() {}");
      Line ("fn void alb_event_slot_35() {}");
      Line ("fn void alb_event_slot_36() {}");
      Line ("fn void alb_event_slot_37() {}");
      Line ("fn void alb_event_slot_38() {}");
      Line ("fn void alb_event_slot_39() {}");
      Line ("fn void alb_event_slot_40() {}");
      Line ("fn void alb_event_slot_41() {}");
      Line ("fn void alb_event_slot_42() {}");
      Line ("fn void alb_event_slot_43() {}");
      Line ("fn void alb_event_slot_44() {}");
      Line ("fn void alb_event_slot_45() {}");
      Line ("fn void alb_event_slot_46() {}");
      Line ("fn void alb_event_slot_47() {}");
      Line ("fn void alb_event_slot_48() {}");
      Line ("fn void alb_event_slot_49() {}");
      Line ("fn void alb_event_slot_50() {}");
      Line ("fn void alb_event_slot_51() {}");
      Line ("fn void alb_event_slot_52() {}");
      Line ("fn void alb_event_slot_53() {}");
      Line ("fn void alb_event_slot_54() {}");
      Line ("fn void alb_event_slot_55() {}");
      Line ("fn void alb_event_slot_56() {}");
      Line ("fn void alb_event_slot_57() {}");
      Line ("fn void alb_event_slot_58() {}");
      Line ("fn void alb_event_slot_59() {}");
      Line ("fn void alb_event_slot_60() {}");
      Line ("fn void alb_event_slot_61() {}");
      Line ("fn void alb_event_slot_62() {}");
      Line ("fn void alb_event_slot_63() {}");
      Line ("fn void alb_event_slot_64() {}");
      New_Line_Emit;
      Line ("// End of ALBC3 runtime preamble");
   end Emit_Runtime;


   function RustImport_Alias (Binding : Foreign_Binding_Record) return String is
   begin
      return "__alb_imp_" & Safe_C3_Name (To_String (Binding.C3_Name));
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
                  Escape_C3_String (C3Import_Specifier (To_String (Foreign_Imports (I).Path))) &
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
            Line ("// ALBC3 WASM stub fetch " &
                  Escape_C3_String (C3Import_Specifier (To_String (Foreign_Imports (I).Path))) &
                  ");");
            Line ("if (!response.ok) alb_fatal(`WASM fetch failed for " &
                  To_String (Foreign_Imports (I).Name) & ": ${response.status}`);");
            Line ("// ALBC3 WASM stub arrayBuffer");
            Line ("// ALBC3 WASM stub instantiate");
            Line ("// ALBC3 WASM stub exports");
            Line ("// ALBC3 WASM stub fn " &
                  Escape_C3_String (To_String (Foreign_Imports (I).Name)) & "];");
            Line ("if (/*tyof*/ fn != 'function') alb_fatal('Missing WASM export: " &
                  To_String (Foreign_Imports (I).Name) & "');");
            Line ("albWasmBindings[" &
                  Escape_C3_String (To_String (Foreign_Imports (I).C3_Name)) &
                  "] = fn as (...args: long[]) => any;");
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
                     Escape_C3_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args: long[]) => (" &
                     To_String (Foreign_Exports (I).C3_Name) &
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
                     Escape_C3_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args: long[]) => (" &
                     To_String (Foreign_Exports (I).C3_Name) &
                     " as any)(...args);");
            end if;
         end loop;
         Line ("Object.assign(globalThis as Record<string, unknown>, albCompatExports);");
         New_Line_Emit;
      end if;

      if Any_ES_Exports then
         --  Emit one export per line so full-engine libraries (~1k+ symbols)
         --  do not produce a single multi-megabyte export { â€¦ } statement.
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_ES then
               Line ("export { " &
                     To_String (Foreign_Exports (I).C3_Name) & " as " &
                     To_String (Foreign_Exports (I).Name) & " };");
            end if;
         end loop;
         New_Line_Emit;
      end if;
   end Emit_Module_Exports;

   --  Native DLL/SO/Dylib/Jar imports via LoadLibraryA/GetProcAddress (Win64 C ABI).
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
         return Tag = VK_F64;
      end Is_Float_Tag;

      function Looks_Like_CString_Param
        (Param_Name : String;
         Tag        : Value_Kind) return Boolean
      is
         U : constant String := Upper_Text (Param_Name);
      begin
         if Tag /= VK_Number and then Tag /= VK_U64 and then Tag /= VK_Unknown
           and then Tag /= VK_S32
         then
            return False;
         end if;
         return U = "TITLE" or else U = "NAME" or else U = "MSG"
           or else U = "LABEL" or else U = "ITEMS_PIPE"
           or else U = "PATH" or else U = "TEXT" or else U = "CAPTION"
           or else U = "FILENAME" or else U = "FILE" or else U = "URL"
           or else U = "ITEMS";
         --  Note: SELECTED is usually an integer index, not a cstring.
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

      --  Pointer-sized / opaque handles only. Narrow integers must stay
      --  `int` so Win64 FFI matches C uint32_t/int32_t (mem_poke offset,
      --  mem_alloc bytes, set_texture_rgba byte_count, lat/lon bands).
      function Is_Pointerish_Int_Tag (Tag : Value_Kind) return Boolean is
      begin
         case Tag is
            when VK_Number | VK_U64 | VK_Pure | VK_Unknown =>
               return True;
            when others =>
               return False;
         end case;
      end Is_Pointerish_Int_Tag;

      function Is_Narrow_Int_Tag (Tag : Value_Kind) return Boolean is
      begin
         case Tag is
            when VK_S32 | VK_U32 | VK_U16 | VK_U8
               | VK_S8 | VK_S16 | VK_HW8 | VK_HW16 | VK_HW32 =>
               return True;
            when others =>
               return False;
         end case;
      end Is_Narrow_Int_Tag;

      function C_Foreign_Param_Type (Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return "float";
         elsif Is_Narrow_Int_Tag (Tag) then
            return "int";
         elsif Tag = VK_String or else Tag = VK_Binary then
            return "char*";
         elsif Is_Pointerish_Int_Tag (Tag) then
            return "void*";
         else
            return "long";
         end if;
      end C_Foreign_Param_Type;

      function C_Foreign_Return_Type (Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return "double";
         elsif Is_Narrow_Int_Tag (Tag) then
            return "int";
         elsif Tag = VK_String or else Tag = VK_Binary then
            return "char*";
         elsif Is_Pointerish_Int_Tag (Tag) then
            return "void*";
         else
            return "long";
         end if;
      end C_Foreign_Return_Type;

      function Cast_Arg_To_C (Param_Name : String; Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return "(float)" & Param_Name;
         elsif Is_Narrow_Int_Tag (Tag) then
            return "(int)" & Param_Name;
         elsif Tag = VK_String or else Tag = VK_Binary then
            return "__c_" & Param_Name;
         elsif Is_Pointerish_Int_Tag (Tag) then
            return "(void*)" & Param_Name;
         else
            return Param_Name;
         end if;
      end Cast_Arg_To_C;

      function Wrap_C_Return (Call_Expr : String; Tag : Value_Kind) return String is
      begin
         if Is_Float_Tag (Tag) then
            return Call_Expr;
         elsif Is_Narrow_Int_Tag (Tag) then
            return "(long)" & Call_Expr;
         elsif Tag = VK_String or else Tag = VK_Binary then
            --  C3 rejects `(String)char*`; go through length-aware helper.
            return "alb_from_cstr(" & Call_Expr & ")";
         elsif Is_Pointerish_Int_Tag (Tag) then
            return "(long)" & Call_Expr;
         else
            return Call_Expr;
         end if;
      end Wrap_C_Return;
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
         Binding.C3_Name := U (Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
         Binding.Is_Function := Tree (Decl_Node).Kind = AST_Function_Decl;
         Binding.Return_Tag := Type_From_Token (Tree (Decl_Node).Token_Index);
         if Binding.Return_Tag = VK_Unknown then
            Binding.Return_Tag := VK_Number;
         end if;
      end if;

      declare
         Wrapper_Name : constant String := To_String (Binding.C3_Name);
         Sym_Name     : constant String := To_String (Binding.Name);
         Ret_C3       : constant String := Primitive_C3_Type (Binding.Return_Tag);
         Nil_Ret      : constant String := Default_Value (Binding.Return_Tag);
         Alias_Name   : constant String := "Alb_Ffi_" & Safe_C3_Type_Name (Wrapper_Name);
         Slot_Name    : constant String := "alb_ffi_slot_" & Wrapper_Name;
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
                       Safe_C3_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
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
                     Append (Param_Sig, Primitive_C3_Type (Param_Tag) & " " & Param_Name);
                     Append (C_Param_Sig, C_Foreign_Param_Type (Param_Tag) & " " & Param_Name);
                     Append (Call_Args, Cast_Arg_To_C (Param_Name, Param_Tag));
                     First := False;
                  end;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         if Binding.Is_Function then
            Line ("alias " & Alias_Name & " = fn " & C_Foreign_Return_Type (Binding.Return_Tag) &
                  "(" & To_String (C_Param_Sig) & ");");
         else
            Line ("alias " & Alias_Name & " = fn void(" & To_String (C_Param_Sig) & ");");
         end if;
         Line ("void* " & Slot_Name & " = null;");

         Emit_Indent;
         if Binding.Is_Function then
            Emit ("fn " & Ret_C3 & " " & Wrapper_Name & "(" & To_String (Param_Sig) & ")");
         else
            Emit ("fn void " & Wrapper_Name & "(" & To_String (Param_Sig) & ")");
         end if;
         New_Line_Emit;
         Line ("{");
         Indent_Level := Indent_Level + 1;

         if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
            Param_Node := Tree (List_Node).Left_Child;
            while Param_Node > 0 loop
               if Tree (Param_Node).Kind = AST_Param_Decl then
                  declare
                     Param_Name : constant String :=
                       Safe_C3_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
                     Raw_Tag    : constant Value_Kind :=
                       (if Tree (Param_Node).Right_Child > 0
                        then Type_From_Token (Tree (Tree (Param_Node).Right_Child).Token_Index)
                        else VK_Number);
                     Param_Tag  : constant Value_Kind :=
                       Effective_Param_Tag (Param_Name, Raw_Tag);
                  begin
                     if Param_Tag in VK_String | VK_Binary then
                        Line ("char* __c_" & Param_Name & " = alb_cstr(alb_text_s(" & Param_Name & "));");
                     end if;
                  end;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         Line ("if (" & Slot_Name & " == null)");
         Line ("{");
         Indent_Level := Indent_Level + 1;
         Line (Slot_Name & " = alb_load_sym(" & Escape_C3_String (Resolved) & ", " &
               Escape_C3_String (Sym_Name) & ");");
         if Binding.Is_Function then
            Line ("if (" & Slot_Name & " == null) return " & Nil_Ret & ";");
         else
            Line ("if (" & Slot_Name & " == null) return;");
         end if;
         Indent_Level := Indent_Level - 1;
         Line ("}");

         Line (Alias_Name & " p = (" & Alias_Name & ")" & Slot_Name & ";");
         if Binding.Is_Function then
            Line ("return " & Wrap_C_Return ("p(" & To_String (Call_Args) & ")", Binding.Return_Tag) & ";");
         else
            Line ("p(" & To_String (Call_Args) & ");");
         end if;

         Indent_Level := Indent_Level - 1;
         Line ("}");
         New_Line_Emit;
      end;
   end Emit_Dll_Import_Node;

   procedure Emit_Foreign_Import_Node (Index : Node_Index) is
      Binding    : Foreign_Binding_Record;
      Decl_Node  : constant Node_Index := Tree (Index).Left_Child;
      Name_Node  : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      List_Node  : constant Node_Index := (if Name_Node > 0 then Tree (Name_Node).Right_Child else 0);
      Param_Node : Node_Index := 0;
      First      : Boolean := True;

      function Looks_Like_CString_Param
        (Param_Name : String;
         Tag        : Value_Kind) return Boolean
      is
         U : constant String := Upper_Text (Param_Name);
      begin
         if Tag /= VK_Number and then Tag /= VK_U64 and then Tag /= VK_Unknown
           and then Tag /= VK_S32
         then
            return False;
         end if;
         return U = "TITLE" or else U = "NAME" or else U = "MSG"
           or else U = "LABEL" or else U = "ITEMS_PIPE"
           or else U = "PATH" or else U = "TEXT" or else U = "CAPTION"
           or else U = "FILENAME" or else U = "FILE" or else U = "URL"
           or else U = "ITEMS";
      end Looks_Like_CString_Param;
   begin
      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Node = Index then
            Binding := Foreign_Imports (I);
            exit;
         end if;
      end loop;

      if not Binding.Active and then Name_Node > 0 then
         Binding.Active := True;
         Binding.Name := U (Raw_Lexeme (Tree (Name_Node).Token_Index));
         Binding.C3_Name := U (Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
         Binding.Is_Function := Tree (Decl_Node).Kind = AST_Function_Decl;
         Binding.Return_Tag := Type_From_Token (Tree (Decl_Node).Token_Index);
         if Binding.Return_Tag = VK_Unknown then
            Binding.Return_Tag := VK_Number;
         end if;
      end if;

      if not Binding.Active or else Name_Node = 0 then
         return;
      end if;

      --  ES/WASM fallback stubs (native DLL handled by Emit_Dll_Import_Node).
      Emit_Indent;
      if Binding.Is_Function then
         Emit ("fn " & Primitive_C3_Type (Binding.Return_Tag) & " " &
               To_String (Binding.C3_Name) & "(");
      else
         Emit ("fn void " & To_String (Binding.C3_Name) & "(");
      end if;

      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Param_Node := Tree (List_Node).Left_Child;
         while Param_Node > 0 loop
            if Tree (Param_Node).Kind = AST_Param_Decl then
               declare
                  Param_Name : constant String :=
                    Safe_C3_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
                  Raw_Tag    : constant Value_Kind :=
                    (if Tree (Param_Node).Right_Child > 0
                     then Type_From_Token (Tree (Tree (Param_Node).Right_Child).Token_Index)
                     else VK_Number);
                  Param_Tag  : constant Value_Kind :=
                    (if Looks_Like_CString_Param (Param_Name, Raw_Tag)
                     then VK_String
                     else Raw_Tag);
               begin
                  if not First then
                     Emit (", ");
                  end if;
                  Emit (Primitive_C3_Type (Param_Tag) & " " & Param_Name);
                  First := False;
               end;
            end if;
            Param_Node := Tree (Param_Node).Next_Sibling;
         end loop;
      end if;

      Emit (")");
      New_Line_Emit;
      Line ("{");
      Indent_Level := Indent_Level + 1;
      if Binding.Is_Function then
         Line ("return " & Default_Value (Binding.Return_Tag) & ";");
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
            Escape_C3_String (To_String (Content)) & ";");
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
                  return "__alb_garr:" & To_String (Sym.C3_Name) & ":" & Idx_Expr;
               else
                  return To_String (Sym.C3_Name) & "[" & Idx_Expr & "]";
               end if;
            end;
         elsif Sym.Active
           and then Is_Global_Storage_Sym (Sym)
           and then Sym.Kind in Sym_Scalar | Sym_Const | Sym_Temporal
         then
            return "__alb_gscal:" & To_String (Sym.C3_Name);
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
                             To_String (Symbols (Field_Sym_Id).C3_Name) & ":" & Idx_Expr;
                        else
                           return To_String (Symbols (Field_Sym_Id).C3_Name) &
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
                     return "__alb_garr:" & To_String (Group_Sym.C3_Name) & ":" & Idx_Expr;
                  else
                     return To_String (Group_Sym.C3_Name) & "[" & Idx_Expr & "]";
                  end if;
               end;
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               return To_String (Left_Sym.C3_Name) & "." & Safe_C3_Name (Right_Name);
            elsif Group_Sym.Active then
               if Is_Global_Storage_Sym (Group_Sym)
                 and then Group_Sym.Kind in Sym_Scalar | Sym_Const | Sym_Temporal
               then
                  return "__alb_gscal:" & To_String (Group_Sym.C3_Name);
               end if;
               return To_String (Group_Sym.C3_Name);
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
            return To_String (Sym.C3_Name);
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
               return Firewall_Key_For_Symbol (Sym, To_String (Sym.C3_Name));
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
               return Firewall_Key_For_Symbol (Group_Sym, To_String (Group_Sym.C3_Name));
            elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               if To_String (Left_Sym.Scope) /= "" then
                  return "";
               else
                  return To_String (Left_Sym.C3_Name) & "." & Safe_C3_Name (Right_Name);
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
      if not Need_Firewall_Runtime or else Key'Length = 0 then
         return Value_Text;
      else
         return "alb_firewall_read(" & Escape_C3_String (Key) & ", " & Value_Text & ")";
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
         return "alb_firewall_write(" & Escape_C3_String (Key) & ", " & Value_Text & ")";
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
         Line ("alb_firewall_touch_read(" & Escape_C3_String (Key) & ");");
      end if;

      if Need_Write then
         Line ("alb_firewall_touch_write(" & Escape_C3_String (Key) & ");");
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
      Handler     : constant String := Name & "_handler";
   begin
      if Count = 0 then
         return;
      end if;

      Current_Routine := U (Handler);
      --  Module-scope handler. Pointer slot is wired from main().
      Line ("fn void " & Handler & "()");
      Line ("{");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Count loop
         Emit_Block (Blocks (I));
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;
      Current_Routine := Old_Routine;
   end Emit_Event_Handler;

   procedure Emit_Address_Routines is
   begin
      --  Runtime already provides alb_peek/POKE/DEREF. Skip TS leftover override.
      null;
   end Emit_Address_Routines;

   procedure Emit_State_Routines is
   begin
      --  Runtime preamble already provides alb_save_state / alb_load_state stubs.
      null;
   end Emit_State_Routines;

   procedure Emit_Logic_Setup is
   begin
      if Rule_Node_Count = 0 and Watch_Node_Count = 0 then
         return;
      end if;

      Line ("fn void alb_init_logic()");
      Line ("{");
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

      Line ("alb_notify_knows_change = fn void (long pred, long arg1, long arg2, long arg3, long arg4)");
      Line ("{");
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
               Var_JS     : constant String := Safe_C3_Name (Var_Name);
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
                       C3_Name => Var_JS,
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
      Line ("alb_init_logic();");
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
      Line ("long " & Switch_Value & " = " & Expr (Expr_Node) & ";");
      Line ("switch (" & Switch_Value & ") {");
      Indent_Level := Indent_Level + 1;

      while Curr_Case > 0 loop
         if Tree (Curr_Case).Left_Child = 0 then
            Line ("default:");
            Saw_Else := True;
         else
            Line ("case " & Expr (Tree (Curr_Case).Left_Child) & ":");
         end if;
         Indent_Level := Indent_Level + 1;
         Emit_Block (Tree (Curr_Case).Right_Child);
         Line ("break;");
         Indent_Level := Indent_Level - 1;
         Curr_Case := Tree (Curr_Case).Next_Sibling;
      end loop;

      if not Saw_Else then
         Line ("default:");
         Indent_Level := Indent_Level + 1;
         Line ("break;");
         Indent_Level := Indent_Level - 1;
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
            Line (To_String (Target_Sym.C3_Name) & "[" & Swap_Index & "] = " &
                  To_String (Target_Sym.C3_Name) & "[" & Last_Index & "];");
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
                       (To_String (Symbols (I).C3_Name),
                        Symbols (I).Tag,
                        Swap_Index,
                        Global_Array_Get
                          (To_String (Symbols (I).C3_Name),
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
        Cast_Expr
          (Decl_Tag,
           Emit_Value_Expr_With_Out (Value_Node),
           Infer_Expr_Kind (Value_Node));
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
               then Find_Field (To_String (Left_Sym.Struct_Name), Safe_C3_Name (Raw_Lexeme (Right_Node.Token_Index)))
               else 0);
         begin
            if Field_Id /= 0 and then Fields (Field_Id).Bit_Width > 0 then
               Line (Field_Write_Expr (To_String (Left_Sym.C3_Name), Field_Id, Value_Text) & ";");
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
              (Global_Scalar_Set (To_String (TSym.C3_Name), Decl_Tag, Value_Text) & ";");
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
            Line (Primitive_C3_Type (Decl_Tag) & " " & Target_Name & " = " & Value_Text & ";");
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
      Struct_Name : constant String := Safe_C3_Type_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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
                     Field_Name := U (Safe_C3_Name (Raw_Lexeme (Tree (Field_Node.Left_Child).Token_Index)));
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
                        Field_Name := U (Safe_C3_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)));
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
         C3_Name   : constant String :=
           (if Upper_Text (Func_Name) = "GETTICKCOUNT"
            then "alb_user_gettickcount"
            else Scoped_Name (Func_Name));
      begin
         Register_Routine (Func_Name, C3_Name, Param_Count, Modes);
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
                     Current_Module := U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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
      C3_Name      : constant String :=
        (if Upper_Text (Func_Name) = "GETTICKCOUNT"
         then "alb_user_gettickcount"
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

      Current_Routine := U (C3_Name);
      Current_Routine_Out_Count := 0;

      if Is_Function and then Node.Token_Index > 0 then
         Return_Type := Type_From_Token (Node.Token_Index);
         if Return_Type = VK_Unknown then
            Return_Type := VK_Number;
         end if;
      end if;

      Emit_Indent;
      if Is_Function then
         Emit ("fn " & Primitive_C3_Type (Return_Type) & " " & C3_Name & "(");
      else
         Emit ("fn void " & C3_Name & "(");
      end if;

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
                     then "__out_" & Safe_C3_Name (Param_Name)
                     else Safe_C3_Name (Param_Name));
               begin
                  if not First_Param then
                     Emit (", ");
                  end if;
                  if Mode = Param_Out then
                     Emit (Primitive_C3_Type (Param_Kind) & "* " & Decl_Name);
                     if Current_Routine_Out_Count < Max_Params then
                        Current_Routine_Out_Count := Current_Routine_Out_Count + 1;
                        Current_Routine_Out_Names (Current_Routine_Out_Count) :=
                          U (Safe_C3_Name (Param_Name));
                     end if;
                  else
                     Emit (Primitive_C3_Type (Param_Kind) & " " & Decl_Name);
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

      Emit (")");
      New_Line_Emit;
      Line ("{");
      Indent_Level := Indent_Level + 1;

      Register_Routine (Func_Name, C3_Name, Param_Count, Modes);

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
                  Decl_Name       : constant String := Safe_C3_Name (Param_Name);
               begin
                  Register_Symbol
                    (Scope => C3_Name,
                     Name => Param_Name,
                     C3_Name => Decl_Name,
                     Tag => Param_Kind,
                     Kind => Sym_Param);
                  if Mode = Param_Out then
                     Line (Primitive_C3_Type (Param_Kind) & " " & Decl_Name &
                           " = *__out_" & Decl_Name & ";");
                  end if;
               end;
            elsif Tree (Curr_Param).Kind = AST_Require_Clause then
               Line ("if (!alb_truthy(" & Expr (Tree (Curr_Param).Left_Child) &
                     ")) { alb_fatal(""REQUIRE failed""); }");
            elsif Tree (Curr_Param).Kind = AST_Bound_To_Clause then
               Bound_Node := Curr_Param;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Line ("alb_firewall_enter(" & Expr (Tree (Bound_Node).Left_Child) & ");");
         Line ("// ALBC3 try-begin"); Line ("{");
         Indent_Level := Indent_Level + 1;
      end if;

      --  Always lower the ALB body (FASM style). Never special-case user
      --  module/proc names — game/app logic lives in .alb/.albi only.
      Emit_Block (Body_Node);

      if Param_Count > 0 then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Param_Name : constant String := Safe_C3_Name (Raw_Lexeme (Tree (Param_Name_Node).Token_Index));
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
         Line ("alb_firewall_leave();");
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
      C3_Name     : Unbounded_String := U ("");
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
               Curr      : Node_Index := 0;
            begin
               if Name_Node > 0 then
                  Current_Module := U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
               end if;
               --  Procedure/function decls are hoisted to module scope before
               --  main(); module storage is emitted in alb_init_globals().
               --  Only emit remaining executable statements here.
               if Body_Node > 0 then
                  if Tree (Body_Node).Kind = AST_Block_Stmt then
                     Curr := Tree (Body_Node).Left_Child;
                  else
                     Curr := Body_Node;
                  end if;
                  while Curr > 0 loop
                     if Tree (Curr).Kind /= AST_Procedure_Decl
                       and then Tree (Curr).Kind /= AST_Function_Decl
                       and then Tree (Curr).Kind /= AST_Strict_Stmt
                       and then Tree (Curr).Kind /= AST_Slide_Stmt
                       and then Tree (Curr).Kind /= AST_Parallel_Decl
                       and then Tree (Curr).Kind /= AST_Temporal_Decl
                       and then Tree (Curr).Kind /= AST_Let_Stmt
                       and then Tree (Curr).Kind /= AST_Const_Decl
                       and then Tree (Curr).Kind /= AST_Enum_Decl
                       and then Tree (Curr).Kind /= AST_Struct_Decl
                       and then Tree (Curr).Kind /= AST_Import_DLL
                       and then Tree (Curr).Kind /= AST_Import_SO
                       and then Tree (Curr).Kind /= AST_Import_Dylib
                       and then Tree (Curr).Kind /= AST_Import_Jar
                       and then Tree (Curr).Kind /= AST_Import_ES
                       and then Tree (Curr).Kind /= AST_Import_WASM
                     then
                        Emit_Node (Curr);
                     end if;
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end if;
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
               Embed_Name   : constant String := "__alb_bmp_" & Safe_C3_Name (Sprite_RS);
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
                                  "STATIC_SPRITE without FORMAT defaults to INDEXED8BIT on ALBC3");
               elsif To_String (Format_Text) /= "INDEXED8BIT" then
                  Emit_Warn_Once ("static-sprite-format-" & Safe_C3_Name (To_String (Format_Text)),
                                  "STATIC_SPRITE format " & To_String (Format_Text) &
                                  " is approximated as INDEXED8BIT on ALBC3");
               end if;
               if Length (Source_Path) > 0 then
                  Emit_Embedded_File_Bytes (Embed_Name, To_String (Source_Path));
               else
                  Emit_Warn_Once ("static-sprite-missing-source-" & Safe_C3_Name (Sprite_RS),
                                  "STATIC_SPRITE without SOURCE becomes a blank sprite on ALBC3");
                  Line ("const " & Embed_Name & ": Vec<u8> = vec![0];");
               end if;
               Line ("long " & Sprite_RS & " = alb_static_sprite_from_bmp(" &
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
                                  "STATIC_SURFACE without FORMAT defaults to RGB565 on ALBC3");
               elsif To_String (Format_Text) /= "RGB565" then
                  Emit_Warn_Once ("static-surface-format-" & Safe_C3_Name (To_String (Format_Text)),
                                  "STATIC_SURFACE format " & To_String (Format_Text) &
                                  " is approximated as RGB565 on ALBC3");
               end if;
               Line ("long " & Surface_RS & " = alb_static_surface(" &
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
               Emit ("ulong[] " & LUT_RS & " = {");
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
                 (if Param_Node > 0 then Safe_C3_Name (Raw_Feature_Atom (Param_Node)) else "_alb_context");
               Clause     : Node_Index := Node.Right_Child;
            begin
               Register_Symbol ("", Rule_RS, Rule_RS, VK_Number, Sym_Scalar);
               Line ("long " & Rule_RS & " = {");
               Indent_Level := Indent_Level + 1;
               Line ("kind: 'visualRule',");
               Line ("name: " & Escape_C3_String (Rule_Name) & ",");
               Line ("resolve: (" & Param_Name & ": long) => {");
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
               Line ("long " & View_RS & " = alb_static_viewport(" &
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
                  Emit_Warn_Once ("bitmap-font-descriptor-" & Safe_C3_Name (Font_RS),
                                  "BITMAP_FONT descriptor metadata is accepted but canvas text remains an approximation on ALBC3");
               end if;
               Line ("long " & Font_RS & " = alb_define_bitmap_font(" &
                     Escape_C3_String (Font_Name) & ", " &
                     (if Length (Source_Text) > 0 then To_String (Source_Text) else Escape_C3_String ("")) & ", " &
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
               Family_Text     : Unbounded_String := U (Escape_C3_String (Font_Name));
               Size_Text       : Unbounded_String := U ("16");
               Weight_Text     : Unbounded_String := U (Escape_C3_String ("normal"));
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
               Line ("long " & Font_RS & " = alb_define_system_font(" &
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
                              Append (Read_Text, Escape_C3_String (Key));
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
                              Append (Write_Text, Escape_C3_String (Key));
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
               Line ("long " & FW_RS & " = { kind: 'firewall', name: " &
                     Escape_C3_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
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
                              Append (Rights_Text, Escape_C3_String (Raw_Feature_Atom (Right_Node)));
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
               Line ("long " & Proc_JS & " = alb_process_define(" &
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
               Interface_Text : Unbounded_String := U (Escape_C3_String ("any"));
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
                               "NETWORK_SNIFFER is simulated on ALBC3 with deterministic sample packets");
               Line ("long " & Error_JS & " = alb_make_cell(0);");
               Line ("long " & Sniffer_JS & " = alb_sniffer_define(" &
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
               Line ("long " & Socket_JS & " = alb_net_define(" &
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
               Emit ("long " & Model_JS & " = { states: " & To_String (States_Text) & ", matrix: [");
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
               Emit ("long " & Net_JS & " = alb_nn_create(" &
                     Escape_C3_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
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
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               declare
                  R : constant String := To_String (Raw_Name);
                  Existing : Natural;
               begin
                  C3_Name := U (Safe_C3_Name (R (R'First + 1 .. R'Last)));
                  Capacity := Eval_Static_Int (Value_Node);
                  Existing := Find_Symbol ("", To_String (C3_Name));
                  if Existing = 0 then
                     --  Use let so later #CONST redefinitions (common across
                     --  engine modules) can reassign under ES module mode.
                     Register_Symbol
                       ("", To_String (C3_Name), To_String (C3_Name),
                        VK_Number, Sym_Const, Capacity => Capacity);
                     Line (Global_Scalar_Set
                             (To_String (C3_Name), VK_Number, Expr (Value_Node)) & ";");
                  else
                     Symbols (Existing).Capacity := Capacity;
                     Line (Global_Scalar_Set
                             (To_String (C3_Name), VK_Number, Expr (Value_Node)) & ";");
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
                  C3_Name := U (Safe_C3_Name (To_String (Raw_Name)));
                  declare
                     Existing : constant Natural :=
                       Find_Symbol ("", To_String (C3_Name));
                  begin
                     if Existing = 0 then
                        Register_Symbol
                          ("", To_String (C3_Name), To_String (C3_Name),
                           VK_Number, Sym_Const, Capacity => Value);
                        Line (Global_Scalar_Set
                                (To_String (C3_Name), VK_Number, Trim_Image (Value)) & ";");
                     else
                        Symbols (Existing).Capacity := Value;
                        Line (Global_Scalar_Set
                                (To_String (C3_Name), VK_Number, Trim_Image (Value)) & ";");
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
               Struct_Name : constant String := Safe_C3_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
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
                          (Safe_C3_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)) &
                           ": " &
                           (if Tree (Curr).Token_Index > 0
                            then Type_Annotation_From_Name (Raw_Lexeme (Tree (Curr).Token_Index))
                            else "number"));
                     else
                        Emit ("long alb_missing_field");
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
               C3_Name := U (Scoped_Name (To_String (Raw_Name)));
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
               Register_Symbol ("", To_String (C3_Name), To_String (C3_Name), Tag, Sym_Strict_Array, Rank, Dims, Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               Line (Vec_Decl_Line (To_String (C3_Name), Tag, Trim_Image (Capacity)));
            end if;

         when AST_Slide_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               C3_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0
                       then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                       else VK_Number);
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (C3_Name), To_String (C3_Name), Tag, Sym_Slide_Array, 1, (1 => Capacity, others => 0), Capacity,
                                Active_Size => (if Tree (Node.Right_Child).Next_Sibling > 0 then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling) else Capacity),
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               Line (Vec_Decl_Line (To_String (C3_Name), Tag, Trim_Image (Capacity)));
               Line ("alb_gscal_set(" & Escape_C3_String (To_String (C3_Name) & "_active") &
                     ", " &
                     Trim_Image ((if Tree (Node.Right_Child).Next_Sibling > 0
                                  then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling)
                                  else Capacity)) & ");");
            end if;

         when AST_Parallel_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               C3_Name := U (Scoped_Name (To_String (Raw_Name)));
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
                        --  Match STRICT naming: module-scoped garr keys.
                        Field_JS        : constant String :=
                          Scoped_Name (To_String (Raw_Name) & "_" & Field_Name);
                        Field_Tag       : constant Value_Kind :=
                          (if Tree (Field_Name_Node).Right_Child > 0
                           then Type_From_Name (Raw_Lexeme (Tree (Tree (Field_Name_Node).Right_Child).Token_Index))
                           else VK_Number);
                     begin
                        Register_Symbol ("", To_String (C3_Name) & "." & Field_Name, Field_JS, Field_Tag,
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
               C3_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := VK_Number;
               end if;
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (C3_Name), To_String (C3_Name), Tag, Sym_Temporal,
                                History_Size => Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (Tag)));
               declare
                  TId : constant Natural := Find_Symbol ("", To_String (C3_Name));
               begin
                  if TId /= 0 then
                     Symbols (TId).Aux_Offset := Allocate_Address_Bytes (Capacity * Element_Bytes (Tag));
                  end if;
               end;
               Line (Global_Scalar_Set
                       (To_String (C3_Name), Tag,
                        Cast_Expr (Tag, Expr (Tree (Node.Right_Child).Next_Sibling))) & ";");
               if Tag in VK_String | VK_Binary then
                  Line ("alb_gstrarr_init(" & Escape_C3_String (To_String (C3_Name) & "_history") &
                        ", " & Trim_Image (Capacity) & ");");
               else
                  Line ("alb_garr_init(" & Escape_C3_String (To_String (C3_Name) & "_history") &
                        ", " & Trim_Image (Capacity) & ");");
               end if;
               Line ("alb_gscal_set(" & Escape_C3_String (To_String (C3_Name) & "_head") &
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
                        Plain_Id  : constant Natural := Find_Symbol ("", Safe_C3_Name (To_String (Raw_Name)));
                     begin
                        if Global_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Global_Id).Tag, False);
                        elsif Plain_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Plain_Id).Tag, False);
                        else
                           Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_C3_Name (To_String (Raw_Name)), Tag, Sym_Scalar);
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
                           Struct_Name : constant String := Safe_C3_Name (Raw_Lexeme (Node.Token_Index));
                           SIdx : constant Natural := Find_Struct (Struct_Name);
                        begin
                           Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Struct_Var,
                                            Struct_Name => Raw_Lexeme (Node.Token_Index),
                                            Offset_Bytes => (if SIdx /= 0 then Allocate_Address_Bytes (Structs (SIdx).Size_Bytes) else 0));
                        end;
                        declare
                           Struct_Name : constant String := Safe_C3_Name (Raw_Lexeme (Node.Token_Index));
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
                             (Primitive_C3_Type (Tag) & " " & Scoped_Name (To_String (Raw_Name)) &
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
                                  "STRIDE nesting beyond 32 levels falls back to normal FOR stepping on ALBC3");
                  Emit_Block (Body_Node);
               end if;
            end;

         when AST_Ratio_Space_Block =>
            Emit_Warn_Once ("ratio-space-albr",
                            "RATIO_SPACE pinning is approximated as ordinary Rust evaluation on ALBC3");
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
               Line ("long " & Width_Name & " = alb_max(1, alb_i64(" & To_String (Width_Text) & "));");
               Line ("long " & Height_Name & " = alb_max(1, alb_i64(" & To_String (Height_Text) & "));");
               Line ("long " & Limit_Name & " = alb_max(" & Width_Name & ", " & Height_Name & ");");
               Line (Primitive_C3_Type (Tag) & " " & Code_Name & ": i64 = 0;");
               Line (Primitive_C3_Type (Tag) & " " & Seen_Name & ": i64 = 0;");
               Line ("while " & Seen_Name & " < (" & Width_Name & " * " & Height_Name & ") {");
               Indent_Level := Indent_Level + 1;
               Line (Primitive_C3_Type (Tag) & " " & X_Name & ": i64 = 0;");
               Line (Primitive_C3_Type (Tag) & " " & Y_Name & ": i64 = 0;");
               Line ("long " & Bits_Name & " = " & Code_Name & ";");
               Line (Primitive_C3_Type (Tag) & " " & Shift_Name & ": i64 = 0;");
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
               Line ("if (" & X_Name & " >= " & Width_Name & " || " & Y_Name & " >= " & Height_Name & ") { " &
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
               Line ("long " & Guard_Name & " = 0;");
               Line ("while (alb_truthy(" & Expr (Node.Left_Child) & ")) {");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " += 1; if (" & Guard_Name & " > 500000) { break; }");
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
               Step_Name  : constant String := Next_Temp_Name ("for_step");
               End_Name   : constant String := Next_Temp_Name ("for_end");
               Loop_Local : constant String := Next_Temp_Name ("for_" & Safe_C3_Name (Var_Name));
               Use_Gscal  : Boolean := False;
               Iter_Get   : Unbounded_String := U ("");
            begin
               Raw_Name := U (Var_Name);
               --  Mirror ALBO: new locals get a C3 var; existing globals are
               --  advanced via gscal so bodies reading tip/i see each index
               --  (star tips were stuck at tip=0 → only two segments).
               if Find_Symbol (To_String (Current_Routine), To_String (Raw_Name)) = 0
                 and then Find_Symbol ("", Scoped_Name (To_String (Raw_Name))) = 0
               then
                  if Length (Current_Routine) > 0 then
                     Register_Symbol
                       (To_String (Current_Routine), To_String (Raw_Name),
                        Loop_Local, VK_Number, Sym_Scalar);
                     Line ("long " & Loop_Local & " = 0;");
                     Var_Sym := Resolve_Symbol (Var_Name);
                  else
                     Register_Symbol
                       ("", Scoped_Name (To_String (Raw_Name)),
                        Scoped_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar,
                        Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (VK_Number)));
                     Var_Sym := Resolve_Symbol (Var_Name);
                  end if;
               end if;

               Use_Gscal := Var_Sym.Active and then Is_Global_Storage_Sym (Var_Sym)
                 and then Var_Sym.Kind in Sym_Scalar | Sym_Const | Sym_Temporal;
               if Use_Gscal then
                  Iter_Get := U (Global_Scalar_Get (To_String (Var_Sym.C3_Name), Var_Sym.Tag));
               else
                  Iter_Get := U (Resolve_Var_Name (Var_Name));
               end if;

               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("long " & Step_Name & " = alb_i64(" & Step_Expr & ");");
               Line ("long " & End_Name & " = alb_i64(" & End_Expr & ");");
               if Use_Gscal then
                  Line (Global_Scalar_Set
                          (To_String (Var_Sym.C3_Name), Var_Sym.Tag,
                           Cast_Expr (Var_Sym.Tag, Start_Expr)) & ";");
               else
                  Line (To_String (Iter_Get) & " = alb_i64(" & Start_Expr & ");");
               end if;
               Line ("while (true) {");
               Indent_Level := Indent_Level + 1;
               Line ("if ((" & Step_Name & " >= 0) ? (" & To_String (Iter_Get) &
                     " <= " & End_Name & ") : (" & To_String (Iter_Get) &
                     " >= " & End_Name & ")) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Node.Right_Child);
               if Use_Gscal then
                  Line (Global_Scalar_Set
                          (To_String (Var_Sym.C3_Name), Var_Sym.Tag,
                           "(" & To_String (Iter_Get) & " + " & Step_Name & ")") & ";");
               else
                  Line (To_String (Iter_Get) & " += " & Step_Name & ";");
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
               Iterator_JS   : constant String := Safe_C3_Name (Iterator_Raw);
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
                  then "alb_gscal_get(" & Escape_C3_String (To_String (Sequence_Sym.C3_Name) & "_active") & ")"
                  elsif Sequence_Sym.Active
                  then "alb_garr_len(" & Escape_C3_String (To_String (Sequence_Sym.C3_Name)) & ")"
                  else "0");
               Seq_Rust      : constant String :=
                 (if Sequence_Sym.Active then To_String (Sequence_Sym.C3_Name)
                  else Expr (Sequence_Node));
            begin
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("long " & Length_Name & " = " & Sequence_Len & ";");
               Line ("long " & Guard_Name & " = 0;");
               Line (Primitive_C3_Type (Tag) & " " & Index_Name & ": i64 = 0;");
               Line ("while " & Index_Name & " < " & Length_Name & " {");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " += 1; if (" & Guard_Name & " > 500000) { break; }");
               Line (Primitive_C3_Type (Tag) & " " & Iterator_JS & ": " & Primitive_C3_Type (Item_Tag) & " = " &
                     Cast_Expr
                       (Item_Tag,
                        Global_Array_Get
                          (Seq_Rust, Item_Tag, "alb_idx(" & Index_Name & ")")) &
                     ";");
               Shadow_Id :=
                 Push_Shadow_Symbol
                   (Scope   => Iterator_Scope,
                    Name    => Iterator_Raw,
                    C3_Name => Iterator_JS,
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
               Line ("long " & Guard_Name & " = 0;");
               Line ("while (true) {");
               Indent_Level := Indent_Level + 1;
               Line (Guard_Name & " += 1; if (" & Guard_Name & " > 500000) { break; }");
               Emit_Block (Node.Left_Child);
               Line ("if (alb_truthy(" & Expr (Node.Right_Child) & ")) { break; }");
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
               Line ("alb_create_window(" &
                     Expr (Title_Node) & ", " &
                     Expr (Tree (Pair_Node).Left_Child) & ", " &
                     Expr (Tree (Pair_Node).Right_Child) & ");");
            end;

         when AST_Set_Fullscreen =>
            Line ("alb_set_fullscreen(alb_truthy(" & Expr (Node.Left_Child) & "));");

         when AST_Set_Resizable =>
            Line ("alb_set_resizable(alb_truthy(" & Expr (Node.Left_Child) & "));");

         when AST_Set_Stretchy =>
            Line ("alb_set_stretchy(alb_truthy(" & Expr (Node.Left_Child) & "));");

         when AST_Tick =>
            Line ("albFrameInterval = alb_max(1, " & Expr (Node.Left_Child) & ");");

         when AST_Color =>
            Line ("alb_color(" & Expr (Node.Left_Child) & ");");

         when AST_Clear =>
            Line ("alb_clear(" & Expr (Node.Left_Child) & ");");

         when AST_Use_Font_Stmt =>
            Line ("alb_set_font(" & Expr (Node.Left_Child) & ");");

         when AST_Apply_Lut_Stmt =>
            declare
               Visual_Node : constant Node_Index := Node.Right_Child;
               With_Node   : constant Node_Index :=
                 (if Visual_Node > 0 and then Tree (Visual_Node).Next_Sibling > 0
                  and then Tree (Tree (Visual_Node).Next_Sibling).Kind = AST_With_Clause
                  then Tree (Visual_Node).Next_Sibling
                  else 0);
            begin
               Line ("alb_static_apply_lut(" &
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

               Line ("alb_static_blit(" &
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
                  " = alb_markov_predict(" &
                  Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Infer_Network_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, False);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Emit_Firewall_Touch (Tree (Node.Right_Child).Next_Sibling, False, True);
            Line ("alb_nn_infer(" & Expr (Node.Left_Child) & ", " &
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
               Line ("alb_nn_train(" & Expr (Node.Left_Child) & ", " &
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
               Line ("const " & Status_Name & " = alb_export_ppm(" &
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
                            "FITS_CUBE is not implemented on ALBC3 yet; running FALLBACK when present");
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
                  Line ("String " & Embed_Name & " = """";");
               end if;

               Line ("{");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Line ("// ALBC3 ini table " & Table_Name);
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
                        Line ("{ key: " & Escape_C3_String (Lower_Key) &
                              ", apply: (value: i64) => { " &
                              Statement_Target_Name (Target_Var) &
                              " = value; } },");
                     end;
                  end if;
                  Entry_Node := Tree (Entry_Node).Next_Sibling;
               end loop;
               Indent_Level := Indent_Level - 1;
               Line ("];");
               Line ("if (alb_ini_bind(" & As_Text_Expr (Path_Node) & ", " & Embed_Name & ", " & Table_Name & ") == 0) {");
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
                            "STREAM_BYPASS is ignored on ALBC3; running FALLBACK when present");
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
                            "SYNTH_BAKE is not implemented on ALBC3 yet; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Mount_Archive_Block =>
            Emit_Warn_Once ("mount-archive-albr",
                            "MOUNT_ARCHIVE is not available on ALBC3; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Network_Sniff_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("alb_sniffer_capture(" & Expr (Node.Left_Child) & ", " &
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
                  Line (Statement_Target_Name (D1) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 0, 6);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 6, 6);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 12, 2);");
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
                  Line (Statement_Target_Name (D1) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 26, 4);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 30, 4);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 23, 1);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 16, 2);");
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
                  Line (Statement_Target_Name (D1) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 34, 2);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 36, 2);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 38, 4);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = alb_buffer_pack_le(" & Expr (Src_Node) & ", 42, 4);");
               end if;
            end;

         when AST_Network_Listen_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("alb_net_listen(" & Expr (Node.Left_Child) & ");");

         when AST_Network_Accept_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line (Statement_Target_Name (Node.Right_Child) &
                  " = alb_net_accept(" & Expr (Node.Left_Child) & ");");

         when AST_Network_Receive_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("alb_net_receive(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Network_Send_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Line ("alb_net_send(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_Network_Close_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("alb_net_close(" & Expr (Node.Left_Child) & ");");

         when AST_Read_Process_Memory_Stmt =>
            declare
               Addr_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Raw  : constant String := Raw_Feature_Atom (Target_Node);
               Target_Sym  : constant Symbol_Record := Resolve_Symbol (Target_Raw);
            begin
               if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field then
                  Line ("alb_process_read_buffer(" & Expr (Node.Left_Child) & ", " &
                        Expr (Addr_Node) & ", " & Statement_Target_Name (Target_Node) & ");");
               else
                  Line (Statement_Target_Name (Target_Node) & " = alb_process_read_scalar(" &
                        Expr (Node.Left_Child) & ", " & Expr (Addr_Node) & ");");
               end if;
            end;

         when AST_Write_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("alb_process_write_scalar(" & Expr (Node.Left_Child) & ", " &
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
               Line ("long __alb_monitor_value = alb_i64(" & Expr (Target_Node) & ");");
               Line ("long __alb_monitor_change = alb_i64(" & Expr (Change_Node) & ");");
               Line ("alb_process_monitor(" & Expr (Node.Left_Child) & ", " &
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
               Line ("alb_process_dump(" & Expr (Node.Left_Child) & ", " &
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
                     " = alb_process_create(" & Expr (Node.Left_Child) & ", " &
                     (if Args_Node > 0 then Expr (Args_Node) else """""") & ");");
            end;

         when AST_Elevate_Privileges_Stmt =>
            Line ("alb_process_elevate(" & Expr (Node.Left_Child) & ");");

         when AST_Hack_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("alb_process_write_scalar(" & Expr (Node.Left_Child) & ", " &
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
            Line ("alb_process_sniff(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Encrypt_File_Stmt | AST_Decrypt_File_Stmt =>
            declare
               Key_Node  : constant Node_Index := Node.Right_Child;
               Path_Node : constant Node_Index := (if Key_Node > 0 then Tree (Key_Node).Next_Sibling else 0);
            begin
               Line ("alb_file_xor(" & Expr (Node.Left_Child) & ", " &
                     Expr (Key_Node) & ", " & Expr (Path_Node) & ");");
            end;

         when AST_Print_Stmt =>
            if Node.Left_Child > 0 then
               Line ("alb_print(" & As_Text_Expr (Node.Left_Child) & ");");
            else
               Line ("alb_print("""");");
            end if;

         when AST_Locate_Stmt =>
            Line ("alb_locate(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_Print_Str_Stmt =>
            if Node.Left_Child > 0 then
               Line ("alb_print_raw(" & As_Text_Expr (Node.Left_Child) & ");");
            else
               Line ("alb_print_raw("""");");
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
                     Line ("alb_draw_text(" & To_String (Args (1)) & ", " &
                           To_String (Args (2)) & ", " & To_String (Args (3)) & ");");
                  end if;
               elsif Node.Kind = AST_Plot then
                  if Count >= 2 then
                     Line ("alb_plot(" & To_String (Args (1)) & ", " & To_String (Args (2)) & ");");
                  end if;
               else
                  case Tokens (Node.Token_Index).Kind is
                     when Tok_Rect =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("alb_draw_rect");
                        else
                           Call_Name := U ("alb_fill_rect");
                        end if;
                     when Tok_Line =>
                        Call_Name := U ("alb_draw_line");
                     when Tok_Circle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("alb_draw_circle");
                        else
                           Call_Name := U ("alb_fill_circle");
                        end if;
                     when Tok_Triangle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("alb_draw_triangle");
                        else
                           Call_Name := U ("alb_fill_triangle");
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
            Line ("alb_msg_box(" & Expr (Node.Left_Child) &
                  (if Node.Right_Child > 0 then ", " & Expr (Node.Right_Child) else "") &
                  ");");

         when AST_Listen =>
            Saw_Listen := True;

         when AST_Cease =>
            Line ("alb_cease();");

         when AST_Play_Sound =>
            Line ("alb_play_sound(" & Expr (Node.Left_Child) & ");");

         when AST_Play_Music =>
            Line ("alb_play_music(" & Expr (Node.Left_Child) & ");");

         when AST_Play_Music_From =>
            Line ("void alb_play_music_from(" & Expr (Node.Left_Child) & ");");

         when AST_Input_Stmt =>
            Line (Statement_Target_Name (Node.Right_Child) & " = alb_prompt_text(" &
                  (if Node.Left_Child > 0 then Expr (Node.Left_Child) else """""") &
                  ");");

         when AST_Readline_Stmt =>
            if Node.Left_Child > 0 then
               Line (Statement_Target_Name (Node.Left_Child) &
                     " = alb_readline_text();");
            else
               Line ("alb_readline_text();");
            end if;

         when AST_File_Open =>
            Line ("/* file open expression should be used in LET/assignment context */");

         when AST_File_Close =>
            Line ("alb_close(" & Expr (Node.Left_Child) & ");");

         when AST_File_Write =>
            Line ("alb_write(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Load_Stmt =>
            declare
               Target_Sym : constant Symbol_Record := Target_Symbol (Node.Right_Child);
            begin
               if Target_Sym.Active
                 and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
               then
                  Line ("alb_loadbuffer(" & Expr (Node.Left_Child) & ", " &
                        Statement_Target_Name (Node.Right_Child) & ");");
               else
                  Line (Statement_Target_Name (Node.Right_Child) & " = alb_loadtextbuffer(" &
                        Expr (Node.Left_Child) & ");");
               end if;
            end;

         when AST_Flush_Stmt =>
            if Tree (Node.Left_Child).Next_Sibling > 0 then
               Line ("alb_flushbuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ", " &
                     Expr (Tree (Node.Left_Child).Next_Sibling) & ");");
            else
               Line ("alb_flushbuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ");");
            end if;

         when AST_Poke_Stmt =>
            Line ("alb_poke(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Save_State =>
            Line ("alb_save_state();");

         when AST_Load_State =>
            Line ("alb_load_state();");

         when AST_Claim_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = alb_claim();");

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
               Line ("alb_bind(" & To_String (Args) & ");");
            end;

         when AST_Drop_Stmt =>
            Line ("alb_drop(" & Expr (Node.Left_Child) & ");");

         when AST_Sweep_Stmt =>
            Line ("alb_sweep(" & Expr (Node.Left_Child) & ");");

         when AST_Knows_Fact =>
            Line ("alb_knows_set(" &
                  Escape_C3_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                  ", " & Expr (Node.Right_Child) & ");");

         when AST_Assert_Stmt =>
            Line
              ("alb_rel_set(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0, 1);");

         when AST_Retract_Stmt =>
            Line
              ("alb_rel_retract(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0);");

         when AST_Update_Stmt =>
            Line ("alb_rel_set(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Predicate_Arity_Expr (Node.Left_Child) & ", " &
                  Predicate_Arg1_Expr (Node.Left_Child) &
                  ", 0, 0, 0, " & Expr (Node.Right_Child) & ");");

         when AST_Findall_Query =>
            Line ("alb_rel_findall1(" &
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
                     Line ("{ long __adv = 0; while (__adv < (" & Count_Expr & ")) {");
                     Indent_Level := Indent_Level + 1;
                     Line ("alb_gscal_set(" & Escape_C3_String (To_String (Symbols (I).C3_Name) & "_head") &
                           ", (alb_gscal_get(" & Escape_C3_String (To_String (Symbols (I).C3_Name) & "_head") &
                           ") + 1) % " & Trim_Image (Symbols (I).History_Size) & ");");
                     Line ("ulong __hix = alb_idx(alb_gscal_get(" &
                           Escape_C3_String (To_String (Symbols (I).C3_Name) & "_head") & "));");
                     Line (Global_Array_Set
                             (To_String (Symbols (I).C3_Name) & "_history",
                              Symbols (I).Tag,
                              "__hix",
                              Global_Scalar_Get
                                (To_String (Symbols (I).C3_Name), Symbols (I).Tag)) & ";");
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
                  Line ("alb_set_alpha(" & A1 & ", " & To_String (A2) & ");");
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
               Line ("alb_set_clip(" & To_String (A1) & ", " & To_String (A2) & ", " & To_String (A3) & ", " & To_String (A4) & ");");
            end;

         when AST_Set_Origin =>
            declare
               Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
               A1, A2 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); end if;
               Line ("alb_set_origin(" & To_String (A1) & ", " & To_String (A2) & ");");
            end;

         when AST_Delay_Stmt =>
            Line ("alb_delay(" & Expr (Node.Left_Child) & ");");

         when AST_Try_Stmt =>
            Line ("// ALBC3 try-begin"); Line ("{");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            if Node.Right_Child > 0 then
               Line ("} // ALBC3 catch-begin"); Line ("{");
               Indent_Level := Indent_Level + 1;
               declare
                  Catch_Name : constant String :=
                    (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
                  Catch_JS   : constant String := Safe_C3_Name (Catch_Name);
                  Catch_Id   : Natural := 0;
               begin
                  if Catch_Name'Length > 0 then
                     Line ("const " & Catch_JS &
                           " = alb_text(0); // ALBC3 catch message");
                     Catch_Id :=
                       Push_Shadow_Symbol
                         (Scope   => To_String (Current_Routine),
                          Name    => Catch_Name,
                          C3_Name => Catch_JS,
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
            Line ("alb_fatal(" &
                  Cast_Expr (VK_String, Expr (Node.Left_Child),
                             Infer_Expr_Kind (Node.Left_Child)) &
                  ");");

         when AST_Runtime_Assert =>
            Line ("if (!alb_truthy(" & Expr (Node.Left_Child) &
                  ")) { alb_fatal(""runtime assert failed""); }");

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
         Stmt_First := Statement_List_First (Root_Index);
         Listen_Idx := Find_Listen_Stmt (Stmt_First);

         --  C3 forbids nested fns, so module storage must be registered BEFORE
         --  procedure bodies are emitted (otherwise indexed assigns collapse to
         --  bare names). Struct/type decls stay at module scope; array/scalar
         --  inits go into alb_init_globals() which main() calls first.
         declare
            procedure Emit_Type_Decls (Index : Node_Index) is
               Curr : Node_Index := Index;
            begin
               while Curr > 0 loop
                  case Tree (Curr).Kind is
                     when AST_Struct_Decl =>
                        Emit_Node (Curr);
                     when AST_Module =>
                        declare
                           Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                           Body_Node : constant Node_Index := Tree (Curr).Right_Child;
                           Saved     : constant Unbounded_String := Current_Module;
                           Inner     : Node_Index := 0;
                        begin
                           if Name_Node > 0 then
                              Current_Module :=
                                U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                           end if;
                           if Body_Node > 0 then
                              if Tree (Body_Node).Kind = AST_Block_Stmt then
                                 Inner := Tree (Body_Node).Left_Child;
                              else
                                 Inner := Body_Node;
                              end if;
                              Emit_Type_Decls (Inner);
                           end if;
                           Current_Module := Saved;
                        end;
                     when AST_Program | AST_Block_Stmt =>
                        if Tree (Curr).Left_Child > 0 then
                           Emit_Type_Decls (Tree (Curr).Left_Child);
                        end if;
                     when AST_Procedure_Decl | AST_Function_Decl | AST_On_Block =>
                        null;
                     when others =>
                        null;
                  end case;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            end Emit_Type_Decls;

            procedure Emit_Storage_Decls (Index : Node_Index) is
               Curr : Node_Index := Index;
            begin
               while Curr > 0 loop
                  case Tree (Curr).Kind is
                     when AST_Strict_Stmt | AST_Slide_Stmt | AST_Parallel_Decl |
                          AST_Temporal_Decl | AST_Let_Stmt | AST_Const_Decl |
                          AST_Enum_Decl =>
                        Emit_Node (Curr);
                     when AST_Module =>
                        declare
                           Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                           Body_Node : constant Node_Index := Tree (Curr).Right_Child;
                           Saved     : constant Unbounded_String := Current_Module;
                           Inner     : Node_Index := 0;
                        begin
                           if Name_Node > 0 then
                              Current_Module :=
                                U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                           end if;
                           if Body_Node > 0 then
                              if Tree (Body_Node).Kind = AST_Block_Stmt then
                                 Inner := Tree (Body_Node).Left_Child;
                              else
                                 Inner := Body_Node;
                              end if;
                              Emit_Storage_Decls (Inner);
                           end if;
                           Current_Module := Saved;
                        end;
                     when AST_Program | AST_Block_Stmt =>
                        if Tree (Curr).Left_Child > 0 then
                           Emit_Storage_Decls (Tree (Curr).Left_Child);
                        end if;
                     when AST_Procedure_Decl | AST_Function_Decl | AST_On_Block =>
                        null;
                     when others =>
                        null;
                  end case;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            end Emit_Storage_Decls;

            procedure Emit_Scoped_Routines (Index : Node_Index) is
               Curr : Node_Index := Index;
            begin
               while Curr > 0 loop
                  case Tree (Curr).Kind is
                     when AST_Procedure_Decl | AST_Function_Decl =>
                        Emit_Node (Curr);
                     when AST_Module =>
                        declare
                           Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                           Body_Node : constant Node_Index := Tree (Curr).Right_Child;
                           Saved     : constant Unbounded_String := Current_Module;
                           Inner     : Node_Index := 0;
                        begin
                           if Name_Node > 0 then
                              Current_Module :=
                                U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                           end if;
                           if Body_Node > 0 then
                              if Tree (Body_Node).Kind = AST_Block_Stmt then
                                 Inner := Tree (Body_Node).Left_Child;
                              else
                                 Inner := Body_Node;
                              end if;
                              Emit_Scoped_Routines (Inner);
                           end if;
                           Current_Module := Saved;
                        end;
                     when AST_Program | AST_Block_Stmt =>
                        if Tree (Curr).Left_Child > 0 then
                           Emit_Scoped_Routines (Tree (Curr).Left_Child);
                        end if;
                     when others =>
                        null;
                  end case;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            end Emit_Scoped_Routines;
         begin
            Current_Module := U ("");
            Emit_Type_Decls (Stmt_First);

            --  DLL/foreign stubs must exist before alb_init_globals() — LET
            --  initializers often call gfx_* / nuklear_* / openblas_*.
            Current_Module := U ("");
            declare
               procedure Emit_Import_Stubs (Index : Node_Index) is
                  Curr : Node_Index := Index;
               begin
                  while Curr > 0 loop
                     case Tree (Curr).Kind is
                        when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib |
                             AST_Import_Jar | AST_Import_ES | AST_Import_WASM =>
                           Emit_Node (Curr);
                        when AST_Module =>
                           declare
                              Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                              Body_Node : constant Node_Index := Tree (Curr).Right_Child;
                              Saved     : constant Unbounded_String := Current_Module;
                              Inner     : Node_Index := 0;
                           begin
                              if Name_Node > 0 then
                                 Current_Module :=
                                   U (Safe_C3_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                              end if;
                              if Body_Node > 0 then
                                 if Tree (Body_Node).Kind = AST_Block_Stmt then
                                    Inner := Tree (Body_Node).Left_Child;
                                 else
                                    Inner := Body_Node;
                                 end if;
                                 Emit_Import_Stubs (Inner);
                              end if;
                              Current_Module := Saved;
                           end;
                        when AST_Program | AST_Block_Stmt =>
                           if Tree (Curr).Left_Child > 0 then
                              Emit_Import_Stubs (Tree (Curr).Left_Child);
                           end if;
                        when others =>
                           null;
                     end case;
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end Emit_Import_Stubs;
            begin
               Emit_Import_Stubs (Stmt_First);
            end;

            New_Line_Emit;
            Line ("fn void alb_init_globals()");
            Line ("{");
            Indent_Level := Indent_Level + 1;
            Current_Module := U ("");
            Current_Routine := U ("");
            Emit_Storage_Decls (Stmt_First);
            Indent_Level := Indent_Level - 1;
            Line ("}");
            New_Line_Emit;

            Current_Module := U ("");
            Emit_Scoped_Routines (Stmt_First);
         end;
         Collect_Event_Blocks (Stmt_First, Listen_Idx);
      elsif Root.Kind /= AST_Null then
         Line ("// ALBC3 warning: could not recover top-level root index for " &
               Node_Kind'Image (Root.Kind));
      end if;

      Emit_Address_Routines;
      Emit_State_Routines;
      Emit_Logic_Setup;
      --  Event handlers emitted inside main() after INCLUDE module procs so
      --  nested module procs are in scope.
      Emit_Module_Exports;
      Emit_Foreign_Loaders;

      New_Line_Emit;
      Line ("fn void alb_programshutdown()");
      Line ("{");
      Indent_Level := Indent_Level + 1;
      Line ("if (albShutdownDone) return;");
      Line ("albShutdownDone = true;");
      Line ("albRunning = false;");
      if Listen_Idx > 0 then
         Emit_Top_Level_Range (Tree (Listen_Idx).Next_Sibling, 0);
      end if;
      Line ("alb_sdl_shutdown();");
      Indent_Level := Indent_Level - 1;
      Line ("}");

      --  Event handlers at module scope (before main). Assignment of function
      --  pointers happens immediately after each handler definition.
      Emit_Event_Handler ("alb_on_tick", Tick_Blocks, Tick_Block_Count);
      Emit_Event_Handler ("alb_on_paint", Paint_Blocks, Paint_Block_Count);
      Emit_Event_Handler ("alb_on_key", Key_Blocks, Key_Block_Count);

      New_Line_Emit;
      Line ("fn void main()");
      Line ("{");
      Indent_Level := Indent_Level + 1;
      Line ("alb_init_globals();");
      if Root_Index > 0 and then Stmt_First > 0 then
         declare
            function Is_Hoisted (K : Node_Kind) return Boolean is
            begin
               return K = AST_Procedure_Decl
                 or else K = AST_Function_Decl
                 or else K = AST_Import_DLL
                 or else K = AST_Import_SO
                 or else K = AST_Import_Dylib
                 or else K = AST_Import_Jar
                 or else K = AST_Import_ES
                 or else K = AST_Import_WASM
                 or else K = AST_Strict_Stmt
                 or else K = AST_Slide_Stmt
                 or else K = AST_Parallel_Decl
                 or else K = AST_Temporal_Decl
                 or else K = AST_Let_Stmt
                 or else K = AST_Const_Decl
                 or else K = AST_Enum_Decl
                 or else K = AST_Struct_Decl;
            end Is_Hoisted;

            procedure Emit_Executable (Index : Node_Index) is
               Curr : Node_Index := Index;
            begin
               while Curr > 0 loop
                  exit when Listen_Idx /= 0 and then Curr = Listen_Idx;
                  if Tree (Curr).Kind = AST_Module then
                     Emit_Node (Curr);  --  Module handler already skips hoisted kinds
                  elsif Tree (Curr).Kind = AST_Program
                    or else Tree (Curr).Kind = AST_Block_Stmt
                  then
                     if Tree (Curr).Left_Child > 0 then
                        Emit_Executable (Tree (Curr).Left_Child);
                     end if;
                  elsif not Is_Hoisted (Tree (Curr).Kind) then
                     Emit_Node (Curr);
                  end if;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
            end Emit_Executable;
         begin
            Emit_Executable (Stmt_First);
         end;
      end if;
      if Tick_Block_Count > 0 then
         Line ("alb_on_tick = &alb_on_tick_handler;");
      end if;
      if Paint_Block_Count > 0 then
         Line ("alb_on_paint = &alb_on_paint_handler;");
      end if;
      if Key_Block_Count > 0 then
         Line ("alb_on_key = &alb_on_key_handler;");
      end if;
      if Saw_Create or else Saw_Listen or else Tick_Block_Count > 0
        or else Paint_Block_Count > 0 or else Key_Block_Count > 0
      then
         Line ("alb_prepare_frame();");
         Line ("alb_runframe_loop();");
      elsif Need_Wasm_Loaders then
         Line ("// WASM loaders stubbed on ALBC3");
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

end Emit_Native_C3;
