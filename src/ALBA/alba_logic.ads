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

package ALBA_Logic is

   Max_Find_Results : constant Positive := 256;

   function Hash_Name (Text : String) return U32;

   procedure Assert_Fact
     (Pred_Hash : in U32;
      Value     : in S32);

   procedure Retract_Fact
     (Pred_Hash : in U32;
      Value     : in S32);

   procedure Update_Fact
     (Pred_Hash : in U32;
      Old_Value : in S32;
      New_Value : in S32);

   function Prove
     (Pred_Hash : in U32;
      Value     : in S32) return Boolean;

   function Find_First
     (Pred_Hash : in U32) return S32;

   procedure Find_All (Pred_Hash : in U32);

   function Find_Result_Count return Natural;

   function Find_Result (Index : in Positive) return S32;

   function Register_Rule
     (Head_Pred_Hash : in U32;
      Head_Mode      : in Natural;
      Head_Value     : in S32;
      Var_Count      : in Natural) return Natural;

   procedure Add_Rule_Term
     (Rule_Index : in Natural;
      Pred_Hash  : in U32;
      Arg_Mode   : in Natural;
      Arg_Value  : in S32);

end ALBA_Logic;
