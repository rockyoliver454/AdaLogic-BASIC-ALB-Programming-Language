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

package Collision is
   pragma Pure;

   -------------------------------------------------------------------------
   -- Data Structures
   -------------------------------------------------------------------------
   type AABB is record
      X, Y          : Fix16;
      Half_Width    : Fix16; -- Stored as half-extents for center-based math
      Half_Height   : Fix16;
   end record;

   type Circle is record
      X, Y      : Fix16;
      Radius    : Fix16;
      Radius_Sq : Fix16; -- Pre-calculated for fast checks
   end record;

   -------------------------------------------------------------------------
   -- Construction
   -------------------------------------------------------------------------
   -- Creates an AABB. W and H are the FULL width and height.
   procedure Make_AABB (Box : out AABB; X, Y, W, H : Fix16);

   -- Creates a Circle and pre-calculates Radius squared.
   procedure Make_Circle (Circ : out Circle; X, Y, R : Fix16);

   -------------------------------------------------------------------------
   -- Intersection Tests
   -------------------------------------------------------------------------
   function Check_AABB_vs_AABB (A, B : AABB) return Boolean;
   function Check_Circle_vs_Circle (A, B : Circle) return Boolean;
   function Check_AABB_vs_Circle (Box : AABB; Circ : Circle) return Boolean;

   -------------------------------------------------------------------------
   -- Utility
   -------------------------------------------------------------------------
   function Point_In_AABB (Box : AABB; P_X, P_Y : Fix16) return Boolean;

end Collision;