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
pragma SPARK_Mode (On);

with Interfaces; use Interfaces;

package body JaySoond is

   -- HELPERS (Unchanged)
   function Is_Space (C : Character) return Boolean is
   begin
      return C = ' ' or C = ASCII.HT or C = ASCII.LF or C = ASCII.CR;
   end Is_Space;

   function Is_Digit (C : Character) return Boolean is
   begin
      return C in '0' .. '9';
   end Is_Digit;

   function Is_Hex (C : Character) return Boolean is
   begin
      return Is_Digit(C) or else (C in 'A'..'F') or else (C in 'a'..'f');
   end Is_Hex;

   function Hex_Val (C : Character) return Natural is
   begin
      if C in '0'..'9' then return Character'Pos(C) - Character'Pos('0');
      elsif C in 'A'..'F' then return Character'Pos(C) - Character'Pos('A') + 10;
      elsif C in 'a'..'f' then return Character'Pos(C) - Character'Pos('a') + 10;
      else return 0; end if;
   end Hex_Val;

   function Is_Control (C : Character) return Boolean is
   begin
      return Character'Pos(C) <= 31;
   end Is_Control;

   function Is_Ready (P : Parser) return Boolean is
   begin
      return P.Is_Initialized;
   end Is_Ready;

   -- BUFFER LOGIC (Unchanged)
   procedure Refill_Buffer (P : in out Parser) 
     with SPARK_Mode => Off 
   is
      use Ada.Streams;
      Bytes_To_Read : Stream_Element_Offset;
      Bytes_Read    : Stream_Element_Offset;
      Buffer_SE     : Stream_Element_Array (1 .. Stream_Element_Offset(Buffer_Size));
   begin
      if not P.Is_File_Mode or else P.EOF_Reached then return; end if;
      if P.Buf_Len >= Buffer_Size then return; end if;

      Bytes_To_Read := Stream_Element_Offset(Buffer_Size - P.Buf_Len);
      begin
         SIO.Read(P.File_Handle, Buffer_SE(1 .. Bytes_To_Read), Bytes_Read);
         for I in 1 .. Bytes_Read loop
            P.Buffer(P.Buf_Len + Integer(I)) := Character'Val(Buffer_SE(I));
         end loop;
         P.Buf_Len := P.Buf_Len + Integer(Bytes_Read);
         if Bytes_Read < Bytes_To_Read then P.EOF_Reached := True; end if;
      exception
         when SIO.End_Error => P.EOF_Reached := True;
      end;
   end Refill_Buffer;

   procedure Ensure_Data (P : in out Parser) is
   begin
      if P.Cursor > P.Buf_Len then
         if P.Is_File_Mode and not P.EOF_Reached then
            P.Cursor := 1; P.Buf_Len := 0; Refill_Buffer(P);
         end if;
      end if;
   end Ensure_Data;

   procedure Peek_Char (P : in out Parser; C : out Character; Success : out Boolean) is
   begin
      if P.Cursor > P.Buf_Len then Ensure_Data(P); end if;
      if P.Cursor <= P.Buf_Len then
         C := P.Buffer(P.Cursor); Success := True;
      else
         C := ASCII.NUL; Success := False;
      end if;
   end Peek_Char;

   -- Location Tracking
   procedure Consume_Char (P : in out Parser; C : out Character) is
   begin
      if P.Cursor > P.Buf_Len then Ensure_Data(P); end if;
      if P.Cursor <= P.Buf_Len then
         C := P.Buffer(P.Cursor); 
         P.Cursor := P.Cursor + 1;
         
         if C = ASCII.LF then
            P.Current_Line := P.Current_Line + 1;
            P.Current_Col  := 1;
         else
            P.Current_Col := P.Current_Col + 1;
         end if;
      else
         C := ASCII.NUL;
      end if;
   end Consume_Char;

   -- INIT
   procedure Init_String (P : out Parser; Input : String) is
   begin
      P.Is_Initialized := True; P.Is_File_Mode := False;
      P.Buf_Len := Input'Length;
      if P.Buf_Len > Buffer_Size then P.Buf_Len := Buffer_Size; end if;
      P.Buffer(1 .. P.Buf_Len) := Input(Input'First .. Input'First + P.Buf_Len - 1);
      if P.Buf_Len < Buffer_Size then P.Buffer(P.Buf_Len + 1 .. Buffer_Size) := (others => ASCII.NUL); end if;
      P.Cursor := 1; P.Stack_Top := 0; P.Error_State := False; P.EOF_Reached := True;
      P.Stack := (others => Root);
      P.Current_Line := 1; P.Current_Col := 1;
   end Init_String;

   procedure Init_File (P : out Parser; Filename : String) 
     with SPARK_Mode => Off 
   is
   begin
      P.Is_Initialized := True; P.Is_File_Mode := True;
      P.Error_State := False; P.Stack_Top := 0; P.Stack := (others => Root);
      P.Cursor := 1; P.Buf_Len := 0; P.EOF_Reached := False; P.Buffer := (others => ' ');
      P.Current_Line := 1; P.Current_Col := 1;
      begin
         SIO.Open(P.File_Handle, SIO.In_File, Filename);
         Refill_Buffer(P);
      exception
         when others => P.Error_State := True; P.EOF_Reached := True; P.Is_Initialized := False;
      end;
   end Init_File;

   procedure Close (P : in out Parser) 
     with SPARK_Mode => Off 
   is
   begin
      if P.Is_File_Mode and then SIO.Is_Open(P.File_Handle) then
         SIO.Close(P.File_Handle);
      end if;
      P.Is_Initialized := False;
   end Close;

   function Has_More (P : Parser) return Boolean is
   begin
      return P.Is_Initialized and then not P.Error_State and then 
             (P.Cursor <= P.Buf_Len or else (P.Is_File_Mode and not P.EOF_Reached));
   end Has_More;

   -- NEXT TOKEN
   procedure Next (P : in out Parser; Tok : out Token_Data) is
      C, Peek_C : Character;
      Success : Boolean;
      Text_Idx : Natural := 0;
      
      -- Helper: Append char to Token Text
      -- FIX 1: Detect truncation and error out
      procedure Append (Char_To_Add : Character) is
      begin
         if P.Error_State then return; end if;
         if Text_Idx < Max_Str_Len then
            Text_Idx := Text_Idx + 1;
            Tok.Text(Text_Idx) := Char_To_Add;
         else
            -- STRING OVERFLOW
            P.Error_State := True; 
            Tok.Kind := Error;
         end if;
      end Append;

      procedure Encode_UTF8 (Code_Point : Natural) is
         U_Point : constant Unsigned_32 := Unsigned_32 (Code_Point);
      begin
         if P.Error_State then return; end if;
         if Code_Point <= 16#7F# then
            Append(Character'Val(Code_Point));
         elsif Code_Point <= 16#7FF# then
            Append(Character'Val(Integer(Unsigned_32'(16#C0#) or (U_Point / 64))));
            Append(Character'Val(Integer(Unsigned_32'(16#80#) or (U_Point mod 64))));
         elsif Code_Point <= 16#FFFF# then
            Append(Character'Val(Integer(Unsigned_32'(16#E0#) or (U_Point / 4096))));
            Append(Character'Val(Integer(Unsigned_32'(16#80#) or ((U_Point / 64) mod 64))));
            Append(Character'Val(Integer(Unsigned_32'(16#80#) or (U_Point mod 64))));
         elsif Code_Point <= 16#10FFFF# then
            Append(Character'Val(Integer(Unsigned_32'(16#F0#) or (U_Point / 262144))));
            Append(Character'Val(Integer(Unsigned_32'(16#80#) or ((U_Point / 4096) mod 64))));
            Append(Character'Val(Integer(Unsigned_32'(16#80#) or ((U_Point / 64) mod 64))));
            Append(Character'Val(Integer(Unsigned_32'(16#80#) or (U_Point mod 64))));
         else
            Append(Character'Val(16#EF#)); Append(Character'Val(16#BF#)); Append(Character'Val(16#BD#));
         end if;
      end Encode_UTF8;

      procedure Read_Hex4 (Result : out Natural; Valid : out Boolean) is
         H : Character;
         Val : Natural := 0;
      begin
         Valid := True;
         for I in 1..4 loop
            Peek_Char(P, H, Valid);
            if not Valid or else not Is_Hex(H) then Valid := False; return; end if;
            Consume_Char(P, H);
            Val := Val * 16 + Hex_Val(H);
         end loop;
         Result := Val;
      end Read_Hex4;

   begin
      Tok.Kind := None;
      Tok.Length := 0;
      Tok.Text := (others => ' ');
      Tok.Line := P.Current_Line;
      Tok.Column := P.Current_Col;

      if not Has_More(P) then Tok.Kind := End_Of_File; return; end if;

      -- 1. SKIP WHITESPACE
      loop
         Peek_Char(P, C, Success);
         if not Success then Tok.Kind := End_Of_File; return; end if;
         if not Is_Space(C) then exit; end if;
         Consume_Char(P, C);
      end loop;

      Tok.Line := P.Current_Line;
      Tok.Column := P.Current_Col;

      Consume_Char(P, C); 

      case C is
         when '{' =>
            Tok.Kind := Start_Object;
            if P.Stack_Top < Max_Depth then P.Stack_Top := P.Stack_Top + 1; P.Stack(P.Stack_Top) := In_Object;
            else P.Error_State := True; Tok.Kind := Error; end if;

         when '}' =>
            Tok.Kind := End_Object;
            if P.Stack_Top > 0 and then P.Stack(P.Stack_Top) = In_Object then P.Stack_Top := P.Stack_Top - 1;
            else P.Error_State := True; Tok.Kind := Error; end if;

         when '[' =>
            Tok.Kind := Start_Array;
             if P.Stack_Top < Max_Depth then P.Stack_Top := P.Stack_Top + 1; P.Stack(P.Stack_Top) := In_Array;
            else P.Error_State := True; Tok.Kind := Error; end if;

         when ']' =>
            Tok.Kind := End_Array;
            if P.Stack_Top > 0 and then P.Stack(P.Stack_Top) = In_Array then P.Stack_Top := P.Stack_Top - 1;
            else P.Error_State := True; Tok.Kind := Error; end if;

         when ':' => Next(P, Tok);
         when ',' => Next(P, Tok);

         when '"' =>
            Tok.Kind := String_Val;
            loop
               Peek_Char(P, Peek_C, Success);
               if not Success then P.Error_State := True; Tok.Kind := Error; return; end if;
               if Is_Control(Peek_C) then P.Error_State := True; Tok.Kind := Error; return; end if;

               Consume_Char(P, C); 

               if C = '"' then
                  exit; 
               elsif C = '\' then
                  Peek_Char(P, Peek_C, Success);
                  if not Success then P.Error_State := True; Tok.Kind := Error; return; end if;
                  Consume_Char(P, C);

                  case C is
                     when '"'  => Append('"');
                     when '\'  => Append('\');
                     when '/'  => Append('/');
                     when 'b'  => Append(ASCII.BS);
                     when 'f'  => Append(ASCII.FF);
                     when 'n'  => Append(ASCII.LF);
                     when 'r'  => Append(ASCII.CR);
                     when 't'  => Append(ASCII.HT);
                     when 'u'  => 
                        declare
                           Val1, Val2, Code_Point : Natural;
                           Hex_Valid : Boolean;
                        begin
                           Read_Hex4(Val1, Hex_Valid);
                           if not Hex_Valid then P.Error_State := True; Tok.Kind := Error; return; end if;

                           if Val1 >= 16#D800# and Val1 <= 16#DBFF# then
                              Peek_Char(P, Peek_C, Success);
                              if Success and Peek_C = '\' then
                                 Consume_Char(P, C); 
                                 Peek_Char(P, Peek_C, Success);
                                 if Success and Peek_C = 'u' then
                                    Consume_Char(P, C);
                                    Read_Hex4(Val2, Hex_Valid);
                                    if Hex_Valid and then (Val2 >= 16#DC00# and Val2 <= 16#DFFF#) then
                                       Code_Point := 16#10000# + (Val1 - 16#D800#) * 16#400# + (Val2 - 16#DC00#);
                                       Encode_UTF8(Code_Point);
                                    else
                                       P.Error_State := True; Tok.Kind := Error; return;
                                    end if;
                                 else
                                    P.Error_State := True; Tok.Kind := Error; return;
                                 end if;
                              else
                                 P.Error_State := True; Tok.Kind := Error; return;
                              end if;
                           else
                              Encode_UTF8(Val1);
                           end if;
                        end;
                     when others => Append(C);
                  end case;
               else
                  Append(C);
               end if;
               
               -- Exit if Append caused error
               if P.Error_State then return; end if;
            end loop;
            Tok.Length := Text_Idx;
            
            loop
               Peek_Char(P, Peek_C, Success);
               if not Success or else not Is_Space(Peek_C) then exit; end if;
               Consume_Char(P, C); 
            end loop;
            if Success and Peek_C = ':' then Tok.Kind := Key; end if;

         when '-' | '0' .. '9' =>
            Tok.Kind := Integer_Val;
            Append(C);
            if C = '0' then
               Peek_Char(P, Peek_C, Success);
               if Success and then Is_Digit(Peek_C) then
                   P.Error_State := True; Tok.Kind := Error; return;
               end if;
            end if;

            -- FIX 2: Strict Number Loop (No dangling dot or exponent)
            loop
               Peek_Char(P, Peek_C, Success);
               if not Success then exit; end if;
               
               if Is_Digit(Peek_C) then
                  Consume_Char(P, C); Append(C);
               elsif Peek_C = '.' then
                  Consume_Char(P, C); Append(C);
                  Tok.Kind := Float_Val;
                  
                  -- DOT must be followed by Digit
                  Peek_Char(P, Peek_C, Success);
                  if not Success or else not Is_Digit(Peek_C) then
                     P.Error_State := True; Tok.Kind := Error; return;
                  end if;
               elsif Peek_C = 'e' or Peek_C = 'E' then
                  Consume_Char(P, C); Append(C);
                  Tok.Kind := Float_Val;
                  
                  -- Exponent Logic
                  Peek_Char(P, Peek_C, Success);
                  if Success and then (Peek_C = '+' or Peek_C = '-') then
                      Consume_Char(P, C); Append(C);
                      Peek_Char(P, Peek_C, Success);
                  end if;
                  
                  -- Exponent/Sign must be followed by Digit
                  if not Success or else not Is_Digit(Peek_C) then
                     P.Error_State := True; Tok.Kind := Error; return;
                  end if;
               else
                  exit; -- End of number
               end if;
               
               if P.Error_State then return; end if;
            end loop;
            Tok.Length := Text_Idx;

         when 't' =>
            for I in 1..3 loop Consume_Char(P, C); Append(C); end loop;
            if Tok.Text(1..3) = "rue" then Tok.Kind := Boolean_Val; Tok.Text(1..4) := "true"; Tok.Length := 4;
            else P.Error_State := True; Tok.Kind := Error; end if;

         when 'f' =>
            for I in 1..4 loop Consume_Char(P, C); Append(C); end loop;
            if Tok.Text(1..4) = "alse" then Tok.Kind := Boolean_Val; Tok.Text(1..5) := "false"; Tok.Length := 5;
            else P.Error_State := True; Tok.Kind := Error; end if;

         when 'n' =>
            for I in 1..3 loop Consume_Char(P, C); Append(C); end loop;
            if Tok.Text(1..3) = "ull" then Tok.Kind := Null_Val; Tok.Text(1..4) := "null"; Tok.Length := 4;
            else P.Error_State := True; Tok.Kind := Error; end if;

         when others =>
            Tok.Kind := Error; P.Error_State := True;
      end case;
   end Next;

end JaySoond;
