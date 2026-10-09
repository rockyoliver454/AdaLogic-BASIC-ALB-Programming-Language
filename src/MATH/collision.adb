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

package body Collision is

   -------------------------------------------------------------------------
   -- Internal Helpers
   -------------------------------------------------------------------------
   function Local_Clamp (Val, Lo, Hi : Fix16) return Fix16 is
   begin
      if Val < Lo then return Lo; end if;
      if Val > Hi then return Hi; end if;
      return Val;
   end Local_Clamp;

   function Local_Abs (Val : Fix16) return Fix16 is
   begin
      if Val < Zero then return -Val; end if;
      return Val;
   end Local_Abs;

   -------------------------------------------------------------------------
   -- Construction
   -------------------------------------------------------------------------
   procedure Make_AABB (Box : out AABB; X, Y, W, H : Fix16) is
   begin
      -- Rule: Assert inputs are sane
      pragma Assert (W >= Zero);
      pragma Assert (H >= Zero);

      Box.X := X;
      Box.Y := Y;
      -- Logic: Store half-extents (W / 2)
      Box.Half_Width  := Mul_Sat(W, Half);
      Box.Half_Height := Mul_Sat(H, Half);
   end Make_AABB;

   procedure Make_Circle (Circ : out Circle; X, Y, R : Fix16) is
   begin
      pragma Assert (R >= Zero);

      Circ.X := X;
      Circ.Y := Y;
      Circ.Radius := R;
      Circ.Radius_Sq := Mul_Sat(R, R);
      
      -- Rule: Verify pre-calc integrity
      pragma Assert (Circ.Radius_Sq >= Zero);
   end Make_Circle;

   -------------------------------------------------------------------------
   -- AABB vs AABB
   -------------------------------------------------------------------------
   function Check_AABB_vs_AABB (A, B : AABB) return Boolean is
      DX, DY     : Fix16;
      Sum_W, Sum_H : Fix16;
   begin
      -- Center-to-Center difference
      DX := Local_Abs(Sub_Sat(A.X, B.X));
      DY := Local_Abs(Sub_Sat(A.Y, B.Y));

      -- Sum of half-extents
      Sum_W := Add_Sat(A.Half_Width, B.Half_Width);
      Sum_H := Add_Sat(A.Half_Height, B.Half_Height);

      return (DX < Sum_W) and then (DY < Sum_H);
   end Check_AABB_vs_AABB;

   -------------------------------------------------------------------------
   -- Circle vs Circle
   -------------------------------------------------------------------------
   function Check_Circle_vs_Circle (A, B : Circle) return Boolean is
      DX, DY       : Fix16;
      Dist_Sq      : Fix16;
      Rad_Sum      : Fix16;
      Rad_Sum_Sq   : Fix16;
   begin
      DX := Sub_Sat(A.X, B.X);
      DY := Sub_Sat(A.Y, B.Y);

      -- Squared Distance Check (No Sqrt)
      Dist_Sq := Add_Sat(Mul_Sat(DX, DX), Mul_Sat(DY, DY));

      Rad_Sum    := Add_Sat(A.Radius, B.Radius);
      Rad_Sum_Sq := Mul_Sat(Rad_Sum, Rad_Sum);

      return Dist_Sq < Rad_Sum_Sq;
   end Check_Circle_vs_Circle;

   -------------------------------------------------------------------------
   -- AABB vs Circle
   -------------------------------------------------------------------------
   function Check_AABB_vs_Circle (Box : AABB; Circ : Circle) return Boolean is
      Min_X, Max_X : Fix16;
      Min_Y, Max_Y : Fix16;
      Closest_X    : Fix16;
      Closest_Y    : Fix16;
      DX, DY       : Fix16;
      Dist_Sq      : Fix16;
   begin
      -- 1. Find point on AABB closest to Circle center
      Min_X := Sub_Sat(Box.X, Box.Half_Width);
      Max_X := Add_Sat(Box.X, Box.Half_Width);
      Min_Y := Sub_Sat(Box.Y, Box.Half_Height);
      Max_Y := Add_Sat(Box.Y, Box.Half_Height);

      Closest_X := Local_Clamp(Circ.X, Min_X, Max_X);
      Closest_Y := Local_Clamp(Circ.Y, Min_Y, Max_Y);

      -- 2. Calculate squared distance from closest point to circle center
      DX := Sub_Sat(Circ.X, Closest_X);
      DY := Sub_Sat(Circ.Y, Closest_Y);
      
      Dist_Sq := Add_Sat(Mul_Sat(DX, DX), Mul_Sat(DY, DY));

      -- 3. Check against squared radius
      return Dist_Sq < Circ.Radius_Sq;
   end Check_AABB_vs_Circle;

   -------------------------------------------------------------------------
   -- Point in AABB
   -------------------------------------------------------------------------
   function Point_In_AABB (Box : AABB; P_X, P_Y : Fix16) return Boolean is
      DX, DY : Fix16;
   begin
      DX := Local_Abs(Sub_Sat(Box.X, P_X));
      DY := Local_Abs(Sub_Sat(Box.Y, P_Y));

      return (DX < Box.Half_Width) and then (DY < Box.Half_Height);
   end Point_In_AABB;

end Collision;