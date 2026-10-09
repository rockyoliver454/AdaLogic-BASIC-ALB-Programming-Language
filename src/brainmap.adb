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
with Brainmap_Arena;    use Brainmap_Arena;
with Float_Expr;
with Galois_Field;      use Galois_Field;

package body Brainmap
  with SPARK_Mode => On
is
   use type Float_Expr.Status_Code;

   subtype Unit_Count_Range is Natural range 0 .. Max_Units_Per_Brain;
   subtype Edge_Count_Range is Natural range 0 .. Max_Edges_Per_Brain;

   type Brain_Symbols is record
      Sum_Id    : Float_Expr.Var_Id := 1;
      Bias_Id   : Float_Expr.Var_Id := 1;
      Prev_Id   : Float_Expr.Var_Id := 1;
      Input_Id  : Float_Expr.Var_Id := 1;
      Trace_Id  : Float_Expr.Var_Id := 1;
      Reward_Id : Float_Expr.Var_Id := 1;
      Temp_Id   : Float_Expr.Var_Id := 1;
      State_Id  : Float_Expr.Var_Id := 1;
      Ext_Id    : Float_Expr.Var_Id := 1;
   end record;

   type Brain_Record is record
      Active        : Boolean := False;
      Token         : Link_ID := 0;
      Seed          : Word := 0;
      RNG           : RNG_State := (State => 0, Increment => 1);
      Region_Count  : Natural range 0 .. Max_Regions := 0;
      Unit_Count    : Unit_Count_Range := 0;
      Edge_Count    : Edge_Count_Range := 0;
      Builder       : Float_Expr.Builder;
      Symbols       : Brain_Symbols;
      Activation    : Float_Expr.Expr := (Root => Float_Expr.Null_Node);
      Gate          : Float_Expr.Expr := (Root => Float_Expr.Null_Node);
      Score         : Float_Expr.Expr := (Root => Float_Expr.Null_Node);
      State_Span    : Real_Span_Id := Null_Real_Span;
      Prev_Span     : Real_Span_Id := Null_Real_Span;
      Input_Span    : Real_Span_Id := Null_Real_Span;
      Bias_Span     : Real_Span_Id := Null_Real_Span;
      Trace_Span    : Real_Span_Id := Null_Real_Span;
      Score_Span    : Real_Span_Id := Null_Real_Span;
      From_Span     : Index_Span_Id := Null_Index_Span;
      To_Span       : Index_Span_Id := Null_Index_Span;
      Weight_Span   : Real_Span_Id := Null_Real_Span;
      External_Bias : Real := 0.0;
      Reward        : Real := 0.0;
      Temperature   : Real := 0.25;
   end record;

   type Region_Record is record
      Active      : Boolean := False;
      Brain       : Brain_Id := Null_Brain;
      Kind        : Region_Kind := Hidden_Region;
      First_Unit  : Unit_Id := Null_Unit;
      Unit_Count  : Unit_Count_Range := 0;
   end record;

   type Snapshot_Vector is array (Positive range 1 .. Max_Units_Per_Brain) of Real;

   type Snapshot_Record is record
      Active        : Boolean := False;
      Brain         : Brain_Id := Null_Brain;
      Unit_Count    : Unit_Count_Range := 0;
      External_Bias : Real := 0.0;
      Reward        : Real := 0.0;
      Temperature   : Real := 0.25;
      State_Data    : Snapshot_Vector := (others => 0.0);
      Prev_Data     : Snapshot_Vector := (others => 0.0);
      Input_Data    : Snapshot_Vector := (others => 0.0);
      Bias_Data     : Snapshot_Vector := (others => 0.0);
      Trace_Data    : Snapshot_Vector := (others => 0.0);
      Score_Data    : Snapshot_Vector := (others => 0.0);
      Checksum      : Word := 0;
   end record;

   type Brain_Table is
     array (Brain_Id range 1 .. Brain_Id (Max_Brains)) of Brain_Record;
   type Region_Table is
     array (Region_Id range 1 .. Region_Id (Max_Regions)) of Region_Record;
   type Snapshot_Table is
     array (Snapshot_Id range 1 .. Snapshot_Id (Max_Snapshots))
       of Snapshot_Record;

   Brains      : Brain_Table := (others => (others => <>));
   Regions     : Region_Table := (others => (others => <>));
   Snapshots   : Snapshot_Table := (others => (others => <>));
   Initialized : Boolean := False;

   function Valid_Brain (Brain : Brain_Id) return Boolean is
   begin
      return Brain /= Null_Brain and then Brains (Brain).Active;
   end Valid_Brain;

   function Valid_Unit (Brain : Brain_Id; Unit : Unit_Id) return Boolean is
   begin
      return
        Valid_Brain (Brain)
        and then Unit /= Null_Unit
        and then Natural (Unit) <= Brains (Brain).Unit_Count;
   end Valid_Unit;

   function Valid_Region (Brain : Brain_Id; Region : Region_Id) return Boolean is
   begin
      return
        Region /= Null_Region
        and then Regions (Region).Active
        and then Regions (Region).Brain = Brain;
   end Valid_Region;

   procedure Map_Arena_Status
     (Source : Brainmap_Arena.Arena_Status;
      Target : out Brain_Status) is
   begin
      case Source is
         when Arena_Ok =>
            Target := Brain_Ok;
         when Arena_Already_Initialized =>
            Target := Brain_Already_Initialized;
         when Arena_Dumptruck_Error =>
            Target := Brain_Dumptruck_Error;
         when others =>
            Target := Brain_Arena_Error;
      end case;
   end Map_Arena_Status;

   procedure Map_Expr_Status
     (Source : Float_Expr.Status_Code;
      Target : out Brain_Status) is
   begin
      if Source = Float_Expr.Ok then
         Target := Brain_Ok;
      else
         Target := Brain_Expression_Error;
      end if;
   end Map_Expr_Status;

   procedure Define_Required_Symbols
     (B       : in out Brain_Record;
      Status  : out Brain_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      Float_Expr.Reset (B.Builder);
      Float_Expr.Define_Symbol (B.Builder, "sum", B.Symbols.Sum_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "bias", B.Symbols.Bias_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "prev", B.Symbols.Prev_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "input", B.Symbols.Input_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "trace", B.Symbols.Trace_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "reward", B.Symbols.Reward_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "temp", B.Symbols.Temp_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "state", B.Symbols.State_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (B.Builder, "extb", B.Symbols.Ext_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;
      Status := Brain_Ok;
   end Define_Required_Symbols;

   procedure Parse_Default_Programs
     (B      : in out Brain_Record;
      Status : out Brain_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      Float_Expr.Parse_Infix
        (B.Builder,
         "1 / (1 + exp(-(sum + bias + input + prev * 0.25 + extb)))",
         B.Activation,
         Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;

      Float_Expr.Parse_Infix
        (B.Builder,
         "1 / (1 + exp(-(trace + reward + extb - temp)))",
         B.Gate,
         Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;

      Float_Expr.Parse_Infix
        (B.Builder,
         "abs(state) + trace + reward + abs(extb)",
         B.Score,
         Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Brain_Expression_Error;
         return;
      end if;

      Status := Brain_Ok;
   end Parse_Default_Programs;

   procedure Build_Env
     (B      : Brain_Record;
      Sum    : Real;
      Bias   : Real;
      Prev   : Real;
      Input  : Real;
      Trace  : Real;
      State  : Real;
      Env    : out Float_Expr.Var_Values) is
   begin
      Env := (others => 0.0);
      Env (B.Symbols.Sum_Id) := Sum;
      Env (B.Symbols.Bias_Id) := Bias;
      Env (B.Symbols.Prev_Id) := Prev;
      Env (B.Symbols.Input_Id) := Input;
      Env (B.Symbols.Trace_Id) := Trace;
      Env (B.Symbols.Reward_Id) := B.Reward;
      Env (B.Symbols.Temp_Id) := B.Temperature;
      Env (B.Symbols.State_Id) := State;
      Env (B.Symbols.Ext_Id) := B.External_Bias;
   end Build_Env;

   procedure Evaluate_Program
     (B         : Brain_Record;
      Program   : Float_Expr.Expr;
      Env       : Float_Expr.Var_Values;
      Result    : out Real;
      Status    : out Brain_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      Float_Expr.Evaluate (B.Builder, Program, Env, Result, Expr_Status);
      Map_Expr_Status (Expr_Status, Status);
   end Evaluate_Program;

   procedure Zero_All_Spans
     (B      : in out Brain_Record;
      Status : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      Fill_Real (B.State_Span, 0.0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Real (B.Prev_Span, 0.0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Real (B.Input_Span, 0.0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Real (B.Bias_Span, 0.0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Real (B.Trace_Span, 0.0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Real (B.Score_Span, 0.0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Index (B.From_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Index (B.To_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Fill_Real (B.Weight_Span, 0.0, Arena_Status);
      Map_Arena_Status (Arena_Status, Status);
   end Zero_All_Spans;

   procedure Initialize (Status : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      if Initialized then
         Status := Brain_Already_Initialized;
         return;
      end if;

      Brainmap_Arena.Initialize (Arena_Status);
      if Arena_Status /= Arena_Ok
        and then Arena_Status /= Arena_Already_Initialized
      then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;

      Brains := (others => (others => <>));
      Regions := (others => (others => <>));
      Snapshots := (others => (others => <>));
      Initialized := True;
      Status := Brain_Ok;
   end Initialize;

   procedure Reset (Status : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Success      : Boolean := False;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;

      for B in Brains'Range loop
         if Brains (B).Token > 0 then
            Drop_Reference (Node_ID (Brains (B).Token), Success);
         end if;
      end loop;

      Brainmap_Arena.Reset (Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;

      Brains := (others => (others => <>));
      Regions := (others => (others => <>));
      Snapshots := (others => (others => <>));
      Status := Brain_Ok;
   end Reset;

   function Is_Initialized return Boolean is
   begin
      return Initialized;
   end Is_Initialized;

   procedure Create_Brain
     (Seed   : Galois_Field.Word;
      Brain  : out Brain_Id;
      Status : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Token_Node    : Node_ID := 1;
      Token_Success : Boolean := False;
   begin
      Brain := Null_Brain;
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;

      for Candidate in Brains'Range loop
         if not Brains (Candidate).Active then
            Brain := Candidate;
            exit;
         end if;
      end loop;

      if Brain = Null_Brain then
         Status := Brain_Out_Of_Brains;
         return;
      end if;

      Grab_New_Node (Token_Node, Token_Success);
      if not Token_Success then
         Status := Brain_Dumptruck_Error;
         Brain := Null_Brain;
         return;
      end if;

      Brains (Brain).Active := True;
      Brains (Brain).Token := Link_ID (Token_Node);
      Brains (Brain).Seed := Seed;
      Seed_State (Seed, Word (Brain), Brains (Brain).RNG);

      Claim_Real_Span (Max_Units_Per_Brain, Brains (Brain).State_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Real_Span (Max_Units_Per_Brain, Brains (Brain).Prev_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Real_Span (Max_Units_Per_Brain, Brains (Brain).Input_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Real_Span (Max_Units_Per_Brain, Brains (Brain).Bias_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Real_Span (Max_Units_Per_Brain, Brains (Brain).Trace_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Real_Span (Max_Units_Per_Brain, Brains (Brain).Score_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Index_Span (Max_Edges_Per_Brain, Brains (Brain).From_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Index_Span (Max_Edges_Per_Brain, Brains (Brain).To_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Claim_Real_Span (Max_Edges_Per_Brain, Brains (Brain).Weight_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Define_Required_Symbols (Brains (Brain), Status);
      if Status /= Brain_Ok then
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Parse_Default_Programs (Brains (Brain), Status);
      if Status /= Brain_Ok then
         Brains (Brain).Active := False;
         Brain := Null_Brain;
         return;
      end if;

      Zero_All_Spans (Brains (Brain), Status);
      if Status /= Brain_Ok then
         Brains (Brain).Active := False;
         Brain := Null_Brain;
      end if;
   end Create_Brain;

   procedure Add_Region
     (Brain      : Brain_Id;
      Kind       : Region_Kind;
      Unit_Count : Positive;
      Region     : out Region_Id;
      First_Unit : out Unit_Id;
      Status     : out Brain_Status) is
   begin
      Region := Null_Region;
      First_Unit := Null_Unit;
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;

      if not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
         return;
      end if;

      if Brains (Brain).Region_Count >= Max_Regions then
         Status := Brain_Out_Of_Regions;
         return;
      end if;

      if Brains (Brain).Unit_Count + Unit_Count > Max_Units_Per_Brain then
         Status := Brain_Out_Of_Units;
         return;
      end if;

      for Candidate in Regions'Range loop
         if not Regions (Candidate).Active then
            Region := Candidate;
            exit;
         end if;
      end loop;

      if Region = Null_Region then
         Status := Brain_Out_Of_Regions;
         return;
      end if;

      First_Unit := Unit_Id (Brains (Brain).Unit_Count + 1);
      Regions (Region).Active := True;
      Regions (Region).Brain := Brain;
      Regions (Region).Kind := Kind;
      Regions (Region).First_Unit := First_Unit;
      Regions (Region).Unit_Count := Unit_Count;
      Brains (Brain).Region_Count := Brains (Brain).Region_Count + 1;
      Brains (Brain).Unit_Count := Brains (Brain).Unit_Count + Unit_Count;
      Status := Brain_Ok;
   end Add_Region;

   procedure Connect_Units
     (Brain    : Brain_Id;
      From_Unit : Unit_Id;
      To_Unit   : Unit_Id;
      Weight    : Real;
      Status    : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Slot         : Natural := 0;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;

      if not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
         return;
      end if;

      if not Valid_Unit (Brain, From_Unit) or else not Valid_Unit (Brain, To_Unit) then
         Status := Brain_Invalid_Unit;
         return;
      end if;

      if Brains (Brain).Edge_Count >= Max_Edges_Per_Brain then
         Status := Brain_Out_Of_Edges;
         return;
      end if;

      Slot := Brains (Brain).Edge_Count;
      Write_Index (Brains (Brain).From_Span, Slot, Natural (From_Unit), Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Write_Index (Brains (Brain).To_Span, Slot, Natural (To_Unit), Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Write_Real (Brains (Brain).Weight_Span, Slot, Weight, Arena_Status);
      Map_Arena_Status (Arena_Status, Status);
      if Status = Brain_Ok then
         Brains (Brain).Edge_Count := Brains (Brain).Edge_Count + 1;
      end if;
   end Connect_Units;

   procedure Randomize_Region
     (Brain     : Brain_Id;
      Region    : Region_Id;
      Magnitude : Real;
      Status    : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Sample       : Real := 0.0;
      Unit_Offset  : Natural := 0;
      Unit_Index   : Unit_Id := Null_Unit;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;

      if not Valid_Region (Brain, Region) then
         Status := Brain_Invalid_Region;
         return;
      end if;

      for Offset in 0 .. Regions (Region).Unit_Count - 1 loop
         Unit_Offset := Offset;
         Unit_Index := Unit_Id (Natural (Regions (Region).First_Unit) + Unit_Offset);
         Next_Unit_Real (Brains (Brain).RNG, Sample);
         Write_Real
           (Brains (Brain).State_Span,
            Natural (Unit_Index) - 1,
            ((Sample * 2.0) - 1.0) * Magnitude,
            Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;

         Next_Unit_Real (Brains (Brain).RNG, Sample);
         Write_Real
           (Brains (Brain).Bias_Span,
            Natural (Unit_Index) - 1,
            ((Sample * 2.0) - 1.0) * Magnitude,
            Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
      end loop;

      Status := Brain_Ok;
   end Randomize_Region;

   procedure Set_Unit_Input
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : Real;
      Status  : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      elsif not Valid_Unit (Brain, Unit) then
         Status := Brain_Invalid_Unit;
      else
         Write_Real (Brains (Brain).Input_Span, Natural (Unit) - 1, Value, Arena_Status);
         Map_Arena_Status (Arena_Status, Status);
      end if;
   end Set_Unit_Input;

   procedure Set_Unit_Bias
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : Real;
      Status  : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      elsif not Valid_Unit (Brain, Unit) then
         Status := Brain_Invalid_Unit;
      else
         Write_Real (Brains (Brain).Bias_Span, Natural (Unit) - 1, Value, Arena_Status);
         Map_Arena_Status (Arena_Status, Status);
      end if;
   end Set_Unit_Bias;

   procedure Get_Unit_State
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : out Real;
      Status  : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      Value := 0.0;
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      elsif not Valid_Unit (Brain, Unit) then
         Status := Brain_Invalid_Unit;
      else
         Read_Real (Brains (Brain).State_Span, Natural (Unit) - 1, Value, Arena_Status);
         Map_Arena_Status (Arena_Status, Status);
      end if;
   end Get_Unit_State;

   procedure Get_Unit_Trace
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : out Real;
      Status  : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      Value := 0.0;
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      elsif not Valid_Unit (Brain, Unit) then
         Status := Brain_Invalid_Unit;
      else
         Read_Real (Brains (Brain).Trace_Span, Natural (Unit) - 1, Value, Arena_Status);
         Map_Arena_Status (Arena_Status, Status);
      end if;
   end Get_Unit_Trace;

   procedure Set_External_Bias
     (Brain   : Brain_Id;
      Value   : Real;
      Status  : out Brain_Status) is
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      else
         Brains (Brain).External_Bias := Value;
         Status := Brain_Ok;
      end if;
   end Set_External_Bias;

   procedure Set_Reward
     (Brain   : Brain_Id;
      Value   : Real;
      Status  : out Brain_Status) is
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      else
         Brains (Brain).Reward := Value;
         Status := Brain_Ok;
      end if;
   end Set_Reward;

   procedure Set_Temperature
     (Brain   : Brain_Id;
      Value   : Real;
      Status  : out Brain_Status) is
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      else
         Brains (Brain).Temperature := Value;
         Status := Brain_Ok;
      end if;
   end Set_Temperature;

   procedure Set_Activation_Expression
     (Brain   : Brain_Id;
      Text    : String;
      Status  : out Brain_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      else
         Float_Expr.Parse_Infix (Brains (Brain).Builder, Text, Brains (Brain).Activation, Expr_Status);
         Map_Expr_Status (Expr_Status, Status);
      end if;
   end Set_Activation_Expression;

   procedure Set_Gate_Expression
     (Brain   : Brain_Id;
      Text    : String;
      Status  : out Brain_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      else
         Float_Expr.Parse_Infix (Brains (Brain).Builder, Text, Brains (Brain).Gate, Expr_Status);
         Map_Expr_Status (Expr_Status, Status);
      end if;
   end Set_Gate_Expression;

   procedure Set_Score_Expression
     (Brain   : Brain_Id;
      Text    : String;
      Status  : out Brain_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      else
         Float_Expr.Parse_Infix (Brains (Brain).Builder, Text, Brains (Brain).Score, Expr_Status);
         Map_Expr_Status (Expr_Status, Status);
      end if;
   end Set_Score_Expression;

   procedure Step
     (Brain   : Brain_Id;
      Cycles  : Positive;
      Status  : out Brain_Status) is
      Arena_Status   : Brainmap_Arena.Arena_Status := Arena_Ok;
      Eval_Status    : Brain_Status := Brain_Ok;
      Env            : Float_Expr.Var_Values := (others => 0.0);
      Sum_Value      : Real := 0.0;
      Bias_Value     : Real := 0.0;
      Prev_Value     : Real := 0.0;
      Input_Value    : Real := 0.0;
      Trace_Value    : Real := 0.0;
      Gate_Value     : Real := 0.0;
      Activation_Val : Real := 0.0;
      New_State      : Real := 0.0;
      Score_Value    : Real := 0.0;
      Edge_From      : Index_Value := 0;
      Edge_To        : Index_Value := 0;
      Edge_Weight    : Real := 0.0;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;

      if not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
         return;
      end if;

      for Cycle in 1 .. Cycles loop
         Copy_Real_Span
           (Brains (Brain).State_Span,
            Brains (Brain).Prev_Span,
            Brains (Brain).Unit_Count,
            Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;

         for Unit_Index in 1 .. Brains (Brain).Unit_Count loop
            Read_Real (Brains (Brain).Input_Span, Unit_Index - 1, Sum_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Input_Value := Sum_Value;

            for Edge_Index in 0 .. Brains (Brain).Edge_Count - 1 loop
               Read_Index (Brains (Brain).To_Span, Edge_Index, Edge_To, Arena_Status);
               if Arena_Status /= Arena_Ok then
                  Map_Arena_Status (Arena_Status, Status);
                  return;
               end if;

               if Edge_To = Unit_Index then
                  Read_Index (Brains (Brain).From_Span, Edge_Index, Edge_From, Arena_Status);
                  if Arena_Status /= Arena_Ok then
                     Map_Arena_Status (Arena_Status, Status);
                     return;
                  end if;
                  Read_Real (Brains (Brain).Weight_Span, Edge_Index, Edge_Weight, Arena_Status);
                  if Arena_Status /= Arena_Ok then
                     Map_Arena_Status (Arena_Status, Status);
                     return;
                  end if;
                  Read_Real (Brains (Brain).Prev_Span, Edge_From - 1, Prev_Value, Arena_Status);
                  if Arena_Status /= Arena_Ok then
                     Map_Arena_Status (Arena_Status, Status);
                     return;
                  end if;
                  Sum_Value := Sum_Value + (Prev_Value * Edge_Weight);
               end if;
            end loop;

            Read_Real (Brains (Brain).Bias_Span, Unit_Index - 1, Bias_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Read_Real (Brains (Brain).Prev_Span, Unit_Index - 1, Prev_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Read_Real (Brains (Brain).Trace_Span, Unit_Index - 1, Trace_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;

            Build_Env
              (Brains (Brain),
               Sum_Value,
               Bias_Value,
               Prev_Value,
               Input_Value,
               Trace_Value,
               Prev_Value,
               Env);
            Evaluate_Program (Brains (Brain), Brains (Brain).Gate, Env, Gate_Value, Eval_Status);
            if Eval_Status /= Brain_Ok then
               Status := Eval_Status;
               return;
            end if;

            Evaluate_Program
              (Brains (Brain),
               Brains (Brain).Activation,
               Env,
               Activation_Val,
               Eval_Status);
            if Eval_Status /= Brain_Ok then
               Status := Eval_Status;
               return;
            end if;

            New_State := (Activation_Val * Gate_Value) + (Prev_Value * (1.0 - Gate_Value));
            Trace_Value := (Trace_Value * 0.85) + abs (New_State - Prev_Value) + (Brains (Brain).Reward * 0.05);
            Build_Env
              (Brains (Brain),
               Sum_Value,
               Bias_Value,
               Prev_Value,
               Input_Value,
               Trace_Value,
               New_State,
               Env);
            Evaluate_Program
              (Brains (Brain),
               Brains (Brain).Score,
               Env,
               Score_Value,
               Eval_Status);
            if Eval_Status /= Brain_Ok then
               Status := Eval_Status;
               return;
            end if;

            Write_Real (Brains (Brain).State_Span, Unit_Index - 1, New_State, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Write_Real (Brains (Brain).Trace_Span, Unit_Index - 1, Trace_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Write_Real (Brains (Brain).Score_Span, Unit_Index - 1, Score_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
         end loop;
      end loop;

      Status := Brain_Ok;
   end Step;

   procedure Create_Snapshot
     (Brain     : Brain_Id;
      Snapshot  : out Snapshot_Id;
      Status    : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Value        : Real := 0.0;
      Result       : Word := 0;
   begin
      Snapshot := Null_Snapshot;
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;
      if not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
         return;
      end if;

      for Candidate in Snapshots'Range loop
         if not Snapshots (Candidate).Active then
            Snapshot := Candidate;
            exit;
         end if;
      end loop;

      if Snapshot = Null_Snapshot then
         Status := Brain_Out_Of_Snapshots;
         return;
      end if;

      Snapshots (Snapshot).Active := True;
      Snapshots (Snapshot).Brain := Brain;
      Snapshots (Snapshot).Unit_Count := Brains (Brain).Unit_Count;
      Snapshots (Snapshot).External_Bias := Brains (Brain).External_Bias;
      Snapshots (Snapshot).Reward := Brains (Brain).Reward;
      Snapshots (Snapshot).Temperature := Brains (Brain).Temperature;

      for Unit_Index in 1 .. Brains (Brain).Unit_Count loop
         Read_Real (Brains (Brain).State_Span, Unit_Index - 1, Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            Snapshots (Snapshot).Active := False;
            Snapshot := Null_Snapshot;
            return;
         end if;
         Snapshots (Snapshot).State_Data (Unit_Index) := Value;

         Read_Real (Brains (Brain).Prev_Span, Unit_Index - 1, Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            Snapshots (Snapshot).Active := False;
            Snapshot := Null_Snapshot;
            return;
         end if;
         Snapshots (Snapshot).Prev_Data (Unit_Index) := Value;

         Read_Real (Brains (Brain).Input_Span, Unit_Index - 1, Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            Snapshots (Snapshot).Active := False;
            Snapshot := Null_Snapshot;
            return;
         end if;
         Snapshots (Snapshot).Input_Data (Unit_Index) := Value;

         Read_Real (Brains (Brain).Bias_Span, Unit_Index - 1, Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            Snapshots (Snapshot).Active := False;
            Snapshot := Null_Snapshot;
            return;
         end if;
         Snapshots (Snapshot).Bias_Data (Unit_Index) := Value;

         Read_Real (Brains (Brain).Trace_Span, Unit_Index - 1, Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            Snapshots (Snapshot).Active := False;
            Snapshot := Null_Snapshot;
            return;
         end if;
         Snapshots (Snapshot).Trace_Data (Unit_Index) := Value;

         Read_Real (Brains (Brain).Score_Span, Unit_Index - 1, Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            Snapshots (Snapshot).Active := False;
            Snapshot := Null_Snapshot;
            return;
         end if;
         Snapshots (Snapshot).Score_Data (Unit_Index) := Value;

         Result :=
           Hash_2D
             (Result,
              Word (Unit_Index),
              Word (Natural (Integer (abs (Snapshots (Snapshot).State_Data (Unit_Index) * 1000.0)))));
      end loop;

      Snapshots (Snapshot).Checksum := Result;
      Status := Brain_Ok;
   end Create_Snapshot;

   procedure Restore_Snapshot
     (Brain     : Brain_Id;
      Snapshot  : Snapshot_Id;
      Status    : out Brain_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      if not Initialized then
         Status := Brain_Not_Initialized;
         return;
      end if;
      if not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
         return;
      end if;
      if Snapshot = Null_Snapshot or else not Snapshots (Snapshot).Active then
         Status := Brain_Invalid_Snapshot;
         return;
      end if;
      if Snapshots (Snapshot).Brain /= Brain then
         Status := Brain_Invalid_Snapshot;
         return;
      end if;

      Brains (Brain).External_Bias := Snapshots (Snapshot).External_Bias;
      Brains (Brain).Reward := Snapshots (Snapshot).Reward;
      Brains (Brain).Temperature := Snapshots (Snapshot).Temperature;

      for Unit_Index in 1 .. Snapshots (Snapshot).Unit_Count loop
         Write_Real (Brains (Brain).State_Span, Unit_Index - 1, Snapshots (Snapshot).State_Data (Unit_Index), Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Real (Brains (Brain).Prev_Span, Unit_Index - 1, Snapshots (Snapshot).Prev_Data (Unit_Index), Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Real (Brains (Brain).Input_Span, Unit_Index - 1, Snapshots (Snapshot).Input_Data (Unit_Index), Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Real (Brains (Brain).Bias_Span, Unit_Index - 1, Snapshots (Snapshot).Bias_Data (Unit_Index), Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Real (Brains (Brain).Trace_Span, Unit_Index - 1, Snapshots (Snapshot).Trace_Data (Unit_Index), Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Real (Brains (Brain).Score_Span, Unit_Index - 1, Snapshots (Snapshot).Score_Data (Unit_Index), Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
      end loop;

      Status := Brain_Ok;
   end Restore_Snapshot;

   procedure Get_Snapshot_Checksum
     (Snapshot  : Snapshot_Id;
      Checksum  : out Galois_Field.Word;
      Status    : out Brain_Status) is
   begin
      Checksum := 0;
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif Snapshot = Null_Snapshot or else not Snapshots (Snapshot).Active then
         Status := Brain_Invalid_Snapshot;
      else
         Checksum := Snapshots (Snapshot).Checksum;
         Status := Brain_Ok;
      end if;
   end Get_Snapshot_Checksum;

   procedure Get_Usage
     (Brain       : Brain_Id;
      Region_Count : out Natural;
      Unit_Count   : out Natural;
      Edge_Count   : out Natural;
      Status       : out Brain_Status) is
   begin
      Region_Count := 0;
      Unit_Count := 0;
      Edge_Count := 0;
      if not Initialized then
         Status := Brain_Not_Initialized;
      elsif not Valid_Brain (Brain) then
         Status := Brain_Invalid_Brain;
      else
         Region_Count := Brains (Brain).Region_Count;
         Unit_Count := Brains (Brain).Unit_Count;
         Edge_Count := Brains (Brain).Edge_Count;
         Status := Brain_Ok;
      end if;
   end Get_Usage;

end Brainmap;
