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
with ALB_Types;  use ALB_Types;
with Tokenizer;  use Tokenizer;
with Range_Spec; use Range_Spec;
with Numerus_Magnus; use Numerus_Magnus;

package Symbol_Table is

   -- Da absolute limit o' tracked symbols (Rule 3: Nae heap allocation)
   Max_Symbols : constant := 16384;
   Max_Structs : constant := 64;
   Max_Fields  : constant := 32;

   -- DA NEW STORAGE CLASS!
   type Storage_Class is (Class_Global, Class_Local);

   -- DA UPGRADED SYMBOL RECORD!
   type Symbol_Record is record
      Token_Idx : U32 := 0;          -- UPGRADED tae U32
      Tag       : ALB_Type_Tag := Type_None;
      Mem_Ref   : ALB_Reference;
      Class     : Storage_Class := Class_Global;
      Address   : U64 := 0;
      Offset    : Integer := 0;
      Struct_ID : Natural := 0;
      Scope     : Natural := 0;
      Active    : Boolean := False;
   end record;
   
   type Symbol_Array is array (1 .. Max_Symbols) of Symbol_Record;
   
   -- =========================================================================
   -- DA NEW STRUCT REGISTRY
   -- =========================================================================
   type Struct_Field is record
      Token_Idx : U32 := 0;          -- UPGRADED tae U32
      Tag       : ALB_Type_Tag := Type_None;
      Offset    : Natural := 0;
      Active    : Boolean := False;
   end record;
   
   type Field_Array is array (1 .. Max_Fields) of Struct_Field;

   type Struct_Blueprint is record
      Token_Idx   : U32 := 0;        -- UPGRADED tae U32
      Size_Bytes  : Natural := 0;
      Field_Count : Natural := 0;
      Fields      : Field_Array := (others => (Token_Idx => 0, Tag => Type_None, Offset => 0, Active => False));
      Active      : Boolean := False;
   end record;
   type Struct_Array is array (1 .. Max_Structs) of Struct_Blueprint;

   -- Core procedures
   procedure Clear_Table (Success : out Boolean);
   
   -- Da Memory Forges
   procedure Add_Global_Symbol (Token_Idx : in U32; Tag : in ALB_Type_Tag; Ref : in ALB_Reference; Address : in U64; Struct_ID : in Natural; Success : out Boolean);
   procedure Add_Local_Symbol  (Token_Idx : in U32; Tag : in ALB_Type_Tag; Ref : in ALB_Reference; Offset : in Integer; Struct_ID : in Natural; Scope : in Natural; Success : out Boolean);
   procedure Find_Symbol       (Token_Idx : in U32; Scope : in Natural; Found : out Boolean; Sym : out Symbol_Record);
   
   -- DA NEW FORGE: Drops all local symbols at or above a target scope level!
   procedure Drop_Scope        (Target_Scope : in Natural; Success : out Boolean);
   
   
   -- Da Struct Forges
   procedure Register_Struct   (Token_Idx : in U32; Struct_ID : out Natural; Success : out Boolean);
   procedure Add_Struct_Field  (Struct_ID : in Natural; Token_Idx : in U32; Tag : in ALB_Type_Tag; Size_Bytes : in Natural; Success : out Boolean);
   procedure Find_Struct_Field (Struct_ID : in Natural; Token_Idx : in U32; Found : out Boolean; Field : out Struct_Field);
   
   procedure Find_Struct_ID (Token_Idx : in U32; Struct_ID : out Natural; Found : out Boolean);
   
   procedure Get_Struct_Field_Count (Struct_ID : in Natural; Field_Count : out Natural; Success : out Boolean);
   procedure Get_Struct_Token (Struct_ID : in Natural; Token_Idx : out U32; Success : out Boolean);
end Symbol_Table;
