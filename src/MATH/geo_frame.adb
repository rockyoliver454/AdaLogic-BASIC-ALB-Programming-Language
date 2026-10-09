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

package body Geo_Frame is

   function Identity return Frame is
   begin
      -- Qualified names to avoid ambiguity
      return (Origin => Geo_Algebra.Zero, Orientation => Scalar(GD_Fixed.One));
   end Identity;

   -------------------------------------------------------------------------
   -- Basis Vectors
   -------------------------------------------------------------------------
   function Forward (F : Frame) return Multivector is
      -- Z+ Forward
      World_Fwd : constant Multivector := Vector(GD_Fixed.Zero, GD_Fixed.Zero, GD_Fixed.One);
   begin
      return Rotate(World_Fwd, F.Orientation);
   end Forward;

   function Up (F : Frame) return Multivector is
      World_Up : constant Multivector := Vector(GD_Fixed.Zero, GD_Fixed.One, GD_Fixed.Zero);
   begin
      return Rotate(World_Up, F.Orientation);
   end Up;

   function Right (F : Frame) return Multivector is
      World_Right : constant Multivector := Vector(GD_Fixed.One, GD_Fixed.Zero, GD_Fixed.Zero);
   begin
      return Rotate(World_Right, F.Orientation);
   end Right;

   -------------------------------------------------------------------------
   -- Space Conversion
   -------------------------------------------------------------------------
   function To_World_Point (F : Frame; Local_P : Multivector) return Multivector is
      Rotated : Multivector;
   begin
      -- P_world = (R * P_local * ~R) + Origin
      Rotated := Rotate(Local_P, F.Orientation);
      return Add(Rotated, F.Origin);
   end To_World_Point;

   function To_Local_Point (F : Frame; World_P : Multivector) return Multivector is
      Diff    : Multivector;
      Inv_Rot : Multivector;
   begin
      -- P_local = ~R * (P_world - Origin) * R
      -- We use Sub from Geo_Algebra here (Vector - Vector)
      Diff    := Sub(World_P, F.Origin);
      Inv_Rot := Reverse_MV(F.Orientation);
      return Rotate(Diff, Inv_Rot);
   end To_Local_Point;

   function To_World_Dir (F : Frame; Local_D : Multivector) return Multivector is
   begin
      return Rotate(Local_D, F.Orientation);
   end To_World_Dir;

   function To_Local_Dir (F : Frame; World_D : Multivector) return Multivector is
      Inv_Rot : Multivector;
   begin
      Inv_Rot := Reverse_MV(F.Orientation);
      return Rotate(World_D, Inv_Rot);
   end To_Local_Dir;

   -------------------------------------------------------------------------
   -- Interpolation
   -------------------------------------------------------------------------
   function Lerp (A, B : Frame; T : Fix16) return Frame is
      Result : Frame;
      One_Minus_T : Fix16;
   begin
      -- [FIX] Use standard subtraction operator for Scalars (Fix16)
      -- 'Sub' is only for Multivectors.
      One_Minus_T := GD_Fixed."-"(GD_Fixed.One, T);

      -- 1. Linear Interp of Origin
      Result.Origin := Add(
         Scale(A.Origin, One_Minus_T),
         Scale(B.Origin, T)
      );

      -- 2. NLERP of Orientation (Linear Blend + Normalize)
      -- Note: In a full engine, we'd Normalize() the result here.
      Result.Orientation := Add(
         Scale(A.Orientation, One_Minus_T),
         Scale(B.Orientation, T)
      );
      
      return Result;
   end Lerp;

end Geo_Frame;