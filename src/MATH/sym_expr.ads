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

with GD_Fixed; use GD_Fixed;

package Sym_Expr is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Configuration
   -------------------------------------------------------------------------
   Max_Nodes : constant := 64;
   Max_Vars  : constant := 16;

   -- Error handling for the evaluation
   type Eval_Result is record
      Success : Boolean;
      Value   : Fix16;
   end record;

   -- The input table for variables
   type Variable_Table is array (0 .. Max_Vars - 1) of Fix16;

   -- Opaque type for the expression engine
   type Expression is private;

   -------------------------------------------------------------------------
   -- Construction API (Builder Pattern)
   -------------------------------------------------------------------------
   -- Reset an expression to empty
   procedure Clear (E : in out Expression);
   
   -- [NEW] Accessor for internal node count (Titanium Safety)
   function Get_Count (E : Expression) return Integer;

   -- 1. Constants & Variables
   function Add_Const (E : in out Expression; Val : Fix16) return Integer;
   function Add_Var   (E : in out Expression; Var_Index : Integer) return Integer;

   -- 2. Arithmetic
   function Add_Add (E : in out Expression; A, B : Integer) return Integer;
   function Add_Sub (E : in out Expression; A, B : Integer) return Integer;
   function Add_Mul (E : in out Expression; A, B : Integer) return Integer;
   function Add_Div (E : in out Expression; A, B : Integer) return Integer;

   -- 3. Advanced Math
   function Add_Abs   (E : in out Expression; A : Integer) return Integer;
   function Add_Neg   (E : in out Expression; A : Integer) return Integer;
   function Add_Min   (E : in out Expression; A, B : Integer) return Integer;
   function Add_Max   (E : in out Expression; A, B : Integer) return Integer;
   function Add_Clamp (E : in out Expression; Val, Low, High : Integer) return Integer;
   function Add_Lerp  (E : in out Expression; Start, Stop, T : Integer) return Integer;

   -------------------------------------------------------------------------
   -- Execution
   -------------------------------------------------------------------------
   function Evaluate (E : Expression; Vars : Variable_Table) return Fix16;

private

   type Op_Code is (
      Op_Const, Op_Var, 
      Op_Add, Op_Sub, Op_Mul, Op_Div, 
      Op_Neg, Op_Abs, 
      Op_Min, Op_Max, 
      Op_Clamp, Op_Lerp
   );

   type Node is record
      Op      : Op_Code;
      A, B, C : Integer range 0 .. Max_Nodes - 1;
      Value   : Fix16;
   end record;

   type Node_Array is array (0 .. Max_Nodes - 1) of Node;

   type Expression is record
      Count : Integer range 0 .. Max_Nodes := 0;
      Nodes : Node_Array;
   end record;

end Sym_Expr;