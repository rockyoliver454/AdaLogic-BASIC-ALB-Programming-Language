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

with Interfaces.C;  use Interfaces.C;
with Raylib;        use Raylib;
with GD_Fixed;      use GD_Fixed;
with Geo_Algebra;   use Geo_Algebra;
with Geo_Frame;     use Geo_Frame;
with Geo_Transform; use Geo_Transform;

package body Geo_Transform is

   -------------------------------------------------------------------------
   -- Composition
   -------------------------------------------------------------------------
   function Compose (Parent : Frame; Child : Frame) return Frame is
      Result : Frame;
   begin
      -- Rot = Parent.Rot * Child.Rot
      Result.Orientation := Mul(Parent.Orientation, Child.Orientation);

      -- Pos = Parent.Pos + (Parent.Rot * Child.Pos * ~Parent.Rot)
      Result.Origin := Add(
         Parent.Origin,
         Rotate(Child.Origin, Parent.Orientation)
      );

      return Result;
   end Compose;

   function Relative_Transform (From, To : Frame) return Frame is
      Result   : Frame;
      Inv_From : Multivector;
   begin
      Inv_From := Reverse_MV(From.Orientation);

      -- Delta Rot = ~From * To
      Result.Orientation := Mul(Inv_From, To.Orientation);

      -- Delta Pos = ~From * (To.Pos - From.Pos)
      Result.Origin := Rotate(
         Sub(To.Origin, From.Origin),
         Inv_From
      );

      return Result;
   end Relative_Transform;

   -------------------------------------------------------------------------
   -- Inversion
   -------------------------------------------------------------------------
   function Inverse (F : Frame) return Frame is
      Result  : Frame;
      Inv_Rot : Multivector;
   begin
      Inv_Rot := Reverse_MV(F.Orientation);
      Result.Orientation := Inv_Rot;
      
      -- Pos = -(Inv_Rot * Original_Pos)
      -- Rotate returns a vector. We scale by -1.
      Result.Origin := Scale(
         Rotate(F.Origin, Inv_Rot),
         From_Int(-1)
      );

      return Result;
   end Inverse;

   -------------------------------------------------------------------------
   -- Camera Helpers
   -------------------------------------------------------------------------
   -- [TITANIUM FIX] Renamed 'Up_Ref' to 'Up' to match .ads declaration
   function Look_At (Eye, Target, Up : Multivector) return Frame is
      Result : Frame;
   begin
      -- Placeholder: Identity
      -- (Real implementation requires cross product logic not yet in Geo_Algebra)
      Result := Geo_Frame.Identity;
      Result.Origin := Eye;
      return Result; 
   end Look_At;

   -------------------------------------------------------------------------
   -- Matrix Generation
   -------------------------------------------------------------------------
   function To_Matrix (F : Frame; Scale_Vec : Multivector) return Mat4 is
      M : Mat4;
      X, Y, Z : Multivector;
      -- Qualified local constants
      Z_Zero : constant Fix16 := GD_Fixed.Zero;
      Z_One  : constant Fix16 := GD_Fixed.One;
   begin
      -- Get Basis vectors: Rotate(Basis, Rotor)
      X := Rotate(Vector(Z_One, Z_Zero, Z_Zero), F.Orientation);
      Y := Rotate(Vector(Z_Zero, Z_One, Z_Zero), F.Orientation);
      Z := Rotate(Vector(Z_Zero, Z_Zero, Z_One), F.Orientation);

      -- Apply Scale
      X := Scale(X, Scale_Vec.E1);
      Y := Scale(Y, Scale_Vec.E2);
      Z := Scale(Z, Scale_Vec.E3);

      -- Fill Matrix (Column Major)
      M(1, 1) := To_Float(X.E1); M(2, 1) := To_Float(X.E2); M(3, 1) := To_Float(X.E3); M(4, 1) := 0.0;
      M(1, 2) := To_Float(Y.E1); M(2, 2) := To_Float(Y.E2); M(3, 2) := To_Float(Y.E3); M(4, 2) := 0.0;
      M(1, 3) := To_Float(Z.E1); M(2, 3) := To_Float(Z.E2); M(3, 3) := To_Float(Z.E3); M(4, 3) := 0.0;
      
      M(1, 4) := To_Float(F.Origin.E1);
      M(2, 4) := To_Float(F.Origin.E2);
      M(3, 4) := To_Float(F.Origin.E3);
      M(4, 4) := 1.0;

      return M;
   end To_Matrix;

end Geo_Transform;