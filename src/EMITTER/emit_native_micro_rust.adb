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

   Max_Rank : constant Natural := 4;
   type Dim_Array is array (1 .. Max_Rank) of Natural;

   type Symbol_Record is record
      Active    : Boolean := False;
      Name      : Unbounded_String := To_Unbounded_String ("");
      Rust_Type : Unbounded_String := To_Unbounded_String ("");
      Kind      : Symbol_Kind := Sym_Scalar;
      Rank      : Natural := 0;
      Dims      : Dim_Array := (others => 0);
      Is_Global : Boolean := False;
      Root_Level : Boolean := False;
      Const_Val : Long_Long_Integer := 0;
      Has_Const : Boolean := False;
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

   Max_Declared   : constant := 1024;
   Declared_Names : array (1 .. Max_Declared) of Unbounded_String;
   Declared_Count : Natural := 0;

   Inside_Fn     : Boolean := False;
   Inside_Module : Boolean := False;

   function Is_Declared (Name : String) return Boolean;
   procedure Add_Declared (Name : String);
   procedure Reset_Declared;
   function  Lookup_Array (Name : String) return Natural;
   procedure Register_Array
     (Name : String; Rust_T : String; R : Natural;
      D : Dim_Array; Global : Boolean; Root_Level : Boolean);
   function  Eval_Static_Int
     (N : Node_Index; Value : out Long_Long_Integer) return Boolean;
   function  Emit_Array_Ref
     (Sym : Natural; Name : String; First_Idx : Node_Index) return String;
   function  Zero_Lit (Rust_T : String) return String;
   function  Trim_LLI (V : Long_Long_Integer) return String;
   function  Expr_Is_String (N : Node_Index) return Boolean;
   function  Emit_Str (N : Node_Index) return String;
   function  Emit_String_Lit (Raw : String) return String;
   function  Lookup_Routine (Name : String) return Natural;
   procedure Register_Routine (Name : String; Returns : String);

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
         Kind      => K,
         others    => <>);
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

   function Emit_Call_Target (N : Node_Index) return String is
      K : Node_Kind;
   begin
      if N = 0 then
         return "";
      end if;
      K := Tree (N).Kind;
      if K = AST_Member_Expr then
         return Node_Name (Tree (N).Left_Child) & "::" & Node_Name (Tree (N).Right_Child);
      else
         return Node_Name (N);
      end if;
   end Emit_Call_Target;

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
         declare
            Raw : constant String := Token_Text (Tree (N).Token_Index);
         begin
            Len := Raw'Length;
            if Len <= Op'Length then
               Op (1 .. Len) := Raw;
            end if;
         end;
      end if;
      if K = AST_BinOp and then Len = 1 and then Op (1) = '|' then
         Emit_Print_String (Tree (N).Left_Child);
         Emit_Print_String (Tree (N).Right_Child);
      elsif Expr_Is_String (N) then
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
         when AST_Number_Expr =>
            return Token_Text (Tree (N).Token_Index);
         when AST_Hex_Expr =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Raw'Length > 1 and then Raw (Raw'First) = '$' then
                  return "0x" & Raw (Raw'First + 1 .. Raw'Last);
               else
                  return Raw;
               end if;
            end;
         when AST_Bin_Expr =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Raw'Length > 1 and then Raw (Raw'First) = '%' then
                  return "0b" & Raw (Raw'First + 1 .. Raw'Last);
               else
                  return Raw;
               end if;
            end;
         when AST_Octal_Expr =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Raw'Length > 2
                 and then Raw (Raw'First) = '&'
                 and then Raw (Raw'First + 1) in 'o' | 'O'
               then
                  return "0o" & Raw (Raw'First + 2 .. Raw'Last);
               else
                  return Raw;
               end if;
            end;
         when AST_Var_Expr =>
            if Tree (N).Left_Child /= 0 then
               declare
                  Name     : constant String := Node_Name (N);
                  Sym      : constant Natural := Lookup_Array (Name);
                  Str_Sym  : constant Natural := Lookup_Symbol (Name);
               begin
                  if Sym = 0
                    and then Str_Sym /= 0
                    and then To_String (Symbols (Str_Sym).Rust_Type)
                             = "&'static str"
                  then
                     --  s[i] on a string: panic-free byte fetch
                     return "(" & Name & ".as_bytes().get("
                       & Emit_Expr (Tree (N).Left_Child)
                       & " as usize).copied().unwrap_or(0) as i32)";
                  end if;
                  declare
                     Ref : constant String :=
                       Emit_Array_Ref (Sym, Name, Tree (N).Left_Child);
                  begin
                     if Sym /= 0 and then Symbols (Sym).Is_Global then
                        return "unsafe { " & Ref & " }";
                     else
                        return Ref;
                     end if;
                  end;
               end;
            else
               return Node_Name (N);
            end if;
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
            return Emit_String_Lit (Token_Text (Tree (N).Token_Index));
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
               elsif Op = "AND" then Rust_Op (1 .. 3) := " & "; Len := 3;
               elsif Op = "OR" then Rust_Op (1 .. 3) := " | "; Len := 3;
               elsif Op = "XOR" then Rust_Op (1 .. 3) := " ^ "; Len := 3;
               elsif Op = "MOD" then Rust_Op (1 .. 1) := "%"; Len := 1;
               elsif Op = "|" or else Op = "&" then
                  --  ALB '|' / '&' is STRING CONCAT, never bitwise.
                  return "unsafe { _alb_concat("
                    & Emit_Str (Tree (N).Left_Child) & ", "
                    & Emit_Str (Tree (N).Right_Child) & ") }";
               else Rust_Op (1 .. Op'Length) := Op; Len := Op'Length;
               end if;
               return "(" & L & " " & Rust_Op (1 .. Len) & " " & R & ")";
            end;
         when AST_Unary_Minus =>
            return "(-" & Emit_Expr (Tree (N).Left_Child) & ")";
         when AST_Not =>
            return "!" & Emit_Expr (Tree (N).Left_Child);
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
         when AST_Str_Len =>
            --  ALB LEN counts characters, not bytes (matches desktop emitter).
            return "(" & Emit_Expr (Tree (N).Left_Child)
              & ".chars().count() as i32)";
         when AST_Str_Left =>
            return "(unsafe { _alb_left(" & Emit_Str (Tree (N).Left_Child) & ", "
              & Emit_Expr (Tree (N).Right_Child) & ") })";
         when AST_Str_Right =>
            return "(unsafe { _alb_right(" & Emit_Str (Tree (N).Left_Child) & ", "
              & Emit_Expr (Tree (N).Right_Child) & ") })";
         when AST_Str_Mid =>
            declare
               Start_Node : constant Node_Index :=
                 (if Tree (N).Right_Child /= 0
                    and then Tree (Tree (N).Right_Child).Kind = AST_Arg_List
                  then Tree (Tree (N).Right_Child).Left_Child
                  else Tree (N).Right_Child);
               Count_Node : constant Node_Index :=
                 (if Start_Node /= 0 then Tree (Start_Node).Next_Sibling else 0);
            begin
               return "(unsafe { _alb_mid(" & Emit_Str (Tree (N).Left_Child) & ", "
                 & (if Start_Node /= 0 then Emit_Expr (Start_Node) else "1")
                 & ", "
                 & (if Count_Node /= 0 then Emit_Expr (Count_Node) else "0")
                 & ") })";
            end;
         when AST_Str_Concat =>
            return "unsafe { _alb_concat("
              & Emit_Str (Tree (N).Left_Child) & ", "
              & Emit_Str (Tree (N).Right_Child) & ") }";
         when AST_Func_Call =>
            declare
               Tgt_Node : constant Node_Index := Tree (N).Left_Child;
               Is_Member : constant Boolean :=
                 (Tgt_Node /= 0 and then Tree (Tgt_Node).Kind = AST_Member_Expr);
               Tgt : constant String :=
                 (if Is_Member then "" else Node_Name (Tgt_Node));
               Sym : constant Natural :=
                 (if Tgt'Length > 0 then Lookup_Array (Tgt) else 0);
               ArgL      : constant Node_Index := Tree (N).Right_Child;
               First_Arg : constant Node_Index :=
                 (if ArgL /= 0 and then Tree (ArgL).Kind = AST_Arg_List
                  then Tree (ArgL).Left_Child else ArgL);
            begin
               --  String builtins that arrive as plain calls
               if Tgt = "CHR" or else Tgt = "chr" then
                  return "unsafe { _alb_chr("
                    & (if First_Arg /= 0 then Emit_Expr (First_Arg) else "0")
                    & ") }";
               elsif Tgt = "ASC" or else Tgt = "asc" then
                  return "("
                    & (if First_Arg /= 0 then Emit_Str (First_Arg)
                       else """""")
                    & ".bytes().next().unwrap_or(0) as i32)";
               end if;
               if Sym /= 0 then
                  declare
                     Ref : constant String :=
                       Emit_Array_Ref (Sym, Tgt, First_Arg);
                  begin
                     if Symbols (Sym).Is_Global then
                        return "unsafe { " & Ref & " }";
                     else
                        return Ref;
                     end if;
                  end;
               else
                  return Emit_Func_Call (Emit_Call_Target (Tgt_Node),
                                         Tree (N).Right_Child);
               end if;
            end;
         when AST_Call_Stmt =>
            return Emit_Expr (Tree (N).Left_Child);
         when others =>
            return "/* micro-alb: unsupported expr " & Node_Kind'Image (K) & " */";
      end case;
   end Emit_Expr;

   --  Re-emit a source string literal as valid UTF-8 Rust.  ALB source is
   --  Latin-1-ish byte text; bytes >= 0x80 become \u{XX} (codepoint = byte
   --  value), backslash/quote escapes are preserved as \u{} too so the
   --  tokenizer's raw spelling can never produce malformed Rust.
   function Emit_String_Lit (Raw : String) return String is
      use Ada.Strings.Unbounded;
      Buf    : Unbounded_String := To_Unbounded_String ("""");
      Lo     : constant Natural :=
        (if Raw'Length >= 2 and then Raw (Raw'First) = '"'
         then Raw'First + 1 else Raw'First);
      Hi     : constant Natural :=
        (if Raw'Length >= 2 and then Raw (Raw'Last) = '"'
         then Raw'Last - 1 else Raw'Last);
      Hex    : constant String := "0123456789abcdef";
   begin
      for I in Lo .. Hi loop
         declare
            C : constant Character := Raw (I);
            V : constant Natural := Character'Pos (C);
         begin
            if C = '"' then
               Append (Buf, "\u{22}");
            elsif C = '\' then
               Append (Buf, "\u{5c}");
            elsif V < 16#20# or else V >= 16#7F# then
               Append (Buf, "\u{");
               if V >= 16 then
                  Append (Buf, Hex (V / 16 + 1));
               end if;
               Append (Buf, Hex (V mod 16 + 1));
               Append (Buf, "}");
            else
               Append (Buf, C);
            end if;
         end;
      end loop;
      Append (Buf, """");
      return To_String (Buf);
   end Emit_String_Lit;

   function Lookup_Routine (Name : String) return Natural is
   begin
      for I in 1 .. Routine_Count loop
         if Routines (I).Active and then To_String (Routines (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Lookup_Routine;

   procedure Register_Routine (Name : String; Returns : String) is
   begin
      if Routine_Count >= Max_Routines or else Lookup_Routine (Name) /= 0 then
         return;
      end if;
      Routine_Count := Routine_Count + 1;
      Routines (Routine_Count) :=
        (Active  => True,
         Name    => To_Unbounded_String (Name),
         Returns => To_Unbounded_String (Returns));
   end Register_Routine;

   function Expr_Is_String (N : Node_Index) return Boolean is
   begin
      if N = 0 then
         return False;
      end if;
      case Tree (N).Kind is
         when AST_String_Expr =>
            return True;
         when AST_Str_Left | AST_Str_Right | AST_Str_Mid | AST_Str_Concat =>
            return True;
         when AST_Var_Expr | AST_Const_Ref =>
            if Tree (N).Left_Child /= 0 then
               --  Indexed access on a string yields a byte (i32), not a str.
               return False;
            end if;
            declare
               Nam : constant String := Token_Text (Tree (N).Token_Index);
               Key : constant String :=
                 (if Tree (N).Kind = AST_Const_Ref
                    and then Nam'Length > 0 and then Nam (Nam'First) = '#'
                  then Safe_Ident (Nam (Nam'First + 1 .. Nam'Last))
                  else Node_Name (N));
               Idx : constant Natural := Lookup_Symbol (Key);
            begin
               return Idx /= 0
                 and then To_String (Symbols (Idx).Rust_Type) = "&'static str";
            end;
         when AST_BinOp =>
            declare
               Op : constant String := Token_Text (Tree (N).Token_Index);
            begin
               return Op = "|" or else Op = "&";
            end;
         when AST_Func_Call =>
            declare
               Tgt : constant Node_Index := Tree (N).Left_Child;
               TN  : constant String :=
                 (if Tgt /= 0
                    and then Tree (Tgt).Kind /= AST_Member_Expr
                  then Node_Name (Tgt) else "");
            begin
               --  CHR(...) yields a string; ASC(...) yields a byte.
               if TN = "CHR" or else TN = "chr" then
                  return True;
               elsif TN = "ASC" or else TN = "asc" then
                  return False;
               end if;
               if Tgt /= 0 and then Tree (Tgt).Kind = AST_Member_Expr then
                  --  Module.Name(args): use the leaf member name
                  declare
                     R : constant Natural :=
                       Lookup_Routine (Node_Name (Tree (Tgt).Right_Child));
                  begin
                     return R /= 0
                       and then To_String (Routines (R).Returns)
                                = "&'static str";
                  end;
               else
                  declare
                     R : constant Natural := Lookup_Routine (Node_Name (Tgt));
                  begin
                     return R /= 0
                       and then To_String (Routines (R).Returns)
                                = "&'static str";
                  end;
               end if;
            end;
         when others =>
            return False;
      end case;
   end Expr_Is_String;

   function Emit_Str (N : Node_Index) return String is
   begin
      if Expr_Is_String (N) then
         return Emit_Expr (N);
      else
         return "_alb_str_i32(" & Emit_Expr (N) & ")";
      end if;
   end Emit_Str;

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
   procedure Emit_Procedure_Decl (N : Node_Index);
   procedure Emit_Function_Decl (N : Node_Index);
   procedure Emit_Module_Decl (N : Node_Index);
   procedure Emit_Strict_Decl (N : Node_Index; Global : Boolean);

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
                  declare
                     L   : constant Node_Index := Tree (N).Left_Child;
                     Rhs : constant String := Emit_Expr (Tree (N).Right_Child);
                  begin
                     if Tree (L).Kind = AST_Var_Expr
                       and then Tree (L).Left_Child /= 0
                     then
                        declare
                           Name : constant String := Node_Name (L);
                           Sym  : constant Natural := Lookup_Array (Name);
                           Ref  : constant String :=
                             Emit_Array_Ref (Sym, Name, Tree (L).Left_Child);
                        begin
                           if Sym /= 0 and then Symbols (Sym).Is_Global then
                              Out_Line ("unsafe { " & Ref & " = " & Rhs & "; }");
                           else
                              Out_Line (Ref & " = " & Rhs & ";");
                           end if;
                        end;
                     elsif Tree (L).Kind = AST_Func_Call
                       and then Tree (L).Left_Child /= 0
                       and then Tree (Tree (L).Left_Child).Kind /= AST_Member_Expr
                     then
                        declare
                           CName : constant String :=
                             Node_Name (Tree (L).Left_Child);
                           Sym   : constant Natural := Lookup_Array (CName);
                           ArgL  : constant Node_Index := Tree (L).Right_Child;
                           First : constant Node_Index :=
                             (if ArgL /= 0
                                and then Tree (ArgL).Kind = AST_Arg_List
                              then Tree (ArgL).Left_Child else ArgL);
                           Ref   : constant String :=
                             Emit_Array_Ref (Sym, CName, First);
                        begin
                           if Sym /= 0 and then Symbols (Sym).Is_Global then
                              Out_Line ("unsafe { " & Ref & " = " & Rhs & "; }");
                           else
                              Out_Line (Ref & " = " & Rhs & ";");
                           end if;
                        end;
                     else
                        Out_Line (Emit_Expr (L) & " = " & Rhs & ";");
                     end if;
                  end;
               else
                  Out_Line (Emit_Expr (N) & ";");
               end if;
            end;

         when AST_Let_Stmt =>
            declare
               Tgt  : constant Node_Index := Tree (N).Left_Child;
               Name : constant String := Node_Name (Tgt);
               TTok : constant Natural := Tree (N).Token_Index;
               Init : constant String := Emit_Expr (Tree (N).Right_Child);
               Indexed : constant Boolean :=
                 (Tgt /= 0
                  and then Tree (Tgt).Kind = AST_Var_Expr
                  and then Tree (Tgt).Left_Child /= 0);
               Call_Idx : constant Boolean :=
                 (Tgt /= 0
                  and then Tree (Tgt).Kind = AST_Func_Call
                  and then Tree (Tgt).Left_Child /= 0
                  and then Tree (Tree (Tgt).Left_Child).Kind /= AST_Member_Expr
                  and then Lookup_Array
                    (Node_Name (Tree (Tgt).Left_Child)) /= 0);
               Already : constant Boolean := Is_Declared (Name);
            begin
               if Indexed then
                  declare
                     Sym : constant Natural := Lookup_Array (Name);
                     Ref : constant String :=
                       Emit_Array_Ref (Sym, Name, Tree (Tgt).Left_Child);
                  begin
                     if Sym /= 0 and then Symbols (Sym).Is_Global then
                        Out_Line ("unsafe { " & Ref & " = " & Init & "; }");
                     else
                        Out_Line (Ref & " = " & Init & ";");
                     end if;
                  end;
               elsif Call_Idx then
                  declare
                     CName : constant String :=
                       Node_Name (Tree (Tgt).Left_Child);
                     Sym   : constant Natural := Lookup_Array (CName);
                     ArgL  : constant Node_Index := Tree (Tgt).Right_Child;
                     First : constant Node_Index :=
                       (if ArgL /= 0
                          and then Tree (ArgL).Kind = AST_Arg_List
                        then Tree (ArgL).Left_Child else ArgL);
                     Ref   : constant String :=
                       Emit_Array_Ref (Sym, CName, First);
                  begin
                     if Symbols (Sym).Is_Global then
                        Out_Line ("unsafe { " & Ref & " = " & Init & "; }");
                     else
                        Out_Line (Ref & " = " & Init & ";");
                     end if;
                  end;
               elsif Already then
                  Out_Line (Name & " = " & Init & ";");
               elsif Inside_Fn
                 and then Lookup_Symbol (Name) /= 0
                 and then Symbols (Lookup_Symbol (Name)).Is_Global
               then
                  --  Reassignment of a file-scope static from a routine.
                  declare
                     Qual : constant String :=
                       (if Symbols (Lookup_Symbol (Name)).Root_Level
                          and then Inside_Module
                        then "crate::" else "");
                  begin
                     Out_Line
                       ("unsafe { " & Qual & Name & " = " & Init & "; }");
                  end;
               elsif TTok /= 0 then
                  Out_Line ("let mut " & Name & " : " & Rust_Type (TTok) & " = " & Init & ";");
               else
                  Out_Line ("let mut " & Name & " = " & Init & ";");
               end if;
               if not Indexed and then not Call_Idx and then not Already then
                  Add_Declared (Name);
                  Add_Symbol
                    (Name,
                     (if TTok /= 0 then Rust_Type (TTok)
                      elsif Expr_Is_String (Tree (N).Right_Child)
                      then "&'static str" else "i32"));
               end if;
            end;

         when AST_Strict_Stmt | AST_Slide_Stmt =>
            Emit_Strict_Decl (N, Global => not Inside_Fn);

         when AST_Const_Decl =>
            declare
               Name : constant String := Node_Name (Tree (N).Left_Child);
               Init : constant String := Emit_Expr (Tree (N).Right_Child);
               V    : Long_Long_Integer;
            begin
               Out_Line ("const " & Name & " : i32 = " & Init & ";");
               Add_Symbol (Name, "i32", Sym_Const);
               if Lookup_Symbol (Name) > 0
                 and then Eval_Static_Int (Tree (N).Right_Child, V)
               then
                  Symbols (Lookup_Symbol (Name)).Const_Val := V;
                  Symbols (Lookup_Symbol (Name)).Has_Const := True;
               end if;
            end;

         when AST_Print_Stmt =>
            if Expr_Is_String (Tree (N).Left_Child) then
               Out_Line ("_alb_print_str(" & Emit_Expr (Tree (N).Left_Child) & ");");
            else
               Out_Line ("_alb_print_i32(" & Emit_Expr (Tree (N).Left_Child) & ");");
            end if;
            Out_Line ("_alb_print_newline();");

         when AST_Print_Str_Stmt =>
            Emit_Print_String (Tree (N).Left_Child);
            Out_Line ("_alb_print_newline();");

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
            declare
               Then_Node : constant Node_Index := Tree (N).Right_Child;
               Else_Node : constant Node_Index := Tree (Then_Node).Next_Sibling;
            begin
               Out_Line ("if " & Emit_Expr (Tree (N).Left_Child) & " {");
               Indent_Level := Indent_Level + 1;
               Emit_Node (Then_Node);
               Indent_Level := Indent_Level - 1;
               Out_Line ("}");
               if Else_Node /= 0 then
                  Out_Line ("else {");
                  Indent_Level := Indent_Level + 1;
                  Emit_Node (Else_Node);
                  Indent_Level := Indent_Level - 1;
                  Out_Line ("}");
               end if;
            end;

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

         when AST_Procedure_Decl =>
            Emit_Procedure_Decl (N);

         when AST_Function_Decl =>
            Emit_Function_Decl (N);

         when AST_Struct_Decl | AST_Enum_Decl | AST_Range_Type_Decl |
              AST_DeclareModule | AST_Module =>
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

   function Params_For (Name_Node : Node_Index) return String is
      List_Node : constant Node_Index := Tree (Name_Node).Right_Child;
      Result    : Unbounded_String := To_Unbounded_String ("");
      First     : Boolean := True;
      Param     : Node_Index := 0;
   begin
      if List_Node /= 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Param := Tree (List_Node).Left_Child;
         while Param /= 0 loop
            if Tree (Param).Kind = AST_Param_Decl then
               declare
                  Param_Name_Node : constant Node_Index := Tree (Param).Left_Child;
                  Param_Name      : constant String :=
                    (if Param_Name_Node /= 0
                     then Safe_Ident (Token_Text (Tree (Param_Name_Node).Token_Index))
                     else "_");
                  Type_Node       : constant Node_Index := Tree (Param).Right_Child;
                  Param_Type      : constant String :=
                    (if Type_Node /= 0 and then Tree (Type_Node).Token_Index /= 0
                     then Rust_Type (Tree (Type_Node).Token_Index)
                     else "i32");
               begin
                  if not First then
                     Append (Result, ", ");
                  end if;
                  Append (Result, Param_Name & ": " & Param_Type);
                  First := False;
               end;
            end if;
            Param := Tree (Param).Next_Sibling;
         end loop;
      end if;
      return To_String (Result);
   end Params_For;

   --  Mirror Params_For, but register each parameter in the symbol table so
   --  expression typing (Expr_Is_String, indexed access, etc.) sees them.
   procedure Register_Params (Name_Node : Node_Index) is
      List_Node : constant Node_Index := Tree (Name_Node).Right_Child;
      Param     : Node_Index := 0;
   begin
      if List_Node = 0 or else Tree (List_Node).Kind /= AST_Arg_List then
         return;
      end if;
      Param := Tree (List_Node).Left_Child;
      while Param /= 0 loop
         if Tree (Param).Kind = AST_Param_Decl then
            declare
               Param_Name_Node : constant Node_Index := Tree (Param).Left_Child;
               Param_Name      : constant String :=
                 (if Param_Name_Node /= 0
                  then Safe_Ident (Token_Text (Tree (Param_Name_Node).Token_Index))
                  else "_");
               Type_Node       : constant Node_Index := Tree (Param).Right_Child;
               Param_Type      : constant String :=
                 (if Type_Node /= 0 and then Tree (Type_Node).Token_Index /= 0
                  then Rust_Type (Tree (Type_Node).Token_Index)
                  else "i32");
            begin
               Add_Symbol (Param_Name, Param_Type);
            end;
         end if;
         Param := Tree (Param).Next_Sibling;
      end loop;
   end Register_Params;

   procedure Emit_Procedure_Decl (N : Node_Index) is
      Name_Node : constant Node_Index := Tree (N).Left_Child;
      Name      : constant String := Node_Name (Name_Node);
      Body_Node : constant Node_Index := Tree (N).Right_Child;
      Params    : constant String := Params_For (Name_Node);
   begin
      Out_Line ("pub fn " & Name & "(" & Params & ") {");
      Indent_Level := Indent_Level + 1;
      Reset_Declared;
      Register_Params (Name_Node);
      Inside_Fn := True;
      Emit_Node (Body_Node);
      Inside_Fn := False;
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Procedure_Decl;

   procedure Emit_Function_Decl (N : Node_Index) is
      Name_Node : constant Node_Index := Tree (N).Left_Child;
      Name      : constant String := Node_Name (Name_Node);
      Body_Node : constant Node_Index := Tree (N).Right_Child;
      Params    : constant String := Params_For (Name_Node);
      TTok      : constant Natural := Tree (N).Token_Index;
      Ret_Type  : constant String := (if TTok /= 0 then Rust_Type (TTok) else "i32");
   begin
      Register_Routine (Name, Ret_Type);
      Out_Line ("pub fn " & Name & "(" & Params & ") -> " & Ret_Type & " {");
      Indent_Level := Indent_Level + 1;
      Reset_Declared;
      Register_Params (Name_Node);
      Inside_Fn := True;
      Emit_Node (Body_Node);
      Inside_Fn := False;
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Function_Decl;

   function Zero_Lit (Rust_T : String) return String is
   begin
      if Rust_T = "f32" or else Rust_T = "f64" then
         return "0.0";
      elsif Rust_T = "bool" then
         return "false";
      elsif Rust_T = "&'static str" then
         return """""";
      else
         return "0";
      end if;
   end Zero_Lit;

   function Trim_LLI (V : Long_Long_Integer) return String is
      Img : constant String := Long_Long_Integer'Image (V);
   begin
      if Img'Length > 0 and then Img (Img'First) = ' ' then
         return Img (Img'First + 1 .. Img'Last);
      end if;
      return Img;
   end Trim_LLI;

   function Eval_Static_Int
     (N : Node_Index; Value : out Long_Long_Integer) return Boolean
   is
      function Parse_Based (Raw : String; Base : Natural;
                            First, Last : Natural) return Long_Long_Integer is
         Result : Long_Long_Integer := 0;
      begin
         for I in First .. Last loop
            declare
               C : constant Character := Raw (I);
               D : Natural;
            begin
               if C in '0' .. '9' then
                  D := Character'Pos (C) - Character'Pos ('0');
               elsif C in 'a' .. 'f' then
                  D := Character'Pos (C) - Character'Pos ('a') + 10;
               elsif C in 'A' .. 'F' then
                  D := Character'Pos (C) - Character'Pos ('A') + 10;
               else
                  raise Constraint_Error;
               end if;
               if D >= Base then
                  raise Constraint_Error;
               end if;
               Result := Result * Long_Long_Integer (Base) + Long_Long_Integer (D);
            end;
         end loop;
         return Result;
      end Parse_Based;

      LV, RV : Long_Long_Integer;
      Op     : Unbounded_String;
   begin
      Value := 0;
      if N = 0 then
         return False;
      end if;
      case Tree (N).Kind is
         when AST_Number_Expr =>
            declare
               Img : constant String := Token_Text (Tree (N).Token_Index);
               Buf : String (1 .. Img'Length);
               Len : Natural := 0;
            begin
               for C of Img loop
                  if C /= '_' then
                     Len := Len + 1;
                     Buf (Len) := C;
                  end if;
               end loop;
               Value := Long_Long_Integer'Value (Buf (1 .. Len));
               return True;
            exception
               when others => return False;
            end;
         when AST_Hex_Expr =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Raw'Length > 1 and then Raw (Raw'First) = '$' then
                  Value := Parse_Based (Raw, 16, Raw'First + 1, Raw'Last);
                  return True;
               elsif Raw'Length > 2
                 and then Raw (Raw'First) = '0'
                 and then Raw (Raw'First + 1) in 'x' | 'X'
               then
                  Value := Parse_Based (Raw, 16, Raw'First + 2, Raw'Last);
                  return True;
               end if;
               return False;
            exception
               when others => return False;
            end;
         when AST_Bin_Expr =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Raw'Length > 1 and then Raw (Raw'First) = '%' then
                  Value := Parse_Based (Raw, 2, Raw'First + 1, Raw'Last);
                  return True;
               elsif Raw'Length > 2
                 and then Raw (Raw'First) = '0'
                 and then Raw (Raw'First + 1) in 'b' | 'B'
               then
                  Value := Parse_Based (Raw, 2, Raw'First + 2, Raw'Last);
                  return True;
               end if;
               return False;
            exception
               when others => return False;
            end;
         when AST_Octal_Expr =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
            begin
               if Raw'Length > 2
                 and then Raw (Raw'First) = '&'
                 and then Raw (Raw'First + 1) in 'o' | 'O'
               then
                  Value := Parse_Based (Raw, 8, Raw'First + 2, Raw'Last);
                  return True;
               elsif Raw'Length > 2
                 and then Raw (Raw'First) = '0'
                 and then Raw (Raw'First + 1) in 'o' | 'O'
               then
                  Value := Parse_Based (Raw, 8, Raw'First + 2, Raw'Last);
                  return True;
               end if;
               return False;
            exception
               when others => return False;
            end;
         when AST_Const_Ref =>
            declare
               Raw : constant String := Token_Text (Tree (N).Token_Index);
               Nam : constant String :=
                 (if Raw'Length > 0 and then Raw (Raw'First) = '#'
                  then Safe_Ident (Raw (Raw'First + 1 .. Raw'Last))
                  else Safe_Ident (Raw));
               Idx : constant Natural := Lookup_Symbol (Nam);
            begin
               if Idx /= 0
                 and then Symbols (Idx).Kind = Sym_Const
                 and then Symbols (Idx).Has_Const
               then
                  Value := Symbols (Idx).Const_Val;
                  return True;
               end if;
               return False;
            end;
         when AST_Unary_Minus =>
            if Eval_Static_Int (Tree (N).Left_Child, LV) then
               Value := -LV;
               return True;
            end if;
            return False;
         when AST_BinOp =>
            Op := To_Unbounded_String (Token_Text (Tree (N).Token_Index));
            if not Eval_Static_Int (Tree (N).Left_Child, LV)
              or else not Eval_Static_Int (Tree (N).Right_Child, RV)
            then
               return False;
            end if;
            declare
               O : constant String := To_String (Op);
            begin
               if O = "+" then Value := LV + RV; return True;
               elsif O = "-" then Value := LV - RV; return True;
               elsif O = "*" then Value := LV * RV; return True;
               elsif O = "/" and then RV /= 0 then Value := LV / RV; return True;
               elsif O = "MOD" and then RV /= 0 then Value := LV mod RV; return True;
               else return False;
               end if;
            end;
         when others =>
            return False;
      end case;
   end Eval_Static_Int;

   function Lookup_Array (Name : String) return Natural is
   begin
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then Symbols (I).Kind = Sym_Array
           and then To_String (Symbols (I).Name) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Lookup_Array;

   procedure Register_Array
     (Name : String; Rust_T : String; R : Natural;
      D : Dim_Array; Global : Boolean; Root_Level : Boolean)
   is
   begin
      if Symbol_Count >= Max_Symbols or else Lookup_Array (Name) /= 0 then
         return;
      end if;
      Symbol_Count := Symbol_Count + 1;
      Symbols (Symbol_Count) :=
        (Active    => True,
         Name      => To_Unbounded_String (Name),
         Rust_Type => To_Unbounded_String (Rust_T),
         Kind      => Sym_Array,
         Rank      => R,
         Dims      => D,
         Is_Global => Global,
         Root_Level => Root_Level,
         Const_Val => 0,
         Has_Const => False);
   end Register_Array;

   function Emit_Array_Ref
     (Sym : Natural; Name : String; First_Idx : Node_Index) return String
   is
      Acc     : Unbounded_String := To_Unbounded_String ("");
      Idx     : Node_Index := First_Idx;
      Dim_Pos : Natural := 1;
      E       : Unbounded_String;
   begin
      while Idx /= 0 loop
         E := To_Unbounded_String (Emit_Expr (Idx));
         if Dim_Pos = 1 then
            Acc := E;
         elsif Sym /= 0
           and then Dim_Pos <= Symbols (Sym).Rank
           and then Symbols (Sym).Dims (Dim_Pos) > 0
         then
            Acc := "(" & Acc & " * "
              & Trim_LLI (Long_Long_Integer (Symbols (Sym).Dims (Dim_Pos)))
              & " + " & E & ")";
         else
            Acc := "(" & Acc & " + " & E & ")";
         end if;
         Dim_Pos := Dim_Pos + 1;
         Idx := Tree (Idx).Next_Sibling;
      end loop;
      if Acc = "" then
         Acc := To_Unbounded_String ("0");
      end if;
      if Sym /= 0 and then Symbols (Sym).Root_Level then
         return "crate::" & Name & "[(" & To_String (Acc) & ") as usize]";
      end if;
      return Name & "[(" & To_String (Acc) & ") as usize]";
   end Emit_Array_Ref;

   procedure Emit_Strict_Decl (N : Node_Index; Global : Boolean) is
      Var_Node : constant Node_Index := Tree (N).Left_Child;
      Name     : constant String := Node_Name (Var_Node);
      Type_Node : constant Node_Index :=
        (if Var_Node /= 0 then Tree (Var_Node).Right_Child else 0);
      Elem_T   : constant String :=
        (if Type_Node /= 0 and then Tree (Type_Node).Token_Index /= 0
         then Rust_Type (Tree (Type_Node).Token_Index)
         else "i32");
      Dim_Node : Node_Index := Tree (N).Right_Child;
      D        : Dim_Array := (others => 0);
      R        : Natural := 0;
      Total    : Long_Long_Integer := 1;
      DimV     : Long_Long_Integer;
      Ok       : Boolean := True;
   begin
      if Var_Node = 0 then
         return;
      end if;
      while Dim_Node /= 0 and then R < Max_Rank loop
         R := R + 1;
         if Eval_Static_Int (Dim_Node, DimV) and then DimV > 0 then
            D (R) := Natural (DimV);
            Total := Total * DimV;
         else
            Ok := False;
            D (R) := 1;
         end if;
         Dim_Node := Tree (Dim_Node).Next_Sibling;
      end loop;
      if not Ok or else R = 0 then
         if Global then
            Out_Line ("// micro-alb: STRICT " & Name
                      & " skipped (non-static bounds)");
         else
            Out_Line ("// micro-alb: STRICT " & Name
                      & " skipped (non-static bounds)");
         end if;
         return;
      end if;
      if Global then
         Out_Line ("#[allow(non_upper_case_globals)]");
         Out_Line ("static mut " & Name & " : [" & Elem_T & "; "
                   & Trim_LLI (Total) & "] = [" & Zero_Lit (Elem_T)
                   & "; " & Trim_LLI (Total) & "];");
      else
         Out_Line ("let mut " & Name & " : [" & Elem_T & "; "
                   & Trim_LLI (Total) & "] = [" & Zero_Lit (Elem_T)
                   & "; " & Trim_LLI (Total) & "];");
      end if;
      Register_Array (Name, Elem_T, R, D, Global,
                      Root_Level => Global and then not Inside_Module);
      Add_Declared (Name);
   end Emit_Strict_Decl;

   procedure Emit_Module_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
   begin
      Out_Line ("pub mod " & Name & " {");
      Indent_Level := Indent_Level + 1;
      Out_Line ("use super::support::{_alb_print_i32, _alb_print_str, _alb_print_newline};");
      Out_Line ("use super::{_alb_concat, _alb_str_i32, _alb_chr, _alb_left, _alb_right, _alb_mid};");
      Inside_Module := True;
      Emit_Node (Tree (N).Right_Child);
      Inside_Module := False;
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
   end Emit_Module_Decl;

   procedure Emit_DeclareModule_Decl (N : Node_Index) is
      Name : constant String := Node_Name (Tree (N).Left_Child);
   begin
      if Name = "_" then
         return;
      end if;
      Out_Line ("pub mod " & Name & " {");
      Indent_Level := Indent_Level + 1;
      Out_Line ("use super::support::{_alb_print_i32, _alb_print_str, _alb_print_newline};");
      Out_Line ("use super::{_alb_concat, _alb_str_i32, _alb_chr, _alb_left, _alb_right, _alb_mid};");
      Inside_Module := True;
      Emit_Node (Tree (N).Right_Child);
      Inside_Module := False;
      Indent_Level := Indent_Level - 1;
      Out_Line ("}");
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
      Out_Line ("#[no_mangle]");
      Out_Line ("extern ""C"" fn rust_eh_personality() {}");
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
      Out_Line ("#[allow(static_mut_refs)]");
      Out_Line ("unsafe fn _alb_copy_out(src: &[u8], n: usize) -> &'static str {");
      Out_Line ("    let p = _alb_claim(n);");
      Out_Line ("    core::ptr::copy_nonoverlapping(src.as_ptr(), p, n);");
      Out_Line ("    core::str::from_utf8_unchecked(core::slice::from_raw_parts(p, n))");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("unsafe fn _alb_concat(a: &str, b: &str) -> &'static str {");
      Out_Line ("    let na = a.len();");
      Out_Line ("    let nb = b.len();");
      Out_Line ("    let p = _alb_claim(na + nb);");
      Out_Line ("    core::ptr::copy_nonoverlapping(a.as_ptr(), p, na);");
      Out_Line ("    core::ptr::copy_nonoverlapping(b.as_ptr(), p.add(na), nb);");
      Out_Line ("    core::str::from_utf8_unchecked(core::slice::from_raw_parts(p, na + nb))");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("unsafe fn _alb_str_i32(v: i32) -> &'static str {");
      Out_Line ("    let mut buf: [u8; 12] = [0; 12];");
      Out_Line ("    let mut n = v;");
      Out_Line ("    let mut i: usize = 12;");
      Out_Line ("    if n < 0 { n = -n; }");
      Out_Line ("    loop {");
      Out_Line ("        i -= 1;");
      Out_Line ("        buf[i] = b'0' + (n % 10) as u8;");
      Out_Line ("        n /= 10;");
      Out_Line ("        if n == 0 { break; }");
      Out_Line ("    }");
      Out_Line ("    if v < 0 { i -= 1; buf[i] = b'-'; }");
      Out_Line ("    _alb_copy_out(&buf[i..], 12 - i)");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("unsafe fn _alb_chr(v: i32) -> &'static str {");
      Out_Line ("    let buf: [u8; 1] = [v as u8];");
      Out_Line ("    _alb_copy_out(&buf, 1)");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("unsafe fn _alb_left(s: &str, n: i32) -> &'static str {");
      Out_Line ("    if n <= 0 { return _alb_copy_out(&[], 0); }");
      Out_Line ("    let end = match s.char_indices().nth(n as usize) {");
      Out_Line ("        Some((i, _)) => i,");
      Out_Line ("        None => s.len(),");
      Out_Line ("    };");
      Out_Line ("    _alb_copy_out(&s.as_bytes()[..end], end)");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("unsafe fn _alb_right(s: &str, n: i32) -> &'static str {");
      Out_Line ("    if n <= 0 { return _alb_copy_out(&[], 0); }");
      Out_Line ("    let start = match s.char_indices().nth_back(n as usize - 1) {");
      Out_Line ("        Some((i, _)) => i,");
      Out_Line ("        None => 0,");
      Out_Line ("    };");
      Out_Line ("    _alb_copy_out(&s.as_bytes()[start..], s.len() - start)");
      Out_Line ("}");
      Out_Line ("");
      Out_Line ("unsafe fn _alb_mid(s: &str, start1: i32, count: i32) -> &'static str {");
      Out_Line ("    if count <= 0 { return _alb_copy_out(&[], 0); }");
      Out_Line ("    let lo = if start1 <= 1 { 0 } else {");
      Out_Line ("        match s.char_indices().nth(start1 as usize - 1) {");
      Out_Line ("            Some((i, _)) => i,");
      Out_Line ("            None => return _alb_copy_out(&[], 0),");
      Out_Line ("        }");
      Out_Line ("    };");
      Out_Line ("    let tail = &s[lo..];");
      Out_Line ("    let hi = match tail.char_indices().nth(count as usize) {");
      Out_Line ("        Some((i, _)) => lo + i,");
      Out_Line ("        None => s.len(),");
      Out_Line ("    };");
      Out_Line ("    _alb_copy_out(&s.as_bytes()[lo..hi], hi - lo)");
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

   function Module_Has_Statements (N : Node_Index) return Boolean is
      B : constant Node_Index := (if N = 0 then 0 else Tree (N).Right_Child);
   begin
      return B /= 0 and then Tree (B).Left_Child /= 0;
   end Module_Has_Statements;

   function Find_Sibling_Module
     (Start : Node_Index; Kind : Node_Kind; Name : String) return Node_Index
   is
      C : Node_Index := Start;
   begin
      while C /= 0 loop
         if Tree (C).Kind = Kind
           and then Node_Name (Tree (C).Left_Child) = Name
         then
            return C;
         end if;
         C := Tree (C).Next_Sibling;
      end loop;
      return 0;
   end Find_Sibling_Module;

   function Is_Declared (Name : String) return Boolean is
   begin
      for I in 1 .. Declared_Count loop
         if To_String (Declared_Names (I)) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Is_Declared;

   procedure Add_Declared (Name : String) is
   begin
      if Declared_Count < Max_Declared and then not Is_Declared (Name) then
         Declared_Count := Declared_Count + 1;
         Declared_Names (Declared_Count) := To_Unbounded_String (Name);
      end if;
   end Add_Declared;

   procedure Reset_Declared is
   begin
      Declared_Count := 0;
   end Reset_Declared;

   procedure Compile_To_File
     (Root_Index      : in Node_Index;
      Output_Filename : in String)
   is
      Main_Node : Node_Index := 0;
      Body_Node : Node_Index := 0;
      Curr      : Node_Index := Root_Index;
   begin
      Symbol_Count := 0;
      Routine_Count := 0;
      Comptime_Count := 0;
      Inline_C_Count := 0;
      Reset_Declared;
      Indent_Level := 0;

      Open_Output (Output_Filename);
      Emit_Preamble;

      --  First pass: walk top-level siblings.  Anything that is a program or
      --  bare block is the main entry; declarations and modules are emitted.
      while Curr /= 0 loop
         declare
            K : constant Node_Kind := Tree (Curr).Kind;
         begin
            case K is
               when AST_Program | AST_Block_Stmt =>
                  Main_Node := Curr;
               when AST_Struct_Decl =>
                  Emit_Struct_Decl (Curr);
               when AST_Enum_Decl =>
                  Emit_Enum_Decl (Curr);
               when AST_Range_Type_Decl =>
                  Emit_Range_Type_Decl (Curr);
               when AST_DeclareModule =>
                  declare
                     MName : constant String := Node_Name (Tree (Curr).Left_Child);
                     Impl  : constant Node_Index :=
                       Find_Sibling_Module (Root_Index, AST_Module, MName);
                  begin
                     if Impl = 0 or else not Module_Has_Statements (Impl) then
                        Emit_DeclareModule_Decl (Curr);
                     end if;
                  end;
               when AST_Module =>
                  declare
                     MName : constant String := Node_Name (Tree (Curr).Left_Child);
                  begin
                     if Module_Has_Statements (Curr) then
                        Emit_Module_Decl (Curr);
                     else
                        declare
                           Spec : constant Node_Index :=
                             Find_Sibling_Module (Root_Index, AST_DeclareModule, MName);
                        begin
                           if Spec /= 0 and then Module_Has_Statements (Spec) then
                              Emit_DeclareModule_Decl (Spec);
                           else
                              Emit_Module_Decl (Curr);
                           end if;
                        end;
                     end if;
                  end;
               when AST_Procedure_Decl =>
                  Emit_Procedure_Decl (Curr);
               when AST_Function_Decl =>
                  Emit_Function_Decl (Curr);
               when AST_Strict_Stmt | AST_Slide_Stmt =>
                  Emit_Strict_Decl (Curr, Global => True);
               when others =>
                  null;
            end case;
         end;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      --  Entry point
      if Main_Node /= 0 then
         Body_Node :=
           (if Tree (Main_Node).Kind = AST_Program
            then Tree (Main_Node).Left_Child
            else Main_Node);

         Out_Line ("");
         Out_Line ("fn _alb_main_body() {");
         Indent_Level := 1;
         Inside_Fn := True;
         Emit_Node (Body_Node);
         Inside_Fn := False;
         Indent_Level := 0;
         Out_Line ("}");
      else
         --  No PROGRAM/BEGIN wrapper: bare top-level statements are the
         --  implicit main body.  Declarations were already emitted above.
         Out_Line ("");
         Out_Line ("fn _alb_main_body() {");
         Indent_Level := 1;
         Inside_Fn := True;
         declare
            S : Node_Index := Root_Index;
         begin
            while S /= 0 loop
               case Tree (S).Kind is
                  when AST_DeclareModule | AST_Module | AST_Struct_Decl
                     | AST_Enum_Decl | AST_Range_Type_Decl
                     | AST_Procedure_Decl | AST_Function_Decl
                     | AST_Strict_Stmt | AST_Slide_Stmt | AST_Import_C =>
                     null;
                  when others =>
                     Emit_Node (S);
               end case;
               S := Tree (S).Next_Sibling;
            end loop;
         end;
         Inside_Fn := False;
         Indent_Level := 0;
         Out_Line ("}");
      end if;

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
