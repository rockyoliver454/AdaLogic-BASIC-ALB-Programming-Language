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

with KyuOhAye;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces; use Interfaces;

package body Lib_KyuOhAye is

   function Safe_Value (Ptr : chars_ptr) return String is
   begin
      if Ptr = Null_Ptr then
         return "";
      else
         return Value (Ptr);
      end if;
   end Safe_Value;

   procedure Put_U8 (Base : System.Address; Offset : Integer; V : Unsigned_8) is
      B : Unsigned_8;
      for B'Address use Base + Storage_Offset (Offset);
      pragma Import (Ada, B);
   begin
      B := V;
   end Put_U8;

   function KyuOhAye_Atlas_Min return int is (KYU_ATLAS_MIN);
   function KyuOhAye_Atlas_Max return int is (KYU_ATLAS_MAX);

   function KyuOhAye_Decoder_Size return int is
   begin
      return int (KyuOhAye.Decoder'Size / 8);
   end KyuOhAye_Decoder_Size;

   function KyuOhAye_Open
     (Decoder_Ptr : System.Address;
      Filename    : chars_ptr) return int
   is
      D : KyuOhAye.Decoder;
      pragma Import (Ada, D);
      for D'Address use Decoder_Ptr;
   begin
      KyuOhAye.Open (D, Safe_Value (Filename));
      if KyuOhAye.Is_Open (D) and then not KyuOhAye.Has_Error (D) then
         return 1;
      else
         return 0;
      end if;
   end KyuOhAye_Open;

   function KyuOhAye_Get_Width (Decoder_Ptr : System.Address) return int is
      D : KyuOhAye.Decoder;
      pragma Import (Ada, D);
      for D'Address use Decoder_Ptr;
   begin
      return int (KyuOhAye.Get_Width (D));
   end KyuOhAye_Get_Width;

   function KyuOhAye_Get_Height (Decoder_Ptr : System.Address) return int is
      D : KyuOhAye.Decoder;
      pragma Import (Ada, D);
      for D'Address use Decoder_Ptr;
   begin
      return int (KyuOhAye.Get_Height (D));
   end KyuOhAye_Get_Height;

   function KyuOhAye_Get_Channels (Decoder_Ptr : System.Address) return int is
      D : KyuOhAye.Decoder;
      pragma Import (Ada, D);
      for D'Address use Decoder_Ptr;
   begin
      return int (KyuOhAye.Get_Channels (D));
   end KyuOhAye_Get_Channels;

   function KyuOhAye_Has_Error (Decoder_Ptr : System.Address) return int is
      D : KyuOhAye.Decoder;
      pragma Import (Ada, D);
      for D'Address use Decoder_Ptr;
   begin
      if KyuOhAye.Has_Error (D) then
         return 1;
      else
         return 0;
      end if;
   end KyuOhAye_Has_Error;

   function KyuOhAye_Decode_RGBA
     (Decoder_Ptr : System.Address;
      Dest        : System.Address;
      Dest_Len    : int) return int
   is
      D : KyuOhAye.Decoder;
      pragma Import (Ada, D);
      for D'Address use Decoder_Ptr;

      W : constant Natural := KyuOhAye.Get_Width (D);
      H : constant Natural := KyuOhAye.Get_Height (D);
      Need : Integer;
      P : KyuOhAye.Pixel;
      Offset : Integer := 0;
      Count : Integer := 0;
   begin
      if not KyuOhAye.Is_Open (D) then
         return -1;
      end if;
      if W < 1 or else H < 1 then
         return -1;
      end if;
      if W > Natural (KYU_ATLAS_MAX) or else H > Natural (KYU_ATLAS_MAX) then
         return -1;
      end if;

      Need := Integer (W) * Integer (H) * 4;
      if Dest_Len < int (Need) then
         return -1;
      end if;

      while KyuOhAye.Has_More (D) loop
         KyuOhAye.Next (D, P);
         if KyuOhAye.Has_Error (D) then
            return -1;
         end if;
         Put_U8 (Dest, Offset,     P.R);
         Put_U8 (Dest, Offset + 1, P.G);
         Put_U8 (Dest, Offset + 2, P.B);
         Put_U8 (Dest, Offset + 3, P.A);
         Offset := Offset + 4;
         Count  := Count + 1;
      end loop;

      return int (Count);
   end KyuOhAye_Decode_RGBA;

   procedure KyuOhAye_Close (Decoder_Ptr : System.Address) is
      D : KyuOhAye.Decoder;
      pragma Import (Ada, D);
      for D'Address use Decoder_Ptr;
   begin
      KyuOhAye.Close (D);
   end KyuOhAye_Close;

end Lib_KyuOhAye;
