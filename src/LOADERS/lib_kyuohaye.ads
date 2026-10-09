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

--------------------------------------------------------------------------------
-- Lib_KyuOhAye — C ABI for the KyuOhAye QOI decoder
--
-- Atlas policy (Cel Nav dual-assets):
--   Minimum image : 1 x 1
--   Soft maximum  : 8192 x 8192  (documented; not hard-coded in Ada)
--   Pixels are decoded into a caller-owned RGBA8 buffer (no Ada heap).
--------------------------------------------------------------------------------
pragma Ada_2012;

with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;
with Interfaces; use Interfaces;

package Lib_KyuOhAye is

   -- Soft atlas bounds for host code (not enforced as SPARK generics).
   KYU_ATLAS_MIN : constant int := 1;
   KYU_ATLAS_MAX : constant int := 8192;

   function KyuOhAye_Atlas_Min return int;
   pragma Export (C, KyuOhAye_Atlas_Min, "KyuOhAye_Atlas_Min");

   function KyuOhAye_Atlas_Max return int;
   pragma Export (C, KyuOhAye_Atlas_Max, "KyuOhAye_Atlas_Max");

   function KyuOhAye_Decoder_Size return int;
   pragma Export (C, KyuOhAye_Decoder_Size, "KyuOhAye_Decoder_Size");

   -- Open a .qoi file. Returns 1 on success, 0 on failure.
   function KyuOhAye_Open
     (Decoder_Ptr : System.Address;
      Filename    : chars_ptr) return int;
   pragma Export (C, KyuOhAye_Open, "KyuOhAye_Open");

   function KyuOhAye_Get_Width  (Decoder_Ptr : System.Address) return int;
   pragma Export (C, KyuOhAye_Get_Width, "KyuOhAye_Get_Width");

   function KyuOhAye_Get_Height (Decoder_Ptr : System.Address) return int;
   pragma Export (C, KyuOhAye_Get_Height, "KyuOhAye_Get_Height");

   function KyuOhAye_Get_Channels (Decoder_Ptr : System.Address) return int;
   pragma Export (C, KyuOhAye_Get_Channels, "KyuOhAye_Get_Channels");

   function KyuOhAye_Has_Error (Decoder_Ptr : System.Address) return int;
   pragma Export (C, KyuOhAye_Has_Error, "KyuOhAye_Has_Error");

   -- Decode all remaining pixels into RGBA8 Dest.
   -- Dest_Len must be >= width*height*4.
   -- Returns number of pixels written, or -1 on error / overflow.
   function KyuOhAye_Decode_RGBA
     (Decoder_Ptr : System.Address;
      Dest        : System.Address;
      Dest_Len    : int) return int;
   pragma Export (C, KyuOhAye_Decode_RGBA, "KyuOhAye_Decode_RGBA");

   procedure KyuOhAye_Close (Decoder_Ptr : System.Address);
   pragma Export (C, KyuOhAye_Close, "KyuOhAye_Close");

end Lib_KyuOhAye;
