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

package body Emit_Native_Haskell is

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
   --  (+ optional EXPORT_WASM) faÃƒÂ§ades fit in one web library weave.
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
      HS_Name   : Unbounded_String := To_Unbounded_String ("");
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
      HS_Name      : Unbounded_String := To_Unbounded_String ("");
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
      HS_Field     : Unbounded_String := To_Unbounded_String ("");
      Type_Name    : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
      Offset_Bytes : Integer := 0;
      Bit_Width    : Integer := 0;
      Bit_Shift    : Integer := 0;
   end record;

   type Routine_Record is record
      Active      : Boolean := False;
      Name        : Unbounded_String := To_Unbounded_String ("");
      HS_Name     : Unbounded_String := To_Unbounded_String ("");
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
   Current_Emitting_Function : Boolean := False;
   Current_Routine_Out_Count : Natural := 0;
   Current_Routine_Out_Names : array (1 .. Max_Params) of Unbounded_String :=
     (others => To_Unbounded_String (""));
   Saw_Create      : Boolean := False;
   Saw_Listen      : Boolean := False;
   No_Console_Overlay : Boolean := False;
   --  Phase_Decls: top-level mkRef / function / procedure / array decls only.
   --  Phase_Boot:  executable IO for albBoot (CREATE, CALL, loops, assigns...).
   --  Phase_All:   unrestricted (bodies, event handlers).
   type Emit_Phase_Kind is (Phase_Decls, Phase_Boot, Phase_All);
   Emit_Phase : Emit_Phase_Kind := Phase_All;
   Need_Firewall_Runtime : Boolean := False;
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
   function Escape_HS_String (Text : String) return String;
   function Resolve_Symbol (Raw : String) return Symbol_Record;
   function Target_Symbol (Target_Node : Node_Index) return Symbol_Record;
   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String;

   function Safe_HS_Name (Name : String) return String is
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
        Upper = "AS" or else
        Upper = "CASE" or else
        Upper = "CLASS" or else
        Upper = "DATA" or else
        Upper = "DEFAULT" or else
        Upper = "DERIVING" or else
        Upper = "DO" or else
        Upper = "ELSE" or else
        Upper = "HIDING" or else
        Upper = "IF" or else
        Upper = "IMPORT" or else
        Upper = "IN" or else
        Upper = "INFIX" or else
        Upper = "INFIXL" or else
        Upper = "INFIXR" or else
        Upper = "INSTANCE" or else
        Upper = "LET" or else
        Upper = "MODULE" or else
        Upper = "NEWTYPE" or else
        Upper = "OF" or else
        Upper = "QUALIFIED" or else
        Upper = "THEN" or else
        Upper = "TYPE" or else
        Upper = "WHERE" or else
        Upper = "FOREIGN" or else
        Upper = "FORALL" or else
        Upper = "MDO" or else
        Upper = "REC" or else
        Upper = "PROC" or else
        Upper = "TRUE" or else
        Upper = "FALSE";

      if Needs_Prefix then
         Result := To_Unbounded_String ("alb_" & To_String (Result));
      end if;

      declare
         S : constant String := To_String (Result);
      begin
         if S'Length > 0 and then S (S'First) in 'A' .. 'Z' then
            return Character'Val (Character'Pos (S (S'First)) + 32) &
                   S (S'First + 1 .. S'Last);
         end if;
         return S;
      end;
   end Safe_HS_Name;

   function Scoped_Name (Name : String) return String is
   begin
      if Length (Current_Module) = 0 then
         return Safe_HS_Name (Name);
      else
         return Safe_HS_Name (To_String (Current_Module) & "_" & Name);
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
      return "__alb_" & Safe_HS_Name (Prefix) & "_" & Trim_Image (Integer (Temp_Name_Counter));
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
      Emit_Phase := Phase_All;
      Need_Firewall_Runtime := False;
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

   function Primitive_HS_Type (Kind : Value_Kind) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "Bool";
         when VK_String | VK_Binary =>
            return "String";
         when VK_U128 =>
            return "Integer";
         when VK_F64 =>
            return "Double";
         when others =>
            return "Integer";
      end case;
   end Primitive_HS_Type;

   function Default_Value
     (Kind        : Value_Kind;
      Struct_Name : String := "") return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "False";
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
                  return "alb_struct_" & Safe_HS_Name (Struct_Name);
               else
                  return "alb_empty_struct";
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
         return "[Integer]";
      elsif Kind = VK_Struct then
         return Safe_HS_Name (Name);
      else
         return Primitive_HS_Type (Kind);
      end if;
   end Type_Annotation_From_Name;

   function Cast_Expr (Kind : Value_Kind; Expr : String) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "albBool (albTruthy (" & Expr & "))";
         when VK_String | VK_Binary =>
            return "albText (" & Expr & ")";
         when VK_U8 =>
            return "albU8 (" & Expr & ")";
         when VK_U16 =>
            return "albU16 (" & Expr & ")";
         when VK_S8 =>
            return "albI8 (" & Expr & ")";
         when VK_S16 =>
            return "albI16 (" & Expr & ")";
         when VK_U32 =>
            return "albU32 (" & Expr & ")";
         when VK_U64 =>
            return "albU32 (" & Expr & ")";
         when VK_S32 | VK_HW8 | VK_HW16 | VK_HW32 =>
            return "albI32 (" & Expr & ")";
         when VK_F64 | VK_Number | VK_Pure | VK_Unknown =>
            return "albNum (" & Expr & ")";
         when VK_U128 =>
            return "albNum (" & Expr & ")";
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
   begin
      case Kind is
         when VK_U8 | VK_Boolean =>
            return "ALBMap";
         when VK_S8 | VK_HW8 =>
            return "ALBMap";
         when VK_U16 =>
            return "ALBMap";
         when VK_S16 | VK_HW16 =>
            return "ALBMap";
         when VK_U32 | VK_U64 =>
            return "ALBMap";
         when VK_F64 | VK_Pure =>
            return "ALBMap";
         when others =>
            return "ALBMap";
      end case;
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
         return "((" & Base_Expr & "." & To_String (Fields (Field_Id).HS_Field) &
           " >>> " & Trim_Image (Fields (Field_Id).Bit_Shift) & ") & " &
           Trim_Image (Mask) & ")";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).HS_Field);
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
         return Base_Expr & "." & To_String (Fields (Field_Id).HS_Field) &
           " = ((" & Base_Expr & "." & To_String (Fields (Field_Id).HS_Field) &
           " & ~(" & Trim_Image (Mask) & " << " & Trim_Image (Fields (Field_Id).Bit_Shift) &
           ")) | ((albNum (" & Value_Expr & ") & " & Trim_Image (Mask) & ") << " &
           Trim_Image (Fields (Field_Id).Bit_Shift) & "))";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).HS_Field) &
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

   function Find_Routine (HS_Name : String) return Natural is
   begin
      for I in 1 .. Routine_Count loop
         if Routines (I).Active and then To_String (Routines (I).HS_Name) = HS_Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Routine;

   procedure Register_Symbol
     (Scope        : String;
      Name         : String;
      HS_Name      : String;
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
         Symbols (Symbol_Count).HS_Name := U (HS_Name);
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
      HS_Name     : String;
      Param_Count : Natural;
      Param_Modes : Param_Mode_List) is
      Existing : constant Natural := Find_Routine (HS_Name);
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
         Routines (Routine_Count).HS_Name := U (HS_Name);
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
      HS_Name : String;
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
      Symbols (Symbol_Count).HS_Name := U (HS_Name);
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

      function Wrap (Name : String; Kind : Symbol_Kind) return String is
      begin
         if Kind = Sym_Param then
            return Name;
         end if;
         return "(albGet " & Name & ")";
      end Wrap;
   begin
      if Length (Current_Routine) > 0 then
         Idx := Find_Symbol (To_String (Current_Routine), Raw);
         if Idx /= 0 then
            return Wrap (To_String (Symbols (Idx).HS_Name), Symbols (Idx).Kind);
         end if;
      end if;

      Idx := Find_Symbol ("", Scoped);
      if Idx /= 0 then
         return Wrap (To_String (Symbols (Idx).HS_Name), Symbols (Idx).Kind);
      end if;

      Idx := Find_Symbol ("", Safe_HS_Name (Raw));
      if Idx /= 0 then
         return Wrap (To_String (Symbols (Idx).HS_Name), Symbols (Idx).Kind);
      end if;

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return Wrap (To_String (Symbols (Idx).HS_Name), Symbols (Idx).Kind);
      end if;

      return Wrap (Safe_HS_Name (Raw), Sym_Scalar);
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
      Scoped_HS : constant String := Scoped_Name (Raw);
      Plain_HS  : constant String := Safe_HS_Name (Raw);
   begin
      if Find_Routine (Scoped_HS) /= 0 then
         return Scoped_HS;
      elsif Find_Routine (Plain_HS) /= 0 then
         return Plain_HS;
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
               Append (Args, " ");
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
               return Safe_HS_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
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
           and then To_String (Routines (I).HS_Name) = Target_Name
         then
            return I;
         end if;
      end loop;

      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then Ada.Strings.Fixed.Index (Target_Name, To_String (Routines (I).HS_Name)) > 0
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
               Append (Args, " ");
            end if;
            if Routine_Id > 0
              and then Param_No <= Routines (Routine_Id).Param_Count
              and then Routines (Routine_Id).Param_Modes (Param_No) = Param_Out
            then
               Args := Args & ("__out_" & Out_Arg_Name (Curr));
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
         declare
            Args_Joined : constant String := Join_Arg_List (Arg_List);
         begin
            if Args_Joined'Length = 0 then
               return Target_Name;
            else
               return Target_Name & " " & Args_Joined;
            end if;
         end;
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
         declare
            Args_Joined : constant String := Join_Arg_List (Arg_List);
         begin
            if Args_Joined'Length = 0 then
               return Target_Name;
            else
               return Target_Name & " " & Args_Joined;
            end if;
         end;
   end Emit_Call_Expr_With_Out;

   function Predicate_Key_Expr (Pred_Node : Node_Index) return String is
      Node : constant AST_Node := Tree (Pred_Node);
   begin
      if Pred_Node = 0 then
         return Escape_HS_String ("");
      end if;

      case Node.Kind is
         when AST_Assert_Stmt | AST_Retract_Stmt =>
            return "alb_PRED(" &
              Escape_HS_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Expr (Node.Left_Child) else "") &
              ")";
         when AST_Predicate =>
            return "alb_PRED(" &
              Escape_HS_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Join_Arg_List (Node.Left_Child) else "") &
              ")";
         when AST_Func_Call =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               return "alb_PRED(" &
                 Escape_HS_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                 (if Node.Right_Child > 0 then ", " & Join_Arg_List (Node.Right_Child) else "") &
                 ")";
            end if;
            return Expr (Pred_Node);
         when AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            return Escape_HS_String (Raw_Lexeme (Node.Token_Index));
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
               Name : constant String := Safe_HS_Name (T (T'First + 1 .. T'Last));
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

   function Escape_HS_String (Text : String) return String is
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
   end Escape_HS_String;

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

   function HSImport_Specifier (Raw_Path : String) return String is
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
         return "./" & Safe_HS_Name (Trimmed);
   end HSImport_Specifier;

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
      HS_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "alb_User_GetTickCount"
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
      Foreign_Imports (Foreign_Import_Count).HS_Name := U (HS_Name);
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
      HS_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "alb_User_GetTickCount"
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
      Foreign_Exports (Foreign_Export_Count).HS_Name := U (HS_Name);
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
                     Current_Module := U (Safe_HS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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
                     Current_Module := U (Safe_HS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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

            when AST_Memory_Firewall_Decl | AST_Network_Socket_Decl |
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

      return Safe_HS_Name (Raw_Lexeme (Tree (Left_Node).Token_Index) & "_" &
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
      Field_Id : constant Natural := Find_Field (Struct_Name, Safe_HS_Name (Field_Name));
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
      if Node_Index_Value > 0 then
         declare
            Node : constant AST_Node := Tree (Node_Index_Value);
         begin
            --  String literals and pipe/& concat already produce String; do not
            --  re-wrap with albText (show) or HUD gets Haskell quotes/escapes.
            if Node.Kind = AST_String_Expr then
               return Expr (Node_Index_Value);
            elsif Node.Kind = AST_BinOp
              and then Node.Token_Index > 0
              and then Tokens (Node.Token_Index).Kind in Tok_Pipe | Tok_Ampersand
            then
               return Expr (Node_Index_Value);
            end if;
         end;
      end if;
      return "(albText (" & Expr (Node_Index_Value) & "))";
   end As_Text_Expr;


   function Feature_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      if Node_Index_Value = 0 then
         return Escape_HS_String ("");
      elsif Tree (Node_Index_Value).Kind = AST_String_Expr then
         return Expr (Node_Index_Value);
      elsif Tree (Node_Index_Value).Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
         return Escape_HS_String (Raw_Feature_Atom (Node_Index_Value));
      else
         return As_Text_Expr (Node_Index_Value);
      end if;
   end Feature_Text_Expr;

   procedure Emit_Warn_Once
     (Key     : String;
      Message : String) is
   begin
      Line ("alb_WARN_ONCE " & Escape_HS_String (Key) & " " &
            Escape_HS_String (Message));
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
      Plain_HS     : constant String := Safe_HS_Name (Raw_Name);
      Scoped_HS    : constant String := Scoped_Name (Raw_Name);
   begin
      if Routine_Name'Length > 0 then
         if Find_Symbol (Routine_Name, Raw_Name) = 0 then
            Register_Symbol (Routine_Name, Raw_Name, Plain_HS, Tag, Sym_Scalar);
            Line (Plain_HS & " :: IORef " & Primitive_HS_Type (Tag));
            Line (Plain_HS & " = mkRef (" & Default_Value (Tag) & ")");
            Line ("{-# NOINLINE " & Plain_HS & " #-}");
         end if;
      elsif Find_Symbol ("", Scoped_HS) = 0 and then Find_Symbol ("", Raw_Name) = 0 then
         Register_Symbol ("", Scoped_HS, Scoped_HS, Tag, Sym_Scalar);
         Line (Scoped_HS & " :: IORef " & Primitive_HS_Type (Tag));
         Line (Scoped_HS & " = mkRef (" & Default_Value (Tag) & ")");
         Line ("{-# NOINLINE " & Scoped_HS & " #-}");
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
                  return Escape_HS_String (T);
               end if;
            end;
         when AST_True =>
            return "True";
         when AST_False =>
            return "False";
         when AST_Const_Ref =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return Safe_HS_Name (T (T'First + 1 .. T'Last));
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
                     "(albRefArrGet " & To_String (S.HS_Name) & " (" &
                     Build_Array_Index (S.Dims, S.Rank, Node.Left_Child) & "))");
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
                           "(albRefArrGet " & To_String (Symbols (Field_Sym_Id).HS_Name) &
                             " (" &
                             Build_Array_Index
                               (Symbols (Field_Sym_Id).Dims,
                                Symbols (Field_Sym_Id).Rank,
                                Left_Node.Left_Child) &
                             "))");
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
                     "(albRefArrGet " & To_String (Group_Sym.HS_Name) & " (" &
                       Build_Array_Index
                         (Group_Sym.Dims,
                          Group_Sym.Rank,
                          Right_Node.Left_Child) &
                       "))");
               end if;

               if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                  declare
                     Field_Id : constant Natural :=
                       Find_Field (To_String (Left_Sym.Struct_Name), Safe_HS_Name (Right_Name));
                  begin
                     return Wrap_Firewall_Read
                       (Node_Index_Value,
                        Field_Read_Expr (To_String (Left_Sym.HS_Name), Field_Id));
                  end;
               elsif Group_Sym.Active then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Group_Sym.HS_Name));
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
                  when Tok_Pipe | Tok_Ampersand =>
                     return "(" & As_Text_Expr (Node.Left_Child) & " ++ " &
                       As_Text_Expr (Node.Right_Child) & ")";
                  when Tok_Plus =>
                     return "(" & L & " + " & R & ")";
                  when Tok_Minus =>
                     return "(" & L & " - " & R & ")";
                  when Tok_Mul =>
                     return "(" & L & " * " & R & ")";
                  when Tok_Div =>
                     return "(albDiv (" & L & ") (" & R & "))";
                  when Tok_Mod =>
                     return "(albMod (" & L & ") (" & R & "))";
                  when Tok_Pow =>
                     if Uses_Real_Power (Node.Left_Child)
                       or else Uses_Real_Power (Node.Right_Child)
                     then
                        return "((" & L & ") ** (" & R & "))";
                     end if;
                     return "(alb_POW (" & L & ") (" & R & "))";
                  when Tok_Less =>
                     return "(if (" & L & ") < (" & R & ") then 1 else 0)";
                  when Tok_Greater =>
                     return "(if (" & L & ") > (" & R & ") then 1 else 0)";
                  when Tok_Less_Equal =>
                     return "(if (" & L & ") <= (" & R & ") then 1 else 0)";
                  when Tok_Greater_Equal =>
                     return "(if (" & L & ") >= (" & R & ") then 1 else 0)";
                  when Tok_Equal | Tok_Assign =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(if albTruthy (" & R & ") then 1 else 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(if albTruthy (" & L & ") then 1 else 0)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(if albTruthy (" & R & ") then 0 else 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(if albTruthy (" & L & ") then 0 else 1)";
                     end if;
                     return "(if (" & L & ") == (" & R & ") then 1 else 0)";
                  when Tok_Not_Equal =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(if albTruthy (" & R & ") then 0 else 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(if albTruthy (" & L & ") then 0 else 1)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(if albTruthy (" & R & ") then 1 else 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(if albTruthy (" & L & ") then 1 else 0)";
                     end if;
                     return "(if (" & L & ") /= (" & R & ") then 1 else 0)";
                  when Tok_And =>
                     -- ALB AND/OR are bitwise (same as FASM/C/Python). Logical
                     -- short-circuit is ORELSE when implemented. Do not emit JS
                     -- && / || here; that breaks UTF-8, inflate, and JSON masks.
                     return "((" & L & ") .&. (" & R & "))";
                  when Tok_Or =>
                     return "((" & L & ") .|. (" & R & "))";
                  when Tok_Xor =>
                     return "(xor (" & L & ") (" & R & "))";
                  when Tok_Shl =>
                     return "(shiftL (" & L & ") (fromIntegral (" & R & ")))";
                  when Tok_Shr =>
                     return "(shiftR (" & L & ") (fromIntegral (" & R & ")))";
                  when others =>
                     return "(" & L & " + " & R & ")";
               end case;
            end;
         when AST_Unary_Minus =>
            return "(-" & Expr (Node.Left_Child) & ")";
         when AST_Not =>
            return "(if albTruthy (" & Expr (Node.Left_Child) & ") then 0 else 1)";
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
                  return "(albPURE (" &
                    (if A1 > 0 then Expr (A1) else "0") &
                    ") (" &
                    (if A2 > 0 then Expr (A2) else "1") &
                    "))";
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
                        Target_Name := U ("albPURE");
                     elsif To_String (Raw_Upper) = "REAL" then
                        Target_Name := U ("f64");
                     elsif To_String (Raw_Upper) = "GETTICKCOUNT" then
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           Target_Name := U ("alb_GetTickCount");
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
                        if To_String (Raw_Upper) = "PURE"
                          or else To_String (Raw_Upper) = "RATIONAL"
                        then
                           Target_Name := U ("albPURE");
                        elsif To_String (Raw_Upper) = "PURE_NUM" then
                           Target_Name := U ("albPURE_NUM");
                        elsif To_String (Raw_Upper) = "PURE_DEN" then
                           Target_Name := U ("albPURE_DEN");
                        elsif To_String (Raw_Upper) = "PURE_ADD" then
                           Target_Name := U ("albPURE_ADD");
                        elsif To_String (Raw_Upper) = "PURE_SUB" then
                           Target_Name := U ("albPURE_SUB");
                        elsif To_String (Raw_Upper) = "PURE_MUL" then
                           Target_Name := U ("albPURE_MUL");
                        elsif To_String (Raw_Upper) = "PURE_DIV" then
                           Target_Name := U ("albPURE_DIV");
                        elsif To_String (Raw_Upper) = "PURE_POW" then
                           Target_Name := U ("albPURE_POW");
                        elsif To_String (Raw_Upper) = "S32"
                          or else To_String (Raw_Upper) = "I32"
                          or else To_String (Raw_Upper) = "INT32"
                        then
                           Target_Name := U ("albI32");
                        elsif To_String (Raw_Upper) = "U32"
                          or else To_String (Raw_Upper) = "U64"
                        then
                           Target_Name := U ("albU32");
                        elsif To_String (Raw_Upper) = "U8" then
                           Target_Name := U ("albU8");
                        elsif To_String (Raw_Upper) = "U16" then
                           Target_Name := U ("albU16");
                        elsif To_String (Raw_Upper) = "S8"
                          or else To_String (Raw_Upper) = "I8"
                          or else To_String (Raw_Upper) = "INT8"
                        then
                           Target_Name := U ("albI8");
                        elsif To_String (Raw_Upper) = "S16"
                          or else To_String (Raw_Upper) = "I16"
                          or else To_String (Raw_Upper) = "INT16"
                        then
                           Target_Name := U ("albI16");
                        elsif To_String (Raw_Upper) = "F64"
                          or else To_String (Raw_Upper) = "REAL"
                        then
                           Target_Name := U ("albNum");
                        elsif To_String (Raw_Upper) = "RND" then
                           Target_Name := U ("alb_RND");
                        elsif To_String (Raw_Upper) = "SIN" then
                           Target_Name := U ("alb_SIN");
                        elsif To_String (Raw_Upper) = "COS" then
                           Target_Name := U ("alb_COS");
                        elsif To_String (Raw_Upper) = "SQRT" then
                           Target_Name := U ("alb_SQRT");
                        elsif To_String (Raw_Upper) = "EXP" then
                           Target_Name := U ("alb_EXP");
                        elsif To_String (Raw_Upper) = "COLLIDE_RECT" then
                           Target_Name := U ("alb_COLLIDE_RECT");
                        else
                           Target_Name := U ("alb" & To_String (Raw_Upper));
                        end if;
                     else
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           Target_Name := U ("alb_PRED(" &
                             Escape_HS_String (To_String (Raw)) &
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

               if Starts_With (To_String (Target_Name), "alb_PRED(") then
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
                  Args_Joined : constant String :=
                    Join_Arg_List_For_Call (Arg_List, Routine_Id);
                  Call_Text : Unbounded_String := U ("");
               begin
                  if Args_Joined'Length = 0 then
                     Call_Text := Target_Name;
                  else
                     Call_Text := U ("(" & To_String (Target_Name) & " " &
                       Args_Joined & ")");
                  end if;
                  return To_String (Call_Text);
               end;
            end;
         when AST_Key_State =>
            return "(alb_KEY (" & Expr (Node.Left_Child) & "))";
         when AST_Mouse_X =>
            return "(alb_getMouseX ())";
         when AST_Mouse_Y =>
            return "(alb_getMouseY ())";
         when AST_Mouse_Wheel =>
            return "(alb_getMouseWheel ())";
         when AST_Mouse_Click =>
            return "(alb_MOUSE_CLICK (" &
              (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "0") & "))";
         when AST_VMouse_X =>
            return "(alb_getMouseX ())";
         when AST_VMouse_y =>
            return "(alb_getMouseY ())";
         when AST_SCREEN_WIDTH =>
            return "(alb_getScreenWidth ())";
         when AST_SCREEN_HEIGHT =>
            return "(alb_getScreenHeight ())";
         when AST_VIRTUAL_WIDTH =>
            return "(alb_getVirtualWidth ())";
         when AST_VIRTUAL_HEIGHT =>
            return "(alb_getVirtualHeight ())";
         when AST_Peek_Expr =>
            return "(alb_PEEK (" & Expr (Node.Left_Child) & "))";
         when AST_Deref_Expr =>
            return "(alb_DEREF (" & Expr (Node.Left_Child) & "))";
         when AST_AddressOf | AST_Ref_Expr =>
            return Address_Expr_For (Node.Left_Child);
         when AST_Read_Process_Memory_Expr =>
            return "alb_PROCESS_READ_SCALAR(" &
              Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Read_Pixel =>
            return "alb_READ_PIXEL(" & Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Rnd_Expr =>
            return "(alb_RND (" & Expr (Node.Left_Child) & "))";
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
                 (Safe_HS_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)),
                  Raw_Lexeme (Tree (Node.Right_Child).Token_Index));
            else
               return "0";
            end if;
         when AST_TypeOf_Expr =>
            return Escape_HS_String ("number");
         when AST_Temporal_Ref =>
            declare
               Base_Name : constant String := Raw_Lexeme (Tree (Node.Left_Child).Token_Index);
               JS_Base   : constant String := Resolve_Var_Name (Base_Name);
               Sel       : constant Token_Kind := Tokens (Node.Token_Index).Kind;
               TSym      : constant Symbol_Record := Resolve_Symbol (Base_Name);
               Hist      : constant String := Trim_Image (Integer'Max (1, TSym.History_Size));
            begin
               case Sel is
                  when Tok_Now =>
                     return JS_Base;
                  when Tok_Past =>
                     return JS_Base & "_history[(" & JS_Base & "_head + " & Hist & " - 1) % " & Hist & "]";
                  when Tok_Future =>
                     return JS_Base & "_history[(" & JS_Base & "_head + 1) % " & Hist & "]";
                  when Tok_Timeline =>
                     return Trim_Image (TSym.Aux_Offset);
                  when others =>
                     return JS_Base;
               end case;
            end;
         when AST_Find_Query =>
            if Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND" then
               if Node.Left_Child > 0 then
                  return "alb_REL_FIND1(" & Predicate_Id_Expr (Node.Left_Child) & ")";
               else
                  return "0";
               end if;
            else
               return "alb_REL_HAS(" &
                 Predicate_Id_Expr (Node_Index_Value) & ", " &
                 Predicate_Arity_Expr (Node_Index_Value) & ", " &
                 Predicate_Arg1_Expr (Node_Index_Value) &
                 ", 0, 0, 0)";
            end if;
         when AST_Query =>
            if Node.Left_Child > 0 then
               return "alb_REL_HAS(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_Knows_Query =>
            if Node.Left_Child > 0 then
               return "alb_REL_HAS(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_File_Open =>
            return "alb_Open(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Len =>
            return "alb_FileLen(" & Expr (Node.Left_Child) & ")";
         when AST_File_Seek =>
            return "alb_Seek(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Read =>
            return "alb_Read(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Inline_Typescript_Expr =>
            return Raw_Lexeme (Node.Token_Index);
         when others =>
            return "0";
      end case;
   end Expr;

   procedure Emit_Runtime is
   begin
      Line ("{-# LANGUAGE BangPatterns #-}");
      Line ("{-# LANGUAGE ScopedTypeVariables #-}");
      Line ("{-# LANGUAGE ExistentialQuantification #-}");
      Line ("{-# LANGUAGE ForeignFunctionInterface #-}");
      Line ("{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}");
      Line ("module Main where");
      Line ("import Control.Concurrent (threadDelay)");
      Line ("import Control.Exception (Exception, SomeException, catch, throwIO, try, evaluate)");
      Line ("import Control.Monad (forM_, when, unless, void, foldM, join)");
      Line ("import Data.Bits ((.&.), (.|.), xor, shiftL, shiftR, complement)");
      Line ("import Data.Char (chr, ord)");
      Line ("import Data.IORef");
      Line ("import Data.Function (fix)");
      Line ("import Data.List (foldl', sortBy)");
      Line ("import Data.Ord (comparing)");
      Line ("import Data.Word (Word8, Word32, Word64)");
      Line ("import qualified Data.Map.Strict as Map");
      Line ("import Data.Maybe (fromMaybe, isJust)");
      Line ("import Foreign.C.Types");
      Line ("import Foreign.C.String");
      Line ("import Foreign.Ptr");
      Line ("import Foreign.Marshal.Alloc");
      Line ("import Foreign.Marshal.Array");
      Line ("import Foreign.Storable");
      Line ("import System.IO");
      Line ("import System.IO.Unsafe (unsafePerformIO)");
      Line ("import Text.Read (readMaybe)");
      New_Line_Emit;
      Line ("-- Generated by ALBH - AdaLogic BASIC to Haskell (GHC)");
      Line ("-- Imperative ALB mutability via IORef + albGet/albSet (unsafePerformIO globals).");
      New_Line_Emit;
      Line ("type ALBVal = Integer");
      Line ("type ALBMap = Map.Map Int ALBVal");
      Line ("type ALBStrMap = Map.Map String String");
      New_Line_Emit;
      Line ("albEpoch :: IORef Integer");
      Line ("albEpoch = unsafePerformIO (newIORef 0)");
      Line ("{-# NOINLINE albEpoch #-}");
      Line ("albGet :: IORef a -> a");
      Line ("albGet r = unsafePerformIO $ do");
      Line ("  e <- readIORef albEpoch");
      Line ("  v <- readIORef r");
      Line ("  e `seq` return $! v");
      Line ("{-# NOINLINE albGet #-}");
      Line ("albWhile :: IO Bool -> IO () -> IO ()");
      Line ("albWhile cond body = do");
      Line ("  c <- cond");
      Line ("  when c (body >> albWhile cond body)");
      New_Line_Emit;
      Line ("albSet :: IORef a -> a -> IO ()");
      Line ("albSet r v = do");
      Line ("  vv <- evaluate v");
      Line ("  writeIORef r vv");
      Line ("  modifyIORef' albEpoch (+1)");
      New_Line_Emit;
      Line ("albModify :: IORef a -> (a -> a) -> IO ()");
      Line ("albModify = modifyIORef'");
      New_Line_Emit;
      Line ("mkRef :: a -> IORef a");
      Line ("mkRef v = unsafePerformIO (newIORef v)");
      Line ("{-# NOINLINE mkRef #-}");
      New_Line_Emit;
      Line ("albTruthy :: ALBVal -> Bool");
      Line ("albTruthy 0 = False");
      Line ("albTruthy _ = True");
      New_Line_Emit;
      Line ("albBool :: Bool -> ALBVal");
      Line ("albBool True = 1");
      Line ("albBool False = 0");
      New_Line_Emit;
      Line ("albText :: ALBVal -> String");
      Line ("albText = show");
      Line ("alb_Text :: ALBVal -> String");
      Line ("alb_Text = albText");
      New_Line_Emit;
      Line ("albConcat :: String -> String -> String");
      Line ("albConcat = (++)");
      New_Line_Emit;
      Line ("albNum :: (Integral a) => a -> ALBVal");
      Line ("albNum = toInteger");
      New_Line_Emit;
      Line ("alb_empty_struct :: ALBVal");
      Line ("alb_empty_struct = 0");
      New_Line_Emit;
      Line ("-- Global runtime cells (ALB imperative state)");
      Line ("albWarnedKeys :: IORef (Map.Map String Bool)");
      Line ("albWarnedKeys = mkRef Map.empty");
      Line ("{-# NOINLINE albWarnedKeys #-}");
      Line ("albSaveStore :: IORef ALBStrMap");
      Line ("albSaveStore = mkRef Map.empty");
      Line ("{-# NOINLINE albSaveStore #-}");
      Line ("albKeys :: IORef (Map.Map Int Int)");
      Line ("albKeys = mkRef Map.empty");
      Line ("{-# NOINLINE albKeys #-}");
      Line ("albMouseButtons :: IORef (Map.Map Int Int)");
      Line ("albMouseButtons = mkRef Map.empty");
      Line ("{-# NOINLINE albMouseButtons #-}");
      Line ("albVas :: IORef (Map.Map Int ALBVal)");
      Line ("albVas = mkRef Map.empty");
      Line ("{-# NOINLINE albVas #-}");
      Line ("albGcAlive :: IORef (Map.Map Int Int)");
      Line ("albGcAlive = mkRef Map.empty");
      Line ("{-# NOINLINE albGcAlive #-}");
      Line ("albGcRefs :: IORef (Map.Map Int Int)");
      Line ("albGcRefs = mkRef Map.empty");
      Line ("{-# NOINLINE albGcRefs #-}");
      Line ("albGcChildA :: IORef (Map.Map Int Int)");
      Line ("albGcChildA = mkRef Map.empty");
      Line ("{-# NOINLINE albGcChildA #-}");
      Line ("albGcChildB :: IORef (Map.Map Int Int)");
      Line ("albGcChildB = mkRef Map.empty");
      Line ("{-# NOINLINE albGcChildB #-}");
      Line ("albGcChildC :: IORef (Map.Map Int Int)");
      Line ("albGcChildC = mkRef Map.empty");
      Line ("{-# NOINLINE albGcChildC #-}");
      Line ("albGcChildD :: IORef (Map.Map Int Int)");
      Line ("albGcChildD = mkRef Map.empty");
      Line ("{-# NOINLINE albGcChildD #-}");
      Line ("albFactLive :: IORef (Map.Map Int Int)");
      Line ("albFactLive = mkRef Map.empty");
      Line ("{-# NOINLINE albFactLive #-}");
      Line ("albFactKey :: IORef (Map.Map Int String)");
      Line ("albFactKey = mkRef Map.empty");
      Line ("{-# NOINLINE albFactKey #-}");
      Line ("albFactValue :: IORef (Map.Map Int ALBVal)");
      Line ("albFactValue = mkRef Map.empty");
      Line ("{-# NOINLINE albFactValue #-}");
      Line ("albRelLive :: IORef (Map.Map Int Int)");
      Line ("albRelLive = mkRef Map.empty");
      Line ("{-# NOINLINE albRelLive #-}");
      Line ("albRelPred :: IORef (Map.Map Int Int)");
      Line ("albRelPred = mkRef Map.empty");
      Line ("{-# NOINLINE albRelPred #-}");
      Line ("albRelArity :: IORef (Map.Map Int Int)");
      Line ("albRelArity = mkRef Map.empty");
      Line ("{-# NOINLINE albRelArity #-}");
      Line ("albRelArg1 :: IORef (Map.Map Int ALBVal)");
      Line ("albRelArg1 = mkRef Map.empty");
      Line ("{-# NOINLINE albRelArg1 #-}");
      Line ("albRelArg2 :: IORef (Map.Map Int ALBVal)");
      Line ("albRelArg2 = mkRef Map.empty");
      Line ("{-# NOINLINE albRelArg2 #-}");
      Line ("albRelArg3 :: IORef (Map.Map Int ALBVal)");
      Line ("albRelArg3 = mkRef Map.empty");
      Line ("{-# NOINLINE albRelArg3 #-}");
      Line ("albRelArg4 :: IORef (Map.Map Int ALBVal)");
      Line ("albRelArg4 = mkRef Map.empty");
      Line ("{-# NOINLINE albRelArg4 #-}");
      Line ("albRelValue :: IORef (Map.Map Int ALBVal)");
      Line ("albRelValue = mkRef Map.empty");
      Line ("{-# NOINLINE albRelValue #-}");
      Line ("albRuleHeadPred :: IORef (Map.Map Int Int)");
      Line ("albRuleHeadPred = mkRef Map.empty");
      Line ("{-# NOINLINE albRuleHeadPred #-}");
      Line ("albRuleFlags :: IORef (Map.Map Int Int)");
      Line ("albRuleFlags = mkRef Map.empty");
      Line ("{-# NOINLINE albRuleFlags #-}");
      Line ("albRuleBodyLen :: IORef (Map.Map Int Int)");
      Line ("albRuleBodyLen = mkRef Map.empty");
      Line ("{-# NOINLINE albRuleBodyLen #-}");
      Line ("albRuleBodyPred :: IORef (Map.Map Int Int)");
      Line ("albRuleBodyPred = mkRef Map.empty");
      Line ("{-# NOINLINE albRuleBodyPred #-}");
      Line ("albRuleBodyArgMode :: IORef (Map.Map Int Int)");
      Line ("albRuleBodyArgMode = mkRef Map.empty");
      Line ("{-# NOINLINE albRuleBodyArgMode #-}");
      Line ("albRuleBodyArgConst :: IORef (Map.Map Int ALBVal)");
      Line ("albRuleBodyArgConst = mkRef Map.empty");
      Line ("{-# NOINLINE albRuleBodyArgConst #-}");
      Line ("albRuleCount :: IORef Int");
      Line ("albRuleCount = mkRef 0");
      Line ("{-# NOINLINE albRuleCount #-}");
      Line ("albFileLive :: IORef (Map.Map Int Int)");
      Line ("albFileLive = mkRef Map.empty");
      Line ("{-# NOINLINE albFileLive #-}");
      Line ("albFileMode :: IORef (Map.Map Int String)");
      Line ("albFileMode = mkRef Map.empty");
      Line ("{-# NOINLINE albFileMode #-}");
      Line ("albFileName :: IORef (Map.Map Int String)");
      Line ("albFileName = mkRef Map.empty");
      Line ("{-# NOINLINE albFileName #-}");
      Line ("albFileBuffer :: IORef (Map.Map Int String)");
      Line ("albFileBuffer = mkRef Map.empty");
      Line ("{-# NOINLINE albFileBuffer #-}");
      Line ("albFileCursor :: IORef (Map.Map Int Int)");
      Line ("albFileCursor = mkRef Map.empty");
      Line ("{-# NOINLINE albFileCursor #-}");
      Line ("albTextRows :: IORef [String]");
      Line ("albTextRows = mkRef [""""]");
      Line ("{-# NOINLINE albTextRows #-}");
      Line ("albTextCursorX :: IORef Int");
      Line ("albTextCursorX = mkRef 1");
      Line ("{-# NOINLINE albTextCursorX #-}");
      Line ("albTextCursorY :: IORef Int");
      Line ("albTextCursorY = mkRef 1");
      Line ("{-# NOINLINE albTextCursorY #-}");
      Line ("albCurrentColor :: IORef ALBVal");
      Line ("albCurrentColor = mkRef 0xffffffff");
      Line ("{-# NOINLINE albCurrentColor #-}");
      Line ("albColorValue :: IORef ALBVal");
      Line ("albColorValue = mkRef 0xffffffff");
      Line ("{-# NOINLINE albColorValue #-}");
      Line ("albBaseWidth :: IORef Int");
      Line ("albBaseWidth = mkRef 320");
      Line ("{-# NOINLINE albBaseWidth #-}");
      Line ("albBaseHeight :: IORef Int");
      Line ("albBaseHeight = mkRef 200");
      Line ("{-# NOINLINE albBaseHeight #-}");
      Line ("albWindowWidth :: IORef Int");
      Line ("albWindowWidth = mkRef 320");
      Line ("{-# NOINLINE albWindowWidth #-}");
      Line ("albWindowHeight :: IORef Int");
      Line ("albWindowHeight = mkRef 200");
      Line ("{-# NOINLINE albWindowHeight #-}");
      Line ("albVirtualWidth :: IORef Int");
      Line ("albVirtualWidth = mkRef 320");
      Line ("{-# NOINLINE albVirtualWidth #-}");
      Line ("albVirtualHeight :: IORef Int");
      Line ("albVirtualHeight = mkRef 200");
      Line ("{-# NOINLINE albVirtualHeight #-}");
      Line ("albOriginX :: IORef Int");
      Line ("albOriginX = mkRef 0");
      Line ("{-# NOINLINE albOriginX #-}");
      Line ("albOriginY :: IORef Int");
      Line ("albOriginY = mkRef 0");
      Line ("{-# NOINLINE albOriginY #-}");
      Line ("albAlphaChannel :: IORef Int");
      Line ("albAlphaChannel = mkRef 0");
      Line ("{-# NOINLINE albAlphaChannel #-}");
      Line ("albAlphaValue :: IORef Int");
      Line ("albAlphaValue = mkRef 255");
      Line ("{-# NOINLINE albAlphaValue #-}");
      Line ("albStretchy :: IORef Bool");
      Line ("albStretchy = mkRef False");
      Line ("{-# NOINLINE albStretchy #-}");
      Line ("albResizable :: IORef Bool");
      Line ("albResizable = mkRef True");
      Line ("{-# NOINLINE albResizable #-}");
      Line ("albRunning :: IORef Bool");
      Line ("albRunning = mkRef True");
      Line ("{-# NOINLINE albRunning #-}");
      Line ("albShutdownDone :: IORef Bool");
      Line ("albShutdownDone = mkRef False");
      Line ("{-# NOINLINE albShutdownDone #-}");
      Line ("albMouseX :: IORef Int");
      Line ("albMouseX = mkRef 0");
      Line ("{-# NOINLINE albMouseX #-}");
      Line ("albMouseY :: IORef Int");
      Line ("albMouseY = mkRef 0");
      Line ("{-# NOINLINE albMouseY #-}");
      Line ("albMouseWheel :: IORef Int");
      Line ("albMouseWheel = mkRef 0");
      Line ("{-# NOINLINE albMouseWheel #-}");
      Line ("albDelayUntil :: IORef Int");
      Line ("albDelayUntil = mkRef 0");
      Line ("{-# NOINLINE albDelayUntil #-}");
      Line ("albFrameInterval :: IORef Int");
      Line ("albFrameInterval = mkRef 16");
      Line ("{-# NOINLINE albFrameInterval #-}");
      Line ("albLastFrame :: IORef Int");
      Line ("albLastFrame = mkRef 0");
      Line ("{-# NOINLINE albLastFrame #-}");
      Line ("albCompatTick :: IORef Int");
      Line ("albCompatTick = mkRef 0");
      Line ("{-# NOINLINE albCompatTick #-}");
      Line ("albNextProcessHandle :: IORef Int");
      Line ("albNextProcessHandle = mkRef 1");
      Line ("{-# NOINLINE albNextProcessHandle #-}");
      Line ("albProcessTable :: IORef (Map.Map Int String)");
      Line ("albProcessTable = mkRef Map.empty");
      Line ("{-# NOINLINE albProcessTable #-}");
      Line ("albProcessMonitor :: IORef (Map.Map String ALBVal)");
      Line ("albProcessMonitor = mkRef Map.empty");
      Line ("{-# NOINLINE albProcessMonitor #-}");
      Line ("albNextNetworkHandle :: IORef Int");
      Line ("albNextNetworkHandle = mkRef 1");
      Line ("{-# NOINLINE albNextNetworkHandle #-}");
      Line ("albNetworkTable :: IORef (Map.Map Int String)");
      Line ("albNetworkTable = mkRef Map.empty");
      Line ("{-# NOINLINE albNetworkTable #-}");
      Line ("albNextSnifferHandle :: IORef Int");
      Line ("albNextSnifferHandle = mkRef 1");
      Line ("{-# NOINLINE albNextSnifferHandle #-}");
      Line ("albSnifferTable :: IORef (Map.Map Int String)");
      Line ("albSnifferTable = mkRef Map.empty");
      Line ("{-# NOINLINE albSnifferTable #-}");
      Line ("albNetworkBus :: IORef (Map.Map String [ALBVal])");
      Line ("albNetworkBus = mkRef Map.empty");
      Line ("{-# NOINLINE albNetworkBus #-}");
      Line ("albFirewallStack :: IORef [String]");
      Line ("albFirewallStack = mkRef []");
      Line ("{-# NOINLINE albFirewallStack #-}");
      Line ("albPixels :: IORef (Map.Map Int ALBVal)");
      Line ("albPixels = mkRef Map.empty");
      Line ("{-# NOINLINE albPixels #-}");
      Line ("albClipRect :: IORef (Maybe (Int,Int,Int,Int))");
      Line ("albClipRect = mkRef Nothing");
      Line ("{-# NOINLINE albClipRect #-}");
      Line ("albCurrentFont :: IORef String");
      Line ("albCurrentFont = mkRef ""monospace""");
      Line ("{-# NOINLINE albCurrentFont #-}");
      Line ("albConsoleDisabled :: IORef Bool");
      Line ("albConsoleDisabled = mkRef " &
            (if No_Console_Overlay then "True" else "False"));
      Line ("{-# NOINLINE albConsoleDisabled #-}");
      Line ("alb_STATIC_Active_Lut :: IORef (Maybe ALBMap)");
      Line ("alb_STATIC_Active_Lut = mkRef Nothing");
      Line ("{-# NOINLINE alb_STATIC_Active_Lut #-}");
      Line ("alb_STATIC_Active_Visual :: IORef ALBVal");
      Line ("alb_STATIC_Active_Visual = mkRef 0");
      Line ("{-# NOINLINE alb_STATIC_Active_Visual #-}");
      Line ("alb_STATIC_Active_Context :: IORef ALBVal");
      Line ("alb_STATIC_Active_Context = mkRef 0");
      Line ("{-# NOINLINE alb_STATIC_Active_Context #-}");
      Line ("alb_STATIC_Active_Context_Used :: IORef Bool");
      Line ("alb_STATIC_Active_Context_Used = mkRef False");
      Line ("{-# NOINLINE alb_STATIC_Active_Context_Used #-}");
      Line ("albWasmBindings :: IORef (Map.Map String ALBVal)");
      Line ("albWasmBindings = mkRef Map.empty");
      Line ("{-# NOINLINE albWasmBindings #-}");
      Line ("albWasmLoaders :: IORef [IO ()]");
      Line ("albWasmLoaders = mkRef []");
      Line ("{-# NOINLINE albWasmLoaders #-}");
      Line ("albCompatExports :: IORef (Map.Map String ALBVal)");
      Line ("albCompatExports = mkRef Map.empty");
      Line ("{-# NOINLINE albCompatExports #-}");
      Line ("alb_ON_TICK :: IORef (IO ())");
      Line ("alb_ON_TICK = mkRef (return ())");
      Line ("{-# NOINLINE alb_ON_TICK #-}");
      Line ("alb_ON_PAINT :: IORef (IO ())");
      Line ("alb_ON_PAINT = mkRef (return ())");
      Line ("{-# NOINLINE alb_ON_PAINT #-}");
      Line ("alb_ON_KEY :: IORef (IO ())");
      Line ("alb_ON_KEY = mkRef (return ())");
      Line ("{-# NOINLINE alb_ON_KEY #-}");
      Line ("alb_NOTIFY_KNOWS_CHANGE :: IORef (Int -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> IO ())");
      Line ("alb_NOTIFY_KNOWS_CHANGE = mkRef (\_ _ _ _ _ -> return ())");
      Line ("{-# NOINLINE alb_NOTIFY_KNOWS_CHANGE #-}");
      New_Line_Emit;
      Line ("-- Function returns use AlbFnReturn + ret slot. Proc early-exit uses AlbProcReturn.");
      Line ("-- Separate exception types so nested unsafePerformIO albRunFn cannot abort albRunProc.");
      Line ("albRetSlot :: IORef (Maybe ALBVal)");
      Line ("albRetSlot = unsafePerformIO (newIORef Nothing)");
      Line ("{-# NOINLINE albRetSlot #-}");
      Line ("data AlbFnReturn = AlbFnReturn deriving (Show)");
      Line ("instance Exception AlbFnReturn");
      Line ("data AlbProcReturn = AlbProcReturn deriving (Show)");
      Line ("instance Exception AlbProcReturn");
      Line ("albReturn :: ALBVal -> IO ()");
      Line ("albReturn v = writeIORef albRetSlot (Just v) >> throwIO AlbFnReturn");
      Line ("albProcReturn :: IO ()");
      Line ("albProcReturn = throwIO AlbProcReturn");
      Line ("albRunFn :: IO () -> IO ALBVal");
      Line ("albRunFn act = do");
      Line ("  writeIORef albRetSlot Nothing");
      Line ("  act `catch` \(_ :: AlbFnReturn) -> return ()");
      Line ("  readIORef albRetSlot >>= maybe (return 0) return");
      Line ("albRunProc :: IO () -> IO ()");
      Line ("albRunProc act =");
      Line ("  (act >> return ()) `catch` \(_ :: AlbProcReturn) -> return ()");
      Line ("alb_FATAL :: String -> IO a");
      Line ("alb_FATAL msg = do");
      Line ("  albSet albRunning False");
      Line ("  hPutStrLn stderr (""ALBH fatal: "" ++ msg)");
      Line ("  error msg");
      New_Line_Emit;
      Line ("alb_WARN_ONCE :: String -> String -> IO ()");
      Line ("alb_WARN_ONCE key message = do");
      Line ("  m <- readIORef albWarnedKeys");
      Line ("  unless (Map.member key m) $ do");
      Line ("    writeIORef albWarnedKeys (Map.insert key True m)");
      Line ("    hPutStrLn stderr (""ALBH: "" ++ message)");
      New_Line_Emit;
      Line ("alb_new_array :: Int -> ALBVal -> ALBMap");
      Line ("alb_new_array n fill = Map.fromList [(i, fill) | i <- [0 .. max 0 (n - 1)]]");
      New_Line_Emit;
      Line ("alb_filled :: Int -> ALBVal -> ALBMap");
      Line ("alb_filled = alb_new_array");
      New_Line_Emit;
      Line ("alb_arrGet :: ALBMap -> Int -> ALBVal");
      Line ("alb_arrGet m i = Map.findWithDefault 0 i m");
      New_Line_Emit;
      Line ("alb_arrSet :: ALBMap -> Int -> ALBVal -> ALBMap");
      Line ("alb_arrSet m i v = Map.insert i v m");
      Line ("albRefArrGet :: IORef ALBMap -> ALBVal -> ALBVal");
      Line ("albRefArrGet r i = unsafePerformIO $ do");
      Line ("  e <- readIORef albEpoch");
      Line ("  m <- readIORef r");
      Line ("  e `seq` return $! alb_arrGet m (fromIntegral i)");
      Line ("{-# NOINLINE albRefArrGet #-}");
      Line ("albRefArrSet :: IORef ALBMap -> ALBVal -> ALBVal -> IO ()");
      Line ("albRefArrSet r i v = do");
      Line ("  modifyIORef' r (\m -> alb_arrSet m (fromIntegral i) v)");
      Line ("  modifyIORef' albEpoch (+1)");
      New_Line_Emit;
      Line ("albU8 :: ALBVal -> ALBVal");
      Line ("albU8 v = v .&. 0xff");
      Line ("albU16 :: ALBVal -> ALBVal");
      Line ("albU16 v = v .&. 0xffff");
      Line ("albU32 :: ALBVal -> ALBVal");
      Line ("albU32 v = v .&. 0xffffffff");
      Line ("albI8 :: ALBVal -> ALBVal");
      Line ("albI8 v = let n = v .&. 0xff in if n >= 0x80 then n - 0x100 else n");
      Line ("albI16 :: ALBVal -> ALBVal");
      Line ("albI16 v = let n = v .&. 0xffff in if n >= 0x8000 then n - 0x10000 else n");
      Line ("albI32 :: ALBVal -> ALBVal");
      Line ("albI32 v = let n = v .&. 0xffffffff in if n >= 0x80000000 then n - 0x100000000 else n");
      New_Line_Emit;
      Line ("u8 = albU8; u16 = albU16; s8 = albI8; i8 = albI8");
      Line ("s16 = albI16; i16 = albI16; u32 = albU32; u64 = albU32; u128 = id");
      Line ("s32 = albI32; i32 = albI32; hw8 = albI32; hw16 = albI32; hw32 = albI32");
      Line ("f64 :: ALBVal -> Double");
      Line ("f64 = fromIntegral");
      New_Line_Emit;
      Line ("alb_PURE_NUM_BITS :: Int");
      Line ("alb_PURE_NUM_BITS = 21");
      Line ("alb_PURE_NUM_MOD :: ALBVal");
      Line ("alb_PURE_NUM_MOD = 1 `shiftL` alb_PURE_NUM_BITS");
      Line ("alb_PURE_NUM_SIGN :: ALBVal");
      Line ("alb_PURE_NUM_SIGN = 1 `shiftL` (alb_PURE_NUM_BITS - 1)");
      Line ("alb_PURE_DEN_LIMIT :: ALBVal");
      Line ("alb_PURE_DEN_LIMIT = 0x7fffffff");
      New_Line_Emit;
      Line ("albPureAbs :: ALBVal -> ALBVal");
      Line ("albPureAbs v = if v < 0 then negate v else v");
      New_Line_Emit;
      Line ("albPureIsPacked :: ALBVal -> Bool");
      Line ("albPureIsPacked v = v >= alb_PURE_NUM_MOD");
      New_Line_Emit;
      Line ("albPureGcd :: ALBVal -> ALBVal -> ALBVal");
      Line ("albPureGcd a b =");
      Line ("  let loop x y = if y == 0 then (if x == 0 then 1 else x) else loop y (x `mod` y)");
      Line ("  in loop (albPureAbs a) (albPureAbs b)");
      New_Line_Emit;
      Line ("albPurePack :: ALBVal -> ALBVal -> ALBVal");
      Line ("albPurePack num den =");
      Line ("  let (n0, d0) = if den == 0 then (0, 1) else if den < 0 then (negate num, negate den) else (num, den)");
      Line ("  in if n0 == 0 then alb_PURE_NUM_MOD");
      Line ("     else");
      Line ("       let g0 = albPureGcd n0 d0");
      Line ("           n1 = n0 `div` g0");
      Line ("           d1 = d0 `div` g0");
      Line ("           maxNum = alb_PURE_NUM_SIGN - 1");
      Line ("           shrink n d");
      Line ("             | (albPureAbs n > maxNum || d > alb_PURE_DEN_LIMIT) && d > 1 =");
      Line ("                 let n' = n `div` 2; d' = max 1 (d `div` 2); g = albPureGcd n' d'");
      Line ("                 in shrink (n' `div` g) (d' `div` g)");
      Line ("             | otherwise = (n, d)");
      Line ("           (n2, d2) = shrink n1 d1");
      Line ("           enc = if n2 < 0 then alb_PURE_NUM_MOD + n2 else n2");
      Line ("       in d2 * alb_PURE_NUM_MOD + enc");
      New_Line_Emit;
      Line ("albPURE :: ALBVal -> ALBVal -> ALBVal");
      Line ("albPURE num den = albPurePack num den");
      Line ("albPURE_NUM :: ALBVal -> ALBVal");
      Line ("albPURE_NUM v");
      Line ("  | not (albPureIsPacked v) = v");
      Line ("  | otherwise = let enc = v `mod` alb_PURE_NUM_MOD");
      Line ("                in if enc >= alb_PURE_NUM_SIGN then enc - alb_PURE_NUM_MOD else enc");
      Line ("albPURE_DEN :: ALBVal -> ALBVal");
      Line ("albPURE_DEN v");
      Line ("  | not (albPureIsPacked v) = 1");
      Line ("  | otherwise = let d = v `div` alb_PURE_NUM_MOD in if d <= 0 then 1 else d");
      Line ("albPURE_ADD a b =");
      Line ("  let an = albPURE_NUM a; ad = albPURE_DEN a; bn = albPURE_NUM b; bd = albPURE_DEN b");
      Line ("      g = albPureGcd ad bd; lm = bd `div` g; rm = ad `div` g");
      Line ("  in albPurePack (an * lm + bn * rm) (ad * lm)");
      Line ("albPURE_SUB a b =");
      Line ("  let an = albPURE_NUM a; ad = albPURE_DEN a; bn = albPURE_NUM b; bd = albPURE_DEN b");
      Line ("      g = albPureGcd ad bd; lm = bd `div` g; rm = ad `div` g");
      Line ("  in albPurePack (an * lm - bn * rm) (ad * lm)");
      Line ("albPURE_MUL a b =");
      Line ("  let an0 = albPURE_NUM a; ad0 = albPURE_DEN a; bn0 = albPURE_NUM b; bd0 = albPURE_DEN b");
      Line ("      g1 = albPureGcd an0 bd0; an = an0 `div` g1; bd = bd0 `div` g1");
      Line ("      g2 = albPureGcd bn0 ad0; bn = bn0 `div` g2; ad = ad0 `div` g2");
      Line ("  in albPurePack (an * bn) (ad * bd)");
      Line ("albPURE_DIV a b =");
      Line ("  let an0 = albPURE_NUM a; ad0 = albPURE_DEN a; bn0 = albPURE_NUM b; bd0 = albPURE_DEN b");
      Line ("  in if bn0 == 0 then alb_PURE_NUM_MOD");
      Line ("     else");
      Line ("       let (bn1, bd1) = if bn0 < 0 then (negate bn0, negate bd0) else (bn0, bd0)");
      Line ("           g1 = albPureGcd an0 bn1; an = an0 `div` g1; bn = bn1 `div` g1");
      Line ("           g2 = albPureGcd bd1 ad0; bd = bd1 `div` g2; ad = ad0 `div` g2");
      Line ("       in albPurePack (an * bd) (ad * bn)");
      Line ("albPURE_POW a b =");
      Line ("  let en = albPURE_NUM b; ed = albPURE_DEN b");
      Line ("  in if ed == 1 then");
      Line ("       if en == 0 then albPURE 1 1");
      Line ("       else");
      Line ("         let go factor power result");
      Line ("               | power <= 0 = result");
      Line ("               | odd power = go (albPURE_MUL factor factor) (power `div` 2) (albPURE_MUL result factor)");
      Line ("               | otherwise = go (albPURE_MUL factor factor) (power `div` 2) result");
      Line ("             (factor0, power0) =");
      Line ("               if en < 0 then");
      Line ("                 if albPURE_NUM a == 0 then (albPURE 0 1, 0)");
      Line ("                 else (albPURE_DIV (albPURE 1 1) a, negate en)");
      Line ("               else (a, en)");
      Line ("         in go factor0 power0 (albPURE 1 1)");
      Line ("     else");
      Line ("       let av = fromIntegral (albPURE_NUM a) / fromIntegral (albPURE_DEN a) :: Double");
      Line ("           bv = fromIntegral en / fromIntegral ed :: Double");
      Line ("       in albPurePack (round (av ** bv * 1000000)) 1000000");
      New_Line_Emit;
      Line ("albPowInt :: ALBVal -> ALBVal -> ALBVal");
      Line ("albPowInt base expn");
      Line ("  | expn < 0 = if base == 1 then 1 else if base == (-1) then (if odd expn then (-1) else 1) else 0");
      Line ("  | otherwise = go 1 base expn");
      Line ("  where");
      Line ("    go result factor power");
      Line ("      | power <= 0 = result");
      Line ("      | odd power = go (result * factor) (factor * factor) (power `div` 2)");
      Line ("      | otherwise = go result (factor * factor) (power `div` 2)");
      New_Line_Emit;
      Line ("alb_POW :: ALBVal -> ALBVal -> ALBVal");
      Line ("alb_POW = albPowInt");
      Line ("albDiv a b = if b == 0 then 0 else a `div` b");
      Line ("albMod a b = if b == 0 then 0 else a `mod` b");
      New_Line_Emit;
      Line ("alb_PRINT :: String -> IO ()");
      Line ("alb_PRINT v = do");
      Line ("  disabled <- readIORef albConsoleDisabled");
      Line ("  unless disabled $ putStrLn v");
      New_Line_Emit;
      Line ("alb_PRINT_RAW :: String -> IO ()");
      Line ("alb_PRINT_RAW v = do");
      Line ("  disabled <- readIORef albConsoleDisabled");
      Line ("  unless disabled $ putStr v >> hFlush stdout");
      New_Line_Emit;
      Line ("alb_PROMPT_TEXT :: String -> IO String");
      Line ("alb_PROMPT_TEXT prompt = do");
      Line ("  unless (null prompt) (alb_PRINT prompt)");
      Line ("  hFlush stdout");
      Line ("  getLine `catch` (\(_ :: SomeException) -> return """")");
      New_Line_Emit;
      Line ("alb_READLINE_TEXT :: IO String");
      Line ("alb_READLINE_TEXT = alb_PROMPT_TEXT """"");
      New_Line_Emit;
      Line ("alb_LOCATE :: Int -> Int -> IO ()");
      Line ("alb_LOCATE x y = do");
      Line ("  writeIORef albTextCursorX (max 1 x)");
      Line ("  writeIORef albTextCursorY (max 1 y)");
      New_Line_Emit;
      New_Line_Emit;
      Line ("-- ===== SDL3 FFI =====");
      Line ("data SDL_FRect = SDL_FRect {-# UNPACK #-} !CFloat {-# UNPACK #-} !CFloat {-# UNPACK #-} !CFloat {-# UNPACK #-} !CFloat");
      Line ("instance Storable SDL_FRect where");
      Line ("  sizeOf _ = 16; alignment _ = 4");
      Line ("  peek p = SDL_FRect <$> peekByteOff p 0 <*> peekByteOff p 4 <*> peekByteOff p 8 <*> peekByteOff p 12");
      Line ("  poke p (SDL_FRect x y w h) = pokeByteOff p 0 x >> pokeByteOff p 4 y >> pokeByteOff p 8 w >> pokeByteOff p 12 h");
      Line ("data SDL_FPoint = SDL_FPoint {-# UNPACK #-} !CFloat {-# UNPACK #-} !CFloat");
      Line ("instance Storable SDL_FPoint where");
      Line ("  sizeOf _ = 8; alignment _ = 4");
      Line ("  peek p = SDL_FPoint <$> peekByteOff p 0 <*> peekByteOff p 4");
      Line ("  poke p (SDL_FPoint x y) = pokeByteOff p 0 x >> pokeByteOff p 4 y");
      Line ("data SDL_FColor = SDL_FColor {-# UNPACK #-} !CFloat {-# UNPACK #-} !CFloat {-# UNPACK #-} !CFloat {-# UNPACK #-} !CFloat");
      Line ("instance Storable SDL_FColor where");
      Line ("  sizeOf _ = 16; alignment _ = 4");
      Line ("  peek p = SDL_FColor <$> peekByteOff p 0 <*> peekByteOff p 4 <*> peekByteOff p 8 <*> peekByteOff p 12");
      Line ("  poke p (SDL_FColor r g b a) = pokeByteOff p 0 r >> pokeByteOff p 4 g >> pokeByteOff p 8 b >> pokeByteOff p 12 a");
      Line ("data SDL_Vertex = SDL_Vertex !SDL_FPoint !SDL_FColor !SDL_FPoint");
      Line ("instance Storable SDL_Vertex where");
      Line ("  sizeOf _ = 32; alignment _ = 4");
      Line ("  peek p = SDL_Vertex <$> peekByteOff p 0 <*> peekByteOff p 8 <*> peekByteOff p 24");
      Line ("  poke p (SDL_Vertex pos col tex) = pokeByteOff p 0 pos >> pokeByteOff p 8 col >> pokeByteOff p 24 tex");
      New_Line_Emit;
      Line ("foreign import ccall unsafe ""SDL_Init"" c_SDL_Init :: CUInt -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_Quit"" c_SDL_Quit :: IO ()");
      Line ("foreign import ccall unsafe ""SDL_CreateWindowAndRenderer"" c_SDL_CreateWindowAndRenderer :: CString -> CInt -> CInt -> Word64 -> Ptr (Ptr ()) -> Ptr (Ptr ()) -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_DestroyWindow"" c_SDL_DestroyWindow :: Ptr () -> IO ()");
      Line ("foreign import ccall unsafe ""SDL_DestroyRenderer"" c_SDL_DestroyRenderer :: Ptr () -> IO ()");
      Line ("foreign import ccall unsafe ""SDL_SetRenderVSync"" c_SDL_SetRenderVSync :: Ptr () -> CInt -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_SetRenderDrawColor"" c_SDL_SetRenderDrawColor :: Ptr () -> Word8 -> Word8 -> Word8 -> Word8 -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_SetRenderDrawBlendMode"" c_SDL_SetRenderDrawBlendMode :: Ptr () -> CInt -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderClear"" c_SDL_RenderClear :: Ptr () -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderPresent"" c_SDL_RenderPresent :: Ptr () -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderFillRect"" c_SDL_RenderFillRect :: Ptr () -> Ptr SDL_FRect -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderRect"" c_SDL_RenderRect :: Ptr () -> Ptr SDL_FRect -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderLine"" c_SDL_RenderLine :: Ptr () -> CFloat -> CFloat -> CFloat -> CFloat -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderPoint"" c_SDL_RenderPoint :: Ptr () -> CFloat -> CFloat -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderPoints"" c_SDL_RenderPoints :: Ptr () -> Ptr SDL_FPoint -> CInt -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_RenderGeometry"" c_SDL_RenderGeometry :: Ptr () -> Ptr () -> Ptr SDL_Vertex -> CInt -> Ptr CInt -> CInt -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_PollEvent"" c_SDL_PollEvent :: Ptr Word8 -> IO CBool");
      Line ("foreign import ccall unsafe ""SDL_GetTicks"" c_SDL_GetTicks :: IO Word64");
      Line ("foreign import ccall unsafe ""SDL_Delay"" c_SDL_Delay :: Word32 -> IO ()");
      Line ("foreign import ccall unsafe ""SDL_GetError"" c_SDL_GetError :: IO CString");
      New_Line_Emit;
      Line ("albSdlWindow :: IORef (Ptr ())");
      Line ("albSdlWindow = mkRef nullPtr");
      Line ("{-# NOINLINE albSdlWindow #-}");
      Line ("albSdlRenderer :: IORef (Ptr ())");
      Line ("albSdlRenderer = mkRef nullPtr");
      Line ("{-# NOINLINE albSdlRenderer #-}");
      Line ("albSdlReady :: IORef Bool");
      Line ("albSdlReady = mkRef False");
      Line ("{-# NOINLINE albSdlReady #-}");
      New_Line_Emit;
      Line ("albSdlOk :: CBool -> Bool");
      Line ("albSdlOk b = (fromIntegral b :: Int) /= 0");
      New_Line_Emit;
      Line ("albSdlErr :: IO String");
      Line ("albSdlErr = do");
      Line ("  p <- c_SDL_GetError");
      Line ("  if p == nullPtr then return ""SDL error"" else peekCString p");
      New_Line_Emit;
      Line ("albSdlRdr :: IO (Ptr ())");
      Line ("albSdlRdr = readIORef albSdlRenderer");
      New_Line_Emit;
      Line ("albSdlApplyColor :: IO ()");
      Line ("albSdlApplyColor = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    c <- readIORef albColorValue");
      Line ("    let a0 = fromIntegral ((c `shiftR` 24) .&. 255) :: Word8");
      Line ("        a = if a0 == 0 then 255 else a0");
      Line ("        r = fromIntegral ((c `shiftR` 16) .&. 255) :: Word8");
      Line ("        g = fromIntegral ((c `shiftR` 8) .&. 255) :: Word8");
      Line ("        b = fromIntegral (c .&. 255) :: Word8");
      Line ("    void (c_SDL_SetRenderDrawColor rdr r g b a)");
      New_Line_Emit;
      Line ("albSdlColorToF :: ALBVal -> SDL_FColor");
      Line ("albSdlColorToF c =");
      Line ("  let aByte = (c `shiftR` 24) .&. 255");
      Line ("      a = if aByte == 0 then 1.0 else fromIntegral aByte / 255.0");
      Line ("  in SDL_FColor (CFloat (fromIntegral ((c `shiftR` 16) .&. 255) / 255.0))");
      Line ("                (CFloat (fromIntegral ((c `shiftR` 8) .&. 255) / 255.0))");
      Line ("                (CFloat (fromIntegral (c .&. 255) / 255.0))");
      Line ("                (CFloat a)");
      New_Line_Emit;
      Line ("albReadU32LE :: [Word8] -> Int -> Word32");
      Line ("albReadU32LE buf off =");
      Line ("  let b i = fromIntegral (buf !! (off + i)) :: Word32");
      Line ("  in b 0 .|. shiftL (b 1) 8 .|. shiftL (b 2) 16 .|. shiftL (b 3) 24");
      New_Line_Emit;
      Line ("albCastF32 :: Word32 -> Float");
      Line ("albCastF32 w = unsafePerformIO $ alloca $ \(p :: Ptr Word32) -> poke p w >> peek (castPtr p :: Ptr Float)");
      Line ("{-# NOINLINE albCastF32 #-}");
      New_Line_Emit;
      Line ("albReadF32LE :: [Word8] -> Int -> Float");
      Line ("albReadF32LE buf off = albCastF32 (albReadU32LE buf off)");
      New_Line_Emit;
      Line ("alb_Poll_Events :: IO Bool");
      Line ("alb_Poll_Events = do");
      Line ("  allocaArray 128 $ \(ev :: Ptr Word8) -> do");
      Line ("    let loop = do");
      Line ("          ok <- c_SDL_PollEvent ev");
      Line ("          when (albSdlOk ok) $ do");
      Line ("            bytes <- peekArray 128 ev");
      Line ("            let ty = albReadU32LE bytes 0");
      Line ("            if ty == 0x100 then writeIORef albRunning False");
      Line ("            else if ty == 0x300 || ty == 0x301 then do");
      Line ("              let sc = fromIntegral (albReadU32LE bytes 24) :: Int");
      Line ("              when (sc >= 0 && sc < 512) $");
      Line ("                modifyIORef' albKeys (Map.insert sc (if ty == 0x300 then 1 else 0))");
      Line ("            else if ty == 0x400 then do");
      Line ("              writeIORef albMouseX (round (albReadF32LE bytes 28))");
      Line ("              writeIORef albMouseY (round (albReadF32LE bytes 32))");
      Line ("            else if ty == 0x401 || ty == 0x402 then do");
      Line ("              let button = fromIntegral (bytes !! 24) :: Int");
      Line ("              when (button >= 1 && button <= 8) $");
      Line ("                modifyIORef' albMouseButtons (Map.insert (button - 1) (if ty == 0x401 then 1 else 0))");
      Line ("            else if ty == 0x403 then");
      Line ("              modifyIORef' albMouseWheel (+ round (albReadF32LE bytes 28))");
      Line ("            else return ()");
      Line ("            loop");
      Line ("    loop");
      Line ("  readIORef albRunning");
      New_Line_Emit;
      Line ("alb_PRESENT :: IO ()");
      Line ("alb_PRESENT = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ void (c_SDL_RenderPresent rdr)");
      New_Line_Emit;
      Line ("alb_SDL_Shutdown :: IO ()");
      Line ("alb_SDL_Shutdown = do");
      Line ("  rdr <- readIORef albSdlRenderer");
      Line ("  win <- readIORef albSdlWindow");
      Line ("  when (rdr /= nullPtr) $ c_SDL_DestroyRenderer rdr >> writeIORef albSdlRenderer nullPtr");
      Line ("  when (win /= nullPtr) $ c_SDL_DestroyWindow win >> writeIORef albSdlWindow nullPtr");
      Line ("  ready <- readIORef albSdlReady");
      Line ("  when ready $ c_SDL_Quit >> writeIORef albSdlReady False");
      New_Line_Emit;
      Line ("alb_CreateWindow :: String -> Int -> Int -> IO ()");
      Line ("alb_CreateWindow title w0 h0 = do");
      Line ("  let w = max 1 w0; h = max 1 h0");
      Line ("  writeIORef albBaseWidth w; writeIORef albBaseHeight h");
      Line ("  writeIORef albVirtualWidth w; writeIORef albVirtualHeight h");
      Line ("  writeIORef albWindowWidth w; writeIORef albWindowHeight h");
      Line ("  modifyIORef' albEpoch (+1)");
      Line ("  win0 <- readIORef albSdlWindow");
      Line ("  when (win0 == nullPtr) $ do");
      Line ("    okInit <- c_SDL_Init 0x00000020");
      Line ("    unless (albSdlOk okInit) $ do");
      Line ("      msg <- albSdlErr");
      Line ("      alb_FATAL (""SDL_Init: "" ++ msg)");
      Line ("    withCString title $ \ctitle ->");
      Line ("      alloca $ \pWin ->");
      Line ("      alloca $ \pRdr -> do");
      Line ("        poke pWin nullPtr; poke pRdr nullPtr");
      Line ("        okWin <- c_SDL_CreateWindowAndRenderer ctitle (fromIntegral w) (fromIntegral h) 0 pWin pRdr");
      Line ("        unless (albSdlOk okWin) $ do");
      Line ("          msg <- albSdlErr");
      Line ("          alb_FATAL (""SDL_CreateWindowAndRenderer: "" ++ msg)");
      Line ("        win <- peek pWin; rdr <- peek pRdr");
      Line ("        writeIORef albSdlWindow win; writeIORef albSdlRenderer rdr");
      Line ("        void (c_SDL_SetRenderVSync rdr 1)");
      Line ("        void (c_SDL_SetRenderDrawBlendMode rdr 1) -- SDL_BLENDMODE_BLEND");
      Line ("        writeIORef albSdlReady True");
      Line ("  writeIORef albKeys Map.empty");
      New_Line_Emit;
      Line ("alb_CREATE_WINDOW = alb_CreateWindow");
      Line ("alb_SET_FULLSCREEN :: Bool -> IO ()");
      Line ("alb_SET_FULLSCREEN _ = return ()");
      Line ("alb_SET_RESIZABLE :: Bool -> IO ()");
      Line ("alb_SET_RESIZABLE v = writeIORef albResizable v");
      Line ("alb_SET_STRETCHY :: Bool -> IO ()");
      Line ("alb_SET_STRETCHY v = writeIORef albStretchy v");
      Line ("alb_PREPARE_FRAME :: IO ()");
      Line ("alb_PREPARE_FRAME = albSdlApplyColor");
      Line ("alb_COLOR :: ALBVal -> IO ()");
      Line ("alb_COLOR v = do");
      Line ("  writeIORef albColorValue (albU32 v)");
      Line ("  writeIORef albCurrentColor (albU32 v)");
      Line ("  albSdlApplyColor");
      Line ("alb_CLEAR :: ALBVal -> IO ()");
      Line ("alb_CLEAR v = do");
      Line ("  alb_COLOR v");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ void (c_SDL_RenderClear rdr)");
      New_Line_Emit;
      Line ("alb_DRAW_RECT :: ALBVal -> ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_DRAW_RECT x y w h = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- readIORef albOriginX; oy <- readIORef albOriginY");
      Line ("    let rect = SDL_FRect (CFloat (fromIntegral (fromIntegral x + ox))) (CFloat (fromIntegral (fromIntegral y + oy))) (CFloat (fromIntegral w)) (CFloat (fromIntegral h))");
      Line ("    albSdlApplyColor");
      Line ("    alloca $ \p -> poke p rect >> void (c_SDL_RenderRect rdr p)");
      New_Line_Emit;
      Line ("alb_FILL_RECT :: ALBVal -> ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_FILL_RECT x y w h = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- readIORef albOriginX; oy <- readIORef albOriginY");
      Line ("    let rect = SDL_FRect (CFloat (fromIntegral (fromIntegral x + ox))) (CFloat (fromIntegral (fromIntegral y + oy))) (CFloat (fromIntegral w)) (CFloat (fromIntegral h))");
      Line ("    albSdlApplyColor");
      Line ("    alloca $ \p -> poke p rect >> void (c_SDL_RenderFillRect rdr p)");
      New_Line_Emit;
      Line ("alb_DRAW_LINE :: ALBVal -> ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_DRAW_LINE x1 y1 x2 y2 = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- fmap fromIntegral (readIORef albOriginX) :: IO Float");
      Line ("    oy <- fmap fromIntegral (readIORef albOriginY) :: IO Float");
      Line ("    albSdlApplyColor");
      Line ("    void (c_SDL_RenderLine rdr (CFloat (fromIntegral x1 + ox)) (CFloat (fromIntegral y1 + oy)) (CFloat (fromIntegral x2 + ox)) (CFloat (fromIntegral y2 + oy)))");
      New_Line_Emit;
      Line ("alb_DRAW_CIRCLE :: ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_DRAW_CIRCLE x y r = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- readIORef albOriginX; oy <- readIORef albOriginY");
      Line ("    let cx = fromIntegral (fromIntegral x + ox) :: Float");
      Line ("        cy = fromIntegral (fromIntegral y + oy) :: Float");
      Line ("        rad = max 0 (fromIntegral r) :: Int");
      Line ("    albSdlApplyColor");
      Line ("    forM_ [-rad .. rad] $ \yy -> forM_ [-rad .. rad] $ \xx -> do");
      Line ("      let d = xx*xx + yy*yy; outer = rad*rad; inner = (rad-1)*(rad-1)");
      Line ("      when (d <= outer && d >= inner) $");
      Line ("        void (c_SDL_RenderPoint rdr (CFloat (cx + fromIntegral xx)) (CFloat (cy + fromIntegral yy)))");
      New_Line_Emit;
      Line ("alb_FILL_CIRCLE :: ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_FILL_CIRCLE x y r = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- readIORef albOriginX; oy <- readIORef albOriginY");
      Line ("    let cx = fromIntegral (fromIntegral x + ox) :: Float");
      Line ("        cy = fromIntegral (fromIntegral y + oy) :: Float");
      Line ("        rad = max 0 (fromIntegral r) :: Int");
      Line ("    albSdlApplyColor");
      Line ("    forM_ [-rad .. rad] $ \yy -> forM_ [-rad .. rad] $ \xx ->");
      Line ("      when (xx*xx + yy*yy <= rad*rad) $");
      Line ("        void (c_SDL_RenderPoint rdr (CFloat (cx + fromIntegral xx)) (CFloat (cy + fromIntegral yy)))");
      New_Line_Emit;
      Line ("alb_DRAW_TRIANGLE :: ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_DRAW_TRIANGLE x1 y1 x2 y2 x3 y3 = do");
      Line ("  alb_DRAW_LINE x1 y1 x2 y2; alb_DRAW_LINE x2 y2 x3 y3; alb_DRAW_LINE x3 y3 x1 y1");
      New_Line_Emit;
      Line ("alb_FILL_TRIANGLE :: ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_FILL_TRIANGLE x1 y1 x2 y2 x3 y3 = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- fmap fromIntegral (readIORef albOriginX) :: IO Float");
      Line ("    oy <- fmap fromIntegral (readIORef albOriginY) :: IO Float");
      Line ("    c <- readIORef albColorValue");
      Line ("    let aByte = (c `shiftR` 24) .&. 255");
      Line ("        a = if aByte == 0 then 1.0 else fromIntegral aByte / 255.0 :: Float");
      Line ("        r = fromIntegral ((c `shiftR` 16) .&. 255) / 255.0 :: Float");
      Line ("        g = fromIntegral ((c `shiftR` 8) .&. 255) / 255.0 :: Float");
      Line ("        b = fromIntegral (c .&. 255) / 255.0 :: Float");
      Line ("        -- Flat SDL_Vertex layout: x,y, r,g,b,a, u,v  (8 floats) x 3");
      Line ("        floats =");
      Line ("          [ fromIntegral x1 + ox, fromIntegral y1 + oy, r, g, b, a, 0, 0");
      Line ("          , fromIntegral x2 + ox, fromIntegral y2 + oy, r, g, b, a, 0, 0");
      Line ("          , fromIntegral x3 + ox, fromIntegral y3 + oy, r, g, b, a, 0, 0 ] :: [Float]");
      Line ("    allocaArray 24 $ \(p :: Ptr CFloat) -> do");
      Line ("      pokeArray p (map CFloat floats)");
      Line ("      void (c_SDL_RenderGeometry rdr nullPtr (castPtr p) 3 nullPtr 0)");
      New_Line_Emit;
      Line ("alb_PLOT :: ALBVal -> ALBVal -> IO ()");
      Line ("alb_PLOT x y = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- fmap fromIntegral (readIORef albOriginX) :: IO Float");
      Line ("    oy <- fmap fromIntegral (readIORef albOriginY) :: IO Float");
      Line ("    albSdlApplyColor");
      Line ("    void (c_SDL_RenderPoint rdr (CFloat (fromIntegral x + ox)) (CFloat (fromIntegral y + oy)))");
      New_Line_Emit;
      New_Line_Emit;
      Line ("alb_FONT8X8 :: [[Word8]]");
      Line ("alb_FONT8X8 =");
      Line ("  [");
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
      Line ("  ]");
      New_Line_Emit;
      Line ("alb_DRAW_TEXT :: ALBVal -> ALBVal -> String -> IO ()");
      Line ("alb_DRAW_TEXT x y t = do");
      Line ("  rdr <- albSdlRdr");
      Line ("  when (rdr /= nullPtr) $ do");
      Line ("    ox <- fmap fromIntegral (readIORef albOriginX) :: IO Float");
      Line ("    oy <- fmap fromIntegral (readIORef albOriginY) :: IO Float");
      Line ("    let x0 = fromIntegral x + ox");
      Line ("        flush pts = when (not (null pts)) $ withArray pts $ \p -> void (c_SDL_RenderPoints rdr p (fromIntegral (length pts)))");
      Line ("        go _ _ [] pts = flush pts");
      Line ("        go cx cy (ch:rest) pts");
      Line ("          | ch == '\n' = flush pts >> go x0 (cy + 10) rest []");
      Line ("          | fromEnum ch < 32 || fromEnum ch > 127 = go (cx + 8) cy rest pts");
      Line ("          | otherwise =");
      Line ("              let glyph = alb_FONT8X8 !! (fromEnum ch - 32)");
      Line ("                  pts2 = pts ++ [ SDL_FPoint (CFloat (cx + fromIntegral col)) (CFloat (cy + fromIntegral row))");
      Line ("                                | (row, rowData) <- zip [0..] glyph, rowData /= 0");
      Line ("                                , col <- [0..7], (rowData .&. shiftR 0x80 col) /= 0 ]");
      Line ("              in if length pts2 >= 512 then flush pts2 >> go (cx + 8) cy rest []");
      Line ("                 else go (cx + 8) cy rest pts2");
      Line ("    albSdlApplyColor");
      Line ("    go x0 (fromIntegral y + oy) t []");
      New_Line_Emit;
      Line ("alb_PAINTER_MESH :: IORef ALBMap -> IORef ALBMap -> IORef ALBMap");
      Line ("  -> IORef ALBMap -> IORef ALBMap -> IORef ALBMap -> IORef ALBMap");
      Line ("  -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> ALBVal -> IO ()");
      Line ("alb_PAINTER_MESH vxRef vyRef vzRef p1Ref p2Ref p3Ref colRef vc0 fc0 yaw pitch cam_z scale cx cy seed_max = do");
      Line ("  let vcount0 = fromIntegral vc0 :: Int");
      Line ("      fcount0 = fromIntegral fc0 :: Int");
      Line ("  when (vcount0 >= 1 && fcount0 >= 1) $ do");
      Line ("    let vcount = min 256 vcount0");
      Line ("        fcount = min 256 fcount0");
      Line ("    av_x <- readIORef vxRef; av_y <- readIORef vyRef; av_z <- readIORef vzRef");
      Line ("    af_p1 <- readIORef p1Ref; af_p2 <- readIORef p2Ref; af_p3 <- readIORef p3Ref; af_col <- readIORef colRef");
      Line ("    let yd0 = fromIntegral (yaw `mod` 360) :: Int");
      Line ("        pd0 = fromIntegral (pitch `mod` 360) :: Int");
      Line ("        yd = if yd0 < 0 then yd0 + 360 else yd0");
      Line ("        pd = if pd0 < 0 then pd0 + 360 else pd0");
      Line ("        yaw_r = fromIntegral yd * pi / 180.0 :: Double");
      Line ("        pitch_r = fromIntegral pd * pi / 180.0 :: Double");
      Line ("        ysn = sin yaw_r; ycn = cos yaw_r; psn = sin pitch_r; pcn = cos pitch_r");
      Line ("        takeV m i = Map.findWithDefault 0 i m");
      Line ("        project i =");
      Line ("          let x = fromIntegral (takeV av_x i) :: Double");
      Line ("              y = fromIntegral (takeV av_y i) :: Double");
      Line ("              z = fromIntegral (takeV av_z i) :: Double");
      Line ("              tx = x * ycn - z * ysn");
      Line ("              tz = x * ysn + z * ycn");
      Line ("              ty = y");
      Line ("              rx = tx");
      Line ("              rz = ty * psn + tz * pcn");
      Line ("              ry = ty * pcn - tz * psn");
      Line ("              z_depth = max 1 (truncate rz + fromIntegral cam_z)");
      Line ("              px = fromIntegral cx + truncate (rx * fromIntegral scale / fromIntegral z_depth)");
      Line ("              py = fromIntegral cy + truncate (ry * fromIntegral scale / fromIntegral z_depth)");
      Line ("          in (px, py, truncate rz :: Integer)");
      Line ("        projs = [project i | i <- [0 .. vcount - 1]]");
      Line ("        clampV v = max 0 (min (vcount - 1) v)");
      Line ("        faces = sortBy (comparing fst)");
      Line ("          [ let v1 = clampV (fromIntegral (takeV af_p1 f) - 1)");
      Line ("                v2 = clampV (fromIntegral (takeV af_p2 f) - 1)");
      Line ("                v3 = clampV (fromIntegral (takeV af_p3 f) - 1)");
      Line ("                (_,_,z1) = projs !! v1; (_,_,z2) = projs !! v2; (_,_,z3) = projs !! v3");
      Line ("            in ((z1+z2+z3) `div` 3, f)");
      Line ("          | f <- [0 .. fcount - 1] ]");
      Line ("    forM_ faces $ \(avg_z, real_id) -> do");
      Line ("      let v1 = clampV (fromIntegral (takeV af_p1 real_id) - 1)");
      Line ("          v2 = clampV (fromIntegral (takeV af_p2 real_id) - 1)");
      Line ("          v3 = clampV (fromIntegral (takeV af_p3 real_id) - 1)");
      Line ("          (px1,py1,_) = projs !! v1");
      Line ("          (px2,py2,_) = projs !! v2");
      Line ("          (px3,py3,_) = projs !! v3");
      Line ("          face_col = takeV af_col real_id");
      Line ("      alb_COLOR face_col");
      Line ("      alb_FILL_TRIANGLE (fromIntegral px1) (fromIntegral py1) (fromIntegral px2) (fromIntegral py2) (fromIntegral px3) (fromIntegral py3)");
      Line ("      when (seed_max > 0 && fromIntegral (real_id + 1) <= seed_max && avg_z < 10) $ do");
      Line ("        let scx = (px1 + px2 + px3) `div` 3");
      Line ("            scy = (py1 + py2 + py3) `div` 3");
      Line ("        alb_COLOR 0xFFDD00");
      Line ("        alb_FILL_RECT (fromIntegral (scx - 1)) (fromIntegral (scy - 1)) 2 3");
      New_Line_Emit;
      Line ("alb_SET_ALPHA ch v = writeIORef albAlphaChannel (fromIntegral ch) >> writeIORef albAlphaValue (max 0 (min 255 (fromIntegral v)))");
      Line ("alb_SET_CLIP x y w h = writeIORef albClipRect (Just (fromIntegral x, fromIntegral y, fromIntegral w, fromIntegral h))");
      Line ("alb_SET_ORIGIN x y = writeIORef albOriginX (fromIntegral x) >> writeIORef albOriginY (fromIntegral y)");
      Line ("alb_READ_PIXEL _x _y = return (0 :: ALBVal)");
      Line ("alb_KEY :: ALBVal -> ALBVal");
      Line ("alb_KEY code = unsafePerformIO $ do");
      Line ("  ks <- readIORef albKeys");
      Line ("  let c = fromIntegral code :: Int");
      Line ("      get i = Map.findWithDefault 0 i ks");
      Line ("      v0 = get c");
      Line ("      v = if c == 4 then v0 .|. get 80");
      Line ("          else if c == 7 then v0 .|. get 79");
      Line ("          else if c == 22 then v0 .|. get 81");
      Line ("          else if c == 26 then v0 .|. get 82");
      Line ("          else if c == 44 then v0 .|. get 40");
      Line ("          else v0");
      Line ("  return (if v /= 0 then 1 else 0)");
      Line ("{-# NOINLINE alb_KEY #-}");
      Line ("alb_getMouseX :: () -> ALBVal");
      Line ("alb_getMouseX _ = unsafePerformIO (fmap fromIntegral (readIORef albMouseX))");
      Line ("{-# NOINLINE alb_getMouseX #-}");
      Line ("alb_getMouseY :: () -> ALBVal");
      Line ("alb_getMouseY _ = unsafePerformIO (fmap fromIntegral (readIORef albMouseY))");
      Line ("{-# NOINLINE alb_getMouseY #-}");
      Line ("alb_getMouseWheel :: () -> ALBVal");
      Line ("alb_getMouseWheel _ = unsafePerformIO (fmap fromIntegral (readIORef albMouseWheel))");
      Line ("{-# NOINLINE alb_getMouseWheel #-}");
      Line ("alb_MOUSE_X = alb_getMouseX ()");
      Line ("alb_MOUSE_Y = alb_getMouseY ()");
      Line ("alb_MOUSE_WHEEL = alb_getMouseWheel ()");
      Line ("alb_VMOUSE_X = alb_getMouseX ()");
      Line ("alb_VMOUSE_Y = alb_getMouseY ()");
      Line ("alb_MOUSE_CLICK :: ALBVal -> ALBVal");
      Line ("alb_MOUSE_CLICK button = unsafePerformIO $ do");
      Line ("  mb <- readIORef albMouseButtons");
      Line ("  return (fromIntegral (Map.findWithDefault 0 (fromIntegral button) mb))");
      Line ("{-# NOINLINE alb_MOUSE_CLICK #-}");
      Line ("alb_getScreenWidth :: () -> ALBVal");
      Line ("alb_getScreenWidth _ = unsafePerformIO (fmap fromIntegral (readIORef albWindowWidth))");
      Line ("{-# NOINLINE alb_getScreenWidth #-}");
      Line ("alb_getScreenHeight :: () -> ALBVal");
      Line ("alb_getScreenHeight _ = unsafePerformIO (fmap fromIntegral (readIORef albWindowHeight))");
      Line ("{-# NOINLINE alb_getScreenHeight #-}");
      Line ("alb_getVirtualWidth :: () -> ALBVal");
      Line ("alb_getVirtualWidth _ = unsafePerformIO $ do");
      Line ("  _ <- readIORef albEpoch");
      Line ("  fmap fromIntegral (readIORef albVirtualWidth)");
      Line ("{-# NOINLINE alb_getVirtualWidth #-}");
      Line ("alb_getVirtualHeight :: () -> ALBVal");
      Line ("alb_getVirtualHeight _ = unsafePerformIO $ do");
      Line ("  _ <- readIORef albEpoch");
      Line ("  fmap fromIntegral (readIORef albVirtualHeight)");
      Line ("{-# NOINLINE alb_getVirtualHeight #-}");
      Line ("alb_SCREEN_WIDTH = alb_getScreenWidth ()");
      Line ("alb_SCREEN_HEIGHT = alb_getScreenHeight ()");
      Line ("-- Prefer alb_getVirtualWidth () at use sites; these CAFs are legacy aliases only.");
      Line ("alb_VIRTUAL_WIDTH = alb_getVirtualWidth ()");
      Line ("alb_VIRTUAL_HEIGHT = alb_getVirtualHeight ()");
      New_Line_Emit;
      New_Line_Emit;
      Line ("alb_RND :: ALBVal -> ALBVal");
      Line ("alb_RND limit = unsafePerformIO $ do");
      Line ("  let n = max 1 (fromIntegral limit)");
      Line ("  s <- readIORef albCompatTick");
      Line ("  let s2 = xor (s * 1103515245 + 12345) (shiftL s 7)");
      Line ("  writeIORef albCompatTick s2");
      Line ("  return (fromIntegral (abs s2 `mod` n))");
      Line ("{-# NOINLINE alb_RND #-}");
      Line ("alb_COLLIDE_RECT ax ay aw ah bx by bw bh =");
      Line ("  albBool (ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by)");
      Line ("alb_SIN deg = round (sin (fromIntegral deg * pi / 180) * 1024) :: ALBVal");
      Line ("alb_COS deg = round (cos (fromIntegral deg * pi / 180) * 1024) :: ALBVal");
      Line ("alb_SQRT v = floor (sqrt (fromIntegral (max 0 v) :: Double)) :: ALBVal");
      Line ("alb_EXP v = floor (exp (fromIntegral v :: Double)) :: ALBVal");
      Line ("albRND = alb_RND");
      Line ("albCOLLIDE_RECT = alb_COLLIDE_RECT");
      Line ("albSIN = alb_SIN");
      Line ("albCOS = alb_COS");
      Line ("albSQRT = alb_SQRT");
      Line ("albEXP = alb_EXP");
      Line ("albLEFT s n = take (fromIntegral (max 0 n)) s");
      Line ("albRIGHT s n = let c = fromIntegral (max 0 n) in if c >= length s then s else drop (length s - c) s");
      Line ("albMID s startAt n =");
      Line ("  let startIx = max 0 (fromIntegral startAt - 1)");
      Line ("      c = fromIntegral (max 0 n)");
      Line ("  in take c (drop startIx s)");
      Line ("albLEN s = fromIntegral (length s) :: ALBVal");
      Line ("albCHR v = [chr (fromIntegral (v .&. 255))]");
      Line ("albASC s = if null s then 0 else fromIntegral (ord (head s) .&. 255)");
      Line ("albCONCAT = (++)");
      Line ("albPRINT_PURE = alb_PRINT");
      Line ("alb_GetTickCount :: IO ALBVal");
      Line ("alb_GetTickCount = do");
      Line ("  ready <- readIORef albSdlReady");
      Line ("  if ready then fmap fromIntegral c_SDL_GetTicks");
      Line ("  else do");
      Line ("    t <- readIORef albCompatTick");
      Line ("    writeIORef albCompatTick (t + 16)");
      Line ("    return (fromIntegral t)");
      Line ("alb_PRED name a b c d = name ++ ""("" ++ show a ++ "","" ++ show b ++ "","" ++ show c ++ "","" ++ show d ++ "")""");
      Line ("alb_PLAY_SOUND _ = return ()");
      Line ("alb_PLAY_MUSIC _ = return ()");
      Line ("alb_PLAY_MUSIC_FROM _ = return ()");
      Line ("alb_MSG_BOX msg title = alb_PRINT (title ++ "": "" ++ msg)");
      Line ("alb_Delay ms = do");
      Line ("  ready <- readIORef albSdlReady");
      Line ("  let m = max 0 (fromIntegral ms) :: Int");
      Line ("  if ready then c_SDL_Delay (fromIntegral m)");
      Line ("  else threadDelay (m * 1000)");
      Line ("alb_CEASE = do");
      Line ("  writeIORef albRunning False");
      Line ("  alb_ProgramShutdown");
      New_Line_Emit;
      New_Line_Emit;
      Line ("albMapGet :: Ord k => IORef (Map.Map k v) -> k -> v -> IO v");
      Line ("albMapGet r k d = Map.findWithDefault d k <$> readIORef r");
      Line ("albMapPut :: Ord k => IORef (Map.Map k v) -> k -> v -> IO ()");
      Line ("albMapPut r k v = modifyIORef' r (Map.insert k v)");
      New_Line_Emit;
      Line ("alb_CLAIM :: IO ALBVal");
      Line ("alb_CLAIM = do");
      Line ("  alive <- readIORef albGcAlive");
      Line ("  let slot = head $ [i | i <- [1..1023], Map.findWithDefault 0 i alive == 0] ++ [0]");
      Line ("  when (slot /= 0) $ do");
      Line ("    albMapPut albGcAlive slot 1");
      Line ("    albMapPut albGcRefs slot 1");
      Line ("    albMapPut albGcChildA slot 0");
      Line ("    albMapPut albGcChildB slot 0");
      Line ("    albMapPut albGcChildC slot 0");
      Line ("    albMapPut albGcChildD slot 0");
      Line ("  return (fromIntegral slot)");
      New_Line_Emit;
      Line ("alb_BIND _parent _c1 _c2 _c3 _c4 = return ()");
      Line ("alb_DROP handle = modifyIORef' albGcRefs (\m -> Map.adjust (\n -> max 0 (n-1)) (fromIntegral handle) m)");
      Line ("alb_SWEEP _ = return ()");
      New_Line_Emit;
      Line ("alb_KNOWS_SET key value = do");
      Line ("  live <- readIORef albFactLive");
      Line ("  keys <- readIORef albFactKey");
      Line ("  let existing = [i | (i,1) <- Map.toList live, Map.lookup i keys == Just key]");
      Line ("  slot <- case existing of");
      Line ("    (i:_) -> return i");
      Line ("    [] -> do");
      Line ("      let free = head ([i | i <- [0..1023], Map.findWithDefault 0 i live == 0] ++ [0])");
      Line ("      return free");
      Line ("  albMapPut albFactLive slot 1");
      Line ("  albMapPut albFactKey slot key");
      Line ("  albMapPut albFactValue slot value");
      New_Line_Emit;
      Line ("alb_KNOWS_GET key = do");
      Line ("  live <- readIORef albFactLive");
      Line ("  keys <- readIORef albFactKey");
      Line ("  vals <- readIORef albFactValue");
      Line ("  let hits = [Map.findWithDefault 0 i vals | (i,1) <- Map.toList live, Map.lookup i keys == Just key]");
      Line ("  return (case hits of (v:_) -> v; [] -> 0)");
      New_Line_Emit;
      Line ("alb_KNOWS_HAS key = do");
      Line ("  live <- readIORef albFactLive");
      Line ("  keys <- readIORef albFactKey");
      Line ("  return (albBool (any (\(i, on) -> on == 1 && Map.lookup i keys == Just key) (Map.toList live)))");
      New_Line_Emit;
      Line ("alb_ASSERT = alb_KNOWS_SET");
      Line ("alb_RETRACT key = do");
      Line ("  live <- readIORef albFactLive");
      Line ("  keys <- readIORef albFactKey");
      Line ("  forM_ [i | (i,1) <- Map.toList live, Map.lookup i keys == Just key] $ \i -> do");
      Line ("    albMapPut albFactLive i 0");
      Line ("    albMapPut albFactKey i """"");
      Line ("    albMapPut albFactValue i 0");
      Line ("alb_UPDATE = alb_KNOWS_SET");
      Line ("alb_PROVE key = alb_KNOWS_HAS key");
      New_Line_Emit;
      Line ("alb_REL_FACT_MATCH slot pred arity a1 a2 a3 a4 = do");
      Line ("  live <- albMapGet albRelLive slot 0");
      Line ("  p <- albMapGet albRelPred slot 0");
      Line ("  ar <- albMapGet albRelArity slot 0");
      Line ("  x1 <- albMapGet albRelArg1 slot 0");
      Line ("  x2 <- albMapGet albRelArg2 slot 0");
      Line ("  x3 <- albMapGet albRelArg3 slot 0");
      Line ("  x4 <- albMapGet albRelArg4 slot 0");
      Line ("  return (live /= 0 && p == pred && ar == arity && x1 == a1 && x2 == a2 && x3 == a3 && x4 == a4)");
      New_Line_Emit;
      Line ("alb_REL_FACT_HAS pred arity a1 a2 a3 a4 = do");
      Line ("  hits <- mapM (\i -> alb_REL_FACT_MATCH i pred arity a1 a2 a3 a4) [0..1023]");
      Line ("  return (albBool (or hits))");
      New_Line_Emit;
      Line ("alb_REL_HAS = alb_REL_FACT_HAS");
      Line ("alb_REL_SET pred arity a1 a2 a3 a4 value = do");
      Line ("  let trySlot i = do");
      Line ("        ok <- alb_REL_FACT_MATCH i pred arity a1 a2 a3 a4");
      Line ("        if ok then do");
      Line ("          albMapPut albRelValue i value");
      Line ("          return True");
      Line ("        else return False");
      Line ("  done <- fmap or $ mapM trySlot [0..1023]");
      Line ("  unless done $ do");
      Line ("    live <- readIORef albRelLive");
      Line ("    let free = head ([i | i <- [0..1023], Map.findWithDefault 0 i live == 0] ++ [0])");
      Line ("    albMapPut albRelLive free 1");
      Line ("    albMapPut albRelPred free pred");
      Line ("    albMapPut albRelArity free arity");
      Line ("    albMapPut albRelArg1 free a1");
      Line ("    albMapPut albRelArg2 free a2");
      Line ("    albMapPut albRelArg3 free a3");
      Line ("    albMapPut albRelArg4 free a4");
      Line ("    albMapPut albRelValue free value");
      New_Line_Emit;
      Line ("alb_REL_RETRACT pred arity a1 a2 a3 a4 = do");
      Line ("  forM_ [0..1023] $ \i -> do");
      Line ("    ok <- alb_REL_FACT_MATCH i pred arity a1 a2 a3 a4");
      Line ("    when ok $ do");
      Line ("      albMapPut albRelLive i 0");
      Line ("      albMapPut albRelPred i 0");
      Line ("      albMapPut albRelArity i 0");
      Line ("      albMapPut albRelArg1 i 0");
      Line ("      albMapPut albRelArg2 i 0");
      Line ("      albMapPut albRelArg3 i 0");
      Line ("      albMapPut albRelArg4 i 0");
      Line ("      albMapPut albRelValue i 0");
      New_Line_Emit;
      Line ("alb_REL_GET_VALUE pred arity a1 a2 a3 a4 = do");
      Line ("  vals <- mapM (\i -> do");
      Line ("    ok <- alb_REL_FACT_MATCH i pred arity a1 a2 a3 a4");
      Line ("    if ok then albMapGet albRelValue i 0 else return (-1)) [0..1023]");
      Line ("  case filter (/= (-1)) vals of");
      Line ("    (v:_) -> return v");
      Line ("    [] -> alb_REL_HAS pred arity a1 a2 a3 a4");
      New_Line_Emit;
      Line ("alb_REL_FIND1 pred = do");
      Line ("  live <- readIORef albRelLive");
      Line ("  preds <- readIORef albRelPred");
      Line ("  a1s <- readIORef albRelArg1");
      Line ("  let hits = [Map.findWithDefault 0 i a1s | (i,1) <- Map.toList live, Map.lookup i preds == Just pred]");
      Line ("  return (case hits of (v:_) -> v; [] -> 0)");
      New_Line_Emit;
      Line ("alb_Open path mode = do");
      Line ("  live <- readIORef albFileLive");
      Line ("  let free = head ([i | i <- [1..63], Map.findWithDefault 0 i live == 0] ++ [0])");
      Line ("  when (free /= 0) $ do");
      Line ("    albMapPut albFileLive free 1");
      Line ("    albMapPut albFileMode free mode");
      Line ("    albMapPut albFileName free path");
      Line ("    albMapPut albFileCursor free 0");
      Line ("    store <- readIORef albSaveStore");
      Line ("    albMapPut albFileBuffer free (Map.findWithDefault """" path store)");
      Line ("  return (fromIntegral free)");
      New_Line_Emit;
      Line ("alb_FileLen path = do");
      Line ("  store <- readIORef albSaveStore");
      Line ("  return (fromIntegral (length (Map.findWithDefault """" path store)))");
      New_Line_Emit;
      Line ("alb_Seek handle offset = do");
      Line ("  albMapPut albFileCursor (fromIntegral handle) (fromIntegral offset)");
      Line ("  return offset");
      New_Line_Emit;
      Line ("alb_Read handle count = do");
      Line ("  buf <- albMapGet albFileBuffer (fromIntegral handle) """"");
      Line ("  cur <- albMapGet albFileCursor (fromIntegral handle) 0");
      Line ("  let chunk = if count <= 0 then drop cur buf else take (fromIntegral count) (drop cur buf)");
      Line ("  albMapPut albFileCursor (fromIntegral handle) (cur + length chunk)");
      Line ("  return chunk");
      New_Line_Emit;
      Line ("alb_Write handle dataText = do");
      Line ("  buf <- albMapGet albFileBuffer (fromIntegral handle) """"");
      Line ("  albMapPut albFileBuffer (fromIntegral handle) (buf ++ dataText)");
      New_Line_Emit;
      Line ("alb_Close handle = do");
      Line ("  name <- albMapGet albFileName (fromIntegral handle) """"");
      Line ("  buf <- albMapGet albFileBuffer (fromIntegral handle) """"");
      Line ("  modifyIORef' albSaveStore (Map.insert name buf)");
      Line ("  albMapPut albFileLive (fromIntegral handle) 0");
      Line ("  albMapPut albFileName (fromIntegral handle) """"");
      Line ("  albMapPut albFileBuffer (fromIntegral handle) """"");
      Line ("  albMapPut albFileCursor (fromIntegral handle) 0");
      New_Line_Emit;
      Line ("alb_LoadTextBuffer path = Map.findWithDefault """" path <$> readIORef albSaveStore");
      Line ("alb_LoadBuffer path = alb_LoadTextBuffer path");
      Line ("alb_FlushBuffer target path = modifyIORef' albSaveStore (Map.insert path target)");
      New_Line_Emit;
      Line ("alb_FIREWALL_TOUCH_READ _ = return ()");
      Line ("alb_FIREWALL_TOUCH_WRITE _ = return ()");
      Line ("alb_FIREWALL_READ _ v = v");
      Line ("alb_FIREWALL_WRITE _ v = v");
      Line ("alb_FIREWALL_ENTER fw = modifyIORef' albFirewallStack (fw:)");
      Line ("alb_FIREWALL_LEAVE = modifyIORef' albFirewallStack (\xs -> case xs of (_:t) -> t; [] -> [])");
      New_Line_Emit;
      Line ("alb_COMPAT_IMPORT _lib symbol _args = do");
      Line ("  t <- readIORef albCompatTick");
      Line ("  writeIORef albCompatTick (t + 16)");
      Line ("  return (fromIntegral t)");
      New_Line_Emit;
      Line ("alb_MAKE_CELL v = mkRef (v :: ALBVal)");
      Line ("alb_BUFFER_BYTE buf index = alb_arrGet buf (fromIntegral index)");
      Line ("alb_BUFFER_PACK_LE buf start size =");
      Line ("  sum [alb_arrGet buf (fromIntegral start + i) * (256 ^ i) | i <- [0 .. fromIntegral size - 1]]");
      New_Line_Emit;
      Line ("alb_DEFINE_SYSTEM_FONT name size _w _aa _cs _ce = return (fromIntegral size)");
      Line ("alb_DEFINE_BITMAP_FONT name _src _fmt gw gh _fc _sp = return (fromIntegral (gw * gh))");
      Line ("alb_SET_FONT _ = return ()");
      Line ("alb_INI_BIND _path _text _table = return (0 :: ALBVal)");
      Line ("alb_EXPORT_PPM _surface _path _format = return (0 :: ALBVal)");
      Line ("alb_SNIFFER_DEFINE _iface _proto _port _buf = do");
      Line ("  h <- readIORef albNextSnifferHandle");
      Line ("  writeIORef albNextSnifferHandle (h + 1)");
      Line ("  return (fromIntegral h)");
      Line ("alb_SNIFFER_CAPTURE _sniffer _dest = return (0 :: ALBVal)");
      New_Line_Emit;
      Line ("alb_STATIC_RGB565 rgb =");
      Line ("  let v = albU32 rgb");
      Line ("      r = shiftR ((shiftR v 16) .&. 255) 3");
      Line ("      g = shiftR ((shiftR v 8) .&. 255) 2");
      Line ("      b = shiftR (v .&. 255) 3");
      Line ("  in ((r `shiftL` 11) .|. (g `shiftL` 5) .|. b) .&. 0xffff");
      Line ("alb_STATIC_SURFACE w h = return (fromIntegral (max 1 w * max 1 h))");
      Line ("alb_STATIC_VIEWPORT x y w h = return (fromIntegral x)");
      Line ("alb_STATIC_EMPTY_SPRITE fw fh frames = return (fromIntegral (fw * fh * frames))");
      Line ("alb_STATIC_SPRITE_FROM_BMP _bytes fw fh frames = alb_STATIC_EMPTY_SPRITE fw fh frames");
      Line ("alb_STATIC_APPLY_LUT lut visual context used = do");
      Line ("  writeIORef alb_STATIC_Active_Lut (Just lut)");
      Line ("  writeIORef alb_STATIC_Active_Visual visual");
      Line ("  writeIORef alb_STATIC_Active_Context context");
      Line ("  writeIORef alb_STATIC_Active_Context_Used used");
      Line ("alb_STATIC_BLIT _vis _ctx _used _tgt _x _y _vp _am = return ()");
      New_Line_Emit;
      Line ("alb_MARKOV_PREDICT _model currentState = return currentState");
      Line ("alb_NN_ACT code value =");
      Line ("  case code of");
      Line ("    1 -> if value > 0 then value else 0");
      Line ("    2 -> if value > 0 then 1 else 0");
      Line ("    3 -> if value > 128 then 1024 else if value < (-128) then (-1024) else value * 8");
      Line ("    _ -> value");
      Line ("alb_NN_CREATE _name _sizes _acts = return (0 :: ALBVal)");
      Line ("alb_NN_INFER _model _input _output = return ()");
      Line ("alb_NN_TRAIN _model _train _expect _epochs = return ()");
      New_Line_Emit;
      Line ("alb_NET_DEFINE protocol port bufferSize = do");
      Line ("  h <- readIORef albNextNetworkHandle");
      Line ("  writeIORef albNextNetworkHandle (h + 1)");
      Line ("  albMapPut albNetworkTable h (show protocol ++ "":"" ++ show port ++ "":"" ++ show bufferSize)");
      Line ("  return (fromIntegral h)");
      Line ("alb_NET_LISTEN _ = return ()");
      Line ("alb_NET_ACCEPT handle = alb_NET_DEFINE 0 0 256");
      Line ("alb_NET_RECEIVE _handle _dest = return ()");
      Line ("alb_NET_SEND _handle _src = return ()");
      Line ("alb_NET_CLOSE handle = modifyIORef' albNetworkTable (Map.delete (fromIntegral handle))");
      New_Line_Emit;
      Line ("alb_PROCESS_DEFINE image _rights pid = do");
      Line ("  h <- readIORef albNextProcessHandle");
      Line ("  writeIORef albNextProcessHandle (h + 1)");
      Line ("  albMapPut albProcessTable h (image ++ "":"" ++ show pid)");
      Line ("  return (fromIntegral h)");
      Line ("alb_PROCESS_CREATE image args = alb_PROCESS_DEFINE image [] 0");
      Line ("alb_PROCESS_READ_SCALAR _handle addr = do");
      Line ("  vas <- readIORef albVas");
      Line ("  return (Map.findWithDefault 0 (fromIntegral addr) vas)");
      Line ("alb_PROCESS_WRITE_SCALAR _handle addr value = albMapPut albVas (fromIntegral addr) value");
      Line ("alb_PROCESS_READ_BUFFER handle addr target = return ()");
      Line ("alb_PROCESS_MONITOR handle addr outTarget changed = do");
      Line ("  value <- alb_PROCESS_READ_SCALAR handle addr");
      Line ("  albSet outTarget value");
      Line ("  albSet changed 0");
      Line ("alb_PROCESS_DUMP _h _a _s _p = return ()");
      Line ("alb_FILE_XOR src key outPath = do");
      Line ("  store <- readIORef albSaveStore");
      Line ("  let s = Map.findWithDefault """" src store");
      Line ("      k = if null key then ""0"" else key");
      Line ("      out = zipWith (\c kc -> chr (ord c `xor` ord kc)) s (cycle k)");
      Line ("  writeIORef albSaveStore (Map.insert outPath out store)");
      Line ("alb_PROCESS_ELEVATE _ = return ()");
      Line ("alb_PROCESS_SNIFF _source _target = return ()");
      New_Line_Emit;
      Line ("alb_PEEK :: ALBVal -> ALBVal");
      Line ("alb_PEEK addr = unsafePerformIO (alb_PROCESS_READ_SCALAR 0 addr)");
      Line ("{-# NOINLINE alb_PEEK #-}");
      Line ("alb_DEREF addr = alb_PEEK addr");
      Line ("alb_POKE addr value = alb_PROCESS_WRITE_SCALAR 0 addr value");
      New_Line_Emit;
      Line ("alb_MainLoop :: IO ()");
      Line ("alb_MainLoop = go");
      Line ("  where");
      Line ("    go = do");
      Line ("      running <- readIORef albRunning");
      Line ("      when running $ do");
      Line ("        still <- alb_Poll_Events");
      Line ("        unless still alb_ProgramShutdown");
      Line ("        running2 <- readIORef albRunning");
      Line ("        when running2 $ do");
      Line ("          now <- alb_GetTickCount");
      Line ("          delayUntil <- fmap fromIntegral (readIORef albDelayUntil)");
      Line ("          when (now >= delayUntil) $ do");
      Line ("            lastF <- fmap fromIntegral (readIORef albLastFrame)");
      Line ("            interval <- fmap fromIntegral (readIORef albFrameInterval)");
      Line ("            when (now - lastF >= interval) $ do");
      Line ("              writeIORef albLastFrame (fromIntegral now)");
      Line ("              alb_PREPARE_FRAME");
      Line ("              tick <- readIORef alb_ON_TICK");
      Line ("              tick");
      Line ("              writeIORef albMouseWheel 0");
      Line ("              paint <- readIORef alb_ON_PAINT");
      Line ("              paint");
      Line ("              keyh <- readIORef alb_ON_KEY");
      Line ("              keyh");
      Line ("              alb_PRESENT");
      Line ("          remTicks <- do");
      Line ("            lastF <- fmap fromIntegral (readIORef albLastFrame)");
      Line ("            interval <- fmap fromIntegral (readIORef albFrameInterval)");
      Line ("            now2 <- alb_GetTickCount");
      Line ("            return (interval - (now2 - lastF))");
      Line ("          when (remTicks > 1) $ do");
      Line ("            ready <- readIORef albSdlReady");
      Line ("            if ready then c_SDL_Delay (fromIntegral remTicks)");
      Line ("            else writeIORef albDelayUntil (fromIntegral (now + remTicks))");
      Line ("          go");
      Line ("      alb_ProgramShutdown");
      New_Line_Emit;
      Line ("alb_RunFrame :: IO ()");
      Line ("alb_RunFrame = alb_MainLoop");
      New_Line_Emit;
   end Emit_Runtime;


   function HSImport_Alias (Binding : Foreign_Binding_Record) return String is
   begin
      return "__alb_imp_" & Safe_HS_Name (To_String (Binding.HS_Name));
   end HSImport_Alias;

   procedure Emit_Module_Imports is
   begin
      if not Need_Module_Support then
         return;
      end if;

      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Link_Kind = Foreign_ES then
            Line ("import { " & To_String (Foreign_Imports (I).Name) &
                  " as " & HSImport_Alias (Foreign_Imports (I)) &
                  " } from " &
                  Escape_HS_String (HSImport_Specifier (To_String (Foreign_Imports (I).Path))) &
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
            Line ("response = await fetch(" &
                  Escape_HS_String (HSImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                  ");");
            Line ("if (!response.ok) alb_FATAL(`WASM fetch failed for " &
                  To_String (Foreign_Imports (I).Name) & ": ${response.status}`);");
            Line ("bytes = await response.arrayBuffer();");
            Line ("result = await WebAssembly.instantiate(bytes, alb_WASM_HOST_IMPORTS as WebAssembly.Imports);");
            Line ("exportsTable = result.instance.exports as Record<string, unknown>;");
            Line ("fn = exportsTable[" &
                  Escape_HS_String (To_String (Foreign_Imports (I).Name)) & "];");
            Line ("if (typeof fn /= 'function') alb_FATAL('Missing WASM export: " &
                  To_String (Foreign_Imports (I).Name) & "');");
            Line ("albWasmBindings[" &
                  Escape_HS_String (To_String (Foreign_Imports (I).HS_Name)) &
                  "] = fn as (...args[]) => any;");
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
               Line ("alb_WASM_HOST_IMPORTS.alb[" &
                     Escape_HS_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args[]) => (" &
                     To_String (Foreign_Exports (I).HS_Name) &
                     ")(...args);");
            end if;
         end loop;
         Line ("export { alb_WASM_HOST_IMPORTS };");
         New_Line_Emit;
      end if;

      if Any_Compat_Exports then
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_Compat then
               Line ("albCompatExports[" &
                     Escape_HS_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args[]) => (" &
                     To_String (Foreign_Exports (I).HS_Name) &
                     ")(...args);");
            end if;
         end loop;
         Line ("Object.assign(globalThis as Record<string, unknown>, albCompatExports);");
         New_Line_Emit;
      end if;

      if Any_ES_Exports then
         --  Emit one export per line so full-engine libraries (~1k+ symbols)
         --  do not produce a single multi-megabyte export { Ã¢â‚¬Â¦ } statement.
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_ES then
               Line ("export { " &
                     To_String (Foreign_Exports (I).HS_Name) & " as " &
                     To_String (Foreign_Exports (I).Name) & " };");
            end if;
         end loop;
         New_Line_Emit;
      end if;
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
      Emit ("" & To_String (Binding.HS_Name) & "(");
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Param_Node := Tree (List_Node).Left_Child;
         while Param_Node > 0 loop
            if Tree (Param_Node).Kind = AST_Param_Decl then
               declare
                  Param_Name : constant String := Safe_HS_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
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
                     Emit (Param_Name & ": { value: " & Primitive_HS_Type (Param_Tag) & " }");
                     Has_Out := True;
                  else
                     Emit (Param_Name & ": " & Primitive_HS_Type (Param_Tag));
                  end if;
                  First := False;
               end;
            end if;
            Param_Node := Tree (Param_Node).Next_Sibling;
         end loop;
      end if;

      if Binding.Is_Function then
         Emit ("): " & Primitive_HS_Type (Binding.Return_Tag) & " {");
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
                          Safe_HS_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index)));
                  First := False;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         if Has_Out then
            Line ("alb_WARN_ONCE(" &
                  Escape_HS_String ("foreign-out-" & To_String (Binding.Name)) & ", " &
                  Escape_HS_String ("ALBH passes OUT parameters to foreign imports as { value } boxes; the callee must mutate .value to write back") &
                  ")");
         end if;

         if Binding.Link_Kind = Foreign_ES then
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     HSImport_Alias (Binding) & "(" & To_String (Call_Args) & ")"));
            else
               Line (HSImport_Alias (Binding) & "(" & To_String (Call_Args) & ")");
            end if;
         elsif Binding.Link_Kind = Foreign_WASM then
            Line ("__alb_wasm_fn = albWasmBindings[" &
                  Escape_HS_String (To_String (Binding.HS_Name)) & "];");
            Line ("if (typeof __alb_wasm_fn /= 'function') alb_FATAL('WASM import not ready: " &
                  To_String (Binding.Name) & "');");
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "__alb_wasm_fn(" & To_String (Call_Args) & ")"));
            else
               Line ("__alb_wasm_fn(" & To_String (Call_Args) & ")");
            end if;
         else
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "alb_COMPAT_IMPORT(" &
                     Escape_HS_String (To_String (Binding.Path)) & ", " &
                     Escape_HS_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ")"));
            else
               Line ("alb_COMPAT_IMPORT(" &
                     Escape_HS_String (To_String (Binding.Path)) & ", " &
                     Escape_HS_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ")");
            end if;
         end if;
      end;

      if not Binding.Is_Function then
         Line ("pure ()");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
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
            Line (Const_Name & " = alb_new_array([0]);");
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
            Emit ("const " & Const_Name & " = alb_new_array([");
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
            Emit ("]);");
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
         Line (Const_Name & " = alb_new_array([0]);");
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
            Escape_HS_String (To_String (Content)));
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
         Line (Const_Name & " = """";");
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
            return "ALB_ARR|" & To_String (Sym.HS_Name) & "|" &
              Build_Array_Index (Sym.Dims, Sym.Rank, Node.Left_Child);
         elsif Sym.Active then
            return To_String (Sym.HS_Name);
         else
            return Scoped_Name (Raw);
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
                     return "ALB_ARR|" & To_String (Symbols (Field_Sym_Id).HS_Name) & "|" &
                       Build_Array_Index
                         (Symbols (Field_Sym_Id).Dims,
                          Symbols (Field_Sym_Id).Rank,
                          Left_Node.Left_Child);
                  end if;
               end;
            end if;

            if Right_Node.Kind = AST_Var_Expr
              and then Right_Node.Left_Child > 0
              and then Group_Sym.Active
              and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               return "ALB_ARR|" & To_String (Group_Sym.HS_Name) & "|" &
                 Build_Array_Index (Group_Sym.Dims, Group_Sym.Rank, Right_Node.Left_Child);
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               return To_String (Left_Sym.HS_Name) & "." & Safe_HS_Name (Right_Name);
            elsif Group_Sym.Active then
               return To_String (Group_Sym.HS_Name);
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
            return To_String (Sym.HS_Name);
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
               return Firewall_Key_For_Symbol (Sym, To_String (Sym.HS_Name));
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
               return Firewall_Key_For_Symbol (Group_Sym, To_String (Group_Sym.HS_Name));
            elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               if To_String (Left_Sym.Scope) /= "" then
                  return "";
               else
                  return To_String (Left_Sym.HS_Name) & "." & Safe_HS_Name (Right_Name);
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
      if (not Need_Firewall_Runtime) or else Key'Length = 0 then
         return Value_Text;
      else
         return "(alb_FIREWALL_READ " & Escape_HS_String (Key) & " (" & Value_Text & "))";
      end if;
   end Wrap_Firewall_Read;

   function Wrap_Firewall_Write
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if (not Need_Firewall_Runtime) or else Key'Length = 0 then
         return Value_Text;
      else
         return "(alb_FIREWALL_WRITE " & Escape_HS_String (Key) & " (" & Value_Text & "))";
      end if;
   end Wrap_Firewall_Write;

   procedure Emit_Firewall_Touch
     (Node_Index_Value : Node_Index;
      Need_Read        : Boolean;
      Need_Write       : Boolean) is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return;
      end if;

      if Need_Read then
         Line ("alb_FIREWALL_TOUCH_READ (" & Escape_HS_String (Key) & ")");
      end if;

      if Need_Write then
         Line ("alb_FIREWALL_TOUCH_WRITE (" & Escape_HS_String (Key) & ")");
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
      Old_Phase   : constant Emit_Phase_Kind := Emit_Phase;
      Fn_Name     : constant String := Name & "_Handler";
   begin
      if Count = 0 then
         return;
      end if;

      Emit_Phase := Phase_All;
      Current_Routine := U (Fn_Name);
      Line (Fn_Name & " :: IO ()");
      Line (Fn_Name & " = albRunProc $ do");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Count loop
         Emit_Block (Blocks (I));
      end loop;
      Line ("pure ()");
      Indent_Level := Indent_Level - 1;
      New_Line_Emit;
      Current_Routine := Old_Routine;
      Emit_Phase := Old_Phase;
   end Emit_Event_Handler;

   procedure Emit_Event_Registrations is
   begin
      if Tick_Block_Count > 0 then
         Line ("writeIORef alb_ON_TICK alb_ON_TICK_Handler");
      end if;
      if Paint_Block_Count > 0 then
         Line ("writeIORef alb_ON_PAINT alb_ON_PAINT_Handler");
      end if;
      if Key_Block_Count > 0 then
         Line ("writeIORef alb_ON_KEY alb_ON_KEY_Handler");
      end if;
   end Emit_Event_Registrations;

   procedure Emit_Address_Routines is
      procedure Emit_Struct_Field_Cases
        (Base_HS      : String;
         Struct_Name  : String;
         Base_Offset  : Integer;
         For_Write    : Boolean) is
      begin
         for I in 1 .. Field_Count loop
            if Fields (I).Active
              and then To_String (Fields (I).Struct_Name) = Struct_Name
            then
               if For_Write then
                  Line ("if (a == " &
                        Trim_Image (Base_Offset + Fields (I).Offset_Bytes) & ") { " &
                        Field_Write_Expr (Base_HS, I, Cast_Expr (Fields (I).Tag, "value")) &
                        "; return; }");
               else
                  Line ("if (a == " &
                        Trim_Image (Base_Offset + Fields (I).Offset_Bytes) & ") return " &
                        Field_Read_Expr (Base_HS, I));
               end if;
            end if;
         end loop;
      end Emit_Struct_Field_Cases;
   begin
      New_Line_Emit;
      Line ("alb_PEEK(addr): ALBVal {");
      Indent_Level := Indent_Level + 1;
      Line ("a = addr | 0;");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Offset_Bytes > 0
         then
            declare
               Base_HS  : constant String := To_String (Symbols (I).HS_Name);
               Base_Off : constant Integer := Symbols (I).Offset_Bytes;
               Elem     : constant Integer := Element_Bytes (Symbols (I).Tag);
               Span     : constant Integer := Integer'Max (1, Symbols (I).Capacity) * Elem;
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line ("if (a == " & Trim_Image (Base_Off) & ") return " & Base_HS);
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("if (a >= " & Trim_Image (Base_Off) & " && a < " &
                           Trim_Image (Base_Off + Span) & " && ((a - " &
                           Trim_Image (Base_Off) & ") % " & Trim_Image (Elem) &
                           ") == 0) return " & Base_HS & "[truncate((a - " &
                           Trim_Image (Base_Off) & ") / " & Trim_Image (Elem) & ")];");
                  when Sym_Temporal =>
                     Line ("if (a == " & Trim_Image (Base_Off) & ") return " & Base_HS);
                     if Symbols (I).Aux_Offset > 0 and then Symbols (I).History_Size > 0 then
                        Line ("if (a >= " & Trim_Image (Symbols (I).Aux_Offset) & " && a < " &
                              Trim_Image (Symbols (I).Aux_Offset + Symbols (I).History_Size * Elem) &
                              " && ((a - " & Trim_Image (Symbols (I).Aux_Offset) & ") % " &
                              Trim_Image (Elem) & ") == 0) return " & Base_HS &
                              "_history[truncate((a - " & Trim_Image (Symbols (I).Aux_Offset) &
                              ") / " & Trim_Image (Elem) & ")];");
                     end if;
                  when Sym_Struct_Var =>
                     Emit_Struct_Field_Cases
                       (Base_HS,
                        Safe_HS_Name (To_String (Symbols (I).Struct_Name)),
                        Base_Off,
                        False);
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Line ("return 0;");
      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
      Line ("alb_DEREF(addr): ALBVal { return alb_PEEK(addr); }");
      Line ("alb_POKE(addr, value: ALBVal) {");
      Indent_Level := Indent_Level + 1;
      Line ("a = addr | 0;");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Offset_Bytes > 0
         then
            declare
               Base_HS  : constant String := To_String (Symbols (I).HS_Name);
               Base_Off : constant Integer := Symbols (I).Offset_Bytes;
               Elem     : constant Integer := Element_Bytes (Symbols (I).Tag);
               Span     : constant Integer := Integer'Max (1, Symbols (I).Capacity) * Elem;
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line ("if (a == " & Trim_Image (Base_Off) & ") { " & Base_HS & " = " &
                           Cast_Expr (Symbols (I).Tag, "value") & "; return; }");
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("if (a >= " & Trim_Image (Base_Off) & " && a < " &
                           Trim_Image (Base_Off + Span) & " && ((a - " &
                           Trim_Image (Base_Off) & ") % " & Trim_Image (Elem) &
                           ") == 0) { " & Base_HS & "[truncate((a - " &
                           Trim_Image (Base_Off) & ") / " & Trim_Image (Elem) &
                           ")] = " & Cast_Expr (Symbols (I).Tag, "value") & "; return; }");
                  when Sym_Temporal =>
                     Line ("if (a == " & Trim_Image (Base_Off) & ") { " & Base_HS & " = " &
                           Cast_Expr (Symbols (I).Tag, "value") & "; return; }");
                     if Symbols (I).Aux_Offset > 0 and then Symbols (I).History_Size > 0 then
                        Line ("if (a >= " & Trim_Image (Symbols (I).Aux_Offset) & " && a < " &
                              Trim_Image (Symbols (I).Aux_Offset + Symbols (I).History_Size * Elem) &
                              " && ((a - " & Trim_Image (Symbols (I).Aux_Offset) & ") % " &
                              Trim_Image (Elem) & ") == 0) { " & Base_HS &
                              "_history[truncate((a - " & Trim_Image (Symbols (I).Aux_Offset) &
                              ") / " & Trim_Image (Elem) & ")] = " &
                              Cast_Expr (Symbols (I).Tag, "value") & "; return; }");
                     end if;
                  when Sym_Struct_Var =>
                     Emit_Struct_Field_Cases
                       (Base_HS,
                        Safe_HS_Name (To_String (Symbols (I).Struct_Name)),
                        Base_Off,
                        True);
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
      New_Line_Emit;
   end Emit_Address_Routines;

   procedure Emit_State_Routines is
      procedure Emit_String_Array_Load
        (Target_Name : String;
         Source_Expr : String) is
      begin
         Line ("if (" & Source_Expr & ") { for (let i = 0; i < " & Target_Name &
               ".length && i < " & Source_Expr &
               ".length; i++) " & Target_Name & "[i] = albText (" & Source_Expr &
               "[i] ?? """"); }");
      end Emit_String_Array_Load;
   begin
      New_Line_Emit;
      Line ("alb_SAVE_STATE() {");
      Indent_Level := Indent_Level + 1;
      Line ("state = {");
      Indent_Level := Indent_Level + 1;
      Line ("vas: Array.from(albVas),");
      Line ("gcAlive: Array.from(albGcAlive),");
      Line ("gcRefs: Array.from(albGcRefs),");
      Line ("gcChildA: Array.from(albGcChildA),");
      Line ("gcChildB: Array.from(albGcChildB),");
      Line ("gcChildC: Array.from(albGcChildC),");
      Line ("gcChildD: Array.from(albGcChildD),");
      Line ("factLive: Array.from(albFactLive),");
      Line ("factKey: albFactKey.slice(),");
      Line ("factValue: albFactValue.slice(),");
      Line ("relLive: Array.from(albRelLive),");
      Line ("relPred: Array.from(albRelPred),");
      Line ("relArity: Array.from(albRelArity),");
      Line ("relArg1: Array.from(albRelArg1),");
      Line ("relArg2: Array.from(albRelArg2),");
      Line ("relArg3: Array.from(albRelArg3),");
      Line ("relArg4: Array.from(albRelArg4),");
      Line ("relValue: Array.from(albRelValue),");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
         then
            declare
               Name : constant String := To_String (Symbols (I).HS_Name);
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line (Name & ": " & Name & ",");
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line (Name & ": " & Name & ".slice(),");
                     else
                        Line (Name & ": Array.from(" & Name & "),");
                     end if;
                     if Symbols (I).Kind = Sym_Slide_Array then
                        Line (Name & "_active: " & Name & "_active,");
                     end if;
                  when Sym_Temporal =>
                     Line (Name & ": " & Name & ",");
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line (Name & "_history: " & Name & "_history.slice(),");
                     else
                        Line (Name & "_history: Array.from(" & Name & "_history),");
                     end if;
                     Line (Name & "_head: " & Name & "_head,");
                  when Sym_Struct_Var =>
                     Line (Name & ": " & Name & ",");
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
      Line ("albSaveStore['alb_state'] = JSON.stringify(state);");
      Indent_Level := Indent_Level - 1;
      Line ("pure ()");

      Line ("alb_LOAD_STATE() {");
      Indent_Level := Indent_Level + 1;
      Line ("raw = albSaveStore['alb_state'];");
      Line ("if (!raw) return;");
      Line ("state = JSON.parse(raw);");
      Line ("if (state.vas) albVas.set(state.vas as ArrayLike<number>);");
      Line ("if (state.gcAlive) albGcAlive.set(state.gcAlive as ArrayLike<number>);");
      Line ("if (state.gcRefs) albGcRefs.set(state.gcRefs as ArrayLike<number>);");
      Line ("if (state.gcChildA) albGcChildA.set(state.gcChildA as ArrayLike<number>);");
      Line ("if (state.gcChildB) albGcChildB.set(state.gcChildB as ArrayLike<number>);");
      Line ("if (state.gcChildC) albGcChildC.set(state.gcChildC as ArrayLike<number>);");
      Line ("if (state.gcChildD) albGcChildD.set(state.gcChildD as ArrayLike<number>);");
      Line ("if (state.factLive) albFactLive.set(state.factLive as ArrayLike<number>);");
      Emit_String_Array_Load ("albFactKey", "state.factKey");
      Line ("if (state.factValue) { for (let i = 0; i < albFactValue.length && i < state.factValue.length; i++) albFactValue[i] = state.factValue[i] as ALBVal; }");
      Line ("if (state.relLive) albRelLive.set(state.relLive as ArrayLike<number>);");
      Line ("if (state.relPred) albRelPred.set(state.relPred as ArrayLike<number>);");
      Line ("if (state.relArity) albRelArity.set(state.relArity as ArrayLike<number>);");
      Line ("if (state.relArg1) albRelArg1.set(state.relArg1 as ArrayLike<number>);");
      Line ("if (state.relArg2) albRelArg2.set(state.relArg2 as ArrayLike<number>);");
      Line ("if (state.relArg3) albRelArg3.set(state.relArg3 as ArrayLike<number>);");
      Line ("if (state.relArg4) albRelArg4.set(state.relArg4 as ArrayLike<number>);");
      Line ("if (state.relValue) albRelValue.set(state.relValue as ArrayLike<number>);");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
         then
            declare
               Name : constant String := To_String (Symbols (I).HS_Name);
               Hist : constant String := Trim_Image (Integer'Max (1, Symbols (I).History_Size));
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line ("if (state." & Name & " /= Nothing) " & Name & " = albText (state." & Name & ")");
                     elsif Symbols (I).Tag = VK_Boolean then
                        Line ("if (state." & Name & " /= Nothing) " & Name & " = albTruthy (state." & Name & ")");
                     else
                        Line ("if (state." & Name & " /= Nothing) " & Name & " = " &
                              Cast_Expr (Symbols (I).Tag, "state." & Name));
                     end if;
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Emit_String_Array_Load (Name, "state." & Name);
                     else
                        Line ("if (state." & Name & ") " & Name &
                              ".set(state." & Name & " as ArrayLike<number>);");
                     end if;
                     if Symbols (I).Kind = Sym_Slide_Array then
                        Line ("if (state." & Name & "_active /= Nothing) " & Name &
                              "_active = state." & Name & "_active | 0;");
                     end if;
                  when Sym_Temporal =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line ("if (state." & Name & " /= Nothing) " & Name & " = albText (state." & Name & ")");
                        Emit_String_Array_Load (Name & "_history", "state." & Name & "_history");
                     elsif Symbols (I).Tag = VK_Boolean then
                        Line ("if (state." & Name & " /= Nothing) " & Name & " = albTruthy (state." & Name & ")");
                        Line ("if (state." & Name & "_history) " & Name &
                              "_history.set((state." & Name & "_history as ArrayLike<number>));");
                     else
                        Line ("if (state." & Name & " /= Nothing) " & Name & " = " &
                              Cast_Expr (Symbols (I).Tag, "state." & Name));
                        Line ("if (state." & Name & "_history) " & Name &
                              "_history.set((state." & Name & "_history as ArrayLike<number>));");
                     end if;
                     Line ("if (state." & Name & "_head /= Nothing) " & Name &
                           "_head = ((state." & Name & "_head | 0) % " & Hist & " + " & Hist & ") % " & Hist);
                  when Sym_Struct_Var =>
                     Line ("if (state." & Name & " /= Nothing) " & Name &
                           " = state." & Name & " as typeof " & Name);
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
      New_Line_Emit;
   end Emit_State_Routines;

   procedure Emit_Logic_Setup is
   begin
      if Rule_Node_Count = 0 and Watch_Node_Count = 0 then
         return;
      end if;

      Line ("alb_INIT_LOGIC() {");
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
      Line ("pure ()");
      New_Line_Emit;

      Line ("alb_NOTIFY_KNOWS_CHANGE = (pred, arg1, arg2, arg3, arg4) => {");
      Indent_Level := Indent_Level + 1;

      if Watch_Node_Count = 0 then
         Line ("pure ()");
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
               Var_HS     : constant String := Safe_HS_Name (Var_Name);
               Shadow_Id  : Natural := 0;
            begin
               Line ("case " & Predicate_Id_Expr (Pred_Node) & ": {");
               Indent_Level := Indent_Level + 1;
               if Var_Name'Length > 0 then
                  Line (Var_HS & " = arg1 | 0;");
                  Shadow_Id :=
                    Push_Shadow_Symbol
                      (Scope   => "",
                       Name    => Var_Name,
                       HS_Name => Var_HS,
                       Tag     => VK_Number);
               end if;
               Emit_Block (Body_Node);
               if Shadow_Id > 0 then
                  Pop_Shadow_Symbol (Shadow_Id);
               end if;
               Line ("pure ()  -- break approximated");
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
            end;
         end loop;

         Line ("default:");
         Indent_Level := Indent_Level + 1;
         Line ("pure ()  -- break approximated");
         Indent_Level := Indent_Level - 1;
         Indent_Level := Indent_Level - 1;
         Line ("pure ()");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
      New_Line_Emit;
      Line ("alb_INIT_LOGIC();");
      New_Line_Emit;
   end Emit_Logic_Setup;

   procedure Emit_Switch_Stmt
     (Expr_Node      : Node_Index;
      First_Case     : Node_Index) is
      Switch_Value : constant String := Next_Temp_Name ("switch_value");
      Curr_Case    : Node_Index := First_Case;
      First        : Boolean := True;
      Saw_Else     : Boolean := False;
   begin
      Line ("case " & Expr (Expr_Node) & " of");
      Indent_Level := Indent_Level + 1;

      while Curr_Case > 0 loop
         if Tree (Curr_Case).Left_Child = 0 then
            Line ("_ -> do");
            Saw_Else := True;
         else
            Line (Expr (Tree (Curr_Case).Left_Child) & " -> do");
         end if;
         Indent_Level := Indent_Level + 1;
         Emit_Block (Tree (Curr_Case).Right_Child);
         Line ("pure ()");
         Indent_Level := Indent_Level - 1;
         Curr_Case := Tree (Curr_Case).Next_Sibling;
         First := False;
      end loop;

      -- Only one wildcard default; skip if ELSE already emitted `_`.
      if not Saw_Else then
         Line ("_ -> pure ()");
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
      Line ("if (" & Count_Name & " > 0) {");
      Indent_Level := Indent_Level + 1;
      Line (Swap_Index & " = " & Target_Index);
      Line (Last_Index & " = (" & Count_Name & " - 1);");
      Line ("if (" & Swap_Index & " /= " & Last_Index & ") {");
      Indent_Level := Indent_Level + 1;

      if Target_AST.Kind = AST_Var_Expr and then Target_AST.Left_Child > 0 then
         if Target_Sym.Active
           and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
         then
            Line (To_String (Target_Sym.HS_Name) & "[" & Swap_Index & "] = " &
                  To_String (Target_Sym.HS_Name) & "[" & Last_Index & "];");
            Found_Field := True;
         else
            for I in 1 .. Symbol_Count loop
               if Symbols (I).Active
                 and then Symbols (I).Kind = Sym_Parallel_Field
                 and then
                   (Starts_With (To_String (Symbols (I).Name), Scoped_Group & ".")
                    or else Starts_With (To_String (Symbols (I).Name), Raw_Name & "."))
               then
                  Line (To_String (Symbols (I).HS_Name) & "[" & Swap_Index & "] = " &
                        To_String (Symbols (I).HS_Name) & "[" & Last_Index & "];");
                  Found_Field := True;
               end if;
            end loop;
         end if;
      end if;

      if not Found_Field then
         Line ("-- SWAPPOP target could not be resolved statically");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
      Line (Count_Name & " -= 1;");
      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
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
               then Find_Field (To_String (Left_Sym.Struct_Name), Safe_HS_Name (Raw_Lexeme (Right_Node.Token_Index)))
               else 0);
         begin
            if Field_Id /= 0 and then Fields (Field_Id).Bit_Width > 0 then
               Line (Field_Write_Expr (To_String (Left_Sym.HS_Name), Field_Id, Value_Text));
               return;
            end if;
         end;
      end if;

      if Declare_New then
         --  Top-level: unsafePerformIO mkRef. Inside routines/boot: newIORef in do-block.
         if Length (Current_Routine) > 0 or else Emit_Phase = Phase_Boot then
            Line (Target_Name & " <- newIORef (" & Base_Value_Text & ")");
         else
            Line (Target_Name & " :: IORef " & Primitive_HS_Type (Decl_Tag));
            Line (Target_Name & " = mkRef (" & Base_Value_Text & ")");
            Line ("{-# NOINLINE " & Target_Name & " #-}");
         end if;
      else
         if Ada.Strings.Fixed.Index (Target_Name, "ALB_ARR|") = Target_Name'First then
            declare
               Rest  : constant String :=
                 Target_Name (Target_Name'First + 8 .. Target_Name'Last);
               Bar   : constant Natural := Ada.Strings.Fixed.Index (Rest, "|");
               Arr   : constant String := Rest (Rest'First .. Bar - 1);
               Idx   : constant String := Rest (Bar + 1 .. Rest'Last);
            begin
               Line ("albRefArrSet " & Arr & " (" & Idx & ") (" & Value_Text & ")");
            end;
         else
            Line ("albSet " & Target_Name & " (" & Value_Text & ")");
         end if;
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
      Struct_Name : constant String := Safe_HS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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
                     Field_Name := U (Safe_HS_Name (Raw_Lexeme (Tree (Field_Node.Left_Child).Token_Index)));
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
                        Field_Name := U (Safe_HS_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)));
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
                  Fields (Field_Count).HS_Field := Field_Name;
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
         HS_Name   : constant String :=
           (if Upper_Text (Func_Name) = "GETTICKCOUNT"
            then "alb_User_GetTickCount"
            else Scoped_Name (Func_Name));
      begin
         Register_Routine (Func_Name, HS_Name, Param_Count, Modes);
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
                     Current_Module := U (Safe_HS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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
      HS_Name      : constant String :=
        (if Upper_Text (Func_Name) = "GETTICKCOUNT"
         then "alb_User_GetTickCount"
         else Scoped_Name (Func_Name));
      Old_Routine  : constant Unbounded_String := Current_Routine;
      Old_Emitting_Function : constant Boolean := Current_Emitting_Function;
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

      Current_Routine := U (HS_Name);
      Current_Emitting_Function := Is_Function;
      Current_Routine_Out_Count := 0;

      if Is_Function and then Node.Token_Index > 0 then
         Return_Type := Type_From_Token (Node.Token_Index);
         if Return_Type = VK_Unknown then
            Return_Type := VK_Number;
         end if;
      end if;

      --  Collect params first for a proper Haskell type signature.
      List_Node := Tree (Name_Node).Right_Child;
      declare
         Type_Parts : Unbounded_String := U ("");
         Arg_Parts  : Unbounded_String := U ("");
      begin
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
                        then "__out_" & Safe_HS_Name (Param_Name)
                        else Safe_HS_Name (Param_Name));
                     Ty              : constant String :=
                       (if Mode = Param_Out
                        then "(IORef " & Primitive_HS_Type (Param_Kind) & ")"
                        else Primitive_HS_Type (Param_Kind));
                  begin
                     if Length (Type_Parts) > 0 then
                        Append (Type_Parts, " -> ");
                        Append (Arg_Parts, " ");
                     end if;
                     Append (Type_Parts, Ty);
                     Append (Arg_Parts, Decl_Name);
                     if Mode = Param_Out then
                        if Current_Routine_Out_Count < Max_Params then
                           Current_Routine_Out_Count := Current_Routine_Out_Count + 1;
                           Current_Routine_Out_Names (Current_Routine_Out_Count) :=
                             U (Safe_HS_Name (Param_Name));
                        end if;
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

         if Length (Type_Parts) > 0 then
            Append (Type_Parts, " -> ");
         end if;
         if Is_Function then
            Append (Type_Parts, Primitive_HS_Type (Return_Type));
         else
            Append (Type_Parts, "IO ()");
         end if;

         Line (HS_Name & " :: " & To_String (Type_Parts));
         if Length (Arg_Parts) > 0 then
            if Is_Function then
               Line (HS_Name & " " & To_String (Arg_Parts) &
                     " = unsafePerformIO $ albRunFn $ do");
            else
               Line (HS_Name & " " & To_String (Arg_Parts) & " = albRunProc $ do");
            end if;
         else
            if Is_Function then
               Line (HS_Name & " = unsafePerformIO $ albRunFn $ do");
            else
               Line (HS_Name & " = albRunProc $ do");
            end if;
         end if;
      end;
      Indent_Level := Indent_Level + 1;

      Register_Routine (Func_Name, HS_Name, Param_Count, Modes);

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
                  Decl_Name       : constant String := Safe_HS_Name (Param_Name);
               begin
                  Register_Symbol
                    (Scope => HS_Name,
                     Name => Param_Name,
                     HS_Name => Decl_Name,
                     Tag => Param_Kind,
                     Kind => Sym_Param);
                  if Mode = Param_Out then
                     Line (Decl_Name & ": " & Primitive_HS_Type (Param_Kind) &
                           " = __out_" & Decl_Name & ".value;");
                  end if;
               end;
            elsif Tree (Curr_Param).Kind = AST_Require_Clause then
               Line ("if (!albTruthy (" & Expr (Tree (Curr_Param).Left_Child) &
                     ")) { alb_FATAL('REQUIRE failed'); }");
            elsif Tree (Curr_Param).Kind = AST_Bound_To_Clause then
               Bound_Node := Curr_Param;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      declare
         Old_Phase : constant Emit_Phase_Kind := Emit_Phase;
      begin
      Emit_Phase := Phase_All;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Line ("alb_FIREWALL_ENTER (" & Expr (Tree (Bound_Node).Left_Child) & ")");
         Line ("do");
         Indent_Level := Indent_Level + 1;
      end if;

      -- ALBH hot path: mesh FillTriangle/Render via SDL3 PAINTER_MESH.
      if HS_Name'Length >= 13
        and then HS_Name (HS_Name'Last - 12 .. HS_Name'Last) = "_FillTriangle"
      then
         Line ("alb_COLOR ccol");
         Line ("alb_FILL_TRIANGLE x1 y1 x2 y2 x3 y3");
      elsif HS_Name = "strawBerry_Render" or else HS_Name = "StrawBerry_Render" then
         Line ("let !cam_z' = cam_z; !scale' = scale; !yaw' = rot_yaw; !pitch' = rot_pitch; !cx' = cx; !cy' = cy");
         Line ("alb_PAINTER_MESH strawBerry_SB_v_x strawBerry_SB_v_y strawBerry_SB_v_z " &
               "strawBerry_SB_f_p1 strawBerry_SB_f_p2 strawBerry_SB_f_p3 strawBerry_SB_f_col " &
               "(albGet strawBerry_SB_v_count) (albGet strawBerry_SB_f_count) " &
               "yaw' pitch' cam_z' scale' cx' cy' 144");
      elsif HS_Name = "ant_Render" or else HS_Name = "Ant_Render" then
         Line ("let !cam_z' = cam_z; !scale' = scale; !yaw' = rot_yaw; !pitch' = rot_pitch; !cx' = cx; !cy' = cy");
         Line ("alb_PAINTER_MESH ant_ANT_v_x ant_ANT_v_y ant_ANT_v_z " &
               "ant_ANT_f_p1 ant_ANT_f_p2 ant_ANT_f_p3 ant_ANT_f_col " &
               "(albGet ant_ANT_v_count) (albGet ant_ANT_f_count) " &
               "yaw' pitch' cam_z' scale' cx' cy' 0");
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
                  Param_Name : constant String := Safe_HS_Name (Raw_Lexeme (Tree (Param_Name_Node).Token_Index));
               begin
                  if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then
                     Line ("albSet __out_" & Param_Name & " (albGet " & Param_Name & ")");
                  end if;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      Line ("pure ()");

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Indent_Level := Indent_Level - 1;
         Line ("alb_FIREWALL_LEAVE");
      end if;

      Emit_Phase := Old_Phase;
      end;

      Indent_Level := Indent_Level - 1;
      if Is_Function then
         Line ("{-# NOINLINE " & HS_Name & " #-}");
      end if;
      New_Line_Emit;

      Current_Routine := Old_Routine;
      Current_Emitting_Function := Old_Emitting_Function;
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
          declare
            Args_Joined : constant String := Join_Arg_List (Arg_List);
         begin
            if Args_Joined'Length = 0 then
               Line (Target_Name);
            else
               Line (Target_Name & " " & Args_Joined);
            end if;
         end;
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
                  Append (Call_Args, " ");
               end if;
               Append (Call_Args, To_String (Args (I)));
            end loop;
            if Length (Call_Args) = 0 then
               Line (Target_Name);
            else
               Line (Target_Name & " " & To_String (Call_Args));
            end if;
         end;
         return;
      end if;

      Line ("do");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line ("__out_" & Trim_Image (Integer (I)) & " = { value: " &
                  To_String (Targets (I)) & " };");
         end if;
      end loop;

      declare
         Call_Args : Unbounded_String := U ("");
      begin
         for I in 1 .. Param_No loop
            if I > 1 then
               Append (Call_Args, " ");
            end if;
            Append (Call_Args, To_String (Args (I)));
         end loop;
         if Length (Call_Args) = 0 then
            Line (Target_Name);
         else
            Line (Target_Name & " " & To_String (Call_Args));
         end if;
      end;

      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line (To_String (Targets (I)) & " = __out_" & Trim_Image (Integer (I)) & ".value;");
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("pure ()");
   end Emit_Call_With_Out;

   function Is_Decl_Kind (Kind : Node_Kind) return Boolean is
   begin
      case Kind is
         when AST_Procedure_Decl | AST_Function_Decl
            | AST_Strict_Stmt | AST_Slide_Stmt | AST_Parallel_Decl
            | AST_Temporal_Decl | AST_Struct_Decl | AST_Static_Sprite_Decl
            | AST_DeclareModule | AST_Import | AST_Import_C | AST_Include_Stmt
            | AST_Version | AST_Range_Type_Decl
            | AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar
            | AST_Import_ES | AST_Import_WASM
            | AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar
            | AST_Export_ES | AST_Export_WASM
            | AST_Set_Shoebox_Stmt | AST_Module =>
            return True;
         when others =>
            return False;
      end case;
   end Is_Decl_Kind;

   function Is_Executable_Top_Kind (Kind : Node_Kind) return Boolean is
   begin
      --  Opposite of pure decls: anything that produces IO at top level.
      return not Is_Decl_Kind (Kind)
        or else Kind = AST_Module
        or else Kind = AST_On_Block;
   end Is_Executable_Top_Kind;

   procedure Emit_Node (Index : Node_Index) is
      Node : constant AST_Node := Tree (Index);
      Target_Node : Node_Index := 0;
      Value_Node  : Node_Index := 0;
      Raw_Name    : Unbounded_String := U ("");
      HS_Name     : Unbounded_String := U ("");
      Sym_Id      : Natural := 0;
      Tag         : Value_Kind := VK_Number;
      Dims        : Dim_List := (others => 0);
      Rank        : Natural := 0;
      Capacity    : Integer := 0;
   begin
      --  Top-level phase filter (bodies use Phase_All).
      if Emit_Phase = Phase_Decls then
         if Node.Kind not in
              AST_Program | AST_Block_Stmt | AST_Module
            | AST_Procedure_Decl | AST_Function_Decl
            | AST_Strict_Stmt | AST_Slide_Stmt | AST_Parallel_Decl
            | AST_Temporal_Decl | AST_Struct_Decl | AST_Static_Sprite_Decl
            | AST_Let_Stmt | AST_On_Block
            | AST_DeclareModule | AST_Import | AST_Import_C | AST_Include_Stmt
            | AST_Version | AST_Range_Type_Decl
            | AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar
            | AST_Import_ES | AST_Import_WASM
            | AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar
            | AST_Export_ES | AST_Export_WASM
            | AST_Set_Shoebox_Stmt
         then
            return;
         end if;
      elsif Emit_Phase = Phase_Boot then
         if Node.Kind in
              AST_Procedure_Decl | AST_Function_Decl
            | AST_Strict_Stmt | AST_Slide_Stmt | AST_Parallel_Decl
            | AST_Temporal_Decl | AST_Struct_Decl | AST_Static_Sprite_Decl
            | AST_On_Block
         then
            return;
         end if;
      end if;

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
                  Current_Module := U (Safe_HS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
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
               Sprite_HS    : constant String := Scoped_Name (Sprite_Name);
               Setting      : Node_Index := Node.Right_Child;
               Source_Path  : Unbounded_String := U ("");
               Frame_Width  : Integer := 1;
               Frame_Height : Integer := 1;
               Frame_Count  : Integer := 1;
               Format_Text  : Unbounded_String := U ("INDEXED8BIT");
               Saw_Format   : Boolean := False;
               Embed_Name   : constant String := "__alb_bmp_" & Safe_HS_Name (Sprite_HS);
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

               Register_Symbol ("", Sprite_HS, Sprite_HS, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-sprite-default-format",
                                  "STATIC_SPRITE without FORMAT defaults to INDEXED8BIT on ALBH");
               elsif To_String (Format_Text) /= "INDEXED8BIT" then
                  Emit_Warn_Once ("static-sprite-format-" & Safe_HS_Name (To_String (Format_Text)),
                                  "STATIC_SPRITE format " & To_String (Format_Text) &
                                  " is approximated as INDEXED8BIT on ALBH");
               end if;
               if Length (Source_Path) > 0 then
                  Emit_Embedded_File_Bytes (Embed_Name, To_String (Source_Path));
               else
                  Emit_Warn_Once ("static-sprite-missing-source-" & Safe_HS_Name (Sprite_HS),
                                  "STATIC_SPRITE without SOURCE becomes a blank sprite on ALBH");
                  Line (Embed_Name & " = alb_new_array([0]);");
               end if;
               Line (Sprite_HS & " = alb_STATIC_SPRITE_FROM_BMP(" &
                     Embed_Name & ", " & Trim_Image (Frame_Width) & ", " &
                     Trim_Image (Frame_Height) & ", " & Trim_Image (Frame_Count) & ")");
               New_Line_Emit;
            end;

         when AST_Static_Surface_Decl =>
            declare
               Name_Node   : constant Node_Index := Node.Left_Child;
               Surface_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Surface_HS   : constant String := Scoped_Name (Surface_Name);
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

               Register_Symbol ("", Surface_HS, Surface_HS, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-surface-default-format",
                                  "STATIC_SURFACE without FORMAT defaults to RGB565 on ALBH");
               elsif To_String (Format_Text) /= "RGB565" then
                  Emit_Warn_Once ("static-surface-format-" & Safe_HS_Name (To_String (Format_Text)),
                                  "STATIC_SURFACE format " & To_String (Format_Text) &
                                  " is approximated as RGB565 on ALBH");
               end if;
               Line (Surface_HS & " = alb_STATIC_SURFACE(" &
                     Trim_Image (Width_Val) & ", " & Trim_Image (Height_Val) & ")");
               New_Line_Emit;
            end;

         when AST_Color_Lut_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               LUT_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               LUT_HS    : constant String := Scoped_Name (LUT_Name);
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

               Register_Symbol ("", LUT_HS, LUT_HS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ( LUT_HS & " = alb_new_array([");
               for I in Values'Range loop
                  if not First then
                     Emit (", ");
                  end if;
                  Emit (Trim_Image (Values (I)));
                  First := False;
               end loop;
               Emit ("]);");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Visual_Rule_Decl =>
            declare
               Name_Node  : constant Node_Index := Node.Left_Child;
               Rule_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Rule_HS    : constant String := Scoped_Name (Rule_Name);
               Param_List : constant Node_Index := Tree (Name_Node).Right_Child;
               Param_Node : constant Node_Index :=
                 (if Param_List > 0 and then Tree (Param_List).Kind = AST_Arg_List
                  then Tree (Param_List).Left_Child
                  else 0);
               Param_Name : constant String :=
                 (if Param_Node > 0 then Safe_HS_Name (Raw_Feature_Atom (Param_Node)) else "_alb_context");
               Clause     : Node_Index := Node.Right_Child;
            begin
               Register_Symbol ("", Rule_HS, Rule_HS, VK_Number, Sym_Scalar);
               Line (Rule_HS & " = {");
               Indent_Level := Indent_Level + 1;
               Line ("kind = ""visualRule"",");
               Line ("name: " & Escape_HS_String (Rule_Name) & ",");
               Line ("resolve: (" & Param_Name & ") => {");
               Indent_Level := Indent_Level + 1;
               while Clause > 0 loop
                  if Tree (Clause).Kind = AST_Visual_When_Clause then
                     Line ("if albTruthy (" & Expr (Tree (Clause).Left_Child) & ") then do");
                     Indent_Level := Indent_Level + 1;
                     Line ("return { sprite: " & Expr (Tree (Clause).Right_Child) &
                           ", frame: " & Expr (Tree (Tree (Clause).Right_Child).Next_Sibling) & " };");
                     Indent_Level := Indent_Level - 1;
                     Line ("pure ()");
                  elsif Tree (Clause).Kind = AST_Visual_Default_Clause then
                     Line ("return { sprite: " & Expr (Tree (Clause).Left_Child) &
                           ", frame: " & Expr (Tree (Clause).Right_Child) & " };");
                  end if;
                  Clause := Tree (Clause).Next_Sibling;
               end loop;
               Line ("return { sprite: 0, frame: 0 };");
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
               New_Line_Emit;
            end;

         when AST_Render_Viewport_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               View_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               View_HS   : constant String := Scoped_Name (View_Name);
               Setting   : constant Node_Index := Node.Right_Child;
               X_Node    : constant Node_Index := Tree (Setting).Left_Child;
               Y_Node    : constant Node_Index := Tree (Setting).Right_Child;
               W_Node    : constant Node_Index := (if Y_Node > 0 then Tree (Y_Node).Next_Sibling else 0);
               H_Node    : constant Node_Index := (if W_Node > 0 then Tree (W_Node).Next_Sibling else 0);
            begin
               Register_Symbol ("", View_HS, View_HS, VK_Number, Sym_Scalar);
               Line (View_HS & " = alb_STATIC_VIEWPORT(" &
                     Expr (X_Node) & ", " & Expr (Y_Node) & ", " &
                     Expr (W_Node) & ", " & Expr (H_Node) & ")");
               New_Line_Emit;
            end;

         when AST_Bitmap_Font_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Font_Name      : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Font_HS        : constant String := Scoped_Name (Font_Name);
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

               Register_Symbol ("", Font_HS, Font_HS, VK_U64, Sym_Scalar);
               if Length (Descriptor_Text) > 0 then
                  Emit_Warn_Once ("bitmap-font-descriptor-" & Safe_HS_Name (Font_HS),
                                  "BITMAP_FONT descriptor metadata is accepted but canvas text remains an approximation on ALBH");
               end if;
               Line (Font_HS & " = alb_DEFINE_BITMAP_FONT(" &
                     Escape_HS_String (Font_Name) & ", " &
                     (if Length (Source_Text) > 0 then To_String (Source_Text) else Escape_HS_String ("")) & ", " &
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
               Font_HS         : constant String := Scoped_Name (Font_Name);
               Setting         : Node_Index := Node.Right_Child;
               Family_Text     : Unbounded_String := U (Escape_HS_String (Font_Name));
               Size_Text       : Unbounded_String := U ("16");
               Weight_Text     : Unbounded_String := U (Escape_HS_String ("normal"));
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

               Register_Symbol ("", Font_HS, Font_HS, VK_U64, Sym_Scalar);
               Line (Font_HS & " = alb_DEFINE_SYSTEM_FONT(" &
                     To_String (Family_Text) & ", " &
                     To_String (Size_Text) & ", " &
                     To_String (Weight_Text) & ", " &
                     "(albTruthy (" & To_String (Anti_Alias_Text) & "))" & ", " &
                     To_String (Charset_Start) & ", " &
                     To_String (Charset_End) & ")");
               New_Line_Emit;
            end;

         when AST_Memory_Firewall_Decl =>
            Need_Firewall_Runtime := True;
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               FW_HS     : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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
                              Append (Read_Text, Escape_HS_String (Key));
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
                              Append (Write_Text, Escape_HS_String (Key));
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

               Register_Symbol ("", FW_HS, FW_HS, VK_Number, Sym_Scalar);
               Line (FW_HS & " = { kind = ""firewall"", name: " &
                     Escape_HS_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
                     ", denyAll: " & (if Deny_All then "True" else "False") &
                     ", read: new Set<string>([" & To_String (Read_Text) &
                     "]), write: new Set<string>([" & To_String (Write_Text) & "]) };");
               New_Line_Emit;
            end;

         when AST_Process_Handle_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Proc_HS   : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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
                              Append (Rights_Text, Escape_HS_String (Raw_Feature_Atom (Right_Node)));
                              First_Right := False;
                              Right_Node := Tree (Right_Node).Next_Sibling;
                           end loop;
                        end;
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Proc_HS, Proc_HS, VK_U64, Sym_Scalar);
               Line (Proc_HS & " = alb_PROCESS_DEFINE(" &
                     To_String (Image_Text) & ", [" &
                     To_String (Rights_Text) & "], " & To_String (Pid_Text) & ")");
               New_Line_Emit;
            end;

         when AST_Network_Sniffer_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Sniffer_Name   : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Sniffer_HS     : constant String := Scoped_Name (Sniffer_Name);
               Error_HS       : constant String := Scoped_Name (Sniffer_Name & "_ERROR");
               Setting        : Node_Index := Node.Right_Child;
               Interface_Text : Unbounded_String := U (Escape_HS_String ("any"));
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

               Register_Symbol ("", Sniffer_HS, Sniffer_HS, VK_U64, Sym_Scalar);
               Register_Symbol ("", Error_HS, Error_HS, VK_U64, Sym_Scalar);
               Emit_Warn_Once ("network-sniffer-albh",
                               "NETWORK_SNIFFER is simulated on ALBH with deterministic sample packets");
               Line (Error_HS & " = alb_MAKE_CELL(0);");
               Line (Sniffer_HS & " = alb_SNIFFER_DEFINE(" &
                     To_String (Interface_Text) & ", " &
                     To_String (Protocol_Text) & ", " &
                     To_String (Port_Text) & ", " &
                     To_String (Buffer_Text) & ")");
               Line (Sniffer_HS & "_errorCell = " & Error_HS);
               New_Line_Emit;
            end;

         when AST_Network_Socket_Decl =>
            declare
               Name_Node    : constant Node_Index := Node.Left_Child;
               Socket_HS    : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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

               Register_Symbol ("", Socket_HS, Socket_HS, VK_U64, Sym_Scalar);
               Line (Socket_HS & " = alb_NET_DEFINE(" &
                     To_String (Protocol_Code) & ", " & To_String (Port_Val) & ", " &
                     To_String (Buffer_Val) & ")");
               New_Line_Emit;
            end;

         when AST_Markov_Model_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Model_HS  : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
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

               Register_Symbol ("", Model_HS, Model_HS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ( Model_HS & " = { states: " & To_String (States_Text) & ", matrix: [");
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
               Net_HS    : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Layer_Node : Node_Index := Node.Right_Child;
               First     : Boolean := True;
               First_Act : Boolean := True;
            begin
               Register_Symbol ("", Net_HS, Net_HS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ( Net_HS & " = alb_NN_CREATE(" &
                     Escape_HS_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
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
                  HS_Name := U (Safe_HS_Name (R (R'First + 1 .. R'Last)));
                  Capacity := Eval_Static_Int (Value_Node);
                  Existing := Find_Symbol ("", To_String (HS_Name));
                  if Existing = 0 then
                     --  Use let so later #CONST redefinitions (common across
                     --  engine modules) can reassign under ES module mode.
                     Register_Symbol
                       ("", To_String (HS_Name), To_String (HS_Name),
                        VK_Number, Sym_Const, Capacity => Capacity);
                     Line (To_String (HS_Name) &
                           " = " & Expr (Value_Node));
                  else
                     Symbols (Existing).Capacity := Capacity;
                     Line (To_String (HS_Name) & " = " & Expr (Value_Node));
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
                  HS_Name := U (Safe_HS_Name (To_String (Raw_Name)));
                  declare
                     Existing : constant Natural :=
                       Find_Symbol ("", To_String (HS_Name));
                  begin
                     if Existing = 0 then
                        Register_Symbol
                          ("", To_String (HS_Name), To_String (HS_Name),
                           VK_Number, Sym_Const, Capacity => Value);
                        Line (To_String (HS_Name) &
                              " = " & Trim_Image (Value));
                     else
                        Symbols (Existing).Capacity := Value;
                        Line (To_String (HS_Name) & " = " &
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
               Struct_Name : constant String := Safe_HS_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
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
                          (Safe_HS_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)) &
                           ": " &
                           (if Tree (Curr).Token_Index > 0
                            then Type_Annotation_From_Name (Raw_Lexeme (Tree (Curr).Token_Index))
                            else "number"));
                     else
                        Emit ("alb_missing_field");
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
               HS_Name := U (Scoped_Name (To_String (Raw_Name)));
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
               Register_Symbol ("", To_String (HS_Name), To_String (HS_Name), Tag, Sym_Strict_Array, Rank, Dims, Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               Line (To_String (HS_Name) & " :: IORef ALBMap");
               Line (To_String (HS_Name) & " = mkRef (alb_new_array (" &
                     Trim_Image (Capacity) & ") " &
                     (if Tag in VK_String | VK_Binary then "0" else "0") & ")");
               Line ("{-# NOINLINE " & To_String (HS_Name) & " #-}");
            end if;

         when AST_Slide_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               HS_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0
                       then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                       else VK_Number);
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (HS_Name), To_String (HS_Name), Tag, Sym_Slide_Array, 1, (1 => Capacity, others => 0), Capacity,
                                Active_Size => (if Tree (Node.Right_Child).Next_Sibling > 0 then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling) else Capacity),
                                Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)));
               Line (To_String (HS_Name) & " :: IORef ALBMap");
               Line (To_String (HS_Name) & " = mkRef (alb_new_array (" &
                     Trim_Image (Capacity) & ") 0)");
               Line ("{-# NOINLINE " & To_String (HS_Name) & " #-}");
               Line (To_String (HS_Name) & "_active :: IORef Integer");
               Line (To_String (HS_Name) & "_active = mkRef (" &
                     Trim_Image ((if Tree (Node.Right_Child).Next_Sibling > 0
                                  then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling)
                                  else Capacity)) & ")");
               Line ("{-# NOINLINE " & To_String (HS_Name) & "_active #-}");
            end if;

         when AST_Parallel_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               HS_Name := U (Scoped_Name (To_String (Raw_Name)));
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
                        Field_HS        : constant String := Safe_HS_Name (To_String (Raw_Name) & "_" & Field_Name);
                        Field_Tag       : constant Value_Kind :=
                          (if Tree (Field_Name_Node).Right_Child > 0
                           then Type_From_Name (Raw_Lexeme (Tree (Tree (Field_Name_Node).Right_Child).Token_Index))
                           else VK_Number);
                     begin
                        Register_Symbol ("", To_String (HS_Name) & "." & Field_Name, Field_HS, Field_Tag,
                                         Sym_Parallel_Field, Rank, Dims, Capacity,
                                         Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Field_Tag)));
                        Line (Field_HS & " :: IORef ALBMap");
                        Line (Field_HS & " = mkRef (alb_new_array (" &
                              Trim_Image (Capacity) & ") 0)");
                        Line ("{-# NOINLINE " & Field_HS & " #-}");
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
               HS_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := VK_Number;
               end if;
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (HS_Name), To_String (HS_Name), Tag, Sym_Temporal,
                                History_Size => Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (Tag)));
               declare
                  TId : constant Natural := Find_Symbol ("", To_String (HS_Name));
               begin
                  if TId /= 0 then
                     Symbols (TId).Aux_Offset := Allocate_Address_Bytes (Capacity * Element_Bytes (Tag));
                  end if;
               end;
               Line (To_String (HS_Name) & " :: IORef " & Primitive_HS_Type (Tag));
               Line (To_String (HS_Name) & " = mkRef (" &
                     Cast_Expr (Tag, Expr (Tree (Node.Right_Child).Next_Sibling)) & ")");
               Line ("{-# NOINLINE " & To_String (HS_Name) & " #-}");
               Line (To_String (HS_Name) & "_history :: IORef ALBMap");
               Line (To_String (HS_Name) & "_history = mkRef (alb_new_array (" &
                     Trim_Image (Capacity) & ") 0)");
               Line ("{-# NOINLINE " & To_String (HS_Name) & "_history #-}");
               Line (To_String (HS_Name) & "_head :: IORef Integer");
               Line (To_String (HS_Name) & "_head = mkRef 0");
               Line ("{-# NOINLINE " & To_String (HS_Name) & "_head #-}");
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
                        Plain_Id  : constant Natural := Find_Symbol ("", Safe_HS_Name (To_String (Raw_Name)));
                     begin
                        if Global_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Global_Id).Tag, False);
                        elsif Plain_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Plain_Id).Tag, False);
                        else
                           Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_HS_Name (To_String (Raw_Name)), Tag, Sym_Scalar);
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
                           Struct_Name : constant String := Safe_HS_Name (Raw_Lexeme (Node.Token_Index));
                           SIdx : constant Natural := Find_Struct (Struct_Name);
                        begin
                           Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Struct_Var,
                                            Struct_Name => Raw_Lexeme (Node.Token_Index),
                                            Offset_Bytes => (if SIdx /= 0 then Allocate_Address_Bytes (Structs (SIdx).Size_Bytes) else 0));
                        end;
                        declare
                           Struct_Name : constant String := Safe_HS_Name (Raw_Lexeme (Node.Token_Index));
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
                                            To_String (Fields (I).HS_Field) & ": " &
                                            Default_Value
                                              (Fields (I).Tag,
                                               To_String (Fields (I).Type_Name)));
                                    Curr := Curr + 1;
                                 end if;
                              end loop;
                           end if;
                           Line
                             ("var " & Scoped_Name (To_String (Raw_Name)) &
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
            if Current_Emitting_Function then
               if Node.Left_Child > 0 then
                  Line ("albReturn (" & Expr (Node.Left_Child) & ")");
               else
                  Line ("albReturn 0");
               end if;
            else
               Line ("albProcReturn");
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
               Line ("if albTruthy (" & Expr (Node.Left_Child) & ") then do");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("else do");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
                  Line ("pure ()");
               else
                  Line ("pure ()");
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
                                  "STRIDE nesting beyond 32 levels falls back to normal FOR stepping on ALBH");
                  Emit_Block (Body_Node);
               end if;
            end;

         when AST_Ratio_Space_Block =>
            Emit_Warn_Once ("ratio-space-albh",
                            "RATIO_SPACE pinning is approximated as ordinary Haskell evaluation on ALBH");
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
               Line ("do");
               Indent_Level := Indent_Level + 1;
               Line (Width_Name & " = max(1, albNum (" & To_String (Width_Text) & ") | 0);");
               Line (Height_Name & " = max(1, albNum (" & To_String (Height_Text) & ") | 0);");
               Line (Limit_Name & " = max(" & Width_Name & ", " & Height_Name & ")");
               Line ("for (let " & Code_Name & " = 0, " & Seen_Name & " = 0; " &
                     Seen_Name & " < (" & Width_Name & " * " & Height_Name & "); " &
                     Code_Name & " += 1) {");
               Indent_Level := Indent_Level + 1;
               Line (X_Name & " = 0;");
               Line (Y_Name & " = 0;");
               Line (Bits_Name & " = " & Code_Name);
               Line ("for (let " & Shift_Name & " = 0; " & Shift_Name & " < 16; " & Shift_Name & " += 1) {");
               Indent_Level := Indent_Level + 1;
               Line (X_Name & " |= (" & Bits_Name & " & 1) << " & Shift_Name);
               Line (Bits_Name & " = " & Bits_Name & " >>> 1;");
               Line (Y_Name & " |= (" & Bits_Name & " & 1) << " & Shift_Name);
               Line (Bits_Name & " = " & Bits_Name & " >>> 1;");
               Line ("if ((1 << (" & Shift_Name & " + 1)) > " & Limit_Name & " && " & Bits_Name & " == 0) break;");
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
               Line ("if (" & X_Name & " >= " & Width_Name & " || " & Y_Name & " >= " & Height_Name & ") continue;");
               Line ("MTX = " & X_Name);
               Line ("MTY = " & Y_Name);
               Line (Seen_Name & " += 1;");
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
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
               Line ("if albTruthy (" & Expr (Node.Left_Child) & ") then do");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Then_Block);
               Indent_Level := Indent_Level - 1;
               if Else_Block > 0 then
                  Line ("else do");
                  Indent_Level := Indent_Level + 1;
                  Emit_Block (Else_Block);
                  Indent_Level := Indent_Level - 1;
                  Line ("pure ()");
               else
                  Line ("else pure ()");
               end if;
            end;

         when AST_While_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
            begin
               Line (Guard_Name & " <- newIORef (0 :: Int)");
               Line ("albWhile");
               Line ("  (do");
               Indent_Level := Indent_Level + 1;
               Line ("g <- readIORef " & Guard_Name);
               Line ("when (g > 500000) (alb_FATAL ""ALBH while guard"")");
               Line ("writeIORef " & Guard_Name & " (g + 1)");
               Line ("return (albTruthy (" & Expr (Node.Left_Child) & "))");
               Indent_Level := Indent_Level - 1;
               Line ("  )");
               Line ("  (do");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Node.Right_Child);
               Line ("return ()");
               Indent_Level := Indent_Level - 1;
               Line ("  )");
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
               Loop_Var   : constant String := Safe_HS_Name (Var_Name);
               Step_Name  : constant String := Next_Temp_Name ("for_step");
               Loop_Name  : constant String := Next_Temp_Name ("for_loop");
            begin
               Raw_Name := U (Var_Name);
               if Find_Symbol (To_String (Current_Routine), To_String (Raw_Name)) = 0
                 and then Find_Symbol ("", Scoped_Name (To_String (Raw_Name))) = 0
               then
                  if Length (Current_Routine) > 0 then
                     Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Loop_Var, VK_Number, Sym_Scalar);
                     Line (Loop_Var & " :: IORef Integer");
                     Line (Loop_Var & " = mkRef (" & Cast_Expr (VK_Number, Start_Expr) & ")");
                     Line ("{-# NOINLINE " & Loop_Var & " #-}");
                  else
                     Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line (Scoped_Name (To_String (Raw_Name)) & " :: IORef Integer");
                     Line (Scoped_Name (To_String (Raw_Name)) & " = mkRef (" & Cast_Expr (VK_Number, Start_Expr) & ")");
                     Line ("{-# NOINLINE " & Scoped_Name (To_String (Raw_Name)) & " #-}");
                  end if;
               end if;

               Line ("let " & Step_Name & " = " & Step_Expr);
               Line ("    " & Loop_Name & " = do");
               Indent_Level := Indent_Level + 1;
               Line ("i <- readIORef " & Loop_Var);
               Line ("let step = " & Step_Name);
               Line ("    done = if step >= 0 then i > (" & End_Expr & ") else i < (" & End_Expr & ")");
               Line ("unless done $ do");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Node.Right_Child);
               Line ("writeIORef " & Loop_Var & " (i + step)");
               Line (Loop_Name);
               Indent_Level := Indent_Level - 1;
               Indent_Level := Indent_Level - 1;
               Line ("in " & Loop_Name);
            end;

         when AST_Foreach_Stmt =>
            declare
               Iterator_Raw  : constant String := Raw_Lexeme (Node.Token_Index);
               Iterator_HS   : constant String := Safe_HS_Name (Iterator_Raw);
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
                  then "(albGet " & To_String (Sequence_Sym.HS_Name) & "_active)"
                  else "Map.size " & Seq_Name);
            begin
               Line (Seq_Name & " <- return (" & Expr (Sequence_Node) & ")");
               Line (Length_Name & " <- return (" & Sequence_Len & ")");
               Line ("forM_ [0 .. (" & Length_Name & " - 1)] $ \" & Index_Name & " -> do");
               Indent_Level := Indent_Level + 1;
               Line (Iterator_HS & " <- newIORef (" &
                     Cast_Expr (Item_Tag, "alb_arrGet " & Seq_Name & " " & Index_Name) & ")");
               Shadow_Id :=
                 Push_Shadow_Symbol
                   (Scope   => Iterator_Scope,
                    Name    => Iterator_Raw,
                    HS_Name => Iterator_HS,
                    Tag     => Item_Tag);
               Emit_Block (Node.Right_Child);
               Pop_Shadow_Symbol (Shadow_Id);
               Indent_Level := Indent_Level - 1;
            end;

         when AST_Repeat_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
               Loop_Name  : constant String := Next_Temp_Name ("repeat_loop");
            begin
               Line (Guard_Name & " <- newIORef (0 :: Int)");
               Line ("let " & Loop_Name & " = do");
               Indent_Level := Indent_Level + 1;
               Line ("g <- readIORef " & Guard_Name);
               Line ("when (g > 500000) (alb_FATAL ""ALBH loop guard"")");
               Line ("writeIORef " & Guard_Name & " (g + 1)");
               Emit_Block (Node.Left_Child);
               Line ("unless (albTruthy (" & Expr (Node.Right_Child) & ")) " & Loop_Name);
               Indent_Level := Indent_Level - 1;
               Line ("in " & Loop_Name);
            end;

         when AST_Break_Stmt =>
            Line ("pure ()  -- break approximated");

         when AST_Continue_Stmt =>
            Line ("pure ()  -- continue approximated");

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
                  Line ("-- unsupported ON event for HS backend: " &
                        Token_Kind'Image (Tokens (Node.Token_Index).Kind) & ")");
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
            Line ("do");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            Line ("pure ()");

         when AST_Find_Query | AST_Query | AST_Knows_Query =>
            Line (Expr (Index));

         when AST_Create_Window =>
            Saw_Create := True;
            declare
               Title_Node : constant Node_Index := Node.Left_Child;
               Pair_Node  : constant Node_Index := Node.Right_Child;
            begin
               Line ("alb_CREATE_WINDOW (" &
                     Expr (Title_Node) & ") (" &
                     Expr (Tree (Pair_Node).Left_Child) & ") (" &
                     Expr (Tree (Pair_Node).Right_Child) & ")");
            end;

         when AST_Set_Fullscreen =>
            Line ("alb_SET_FULLSCREEN (albTruthy (" & Expr (Node.Left_Child) & "));");

         when AST_Set_Resizable =>
            Line ("alb_SET_RESIZABLE (albTruthy (" & Expr (Node.Left_Child) & "));");

         when AST_Set_Stretchy =>
            Line ("alb_SET_STRETCHY (albTruthy (" & Expr (Node.Left_Child) & "));");

         when AST_Tick =>
            Line ("writeIORef albFrameInterval (max 1 (fromIntegral (" &
                  Expr (Node.Left_Child) & ")))");

         when AST_Color =>
            Line ("alb_COLOR (" & Expr (Node.Left_Child) & ")");

         when AST_Clear =>
            Line ("alb_CLEAR (" & Expr (Node.Left_Child) & ")");

         when AST_Use_Font_Stmt =>
            Line ("alb_SET_FONT (" & Expr (Node.Left_Child) & ")");

         when AST_Apply_Lut_Stmt =>
            declare
               Visual_Node : constant Node_Index := Node.Right_Child;
               With_Node   : constant Node_Index :=
                 (if Visual_Node > 0 and then Tree (Visual_Node).Next_Sibling > 0
                  and then Tree (Tree (Visual_Node).Next_Sibling).Kind = AST_With_Clause
                  then Tree (Visual_Node).Next_Sibling
                  else 0);
            begin
               Line ("alb_STATIC_APPLY_LUT(" &
                     Expr (Node.Left_Child) & ", " &
                     Expr (Visual_Node) & ", " &
                     (if With_Node > 0 then Expr (Tree (With_Node).Left_Child) else "0") & ", " &
                     (if With_Node > 0 then "True" else "False") & ")");
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

               Line ("alb_STATIC_BLIT(" &
                     Expr (Visual_Node) & ", " &
                     (if Visual_With > 0 then Expr (Tree (Visual_With).Left_Child) else "0") & ", " &
                     (if Visual_With > 0 then "True" else "False") & ", " &
                     Expr (Target_Node) & ", " &
                     Expr (Tree (Position_Node).Left_Child) & ", " &
                     Expr (Tree (Position_Node).Right_Child) & ", " &
                     To_String (View_Expr) & ", " &
                     (if Alpha_Mask then "True" else "False") & ")");
            end;

         when AST_Predict_Markov_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, False);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Emit_Firewall_Touch (Tree (Node.Right_Child).Next_Sibling, False, True);
            Line (Statement_Target_Name (Tree (Node.Right_Child).Next_Sibling) &
                  " = alb_MARKOV_PREDICT(" &
                  Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");

         when AST_Infer_Network_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, False);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Emit_Firewall_Touch (Tree (Node.Right_Child).Next_Sibling, False, True);
            Line ("alb_NN_INFER (" & Expr (Node.Left_Child) & ", " &
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
               Line ("alb_NN_TRAIN (" & Expr (Node.Left_Child) & ", " &
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
               Line ("do");
               Indent_Level := Indent_Level + 1;
               Line (Status_Name & " = alb_EXPORT_PPM(" &
                     Expr (Node.Left_Child) & ", " &
                     As_Text_Expr (Path_Node) & ", " &
                     Feature_Text_Expr (Format_Node) & ")");
               Line ("if (" & Status_Name & " /= 0) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("else do");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
                  Line ("pure ()");
               else
                  Line ("pure ()");
               end if;
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
            end;

         when AST_Fits_Cube_Block =>
            Emit_Warn_Once ("fits-cube-albh",
                            "FITS_CUBE is not implemented on ALBH yet; running FALLBACK when present");
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
                  Line (Embed_Name & " | null = null;");
               end if;

               Line ("do");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Line (Table_Name & ": Array<{ key; apply: (value) => void }> = [");
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
                        Line ("{ key: " & Escape_HS_String (Lower_Key) &
                              ", apply: (value) => { " &
                              Statement_Target_Name (Target_Var) &
                              " = value; } },");
                     end;
                  end if;
                  Entry_Node := Tree (Entry_Node).Next_Sibling;
               end loop;
               Indent_Level := Indent_Level - 1;
               Line ("];");
               Line ("if (alb_INI_BIND(" & As_Text_Expr (Path_Node) & ", " & Embed_Name & ", " & Table_Name & ") == 0) {");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Emit_Fallback_Body (Fallback_Node);
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
            end;

         when AST_Stream_Bypass_Block =>
            Emit_Warn_Once ("stream-bypass-albh",
                            "STREAM_BYPASS is ignored on ALBH; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
              and then Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body
                 (Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling);
            end if;

         when AST_Synth_Bake_Block =>
            Emit_Warn_Once ("synth-bake-albh",
                            "SYNTH_BAKE is not implemented on ALBH yet; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Mount_Archive_Block =>
            Emit_Warn_Once ("mount-archive-albh",
                            "MOUNT_ARCHIVE is not available on ALBH; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Network_Sniff_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("alb_SNIFFER_CAPTURE (" & Expr (Node.Left_Child) & ", " &
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
                  Line (Statement_Target_Name (D1) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 0, 6);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 6, 6);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 12, 2);");
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
                  Line (Statement_Target_Name (D1) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 26, 4);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 30, 4);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 23, 1);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 16, 2);");
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
                  Line (Statement_Target_Name (D1) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 34, 2);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 36, 2);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 38, 4);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = alb_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 42, 4);");
               end if;
            end;

         when AST_Network_Listen_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("alb_NET_LISTEN (" & Expr (Node.Left_Child) & ")");

         when AST_Network_Accept_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line (Statement_Target_Name (Node.Right_Child) &
                  " = alb_NET_ACCEPT(" & Expr (Node.Left_Child) & ")");

         when AST_Network_Receive_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("alb_NET_RECEIVE (" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ")");

         when AST_Network_Send_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Line ("alb_NET_SEND (" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ")");

         when AST_Network_Close_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("alb_NET_CLOSE (" & Expr (Node.Left_Child) & ")");

         when AST_Read_Process_Memory_Stmt =>
            declare
               Addr_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Raw  : constant String := Raw_Feature_Atom (Target_Node);
               Target_Sym  : constant Symbol_Record := Resolve_Symbol (Target_Raw);
            begin
               if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field then
                  Line ("alb_PROCESS_READ_BUFFER (" & Expr (Node.Left_Child) & ", " &
                        Expr (Addr_Node) & ", " & Statement_Target_Name (Target_Node) & ")");
               else
                  Line (Statement_Target_Name (Target_Node) & " = alb_PROCESS_READ_SCALAR(" &
                        Expr (Node.Left_Child) & ", " & Expr (Addr_Node) & ")");
               end if;
            end;

         when AST_Write_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("alb_PROCESS_WRITE_SCALAR (" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ")");
            end;

         when AST_Monitor_Process_Memory_Stmt =>
            declare
               Addr_Node    : constant Node_Index := Node.Right_Child;
               Type_Node    : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Node  : constant Node_Index := (if Type_Node > 0 then Tree (Type_Node).Next_Sibling else 0);
               Change_Node  : constant Node_Index := (if Target_Node > 0 then Tree (Target_Node).Next_Sibling else 0);
            begin
               Line ("do");
               Indent_Level := Indent_Level + 1;
               Line ("__alb_monitor_value = { value: albNum (" & Expr (Target_Node) & ") };");
               Line ("__alb_monitor_change = { value: albNum (" & Expr (Change_Node) & ") };");
               Line ("alb_PROCESS_MONITOR (" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", __alb_monitor_value, __alb_monitor_change);");
               Line (Statement_Target_Name (Target_Node) & " = __alb_monitor_value.value;");
               Line (Statement_Target_Name (Change_Node) & " = __alb_monitor_change.value;");
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
            end;

         when AST_Dump_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Size_Node  : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Path_Node  : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Next_Sibling else 0);
            begin
               Line ("alb_PROCESS_DUMP (" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Size_Node) & ", " &
                     Expr (Path_Node) & ")");
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
                     " = alb_PROCESS_CREATE(" & Expr (Node.Left_Child) & ", " &
                     (if Args_Node > 0 then Expr (Args_Node) else """""") & ")");
            end;

         when AST_Elevate_Privileges_Stmt =>
            Line ("alb_PROCESS_ELEVATE (" & Expr (Node.Left_Child) & ")");

         when AST_Hack_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("alb_PROCESS_WRITE_SCALAR (" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ")");
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
            Line ("alb_PROCESS_SNIFF (" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ")");

         when AST_Encrypt_File_Stmt | AST_Decrypt_File_Stmt =>
            declare
               Key_Node  : constant Node_Index := Node.Right_Child;
               Path_Node : constant Node_Index := (if Key_Node > 0 then Tree (Key_Node).Next_Sibling else 0);
            begin
               Line ("alb_FILE_XOR (" & Expr (Node.Left_Child) & ", " &
                     Expr (Key_Node) & ", " & Expr (Path_Node) & ")");
            end;

         when AST_Print_Stmt =>
            if Node.Left_Child > 0 then
               Line ("alb_PRINT (" & As_Text_Expr (Node.Left_Child) & ")");
            else
               Line ("alb_PRINT(""""");
            end if;

         when AST_Locate_Stmt =>
            Line ("alb_LOCATE (" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ")");

         when AST_Print_Str_Stmt =>
            if Node.Left_Child > 0 then
               Line ("alb_PRINT_RAW (" & As_Text_Expr (Node.Left_Child) & ")");
            else
               Line ("alb_PRINT_RAW(""""");
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
                     Line ("alb_DRAW_TEXT (" & To_String (Args (1)) & ") (" &
                           To_String (Args (2)) & ") (" & To_String (Args (3)) & ")");
                  end if;
               elsif Node.Kind = AST_Plot then
                  if Count >= 2 then
                     Line ("alb_PLOT (" & To_String (Args (1)) & ") (" & To_String (Args (2)) & ")");
                  end if;
               else
                  case Tokens (Node.Token_Index).Kind is
                     when Tok_Rect =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("alb_DRAW_RECT");
                        else
                           Call_Name := U ("alb_FILL_RECT");
                        end if;
                     when Tok_Line =>
                        Call_Name := U ("alb_DRAW_LINE");
                     when Tok_Circle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("alb_DRAW_CIRCLE");
                        else
                           Call_Name := U ("alb_FILL_CIRCLE");
                        end if;
                     when Tok_Triangle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("alb_DRAW_TRIANGLE");
                        else
                           Call_Name := U ("alb_FILL_TRIANGLE");
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
                           Append (Arg_Text, " (" & To_String (Args (I)) & ")");
                        end loop;
                        Line (Call_Text & To_String (Arg_Text));
                     end;
                  else
                     Line (To_String (Call_Name));
                  end if;
               end if;
            end;

         when AST_Msg_Box =>
            Line ("alb_MSG_BOX (" & Expr (Node.Left_Child) &
                  (if Node.Right_Child > 0 then ") (" & Expr (Node.Right_Child) else " """) &
                  ")");

         when AST_Listen =>
            Saw_Listen := True;

         when AST_Cease =>
            Line ("alb_CEASE();");

         when AST_Play_Sound =>
            Line ("alb_PLAY_SOUND (" & Expr (Node.Left_Child) & ")");

         when AST_Play_Music =>
            Line ("alb_PLAY_MUSIC (" & Expr (Node.Left_Child) & ")");

         when AST_Play_Music_From =>
            Line ("void alb_PLAY_MUSIC_FROM(" & Expr (Node.Left_Child) & ")");

         when AST_Input_Stmt =>
            Line (Statement_Target_Name (Node.Right_Child) &
                  " <- alb_PROMPT_TEXT (" &
                  (if Node.Left_Child > 0 then Expr (Node.Left_Child) else """""") &
                  ")");

         when AST_Readline_Stmt =>
            if Node.Left_Child > 0 then
               Line (Statement_Target_Name (Node.Left_Child) &
                     " = alb_READLINE_TEXT();");
            else
               Line ("alb_READLINE_TEXT();");
            end if;

         when AST_File_Open =>
            Line ("-- file open expression should be used in LET/assignment context");

         when AST_File_Close =>
            Line ("alb_Close(" & Expr (Node.Left_Child) & ")");

         when AST_File_Write =>
            Line ("alb_Write(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");

         when AST_Load_Stmt =>
            declare
               Target_Sym : constant Symbol_Record := Target_Symbol (Node.Right_Child);
            begin
               if Target_Sym.Active
                 and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
               then
                  Line ("alb_LoadBuffer(" & Expr (Node.Left_Child) & ", " &
                        Statement_Target_Name (Node.Right_Child) & ")");
               else
                  Line (Statement_Target_Name (Node.Right_Child) & " = alb_LoadTextBuffer(" &
                        Expr (Node.Left_Child) & ")");
               end if;
            end;

         when AST_Flush_Stmt =>
            if Tree (Node.Left_Child).Next_Sibling > 0 then
               Line ("alb_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ", " &
                     Expr (Tree (Node.Left_Child).Next_Sibling) & ")");
            else
               Line ("alb_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ")");
            end if;

         when AST_Poke_Stmt =>
            Line ("alb_POKE (" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ")");

         when AST_Save_State =>
            Line ("alb_SAVE_STATE();");

         when AST_Load_State =>
            Line ("alb_LOAD_STATE();");

         when AST_Claim_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = alb_CLAIM();");

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
               Line ("alb_BIND (" & To_String (Args) & ")");
            end;

         when AST_Drop_Stmt =>
            Line ("alb_DROP (" & Expr (Node.Left_Child) & ")");

         when AST_Sweep_Stmt =>
            Line ("alb_SWEEP (" & Expr (Node.Left_Child) & ")");

         when AST_Knows_Fact =>
            Line ("alb_KNOWS_SET(" &
                  Escape_HS_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                  ", " & Expr (Node.Right_Child) & ")");

         when AST_Assert_Stmt =>
            Line
              ("alb_REL_SET(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0, 1);");

         when AST_Retract_Stmt =>
            Line
              ("alb_REL_RETRACT(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0);");

         when AST_Update_Stmt =>
            Line ("alb_REL_SET(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Predicate_Arity_Expr (Node.Left_Child) & ", " &
                  Predicate_Arg1_Expr (Node.Left_Child) &
                  ", 0, 0, 0, " & Expr (Node.Right_Child) & ")");

         when AST_Findall_Query =>
            Line ("alb_REL_FINDALL1(" &
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
                     Line ("for (let __adv = 0; __adv < (" & Count_Expr & "); __adv += 1) {");
                     Indent_Level := Indent_Level + 1;
                     Line (To_String (Symbols (I).HS_Name) & "_head = (" &
                           To_String (Symbols (I).HS_Name) & "_head + 1) % " &
                           Trim_Image (Symbols (I).History_Size));
                     Line (To_String (Symbols (I).HS_Name) & "_history[" &
                           To_String (Symbols (I).HS_Name) & "_head] = " &
                           To_String (Symbols (I).HS_Name));
                     Indent_Level := Indent_Level - 1;
                     Line ("pure ()");
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
                  Line ("alb_SET_ALPHA (" & A1 & ", " & To_String (A2) & ")");
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
               Line ("alb_SET_CLIP (" & To_String (A1) & ", " & To_String (A2) & ", " & To_String (A3) & ", " & To_String (A4) & ")");
            end;

         when AST_Set_Origin =>
            declare
               Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
               A1, A2 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); end if;
               Line ("alb_SET_ORIGIN (" & To_String (A1) & ", " & To_String (A2) & ")");
            end;

         when AST_Delay_Stmt =>
            Line ("alb_Delay(" & Expr (Node.Left_Child) & ")");

         when AST_Try_Stmt =>
            Line ("do");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            if Node.Right_Child > 0 then
               Line ("} catch (__alb_err) {");
               Indent_Level := Indent_Level + 1;
               declare
                  Catch_Name : constant String :=
                    (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
                  Catch_HS   : constant String := Safe_HS_Name (Catch_Name);
                  Catch_Id   : Natural := 0;
               begin
                  if Catch_Name'Length > 0 then
                     Line (Catch_HS &
                           " = albText ((__alb_err instanceof Error) ? __alb_err.message : __alb_err);");
                     Catch_Id :=
                       Push_Shadow_Symbol
                         (Scope   => To_String (Current_Routine),
                          Name    => Catch_Name,
                          HS_Name => Catch_HS,
                          Tag     => VK_String);
                  end if;
                  Emit_Block (Node.Right_Child);
                  Pop_Shadow_Symbol (Catch_Id);
               end;
               Indent_Level := Indent_Level - 1;
               Line ("pure ()");
            else
               Line ("} catch (_e) {}");
            end if;

         when AST_Throw_Stmt =>
            Line ("alb_FATAL (" & As_Text_Expr (Node.Left_Child) & ")");

         when AST_Runtime_Assert =>
            Line ("if (!albTruthy (" & Expr (Node.Left_Child) &
                  ")) { alb_FATAL('runtime assert failed'); }");

         when AST_Reversible_Block | AST_Atomic_Block =>
            Emit_Block (Node.Left_Child);

         when AST_Rev_Add_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " += " & Expr (Node.Right_Child));
         when AST_Rev_Sub_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " -= " & Expr (Node.Right_Child));
         when AST_Rev_Xor_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " ^= " & Expr (Node.Right_Child));
         when AST_Rev_Rol_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = (" & Statement_Target_Name (Node.Left_Child) &
                  " << " & Expr (Node.Right_Child) & ") | (" & Statement_Target_Name (Node.Left_Child) &
                  " >>> (32 - (" & Expr (Node.Right_Child) & ")));");
         when AST_Rev_Ror_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = (" & Statement_Target_Name (Node.Left_Child) &
                  " >>> " & Expr (Node.Right_Child) & ") | (" & Statement_Target_Name (Node.Left_Child) &
                  " << (32 - (" & Expr (Node.Right_Child) & ")));");
         when AST_Rev_Swap_Stmt =>
            Line ("{ const __tmp = " & Statement_Target_Name (Node.Left_Child) & "; " &
                  Statement_Target_Name (Node.Left_Child) & " = " & Statement_Target_Name (Node.Right_Child) &
                  "; " & Statement_Target_Name (Node.Right_Child) & " = __tmp; }");
         when AST_Rev_Not_Stmt =>
            Line (Statement_Target_Name (Node.Left_Child) & " = ~" & Statement_Target_Name (Node.Left_Child));
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
            Line ("-- unsupported or backend-specific node: " & Node_Kind'Image (Node.Kind) & ")");

         when others =>
            Line ("-- TODO node: " & Node_Kind'Image (Node.Kind) & ")");
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
         --  Pass 1: declarations / functions / mkRef scalars at module top level.
         Emit_Phase := Phase_Decls;
         Emit_Top_Level_Range (Stmt_First, Listen_Idx);
         Emit_Phase := Phase_All;
      elsif Root.Kind /= AST_Null then
         Line ("-- ALBH warning: could not recover top-level root index for " &
               Node_Kind'Image (Root.Kind) & ")");
      end if;

      -- Emit_Address_Routines / Emit_State_Routines currently emit JS; skip for GHC.
      Emit_Logic_Setup;
      Emit_Event_Handler ("alb_ON_TICK", Tick_Blocks, Tick_Block_Count);
      Emit_Event_Handler ("alb_ON_PAINT", Paint_Blocks, Paint_Block_Count);
      Emit_Event_Handler ("alb_ON_KEY", Key_Blocks, Key_Block_Count);
      Emit_Module_Exports;
      Emit_Foreign_Loaders;

      New_Line_Emit;
      Line ("alb_ProgramShutdown :: IO ()");
      Line ("alb_ProgramShutdown = do");
      Indent_Level := Indent_Level + 1;
      Line ("done <- readIORef albShutdownDone");
      Line ("unless done $ do");
      Indent_Level := Indent_Level + 1;
      Line ("writeIORef albShutdownDone True");
      Line ("alb_SDL_Shutdown");
      if Listen_Idx > 0 then
         Emit_Phase := Phase_Boot;
         Emit_Top_Level_Range (Tree (Listen_Idx).Next_Sibling, 0);
         Emit_Phase := Phase_All;
      end if;
      Indent_Level := Indent_Level - 1;
      Indent_Level := Indent_Level - 1;

      New_Line_Emit;
      Line ("albBoot :: IO ()");
      Line ("albBoot = do");
      Indent_Level := Indent_Level + 1;
      if Root_Index > 0 and then Stmt_First > 0 then
         Emit_Phase := Phase_Boot;
         Emit_Top_Level_Range (Stmt_First, Listen_Idx);
         Emit_Phase := Phase_All;
      end if;
      Emit_Event_Registrations;
      Line ("pure ()");
      Indent_Level := Indent_Level - 1;

      New_Line_Emit;
      Line ("main :: IO ()");
      Line ("main = do");
      Indent_Level := Indent_Level + 1;
      Line ("hSetBuffering stdout LineBuffering");
      Line ("hSetBuffering stdin LineBuffering");
      if Need_Wasm_Loaders then
         Line ("loaders <- readIORef albWasmLoaders");
         Line ("mapM_ id loaders");
      end if;
      Line ("albBoot");
      if Saw_Create or else Saw_Listen or else Tick_Block_Count > 0 or else Paint_Block_Count > 0 or else Key_Block_Count > 0 then
         Line ("alb_PREPARE_FRAME");
         Line ("alb_MainLoop");
      else
         Line ("pure ()");
      end if;
      Indent_Level := Indent_Level - 1;

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

end Emit_Native_Haskell;
