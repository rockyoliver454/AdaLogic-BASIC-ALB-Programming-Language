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

with Ada.Streams.Stream_IO;
with System.Storage_Elements;

package body Cairn_DB is

   use Ada.Streams.Stream_IO;
   use System.Storage_Elements;

   -----------------------------------------------------------------------------
   -- BINARY SEARCH (Verified Logic)
   -----------------------------------------------------------------------------
   function Find_Index (Target : ID_Type) return Integer is
      Left  : Integer := 1;
      Right : Integer := State.Entry_Count;
      Mid   : Integer;
   begin
      -- Safety check for empty DB
      if State.Entry_Count = 0 then
         return 0;
      end if;

      -- SPARK Loop Invariant (Optional, but good for proving termination)
      -- We keep it simple for now; SPARK can usually infer termination here.
      while Left <= Right loop
         Mid := Left + (Right - Left) / 2;
         
         if State.Index(Mid).ID = Target then
            return Mid;
         elsif State.Index(Mid).ID < Target then
            Left := Mid + 1;
         else
            Right := Mid - 1;
         end if;
      end loop;
      
      return 0; -- Not found
   end Find_Index;

   -----------------------------------------------------------------------------
   -- LOAD CAIRN (Unverified - IO)
   -----------------------------------------------------------------------------
   procedure Load_Cairn 
     (Index_File : String; 
      Blob_File  : String;
      Result     : out Cairn_Result)
   with SPARK_Mode => Off
   is
      Idx_File    : File_Type;
      Dat_File    : File_Type;
      File_Stream : Stream_Access;
      Count       : Unsigned_32;
   begin
      -- 1. LOAD INDEX
      begin
         Open (Idx_File, In_File, Index_File);
         File_Stream := Stream(Idx_File);
         
         Unsigned_32'Read(File_Stream, Count);
         
         if Count > Unsigned_32(Max_Entries) then
            Close(Idx_File);
            Result := Database_Full;
            return;
         end if;
         
         State.Entry_Count := Natural(Count);
         
         for I in 1 .. State.Entry_Count loop
            Index_Entry'Read(File_Stream, State.Index(I));
         end loop;
         
         Close (Idx_File);
      exception
         when others =>
            if Is_Open(Idx_File) then Close(Idx_File); end if;
            Result := File_Not_Found;
            return;
      end;

      -- 2. LOAD BLOB
      begin
         Open (Dat_File, In_File, Blob_File);
         File_Stream := Stream(Dat_File);
         
         Blob_Array'Read(File_Stream, State.Blob);
         
         Close (Dat_File);
      exception
         when others =>
            if Is_Open(Dat_File) then Close(Dat_File); end if;
      end;

      Result := Success;
   end Load_Cairn;

   -----------------------------------------------------------------------------
   -- GET ADDRESS (Unverified - Pointer Logic)
   -----------------------------------------------------------------------------
   function Get_Address (ID : ID_Type) return System.Address 
   with SPARK_Mode => Off
   is
      Idx : Integer := Find_Index(ID);
      Offset : Storage_Offset;
   begin
      if Idx = 0 then
         return System.Null_Address;
      end if;
      
      Offset := Storage_Offset(State.Index(Idx).Blob_Offset);
      
      -- Safety Check (Runtime only since SPARK is Off here)
      if Integer(Offset) + 1 > Max_Blob_Size then
         return System.Null_Address;
      end if;

      return State.Blob(1 + Integer(Offset))'Address;
   end Get_Address;

   -----------------------------------------------------------------------------
   -- GET TAG (Verified)
   -----------------------------------------------------------------------------
   function Get_Tag (ID : ID_Type) return Tag_Type is
      Idx : Integer := Find_Index(ID);
   begin
      if Idx = 0 then return 0; end if;
      return State.Index(Idx).Tag;
   end Get_Tag;

   -----------------------------------------------------------------------------
   -- GET SIZE (Verified)
   -----------------------------------------------------------------------------
   function Get_Size (ID : ID_Type) return Size_Type is
      Idx : Integer := Find_Index(ID);
   begin
      if Idx = 0 then return 0; end if;
      return State.Index(Idx).Data_Size;
   end Get_Size;

end Cairn_DB;
