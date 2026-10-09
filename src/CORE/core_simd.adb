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

--  core_simd.adb
pragma Ada_2012;

package body Core_Simd
  with SPARK_Mode => On
is
   use type F32;

   ----------------------------------------------------------------------------
   --  Small internal helper
   ----------------------------------------------------------------------------
   function Mask_Lane (B : Boolean) return F32 is
   begin
      if B then
         return 1.0;
      else
         return 0.0;
      end if;
   end Mask_Lane;
   pragma Inline_Always (Mask_Lane);

   ----------------------------------------------------------------------------
   --  Constructors / Accessors
   ----------------------------------------------------------------------------

   function Splat (V : F32) return Float4 is
   begin
      return (others => V);
   end Splat;

   function Make (V0, V1, V2, V3 : F32) return Float4 is
   begin
      return (0 => V0, 1 => V1, 2 => V2, 3 => V3);
   end Make;

   function Lane (V : Float4; I : Lane_Index) return F32 is
   begin
      return V (I);
   end Lane;

   ----------------------------------------------------------------------------
   --  Arithmetic (vector-vector)
   ----------------------------------------------------------------------------

   function "+" (A, B : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         R (I) := A (I) + B (I);
      end loop;
      return R;
   end "+";

   function "-" (A, B : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         R (I) := A (I) - B (I);
      end loop;
      return R;
   end "-";

   function "-" (A : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         R (I) := -A (I);
      end loop;
      return R;
   end "-";

   function "*" (A, B : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         R (I) := A (I) * B (I);
      end loop;
      return R;
   end "*";

   function "/" (A, B : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         R (I) := A (I) / B (I);
      end loop;
      return R;
   end "/";

   ----------------------------------------------------------------------------
   --  Arithmetic (vector-scalar)
   ----------------------------------------------------------------------------

   function "+" (A : Float4; B : F32) return Float4 is
   begin
      return A + Splat (B);
   end "+";

   function "-" (A : Float4; B : F32) return Float4 is
   begin
      return A - Splat (B);
   end "-";

   function "*" (A : Float4; B : F32) return Float4 is
   begin
      return A * Splat (B);
   end "*";

   function "/" (A : Float4; B : F32) return Float4 is
   begin
      return A / Splat (B);
   end "/";

   ----------------------------------------------------------------------------
   --  Utility primitives
   --  MOVED UP: These must be defined before they are used in Clamp/FMA
   ----------------------------------------------------------------------------

   function "abs" (A : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         if A (I) < 0.0 then
            R (I) := -A (I);
         else
            R (I) := A (I);
         end if;
      end loop;
      return R;
   end "abs";

   function Min (A, B : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         if A (I) < B (I) then
            R (I) := A (I);
         else
            R (I) := B (I);
         end if;
      end loop;
      return R;
   end Min;

   function Max (A, B : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         if A (I) > B (I) then
            R (I) := A (I);
         else
            R (I) := B (I);
         end if;
      end loop;
      return R;
   end Max;

   ----------------------------------------------------------------------------
   --  Phase 4: Geometric & Math Helpers
   ----------------------------------------------------------------------------

   function FMA (A, B, C : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         R (I) := A (I) * B (I) + C (I);
      end loop;
      return R;
   end FMA;

   function Lerp (A, B : Float4; T : F32) return Float4 is
   begin
      return A + (B - A) * Splat (T);
   end Lerp;

   function Dot (A, B : Float4) return F32 is
      Sum : F32 := 0.0;
   begin
      for I in Lane_Index loop
         Sum := Sum + (A (I) * B (I));
      end loop;
      return Sum;
   end Dot;

   function Clamp (V, Low, High : Float4) return Float4 is
   begin
      return Min (Max (V, Low), High);
   end Clamp;

   ----------------------------------------------------------------------------
   --  Comparisons
   ----------------------------------------------------------------------------

   function Cmp_LT (A, B : Float4) return Mask4 is
      M : Mask4 := Mask_False;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         M (I) := Mask_Lane (A (I) < B (I));
      end loop;
      return M;
   end Cmp_LT;

   function Cmp_LE (A, B : Float4) return Mask4 is
      M : Mask4 := Mask_False;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         M (I) := Mask_Lane (A (I) <= B (I));
      end loop;
      return M;
   end Cmp_LE;

   function Cmp_GT (A, B : Float4) return Mask4 is
      M : Mask4 := Mask_False;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         M (I) := Mask_Lane (A (I) > B (I));
      end loop;
      return M;
   end Cmp_GT;

   function Cmp_GE (A, B : Float4) return Mask4 is
      M : Mask4 := Mask_False;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         M (I) := Mask_Lane (A (I) >= B (I));
      end loop;
      return M;
   end Cmp_GE;

   function Cmp_EQ (A, B : Float4) return Mask4 is
      M : Mask4 := Mask_False;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         M (I) := Mask_Lane (A (I) = B (I));
      end loop;
      return M;
   end Cmp_EQ;

   function Cmp_NE (A, B : Float4) return Mask4 is
      M : Mask4 := Mask_False;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         M (I) := Mask_Lane (A (I) /= B (I));
      end loop;
      return M;
   end Cmp_NE;

   ----------------------------------------------------------------------------
   --  Branchless Blend (Replaces Select)
   ----------------------------------------------------------------------------

   function Blend (M : Mask4; T, F : Float4) return Float4 is
      R : Float4 := Zero4;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         R (I) := F (I) + (T (I) - F (I)) * M (I);
      end loop;
      return R;
   end Blend;

   ----------------------------------------------------------------------------
   --  Lane aggregation
   ----------------------------------------------------------------------------

   function Any (M : Mask4) return Boolean is
   begin
      return (M (0) /= 0.0) or else
             (M (1) /= 0.0) or else
             (M (2) /= 0.0) or else
             (M (3) /= 0.0);
   end Any;

   function All_Lanes (M : Mask4) return Boolean is
   begin
      return (M (0) /= 0.0) and then
             (M (1) /= 0.0) and then
             (M (2) /= 0.0) and then
             (M (3) /= 0.0);
   end All_Lanes;

   ----------------------------------------------------------------------------
   --  Verification hook
   ----------------------------------------------------------------------------

   function Is_Close (X, Y : F32) return Boolean is
      Tol : constant F32 := 1.0E-6;
      D   : constant F32 := (if X >= Y then X - Y else Y - X);
   begin
      return D <= Tol;
   end Is_Close;
   pragma Inline_Always (Is_Close);

   procedure Self_Test (Ok : out Boolean) is
      A  : constant Float4 := Make (1.0,  2.0,  3.0,  4.0);
      B  : constant Float4 := Make (5.0, -2.0, 10.0,  0.5);

      C1 : constant Float4 := A + B;
      C2 : constant Float4 := A * B;
      C3 : constant Float4 := abs B;

      M  : constant Mask4  := Cmp_GT (A, B);
      S  : constant Float4 := Blend (M, A, B);

      --  Additional tests for new features
      Dot_Res : constant F32    := Dot (A, B);
      FMA_Res : constant Float4 := FMA (A, B, One4); 
      
      E1 : constant Float4 := Make (6.0, 0.0, 13.0, 4.5);
      E2 : constant Float4 := Make (5.0, -4.0, 30.0, 2.0);
      E3 : constant Float4 := Make (5.0, 2.0, 10.0, 0.5);
      ES : constant Float4 := Make (5.0, 2.0, 10.0, 4.0);
      EF : constant Float4 := Make (6.0, -3.0, 31.0, 3.0);

      Pass : Boolean := True;
   begin
      for I in Lane_Index loop
         pragma Loop_Optimize (Vector);
         Pass := Pass and then Is_Close (C1 (I), E1 (I));
         Pass := Pass and then Is_Close (C2 (I), E2 (I));
         Pass := Pass and then Is_Close (C3 (I), E3 (I));
         Pass := Pass and then Is_Close (S  (I), ES (I));
         Pass := Pass and then Is_Close (FMA_Res (I), EF (I));
      end loop;

      Pass := Pass and then Is_Close (Dot_Res, 33.0);

      Ok := Pass;
   end Self_Test;

end Core_Simd;