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

with Interfaces;

package body Shoebox_Static_Vault is
   use type Interfaces.Unsigned_32;

   function Read_U32_LE
     (Blob   : Byte_Array;
      Offset : Natural) return U32
   is
   begin
      return U32 (Blob (Offset))
        or Interfaces.Shift_Left (U32 (Blob (Offset + 1)), 8)
        or Interfaces.Shift_Left (U32 (Blob (Offset + 2)), 16)
        or Interfaces.Shift_Left (U32 (Blob (Offset + 3)), 24);
   end Read_U32_LE;

   function Payload_Base_Of (Count : File_Count_Range) return Blob_Length is
   begin
      return Blob_Length (Header_Size + Natural (Count) * File_Record_Size);
   end Payload_Base_Of;

   function Record_Layout_Is_Valid
     (Length : Blob_Length;
      Count  : File_Count_Range;
      Item   : File_Record) return Boolean
   is
      Payload_Base  : constant Natural := Natural (Payload_Base_Of (Count));
      Payload_Bytes : constant Natural := Natural (Length) - Payload_Base;
      Offset_Val    : Natural := 0;
      Comp_Size_Val : Natural := 0;
   begin
      if Item.Offset > U32 (Payload_Bytes) then
         return False;
      end if;

      if Item.Comp_Size > U32 (Max_Blob_Size)
        or else Item.Raw_Size > U32 (Max_Blob_Size)
      then
         return False;
      end if;

      Offset_Val := Natural (Item.Offset);
      Comp_Size_Val := Natural (Item.Comp_Size);

      return Comp_Size_Val <= Payload_Bytes - Offset_Val;
   end Record_Layout_Is_Valid;

   function Hash_Name_FNV1a (Name : String) return U32 is
      Hash : U32 := 16#811C9DC5#;
   begin
      for Ch of Name loop
         Hash := Hash xor U32 (Character'Pos (Ch));
         Hash := Hash * 16#01000193#;
      end loop;

      return Hash;
   end Hash_Name_FNV1a;

   function Header_Is_Valid
     (Blob   : Byte_Array;
      Length : Blob_Length) return Boolean
   is
      Count : U32 := 0;
   begin
      if Length < Header_Size then
         return False;
      end if;

      if Blob (0) /= Magic_0
        or else Blob (1) /= Magic_1
        or else Blob (2) /= Magic_2
        or else Blob (3) /= Magic_3
      then
         return False;
      end if;

      Count := Read_U32_LE (Blob, 4);

      if Count > U32 (Max_Files) then
         return False;
      end if;

      return Payload_Base_Of (File_Count_Range (Count)) <= Length;
   end Header_Is_Valid;

   function File_Count_Of
     (Blob   : Byte_Array;
      Length : Blob_Length) return File_Count_Range
   is
      pragma Unreferenced (Length);
   begin
      return File_Count_Range (Read_U32_LE (Blob, 4));
   end File_Count_Of;

   procedure Read_File_Record
     (Blob    : in Byte_Array;
      Length  : in Blob_Length;
      Index   : in File_Index;
      Item    : out File_Record;
      Success : out Boolean)
   is
      Count        : File_Count_Range := 0;
      Entry_Offset : Natural := 0;
   begin
      Item := (Name_Hash => 0, Offset => 0, Comp_Size => 0, Raw_Size => 0);
      Success := False;

      if not Header_Is_Valid (Blob, Length) then
         return;
      end if;

      Count := File_Count_Of (Blob, Length);
      if Index > Count then
         return;
      end if;

      Entry_Offset := Header_Size + (Natural (Index) - 1) * File_Record_Size;

      Item := (Name_Hash => Read_U32_LE (Blob, Entry_Offset),
               Offset    => Read_U32_LE (Blob, Entry_Offset + 4),
               Comp_Size => Read_U32_LE (Blob, Entry_Offset + 8),
               Raw_Size  => Read_U32_LE (Blob, Entry_Offset + 12));

      Success := Record_Layout_Is_Valid (Length, Count, Item);
      if not Success then
         Item := (Name_Hash => 0, Offset => 0, Comp_Size => 0, Raw_Size => 0);
      end if;
   end Read_File_Record;

   procedure Find_File
     (Blob      : in Byte_Array;
      Length    : in Blob_Length;
      Name_Hash : in U32;
      Item      : out File_Record;
      Found     : out Boolean)
   is
      Count   : File_Count_Range := 0;
      Current : File_Record := (Name_Hash => 0, Offset => 0, Comp_Size => 0, Raw_Size => 0);
      Valid   : Boolean := False;
   begin
      Item := (Name_Hash => 0, Offset => 0, Comp_Size => 0, Raw_Size => 0);
      Found := False;

      if not Header_Is_Valid (Blob, Length) then
         return;
      end if;

      Count := File_Count_Of (Blob, Length);

      for I in 1 .. Count loop
         Read_File_Record (Blob, Length, File_Index (I), Current, Valid);
         if not Valid then
            return;
         end if;

         if Current.Name_Hash = Name_Hash then
            Item := Current;
            Found := True;
            return;
         end if;
      end loop;
   end Find_File;

   procedure Resolve_Payload_Slice
     (Blob           : in Byte_Array;
      Length         : in Blob_Length;
      Item           : in File_Record;
      Payload_First  : out Blob_Length;
      Payload_Length : out Blob_Length;
      Success        : out Boolean)
   is
      Count        : File_Count_Range := 0;
      Payload_Base : Natural := 0;
   begin
      Payload_First := 0;
      Payload_Length := 0;
      Success := False;

      if not Header_Is_Valid (Blob, Length) then
         return;
      end if;

      Count := File_Count_Of (Blob, Length);
      if not Record_Layout_Is_Valid (Length, Count, Item) then
         return;
      end if;

      Payload_Base := Natural (Payload_Base_Of (Count));
      Payload_First := Blob_Length (Payload_Base + Natural (Item.Offset));
      Payload_Length := Blob_Length (Natural (Item.Comp_Size));
      Success := True;
   end Resolve_Payload_Slice;

   procedure Decompress_LZSS
     (Source     : in Byte_Array;
      Source_Len : in Natural;
      Target     : in out Byte_Array;
      Target_Len : out Natural)
   is
      Src_Ptr      : Natural := 0;
      Dst_Ptr      : Natural := 0;
      Control      : Byte := 0;
      Bit_Pos      : Natural range 0 .. 8 := 0;
      Match_Offset : Natural := 0;
      Match_Length : Natural := 0;
   begin
      while Src_Ptr < Source_Len and Dst_Ptr < Target'Length loop
         pragma Loop_Invariant (Src_Ptr <= Source_Len);
         pragma Loop_Invariant (Dst_Ptr <= Target'Length);

         if Bit_Pos = 0 then
            exit when Src_Ptr >= Source_Len;
            Control := Source (Src_Ptr);
            Src_Ptr := Src_Ptr + 1;
            Bit_Pos := 8;
         end if;

         if (Control and 1) = 1 then
            exit when Src_Ptr >= Source_Len or else Dst_Ptr >= Target'Length;
            Target (Dst_Ptr) := Source (Src_Ptr);
            Dst_Ptr := Dst_Ptr + 1;
            Src_Ptr := Src_Ptr + 1;
         else
            exit when Src_Ptr + 1 >= Source_Len;

            Match_Offset := Natural (Source (Src_Ptr));
            Src_Ptr := Src_Ptr + 1;

            Match_Length := Natural (Source (Src_Ptr)) + 3;
            Src_Ptr := Src_Ptr + 1;

            if Match_Offset = 0 or else Match_Offset > Dst_Ptr then
               exit;
            end if;

            for I in 1 .. Match_Length loop
               pragma Loop_Invariant (Dst_Ptr <= Target'Length);
               exit when Dst_Ptr >= Target'Length;
               Target (Dst_Ptr) := Target (Dst_Ptr - Match_Offset);
               Dst_Ptr := Dst_Ptr + 1;
            end loop;
         end if;

         Control := Control / 2;
         Bit_Pos := Bit_Pos - 1;
      end loop;

      Target_Len := Dst_Ptr;
   end Decompress_LZSS;

end Shoebox_Static_Vault;
