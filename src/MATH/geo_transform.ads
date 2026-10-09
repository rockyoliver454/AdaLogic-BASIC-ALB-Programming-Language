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
with Geo_Frame;   use Geo_Frame;
with Raylib;      use Raylib; -- For Mat4

package Geo_Transform is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Composition
   -------------------------------------------------------------------------
   -- World = Parent * Child
   function Compose (Parent : Frame; Child : Frame) return Frame;

   -- B = A * Result
   function Relative_Transform (From, To : Frame) return Frame;

   -------------------------------------------------------------------------
   -- Inversion
   -------------------------------------------------------------------------
   -- View Matrix Logic
   function Inverse (F : Frame) return Frame;

   -------------------------------------------------------------------------
   -- Camera Helpers
   -------------------------------------------------------------------------
   function Look_At (Eye, Target, Up : Multivector) return Frame;

   -------------------------------------------------------------------------
   -- Matrix Generation
   -------------------------------------------------------------------------
   -- Converts Frame to Raylib Mat4
   -- Scale is a Vector (Multivector with E1, E2, E3 set)
   function To_Matrix (F : Frame; Scale_Vec : Multivector) return Mat4;

end Geo_Transform;