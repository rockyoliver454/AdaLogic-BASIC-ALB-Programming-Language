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

package EO_PGA2D is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Multivector (Cl2,0,1)
   -- Basis: 1, e0, e1, e2, e01, e20, e12, e012
   -- e0 is the Ideal (Projective) axis (e0^2 = 0)
   -- e1, e2 are Euclidean axes (e1^2 = 1, e2^2 = 1)
   -------------------------------------------------------------------------
   type Multivector is record
      -- Grade 0: Scalar
      S : Fix16;
      
      -- Grade 1: Vectors (Lines)
      E0 : Fix16; -- Ideal Line (Line at infinity)
      E1 : Fix16; -- X Axis Line
      E2 : Fix16; -- Y Axis Line
      
      -- Grade 2: Bivectors (Points)
      E01 : Fix16; -- Ideal Point Y
      E20 : Fix16; -- Ideal Point X
      E12 : Fix16; -- The Origin
      
      -- Grade 3: Trivector (Pseudoscalar)
      I : Fix16;
   end record;

   -------------------------------------------------------------------------
   -- Constructors
   -------------------------------------------------------------------------
   function Zero return Multivector;
   
   -- Creates a normalized Euclidean point (e12 = 1)
   function Point (X, Y : Fix16) return Multivector;
   
   -- Creates a normalized line: ax + by + c = 0
   -- Normal (a,b) should be length 1 for correct distance measures.
   function Line (A, B, C : Fix16) return Multivector;
   
   -- Creates an ideal line (direction)
   function Ideal_Line (VX, VY : Fix16) return Multivector;

   -------------------------------------------------------------------------
   -- Motors (Rotation + Translation)
   -------------------------------------------------------------------------
   -- Creates a motor that rotates by Angle and translates by (TX, TY)
   function Motor (Angle : Fix16; TX, TY : Fix16) return Multivector;
   
   -- Interpolates between two motors (slerp-like)
   function Motor_Blend (A, B : Multivector; T : Fix16) return Multivector;

   -------------------------------------------------------------------------
   -- Basic Algebra
   -------------------------------------------------------------------------
   function Add (A, B : Multivector) return Multivector;
   function Sub (A, B : Multivector) return Multivector;
   function Mul (A, B : Multivector) return Multivector; -- Geometric Product
   function Reverse_MV (A : Multivector) return Multivector; -- Reversion (~)
   function Dual (A : Multivector) return Multivector; -- Poincare Dual (Map to Euclidean)

   -------------------------------------------------------------------------
   -- Geometric Operations
   -------------------------------------------------------------------------
   -- "Meet" (Intersection): Wedge Product (^)
   -- Intersection of two Lines -> Point
   function Meet (A, B : Multivector) return Multivector;
   
   -- "Join" (Connection): Regressive Product (v)
   -- Connection of two Points -> Line
   function Join (A, B : Multivector) return Multivector;

   -- Applies Motor M to geometry G (Sandwich: M * G * ~M)
   function Transform (G, M : Multivector) return Multivector;
   
   -- Normalizes a Multivector (mostly for Motors and Lines)
   function Normalize (A : Multivector) return Multivector;

end EO_PGA2D;