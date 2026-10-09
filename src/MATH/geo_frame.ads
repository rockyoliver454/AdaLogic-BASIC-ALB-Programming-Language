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

with GD_Fixed;    use GD_Fixed;
with Geo_Algebra; use Geo_Algebra;

package Geo_Frame is
   pragma Pure;

   -- A Frame represents a rigid body's position and orientation.
   -- We use Multivectors for both (Origin is a Vector, Orientation is a Rotor).
   type Frame is record
      Origin      : Multivector; -- A vector (E1, E2, E3)
      Orientation : Multivector; -- A rotor (Scalar + Bivectors)
   end record;

   -- Identity: Origin at 0, Orientation is Scalar 1 (No rotation)
   function Identity return Frame;

   -------------------------------------------------------------------------
   -- Basis Vector Extraction
   -------------------------------------------------------------------------
   -- "Which way is this object facing?"
   function Forward (F : Frame) return Multivector; -- Local Z+ (or -Z)
   function Up      (F : Frame) return Multivector; -- Local Y+
   function Right   (F : Frame) return Multivector; -- Local X+

   -------------------------------------------------------------------------
   -- Space Conversion (Point)
   -------------------------------------------------------------------------
   -- Converts a point from Local Space -> World Space
   function To_World_Point (F : Frame; Local_P : Multivector) return Multivector;

   -- Converts a point from World Space -> Local Space
   function To_Local_Point (F : Frame; World_P : Multivector) return Multivector;

   -------------------------------------------------------------------------
   -- Space Conversion (Direction)
   -------------------------------------------------------------------------
   -- Converts a direction (ignores translation) Local -> World
   function To_World_Dir (F : Frame; Local_D : Multivector) return Multivector;

   -- Converts a direction (ignores translation) World -> Local
   function To_Local_Dir (F : Frame; World_D : Multivector) return Multivector;

   -------------------------------------------------------------------------
   -- Interpolation
   -------------------------------------------------------------------------
   -- Linear interpolation for position, geometric/rotor blend for orientation
   -- Note: True SLERP for rotors requires logs/exps or trig. 
   -- For this engine, we will use N-LERP (Normalized Linear Interpolation) which is cheaper and sufficient.
   function Lerp (A, B : Frame; T : Fix16) return Frame;

end Geo_Frame;