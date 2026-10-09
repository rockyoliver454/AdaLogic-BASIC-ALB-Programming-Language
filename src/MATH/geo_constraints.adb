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

package body Geo_Constraints is

   function Solve_Distance (Pos_A, Pos_B : Vec2; 
                            Inv_Mass_A, Inv_Mass_B : Fix16; 
                            Target_Dist : Fix16) return Constraint_Result is
      Diff    : Vec2 := Sub(Pos_A, Pos_B); 
      Len     : Fix16 := Length(Diff);
      Inv_W   : Fix16 := Add_Sat(Inv_Mass_A, Inv_Mass_B);
      Err     : Fix16;
      Scale_Factor : Fix16;
      Res     : Constraint_Result;
      Dir     : Vec2;
   begin
      -- [TITANIUM FIX] Explicit GD_Fixed.Epsilon
      if Inv_W <= GD_Fixed.Epsilon then 
         return (Geo_Vec2.Zero, Geo_Vec2.Zero); 
      end if;

      if Len <= GD_Fixed.Epsilon then
         Dir := Geo_Vec2.Unit_X;
         Len := GD_Fixed.Epsilon; 
      else
         Dir := Normalize(Diff);
      end if;

      Err := Sub_Sat(Len, Target_Dist);
      Scale_Factor := Div_Sat(Err, Inv_W);
      
      -- [TITANIUM FIX] Use scalar negation '-' instead of vector Negate()
      Res.Correction_A := Scale(Dir, -Mul_Sat(Inv_Mass_A, Scale_Factor));
      Res.Correction_B := Scale(Dir, Mul_Sat(Inv_Mass_B, Scale_Factor));
      
      return Res;
   end Solve_Distance;

   function Project_To_Circle (Pos, Anchor : Vec2; Radius : Fix16) return Vec2 is
      Diff : Vec2 := Sub(Pos, Anchor);
      Dir  : Vec2 := Normalize(Diff);
   begin
      return Add(Anchor, Scale(Dir, Radius));
   end Project_To_Circle;

   function Solve_Penetration (Pos_A, Pos_B : Vec2;
                               Inv_Mass_A, Inv_Mass_B : Fix16;
                               Normal : Vec2;
                               Depth  : Fix16) return Constraint_Result is
      Inv_W : Fix16 := Add_Sat(Inv_Mass_A, Inv_Mass_B);
      Scale_Factor : Fix16;
      Res : Constraint_Result;
   begin
      -- [TITANIUM FIX] Explicit GD_Fixed.Epsilon
      if Inv_W <= GD_Fixed.Epsilon or else Depth <= GD_Fixed.Epsilon then
         return (Geo_Vec2.Zero, Geo_Vec2.Zero);
      end if;
      
      Scale_Factor := Div_Sat(Depth, Inv_W);
      
      -- [TITANIUM FIX] Use scalar negation '-'
      Res.Correction_A := Scale(Normal, Mul_Sat(Inv_Mass_A, Scale_Factor));
      Res.Correction_B := Scale(Normal, -Mul_Sat(Inv_Mass_B, Scale_Factor));
      
      return Res;
   end Solve_Penetration;

end Geo_Constraints;