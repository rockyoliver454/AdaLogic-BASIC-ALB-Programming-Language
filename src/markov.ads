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

with Galois_Field;

package Markov
  with SPARK_Mode => On
is
   subtype Real is Float;

   Max_Chains                : constant Positive := 8;
   Max_Order                 : constant Positive := 4;
   Max_States_Per_Chain      : constant Positive := 512;
   Max_Transitions_Per_Chain : constant Positive := 4_096;
   Max_Formula_Length        : constant Positive := 120;

   type Markov_Status is
     (Markov_Ok,
      Markov_Not_Initialized,
      Markov_Already_Initialized,
      Markov_Arena_Error,
      Markov_Dumptruck_Error,
      Markov_Out_Of_Chains,
      Markov_Out_Of_States,
      Markov_Out_Of_Transitions,
      Markov_Invalid_Chain,
      Markov_Invalid_Order,
      Markov_No_Context,
      Markov_No_Prediction,
      Markov_Invalid_Expression,
      Markov_Expression_Error);

   type Chain_Id is range 0 .. Max_Chains;
   Null_Chain : constant Chain_Id := 0;

   procedure Initialize (Status : out Markov_Status);
   procedure Reset (Status : out Markov_Status);

   function Is_Initialized return Boolean;

   procedure Create_Chain
     (Seed   : Galois_Field.Word;
      Order  : Positive;
      Chain  : out Chain_Id;
      Status : out Markov_Status)
     with Pre => Order <= Max_Order;

   procedure Reset_Context
     (Chain  : Chain_Id;
      Status : out Markov_Status);

   procedure Observe
     (Chain   : Chain_Id;
      Symbol  : Galois_Field.Word;
      Status  : out Markov_Status);

   procedure Observe_Block
     (Chain   : Chain_Id;
      Data    : Galois_Field.Word_Array;
      Count   : Natural;
      Status  : out Markov_Status)
     with Pre => Count <= Data'Length;

   procedure Predict_Best
     (Chain      : Chain_Id;
      Symbol     : out Galois_Field.Word;
      Confidence : out Real;
      Status     : out Markov_Status);

   procedure Sample_Next
     (Chain      : Chain_Id;
      Symbol     : out Galois_Field.Word;
      Confidence : out Real;
      Status     : out Markov_Status);

   procedure Decay
     (Chain   : Chain_Id;
      Factor  : Real;
      Status  : out Markov_Status);

   procedure Set_Bias_Expression
     (Chain   : Chain_Id;
      Text    : String;
      Status  : out Markov_Status)
     with Pre => Text'Length > 0 and then Text'Length <= Max_Formula_Length;

   procedure Set_Temperature_Expression
     (Chain   : Chain_Id;
      Text    : String;
      Status  : out Markov_Status)
     with Pre => Text'Length > 0 and then Text'Length <= Max_Formula_Length;

   procedure Set_External_Bias
     (Chain   : Chain_Id;
      Value   : Real;
      Status  : out Markov_Status);

   procedure Get_Entropy
     (Chain   : Chain_Id;
      Value   : out Real;
      Status  : out Markov_Status);

   procedure Get_Usage
     (Chain        : Chain_Id;
      State_Count  : out Natural;
      Transit_Count : out Natural;
      Status       : out Markov_Status);

end Markov;
