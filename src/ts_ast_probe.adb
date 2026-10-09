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

with Ada.Command_Line;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with AST; use AST;
with Compiler_State; use Compiler_State;
with Parser; use Parser;
with Tokenizer; use Tokenizer;

procedure Ts_Ast_Probe is

   function Read_File (Path : String) return String is
      F      : File_Type;
      Buffer : Unbounded_String := Null_Unbounded_String;
   begin
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         declare
            Line : constant String := Get_Line (F);
         begin
            Append (Buffer, Line);
            if not End_Of_File (F) then
               Append (Buffer, ASCII.LF);
            end if;
         end;
      end loop;
      Close (F);
      return To_String (Buffer);
   end Read_File;

   function Lexeme_Of (Input : String; Tok : Token) return String is
   begin
      if Tok.Length = 0 then
         return "";
      end if;
      return Input (Tok.Start .. Tok.Start + Tok.Length - 1);
   end Lexeme_Of;

   procedure Dump_Node
     (Input  : String;
      Tokens : Token_Array;
      Tree   : Node_Array;
      Index  : Node_Index;
      Depth  : Natural := 0;
      Budget : in out Natural)
   is
      Prefix : constant String := (1 .. Depth * 2 => ' ');
   begin
      if Budget = 0 then
         Put_Line (Prefix & "<budget exhausted>");
         return;
      end if;

      if Index = 0 then
         Put_Line (Prefix & "<null>");
         return;
      end if;

      Budget := Budget - 1;

      Put_Line
        (Prefix &
         Node_Index'Image (Index) &
         " " &
         Node_Kind'Image (Tree (Index).Kind) &
         " tok=" &
         Natural'Image (Tree (Index).Token_Index) &
         (if Tree (Index).Token_Index > 0
          then " [" &
            Token_Kind'Image (Tokens (Tree (Index).Token_Index).Kind) &
            " '" &
            Lexeme_Of (Input, Tokens (Tree (Index).Token_Index)) &
            "']"
          else ""));

      if Tree (Index).Left_Child /= 0 then
         Put_Line (Prefix & "  L:");
         if Depth < 12 then
            Dump_Node (Input, Tokens, Tree, Tree (Index).Left_Child, Depth + 2, Budget);
         else
            Put_Line (Prefix & "    <depth limit>");
         end if;
      end if;

      if Tree (Index).Right_Child /= 0 then
         Put_Line (Prefix & "  R:");
         if Depth < 12 then
            Dump_Node (Input, Tokens, Tree, Tree (Index).Right_Child, Depth + 2, Budget);
         else
            Put_Line (Prefix & "    <depth limit>");
         end if;
      end if;

      if Tree (Index).Next_Sibling /= 0 then
         Put_Line (Prefix & "  S:");
         if Depth < 12 then
            Dump_Node (Input, Tokens, Tree, Tree (Index).Next_Sibling, Depth, Budget);
         else
            Put_Line (Prefix & "    <depth limit>");
         end if;
      end if;
   end Dump_Node;

   Source      : constant String := Read_File (Ada.Command_Line.Argument (1));
   Token_Count : Natural := 0;
   Lex_Diag    : Lexer_Diagnostic;
   Root        : Node_Index := 0;
   Success     : Boolean := False;
   Diag        : Parser_Diagnostic;
   Budget      : Natural := 220;
begin
   Tree := (others => (Kind => AST_Null, Token_Index => 0, Left_Child => 0, Right_Child => 0, Next_Sibling => 0));
   Tokenize (Source, Tokens, Token_Count, Lex_Diag);
   if not Lex_Diag.Success then
      Put_Line ("Lex failed at" & Positive'Image (Lex_Diag.Error_Line) & ":" & Positive'Image (Lex_Diag.Error_Col));
      return;
   end if;

   Parse (Tokens, Token_Count, Tree, Root, Success, Diag);
   if not Success then
      Put_Line ("Parse failed at" & Positive'Image (Diag.Error_Line) & ":" & Positive'Image (Diag.Error_Col));
      Put_Line ("Errors:" & Natural'Image (Diag.Error_Count));
   end if;

   Put_Line ("NODE 55 left=" & Node_Index'Image (Tree (55).Left_Child) &
             " right=" & Node_Index'Image (Tree (55).Right_Child) &
             " next=" & Node_Index'Image (Tree (55).Next_Sibling));
   Put_Line ("NODE 58 next=" & Node_Index'Image (Tree (58).Next_Sibling));
   Put_Line ("NODE 70 next=" & Node_Index'Image (Tree (70).Next_Sibling));

   declare
      Top  : Node_Index := Root;
      Step : Natural := 0;
   begin
      Put_Line ("TOP-LEVEL CHAIN");
      while Top > 0 and then Step < 24 loop
         Put_Line
           (Node_Index'Image (Top) & " " & Node_Kind'Image (Tree (Top).Kind) &
            " next=" & Node_Index'Image (Tree (Top).Next_Sibling));
         if Tree (Top).Kind = AST_FOR_STMT then
            declare
               Body_Curr : Node_Index :=
                 (if Tree (Top).Right_Child > 0 then Tree (Tree (Top).Right_Child).Left_Child else 0);
               J : Natural := 0;
            begin
               Put_Line ("FOR BODY CHAIN");
               while Body_Curr > 0 and then J < 24 loop
                  Put_Line
                    (Node_Index'Image (Body_Curr) & " " & Node_Kind'Image (Tree (Body_Curr).Kind) &
                     " next=" & Node_Index'Image (Tree (Body_Curr).Next_Sibling));
                  Body_Curr := Tree (Body_Curr).Next_Sibling;
                  J := J + 1;
               end loop;
            end;
         end if;
         Top := Tree (Top).Next_Sibling;
         Step := Step + 1;
      end loop;
   end;

   if Root > 0 and then Tree (Root).Next_Sibling = 0 and then Tree (Root).Kind = AST_BLOCK_STMT then
      declare
         Curr : Node_Index := Tree (Root).Left_Child;
         I    : Natural := 0;
      begin
         Put_Line ("ROOT BLOCK CHAIN");
         while Curr > 0 and then I < 40 loop
            Put_Line
              (Node_Index'Image (Curr) & " " & Node_Kind'Image (Tree (Curr).Kind) &
               " next=" & Node_Index'Image (Tree (Curr).Next_Sibling));
            if Tree (Curr).Kind = AST_FOR_STMT then
               declare
                  Body_Curr : Node_Index :=
                    (if Tree (Curr).Right_Child > 0 then Tree (Tree (Curr).Right_Child).Left_Child else 0);
                  J : Natural := 0;
               begin
                  Put_Line ("ROOT FOR BODY CHAIN");
                  while Body_Curr > 0 and then J < 40 loop
                     Put_Line
                       (Node_Index'Image (Body_Curr) & " " & Node_Kind'Image (Tree (Body_Curr).Kind) &
                        " next=" & Node_Index'Image (Tree (Body_Curr).Next_Sibling));
                     Body_Curr := Tree (Body_Curr).Next_Sibling;
                     J := J + 1;
                  end loop;
               end;
            end if;
            Curr := Tree (Curr).Next_Sibling;
            I := I + 1;
         end loop;
      end;
   end if;

   Dump_Node (Source, Tokens, Tree, Root, 0, Budget);
end Ts_Ast_Probe;
