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

pragma SPARK_Mode (On);

with Ada.IO_Exceptions;
with Ada.Text_IO;
with Compiler_State; use Compiler_State;

package body Emit_Native_DotNet is

   Max_Output_Size   : constant Natural := 16_777_216;
   Max_Path_Len      : constant Natural := 512;
   Max_Name_Len      : constant Natural := 128;
   Max_Symbols       : constant Natural := 16_384;
   Max_Imports       : constant Natural := 1_024;
   Max_Routines      : constant Natural := 8_192;
   Max_Array_Rank    : constant Natural := 4;
   Max_Logic_Watches : constant Natural := 256;
   Max_User_Structs  : constant Natural := 256;
   Max_User_Fields   : constant Natural := 2_048;
   Max_Advanced_Nodes : constant Natural := 256;

   type DotNet_Value_Kind is
     (Kind_S64,
      Kind_U64,
      Kind_U32,
      Kind_U16,
      Kind_U8,
      Kind_U128,
      Kind_F64,
      Kind_F32,
      Kind_F32x2,
      Kind_F32x4,
      Kind_Mat2x2,
      Kind_Mat3x3,
      Kind_Mat4x4,
      Kind_Bool,
      Kind_String,
      Kind_Pure,
      Kind_Void);

   type Name_Buffer is array (1 .. Max_Name_Len) of Character;
   type Dim_Node_List is array (1 .. Max_Array_Rank) of Node_Index;

   type DotNet_Symbol_Shape is
     (Shape_Scalar,
      Shape_Const,
      Shape_Strict_Array,
      Shape_Slide_Array,
      Shape_Parallel_Field,
      Shape_Temporal);

   type Symbol_Record is record
      Active       : Boolean := False;
      Name         : Name_Buffer := (others => ' ');
      Name_Len     : Natural := 0;
      Emit_Name    : Name_Buffer := (others => ' ');
      Emit_Name_Len : Natural := 0;
      Type_Token   : Natural := 0;
      Kind         : DotNet_Value_Kind := Kind_S64;
      Shape        : DotNet_Symbol_Shape := Shape_Scalar;
      Init_Node    : Node_Index := 0;
      Rank         : Natural := 0;
      Dims         : Dim_Node_List := (others => 0);
      Active_Node  : Node_Index := 0;
      History_Node : Node_Index := 0;
      Module_Token : Natural := 0;
      Routine_Node : Node_Index := 0;
   end record;

   type Import_Record is record
      Active : Boolean := False;
      Node   : Node_Index := 0;
   end record;

   type Routine_Record is record
      Active       : Boolean := False;
      Name         : Name_Buffer := (others => ' ');
      Name_Len     : Natural := 0;
      Node         : Node_Index := 0;
      Is_Function  : Boolean := False;
      Module_Token : Natural := 0;
   end record;

   type User_Struct_Record is record
      Active   : Boolean := False;
      Name     : Name_Buffer := (others => ' ');
      Name_Len : Natural := 0;
   end record;

   type User_Struct_Field_Record is record
      Active          : Boolean := False;
      Struct_Name     : Name_Buffer := (others => ' ');
      Struct_Name_Len : Natural := 0;
      Field_Name      : Name_Buffer := (others => ' ');
      Field_Name_Len  : Natural := 0;
      Type_Token      : Natural := 0;
      Kind            : DotNet_Value_Kind := Kind_S64;
   end record;

   type Named_Node_Record is record
      Active   : Boolean := False;
      Name     : Name_Buffer := (others => ' ');
      Name_Len : Natural := 0;
      Node     : Node_Index := 0;
   end record;

   type Watch_Node_List is array (1 .. Max_Logic_Watches) of Node_Index;

   Output_Buffer : String (1 .. Max_Output_Size) := (others => ' ');
   Output_Len    : Natural := 0;
   Output_Path   : String (1 .. Max_Path_Len) := (others => ' ');
   Output_Flen   : Natural := 0;
   Indent_Level  : Natural := 0;
   At_Line_Start : Boolean := True;

   Symbols      : array (1 .. Max_Symbols) of Symbol_Record;
   Symbol_Count : Natural := 0;
   Imports      : array (1 .. Max_Imports) of Import_Record;
   Import_Count : Natural := 0;
   Routines      : array (1 .. Max_Routines) of Routine_Record;
   Routine_Count : Natural := 0;
   User_Structs  : array (1 .. Max_User_Structs) of User_Struct_Record;
   User_Struct_Count : Natural := 0;
   User_Struct_Fields : array (1 .. Max_User_Fields) of User_Struct_Field_Record;
   User_Field_Count   : Natural := 0;
   Markov_Models : array (1 .. Max_Advanced_Nodes) of Named_Node_Record;
   Markov_Model_Count : Natural := 0;
   Neural_Models : array (1 .. Max_Advanced_Nodes) of Named_Node_Record;
   Neural_Model_Count : Natural := 0;
   Network_Sockets : array (1 .. Max_Advanced_Nodes) of Named_Node_Record;
   Network_Socket_Count : Natural := 0;
   Watch_Nodes   : Watch_Node_List := (others => 0);
   Watch_Count   : Natural := 0;
   Tick_Block    : Node_Index := 0;
   Paint_Block   : Node_Index := 0;
   Key_Block     : Node_Index := 0;
   Temp_Count    : Natural := 0;
   Active_Routine_Module_Token : Natural := 0;
   Active_Routine_Node         : Node_Index := 0;
   Current_Emitter_Diag        : Emitter_Diagnostic_Log;

   function Emit_Raw (Text : String) return Boolean;
   procedure Store_Diagnostic_Message
     (Text   : in String;
      Buffer : out Diagnostic_Message_Buffer;
      Length : out Natural);
   procedure Add_Emitter_Warning
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Category : in Emitter_Diagnostic_Category;
      Message  : in String);
   procedure Mark_Emitter_Fatal
     (Category : in Emitter_Diagnostic_Category;
      Message  : in String;
      Node     : in Node_Index := 0);
   procedure Emit_Warning_Comment
     (Message : in String;
      Success : in out Boolean);
   procedure Emit_Expression_Fallback
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Expected : in DotNet_Value_Kind;
      Category : in Emitter_Diagnostic_Category;
      Message  : in String;
      Success  : in out Boolean);
   procedure Emit_Statement_Warning
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Category : in Emitter_Diagnostic_Category;
      Message  : in String;
      Success  : in out Boolean);
   procedure Emit_Expression
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Expected : in DotNet_Value_Kind;
      Success  : in out Boolean);
   procedure Emit_Import_Arg_List
     (Tokens        : in Token_Array;
      Tree          : in Node_Array;
      Import_Index  : in Natural;
      List          : in Node_Index;
      Success       : in out Boolean);
   procedure Emit_Default_Value
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean);
   procedure Emit_Line
     (Text    : in String;
      Success : in out Boolean);
   procedure Emit_Condition
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean);
   procedure Emit_Token_Name_Content
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Success     : in out Boolean);
   function Token_Text_Copy
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return String;
   procedure Store_Name_Text
     (Text   : in String;
      Buffer : out Name_Buffer;
      Length : out Natural);
   procedure Store_Emit_Name
     (Text   : in String;
      Buffer : out Name_Buffer;
      Length : out Natural);
   procedure Emit_Name_Text
     (Buffer  : in Name_Buffer;
      Length  : in Natural;
      Success : in out Boolean);
   function Name_Equals_Text
     (Buffer : in Name_Buffer;
      Length : in Natural;
      Text   : in String) return Boolean;
   function Name_Has_Prefix
     (Buffer : in Name_Buffer;
      Length : in Natural;
      Prefix : in String) return Boolean;
   function Find_Symbol_By_Text
     (Text         : in String;
      Module_Token : in Natural := 0) return Natural;
   function Find_Local_Symbol
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural;
   function Find_Symbol_In_Context
     (Tokens       : in Token_Array;
      Token_Index  : in Natural;
      Module_Token : in Natural) return Natural;
   function Compose_Module_Emit_Name
     (Tokens       : in Token_Array;
      Module_Token : in Natural;
      Base_Name    : in String) return String;
   function Kind_Storage_Bytes
     (Kind : in DotNet_Value_Kind) return Natural;
   function Find_Target_Symbol
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return Natural;
   function Member_Path_Text
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return String;
   function Leftmost_Member_Token
     (Tree : in Node_Array;
      Node : in Node_Index) return Natural;
   function Predicate_Name_From_Node
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return String;
   function Predicate_First_Arg_Node
     (Tree : in Node_Array;
      Node : in Node_Index) return Node_Index;
   function Predicate_Id_From_Name (Name : in String) return Natural;
   function Find_Member_Routine
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return Natural;
   procedure Register_Markov_Model
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index);
   procedure Register_Neural_Model
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index);
   procedure Register_Network_Socket
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index;
      Module_Token : in Natural);
   function Find_Markov_Model
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural;
   function Find_Neural_Model
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural;
   function Find_Network_Socket
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural;
   procedure Emit_Predicate_Id
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean);
   procedure Emit_Predicate_Arg1
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean);
   procedure Emit_Predicate_Arity
     (Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean);
   procedure Emit_Array_Index
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Dims     : in Dim_Node_List;
      Rank     : in Natural;
      Bounds   : in Node_Index;
      Success  : in out Boolean);
   procedure Emit_Array_Length
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Dims     : in Dim_Node_List;
      Rank     : in Natural;
      Success  : in out Boolean);
   procedure Emit_Target
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean);
   procedure Emit_Assignment_To_Target
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Target  : in Node_Index;
      RHS     : in Node_Index;
      Kind    : in DotNet_Value_Kind;
      Success : in out Boolean);
   procedure Emit_Assignment_Cast_Open
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean);
   procedure Emit_Assignment_Cast_Close
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean);
   procedure Register_Local_Symbol
     (Tokens       : in Token_Array;
      Name_Token   : in Natural;
      Type_Token   : in Natural;
      Kind         : in DotNet_Value_Kind;
      Init_Node    : in Node_Index;
      Allow_Shadow : in Boolean := False);
   procedure Register_Struct_From_Node
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index);
   procedure Register_Struct_Instance_Symbols
     (Tokens       : in Token_Array;
      Name_Token   : in Natural;
      Type_Token   : in Natural;
      Module_Token : in Natural);
   function Is_User_Struct_Type
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Boolean;
   procedure Register_Routine_Params
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      List    : in Node_Index);
   procedure Emit_Local_Declaration
     (Tokens      : in Token_Array;
      Tree        : in Node_Array;
      Name_Token  : in Natural;
      Kind        : in DotNet_Value_Kind;
      RHS         : in Node_Index;
      Success     : in out Boolean);
   function Statement_Guarantees_Return
     (Tree : in Node_Array;
      Node : in Node_Index) return Boolean;
   function Block_Guarantees_Return
     (Tree : in Node_Array;
      Node : in Node_Index) return Boolean;

   function To_Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
   end To_Upper;

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

   procedure Add_Emitter_Warning
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Category : in Emitter_Diagnostic_Category;
      Message  : in String)
   is
      Slot        : Natural := 0;
      Token_Index : Natural := 0;
      Line_No     : Natural := 0;
      Column_No   : Natural := 0;
   begin
      Current_Emitter_Diag.Had_Warnings := True;
      Current_Emitter_Diag.Warning_Count :=
        Current_Emitter_Diag.Warning_Count + 1;
      Compilation_Had_Warnings := True;

      if Node /= 0 then
         Token_Index := Tree (Node).Token_Index;
         if Token_Index /= 0 and then Token_Index <= Tokens'Length then
            Line_No := Natural (Tokens (Token_Index).Line);
            Column_No := Natural (Tokens (Token_Index).Column);
         end if;
      end if;

      if Current_Emitter_Diag.Stored_Count < Max_Emitter_Diagnostics then
         Current_Emitter_Diag.Stored_Count :=
           Current_Emitter_Diag.Stored_Count + 1;
         Slot := Current_Emitter_Diag.Stored_Count;
         Current_Emitter_Diag.Entries (Slot).Active := True;
         Current_Emitter_Diag.Entries (Slot).Node := Node;
         Current_Emitter_Diag.Entries (Slot).Token_Index := Token_Index;
         Current_Emitter_Diag.Entries (Slot).Line := Line_No;
         Current_Emitter_Diag.Entries (Slot).Column := Column_No;
         Current_Emitter_Diag.Entries (Slot).Category := Category;
         Store_Diagnostic_Message
           (Message,
            Current_Emitter_Diag.Entries (Slot).Message,
            Current_Emitter_Diag.Entries (Slot).Message_Len);
      end if;

      Ada.Text_IO.Put_Line
        ("ALBN WARNING [emitter]: node " &
         Natural'Image (Natural (Node)) &
         " line " &
         Natural'Image (Line_No) &
         " col " &
         Natural'Image (Column_No) &
         " -> " &
         Message);
   end Add_Emitter_Warning;

   procedure Mark_Emitter_Fatal
     (Category : in Emitter_Diagnostic_Category;
      Message  : in String;
      Node     : in Node_Index := 0)
   is
      Slot : Natural := 0;
   begin
      Current_Emitter_Diag.Had_Fatal_Error := True;
      Current_Emitter_Diag.Had_Warnings := True;
      Current_Emitter_Diag.Warning_Count :=
        Current_Emitter_Diag.Warning_Count + 1;
      Compilation_Had_Warnings := True;

      if Current_Emitter_Diag.Stored_Count < Max_Emitter_Diagnostics then
         Current_Emitter_Diag.Stored_Count :=
           Current_Emitter_Diag.Stored_Count + 1;
         Slot := Current_Emitter_Diag.Stored_Count;
         Current_Emitter_Diag.Entries (Slot).Active := True;
         Current_Emitter_Diag.Entries (Slot).Node := Node;
         Current_Emitter_Diag.Entries (Slot).Category := Category;
         Store_Diagnostic_Message
           (Message,
            Current_Emitter_Diag.Entries (Slot).Message,
            Current_Emitter_Diag.Entries (Slot).Message_Len);
      end if;

      Ada.Text_IO.Put_Line ("ALBN WARNING [emitter]: " & Message);
   end Mark_Emitter_Fatal;

   procedure Emit_Warning_Comment
     (Message : in String;
      Success : in out Boolean)
   is
   begin
      if not Success then
         return;
      end if;

      Success := Emit_Raw (" /* ALBN WARNING: " & Message & " */");
   end Emit_Warning_Comment;

   procedure Emit_Expression_Fallback
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Expected : in DotNet_Value_Kind;
      Category : in Emitter_Diagnostic_Category;
      Message  : in String;
      Success  : in out Boolean)
   is
   begin
      Add_Emitter_Warning (Tokens, Tree, Node, Category, Message);
      Emit_Default_Value (Expected, Success);
      Emit_Warning_Comment (Message, Success);
   end Emit_Expression_Fallback;

   procedure Emit_Statement_Warning
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Category : in Emitter_Diagnostic_Category;
      Message  : in String;
      Success  : in out Boolean)
   is
   begin
      Add_Emitter_Warning (Tokens, Tree, Node, Category, Message);
      Emit_Line ("/* ALBN WARNING: " & Message & " */", Success);
   end Emit_Statement_Warning;

   function Token_Text_Equals
     (Tokens      : Token_Array;
      Token_Index : Natural;
      Text        : String) return Boolean
   is
      Tok : Token;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return False;
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length /= Text'Length or else Tok.Length = 0 then
         return False;
      end if;

      for I in 0 .. Tok.Length - 1 loop
         if To_Upper (Input_Buffer (Tok.Start + I)) /=
           To_Upper (Text (Text'First + I))
         then
            return False;
         end if;
      end loop;

      return True;
   end Token_Text_Equals;

   function Raw_Name_Equals
     (Name     : Name_Buffer;
      Name_Len : Natural;
      Tokens   : Token_Array;
      Tok_Idx  : Natural) return Boolean
   is
      Tok : Token;
   begin
      if Tok_Idx = 0 or else Tok_Idx > Tokens'Length then
         return False;
      end if;

      Tok := Tokens (Tok_Idx);
      if Tok.Length /= Name_Len then
         return False;
      end if;

      for I in 1 .. Name_Len loop
         if Name (I) /= Input_Buffer (Tok.Start + I - 1) then
            return False;
         end if;
      end loop;

      return True;
   end Raw_Name_Equals;

   function Token_Text_Same
     (Tokens : Token_Array;
      Left   : Natural;
      Right  : Natural) return Boolean
   is
      Left_Tok  : Token;
      Right_Tok : Token;
   begin
      if Left = 0 or else Right = 0
        or else Left > Tokens'Length or else Right > Tokens'Length
      then
         return False;
      end if;

      Left_Tok := Tokens (Left);
      Right_Tok := Tokens (Right);
      if Left_Tok.Length /= Right_Tok.Length then
         return False;
      end if;

      for I in 0 .. Left_Tok.Length - 1 loop
         if To_Upper (Input_Buffer (Left_Tok.Start + I)) /=
           To_Upper (Input_Buffer (Right_Tok.Start + I))
         then
            return False;
         end if;
      end loop;

      return True;
   end Token_Text_Same;

   function Text_Equals_Ignore_Case
     (Left  : String;
      Right : String) return Boolean
   is
   begin
      if Left'Length /= Right'Length then
         return False;
      end if;

      for I in Left'Range loop
         if To_Upper (Left (I)) /=
           To_Upper (Right (Right'First + (I - Left'First)))
         then
            return False;
         end if;
      end loop;

      return True;
   end Text_Equals_Ignore_Case;

   function Is_CSharp_Keyword_Text (Text : String) return Boolean is
   begin
      return
        Text_Equals_Ignore_Case (Text, "abstract") or else
        Text_Equals_Ignore_Case (Text, "as") or else
        Text_Equals_Ignore_Case (Text, "base") or else
        Text_Equals_Ignore_Case (Text, "bool") or else
        Text_Equals_Ignore_Case (Text, "break") or else
        Text_Equals_Ignore_Case (Text, "byte") or else
        Text_Equals_Ignore_Case (Text, "case") or else
        Text_Equals_Ignore_Case (Text, "catch") or else
        Text_Equals_Ignore_Case (Text, "char") or else
        Text_Equals_Ignore_Case (Text, "class") or else
        Text_Equals_Ignore_Case (Text, "const") or else
        Text_Equals_Ignore_Case (Text, "continue") or else
        Text_Equals_Ignore_Case (Text, "default") or else
        Text_Equals_Ignore_Case (Text, "delegate") or else
        Text_Equals_Ignore_Case (Text, "do") or else
        Text_Equals_Ignore_Case (Text, "double") or else
        Text_Equals_Ignore_Case (Text, "else") or else
        Text_Equals_Ignore_Case (Text, "enum") or else
        Text_Equals_Ignore_Case (Text, "event") or else
        Text_Equals_Ignore_Case (Text, "explicit") or else
        Text_Equals_Ignore_Case (Text, "extern") or else
        Text_Equals_Ignore_Case (Text, "false") or else
        Text_Equals_Ignore_Case (Text, "fixed") or else
        Text_Equals_Ignore_Case (Text, "float") or else
        Text_Equals_Ignore_Case (Text, "for") or else
        Text_Equals_Ignore_Case (Text, "foreach") or else
        Text_Equals_Ignore_Case (Text, "goto") or else
        Text_Equals_Ignore_Case (Text, "if") or else
        Text_Equals_Ignore_Case (Text, "implicit") or else
        Text_Equals_Ignore_Case (Text, "in") or else
        Text_Equals_Ignore_Case (Text, "int") or else
        Text_Equals_Ignore_Case (Text, "interface") or else
        Text_Equals_Ignore_Case (Text, "internal") or else
        Text_Equals_Ignore_Case (Text, "is") or else
        Text_Equals_Ignore_Case (Text, "lock") or else
        Text_Equals_Ignore_Case (Text, "long") or else
        Text_Equals_Ignore_Case (Text, "namespace") or else
        Text_Equals_Ignore_Case (Text, "operator") or else
        Text_Equals_Ignore_Case (Text, "out") or else
        Text_Equals_Ignore_Case (Text, "override") or else
        Text_Equals_Ignore_Case (Text, "params") or else
        Text_Equals_Ignore_Case (Text, "private") or else
        Text_Equals_Ignore_Case (Text, "protected") or else
        Text_Equals_Ignore_Case (Text, "public") or else
        Text_Equals_Ignore_Case (Text, "readonly") or else
        Text_Equals_Ignore_Case (Text, "ref") or else
        Text_Equals_Ignore_Case (Text, "return") or else
        Text_Equals_Ignore_Case (Text, "sbyte") or else
        Text_Equals_Ignore_Case (Text, "sealed") or else
        Text_Equals_Ignore_Case (Text, "short") or else
        Text_Equals_Ignore_Case (Text, "sizeof") or else
        Text_Equals_Ignore_Case (Text, "stackalloc") or else
        Text_Equals_Ignore_Case (Text, "static") or else
        Text_Equals_Ignore_Case (Text, "string") or else
        Text_Equals_Ignore_Case (Text, "struct") or else
        Text_Equals_Ignore_Case (Text, "switch") or else
        Text_Equals_Ignore_Case (Text, "this") or else
        Text_Equals_Ignore_Case (Text, "throw") or else
        Text_Equals_Ignore_Case (Text, "true") or else
        Text_Equals_Ignore_Case (Text, "try") or else
        Text_Equals_Ignore_Case (Text, "typeof") or else
        Text_Equals_Ignore_Case (Text, "uint") or else
        Text_Equals_Ignore_Case (Text, "ulong") or else
        Text_Equals_Ignore_Case (Text, "unsafe") or else
        Text_Equals_Ignore_Case (Text, "ushort") or else
        Text_Equals_Ignore_Case (Text, "using") or else
        Text_Equals_Ignore_Case (Text, "virtual") or else
        Text_Equals_Ignore_Case (Text, "void") or else
        Text_Equals_Ignore_Case (Text, "volatile") or else
        Text_Equals_Ignore_Case (Text, "while");
   end Is_CSharp_Keyword_Text;

   function Token_Has_Uppercase
     (Tokens      : Token_Array;
      Token_Index : Natural) return Boolean
   is
      Tok : Token;
      C   : Character;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return False;
      end if;

      Tok := Tokens (Token_Index);
      for Offset in 0 .. Tok.Length - 1 loop
         C := Input_Buffer (Tok.Start + Offset);
         if C in 'A' .. 'Z' then
            return True;
         end if;
      end loop;

      return False;
   end Token_Has_Uppercase;

   function Is_CSharp_Keyword
     (Tokens      : Token_Array;
      Token_Index : Natural) return Boolean
   is
   begin
      return
        Token_Text_Equals (Tokens, Token_Index, "abstract") or else
        Token_Text_Equals (Tokens, Token_Index, "as") or else
        Token_Text_Equals (Tokens, Token_Index, "base") or else
        Token_Text_Equals (Tokens, Token_Index, "bool") or else
        Token_Text_Equals (Tokens, Token_Index, "break") or else
        Token_Text_Equals (Tokens, Token_Index, "byte") or else
        Token_Text_Equals (Tokens, Token_Index, "case") or else
        Token_Text_Equals (Tokens, Token_Index, "catch") or else
        Token_Text_Equals (Tokens, Token_Index, "char") or else
        Token_Text_Equals (Tokens, Token_Index, "class") or else
        Token_Text_Equals (Tokens, Token_Index, "const") or else
        Token_Text_Equals (Tokens, Token_Index, "continue") or else
        Token_Text_Equals (Tokens, Token_Index, "default") or else
        Token_Text_Equals (Tokens, Token_Index, "delegate") or else
        Token_Text_Equals (Tokens, Token_Index, "do") or else
        Token_Text_Equals (Tokens, Token_Index, "double") or else
        Token_Text_Equals (Tokens, Token_Index, "else") or else
        Token_Text_Equals (Tokens, Token_Index, "enum") or else
        Token_Text_Equals (Tokens, Token_Index, "event") or else
        Token_Text_Equals (Tokens, Token_Index, "explicit") or else
        Token_Text_Equals (Tokens, Token_Index, "extern") or else
        Token_Text_Equals (Tokens, Token_Index, "false") or else
        Token_Text_Equals (Tokens, Token_Index, "fixed") or else
        Token_Text_Equals (Tokens, Token_Index, "float") or else
        Token_Text_Equals (Tokens, Token_Index, "for") or else
        Token_Text_Equals (Tokens, Token_Index, "foreach") or else
        Token_Text_Equals (Tokens, Token_Index, "goto") or else
        Token_Text_Equals (Tokens, Token_Index, "if") or else
        Token_Text_Equals (Tokens, Token_Index, "implicit") or else
        Token_Text_Equals (Tokens, Token_Index, "in") or else
        Token_Text_Equals (Tokens, Token_Index, "int") or else
        Token_Text_Equals (Tokens, Token_Index, "interface") or else
        Token_Text_Equals (Tokens, Token_Index, "internal") or else
        Token_Text_Equals (Tokens, Token_Index, "is") or else
        Token_Text_Equals (Tokens, Token_Index, "lock") or else
        Token_Text_Equals (Tokens, Token_Index, "long") or else
        Token_Text_Equals (Tokens, Token_Index, "namespace") or else
        Token_Text_Equals (Tokens, Token_Index, "operator") or else
        Token_Text_Equals (Tokens, Token_Index, "out") or else
        Token_Text_Equals (Tokens, Token_Index, "override") or else
        Token_Text_Equals (Tokens, Token_Index, "params") or else
        Token_Text_Equals (Tokens, Token_Index, "private") or else
        Token_Text_Equals (Tokens, Token_Index, "protected") or else
        Token_Text_Equals (Tokens, Token_Index, "public") or else
        Token_Text_Equals (Tokens, Token_Index, "readonly") or else
        Token_Text_Equals (Tokens, Token_Index, "ref") or else
        Token_Text_Equals (Tokens, Token_Index, "return") or else
        Token_Text_Equals (Tokens, Token_Index, "sbyte") or else
        Token_Text_Equals (Tokens, Token_Index, "sealed") or else
        Token_Text_Equals (Tokens, Token_Index, "short") or else
        Token_Text_Equals (Tokens, Token_Index, "sizeof") or else
        Token_Text_Equals (Tokens, Token_Index, "stackalloc") or else
        Token_Text_Equals (Tokens, Token_Index, "static") or else
        Token_Text_Equals (Tokens, Token_Index, "string") or else
        Token_Text_Equals (Tokens, Token_Index, "struct") or else
        Token_Text_Equals (Tokens, Token_Index, "switch") or else
        Token_Text_Equals (Tokens, Token_Index, "this") or else
        Token_Text_Equals (Tokens, Token_Index, "throw") or else
        Token_Text_Equals (Tokens, Token_Index, "true") or else
        Token_Text_Equals (Tokens, Token_Index, "try") or else
        Token_Text_Equals (Tokens, Token_Index, "typeof") or else
        Token_Text_Equals (Tokens, Token_Index, "uint") or else
        Token_Text_Equals (Tokens, Token_Index, "ulong") or else
        Token_Text_Equals (Tokens, Token_Index, "unsafe") or else
        Token_Text_Equals (Tokens, Token_Index, "ushort") or else
        Token_Text_Equals (Tokens, Token_Index, "using") or else
        Token_Text_Equals (Tokens, Token_Index, "virtual") or else
        Token_Text_Equals (Tokens, Token_Index, "void") or else
        Token_Text_Equals (Tokens, Token_Index, "volatile") or else
        Token_Text_Equals (Tokens, Token_Index, "while");
   end Is_CSharp_Keyword;

   function Emit_Raw (Text : String) return Boolean is
      Needed : Natural;
   begin
      for I in Text'Range loop
         Needed := 1;
         if At_Line_Start and then Text (I) /= ASCII.LF then
            Needed := Needed + (Indent_Level * 4);
         end if;

         if Output_Len + Needed > Max_Output_Size then
            return False;
         end if;

         if At_Line_Start and then Text (I) /= ASCII.LF then
            for J in 1 .. Indent_Level loop
               Output_Buffer (Output_Len + 1 .. Output_Len + 4) := "    ";
               Output_Len := Output_Len + 4;
            end loop;
            At_Line_Start := False;
         end if;

         Output_Len := Output_Len + 1;
         Output_Buffer (Output_Len) := Text (I);

         if Text (I) = ASCII.LF then
            At_Line_Start := True;
         end if;
      end loop;

      return True;
   end Emit_Raw;

   procedure Emit_Line (Text : String; Success : in out Boolean) is
   begin
      if Success then
         Success := Emit_Raw (Text);
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Line;

   procedure Increase_Indent is
   begin
      Indent_Level := Indent_Level + 1;
   end Increase_Indent;

   procedure Decrease_Indent is
   begin
      if Indent_Level > 0 then
         Indent_Level := Indent_Level - 1;
      end if;
   end Decrease_Indent;

   procedure Emit_Natural
     (Value   : in Natural;
      Success : in out Boolean)
   is
      Image : constant String := Natural'Image (Value);
      First : Natural := Image'First;
   begin
      while First <= Image'Last and then Image (First) = ' ' loop
         First := First + 1;
      end loop;

      if First <= Image'Last then
         Success := Emit_Raw (Image (First .. Image'Last));
      else
         Success := Emit_Raw ("0");
      end if;
   end Emit_Natural;

   procedure Emit_S64
     (Value   : in Long_Long_Integer;
      Success : in out Boolean)
   is
      Image : constant String := Long_Long_Integer'Image (Value);
      First : Natural := Image'First;
   begin
      while First <= Image'Last and then Image (First) = ' ' loop
         First := First + 1;
      end loop;

      if First <= Image'Last then
         Success := Emit_Raw (Image (First .. Image'Last));
      else
         Success := Emit_Raw ("0");
      end if;
   end Emit_S64;

   procedure Emit_Identifier
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Success     : in out Boolean)
   is
      Tok       : Token;
      C         : Character;
      Saw_Char  : Boolean := False;
      First_Out : Boolean := True;
   begin
      if not Success then
         return;
      end if;

      if Token_Index = 0 or else Token_Index > Tokens'Length then
         Success := Emit_Raw ("alb_anon");
         return;
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         Success := Emit_Raw ("alb_anon");
         return;
      end if;

      if Is_CSharp_Keyword (Tokens, Token_Index) then
         Success := Emit_Raw ("alb_");
      end if;

      for Offset in 0 .. Tok.Length - 1 loop
         C := Input_Buffer (Tok.Start + Offset);

         if C = '#' then
            if First_Out then
               Success := Emit_Raw ("Const_");
               First_Out := False;
               Saw_Char := True;
            end if;
         elsif ((C in 'a' .. 'z') or else (C in 'A' .. 'Z') or else C = '_')
           or else ((C in '0' .. '9') and then not First_Out)
         then
            if First_Out and then C in '0' .. '9' then
               Success := Emit_Raw ("alb_");
            end if;
            if Success then
               Success := Emit_Raw (C & "");
            end if;
            First_Out := False;
            Saw_Char := True;
         elsif C in '0' .. '9' then
            Success := Emit_Raw ("alb_");
            if Success then
               Success := Emit_Raw (C & "");
            end if;
            First_Out := False;
            Saw_Char := True;
         else
            if Success then
               Success := Emit_Raw ("_");
            end if;
            First_Out := False;
            Saw_Char := True;
         end if;

         exit when not Success;
      end loop;

      if Success and then not Saw_Char then
         Success := Emit_Raw ("alb_anon");
      end if;
   end Emit_Identifier;

   function Token_Text_Copy
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return String
   is
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
   end Token_Text_Copy;

   function Compose_Module_Emit_Name
     (Tokens       : in Token_Array;
      Module_Token : in Natural;
      Base_Name    : in String) return String
   is
   begin
      if Module_Token = 0 then
         return Base_Name;
      end if;

      return Token_Text_Copy (Tokens, Module_Token) & "_" & Base_Name;
   end Compose_Module_Emit_Name;

   procedure Store_Name_Text
     (Text   : in String;
      Buffer : out Name_Buffer;
      Length : out Natural)
   is
   begin
      Buffer := (others => ' ');
      Length := 0;
      for I in Text'Range loop
         exit when Length >= Max_Name_Len;
         Length := Length + 1;
         Buffer (Length) := Text (I);
      end loop;
   end Store_Name_Text;

   procedure Store_Emit_Name
     (Text   : in String;
      Buffer : out Name_Buffer;
      Length : out Natural)
   is
      procedure Append_Text (Value : in String) is
      begin
         for J in Value'Range loop
            exit when Length >= Max_Name_Len;
            Length := Length + 1;
            Buffer (Length) := Value (J);
         end loop;
      end Append_Text;

      C : Character;
   begin
      Buffer := (others => ' ');
      Length := 0;

      if Text'Length = 0 then
         Append_Text ("alb_anon");
         return;
      end if;

      if Is_CSharp_Keyword_Text (Text) then
         Append_Text ("alb_");
      end if;

      for I in Text'Range loop
         exit when Length >= Max_Name_Len;
         C := Text (I);
         if C = '#' then
            if Length = 0 then
               Append_Text ("Const_");
            end if;
         elsif (C in 'a' .. 'z') or else (C in 'A' .. 'Z') or else C = '_' then
            Length := Length + 1;
            Buffer (Length) := C;
         elsif C in '0' .. '9' then
            if Length = 0 then
               Append_Text ("alb_");
            end if;
            exit when Length >= Max_Name_Len;
            Length := Length + 1;
            Buffer (Length) := C;
         else
            Length := Length + 1;
            Buffer (Length) := '_';
         end if;
      end loop;

      if Length = 0 then
         Append_Text ("alb_anon");
      end if;
   end Store_Emit_Name;

   function Buffer_Text
     (Buffer : in Name_Buffer;
      Length : in Natural) return String
   is
      Result : String (1 .. Length);
   begin
      if Length = 0 then
         return "";
      end if;

      for I in 1 .. Length loop
         Result (I) := Buffer (I);
      end loop;
      return Result;
   end Buffer_Text;

   procedure Emit_Name_Text
     (Buffer  : in Name_Buffer;
      Length  : in Natural;
      Success : in out Boolean)
   is
   begin
      if not Success then
         return;
      end if;

      if Length = 0 then
         Success := Emit_Raw ("alb_anon");
         return;
      end if;

      for I in 1 .. Length loop
         Success := Emit_Raw (Buffer (I) & "");
         exit when not Success;
      end loop;
   end Emit_Name_Text;

   function Name_Equals_Text
     (Buffer : in Name_Buffer;
      Length : in Natural;
      Text   : in String) return Boolean
   is
   begin
      if Length /= Text'Length then
         return False;
      end if;

      for I in 1 .. Length loop
         if Buffer (I) /= Text (Text'First + I - 1) then
            return False;
         end if;
      end loop;

      return True;
   end Name_Equals_Text;

   function Name_Has_Prefix
     (Buffer : in Name_Buffer;
      Length : in Natural;
      Prefix : in String) return Boolean
   is
   begin
      if Prefix'Length > Length then
         return False;
      end if;

      for I in 1 .. Prefix'Length loop
         if Buffer (I) /= Prefix (Prefix'First + I - 1) then
            return False;
         end if;
      end loop;

      return True;
   end Name_Has_Prefix;

   function Find_Symbol_By_Text
     (Text         : in String;
      Module_Token : in Natural := 0) return Natural
   is
   begin
      for I in reverse 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then Symbols (I).Routine_Node = 0
           and then Symbols (I).Module_Token = Module_Token
           and then Name_Equals_Text (Symbols (I).Name, Symbols (I).Name_Len, Text)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Symbol_By_Text;

   function Find_Local_Symbol
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural
   is
   begin
      if Active_Routine_Node = 0 then
         return 0;
      end if;

      for I in reverse 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then Symbols (I).Routine_Node = Active_Routine_Node
           and then Raw_Name_Equals
             (Symbols (I).Name, Symbols (I).Name_Len, Tokens, Token_Index)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Local_Symbol;

   function Find_Symbol_In_Context
     (Tokens       : in Token_Array;
      Token_Index  : in Natural;
      Module_Token : in Natural) return Natural
   is
   begin
      if Module_Token /= 0 then
         for I in reverse 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then Symbols (I).Routine_Node = 0
              and then Symbols (I).Module_Token = Module_Token
              and then Raw_Name_Equals
                (Symbols (I).Name, Symbols (I).Name_Len, Tokens, Token_Index)
            then
               return I;
            end if;
         end loop;
      end if;

      for I in reverse 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then Symbols (I).Routine_Node = 0
           and then Symbols (I).Module_Token = 0
           and then Raw_Name_Equals
             (Symbols (I).Name, Symbols (I).Name_Len, Tokens, Token_Index)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Symbol_In_Context;

   function Kind_From_Type_Token
     (Tokens      : Token_Array;
      Token_Index : Natural;
      Fallback    : DotNet_Value_Kind) return DotNet_Value_Kind
   is
   begin
      if Token_Index = 0 then
         return Fallback;
      elsif Token_Text_Equals (Tokens, Token_Index, "U8")
      then
         return Kind_U8;
      elsif Token_Text_Equals (Tokens, Token_Index, "U16")
      then
         return Kind_U16;
      elsif Token_Text_Equals (Tokens, Token_Index, "U32")
      then
         return Kind_U32;
      elsif Token_Text_Equals (Tokens, Token_Index, "U64") then
         return Kind_U64;
      elsif Token_Text_Equals (Tokens, Token_Index, "U128") then
         return Kind_U128;
      elsif Token_Text_Equals (Tokens, Token_Index, "S32") or else
        Token_Text_Equals (Tokens, Token_Index, "HW8") or else
        Token_Text_Equals (Tokens, Token_Index, "HW16") or else
        Token_Text_Equals (Tokens, Token_Index, "HW32") or else
        Token_Text_Equals (Tokens, Token_Index, "I8") or else
        Token_Text_Equals (Tokens, Token_Index, "I16") or else
        Token_Text_Equals (Tokens, Token_Index, "I32") or else
        Token_Text_Equals (Tokens, Token_Index, "I64")
      then
         return Kind_S64;
      elsif Token_Text_Equals (Tokens, Token_Index, "F64") or else
        Token_Text_Equals (Tokens, Token_Index, "REAL")
      then
         return Kind_F64;
      elsif Token_Text_Equals (Tokens, Token_Index, "F32") or else
        Token_Text_Equals (Tokens, Token_Index, "SINGLE") or else
        Token_Text_Equals (Tokens, Token_Index, "FLOAT")
      then
         return Kind_F32;
      elsif Token_Text_Equals (Tokens, Token_Index, "FLOAT2") or else
        Token_Text_Equals (Tokens, Token_Index, "F32X2")
      then
         return Kind_F32x2;
      elsif Token_Text_Equals (Tokens, Token_Index, "FLOAT4") or else
        Token_Text_Equals (Tokens, Token_Index, "F32X4")
      then
         return Kind_F32x4;
      elsif Token_Text_Equals (Tokens, Token_Index, "MAT2") or else
        Token_Text_Equals (Tokens, Token_Index, "MAT2X2")
      then
         return Kind_Mat2x2;
      elsif Token_Text_Equals (Tokens, Token_Index, "MAT3") or else
        Token_Text_Equals (Tokens, Token_Index, "MAT3X3")
      then
         return Kind_Mat3x3;
      elsif Token_Text_Equals (Tokens, Token_Index, "MAT4") or else
        Token_Text_Equals (Tokens, Token_Index, "MAT4X4")
      then
         return Kind_Mat4x4;
      elsif Token_Text_Equals (Tokens, Token_Index, "BOOL") or else
        Token_Text_Equals (Tokens, Token_Index, "BOOLEAN")
      then
         return Kind_Bool;
      elsif Token_Text_Equals (Tokens, Token_Index, "STRING") or else
        Token_Text_Equals (Tokens, Token_Index, "BINARY")
      then
         return Kind_String;
      elsif Token_Text_Equals (Tokens, Token_Index, "PURE") or else
        Token_Text_Equals (Tokens, Token_Index, "RATIONAL")
      then
         return Kind_Pure;
      elsif Token_Text_Equals (Tokens, Token_Index, "U0") or else
        Token_Text_Equals (Tokens, Token_Index, "VOID")
      then
         return Kind_Void;
      else
         return Fallback;
      end if;
   end Kind_From_Type_Token;

   function Infer_Expression_Kind
     (Tokens : Token_Array;
      Tree   : Node_Array;
      Node   : Node_Index) return DotNet_Value_Kind
   is
      Name_Node : Node_Index;
      Sym       : Natural := 0;
      function Token_Number_Text_Is_Real
        (Token_Index : Natural) return Boolean is
      begin
         if Token_Index = 0 or else Token_Index > Tokens'Length then
            return False;
         end if;

         declare
            Tok : constant Token := Tokens (Token_Index);
         begin
            for Offset in 0 .. Tok.Length - 1 loop
               declare
                  C : constant Character := Input_Buffer (Tok.Start + Offset);
               begin
                  if C = '.' or else C = 'e' or else C = 'E' then
                     return True;
                  end if;
               end;
            end loop;
         end;

         return False;
      end Token_Number_Text_Is_Real;
   begin
      if Node = 0 then
         return Kind_S64;
      end if;

      case Tree (Node).Kind is
         when AST_String_Expr =>
            return Kind_String;
         when AST_True | AST_False =>
            return Kind_Bool;
         when AST_Number_Expr =>
            if Token_Number_Text_Is_Real (Tree (Node).Token_Index) then
               return Kind_F64;
            end if;
            return Kind_S64;
         when AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
            return Kind_S64;
         when AST_Var_Expr | AST_Const_Ref =>
            Sym := Find_Target_Symbol (Tokens, Tree, Node);
            if Sym /= 0 then
               return Symbols (Sym).Kind;
            end if;
            return Kind_S64;
         when AST_Member_Expr | AST_Temporal_Ref =>
            Sym := Find_Target_Symbol (Tokens, Tree, Node);
            if Sym /= 0 then
               return Symbols (Sym).Kind;
            end if;
            return Kind_S64;
         when AST_Func_Call =>
            Name_Node := Tree (Node).Left_Child;
            if Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Var_Expr then
               if Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U8") then
                  return Kind_U8;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U16") then
                  return Kind_U16;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U32") then
                  return Kind_U32;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U64") then
                  return Kind_U64;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U128") then
                  return Kind_U128;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "F64") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "REAL")
               then
                  return Kind_F64;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "F32") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "SINGLE") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "FLOAT")
               then
                  return Kind_F32;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "BOOL") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "BOOLEAN")
               then
                  return Kind_Bool;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "RATIONAL")
               then
                  return Kind_Pure;
               end if;
            end if;
            return Kind_S64;
         when AST_BinOp =>
            if Tree (Node).Token_Index /= 0 then
               if Tokens (Tree (Node).Token_Index).Kind in
                 TOK_EQUAL | TOK_NOT_EQUAL | TOK_LESS | TOK_GREATER |
                 TOK_LESS_EQUAL | TOK_GREATER_EQUAL | TOK_AND | TOK_OR
               then
                  return Kind_Bool;
               elsif Tokens (Tree (Node).Token_Index).Kind = TOK_POW then
                  declare
                     Left_Kind  : constant DotNet_Value_Kind :=
                       Infer_Expression_Kind (Tokens, Tree, Tree (Node).Left_Child);
                     Right_Kind : constant DotNet_Value_Kind :=
                       Infer_Expression_Kind (Tokens, Tree, Tree (Node).Right_Child);
                  begin
                     if Left_Kind = Kind_F64 or else Right_Kind = Kind_F64 then
                        return Kind_F64;
                     elsif Left_Kind = Kind_F32 or else Right_Kind = Kind_F32 then
                        return Kind_F32;
                     end if;
                  end;
               end if;
            end if;
            return Infer_Expression_Kind (Tokens, Tree, Tree (Node).Left_Child);
         when others =>
            return Kind_S64;
      end case;
   end Infer_Expression_Kind;

   procedure Emit_CSharp_Type
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean)
   is
   begin
      if not Success then
         return;
      end if;

      case Kind is
         when Kind_U8 =>
            Success := Emit_Raw ("byte");
         when Kind_U16 =>
            Success := Emit_Raw ("ushort");
         when Kind_U32 =>
            Success := Emit_Raw ("uint");
         when Kind_U64 =>
            Success := Emit_Raw ("ulong");
         when Kind_U128 =>
            Success := Emit_Raw ("ALB_U128");
         when Kind_F64 =>
            Success := Emit_Raw ("double");
         when Kind_F32 =>
            Success := Emit_Raw ("float");
         when Kind_F32x2 =>
            Success := Emit_Raw ("F32x2");
         when Kind_F32x4 =>
            Success := Emit_Raw ("F32x4");
         when Kind_Mat2x2 =>
            Success := Emit_Raw ("Mat2x2");
         when Kind_Mat3x3 =>
            Success := Emit_Raw ("Mat3x3");
         when Kind_Mat4x4 =>
            Success := Emit_Raw ("Mat4x4");
         when Kind_Bool =>
            Success := Emit_Raw ("bool");
         when Kind_String =>
            Success := Emit_Raw ("string");
         when Kind_Pure =>
            Success := Emit_Raw ("Pure128");
         when Kind_Void =>
            Success := Emit_Raw ("void");
         when Kind_S64 =>
            Success := Emit_Raw ("long");
      end case;
   end Emit_CSharp_Type;

   procedure Emit_Foreign_CSharp_Type
     (Tokens     : in Token_Array;
      Type_Token : in Natural;
      Success    : in out Boolean)
   is
   begin
      if Token_Text_Equals (Tokens, Type_Token, "S32") or else
        Token_Text_Equals (Tokens, Type_Token, "I32") or else
        Token_Text_Equals (Tokens, Type_Token, "HW32")
      then
         Success := Emit_Raw ("int");
      elsif Token_Text_Equals (Tokens, Type_Token, "I8") or else
        Token_Text_Equals (Tokens, Type_Token, "HW8")
      then
         Success := Emit_Raw ("sbyte");
      elsif Token_Text_Equals (Tokens, Type_Token, "I16") or else
        Token_Text_Equals (Tokens, Type_Token, "HW16")
      then
         Success := Emit_Raw ("short");
      elsif Token_Text_Equals (Tokens, Type_Token, "U8") then
         Success := Emit_Raw ("byte");
      elsif Token_Text_Equals (Tokens, Type_Token, "U16") then
         Success := Emit_Raw ("ushort");
      elsif Token_Text_Equals (Tokens, Type_Token, "U32") then
         Success := Emit_Raw ("uint");
      elsif Token_Text_Equals (Tokens, Type_Token, "U64") then
         Success := Emit_Raw ("ulong");
      elsif Token_Text_Equals (Tokens, Type_Token, "I64") or else
        Token_Text_Equals (Tokens, Type_Token, "S64")
      then
         Success := Emit_Raw ("long");
      elsif Token_Text_Equals (Tokens, Type_Token, "F64") or else
        Token_Text_Equals (Tokens, Type_Token, "REAL")
      then
         Success := Emit_Raw ("double");
      elsif Token_Text_Equals (Tokens, Type_Token, "BOOL") or else
        Token_Text_Equals (Tokens, Type_Token, "BOOLEAN")
      then
         Success := Emit_Raw ("bool");
      else
         Emit_CSharp_Type
           (Kind_From_Type_Token (Tokens, Type_Token, Kind_S64), Success);
      end if;
   end Emit_Foreign_CSharp_Type;

   procedure Emit_Default_Value
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean)
   is
   begin
      if not Success then
         return;
      end if;

      case Kind is
         when Kind_Bool =>
            Success := Emit_Raw ("false");
         when Kind_String =>
            Success := Emit_Raw ("""""");
         when Kind_Pure =>
            Success := Emit_Raw ("default(Pure128)");
         when Kind_U128 =>
            Success := Emit_Raw ("default(ALB_U128)");
         when Kind_F64 =>
            Success := Emit_Raw ("0.0");
         when Kind_F32 =>
            Success := Emit_Raw ("0.0f");
         when Kind_F32x2 | Kind_F32x4 | Kind_Mat2x2 |
              Kind_Mat3x3 | Kind_Mat4x4 =>
            Success := Emit_Raw ("default(");
            Emit_CSharp_Type (Kind, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;
         when others =>
            Success := Emit_Raw ("0");
      end case;
   end Emit_Default_Value;

   function Needs_Assignment_Cast (Kind : DotNet_Value_Kind) return Boolean is
   begin
      return Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 | Kind_F64 | Kind_F32;
   end Needs_Assignment_Cast;

   function Current_Routine_Return_Kind
     (Tokens : in Token_Array;
      Tree   : in Node_Array) return DotNet_Value_Kind
   is
   begin
      if Active_Routine_Node /= 0
        and then Tree (Active_Routine_Node).Token_Index /= 0
      then
         return
           Kind_From_Type_Token
             (Tokens,
              Tree (Active_Routine_Node).Token_Index,
              Kind_S64);
      end if;

      return Kind_S64;
   end Current_Routine_Return_Kind;

   function Kind_Storage_Bytes
     (Kind : in DotNet_Value_Kind) return Natural
   is
   begin
      case Kind is
         when Kind_U8 | Kind_Bool =>
            return 1;
         when Kind_U16 =>
            return 2;
         when Kind_U32 =>
            return 4;
         when Kind_U128 | Kind_Pure =>
            return 16;
         when Kind_F32x2 =>
            return 8;
         when Kind_F32x4 | Kind_Mat2x2 =>
            return 16;
         when Kind_Mat3x3 =>
            return 36;
         when Kind_Mat4x4 =>
            return 64;
         when others =>
            return 8;
      end case;
   end Kind_Storage_Bytes;

   procedure Emit_Assignment_Value
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      RHS     : in Node_Index;
      Kind    : in DotNet_Value_Kind;
      Success : in out Boolean)
   is
      RHS_Kind : constant DotNet_Value_Kind :=
        Infer_Expression_Kind (Tokens, Tree, RHS);
   begin
      if Kind = Kind_U128 then
         Emit_Default_Value (Kind_U128, Success);
      elsif Kind = Kind_S64 and then RHS_Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
         Success := Emit_Raw ("unchecked((long)(");
         Emit_Expression (Tokens, Tree, RHS, RHS_Kind, Success);
         if Success then
            Success := Emit_Raw ("))");
         end if;
      elsif Kind = Kind_S64 and then RHS_Kind = Kind_F64 then
         Success := Emit_Raw ("((long)(");
         Emit_Expression (Tokens, Tree, RHS, RHS_Kind, Success);
         if Success then
            Success := Emit_Raw ("))");
         end if;
      elsif Kind = Kind_S64 and then RHS_Kind in Kind_Bool | Kind_String | Kind_Pure then
         Success := Emit_Raw ("ALB_Num(");
         Emit_Expression (Tokens, Tree, RHS, RHS_Kind, Success);
         if Success then
            Success := Emit_Raw (")");
         end if;
      elsif Needs_Assignment_Cast (Kind) then
         if Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
            Success := Emit_Raw ("unchecked((");
         else
            Success := Emit_Raw ("(");
         end if;

         Emit_CSharp_Type (Kind, Success);
         if Success and then Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
            Success := Emit_Raw (")(");
         elsif Success then
            Success := Emit_Raw (")(");
         end if;
         Emit_Expression (Tokens, Tree, RHS, Kind, Success);
         if Success and then Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
            Success := Emit_Raw ("))");
         elsif Success then
            Success := Emit_Raw (")");
         end if;
      else
         Emit_Expression (Tokens, Tree, RHS, Kind, Success);
      end if;
   end Emit_Assignment_Value;

   function Find_Symbol
     (Tokens      : Token_Array;
      Token_Index : Natural) return Natural
   is
      Local_Sym : constant Natural := Find_Local_Symbol (Tokens, Token_Index);
   begin
      if Local_Sym /= 0 then
         return Local_Sym;
      end if;

      return Find_Symbol_In_Context
        (Tokens, Token_Index, Active_Routine_Module_Token);
   end Find_Symbol;

   function Find_Unprefixed_Const
     (Tokens      : Token_Array;
      Token_Index : Natural) return Natural
   is
      Tok : Token;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return 0;
      end if;

      Tok := Tokens (Token_Index);
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then Symbols (I).Name_Len = Tok.Length + 1
           and then Symbols (I).Name (1) = '#'
         then
            declare
               Matches : Boolean := True;
            begin
               for J in 1 .. Tok.Length loop
                  if Symbols (I).Name (J + 1) /=
                    Input_Buffer (Tok.Start + J - 1)
                  then
                     Matches := False;
                  end if;
               end loop;

               if Matches then
                  return I;
               end if;
            end;
         end if;
      end loop;

      return 0;
   end Find_Unprefixed_Const;

   type Static_S64_Result is record
      Value   : Long_Long_Integer := 0;
      Success : Boolean := False;
   end record;

   function Static_S64
     (Value : Long_Long_Integer) return Static_S64_Result
   is
   begin
      return (Value => Value, Success => True);
   end Static_S64;

   function Static_S64_Failure return Static_S64_Result
   is
   begin
      return (Value => 0, Success => False);
   end Static_S64_Failure;

   function Try_Parse_Static_S64
     (Tokens : Token_Array;
      Kind   : Node_Kind;
      Token_Index : Natural) return Static_S64_Result
   is
      Tok   : Token;
      Value : Long_Long_Integer := 0;
      Digit : Long_Long_Integer := 0;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return Static_S64_Failure;
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         return Static_S64_Failure;
      end if;

      case Kind is
         when AST_Number_Expr =>
            for Offset in 0 .. Tok.Length - 1 loop
               declare
                  C : constant Character := Input_Buffer (Tok.Start + Offset);
               begin
                  if C in '0' .. '9' then
                     Digit := Character'Pos (C) - Character'Pos ('0');
                     Value := (Value * 10) + Digit;
                  elsif C /= '_' then
                     return Static_S64_Failure;
                  end if;
               end;
            end loop;

         when AST_Hex_Expr =>
            for Offset in 0 .. Tok.Length - 1 loop
               declare
                  C : constant Character := Input_Buffer (Tok.Start + Offset);
               begin
                  if C = '$' or else C = '_' then
                     null;
                  elsif C in '0' .. '9' then
                     Digit := Character'Pos (C) - Character'Pos ('0');
                     Value := (Value * 16) + Digit;
                  elsif C in 'A' .. 'F' then
                     Digit := 10 + Character'Pos (C) - Character'Pos ('A');
                     Value := (Value * 16) + Digit;
                  elsif C in 'a' .. 'f' then
                     Digit := 10 + Character'Pos (C) - Character'Pos ('a');
                     Value := (Value * 16) + Digit;
                  else
                     return Static_S64_Failure;
                  end if;
               end;
            end loop;

         when AST_Bin_Expr =>
            for Offset in 0 .. Tok.Length - 1 loop
               declare
                  C : constant Character := Input_Buffer (Tok.Start + Offset);
               begin
                  if C = '%' or else C = '_' then
                     null;
                  elsif C = '0' or else C = '1' then
                     Digit := (if C = '1' then 1 else 0);
                     Value := (Value * 2) + Digit;
                  else
                     return Static_S64_Failure;
                  end if;
               end;
            end loop;

         when AST_Octal_Expr =>
            for Offset in 0 .. Tok.Length - 1 loop
               declare
                  C : constant Character := Input_Buffer (Tok.Start + Offset);
               begin
                  if C in '0' .. '7' then
                     Digit := Character'Pos (C) - Character'Pos ('0');
                     Value := (Value * 8) + Digit;
                  elsif C /= '_' then
                     return Static_S64_Failure;
                  end if;
               end;
            end loop;

         when others =>
            return Static_S64_Failure;
      end case;

      return Static_S64 (Value);
   end Try_Parse_Static_S64;

   function Try_Eval_Static_S64
     (Tokens : Token_Array;
      Tree   : Node_Array;
      Node   : Node_Index) return Static_S64_Result
   is
      Sym   : Natural := 0;
      Left  : Static_S64_Result;
      Right : Static_S64_Result;
   begin
      if Node = 0 then
         return Static_S64_Failure;
      end if;

      case Tree (Node).Kind is
         when AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
            return Try_Parse_Static_S64
              (Tokens, Tree (Node).Kind, Tree (Node).Token_Index);

         when AST_Unary_Minus =>
            Left := Try_Eval_Static_S64 (Tokens, Tree, Tree (Node).Left_Child);
            if Left.Success then
               return Static_S64 (-Left.Value);
            end if;
            return Static_S64_Failure;

         when AST_Cast_Expr =>
            return Try_Eval_Static_S64 (Tokens, Tree, Tree (Node).Left_Child);

         when AST_Var_Expr | AST_Const_Ref =>
            if Tree (Node).Kind = AST_Var_Expr
              and then Tree (Node).Left_Child /= 0
            then
               return Static_S64_Failure;
            end if;

            Sym := Find_Symbol (Tokens, Tree (Node).Token_Index);
            if Sym = 0 and then Tree (Node).Kind = AST_Var_Expr then
               Sym := Find_Unprefixed_Const (Tokens, Tree (Node).Token_Index);
            end if;

            if Sym /= 0
              and then Symbols (Sym).Shape = Shape_Const
              and then Symbols (Sym).Init_Node /= 0
            then
               return Try_Eval_Static_S64
                 (Tokens, Tree, Symbols (Sym).Init_Node);
            end if;

            return Static_S64_Failure;

         when AST_BinOp =>
            Left := Try_Eval_Static_S64 (Tokens, Tree, Tree (Node).Left_Child);
            Right := Try_Eval_Static_S64 (Tokens, Tree, Tree (Node).Right_Child);

            if not Left.Success or else not Right.Success then
               return Static_S64_Failure;
            end if;

            if Tree (Node).Token_Index = 0
              or else Tree (Node).Token_Index > Tokens'Length
            then
               return Static_S64_Failure;
            end if;

            case Tokens (Tree (Node).Token_Index).Kind is
               when TOK_PLUS =>
                  return Static_S64 (Left.Value + Right.Value);
               when TOK_MINUS =>
                  return Static_S64 (Left.Value - Right.Value);
               when TOK_MUL =>
                  return Static_S64 (Left.Value * Right.Value);
               when TOK_DIV =>
                  if Right.Value = 0 then
                     return Static_S64_Failure;
                  end if;
                  return Static_S64 (Left.Value / Right.Value);
               when TOK_MOD =>
                  if Right.Value = 0 then
                     return Static_S64_Failure;
                  end if;
                  return Static_S64 (Left.Value rem Right.Value);
               when TOK_POW =>
                  if Right.Value < 0 then
                     return Static_S64_Failure;
                  end if;
                  declare
                     Result : Long_Long_Integer := 1;
                  begin
                     for I in 1 .. Integer (Right.Value) loop
                        Result := Result * Left.Value;
                     end loop;
                     return Static_S64 (Result);
                  exception
                     when others =>
                        return Static_S64_Failure;
                  end;
               when others =>
                  return Static_S64_Failure;
            end case;

         when others =>
            return Static_S64_Failure;
      end case;
   end Try_Eval_Static_S64;

   procedure Register_Symbol_Text
     (Tokens       : in Token_Array;
      Raw_Name     : in String;
      Emit_Name    : in String;
      Type_Token   : in Natural;
      Kind         : in DotNet_Value_Kind;
      Init_Node    : in Node_Index;
      Shape        : in DotNet_Symbol_Shape := Shape_Scalar;
      Rank         : in Natural := 0;
      Dims         : in Dim_Node_List := (others => 0);
      Active_Node  : in Node_Index := 0;
      History_Node : in Node_Index := 0;
      Module_Token : in Natural := 0)
   is
   begin
      if Raw_Name'Length = 0 then
         return;
      end if;

      if Find_Symbol_By_Text (Raw_Name, Module_Token) /= 0 then
         return;
      end if;

      if Symbol_Count >= Max_Symbols then
         return;
      end if;

      Symbol_Count := Symbol_Count + 1;
      Symbols (Symbol_Count).Active := True;
      Store_Name_Text (Raw_Name, Symbols (Symbol_Count).Name, Symbols (Symbol_Count).Name_Len);
      Store_Emit_Name
        (Compose_Module_Emit_Name
           (Tokens,
            Module_Token,
            (if Emit_Name'Length = 0 then Raw_Name else Emit_Name)),
         Symbols (Symbol_Count).Emit_Name,
         Symbols (Symbol_Count).Emit_Name_Len);
      Symbols (Symbol_Count).Type_Token := Type_Token;
      Symbols (Symbol_Count).Kind := Kind;
      Symbols (Symbol_Count).Shape := Shape;
      Symbols (Symbol_Count).Init_Node := Init_Node;
      Symbols (Symbol_Count).Rank := Rank;
      Symbols (Symbol_Count).Dims := Dims;
      Symbols (Symbol_Count).Active_Node := Active_Node;
      Symbols (Symbol_Count).History_Node := History_Node;
      Symbols (Symbol_Count).Module_Token := Module_Token;
      Symbols (Symbol_Count).Routine_Node := 0;
   end Register_Symbol_Text;

   procedure Register_Symbol
     (Tokens      : in Token_Array;
      Name_Token  : in Natural;
      Type_Token  : in Natural;
      Kind        : in DotNet_Value_Kind;
      Init_Node   : in Node_Index;
      Module_Token : in Natural := 0)
   is
   begin
      if Name_Token = 0 or else Name_Token > Tokens'Length then
         return;
      end if;

      Register_Symbol_Text
        (Tokens,
         Token_Text_Copy (Tokens, Name_Token),
         Token_Text_Copy (Tokens, Name_Token),
         Type_Token,
         Kind,
         Init_Node,
         Shape_Scalar,
         Module_Token => Module_Token);
   end Register_Symbol;

   procedure Register_Local_Symbol
     (Tokens       : in Token_Array;
      Name_Token   : in Natural;
      Type_Token   : in Natural;
      Kind         : in DotNet_Value_Kind;
      Init_Node    : in Node_Index;
      Allow_Shadow : in Boolean := False)
   is
   begin
      if Active_Routine_Node = 0
        or else Name_Token = 0
        or else Name_Token > Tokens'Length
      then
         return;
      end if;

      if not Allow_Shadow and then Find_Local_Symbol (Tokens, Name_Token) /= 0 then
         return;
      end if;

      if Symbol_Count >= Max_Symbols then
         return;
      end if;

      Symbol_Count := Symbol_Count + 1;
      Symbols (Symbol_Count).Active := True;
      Store_Name_Text
        (Token_Text_Copy (Tokens, Name_Token),
         Symbols (Symbol_Count).Name,
         Symbols (Symbol_Count).Name_Len);
      Store_Emit_Name
        (Token_Text_Copy (Tokens, Name_Token),
         Symbols (Symbol_Count).Emit_Name,
         Symbols (Symbol_Count).Emit_Name_Len);
      Symbols (Symbol_Count).Type_Token := Type_Token;
      Symbols (Symbol_Count).Kind := Kind;
      Symbols (Symbol_Count).Shape := Shape_Scalar;
      Symbols (Symbol_Count).Init_Node := Init_Node;
      Symbols (Symbol_Count).Rank := 0;
      Symbols (Symbol_Count).Dims := (others => 0);
      Symbols (Symbol_Count).Active_Node := 0;
      Symbols (Symbol_Count).History_Node := 0;
      Symbols (Symbol_Count).Module_Token := Active_Routine_Module_Token;
      Symbols (Symbol_Count).Routine_Node := Active_Routine_Node;
   end Register_Local_Symbol;

   function Find_User_Struct (Name : in String) return Natural is
   begin
      for I in 1 .. User_Struct_Count loop
         if User_Structs (I).Active
           and then Name_Equals_Text
             (User_Structs (I).Name,
              User_Structs (I).Name_Len,
              Name)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_User_Struct;

   function Is_User_Struct_Type
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Boolean
   is
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return False;
      end if;

      return Find_User_Struct (Token_Text_Copy (Tokens, Token_Index)) /= 0;
   end Is_User_Struct_Type;

   procedure Register_Struct_From_Node
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index)
   is
      Name_Node   : constant Node_Index := Tree (Node).Left_Child;
      Block_Node  : constant Node_Index := Tree (Node).Right_Child;
      Curr        : Node_Index := 0;
   begin
      if Name_Node = 0 or else Tree (Name_Node).Token_Index = 0 then
         return;
      end if;
      declare
         Struct_Name : constant String :=
           Token_Text_Copy (Tokens, Tree (Name_Node).Token_Index);
      begin
         if Struct_Name'Length = 0 or else Find_User_Struct (Struct_Name) /= 0 then
            return;
         end if;

         if User_Struct_Count < Max_User_Structs then
            User_Struct_Count := User_Struct_Count + 1;
            User_Structs (User_Struct_Count).Active := True;
            Store_Name_Text
              (Struct_Name,
               User_Structs (User_Struct_Count).Name,
               User_Structs (User_Struct_Count).Name_Len);
         end if;

         Curr := Block_Node;
         if Curr /= 0 and then Tree (Curr).Kind = AST_Block_Stmt then
            Curr := Tree (Curr).Left_Child;
         end if;

         while Curr /= 0 loop
            if Tree (Curr).Kind in AST_Struct_Field | AST_Null
              and then Tree (Curr).Left_Child /= 0
              and then Tree (Tree (Curr).Left_Child).Kind = AST_Var_Expr
              and then User_Field_Count < Max_User_Fields
            then
               User_Field_Count := User_Field_Count + 1;
               User_Struct_Fields (User_Field_Count).Active := True;
               Store_Name_Text
                 (Struct_Name,
                  User_Struct_Fields (User_Field_Count).Struct_Name,
                  User_Struct_Fields (User_Field_Count).Struct_Name_Len);
               Store_Name_Text
                 (Token_Text_Copy (Tokens, Tree (Tree (Curr).Left_Child).Token_Index),
                  User_Struct_Fields (User_Field_Count).Field_Name,
                  User_Struct_Fields (User_Field_Count).Field_Name_Len);
               User_Struct_Fields (User_Field_Count).Type_Token :=
                 (if Tree (Tree (Curr).Left_Child).Right_Child /= 0
                  then Tree (Tree (Tree (Curr).Left_Child).Right_Child).Token_Index
                  else 0);
               User_Struct_Fields (User_Field_Count).Kind :=
                 Kind_From_Type_Token
                   (Tokens,
                    User_Struct_Fields (User_Field_Count).Type_Token,
                    Kind_S64);
            end if;

            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end;
   end Register_Struct_From_Node;

   procedure Register_Struct_Instance_Symbols
     (Tokens       : in Token_Array;
      Name_Token   : in Natural;
      Type_Token   : in Natural;
      Module_Token : in Natural)
   is
      Base_Name   : constant String := Token_Text_Copy (Tokens, Name_Token);
      Struct_Name : constant String := Token_Text_Copy (Tokens, Type_Token);
   begin
      if Base_Name'Length = 0 or else Struct_Name'Length = 0 then
         return;
      end if;

      for I in 1 .. User_Field_Count loop
         if User_Struct_Fields (I).Active
           and then Name_Equals_Text
             (User_Struct_Fields (I).Struct_Name,
              User_Struct_Fields (I).Struct_Name_Len,
              Struct_Name)
         then
            declare
               Field_Name : constant String :=
                 Base_Name & "." &
                 Buffer_Text
                   (User_Struct_Fields (I).Field_Name,
                    User_Struct_Fields (I).Field_Name_Len);
            begin
               Register_Symbol_Text
                 (Tokens,
                  Field_Name,
                  Base_Name & "_" &
                    Buffer_Text
                      (User_Struct_Fields (I).Field_Name,
                       User_Struct_Fields (I).Field_Name_Len),
                  User_Struct_Fields (I).Type_Token,
                  User_Struct_Fields (I).Kind,
                  0,
                  Shape_Scalar,
                  Module_Token => Module_Token);
            end;
         end if;
      end loop;
   end Register_Struct_Instance_Symbols;

   procedure Register_Import (Node : in Node_Index) is
   begin
      if Node /= 0 and then Import_Count < Max_Imports then
         Import_Count := Import_Count + 1;
         Imports (Import_Count) := (Active => True, Node => Node);
      end if;
   end Register_Import;

   procedure Register_Markov_Model
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index)
   is
      Name_Node : constant Node_Index := Tree (Node).Left_Child;
      Name_Text : constant String :=
        (if Name_Node /= 0 then Token_Text_Copy (Tokens, Tree (Name_Node).Token_Index) else "");
   begin
      if Name_Text'Length = 0 or else Markov_Model_Count >= Max_Advanced_Nodes then
         return;
      end if;

      if Find_Markov_Model (Tokens, Tree (Name_Node).Token_Index) /= 0 then
         return;
      end if;

      Markov_Model_Count := Markov_Model_Count + 1;
      Markov_Models (Markov_Model_Count).Active := True;
      Store_Name_Text
        (Name_Text,
         Markov_Models (Markov_Model_Count).Name,
         Markov_Models (Markov_Model_Count).Name_Len);
      Markov_Models (Markov_Model_Count).Node := Node;
   end Register_Markov_Model;

   procedure Register_Neural_Model
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index)
   is
      Name_Node : constant Node_Index := Tree (Node).Left_Child;
      Name_Text : constant String :=
        (if Name_Node /= 0 then Token_Text_Copy (Tokens, Tree (Name_Node).Token_Index) else "");
   begin
      if Name_Text'Length = 0 or else Neural_Model_Count >= Max_Advanced_Nodes then
         return;
      end if;

      if Find_Neural_Model (Tokens, Tree (Name_Node).Token_Index) /= 0 then
         return;
      end if;

      Neural_Model_Count := Neural_Model_Count + 1;
      Neural_Models (Neural_Model_Count).Active := True;
      Store_Name_Text
        (Name_Text,
         Neural_Models (Neural_Model_Count).Name,
         Neural_Models (Neural_Model_Count).Name_Len);
      Neural_Models (Neural_Model_Count).Node := Node;
   end Register_Neural_Model;

   procedure Register_Network_Socket
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index;
      Module_Token : in Natural)
   is
      Name_Node : constant Node_Index := Tree (Node).Left_Child;
      Name_Text : constant String :=
        (if Name_Node /= 0 then Token_Text_Copy (Tokens, Tree (Name_Node).Token_Index) else "");
   begin
      if Name_Text'Length = 0 or else Network_Socket_Count >= Max_Advanced_Nodes then
         return;
      end if;

      if Find_Network_Socket (Tokens, Tree (Name_Node).Token_Index) = 0 then
         Network_Socket_Count := Network_Socket_Count + 1;
         Network_Sockets (Network_Socket_Count).Active := True;
         Store_Name_Text
           (Name_Text,
            Network_Sockets (Network_Socket_Count).Name,
            Network_Sockets (Network_Socket_Count).Name_Len);
         Network_Sockets (Network_Socket_Count).Node := Node;
      end if;

      Register_Symbol
        (Tokens,
         Tree (Name_Node).Token_Index,
         0,
         Kind_U64,
         0,
         Module_Token => Module_Token);
   end Register_Network_Socket;

   function Find_Import
     (Tokens      : Token_Array;
      Tree        : Node_Array;
      Token_Index : Natural) return Natural
   is
      Decl_Node : Node_Index;
      Name_Node : Node_Index;
   begin
      for I in 1 .. Import_Count loop
         if Imports (I).Active then
            Decl_Node := Tree (Imports (I).Node).Left_Child;
            if Decl_Node /= 0 then
               Name_Node := Tree (Decl_Node).Left_Child;
               if Name_Node /= 0
                 and then Token_Text_Same
                   (Tokens, Tree (Name_Node).Token_Index, Token_Index)
               then
                  return I;
               end if;
            end if;
         end if;
      end loop;

      return 0;
   end Find_Import;

   function Find_Markov_Model
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural
   is
      Name_Text : constant String := Token_Text_Copy (Tokens, Token_Index);
   begin
      for I in 1 .. Markov_Model_Count loop
         if Markov_Models (I).Active
           and then Name_Equals_Text
             (Markov_Models (I).Name,
              Markov_Models (I).Name_Len,
              Name_Text)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Markov_Model;

   function Find_Neural_Model
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural
   is
      Name_Text : constant String := Token_Text_Copy (Tokens, Token_Index);
   begin
      for I in 1 .. Neural_Model_Count loop
         if Neural_Models (I).Active
           and then Name_Equals_Text
             (Neural_Models (I).Name,
              Neural_Models (I).Name_Len,
              Name_Text)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Neural_Model;

   function Find_Network_Socket
     (Tokens      : in Token_Array;
      Token_Index : in Natural) return Natural
   is
      Name_Text : constant String := Token_Text_Copy (Tokens, Token_Index);
   begin
      for I in 1 .. Network_Socket_Count loop
         if Network_Sockets (I).Active
           and then Name_Equals_Text
             (Network_Sockets (I).Name,
              Network_Sockets (I).Name_Len,
              Name_Text)
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Network_Socket;

   function Find_Routine
     (Tokens       : Token_Array;
      Token_Index  : Natural;
      Module_Token : Natural := 0) return Natural
   is
      Tok : Token;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return 0;
      end if;

      Tok := Tokens (Token_Index);
      for I in 1 .. Routine_Count loop
         if Routines (I).Active and then Routines (I).Name_Len = Tok.Length then
            declare
               Matches : Boolean := True;
            begin
               if Module_Token = 0 then
                  if Routines (I).Module_Token /= 0 then
                     Matches := False;
                  end if;
               else
                  if Routines (I).Module_Token = 0 or else not Token_Text_Same (Tokens, Module_Token, Routines (I).Module_Token) then
                     Matches := False;
                  end if;
               end if;

               if Matches then
                  for J in 1 .. Routines (I).Name_Len loop
                     if Routines (I).Name (J) /=
                       Input_Buffer (Tok.Start + J - 1)
                     then
                        Matches := False;
                     end if;
                  end loop;
               end if;

               if Matches then
                  return I;
               end if;
            end;
         end if;
      end loop;

      return 0;
   end Find_Routine;

   function Find_Visible_Routine
     (Tokens      : Token_Array;
      Token_Index : Natural) return Natural
   is
      Routine_Id : Natural := 0;
   begin
      if Active_Routine_Module_Token /= 0 then
         Routine_Id :=
           Find_Routine
             (Tokens,
              Token_Index,
              Active_Routine_Module_Token);
         if Routine_Id /= 0 then
            return Routine_Id;
         end if;
      end if;

      return Find_Routine (Tokens, Token_Index);
   end Find_Visible_Routine;

   function Find_Member_Routine
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return Natural
   is
      Module_Node : Node_Index := 0;
      Member_Node : Node_Index := 0;
   begin
      if Node = 0 or else Tree (Node).Kind /= AST_Member_Expr then
         return 0;
      end if;

      Module_Node := Tree (Node).Left_Child;
      Member_Node := Tree (Node).Right_Child;
      if Module_Node = 0 or else Member_Node = 0 then
         return 0;
      end if;

      if Tree (Module_Node).Kind /= AST_Var_Expr
        or else Tree (Member_Node).Kind /= AST_Var_Expr
      then
         return 0;
      end if;

      return
        Find_Routine
          (Tokens,
           Tree (Member_Node).Token_Index,
           Tree (Module_Node).Token_Index);
   end Find_Member_Routine;

   procedure Register_Routine
     (Tokens       : in Token_Array;
      Name_Token   : in Natural;
      Module_Token : in Natural;
      Node         : in Node_Index;
      Is_Function  : in Boolean)
   is
      Tok : Token;
      Pos : Natural;
   begin
      if Name_Token = 0 or else Name_Token > Tokens'Length then
         return;
      end if;

      if Find_Routine (Tokens, Name_Token, Module_Token) /= 0 then
         return;
      end if;

      if Routine_Count >= Max_Routines then
         return;
      end if;

      Tok := Tokens (Name_Token);
      if Tok.Length = 0 then
         return;
      end if;

      Routine_Count := Routine_Count + 1;
      Routines (Routine_Count).Active := True;
      Routines (Routine_Count).Name := (others => ' ');
      Routines (Routine_Count).Name_Len :=
        (if Tok.Length > Max_Name_Len then Max_Name_Len else Tok.Length);
      Routines (Routine_Count).Node := Node;
      Routines (Routine_Count).Is_Function := Is_Function;
      Routines (Routine_Count).Module_Token := Module_Token;

      for I in 1 .. Routines (Routine_Count).Name_Len loop
         Pos := Tok.Start + I - 1;
         Routines (Routine_Count).Name (I) := Input_Buffer (Pos);
      end loop;
   end Register_Routine;

   procedure Emit_Routine_Name
     (Tokens     : in Token_Array;
      Tree       : in Node_Array;
      Routine_Id : in Natural;
      Success    : in out Boolean)
   is
      Node      : Node_Index := 0;
      Name_Node : Node_Index := 0;
   begin
      if not Success then
         return;
      end if;

      if Routine_Id = 0
        or else Routine_Id > Routine_Count
        or else not Routines (Routine_Id).Active
      then
         Success := Emit_Raw ("alb_routine");
         return;
      end if;

      Node := Routines (Routine_Id).Node;
      if Node /= 0 then
         Name_Node := Tree (Node).Left_Child;
      end if;

      Success := Emit_Raw ("ALB_");
      if Routines (Routine_Id).Module_Token /= 0 then
         Emit_Token_Name_Content
           (Tokens,
            Routines (Routine_Id).Module_Token,
            Success);
         if Success then
            Success := Emit_Raw ("_");
         end if;
      end if;

      if Name_Node /= 0 then
         Emit_Token_Name_Content
           (Tokens,
            Tree (Name_Node).Token_Index,
            Success);
      else
         Success := Emit_Raw ("alb_routine");
      end if;
   end Emit_Routine_Name;

   procedure Scan_Node
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index;
      Module_Token : in Natural)
   is
      Curr      : Node_Index;
      Name_Node : Node_Index;
      K         : DotNet_Value_Kind;
      Dims      : Dim_Node_List := (others => 0);
      Rank      : Natural := 0;
   begin
      if Node = 0 then
         return;
      end if;

      case Tree (Node).Kind is
         when AST_Block_Stmt | AST_Program =>
            Curr := Tree (Node).Left_Child;
            while Curr /= 0 loop
               Scan_Node (Tokens, Tree, Curr, Module_Token);
               Curr := Tree (Curr).Next_Sibling;
            end loop;

         when AST_Let_Stmt =>
            Name_Node := Tree (Node).Left_Child;
            if Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Var_Expr
              and then Tree (Name_Node).Left_Child = 0
              and then not
                (Tree (Node).Right_Child = 0
                 and then Tree (Node).Token_Index > 0
                 and then Tokens (Tree (Node).Token_Index).Kind = Tok_U0)
            then
               if Is_User_Struct_Type (Tokens, Tree (Node).Token_Index) then
                  Register_Struct_Instance_Symbols
                    (Tokens,
                     Tree (Name_Node).Token_Index,
                     Tree (Node).Token_Index,
                     Module_Token);
               else
                  K := Kind_From_Type_Token
                    (Tokens,
                     Tree (Node).Token_Index,
                     Infer_Expression_Kind (Tokens, Tree, Tree (Node).Right_Child));
                  Register_Symbol
                    (Tokens,
                     Tree (Name_Node).Token_Index,
                     Tree (Node).Token_Index,
                     K,
                     Tree (Node).Right_Child,
                     Module_Token => Module_Token);
               end if;
            end if;

         when AST_Const_Decl =>
            Name_Node := Tree (Node).Left_Child;
            if Name_Node /= 0 then
               Register_Symbol_Text
                 (Tokens,
                  Token_Text_Copy (Tokens, Tree (Name_Node).Token_Index),
                  Token_Text_Copy (Tokens, Tree (Name_Node).Token_Index),
                  0,
                  Kind_S64,
                  Tree (Node).Right_Child,
                  Shape_Const,
                  Module_Token => Module_Token);
            end if;

         when AST_Import_C | AST_Import_DLL =>
            Register_Import (Node);

         when AST_Markov_Model_Decl =>
            Register_Markov_Model (Tokens, Tree, Node);

         when AST_Neural_Topology_Decl =>
            Register_Neural_Model (Tokens, Tree, Node);

         when AST_Network_Socket_Decl =>
            Register_Network_Socket (Tokens, Tree, Node, Module_Token);

         when AST_Struct_Decl =>
            Register_Struct_From_Node (Tokens, Tree, Node);

         when AST_Procedure_Decl | AST_Function_Decl =>
            Name_Node := Tree (Node).Left_Child;
            if Name_Node /= 0 then
               Register_Routine
                 (Tokens,
                  Tree (Name_Node).Token_Index,
                  Module_Token,
                  Node,
                  Tree (Node).Kind = AST_Function_Decl);
            end if;

         when AST_DeclareModule =>
            null;

         when AST_Module =>
            Name_Node := Tree (Node).Left_Child;
            if Name_Node /= 0 and then Tree (Name_Node).Token_Index /= 0 then
               Scan_Node
                 (Tokens,
                  Tree,
                  Tree (Node).Right_Child,
                  Tree (Name_Node).Token_Index);
            else
               Scan_Node (Tokens, Tree, Tree (Node).Right_Child, 0);
            end if;

         when AST_On_Block =>
            if Tree (Node).Token_Index /= 0 then
               case Tokens (Tree (Node).Token_Index).Kind is
                  when Tok_Tick =>
                     Tick_Block := Tree (Node).Left_Child;
                  when Tok_Paint =>
                     Paint_Block := Tree (Node).Left_Child;
                  when Tok_Key =>
                     Key_Block := Tree (Node).Left_Child;
                  when others =>
                     null;
               end case;
            end if;
            Scan_Node (Tokens, Tree, Tree (Node).Left_Child, Module_Token);

         when AST_Strict_Stmt =>
            if Tree (Node).Left_Child /= 0 then
               Curr := Tree (Node).Right_Child;
               Dims := (others => 0);
               Rank := 0;
               while Curr /= 0 and then Rank < Max_Array_Rank loop
                  Rank := Rank + 1;
                  Dims (Rank) := Curr;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;

               Register_Symbol_Text
                 (Tokens,
                  Token_Text_Copy (Tokens, Tree (Tree (Node).Left_Child).Token_Index),
                  Token_Text_Copy (Tokens, Tree (Tree (Node).Left_Child).Token_Index),
                  (if Tree (Tree (Node).Left_Child).Right_Child /= 0
                   then Tree (Tree (Tree (Node).Left_Child).Right_Child).Token_Index
                   else 0),
                  Kind_From_Type_Token
                    (Tokens,
                     (if Tree (Tree (Node).Left_Child).Right_Child /= 0
                      then Tree (Tree (Tree (Node).Left_Child).Right_Child).Token_Index
                      else 0),
                     Kind_S64),
                  0,
                  Shape_Strict_Array,
                  Rank,
                  Dims,
                  Module_Token => Module_Token);
            end if;

         when AST_Slide_Stmt =>
            if Tree (Node).Left_Child /= 0 then
               Dims := (others => 0);
               Dims (1) := Tree (Node).Right_Child;
               Register_Symbol_Text
                 (Tokens,
                  Token_Text_Copy (Tokens, Tree (Tree (Node).Left_Child).Token_Index),
                  Token_Text_Copy (Tokens, Tree (Tree (Node).Left_Child).Token_Index),
                  (if Tree (Tree (Node).Left_Child).Right_Child /= 0
                   then Tree (Tree (Tree (Node).Left_Child).Right_Child).Token_Index
                   else 0),
                  Kind_From_Type_Token
                    (Tokens,
                     (if Tree (Tree (Node).Left_Child).Right_Child /= 0
                      then Tree (Tree (Tree (Node).Left_Child).Right_Child).Token_Index
                      else 0),
                     Kind_S64),
                  0,
                  Shape_Slide_Array,
                  1,
                  Dims,
                  (if Tree (Node).Right_Child /= 0
                   then Tree (Tree (Node).Right_Child).Next_Sibling
                   else 0),
                  Module_Token => Module_Token);
            end if;

         when AST_Parallel_Decl =>
            if Tree (Node).Left_Child /= 0 then
               declare
                  Group_Name  : constant String :=
                    Token_Text_Copy (Tokens, Tree (Tree (Node).Left_Child).Token_Index);
                  Field_Node  : Node_Index := Tree (Node).Right_Child;
               begin
                  Curr := Tree (Tree (Node).Left_Child).Left_Child;
                  Dims := (others => 0);
                  Rank := 0;
                  while Curr /= 0 and then Rank < Max_Array_Rank loop
                     Rank := Rank + 1;
                     Dims (Rank) := Curr;
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;

                  while Field_Node /= 0 loop
                     if Tree (Field_Node).Kind = AST_Parallel_Field
                       and then Tree (Field_Node).Left_Child /= 0
                     then
                        declare
                           Field_Name : constant String :=
                             Token_Text_Copy (Tokens, Tree (Tree (Field_Node).Left_Child).Token_Index);
                           Type_Tok   : constant Natural :=
                             (if Tree (Tree (Field_Node).Left_Child).Right_Child /= 0
                              then Tree (Tree (Tree (Field_Node).Left_Child).Right_Child).Token_Index
                              else 0);
                        begin
                           Register_Symbol_Text
                             (Tokens,
                              Group_Name & "." & Field_Name,
                              Group_Name & "_" & Field_Name,
                              Type_Tok,
                              Kind_From_Type_Token (Tokens, Type_Tok, Kind_S64),
                              0,
                              Shape_Parallel_Field,
                              Rank,
                              Dims,
                              Module_Token => Module_Token);
                        end;
                     end if;
                     Field_Node := Tree (Field_Node).Next_Sibling;
                  end loop;
               end;
            end if;

         when AST_Temporal_Decl =>
            if Tree (Node).Left_Child /= 0 then
               Register_Symbol_Text
                 (Tokens,
                  Token_Text_Copy (Tokens, Tree (Tree (Node).Left_Child).Token_Index),
                  Token_Text_Copy (Tokens, Tree (Tree (Node).Left_Child).Token_Index),
                  Tree (Node).Token_Index,
                  Kind_From_Type_Token (Tokens, Tree (Node).Token_Index, Kind_S64),
                  (if Tree (Node).Right_Child /= 0
                   then Tree (Tree (Node).Right_Child).Next_Sibling
                   else 0),
                  Shape_Temporal,
                  0,
                  (others => 0),
                  0,
                  Tree (Node).Right_Child,
                  Module_Token => Module_Token);
            end if;

         when AST_Knows_Change =>
            if Watch_Count < Max_Logic_Watches then
               Watch_Count := Watch_Count + 1;
               Watch_Nodes (Watch_Count) := Node;
            end if;

         when AST_For_Stmt =>
            if Tree (Node).Token_Index /= 0
              and then Find_Symbol_In_Context
                (Tokens, Tree (Node).Token_Index, Module_Token) = 0
            then
               Register_Symbol
                 (Tokens,
                  Tree (Node).Token_Index,
                  0,
                  Kind_S64,
                  0,
                  Module_Token => Module_Token);
            end if;
            Scan_Node (Tokens, Tree, Tree (Node).Left_Child, Module_Token);
            Scan_Node (Tokens, Tree, Tree (Node).Right_Child, Module_Token);

         when AST_If_Stmt | AST_While_Stmt | AST_Repeat_Stmt |
              AST_Foreach_Stmt | AST_Temporal_Block |
              AST_Reversible_Block | AST_Atomic_Block =>
            Scan_Node (Tokens, Tree, Tree (Node).Left_Child, Module_Token);
            Scan_Node (Tokens, Tree, Tree (Node).Right_Child, Module_Token);
            if Tree (Node).Kind = AST_If_Stmt
              and then Tree (Node).Right_Child /= 0
              and then Tree (Tree (Node).Right_Child).Next_Sibling /= 0
            then
               Scan_Node
                 (Tokens,
                  Tree,
                  Tree (Tree (Node).Right_Child).Next_Sibling,
                  Module_Token);
            end if;

         when others =>
            null;
      end case;

   end Scan_Node;

   procedure Scan_List
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      First  : in Node_Index)
   is
      Curr : Node_Index := First;
   begin
      while Curr /= 0 loop
         Scan_Node (Tokens, Tree, Curr, 0);
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Scan_List;

   procedure Emit_String_Literal
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Success     : in out Boolean)
   is
      Tok         : Token;
      First_Char  : Character := '"';
      First_Offset : Natural := 0;
      Last_Offset : Natural := 0;
      C           : Character;
   begin
      if not Success then
         return;
      end if;

      if Token_Index = 0 or else Token_Index > Tokens'Length then
         Success := Emit_Raw ("""""");
         return;
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         Success := Emit_Raw ("""""");
         return;
      end if;

      First_Char := Input_Buffer (Tok.Start);
      if Tok.Length >= 2 and then
        (First_Char = '"' or else First_Char = '`')
      then
         First_Offset := 1;
         Last_Offset := Tok.Length - 2;
      else
         First_Offset := 0;
         Last_Offset := Tok.Length - 1;
      end if;

      Success := Emit_Raw ("""");
      for Offset in First_Offset .. Last_Offset loop
         exit when not Success;
         C := Input_Buffer (Tok.Start + Offset);
         if C = '"' then
            Success := Emit_Raw ("\""");
         elsif C = '\' then
            Success := Emit_Raw ("\\");
         elsif C = ASCII.HT then
            Success := Emit_Raw ("\t");
         elsif C = ASCII.CR then
            Success := Emit_Raw ("\r");
         elsif C = ASCII.LF then
            Success := Emit_Raw ("\n");
         else
            Success := Emit_Raw (C & "");
         end if;
      end loop;

      if Success then
         Success := Emit_Raw ("""");
      end if;
   end Emit_String_Literal;

   procedure Emit_Raw_Token
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Success     : in out Boolean)
   is
      Tok : Token;
   begin
      if not Success then
         return;
      end if;

      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return;
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         return;
      end if;

      for Offset in 0 .. Tok.Length - 1 loop
         Success := Emit_Raw (Input_Buffer (Tok.Start + Offset) & "");
         exit when not Success;
      end loop;
   end Emit_Raw_Token;

   function Line_Is_End_Enable
     (First : Natural;
      Last  : Natural) return Boolean
   is
      P : Natural := First;
   begin
      while P <= Last and then
        (Input_Buffer (P) = ' ' or else Input_Buffer (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P + 2 > Last
        or else To_Upper (Input_Buffer (P)) /= 'E'
        or else To_Upper (Input_Buffer (P + 1)) /= 'N'
        or else To_Upper (Input_Buffer (P + 2)) /= 'D'
      then
         return False;
      end if;
      P := P + 3;

      while P <= Last and then
        (Input_Buffer (P) = ' ' or else Input_Buffer (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P + 5 > Last
        or else To_Upper (Input_Buffer (P)) /= 'E'
        or else To_Upper (Input_Buffer (P + 1)) /= 'N'
        or else To_Upper (Input_Buffer (P + 2)) /= 'A'
        or else To_Upper (Input_Buffer (P + 3)) /= 'B'
        or else To_Upper (Input_Buffer (P + 4)) /= 'L'
        or else To_Upper (Input_Buffer (P + 5)) /= 'E'
      then
         return False;
      end if;
      P := P + 6;

      while P <= Last loop
         if Input_Buffer (P) /= ' ' and then Input_Buffer (P) /= ASCII.HT
         then
            return False;
         end if;
         P := P + 1;
      end loop;

      return True;
   end Line_Is_End_Enable;

   procedure Emit_Raw_Block_Body
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Success     : in out Boolean)
   is
      Tok        : Token;
      Pos        : Natural;
      Last       : Natural;
      Line_First : Natural;
      Line_Last  : Natural;
   begin
      if not Success then
         return;
      end if;

      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return;
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         return;
      end if;

      Pos := Tok.Start;
      Last := Tok.Start + Tok.Length - 1;

      while Pos <= Last and then Input_Buffer (Pos) /= ASCII.LF loop
         Pos := Pos + 1;
      end loop;
      if Pos <= Last and then Input_Buffer (Pos) = ASCII.LF then
         Pos := Pos + 1;
      end if;

      while Pos <= Last loop
         Line_First := Pos;
         Line_Last := Pos;
         while Line_Last <= Last and then Input_Buffer (Line_Last) /= ASCII.LF loop
            Line_Last := Line_Last + 1;
         end loop;

         if Line_Last > Line_First
           and then Line_Is_End_Enable (Line_First, Line_Last - 1)
         then
            return;
         end if;

         for I in Line_First .. Line_Last - 1 loop
            Success := Emit_Raw (Input_Buffer (I) & "");
            exit when not Success;
         end loop;
         exit when not Success;

         if Line_Last <= Last and then Input_Buffer (Line_Last) = ASCII.LF then
            Success := Emit_Raw (ASCII.LF & "");
            Pos := Line_Last + 1;
         else
            Pos := Last + 1;
         end if;
      end loop;
   end Emit_Raw_Block_Body;

   procedure Emit_Numeric_Literal
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Kind        : in AST.Node_Kind;
      Success     : in out Boolean)
   is
      Tok : Token;
      C   : Character;
   begin
      if not Success then
         return;
      end if;

      if Token_Index = 0 or else Token_Index > Tokens'Length then
         Success := Emit_Raw ("0");
         return;
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         Success := Emit_Raw ("0");
         return;
      end if;

      if Kind = AST_Hex_Expr then
         Success := Emit_Raw ("0x");
         for Offset in 0 .. Tok.Length - 1 loop
            exit when not Success;
            C := Input_Buffer (Tok.Start + Offset);
            if C /= '$' then
               Success := Emit_Raw (C & "");
            end if;
         end loop;
      elsif Kind = AST_Bin_Expr then
         Success := Emit_Raw ("0b");
         for Offset in 0 .. Tok.Length - 1 loop
            exit when not Success;
            C := Input_Buffer (Tok.Start + Offset);
            if C /= '%' then
               Success := Emit_Raw (C & "");
            end if;
         end loop;
      elsif Kind = AST_Octal_Expr then
         Success := Emit_Raw ("0");
      else
         for Offset in 0 .. Tok.Length - 1 loop
            exit when not Success;
            Success := Emit_Raw (Input_Buffer (Tok.Start + Offset) & "");
         end loop;
      end if;
   end Emit_Numeric_Literal;

   procedure Emit_BinOp_Token
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Success     : in out Boolean)
   is
      K : Token_Kind;
   begin
      if not Success then
         return;
      end if;

      if Token_Index = 0 or else Token_Index > Tokens'Length then
         Success := Emit_Raw (" + ");
         return;
      end if;

      K := Tokens (Token_Index).Kind;
      case K is
         when TOK_PLUS =>
            Success := Emit_Raw (" + ");
         when TOK_MINUS =>
            Success := Emit_Raw (" - ");
         when TOK_MUL =>
            Success := Emit_Raw (" * ");
         when TOK_DIV =>
            Success := Emit_Raw (" / ");
         when TOK_MOD =>
            Success := Emit_Raw (" % ");
         when TOK_LESS =>
            Success := Emit_Raw (" < ");
         when TOK_GREATER =>
            Success := Emit_Raw (" > ");
         when TOK_LESS_EQUAL =>
            Success := Emit_Raw (" <= ");
         when TOK_GREATER_EQUAL =>
            Success := Emit_Raw (" >= ");
         when TOK_EQUAL =>
            Success := Emit_Raw (" == ");
         when TOK_NOT_EQUAL =>
            Success := Emit_Raw (" != ");
         when TOK_AND =>
            Success := Emit_Raw (" & ");
         when TOK_OR =>
            Success := Emit_Raw (" | ");
         when TOK_XOR =>
            Success := Emit_Raw (" ^ ");
         when TOK_SHL =>
            Success := Emit_Raw (" << ");
         when TOK_SHR =>
            Success := Emit_Raw (" >> ");
         when TOK_ASSIGN =>
            Success := Emit_Raw (" == ");
         when others =>
            Success := Emit_Raw (" + ");
      end case;
   end Emit_BinOp_Token;

   procedure Emit_Arg_List
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      List    : in Node_Index;
      Success : in out Boolean)
   is
      Curr  : Node_Index := 0;
      First : Boolean := True;
   begin
      if List /= 0 then
         Curr := Tree (List).Left_Child;
      end if;

      while Curr /= 0 loop
         if not First then
            Success := Emit_Raw (", ");
         end if;
         Emit_Expression (Tokens, Tree, Curr, Kind_S64, Success);
         First := False;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Arg_List;

   procedure Emit_Arg_List_For_Routine
     (Tokens      : in Token_Array;
      Tree        : in Node_Array;
      List        : in Node_Index;
      Routine_Id  : in Natural;
      Success     : in out Boolean)
   is
      Arg_Curr   : Node_Index := 0;
      Param_Curr : Node_Index := 0;
      Params     : Node_Index := 0;
      Name_Node  : Node_Index := 0;
      Type_Node  : Node_Index := 0;
      First      : Boolean := True;
      K          : DotNet_Value_Kind := Kind_S64;
   begin
      if List /= 0 then
         Arg_Curr := Tree (List).Left_Child;
      end if;

      if Routine_Id /= 0 and then Routine_Id <= Routine_Count
        and then Routines (Routine_Id).Active
      then
         Name_Node := Tree (Routines (Routine_Id).Node).Left_Child;
         if Name_Node /= 0 then
            Params := Tree (Name_Node).Right_Child;
            if Params /= 0 then
               Param_Curr := Tree (Params).Left_Child;
            end if;
         end if;
      end if;

      while Arg_Curr /= 0 loop
         if not First then
            Success := Emit_Raw (", ");
         end if;

         K := Kind_S64;
         if Param_Curr /= 0 then
            Type_Node := Tree (Param_Curr).Right_Child;
            if Type_Node /= 0 then
               K := Kind_From_Type_Token
                 (Tokens, Tree (Type_Node).Token_Index, Kind_S64);
            end if;

            if Tree (Param_Curr).Token_Index /= 0
              and then Tokens (Tree (Param_Curr).Token_Index).Kind = Tok_Out
            then
               Success := Emit_Raw ("ref ");
            end if;
         end if;

         if Param_Curr /= 0
           and then Tree (Param_Curr).Token_Index /= 0
           and then Tokens (Tree (Param_Curr).Token_Index).Kind = Tok_Out
         then
            Emit_Expression (Tokens, Tree, Arg_Curr, K, Success);
         else
            Emit_Assignment_Value (Tokens, Tree, Arg_Curr, K, Success);
         end if;
         First := False;
         Arg_Curr := Tree (Arg_Curr).Next_Sibling;
         if Param_Curr /= 0 then
            Param_Curr := Tree (Param_Curr).Next_Sibling;
         end if;
      end loop;
   end Emit_Arg_List_For_Routine;

   function First_Arg
     (Tree : Node_Array;
      List : Node_Index) return Node_Index
   is
   begin
      if List /= 0 and then Tree (List).Kind = AST_Arg_List then
         return Tree (List).Left_Child;
      end if;
      return 0;
   end First_Arg;

   function Next_Arg
     (Tree : Node_Array;
      Arg  : Node_Index) return Node_Index
   is
   begin
      if Arg /= 0 then
         return Tree (Arg).Next_Sibling;
      end if;
      return 0;
   end Next_Arg;

   function Predicate_Name_From_Node
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return String
   is
   begin
      if Node = 0 then
         return "";
      end if;

      case Tree (Node).Kind is
         when AST_Predicate | AST_Assert_Stmt | AST_Retract_Stmt =>
            return Token_Text_Copy (Tokens, Tree (Node).Token_Index);

         when AST_Update_Stmt | AST_Findall_Query | AST_Query | AST_Knows_Query =>
            return Predicate_Name_From_Node (Tokens, Tree, Tree (Node).Left_Child);

         when AST_Knows_Change =>
            return Predicate_Name_From_Node (Tokens, Tree, Tree (Node).Right_Child);

         when AST_Find_Query =>
            if Token_Text_Equals (Tokens, Tree (Node).Token_Index, "FIND") then
               return Predicate_Name_From_Node (Tokens, Tree, Tree (Node).Left_Child);
            else
               return Token_Text_Copy (Tokens, Tree (Node).Token_Index);
            end if;

         when AST_Func_Call | AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            return Token_Text_Copy (Tokens, Tree (Node).Token_Index);

         when others =>
            return Token_Text_Copy (Tokens, Tree (Node).Token_Index);
      end case;
   end Predicate_Name_From_Node;

   function Predicate_First_Arg_Node
     (Tree : in Node_Array;
      Node : in Node_Index) return Node_Index
   is
   begin
      if Node = 0 then
         return 0;
      end if;

      if Tree (Node).Kind = AST_Predicate and then Tree (Node).Left_Child > 0 then
         if Tree (Tree (Node).Left_Child).Kind = AST_Arg_List then
            return Tree (Tree (Node).Left_Child).Left_Child;
         else
            return Tree (Node).Left_Child;
         end if;
      elsif Tree (Node).Kind in AST_Update_Stmt | AST_Findall_Query |
        AST_Query | AST_Knows_Query
      then
         return Predicate_First_Arg_Node (Tree, Tree (Node).Left_Child);
      elsif Tree (Node).Kind = AST_Knows_Change and then Tree (Node).Right_Child > 0 then
         return Predicate_First_Arg_Node (Tree, Tree (Node).Right_Child);
      elsif Tree (Node).Kind = AST_Find_Query then
         if Tree (Node).Left_Child > 0 then
            return Predicate_First_Arg_Node (Tree, Tree (Node).Left_Child);
         end if;
         return Tree (Node).Left_Child;
      elsif Tree (Node).Kind in AST_Assert_Stmt | AST_Retract_Stmt then
         return Tree (Node).Left_Child;
      elsif Tree (Node).Kind = AST_Func_Call and then Tree (Node).Right_Child > 0 then
         if Tree (Tree (Node).Right_Child).Kind = AST_Arg_List then
            return Tree (Tree (Node).Right_Child).Left_Child;
         else
            return Tree (Node).Right_Child;
         end if;
      else
         return 0;
      end if;
   end Predicate_First_Arg_Node;

   function Predicate_Id_From_Name (Name : in String) return Natural is
      H : Long_Long_Integer := 5381;
   begin
      if Name'Length = 0 then
         return 0;
      end if;

      for I in Name'Range loop
         H := ((H * 33) + Character'Pos (To_Upper (Name (I)))) mod 2_147_483_647;
      end loop;
      if H = 0 then
         return 1;
      end if;
      return Natural (H);
   end Predicate_Id_From_Name;

   procedure Emit_Predicate_Id
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Emit_Natural
        (Predicate_Id_From_Name (Predicate_Name_From_Node (Tokens, Tree, Node)),
         Success);
   end Emit_Predicate_Id;

   procedure Emit_Predicate_Arg1
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Arg_Node : constant Node_Index := Predicate_First_Arg_Node (Tree, Node);
   begin
      if Arg_Node /= 0 then
         Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
      else
         Success := Emit_Raw ("0");
      end if;
   end Emit_Predicate_Arg1;

   procedure Emit_Predicate_Arity
     (Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      if Predicate_First_Arg_Node (Tree, Node) /= 0 then
         Success := Emit_Raw ("1");
      else
         Success := Emit_Raw ("0");
      end if;
   end Emit_Predicate_Arity;

   procedure Emit_Array_Index
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Dims     : in Dim_Node_List;
      Rank     : in Natural;
      Bounds   : in Node_Index;
      Success  : in out Boolean)
   is
      Curr : Node_Index := Bounds;
   begin
      if Rank = 0 then
         Success := Emit_Raw ("0");
         return;
      end if;

      if Rank = 1 then
         Success := Emit_Raw ("((");
         Emit_Expression (Tokens, Tree, Curr, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (") - 1)");
         end if;
         return;
      end if;

      Success := Emit_Raw ("(");
      if Success then
         Success := Emit_Raw ("((");
      end if;
      Emit_Expression (Tokens, Tree, Curr, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (") - 1)");
      end if;
      Curr := Tree (Curr).Next_Sibling;

      for I in 2 .. Rank loop
         if not Success then
            exit;
         end if;
         Success := Emit_Raw (" * (");
         Emit_Expression (Tokens, Tree, Dims (I), Kind_S64, Success);
         if Success then
            Success := Emit_Raw (") + ((");
         end if;
         if Curr /= 0 then
            Emit_Expression (Tokens, Tree, Curr, Kind_S64, Success);
            Curr := Tree (Curr).Next_Sibling;
         else
            Success := Emit_Raw ("1");
         end if;
         if Success then
            Success := Emit_Raw (") - 1)");
         end if;
      end loop;

      if Success then
         Success := Emit_Raw (")");
      end if;
   end Emit_Array_Index;

   procedure Emit_Array_Length
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Dims     : in Dim_Node_List;
      Rank     : in Natural;
      Success  : in out Boolean)
   is
   begin
      if Rank = 0 then
         Success := Emit_Raw ("1");
         return;
      end if;

      Success := Emit_Raw ("(");
      for I in 1 .. Rank loop
         exit when not Success;
         if I > 1 then
            Success := Emit_Raw (" * ");
         end if;
         Emit_Expression (Tokens, Tree, Dims (I), Kind_S64, Success);
      end loop;
      if Success then
         Success := Emit_Raw (")");
      end if;
   end Emit_Array_Length;

   function Member_Path_Text
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return String
   is
   begin
      if Node = 0 then
         return "";
      elsif Tree (Node).Kind = AST_Var_Expr
        and then Tree (Node).Token_Index /= 0
      then
         return Token_Text_Copy (Tokens, Tree (Node).Token_Index);
      elsif Tree (Node).Kind /= AST_Member_Expr then
         return "";
      end if;

      declare
         Left_Text  : constant String :=
           Member_Path_Text (Tokens, Tree, Tree (Node).Left_Child);
         Right_Text : constant String :=
           Member_Path_Text (Tokens, Tree, Tree (Node).Right_Child);
      begin
         if Left_Text'Length = 0 then
            return Right_Text;
         elsif Right_Text'Length = 0 then
            return Left_Text;
         else
            return Left_Text & "." & Right_Text;
         end if;
      end;
   end Member_Path_Text;

   function Leftmost_Member_Token
     (Tree : in Node_Array;
      Node : in Node_Index) return Natural
   is
      Curr : Node_Index := Node;
   begin
      while Curr /= 0 and then Tree (Curr).Kind = AST_Member_Expr loop
         Curr := Tree (Curr).Left_Child;
      end loop;

      if Curr /= 0 then
         return Tree (Curr).Token_Index;
      end if;

      return 0;
   end Leftmost_Member_Token;

   function Find_Target_Symbol
     (Tokens : in Token_Array;
      Tree   : in Node_Array;
      Node   : in Node_Index) return Natural
   is
   begin
      if Node = 0 then
         return 0;
      end if;

      if Tree (Node).Kind = AST_Var_Expr then
         return Find_Symbol (Tokens, Tree (Node).Token_Index);
      elsif Tree (Node).Kind = AST_Temporal_Ref then
         if Tree (Node).Left_Child /= 0 then
            return Find_Target_Symbol (Tokens, Tree, Tree (Node).Left_Child);
         end if;
         return 0;
      elsif Tree (Node).Kind = AST_Member_Expr
      then
         declare
            Full_Name      : constant String :=
              Member_Path_Text (Tokens, Tree, Node);
            Leftmost_Token : constant Natural :=
              Leftmost_Member_Token (Tree, Node);
            Dot_Pos        : Natural := 0;
            Sym            : Natural := 0;
         begin
            if Full_Name'Length = 0 then
               return 0;
            end if;

            if Active_Routine_Module_Token /= 0 then
               Sym := Find_Symbol_By_Text
                 (Full_Name, Active_Routine_Module_Token);
               if Sym /= 0 then
                  return Sym;
               end if;
            end if;

            Sym := Find_Symbol_By_Text (Full_Name, 0);
            if Sym /= 0 then
               return Sym;
            end if;

            for I in Full_Name'Range loop
               if Full_Name (I) = '.' then
                  Dot_Pos := I;
                  exit;
               end if;
            end loop;

            if Leftmost_Token /= 0
              and then Dot_Pos /= 0
              and then Dot_Pos < Full_Name'Last
            then
               Sym := Find_Symbol_By_Text
                 (Full_Name (Dot_Pos + 1 .. Full_Name'Last),
                  Leftmost_Token);
               if Sym /= 0 then
                  return Sym;
               end if;
            end if;
         end;
      end if;

      return 0;
   end Find_Target_Symbol;

   procedure Emit_Target
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Sym       : Natural := 0;
      Left_Node : Node_Index := 0;
   begin
      if Node = 0 then
         Success := Emit_Raw ("alb_missing_target");
         return;
      end if;

      if Tree (Node).Kind = AST_Var_Expr then
         Sym := Find_Symbol (Tokens, Tree (Node).Token_Index);
         if Tree (Node).Left_Child /= 0 and then Sym /= 0
           and then Symbols (Sym).Shape in Shape_Strict_Array | Shape_Slide_Array
         then
            Emit_Name_Text
              (Symbols (Sym).Emit_Name,
               Symbols (Sym).Emit_Name_Len,
               Success);
            if Success then
               Success := Emit_Raw ("[");
            end if;
            Emit_Array_Index
              (Tokens,
               Tree,
               Symbols (Sym).Dims,
               Symbols (Sym).Rank,
               Tree (Node).Left_Child,
               Success);
            if Success then
               Success := Emit_Raw ("]");
            end if;
         elsif Sym /= 0 then
            Emit_Name_Text
              (Symbols (Sym).Emit_Name,
               Symbols (Sym).Emit_Name_Len,
               Success);
         else
            Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
         end if;
         return;
      elsif Tree (Node).Kind = AST_Member_Expr then
         Sym := Find_Target_Symbol (Tokens, Tree, Node);
         if Sym /= 0 then
            Left_Node := Tree (Node).Left_Child;
            Emit_Name_Text
              (Symbols (Sym).Emit_Name,
               Symbols (Sym).Emit_Name_Len,
               Success);
            if Left_Node /= 0 and then Tree (Left_Node).Left_Child /= 0 then
               if Success then
                  Success := Emit_Raw ("[");
               end if;
               Emit_Array_Index
                 (Tokens,
                  Tree,
                  Symbols (Sym).Dims,
                  Symbols (Sym).Rank,
                  Tree (Left_Node).Left_Child,
                  Success);
               if Success then
                  Success := Emit_Raw ("]");
               end if;
            end if;
            return;
         elsif Tree (Node).Left_Child /= 0 and then Tree (Node).Right_Child /= 0 then
            Emit_Target (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (".");
            end if;
            if Tree (Tree (Node).Right_Child).Kind = AST_Var_Expr then
               Emit_Identifier
                 (Tokens,
                  Tree (Tree (Node).Right_Child).Token_Index,
                  Success);
            else
               Emit_Target (Tokens, Tree, Tree (Node).Right_Child, Success);
            end if;
            return;
         end if;
      end if;

      Emit_Expression (Tokens, Tree, Node, Kind_S64, Success);
   end Emit_Target;

   procedure Emit_Assignment_To_Target
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Target  : in Node_Index;
      RHS     : in Node_Index;
      Kind    : in DotNet_Value_Kind;
      Success : in out Boolean)
   is
   begin
      Emit_Target (Tokens, Tree, Target, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Emit_Assignment_Value (Tokens, Tree, RHS, Kind, Success);
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Assignment_To_Target;

   procedure Emit_Expression
     (Tokens   : in Token_Array;
      Tree     : in Node_Array;
      Node     : in Node_Index;
      Expected : in DotNet_Value_Kind;
      Success  : in out Boolean)
   is
      Name_Node : Node_Index;
      Args_Node : Node_Index;
      Arg_Node  : Node_Index;
      Module_Node : Node_Index;
      Member_Node : Node_Index;
      Sym       : Natural;
      Routine   : Natural;
      Import    : Natural;
   begin
      if not Success then
         return;
      end if;

      if Node = 0 then
         Emit_Default_Value (Expected, Success);
         return;
      end if;

      case Tree (Node).Kind is
         when AST_Number_Expr | AST_Hex_Expr | AST_Bin_Expr | AST_Octal_Expr =>
            Emit_Numeric_Literal
              (Tokens, Tree (Node).Token_Index, Tree (Node).Kind, Success);

         when AST_String_Expr =>
            Emit_String_Literal (Tokens, Tree (Node).Token_Index, Success);

         when AST_True =>
            Success := Emit_Raw ("true");

         when AST_False =>
            Success := Emit_Raw ("false");

         when AST_Var_Expr | AST_Const_Ref =>
            if Tree (Node).Kind = AST_Var_Expr
              and then Tree (Node).Left_Child /= 0
            then
               Sym := Find_Symbol (Tokens, Tree (Node).Token_Index);
               if Sym /= 0
                 and then Symbols (Sym).Shape in Shape_Strict_Array | Shape_Slide_Array
               then
                  Emit_Name_Text
                    (Symbols (Sym).Emit_Name,
                     Symbols (Sym).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("[");
                  end if;
                  Emit_Array_Index
                    (Tokens,
                     Tree,
                     Symbols (Sym).Dims,
                     Symbols (Sym).Rank,
                     Tree (Node).Left_Child,
                     Success);
                  if Success then
                     Success := Emit_Raw ("]");
                  end if;
               else
                  Emit_Default_Value (Expected, Success);
               end if;
            else
               Sym := Find_Symbol (Tokens, Tree (Node).Token_Index);
               if Sym /= 0 or else Tree (Node).Kind = AST_Const_Ref then
                  if Sym /= 0 then
                     Emit_Name_Text
                       (Symbols (Sym).Emit_Name,
                        Symbols (Sym).Emit_Name_Len,
                        Success);
                  else
                     Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
                  end if;
               elsif Find_Unprefixed_Const
                 (Tokens, Tree (Node).Token_Index) /= 0
               then
                  Success := Emit_Raw ("Const_");
                  Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
               elsif Token_Text_Equals (Tokens, Tree (Node).Token_Index, "SCREEN_WIDTH") or else
                 Token_Text_Equals (Tokens, Tree (Node).Token_Index, "SCREEN_HEIGHT") or else
                 Token_Text_Equals (Tokens, Tree (Node).Token_Index, "VIRTUAL_WIDTH") or else
                 Token_Text_Equals (Tokens, Tree (Node).Token_Index, "VIRTUAL_HEIGHT")
               then
                  if Token_Text_Equals (Tokens, Tree (Node).Token_Index, "SCREEN_WIDTH")
                  then
                     Success := Emit_Raw ("ALB_ScreenW");
                  elsif Token_Text_Equals (Tokens, Tree (Node).Token_Index, "VIRTUAL_WIDTH") then
                     Success := Emit_Raw ("ALB_VirtualW");
                  elsif Token_Text_Equals (Tokens, Tree (Node).Token_Index, "SCREEN_HEIGHT") then
                     Success := Emit_Raw ("ALB_ScreenH");
                  else
                     Success := Emit_Raw ("ALB_VirtualH");
                  end if;
               elsif Token_Has_Uppercase (Tokens, Tree (Node).Token_Index) then
                  Emit_Default_Value (Expected, Success);
               else
                  Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
               end if;
            end if;

         when AST_BinOp =>
            if Tree (Node).Token_Index /= 0
              and then Tokens (Tree (Node).Token_Index).Kind in TOK_DIV | TOK_MOD
            then
               declare
                  Left_Kind  : constant DotNet_Value_Kind :=
                    Infer_Expression_Kind (Tokens, Tree, Tree (Node).Left_Child);
                  Right_Kind : constant DotNet_Value_Kind :=
                    Infer_Expression_Kind (Tokens, Tree, Tree (Node).Right_Child);
                  Float_Kind : constant Boolean :=
                    Expected in Kind_F64 | Kind_F32
                      or else Left_Kind in Kind_F64 | Kind_F32
                      or else Right_Kind in Kind_F64 | Kind_F32;
                  Target_Kind : constant DotNet_Value_Kind :=
                    (if Expected in Kind_F64 | Kind_F32 then Expected
                     elsif Left_Kind in Kind_F64 | Kind_F32 then Left_Kind
                     elsif Right_Kind in Kind_F64 | Kind_F32 then Right_Kind
                     else Kind_S64);
               begin
                  if Tokens (Tree (Node).Token_Index).Kind = TOK_DIV then
                     if Float_Kind then
                        Success := Emit_Raw ("(");
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Left_Child, Target_Kind, Success);
                        if Success then
                           Success := Emit_Raw (" / ");
                        end if;
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Right_Child, Target_Kind, Success);
                        if Success then
                           Success := Emit_Raw (")");
                        end if;
                     else
                        Success := Emit_Raw ("ALB_Div(");
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
                        if Success then
                           Success := Emit_Raw (", ");
                        end if;
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
                        if Success then
                           Success := Emit_Raw (")");
                        end if;
                     end if;
                  else
                     Success := Emit_Raw ("ALB_Mod(");
                     Emit_Expression
                       (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
                     if Success then
                        Success := Emit_Raw (", ");
                     end if;
                     Emit_Expression
                       (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
                     if Success then
                        Success := Emit_Raw (")");
                     end if;
                  end if;
               end;
            else
               if Tree (Node).Token_Index /= 0
                 and then Tokens (Tree (Node).Token_Index).Kind in
                   TOK_EQUAL | TOK_NOT_EQUAL | TOK_LESS | TOK_GREATER |
                   TOK_LESS_EQUAL | TOK_GREATER_EQUAL | TOK_ASSIGN
               then
                  declare
                     Left_Kind  : constant DotNet_Value_Kind :=
                       Infer_Expression_Kind (Tokens, Tree, Tree (Node).Left_Child);
                     Right_Kind : constant DotNet_Value_Kind :=
                       Infer_Expression_Kind (Tokens, Tree, Tree (Node).Right_Child);
                     Op_Kind    : constant Token_Kind := Tokens (Tree (Node).Token_Index).Kind;
                  begin
                     if (Left_Kind = Kind_String or else Right_Kind = Kind_String)
                       and then Op_Kind in TOK_EQUAL | TOK_NOT_EQUAL | TOK_ASSIGN
                     then
                        if Op_Kind = TOK_NOT_EQUAL then
                           Success := Emit_Raw ("(!string.Equals(");
                        else
                           Success := Emit_Raw ("(string.Equals(");
                        end if;
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
                        if Success then
                           Success := Emit_Raw (", ");
                        end if;
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Right_Child, Kind_String, Success);
                        if Success then
                           Success := Emit_Raw (", StringComparison.Ordinal))");
                        end if;
                     else
                        Success := Emit_Raw ("(ALB_Num(");
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
                        if Success then
                           Success := Emit_Raw (")");
                        end if;
                        Emit_BinOp_Token (Tokens, Tree (Node).Token_Index, Success);
                        if Success then
                           Success := Emit_Raw ("ALB_Num(");
                        end if;
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
                        if Success then
                           Success := Emit_Raw ("))");
                        end if;
                     end if;
                  end;
               elsif Tree (Node).Token_Index /= 0
                 and then Tokens (Tree (Node).Token_Index).Kind = TOK_POW
               then
                  declare
                     Result_Kind : constant DotNet_Value_Kind :=
                       Infer_Expression_Kind (Tokens, Tree, Node);
                  begin
                     if Result_Kind = Kind_F64 or else Expected = Kind_F64 then
                        Success := Emit_Raw ("Math.Pow((double)(");
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Left_Child, Kind_F64, Success);
                        if Success then
                           Success := Emit_Raw ("), (double)(");
                        end if;
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Right_Child, Kind_F64, Success);
                        if Success then
                           Success := Emit_Raw ("))");
                        end if;
                     else
                        Success := Emit_Raw ("((long)Math.Pow((double)(");
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
                        if Success then
                           Success := Emit_Raw ("), (double)(");
                        end if;
                        Emit_Expression
                          (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
                        if Success then
                           Success := Emit_Raw (")))");
                        end if;
                     end if;
                  end;
               else
                  Success := Emit_Raw ("(");
                  Emit_Expression
                    (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
                  Emit_BinOp_Token (Tokens, Tree (Node).Token_Index, Success);
                  Emit_Expression
                    (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               end if;
            end if;

         when AST_Not =>
            Success := Emit_Raw ("!(");
            Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Kind_Bool, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Unary_Minus =>
            Success := Emit_Raw ("-(");
            Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Expected, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Cast_Expr =>
            if Kind_From_Type_Token
              (Tokens, Tree (Node).Token_Index, Expected) = Kind_U128
            then
               Success := Emit_Raw ("default(ALB_U128)");
            else
               Success := Emit_Raw ("(");
               Emit_CSharp_Type
                 (Kind_From_Type_Token
                    (Tokens, Tree (Node).Token_Index, Expected),
                  Success);
               if Success then
                  Success := Emit_Raw (")(");
               end if;
               Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Expected, Success);
               if Success then
                  Success := Emit_Raw (")");
               end if;
            end if;

         when AST_Constructor =>
            if Token_Text_Equals (Tokens, Tree (Node).Token_Index, "PURE") or else
              Token_Text_Equals (Tokens, Tree (Node).Token_Index, "RATIONAL")
            then
               Success := Emit_Raw ("ALB_Pure(");
               Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
               if Success then
                  Success := Emit_Raw (", ");
               end if;
               Emit_Expression
                 (Tokens,
                  Tree,
                  Next_Arg (Tree, Tree (Node).Left_Child),
                  Kind_S64,
                  Success);
               if Success then
                  Success := Emit_Raw (")");
               end if;
            elsif Token_Text_Equals (Tokens, Tree (Node).Token_Index, "U128") then
               Success := Emit_Raw ("default(ALB_U128)");
            elsif Kind_From_Type_Token
              (Tokens, Tree (Node).Token_Index, Kind_Void) /= Kind_Void
            then
               Success := Emit_Raw ("(");
               Emit_CSharp_Type
                 (Kind_From_Type_Token
                    (Tokens, Tree (Node).Token_Index, Expected),
                  Success);
               if Success then
                  Success := Emit_Raw (")(");
               end if;
               Emit_Expression
                 (Tokens, Tree, Tree (Node).Left_Child, Expected, Success);
               if Success then
                  Success := Emit_Raw (")");
               end if;
            else
               Emit_Default_Value (Expected, Success);
            end if;

         when AST_Str_Len =>
            Success := Emit_Raw ("ALB_Len(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Str_Left =>
            Success := Emit_Raw ("ALB_Left(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Str_Right =>
            Success := Emit_Raw ("ALB_Right(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Str_Mid =>
            Success := Emit_Raw ("ALB_Mid(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (", 0)");
            end if;

         when AST_Str_Concat =>
            Success := Emit_Raw ("ALB_Concat(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Choose =>
            Success := Emit_Raw ("(");
            Emit_Condition (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (" ? ");
            end if;
            if Tree (Node).Right_Child /= 0 then
               Emit_Expression
                 (Tokens,
                  Tree,
                  Tree (Tree (Node).Right_Child).Left_Child,
                  Expected,
                  Success);
            else
               Emit_Default_Value (Expected, Success);
            end if;
            if Success then
               Success := Emit_Raw (" : ");
            end if;
            if Tree (Node).Right_Child /= 0 then
               Emit_Expression
                 (Tokens,
                  Tree,
                  Tree (Tree (Node).Right_Child).Right_Child,
                  Expected,
                  Success);
            else
               Emit_Default_Value (Expected, Success);
            end if;
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Func_Call =>
            Name_Node := Tree (Node).Left_Child;
            Args_Node := Tree (Node).Right_Child;
            Arg_Node := 0;
            if Args_Node /= 0 then
               Arg_Node := Tree (Args_Node).Left_Child;
            end if;

            if Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Member_Expr then
               Routine := Find_Member_Routine (Tokens, Tree, Name_Node);
               if Routine /= 0 then
                  Emit_Routine_Name (Tokens, Tree, Routine, Success);
                  if Success then
                     Success := Emit_Raw ("(");
                  end if;
                  Emit_Arg_List_For_Routine
                    (Tokens, Tree, Args_Node, Routine, Success);
               else
                  Module_Node := Tree (Name_Node).Left_Child;
                  Member_Node := Tree (Name_Node).Right_Child;
                  Success := Emit_Raw ("ALB_");
                  if Module_Node /= 0 then
                     Emit_Token_Name_Content
                       (Tokens, Tree (Module_Node).Token_Index, Success);
                  end if;
                  if Success then
                     Success := Emit_Raw ("_");
                  end if;
                  if Member_Node /= 0 then
                     Emit_Token_Name_Content
                       (Tokens, Tree (Member_Node).Token_Index, Success);
                  end if;
                  if Success then
                     Success := Emit_Raw ("(");
                  end if;
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
               end if;
               if Success then
                  Success := Emit_Raw (")");
               end if;
               return;
            elsif Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Var_Expr then
               if Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U128") then
                  Success := Emit_Raw ("default(ALB_U128)");
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U8") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "HW8") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U16") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "HW16") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U32") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "HW32") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "U64") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "S32") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "I8") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "I16") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "I32") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "I64") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "F64") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "REAL")
               then
                  Success := Emit_Raw ("(");
                  Emit_CSharp_Type
                    (Kind_From_Type_Token
                       (Tokens, Tree (Name_Node).Token_Index, Expected),
                     Success);
                  if Success then
                     Success := Emit_Raw (")(");
                  end if;
                  Emit_Expression
                    (Tokens,
                     Tree,
                     Arg_Node,
                     Kind_From_Type_Token
                       (Tokens, Tree (Name_Node).Token_Index, Expected),
                     Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "BOOL") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "BOOLEAN")
               then
                  Success := Emit_Raw ("(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (" != 0)");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "RATIONAL")
               then
                  Success := Emit_Raw ("ALB_Pure(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Expression
                    (Tokens, Tree, Next_Arg (Tree, Arg_Node), Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "LEN") then
                  Success := Emit_Raw ("ALB_Len(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_String, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "LEFT") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "LEFT$")
               then
                  Success := Emit_Raw ("ALB_Left(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_String, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Expression
                    (Tokens, Tree, Next_Arg (Tree, Arg_Node), Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "RIGHT") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "RIGHT$")
               then
                  Success := Emit_Raw ("ALB_Right(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_String, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Expression
                    (Tokens, Tree, Next_Arg (Tree, Arg_Node), Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "MID") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "MID$")
               then
                  Success := Emit_Raw ("ALB_Mid(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_String, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Expression
                    (Tokens, Tree, Next_Arg (Tree, Arg_Node), Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Expression
                    (Tokens,
                     Tree,
                     Next_Arg (Tree, Next_Arg (Tree, Arg_Node)),
                     Kind_S64,
                     Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "CHR") then
                  Success := Emit_Raw ("ALB_Chr(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "CONCAT") then
                  Success := Emit_Raw ("ALB_Concat(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_String, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Expression
                    (Tokens, Tree, Next_Arg (Tree, Arg_Node), Kind_String, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "RND") then
                  Success := Emit_Raw ("ALB_Rnd(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "KEY") then
                  Success := Emit_Raw ("ALB_Key(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "SIN") then
                  Success := Emit_Raw ("ALB_Sin(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "COS") then
                  Success := Emit_Raw ("ALB_Cos(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "SQRT") then
                  Success := Emit_Raw ("ALB_Sqrt(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "EXP") then
                  Success := Emit_Raw ("ALB_Exp(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "COLLIDE_RECT") then
                  Success := Emit_Raw ("ALB_CollideRect(");
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE_ADD") then
                  Success := Emit_Raw ("ALB_PureAdd(");
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE_SUB") then
                  Success := Emit_Raw ("ALB_PureSub(");
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE_MUL") then
                  Success := Emit_Raw ("ALB_PureMul(");
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE_DIV") then
                  Success := Emit_Raw ("ALB_PureDiv(");
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE_POW") then
                  Success := Emit_Raw ("ALB_PurePow(");
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE_NUM") then
                  Success := Emit_Raw ("ALB_PureNum(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_Pure, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "PURE_DEN") then
                  Success := Emit_Raw ("ALB_PureDen(");
                  Emit_Expression (Tokens, Tree, Arg_Node, Kind_Pure, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "SIZEOF") or else
                 Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "OFFSETOF")
               then
                  Success := Emit_Raw ("0");
               elsif Token_Text_Equals (Tokens, Tree (Name_Node).Token_Index, "TYPEOF") then
                  if Expected = Kind_String then
                     Success := Emit_Raw ("""UNKNOWN""");
                  else
                     Success := Emit_Raw ("0");
                  end if;
               elsif Find_Import (Tokens, Tree, Tree (Name_Node).Token_Index) /= 0 then
                  Import := Find_Import (Tokens, Tree, Tree (Name_Node).Token_Index);
                  Emit_Identifier (Tokens, Tree (Name_Node).Token_Index, Success);
                  if Success then
                     Success := Emit_Raw ("(");
                  end if;
                  Emit_Import_Arg_List
                    (Tokens, Tree, Import, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Find_Visible_Routine (Tokens, Tree (Name_Node).Token_Index) /= 0 then
                  Routine := Find_Visible_Routine (Tokens, Tree (Name_Node).Token_Index);
                  Emit_Routine_Name (Tokens, Tree, Routine, Success);
                  if Success then
                     Success := Emit_Raw ("(");
                  end if;
                  Emit_Arg_List_For_Routine
                    (Tokens, Tree, Args_Node, Routine, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               elsif Find_Symbol (Tokens, Tree (Name_Node).Token_Index) /= 0 then
                  Emit_Identifier (Tokens, Tree (Name_Node).Token_Index, Success);
                  if Success then
                     Success := Emit_Raw ("(");
                  end if;
                  Emit_Arg_List (Tokens, Tree, Args_Node, Success);
                  if Success then
                     Success := Emit_Raw (")");
                  end if;
               else
                  Emit_Default_Value (Expected, Success);
               end if;
            else
               Emit_Default_Value (Expected, Success);
            end if;

         when AST_Rnd_Expr =>
            Success := Emit_Raw ("ALB_Rnd(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Key_State =>
            Success := Emit_Raw ("ALB_Key(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Mouse_X =>
            Success := Emit_Raw ("ALB_MouseX");

         when AST_VMouse_X =>
            Success := Emit_Raw ("ALB_VMouseX");

         when AST_Mouse_Y =>
            Success := Emit_Raw ("ALB_MouseY");

         when AST_Mouse_Wheel =>
            Success := Emit_Raw ("0");

         when AST_VMouse_y =>
            Success := Emit_Raw ("ALB_VMouseY");

         when AST_Mouse_Click =>
            Success := Emit_Raw ("ALB_MouseClick(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_SCREEN_WIDTH =>
            Success := Emit_Raw ("ALB_ScreenW");

         when AST_VIRTUAL_WIDTH =>
            Success := Emit_Raw ("ALB_VirtualW");

         when AST_SCREEN_HEIGHT =>
            Success := Emit_Raw ("ALB_ScreenH");

         when AST_VIRTUAL_HEIGHT =>
            Success := Emit_Raw ("ALB_VirtualH");

         when AST_File_Open =>
            Success := Emit_Raw ("ALB_Open(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_File_Len =>
            Success := Emit_Raw ("ALB_FileLen(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_File_Seek =>
            Success := Emit_Raw ("ALB_Seek(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_U64, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_U64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_File_Read =>
            if Expected = Kind_String then
               Success := Emit_Raw ("ALB_ReadText(");
            else
               Success := Emit_Raw ("ALB_Read(");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_U64, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Peek_Expr =>
            Success := Emit_Raw ("ALB_Peek(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Deref_Expr =>
            Success := Emit_Raw ("ALB_Deref(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_SizeOf_Expr | AST_OffsetOf_Expr =>
            Success := Emit_Raw ("0");

         when AST_TypeOf_Expr =>
            if Expected = Kind_String then
               Success := Emit_Raw ("""UNKNOWN""");
            else
               Success := Emit_Raw ("0");
            end if;

         when AST_READ_PIXEL =>
            Arg_Node := First_Arg (Tree, Tree (Node).Left_Child);
            Success := Emit_Raw ("ALB_ReadPixel(");
            Emit_Expression (Tokens, Tree, Arg_Node, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Next_Arg (Tree, Arg_Node), Kind_S64, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;

         when AST_Find_Query | AST_Query | AST_Knows_Query =>
            if Tree (Node).Kind = AST_Find_Query
              and then Tree (Node).Token_Index /= 0
              and then Token_Text_Equals (Tokens, Tree (Node).Token_Index, "FIND")
            then
               Success := Emit_Raw ("ALB_RelFind1(");
               if Tree (Node).Left_Child /= 0 then
                  Emit_Predicate_Id (Tokens, Tree, Tree (Node).Left_Child, Success);
               else
                  Success := Emit_Raw ("0");
               end if;
               if Success then
                  Success := Emit_Raw (")");
               end if;
            else
               if Expected = Kind_Bool then
                  Success := Emit_Raw ("ALB_Bool(ALB_RelHas(");
               else
                  Success := Emit_Raw ("ALB_RelHas(");
               end if;
               if Tree (Node).Left_Child /= 0 then
                  Emit_Predicate_Id (Tokens, Tree, Tree (Node).Left_Child, Success);
               else
                  Emit_Predicate_Id (Tokens, Tree, Node, Success);
               end if;
               if Success then
                  Success := Emit_Raw (", ");
               end if;
               if Tree (Node).Left_Child /= 0 then
                  Emit_Predicate_Arity (Tree, Tree (Node).Left_Child, Success);
               else
                  Emit_Predicate_Arity (Tree, Node, Success);
               end if;
               if Success then
                  Success := Emit_Raw (", ");
               end if;
               if Tree (Node).Left_Child /= 0 then
                  Emit_Predicate_Arg1 (Tokens, Tree, Tree (Node).Left_Child, Success);
               else
                  Emit_Predicate_Arg1 (Tokens, Tree, Node, Success);
               end if;
               if Success then
                  if Expected = Kind_Bool then
                     Success := Emit_Raw ("))");
                  else
                     Success := Emit_Raw (")");
                  end if;
               end if;
            end if;

         when AST_Inline_Typescript_Expr | AST_Inline_CSharp_Expr =>
            Emit_Raw_Block_Body (Tokens, Tree (Node).Token_Index, Success);

         when AST_Member_Expr =>
            Sym := Find_Target_Symbol (Tokens, Tree, Node);
            if Sym /= 0 then
               Emit_Target (Tokens, Tree, Node, Success);
            else
               Emit_Default_Value (Expected, Success);
            end if;

         when AST_Temporal_Ref =>
            Sym := Find_Target_Symbol (Tokens, Tree, Tree (Node).Left_Child);
            if Sym = 0 then
               Emit_Default_Value (Expected, Success);
            elsif Tree (Node).Token_Index /= 0
              and then Tokens (Tree (Node).Token_Index).Kind = Tok_Past
            then
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history[((");
               end if;
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_head + ");
               end if;
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history.Length - 1) % ");
               end if;
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history.Length)]");
               end if;
            elsif Tree (Node).Token_Index /= 0
              and then Tokens (Tree (Node).Token_Index).Kind = Tok_Future
            then
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history[((");
               end if;
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_head + 1) % ");
               end if;
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history.Length)]");
               end if;
            elsif Tree (Node).Token_Index /= 0
              and then Tokens (Tree (Node).Token_Index).Kind = Tok_Timeline
            then
               Success := Emit_Raw ("unchecked((ulong)(ALB_TimelineAddressBase + ");
               Emit_Natural (Sym, Success);
               if Success then
                  Success := Emit_Raw ("L * ALB_TimelineAddressStride))");
               end if;
            else
               Emit_Name_Text
                 (Symbols (Sym).Emit_Name,
                  Symbols (Sym).Emit_Name_Len,
                  Success);
            end if;

         when AST_Array_Access | AST_Simd_Intrinsic =>
            Emit_Expression_Fallback
              (Tokens,
               Tree,
               Node,
               Expected,
               Emitter_Unsupported_Expression_Node,
               "unsupported array or SIMD expression fallback emitted",
               Success);

         when others =>
            Emit_Expression_Fallback
              (Tokens,
               Tree,
               Node,
               Expected,
               Emitter_Unsupported_Expression_Node,
               "unsupported expression fallback emitted",
               Success);
      end case;
   end Emit_Expression;

   procedure Emit_Markov_Model_Fields
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Success : in out Boolean)
   is
      procedure Emit_Model_Field_Name
        (Model_Index : in Natural;
         Success     : in out Boolean) is
      begin
         Success := Emit_Raw ("ALB_MARKOV_");
         if Success then
            Success :=
              Emit_Raw
                (Buffer_Text
                   (Markov_Models (Model_Index).Name,
                    Markov_Models (Model_Index).Name_Len));
         end if;
      end Emit_Model_Field_Name;

      function Find_Setting
        (Decl_Node : in Node_Index;
         Kind      : in Node_Kind) return Node_Index
      is
         Curr : Node_Index := Tree (Decl_Node).Right_Child;
      begin
         while Curr /= 0 loop
            if Tree (Curr).Kind = Kind then
               return Curr;
            end if;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
         return 0;
      end Find_Setting;

      procedure Emit_Row_Values
        (Row_Node : in Node_Index;
         Success  : in out Boolean)
      is
         Curr  : Node_Index := Tree (Row_Node).Left_Child;
         First : Boolean := True;
      begin
         while Curr /= 0 loop
            if not First then
               Success := Emit_Raw (", ");
            end if;
            if Success then
               Success := Emit_Raw (Token_Text_Copy (Tokens, Tree (Curr).Token_Index));
            end if;
            First := False;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Row_Values;

      Model_Node  : Node_Index;
      States_Node : Node_Index;
      Matrix_Node : Node_Index;
      Row_Node    : Node_Index;
      First_Value : Boolean;
   begin
      for I in 1 .. Markov_Model_Count loop
         exit when not Success;
         if not Markov_Models (I).Active then
            goto Continue_Model;
         end if;

         Model_Node := Markov_Models (I).Node;
         States_Node := Find_Setting (Model_Node, AST_Markov_States);
         Matrix_Node := Find_Setting (Model_Node, AST_Markov_Transition_Matrix);

         Success := Emit_Raw ("private static readonly ulong ");
         Emit_Model_Field_Name (I, Success);
         if Success then
            Success := Emit_Raw ("_STATES = (ulong)(");
         end if;
         if States_Node /= 0 then
            Emit_Expression (Tokens, Tree, Tree (States_Node).Left_Child, Kind_S64, Success);
         else
            Success := Emit_Raw ("0");
         end if;
         if Success then
            Success := Emit_Raw (");");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;

         Success := Emit_Raw ("private static readonly double[] ");
         Emit_Model_Field_Name (I, Success);
         if Success then
            Success := Emit_Raw (" = new double[] { ");
         end if;

         First_Value := True;
         if Matrix_Node /= 0 then
            Row_Node := Tree (Matrix_Node).Left_Child;
            while Row_Node /= 0 loop
               if not First_Value then
                  Success := Emit_Raw (", ");
               end if;
               Emit_Row_Values (Row_Node, Success);
               First_Value := False;
               Row_Node := Tree (Row_Node).Next_Sibling;
            end loop;
         end if;

         if Success then
            Success := Emit_Raw (" };");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;

         <<Continue_Model>>
         null;
      end loop;
   end Emit_Markov_Model_Fields;

   procedure Emit_Neural_Model_Fields
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Success : in out Boolean)
   is
      function Activation_Code (Node : in Node_Index) return Natural is
      begin
         if Node = 0 then
            return 0;
         elsif Token_Text_Equals (Tokens, Tree (Node).Token_Index, "RELU") then
            return 1;
         elsif Token_Text_Equals (Tokens, Tree (Node).Token_Index, "SIGMOID") then
            return 2;
         elsif Token_Text_Equals (Tokens, Tree (Node).Token_Index, "TANH") then
            return 3;
         else
            return 0;
         end if;
      end Activation_Code;

      procedure Emit_Model_Field_Name
        (Model_Index : in Natural;
         Success     : in out Boolean) is
      begin
         Success := Emit_Raw ("ALB_NN_");
         if Success then
            Success :=
              Emit_Raw
                (Buffer_Text
                   (Neural_Models (Model_Index).Name,
                    Neural_Models (Model_Index).Name_Len));
         end if;
      end Emit_Model_Field_Name;

      Layer_Node : Node_Index;
      First      : Boolean;
   begin
      for I in 1 .. Neural_Model_Count loop
         exit when not Success;
         if not Neural_Models (I).Active then
            goto Continue_Model;
         end if;

         Success := Emit_Raw ("private static readonly ALB_NN_Model ");
         Emit_Model_Field_Name (I, Success);
         if Success then
            Success := Emit_Raw (" = ALB_NN_CREATE(new int[] { ");
         end if;

         First := True;
         Layer_Node := Tree (Neural_Models (I).Node).Right_Child;
         while Layer_Node /= 0 loop
            if not First then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression (Tokens, Tree, Tree (Layer_Node).Left_Child, Kind_S64, Success);
            First := False;
            Layer_Node := Tree (Layer_Node).Next_Sibling;
         end loop;

         if Success then
            Success := Emit_Raw (" }, new int[] { ");
         end if;

         First := True;
         Layer_Node := Tree (Neural_Models (I).Node).Right_Child;
         while Layer_Node /= 0 loop
            if not First then
               Success := Emit_Raw (", ");
            end if;
            Emit_Natural (Activation_Code (Tree (Layer_Node).Right_Child), Success);
            First := False;
            Layer_Node := Tree (Layer_Node).Next_Sibling;
         end loop;

         if Success then
            Success := Emit_Raw (" });");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;

         <<Continue_Model>>
         null;
      end loop;
   end Emit_Neural_Model_Fields;

   procedure Emit_Global_Fields
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Success : in out Boolean)
   is
   begin
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active then
            case Symbols (I).Shape is
               when Shape_Const =>
                  Success := Emit_Raw ("public const ");
                  Emit_CSharp_Type (Symbols (I).Kind, Success);
                  if Success then
                     Success := Emit_Raw (" ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw (" = ");
                  end if;
                  Emit_Expression
                    (Tokens,
                     Tree,
                     Symbols (I).Init_Node,
                     Symbols (I).Kind,
                     Success);
                  if Success then
                     Success := Emit_Raw (";");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;

               when Shape_Scalar =>
                  Success := Emit_Raw ("public static ");
                  Emit_CSharp_Type (Symbols (I).Kind, Success);
                  if Success then
                     Success := Emit_Raw (" ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw (";");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;

               when Shape_Strict_Array | Shape_Slide_Array | Shape_Parallel_Field =>
                  Success := Emit_Raw ("public static ");
                  Emit_CSharp_Type (Symbols (I).Kind, Success);
                  if Success then
                     Success := Emit_Raw ("[] ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw (" = new ");
                  end if;
                  Emit_CSharp_Type (Symbols (I).Kind, Success);
                  if Success then
                     Success := Emit_Raw ("[(int)(");
                  end if;
                  Emit_Array_Length
                    (Tokens,
                     Tree,
                     Symbols (I).Dims,
                     Symbols (I).Rank,
                     Success);
                  if Success then
                     Success := Emit_Raw (")];");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;

                  if Symbols (I).Shape = Shape_Slide_Array then
                     Success := Emit_Raw ("public static long ");
                     Emit_Name_Text
                       (Symbols (I).Emit_Name,
                        Symbols (I).Emit_Name_Len,
                        Success);
                     if Success then
                        Success := Emit_Raw ("_active = ");
                     end if;
                     if Symbols (I).Active_Node /= 0 then
                        Emit_Expression
                          (Tokens,
                           Tree,
                           Symbols (I).Active_Node,
                           Kind_S64,
                           Success);
                     else
                        Emit_Array_Length
                          (Tokens,
                           Tree,
                           Symbols (I).Dims,
                           Symbols (I).Rank,
                           Success);
                     end if;
                     if Success then
                        Success := Emit_Raw (";");
                     end if;
                     if Success then
                        Success := Emit_Raw (ASCII.LF & "");
                     end if;
                  end if;

               when Shape_Temporal =>
                  Success := Emit_Raw ("public static ");
                  Emit_CSharp_Type (Symbols (I).Kind, Success);
                  if Success then
                     Success := Emit_Raw (" ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw (" = ");
                  end if;
                  if Symbols (I).Init_Node /= 0 then
                     Emit_Assignment_Value
                       (Tokens, Tree, Symbols (I).Init_Node, Symbols (I).Kind, Success);
                  else
                     Emit_Default_Value (Symbols (I).Kind, Success);
                  end if;
                  if Success then
                     Success := Emit_Raw (";");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;

                  Success := Emit_Raw ("public static ");
                  Emit_CSharp_Type (Symbols (I).Kind, Success);
                  if Success then
                     Success := Emit_Raw ("[] ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_history = ALB_CreateFilledArray<");
                  end if;
                  Emit_CSharp_Type (Symbols (I).Kind, Success);
                  if Success then
                     Success := Emit_Raw (">((int)(");
                  end if;
                  if Symbols (I).History_Node /= 0 then
                     Emit_Expression
                       (Tokens, Tree, Symbols (I).History_Node, Kind_S64, Success);
                  else
                     Success := Emit_Raw ("1");
                  end if;
                  if Success then
                     Success := Emit_Raw ("), ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw (");");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;

                  Success := Emit_Raw ("public static int ");
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_head;");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
            end case;
         end if;
      end loop;

      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      Emit_Markov_Model_Fields (Tokens, Tree, Success);
      if Success and then Markov_Model_Count > 0 then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      Emit_Neural_Model_Fields (Tokens, Tree, Success);
      if Success and then Neural_Model_Count > 0 then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Global_Fields;

   procedure Emit_User_State_Support
     (Success : in out Boolean)
   is
   begin
      Emit_Line ("private struct ALB_UserStateSnapshot", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then Symbols (I).Shape in Shape_Scalar | Shape_Temporal
         then
            Success := Emit_Raw ("public ");
            Emit_CSharp_Type (Symbols (I).Kind, Success);
            if Success then
               Success := Emit_Raw (" ");
            end if;
            Emit_Name_Text
              (Symbols (I).Emit_Name,
               Symbols (I).Emit_Name_Len,
               Success);

            if Success then
               Success := Emit_Raw (";");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;
         end if;
      end loop;
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static ALB_UserStateSnapshot ALB_SavedUserState;", Success);
      Emit_Line ("", Success);

      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active then
            if Symbols (I).Shape in Shape_Strict_Array | Shape_Slide_Array | Shape_Parallel_Field then
               Success := Emit_Raw ("private static readonly ");
               Emit_CSharp_Type (Symbols (I).Kind, Success);
               if Success then
                  Success := Emit_Raw ("[] ALB_Saved_");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (" = new ");
               end if;
               Emit_CSharp_Type (Symbols (I).Kind, Success);
               if Success then
                  Success := Emit_Raw ("[");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (".Length];");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
               if Symbols (I).Shape = Shape_Slide_Array then
                  Success := Emit_Raw ("private static long ALB_Saved_");
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_active;");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               end if;
            elsif Symbols (I).Shape = Shape_Temporal then
               Success := Emit_Raw ("private static readonly ");
               Emit_CSharp_Type (Symbols (I).Kind, Success);
               if Success then
                  Success := Emit_Raw ("[] ALB_Saved_");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history = new ");
               end if;
               Emit_CSharp_Type (Symbols (I).Kind, Success);
               if Success then
                  Success := Emit_Raw ("[");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history.Length];");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
               Success := Emit_Raw ("private static int ALB_Saved_");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_head;");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            end if;
         end if;
      end loop;
      Emit_Line ("", Success);

      Emit_Line ("private static void ALB_CaptureUserState()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active then
            if Symbols (I).Shape in Shape_Scalar | Shape_Temporal then
               Success := Emit_Raw ("ALB_SavedUserState.");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (" = ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (";");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            end if;

            if Symbols (I).Shape in Shape_Strict_Array | Shape_Slide_Array | Shape_Parallel_Field then
               Success := Emit_Raw ("Array.Copy(");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (", ALB_Saved_");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (", ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (".Length);");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
               if Symbols (I).Shape = Shape_Slide_Array then
                  Success := Emit_Raw ("ALB_Saved_");
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_active = ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_active;");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               end if;
            elsif Symbols (I).Shape = Shape_Temporal then
               Success := Emit_Raw ("Array.Copy(");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history, ALB_Saved_");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history, ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history.Length);");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
               Success := Emit_Raw ("ALB_Saved_");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_head = ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_head;");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            end if;
         end if;
      end loop;
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("private static void ALB_RestoreUserState()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active then
            if Symbols (I).Shape in Shape_Scalar | Shape_Temporal then
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (" = ALB_SavedUserState.");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (";");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            end if;

            if Symbols (I).Shape in Shape_Strict_Array | Shape_Slide_Array | Shape_Parallel_Field then
               Success := Emit_Raw ("Array.Copy(ALB_Saved_");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (", ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (", ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw (".Length);");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
               if Symbols (I).Shape = Shape_Slide_Array then
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_active = ALB_Saved_");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_active;");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               end if;
            elsif Symbols (I).Shape = Shape_Temporal then
               Success := Emit_Raw ("Array.Copy(ALB_Saved_");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history, ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history, ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_history.Length);");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_head = ALB_Saved_");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("_head;");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            end if;
         end if;
      end loop;
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);
   end Emit_User_State_Support;

   procedure Emit_Param_List
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      List    : in Node_Index;
      Success : in out Boolean)
   is
      Curr       : Node_Index := 0;
      Name_Node  : Node_Index;
      Type_Node  : Node_Index;
      First      : Boolean := True;
      Param_Kind : DotNet_Value_Kind;
   begin
      if List /= 0 then
         Curr := Tree (List).Left_Child;
      end if;

      while Curr /= 0 loop
         if not First then
            Success := Emit_Raw (", ");
         end if;

         if Success
           and then Tree (Curr).Token_Index /= 0
           and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Out
         then
            Success := Emit_Raw ("ref ");
         end if;

         Name_Node := Tree (Curr).Left_Child;
         Type_Node := Tree (Curr).Right_Child;
         Param_Kind := Kind_S64;
         if Type_Node /= 0 then
            Param_Kind :=
              Kind_From_Type_Token
                (Tokens, Tree (Type_Node).Token_Index, Kind_S64);
         end if;

         Emit_CSharp_Type (Param_Kind, Success);
         if Success then
            Success := Emit_Raw (" ");
         end if;
         if Name_Node /= 0 then
            Emit_Identifier (Tokens, Tree (Name_Node).Token_Index, Success);
         else
            Success := Emit_Raw ("arg");
         end if;

         First := False;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Param_List;

   procedure Emit_Import_Param_List
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      List    : in Node_Index;
      Success : in out Boolean)
   is
      Curr      : Node_Index := 0;
      Name_Node : Node_Index;
      Type_Node : Node_Index;
      First     : Boolean := True;
   begin
      if List /= 0 then
         Curr := Tree (List).Left_Child;
      end if;

      while Curr /= 0 loop
         if not First then
            Success := Emit_Raw (", ");
         end if;

         if Success
           and then Tree (Curr).Token_Index /= 0
           and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Out
         then
            Success := Emit_Raw ("ref ");
         end if;

         Name_Node := Tree (Curr).Left_Child;
         Type_Node := Tree (Curr).Right_Child;
         Emit_Foreign_CSharp_Type
           (Tokens,
            (if Type_Node /= 0 then Tree (Type_Node).Token_Index else 0),
            Success);
         if Success then
            Success := Emit_Raw (" ");
         end if;
         if Name_Node /= 0 then
            Emit_Identifier (Tokens, Tree (Name_Node).Token_Index, Success);
         else
            Success := Emit_Raw ("arg");
         end if;

         First := False;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Import_Param_List;

   function Import_Param_Type_Token
     (Tokens        : in Token_Array;
      Tree          : in Node_Array;
      Import_Index  : in Natural;
      Ordinal       : in Natural) return Natural
   is
      Decl_Node : Node_Index;
      Name_Node : Node_Index;
      List_Node : Node_Index;
      Curr      : Node_Index := 0;
      Position  : Natural := 0;
   begin
      if Import_Index = 0 or else Import_Index > Import_Count then
         return 0;
      end if;
      Decl_Node := Tree (Imports (Import_Index).Node).Left_Child;
      if Decl_Node = 0 then
         return 0;
      end if;
      Name_Node := Tree (Decl_Node).Left_Child;
      if Name_Node = 0 then
         return 0;
      end if;
      List_Node := Tree (Name_Node).Right_Child;
      if List_Node /= 0 then
         Curr := Tree (List_Node).Left_Child;
      end if;
      while Curr /= 0 loop
         Position := Position + 1;
         if Position = Ordinal then
            declare
               Type_Node : constant Node_Index := Tree (Curr).Right_Child;
            begin
               return (if Type_Node /= 0 then Tree (Type_Node).Token_Index else 0);
            end;
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
      return 0;
   end Import_Param_Type_Token;

   procedure Emit_Import_Arg_List
     (Tokens        : in Token_Array;
      Tree          : in Node_Array;
      Import_Index  : in Natural;
      List          : in Node_Index;
      Success       : in out Boolean)
   is
      Curr       : Node_Index := 0;
      First      : Boolean := True;
      Ordinal    : Natural := 0;
      Type_Token : Natural;
      Narrow     : Boolean;
   begin
      if List /= 0 then
         Curr := Tree (List).Left_Child;
      end if;
      while Curr /= 0 loop
         if not First then
            Success := Emit_Raw (", ");
         end if;
         Ordinal := Ordinal + 1;
         Type_Token := Import_Param_Type_Token (Tokens, Tree, Import_Index, Ordinal);
         Narrow :=
           Token_Text_Equals (Tokens, Type_Token, "S32") or else
           Token_Text_Equals (Tokens, Type_Token, "I32") or else
           Token_Text_Equals (Tokens, Type_Token, "HW32") or else
           Token_Text_Equals (Tokens, Type_Token, "I8") or else
           Token_Text_Equals (Tokens, Type_Token, "HW8") or else
           Token_Text_Equals (Tokens, Type_Token, "I16") or else
           Token_Text_Equals (Tokens, Type_Token, "HW16") or else
           Token_Text_Equals (Tokens, Type_Token, "U8") or else
           Token_Text_Equals (Tokens, Type_Token, "U16") or else
           Token_Text_Equals (Tokens, Type_Token, "U32");
         if Narrow then
            Success := Emit_Raw ("(");
            Emit_Foreign_CSharp_Type (Tokens, Type_Token, Success);
            if Success then
               Success := Emit_Raw (")(");
            end if;
            Emit_Expression
              (Tokens,
               Tree,
               Curr,
               Kind_From_Type_Token (Tokens, Type_Token, Kind_S64),
               Success);
            if Success then
               Success := Emit_Raw (")");
            end if;
         else
            Emit_Expression
              (Tokens,
               Tree,
               Curr,
               Kind_From_Type_Token (Tokens, Type_Token, Kind_S64),
               Success);
         end if;
         First := False;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Import_Arg_List;

   procedure Register_Routine_Params
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      List    : in Node_Index)
   is
      Curr       : Node_Index := 0;
      Name_Node  : Node_Index := 0;
      Type_Node  : Node_Index := 0;
      Param_Kind : DotNet_Value_Kind := Kind_S64;
   begin
      if Active_Routine_Node = 0 or else List = 0 then
         return;
      end if;

      Curr := Tree (List).Left_Child;
      while Curr /= 0 loop
         Name_Node := Tree (Curr).Left_Child;
         Type_Node := Tree (Curr).Right_Child;
         Param_Kind := Kind_S64;
         if Type_Node /= 0 then
            Param_Kind :=
              Kind_From_Type_Token
                (Tokens, Tree (Type_Node).Token_Index, Kind_S64);
         end if;

         if Name_Node /= 0 then
            Register_Local_Symbol
              (Tokens,
               Tree (Name_Node).Token_Index,
               (if Type_Node /= 0 then Tree (Type_Node).Token_Index else 0),
               Param_Kind,
               0);
         end if;

         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Register_Routine_Params;

   procedure Emit_Local_Declaration
     (Tokens      : in Token_Array;
      Tree        : in Node_Array;
      Name_Token  : in Natural;
      Kind        : in DotNet_Value_Kind;
      RHS         : in Node_Index;
      Success     : in out Boolean)
   is
   begin
      Emit_CSharp_Type (Kind, Success);
      if Success then
         Success := Emit_Raw (" ");
      end if;
      Emit_Identifier (Tokens, Name_Token, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Emit_Assignment_Value (Tokens, Tree, RHS, Kind, Success);
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Local_Declaration;

   procedure Emit_Import_C
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Decl_Node : Node_Index;
      Name_Node : Node_Index;
      Args_Node : Node_Index;
   begin
      if Node = 0 or else Tree (Node).Kind not in AST_Import_C | AST_Import_DLL then
         return;
      end if;

      Decl_Node := Tree (Node).Left_Child;
      if Decl_Node = 0 then
         return;
      end if;

      Name_Node := Tree (Decl_Node).Left_Child;
      Args_Node := 0;
      if Name_Node /= 0 then
         Args_Node := Tree (Name_Node).Right_Child;
      end if;

      Success := Emit_Raw ("[DllImport(");
      Emit_String_Literal (Tokens, Tree (Tree (Node).Right_Child).Token_Index, Success);
      if Success then
         Success := Emit_Raw (", EntryPoint = ");
      end if;
      if Name_Node /= 0 then
         Emit_String_Literal (Tokens, Tree (Name_Node).Token_Index, Success);
      else
         Success := Emit_Raw ("""alb_native""");
      end if;
      if Success then
         Success := Emit_Raw (", CallingConvention = CallingConvention.Cdecl)]");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      Success := Emit_Raw ("public static extern ");
      if Tree (Decl_Node).Kind = AST_Function_Decl then
         Emit_Foreign_CSharp_Type
           (Tokens, Tree (Decl_Node).Token_Index, Success);
      else
         Emit_CSharp_Type (Kind_Void, Success);
      end if;
      if Success then
         Success := Emit_Raw (" ");
      end if;
      if Name_Node /= 0 then
         Emit_Identifier (Tokens, Tree (Name_Node).Token_Index, Success);
      else
         Success := Emit_Raw ("alb_native");
      end if;
      if Success then
         Success := Emit_Raw ("(");
      end if;
      Emit_Import_Param_List (Tokens, Tree, Args_Node, Success);
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & ASCII.LF & "");
      end if;
   end Emit_Import_C;

   procedure Emit_Runtime_Types (Success : in out Boolean) is
      procedure Emit_Timeline_Address_Dispatch
        (Write_Mode : in Boolean;
         Success    : in out Boolean)
      is
         Elem_Bytes : Natural;
      begin
         Emit_Line
           ("long alb_timeline_slot = (address - ALB_TimelineAddressBase) / ALB_TimelineAddressStride;",
            Success);
         Emit_Line
           ("long alb_timeline_offset = address - ALB_TimelineAddressBase - (alb_timeline_slot * ALB_TimelineAddressStride);",
            Success);
         Emit_Line ("switch (alb_timeline_slot)", Success);
         Emit_Line ("{", Success);
         Increase_Indent;

         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active and then Symbols (I).Shape = Shape_Temporal then
               Elem_Bytes := Kind_Storage_Bytes (Symbols (I).Kind);
               Emit_Line ("case" & Natural'Image (I) & ":", Success);
               Increase_Indent;
               Success := Emit_Raw
                 ("if (alb_timeline_offset >= 0 && alb_timeline_offset < ((long)");
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw
                    ("_history.Length) *" & Natural'Image (Elem_Bytes) &
                     "L && (alb_timeline_offset %" &
                     Natural'Image (Elem_Bytes) & "L) == 0)");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
               Emit_Line ("{", Success);
               Increase_Indent;

               if Write_Mode then
                  case Symbols (I).Kind is
                     when Kind_S64 =>
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) & "L)] = value;");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                        Emit_Line ("return;", Success);
                     when Kind_U64 =>
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) &
                              "L)] = unchecked((ulong)value);");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                        Emit_Line ("return;", Success);
                     when Kind_U32 =>
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) &
                              "L)] = unchecked((uint)value);");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                        Emit_Line ("return;", Success);
                     when Kind_U16 =>
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) &
                              "L)] = unchecked((ushort)value);");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                        Emit_Line ("return;", Success);
                     when Kind_U8 =>
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) &
                              "L)] = unchecked((byte)value);");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                        Emit_Line ("return;", Success);
                     when Kind_Bool =>
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) &
                              "L)] = value != 0;");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                        Emit_Line ("return;", Success);
                     when Kind_F64 =>
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) &
                              "L)] = (double)value;");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                        Emit_Line ("return;", Success);
                     when others =>
                        Emit_Line ("return;", Success);
                  end case;
               else
                  case Symbols (I).Kind is
                     when Kind_S64 =>
                        Success := Emit_Raw ("return ");
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) & "L)];");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                     when Kind_U64 =>
                        Success := Emit_Raw ("return unchecked((long)");
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) & "L)]);");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                     when Kind_U32 | Kind_U16 | Kind_U8 =>
                        Success := Emit_Raw ("return unchecked((long)");
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) & "L)]);");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                     when Kind_Bool =>
                        Success := Emit_Raw ("return ");
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) &
                              "L)] ? 1L : 0L;");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                     when Kind_F64 =>
                        Success := Emit_Raw ("return unchecked((long)");
                        Emit_Name_Text
                          (Symbols (I).Emit_Name,
                           Symbols (I).Emit_Name_Len,
                           Success);
                        if Success then
                           Success := Emit_Raw
                             ("_history[(int)(alb_timeline_offset /" &
                              Natural'Image (Elem_Bytes) & "L)]);");
                        end if;
                        if Success then
                           Success := Emit_Raw (ASCII.LF & "");
                        end if;
                     when others =>
                        Emit_Line ("return 0;", Success);
                  end case;
               end if;

               Decrease_Indent;
               Emit_Line ("}", Success);
               if Write_Mode then
                  Emit_Line ("return;", Success);
               else
                  Emit_Line ("return 0;", Success);
               end if;
               Decrease_Indent;
            end if;
         end loop;

         Emit_Line ("default:", Success);
         Increase_Indent;
         if Write_Mode then
            Emit_Line ("return;", Success);
         else
            Emit_Line ("return 0;", Success);
         end if;
         Decrease_Indent;
         Decrease_Indent;
         Emit_Line ("}", Success);
      end Emit_Timeline_Address_Dispatch;
   begin
      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct Pure128", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public long Numerator;", Success);
      Emit_Line ("public long Denominator;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct ALB_U128", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public ulong Low;", Success);
      Emit_Line ("public ulong High;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct F32x2", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public float X;", Success);
      Emit_Line ("public float Y;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct F32x4", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public float X;", Success);
      Emit_Line ("public float Y;", Success);
      Emit_Line ("public float Z;", Success);
      Emit_Line ("public float W;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct Mat2x2", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public float M11;", Success);
      Emit_Line ("public float M12;", Success);
      Emit_Line ("public float M21;", Success);
      Emit_Line ("public float M22;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct Mat3x3", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public float M11;", Success);
      Emit_Line ("public float M12;", Success);
      Emit_Line ("public float M13;", Success);
      Emit_Line ("public float M21;", Success);
      Emit_Line ("public float M22;", Success);
      Emit_Line ("public float M23;", Success);
      Emit_Line ("public float M31;", Success);
      Emit_Line ("public float M32;", Success);
      Emit_Line ("public float M33;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct Mat4x4", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public float M11;", Success);
      Emit_Line ("public float M12;", Success);
      Emit_Line ("public float M13;", Success);
      Emit_Line ("public float M14;", Success);
      Emit_Line ("public float M21;", Success);
      Emit_Line ("public float M22;", Success);
      Emit_Line ("public float M23;", Success);
      Emit_Line ("public float M24;", Success);
      Emit_Line ("public float M31;", Success);
      Emit_Line ("public float M32;", Success);
      Emit_Line ("public float M33;", Success);
      Emit_Line ("public float M34;", Success);
      Emit_Line ("public float M41;", Success);
      Emit_Line ("public float M42;", Success);
      Emit_Line ("public float M43;", Success);
      Emit_Line ("public float M44;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct SDL_FRect", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public float X;", Success);
      Emit_Line ("public float Y;", Success);
      Emit_Line ("public float W;", Success);
      Emit_Line ("public float H;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct SDL_Rect", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public int X;", Success);
      Emit_Line ("public int Y;", Success);
      Emit_Line ("public int W;", Success);
      Emit_Line ("public int H;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential, Size = 256)]", Success);
      Emit_Line ("public struct SDL_Event", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public uint Type;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct SDL_Surface", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public uint Flags;", Success);
      Emit_Line ("public uint Format;", Success);
      Emit_Line ("public int W;", Success);
      Emit_Line ("public int H;", Success);
      Emit_Line ("public int Pitch;", Success);
      Emit_Line ("public IntPtr Pixels;", Success);
      Emit_Line ("public int RefCount;", Success);
      Emit_Line ("public IntPtr Reserved;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("[StructLayout(LayoutKind.Sequential)]", Success);
      Emit_Line ("public struct SDL_AudioSpec", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public ushort Format;", Success);
      Emit_Line ("public int Channels;", Success);
      Emit_Line ("public int Freq;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("private const uint SDL_INIT_AUDIO = 0x00000010U;", Success);
      Emit_Line ("private const uint SDL_INIT_VIDEO = 0x00000020U;", Success);
      Emit_Line ("private const uint SDL_EVENT_QUIT = 0x100U;", Success);
      Emit_Line ("private const ulong SDL_WINDOW_FULLSCREEN = 0x0000000000000001UL;", Success);
      Emit_Line ("private const ulong SDL_WINDOW_RESIZABLE = 0x0000000000000020UL;", Success);
      Emit_Line ("private const uint SDL_BLENDMODE_BLEND = 0x00000001U;", Success);
      Emit_Line ("private const ushort SDL_AUDIO_S16 = 0x8010;", Success);
      Emit_Line ("private const uint SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK = 0xFFFFFFFFU;", Success);
      Emit_Line ("", Success);

      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_Init(uint flags);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern void SDL_Quit();", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_CreateWindowAndRenderer(string title, int width, int height, ulong flags, out IntPtr window, out IntPtr renderer);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr SDL_CreateRenderer(IntPtr window, string name);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_SetWindowFullscreen(IntPtr window, [MarshalAs(UnmanagedType.I1)] bool fullscreen);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_SetWindowResizable(IntPtr window, [MarshalAs(UnmanagedType.I1)] bool resizable);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_SetWindowSize(IntPtr window, int width, int height);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_GetCurrentRenderOutputSize(IntPtr renderer, out int width, out int height);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_PollEvent(out SDL_Event ev);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr SDL_GetKeyboardState(out int numkeys);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern uint SDL_GetMouseState(out float x, out float y);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern ulong SDL_GetTicks();", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern void SDL_Delay(uint ms);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_SetRenderDrawColor(IntPtr renderer, byte r, byte g, byte b, byte a);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_SetRenderDrawBlendMode(IntPtr renderer, uint blendMode);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_RenderClear(IntPtr renderer);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_RenderPresent(IntPtr renderer);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_RenderPoint(IntPtr renderer, float x, float y);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_RenderLine(IntPtr renderer, float x1, float y1, float x2, float y2);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_RenderRect(IntPtr renderer, ref SDL_FRect rect);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_RenderFillRect(IntPtr renderer, ref SDL_FRect rect);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_RenderDebugText(IntPtr renderer, float x, float y, string text);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_SetRenderClipRect(IntPtr renderer, ref SDL_Rect rect);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl, EntryPoint = ""SDL_SetRenderClipRect"")] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_SetRenderClipRectNull(IntPtr renderer, IntPtr rect);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr SDL_RenderReadPixels(IntPtr renderer, ref SDL_Rect rect);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern void SDL_DestroySurface(IntPtr surface);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_LoadWAV(string path, out SDL_AudioSpec spec, out IntPtr audioBuf, out uint audioLen);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr SDL_OpenAudioDeviceStream(uint devid, ref SDL_AudioSpec spec, IntPtr callback, IntPtr userdata);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_PutAudioStreamData(IntPtr stream, IntPtr buf, int len);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_ClearAudioStream(IntPtr stream);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool SDL_ResumeAudioStreamDevice(IntPtr stream);", Success);
      Emit_Line ("[DllImport(""SDL3"", CallingConvention = CallingConvention.Cdecl)] private static extern void SDL_free(IntPtr mem);", Success);
      Emit_Line ("", Success);

      Emit_Line ("public static long ALB_ScreenW;", Success);
      Emit_Line ("public static long ALB_ScreenH;", Success);
      Emit_Line ("public static long ALB_VirtualW;", Success);
      Emit_Line ("public static long ALB_VirtualH;", Success);
      Emit_Line ("public static long ALB_MouseX;", Success);
      Emit_Line ("public static long ALB_MouseY;", Success);
      Emit_Line ("public static long ALB_VMouseX;", Success);
      Emit_Line ("public static long ALB_VMouseY;", Success);
      Emit_Line ("public static int ALB_FrameMilliseconds = 16;", Success);
      Emit_Line ("public static bool ALB_Running = true;", Success);
      Emit_Line ("private static uint ALB_RngState = 2463534242U;", Success);
      Emit_Line ("private static ulong ALB_NextHandle = 1UL;", Success);
      Emit_Line ("public static string ALB_LastError = """";", Success);
      Emit_Line ("private static bool ALB_SDLReady;", Success);
      Emit_Line ("private static IntPtr ALB_Window;", Success);
      Emit_Line ("private static IntPtr ALB_Renderer;", Success);
      Emit_Line ("private static IntPtr ALB_AudioStream;", Success);
      Emit_Line ("private static IntPtr ALB_AudioScratch;", Success);
      Emit_Line ("private static int ALB_AudioScratchBytes;", Success);
      Emit_Line ("private static byte ALB_ColorR = 255;", Success);
      Emit_Line ("private static byte ALB_ColorG = 255;", Success);
      Emit_Line ("private static byte ALB_ColorB = 255;", Success);
      Emit_Line ("private static byte ALB_ColorA = 255;", Success);
      Emit_Line ("private static long ALB_OriginX;", Success);
      Emit_Line ("private static long ALB_OriginY;", Success);
      Emit_Line ("private static long ALB_ContentOffsetX;", Success);
      Emit_Line ("private static long ALB_ContentOffsetY;", Success);
      Emit_Line ("private static uint ALB_MouseMask;", Success);
      Emit_Line ("private static bool ALB_Stretchy;", Success);
      Emit_Line ("private static bool ALB_WindowResizable;", Success);
      Emit_Line ("private static bool ALB_WindowFullscreen;", Success);
      Emit_Line ("private static bool ALB_ClipEnabled;", Success);
      Emit_Line ("private static long ALB_ClipX;", Success);
      Emit_Line ("private static long ALB_ClipY;", Success);
      Emit_Line ("private static long ALB_ClipW;", Success);
      Emit_Line ("private static long ALB_ClipH;", Success);
      Emit_Line ("private const int ALB_MaxFiles = 32;", Success);
      Emit_Line ("private const int ALB_FileScratchBytes = 65536;", Success);
      Emit_Line ("private const int ALB_MemoryPoolBytes = 1048576;", Success);
      Emit_Line ("private const int ALB_LogicMaxFacts = 1024;", Success);
      Emit_Line ("private const int ALB_MaxClaimNodes = 4096;", Success);
      Emit_Line ("private const int ALB_ClaimStride = 8;", Success);
      Emit_Line ("private const int ALB_ClaimRegionStart = 262144;", Success);
      Emit_Line ("private const long ALB_TimelineAddressBase = 1073741824L;", Success);
      Emit_Line ("private const long ALB_TimelineAddressStride = 1048576L;", Success);
      Emit_Line ("private const int ALB_AssignSlotCount = 64;", Success);
      Emit_Line ("", Success);
      Emit_Line ("private struct ALB_FileSlot { public bool Active; public bool CanRead; public bool CanWrite; public ulong Handle; public FileStream Stream; }", Success);
      Emit_Line ("private struct ALB_RelFact { public bool Active; public long RelId; public long Arity; public long Arg1; public long Value; }", Success);
      Emit_Line ("private struct ALB_ClaimNode { public bool Active; public bool Marked; public bool Root; public long Address; public long Child1; public long Child2; }", Success);
      Emit_Line ("private struct ALB_AssignSlot { public byte Kind; public long LongValue; public ulong ULongValue; public double DoubleValue; public bool BoolValue; public string StringValue; public Pure128 PureValue; public ALB_U128 U128Value; }", Success);
      Emit_Line ("", Success);
      Emit_Line ("private static readonly ALB_FileSlot[] ALB_FileTable = new ALB_FileSlot[ALB_MaxFiles];", Success);
      Emit_Line ("private static readonly byte[] ALB_FileScratch = new byte[ALB_FileScratchBytes];", Success);
      Emit_Line ("private static readonly byte[] ALB_MemoryPool = new byte[ALB_MemoryPoolBytes];", Success);
      Emit_Line ("private static readonly byte[] ALB_MemorySnapshot = new byte[ALB_MemoryPoolBytes];", Success);
      Emit_Line ("private static readonly ALB_RelFact[] ALB_RelFacts = new ALB_RelFact[ALB_LogicMaxFacts];", Success);
      Emit_Line ("private static readonly ALB_RelFact[] ALB_RelFactsSnapshot = new ALB_RelFact[ALB_LogicMaxFacts];", Success);
      Emit_Line ("private static readonly long[] ALB_RelFindBuffer = new long[ALB_LogicMaxFacts];", Success);
      Emit_Line ("private static readonly ALB_ClaimNode[] ALB_ClaimNodes = new ALB_ClaimNode[ALB_MaxClaimNodes];", Success);
      Emit_Line ("private static readonly ALB_ClaimNode[] ALB_ClaimNodesSnapshot = new ALB_ClaimNode[ALB_MaxClaimNodes];", Success);
      Emit_Line ("private static readonly ALB_AssignSlot[] ALB_AssignSlots = new ALB_AssignSlot[ALB_AssignSlotCount];", Success);
      Emit_Line ("private static readonly byte[] ALB_NumberScratch = new byte[32];", Success);
      Emit_Line ("private static int ALB_AssignCount;", Success);
      Emit_Line ("private static bool ALB_HaveSavedState;", Success);
      Emit_Line ("private static long ALB_KnowsValue;", Success);
      Emit_Line ("private static long ALB_LastFindCount;", Success);
      Emit_Line ("private static uint ALB_RngStateSnapshot;", Success);
      Emit_Line ("private static ulong ALB_NextHandleSnapshot;", Success);
      Emit_Line ("private static string ALB_LastErrorSnapshot = """";", Success);
      Emit_Line ("private static long ALB_OriginXSnapshot;", Success);
      Emit_Line ("private static long ALB_OriginYSnapshot;", Success);
      Emit_Line ("private static byte ALB_ColorRSnapshot;", Success);
      Emit_Line ("private static byte ALB_ColorGSnapshot;", Success);
      Emit_Line ("private static byte ALB_ColorBSnapshot;", Success);
      Emit_Line ("private static byte ALB_ColorASnapshot;", Success);
      Emit_Line ("private static long ALB_KnowsValueSnapshot;", Success);
      Emit_Line ("", Success);
      Emit_Line ("private static T[] ALB_CreateFilledArray<T>(int count, T value)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int n = count <= 0 ? 1 : count;", Success);
      Emit_Line ("T[] result = new T[n];", Success);
      Emit_Line ("for (int i = 0; i < n; i += 1) { result[i] = value; }", Success);
      Emit_Line ("return result;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static Action<long, long> ALB_OnKnowsChange = null;", Success);
      Emit_Line ("", Success);

      Emit_Line ("public static bool ALB_Bool(bool value) { return value; }", Success);
      Emit_Line ("public static bool ALB_Bool(long value) { return value != 0; }", Success);
      Emit_Line ("public static bool ALB_Bool(ulong value) { return value != 0UL; }", Success);
      Emit_Line ("public static bool ALB_Bool(uint value) { return value != 0U; }", Success);
      Emit_Line ("public static bool ALB_Bool(double value) { return value != 0.0; }", Success);
      Emit_Line ("public static bool ALB_Bool(string value) { return value != null && value.Length != 0; }", Success);
      Emit_Line ("public static bool ALB_Bool(Pure128 value) { return value.Numerator != 0; }", Success);
      Emit_Line ("public static long ALB_Num(bool value) { return value ? 1L : 0L; }", Success);
      Emit_Line ("public static long ALB_Num(long value) { return value; }", Success);
      Emit_Line ("public static long ALB_Num(uint value) { return value; }", Success);
      Emit_Line ("public static long ALB_Num(ulong value) { return unchecked((long)value); }", Success);
      Emit_Line ("public static long ALB_Num(double value) { return (long)value; }", Success);
      Emit_Line ("public static long ALB_Num(string value) { return value == null ? 0 : value.Length; }", Success);
      Emit_Line ("public static long ALB_Num(Pure128 value) { long den = value.Denominator == 0 ? 1 : value.Denominator; return value.Numerator / den; }", Success);
      Emit_Line ("public static long ALB_Len(string value) { return value == null ? 0 : value.Length; }", Success);
      Emit_Line ("public static long ALB_Key(long keyCode)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (!ALB_SDLReady) { return 0; }", Success);
      Emit_Line ("int count = 0;", Success);
      Emit_Line ("IntPtr keys = SDL_GetKeyboardState(out count);", Success);
      Emit_Line ("int idx = keyCode < 0 ? 0 : (keyCode > int.MaxValue ? int.MaxValue : (int)keyCode);", Success);
      Emit_Line ("if (keys == IntPtr.Zero || idx < 0 || idx >= count) { return 0; }", Success);
      Emit_Line ("return Marshal.ReadByte(keys, idx) != 0 ? 1 : 0;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static long ALB_Rnd(long max)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_RngState = unchecked(ALB_RngState * 1664525U + 1013904223U);", Success);
      Emit_Line ("return max <= 0 ? 0 : (long)(ALB_RngState % (uint)max);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static long ALB_Sin(long degrees) { return (long)(Math.Sin(degrees * Math.PI / 180.0) * 1024.0); }", Success);
      Emit_Line ("public static long ALB_Cos(long degrees) { return (long)(Math.Cos(degrees * Math.PI / 180.0) * 1024.0); }", Success);
      Emit_Line ("public static long ALB_Sqrt(long value) { return value <= 0 ? 0 : (long)Math.Sqrt(value); }", Success);
      Emit_Line ("public static long ALB_Exp(long value) { return (long)Math.Exp(value); }", Success);
      Emit_Line ("public static long ALB_Div(long left, long right) { return right == 0 ? 0 : left / right; }", Success);
      Emit_Line ("public static long ALB_Div(long left, ulong right) { return right == 0UL ? 0 : left / unchecked((long)right); }", Success);
      Emit_Line ("public static ulong ALB_Div(ulong left, long right) { return right <= 0 ? 0UL : left / unchecked((ulong)right); }", Success);
      Emit_Line ("public static ulong ALB_Div(ulong left, ulong right) { return right == 0UL ? 0UL : left / right; }", Success);
      Emit_Line ("public static long ALB_Mod(long left, long right) { return right == 0 ? 0 : left % right; }", Success);
      Emit_Line ("public static long ALB_Mod(long left, ulong right) { return right == 0UL ? 0 : left % unchecked((long)right); }", Success);
      Emit_Line ("public static ulong ALB_Mod(ulong left, long right) { return right <= 0 ? 0UL : left % unchecked((ulong)right); }", Success);
      Emit_Line ("public static ulong ALB_Mod(ulong left, ulong right) { return right == 0UL ? 0UL : left % right; }", Success);
      Emit_Line ("public static long ALB_Rol(long value, long count) { int c = (int)(count & 63L); ulong v = unchecked((ulong)value); return unchecked((long)((v << c) | (v >> ((64 - c) & 63)))); }", Success);
      Emit_Line ("public static long ALB_Ror(long value, long count) { int c = (int)(count & 63L); ulong v = unchecked((ulong)value); return unchecked((long)((v >> c) | (v << ((64 - c) & 63)))); }", Success);
      Emit_Line ("public static string ALB_Left(string value, long count) { if (value == null || count <= 0) { return """"; } int n = count > value.Length ? value.Length : (int)count; return value.Substring(0, n); }", Success);
      Emit_Line ("public static string ALB_Right(string value, long count) { if (value == null || count <= 0) { return """"; } int n = count > value.Length ? value.Length : (int)count; return value.Substring(value.Length - n, n); }", Success);
      Emit_Line ("public static string ALB_Mid(string value, long start, long count) { if (value == null || count <= 0) { return """"; } int s = start <= 1 ? 0 : (int)(start - 1); if (s >= value.Length) { return """"; } int n = count > value.Length - s ? value.Length - s : (int)count; return value.Substring(s, n); }", Success);
      Emit_Line ("public static string ALB_Chr(long value) { return ((char)(value & 255L)).ToString(); }", Success);
      Emit_Line ("public static string ALB_Concat(string left, string right) { return (left ?? """") + (right ?? """"); }", Success);
      Emit_Line ("public static bool ALB_CollideRect(long ax, long ay, long aw, long ah, long bx, long by, long bw, long bh) { return ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by; }", Success);
      Emit_Line ("public static Pure128 ALB_Pure(long numerator, long denominator) { Pure128 r = default(Pure128); r.Numerator = numerator; r.Denominator = denominator == 0 ? 1 : denominator; return ALB_NormalizePure(r); }", Success);
      Emit_Line ("public static Pure128 ALB_Pure(long numerator, ulong denominator) { return ALB_Pure(numerator, unchecked((long)denominator)); }", Success);
      Emit_Line ("public static Pure128 ALB_Pure(ulong numerator, long denominator) { return ALB_Pure(unchecked((long)numerator), denominator); }", Success);
      Emit_Line ("public static Pure128 ALB_Pure(ulong numerator, ulong denominator) { return ALB_Pure(unchecked((long)numerator), unchecked((long)denominator)); }", Success);
      Emit_Line ("public static long ALB_Abs(long value) { return value < 0 ? 0 - value : value; }", Success);
      Emit_Line ("public static long ALB_Gcd(long left, long right) { long a = ALB_Abs(left); long b = ALB_Abs(right); while (b != 0) { long t = a % b; a = b; b = t; } return a == 0 ? 1 : a; }", Success);
      Emit_Line ("public static Pure128 ALB_NormalizePure(Pure128 value) { if (value.Denominator == 0) { value.Denominator = 1; } if (value.Denominator < 0) { value.Numerator = 0 - value.Numerator; value.Denominator = 0 - value.Denominator; } long g = ALB_Gcd(value.Numerator, value.Denominator); value.Numerator /= g; value.Denominator /= g; return value; }", Success);
      Emit_Line ("public static Pure128 ALB_PureZero() { return ALB_Pure(0, 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureOne() { return ALB_Pure(1, 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureNegOne() { return ALB_Pure(-1, 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureFromU64(ulong value) { return ALB_Pure(value, 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureFromS32(long value) { return ALB_Pure(value, 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureMake(long numerator, ulong denominator) { return ALB_Pure(numerator, denominator); }", Success);
      Emit_Line ("public static Pure128 ALB_PureReduce(Pure128 value) { return ALB_NormalizePure(value); }", Success);
      Emit_Line ("public static Pure128 ALB_PureAdd(Pure128 left, Pure128 right) { return ALB_Pure(left.Numerator * right.Denominator + right.Numerator * left.Denominator, left.Denominator * right.Denominator); }", Success);
      Emit_Line ("public static Pure128 ALB_PureSub(Pure128 left, Pure128 right) { return ALB_Pure(left.Numerator * right.Denominator - right.Numerator * left.Denominator, left.Denominator * right.Denominator); }", Success);
      Emit_Line ("public static Pure128 ALB_PureMul(Pure128 left, Pure128 right) { return ALB_Pure(left.Numerator * right.Numerator, left.Denominator * right.Denominator); }", Success);
      Emit_Line ("public static Pure128 ALB_PureDiv(Pure128 left, Pure128 right) { return right.Numerator == 0 ? default(Pure128) : ALB_Pure(left.Numerator * right.Denominator, left.Denominator * right.Numerator); }", Success);
      Emit_Line ("public static Pure128 ALB_PurePow(Pure128 value, Pure128 power) { long n = power.Numerator / (power.Denominator == 0 ? 1 : power.Denominator); Pure128 r = ALB_Pure(1, 1); long limit = n < 0 ? 0 - n : n; for (long i = 0; i < limit; i += 1) { r = ALB_PureMul(r, value); } return n < 0 ? ALB_PureDiv(ALB_Pure(1, 1), r) : r; }", Success);
      Emit_Line ("public static long ALB_PureNum(Pure128 value) { return value.Numerator; }", Success);
      Emit_Line ("public static long ALB_PureDen(Pure128 value) { return value.Denominator == 0 ? 1 : value.Denominator; }", Success);
      Emit_Line ("public static ulong ALB_PureIsZero(Pure128 value) { return value.Numerator == 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureIsPositive(Pure128 value) { return value.Numerator > 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureIsNegative(Pure128 value) { return value.Numerator < 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureIsWhole(Pure128 value) { long den = ALB_PureDen(value); return value.Numerator % den == 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureIsUnitInterval(Pure128 value) { return ALB_PureGte(value, ALB_PureZero()) != 0UL && ALB_PureLte(value, ALB_PureOne()) != 0UL ? 1UL : 0UL; }", Success);
      Emit_Line ("public static Pure128 ALB_PureAbs(Pure128 value) { value = ALB_NormalizePure(value); if (value.Numerator < 0) { value.Numerator = 0 - value.Numerator; } return value; }", Success);
      Emit_Line ("public static Pure128 ALB_PureNeg(Pure128 value) { value = ALB_NormalizePure(value); value.Numerator = 0 - value.Numerator; return value; }", Success);
      Emit_Line ("public static Pure128 ALB_PureReciprocal(Pure128 value) { value = ALB_NormalizePure(value); return value.Numerator == 0 ? default(Pure128) : ALB_Pure(value.Denominator, value.Numerator); }", Success);
      Emit_Line ("public static Pure128 ALB_PureSqr(Pure128 value) { return ALB_PureMul(value, value); }", Success);
      Emit_Line ("public static Pure128 ALB_PurePowU64(Pure128 value, ulong power) { Pure128 r = ALB_Pure(1, 1); for (ulong i = 0; i < power; i += 1UL) { r = ALB_PureMul(r, value); } return r; }", Success);
      Emit_Line ("public static long ALB_PureCompare(Pure128 left, Pure128 right) { left = ALB_NormalizePure(left); right = ALB_NormalizePure(right); long l = left.Numerator * right.Denominator; long r = right.Numerator * left.Denominator; return l < r ? -1 : (l > r ? 1 : 0); }", Success);
      Emit_Line ("public static ulong ALB_PureEq(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) == 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureNeq(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) != 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureLt(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) < 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureLte(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) <= 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureGt(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) > 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureGte(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) >= 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static Pure128 ALB_PureMin(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) <= 0 ? left : right; }", Success);
      Emit_Line ("public static Pure128 ALB_PureMax(Pure128 left, Pure128 right) { return ALB_PureCompare(left, right) >= 0 ? left : right; }", Success);
      Emit_Line ("public static Pure128 ALB_PureClamp(Pure128 value, Pure128 low, Pure128 high) { if (ALB_PureCompare(value, low) < 0) { return low; } if (ALB_PureCompare(value, high) > 0) { return high; } return value; }", Success);
      Emit_Line ("public static ulong ALB_PureInRange(Pure128 value, Pure128 low, Pure128 high) { return ALB_PureCompare(value, low) >= 0 && ALB_PureCompare(value, high) <= 0 ? 1UL : 0UL; }", Success);
      Emit_Line ("public static long ALB_PureFloorS32(Pure128 value) { value = ALB_NormalizePure(value); long den = ALB_PureDen(value); long q = value.Numerator / den; long r = value.Numerator % den; return value.Numerator < 0 && r != 0 ? q - 1 : q; }", Success);
      Emit_Line ("public static long ALB_PureCeilS32(Pure128 value) { value = ALB_NormalizePure(value); long den = ALB_PureDen(value); long q = value.Numerator / den; long r = value.Numerator % den; return value.Numerator > 0 && r != 0 ? q + 1 : q; }", Success);
      Emit_Line ("public static long ALB_PureTruncS32(Pure128 value) { value = ALB_NormalizePure(value); return value.Numerator / ALB_PureDen(value); }", Success);
      Emit_Line ("public static long ALB_PureRoundS32(Pure128 value) { value = ALB_NormalizePure(value); long den = ALB_PureDen(value); long abs = ALB_Abs(value.Numerator); long q = abs / den; long r = abs % den; if (r * 2 >= den) { q += 1; } return value.Numerator < 0 ? 0 - q : q; }", Success);
      Emit_Line ("public static ulong ALB_PureFloorU64(Pure128 value) { long v = ALB_PureFloorS32(value); return v < 0 ? 0UL : unchecked((ulong)v); }", Success);
      Emit_Line ("public static ulong ALB_PureCeilU64(Pure128 value) { long v = ALB_PureCeilS32(value); return v < 0 ? 0UL : unchecked((ulong)v); }", Success);
      Emit_Line ("public static ulong ALB_PureTruncU64(Pure128 value) { long v = ALB_PureTruncS32(value); return v < 0 ? 0UL : unchecked((ulong)v); }", Success);
      Emit_Line ("public static ulong ALB_PureRoundU64(Pure128 value) { long v = ALB_PureRoundS32(value); return v < 0 ? 0UL : unchecked((ulong)v); }", Success);
      Emit_Line ("public static Pure128 ALB_PureWholePart(Pure128 value) { return ALB_Pure(ALB_PureTruncS32(value), 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureFractionPart(Pure128 value) { return ALB_PureSub(value, ALB_PureWholePart(value)); }", Success);
      Emit_Line ("public static Pure128 ALB_PureProperFraction(Pure128 value) { return ALB_PureAbs(ALB_PureFractionPart(value)); }", Success);
      Emit_Line ("public static ulong ALB_PureSqrtFloorU64(ulong value) { ulong lo = 0UL; ulong hi = value; ulong ans = 0UL; while (lo <= hi) { ulong mid = lo + ((hi - lo) / 2UL); if (mid == 0UL || mid <= value / mid) { ans = mid; lo = mid + 1UL; } else { if (mid == 0UL) { break; } hi = mid - 1UL; } } return ans; }", Success);
      Emit_Line ("public static ulong ALB_PureIsPerfectSquareU64(ulong value) { ulong r = ALB_PureSqrtFloorU64(value); return r * r == value ? 1UL : 0UL; }", Success);
      Emit_Line ("public static ulong ALB_PureIsPerfectSquarePure(Pure128 value) { value = ALB_NormalizePure(value); if (value.Numerator < 0) { return 0UL; } return ALB_PureIsPerfectSquareU64(unchecked((ulong)value.Numerator)) != 0UL && ALB_PureIsPerfectSquareU64(unchecked((ulong)ALB_PureDen(value))) != 0UL ? 1UL : 0UL; }", Success);
      Emit_Line ("public static Pure128 ALB_PureSqrtExact(Pure128 value) { value = ALB_NormalizePure(value); if (ALB_PureIsPerfectSquarePure(value) == 0UL) { return default(Pure128); } return ALB_Pure(unchecked((long)ALB_PureSqrtFloorU64(unchecked((ulong)value.Numerator))), unchecked((long)ALB_PureSqrtFloorU64(unchecked((ulong)ALB_PureDen(value))))); }", Success);
      Emit_Line ("public static Pure128 ALB_PureSqrtFloor(Pure128 value) { return ALB_Pure(ALB_PureFloorS32(ALB_PureSqrtApprox(value, 8UL)), 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureSqrtCeil(Pure128 value) { return ALB_Pure(ALB_PureCeilS32(ALB_PureSqrtApprox(value, 8UL)), 1); }", Success);
      Emit_Line ("public static Pure128 ALB_PureSqrtApprox(Pure128 value, ulong steps) { if (value.Numerator <= 0) { return default(Pure128); } double d = Math.Sqrt((double)value.Numerator / (double)ALB_PureDen(value)); return ALB_Pure((long)(d * 1000000.0), 1000000); }", Success);
      Emit_Line ("public static long ALB_PureToScaledFloor(Pure128 value, ulong scale) { return ALB_PureFloorS32(ALB_PureMul(value, ALB_Pure(scale, 1))); }", Success);
      Emit_Line ("public static long ALB_PureToScaledCeil(Pure128 value, ulong scale) { return ALB_PureCeilS32(ALB_PureMul(value, ALB_Pure(scale, 1))); }", Success);
      Emit_Line ("public static long ALB_PureToScaledRound(Pure128 value, ulong scale) { return ALB_PureRoundS32(ALB_PureMul(value, ALB_Pure(scale, 1))); }", Success);
      Emit_Line ("public static Pure128 ALB_PureFromScaled(long value, ulong scale) { return ALB_Pure(value, scale == 0UL ? 1UL : scale); }", Success);
      Emit_Line ("public static Pure128 ALB_PureRatio(ulong part, ulong whole) { return ALB_Pure(part, whole == 0UL ? 1UL : whole); }", Success);
      Emit_Line ("public static Pure128 ALB_PurePercent(ulong pct) { return ALB_Pure(pct, 100UL); }", Success);
      Emit_Line ("public static Pure128 ALB_PureBasisPoints(ulong bps) { return ALB_Pure(bps, 10000UL); }", Success);
      Emit_Line ("public static ulong ALB_PurePercentOf(ulong value, Pure128 pct) { return ALB_PureTruncU64(ALB_PureMul(ALB_Pure(value, 1), pct)); }", Success);
      Emit_Line ("public static Pure128 ALB_PureLerp(Pure128 left, Pure128 right, Pure128 t) { return ALB_PureAdd(left, ALB_PureMul(ALB_PureSub(right, left), t)); }", Success);
      Emit_Line ("public static Pure128 ALB_PureInverseLerp(Pure128 left, Pure128 right, Pure128 value) { return ALB_PureDiv(ALB_PureSub(value, left), ALB_PureSub(right, left)); }", Success);
      Emit_Line ("public static Pure128 ALB_PureRemap(Pure128 value, Pure128 a1, Pure128 b1, Pure128 a2, Pure128 b2) { return ALB_PureLerp(a2, b2, ALB_PureInverseLerp(a1, b1, value)); }", Success);
      Emit_Line ("public static Pure128 ALB_PureSinDegApprox(ulong angle) { double r = (double)(angle % 360UL) * Math.PI / 180.0; return ALB_Pure((long)(Math.Sin(r) * 1000000.0), 1000000); }", Success);
      Emit_Line ("public static Pure128 ALB_PureCosDegApprox(ulong angle) { double r = (double)(angle % 360UL) * Math.PI / 180.0; return ALB_Pure((long)(Math.Cos(r) * 1000000.0), 1000000); }", Success);
      Emit_Line ("public static ulong ALB_PureTanDegDefined(ulong angle) { ulong a = angle % 180UL; return a == 90UL ? 0UL : 1UL; }", Success);
      Emit_Line ("public static Pure128 ALB_PureTanDegApprox(ulong angle) { if (ALB_PureTanDegDefined(angle) == 0UL) { return default(Pure128); } double r = (double)(angle % 360UL) * Math.PI / 180.0; return ALB_Pure((long)(Math.Tan(r) * 1000000.0), 1000000); }", Success);
      Emit_Line ("public static ulong ALB_PureDenU(Pure128 value) { return unchecked((ulong)ALB_PureDen(value)); }", Success);
      Emit_Line ("", Success);

      Emit_Line ("public static void ALB_EnsureSDL()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_SDLReady) { return; }", Success);
      Emit_Line ("ALB_SDLReady = SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_EnsureAudio()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_EnsureSDL();", Success);
      Emit_Line ("if (ALB_AudioStream != IntPtr.Zero) { return; }", Success);
      Emit_Line ("SDL_AudioSpec spec = default(SDL_AudioSpec);", Success);
      Emit_Line ("spec.Format = SDL_AUDIO_S16;", Success);
      Emit_Line ("spec.Channels = 1;", Success);
      Emit_Line ("spec.Freq = 44100;", Success);
      Emit_Line ("ALB_AudioStream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, ref spec, IntPtr.Zero, IntPtr.Zero);", Success);
      Emit_Line ("if (ALB_AudioStream != IntPtr.Zero) { SDL_ResumeAudioStreamDevice(ALB_AudioStream); }", Success);
      Emit_Line ("if (ALB_AudioScratch == IntPtr.Zero) { ALB_AudioScratchBytes = 262144; ALB_AudioScratch = Marshal.AllocHGlobal(ALB_AudioScratchBytes); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_ApplyColor()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer != IntPtr.Zero) { SDL_SetRenderDrawColor(ALB_Renderer, ALB_ColorR, ALB_ColorG, ALB_ColorB, ALB_ColorA); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_UpdateOutputState()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer == IntPtr.Zero) { return; }", Success);
      Emit_Line ("int outW;", Success);
      Emit_Line ("int outH;", Success);
      Emit_Line ("if (!SDL_GetCurrentRenderOutputSize(ALB_Renderer, out outW, out outH)) { return; }", Success);
      Emit_Line ("ALB_ScreenW = outW;", Success);
      Emit_Line ("ALB_ScreenH = outH;", Success);
      Emit_Line ("if (ALB_Stretchy)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_ContentOffsetX = 0;", Success);
      Emit_Line ("ALB_ContentOffsetY = 0;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("else", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long dx = ALB_ScreenW - ALB_VirtualW;", Success);
      Emit_Line ("if (dx < 0) { dx = 0; }", Success);
      Emit_Line ("ALB_ContentOffsetX = dx / 2;", Success);
      Emit_Line ("long dy = ALB_ScreenH - ALB_VirtualH;", Success);
      Emit_Line ("if (dy < 0) { dy = 0; }", Success);
      Emit_Line ("ALB_ContentOffsetY = dy / 2;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("ALB_ApplyClip();", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("private static float ALB_MapRenderX(long x)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long value = x + ALB_OriginX;", Success);
      Emit_Line ("if (ALB_Stretchy && ALB_VirtualW > 0) { return (float)(((double)value * (double)ALB_ScreenW) / (double)ALB_VirtualW); }", Success);
      Emit_Line ("return (float)(value + ALB_ContentOffsetX);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("private static float ALB_MapRenderY(long y)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long value = y + ALB_OriginY;", Success);
      Emit_Line ("if (ALB_Stretchy && ALB_VirtualH > 0) { return (float)(((double)value * (double)ALB_ScreenH) / (double)ALB_VirtualH); }", Success);
      Emit_Line ("return (float)(value + ALB_ContentOffsetY);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("private static float ALB_MapRenderW(long width)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Stretchy && ALB_VirtualW > 0) { return (float)(((double)width * (double)ALB_ScreenW) / (double)ALB_VirtualW); }", Success);
      Emit_Line ("return (float)width;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("private static float ALB_MapRenderH(long height)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Stretchy && ALB_VirtualH > 0) { return (float)(((double)height * (double)ALB_ScreenH) / (double)ALB_VirtualH); }", Success);
      Emit_Line ("return (float)height;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("private static void ALB_ApplyClip()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer == IntPtr.Zero) { return; }", Success);
      Emit_Line ("if (!ALB_ClipEnabled || ALB_ClipW <= 0 || ALB_ClipH <= 0) { SDL_SetRenderClipRectNull(ALB_Renderer, IntPtr.Zero); return; }", Success);
      Emit_Line ("float x1f = ALB_MapRenderX(ALB_ClipX);", Success);
      Emit_Line ("float y1f = ALB_MapRenderY(ALB_ClipY);", Success);
      Emit_Line ("float x2f = ALB_MapRenderX(ALB_ClipX + ALB_ClipW);", Success);
      Emit_Line ("float y2f = ALB_MapRenderY(ALB_ClipY + ALB_ClipH);", Success);
      Emit_Line ("SDL_Rect r = default(SDL_Rect);", Success);
      Emit_Line ("r.X = (int)x1f;", Success);
      Emit_Line ("r.Y = (int)y1f;", Success);
      Emit_Line ("r.W = (int)(x2f - x1f);", Success);
      Emit_Line ("r.H = (int)(y2f - y1f);", Success);
      Emit_Line ("if (r.W < 1) { r.W = 1; }", Success);
      Emit_Line ("if (r.H < 1) { r.H = 1; }", Success);
      Emit_Line ("SDL_SetRenderClipRect(ALB_Renderer, ref r);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_CreateWindow(string title, long width, long height)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_EnsureSDL();", Success);
      Emit_Line ("ALB_VirtualW = width <= 0 ? 640 : width;", Success);
      Emit_Line ("ALB_VirtualH = height <= 0 ? 480 : height;", Success);
      Emit_Line ("ALB_ScreenW = ALB_VirtualW;", Success);
      Emit_Line ("ALB_ScreenH = ALB_VirtualH;", Success);
      Emit_Line ("if (ALB_Window == IntPtr.Zero || ALB_Renderer == IntPtr.Zero)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ulong flags = 0UL;", Success);
      Emit_Line ("if (ALB_WindowResizable) { flags |= SDL_WINDOW_RESIZABLE; }", Success);
      Emit_Line ("if (ALB_WindowFullscreen) { flags |= SDL_WINDOW_FULLSCREEN; }", Success);
      Emit_Line ("if (!SDL_CreateWindowAndRenderer(title, (int)ALB_VirtualW, (int)ALB_VirtualH, flags, out ALB_Window, out ALB_Renderer)) { ALB_Running = false; return; }", Success);
      Emit_Line ("SDL_SetRenderDrawBlendMode(ALB_Renderer, SDL_BLENDMODE_BLEND);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("else", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("SDL_SetWindowSize(ALB_Window, (int)ALB_VirtualW, (int)ALB_VirtualH);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("if (ALB_Window != IntPtr.Zero) { SDL_SetWindowSize(ALB_Window, (int)ALB_VirtualW, (int)ALB_VirtualH); SDL_SetWindowResizable(ALB_Window, ALB_WindowResizable); SDL_SetWindowFullscreen(ALB_Window, ALB_WindowFullscreen); }", Success);
      Emit_Line ("ALB_UpdateOutputState();", Success);
      Emit_Line ("ALB_ApplyClip();", Success);
      Emit_Line ("ALB_ApplyColor();", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_Color(long color)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("uint c = unchecked((uint)color);", Success);
      Emit_Line ("ALB_ColorR = (byte)((c >> 16) & 0xFFU);", Success);
      Emit_Line ("ALB_ColorG = (byte)((c >> 8) & 0xFFU);", Success);
      Emit_Line ("ALB_ColorB = (byte)(c & 0xFFU);", Success);
      Emit_Line ("ALB_ApplyColor();", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_Clear(long color)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer == IntPtr.Zero) { return; }", Success);
      Emit_Line ("ALB_Color(color);", Success);
      Emit_Line ("SDL_RenderClear(ALB_Renderer);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static float ALB_X(long x) { return ALB_MapRenderX(x); }", Success);
      Emit_Line ("public static float ALB_Y(long y) { return ALB_MapRenderY(y); }", Success);
      Emit_Line ("public static void ALB_DrawText(long x, long y, string text) { if (ALB_Renderer != IntPtr.Zero) { ALB_ApplyColor(); SDL_RenderDebugText(ALB_Renderer, ALB_X(x), ALB_Y(y), text ?? """"); } }", Success);
      Emit_Line ("public static void ALB_DrawText(long x, long y, long value) { ALB_DrawText(x, y, value.ToString()); }", Success);
      Emit_Line ("public static void ALB_DrawText(long x, long y, ulong value) { ALB_DrawText(x, y, value.ToString()); }", Success);
      Emit_Line ("public static void ALB_DrawText(long x, long y, Pure128 value) { ALB_DrawText(x, y, ALB_PureNum(value).ToString() + ""/"" + ALB_PureDen(value).ToString()); }", Success);

      Emit_Line ("public static void ALB_DrawCircle(long cx, long cy, long radius, bool fill)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer == IntPtr.Zero || radius < 0) { return; }", Success);
      Emit_Line ("ALB_ApplyColor();", Success);
      Emit_Line ("long r2 = radius * radius;", Success);
      Emit_Line ("if (fill)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("for (long y = -radius; y <= radius; y += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("for (long x = -radius; x <= radius; x += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (x * x + y * y <= r2) { SDL_RenderPoint(ALB_Renderer, ALB_X(cx + x), ALB_Y(cy + y)); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("else", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long x = radius;", Success);
      Emit_Line ("long y = 0;", Success);
      Emit_Line ("long err = 0;", Success);
      Emit_Line ("while (x >= y)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("SDL_RenderPoint(ALB_Renderer, ALB_X(cx + x), ALB_Y(cy + y)); SDL_RenderPoint(ALB_Renderer, ALB_X(cx + y), ALB_Y(cy + x));", Success);
      Emit_Line ("SDL_RenderPoint(ALB_Renderer, ALB_X(cx - y), ALB_Y(cy + x)); SDL_RenderPoint(ALB_Renderer, ALB_X(cx - x), ALB_Y(cy + y));", Success);
      Emit_Line ("SDL_RenderPoint(ALB_Renderer, ALB_X(cx - x), ALB_Y(cy - y)); SDL_RenderPoint(ALB_Renderer, ALB_X(cx - y), ALB_Y(cy - x));", Success);
      Emit_Line ("SDL_RenderPoint(ALB_Renderer, ALB_X(cx + y), ALB_Y(cy - x)); SDL_RenderPoint(ALB_Renderer, ALB_X(cx + x), ALB_Y(cy - y));", Success);
      Emit_Line ("if (err <= 0) { y += 1; err += 2 * y + 1; }", Success);
      Emit_Line ("if (err > 0) { x -= 1; err -= 2 * x + 1; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_DrawTriangle(long x1, long y1, long x2, long y2, long x3, long y3, bool fill)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer == IntPtr.Zero) { return; }", Success);
      Emit_Line ("ALB_ApplyColor();", Success);
      Emit_Line ("if (!fill)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("SDL_RenderLine(ALB_Renderer, ALB_X(x1), ALB_Y(y1), ALB_X(x2), ALB_Y(y2));", Success);
      Emit_Line ("SDL_RenderLine(ALB_Renderer, ALB_X(x2), ALB_Y(y2), ALB_X(x3), ALB_Y(y3));", Success);
      Emit_Line ("SDL_RenderLine(ALB_Renderer, ALB_X(x3), ALB_Y(y3), ALB_X(x1), ALB_Y(y1));", Success);
      Emit_Line ("return;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("long minY = Math.Min(y1, Math.Min(y2, y3));", Success);
      Emit_Line ("long maxY = Math.Max(y1, Math.Max(y2, y3));", Success);
      Emit_Line ("for (long y = minY; y <= maxY; y += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long minX = Math.Min(x1, Math.Min(x2, x3));", Success);
      Emit_Line ("long maxX = Math.Max(x1, Math.Max(x2, x3));", Success);
      Emit_Line ("for (long x = minX; x <= maxX; x += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long d1 = (x - x2) * (y1 - y2) - (x1 - x2) * (y - y2);", Success);
      Emit_Line ("long d2 = (x - x3) * (y2 - y3) - (x2 - x3) * (y - y3);", Success);
      Emit_Line ("long d3 = (x - x1) * (y3 - y1) - (x3 - x1) * (y - y1);", Success);
      Emit_Line ("bool neg = d1 < 0 || d2 < 0 || d3 < 0;", Success);
      Emit_Line ("bool pos = d1 > 0 || d2 > 0 || d3 > 0;", Success);
      Emit_Line ("if (!(neg && pos)) { SDL_RenderPoint(ALB_Renderer, ALB_X(x), ALB_Y(y)); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_Draw(string primitive, long a1, long a2, long a3, long a4, long a5, long a6)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer == IntPtr.Zero) { return; }", Success);
      Emit_Line ("ALB_ApplyColor();", Success);
      Emit_Line ("if (primitive == ""PLOT"") { SDL_RenderPoint(ALB_Renderer, ALB_X(a1), ALB_Y(a2)); }", Success);
      Emit_Line ("else if (primitive == ""LINE"") { SDL_RenderLine(ALB_Renderer, ALB_X(a1), ALB_Y(a2), ALB_X(a3), ALB_Y(a4)); }", Success);
      Emit_Line ("else if (primitive == ""RECT"") { SDL_FRect r = default(SDL_FRect); r.X = ALB_X(a1); r.Y = ALB_Y(a2); r.W = ALB_MapRenderW(a3); r.H = ALB_MapRenderH(a4); SDL_RenderRect(ALB_Renderer, ref r); }", Success);
      Emit_Line ("else if (primitive == ""FILL_RECT"") { SDL_FRect r = default(SDL_FRect); r.X = ALB_X(a1); r.Y = ALB_Y(a2); r.W = ALB_MapRenderW(a3); r.H = ALB_MapRenderH(a4); SDL_RenderFillRect(ALB_Renderer, ref r); }", Success);
      Emit_Line ("else if (primitive == ""CIRCLE"") { ALB_DrawCircle(a1, a2, a3, false); }", Success);
      Emit_Line ("else if (primitive == ""FILL_CIRCLE"") { ALB_DrawCircle(a1, a2, a3, true); }", Success);
      Emit_Line ("else if (primitive == ""TRIANGLE"") { ALB_DrawTriangle(a1, a2, a3, a4, a5, a6, false); }", Success);
      Emit_Line ("else if (primitive == ""FILL_TRIANGLE"") { ALB_DrawTriangle(a1, a2, a3, a4, a5, a6, true); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static void ALB_ClearAssignArgs() { ALB_AssignCount = 0; }", Success);
      Emit_Line ("private static void ALB_PushAssignLong(long value) { int idx = ALB_AssignCount < ALB_AssignSlotCount ? ALB_AssignCount : ALB_AssignSlotCount - 1; ALB_AssignSlots[idx].Kind = 1; ALB_AssignSlots[idx].LongValue = value; ALB_AssignSlots[idx].ULongValue = unchecked((ulong)value); ALB_AssignSlots[idx].StringValue = null; if (ALB_AssignCount < ALB_AssignSlotCount) { ALB_AssignCount += 1; } }", Success);
      Emit_Line ("private static void ALB_PushAssignULong(ulong value) { int idx = ALB_AssignCount < ALB_AssignSlotCount ? ALB_AssignCount : ALB_AssignSlotCount - 1; ALB_AssignSlots[idx].Kind = 2; ALB_AssignSlots[idx].ULongValue = value; ALB_AssignSlots[idx].LongValue = unchecked((long)value); ALB_AssignSlots[idx].StringValue = null; if (ALB_AssignCount < ALB_AssignSlotCount) { ALB_AssignCount += 1; } }", Success);
      Emit_Line ("private static void ALB_PushAssignDouble(double value) { int idx = ALB_AssignCount < ALB_AssignSlotCount ? ALB_AssignCount : ALB_AssignSlotCount - 1; ALB_AssignSlots[idx].Kind = 3; ALB_AssignSlots[idx].DoubleValue = value; ALB_AssignSlots[idx].StringValue = null; if (ALB_AssignCount < ALB_AssignSlotCount) { ALB_AssignCount += 1; } }", Success);
      Emit_Line ("private static void ALB_PushAssignBool(bool value) { int idx = ALB_AssignCount < ALB_AssignSlotCount ? ALB_AssignCount : ALB_AssignSlotCount - 1; ALB_AssignSlots[idx].Kind = 4; ALB_AssignSlots[idx].BoolValue = value; ALB_AssignSlots[idx].StringValue = null; if (ALB_AssignCount < ALB_AssignSlotCount) { ALB_AssignCount += 1; } }", Success);
      Emit_Line ("private static void ALB_PushAssignString(string value) { int idx = ALB_AssignCount < ALB_AssignSlotCount ? ALB_AssignCount : ALB_AssignSlotCount - 1; ALB_AssignSlots[idx].Kind = 5; ALB_AssignSlots[idx].StringValue = value ?? """"; if (ALB_AssignCount < ALB_AssignSlotCount) { ALB_AssignCount += 1; } }", Success);
      Emit_Line ("private static void ALB_PushAssignPure(Pure128 value) { int idx = ALB_AssignCount < ALB_AssignSlotCount ? ALB_AssignCount : ALB_AssignSlotCount - 1; ALB_AssignSlots[idx].Kind = 6; ALB_AssignSlots[idx].PureValue = value; ALB_AssignSlots[idx].StringValue = null; if (ALB_AssignCount < ALB_AssignSlotCount) { ALB_AssignCount += 1; } }", Success);
      Emit_Line ("private static void ALB_PushAssignU128(ALB_U128 value) { int idx = ALB_AssignCount < ALB_AssignSlotCount ? ALB_AssignCount : ALB_AssignSlotCount - 1; ALB_AssignSlots[idx].Kind = 7; ALB_AssignSlots[idx].U128Value = value; ALB_AssignSlots[idx].StringValue = null; if (ALB_AssignCount < ALB_AssignSlotCount) { ALB_AssignCount += 1; } }", Success);
      Emit_Line ("private static int ALB_FindFileSlot(ulong handle) { for (int i = 0; i < ALB_MaxFiles; i += 1) { if (ALB_FileTable[i].Active && ALB_FileTable[i].Handle == handle) { return i; } } return -1; }", Success);
      Emit_Line ("private static bool ALB_MemoryRangeValid(long address, int width) { return address >= 0 && width >= 0 && address <= ALB_MemoryPoolBytes - width; }", Success);
      Emit_Line ("private static long ALB_ReadMemory64(long address) { if (!ALB_MemoryRangeValid(address, 8)) { return 0; } int idx = (int)address; ulong value = (ulong)ALB_MemoryPool[idx] | ((ulong)ALB_MemoryPool[idx + 1] << 8) | ((ulong)ALB_MemoryPool[idx + 2] << 16) | ((ulong)ALB_MemoryPool[idx + 3] << 24) | ((ulong)ALB_MemoryPool[idx + 4] << 32) | ((ulong)ALB_MemoryPool[idx + 5] << 40) | ((ulong)ALB_MemoryPool[idx + 6] << 48) | ((ulong)ALB_MemoryPool[idx + 7] << 56); return unchecked((long)value); }", Success);
      Emit_Line ("private static void ALB_WriteMemory64(long address, long value) { if (!ALB_MemoryRangeValid(address, 8)) { return; } int idx = (int)address; ulong raw = unchecked((ulong)value); ALB_MemoryPool[idx] = (byte)(raw & 0xFFUL); ALB_MemoryPool[idx + 1] = (byte)((raw >> 8) & 0xFFUL); ALB_MemoryPool[idx + 2] = (byte)((raw >> 16) & 0xFFUL); ALB_MemoryPool[idx + 3] = (byte)((raw >> 24) & 0xFFUL); ALB_MemoryPool[idx + 4] = (byte)((raw >> 32) & 0xFFUL); ALB_MemoryPool[idx + 5] = (byte)((raw >> 40) & 0xFFUL); ALB_MemoryPool[idx + 6] = (byte)((raw >> 48) & 0xFFUL); ALB_MemoryPool[idx + 7] = (byte)((raw >> 56) & 0xFFUL); }", Success);
      Emit_Line ("private static int ALB_FindClaimIndex(long address) { for (int i = 0; i < ALB_MaxClaimNodes; i += 1) { if (ALB_ClaimNodes[i].Active && ALB_ClaimNodes[i].Address == address) { return i; } } return -1; }", Success);
      Emit_Line ("private static void ALB_MarkClaim(int index) { if (index < 0 || index >= ALB_MaxClaimNodes || !ALB_ClaimNodes[index].Active || ALB_ClaimNodes[index].Marked) { return; } ALB_ClaimNodes[index].Marked = true; ALB_MarkClaim(ALB_FindClaimIndex(ALB_ClaimNodes[index].Child1)); ALB_MarkClaim(ALB_FindClaimIndex(ALB_ClaimNodes[index].Child2)); }", Success);
      Emit_Line ("private static MethodInfo ALB_FindCallable(string name) { if (string.IsNullOrEmpty(name)) { return null; } MethodInfo exact = typeof(Program).GetMethod(name, BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic); if (exact != null) { return exact; } int dot = name.LastIndexOf('.'); if (dot >= 0 && dot + 1 < name.Length) { return typeof(Program).GetMethod(name.Substring(dot + 1), BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic); } return null; }", Success);
      Emit_Line ("private static bool ALB_TrySetNamedString(string target, string value) { if (string.IsNullOrEmpty(target)) { return false; } FieldInfo field = typeof(Program).GetField(target, BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic); if (field == null) { int dot = target.LastIndexOf('.'); if (dot >= 0 && dot + 1 < target.Length) { field = typeof(Program).GetField(target.Substring(dot + 1), BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic); } } if (field == null || field.FieldType != typeof(string)) { return false; } field.SetValue(null, value ?? """"); return true; }", Success);
      Emit_Line ("public static void ALB_Call(string name)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (string.IsNullOrEmpty(name)) { ALB_ClearAssignArgs(); return; }", Success);
      Emit_Line ("if (name == ""PRINT_PURE"")", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("Pure128 value = ALB_Pure(0, 1);", Success);
      Emit_Line ("bool have = false;", Success);
      Emit_Line ("if (ALB_AssignCount > 0)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_AssignSlot slot = ALB_AssignSlots[ALB_AssignCount - 1];", Success);
      Emit_Line ("if (slot.Kind == 6) { value = slot.PureValue; have = true; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("if (!have)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("FieldInfo field = typeof(Program).GetField(""pure_value"", BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic);", Success);
      Emit_Line ("if (field != null && field.FieldType == typeof(Pure128)) { value = (Pure128)field.GetValue(null); have = true; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("Console.Write(ALB_PureNum(value));", Success);
      Emit_Line ("Console.Write(""/"");", Success);
      Emit_Line ("Console.WriteLine(ALB_PureDen(value));", Success);
      Emit_Line ("ALB_ClearAssignArgs();", Success);
      Emit_Line ("return;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("MethodInfo method = ALB_FindCallable(name);", Success);
      Emit_Line ("if (method != null)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ParameterInfo[] parameters = method.GetParameters();", Success);
      Emit_Line ("if (parameters.Length == 0) { method.Invoke(null, null); ALB_ClearAssignArgs(); return; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("ALB_ClearAssignArgs();", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Particles_Setup() { }", Success);
      Emit_Line ("public static void ALB_Particles_Emit(Pure128 x, Pure128 y, Pure128 dx, Pure128 dy, long col, long life) { }", Success);
      Emit_Line ("public static void ALB_Particles_Emit(Pure128 x, Pure128 y, Pure128 dx, Pure128 dy, long col, ulong life) { }", Success);
      Emit_Line ("public static void ALB_Particles_Simulate() { }", Success);
      Emit_Line ("public static void ALB_Particles_Render() { }", Success);
      Emit_Line ("public static ulong ALB_MiterLessons_GetCount() { return 4UL; }", Success);
      Emit_Line ("public static Pure128 ALB_MiterLessons_GetTargetFraction(ulong id) { if (id == 1UL) { return ALB_Pure(1, 4); } if (id == 2UL) { return ALB_Pure(2, 4); } if (id == 3UL) { return ALB_Pure(3, 4); } if (id == 4UL) { return ALB_Pure(4, 4); } return ALB_Pure(1, 1); }", Success);
      Emit_Line ("public static string ALB_MiterLessons_GetTitle(ulong id) { if (id == 1UL) { return ""LESSON 01: 1/4 CUT (24 INCHES)""; } if (id == 2UL) { return ""LESSON 02: 2/4 CUT (48 INCHES)""; } if (id == 3UL) { return ""LESSON 03: 3/4 CUT (72 INCHES)""; } if (id == 4UL) { return ""LESSON 04: 4/4 FULL BOARD (96 INCHES)""; } return ""UNKNOWN LESSON""; }", Success);
      Emit_Line ("public static long ALB_MiterLessons_GetMaxFrames(ulong id) { return 600; }", Success);
      Emit_Line ("public static long ALB_MiterLessons_GetSawPos(ulong id, long frame) { long pos = 1536; long target = 1536; if (id == 1UL) { target = 384; } if (id == 2UL) { target = 768; } if (id == 3UL) { target = 1152; } if (id == 4UL) { target = 1536; } long travel = 1536 - target; if (frame > 150 && frame <= 300) { pos = 1536 - (((frame - 150) * travel) / 150); } if (frame > 300) { pos = target; } return pos; }", Success);
      Emit_Line ("public static string ALB_MiterLessons_GetSubtitle(ulong id, long frame) { if (id == 1UL) { if (frame < 150) { return ""Welcome! Let's make a 1/4 cut.""; } if (frame < 300) { return ""Moving the blade to the 24-inch mark.""; } if (frame < 450) { return ""Perfectly aligned at 24 inches (1/4).""; } return ""Plunge the blade to complete the 1/4 cut.""; } if (id == 2UL) { if (frame < 150) { return ""Welcome! Let's make a 2/4 cut.""; } if (frame < 300) { return ""Moving the blade to the 48-inch mark.""; } if (frame < 450) { return ""Perfectly aligned at 48 inches (2/4).""; } return ""Plunge the blade to complete the 2/4 cut.""; } if (id == 3UL) { if (frame < 150) { return ""Welcome! Let's make a 3/4 cut.""; } if (frame < 300) { return ""Moving the blade to the 72-inch mark.""; } if (frame < 450) { return ""Perfectly aligned at 72 inches (3/4).""; } return ""Plunge the blade to complete the 3/4 cut.""; } if (id == 4UL) { if (frame < 150) { return ""Welcome! Let's make a 4/4 cut.""; } if (frame < 300) { return ""Moving the blade to the 96-inch mark.""; } if (frame < 450) { return ""Perfectly aligned at 96 inches (4/4).""; } return ""Plunge the blade to complete the 4/4 cut.""; } return """"; }", Success);
      Emit_Line ("public static void ALB_Assign(long value) { ALB_PushAssignLong(value); }", Success);
      Emit_Line ("public static void ALB_Assign(ulong value) { ALB_PushAssignULong(value); }", Success);
      Emit_Line ("public static void ALB_Assign(uint value) { ALB_PushAssignULong(value); }", Success);
      Emit_Line ("public static void ALB_Assign(double value) { ALB_PushAssignDouble(value); }", Success);
      Emit_Line ("public static void ALB_Assign(bool value) { ALB_PushAssignBool(value); }", Success);
      Emit_Line ("public static void ALB_Assign(string value) { ALB_PushAssignString(value); }", Success);
      Emit_Line ("public static void ALB_Assign(Pure128 value) { ALB_PushAssignPure(value); }", Success);
      Emit_Line ("public static void ALB_Assign(ALB_U128 value) { ALB_PushAssignU128(value); }", Success);
      Emit_Line ("public static ulong ALB_Open(string path, string mode)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (string.IsNullOrEmpty(path)) { ALB_LastError = ""open: empty path""; return 0UL; }", Success);
      Emit_Line ("string lower = mode == null ? ""r"" : mode.ToLowerInvariant();", Success);
      Emit_Line ("FileMode fileMode = FileMode.Open;", Success);
      Emit_Line ("FileAccess access = FileAccess.Read;", Success);
      Emit_Line ("if (lower.Contains(""w"")) { fileMode = FileMode.Create; access = FileAccess.Write; } else if (lower.Contains(""a"")) { fileMode = FileMode.Append; access = FileAccess.Write; } else if (lower.Contains(""+"")) { fileMode = FileMode.OpenOrCreate; access = FileAccess.ReadWrite; }", Success);
      Emit_Line ("for (int i = 0; i < ALB_MaxFiles; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (!ALB_FileTable[i].Active)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("try", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("FileStream stream = new FileStream(path, fileMode, access, FileShare.ReadWrite);", Success);
      Emit_Line ("ulong handle = ALB_NextHandle; ALB_NextHandle += 1UL;", Success);
      Emit_Line ("ALB_FileTable[i].Active = true;", Success);
      Emit_Line ("ALB_FileTable[i].CanRead = (access & FileAccess.Read) != 0;", Success);
      Emit_Line ("ALB_FileTable[i].CanWrite = (access & FileAccess.Write) != 0;", Success);
      Emit_Line ("ALB_FileTable[i].Handle = handle;", Success);
      Emit_Line ("ALB_FileTable[i].Stream = stream;", Success);
      Emit_Line ("ALB_LastError = """";", Success);
      Emit_Line ("return handle;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("catch (Exception ex) { ALB_LastError = ex.Message; return 0UL; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("ALB_LastError = ""open: file table exhausted"";", Success);
      Emit_Line ("return 0UL;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static ulong ALB_FileLen(string path)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("try { if (string.IsNullOrEmpty(path) || !File.Exists(path)) return 0UL; return (ulong)new FileInfo(path).Length; } catch { return 0UL; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static ulong ALB_Seek(ulong handle, ulong offset)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int slot = ALB_FindFileSlot(handle);", Success);
      Emit_Line ("if (slot < 0 || ALB_FileTable[slot].Stream == null) { ALB_LastError = ""seek: invalid handle""; return 0UL; }", Success);
      Emit_Line ("try { ALB_FileTable[slot].Stream.Seek((long)offset, SeekOrigin.Begin); ALB_LastError = """"; return (ulong)ALB_FileTable[slot].Stream.Position; } catch (Exception ex) { ALB_LastError = ex.Message; return 0UL; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static long ALB_Read(ulong handle, long count)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int slot = ALB_FindFileSlot(handle);", Success);
      Emit_Line ("if (slot < 0 || ALB_FileTable[slot].Stream == null || !ALB_FileTable[slot].CanRead) { ALB_LastError = ""read: invalid handle""; return 0; }", Success);
      Emit_Line ("int want = count <= 0 ? 8 : (count > 8 ? 8 : (int)count);", Success);
      Emit_Line ("Array.Clear(ALB_NumberScratch, 0, ALB_NumberScratch.Length);", Success);
      Emit_Line ("int read = ALB_FileTable[slot].Stream.Read(ALB_NumberScratch, 0, want);", Success);
      Emit_Line ("ulong value = 0UL;", Success);
      Emit_Line ("for (int i = 0; i < read; i += 1) { value |= ((ulong)ALB_NumberScratch[i]) << (i * 8); }", Success);
      Emit_Line ("ALB_LastError = """";", Success);
      Emit_Line ("return unchecked((long)value);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static string ALB_ReadText(ulong handle, long count)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int slot = ALB_FindFileSlot(handle);", Success);
      Emit_Line ("if (slot < 0 || ALB_FileTable[slot].Stream == null || !ALB_FileTable[slot].CanRead) { ALB_LastError = ""read: invalid handle""; return """"; }", Success);
      Emit_Line ("int want = count <= 0 ? ALB_FileScratchBytes : (count > ALB_FileScratchBytes ? ALB_FileScratchBytes : (int)count);", Success);
      Emit_Line ("int read = ALB_FileTable[slot].Stream.Read(ALB_FileScratch, 0, want);", Success);
      Emit_Line ("ALB_LastError = """";", Success);
      Emit_Line ("return read <= 0 ? """" : System.Text.Encoding.UTF8.GetString(ALB_FileScratch, 0, read);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Write(ulong handle, string data)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int slot = ALB_FindFileSlot(handle);", Success);
      Emit_Line ("if (slot < 0 || ALB_FileTable[slot].Stream == null || !ALB_FileTable[slot].CanWrite) { ALB_LastError = ""write: invalid handle""; return; }", Success);
      Emit_Line ("string text = data ?? """";", Success);
      Emit_Line ("for (int i = 0; i < text.Length; i += 1) { ALB_FileTable[slot].Stream.WriteByte((byte)text[i]); }", Success);
      Emit_Line ("ALB_FileTable[slot].Stream.Flush();", Success);
      Emit_Line ("ALB_LastError = """";", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Write(ulong handle, long data)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int slot = ALB_FindFileSlot(handle);", Success);
      Emit_Line ("if (slot < 0 || ALB_FileTable[slot].Stream == null || !ALB_FileTable[slot].CanWrite) { ALB_LastError = ""write: invalid handle""; return; }", Success);
      Emit_Line ("int pos = ALB_NumberScratch.Length;", Success);
      Emit_Line ("long value = data;", Success);
      Emit_Line ("bool neg = value < 0;", Success);
      Emit_Line ("ulong mag = neg ? unchecked((ulong)(0 - value)) : unchecked((ulong)value);", Success);
      Emit_Line ("if (mag == 0UL) { ALB_NumberScratch[--pos] = (byte)'0'; } else { while (mag > 0UL && pos > 0) { ulong digit = mag % 10UL; ALB_NumberScratch[--pos] = (byte)('0' + digit); mag /= 10UL; } }", Success);
      Emit_Line ("if (neg && pos > 0) { ALB_NumberScratch[--pos] = (byte)'-'; }", Success);
      Emit_Line ("ALB_FileTable[slot].Stream.Write(ALB_NumberScratch, pos, ALB_NumberScratch.Length - pos);", Success);
      Emit_Line ("ALB_FileTable[slot].Stream.Flush();", Success);
      Emit_Line ("ALB_LastError = """";", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Close(ulong handle)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int slot = ALB_FindFileSlot(handle);", Success);
      Emit_Line ("if (slot < 0) { ALB_LastError = ""close: invalid handle""; return; }", Success);
      Emit_Line ("if (ALB_FileTable[slot].Stream != null) { ALB_FileTable[slot].Stream.Flush(); ALB_FileTable[slot].Stream.Dispose(); }", Success);
      Emit_Line ("ALB_FileTable[slot] = default(ALB_FileSlot);", Success);
      Emit_Line ("ALB_LastError = """";", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static string ALB_LoadTextBuffer(string path) { string data = """"; ulong handle = ALB_Open(path, ""r""); if (handle != 0UL) { data = ALB_ReadText(handle, 0); ALB_Close(handle); } return data; }", Success);
      Emit_Line ("private static bool ALB_TryParseBufferItem(string text, Type elementType, out object value)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("string item = text == null ? ""0"" : text.Trim();", Success);
      Emit_Line ("value = 0L;", Success);
      Emit_Line ("if (elementType == typeof(byte)) { byte parsed; if (byte.TryParse(item, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out parsed)) { value = parsed; return true; } value = (byte)0; return false; }", Success);
      Emit_Line ("if (elementType == typeof(ushort)) { ushort parsed; if (ushort.TryParse(item, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out parsed)) { value = parsed; return true; } value = (ushort)0; return false; }", Success);
      Emit_Line ("if (elementType == typeof(uint)) { uint parsed; if (uint.TryParse(item, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out parsed)) { value = parsed; return true; } value = 0U; return false; }", Success);
      Emit_Line ("if (elementType == typeof(ulong)) { ulong parsed; if (ulong.TryParse(item, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out parsed)) { value = parsed; return true; } value = 0UL; return false; }", Success);
      Emit_Line ("if (elementType == typeof(long)) { long parsed; if (long.TryParse(item, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out parsed)) { value = parsed; return true; } value = 0L; return false; }", Success);
      Emit_Line ("if (elementType == typeof(double)) { double parsed; if (double.TryParse(item, System.Globalization.NumberStyles.Float | System.Globalization.NumberStyles.AllowThousands, System.Globalization.CultureInfo.InvariantCulture, out parsed)) { value = parsed; return true; } value = 0.0; return false; }", Success);
      Emit_Line ("if (elementType == typeof(bool)) { if (string.Equals(item, ""true"", StringComparison.OrdinalIgnoreCase) || item == ""1"") { value = true; return true; } if (string.Equals(item, ""false"", StringComparison.OrdinalIgnoreCase) || item == ""0"") { value = false; return true; } value = false; return false; }", Success);
      Emit_Line ("if (elementType == typeof(string)) { value = item; return true; }", Success);
      Emit_Line ("return false;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_LoadBuffer(string path, string target) { ALB_TrySetNamedString(target, ALB_LoadTextBuffer(path)); }", Success);
      Emit_Line ("public static void ALB_LoadBuffer(string path, ref string target) { target = ALB_LoadTextBuffer(path); }", Success);
      Emit_Line ("public static void ALB_LoadBuffer(string path, Array target)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (target == null) { return; }", Success);
      Emit_Line ("string data = ALB_LoadTextBuffer(path);", Success);
      Emit_Line ("if (string.IsNullOrEmpty(data)) { return; }", Success);
      Emit_Line ("Type elementType = target.GetType().GetElementType();", Success);
      Emit_Line ("if (elementType == null) { return; }", Success);
      Emit_Line ("string[] items = data.Split(',');", Success);
      Emit_Line ("int limit = items.Length < target.Length ? items.Length : target.Length;", Success);
      Emit_Line ("for (int i = 0; i < limit; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("object parsed;", Success);
      Emit_Line ("if (ALB_TryParseBufferItem(items[i], elementType, out parsed)) { target.SetValue(parsed, i); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_FlushBuffer(string data, string path) { ulong handle = ALB_Open(path, ""w""); if (handle != 0UL) { ALB_Write(handle, data == null ? """" : data); ALB_Close(handle); } }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(long data, string path) { ALB_FlushBuffer(data.ToString(System.Globalization.CultureInfo.InvariantCulture), path); }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(ulong data, string path) { ALB_FlushBuffer(data.ToString(System.Globalization.CultureInfo.InvariantCulture), path); }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(uint data, string path) { ALB_FlushBuffer(data.ToString(System.Globalization.CultureInfo.InvariantCulture), path); }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(ushort data, string path) { ALB_FlushBuffer(data.ToString(System.Globalization.CultureInfo.InvariantCulture), path); }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(byte data, string path) { ALB_FlushBuffer(data.ToString(System.Globalization.CultureInfo.InvariantCulture), path); }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(double data, string path) { ALB_FlushBuffer(data.ToString(System.Globalization.CultureInfo.InvariantCulture), path); }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(bool data, string path) { ALB_FlushBuffer(data ? ""1"" : ""0"", path); }", Success);
      Emit_Line ("public static void ALB_FlushBuffer(Array data, string path)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ulong handle = ALB_Open(path, ""w"");", Success);
      Emit_Line ("if (handle == 0UL) { return; }", Success);
      Emit_Line ("System.Text.StringBuilder builder = new System.Text.StringBuilder();", Success);
      Emit_Line ("if (data != null)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("for (int i = 0; i < data.Length; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (i > 0) { builder.Append(','); }", Success);
      Emit_Line ("object item = data.GetValue(i);", Success);
      Emit_Line ("if (item == null) { builder.Append('0'); }", Success);
      Emit_Line ("else if (item is IFormattable formattable) { builder.Append(formattable.ToString(null, System.Globalization.CultureInfo.InvariantCulture)); }", Success);
      Emit_Line ("else { builder.Append(item.ToString()); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("ALB_Write(handle, builder.ToString());", Success);
      Emit_Line ("ALB_Close(handle);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_FlushBuffer(byte[] data, string path, long byteCount)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (data == null || byteCount <= 0L) { return; }", Success);
      Emit_Line ("int count = (int)Math.Min((long)data.Length, byteCount);", Success);
      Emit_Line ("if (count <= 0) { return; }", Success);
      Emit_Line ("System.IO.File.WriteAllBytes(path, data.AsSpan(0, count).ToArray());", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static long ALB_Peek(long address)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (address >= ALB_TimelineAddressBase)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Timeline_Address_Dispatch (False, Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("return ALB_ReadMemory64(address);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static long ALB_Deref(long address) { return ALB_Peek(address); }", Success);
      Emit_Line ("public static long ALB_Peek(ulong address) { return ALB_Peek(unchecked((long)address)); }", Success);
      Emit_Line ("public static long ALB_Deref(ulong address) { return ALB_Peek(unchecked((long)address)); }", Success);
      Emit_Line ("public static void ALB_Poke(long address, long value)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (address >= ALB_TimelineAddressBase)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Timeline_Address_Dispatch (True, Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("ALB_WriteMemory64(address, value);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static uint ALB_ReadPixel(long x, long y)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_Renderer == IntPtr.Zero) { return 0U; }", Success);
      Emit_Line ("SDL_Rect r = default(SDL_Rect);", Success);
      Emit_Line ("r.X = (int)ALB_MapRenderX(x); r.Y = (int)ALB_MapRenderY(y); r.W = 1; r.H = 1;", Success);
      Emit_Line ("IntPtr surfacePtr = SDL_RenderReadPixels(ALB_Renderer, ref r);", Success);
      Emit_Line ("if (surfacePtr == IntPtr.Zero) { return 0U; }", Success);
      Emit_Line ("SDL_Surface surface = Marshal.PtrToStructure<SDL_Surface>(surfacePtr);", Success);
      Emit_Line ("uint value = surface.Pixels == IntPtr.Zero ? 0U : unchecked((uint)Marshal.ReadInt32(surface.Pixels));", Success);
      Emit_Line ("SDL_DestroySurface(surfacePtr);", Success);
      Emit_Line ("return value;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static long ALB_MouseClick(long button)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("float x;", Success);
      Emit_Line ("float y;", Success);
      Emit_Line ("ALB_MouseMask = SDL_GetMouseState(out x, out y);", Success);
      Emit_Line ("ALB_MouseX = (long)x;", Success);
      Emit_Line ("ALB_MouseY = (long)y;", Success);
      Emit_Line ("ALB_UpdateInput();", Success);
      Emit_Line ("int b = button <= 0 ? 1 : (button == 1 ? 3 : (button == 2 ? 2 : (button > 31 ? 32 : (int)button + 1)));", Success);
      Emit_Line ("uint mask = 1U << (b - 1);", Success);
      Emit_Line ("return (ALB_MouseMask & mask) != 0 ? 1 : 0;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static long ALB_Claim()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("for (int i = 0; i < ALB_MaxClaimNodes; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (!ALB_ClaimNodes[i].Active)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long address = ALB_ClaimRegionStart + (i * ALB_ClaimStride);", Success);
      Emit_Line ("ALB_ClaimNodes[i].Active = true;", Success);
      Emit_Line ("ALB_ClaimNodes[i].Marked = false;", Success);
      Emit_Line ("ALB_ClaimNodes[i].Root = true;", Success);
      Emit_Line ("ALB_ClaimNodes[i].Address = address;", Success);
      Emit_Line ("ALB_ClaimNodes[i].Child1 = 0;", Success);
      Emit_Line ("ALB_ClaimNodes[i].Child2 = 0;", Success);
      Emit_Line ("ALB_WriteMemory64(address, 0);", Success);
      Emit_Line ("return address;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("ALB_LastError = ""claim: pool exhausted"";", Success);
      Emit_Line ("return 0;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Bind(long parent, long child)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int p = ALB_FindClaimIndex(parent);", Success);
      Emit_Line ("int c = ALB_FindClaimIndex(child);", Success);
      Emit_Line ("if (p < 0 || c < 0) { return; }", Success);
      Emit_Line ("if (ALB_ClaimNodes[p].Child1 == 0) { ALB_ClaimNodes[p].Child1 = child; } else { ALB_ClaimNodes[p].Child2 = child; }", Success);
      Emit_Line ("ALB_ClaimNodes[c].Root = false;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Bind(long parent, long child1, long child2) { ALB_Bind(parent, child1); ALB_Bind(parent, child2); }", Success);
      Emit_Line ("public static void ALB_Drop(long handle) { int idx = ALB_FindClaimIndex(handle); if (idx >= 0) { ALB_ClaimNodes[idx].Root = false; } }", Success);
      Emit_Line ("public static void ALB_Sweep(long count)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("for (int i = 0; i < ALB_MaxClaimNodes; i += 1) { if (ALB_ClaimNodes[i].Active) { ALB_ClaimNodes[i].Marked = false; } }", Success);
      Emit_Line ("for (int i = 0; i < ALB_MaxClaimNodes; i += 1) { if (ALB_ClaimNodes[i].Active && ALB_ClaimNodes[i].Root) { ALB_MarkClaim(i); } }", Success);
      Emit_Line ("long reclaimed = 0;", Success);
      Emit_Line ("for (int i = 0; i < ALB_MaxClaimNodes; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_ClaimNodes[i].Active && !ALB_ClaimNodes[i].Marked)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_WriteMemory64(ALB_ClaimNodes[i].Address, 0);", Success);
      Emit_Line ("ALB_ClaimNodes[i] = default(ALB_ClaimNode);", Success);
      Emit_Line ("reclaimed += 1;", Success);
      Emit_Line ("if (count > 0 && reclaimed >= count) { break; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_SaveState()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("Array.Copy(ALB_MemoryPool, ALB_MemorySnapshot, ALB_MemoryPoolBytes);", Success);
      Emit_Line ("Array.Copy(ALB_RelFacts, ALB_RelFactsSnapshot, ALB_LogicMaxFacts);", Success);
      Emit_Line ("Array.Copy(ALB_ClaimNodes, ALB_ClaimNodesSnapshot, ALB_MaxClaimNodes);", Success);
      Emit_Line ("ALB_RngStateSnapshot = ALB_RngState;", Success);
      Emit_Line ("ALB_NextHandleSnapshot = ALB_NextHandle;", Success);
      Emit_Line ("ALB_LastErrorSnapshot = ALB_LastError ?? """";", Success);
      Emit_Line ("ALB_OriginXSnapshot = ALB_OriginX;", Success);
      Emit_Line ("ALB_OriginYSnapshot = ALB_OriginY;", Success);
      Emit_Line ("ALB_ColorRSnapshot = ALB_ColorR;", Success);
      Emit_Line ("ALB_ColorGSnapshot = ALB_ColorG;", Success);
      Emit_Line ("ALB_ColorBSnapshot = ALB_ColorB;", Success);
      Emit_Line ("ALB_ColorASnapshot = ALB_ColorA;", Success);
      Emit_Line ("ALB_KnowsValueSnapshot = ALB_KnowsValue;", Success);
      Emit_Line ("ALB_CaptureUserState();", Success);
      Emit_Line ("ALB_HaveSavedState = true;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_LoadState()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (!ALB_HaveSavedState) { return; }", Success);
      Emit_Line ("Array.Copy(ALB_MemorySnapshot, ALB_MemoryPool, ALB_MemoryPoolBytes);", Success);
      Emit_Line ("Array.Copy(ALB_RelFactsSnapshot, ALB_RelFacts, ALB_LogicMaxFacts);", Success);
      Emit_Line ("Array.Copy(ALB_ClaimNodesSnapshot, ALB_ClaimNodes, ALB_MaxClaimNodes);", Success);
      Emit_Line ("ALB_RngState = ALB_RngStateSnapshot;", Success);
      Emit_Line ("ALB_NextHandle = ALB_NextHandleSnapshot;", Success);
      Emit_Line ("ALB_LastError = ALB_LastErrorSnapshot ?? """";", Success);
      Emit_Line ("ALB_OriginX = ALB_OriginXSnapshot;", Success);
      Emit_Line ("ALB_OriginY = ALB_OriginYSnapshot;", Success);
      Emit_Line ("ALB_ColorR = ALB_ColorRSnapshot;", Success);
      Emit_Line ("ALB_ColorG = ALB_ColorGSnapshot;", Success);
      Emit_Line ("ALB_ColorB = ALB_ColorBSnapshot;", Success);
      Emit_Line ("ALB_ColorA = ALB_ColorASnapshot;", Success);
      Emit_Line ("ALB_KnowsValue = ALB_KnowsValueSnapshot;", Success);
      Emit_Line ("ALB_RestoreUserState();", Success);
      Emit_Line ("ALB_ApplyColor();", Success);
      Emit_Line ("ALB_ClearAssignArgs();", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Sync() { for (int i = 0; i < ALB_MaxFiles; i += 1) { if (ALB_FileTable[i].Active && ALB_FileTable[i].Stream != null) { ALB_FileTable[i].Stream.Flush(); } } ALB_ClearAssignArgs(); }", Success);
      Emit_Line ("public static void ALB_Delay(long milliseconds) { if (milliseconds > 0) { SDL_Delay((uint)milliseconds); } }", Success);

      Emit_Line ("public static void ALB_PlaySound(string path)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_EnsureAudio();", Success);
      Emit_Line ("if (ALB_AudioStream == IntPtr.Zero || path == null || path.Length == 0) { return; }", Success);
      Emit_Line ("SDL_AudioSpec spec = default(SDL_AudioSpec);", Success);
      Emit_Line ("IntPtr data = IntPtr.Zero;", Success);
      Emit_Line ("uint len = 0;", Success);
      Emit_Line ("if (SDL_LoadWAV(path, out spec, out data, out len) && data != IntPtr.Zero && len > 0)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("SDL_PutAudioStreamData(ALB_AudioStream, data, len > int.MaxValue ? int.MaxValue : (int)len);", Success);
      Emit_Line ("SDL_ResumeAudioStreamDevice(ALB_AudioStream);", Success);
      Emit_Line ("SDL_free(data);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static int ALB_MmlNumber(string text, ref int pos, int fallback)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int value = 0;", Success);
      Emit_Line ("bool saw = false;", Success);
      Emit_Line ("while (pos < text.Length && text[pos] >= '0' && text[pos] <= '9') { saw = true; value = value * 10 + (text[pos] - '0'); pos += 1; }", Success);
      Emit_Line ("return saw ? value : fallback;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static int ALB_MmlSemitone(char c)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("switch (c)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("case 'C': return 0;", Success);
      Emit_Line ("case 'D': return 2;", Success);
      Emit_Line ("case 'E': return 4;", Success);
      Emit_Line ("case 'F': return 5;", Success);
      Emit_Line ("case 'G': return 7;", Success);
      Emit_Line ("case 'A': return 9;", Success);
      Emit_Line ("case 'B': return 11;", Success);
      Emit_Line ("default: return -1;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_QueueTone(double frequency, int durationMs)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_EnsureAudio();", Success);
      Emit_Line ("if (ALB_AudioStream == IntPtr.Zero || durationMs <= 0) { return; }", Success);
      Emit_Line ("int rate = 44100;", Success);
      Emit_Line ("int frames = (rate * durationMs) / 1000;", Success);
      Emit_Line ("if (frames <= 0 || ALB_AudioScratch == IntPtr.Zero || ALB_AudioScratchBytes <= 0) { return; }", Success);
      Emit_Line ("int maxFrames = ALB_AudioScratchBytes / 2;", Success);
      Emit_Line ("double step = (Math.PI * 2.0 * frequency) / rate;", Success);
      Emit_Line ("int done = 0;", Success);
      Emit_Line ("while (done < frames)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int chunk = frames - done;", Success);
      Emit_Line ("if (chunk > maxFrames) { chunk = maxFrames; }", Success);
      Emit_Line ("for (int i = 0; i < chunk; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("short sample = (short)(Math.Sin((done + i) * step) * 8000.0);", Success);
      Emit_Line ("Marshal.WriteInt16(ALB_AudioScratch, i * 2, sample);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("SDL_PutAudioStreamData(ALB_AudioStream, ALB_AudioScratch, chunk * 2);", Success);
      Emit_Line ("done += chunk;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("SDL_ResumeAudioStreamDevice(ALB_AudioStream);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_PlayMusic(string music)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (music == null || music.Length == 0) { return; }", Success);
      Emit_Line ("if (music.EndsWith("".wav"", StringComparison.OrdinalIgnoreCase)) { ALB_PlaySound(music); return; }", Success);
      Emit_Line ("ALB_EnsureAudio();", Success);
      Emit_Line ("if (ALB_AudioStream == IntPtr.Zero) { return; }", Success);
      Emit_Line ("SDL_ClearAudioStream(ALB_AudioStream);", Success);
      Emit_Line ("int tempo = 120;", Success);
      Emit_Line ("int octave = 4;", Success);
      Emit_Line ("int defLen = 4;", Success);
      Emit_Line ("for (int pos = 0; pos < music.Length; pos += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("char ch = char.ToUpperInvariant(music[pos]);", Success);
      Emit_Line ("if (ch == ' ' || ch == '\t' || ch == ',') { continue; }", Success);
      Emit_Line ("if (ch == 'T') { pos += 1; tempo = ALB_MmlNumber(music, ref pos, tempo); pos -= 1; if (tempo <= 0) { tempo = 120; } continue; }", Success);
      Emit_Line ("if (ch == 'O') { pos += 1; octave = ALB_MmlNumber(music, ref pos, octave); pos -= 1; if (octave < 0) { octave = 0; } if (octave > 8) { octave = 8; } continue; }", Success);
      Emit_Line ("if (ch == 'L') { pos += 1; defLen = ALB_MmlNumber(music, ref pos, defLen); pos -= 1; if (defLen <= 0) { defLen = 4; } continue; }", Success);
      Emit_Line ("if (ch == '>') { octave += 1; if (octave > 8) { octave = 8; } continue; }", Success);
      Emit_Line ("if (ch == '<') { octave -= 1; if (octave < 0) { octave = 0; } continue; }", Success);
      Emit_Line ("int semi = ALB_MmlSemitone(ch);", Success);
      Emit_Line ("if (semi >= 0 || ch == 'R' || ch == 'P')", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (semi >= 0 && pos + 1 < music.Length)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("char acc = music[pos + 1];", Success);
      Emit_Line ("if (acc == '#' || acc == '+') { semi += 1; pos += 1; } else if (acc == '-') { semi -= 1; pos += 1; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("pos += 1;", Success);
      Emit_Line ("int len = ALB_MmlNumber(music, ref pos, defLen);", Success);
      Emit_Line ("pos -= 1;", Success);
      Emit_Line ("int ms = (240000 / tempo) / (len <= 0 ? defLen : len);", Success);
      Emit_Line ("if (semi >= 0)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int midi = (octave + 1) * 12 + semi;", Success);
      Emit_Line ("double hz = 440.0 * Math.Pow(2.0, (midi - 69) / 12.0);", Success);
      Emit_Line ("ALB_QueueTone(hz, ms);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("continue;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);

      Emit_Line ("public static void ALB_SetFullscreen(bool value) { ALB_WindowFullscreen = value; if (ALB_Window != IntPtr.Zero) { SDL_SetWindowFullscreen(ALB_Window, value); ALB_UpdateOutputState(); ALB_ApplyClip(); } }", Success);
      Emit_Line ("public static void ALB_SetResizable(bool value) { ALB_WindowResizable = value; if (ALB_Window != IntPtr.Zero) { SDL_SetWindowResizable(ALB_Window, value); ALB_UpdateOutputState(); ALB_ApplyClip(); } }", Success);
      Emit_Line ("public static void ALB_SetStretchy(bool value) { ALB_Stretchy = value; ALB_UpdateOutputState(); ALB_ApplyClip(); }", Success);
      Emit_Line ("public static void ALB_SetAlpha(long channel, long value) { long v = value < 0 ? 0 : (value > 255 ? 255 : value); ALB_ColorA = (byte)v; ALB_ApplyColor(); }", Success);
      Emit_Line ("public static void ALB_SetClip(long x, long y, long width, long height) { ALB_ClipX = x; ALB_ClipY = y; ALB_ClipW = width; ALB_ClipH = height; ALB_ClipEnabled = width > 0 && height > 0; ALB_ApplyClip(); }", Success);
      Emit_Line ("public static void ALB_SetOrigin(long x, long y) { ALB_OriginX = x; ALB_OriginY = y; ALB_ApplyClip(); }", Success);
      Emit_Line ("public static void ALB_Locate() { ALB_Locate(1, 1); }", Success);
      Emit_Line ("public static void ALB_Locate(long row, long column) { try { int r = row <= 1 ? 0 : (row > short.MaxValue ? short.MaxValue : (int)(row - 1)); int c = column <= 1 ? 0 : (column > short.MaxValue ? short.MaxValue : (int)(column - 1)); Console.SetCursorPosition(c, r); } catch { } }", Success);
      Emit_Line ("public static bool ALB_Prove() { for (int i = 0; i < ALB_LogicMaxFacts; i += 1) { if (ALB_RelFacts[i].Active) { return true; } } return false; }", Success);
      Emit_Line ("public static void ALB_KnowsSet(long value) { ALB_KnowsValue = value; }", Success);
      Emit_Line ("public static long ALB_RelHas(long id, long arity, long arg1) { for (int i = 0; i < ALB_LogicMaxFacts; i += 1) { if (ALB_RelFacts[i].Active && ALB_RelFacts[i].RelId == id && ALB_RelFacts[i].Arity == arity && ALB_RelFacts[i].Arg1 == arg1) { return 1; } } return 0; }", Success);
      Emit_Line ("public static long ALB_RelFind1(long id) { for (int i = 0; i < ALB_LogicMaxFacts; i += 1) { if (ALB_RelFacts[i].Active && ALB_RelFacts[i].RelId == id) { return ALB_RelFacts[i].Arg1; } } return 0; }", Success);
      Emit_Line ("public static void ALB_RelSet(long id, long arity, long arg1, long value)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("for (int i = 0; i < ALB_LogicMaxFacts; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ALB_RelFacts[i].Active && ALB_RelFacts[i].RelId == id && ALB_RelFacts[i].Arity == arity && ALB_RelFacts[i].Arg1 == arg1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_RelFacts[i].Value = value;", Success);
      Emit_Line ("if (ALB_OnKnowsChange != null) { ALB_OnKnowsChange(id, arg1); }", Success);
      Emit_Line ("return;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("for (int i = 0; i < ALB_LogicMaxFacts; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (!ALB_RelFacts[i].Active)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_RelFacts[i].Active = true;", Success);
      Emit_Line ("ALB_RelFacts[i].RelId = id;", Success);
      Emit_Line ("ALB_RelFacts[i].Arity = arity;", Success);
      Emit_Line ("ALB_RelFacts[i].Arg1 = arg1;", Success);
      Emit_Line ("ALB_RelFacts[i].Value = value;", Success);
      Emit_Line ("if (ALB_OnKnowsChange != null) { ALB_OnKnowsChange(id, arg1); }", Success);
      Emit_Line ("return;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("ALB_RelFacts[ALB_LogicMaxFacts - 1].Active = true;", Success);
      Emit_Line ("ALB_RelFacts[ALB_LogicMaxFacts - 1].RelId = id;", Success);
      Emit_Line ("ALB_RelFacts[ALB_LogicMaxFacts - 1].Arity = arity;", Success);
      Emit_Line ("ALB_RelFacts[ALB_LogicMaxFacts - 1].Arg1 = arg1;", Success);
      Emit_Line ("ALB_RelFacts[ALB_LogicMaxFacts - 1].Value = value;", Success);
      Emit_Line ("if (ALB_OnKnowsChange != null) { ALB_OnKnowsChange(id, arg1); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_RelRetract(long id, long arity, long arg1) { for (int i = ALB_LogicMaxFacts - 1; i >= 0; i -= 1) { if (ALB_RelFacts[i].Active && ALB_RelFacts[i].RelId == id && ALB_RelFacts[i].Arity == arity && ALB_RelFacts[i].Arg1 == arg1) { ALB_RelFacts[i] = default(ALB_RelFact); if (ALB_OnKnowsChange != null) { ALB_OnKnowsChange(id, arg1); } return; } } }", Success);
      Emit_Line ("private static int ALB_RelCollectFindAll1(long id) { ALB_LastFindCount = 0; for (int i = 0; i < ALB_LogicMaxFacts; i += 1) { if (ALB_RelFacts[i].Active && (id == 0 || ALB_RelFacts[i].RelId == id)) { if (ALB_LastFindCount < ALB_LogicMaxFacts) { ALB_RelFindBuffer[(int)ALB_LastFindCount] = ALB_RelFacts[i].Arg1; ALB_LastFindCount += 1; } } } return (int)ALB_LastFindCount; }", Success);
      Emit_Line ("public static long ALB_RelFindAll1(long id, long[] target) { if (target == null) { return 0; } Array.Clear(target, 0, target.Length); int count = ALB_RelCollectFindAll1(id); int limit = count > target.Length ? target.Length : count; for (int i = 0; i < limit; i += 1) { target[i] = ALB_RelFindBuffer[i]; } return limit; }", Success);
      Emit_Line ("public static long ALB_RelFindAll1(long id, ushort[] target) { if (target == null) { return 0; } Array.Clear(target, 0, target.Length); int count = ALB_RelCollectFindAll1(id); int limit = count > target.Length ? target.Length : count; for (int i = 0; i < limit; i += 1) { target[i] = unchecked((ushort)ALB_RelFindBuffer[i]); } return limit; }", Success);
      Emit_Line ("public static long ALB_RelFindAll1(long id, uint[] target) { if (target == null) { return 0; } Array.Clear(target, 0, target.Length); int count = ALB_RelCollectFindAll1(id); int limit = count > target.Length ? target.Length : count; for (int i = 0; i < limit; i += 1) { target[i] = unchecked((uint)ALB_RelFindBuffer[i]); } return limit; }", Success);
      Emit_Line ("public static long ALB_RelFindAll1(long id, byte[] target) { if (target == null) { return 0; } Array.Clear(target, 0, target.Length); int count = ALB_RelCollectFindAll1(id); int limit = count > target.Length ? target.Length : count; for (int i = 0; i < limit; i += 1) { target[i] = unchecked((byte)ALB_RelFindBuffer[i]); } return limit; }", Success);
      Emit_Line ("public static void ALB_Throw(string message) { ALB_LastError = message ?? """"; }", Success);
      Emit_Line ("public static long ALB_ReadNumber() { string line = Console.ReadLine(); return ALB_Len(line); }", Success);
      Emit_Line ("public static void ALB_MsgBox(string message, string title) { Console.Write(""[ALBN] message ""); Console.Write(title); Console.Write("" ""); Console.WriteLine(message); }", Success);
      Emit_Line ("public static void ALB_Cease() { ALB_Running = false; }", Success);
      Emit_Line ("public static int ALB_ReadFrameLimit()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("string value = Environment.GetEnvironmentVariable(""ALBN_FRAME_LIMIT"");", Success);
      Emit_Line ("if (value == null || value.Length == 0) { return 0; }", Success);
      Emit_Line ("int result = 0;", Success);
      Emit_Line ("for (int i = 0; i < value.Length; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (value[i] < '0' || value[i] > '9') { return 0; }", Success);
      Emit_Line ("result = result * 10 + (value[i] - '0');", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("return result;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_UpdateInput()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("float x;", Success);
      Emit_Line ("float y;", Success);
      Emit_Line ("ALB_MouseMask = SDL_GetMouseState(out x, out y);", Success);
      Emit_Line ("ALB_MouseX = (long)x;", Success);
      Emit_Line ("ALB_MouseY = (long)y;", Success);
      Emit_Line ("if (ALB_ScreenW <= 0 || ALB_ScreenH <= 0 || ALB_VirtualW <= 0 || ALB_VirtualH <= 0)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_VMouseX = ALB_MouseX;", Success);
      Emit_Line ("ALB_VMouseY = ALB_MouseY;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("else if (ALB_Stretchy)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_VMouseX = (ALB_MouseX * ALB_VirtualW) / ALB_ScreenW;", Success);
      Emit_Line ("ALB_VMouseY = (ALB_MouseY * ALB_VirtualH) / ALB_ScreenH;", Success);
      Emit_Line ("if (ALB_VMouseX < 0) { ALB_VMouseX = 0; } else if (ALB_VMouseX >= ALB_VirtualW) { ALB_VMouseX = ALB_VirtualW - 1; }", Success);
      Emit_Line ("if (ALB_VMouseY < 0) { ALB_VMouseY = 0; } else if (ALB_VMouseY >= ALB_VirtualH) { ALB_VMouseY = ALB_VirtualH - 1; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("else", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_VMouseX = ALB_MouseX - ALB_ContentOffsetX;", Success);
      Emit_Line ("ALB_VMouseY = ALB_MouseY - ALB_ContentOffsetY;", Success);
      Emit_Line ("if (ALB_VMouseX < 0) { ALB_VMouseX = 0; } else if (ALB_VMouseX >= ALB_VirtualW) { ALB_VMouseX = ALB_VirtualW - 1; }", Success);
      Emit_Line ("if (ALB_VMouseY < 0) { ALB_VMouseY = 0; } else if (ALB_VMouseY >= ALB_VirtualH) { ALB_VMouseY = ALB_VirtualH - 1; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("public static void ALB_Listen()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_EnsureSDL();", Success);
      Emit_Line ("if (ALB_Window == IntPtr.Zero || ALB_Renderer == IntPtr.Zero) { ALB_CreateWindow(""ALB"", ALB_ScreenW <= 0 ? 640 : ALB_ScreenW, ALB_ScreenH <= 0 ? 480 : ALB_ScreenH); }", Success);
      Emit_Line ("int frameLimit = ALB_ReadFrameLimit();", Success);
      Emit_Line ("int frames = 0;", Success);
      Emit_Line ("while (ALB_Running)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ulong started = SDL_GetTicks();", Success);
      Emit_Line ("SDL_Event ev = default(SDL_Event);", Success);
      Emit_Line ("while (SDL_PollEvent(out ev))", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (ev.Type == SDL_EVENT_QUIT) { ALB_Running = false; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("if (!ALB_Running) { break; }", Success);
      Emit_Line ("ALB_UpdateOutputState();", Success);
      Emit_Line ("ALB_UpdateInput();", Success);
      Emit_Line ("ALB_ClearAssignArgs();", Success);
      Emit_Line ("ALB_OnTick();", Success);
      Emit_Line ("if (!ALB_Running) { break; }", Success);
      Emit_Line ("ALB_ClearAssignArgs();", Success);
      Emit_Line ("ALB_OnPaint();", Success);
      Emit_Line ("if (ALB_Renderer != IntPtr.Zero) { SDL_RenderPresent(ALB_Renderer); }", Success);
      Emit_Line ("frames += 1;", Success);
      Emit_Line ("if (frameLimit > 0 && frames >= frameLimit) { break; }", Success);
      Emit_Line ("ulong elapsed = SDL_GetTicks() - started;", Success);
      Emit_Line ("uint target = ALB_FrameMilliseconds <= 0 ? 1U : (uint)ALB_FrameMilliseconds;", Success);
      Emit_Line ("if (elapsed < target) { SDL_Delay((uint)(target - elapsed)); }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private sealed class ALB_NN_Model", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public int[] Sizes = Array.Empty<int>();", Success);
      Emit_Line ("public int[] Activations = Array.Empty<int>();", Success);
      Emit_Line ("public long[][] Weights = Array.Empty<long[]>();", Success);
      Emit_Line ("public long[][] Biases = Array.Empty<long[]>();", Success);
      Emit_Line ("public long[][] State = Array.Empty<long[]>();", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private sealed class ALB_NetSocket", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("public int Protocol;", Success);
      Emit_Line ("public int Port;", Success);
      Emit_Line ("public int BufferSize;", Success);
      Emit_Line ("public UdpClient Udp;", Success);
      Emit_Line ("public IPEndPoint LastPeer;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static readonly Dictionary<ulong, ALB_NetSocket> ALB_NetTable = new Dictionary<ulong, ALB_NetSocket>();", Success);
      Emit_Line ("private static ulong ALB_NextNetHandle = 1UL;", Success);
      Emit_Line ("private static int ALB_ArrayLength(Array arr) { return arr == null ? 0 : arr.Length; }", Success);
      Emit_Line ("private static long ALB_ArrayGetLong(Array arr, int index)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (arr == null || index < 0 || index >= arr.Length) { return 0L; }", Success);
      Emit_Line ("if (arr is byte[] a8) return a8[index];", Success);
      Emit_Line ("if (arr is ushort[] a16u) return a16u[index];", Success);
      Emit_Line ("if (arr is short[] a16) return a16[index];", Success);
      Emit_Line ("if (arr is uint[] a32u) return a32u[index];", Success);
      Emit_Line ("if (arr is int[] a32) return a32[index];", Success);
      Emit_Line ("if (arr is ulong[] a64u) return unchecked((long)a64u[index]);", Success);
      Emit_Line ("if (arr is long[] a64) return a64[index];", Success);
      Emit_Line ("return Convert.ToInt64(arr.GetValue(index));", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static void ALB_ArraySetLong(Array arr, int index, long value)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (arr == null || index < 0 || index >= arr.Length) { return; }", Success);
      Emit_Line ("if (arr is byte[] a8) { a8[index] = unchecked((byte)value); return; }", Success);
      Emit_Line ("if (arr is ushort[] a16u) { a16u[index] = unchecked((ushort)value); return; }", Success);
      Emit_Line ("if (arr is short[] a16) { a16[index] = unchecked((short)value); return; }", Success);
      Emit_Line ("if (arr is uint[] a32u) { a32u[index] = unchecked((uint)value); return; }", Success);
      Emit_Line ("if (arr is int[] a32) { a32[index] = unchecked((int)value); return; }", Success);
      Emit_Line ("if (arr is ulong[] a64u) { a64u[index] = unchecked((ulong)value); return; }", Success);
      Emit_Line ("if (arr is long[] a64) { a64[index] = value; return; }", Success);
      Emit_Line ("arr.SetValue(value, index);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static ulong ALB_MarkovPredict(double[] matrix, ulong states, ulong currentState)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (matrix == null || states == 0UL || currentState == 0UL) { return 0UL; }", Success);
      Emit_Line ("ulong row = currentState - 1UL;", Success);
      Emit_Line ("if (row >= states) { row = states - 1UL; }", Success);
      Emit_Line ("ulong bestCol = 0UL;", Success);
      Emit_Line ("double bestWeight = matrix[(int)(row * states)];", Success);
      Emit_Line ("for (ulong col = 1UL; col < states; col += 1UL)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("double weight = matrix[(int)((row * states) + col)];", Success);
      Emit_Line ("if (weight > bestWeight) { bestWeight = weight; bestCol = col; }", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("return bestCol + 1UL;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static long ALB_NN_Act(int code, long value)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("switch (code)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("case 1: return value > 0L ? value : 0L;", Success);
      Emit_Line ("case 2: return value > 0L ? 1L : 0L;", Success);
      Emit_Line ("case 3: if (value > 128L) return 1024L; if (value < -128L) return -1024L; return value * 8L;", Success);
      Emit_Line ("default: return value;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static long ALB_NN_Seed(int prevSize, int currSize, int neuronIndex, int inputIndex)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (prevSize <= 0 || currSize <= 0) return 0L;", Success);
      Emit_Line ("if (currSize == prevSize) return inputIndex == neuronIndex ? 256L : 0L;", Success);
      Emit_Line ("if (prevSize == currSize * 2)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (inputIndex == neuronIndex * 2) return 256L;", Success);
      Emit_Line ("if (inputIndex == (neuronIndex * 2) + 1) return -256L;", Success);
      Emit_Line ("return 0L;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("if (currSize > prevSize) return inputIndex == (neuronIndex % prevSize) ? 256L : 0L;", Success);
      Emit_Line ("int inputSpan = Math.Max(1, prevSize / currSize);", Success);
      Emit_Line ("int baseInput = neuronIndex * inputSpan;", Success);
      Emit_Line ("int positiveIn = Math.Min(prevSize - 1, baseInput);", Success);
      Emit_Line ("int negativeIn = Math.Min(prevSize - 1, baseInput + 1);", Success);
      Emit_Line ("if (inputSpan >= 2)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (inputIndex == positiveIn) return 256L;", Success);
      Emit_Line ("if (inputIndex == negativeIn) return -128L;", Success);
      Emit_Line ("return 0L;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("return inputIndex == positiveIn ? 256L : 0L;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static ALB_NN_Model ALB_NN_CREATE(int[] sizes, int[] activations)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_NN_Model model = new ALB_NN_Model();", Success);
      Emit_Line ("model.Sizes = sizes ?? Array.Empty<int>();", Success);
      Emit_Line ("model.Activations = activations ?? Array.Empty<int>();", Success);
      Emit_Line ("model.Weights = model.Sizes.Length <= 1 ? Array.Empty<long[]>() : new long[model.Sizes.Length - 1][];", Success);
      Emit_Line ("model.Biases = model.Sizes.Length <= 1 ? Array.Empty<long[]>() : new long[model.Sizes.Length - 1][];", Success);
      Emit_Line ("model.State = new long[model.Sizes.Length][];", Success);
      Emit_Line ("for (int layer = 0; layer < model.Sizes.Length; layer += 1) model.State[layer] = new long[Math.Max(1, model.Sizes[layer])];", Success);
      Emit_Line ("for (int layer = 1; layer < model.Sizes.Length; layer += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("int prev = Math.Max(1, model.Sizes[layer - 1]);", Success);
      Emit_Line ("int curr = Math.Max(1, model.Sizes[layer]);", Success);
      Emit_Line ("model.Weights[layer - 1] = new long[prev * curr];", Success);
      Emit_Line ("model.Biases[layer - 1] = new long[curr];", Success);
      Emit_Line ("for (int neuron = 0; neuron < curr; neuron += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("for (int inputIndex = 0; inputIndex < prev; inputIndex += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("model.Weights[layer - 1][(neuron * prev) + inputIndex] = ALB_NN_Seed(prev, curr, neuron, inputIndex);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("return model;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static void ALB_NN_INFER(ALB_NN_Model model, Array input, Array output)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (model == null || model.State.Length == 0) return;", Success);
      Emit_Line ("for (int i = 0; i < model.State[0].Length; i += 1) model.State[0][i] = ALB_ArrayGetLong(input, i);", Success);
      Emit_Line ("for (int layer = 1; layer < model.State.Length; layer += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long[] prev = model.State[layer - 1];", Success);
      Emit_Line ("long[] curr = model.State[layer];", Success);
      Emit_Line ("long[] weights = model.Weights[layer - 1];", Success);
      Emit_Line ("long[] biases = model.Biases[layer - 1];", Success);
      Emit_Line ("for (int i = 0; i < curr.Length; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long acc = biases[i];", Success);
      Emit_Line ("for (int j = 0; j < prev.Length; j += 1) acc += prev[j] * weights[(i * prev.Length) + j];", Success);
      Emit_Line ("curr[i] = ALB_NN_Act(layer < model.Activations.Length ? model.Activations[layer] : 0, acc);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("long[] outState = model.State[model.State.Length - 1];", Success);
      Emit_Line ("for (int i = 0; i < ALB_ArrayLength(output); i += 1) ALB_ArraySetLong(output, i, i < outState.Length ? outState[i] : 0L);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static void ALB_NN_TRAIN(ALB_NN_Model model, Array trainData, Array expectData, long epochs)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (model == null || model.Weights.Length == 0) return;", Success);
      Emit_Line ("int outSize = Math.Max(1, model.Sizes[model.Sizes.Length - 1]);", Success);
      Emit_Line ("int prevSize = Math.Max(1, model.Sizes[model.Sizes.Length - 2]);", Success);
      Emit_Line ("long[] output = new long[outSize];", Success);
      Emit_Line ("for (long epoch = 0; epoch < Math.Max(1L, epochs); epoch += 1L)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_NN_INFER(model, trainData, output);", Success);
      Emit_Line ("long[] prev = model.State[model.State.Length - 2];", Success);
      Emit_Line ("long[] weights = model.Weights[model.Weights.Length - 1];", Success);
      Emit_Line ("long[] biases = model.Biases[model.Biases.Length - 1];", Success);
      Emit_Line ("for (int i = 0; i < outSize; i += 1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("long got = output[i];", Success);
      Emit_Line ("long want = ALB_ArrayGetLong(expectData, i);", Success);
      Emit_Line ("long delta = got > want ? -1L : (got < want ? 1L : 0L);", Success);
      Emit_Line ("biases[i] += delta;", Success);
      Emit_Line ("for (int j = 0; j < prevSize; j += 1) if (prev[j] != 0L) weights[(i * prevSize) + j] += delta;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static ulong ALB_NET_DEFINE(long protocol, long port, long bufferSize)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ulong handle = ALB_NextNetHandle++;", Success);
      Emit_Line ("ALB_NetTable[handle] = new ALB_NetSocket { Protocol = (int)protocol, Port = (int)port, BufferSize = Math.Max(1, (int)bufferSize) };", Success);
      Emit_Line ("return handle;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static ulong ALB_NET_LISTEN_SOCKET(ulong handle, long protocol, long port, long bufferSize)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (handle == 0UL || !ALB_NetTable.ContainsKey(handle)) handle = ALB_NET_DEFINE(protocol, port, bufferSize);", Success);
      Emit_Line ("ALB_NetSocket sock = ALB_NetTable[handle];", Success);
      Emit_Line ("if (sock.Udp == null)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("sock.Udp = new UdpClient(sock.Port);", Success);
      Emit_Line ("sock.Udp.Client.ReceiveTimeout = 5000;", Success);
      Emit_Line ("sock.Udp.Client.SendTimeout = 5000;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("return handle;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static void ALB_NET_RECEIVE(ulong handle, Array dest)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (!ALB_NetTable.TryGetValue(handle, out ALB_NetSocket sock) || sock.Udp == null) return;", Success);
      Emit_Line ("IPEndPoint peer = new IPEndPoint(IPAddress.Any, 0);", Success);
      Emit_Line ("byte[] packet = sock.Udp.Receive(ref peer);", Success);
      Emit_Line ("sock.LastPeer = peer;", Success);
      Emit_Line ("int limit = Math.Min(ALB_ArrayLength(dest), packet == null ? 0 : packet.Length);", Success);
      Emit_Line ("for (int i = 0; i < limit; i += 1) ALB_ArraySetLong(dest, i, packet[i]);", Success);
      Emit_Line ("for (int i = limit; i < ALB_ArrayLength(dest); i += 1) ALB_ArraySetLong(dest, i, 0L);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static void ALB_NET_SEND(ulong handle, Array src)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (!ALB_NetTable.TryGetValue(handle, out ALB_NetSocket sock) || sock.Udp == null || sock.LastPeer == null) return;", Success);
      Emit_Line ("int count = Math.Min(ALB_ArrayLength(src), Math.Max(1, sock.BufferSize));", Success);
      Emit_Line ("byte[] payload = new byte[count];", Success);
      Emit_Line ("for (int i = 0; i < count; i += 1) payload[i] = unchecked((byte)ALB_ArrayGetLong(src, i));", Success);
      Emit_Line ("sock.Udp.Send(payload, payload.Length, sock.LastPeer);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("private static void ALB_NET_CLOSE(ref ulong handle)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (handle == 0UL) return;", Success);
      Emit_Line ("if (ALB_NetTable.TryGetValue(handle, out ALB_NetSocket sock))", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("if (sock.Udp != null) { sock.Udp.Close(); }", Success);
      Emit_Line ("ALB_NetTable.Remove(handle);", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("handle = 0UL;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);
   end Emit_Runtime_Types;

   procedure Emit_Statement
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean);

   procedure Emit_Block
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Curr : Node_Index := Node;
   begin
      if Node = 0 then
         return;
      end if;

      if Tree (Node).Kind = AST_Block_Stmt or else Tree (Node).Kind = AST_Program then
         Curr := Tree (Node).Left_Child;
      end if;

      while Curr /= 0 loop
         Emit_Statement (Tokens, Tree, Curr, Success);
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Block;

   procedure Emit_Let
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Target    : constant Node_Index := Tree (Node).Left_Child;
      RHS       : constant Node_Index := Tree (Node).Right_Child;
      Sym       : Natural := 0;
      Local_Sym : Natural := 0;
      K         : DotNet_Value_Kind := Kind_S64;
      Declare_Local : Boolean := False;
   begin
      if Target = 0 then
         return;
      end if;

      if Tree (Target).Kind = AST_Var_Expr and then Tree (Target).Left_Child = 0 then
         Local_Sym := Find_Local_Symbol (Tokens, Tree (Target).Token_Index);
      end if;

      Sym := Find_Target_Symbol (Tokens, Tree, Target);
      Declare_Local :=
        Active_Routine_Node /= 0
        and then Tree (Target).Kind = AST_Var_Expr
        and then Tree (Target).Left_Child = 0
        and then Local_Sym = 0
        and then Sym = 0;
      if Sym /= 0 and then not Declare_Local then
         K := Symbols (Sym).Kind;
      else
         K := Kind_From_Type_Token
           (Tokens,
            Tree (Node).Token_Index,
            Infer_Expression_Kind (Tokens, Tree, RHS));
      end if;

      if RHS = 0 then
         return;
      end if;

      if Declare_Local then
         Register_Local_Symbol
           (Tokens,
            Tree (Target).Token_Index,
            Tree (Node).Token_Index,
            K,
            RHS);
         Emit_Local_Declaration
           (Tokens,
            Tree,
            Tree (Target).Token_Index,
            K,
            RHS,
            Success);
      elsif Tree (Target).Kind in AST_Var_Expr | AST_Member_Expr then
         Emit_Assignment_To_Target (Tokens, Tree, Target, RHS, K, Success);
      else
         Success := Emit_Raw ("ALB_Assign(");
         Emit_Assignment_Value (Tokens, Tree, RHS, K, Success);
         if Success then
            Success := Emit_Raw (");");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      end if;
   end Emit_Let;

   procedure Emit_Print
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Curr : Node_Index := Node;
   begin
      if Curr = 0 then
         Emit_Line ("Console.WriteLine();", Success);
      else
         while Curr /= 0 loop
            Success := Emit_Raw ("Console.Write(");
            Emit_Expression
              (Tokens, Tree, Tree (Curr).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;
            Curr := Tree (Curr).Right_Child;
         end loop;
         Emit_Line ("Console.WriteLine();", Success);
      end if;
   end Emit_Print;

   procedure Emit_BinOp_Statement
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Sym : Natural := 0;
      K   : DotNet_Value_Kind := Kind_S64;
   begin
      if Tree (Node).Token_Index /= 0
        and then Tokens (Tree (Node).Token_Index).Kind = TOK_ASSIGN
      then
         Sym := Find_Target_Symbol (Tokens, Tree, Tree (Node).Left_Child);
         if Sym /= 0 then
            K := Symbols (Sym).Kind;
         else
            K := Infer_Expression_Kind
              (Tokens, Tree, Tree (Node).Right_Child);
         end if;

         if Tree (Tree (Node).Left_Child).Kind in AST_Var_Expr | AST_Member_Expr then
            Emit_Assignment_To_Target
              (Tokens, Tree, Tree (Node).Left_Child, Tree (Node).Right_Child, K, Success);
         else
            K := Infer_Expression_Kind (Tokens, Tree, Tree (Node).Right_Child);
            Success := Emit_Raw ("ALB_Assign(");
            Emit_Assignment_Value
              (Tokens, Tree, Tree (Node).Right_Child, K, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;
         end if;
      else
         Emit_Expression (Tokens, Tree, Node, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (";");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      end if;
   end Emit_BinOp_Statement;

   procedure Emit_Token_Name_Content
     (Tokens      : in Token_Array;
      Token_Index : in Natural;
      Success     : in out Boolean)
   is
      Tok : Token;
      C   : Character;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         Success := Emit_Raw ("alb_call");
         return;
      end if;

      Tok := Tokens (Token_Index);
      for Offset in 0 .. Tok.Length - 1 loop
         C := Input_Buffer (Tok.Start + Offset);
         if ((C in 'a' .. 'z') or else (C in 'A' .. 'Z') or else
             (C in '0' .. '9') or else C = '_')
         then
            Success := Emit_Raw (C & "");
         else
            Success := Emit_Raw ("_");
         end if;
         exit when not Success;
      end loop;
   end Emit_Token_Name_Content;

   procedure Emit_Call_Name_Content
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Target  : in Node_Index;
      Success : in out Boolean)
   is
   begin
      if Target = 0 then
         Success := Emit_Raw ("alb_call");
         return;
      end if;

      case Tree (Target).Kind is
         when AST_Func_Call =>
            Emit_Call_Name_Content
              (Tokens, Tree, Tree (Target).Left_Child, Success);

         when AST_Member_Expr =>
            Emit_Call_Name_Content
              (Tokens, Tree, Tree (Target).Left_Child, Success);
            if Success then
               Success := Emit_Raw (".");
            end if;
            Emit_Call_Name_Content
              (Tokens, Tree, Tree (Target).Right_Child, Success);

         when AST_Var_Expr =>
            Emit_Token_Name_Content (Tokens, Tree (Target).Token_Index, Success);

         when others =>
            Success := Emit_Raw ("alb_call");
      end case;
   end Emit_Call_Name_Content;

   procedure Emit_Call_Name_String
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Target  : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Success := Emit_Raw ("""");
      Emit_Call_Name_Content (Tokens, Tree, Target, Success);
      if Success then
         Success := Emit_Raw ("""");
      end if;
   end Emit_Call_Name_String;

   procedure Emit_Condition
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Success := Emit_Raw ("ALB_Bool(");
      Emit_Expression (Tokens, Tree, Node, Kind_Bool, Success);
      if Success then
         Success := Emit_Raw (")");
      end if;
   end Emit_Condition;

   procedure Emit_If
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Then_Block : constant Node_Index := Tree (Node).Right_Child;
      Else_Block : Node_Index := 0;
   begin
      if Then_Block /= 0
        and then Tree (Then_Block).Kind = AST_Block_Stmt
        and then Tree (Then_Block).Next_Sibling /= 0
        and then Tree (Tree (Then_Block).Next_Sibling).Kind = AST_Block_Stmt
      then
         Else_Block := Tree (Then_Block).Next_Sibling;
      end if;

      Success := Emit_Raw ("if (");
      Emit_Condition (Tokens, Tree, Tree (Node).Left_Child, Success);
      if Success then
         Success := Emit_Raw (")");
      end if;
      Emit_Line ("", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Block (Tokens, Tree, Then_Block, Success);
      Decrease_Indent;
      if Else_Block /= 0 then
         Emit_Line ("}", Success);
         Emit_Line ("else", Success);
         Emit_Line ("{", Success);
         Increase_Indent;
         Emit_Block (Tokens, Tree, Else_Block, Success);
         Decrease_Indent;
         Emit_Line ("}", Success);
      else
         Emit_Line ("}", Success);
      end if;
   end Emit_If;

   procedure Emit_While
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Success := Emit_Raw ("while (");
      Emit_Condition (Tokens, Tree, Tree (Node).Left_Child, Success);
      if Success then
         Success := Emit_Raw (")");
      end if;
      Emit_Line ("", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Block (Tokens, Tree, Tree (Node).Right_Child, Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
   end Emit_While;

   procedure Emit_Repeat
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Emit_Line ("do", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Block (Tokens, Tree, Tree (Node).Left_Child, Success);
      Decrease_Indent;
      Success := Emit_Raw ("} while (!");
      Emit_Condition (Tokens, Tree, Tree (Node).Right_Child, Success);
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Repeat;

   procedure Emit_For
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Loop_Spec  : constant Node_Index := Tree (Node).Left_Child;
      Start_Node : Node_Index := 0;
      End_Node   : Node_Index := 0;
      Step_Node  : Node_Index := 0;
      Sym        : Natural := 0;
      K          : DotNet_Value_Kind := Kind_S64;
      Id         : Natural := 0;
      Declared_Local : Boolean := False;
   begin
      if Loop_Spec /= 0 then
         Start_Node := Tree (Loop_Spec).Left_Child;
         if Tree (Loop_Spec).Right_Child /= 0 then
            if Tree (Tree (Loop_Spec).Right_Child).Kind = AST_Arg_List then
               End_Node := Tree (Tree (Loop_Spec).Right_Child).Left_Child;
               if End_Node /= 0 then
                  Step_Node := Tree (End_Node).Next_Sibling;
               end if;
            else
               End_Node := Tree (Loop_Spec).Right_Child;
            end if;
         end if;
      end if;

      Temp_Count := Temp_Count + 1;
      Id := Temp_Count;
      Sym := Find_Symbol (Tokens, Tree (Node).Token_Index);
      if Sym /= 0 then
         K := Symbols (Sym).Kind;
      elsif Active_Routine_Node /= 0 then
         Register_Local_Symbol
           (Tokens,
            Tree (Node).Token_Index,
            0,
            K,
            0);
         Declared_Local := True;
      end if;

      Emit_Line ("{", Success);
      Increase_Indent;
      Success := Emit_Raw ("long alb_for_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Emit_Expression (Tokens, Tree, Start_Node, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      Success := Emit_Raw ("long alb_end_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Emit_Expression (Tokens, Tree, End_Node, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      Success := Emit_Raw ("long alb_step_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      if Step_Node /= 0 then
         Emit_Expression (Tokens, Tree, Step_Node, Kind_S64, Success);
      else
         Success := Emit_Raw ("1");
      end if;
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      if Declared_Local then
         Emit_CSharp_Type (K, Success);
         if Success then
            Success := Emit_Raw (" ");
         end if;
         Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
         if Success then
            Success := Emit_Raw (" = ");
         end if;
         Emit_Assignment_Cast_Open (K, Success);
         if Success then
            Success := Emit_Raw ("alb_for_");
         end if;
         Emit_Natural (Id, Success);
         Emit_Assignment_Cast_Close (K, Success);
         if Success then
            Success := Emit_Raw (";");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      end if;

      Success := Emit_Raw ("for (; alb_step_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" >= 0 ? alb_for_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" <= alb_end_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" : alb_for_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" >= alb_end_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw ("; alb_for_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" += alb_step_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (")");
      end if;
      Emit_Line ("", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      if Needs_Assignment_Cast (K) then
         if K in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
            Success := Emit_Raw ("unchecked((");
         else
            Success := Emit_Raw ("(");
         end if;
         Emit_CSharp_Type (K, Success);
         if Success then
            Success := Emit_Raw (")(alb_for_");
         end if;
         Emit_Natural (Id, Success);
         if Success and then K in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
            Success := Emit_Raw ("))");
         elsif Success then
            Success := Emit_Raw (")");
         end if;
      else
         Success := Emit_Raw ("alb_for_");
         Emit_Natural (Id, Success);
      end if;
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
      Emit_Block (Tokens, Tree, Tree (Node).Right_Child, Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
   end Emit_For;

   procedure Emit_Foreach
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Seq_Node : constant Node_Index := Tree (Node).Left_Child;
      Sym      : Natural := 0;
      Item_K   : DotNet_Value_Kind := Kind_S64;
      Id       : Natural := 0;
      Saved_Symbol_Count : constant Natural := Symbol_Count;
   begin
      if Seq_Node /= 0 then
         Sym := Find_Target_Symbol (Tokens, Tree, Seq_Node);
      end if;
      if Sym /= 0 then
         Item_K := Symbols (Sym).Kind;
      end if;

      Temp_Count := Temp_Count + 1;
      Id := Temp_Count;

      Emit_Line ("{", Success);
      Increase_Indent;
      Success := Emit_Raw ("for (int alb_foreach_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" = 0; alb_foreach_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" < ");
      end if;
      if Sym /= 0 and then Symbols (Sym).Shape = Shape_Slide_Array then
         Emit_Name_Text
           (Symbols (Sym).Emit_Name,
            Symbols (Sym).Emit_Name_Len,
            Success);
         if Success then
            Success := Emit_Raw ("_active");
         end if;
      elsif Sym /= 0 then
         Emit_Name_Text
           (Symbols (Sym).Emit_Name,
            Symbols (Sym).Emit_Name_Len,
            Success);
         if Success then
            Success := Emit_Raw (".Length");
         end if;
      else
         Success := Emit_Raw ("0");
      end if;
      if Success then
         Success := Emit_Raw ("; alb_foreach_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" += 1)");
      end if;
      Emit_Line ("", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_CSharp_Type (Item_K, Success);
      if Success then
         Success := Emit_Raw (" ");
      end if;
      Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      if Sym /= 0 then
         Emit_Name_Text
           (Symbols (Sym).Emit_Name,
            Symbols (Sym).Emit_Name_Len,
            Success);
         if Success then
            Success := Emit_Raw ("[alb_foreach_");
         end if;
         Emit_Natural (Id, Success);
         if Success then
            Success := Emit_Raw ("];");
         end if;
      else
         Emit_Default_Value (Item_K, Success);
         if Success then
            Success := Emit_Raw (";");
         end if;
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
      if Active_Routine_Node /= 0 and then Tree (Node).Token_Index /= 0 then
         Register_Local_Symbol
           (Tokens,
            Tree (Node).Token_Index,
            0,
            Item_K,
            0,
            Allow_Shadow => True);
      end if;
      Emit_Block (Tokens, Tree, Tree (Node).Right_Child, Success);
      Symbol_Count := Saved_Symbol_Count;
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
   end Emit_Foreach;

   procedure Emit_Call_Statement
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Target     : constant Node_Index := Tree (Node).Left_Child;
      Call_Node  : Node_Index := Target;
      Name_Node  : Node_Index := 0;
      Args_Node  : Node_Index := 0;
      Module_Node : Node_Index := 0;
      Member_Node : Node_Index := 0;
      Routine    : Natural := 0;
   begin
      if Target /= 0 and then Tree (Target).Kind = AST_Func_Call then
         Name_Node := Tree (Target).Left_Child;
         Args_Node := Tree (Target).Right_Child;
         Call_Node := Name_Node;

         if Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Member_Expr then
            Routine := Find_Member_Routine (Tokens, Tree, Name_Node);
            if Routine /= 0 then
               Emit_Routine_Name (Tokens, Tree, Routine, Success);
               if Success then
                  Success := Emit_Raw ("(");
               end if;
               Emit_Arg_List_For_Routine
                 (Tokens, Tree, Args_Node, Routine, Success);
               if Success then
                  Success := Emit_Raw (");" & ASCII.LF);
               end if;
               return;
            end if;

            Module_Node := Tree (Name_Node).Left_Child;
            Member_Node := Tree (Name_Node).Right_Child;
            if Module_Node /= 0 and then Member_Node /= 0
              and then Tree (Module_Node).Kind = AST_Var_Expr
              and then Tree (Member_Node).Kind = AST_Var_Expr
            then
               Success := Emit_Raw ("ALB_");
               Emit_Token_Name_Content (Tokens, Tree (Module_Node).Token_Index, Success);
               if Success then
                  Success := Emit_Raw ("_");
               end if;
               Emit_Token_Name_Content (Tokens, Tree (Member_Node).Token_Index, Success);
               if Success then
                  Success := Emit_Raw ("(");
               end if;
               Emit_Arg_List (Tokens, Tree, Args_Node, Success);
               if Success then
                  Success := Emit_Raw (");" & ASCII.LF);
               end if;
               return;
            end if;
         end if;

         if Name_Node /= 0 and then Tree (Name_Node).Kind = AST_Var_Expr then
            Routine := Find_Visible_Routine (Tokens, Tree (Name_Node).Token_Index);
         end if;

         if Routine /= 0 then
            Emit_Routine_Name (Tokens, Tree, Routine, Success);
            if Success then
               Success := Emit_Raw ("(");
            end if;
            Emit_Arg_List_For_Routine
              (Tokens, Tree, Args_Node, Routine, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;
         else
            Success := Emit_Raw ("ALB_Call(");
            Emit_Call_Name_String (Tokens, Tree, Call_Node, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;
         end if;
      else
         Success := Emit_Raw ("ALB_Call(");
         Emit_Call_Name_String (Tokens, Tree, Target, Success);
         if Success then
            Success := Emit_Raw (");");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      end if;
   end Emit_Call_Statement;

   procedure Emit_Create_Window
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Pair_Node    : constant Node_Index := Tree (Node).Right_Child;
      Width_Node   : constant Node_Index :=
        (if Pair_Node /= 0 then Tree (Pair_Node).Left_Child else 0);
      Height_Node  : constant Node_Index :=
        (if Pair_Node /= 0 then Tree (Pair_Node).Right_Child else 0);
      Width_Value  : constant Static_S64_Result :=
        Try_Eval_Static_S64 (Tokens, Tree, Width_Node);
      Height_Value : constant Static_S64_Result :=
        Try_Eval_Static_S64 (Tokens, Tree, Height_Node);
   begin
      Success := Emit_Raw ("ALB_ScreenW = (long)(");
      if Width_Value.Success then
         Emit_S64 (Width_Value.Value, Success);
      elsif Width_Node /= 0 then
         Emit_Expression (Tokens, Tree, Width_Node, Kind_S64, Success);
      else
         Success := Emit_Raw ("0");
      end if;
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      if not Success then
         return;
      end if;

      Success := Emit_Raw ("ALB_ScreenH = (long)(");
      if Height_Value.Success then
         Emit_S64 (Height_Value.Value, Success);
      elsif Height_Node /= 0 then
         Emit_Expression (Tokens, Tree, Height_Node, Kind_S64, Success);
      else
         Success := Emit_Raw ("0");
      end if;
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      if not Success then
         return;
      end if;

      Success := Emit_Raw ("ALB_CreateWindow(");
      Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
      if Success then
         Success := Emit_Raw (", ALB_ScreenW, ALB_ScreenH);");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Create_Window;

   procedure Emit_Color_Call
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Name    : in String;
      Success : in out Boolean)
   is
   begin
      Success := Emit_Raw (Name & "((long)(");
      Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
      if Success then
         Success := Emit_Raw ("));");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Color_Call;

   procedure Emit_Draw_Text
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Args  : Node_Index := 0;
      X     : Node_Index := 0;
      Y     : Node_Index := 0;
      Text  : Node_Index := 0;
   begin
      if Tree (Node).Left_Child /= 0
        and then Tree (Tree (Node).Left_Child).Kind = AST_Arg_List
      then
         Args := Tree (Tree (Node).Left_Child).Left_Child;
      end if;

      X := Args;
      if X /= 0 then
         Y := Tree (X).Next_Sibling;
      end if;
      if Y /= 0 then
         Text := Tree (Y).Next_Sibling;
      end if;

      Success := Emit_Raw ("ALB_DrawText((long)(");
      Emit_Expression (Tokens, Tree, X, Kind_S64, Success);
      if Success then
         Success := Emit_Raw ("), (long)(");
      end if;
      Emit_Expression (Tokens, Tree, Y, Kind_S64, Success);
      if Success then
         Success := Emit_Raw ("), ");
      end if;
      Emit_Expression (Tokens, Tree, Text, Kind_String, Success);
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Draw_Text;

   procedure Emit_Draw_Primitive
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Arg : Node_Index := 0;
   begin
      Success := Emit_Raw ("ALB_Draw(");
      if Tree (Node).Kind = AST_Plot then
         Success := Emit_Raw ("""PLOT""");
      elsif Tree (Node).Token_Index /= 0 then
         case Tokens (Tree (Node).Token_Index).Kind is
            when Tok_Rect =>
               if Tree (Node).Kind = AST_Fill then
                  Success := Emit_Raw ("""FILL_RECT""");
               else
                  Success := Emit_Raw ("""RECT""");
               end if;
            when Tok_Line =>
               Success := Emit_Raw ("""LINE""");
            when Tok_Circle =>
               if Tree (Node).Kind = AST_Fill then
                  Success := Emit_Raw ("""FILL_CIRCLE""");
               else
                  Success := Emit_Raw ("""CIRCLE""");
               end if;
            when Tok_Triangle =>
               if Tree (Node).Kind = AST_Fill then
                  Success := Emit_Raw ("""FILL_TRIANGLE""");
               else
                  Success := Emit_Raw ("""TRIANGLE""");
               end if;
            when others =>
               Success := Emit_Raw ("""DRAW""");
         end case;
      else
         Success := Emit_Raw ("""DRAW""");
      end if;

      Arg := First_Arg (Tree, Tree (Node).Left_Child);
      for I in 1 .. 6 loop
         if Success then
            Success := Emit_Raw (", ");
         end if;
         if Arg /= 0 then
            Emit_Expression (Tokens, Tree, Arg, Kind_S64, Success);
            Arg := Next_Arg (Tree, Arg);
         else
            Success := Emit_Raw ("0");
         end if;
      end loop;

      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Draw_Primitive;

   procedure Emit_Runtime_Arg_List_Call
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Name    : in String;
      Args    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Success := Emit_Raw (Name & "(");
      Emit_Arg_List (Tokens, Tree, Args, Success);
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Runtime_Arg_List_Call;

   procedure Emit_Read_Input_Value
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean)
   is
   begin
      case Kind is
         when Kind_String =>
            Success := Emit_Raw ("Console.ReadLine()");
         when Kind_Bool =>
            Success := Emit_Raw ("ALB_ReadNumber() != 0");
         when Kind_Pure =>
            Success := Emit_Raw ("default(Pure128)");
         when Kind_U128 =>
            Success := Emit_Raw ("default(ALB_U128)");
         when Kind_F64 =>
            Success := Emit_Raw ("(double)(ALB_ReadNumber())");
         when Kind_F32x2 | Kind_F32x4 | Kind_Mat2x2 |
              Kind_Mat3x3 | Kind_Mat4x4 =>
            Success := Emit_Raw ("default(");
            Emit_CSharp_Type (Kind, Success);
            if Success then
               Success := Emit_Raw (")");
            end if;
         when Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 =>
            Success := Emit_Raw ("unchecked((");
            Emit_CSharp_Type (Kind, Success);
            if Success then
               Success := Emit_Raw (")(ALB_ReadNumber()))");
            end if;
         when others =>
            Success := Emit_Raw ("ALB_ReadNumber()");
      end case;
   end Emit_Read_Input_Value;

   procedure Emit_Input
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Target  : in Node_Index;
      Success : in out Boolean)
   is
      Sym : Natural := 0;
      K   : DotNet_Value_Kind := Kind_String;
   begin
      if Tree (Node).Left_Child /= 0 then
         Success := Emit_Raw ("Console.Write(");
         Emit_Expression
           (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
         if Success then
            Success := Emit_Raw (");");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      end if;

      if Target /= 0 and then Tree (Target).Kind in AST_Var_Expr | AST_Member_Expr then
         Sym := Find_Target_Symbol (Tokens, Tree, Target);
         if Sym /= 0 then
            K := Symbols (Sym).Kind;
         end if;

         Emit_Target (Tokens, Tree, Target, Success);
         if Success then
            Success := Emit_Raw (" = ");
         end if;
         Emit_Read_Input_Value (K, Success);
         if Success then
            Success := Emit_Raw (";");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      else
         Emit_Line ("Console.ReadLine();", Success);
      end if;
   end Emit_Input;

   procedure Emit_File_Write
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Success := Emit_Raw ("ALB_Write((ulong)(");
      Emit_Expression
        (Tokens, Tree, Tree (Node).Left_Child, Kind_U64, Success);
      if Success then
         Success := Emit_Raw ("), ");
      end if;
      Emit_Expression
        (Tokens, Tree, Tree (Node).Right_Child, Kind_String, Success);
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_File_Write;

   procedure Emit_File_Close
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      Success := Emit_Raw ("ALB_Close((ulong)(");
      Emit_Expression
        (Tokens, Tree, Tree (Node).Left_Child, Kind_U64, Success);
      if Success then
         Success := Emit_Raw ("));");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_File_Close;

   procedure Emit_Load_Or_Flush
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Target_Sym : Natural := 0;
   begin
      if Tree (Node).Kind = AST_Load_Stmt then
         if Tree (Node).Right_Child /= 0 then
            Target_Sym := Find_Target_Symbol
              (Tokens, Tree, Tree (Node).Right_Child);
         end if;

         if Target_Sym /= 0
           and then Symbols (Target_Sym).Shape in Shape_Strict_Array | Shape_Slide_Array
         then
            Success := Emit_Raw ("ALB_LoadBuffer(");
            if Success then
               Emit_Expression
                 (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            end if;
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Target (Tokens, Tree, Tree (Node).Right_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
         elsif Target_Sym /= 0 and then Symbols (Target_Sym).Kind = Kind_String then
            Success := Emit_Raw ("ALB_LoadBuffer(");
            if Success then
               Emit_Expression
                 (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            end if;
            if Success then
               Success := Emit_Raw (", ref ");
            end if;
            Emit_Target (Tokens, Tree, Tree (Node).Right_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
         elsif Target_Sym /= 0 then
            Emit_Target (Tokens, Tree, Tree (Node).Right_Child, Success);
            if Success then
               Success := Emit_Raw (" = ALB_LoadTextBuffer(");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
         else
            Emit_Line ("ALB_Assign(ALB_LoadTextBuffer(""""));", Success);
            return;
         end if;
      else
         if Tree (Node).Left_Child /= 0 then
            Target_Sym := Find_Target_Symbol
              (Tokens, Tree, Tree (Node).Left_Child);
         end if;

         Success := Emit_Raw ("ALB_FlushBuffer(");
         if Target_Sym /= 0
           and then Symbols (Target_Sym).Shape in Shape_Strict_Array | Shape_Slide_Array
         then
            Emit_Target (Tokens, Tree, Tree (Node).Left_Child, Success);
         else
            Emit_Expression
              (Tokens,
               Tree,
               Tree (Node).Left_Child,
               Infer_Expression_Kind (Tokens, Tree, Tree (Node).Left_Child),
               Success);
         end if;
         if Success then
            Success := Emit_Raw (", ");
         end if;
         Emit_Expression
           (Tokens, Tree, Tree (Node).Right_Child, Kind_String, Success);
         if Success and then Tree (Tree (Node).Left_Child).Next_Sibling > 0 then
            Success := Emit_Raw (", ");
            Emit_Expression
              (Tokens,
               Tree,
               Tree (Tree (Node).Left_Child).Next_Sibling,
               Kind_U64,
               Success);
         end if;
         if Success then
            Success := Emit_Raw (");");
         end if;
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Load_Or_Flush;

   procedure Emit_Match_Select
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Case_Node : Node_Index := Tree (Node).Right_Child;
      First     : Boolean := True;
   begin
      while Case_Node /= 0 loop
         if Tree (Case_Node).Left_Child = 0 then
            if First then
               Emit_Line ("{", Success);
            else
               Emit_Line ("else", Success);
               Emit_Line ("{", Success);
            end if;
         else
            if First then
               Success := Emit_Raw ("if (ALB_Num(");
            else
               Success := Emit_Raw ("else if (ALB_Num(");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (") == ALB_Num(");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Case_Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw ("))");
            end if;
            Emit_Line ("", Success);
            Emit_Line ("{", Success);
         end if;

         Increase_Indent;
         Emit_Block (Tokens, Tree, Tree (Case_Node).Right_Child, Success);
         Decrease_Indent;
         Emit_Line ("}", Success);
         First := False;
         Case_Node := Tree (Case_Node).Next_Sibling;
      end loop;
   end Emit_Match_Select;

   procedure Emit_SwapPop
     (Tokens     : in Token_Array;
      Tree       : in Node_Array;
      Target_Node : in Node_Index;
      Count_Node  : in Node_Index;
      Success    : in out Boolean)
   is
      Target_Sym : Natural := 0;
      Count_Sym  : Natural := 0;
      Count_Kind : DotNet_Value_Kind := Kind_S64;
      Id         : Natural := 0;
      Group_Name : constant String :=
        (if Target_Node /= 0 and then Tree (Target_Node).Token_Index /= 0
         then Token_Text_Copy (Tokens, Tree (Target_Node).Token_Index)
         else "");
   begin
      if Target_Node = 0 or else Count_Node = 0
        or else Tree (Target_Node).Kind /= AST_Var_Expr
        or else Tree (Target_Node).Left_Child = 0
      then
         Emit_Line ("ALB_Assign(0);", Success);
         return;
      end if;

      Target_Sym := Find_Target_Symbol (Tokens, Tree, Target_Node);
      Count_Sym := Find_Target_Symbol (Tokens, Tree, Count_Node);
      if Count_Sym /= 0 then
         Count_Kind := Symbols (Count_Sym).Kind;
      end if;
      Temp_Count := Temp_Count + 1;
      Id := Temp_Count;

      Success := Emit_Raw ("if (ALB_Num(");
      Emit_Expression (Tokens, Tree, Count_Node, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (") > 0)");
      end if;
      Emit_Line ("", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Success := Emit_Raw ("long alb_swap_ix_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Success := Emit_Raw ("((");
      Emit_Expression
        (Tokens, Tree, Tree (Target_Node).Left_Child, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (") - 1);");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
      Success := Emit_Raw ("long alb_last_ix_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" = ALB_Num(");
      end if;
      Emit_Expression (Tokens, Tree, Count_Node, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (") - 1;");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
      Success := Emit_Raw ("if (alb_swap_ix_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" != alb_last_ix_");
      end if;
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (")");
      end if;
      Emit_Line ("", Success);
      Emit_Line ("{", Success);
      Increase_Indent;

      if Target_Sym /= 0
        and then Symbols (Target_Sym).Shape in Shape_Strict_Array | Shape_Slide_Array
      then
         Emit_Name_Text
           (Symbols (Target_Sym).Emit_Name,
            Symbols (Target_Sym).Emit_Name_Len,
            Success);
         if Success then
            Success := Emit_Raw ("[alb_swap_ix_");
         end if;
         Emit_Natural (Id, Success);
         if Success then
            Success := Emit_Raw ("] = ");
         end if;
         Emit_Name_Text
           (Symbols (Target_Sym).Emit_Name,
            Symbols (Target_Sym).Emit_Name_Len,
            Success);
         if Success then
            Success := Emit_Raw ("[alb_last_ix_");
         end if;
         Emit_Natural (Id, Success);
         if Success then
            Success := Emit_Raw ("];");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      else
         for I in 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then Symbols (I).Shape = Shape_Parallel_Field
              and then Name_Has_Prefix (Symbols (I).Name, Symbols (I).Name_Len, Group_Name & ".")
            then
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("[alb_swap_ix_");
               end if;
               Emit_Natural (Id, Success);
               if Success then
                  Success := Emit_Raw ("] = ");
               end if;
               Emit_Name_Text
                 (Symbols (I).Emit_Name,
                  Symbols (I).Emit_Name_Len,
                  Success);
               if Success then
                  Success := Emit_Raw ("[alb_last_ix_");
               end if;
               Emit_Natural (Id, Success);
               if Success then
                  Success := Emit_Raw ("];");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            end if;
         end loop;
      end if;

      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Target (Tokens, Tree, Count_Node, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      if Needs_Assignment_Cast (Count_Kind) then
         if Count_Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
            Success := Emit_Raw ("unchecked((");
         else
            Success := Emit_Raw ("(");
         end if;
         Emit_CSharp_Type (Count_Kind, Success);
         if Success then
            Success := Emit_Raw (")(");
         end if;
      end if;
      Emit_Target (Tokens, Tree, Count_Node, Success);
      if Success then
         Success := Emit_Raw (" - 1");
      end if;
      if Needs_Assignment_Cast (Count_Kind) and then Success then
         if Count_Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
            Success := Emit_Raw ("))");
         else
            Success := Emit_Raw (")");
         end if;
      end if;
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
      Decrease_Indent;
      Emit_Line ("}", Success);
   end Emit_SwapPop;

   procedure Emit_Assignment_Cast_Open
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean)
   is
   begin
      if Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
         Success := Emit_Raw ("unchecked((");
         Emit_CSharp_Type (Kind, Success);
         if Success then
            Success := Emit_Raw (")(");
         end if;
      elsif Kind = Kind_F64 then
         Success := Emit_Raw ("(double)(");
      elsif Kind = Kind_Bool then
         Success := Emit_Raw ("ALB_Bool(");
      else
         Success := Emit_Raw ("(");
      end if;
   end Emit_Assignment_Cast_Open;

   procedure Emit_Assignment_Cast_Close
     (Kind    : in DotNet_Value_Kind;
      Success : in out Boolean)
   is
   begin
      if Kind in Kind_U8 | Kind_U16 | Kind_U32 | Kind_U64 then
         Success := Emit_Raw ("))");
      else
         Success := Emit_Raw (")");
      end if;
   end Emit_Assignment_Cast_Close;

   procedure Emit_Reversible_Update
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Op_Name : in String;
      Success : in out Boolean)
   is
      Target : constant Node_Index := Tree (Node).Left_Child;
      Value  : constant Node_Index := Tree (Node).Right_Child;
      Sym    : Natural := 0;
      K      : DotNet_Value_Kind := Kind_S64;
   begin
      if Target = 0 or else Tree (Target).Kind not in AST_Var_Expr | AST_Member_Expr then
         Emit_Line ("ALB_Assign(0);", Success);
         return;
      end if;

      Sym := Find_Target_Symbol (Tokens, Tree, Target);
      if Sym /= 0 then
         K := Symbols (Sym).Kind;
      end if;

      Emit_Target (Tokens, Tree, Target, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Emit_Assignment_Cast_Open (K, Success);

      if Op_Name = "ADD" then
         Success := Emit_Raw ("ALB_Num(");
         Emit_Expression (Tokens, Tree, Target, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (") + ALB_Num(");
         end if;
         Emit_Expression (Tokens, Tree, Value, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (")");
         end if;
      elsif Op_Name = "SUB" then
         Success := Emit_Raw ("ALB_Num(");
         Emit_Expression (Tokens, Tree, Target, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (") - ALB_Num(");
         end if;
         Emit_Expression (Tokens, Tree, Value, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (")");
         end if;
      elsif Op_Name = "XOR" then
         Success := Emit_Raw ("ALB_Num(");
         Emit_Expression (Tokens, Tree, Target, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (") ^ ALB_Num(");
         end if;
         Emit_Expression (Tokens, Tree, Value, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (")");
         end if;
      elsif Op_Name = "ROL" or else Op_Name = "ROR" then
         if Op_Name = "ROL" then
            Success := Emit_Raw ("ALB_Rol(ALB_Num(");
         else
            Success := Emit_Raw ("ALB_Ror(ALB_Num(");
         end if;
         Emit_Expression (Tokens, Tree, Target, Kind_S64, Success);
         if Success then
            Success := Emit_Raw ("), ALB_Num(");
         end if;
         Emit_Expression (Tokens, Tree, Value, Kind_S64, Success);
         if Success then
            Success := Emit_Raw ("))");
         end if;
      elsif Op_Name = "NOT" then
         Success := Emit_Raw ("~ALB_Num(");
         Emit_Expression (Tokens, Tree, Target, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (")");
         end if;
      else
         Success := Emit_Raw ("0 - ALB_Num(");
         Emit_Expression (Tokens, Tree, Target, Kind_S64, Success);
         if Success then
            Success := Emit_Raw (")");
         end if;
      end if;

      Emit_Assignment_Cast_Close (K, Success);
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Reversible_Update;

   procedure Emit_Rev_Swap
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Left  : constant Node_Index := Tree (Node).Left_Child;
      Right : constant Node_Index := Tree (Node).Right_Child;
      Sym_L : Natural := 0;
      Sym_R : Natural := 0;
      K_L   : DotNet_Value_Kind := Kind_S64;
      K_R   : DotNet_Value_Kind := Kind_S64;
      Id    : Natural := 0;
   begin
      if Left = 0 or else Right = 0
        or else Tree (Left).Kind not in AST_Var_Expr | AST_Member_Expr
        or else Tree (Right).Kind not in AST_Var_Expr | AST_Member_Expr
      then
         Emit_Line ("ALB_Assign(0);", Success);
         return;
      end if;

      Sym_L := Find_Target_Symbol (Tokens, Tree, Left);
      Sym_R := Find_Target_Symbol (Tokens, Tree, Right);
      if Sym_L /= 0 then
         K_L := Symbols (Sym_L).Kind;
      end if;
      if Sym_R /= 0 then
         K_R := Symbols (Sym_R).Kind;
      end if;

      Temp_Count := Temp_Count + 1;
      Id := Temp_Count;
      Success := Emit_Raw ("long alb_swap_");
      Emit_Natural (Id, Success);
      if Success then
         Success := Emit_Raw (" = ALB_Num(");
      end if;
      Emit_Expression (Tokens, Tree, Left, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (");");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      Emit_Target (Tokens, Tree, Left, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Emit_Assignment_Cast_Open (K_L, Success);
      Success := Emit_Raw ("ALB_Num(");
      Emit_Expression (Tokens, Tree, Right, Kind_S64, Success);
      if Success then
         Success := Emit_Raw (")");
      end if;
      Emit_Assignment_Cast_Close (K_L, Success);
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;

      Emit_Target (Tokens, Tree, Right, Success);
      if Success then
         Success := Emit_Raw (" = ");
      end if;
      Emit_Assignment_Cast_Open (K_R, Success);
      Success := Emit_Raw ("alb_swap_");
      Emit_Natural (Id, Success);
      Emit_Assignment_Cast_Close (K_R, Success);
      if Success then
         Success := Emit_Raw (";");
      end if;
      if Success then
         Success := Emit_Raw (ASCII.LF & "");
      end if;
   end Emit_Rev_Swap;

   procedure Emit_Try
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
      Saved_Symbol_Count : constant Natural := Symbol_Count;
   begin
      Emit_Line ("ALB_LastError = """";", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Block (Tokens, Tree, Tree (Node).Left_Child, Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("if (ALB_LastError.Length != 0)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      if Tree (Node).Token_Index /= 0 then
         Success := Emit_Raw ("string ");
         Emit_Identifier (Tokens, Tree (Node).Token_Index, Success);
         if Success then
            Success := Emit_Raw (" = ALB_LastError;");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
         if Active_Routine_Node /= 0 then
            Register_Local_Symbol
              (Tokens,
               Tree (Node).Token_Index,
               0,
               Kind_String,
               0,
               Allow_Shadow => True);
         end if;
      end if;
      Emit_Block (Tokens, Tree, Tree (Node).Right_Child, Success);
      Symbol_Count := Saved_Symbol_Count;
      Emit_Line ("ALB_LastError = """";", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
   end Emit_Try;

   function Statement_Guarantees_Return
     (Tree : in Node_Array;
      Node : in Node_Index) return Boolean
   is
      Else_Node : Node_Index := 0;
   begin
      if Node = 0 then
         return False;
      end if;

      case Tree (Node).Kind is
         when AST_Return_Stmt =>
            return True;

         when AST_Block_Stmt | AST_Program =>
            return Block_Guarantees_Return (Tree, Node);

         when AST_If_Stmt =>
            if Tree (Node).Right_Child /= 0 then
               Else_Node := Tree (Tree (Node).Right_Child).Next_Sibling;
            end if;

            if Tree (Node).Right_Child = 0 or else Else_Node = 0 then
               return False;
            end if;

            return
              Block_Guarantees_Return (Tree, Tree (Node).Right_Child)
              and then Block_Guarantees_Return (Tree, Else_Node);

         when AST_Comptime_Block =>
            return Block_Guarantees_Return (Tree, Tree (Node).Left_Child);

         when others =>
            return False;
      end case;
   end Statement_Guarantees_Return;

   function Block_Guarantees_Return
     (Tree : in Node_Array;
      Node : in Node_Index) return Boolean
   is
      Curr : Node_Index := Node;
   begin
      if Node = 0 then
         return False;
      end if;

      if Tree (Node).Kind = AST_Block_Stmt
        or else Tree (Node).Kind = AST_Program
      then
         Curr := Tree (Node).Left_Child;
      end if;

      while Curr /= 0 loop
         if Statement_Guarantees_Return (Tree, Curr) then
            return True;
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      return False;
   end Block_Guarantees_Return;

   procedure Emit_Routine_Decl
     (Tokens     : in Token_Array;
      Tree       : in Node_Array;
      Routine_Id : in Natural;
      Success    : in out Boolean)
   is
      Node      : Node_Index := 0;
      Name_Node : Node_Index := 0;
      Args_Node : Node_Index := 0;
      Ret_Kind  : DotNet_Value_Kind := Kind_Void;
      Saved_Module_Token : constant Natural := Active_Routine_Module_Token;
      Saved_Routine_Node : constant Node_Index := Active_Routine_Node;
      Saved_Symbol_Count : constant Natural := Symbol_Count;
      Body_Guarantees_Return : Boolean := False;
   begin
      if Routine_Id = 0 or else Routine_Id > Routine_Count
        or else not Routines (Routine_Id).Active
      then
         return;
      end if;

      Node := Routines (Routine_Id).Node;
      if Node = 0 then
         return;
      end if;

      Name_Node := Tree (Node).Left_Child;
      if Name_Node /= 0 then
         Args_Node := Tree (Name_Node).Right_Child;
      end if;

      if Routines (Routine_Id).Is_Function then
         Ret_Kind :=
           Kind_From_Type_Token
             (Tokens, Tree (Node).Token_Index, Kind_S64);
         Body_Guarantees_Return :=
           Block_Guarantees_Return (Tree, Tree (Node).Right_Child);
      end if;

      Success := Emit_Raw ("public static ");
      Emit_CSharp_Type (Ret_Kind, Success);
      if Success then
         Success := Emit_Raw (" ");
      end if;
      if Name_Node /= 0 then
         Emit_Routine_Name (Tokens, Tree, Routine_Id, Success);
      else
         Success := Emit_Raw ("alb_routine");
      end if;
      if Success then
         Success := Emit_Raw ("(");
      end if;
      Emit_Param_List (Tokens, Tree, Args_Node, Success);
      if Success then
         Success := Emit_Raw (")");
      end if;
      Emit_Line ("", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Active_Routine_Node := Node;
      Active_Routine_Module_Token := Routines (Routine_Id).Module_Token;
      Register_Routine_Params (Tokens, Tree, Args_Node);
      Emit_Block (Tokens, Tree, Tree (Node).Right_Child, Success);
      if Ret_Kind /= Kind_Void and then not Body_Guarantees_Return then
         Success := Emit_Raw ("return ");
         Emit_Default_Value (Ret_Kind, Success);
         if Success then
            Success := Emit_Raw (";");
         end if;
         if Success then
            Success := Emit_Raw (ASCII.LF & "");
         end if;
      end if;
      Symbol_Count := Saved_Symbol_Count;
      Active_Routine_Node := Saved_Routine_Node;
      Active_Routine_Module_Token := Saved_Module_Token;
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);
   end Emit_Routine_Decl;

   procedure Emit_Routines
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Success : in out Boolean)
   is
   begin
      for I in 1 .. Routine_Count loop
         Emit_Routine_Decl (Tokens, Tree, I, Success);
      end loop;
   end Emit_Routines;

   procedure Emit_Event_Method
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Name    : in String;
      Banner  : in String;
      Block   : in Node_Index;
      Success : in out Boolean)
   is
      pragma Unreferenced (Banner);
   begin
      Emit_Line ("public static void " & Name & "()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      if Block /= 0 then
         Emit_Block (Tokens, Tree, Block, Success);
      end if;
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);
   end Emit_Event_Method;

   procedure Emit_Event_Methods
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Success : in out Boolean)
   is
   begin
      Emit_Event_Method
        (Tokens, Tree, "ALB_OnTick", "[ALBN] tick", Tick_Block, Success);
      Emit_Event_Method
        (Tokens, Tree, "ALB_OnPaint", "[ALBN] paint", Paint_Block, Success);
      Emit_Event_Method
        (Tokens, Tree, "ALB_OnKey", "[ALBN] key", Key_Block, Success);
   end Emit_Event_Methods;

   procedure Emit_Logic_Setup
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Success : in out Boolean)
   is
   begin
      if Watch_Count = 0 then
         return;
      end if;

      Emit_Line ("public static void ALB_InitLogic()", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("ALB_OnKnowsChange = ALB_LogicWatch;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);

      Emit_Line ("private static void ALB_LogicWatch(long pred, long arg1)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("switch (pred)", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      for I in 1 .. Watch_Count loop
         if Watch_Nodes (I) /= 0 then
            declare
               Pred_Node : constant Node_Index := Tree (Watch_Nodes (I)).Right_Child;
               Body_Node : constant Node_Index := Tree (Watch_Nodes (I)).Left_Child;
            begin
               Success := Emit_Raw ("case ");
               Emit_Predicate_Id (Tokens, Tree, Pred_Node, Success);
               if Success then
                  Success := Emit_Raw (":");
               end if;
               Emit_Line ("", Success);
               Emit_Line ("{", Success);
               Increase_Indent;
               Emit_Block (Tokens, Tree, Body_Node, Success);
               Emit_Line ("break;", Success);
               Decrease_Indent;
               Emit_Line ("}", Success);
            end;
         end if;
      end loop;
      Emit_Line ("default:", Success);
      Emit_Line ("{", Success);
      Increase_Indent;
      Emit_Line ("break;", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Decrease_Indent;
      Emit_Line ("}", Success);
      Emit_Line ("", Success);
   end Emit_Logic_Setup;

   procedure Emit_Statement
     (Tokens  : in Token_Array;
      Tree    : in Node_Array;
      Node    : in Node_Index;
      Success : in out Boolean)
   is
   begin
      if Node = 0 or else not Success then
         return;
      end if;

      case Tree (Node).Kind is
         when AST_Block_Stmt | AST_Program =>
            Emit_Block (Tokens, Tree, Node, Success);

         when AST_Let_Stmt =>
            Emit_Let (Tokens, Tree, Node, Success);

         when AST_Print_Stmt | AST_Print_Str_Stmt =>
            Emit_Print (Tokens, Tree, Node, Success);

         when AST_BinOp =>
            Emit_BinOp_Statement (Tokens, Tree, Node, Success);

         when AST_Return_Stmt =>
            if Tree (Node).Left_Child /= 0 then
               Success := Emit_Raw ("return ");
               Emit_Assignment_Value
                 (Tokens,
                  Tree,
                  Tree (Node).Left_Child,
                  Current_Routine_Return_Kind (Tokens, Tree),
                  Success);
               if Success then
                  Success := Emit_Raw (";");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            else
               Emit_Line ("return;", Success);
            end if;

         when AST_If_Stmt =>
            Emit_If (Tokens, Tree, Node, Success);

         when AST_While_Stmt =>
            Emit_While (Tokens, Tree, Node, Success);

         when AST_Repeat_Stmt =>
            Emit_Repeat (Tokens, Tree, Node, Success);

         when AST_For_Stmt =>
            Emit_For (Tokens, Tree, Node, Success);

         when AST_Foreach_Stmt =>
            Emit_Foreach (Tokens, Tree, Node, Success);

         when AST_Break_Stmt =>
            Emit_Line ("break;", Success);

         when AST_Continue_Stmt =>
            Emit_Line ("continue;", Success);

         when AST_Call_Stmt =>
            Emit_Call_Statement (Tokens, Tree, Node, Success);

         when AST_Create_Window =>
            Emit_Create_Window (Tokens, Tree, Node, Success);

         when AST_Set_Fullscreen =>
            Success := Emit_Raw ("ALB_SetFullscreen(");
            Emit_Condition (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Set_Resizable =>
            Success := Emit_Raw ("ALB_SetResizable(");
            Emit_Condition (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Set_Stretchy =>
            Success := Emit_Raw ("ALB_SetStretchy(");
            Emit_Condition (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Tick =>
            Success := Emit_Raw ("ALB_FrameMilliseconds = (int)(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_On_Block =>
            null;

         when AST_Color =>
            Emit_Color_Call (Tokens, Tree, Node, "ALB_Color", Success);

         when AST_Clear =>
            Emit_Color_Call (Tokens, Tree, Node, "ALB_Clear", Success);

         when AST_Text =>
            Emit_Draw_Text (Tokens, Tree, Node, Success);

         when AST_Draw | AST_Fill | AST_Plot =>
            Emit_Draw_Primitive (Tokens, Tree, Node, Success);

         when AST_SET_ALPHA =>
            Emit_Runtime_Arg_List_Call
              (Tokens, Tree, "ALB_SetAlpha", Tree (Node).Left_Child, Success);

         when AST_SET_CLIP =>
            Emit_Runtime_Arg_List_Call
              (Tokens, Tree, "ALB_SetClip", Tree (Node).Left_Child, Success);

         when AST_SET_ORIGIN =>
            Emit_Runtime_Arg_List_Call
              (Tokens, Tree, "ALB_SetOrigin", Tree (Node).Left_Child, Success);

         when AST_Locate_Stmt =>
            Success := Emit_Raw ("ALB_Locate(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Listen =>
            Emit_Line ("ALB_Listen();", Success);

         when AST_Cease =>
            Emit_Line ("ALB_Cease();", Success);

         when AST_Input_Stmt =>
            Emit_Input (Tokens, Tree, Node, Tree (Node).Right_Child, Success);

         when AST_Readline_Stmt =>
            Emit_Input (Tokens, Tree, Node, Tree (Node).Left_Child, Success);

         when AST_File_Write =>
            Emit_File_Write (Tokens, Tree, Node, Success);

         when AST_File_Close =>
            Emit_File_Close (Tokens, Tree, Node, Success);

         when AST_Load_Stmt | AST_Flush_Stmt =>
            Emit_Load_Or_Flush (Tokens, Tree, Node, Success);

         when AST_Msg_Box =>
            Success := Emit_Raw ("ALB_MsgBox(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Temporal_Block | AST_Reversible_Block | AST_Atomic_Block =>
            Emit_Block (Tokens, Tree, Tree (Node).Left_Child, Success);

         when AST_Advance_Stmt =>
            Success := Emit_Raw ("for (long alb_adv = 0; alb_adv < ");
            if Tree (Node).Left_Child /= 0 then
               Emit_Expression
                 (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            else
               Success := Emit_Raw ("1");
            end if;
            if Success then
               Success := Emit_Raw ("; alb_adv += 1)");
            end if;
            Emit_Line ("", Success);
            Emit_Line ("{", Success);
            Increase_Indent;
            for I in 1 .. Symbol_Count loop
               if Symbols (I).Active and then Symbols (I).Shape = Shape_Temporal then
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_head = (");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_head + 1) % ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_history.Length;");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_history[");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw ("_head] = ");
                  end if;
                  Emit_Name_Text
                    (Symbols (I).Emit_Name,
                     Symbols (I).Emit_Name_Len,
                     Success);
                  if Success then
                     Success := Emit_Raw (";");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               end if;
            end loop;
            Decrease_Indent;
            Emit_Line ("}", Success);

         when AST_Match_Stmt | AST_Select_Stmt =>
            Emit_Match_Select (Tokens, Tree, Node, Success);

         when AST_SwapPop_Stmt =>
            Emit_SwapPop (Tokens, Tree, Tree (Node).Left_Child, Tree (Node).Right_Child, Success);

         when AST_Poke_Stmt =>
            Success := Emit_Raw ("ALB_Poke(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Save_State =>
            Emit_Line ("ALB_SaveState();", Success);

         when AST_Load_State =>
            Emit_Line ("ALB_LoadState();", Success);

         when AST_Delay_Stmt =>
            Success := Emit_Raw ("ALB_Delay(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Play_Sound =>
            Success := Emit_Raw ("ALB_PlaySound(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Play_Music | AST_Play_Music_From =>
            Success := Emit_Raw ("ALB_PlayMusic(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Claim_Stmt =>
            if Tree (Node).Left_Child /= 0
              and then Tree (Tree (Node).Left_Child).Kind = AST_Var_Expr
              and then Tree (Tree (Node).Left_Child).Left_Child = 0
            then
               Emit_Identifier
                 (Tokens, Tree (Tree (Node).Left_Child).Token_Index, Success);
               if Success then
                  Success := Emit_Raw (" = unchecked((uint)(ALB_Claim()));");
               end if;
               if Success then
                  Success := Emit_Raw (ASCII.LF & "");
               end if;
            else
               Emit_Line ("ALB_Assign(ALB_Claim());", Success);
            end if;

         when AST_Bind_Stmt =>
            Success := Emit_Raw ("ALB_Bind(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            if Tree (Node).Right_Child /= 0
              and then Tree (Tree (Node).Right_Child).Kind = AST_Arg_List
            then
               Emit_Expression
                 (Tokens,
                  Tree,
                  Tree (Tree (Node).Right_Child).Left_Child,
                  Kind_S64,
                  Success);
               if Success and then Tree (Tree (Node).Right_Child).Left_Child /= 0
                 and then Tree (Tree (Tree (Node).Right_Child).Left_Child).Next_Sibling /= 0
               then
                  Success := Emit_Raw (", ");
                  Emit_Expression
                    (Tokens,
                     Tree,
                     Tree (Tree (Tree (Node).Right_Child).Left_Child).Next_Sibling,
                     Kind_S64,
                     Success);
               end if;
            else
               Success := Emit_Raw ("0");
            end if;
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Drop_Stmt =>
            Success := Emit_Raw ("ALB_Drop(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Sweep_Stmt =>
            Success := Emit_Raw ("ALB_Sweep(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Spawn_Stmt =>
            Emit_Call_Statement (Tokens, Tree, Node, Success);

         when AST_Sync_Stmt =>
            Emit_Line ("ALB_Sync();", Success);

         when AST_Rev_Add_Stmt =>
            Emit_Reversible_Update (Tokens, Tree, Node, "ADD", Success);

         when AST_Rev_Sub_Stmt =>
            Emit_Reversible_Update (Tokens, Tree, Node, "SUB", Success);

         when AST_Rev_Xor_Stmt =>
            Emit_Reversible_Update (Tokens, Tree, Node, "XOR", Success);

         when AST_Rev_Rol_Stmt =>
            Emit_Reversible_Update (Tokens, Tree, Node, "ROL", Success);

         when AST_Rev_Ror_Stmt =>
            Emit_Reversible_Update (Tokens, Tree, Node, "ROR", Success);

         when AST_Rev_Not_Stmt =>
            Emit_Reversible_Update (Tokens, Tree, Node, "NOT", Success);

         when AST_Rev_Neg_Stmt =>
            Emit_Reversible_Update (Tokens, Tree, Node, "NEG", Success);

         when AST_Rev_Swap_Stmt =>
            Emit_Rev_Swap (Tokens, Tree, Node, Success);

         when AST_Try_Stmt =>
            Emit_Try (Tokens, Tree, Node, Success);

         when AST_Throw_Stmt =>
            Success := Emit_Raw ("ALB_Throw(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Left_Child, Kind_String, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Runtime_Assert =>
            Success := Emit_Raw ("if (!");
            Emit_Condition (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (") { ALB_Throw(""runtime assert failed""); }");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Knows_Fact =>
            Success := Emit_Raw ("ALB_KnowsSet(");
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Assert_Stmt =>
            Success := Emit_Raw ("ALB_RelSet(");
            Emit_Predicate_Id (Tokens, Tree, Node, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Predicate_Arity (Tree, Node, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Predicate_Arg1 (Tokens, Tree, Node, Success);
            if Success then
               Success := Emit_Raw (", 1);");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Retract_Stmt =>
            Success := Emit_Raw ("ALB_RelRetract(");
            Emit_Predicate_Id (Tokens, Tree, Node, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Predicate_Arity (Tree, Node, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Predicate_Arg1 (Tokens, Tree, Node, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Update_Stmt =>
            Success := Emit_Raw ("ALB_RelSet(");
            Emit_Predicate_Id (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Predicate_Arity (Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Predicate_Arg1 (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Expression
              (Tokens, Tree, Tree (Node).Right_Child, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Findall_Query =>
            Success := Emit_Raw ("ALB_RelFindAll1(");
            Emit_Predicate_Id (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (", ");
            end if;
            Emit_Target (Tokens, Tree, Tree (Node).Right_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Find_Query | AST_Query | AST_Knows_Query =>
            Emit_Expression (Tokens, Tree, Node, Kind_S64, Success);
            if Success then
               Success := Emit_Raw (";");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Predict_Markov_Stmt =>
            declare
               Model_Node  : constant Node_Index := Tree (Node).Left_Child;
               State_Node  : constant Node_Index := Tree (Node).Right_Child;
               Output_Node : constant Node_Index := Tree (State_Node).Next_Sibling;
               Model_Id    : Natural := 0;
            begin
               if Model_Node /= 0 and then Tree (Model_Node).Token_Index /= 0 then
                  Model_Id := Find_Markov_Model (Tokens, Tree (Model_Node).Token_Index);
               end if;
               if Model_Id /= 0 and then Output_Node /= 0 then
                  Emit_Target (Tokens, Tree, Output_Node, Success);
                  if Success then
                     Success := Emit_Raw (" = ALB_MarkovPredict(ALB_MARKOV_");
                  end if;
                  if Success then
                     Success :=
                       Emit_Raw
                         (Buffer_Text
                            (Markov_Models (Model_Id).Name,
                             Markov_Models (Model_Id).Name_Len));
                  end if;
                  if Success then
                     Success := Emit_Raw (", ALB_MARKOV_");
                  end if;
                  if Success then
                     Success :=
                       Emit_Raw
                         (Buffer_Text
                            (Markov_Models (Model_Id).Name,
                             Markov_Models (Model_Id).Name_Len));
                  end if;
                  if Success then
                     Success := Emit_Raw ("_STATES, (ulong)(");
                  end if;
                  Emit_Expression (Tokens, Tree, State_Node, Kind_U64, Success);
                  if Success then
                     Success := Emit_Raw ("));");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               else
                  Emit_Statement_Warning
                    (Tokens,
                     Tree,
                     Node,
                     Emitter_Unsupported_Statement_Node,
                     "markov model was not registered for predict",
                     Success);
               end if;
            end;

         when AST_Infer_Network_Stmt =>
            declare
               Model_Node  : constant Node_Index := Tree (Node).Left_Child;
               Input_Node  : constant Node_Index := Tree (Node).Right_Child;
               Output_Node : constant Node_Index := Tree (Input_Node).Next_Sibling;
               Model_Id    : Natural := 0;
            begin
               if Model_Node /= 0 and then Tree (Model_Node).Token_Index /= 0 then
                  Model_Id := Find_Neural_Model (Tokens, Tree (Model_Node).Token_Index);
               end if;
               if Model_Id /= 0 and then Input_Node /= 0 and then Output_Node /= 0 then
                  Success := Emit_Raw ("ALB_NN_INFER(ALB_NN_");
                  if Success then
                     Success :=
                       Emit_Raw
                         (Buffer_Text
                            (Neural_Models (Model_Id).Name,
                             Neural_Models (Model_Id).Name_Len));
                  end if;
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Target (Tokens, Tree, Input_Node, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Target (Tokens, Tree, Output_Node, Success);
                  if Success then
                     Success := Emit_Raw (");");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               else
                  Emit_Statement_Warning
                    (Tokens,
                     Tree,
                     Node,
                     Emitter_Unsupported_Statement_Node,
                     "neural model was not registered for infer",
                     Success);
               end if;
            end;

         when AST_Train_Network_Stmt =>
            declare
               Model_Node  : constant Node_Index := Tree (Node).Left_Child;
               Train_Node  : constant Node_Index := Tree (Node).Right_Child;
               Expect_Node : constant Node_Index := Tree (Train_Node).Next_Sibling;
               Epoch_Node  : constant Node_Index := Tree (Expect_Node).Next_Sibling;
               Model_Id    : Natural := 0;
            begin
               if Model_Node /= 0 and then Tree (Model_Node).Token_Index /= 0 then
                  Model_Id := Find_Neural_Model (Tokens, Tree (Model_Node).Token_Index);
               end if;
               if Model_Id /= 0 and then Train_Node /= 0 and then Expect_Node /= 0 then
                  Success := Emit_Raw ("ALB_NN_TRAIN(ALB_NN_");
                  if Success then
                     Success :=
                       Emit_Raw
                         (Buffer_Text
                            (Neural_Models (Model_Id).Name,
                             Neural_Models (Model_Id).Name_Len));
                  end if;
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Target (Tokens, Tree, Train_Node, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Target (Tokens, Tree, Expect_Node, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  if Epoch_Node /= 0 then
                     Emit_Expression (Tokens, Tree, Epoch_Node, Kind_S64, Success);
                  else
                     Success := Emit_Raw ("1");
                  end if;
                  if Success then
                     Success := Emit_Raw (");");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               else
                  Emit_Statement_Warning
                    (Tokens,
                     Tree,
                     Node,
                     Emitter_Unsupported_Statement_Node,
                     "neural model was not registered for train",
                     Success);
               end if;
            end;

         when AST_Network_Listen_Stmt =>
            declare
               Socket_Node  : constant Node_Index := Tree (Node).Left_Child;
               Socket_Id    : Natural := 0;
               Decl_Node    : Node_Index := 0;
               Setting_Node : Node_Index := 0;
               Protocol_Code : Natural := 1;
               Port_Node    : Node_Index := 0;
               Size_Node    : Node_Index := 0;
            begin
               if Socket_Node /= 0 and then Tree (Socket_Node).Token_Index /= 0 then
                  Socket_Id := Find_Network_Socket (Tokens, Tree (Socket_Node).Token_Index);
               end if;
               if Socket_Id /= 0 then
                  Decl_Node := Network_Sockets (Socket_Id).Node;
                  Setting_Node := Tree (Decl_Node).Right_Child;
                  while Setting_Node /= 0 loop
                     case Tree (Setting_Node).Kind is
                        when AST_Network_Protocol =>
                           if Tree (Setting_Node).Left_Child /= 0
                             and then Token_Text_Equals
                               (Tokens,
                                Tree (Tree (Setting_Node).Left_Child).Token_Index,
                                "UDP")
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
                  Emit_Target (Tokens, Tree, Socket_Node, Success);
                  if Success then
                     Success := Emit_Raw (" = ALB_NET_LISTEN_SOCKET(");
                  end if;
                  Emit_Target (Tokens, Tree, Socket_Node, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  Emit_Natural (Protocol_Code, Success);
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  if Port_Node /= 0 then
                     Emit_Expression (Tokens, Tree, Port_Node, Kind_S64, Success);
                  else
                     Success := Emit_Raw ("0");
                  end if;
                  if Success then
                     Success := Emit_Raw (", ");
                  end if;
                  if Size_Node /= 0 then
                     Emit_Expression (Tokens, Tree, Size_Node, Kind_S64, Success);
                  else
                     Success := Emit_Raw ("1");
                  end if;
                  if Success then
                     Success := Emit_Raw (");");
                  end if;
                  if Success then
                     Success := Emit_Raw (ASCII.LF & "");
                  end if;
               else
                  Emit_Statement_Warning
                    (Tokens,
                     Tree,
                     Node,
                     Emitter_Unsupported_Statement_Node,
                     "network socket was not registered for listen",
                     Success);
               end if;
            end;

         when AST_Network_Receive_Stmt =>
            Success := Emit_Raw ("ALB_NET_RECEIVE((ulong)(");
            Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Kind_U64, Success);
            if Success then
               Success := Emit_Raw ("), ");
            end if;
            Emit_Target (Tokens, Tree, Tree (Node).Right_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Network_Send_Stmt =>
            Success := Emit_Raw ("ALB_NET_SEND((ulong)(");
            Emit_Expression (Tokens, Tree, Tree (Node).Left_Child, Kind_U64, Success);
            if Success then
               Success := Emit_Raw ("), ");
            end if;
            Emit_Target (Tokens, Tree, Tree (Node).Right_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Network_Close_Stmt =>
            Success := Emit_Raw ("ALB_NET_CLOSE(ref ");
            Emit_Target (Tokens, Tree, Tree (Node).Left_Child, Success);
            if Success then
               Success := Emit_Raw (");");
            end if;
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Import_C | AST_Import_DLL =>
            null;

         when AST_Const_Decl | AST_Markov_Model_Decl | AST_Neural_Topology_Decl |
              AST_Memory_Firewall_Decl | AST_Network_Socket_Decl |
              AST_Export_DLL | AST_Export_ES | AST_Export_WASM |
              AST_Import_ES | AST_Import_WASM =>
            null;

         when AST_Struct_Decl | AST_Enum_Decl | AST_Range_Type_Decl |
              AST_Struct_Field | AST_Bitfield_Decl | AST_Parallel_Field =>
            null;

        when AST_Strict_Stmt | AST_Slide_Stmt | AST_Parallel_Decl |
              AST_Temporal_Decl | AST_String_Decl =>
            null;

         when AST_Module =>
            declare
               Saved_Module_Token : constant Natural :=
                 Active_Routine_Module_Token;
               Name_Node : constant Node_Index := Tree (Node).Left_Child;
            begin
               if Name_Node /= 0 and then Tree (Name_Node).Token_Index /= 0 then
                  Active_Routine_Module_Token :=
                    Tree (Name_Node).Token_Index;
               end if;
               Emit_Block (Tokens, Tree, Tree (Node).Right_Child, Success);
               Active_Routine_Module_Token := Saved_Module_Token;
            end;

         when AST_DeclareModule | AST_Procedure_Decl | AST_Function_Decl =>
            null;

         when AST_Comptime_Block =>
            Emit_Block (Tokens, Tree, Tree (Node).Left_Child, Success);

         when AST_Enable_Typescript_Block | AST_Enable_CSharp_Block =>
            Emit_Raw_Block_Body (Tokens, Tree (Node).Token_Index, Success);
            if Success then
               Success := Emit_Raw (ASCII.LF & "");
            end if;

         when AST_Version | AST_Import | AST_Include_Stmt |
              AST_Enable_Asm | AST_Disable_Asm | AST_Enable_Ada_Block |
              AST_Enable_Java_Block | AST_Asm_Block | AST_Predicate_Decl |
              AST_Case_Stmt | AST_Horn_Clause | AST_Fact |
              AST_Predicate | AST_Logic_Var | AST_Cut_Stmt |
              AST_Param_Decl | AST_Require_Clause | AST_Ensure_Clause |
              AST_Knows_Change | AST_SYS_RENDERER | AST_Atom |
              AST_Array_Assign | AST_Array_Access |
              AST_Inline_Asm_Expr | AST_Inline_Ada_Expr |
              AST_Inline_Java_Expr | AST_Inline_Typescript_Expr |
              AST_Inline_CSharp_Expr |
              AST_AddressOf | AST_Ref_Expr | AST_TypeOf_Expr |
              AST_SizeOf_Expr | AST_OffsetOf_Expr | AST_Simd_Intrinsic =>
            null;

         when others =>
            Emit_Statement_Warning
              (Tokens,
               Tree,
               Node,
               Emitter_Unsupported_Statement_Node,
               "unsupported statement fallback emitted",
               Success);
      end case;
   end Emit_Statement;

   procedure Flush_Output (Success : out Boolean) is
      File : Ada.Text_IO.File_Type;
   begin
      Success := False;
      if Output_Flen = 0 then
         Mark_Emitter_Fatal
           (Emitter_Output_Path_Invalid,
            "output path was empty during flush");
         return;
      end if;

      begin
         Ada.Text_IO.Create
           (File, Ada.Text_IO.Out_File, Output_Path (1 .. Output_Flen));
         if Output_Len > 0 then
            Ada.Text_IO.Put (File, Output_Buffer (1 .. Output_Len));
         end if;
         Ada.Text_IO.Close (File);
         Success := True;
      exception
         when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
            begin
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
            exception
               when Ada.IO_Exceptions.Status_Error | Ada.IO_Exceptions.Use_Error =>
                  null;
            end;
            Mark_Emitter_Fatal
              (Emitter_Output_Create_Failure,
               "could not create emitter output file");
            Success := False;

         when Ada.IO_Exceptions.Status_Error | Ada.IO_Exceptions.Device_Error =>
            begin
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
            exception
               when Ada.IO_Exceptions.Status_Error | Ada.IO_Exceptions.Use_Error =>
                  null;
            end;
            Mark_Emitter_Fatal
              (Emitter_Output_Write_Failure,
               "could not write emitter output file");
            Success := False;
      end;
   end Flush_Output;

   procedure Initialize_Output
     (File_Path  : in String;
      Diagnostic : in out Emitter_Diagnostic_Log)
   is
   begin
      Current_Emitter_Diag :=
        (Had_Warnings    => False,
         Had_Fatal_Error => False,
         Warning_Count   => 0,
         Stored_Count    => 0,
         Entries         =>
           (others =>
              (Active      => False,
               Node        => 0,
               Token_Index => 0,
               Line        => 0,
               Column      => 0,
               Category    => Emitter_None,
               Message     => (others => ' '),
               Message_Len => 0)));
      Output_Buffer := (others => ' ');
      Output_Len := 0;
      Output_Path := (others => ' ');
      Output_Flen := 0;
      Indent_Level := 0;
      At_Line_Start := True;
      Symbols := (others => (Active => False,
                             Name => (others => ' '),
                             Name_Len => 0,
                             Emit_Name => (others => ' '),
                             Emit_Name_Len => 0,
                             Type_Token => 0,
                             Kind => Kind_S64,
                             Shape => Shape_Scalar,
                             Init_Node => 0,
                             Rank => 0,
                             Dims => (others => 0),
                             Active_Node => 0,
                             History_Node => 0,
                             Module_Token => 0,
                             Routine_Node => 0));
      Symbol_Count := 0;
      Imports := (others => (Active => False, Node => 0));
      Import_Count := 0;
      Routines := (others => (Active => False,
                              Name => (others => ' '),
                              Name_Len => 0,
                              Node => 0,
                              Module_Token => 0,
                              Is_Function => False));
      Routine_Count := 0;
      Watch_Nodes := (others => 0);
      Watch_Count := 0;
      Tick_Block := 0;
      Paint_Block := 0;
      Key_Block := 0;
      Temp_Count := 0;
      Active_Routine_Module_Token := 0;
      Active_Routine_Node := 0;

      if File_Path'Length = 0 or else File_Path'Length > Max_Path_Len then
         DotNet_Emitter_Ready := False;
         Mark_Emitter_Fatal
           (Emitter_Output_Path_Invalid,
            "output path was empty or too long for the dotnet emitter");
         Diagnostic := Current_Emitter_Diag;
         return;
      end if;

      Output_Path (1 .. File_Path'Length) := File_Path;
      Output_Flen := File_Path'Length;
      DotNet_Emitter_Ready := True;
      Diagnostic := Current_Emitter_Diag;
   end Initialize_Output;

   procedure Emit_Program
     (Tokens      : in Token_Array;
      Tree        : in Node_Array;
      Root        : in Node_Index;
      Diagnostic  : in out Emitter_Diagnostic_Log)
   is
      Ok : Boolean := DotNet_Emitter_Ready;
   begin
      Current_Emitter_Diag := Diagnostic;

      if not Ok then
         if not Current_Emitter_Diag.Had_Fatal_Error then
            Mark_Emitter_Fatal
              (Emitter_Output_Path_Invalid,
               "dotnet emitter was not initialized before Emit_Program");
         end if;
         Diagnostic := Current_Emitter_Diag;
         return;
      end if;

      Scan_List (Tokens, Tree, Root);

      Emit_Line ("using System;", Ok);
      Emit_Line ("using System.Collections.Generic;", Ok);
      Emit_Line ("using System.IO;", Ok);
      Emit_Line ("using System.Net;", Ok);
      Emit_Line ("using System.Net.Sockets;", Ok);
      Emit_Line ("using System.Numerics;", Ok);
      Emit_Line ("using System.Reflection;", Ok);
      Emit_Line ("using System.Runtime.InteropServices;", Ok);
      Emit_Line ("", Ok);
      Emit_Line ("namespace ALB_Generated", Ok);
      Emit_Line ("{", Ok);
      Increase_Indent;
      Emit_Line ("public static class Program", Ok);
      Emit_Line ("{", Ok);
      Increase_Indent;

      Emit_Runtime_Types (Ok);

      for I in 1 .. Import_Count loop
         if Imports (I).Active then
            Emit_Import_C (Tokens, Tree, Imports (I).Node, Ok);
         end if;
      end loop;

      Emit_Global_Fields (Tokens, Tree, Ok);
      Emit_User_State_Support (Ok);

      Emit_Routines (Tokens, Tree, Ok);
      Emit_Event_Methods (Tokens, Tree, Ok);
      Emit_Logic_Setup (Tokens, Tree, Ok);

      Emit_Line ("public static void Main(string[] args)", Ok);
      Emit_Line ("{", Ok);
      Increase_Indent;
      if Watch_Count > 0 then
         Emit_Line ("ALB_InitLogic();", Ok);
      end if;
      Emit_Block (Tokens, Tree, Root, Ok);
      Decrease_Indent;
      Emit_Line ("}", Ok);

      Decrease_Indent;
      Emit_Line ("}", Ok);
      Decrease_Indent;
      Emit_Line ("}", Ok);

      if Ok then
         Flush_Output (Ok);
      end if;

      if not Ok and then not Current_Emitter_Diag.Had_Fatal_Error then
         Mark_Emitter_Fatal
           (Emitter_Internal_Fallback,
            "dotnet emission stopped after an internal writer failure");
      end if;

      Diagnostic := Current_Emitter_Diag;
   end Emit_Program;

end Emit_Native_DotNet;
