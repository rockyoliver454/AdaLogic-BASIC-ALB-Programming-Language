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

pragma Ada_2012;

with JaySoond_Std;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;

package body Lib_JaySoond is

   use JaySoond_Std;

   function Safe_Value (Ptr : chars_ptr) return String is
   begin
      if Ptr = Null_Ptr then
         return "";
      else
         return Value (Ptr);
      end if;
   end Safe_Value;

   function Kind_Code (K : Token_Kind) return int is
   begin
      case K is
         when None         => return JAY_NONE;
         when Start_Object => return JAY_START_OBJECT;
         when End_Object   => return JAY_END_OBJECT;
         when Start_Array  => return JAY_START_ARRAY;
         when End_Array    => return JAY_END_ARRAY;
         when Key          => return JAY_KEY;
         when String_Val   => return JAY_STRING;
         when Integer_Val  => return JAY_INTEGER;
         when Float_Val    => return JAY_FLOAT;
         when Boolean_Val  => return JAY_BOOLEAN;
         when Null_Val     => return JAY_NULL;
         when Error        => return JAY_ERROR;
         when End_Of_File  => return JAY_EOF;
      end case;
   end Kind_Code;

   function JaySoond_Parser_Size return int is
   begin
      return int (Parser'Size / 8);
   end JaySoond_Parser_Size;

   function JaySoond_Init_File
     (Parser_Ptr : System.Address;
      Filename   : chars_ptr) return int
   is
      P : Parser;
      pragma Import (Ada, P);
      for P'Address use Parser_Ptr;
   begin
      Init_File (P, Safe_Value (Filename));
      if Is_Ready (P) then
         return 1;
      else
         return 0;
      end if;
   end JaySoond_Init_File;

   function JaySoond_Init_String
     (Parser_Ptr : System.Address;
      Input      : chars_ptr) return int
   is
      P : Parser;
      pragma Import (Ada, P);
      for P'Address use Parser_Ptr;
      S : constant String := Safe_Value (Input);
   begin
      if S'Length = 0 then
         return 0;
      end if;
      -- Init_String requires Length <= Buffer_Size (8192)
      if S'Length > 8192 then
         return 0;
      end if;
      Init_String (P, S);
      if Is_Ready (P) then
         return 1;
      else
         return 0;
      end if;
   end JaySoond_Init_String;

   function JaySoond_Next
     (Parser_Ptr : System.Address;
      Dest       : System.Address;
      Dest_Len   : int;
      Out_Line   : access int;
      Out_Col    : access int) return int
   is
      P : Parser;
      pragma Import (Ada, P);
      for P'Address use Parser_Ptr;
      Tok : Token_Data;
      Copy_Len : Natural;
      Dest_Arr : char_array (0 .. size_t (Dest_Len));
      for Dest_Arr'Address use Dest;
      pragma Import (Ada, Dest_Arr);
   begin
      if not Is_Ready (P) then
         return JAY_ERROR;
      end if;

      Next (P, Tok);

      if Out_Line /= null then
         Out_Line.all := int (Tok.Line);
      end if;
      if Out_Col /= null then
         Out_Col.all := int (Tok.Column);
      end if;

      if Dest_Len > 0 then
         Copy_Len := Tok.Length;
         if Copy_Len >= Natural (Dest_Len) then
            Copy_Len := Natural (Dest_Len) - 1;
         end if;
         for I in 1 .. Copy_Len loop
            Dest_Arr (size_t (I - 1)) := To_C (Tok.Text (I));
         end loop;
         Dest_Arr (size_t (Copy_Len)) := nul;
      end if;

      return Kind_Code (Tok.Kind);
   end JaySoond_Next;

   function JaySoond_Has_More (Parser_Ptr : System.Address) return int is
      P : Parser;
      pragma Import (Ada, P);
      for P'Address use Parser_Ptr;
   begin
      if Has_More (P) then
         return 1;
      else
         return 0;
      end if;
   end JaySoond_Has_More;

   procedure JaySoond_Close (Parser_Ptr : System.Address) is
      P : Parser;
      pragma Import (Ada, P);
      for P'Address use Parser_Ptr;
   begin
      Close (P);
   end JaySoond_Close;

end Lib_JaySoond;
