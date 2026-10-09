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

package body Sym_Expr is

   -------------------------------------------------------------------------
   -- Helper: Add Node
   -------------------------------------------------------------------------
   function Push_Node (E : in out Expression; N : Node) return Integer is
      Index : Integer;
   begin
      if E.Count >= Max_Nodes then
         Index := Max_Nodes - 1;
      else
         Index := E.Count;
         E.Count := E.Count + 1;
      end if;
      
      E.Nodes(Index) := N;
      return Index;
   end Push_Node;

   -------------------------------------------------------------------------
   -- Construction API
   -------------------------------------------------------------------------
   procedure Clear (E : in out Expression) is
   begin
      E.Count := 0;
   end Clear;

   -- [NEW] Implementation of Get_Count
   function Get_Count (E : Expression) return Integer is
   begin
      return E.Count;
   end Get_Count;

   function Add_Const (E : in out Expression; Val : Fix16) return Integer is
   begin
      return Push_Node(E, (Op => Op_Const, Value => Val, A => 0, B => 0, C => 0));
   end Add_Const;

   function Add_Var (E : in out Expression; Var_Index : Integer) return Integer is
      Safe_Idx : Integer := Var_Index;
   begin
      if Safe_Idx < 0 then Safe_Idx := 0; end if;
      if Safe_Idx >= Max_Vars then Safe_Idx := Max_Vars - 1; end if;
      return Push_Node(E, (Op => Op_Var, A => Safe_Idx, Value => Zero, B => 0, C => 0));
   end Add_Var;

   -- Binary Ops
   function Add_Add (E : in out Expression; A, B : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Add, A => A, B => B, C => 0, Value => Zero));
   end Add_Add;

   function Add_Sub (E : in out Expression; A, B : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Sub, A => A, B => B, C => 0, Value => Zero));
   end Add_Sub;

   function Add_Mul (E : in out Expression; A, B : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Mul, A => A, B => B, C => 0, Value => Zero));
   end Add_Mul;

   function Add_Div (E : in out Expression; A, B : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Div, A => A, B => B, C => 0, Value => Zero));
   end Add_Div;

   function Add_Min (E : in out Expression; A, B : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Min, A => A, B => B, C => 0, Value => Zero));
   end Add_Min;

   function Add_Max (E : in out Expression; A, B : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Max, A => A, B => B, C => 0, Value => Zero));
   end Add_Max;

   -- Unary Ops
   function Add_Abs (E : in out Expression; A : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Abs, A => A, B => 0, C => 0, Value => Zero));
   end Add_Abs;

   function Add_Neg (E : in out Expression; A : Integer) return Integer is
   begin return Push_Node(E, (Op => Op_Neg, A => A, B => 0, C => 0, Value => Zero));
   end Add_Neg;

   -- Ternary Ops
   function Add_Clamp (E : in out Expression; Val, Low, High : Integer) return Integer is
   begin
      return Push_Node(E, (Op => Op_Clamp, A => Val, B => Low, C => High, Value => Zero));
   end Add_Clamp;

   function Add_Lerp (E : in out Expression; Start, Stop, T : Integer) return Integer is
   begin
      return Push_Node(E, (Op => Op_Lerp, A => Start, B => Stop, C => T, Value => Zero));
   end Add_Lerp;

   -------------------------------------------------------------------------
   -- Evaluation (The VM Loop)
   -------------------------------------------------------------------------
   function Evaluate (E : Expression; Vars : Variable_Table) return Fix16 is
      Results : array (0 .. Max_Nodes - 1) of Fix16;
      Val_A, Val_B, Val_C : Fix16;
   begin
      if E.Count = 0 then
         return Zero;
      end if;

      for I in 0 .. E.Count - 1 loop
         case E.Nodes(I).Op is
            when Op_Const =>
               Results(I) := E.Nodes(I).Value;
            when Op_Var =>
               Results(I) := Vars(E.Nodes(I).A);
            when Op_Add =>
               Results(I) := Add_Sat(Results(E.Nodes(I).A), Results(E.Nodes(I).B));
            when Op_Sub =>
               Results(I) := Sub_Sat(Results(E.Nodes(I).A), Results(E.Nodes(I).B));
            when Op_Mul =>
               Results(I) := Mul_Sat(Results(E.Nodes(I).A), Results(E.Nodes(I).B));
            when Op_Div =>
               Results(I) := Div_Sat(Results(E.Nodes(I).A), Results(E.Nodes(I).B));
            when Op_Neg =>
               Results(I) := Sub_Sat(Zero, Results(E.Nodes(I).A));
            when Op_Abs =>
               Val_A := Results(E.Nodes(I).A);
               if Val_A < Zero then
                  Results(I) := Sub_Sat(Zero, Val_A);
               else
                  Results(I) := Val_A;
               end if;

            when Op_Min =>
               Val_A := Results(E.Nodes(I).A);
               Val_B := Results(E.Nodes(I).B);
               if Val_A < Val_B then Results(I) := Val_A; else Results(I) := Val_B; end if;
            when Op_Max =>
               Val_A := Results(E.Nodes(I).A);
               Val_B := Results(E.Nodes(I).B);
               if Val_A > Val_B then Results(I) := Val_A; else Results(I) := Val_B; end if;

            when Op_Clamp =>
               Val_A := Results(E.Nodes(I).A); -- Value
               Val_B := Results(E.Nodes(I).B); -- Low
               Val_C := Results(E.Nodes(I).C); -- High
               
               if Val_A < Val_B then Val_A := Val_B; end if;
               if Val_A > Val_C then Val_A := Val_C; end if;
               Results(I) := Val_A;

            when Op_Lerp =>
               Val_A := Results(E.Nodes(I).A); -- Start
               Val_B := Results(E.Nodes(I).B); -- Stop
               Val_C := Results(E.Nodes(I).C); -- T
               -- Logic: A + (B - A) * T
               Results(I) := Add_Sat(Val_A, Mul_Sat(Sub_Sat(Val_B, Val_A), Val_C));
         end case;
      end loop;

      return Results(E.Count - 1);
   end Evaluate;

end Sym_Expr;