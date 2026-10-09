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

with GD_CORDIC;
with Fixed_Sqrt; use Fixed_Sqrt;

package body Geo_Kinematics is

   -------------------------------------------------------------------------
   -- Forward Kinematics
   -------------------------------------------------------------------------
   function FK_Chain (Parent_Motor, Local_Motor : Multivector) return Multivector is
   begin
      return EO_PGA2D.Mul(Parent_Motor, Local_Motor);
   end FK_Chain;

   function Get_Position (M : Multivector) return Vec2 is
      P_Origin : Multivector := EO_PGA2D.Point(GD_Fixed.Zero, GD_Fixed.Zero);
      P_Trans  : Multivector := EO_PGA2D.Transform(P_Origin, M);
      P_Norm   : Multivector := EO_PGA2D.Normalize(P_Trans);
      
      W : Fix16 := P_Norm.E12;
      Inv_W : Fix16;
   begin
      -- [TITANIUM FIX] Explicit GD_Fixed.Epsilon
      if Abs_Sat(W) <= GD_Fixed.Epsilon then return Geo_Vec2.Zero; end if;
      
      -- [TITANIUM FIX] Explicit GD_Fixed.One
      Inv_W := Div_Sat(GD_Fixed.One, W);
      return Create(Mul_Sat(P_Norm.E20, Inv_W), Mul_Sat(P_Norm.E01, Inv_W));
   end Get_Position;

   function Get_Rotation (M : Multivector) return Fix16 is
   begin
      return Mul_Sat(From_Int(2), GD_CORDIC.ArcTan2(M.E12, M.S));
   end Get_Rotation;

   -------------------------------------------------------------------------
   -- IK Helpers
   -------------------------------------------------------------------------
   function Solve_CCD_Angle (Joint_Pos, Effector_Pos, Target_Pos : Vec2) return Fix16 is
      To_Effector : Vec2 := Sub(Effector_Pos, Joint_Pos);
      To_Target   : Vec2 := Sub(Target_Pos, Joint_Pos);
      
      Dir_E : Vec2 := Normalize(To_Effector);
      Dir_T : Vec2 := Normalize(To_Target);
      
      Dot_Val  : Fix16 := Dot(Dir_E, Dir_T);
      Perp_Val : Fix16 := Perp_Dot(Dir_E, Dir_T);
   begin
      return GD_CORDIC.ArcTan2(Perp_Val, Dot_Val);
   end Solve_CCD_Angle;

   function Solve_Two_Bone (L1, L2 : Fix16; Target : Vec2; Bend_Right : Boolean) return IK_Result is
      Dist_Sq : Fix16 := Length_Sq(Target);
      Dist    : Fix16;
      Cos_2   : Fix16;
      Theta_2 : Fix16;
      Cos_1_Num : Fix16;
      Theta_1   : Fix16;
      Base_Angle : Fix16;
      Alpha      : Fix16;
      L1_Sq : Fix16 := Mul_Sat(L1, L1);
      L2_Sq : Fix16 := Mul_Sat(L2, L2);
      Res : IK_Result;
   begin
      Res.Valid := False;
      Res.Theta_1 := GD_Fixed.Zero;
      Res.Theta_2 := GD_Fixed.Zero;

      Dist := Sqrt(Dist_Sq);
      if Dist > Add_Sat(L1, L2) then
         Res.Theta_1 := GD_CORDIC.ArcTan2(Target.Y, Target.X);
         Res.Theta_2 := GD_Fixed.Zero;
         return Res;
      end if;
      
      Cos_2 := Div_Sat(Sub_Sat(Sub_Sat(Dist_Sq, L1_Sq), L2_Sq), 
                       Mul_Sat(From_Int(2), Mul_Sat(L1, L2)));
                       
      -- [TITANIUM FIX] Explicit GD_Fixed.One
      if Cos_2 > GD_Fixed.One then Cos_2 := GD_Fixed.One; end if;
      if Cos_2 < From_Int(-1) then Cos_2 := From_Int(-1); end if;
      
      Theta_2 := GD_CORDIC.ArcCos(Cos_2);
      
      if Bend_Right then
         -- [TITANIUM FIX] Scalar negation
         Theta_2 := -Theta_2; 
      end if;
      
      if Dist <= GD_Fixed.Epsilon then 
         Res.Valid := True; 
         return Res;
      end if;
      
      Cos_1_Num := Div_Sat(Sub_Sat(Add_Sat(L1_Sq, Dist_Sq), L2_Sq),
                           Mul_Sat(From_Int(2), Mul_Sat(L1, Dist)));
                           
      if Cos_1_Num > GD_Fixed.One then Cos_1_Num := GD_Fixed.One; end if;
      if Cos_1_Num < From_Int(-1) then Cos_1_Num := From_Int(-1); end if;
      
      Alpha := GD_CORDIC.ArcCos(Cos_1_Num);
      Base_Angle := GD_CORDIC.ArcTan2(Target.Y, Target.X);
      
      if Bend_Right then
         Theta_1 := Add_Sat(Base_Angle, Alpha);
      else
         Theta_1 := Sub_Sat(Base_Angle, Alpha);
      end if;
      
      Res.Theta_1 := Theta_1;
      Res.Theta_2 := Theta_2;
      Res.Valid   := True;
      
      return Res;
   end Solve_Two_Bone;

end Geo_Kinematics;