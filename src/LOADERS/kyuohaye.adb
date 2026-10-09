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
--
-- Author: Rocky L. Oliver
-- Copyright: (c) 2026 Rocky L. Oliver
--------------------------------------------------------------------------------

package body KyuOhAye is

   -- HELPER: READ BYTE (Buffered)
   -- SPARK_Mode Off: IO is inherently side-effecting.
   procedure Read_Byte (D : in out Decoder; B : out Byte) 
     with SPARK_Mode => Off 
   is
      use Ada.Streams;
      SE_Buf : Stream_Element_Array (1 .. Stream_Element_Offset(Buffer_Size));
      Last   : Stream_Element_Offset;
   begin
      -- JPL Rule 5: Check buffer consistency
      pragma Assert (D.Buf_Pos >= 1);

      if D.Buf_Pos > D.Buf_Len then
         if SIO.End_Of_File(D.File) then
            D.Error := True; B := 0; return;
         end if;
         
         SIO.Read(D.File, SE_Buf, Last);
         D.Buf_Len := Natural(Last);
         
         for I in 1 .. D.Buf_Len loop
            D.Buffer(I) := Character'Val(SE_Buf(Stream_Element_Offset(I)));
         end loop;
         D.Buf_Pos := 1;
      end if;

      B := Byte(Character'Pos(D.Buffer(D.Buf_Pos)));
      D.Buf_Pos := D.Buf_Pos + 1;
   exception
      when others => D.Error := True; B := 0;
   end Read_Byte;

   -- HELPER: QOI HASH FUNCTION
   -- [Spec: 48] index_position = (r*3 + g*5 + b*7 + a*11) % 64
   function QOI_Hash (P : Pixel) return Integer is
      Val : Integer;
   begin
      Val := Integer(P.R) * 3 + 
             Integer(P.G) * 5 + 
             Integer(P.B) * 7 + 
             Integer(P.A) * 11;
      
      -- JPL Rule 5: Verify range before modulo to prove no overflow
      -- Max val: 255*(3+5+7+11) = 6630
      pragma Assert (Val >= 0 and Val <= 6630); 
      
      return Val mod 64;
   end QOI_Hash;

   -----------------------------------------------------------------------------
   -- OPEN & PARSE HEADER
   -----------------------------------------------------------------------------
   procedure Open (D : out Decoder; Filename : in String) 
     with SPARK_Mode => Off 
   is
      B : Byte;
      Magic : String(1..4);
      
      -- Helper to build 32-bit BE integer [Spec: 28]
      function Read_U32 return Natural is
         B1, B2, B3, B4 : Byte;
         Val : Unsigned_32;
      begin
         Read_Byte(D, B1); Read_Byte(D, B2); Read_Byte(D, B3); Read_Byte(D, B4);
         Val := Shift_Left(Unsigned_32(B1), 24) or
                Shift_Left(Unsigned_32(B2), 16) or
                Shift_Left(Unsigned_32(B3), 8)  or
                Unsigned_32(B4);
         return Natural(Val);
      end Read_U32;

   begin
      -- Explicit Reset
      D.Buf_Pos := 1;
      D.Buf_Len := 0;
      D.Is_Active := False;
      D.Error := False;
      D.Prev := (0, 0, 0, 255);       -- [Spec: 38]
      D.Cache := (others => (0, 0, 0, 0));
      D.Run_Left := 0;
      D.Pixels_Done := 0;

      begin
         SIO.Open(D.File, SIO.In_File, Filename);
         D.Is_Active := True;

         -- 1. Check Magic "qoif" [Spec: 28]
         for I in 1..4 loop Read_Byte(D, B); Magic(I) := Character'Val(B); end loop;
         if Magic /= "qoif" then D.Error := True; return; end if;

         -- 2. Read Dimensions
         D.Width  := Read_U32;
         D.Height := Read_U32;
         if D.Width = 0 or D.Height = 0 then D.Error := True; return; end if;
         
         D.Total_Pixels := D.Width * D.Height;
         pragma Assert (D.Total_Pixels > 0); -- JPL Rule 5

         -- 3. Channels & Colorspace [Spec: 29]
         Read_Byte(D, B); D.Channels := Natural(B);
         Read_Byte(D, B); 
         if B = 1 then D.Space := Linear_All; else D.Space := SRGB_Linear_Alpha; end if;

      exception
         when others => D.Error := True; D.Is_Active := False;
      end;
   end Open;

   -----------------------------------------------------------------------------
   -- NEXT PIXEL
   -----------------------------------------------------------------------------
   procedure Next (D : in out Decoder; P : out Pixel) is
      B1, B2 : Byte;
      Tag2   : Byte;
      Diff_G, Dr_Dg, Db_Dg : Byte;
      Idx : Integer;
   begin
      -- JPL Rule 5: Ensure we don't overrun total pixels
      pragma Assert (D.Pixels_Done < D.Total_Pixels);

      -- 1. HANDLE RUN STATE [Spec: 93]
      if D.Run_Left > 0 then
         D.Run_Left := D.Run_Left - 1;
         P := D.Prev;
         D.Pixels_Done := D.Pixels_Done + 1;
         return;
      end if;

      -- 2. READ NEXT OP TAG [Spec: 49]
      Read_Byte(D, B1);
      if D.Error then P := D.Prev; return; end if;

      -- 3. CHECK 8-BIT TAGS [Spec: 52]
      if B1 = 254 then -- QOI_OP_RGB (0xFE) [Spec: 55]
         Read_Byte(D, P.R);
         Read_Byte(D, P.G);
         Read_Byte(D, P.B);
         P.A := D.Prev.A;

      elsif B1 = 255 then -- QOI_OP_RGBA (0xFF) [Spec: 83]
         Read_Byte(D, P.R);
         Read_Byte(D, P.G);
         Read_Byte(D, P.B);
         Read_Byte(D, P.A);

      else
         -- 4. CHECK 2-BIT TAGS
         Tag2 := B1 and 2#1100_0000#; 

         case Tag2 is
            when 2#0000_0000# => -- QOI_OP_INDEX (00) [Spec: 30]
               Idx := Integer(B1 and 63); 
               P := D.Cache(Idx);

            when 2#0100_0000# => -- QOI_OP_DIFF (01) [Spec: 67]
               -- Bias 2: Stored 0..3 maps to -2..1
               -- Wraparound handled by Modular Type 'Byte' [Spec: 70]
               P.R := D.Prev.R + (Shift_Right(B1, 4) and 3) - 2;
               P.G := D.Prev.G + (Shift_Right(B1, 2) and 3) - 2;
               P.B := D.Prev.B + (B1 and 3) - 2;
               P.A := D.Prev.A;

            when 2#1000_0000# => -- QOI_OP_LUMA (10) [Spec: 74]
               Read_Byte(D, B2);
               
               -- Green Diff: Bias 32 [Spec: 81]
               Diff_G := (B1 and 63) - 32;
               P.G    := D.Prev.G + Diff_G;

               -- Red/Blue Dr_Dg: Bias 8
               Dr_Dg := (Shift_Right(B2, 4) and 15) - 8;
               Db_Dg := (B2 and 15) - 8;

               P.R := D.Prev.R + Diff_G + Dr_Dg;
               P.B := D.Prev.B + Diff_G + Db_Dg;
               P.A := D.Prev.A;

            when 2#1100_0000# => -- QOI_OP_RUN (11) [Spec: 85]
               -- Bias 1: Stored 0..61 maps to run 1..62 [Spec: 94]
               -- D.Run_Left represents "repetitions AFTER this one"
               D.Run_Left := Integer(B1 and 63); 
               P := D.Prev;
               
               -- JPL Rule 5: Assert valid run length logic
               pragma Assert (D.Run_Left >= 0 and D.Run_Left <= 62);

            when others =>
               D.Error := True; -- Unreachable given 2-bit mask
         end case;
      end if;

      -- 5. UPDATE CACHE & STATE
      D.Prev := P;
      Idx := QOI_Hash(P);
      D.Cache(Idx) := P;
      
      D.Pixels_Done := D.Pixels_Done + 1;
      
      -- JPL Rule 5: Post-condition check
      pragma Assert (D.Pixels_Done <= D.Total_Pixels);

   end Next;

   procedure Close (D : in out Decoder) is
   begin
      if SIO.Is_Open(D.File) then SIO.Close(D.File); end if;
      D.Is_Active := False;
   end Close;

   -- GETTERS
   function Is_Open (D : Decoder) return Boolean is (D.Is_Active);
   function Has_More (D : Decoder) return Boolean is 
      (D.Is_Active and not D.Error and D.Pixels_Done < D.Total_Pixels);
   function Has_Error (D : Decoder) return Boolean is (D.Error);
   function Get_Width (D : Decoder) return Natural is (D.Width);
   function Get_Height (D : Decoder) return Natural is (D.Height);
   function Get_Channels (D : Decoder) return Natural is (D.Channels);
   function Get_Total_Pixels (D : Decoder) return Natural is (D.Total_Pixels);

end KyuOhAye;
