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
-- Project: KyuOhAye - The 100-Year Image Streamer
-- Description: Formally Verified QOI Decoder in SPARK/Ada 2012
-- Standards:   SPARK 2014, NASA JPL "Power of 10", QOI Spec 1.0
--
-- Author: Rocky L. Oliver
-- Copyright: (c) 2026 Rocky L. Oliver
-- License: Dual-licensed under MIT and BSD 3-Clause
--------------------------------------------------------------------------------

pragma Ada_2012;
pragma SPARK_Mode (On);

with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;

package KyuOhAye is

   -- CONFIGURATION (JPL Rule 2: Fixed Bounds)
   Buffer_Size : constant Positive := 4096;

   -- DATA TYPES
   -- [Spec: 71] "Values are stored as unsigned integers"
   subtype Byte is Interfaces.Unsigned_8;
   
   type Pixel is record
      R, G, B, A : Byte;
   end record;

   type Color_Space_Kind is (SRGB_Linear_Alpha, Linear_All);

   -- OPAQUE DECODER STATE
   type Decoder is limited private;

   -- OPERATIONS
   
   -- Initialize and read the 14-byte Header [Spec: 28]
   procedure Open (D : out Decoder; Filename : in String)
     with Global => null,
          Post => Is_Open(D);

   -- Get the next pixel.
   -- SPARK: We verify that P is derived strictly from D, and D is updated.
   procedure Next (D : in out Decoder; P : out Pixel)
     with Global  => null,
          Depends => (D => D, P => D),
          Pre     => Is_Open(D) and then Has_More(D);

   -- Close the file and reset state
   procedure Close (D : in out Decoder)
     with Global => null;

   -- STATUS QUERIES (Side-effect free)
   function Is_Open (D : Decoder) return Boolean
     with Global => null;

   function Has_More (D : Decoder) return Boolean
     with Global => null;

   function Has_Error (D : Decoder) return Boolean
     with Global => null;
   
   -- METADATA GETTERS
   function Get_Width (D : Decoder) return Natural with Global => null;
   function Get_Height (D : Decoder) return Natural with Global => null;
   function Get_Channels (D : Decoder) return Natural with Global => null;
   function Get_Total_Pixels (D : Decoder) return Natural with Global => null;

private
   
   package SIO renames Ada.Streams.Stream_IO;

   -- [Spec: 44] "A running array [64]... of previously seen pixel values"
   type Index_Array is array (0 .. 63) of Pixel;

   type Decoder is record
      -- File IO State (Limited)
      File     : SIO.File_Type;
      Buffer   : String (1 .. Buffer_Size) := (others => Character'Val(0));
      Buf_Pos  : Natural := 1;
      Buf_Len  : Natural := 0;
      Is_Active: Boolean := False;
      Error    : Boolean := False;

      -- Image Metadata [Spec: 28]
      Width    : Natural := 0;
      Height   : Natural := 0;
      Channels : Natural := 0;
      Space    : Color_Space_Kind := SRGB_Linear_Alpha;

      -- Decoding State
      -- [Spec: 38] "start with r: 0, g: 0, b: 0, a: 255"
      Prev     : Pixel := (0, 0, 0, 255); 
      Cache    : Index_Array := (others => (0, 0, 0, 0));
      
      -- Run-Length State
      Run_Left : Natural := 0; 
      
      -- Progress Tracking
      Pixels_Done : Natural := 0;
      Total_Pixels: Natural := 0;
   end record;

end KyuOhAye;
