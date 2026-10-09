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

pragma SPARK_Mode (On);
with ALB_Types;      use ALB_Types;
with Numerus_Magnus; use Numerus_Magnus;
with Pure_Types;     use Pure_Types;

package ALB_Ops is
   pragma Pure;

   -- =========================================================================
   -- DA MATHEMATICAL ANVIL (The ALU)
   -- Operations require strict Type_Tag matching tae prevent silent coercion drift.
   -- =========================================================================

   procedure Add_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean);
   procedure Sub_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean);
   procedure Mul_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean);
   procedure Div_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean);

   -- =========================================================================
   -- DA LOGIC GATES
   -- Returns an ALB_Value explicitly tagged as Type_Boolean.
   -- =========================================================================

   procedure Is_Equal   (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean);
   procedure Is_Less    (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean);
   procedure Is_Greater (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean);

end ALB_Ops;
