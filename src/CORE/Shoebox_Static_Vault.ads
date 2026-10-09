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

package Shoebox_Static_Vault is

   Max_Files        : constant := 1024;
   Max_Blob_Size    : constant := 16_777_216;
   Header_Size      : constant := 8;
   File_Record_Size : constant := 16;

   subtype U32 is Interfaces.Unsigned_32;

   type Byte is mod 2 ** 8;
   for Byte'Size use 8;

   subtype Byte_Index       is Natural range 0 .. Max_Blob_Size - 1;
   subtype Blob_Length      is Natural range 0 .. Max_Blob_Size;
   subtype File_Index       is Positive range 1 .. Max_Files;
   subtype File_Count_Range is Natural range 0 .. Max_Files;

   type Byte_Array is array (Natural range <>) of Byte;
   for Byte_Array'Component_Size use 8;

   Magic_0 : constant Byte := Byte (Character'Pos ('A'));
   Magic_1 : constant Byte := Byte (Character'Pos ('L'));
   Magic_2 : constant Byte := Byte (Character'Pos ('B'));
   Magic_3 : constant Byte := Byte (Character'Pos ('Z'));

   type Archive_Header is record
      Magic_A    : Byte;
      Magic_L    : Byte;
      Magic_B    : Byte;
      Magic_Z    : Byte;
      File_Count : U32;
   end record;
   for Archive_Header'Alignment use 1;
   for Archive_Header'Size use 64;
   for Archive_Header use record
      Magic_A    at 0 range 0 .. 7;
      Magic_L    at 1 range 0 .. 7;
      Magic_B    at 2 range 0 .. 7;
      Magic_Z    at 3 range 0 .. 7;
      File_Count at 4 range 0 .. 31;
   end record;

   type File_Record is record
      Name_Hash : U32;
      Offset    : U32;
      Comp_Size : U32;
      Raw_Size  : U32;
   end record;
   for File_Record'Alignment use 1;
   for File_Record'Size use 128;
   for File_Record use record
      Name_Hash at 0 range 0 .. 31;
      Offset    at 4 range 0 .. 31;
      Comp_Size at 8 range 0 .. 31;
      Raw_Size  at 12 range 0 .. 31;
   end record;

   type FAT_Array is array (File_Index range <>) of File_Record;
   for FAT_Array'Alignment use 1;
   for FAT_Array'Component_Size use 128;

   VFS_Arena : Byte_Array (0 .. Max_Blob_Size - 1) := (others => 0);

   function Hash_Name_FNV1a (Name : String) return U32;

   function Header_Is_Valid
     (Blob   : Byte_Array;
      Length : Blob_Length) return Boolean
   with Pre => Blob'First = 0 and then Length <= Blob'Length;

   function File_Count_Of
     (Blob   : Byte_Array;
      Length : Blob_Length) return File_Count_Range
   with Pre => Blob'First = 0 and then Header_Is_Valid (Blob, Length);

   procedure Read_File_Record
     (Blob    : in Byte_Array;
      Length  : in Blob_Length;
      Index   : in File_Index;
      Item    : out File_Record;
      Success : out Boolean)
   with Pre => Blob'First = 0 and then Length <= Blob'Length;

   procedure Find_File
     (Blob      : in Byte_Array;
      Length    : in Blob_Length;
      Name_Hash : in U32;
      Item      : out File_Record;
      Found     : out Boolean)
   with Pre => Blob'First = 0 and then Length <= Blob'Length;

   procedure Resolve_Payload_Slice
     (Blob           : in Byte_Array;
      Length         : in Blob_Length;
      Item           : in File_Record;
      Payload_First  : out Blob_Length;
      Payload_Length : out Blob_Length;
      Success        : out Boolean)
   with Pre => Blob'First = 0 and then Length <= Blob'Length;

   procedure Decompress_LZSS
     (Source     : in Byte_Array;
      Source_Len : in Natural;
      Target     : in out Byte_Array;
      Target_Len : out Natural)
   with
     Pre  => Source'First = 0
       and then Source_Len <= Source'Length
       and then Target'First = 0,
     Post => Target_Len <= Target'Length;

end Shoebox_Static_Vault;
