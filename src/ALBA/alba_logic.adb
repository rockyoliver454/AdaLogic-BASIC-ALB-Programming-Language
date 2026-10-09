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

pragma SPARK_Mode (Off);

with Numerus_Magnus; use Numerus_Magnus;

package body ALBA_Logic is

   Max_Fact_Slots : constant Positive := 1024;
   Max_Rules      : constant Positive := 128;
   Max_Rule_Terms : constant Positive := 512;
   Max_Rule_Vars  : constant Positive := 16;
   Max_Recursion  : constant Positive := 16;

   type S32_Buffer is array (Positive range <>) of S32;

   Fact_Pred  : array (Positive range 1 .. Max_Fact_Slots) of U32 := (others => 0);
   Fact_Value : array (Positive range 1 .. Max_Fact_Slots) of S32 := (others => 0);
   Fact_State : array (Positive range 1 .. Max_Fact_Slots) of Integer := (others => 0);

   Rule_Count      : Natural := 0;
   Rule_Term_Count : Natural := 0;

   Rule_Head_Pred  : array (Positive range 1 .. Max_Rules) of U32 := (others => 0);
   Rule_Head_Mode  : array (Positive range 1 .. Max_Rules) of Natural := (others => 0);
   Rule_Head_Value : array (Positive range 1 .. Max_Rules) of S32 := (others => 0);
   Rule_Var_Counts : array (Positive range 1 .. Max_Rules) of Natural := (others => 0);
   Rule_Body_Start : array (Positive range 1 .. Max_Rules) of Natural := (others => 0);
   Rule_Body_Count : array (Positive range 1 .. Max_Rules) of Natural := (others => 0);

   Rule_Term_Pred  : array (Positive range 1 .. Max_Rule_Terms) of U32 := (others => 0);
   Rule_Term_Mode  : array (Positive range 1 .. Max_Rule_Terms) of Natural := (others => 0);
   Rule_Term_Value : array (Positive range 1 .. Max_Rule_Terms) of S32 := (others => 0);

   Rule_Bind_State : array (Positive range 1 .. Max_Rule_Vars) of Boolean := (others => False);
   Rule_Bind_Value : array (Positive range 1 .. Max_Rule_Vars) of S32 := (others => 0);
   Saved_Bind_State : array (Positive range 1 .. Max_Rule_Vars) of Boolean := (others => False);
   Saved_Bind_Value : array (Positive range 1 .. Max_Rule_Vars) of S32 := (others => 0);
   Rule_Candidates : S32_Buffer (1 .. Max_Find_Results) := (others => 0);
   Rule_Recursion  : Natural := 0;

   Last_Find_Count   : Natural := 0;
   Last_Find_Results : S32_Buffer (1 .. Max_Find_Results) := (others => 0);

   function Find_Slot
     (Pred_Hash  : U32;
      Value      : S32;
      For_Insert : Boolean) return Natural;

   function Fact_Prove
     (Pred_Hash : U32;
      Value     : S32) return Boolean;

   function Fact_Find_First
     (Pred_Hash : U32) return S32;

   function Fact_Find_All
     (Pred_Hash : U32;
      Target    : in out S32_Buffer;
      Limit     : Natural) return Natural;

   procedure Clear_Bindings (Var_Count : Natural);

   function Bind_Var
     (Var_Id : Natural;
      Value  : S32) return Boolean;

   function Rule_Contains
     (Target : S32_Buffer;
      Count  : Natural;
      Value  : S32) return Boolean;

   function Rule_Seed_Term
     (Rule_Index    : Natural;
      Preferred_Var : S32) return Natural;

   function Rule_Body_Match (Rule_Index : Natural) return Boolean;

   function Rule_Match_Query
     (Rule_Index : Natural;
      Query_Value : S32) return Boolean;

   function Rule_Find_First (Rule_Index : Natural) return S32;

   function Rule_Append_Matches
     (Rule_Index : Natural;
      Target     : in out S32_Buffer;
      Out_Count  : Natural;
      Limit      : Natural) return Natural;

   function Hash_Name (Text : String) return U32 is
      Hash : U32 := 16#811C9DC5#;
   begin
      for Ch of Text loop
         Hash := Hash xor U32 (Character'Pos (Ch));
         Hash := Hash * 16#01000193#;
      end loop;
      return Hash;
   end Hash_Name;

   function Find_Slot
     (Pred_Hash  : U32;
      Value      : S32;
      For_Insert : Boolean) return Natural
   is
      Base_Slot       : Natural := Natural (Pred_Hash mod U32 (Max_Fact_Slots));
      First_Tombstone : Natural := 0;
      Slot            : Natural := 0;
   begin
      for Probe in 0 .. Max_Fact_Slots - 1 loop
         Slot := ((Base_Slot + Probe) mod Max_Fact_Slots) + 1;
         if Fact_State (Slot) = 0 then
            if For_Insert then
               if First_Tombstone /= 0 then
                  return First_Tombstone;
               end if;
               return Slot;
            end if;
            return 0;
         elsif Fact_State (Slot) < 0 then
            if For_Insert and then First_Tombstone = 0 then
               First_Tombstone := Slot;
            end if;
         elsif Fact_Pred (Slot) = Pred_Hash and then Fact_Value (Slot) = Value then
            return Slot;
         end if;
      end loop;

      if For_Insert then
         return First_Tombstone;
      end if;
      return 0;
   end Find_Slot;

   procedure Assert_Fact
     (Pred_Hash : in U32;
      Value     : in S32) is
      Slot : constant Natural := Find_Slot (Pred_Hash, Value, True);
   begin
      if Slot = 0 then
         return;
      end if;
      Fact_Pred (Slot) := Pred_Hash;
      Fact_Value (Slot) := Value;
      Fact_State (Slot) := 1;
   end Assert_Fact;

   procedure Retract_Fact
     (Pred_Hash : in U32;
      Value     : in S32) is
      Slot : constant Natural := Find_Slot (Pred_Hash, Value, False);
   begin
      if Slot = 0 or else Fact_State (Slot) <= 0 then
         return;
      end if;
      Fact_State (Slot) := -1;
   end Retract_Fact;

   procedure Update_Fact
     (Pred_Hash : in U32;
      Old_Value : in S32;
      New_Value : in S32) is
   begin
      if Old_Value /= New_Value then
         Retract_Fact (Pred_Hash, Old_Value);
      end if;
      Assert_Fact (Pred_Hash, New_Value);
   end Update_Fact;

   function Fact_Prove
     (Pred_Hash : U32;
      Value     : S32) return Boolean is
   begin
      return Find_Slot (Pred_Hash, Value, False) /= 0;
   end Fact_Prove;

   function Fact_Find_First
     (Pred_Hash : U32) return S32 is
   begin
      for Slot in 1 .. Max_Fact_Slots loop
         if Fact_State (Slot) > 0 and then Fact_Pred (Slot) = Pred_Hash then
            return Fact_Value (Slot);
         end if;
      end loop;
      return 0;
   end Fact_Find_First;

   function Fact_Find_All
     (Pred_Hash : U32;
      Target    : in out S32_Buffer;
      Limit     : Natural) return Natural
   is
      Out_Count : Natural := 0;
   begin
      for Slot in 1 .. Max_Fact_Slots loop
         exit when Out_Count >= Limit or else Out_Count >= Target'Length;
         if Fact_State (Slot) > 0 and then Fact_Pred (Slot) = Pred_Hash then
            Out_Count := Out_Count + 1;
            Target (Out_Count) := Fact_Value (Slot);
         end if;
      end loop;
      return Out_Count;
   end Fact_Find_All;

   procedure Clear_Bindings (Var_Count : Natural) is
      Limit : Natural := Var_Count;
   begin
      if Limit > Max_Rule_Vars then
         Limit := Max_Rule_Vars;
      end if;
      for I in 1 .. Limit loop
         Rule_Bind_State (I) := False;
         Rule_Bind_Value (I) := 0;
      end loop;
   end Clear_Bindings;

   function Bind_Var
     (Var_Id : Natural;
      Value  : S32) return Boolean is
   begin
      if Var_Id = 0 or else Var_Id > Max_Rule_Vars then
         return False;
      end if;
      if not Rule_Bind_State (Var_Id) then
         Rule_Bind_State (Var_Id) := True;
         Rule_Bind_Value (Var_Id) := Value;
         return True;
      end if;
      return Rule_Bind_Value (Var_Id) = Value;
   end Bind_Var;

   function Rule_Contains
     (Target : S32_Buffer;
      Count  : Natural;
      Value  : S32) return Boolean is
   begin
      for I in 1 .. Natural'Min (Count, Target'Length) loop
         if Target (I) = Value then
            return True;
         end if;
      end loop;
      return False;
   end Rule_Contains;

   function Rule_Seed_Term
     (Rule_Index    : Natural;
      Preferred_Var : S32) return Natural
   is
      Start_At : constant Natural := Rule_Body_Start (Rule_Index);
      Count    : constant Natural := Rule_Body_Count (Rule_Index);
      Slot     : Natural := 0;
   begin
      if Count = 0 then
         return 0;
      end if;
      for I in 0 .. Count - 1 loop
         Slot := Start_At + I;
         if Slot in 1 .. Max_Rule_Terms
           and then Rule_Term_Mode (Slot) = 2
           and then Rule_Term_Value (Slot) = Preferred_Var
         then
            return Slot;
         end if;
      end loop;

      for I in 0 .. Count - 1 loop
         Slot := Start_At + I;
         if Slot in 1 .. Max_Rule_Terms and then Rule_Term_Mode (Slot) = 2 then
            return Slot;
         end if;
      end loop;

      return 0;
   end Rule_Seed_Term;

   function Rule_Body_Match (Rule_Index : Natural) return Boolean is
      Start_At   : constant Natural := Rule_Body_Start (Rule_Index);
      Count      : constant Natural := Rule_Body_Count (Rule_Index);
      Slot       : Natural := 0;
      Mode       : Natural := 0;
      Query_Value : S32 := 0;
   begin
      if Count = 0 then
         return True;
      end if;
      for I in 0 .. Count - 1 loop
         Slot := Start_At + I;
         exit when Slot not in 1 .. Max_Rule_Terms;
         Mode := Rule_Term_Mode (Slot);
         if Mode = 1 then
            Query_Value := Rule_Term_Value (Slot);
         elsif Mode = 2 then
            declare
               Var_Id : constant Natural := Natural'Max (0, Integer (Rule_Term_Value (Slot)));
            begin
               if Var_Id = 0 or else Var_Id > Max_Rule_Vars or else not Rule_Bind_State (Var_Id) then
                  return False;
               end if;
               Query_Value := Rule_Bind_Value (Var_Id);
            end;
         else
            Query_Value := 0;
         end if;

         for Bind in 1 .. Max_Rule_Vars loop
            Saved_Bind_State (Bind) := Rule_Bind_State (Bind);
            Saved_Bind_Value (Bind) := Rule_Bind_Value (Bind);
         end loop;

         if not Prove (Rule_Term_Pred (Slot), Query_Value) then
            for Bind in 1 .. Max_Rule_Vars loop
               Rule_Bind_State (Bind) := Saved_Bind_State (Bind);
               Rule_Bind_Value (Bind) := Saved_Bind_Value (Bind);
            end loop;
            return False;
         end if;

         for Bind in 1 .. Max_Rule_Vars loop
            Rule_Bind_State (Bind) := Saved_Bind_State (Bind);
            Rule_Bind_Value (Bind) := Saved_Bind_Value (Bind);
         end loop;
      end loop;

      return True;
   end Rule_Body_Match;

   function Rule_Match_Query
     (Rule_Index : Natural;
      Query_Value : S32) return Boolean is
      Head_Mode  : constant Natural := Rule_Head_Mode (Rule_Index);
      Head_Value : constant S32 := Rule_Head_Value (Rule_Index);
   begin
      Clear_Bindings (Rule_Var_Counts (Rule_Index));
      if Head_Mode = 1 then
         if Head_Value /= Query_Value then
            return False;
         end if;
         return Rule_Body_Match (Rule_Index);
      elsif Head_Mode = 0 then
         return Query_Value = 0 and then Rule_Body_Match (Rule_Index);
      elsif not Bind_Var (Natural'Max (0, Integer (Head_Value)), Query_Value) then
         return False;
      end if;
      return Rule_Body_Match (Rule_Index);
   end Rule_Match_Query;

   function Rule_Find_First (Rule_Index : Natural) return S32 is
      Head_Mode  : constant Natural := Rule_Head_Mode (Rule_Index);
      Head_Value : constant S32 := Rule_Head_Value (Rule_Index);
      Seed_Slot  : Natural := 0;
      Seed_Var   : Natural := 0;
      Candidate_Count : Natural := 0;
   begin
      Clear_Bindings (Rule_Var_Counts (Rule_Index));
      if Head_Mode = 1 then
         if Rule_Body_Match (Rule_Index) then
            return Head_Value;
         end if;
         return 0;
      elsif Head_Mode = 0 then
         if Rule_Body_Match (Rule_Index) then
            return 0;
         end if;
         return 0;
      end if;

      Seed_Slot := Rule_Seed_Term (Rule_Index, Head_Value);
      if Seed_Slot = 0 then
         return 0;
      end if;
      Seed_Var := Natural'Max (0, Integer (Rule_Term_Value (Seed_Slot)));
      Candidate_Count :=
        Fact_Find_All (Rule_Term_Pred (Seed_Slot), Rule_Candidates, Rule_Candidates'Length);

      for I in 1 .. Candidate_Count loop
         Clear_Bindings (Rule_Var_Counts (Rule_Index));
         if Bind_Var (Seed_Var, Rule_Candidates (I))
           and then Rule_Body_Match (Rule_Index)
         then
            if Natural'Max (0, Integer (Head_Value)) in 1 .. Max_Rule_Vars
              and then Rule_Bind_State (Natural'Max (0, Integer (Head_Value)))
            then
               return Rule_Bind_Value (Natural'Max (0, Integer (Head_Value)));
            end if;
         end if;
      end loop;

      return 0;
   end Rule_Find_First;

   function Rule_Append_Matches
     (Rule_Index : Natural;
      Target     : in out S32_Buffer;
      Out_Count  : Natural;
      Limit      : Natural) return Natural
   is
      Count_Out  : Natural := Out_Count;
      Head_Mode  : constant Natural := Rule_Head_Mode (Rule_Index);
      Head_Value : constant S32 := Rule_Head_Value (Rule_Index);
      Seed_Slot  : Natural := 0;
      Seed_Var   : Natural := 0;
      Candidate_Count : Natural := 0;
      Derived    : S32 := 0;
   begin
      if Head_Mode = 1 then
         Clear_Bindings (Rule_Var_Counts (Rule_Index));
         if Rule_Body_Match (Rule_Index)
           and then Count_Out < Limit
           and then Count_Out < Target'Length
           and then not Rule_Contains (Target, Count_Out, Head_Value)
         then
            Count_Out := Count_Out + 1;
            Target (Count_Out) := Head_Value;
         end if;
         return Count_Out;
      elsif Head_Mode /= 2 then
         return Count_Out;
      end if;

      Seed_Slot := Rule_Seed_Term (Rule_Index, Head_Value);
      if Seed_Slot = 0 then
         return Count_Out;
      end if;
      Seed_Var := Natural'Max (0, Integer (Rule_Term_Value (Seed_Slot)));
      Candidate_Count :=
        Fact_Find_All (Rule_Term_Pred (Seed_Slot), Rule_Candidates, Rule_Candidates'Length);

      for I in 1 .. Candidate_Count loop
         exit when Count_Out >= Limit or else Count_Out >= Target'Length;
         Clear_Bindings (Rule_Var_Counts (Rule_Index));
         if Bind_Var (Seed_Var, Rule_Candidates (I))
           and then Rule_Body_Match (Rule_Index)
           and then Natural'Max (0, Integer (Head_Value)) in 1 .. Max_Rule_Vars
           and then Rule_Bind_State (Natural'Max (0, Integer (Head_Value)))
         then
            Derived := Rule_Bind_Value (Natural'Max (0, Integer (Head_Value)));
            if not Rule_Contains (Target, Count_Out, Derived) then
               Count_Out := Count_Out + 1;
               Target (Count_Out) := Derived;
            end if;
         end if;
      end loop;

      return Count_Out;
   end Rule_Append_Matches;

   function Prove
     (Pred_Hash : in U32;
      Value     : in S32) return Boolean is
   begin
      if Fact_Prove (Pred_Hash, Value) then
         return True;
      end if;
      if Rule_Recursion >= Max_Recursion then
         return False;
      end if;

      Rule_Recursion := Rule_Recursion + 1;
      begin
         for Rule in 1 .. Rule_Count loop
            if Rule_Head_Pred (Rule) = Pred_Hash
              and then Rule_Match_Query (Rule, Value)
            then
               Rule_Recursion := Rule_Recursion - 1;
               return True;
            end if;
         end loop;
      exception
         when others =>
            Rule_Recursion := Rule_Recursion - 1;
            raise;
      end;
      Rule_Recursion := Rule_Recursion - 1;
      return False;
   end Prove;

   function Find_First
     (Pred_Hash : in U32) return S32 is
      Direct : constant S32 := Fact_Find_First (Pred_Hash);
      Derived : S32 := 0;
   begin
      if Direct /= 0 then
         return Direct;
      end if;
      if Rule_Recursion >= Max_Recursion then
         return 0;
      end if;

      Rule_Recursion := Rule_Recursion + 1;
      begin
         for Rule in 1 .. Rule_Count loop
            if Rule_Head_Pred (Rule) = Pred_Hash then
               Derived := Rule_Find_First (Rule);
               if Derived /= 0 or else Rule_Head_Mode (Rule) = 1 then
                  Rule_Recursion := Rule_Recursion - 1;
                  return Derived;
               end if;
            end if;
         end loop;
      exception
         when others =>
            Rule_Recursion := Rule_Recursion - 1;
            raise;
      end;
      Rule_Recursion := Rule_Recursion - 1;
      return 0;
   end Find_First;

   procedure Find_All (Pred_Hash : in U32) is
      Out_Count : Natural := 0;
   begin
      Last_Find_Count := 0;
      Last_Find_Results := (others => 0);
      Out_Count := Fact_Find_All (Pred_Hash, Last_Find_Results, Last_Find_Results'Length);
      if Rule_Recursion >= Max_Recursion then
         Last_Find_Count := Out_Count;
         return;
      end if;

      Rule_Recursion := Rule_Recursion + 1;
      begin
         for Rule in 1 .. Rule_Count loop
            exit when Out_Count >= Last_Find_Results'Length;
            if Rule_Head_Pred (Rule) = Pred_Hash then
               Out_Count :=
                 Rule_Append_Matches
                   (Rule,
                    Last_Find_Results,
                    Out_Count,
                    Last_Find_Results'Length);
            end if;
         end loop;
      exception
         when others =>
            Rule_Recursion := Rule_Recursion - 1;
            raise;
      end;
      Rule_Recursion := Rule_Recursion - 1;
      Last_Find_Count := Out_Count;
   end Find_All;

   function Find_Result_Count return Natural is
   begin
      return Last_Find_Count;
   end Find_Result_Count;

   function Find_Result (Index : in Positive) return S32 is
   begin
      if Index > Last_Find_Count or else Index > Last_Find_Results'Length then
         return 0;
      end if;
      return Last_Find_Results (Index);
   end Find_Result;

   function Register_Rule
     (Head_Pred_Hash : in U32;
      Head_Mode      : in Natural;
      Head_Value     : in S32;
      Var_Count      : in Natural) return Natural is
      Slot : Natural := Rule_Count + 1;
   begin
      if Slot = 0 or else Slot > Max_Rules then
         return 0;
      end if;

      Rule_Count := Slot;
      Rule_Head_Pred (Slot) := Head_Pred_Hash;
      Rule_Head_Mode (Slot) := Head_Mode;
      Rule_Head_Value (Slot) := Head_Value;
      Rule_Var_Counts (Slot) := Natural'Min (Var_Count, Max_Rule_Vars);
      Rule_Body_Start (Slot) := Rule_Term_Count + 1;
      Rule_Body_Count (Slot) := 0;
      return Slot;
   end Register_Rule;

   procedure Add_Rule_Term
     (Rule_Index : in Natural;
      Pred_Hash  : in U32;
      Arg_Mode   : in Natural;
      Arg_Value  : in S32) is
      Slot : Natural := Rule_Term_Count + 1;
   begin
      if Rule_Index = 0 or else Rule_Index > Rule_Count then
         return;
      end if;
      if Slot = 0 or else Slot > Max_Rule_Terms then
         return;
      end if;

      Rule_Term_Count := Slot;
      Rule_Term_Pred (Slot) := Pred_Hash;
      Rule_Term_Mode (Slot) := Arg_Mode;
      Rule_Term_Value (Slot) := Arg_Value;
      Rule_Body_Count (Rule_Index) := Rule_Body_Count (Rule_Index) + 1;
   end Add_Rule_Term;

end ALBA_Logic;
