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

package body Symbol_Table is

   Table : Symbol_Array := (others => (Token_Idx => 0, Tag => Type_None, Mem_Ref => (Target => Target_None, Index => 0), Class => Class_Global, Address => 0, Offset => 0, Struct_ID => 0, Scope => 0, Active => False));
   Count : Natural := 0;

   Structs : Struct_Array := (others => (Token_Idx => 0, Size_Bytes => 0, Field_Count => 0, Fields => (others => (Token_Idx => 0, Tag => Type_None, Offset => 0, Active => False)), Active => False));
   Struct_Count : Natural := 0;

   procedure Clear_Table (Success : out Boolean) is
   begin
      Count := 0;
      Struct_Count := 0;
      Table := (others => (Token_Idx => 0, Tag => Type_None, Mem_Ref => (Target => Target_None, Index => 0), Class => Class_Global, Address => 0, Offset => 0, Struct_ID => 0, Scope => 0, Active => False));
      Structs := (others => (Token_Idx => 0, Size_Bytes => 0, Field_Count => 0, Fields => (others => (Token_Idx => 0, Tag => Type_None, Offset => 0, Active => False)), Active => False));
      Success := True;
   end Clear_Table;

   procedure Find_Symbol (Token_Idx : in U32; Scope : in Natural; Found : out Boolean; Sym : out Symbol_Record) is
      Safe_Bounds : RS_Interval; Valid_Range : Boolean;
      Best_Scope  : Natural := 0;
   begin
      Found := False;
      Sym := (0, Type_None, (Target_None, 0), Class_Global, 0, 0, 0, 0, False);
      -- DA FIX: Use 1.0 boundary for Monad Logic
      Range_Spec.Create (1.0, Long_Float(Max_Symbols + 1), Safe_Bounds, Valid_Range);
      if not Valid_Range or else not Range_Spec.Contains (Safe_Bounds, Long_Float(Count + 1)) then return; end if;

      for I in 1 .. Max_Symbols loop
         exit when I > Count;
         if Table(I).Active and then Table(I).Token_Idx = Token_Idx and then Table(I).Scope <= Scope then
            if (not Found) or else Table(I).Scope >= Best_Scope then
               Sym := Table(I);
               Found := True;
               Best_Scope := Table(I).Scope;
            end if;
         end if;
      end loop;
   end Find_Symbol;
   
   
   procedure Drop_Scope (Target_Scope : in Natural; Success : out Boolean) is
   begin
      Success := True;
      for I in 1 .. Max_Symbols loop
         exit when I > Count;
         
         -- If it's an active local variable at or deeper than the target scope, slay it!
         if Table(I).Active and then Table(I).Class = Class_Local and then Table(I).Scope >= Target_Scope then
            Table(I).Active := False;
         end if;
      end loop;
   end Drop_Scope;
   
   procedure Add_Global_Symbol (Token_Idx : in U32; Tag : in ALB_Type_Tag; Ref : in ALB_Reference; Address : in U64; Struct_ID : in Natural; Success : out Boolean) is
   begin
      if Count >= Max_Symbols then Success := False; return; end if;

      Count := Count + 1;
      Table(Count) := (Token_Idx, Tag, Ref, Class_Global, Address, 0, Struct_ID, 0, True);
      Success := True;
   end Add_Global_Symbol;

   procedure Add_Local_Symbol (Token_Idx : in U32; Tag : in ALB_Type_Tag; Ref : in ALB_Reference; Offset : in Integer; Struct_ID : in Natural; Scope : in Natural; Success : out Boolean) is
   begin
      if Count >= Max_Symbols then Success := False; return; end if;

      Count := Count + 1;
      Table(Count) := (Token_Idx, Tag, Ref, Class_Local, 0, Offset, Struct_ID, Scope, True);
      Success := True;
   end Add_Local_Symbol;

   procedure Register_Struct (Token_Idx : in U32; Struct_ID : out Natural; Success : out Boolean) is
   begin
      Struct_ID := 0;
      if Struct_Count >= Max_Structs then Success := False; return; end if;

      Struct_Count := Struct_Count + 1;
      Structs(Struct_Count).Token_Idx := Token_Idx; -- DA FIX: U32 matches U32!
      Structs(Struct_Count).Active := True;
      Struct_ID := Struct_Count;
      Success := True;
   end Register_Struct;

   procedure Add_Struct_Field (Struct_ID : in Natural; Token_Idx : in U32; Tag : in ALB_Type_Tag; Size_Bytes : in Natural; Success : out Boolean) is
      F_Count : Natural;
   begin
      if Struct_ID < 1 or Struct_ID > Struct_Count then Success := False; return; end if;
      
      F_Count := Structs(Struct_ID).Field_Count;
      if F_Count >= Max_Fields then Success := False; return; end if;

      Structs(Struct_ID).Field_Count := F_Count + 1;
      -- DA FIX: Token_Idx is now U32
      Structs(Struct_ID).Fields(F_Count + 1) := (Token_Idx, Tag, Structs(Struct_ID).Size_Bytes, True);
      Structs(Struct_ID).Size_Bytes := Structs(Struct_ID).Size_Bytes + Size_Bytes;
      Success := True;
   end Add_Struct_Field;

   procedure Find_Struct_Field (Struct_ID : in Natural; Token_Idx : in U32; Found : out Boolean; Field : out Struct_Field) is
   begin
      Found := False;
      Field := (0, Type_None, 0, False);
      if Struct_ID < 1 or Struct_ID > Struct_Count then return; end if;

      for I in 1 .. Max_Fields loop
         exit when I > Structs(Struct_ID).Field_Count;
         if Structs(Struct_ID).Fields(I).Active and then Structs(Struct_ID).Fields(I).Token_Idx = Token_Idx then
            Field := Structs(Struct_ID).Fields(I);
            Found := True;
            return;
         end if;
      end loop;
   end Find_Struct_Field;
   
   procedure Find_Struct_ID (Token_Idx : in U32; Struct_ID : out Natural; Found : out Boolean) is
   begin
      Found := False; Struct_ID := 0;
      for I in 1 .. Struct_Count loop
         if Structs(I).Active and then Structs(I).Token_Idx = Token_Idx then
            Struct_ID := I; Found := True; return;
         end if;
      end loop;
   end Find_Struct_ID;
   
   procedure Get_Struct_Field_Count (Struct_ID : in Natural; Field_Count : out Natural; Success : out Boolean) is
   begin
   Field_Count := 0;
      if Struct_ID < 1 or else Struct_ID > Struct_Count then
      Success := False; return;
      end if;
      Field_Count := Structs(Struct_ID).Field_Count;
   Success := True;
   end Get_Struct_Field_Count;
   
   procedure Get_Struct_Token (Struct_ID : in Natural; Token_Idx : out U32; Success : out Boolean) is
   begin
      Token_Idx := 0;
      if Struct_ID < 1 or else Struct_ID > Struct_Count then
         Success := False; 
         return;
      end if;
      Token_Idx := Structs(Struct_ID).Token_Idx;
      Success := True;
   end Get_Struct_Token;

end Symbol_Table;
