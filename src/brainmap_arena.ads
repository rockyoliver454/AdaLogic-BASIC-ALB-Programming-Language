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

with ALB_Dumptruck;
with Galois_Field;
with range_spec;

package Brainmap_Arena
  with SPARK_Mode => On
is
   subtype Real is Float;

   Max_Real_Cells  : constant Positive := 65_536;
   Max_Index_Cells : constant Positive := 32_768;
   Max_Word_Cells  : constant Positive := 32_768;

   Max_Real_Spans  : constant Positive := 256;
   Max_Index_Spans : constant Positive := 128;
   Max_Word_Spans  : constant Positive := 128;

   type Arena_Status is
     (Arena_Ok,
      Arena_Not_Initialized,
      Arena_Already_Initialized,
      Arena_Out_Of_Handles,
      Arena_Out_Of_Storage,
      Arena_Invalid_Handle,
      Arena_Invalid_Offset,
      Arena_Allocator_Error,
      Arena_Dumptruck_Error);

   type Real_Span_Id is range 0 .. Max_Real_Spans;
   type Index_Span_Id is range 0 .. Max_Index_Spans;
   type Word_Span_Id is range 0 .. Max_Word_Spans;

   Null_Real_Span  : constant Real_Span_Id := 0;
   Null_Index_Span : constant Index_Span_Id := 0;
   Null_Word_Span  : constant Word_Span_Id := 0;

   subtype Index_Value is Natural;

   procedure Initialize (Status : out Arena_Status);
   procedure Reset (Status : out Arena_Status);

   function Is_Initialized return Boolean;

   procedure Claim_Real_Span
     (Length : Positive;
      Span   : out Real_Span_Id;
      Status : out Arena_Status);

   procedure Claim_Index_Span
     (Length : Positive;
      Span   : out Index_Span_Id;
      Status : out Arena_Status);

   procedure Claim_Word_Span
     (Length : Positive;
      Span   : out Word_Span_Id;
      Status : out Arena_Status);

   function Real_Span_Length (Span : Real_Span_Id) return Natural;
   function Index_Span_Length (Span : Index_Span_Id) return Natural;
   function Word_Span_Length (Span : Word_Span_Id) return Natural;

   function Real_Span_Alive (Span : Real_Span_Id) return Boolean;
   function Index_Span_Alive (Span : Index_Span_Id) return Boolean;
   function Word_Span_Alive (Span : Word_Span_Id) return Boolean;

   procedure Write_Real
     (Span   : Real_Span_Id;
      Offset : Natural;
      Value  : Real;
      Status : out Arena_Status);

   procedure Read_Real
     (Span   : Real_Span_Id;
      Offset : Natural;
      Value  : out Real;
      Status : out Arena_Status);

   procedure Fill_Real
     (Span   : Real_Span_Id;
      Value  : Real;
      Status : out Arena_Status);

   procedure Accumulate_Real
     (Span   : Real_Span_Id;
      Offset : Natural;
      Change : Real;
      Status : out Arena_Status);

   procedure Copy_Real_Span
     (Source : Real_Span_Id;
      Target : Real_Span_Id;
      Length : Natural;
      Status : out Arena_Status);

   procedure Write_Index
     (Span   : Index_Span_Id;
      Offset : Natural;
      Value  : Index_Value;
      Status : out Arena_Status);

   procedure Read_Index
     (Span   : Index_Span_Id;
      Offset : Natural;
      Value  : out Index_Value;
      Status : out Arena_Status);

   procedure Fill_Index
     (Span   : Index_Span_Id;
      Value  : Index_Value;
      Status : out Arena_Status);

   procedure Write_Word
     (Span   : Word_Span_Id;
      Offset : Natural;
      Value  : Galois_Field.Word;
      Status : out Arena_Status);

   procedure Read_Word
     (Span   : Word_Span_Id;
      Offset : Natural;
      Value  : out Galois_Field.Word;
      Status : out Arena_Status);

   procedure Fill_Word
     (Span   : Word_Span_Id;
      Value  : Galois_Field.Word;
      Status : out Arena_Status);

   procedure Real_Span_Checksum
     (Span     : Real_Span_Id;
      Checksum : out Galois_Field.Word;
      Status   : out Arena_Status);

   procedure Word_Span_Checksum
     (Span     : Word_Span_Id;
      Checksum : out Galois_Field.Word;
      Status   : out Arena_Status);

   procedure Get_Metrics
     (Real_Used     : out Natural;
      Index_Used    : out Natural;
      Word_Used     : out Natural;
      Real_Spans    : out Natural;
      Index_Spans   : out Natural;
      Word_Spans    : out Natural;
      Status        : out Arena_Status);

   function Verify_Real_Access
     (Span   : Real_Span_Id;
      Offset : Natural) return Boolean;

   function Verify_Index_Access
     (Span   : Index_Span_Id;
      Offset : Natural) return Boolean;

   function Verify_Word_Access
     (Span   : Word_Span_Id;
      Offset : Natural) return Boolean;

private
   Invalid_Interval : constant range_spec.RS_Interval :=
     (Lower => 1.0, Upper => 0.0);
end Brainmap_Arena;
