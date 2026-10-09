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

package Geo_Algebra is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Multivector (Cl3,0)
   -- Represents Scalar + Vector + Bivector + Trivector
   -------------------------------------------------------------------------
   type Multivector is record
      S            : Fix16; -- Scalar
      E1, E2, E3   : Fix16; -- Vector
      E12, E23, E31: Fix16; -- Bivector
      I            : Fix16; -- Trivector (Pseudo-Scalar)
   end record;

   -------------------------------------------------------------------------
   -- Constructors
   -------------------------------------------------------------------------
   function Zero return Multivector;
   function Scalar (Val : Fix16) return Multivector;
   function Vector (X, Y, Z : Fix16) return Multivector;
   function Bivector (XY, YZ, ZX : Fix16) return Multivector;

   -------------------------------------------------------------------------
   -- Axioms
   -------------------------------------------------------------------------
   function Add (A, B : Multivector) return Multivector;
   function Sub (A, B : Multivector) return Multivector;
   function Scale (A : Multivector; S : Fix16) return Multivector;

   -------------------------------------------------------------------------
   -- Products
   -------------------------------------------------------------------------
   function Mul (A, B : Multivector) return Multivector; -- Geometric Product
   function Wedge (A, B : Multivector) return Multivector; -- Outer Product
   function Dot (A, B : Multivector) return Multivector; -- Inner Product

   -------------------------------------------------------------------------
   -- Unary Operators
   -------------------------------------------------------------------------
   function Reverse_MV (A : Multivector) return Multivector;
   function Magnitude_Sq (A : Multivector) return Fix16;
   function Inverse (A : Multivector) return Multivector;

   -------------------------------------------------------------------------
   -- Verbs (Applications)
   -------------------------------------------------------------------------
   -- Create a Rotor (Quaternion-like) from Angle and Axis
   function Rotor (Angle : Fix16; X, Y, Z : Fix16) return Multivector;

   -- Rotate Vector V by Rotor R
   function Rotate (V, R : Multivector) return Multivector;

end Geo_Algebra;