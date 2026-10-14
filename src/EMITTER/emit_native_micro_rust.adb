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

pragma SPARK_Mode (Off);

with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;

with ALB_System_Includes;
with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with AST;            use AST;

package body Emit_Native_Micro_Rust is

   Max_Symbols  : constant Natural := 8_192;
   Max_Routines : constant Natural := 2_048;
   Max_Strings  : constant Natural := 2_048;

   type Symbol_Kind is (Sym_Scalar, Sym_Const, Sym_Array, Sym_Struct, Sym_Routine);

   type Symbol_Record is record
      Active : Boolean := False;
      Name   : Unbounded_String := To_Unbounded_String ("");
      Rust_Type : Unbounded_String := To_Unbounded_String ("");
      Kind   : Symbol_Kind := Sym_Scalar;
   end record;

   type Routine_Record is record
      Active : Boolean := False;
      Name   : Unbounded_String := To_Unbounded_String ("");
      Returns : Unbounded_String := To_Unbounded_String ("");
   end record;

   Symbols        : array (1 .. Max_Symbols)  of Symbol_Record;
   Routines       : array (1 .. Max_Routines) of Routine_Record;
   Symbol_Count   : Natural := 0;
   Routine_Count  : Natural := 0;

   Out_File       : Ada.Text_IO.File_Type;
   File_Open      : Boolean := False;
   Indent_Level   : Natural := 0;
   Custom_Entry   : Boolean := False;
   Entry_Symbol   : Unbounded_String := To_Unbounded_String ("main");
   Target_Triple  : Unbounded_String := To_Unbounded_String ("");
   No_Console     : Boolean := False;

   Comptime_Lines : array (1 .. Max_Strings) of Unbounded_String;
   Comptime_Count : Natural := 0;

   Inline_C_Lines : array (1 .. Max_Strings) of Unbounded_String;
   Inline_C_Count : Natural := 0;

   function Token_Text (TI : Natural) return String is
   begin
      if TI = 0 or else TI > Tokens'Last then
         return "";
      end if;
      declare
         T : constant Token := Tokens (TI);
      begin
         if T.Length = 0 or else T.Start + T.Length - 1 > Input_Buffer'Last then
            return "";
         end if;
         return Input_Buffer (T.Start .. T.Start + T.Length - 1);
      end;
   end Token_Text;

   function Safe_Ident (Raw : String) return String is
      Result : String (Raw'Range);
   begin
      for I in Raw'Range loop
         declare
            C : constant Character := Raw (I);
         begin
            if Ada.Characters.Handling.Is_Alphanumeric (C) or else C = '_' then
               Result (I) := C;
            else
               Result (I) := '_';
            end if;
         end;
      end loop;
      return Result;
   end Safe_Ident;

   function Node_Name (N : Node_Index) return String is
   begin
      if N = 0 or else Tree (N).Kind /= AST_Var_Expr then
         return "_";
      end if;
      return Safe_Ident (Token_Text (Tree (N).Token_Index));
   end Node_Name;

   function Rust_Type (Type_Token : Natural) return String is
      Raw : constant String := Token_Text (Type_Token);
      Up  : String (Raw'Range);
   begin
      for I in Raw'Range loop
         Up (I) := Ada.Characters.Handling.To_Upper (Raw (I));
      end loop;
      if Up = "S32"   then return "i32";
      elsif Up = "S16" then return "i16";
      elsif Up = "S8"  then return "i8";
      elsif Up = "S64" then return "i64";
      elsif Up = "U32"  then return "u32";
      elsif Up = "U16" then return "u16";
      elsif Up = "U8"  then return "u8";
      elsif Up = "U64" then return "u64";
      elsif Up = "F32" then return "f32";
      elsif Up = "F64" then return "f64";
      elsif Up = "BOOL" then return "bool";
      elsif Up = "STRING" then return "&'static str";
      elsif Up = "HW8"  then return "u8";
      elsif Up = "HW16" then return "u16";
      elsif Up = "HW32" then return "u32";
      else return "i32";
      end if;
   end Rust_Type;

   function Indent_String return String is
      Result : String (1 .. Indent_Level * 4) := (others => ' ');
   begin
      return Result;
   end Indent_String;

   procedure Put_Indent is
   begin
      Put (Out_File, Indent_String);
   end Put_Indent;

   procedure Out_Text (S : String) is
   begin
      Put (Out_File, S);
   end Out_Text;

   procedure Out_Line (S : String) is
   begin
      Put_Indent;
      Put_Line (Out_File, S);
   end Out_Line;

   procedure Out_Raw (S : String) is
   begin
      Put (Out_File, S);
   end Out_Raw;

   procedure Open_Output (Path : String) is
   begin
      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Path);
      File_Open := True;
   exception
      when others =>
         File_Open := False;
         raise;
   end Open_Output;

   procedure Close_Output is
   begin
      if File_Open then
         Close (Out_File);
         File_Open := False;
      end if;
   end Close_Output;

   function Lookup_Symbol (Name : String) return Natural is
   begin
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active and then To_String (Symbols (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Lookup_Symbol;

   procedure Add_Symbol (Name : String; Rust_Type_Str : String;
                         K : Symbol_Kind := Sym_Scalar) is
   begin
      if Symbol_Count >= Max_Symbols then
         return;
      end if;
      if Lookup_Symbol (Name) > 0 then
         return;
      end if;
      Symbol_Count := Symbol_Count + 1;
      Symbols (Symbol_Count) :=
        (Active    => True,
         Name      => To_Unbounded_String (Name),
         Rust_Type => To_Unbounded_String (Rust_Type_Str),
         Kind      => K);
   end Add_Symbol;

   function Is_Lvalue_Node (N : Node_Index) return Boolean is
      K : Node_Kind;
   begin
      if N = 0 then
         return False;
      end if;
      K := Tree (N).Kind;
      return K in AST_Var_Expr | AST_Member_Expr | AST_Array_Access;
   end Is_Lvalue_Node;

   function Emit_Expr (N : Node_Index) return String;

   function Emit_Arg_List (N : Node_Index) return String is
      Result : Unbounded_String := To_Unbounded_String ("");
      Curr   : Node_Index := N;
      First  : Boolean := True;
   begin
      while Curr /= 0 loop
         if not First then
            Append (Result, ", ");
         end if;
         First := False;
         Append (Result, Emit_Expr (Curr));
         Curr := Tree (Curr).Next_Sibling;
      end loop;
      return To_String (Result);
   end Emit_Arg_List;

   function Emit_Func_Call (Target : String; Arg_Node : Node_Index) return String is
   begin
      if Arg_Node /= 0 and then Tree (Arg_Node).Kind = AST_Arg_List then
         return Target & "(" & Emit_Arg_List (Tree (Arg_Node).Left_Child) & ")";
      elsif Arg_Node /= 0 then
         return Target & "(" & Emit_Expr (Arg_Node) & ")";
      else
         return Target & "()";
      end if;
   end Emit_Func_Call;

   procedure Emit_Print_String (N : Node_Index) is
      K : Node_Kind;
      Op : String (1 .. 8) := (others => ' ');
      Len : Natural := 0;
   begin
      if N = 0 then
         return;
      end if;
      K := Tree (N).Kind;
      if K = AST_BinOp then
         Op := Token_Text (Tree (N).Token_Index);
         Len := Op'Length;
      end if;
      if K = AST_BinOp and then Len = 1 and then Op (1) = '|' then
         Emit_Print_String (Tree (N).Left_Child);
         Emit_Print_String (Tree (N).Right_Child);
      elsif K = AST_String_Expr then
         Out_Line ("_alb_print_str(" & Emit_Expr (N) & ");");
      else
         Out_Line ("_alb_print_i32(" & Emit_Expr (N) & ");");
      end if;
   end Emit_Print_String;

   function Emit_Expr (N : Node_Index) return String is
      K : Node_Kind;
   begin
      if N = 0 then
         return "0";
      end if;
      K := Tree (N).Kind;
      case K is
         when AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr =>
            return Token_Text (Tree (N).Token_Index);
         when AST_Var_Expr =>
            return Node_Name (N);
         when AST_Const_Ref =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Raw'Length > 0 and then Raw (Raw'First) = '#' then
                  return Safe_Ident (Raw (Raw'First + 1 .. Raw'Last));
               else
                  return Safe_Ident (Raw);
               end if;
            end;
         when AST_String_Expr =>
            return Token_Text (Tree (N).Token_Index);
         when AST_BinOp =>
            declare
               Op : constant String := Token_Text (Tree (N).Token_Index);
               L  : constant String := Emit_Expr (Tree (N).Left_Child);
               R  : constant String := Emit_Expr (Tree (N).Right_Child);
               Rust_Op : String (1 .. 8) := (others => ' ');
               Len     : Natural := 0;
            begin
               if Op = "+" then Rust_Op (1 .. 1) := "+"; Len := 1;
               elsif Op = "-" then Rust_Op (1 .. 1) := "-"; Len := 1;
               elsif Op = "*" then Rust_Op (1 .. 1) := "*"; Len := 1;
               elsif Op = "/" then Rust_Op (1 .. 1) := "/"; Len := 1;
               elsif Op = "=" then Rust_Op (1 .. 2) := "=="; Len := 2;
               elsif Op = "<>" then Rust_Op (1 .. 2) := "!="; Len := 2;
               elsif Op = "<" then Rust_Op (1 .. 1) := "<"; Len := 1;
               elsif Op = ">" then Rust_Op (1 .. 1) := ">"; Len := 1;
               elsif Op = "<=" then Rust_Op (1 .. 2) := "<="; Len := 2;
               elsif Op = ">=" then Rust_Op (1 .. 2) := ">="; Len := 2;
               elsif Op = "AND" or else Op = "&" then Rust_Op (1 .. 3) := " & "; Len := 3;
               elsif Op = "OR" or else Op = "|" then Rust_Op (1 .. 3) := " | "; Len := 3;
               elsif Op = "XOR" then Rust_Op (1 .. 3) := " ^ "; Len := 3;
               else Rust_Op (1 .. Op'Length) := Op; Len := Op'Length;
               end if;
               return "(" & L & " " & Rust_Op (1 .. Len) & " " & R & ")";
            end;
         when AST_Unary_Minus =>
            return "(-" & Emit_Expr (Tree (N).Left_Child) & ")";
         when AST_Cast_Expr =>
            return "(" & Emit_Expr (Tree (N).Left_Child) & " as "
              & Rust_Type (Tree (N).Token_Index) & ")";
         when AST_Member_Expr =>
            return "(" & Emit_Expr (Tree (N).Left_Child) & "."
              & Node_Name (Tree (N).Right_Child) & ")";
         when AST_Array_Access =>
            return "(" & Emit_Expr (Tree (N).Left_Child) & "["
              & Emit_Expr (Tree (N).Right_Child) & "])";
         when AST_Deref_Expr =>
            return "unsafe { *" & Emit_Expr (Tree (N).Left_Child) & " }";
         when AST_AddressOf =>
            return "(&mut " & Emit_Expr (Tree (N).Left_Child) & " as *mut _)";
         when AST_Ref_Expr =>
            return "(&mut " & Emit_Expr (Tree (N).Left_Child) & ")";
         when AST_Peek_Expr =>
            return "unsafe { core::ptr::read_volatile::<u8>("
              & Emit_Expr (Tree (N).Left_Child)
              & " as *const u8) as i32 }";
         when AST_SizeOf_Expr =>
            return "core::mem::size_of::<" & Node_Name (Tree (N).Left_Child) & ">()";
         when AST_OffsetOf_Expr =>
            return "core::mem::offset_of::<"
              & Node_Name (Tree (N).Left_Child) & ", "
              & Node_Name (Tree (N).Right_Child) & ">()";
         when AST_TypeOf_Expr =>
            return "core::mem::size_of::<"
              & Rust_Type (Tree (Tree (N).Left_Child).Token_Index) & ">()";
         when AST_Func_Call =>
            return Emit_Func_Call (Node_Name (Tree (N).Left_Child),
                                   Tree (N).Right_Child);
         when AST_Call_Stmt =>
            return Emit_Func_Call (Node_Name (Tree (N).Left_Child),
                                   Tree (N).Right_Child);
         when others =>
            return "/* micro-alb: unsupported expr " & Node_Kind'Image (K) & " */";
      end case;
   end Emit_Expr;

   function Strip_Quotes (S : String) return String is
   begin
      if S'Length >= 2 and then
        ((S (S'First) = '"' and then S (S'Last) = '"') or else
         (S (S'First) = '`' and then S (S'Last) = '`'))
      then
         return S (S'First + 1 .. S'Last - 1);
      end if;
      return S;
   end Strip_Quotes;

   procedure Emit_C_Foreign_Decl (Decl_Node : Node_Index);
   procedure Emit_Node (N : Node_Index);
   procedure Emit_Block (First : Node_Index);
   procedure Emit_Stmt (N : Node_Index);

   procedure Emit_Stmt (N : Node_Index) is
      K : Node_Kind;
   begin
      if N = 0 then
         return;
      end if;
      K := Tree (N).Kind;
      case K is
         when AST_BinOp =>
            declare
               Op : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Op = "=" and then Is_Lvalue_Node (Tree (N).Left_Child) then
                  Out_Line (Emit_Expr (Tree (N).Left_Child)
                            & " = "
                            & Emit_Expr (Tree (N).Right_Child) & ";");
               else
                  Out_Line (Emit_Expr (N) & ";");
               end if;
            end;

         when AST_Let_Stmt =>
            declare
               Name : constant String := Node_Name (Tree (N).Left_Child);
               TTok : constant Natural := Tree (N).Token_Index;
               Init : constant String := Emit_Expr (Tree (N).Right_Child);
            begin
               if TTok /= 0 then
                  Out_Line ("let mut " & Name & " : " & Rust_Type (TTok) & " = " & Init & ";");
               else
                  Out_Line ("let mut " & Name & " = " & Init & ";");
               end if;
               Add_Symbol (Name, (if TTok /= 0 then Rust_Type (TTok) else "i32"));
            end;

         when AST_Const_Decl =>
            declare
               Name : constant String := Node_Name (Tree (N).Left_Child);
               Init : constant String := Emit_Expr (Tree (N).Right_Child);
            begin
               Out_Line ("const " & Name & " : i32 = " & Init & ";");
               Add_Symbol (Name, "i32", Sym_Const);
            end;

         when AST_Print_Stmt =>
            Out_Line ("_alb_print_i32(" & Emit_Expr (Tree (N).Left_Child) & ");");
            Out_Line ("_alb_print_newline();");

         when AST_Print_Str_Stmt =>
            Emit_Print_String (Tree (N).Left_Child);

         when AST_Poke_Stmt =>
            Out_Line
              ("unsafe { core::ptr::write_volatile::<u8>("
               & Emit_Expr (Tree (N).Left_Child)
               & " as *mut u8, "
               & Emit_Expr (Tree (N).Right_Child)
               & " as u8); }");

         when AST_Delay_Stmt =>
            Out_Line ("// DELAY: target-specific delay omitted");

         when AST_Runtime_Assert =>
            Out_Line ("debug_assert!(" & Emit_Expr (Tree (N).Left_Child) & ", ""ALB ASSERT"");");

         when AST_Require_Clause =>
            Out_Line ("// REQUIRE: " & Emit_Expr (Tree (N).Left_Child) & " (precondition)");

         when AST_Ensure_Clause =>
            Out_Line ("// ENSURE: " & Emit_Expr (Tree (N).Left_Child) & " (postcondition)");

         when AST_Claim_Stmt =>
            Out_Line ("// CLAIM: " & Node_Name (Tree (N).Left_Child));

         when AST_Bind_Stmt =>
            Out_Line ("// BIND: " & Node_Name (Tree (N).Left_Child));

         when AST_Drop_Stmt =>
            Out_Line ("// DROP: " & Node_Name (Tree (N).Left_Child));

         when AST_Sweep_Stmt =>
            Out_Line ("// SWEEP chunk_size=" & Emit_Expr (Tree (N).Left_Child));

         when AST_If_Stmt =>
            Out_Line ("if " & Emit_Expr (Tree (N).Left_Child) & " {");
            Indent_Level := Indent_Level + 1;
            Emit_Node (Tree (N).Right_Child);
            Indent_Level := Indent_Level - 1;
            Out_Line ("}");

         when AST_For_Stmt =>
            declare
               Var  : constant String := Safe_Ident (Token_Text (Tree (N).Token_Index));
               Dummy : constant Node_Index := Tree (N).Left_Child;
               Low  : constant String := Emit_Expr (Tree (Dummy).Left_Child);
               Hi   : constant String := Emit_Expr (Tree (Dummy).Right_Child);
            begin
               Out_Line ("for " & Var & " in " & Low & "..=" & Hi & " {");
               Indent_Level := Indent_Level + 1;
               Emit_Node (Tree (N).Right_Child);
               Indent_Level := Indent_Level - 1;
               Out_Line ("}");
            end;

         when AST_While_Stmt =>
            Out_Line ("while " & Emit_Expr (Tree (N).Left_Child) & " {");
            Indent_Level := Indent_Level + 1;
            Emit_Node (Tree (N).Right_Child);
            Indent_Level := Indent_Level - 1;
            Out_Line ("}");

         when AST_Repeat_Stmt =>
            Out_Line ("loop {");
            Indent_Level := Indent_Level + 1;
            Emit_Node (Tree (N).Right_Child);
            Out_Line ("if " & Emit_Expr (Tree (N).Left_Child) & " { break; }");
            Indent_Level := Indent_Level - 1;
            Out_Line ("}");

         when AST_Break_Stmt =>
            Out_Line ("break;");

         when AST_Continue_Stmt =>
            Out_Line ("continue;");

         when AST_Call_Stmt =>
            Out_Line (Emit_Expr (N) & ";");

         when AST_Return_Stmt =>
            if Tree (N).Left_Child /= 0 then
               Out_Line ("return " & Emit_Expr (Tree (N).Left_Child) & ";");
            else
               Out_Line ("return;");
            end if;

         when AST_Array_Assign =>
            Out_Line
              (Emit_Expr (Tree (N).Left_Child)
               & " = "
               & Emit_Expr (Tree (N).Right_Child) & ";");

         when AST_Procedure_Decl | AST_Function_Decl | AST_Struct_Decl |
              AST_Enum_Decl | AST_Range_Type_Decl | AST_DeclareModule |
              AST_Module =>
            null; -- emitted in first pass or skipped as top-level marker

         when AST_Select_Stmt =>
            Out_Line ("match " & Emit_Expr (Tree (N).Left_Child) & " {");
            Indent_Level := Indent_Level + 1;
            Emit_Node (Tree (N).Right_Child);
            Indent_Level := Indent_Level - 1;
            Out_Line ("}");

         when AST_Case_Stmt =>
            Out_Line (Emit_Expr (Tree (N).Left_Child) & " => {");
            Indent_Level := Indent_Level + 1;
            Emit_Node (Tree (N).Right_Child);
            Indent_Level := Indent_Level - 1;
            Out_Line ("},");

         when AST_Choose =>
            Out_Line (Emit_Expr (Tree (N).Left_Child) & " => {");
            Indent_Level := Indent_Level + 1;
            Emit_Node (Tree (N).Right_Child);
            Indent_Level := Indent_Level - 1;
            Out_Line ("},");

         when AST_Import_C =>
            Emit_C_Foreign_Decl (Tree (N).Left_Child);

         when AST_Comptime_Block =>
            declare
               Line : constant String := "// COMPTIME: " & Node_Name (Tree (N).Left_Child);
            begin
               if Comptime_Count < Max_Strings then
                  Comptime_Count := Comptime_Count + 1;
                  Comptime_Lines (Comptime_Count) := To_Unbounded_String (Line);
               end if;
               Out_Line (Line);
            end;

         when AST_Enable_C_Block =>
            if Inline_C_Count < Max_Strings then
               Inline_C_Count := Inline_C_Count + 1;
               Inline_C_Lines (Inline_C_Count) :=
                 To_Unbounded_String ("/* ENABLE_C_BLOCK see generated .c */");
            end if;
            Out_Line ("// ENABLE_C_BLOCK (provide matching C object at link time)");

         when AST_Enable_Asm =>
            Out_Line ("// ENABLE ASM family: " & Token_Text (Tree (N).Token_Index));

         when AST_Asm_Block | AST_Inline_Asm_Expr =>
            Out_Line ("// INLINE ASM omitted (use core::arch::asm! manually)");

         when AST_Inline_C_Expr =>
            Out_Line ("// INLINE C omitted (provide extern ""C"" implementation)");

         when AST_Block_Stmt =>
            Emit_Block (Tree (N).Left_Child);

         when others =>
            Out_Line ("// micro-alb: unsupported stmt " & Node_Kind'Image (K));
      end case;
   end Emit_Stmt;

   procedure Emit_Block (First : Node_Index) is
      Curr : Node_Index := First;
   begin
      while Curr /= 0 loop
         Emit_Stmt (Curr);
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Block;

   procedure Emit_Node (N : Node_Index) is
      K : Node_Kind;
   begin
      if N = 0 then
         return;
      end if;
      K := Tree (N).Kind;
      case K is
         when AST_Block_Stmt =>
            Emit_Block (Tree (N).Left_Child);
         when AST_Program =>
            Emit_Node (Tree (N).Left_Child);
         when others =>
            Emit_Stmt (N);
      end case;
   end Emit_Node;

   procedure Emit_C_Foreign_Decl (Decl_Node : Node_Index) is
      K    : Node_Kind;
      Name : Unbounded_String := To_Unbounded_String ("");
      Ret  : Unbounded_String := To_Unbounded_String ("i32");
   begin
      if Decl_Node = 0 then
         return;
      end if;
      K := Tree (Decl_Node).Kind;
      if K = AST_Procedure_Decl then
         Name := To_Unbounded_String (Node_Name (Tree (Decl_Node).Left_Child));
         Ret := To_Unbounded_String ("");
      elsif K = AST_Function_Decl then
         Name := To_Unbounded_String (Node_Name (Tree (Decl_Node).Left_Child));
      else
         return;
      end if;

      Out_Text ("extern ""C"" { fn " & To_String (Name) & "(");
      --  Parameters would be walked here; omitted for compactness.
      Out_Text ("); }");
      New_Line (Out_File);
   end Emit_C_Foreign_Decl;

   procedure Emit_Procedure_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
      Body_Node : constant Node_Index := Tree (N).Right_Child;
   begin
      Out_Line ("unsafe fn " & Name & "() {");
      Indent_Level := Indent_Level + 1;
      Emit_Node (Body_Node);
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Procedure_Decl;

   procedure Emit_Function_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
      Body_Node : constant Node_Index := Tree (N).Right_Child;
      TTok : constant Natural := Tree (N).Token_Index;
      Ret_Type : constant String := (if TTok /= 0 then Rust_Type (TTok) else "i32");
   begin
      Out_Line ("unsafe fn " & Name & "() -> " & Ret_Type & " {");
      Indent_Level := Indent_Level + 1;
      Emit_Node (Body_Node);
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Function_Decl;

   procedure Emit_Module_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
   begin
      Out_Line ("pub mod " & Name & " {");
      Indent_Level := Indent_Level + 1;
      Emit_Node (Tree (N).Right_Child);
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Module_Decl;

   procedure Emit_DeclareModule_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
   begin
      Out_Line ("// DECLARE MODULE " & Name);
   end Emit_DeclareModule_Decl;

   procedure Emit_Struct_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
      Field : Node_Index;
   begin
      Out_Line ("#[repr(C)]");
      Out_Line ("pub struct " & Name & " {");
      Indent_Level := Indent_Level + 1;
      Field := Tree (Tree (N).Right_Child).Left_Child;
      while Field /= 0 loop
         if Tree (Field).Kind = AST_Struct_Field then
            declare
               FName : constant String := Node_Name (Tree (Field).Left_Child);
               TTok  : constant Natural := Tree (Field).Token_Index;
               FType : constant String := (if TTok /= 0 then Rust_Type (TTok) else "u32");
            begin
               Out_Line (FName & ": " & FType & ",");
            end;
         elsif Tree (Field).Kind = AST_Bitfield_Decl then
            declare
               FName : constant String := Node_Name (Tree (Field).Left_Child);
            begin
               Out_Line ("// BITFIELD " & FName & " (manual masking required)");
            end;
         end if;
         Field := Tree (Field).Next_Sibling;
      end loop;
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Struct_Decl;

   procedure Emit_Enum_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
      Member : Node_Index := Tree (Tree (N).Right_Child).Left_Child;
   begin
      Out_Line ("#[repr(i32)]");
      Out_Line ("pub enum " & Name & " {");
      Indent_Level := Indent_Level + 1;
      while Member /= 0 loop
         Out_Line (Node_Name (Member) & ",");
         Member := Tree (Member).Next_Sibling;
      end loop;
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Enum_Decl;

   procedure Emit_Range_Type_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
   begin
      Out_Line ("// RANGE TYPE " & Name & " (use checked constructor at runtime)");
   end Emit_Range_Type_Decl;

   procedure Emit_Preamble is
   begin
      Out_Line ("#![no_std]");
      Out_Line ("#![no_main]");
      Out_Line ("");
      Out_Line ("mod support;");
      Out_Line ("use support::{_alb_print_i32, _alb_print_str, _alb_print_newline};");
      Out_Line ("");
      Out_Line ("use core::panic::PanicInfo;");
      Out_Line ("use core::ptr::{read_volatile, write_volatile};");
      Out_Line ("");
      Out_Line ("#[panic_handler]");
      Out_Line ("fn panic(_info: &PanicInfo) -> ! {");
      Out_Line ("    loop {}");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("static mut _ALB_ARENA: [u8; 4096] = [0; 4096];");
      Out_Line ("static mut _ALB_ARENA_USED: usize = 0;");
      Out_Line ("");
      Out_Line ("#[allow(static_mut_refs)]");
      Out_Line ("unsafe fn _alb_claim(size: usize) -> *mut u8 {");
      Out_Line ("    let p = _ALB_ARENA.as_mut_ptr().add(_ALB_ARENA_USED);");
      Out_Line ("    _ALB_ARENA_USED += size;");
      Out_Line ("    p");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("unsafe fn _alb_sweep() {");
      Out_Line ("    _ALB_ARENA_USED = 0;");
      Out_Line ("}");
      Out_Line ("");
   end Emit_Preamble;

   procedure Emit_Postamble is
   begin
      if Custom_Entry then
         Out_Line ("");
         Out_Line ("#[no_mangle]");
         Out_Line ("pub extern ""C"" fn _start() {");
         Indent_Level := Indent_Level + 1;
         Out_Line (To_String (Entry_Symbol) & "();");
         Out_Line ("support::_alb_exit(0);");
         Indent_Level := Indent_Level - 1;
         Out_Line ("}");
      end if;
   end Emit_Postamble;

   procedure Compile_To_File
     (Root_Index      : in Node_Index;
      Output_Filename : in String)
   is
      Program_Node : constant Node_Index := Root_Index;
      Body_Node    : constant Node_Index :=
        (if Tree (Program_Node).Kind = AST_Program
         then Tree (Program_Node).Left_Child
         else Program_Node);
      Curr : Node_Index := Tree (Body_Node).Left_Child;
   begin
      Symbol_Count := 0;
      Routine_Count := 0;
      Comptime_Count := 0;
      Inline_C_Count := 0;
      Indent_Level := 0;

      Open_Output (Output_Filename);
      Emit_Preamble;

      --  First pass: walk top-level declarations to emit struct/enum/function
      --  signatures and module blocks before the entry point.
      while Curr /= 0 loop
         declare
            K : constant Node_Kind := Tree (Curr).Kind;
         begin
            case K is
               when AST_Struct_Decl =>
                  Emit_Struct_Decl (Curr);
               when AST_Enum_Decl =>
                  Emit_Enum_Decl (Curr);
               when AST_Range_Type_Decl =>
                  Emit_Range_Type_Decl (Curr);
               when AST_DeclareModule =>
                  Emit_DeclareModule_Decl (Curr);
               when AST_Module =>
                  Emit_Module_Decl (Curr);
               when AST_Procedure_Decl =>
                  Emit_Procedure_Decl (Curr);
               when AST_Function_Decl =>
                  Emit_Function_Decl (Curr);
               when others =>
                  null;
            end case;
         end;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      --  Entry point
      Out_Line ("");
      Out_Line ("fn _alb_main_body() {");
      Indent_Level := 1;
      Emit_Node (Body_Node);
      Indent_Level := 0;
      Out_Line ("}");

      if Custom_Entry then
         Out_Line ("");
         Out_Line ("#[no_mangle]");
         Out_Line ("pub extern ""C"" fn " & To_String (Entry_Symbol) & "() {");
         Indent_Level := 1;
         Out_Line ("_alb_main_body();");
         Out_Line ("support::_alb_exit(0);");
         Indent_Level := 0;
         Out_Line ("}");
      else
         Out_Line ("");
         Out_Line ("#[no_mangle]");
         Out_Line ("pub extern ""C"" fn main() {");
         Indent_Level := 1;
         Out_Line ("_alb_main_body();");
         Out_Line ("support::_alb_exit(0);");
         Indent_Level := 0;
         Out_Line ("}");
      end if;

      Emit_Postamble;
      Close_Output;
   end Compile_To_File;

   procedure Set_No_Console_Overlay (Enabled : in Boolean) is
   begin
      No_Console := Enabled;
   end Set_No_Console_Overlay;

   procedure Set_Entry_Mode (Use_Custom_Entry : in Boolean;
                             Entry_Name       : in String) is
   begin
      Custom_Entry := Use_Custom_Entry;
      Entry_Symbol := To_Unbounded_String (Safe_Ident (Entry_Name));
   end Set_Entry_Mode;

   procedure Set_Target_Triple (Triple : in String) is
   begin
      Target_Triple := To_Unbounded_String (Triple);
   end Set_Target_Triple;

end Emit_Native_Micro_Rust;
