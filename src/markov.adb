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

package body Markov
  with SPARK_Mode => On
is
   use type Float_Expr.Status_Code;

   subtype State_Count_Range is Natural range 0 .. Max_States_Per_Chain;
   subtype Transition_Count_Range is Natural range 0 .. Max_Transitions_Per_Chain;

   type Markov_Symbols is record
      Count_Id : Float_Expr.Var_Id := 1;
      Seen_Id  : Float_Expr.Var_Id := 1;
      Conf_Id  : Float_Expr.Var_Id := 1;
      Ent_Id   : Float_Expr.Var_Id := 1;
      Ext_Id   : Float_Expr.Var_Id := 1;
      Temp_Id  : Float_Expr.Var_Id := 1;
   end record;

   type Chain_Record is record
      Active            : Boolean := False;
      Token             : Link_ID := 0;
      Seed              : Word := 0;
      Order             : Positive range 1 .. Max_Order := 1;
      RNG               : RNG_State := (State => 0, Increment => 1);
      Builder           : Float_Expr.Builder;
      Symbols           : Markov_Symbols;
      Bias_Expr         : Float_Expr.Expr := (Root => Float_Expr.Null_Node);
      Temp_Expr         : Float_Expr.Expr := (Root => Float_Expr.Null_Node);
      Context_Span      : Word_Span_Id := Null_Word_Span;
      State_Key_Span    : Word_Span_Id := Null_Word_Span;
      State_Total_Span  : Word_Span_Id := Null_Word_Span;
      Trans_From_Span   : Index_Span_Id := Null_Index_Span;
      Trans_Symbol_Span : Word_Span_Id := Null_Word_Span;
      Trans_Count_Span  : Word_Span_Id := Null_Word_Span;
      Score_Span        : Real_Span_Id := Null_Real_Span;
      State_Count       : State_Count_Range := 0;
      Transit_Count     : Transition_Count_Range := 0;
      Context_Length    : Natural range 0 .. Max_Order := 0;
      External_Bias     : Real := 0.0;
      Cached_Entropy    : Real := 0.0;
   end record;

   type Chain_Table is
     array (Chain_Id range 1 .. Chain_Id (Max_Chains)) of Chain_Record;
   Chains      : Chain_Table := (others => (others => <>));
   Initialized : Boolean := False;

   function Valid_Chain (Chain : Chain_Id) return Boolean is
   begin
      return Chain /= Null_Chain and then Chains (Chain).Active;
   end Valid_Chain;

   procedure Map_Arena_Status
     (Source : Brainmap_Arena.Arena_Status;
      Target : out Markov_Status) is
   begin
      case Source is
         when Arena_Ok =>
            Target := Markov_Ok;
         when Arena_Already_Initialized =>
            Target := Markov_Already_Initialized;
         when Arena_Dumptruck_Error =>
            Target := Markov_Dumptruck_Error;
         when others =>
            Target := Markov_Arena_Error;
      end case;
   end Map_Arena_Status;

   procedure Map_Expr_Status
     (Source : Float_Expr.Status_Code;
      Target : out Markov_Status) is
   begin
      if Source = Float_Expr.Ok then
         Target := Markov_Ok;
      else
         Target := Markov_Expression_Error;
      end if;
   end Map_Expr_Status;

   procedure Define_Required_Symbols
     (C       : in out Chain_Record;
      Status  : out Markov_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      Float_Expr.Reset (C.Builder);
      Float_Expr.Define_Symbol (C.Builder, "count", C.Symbols.Count_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (C.Builder, "seen", C.Symbols.Seen_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (C.Builder, "conf", C.Symbols.Conf_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (C.Builder, "ent", C.Symbols.Ent_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (C.Builder, "extb", C.Symbols.Ext_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;
      Float_Expr.Define_Symbol (C.Builder, "temp", C.Symbols.Temp_Id, Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;
      Status := Markov_Ok;
   end Define_Required_Symbols;

   procedure Parse_Default_Programs
     (C       : in out Chain_Record;
      Status  : out Markov_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      Float_Expr.Parse_Infix
        (C.Builder,
         "count * (1 + conf) + extb - ent",
         C.Bias_Expr,
         Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;

      Float_Expr.Parse_Infix
        (C.Builder,
         "1 + temp + ent + abs(extb)",
         C.Temp_Expr,
         Expr_Status);
      if Expr_Status /= Float_Expr.Ok then
         Status := Markov_Expression_Error;
         return;
      end if;

      Status := Markov_Ok;
   end Parse_Default_Programs;

   procedure Build_Context_Array
     (C        : Chain_Record;
      Data     : out Word_Array;
      Status   : out Markov_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Value        : Word := 0;
   begin
      if C.Context_Length = 0 then
         for I in Data'Range loop
            Data (I) := 0;
         end loop;
         Status := Markov_Ok;
         return;
      end if;

      for I in 1 .. C.Context_Length loop
         Read_Word (C.Context_Span, I - 1, Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Data (I) := Value;
      end loop;
      for I in C.Context_Length + 1 .. Data'Length loop
         Data (I) := 0;
      end loop;
      Status := Markov_Ok;
   end Build_Context_Array;

   function Find_State
     (C    : Chain_Record;
      Key  : Word) return Natural is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Value        : Word := 0;
   begin
      for Index in 1 .. C.State_Count loop
         Read_Word (C.State_Key_Span, Index - 1, Value, Arena_Status);
         if Arena_Status = Arena_Ok and then Value = Key then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_State;

   procedure Ensure_State
     (C        : in out Chain_Record;
      Key      : Word;
      State_Id : out Natural;
      Status   : out Markov_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      State_Id := Find_State (C, Key);
      if State_Id /= 0 then
         Status := Markov_Ok;
         return;
      end if;

      if C.State_Count >= Max_States_Per_Chain then
         Status := Markov_Out_Of_States;
         return;
      end if;

      State_Id := C.State_Count + 1;
      Write_Word (C.State_Key_Span, State_Id - 1, Key, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         State_Id := 0;
         return;
      end if;
      Write_Word (C.State_Total_Span, State_Id - 1, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         State_Id := 0;
         return;
      end if;

      C.State_Count := C.State_Count + 1;
      Status := Markov_Ok;
   end Ensure_State;

   function Find_Transition
     (C        : Chain_Record;
      State_Id : Natural;
      Symbol   : Word) return Natural is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      From_Value   : Index_Value := 0;
      Symbol_Value : Word := 0;
   begin
      for Index in 1 .. C.Transit_Count loop
         Read_Index (C.Trans_From_Span, Index - 1, From_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            return 0;
         end if;
         Read_Word (C.Trans_Symbol_Span, Index - 1, Symbol_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            return 0;
         end if;

         if From_Value = State_Id and then Symbol_Value = Symbol then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_Transition;

   procedure Shift_Context
     (C      : in out Chain_Record;
      Symbol : Word;
      Status : out Markov_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Value        : Word := 0;
   begin
      if C.Order > 1 and then C.Context_Length > 0 then
         for Index in reverse 2 .. C.Order loop
            if Index <= C.Context_Length then
               Read_Word (C.Context_Span, Index - 2, Value, Arena_Status);
               if Arena_Status /= Arena_Ok then
                  Map_Arena_Status (Arena_Status, Status);
                  return;
               end if;
               Write_Word (C.Context_Span, Index - 1, Value, Arena_Status);
               if Arena_Status /= Arena_Ok then
                  Map_Arena_Status (Arena_Status, Status);
                  return;
               end if;
            end if;
         end loop;
      end if;

      if C.Order > 0 then
         Write_Word (C.Context_Span, 0, Symbol, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
      end if;

      if C.Context_Length < C.Order then
         C.Context_Length := C.Context_Length + 1;
      end if;
      Status := Markov_Ok;
   end Shift_Context;

   procedure Recompute_Entropy
     (Chain  : Chain_Id;
      Status : out Markov_Status) is
      C            : Chain_Record renames Chains (Chain);
      Data         : Word_Array (1 .. Max_Order);
      Context_Key  : Word := 0;
      Current_State : Natural := 0;
      Arena_Status  : Brainmap_Arena.Arena_Status := Arena_Ok;
      Total_Count   : Word := 0;
      Count_Value   : Word := 0;
      From_Value    : Index_Value := 0;
      Prob          : Real := 0.0;
      Dispersion    : Real := 1.0;
      Local_Status  : Markov_Status := Markov_Ok;
   begin
      Build_Context_Array (C, Data, Local_Status);
      if Local_Status /= Markov_Ok then
         Status := Local_Status;
         return;
      end if;

      Context_Key := Hash_Sequence (C.Seed, Data, C.Context_Length);
      Current_State := Find_State (C, Context_Key);
      if Current_State = 0 then
         C.Cached_Entropy := 0.0;
         Status := Markov_Ok;
         return;
      end if;

      for Index in 1 .. C.Transit_Count loop
         Read_Index (C.Trans_From_Span, Index - 1, From_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         if From_Value = Current_State then
            Read_Word (C.Trans_Count_Span, Index - 1, Count_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Total_Count := Total_Count + Count_Value;
         end if;
      end loop;

      if Total_Count = 0 then
         C.Cached_Entropy := 0.0;
         Status := Markov_Ok;
         return;
      end if;

      for Index in 1 .. C.Transit_Count loop
         Read_Index (C.Trans_From_Span, Index - 1, From_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         if From_Value = Current_State then
            Read_Word (C.Trans_Count_Span, Index - 1, Count_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Prob := Real (Count_Value) / Real (Total_Count);
            Dispersion := Dispersion - (Prob * Prob);
         end if;
      end loop;

      C.Cached_Entropy := Dispersion;
      Status := Markov_Ok;
   end Recompute_Entropy;

   procedure Initialize (Status : out Markov_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      if Initialized then
         Status := Markov_Already_Initialized;
         return;
      end if;

      Brainmap_Arena.Initialize (Arena_Status);
      if Arena_Status /= Arena_Ok
        and then Arena_Status /= Arena_Already_Initialized
      then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;

      Chains := (others => (others => <>));
      Initialized := True;
      Status := Markov_Ok;
   end Initialize;

   procedure Reset (Status : out Markov_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Success      : Boolean := False;
   begin
      if not Initialized then
         Status := Markov_Not_Initialized;
         return;
      end if;

      for Chain in Chains'Range loop
         if Chains (Chain).Token > 0 then
            Drop_Reference (Node_ID (Chains (Chain).Token), Success);
         end if;
      end loop;

      Brainmap_Arena.Reset (Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;

      Chains := (others => (others => <>));
      Status := Markov_Ok;
   end Reset;

   function Is_Initialized return Boolean is
   begin
      return Initialized;
   end Is_Initialized;

   procedure Create_Chain
     (Seed   : Galois_Field.Word;
      Order  : Positive;
      Chain  : out Chain_Id;
      Status : out Markov_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Token_Node   : Node_ID := 1;
      Token_Ok     : Boolean := False;
   begin
      Chain := Null_Chain;
      if not Initialized then
         Status := Markov_Not_Initialized;
         return;
      end if;
      if Order > Max_Order then
         Status := Markov_Invalid_Order;
         return;
      end if;

      for Candidate in Chains'Range loop
         if not Chains (Candidate).Active then
            Chain := Candidate;
            exit;
         end if;
      end loop;

      if Chain = Null_Chain then
         Status := Markov_Out_Of_Chains;
         return;
      end if;

      Grab_New_Node (Token_Node, Token_Ok);
      if not Token_Ok then
         Status := Markov_Dumptruck_Error;
         Chain := Null_Chain;
         return;
      end if;

      Chains (Chain).Active := True;
      Chains (Chain).Token := Link_ID (Token_Node);
      Chains (Chain).Seed := Seed;
      Chains (Chain).Order := Order;
      Seed_State (Seed, Word (Chain), Chains (Chain).RNG);

      Claim_Word_Span (Max_Order, Chains (Chain).Context_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Claim_Word_Span (Max_States_Per_Chain, Chains (Chain).State_Key_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Claim_Word_Span (Max_States_Per_Chain, Chains (Chain).State_Total_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Claim_Index_Span (Max_Transitions_Per_Chain, Chains (Chain).Trans_From_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Claim_Word_Span (Max_Transitions_Per_Chain, Chains (Chain).Trans_Symbol_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Claim_Word_Span (Max_Transitions_Per_Chain, Chains (Chain).Trans_Count_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Claim_Real_Span (Max_Transitions_Per_Chain, Chains (Chain).Score_Span, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;

      Fill_Word (Chains (Chain).Context_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Fill_Word (Chains (Chain).State_Key_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Fill_Word (Chains (Chain).State_Total_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Fill_Index (Chains (Chain).Trans_From_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Fill_Word (Chains (Chain).Trans_Symbol_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Fill_Word (Chains (Chain).Trans_Count_Span, 0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Fill_Real (Chains (Chain).Score_Span, 0.0, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;

      Define_Required_Symbols (Chains (Chain), Status);
      if Status /= Markov_Ok then
         Chains (Chain).Active := False;
         Chain := Null_Chain;
         return;
      end if;
      Parse_Default_Programs (Chains (Chain), Status);
      if Status /= Markov_Ok then
         Chains (Chain).Active := False;
         Chain := Null_Chain;
      end if;
   end Create_Chain;

   procedure Reset_Context
     (Chain  : Chain_Id;
      Status : out Markov_Status) is
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
   begin
      if not Initialized then
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
      else
         Fill_Word (Chains (Chain).Context_Span, 0, Arena_Status);
         Chains (Chain).Context_Length := 0;
         Map_Arena_Status (Arena_Status, Status);
      end if;
   end Reset_Context;

   procedure Observe
     (Chain   : Chain_Id;
      Symbol  : Galois_Field.Word;
      Status  : out Markov_Status) is
      C            : Chain_Record renames Chains (Chain);
      Context_Data : Word_Array (1 .. Max_Order);
      Context_Key  : Word := 0;
      State_Id     : Natural := 0;
      Transition_Id : Natural := 0;
      Arena_Status  : Brainmap_Arena.Arena_Status := Arena_Ok;
      Count_Value   : Word := 0;
      Local_Status  : Markov_Status := Markov_Ok;
   begin
      if not Initialized then
         Status := Markov_Not_Initialized;
         return;
      end if;
      if not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
         return;
      end if;

      Build_Context_Array (C, Context_Data, Local_Status);
      if Local_Status /= Markov_Ok then
         Status := Local_Status;
         return;
      end if;

      Context_Key := Hash_Sequence (C.Seed, Context_Data, C.Context_Length);
      Ensure_State (C, Context_Key, State_Id, Local_Status);
      if Local_Status /= Markov_Ok then
         Status := Local_Status;
         return;
      end if;

      Read_Word (C.State_Total_Span, State_Id - 1, Count_Value, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;
      Write_Word (C.State_Total_Span, State_Id - 1, Count_Value + 1, Arena_Status);
      if Arena_Status /= Arena_Ok then
         Map_Arena_Status (Arena_Status, Status);
         return;
      end if;

      Transition_Id := Find_Transition (C, State_Id, Symbol);
      if Transition_Id = 0 then
         if C.Transit_Count >= Max_Transitions_Per_Chain then
            Status := Markov_Out_Of_Transitions;
            return;
         end if;
         Transition_Id := C.Transit_Count + 1;
         Write_Index (C.Trans_From_Span, Transition_Id - 1, State_Id, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Word (C.Trans_Symbol_Span, Transition_Id - 1, Symbol, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Word (C.Trans_Count_Span, Transition_Id - 1, 1, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         C.Transit_Count := C.Transit_Count + 1;
      else
         Read_Word (C.Trans_Count_Span, Transition_Id - 1, Count_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         Write_Word (C.Trans_Count_Span, Transition_Id - 1, Count_Value + 1, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
      end if;

      Shift_Context (C, Symbol, Local_Status);
      if Local_Status /= Markov_Ok then
         Status := Local_Status;
         return;
      end if;

      Recompute_Entropy (Chain, Status);
   end Observe;

   procedure Observe_Block
     (Chain   : Chain_Id;
      Data    : Galois_Field.Word_Array;
      Count   : Natural;
      Status  : out Markov_Status) is
      Local_Status : Markov_Status := Markov_Ok;
   begin
      if Count = 0 then
         Status := Markov_Ok;
         return;
      end if;

      for Offset in 0 .. Count - 1 loop
         Observe (Chain, Data (Data'First + Offset), Local_Status);
         if Local_Status /= Markov_Ok then
            Status := Local_Status;
            return;
         end if;
      end loop;
      Status := Markov_Ok;
   end Observe_Block;

   procedure Predict_Internal
     (Chain         : Chain_Id;
      Sample_Mode   : Boolean;
      Symbol        : out Galois_Field.Word;
      Confidence    : out Real;
      Status        : out Markov_Status) is
      C             : Chain_Record renames Chains (Chain);
      Context_Data  : Word_Array (1 .. Max_Order);
      Context_Key   : Word := 0;
      State_Id      : Natural := 0;
      Total_Seen    : Word := 0;
      Best_Score    : Real := -1.0;
      Best_Symbol   : Word := 0;
      Arena_Status  : Brainmap_Arena.Arena_Status := Arena_Ok;
      From_Value    : Index_Value := 0;
      Symbol_Value  : Word := 0;
      Count_Value   : Word := 0;
      Env           : Float_Expr.Var_Values := (others => 0.0);
      Expr_Status   : Float_Expr.Status_Code := Float_Expr.Ok;
      Score_Value   : Real := 0.0;
      Temp_Value    : Real := 1.0;
      Running_Total : Real := 0.0;
      Pick          : Real := 0.0;
      Roll          : Real := 0.0;
      Local_Status  : Markov_Status := Markov_Ok;
   begin
      Symbol := 0;
      Confidence := 0.0;

      Build_Context_Array (C, Context_Data, Local_Status);
      if Local_Status /= Markov_Ok then
         Status := Local_Status;
         return;
      end if;

      Context_Key := Hash_Sequence (C.Seed, Context_Data, C.Context_Length);
      State_Id := Find_State (C, Context_Key);
      if State_Id = 0 then
         Status := Markov_No_Context;
         return;
      end if;

      Read_Word (C.State_Total_Span, State_Id - 1, Total_Seen, Arena_Status);
      if Arena_Status /= Arena_Ok or else Total_Seen = 0 then
         Status := Markov_No_Prediction;
         return;
      end if;

      for Index in 1 .. C.Transit_Count loop
         Read_Index (C.Trans_From_Span, Index - 1, From_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;

         if From_Value = State_Id then
            Read_Word (C.Trans_Symbol_Span, Index - 1, Symbol_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            Read_Word (C.Trans_Count_Span, Index - 1, Count_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;

            Env := (others => 0.0);
            Env (C.Symbols.Count_Id) := Real (Count_Value);
            Env (C.Symbols.Seen_Id) := Real (Total_Seen);
            Env (C.Symbols.Conf_Id) := Real (Count_Value) / Real (Total_Seen);
            Env (C.Symbols.Ent_Id) := C.Cached_Entropy;
            Env (C.Symbols.Ext_Id) := C.External_Bias;
            Env (C.Symbols.Temp_Id) := 1.0 + C.Cached_Entropy;

            Float_Expr.Evaluate (C.Builder, C.Bias_Expr, Env, Score_Value, Expr_Status);
            if Expr_Status /= Float_Expr.Ok then
               Status := Markov_Expression_Error;
               return;
            end if;
            Float_Expr.Evaluate (C.Builder, C.Temp_Expr, Env, Temp_Value, Expr_Status);
            if Expr_Status /= Float_Expr.Ok then
               Status := Markov_Expression_Error;
               return;
            end if;

            if Temp_Value <= 0.0 then
               Temp_Value := 1.0;
            end if;
            Score_Value := Score_Value / Temp_Value;
            Write_Real (C.Score_Span, Index - 1, Score_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;

            if Score_Value > Best_Score then
               Best_Score := Score_Value;
               Best_Symbol := Symbol_Value;
               Confidence := Real (Count_Value) / Real (Total_Seen);
            end if;

            if Score_Value > 0.0 then
               Running_Total := Running_Total + Score_Value;
            end if;
         end if;
      end loop;

      if Best_Score < 0.0 then
         Status := Markov_No_Prediction;
         return;
      end if;

      if not Sample_Mode or else Running_Total <= 0.0 then
         Symbol := Best_Symbol;
         Status := Markov_Ok;
         return;
      end if;

      Next_Unit_Real (C.RNG, Roll);
      Pick := Roll * Running_Total;
      Running_Total := 0.0;

      for Index in 1 .. C.Transit_Count loop
         Read_Index (C.Trans_From_Span, Index - 1, From_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;

         if From_Value = State_Id then
            Read_Real (C.Score_Span, Index - 1, Score_Value, Arena_Status);
            if Arena_Status /= Arena_Ok then
               Map_Arena_Status (Arena_Status, Status);
               return;
            end if;
            if Score_Value > 0.0 then
               Running_Total := Running_Total + Score_Value;
               if Running_Total >= Pick then
                  Read_Word (C.Trans_Symbol_Span, Index - 1, Symbol, Arena_Status);
                  if Arena_Status /= Arena_Ok then
                     Map_Arena_Status (Arena_Status, Status);
                     return;
                  end if;
                  Status := Markov_Ok;
                  return;
               end if;
            end if;
         end if;
      end loop;

      Symbol := Best_Symbol;
      Status := Markov_Ok;
   end Predict_Internal;

   procedure Predict_Best
     (Chain      : Chain_Id;
      Symbol     : out Galois_Field.Word;
      Confidence : out Real;
      Status     : out Markov_Status) is
   begin
      if not Initialized then
         Symbol := 0;
         Confidence := 0.0;
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Symbol := 0;
         Confidence := 0.0;
         Status := Markov_Invalid_Chain;
      else
         Predict_Internal (Chain, False, Symbol, Confidence, Status);
      end if;
   end Predict_Best;

   procedure Sample_Next
     (Chain      : Chain_Id;
      Symbol     : out Galois_Field.Word;
      Confidence : out Real;
      Status     : out Markov_Status) is
   begin
      if not Initialized then
         Symbol := 0;
         Confidence := 0.0;
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Symbol := 0;
         Confidence := 0.0;
         Status := Markov_Invalid_Chain;
      else
         Predict_Internal (Chain, True, Symbol, Confidence, Status);
      end if;
   end Sample_Next;

   procedure Decay
     (Chain   : Chain_Id;
      Factor  : Real;
      Status  : out Markov_Status) is
      C            : Chain_Record renames Chains (Chain);
      Arena_Status : Brainmap_Arena.Arena_Status := Arena_Ok;
      Count_Value  : Word := 0;
      New_Value    : Word := 0;
   begin
      if not Initialized then
         Status := Markov_Not_Initialized;
         return;
      end if;
      if not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
         return;
      end if;

      for Index in 1 .. C.Transit_Count loop
         Read_Word (C.Trans_Count_Span, Index - 1, Count_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         if Factor <= 0.0 then
            New_Value := 0;
         else
            New_Value := Word (Natural (Real (Count_Value) * Factor));
         end if;
         Write_Word (C.Trans_Count_Span, Index - 1, New_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
      end loop;

      for Index in 1 .. C.State_Count loop
         Read_Word (C.State_Total_Span, Index - 1, Count_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
         if Factor <= 0.0 then
            New_Value := 0;
         else
            New_Value := Word (Natural (Real (Count_Value) * Factor));
         end if;
         Write_Word (C.State_Total_Span, Index - 1, New_Value, Arena_Status);
         if Arena_Status /= Arena_Ok then
            Map_Arena_Status (Arena_Status, Status);
            return;
         end if;
      end loop;

      Recompute_Entropy (Chain, Status);
   end Decay;

   procedure Set_Bias_Expression
     (Chain   : Chain_Id;
      Text    : String;
      Status  : out Markov_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      if not Initialized then
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
      else
         Float_Expr.Parse_Infix (Chains (Chain).Builder, Text, Chains (Chain).Bias_Expr, Expr_Status);
         Map_Expr_Status (Expr_Status, Status);
      end if;
   end Set_Bias_Expression;

   procedure Set_Temperature_Expression
     (Chain   : Chain_Id;
      Text    : String;
      Status  : out Markov_Status) is
      Expr_Status : Float_Expr.Status_Code := Float_Expr.Ok;
   begin
      if not Initialized then
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
      else
         Float_Expr.Parse_Infix (Chains (Chain).Builder, Text, Chains (Chain).Temp_Expr, Expr_Status);
         Map_Expr_Status (Expr_Status, Status);
      end if;
   end Set_Temperature_Expression;

   procedure Set_External_Bias
     (Chain   : Chain_Id;
      Value   : Real;
      Status  : out Markov_Status) is
   begin
      if not Initialized then
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
      else
         Chains (Chain).External_Bias := Value;
         Status := Markov_Ok;
      end if;
   end Set_External_Bias;

   procedure Get_Entropy
     (Chain   : Chain_Id;
      Value   : out Real;
      Status  : out Markov_Status) is
   begin
      Value := 0.0;
      if not Initialized then
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
      else
         Value := Chains (Chain).Cached_Entropy;
         Status := Markov_Ok;
      end if;
   end Get_Entropy;

   procedure Get_Usage
     (Chain         : Chain_Id;
      State_Count   : out Natural;
      Transit_Count : out Natural;
      Status        : out Markov_Status) is
   begin
      State_Count := 0;
      Transit_Count := 0;
      if not Initialized then
         Status := Markov_Not_Initialized;
      elsif not Valid_Chain (Chain) then
         Status := Markov_Invalid_Chain;
      else
         State_Count := Chains (Chain).State_Count;
         Transit_Count := Chains (Chain).Transit_Count;
         Status := Markov_Ok;
      end if;
   end Get_Usage;

end Markov;
