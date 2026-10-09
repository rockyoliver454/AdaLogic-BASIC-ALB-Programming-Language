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

--  core_simd.ads
pragma Ada_2012;

with Interfaces;

package Core_Simd
  with SPARK_Mode => On,
       Pure
is
   ----------------------------------------------------------------------------
   --  Phase 1: Soft SIMD Foundation
   ----------------------------------------------------------------------------

   subtype F32 is Interfaces.IEEE_Float_32;
   type Lane_Index is range 0 .. 3;

   type Float4 is array (Lane_Index) of F32;
   for Float4'Alignment      use 16;
   for Float4'Component_Size use 32;
   for Float4'Size           use 128;

   type Mask4 is array (Lane_Index) of F32;
   for Mask4'Alignment      use 16;
   for Mask4'Component_Size use 32;
   for Mask4'Size           use 128;

   ----------------------------------------------------------------------------
   --  Phase 2: Interface Layer (API)
   ----------------------------------------------------------------------------

   Zero4      : constant Float4 := (others => 0.0);
   One4       : constant Float4 := (others => 1.0);
   Mask_False : constant Mask4  := (others => 0.0);
   Mask_True  : constant Mask4  := (others => 1.0);

   function Splat (V : F32) return Float4;
   pragma Inline_Always (Splat);

   function Make (V0, V1, V2, V3 : F32) return Float4;
   pragma Inline_Always (Make);

   function Lane (V : Float4; I : Lane_Index) return F32;
   pragma Inline_Always (Lane);

   ----------------------------------------------------------------------------
   --  Phase 3: Arithmetic (operator overloading)
   ----------------------------------------------------------------------------

   function "+" (A, B : Float4) return Float4;
   pragma Inline_Always ("+");

   function "-" (A, B : Float4) return Float4;
   pragma Inline_Always ("-");

   function "-" (A : Float4) return Float4;
   pragma Inline_Always ("-");

   function "*" (A, B : Float4) return Float4;
   pragma Inline_Always ("*");

   function "/" (A, B : Float4) return Float4;
   pragma Inline_Always ("/");

   --  Scalar broadcast helpers
   function "+" (A : Float4; B : F32) return Float4;
   pragma Inline_Always ("+");

   function "-" (A : Float4; B : F32) return Float4;
   pragma Inline_Always ("-");

   function "*" (A : Float4; B : F32) return Float4;
   pragma Inline_Always ("*");

   function "/" (A : Float4; B : F32) return Float4;
   pragma Inline_Always ("/");

   ----------------------------------------------------------------------------
   --  Phase 4: Geometric & Math Helpers
   ----------------------------------------------------------------------------

   --  Fused Multiply-Add: A * B + C
   function FMA (A, B, C : Float4) return Float4;
   pragma Inline_Always (FMA);

   --  Linear Interpolation: A + (B - A) * T
   function Lerp (A, B : Float4; T : F32) return Float4;
   pragma Inline_Always (Lerp);

   --  Dot Product: Sum (A * B)
   function Dot (A, B : Float4) return F32;
   pragma Inline_Always (Dot);

   --  Clamp: Restrict V between Low and High
   function Clamp (V, Low, High : Float4) return Float4;
   pragma Inline_Always (Clamp);

   ----------------------------------------------------------------------------
   --  Useful primitives
   ----------------------------------------------------------------------------

   function "abs" (A : Float4) return Float4;
   pragma Inline_Always ("abs");

   function Min (A, B : Float4) return Float4;
   pragma Inline_Always (Min);

   function Max (A, B : Float4) return Float4;
   pragma Inline_Always (Max);

   ----------------------------------------------------------------------------
   --  Phase 5: Branchless Logic System
   ----------------------------------------------------------------------------

   function Cmp_LT (A, B : Float4) return Mask4;
   pragma Inline_Always (Cmp_LT);

   function Cmp_LE (A, B : Float4) return Mask4;
   pragma Inline_Always (Cmp_LE);

   function Cmp_GT (A, B : Float4) return Mask4;
   pragma Inline_Always (Cmp_GT);

   function Cmp_GE (A, B : Float4) return Mask4;
   pragma Inline_Always (Cmp_GE);

   function Cmp_EQ (A, B : Float4) return Mask4;
   pragma Inline_Always (Cmp_EQ);

   function Cmp_NE (A, B : Float4) return Mask4;
   pragma Inline_Always (Cmp_NE);

   function Blend (M : Mask4; T, F : Float4) return Float4;
   pragma Inline_Always (Blend);

   function Any (M : Mask4) return Boolean;
   pragma Inline_Always (Any);

   function All_Lanes (M : Mask4) return Boolean;
   pragma Inline_Always (All_Lanes);

   ----------------------------------------------------------------------------
   --  Verification hook
   ----------------------------------------------------------------------------

   procedure Self_Test (Ok : out Boolean);
   pragma Inline_Always (Self_Test);

end Core_Simd;