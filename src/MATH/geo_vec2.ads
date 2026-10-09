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

package Geo_Vec2 is
   pragma Pure;

   type Vec2 is record
      X, Y : Fix16;
   end record;

   -------------------------------------------------------------------------
   -- Constructors & Constants
   -------------------------------------------------------------------------
   function Create (X, Y : Fix16) return Vec2;
   function Zero return Vec2;
   function One  return Vec2; -- (1, 1)
   function Unit_X return Vec2;
   function Unit_Y return Vec2;

   -------------------------------------------------------------------------
   -- Basic Arithmetic
   -------------------------------------------------------------------------
   function Add (A, B : Vec2) return Vec2;
   function Sub (A, B : Vec2) return Vec2;
   function Scale (V : Vec2; S : Fix16) return Vec2;
   function Negate (V : Vec2) return Vec2;

   -------------------------------------------------------------------------
   -- Products
   -------------------------------------------------------------------------
   -- Standard Dot Product: X1*X2 + Y1*Y2
   function Dot (A, B : Vec2) return Fix16;

   -- Perpendicular Dot (2D Cross): X1*Y2 - Y1*X2
   -- Returns magnitude of orthogonal area. Useful for winding checks.
   function Perp_Dot (A, B : Vec2) return Fix16;

   -------------------------------------------------------------------------
   -- Metric Operations
   -------------------------------------------------------------------------
   function Length_Sq (V : Vec2) return Fix16;
   function Length (V : Vec2) return Fix16;
   function Distance_Sq (A, B : Vec2) return Fix16;
   function Distance (A, B : Vec2) return Fix16;

   -- Returns a vector with length 1.0 in the same direction.
   -- Returns Zero if input length is effectively zero.
   function Normalize (V : Vec2) return Vec2;

   -------------------------------------------------------------------------
   -- Geometric Verbs
   -------------------------------------------------------------------------
   -- Reflects vector V off surface normal N (Assumes N is normalized)
   -- Formula: V - 2*(V.N)*N
   function Reflect (V, N : Vec2) return Vec2;

   -- Projects V onto N (Assumes N is normalized)
   function Project (V, N : Vec2) return Vec2;

   -- Returns positive if C is to the "left" of line AB, negative if "right".
   -- Effectively the signed double-area of triangle ABC.
   function Oriented_Area (A, B, C : Vec2) return Fix16;

end Geo_Vec2;