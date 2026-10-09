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

with ALB_Dumptruck;     use ALB_Dumptruck;
with Galois_Field;      use Galois_Field;
with memory_allocator;  use memory_allocator;
with range_spec;        use range_spec;

package body Brainmap_Arena
  with SPARK_Mode => On
is
   Arena_Pool_Bytes : constant Pool_Index := 2_097_152;

   subtype Real_Cell_Index is Positive range 1 .. Max_Real_Cells;
   subtype Index_Cell_Index is Positive range 1 .. Max_Index_Cells;
   subtype Word_Cell_Index is Positive range 1 .. Max_Word_Cells;

   type Real_Cells is array (Real_Cell_Index) of Real;
   type Index_Cells is array (Index_Cell_Index) of Index_Value;
   type Word_Cells is array (Word_Cell_Index) of Word;

   type Real_Span_Record is record
      Active : Boolean := False;
      Token  : Link_ID := 0;
      Start  : Natural range 0 .. Max_Real_Cells := 0;
      Length : Natural range 0 .. Max_Real_Cells := 0;
      Bounds : RS_Interval := Invalid_Interval;
   end record;

   type Index_Span_Record is record
      Active : Boolean := False;
      Token  : Link_ID := 0;
      Start  : Natural range 0 .. Max_Index_Cells := 0;
      Length : Natural range 0 .. Max_Index_Cells := 0;
      Bounds : RS_Interval := Invalid_Interval;
   end record;

   type Word_Span_Record is record
      Active : Boolean := False;
      Token  : Link_ID := 0;
      Start  : Natural range 0 .. Max_Word_Cells := 0;
      Length : Natural range 0 .. Max_Word_Cells := 0;
      Bounds : RS_Interval := Invalid_Interval;
   end record;

   type Real_Span_Table is
     array (Real_Span_Id range 1 .. Real_Span_Id (Max_Real_Spans))
       of Real_Span_Record;
   type Index_Span_Table is
     array (Index_Span_Id range 1 .. Index_Span_Id (Max_Index_Spans))
       of Index_Span_Record;
   type Word_Span_Table is
     array (Word_Span_Id range 1 .. Word_Span_Id (Max_Word_Spans))
       of Word_Span_Record;

   Real_Store  : Real_Cells := (others => 0.0);
   Index_Store : Index_Cells := (others => 0);
   Word_Store  : Word_Cells := (others => 0);

   Real_Spans  : Real_Span_Table := (others => (others => <>));
   Index_Spans : Index_Span_Table := (others => (others => <>));
   Word_Spans  : Word_Span_Table := (others => (others => <>));

   Initialized : Boolean := False;

   Next_Real_Cell  : Natural range 1 .. Max_Real_Cells + 1 := 1;
   Next_Index_Cell : Natural range 1 .. Max_Index_Cells + 1 := 1;
   Next_Word_Cell  : Natural range 1 .. Max_Word_Cells + 1 := 1;

   Real_Span_Count  : Natural := 0;
   Index_Span_Count : Natural := 0;
   Word_Span_Count  : Natural := 0;

   function Bytes_For (Length : Positive) return Pool_Index is
   begin
      return Pool_Index (Length * 4);
   end Bytes_For;

   function Real_To_Word (Value : Real) return Word is
      Magnitude : Real := Value;
      Sign_Bit  : Word := 0;
      Scaled    : Word := 0;
   begin
      if Magnitude < 0.0 then
         Magnitude := -Magnitude;
         Sign_Bit := 16#8000_0000#;
      end if;

      if Magnitude > 4_294_967.0 then
         Scaled := 4_294_967_295;
      else
         Scaled := Word (Magnitude * 1000.0);
      end if;

      return Sign_Bit xor Scaled;
   end Real_To_Word;

   procedure Release_Token (Token : in out Link_ID) is
      Success     : Boolean := False;
      Freed_Nodes : Natural := 0;
   begin
      if Token > 0 then
         Drop_Reference (Node_ID (Token), Success);
         if Success then
            Run_Incremental_Sweep (Chunk_Size => 16,
                                   Freed_Nodes => Freed_Nodes,
                                   Success => Success);
         end if;
         Token := 0;
      end if;
   end Release_Token;

   procedure Build_Real_Bounds
     (Start  : Natural;
      Length : Positive;
      Bounds : out RS_Interval;
      Status : out Arena_Status) is
      Success : Boolean := False;
   begin
      Create (Val_A   => Long_Float (Start),
              Val_B   => Long_Float (Start + Length - 1),
              Result  => Bounds,
              Success => Success);
      if Success then
         Status := Arena_Ok;
      else
         Bounds := Invalid_Interval;
         Status := Arena_Allocator_Error;
      end if;
   end Build_Real_Bounds;

   procedure Build_Index_Bounds
     (Start  : Natural;
      Length : Positive;
      Bounds : out RS_Interval;
      Status : out Arena_Status) is
      Success : Boolean := False;
   begin
      Create (Val_A   => Long_Float (Start),
              Val_B   => Long_Float (Start + Length - 1),
              Result  => Bounds,
              Success => Success);
      if Success then
         Status := Arena_Ok;
      else
         Bounds := Invalid_Interval;
         Status := Arena_Allocator_Error;
      end if;
   end Build_Index_Bounds;

   procedure Build_Word_Bounds
     (Start  : Natural;
      Length : Positive;
      Bounds : out RS_Interval;
      Status : out Arena_Status) is
      Success : Boolean := False;
   begin
      Create (Val_A   => Long_Float (Start),
              Val_B   => Long_Float (Start + Length - 1),
              Result  => Bounds,
              Success => Success);
      if Success then
         Status := Arena_Ok;
      else
         Bounds := Invalid_Interval;
         Status := Arena_Allocator_Error;
      end if;
   end Build_Word_Bounds;

   function Find_Free_Real_Span return Real_Span_Id is
   begin
      for Span in Real_Spans'Range loop
         if not Real_Spans (Span).Active then
            return Span;
         end if;
      end loop;
      return Null_Real_Span;
   end Find_Free_Real_Span;

   function Find_Free_Index_Span return Index_Span_Id is
   begin
      for Span in Index_Spans'Range loop
         if not Index_Spans (Span).Active then
            return Span;
         end if;
      end loop;
      return Null_Index_Span;
   end Find_Free_Index_Span;

   function Find_Free_Word_Span return Word_Span_Id is
   begin
      for Span in Word_Spans'Range loop
         if not Word_Spans (Span).Active then
            return Span;
         end if;
      end loop;
      return Null_Word_Span;
   end Find_Free_Word_Span;

   procedure Resolve_Real_Index
     (Span   : Real_Span_Id;
      Offset : Natural;
      Index  : out Real_Cell_Index;
      Success : out Boolean) is
      Absolute : Natural := 0;
   begin
      Index := Real_Cell_Index'First;
      Success := False;
      if Span = Null_Real_Span or else not Real_Spans (Span).Active then
         return;
      end if;
      if Offset >= Real_Spans (Span).Length then
         return;
      end if;
      Absolute := Real_Spans (Span).Start + Offset;
      if Absolute = 0 or else Absolute > Max_Real_Cells then
         return;
      end if;
      Index := Real_Cell_Index (Absolute);
      Success :=
        Verify_Access (Real_Spans (Span).Bounds, Long_Float (Absolute));
   end Resolve_Real_Index;

   procedure Resolve_Index_Cell
     (Span   : Index_Span_Id;
      Offset : Natural;
      Index  : out Index_Cell_Index;
      Success : out Boolean) is
      Absolute : Natural := 0;
   begin
      Index := Index_Cell_Index'First;
      Success := False;
      if Span = Null_Index_Span or else not Index_Spans (Span).Active then
         return;
      end if;
      if Offset >= Index_Spans (Span).Length then
         return;
      end if;
      Absolute := Index_Spans (Span).Start + Offset;
      if Absolute = 0 or else Absolute > Max_Index_Cells then
         return;
      end if;
      Index := Index_Cell_Index (Absolute);
      Success :=
        Verify_Access (Index_Spans (Span).Bounds, Long_Float (Absolute));
   end Resolve_Index_Cell;

   procedure Resolve_Word_Cell
     (Span   : Word_Span_Id;
      Offset : Natural;
      Index  : out Word_Cell_Index;
      Success : out Boolean) is
      Absolute : Natural := 0;
   begin
      Index := Word_Cell_Index'First;
      Success := False;
      if Span = Null_Word_Span or else not Word_Spans (Span).Active then
         return;
      end if;
      if Offset >= Word_Spans (Span).Length then
         return;
      end if;
      Absolute := Word_Spans (Span).Start + Offset;
      if Absolute = 0 or else Absolute > Max_Word_Cells then
         return;
      end if;
      Index := Word_Cell_Index (Absolute);
      Success :=
        Verify_Access (Word_Spans (Span).Bounds, Long_Float (Absolute));
   end Resolve_Word_Cell;

   procedure Initialize (Status : out Arena_Status) is
      Pool_Space        : Pool_Index := 0;
      Pool_Ready        : Boolean := False;
      Dumptruck_Peak    : Natural := 0;
      Dumptruck_Ready   : Boolean := False;
      Bootstrap_Success : Boolean := False;
   begin
      if Initialized then
         Status := Arena_Already_Initialized;
      else
         Get_Space_Left (Space => Pool_Space, Success => Pool_Ready);
         if not Pool_Ready then
            Alloc_Static_Pool (Total_Bytes => Arena_Pool_Bytes,
                               Success     => Bootstrap_Success);
            if not Bootstrap_Success then
               Status := Arena_Allocator_Error;
               return;
            end if;
         end if;

         Get_Peak_Nodes (Peak => Dumptruck_Peak, Success => Dumptruck_Ready);
         if not Dumptruck_Ready then
            Ignite_Dumptruck (Success => Bootstrap_Success);
            if not Bootstrap_Success then
               Status := Arena_Dumptruck_Error;
               return;
            end if;
         end if;

         Initialized := True;
         Next_Real_Cell := 1;
         Next_Index_Cell := 1;
         Next_Word_Cell := 1;
         Real_Span_Count := 0;
         Index_Span_Count := 0;
         Word_Span_Count := 0;
         Status := Arena_Ok;
      end if;
   end Initialize;

   procedure Reset (Status : out Arena_Status) is
      Success : Boolean := False;
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      for Span in Real_Spans'Range loop
         Release_Token (Real_Spans (Span).Token);
         Real_Spans (Span).Active := False;
         Real_Spans (Span).Start := 0;
         Real_Spans (Span).Length := 0;
         Real_Spans (Span).Bounds := Invalid_Interval;
      end loop;

      for Span in Index_Spans'Range loop
         Release_Token (Index_Spans (Span).Token);
         Index_Spans (Span).Active := False;
         Index_Spans (Span).Start := 0;
         Index_Spans (Span).Length := 0;
         Index_Spans (Span).Bounds := Invalid_Interval;
      end loop;

      for Span in Word_Spans'Range loop
         Release_Token (Word_Spans (Span).Token);
         Word_Spans (Span).Active := False;
         Word_Spans (Span).Start := 0;
         Word_Spans (Span).Length := 0;
         Word_Spans (Span).Bounds := Invalid_Interval;
      end loop;

      Next_Real_Cell := 1;
      Next_Index_Cell := 1;
      Next_Word_Cell := 1;
      Real_Span_Count := 0;
      Index_Span_Count := 0;
      Word_Span_Count := 0;

      Real_Store := (others => 0.0);
      Index_Store := (others => 0);
      Word_Store := (others => 0);

      Reset_Pool (Success);
      if Success then
         Status := Arena_Ok;
      else
         Status := Arena_Allocator_Error;
      end if;
   end Reset;

   function Is_Initialized return Boolean is
   begin
      return Initialized;
   end Is_Initialized;

   procedure Claim_Real_Span
     (Length : Positive;
      Span   : out Real_Span_Id;
      Status : out Arena_Status) is
      Alloc_Success : Boolean := False;
      Token_Node    : Node_ID := Node_ID'First;
      Token_Success : Boolean := False;
   begin
      Span := Null_Real_Span;

      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if Find_Free_Real_Span = Null_Real_Span then
         Status := Arena_Out_Of_Handles;
         return;
      end if;

      if Next_Real_Cell + Length - 1 > Max_Real_Cells then
         Status := Arena_Out_Of_Storage;
         return;
      end if;

      Claim_Strict_Block (Req_Bytes => Bytes_For (Length),
                          Bounds    => Real_Spans (Find_Free_Real_Span).Bounds,
                          Success   => Alloc_Success);
      if not Alloc_Success then
         Status := Arena_Allocator_Error;
         return;
      end if;

      Grab_New_Node (ID => Token_Node, Success => Token_Success);
      if not Token_Success then
         Status := Arena_Dumptruck_Error;
         return;
      end if;

      Span := Find_Free_Real_Span;
      Real_Spans (Span).Active := True;
      Real_Spans (Span).Token := Link_ID (Token_Node);
      Real_Spans (Span).Start := Next_Real_Cell;
      Real_Spans (Span).Length := Length;
      Build_Real_Bounds (Start  => Next_Real_Cell,
                         Length => Length,
                         Bounds => Real_Spans (Span).Bounds,
                         Status => Status);
      if Status /= Arena_Ok then
         Real_Spans (Span).Active := False;
         Release_Token (Real_Spans (Span).Token);
         Span := Null_Real_Span;
         return;
      end if;

      Next_Real_Cell := Next_Real_Cell + Length;
      Real_Span_Count := Real_Span_Count + 1;
   end Claim_Real_Span;

   procedure Claim_Index_Span
     (Length : Positive;
      Span   : out Index_Span_Id;
      Status : out Arena_Status) is
      Alloc_Success : Boolean := False;
      Token_Node    : Node_ID := Node_ID'First;
      Token_Success : Boolean := False;
   begin
      Span := Null_Index_Span;

      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if Find_Free_Index_Span = Null_Index_Span then
         Status := Arena_Out_Of_Handles;
         return;
      end if;

      if Next_Index_Cell + Length - 1 > Max_Index_Cells then
         Status := Arena_Out_Of_Storage;
         return;
      end if;

      Claim_Strict_Block (Req_Bytes => Bytes_For (Length),
                          Bounds    => Index_Spans (Find_Free_Index_Span).Bounds,
                          Success   => Alloc_Success);
      if not Alloc_Success then
         Status := Arena_Allocator_Error;
         return;
      end if;

      Grab_New_Node (ID => Token_Node, Success => Token_Success);
      if not Token_Success then
         Status := Arena_Dumptruck_Error;
         return;
      end if;

      Span := Find_Free_Index_Span;
      Index_Spans (Span).Active := True;
      Index_Spans (Span).Token := Link_ID (Token_Node);
      Index_Spans (Span).Start := Next_Index_Cell;
      Index_Spans (Span).Length := Length;
      Build_Index_Bounds (Start  => Next_Index_Cell,
                          Length => Length,
                          Bounds => Index_Spans (Span).Bounds,
                          Status => Status);
      if Status /= Arena_Ok then
         Index_Spans (Span).Active := False;
         Release_Token (Index_Spans (Span).Token);
         Span := Null_Index_Span;
         return;
      end if;

      Next_Index_Cell := Next_Index_Cell + Length;
      Index_Span_Count := Index_Span_Count + 1;
   end Claim_Index_Span;

   procedure Claim_Word_Span
     (Length : Positive;
      Span   : out Word_Span_Id;
      Status : out Arena_Status) is
      Alloc_Success : Boolean := False;
      Token_Node    : Node_ID := Node_ID'First;
      Token_Success : Boolean := False;
   begin
      Span := Null_Word_Span;

      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if Find_Free_Word_Span = Null_Word_Span then
         Status := Arena_Out_Of_Handles;
         return;
      end if;

      if Next_Word_Cell + Length - 1 > Max_Word_Cells then
         Status := Arena_Out_Of_Storage;
         return;
      end if;

      Claim_Strict_Block (Req_Bytes => Bytes_For (Length),
                          Bounds    => Word_Spans (Find_Free_Word_Span).Bounds,
                          Success   => Alloc_Success);
      if not Alloc_Success then
         Status := Arena_Allocator_Error;
         return;
      end if;

      Grab_New_Node (ID => Token_Node, Success => Token_Success);
      if not Token_Success then
         Status := Arena_Dumptruck_Error;
         return;
      end if;

      Span := Find_Free_Word_Span;
      Word_Spans (Span).Active := True;
      Word_Spans (Span).Token := Link_ID (Token_Node);
      Word_Spans (Span).Start := Next_Word_Cell;
      Word_Spans (Span).Length := Length;
      Build_Word_Bounds (Start  => Next_Word_Cell,
                         Length => Length,
                         Bounds => Word_Spans (Span).Bounds,
                         Status => Status);
      if Status /= Arena_Ok then
         Word_Spans (Span).Active := False;
         Release_Token (Word_Spans (Span).Token);
         Span := Null_Word_Span;
         return;
      end if;

      Next_Word_Cell := Next_Word_Cell + Length;
      Word_Span_Count := Word_Span_Count + 1;
   end Claim_Word_Span;

   function Real_Span_Length (Span : Real_Span_Id) return Natural is
   begin
      if Span = Null_Real_Span or else not Real_Spans (Span).Active then
         return 0;
      end if;
      return Real_Spans (Span).Length;
   end Real_Span_Length;

   function Index_Span_Length (Span : Index_Span_Id) return Natural is
   begin
      if Span = Null_Index_Span or else not Index_Spans (Span).Active then
         return 0;
      end if;
      return Index_Spans (Span).Length;
   end Index_Span_Length;

   function Word_Span_Length (Span : Word_Span_Id) return Natural is
   begin
      if Span = Null_Word_Span or else not Word_Spans (Span).Active then
         return 0;
      end if;
      return Word_Spans (Span).Length;
   end Word_Span_Length;

   function Real_Span_Alive (Span : Real_Span_Id) return Boolean is
   begin
      return Span /= Null_Real_Span and then Real_Spans (Span).Active;
   end Real_Span_Alive;

   function Index_Span_Alive (Span : Index_Span_Id) return Boolean is
   begin
      return Span /= Null_Index_Span and then Index_Spans (Span).Active;
   end Index_Span_Alive;

   function Word_Span_Alive (Span : Word_Span_Id) return Boolean is
   begin
      return Span /= Null_Word_Span and then Word_Spans (Span).Active;
   end Word_Span_Alive;

   procedure Write_Real
     (Span   : Real_Span_Id;
      Offset : Natural;
      Value  : Real;
      Status : out Arena_Status) is
      Index   : Real_Cell_Index := Real_Cell_Index'First;
      Success : Boolean := False;
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
      else
         Resolve_Real_Index (Span, Offset, Index, Success);
         if Success then
            Real_Store (Index) := Value;
            Status := Arena_Ok;
         elsif not Real_Span_Alive (Span) then
            Status := Arena_Invalid_Handle;
         else
            Status := Arena_Invalid_Offset;
         end if;
      end if;
   end Write_Real;

   procedure Read_Real
     (Span   : Real_Span_Id;
      Offset : Natural;
      Value  : out Real;
      Status : out Arena_Status) is
      Index   : Real_Cell_Index := Real_Cell_Index'First;
      Success : Boolean := False;
   begin
      Value := 0.0;
      if not Initialized then
         Status := Arena_Not_Initialized;
      else
         Resolve_Real_Index (Span, Offset, Index, Success);
         if Success then
            Value := Real_Store (Index);
            Status := Arena_Ok;
         elsif not Real_Span_Alive (Span) then
            Status := Arena_Invalid_Handle;
         else
            Status := Arena_Invalid_Offset;
         end if;
      end if;
   end Read_Real;

   procedure Fill_Real
     (Span   : Real_Span_Id;
      Value  : Real;
      Status : out Arena_Status) is
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if not Real_Span_Alive (Span) then
         Status := Arena_Invalid_Handle;
         return;
      end if;

      for Offset in 0 .. Real_Spans (Span).Length - 1 loop
         Real_Store (Real_Cell_Index (Real_Spans (Span).Start + Offset)) := Value;
      end loop;
      Status := Arena_Ok;
   end Fill_Real;

   procedure Accumulate_Real
     (Span   : Real_Span_Id;
      Offset : Natural;
      Change : Real;
      Status : out Arena_Status) is
      Index   : Real_Cell_Index := Real_Cell_Index'First;
      Success : Boolean := False;
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
      else
         Resolve_Real_Index (Span, Offset, Index, Success);
         if Success then
            Real_Store (Index) := Real_Store (Index) + Change;
            Status := Arena_Ok;
         elsif not Real_Span_Alive (Span) then
            Status := Arena_Invalid_Handle;
         else
            Status := Arena_Invalid_Offset;
         end if;
      end if;
   end Accumulate_Real;

   procedure Copy_Real_Span
     (Source : Real_Span_Id;
      Target : Real_Span_Id;
      Length : Natural;
      Status : out Arena_Status) is
      Source_Index : Real_Cell_Index := Real_Cell_Index'First;
      Target_Index : Real_Cell_Index := Real_Cell_Index'First;
      Source_Ok    : Boolean := False;
      Target_Ok    : Boolean := False;
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if not Real_Span_Alive (Source) or else not Real_Span_Alive (Target) then
         Status := Arena_Invalid_Handle;
         return;
      end if;

      if Length > Real_Spans (Source).Length
        or else Length > Real_Spans (Target).Length
      then
         Status := Arena_Invalid_Offset;
         return;
      end if;

      if Length = 0 then
         Status := Arena_Ok;
         return;
      end if;

      for Offset in 0 .. Length - 1 loop
         Resolve_Real_Index (Source, Offset, Source_Index, Source_Ok);
         Resolve_Real_Index (Target, Offset, Target_Index, Target_Ok);
         pragma Assert (Source_Ok);
         pragma Assert (Target_Ok);
         Real_Store (Target_Index) := Real_Store (Source_Index);
      end loop;
      Status := Arena_Ok;
   end Copy_Real_Span;

   procedure Write_Index
     (Span   : Index_Span_Id;
      Offset : Natural;
      Value  : Index_Value;
      Status : out Arena_Status) is
      Index   : Index_Cell_Index := Index_Cell_Index'First;
      Success : Boolean := False;
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
      else
         Resolve_Index_Cell (Span, Offset, Index, Success);
         if Success then
            Index_Store (Index) := Value;
            Status := Arena_Ok;
         elsif not Index_Span_Alive (Span) then
            Status := Arena_Invalid_Handle;
         else
            Status := Arena_Invalid_Offset;
         end if;
      end if;
   end Write_Index;

   procedure Read_Index
     (Span   : Index_Span_Id;
      Offset : Natural;
      Value  : out Index_Value;
      Status : out Arena_Status) is
      Index   : Index_Cell_Index := Index_Cell_Index'First;
      Success : Boolean := False;
   begin
      Value := 0;
      if not Initialized then
         Status := Arena_Not_Initialized;
      else
         Resolve_Index_Cell (Span, Offset, Index, Success);
         if Success then
            Value := Index_Store (Index);
            Status := Arena_Ok;
         elsif not Index_Span_Alive (Span) then
            Status := Arena_Invalid_Handle;
         else
            Status := Arena_Invalid_Offset;
         end if;
      end if;
   end Read_Index;

   procedure Fill_Index
     (Span   : Index_Span_Id;
      Value  : Index_Value;
      Status : out Arena_Status) is
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if not Index_Span_Alive (Span) then
         Status := Arena_Invalid_Handle;
         return;
      end if;

      for Offset in 0 .. Index_Spans (Span).Length - 1 loop
         Index_Store
           (Index_Cell_Index (Index_Spans (Span).Start + Offset)) := Value;
      end loop;
      Status := Arena_Ok;
   end Fill_Index;

   procedure Write_Word
     (Span   : Word_Span_Id;
      Offset : Natural;
      Value  : Galois_Field.Word;
      Status : out Arena_Status) is
      Index   : Word_Cell_Index := Word_Cell_Index'First;
      Success : Boolean := False;
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
      else
         Resolve_Word_Cell (Span, Offset, Index, Success);
         if Success then
            Word_Store (Index) := Value;
            Status := Arena_Ok;
         elsif not Word_Span_Alive (Span) then
            Status := Arena_Invalid_Handle;
         else
            Status := Arena_Invalid_Offset;
         end if;
      end if;
   end Write_Word;

   procedure Read_Word
     (Span   : Word_Span_Id;
      Offset : Natural;
      Value  : out Galois_Field.Word;
      Status : out Arena_Status) is
      Index   : Word_Cell_Index := Word_Cell_Index'First;
      Success : Boolean := False;
   begin
      Value := 0;
      if not Initialized then
         Status := Arena_Not_Initialized;
      else
         Resolve_Word_Cell (Span, Offset, Index, Success);
         if Success then
            Value := Word_Store (Index);
            Status := Arena_Ok;
         elsif not Word_Span_Alive (Span) then
            Status := Arena_Invalid_Handle;
         else
            Status := Arena_Invalid_Offset;
         end if;
      end if;
   end Read_Word;

   procedure Fill_Word
     (Span   : Word_Span_Id;
      Value  : Galois_Field.Word;
      Status : out Arena_Status) is
   begin
      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if not Word_Span_Alive (Span) then
         Status := Arena_Invalid_Handle;
         return;
      end if;

      for Offset in 0 .. Word_Spans (Span).Length - 1 loop
         Word_Store (Word_Cell_Index (Word_Spans (Span).Start + Offset)) := Value;
      end loop;
      Status := Arena_Ok;
   end Fill_Word;

   procedure Real_Span_Checksum
     (Span     : Real_Span_Id;
      Checksum : out Galois_Field.Word;
      Status   : out Arena_Status) is
      Result : Galois_Field.Word := 0;
   begin
      Checksum := 0;
      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if not Real_Span_Alive (Span) then
         Status := Arena_Invalid_Handle;
         return;
      end if;

      for Offset in 0 .. Real_Spans (Span).Length - 1 loop
         Result :=
           Hash_2D
             (Result,
              Word (Offset + 1),
              Real_To_Word
                (Real_Store
                   (Real_Cell_Index (Real_Spans (Span).Start + Offset))));
      end loop;

      Checksum := Result;
      Status := Arena_Ok;
   end Real_Span_Checksum;

   procedure Word_Span_Checksum
     (Span     : Word_Span_Id;
      Checksum : out Galois_Field.Word;
      Status   : out Arena_Status) is
      Result : Galois_Field.Word := 0;
   begin
      Checksum := 0;
      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      if not Word_Span_Alive (Span) then
         Status := Arena_Invalid_Handle;
         return;
      end if;

      for Offset in 0 .. Word_Spans (Span).Length - 1 loop
         Result :=
           Hash_2D
             (Result,
              Word (Offset + 1),
              Word_Store (Word_Cell_Index (Word_Spans (Span).Start + Offset)));
      end loop;

      Checksum := Result;
      Status := Arena_Ok;
   end Word_Span_Checksum;

   procedure Get_Metrics
     (Real_Used     : out Natural;
      Index_Used    : out Natural;
      Word_Used     : out Natural;
      Real_Spans    : out Natural;
      Index_Spans   : out Natural;
      Word_Spans    : out Natural;
      Status        : out Arena_Status) is
   begin
      Real_Used := 0;
      Index_Used := 0;
      Word_Used := 0;
      Real_Spans := 0;
      Index_Spans := 0;
      Word_Spans := 0;

      if not Initialized then
         Status := Arena_Not_Initialized;
         return;
      end if;

      Real_Used := Next_Real_Cell - 1;
      Index_Used := Next_Index_Cell - 1;
      Word_Used := Next_Word_Cell - 1;
      Real_Spans := Real_Span_Count;
      Index_Spans := Index_Span_Count;
      Word_Spans := Word_Span_Count;
      Status := Arena_Ok;
   end Get_Metrics;

   function Verify_Real_Access
     (Span   : Real_Span_Id;
      Offset : Natural) return Boolean is
      Index   : Real_Cell_Index := Real_Cell_Index'First;
      Success : Boolean := False;
   begin
      if not Initialized then
         return False;
      end if;
      Resolve_Real_Index (Span, Offset, Index, Success);
      return Success;
   end Verify_Real_Access;

   function Verify_Index_Access
     (Span   : Index_Span_Id;
      Offset : Natural) return Boolean is
      Index   : Index_Cell_Index := Index_Cell_Index'First;
      Success : Boolean := False;
   begin
      if not Initialized then
         return False;
      end if;
      Resolve_Index_Cell (Span, Offset, Index, Success);
      return Success;
   end Verify_Index_Access;

   function Verify_Word_Access
     (Span   : Word_Span_Id;
      Offset : Natural) return Boolean is
      Index   : Word_Cell_Index := Word_Cell_Index'First;
      Success : Boolean := False;
   begin
      if not Initialized then
         return False;
      end if;
      Resolve_Word_Cell (Span, Offset, Index, Success);
      return Success;
   end Verify_Word_Access;

end Brainmap_Arena;
