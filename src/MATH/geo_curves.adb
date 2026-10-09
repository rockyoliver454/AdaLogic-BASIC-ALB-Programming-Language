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

with Fixed_Sqrt; use Fixed_Sqrt;
with GD_Fixed;   use GD_Fixed;

package body Geo_Curves is

   -------------------------------------------------------------------------
   -- Hermite Implementation
   -------------------------------------------------------------------------
   function Hermite_Eval (P0, T0, P1, T1 : Vec2; T : Fix16) return Vec2 is
      T2, T3 : Fix16;
      H1, H2, H3, H4 : Fix16;
      Result : Vec2;
   begin
      T2 := Mul_Sat(T, T);
      T3 := Mul_Sat(T2, T);

      -- H1 = 2t^3 - 3t^2 + 1
      H1 := Add_Sat(Sub_Sat(Mul_Sat(From_Int(2), T3), Mul_Sat(From_Int(3), T2)), GD_Fixed.One);
      
      -- H2 = t^3 - 2t^2 + t
      H2 := Add_Sat(Sub_Sat(T3, Mul_Sat(From_Int(2), T2)), T);
      
      -- H3 = -2t^3 + 3t^2
      H3 := Add_Sat(Sub_Sat(GD_Fixed.Zero, Mul_Sat(From_Int(2), T3)), Mul_Sat(From_Int(3), T2));
      
      -- H4 = t^3 - t^2
      H4 := Sub_Sat(T3, T2);

      -- R = H1*P0 + H2*T0 + H3*P1 + H4*T1
      Result := Scale(P0, H1);
      Result := Add(Result, Scale(T0, H2));
      Result := Add(Result, Scale(P1, H3));
      Result := Add(Result, Scale(T1, H4));
      
      return Result;
   end Hermite_Eval;

   -------------------------------------------------------------------------
   -- Catmull-Rom Implementation
   -------------------------------------------------------------------------
   function Catmull_Eval (P0, P1, P2, P3 : Vec2; T : Fix16) return Vec2 is
      T2, T3 : Fix16;
      Term_A, Term_B, Term_C, Term_D, Sum : Vec2;
   begin
      T2 := Mul_Sat(T, T);
      T3 := Mul_Sat(T2, T);
      
      -- Calculate terms inside the body
      Term_A := Scale(P1, From_Int(2));
      
      Term_B := Add(Negate(P0), P2);
      
      Term_C := Add(Scale(P0, From_Int(2)), Negate(Scale(P1, From_Int(5))));
      Term_C := Add(Term_C, Scale(P2, From_Int(4)));
      Term_C := Add(Term_C, Negate(P3));
      
      Term_D := Add(Negate(P0), Scale(P1, From_Int(3)));
      Term_D := Add(Term_D, Negate(Scale(P2, From_Int(3))));
      Term_D := Add(Term_D, P3);
      
      Sum := Term_A;
      Sum := Add(Sum, Scale(Term_B, T));
      Sum := Add(Sum, Scale(Term_C, T2));
      Sum := Add(Sum, Scale(Term_D, T3));
      
      return Scale(Sum, Half);
   end Catmull_Eval;

   -------------------------------------------------------------------------
   -- Derivatives
   -------------------------------------------------------------------------
   function Catmull_Velocity (P0, P1, P2, P3 : Vec2; T : Fix16) return Vec2 is
      T2 : Fix16;
      Term_B, Term_C, Term_D, Sum : Vec2;
   begin
      T2 := Mul_Sat(T, T);
      
      Term_B := Add(Negate(P0), P2);
      
      Term_C := Add(Scale(P0, From_Int(2)), Negate(Scale(P1, From_Int(5))));
      Term_C := Add(Term_C, Scale(P2, From_Int(4)));
      Term_C := Add(Term_C, Negate(P3));
      
      Term_D := Add(Negate(P0), Scale(P1, From_Int(3)));
      Term_D := Add(Term_D, Negate(Scale(P2, From_Int(3))));
      Term_D := Add(Term_D, P3);
      
      Sum := Term_B;
      Sum := Add(Sum, Scale(Term_C, Mul_Sat(From_Int(2), T)));
      Sum := Add(Sum, Scale(Term_D, Mul_Sat(From_Int(3), T2)));
      
      return Scale(Sum, Half);
   end Catmull_Velocity;

   function Catmull_Acceleration (P0, P1, P2, P3 : Vec2; T : Fix16) return Vec2 is
      Term_C, Term_D, Sum : Vec2;
   begin
      Term_C := Add(Scale(P0, From_Int(2)), Negate(Scale(P1, From_Int(5))));
      Term_C := Add(Term_C, Scale(P2, From_Int(4)));
      Term_C := Add(Term_C, Negate(P3));
      
      Term_D := Add(Negate(P0), Scale(P1, From_Int(3)));
      Term_D := Add(Term_D, Negate(Scale(P2, From_Int(3))));
      Term_D := Add(Term_D, P3);
      
      Sum := Term_C;
      Sum := Add(Sum, Scale(Term_D, Mul_Sat(From_Int(3), T)));
      
      return Sum;
   end Catmull_Acceleration;

   -------------------------------------------------------------------------
   -- Curvature
   -------------------------------------------------------------------------
   function Catmull_Curvature (P0, P1, P2, P3 : Vec2; T : Fix16) return Fix16 is
      Vel   : Vec2 := Catmull_Velocity(P0, P1, P2, P3, T);
      Accel : Vec2 := Catmull_Acceleration(P0, P1, P2, P3, T);
      Num   : Fix16 := Perp_Dot(Vel, Accel);
      Speed_Sq : Fix16 := Length_Sq(Vel);
      Speed    : Fix16;
      Denom    : Fix16;
   begin
      if Speed_Sq <= Epsilon then
         return GD_Fixed.Zero; 
      end if;
      
      Speed := Sqrt(Speed_Sq);
      Denom := Mul_Sat(Speed_Sq, Speed);
      
      if Denom <= Epsilon then
         return Max_Val; 
      end if;
      
      return Div_Sat(Num, Denom);
   end Catmull_Curvature;

   -------------------------------------------------------------------------
   -- Arc-Length
   -------------------------------------------------------------------------
   function Catmull_Arc_Length (P0, P1, P2, P3 : Vec2; Segments : Integer := 10) return Fix16 is
      Total_Dist : Fix16 := GD_Fixed.Zero;
      Prev_Pos   : Vec2 := Catmull_Eval(P0, P1, P2, P3, GD_Fixed.Zero);
      Curr_Pos   : Vec2;
      Step       : Fix16;
      Current_T  : Fix16;
   begin
      if Segments < 1 then return GD_Fixed.Zero; end if;
      
      Step := Div_Sat(GD_Fixed.One, From_Int(Segments));
      Current_T := Step;
      
      for I in 1 .. Segments loop
         Curr_Pos := Catmull_Eval(P0, P1, P2, P3, Current_T);
         Total_Dist := Add_Sat(Total_Dist, Distance(Prev_Pos, Curr_Pos));
         Prev_Pos := Curr_Pos;
         Current_T := Add_Sat(Current_T, Step);
      end loop;
      
      return Total_Dist;
   end Catmull_Arc_Length;

   function Catmull_Solve_T (P0, P1, P2, P3 : Vec2; Target_Dist : Fix16; Tolerance : Fix16) return Fix16 is
      Segments : constant Integer := 20; 
      Step     : constant Fix16 := Div_Sat(GD_Fixed.One, From_Int(Segments));
      
      Prev_Pos : Vec2 := P1;
      Curr_Pos : Vec2;
      Accum    : Fix16 := GD_Fixed.Zero;
      Seg_Dist : Fix16;
      T_Start  : Fix16 := GD_Fixed.Zero;
      T_End    : Fix16;
      Ratio    : Fix16;
   begin
      if Target_Dist <= GD_Fixed.Zero then return GD_Fixed.Zero; end if;

      for I in 1 .. Segments loop
         T_End := Mul_Sat(From_Int(I), Step);
         Curr_Pos := Catmull_Eval(P0, P1, P2, P3, T_End);
         Seg_Dist := Distance(Prev_Pos, Curr_Pos);
         
         if Accum + Seg_Dist >= Target_Dist then
            Ratio := Div_Sat(Sub_Sat(Target_Dist, Accum), Seg_Dist);
            return Add_Sat(T_Start, Mul_Sat(Ratio, Step));
         end if;
         
         Accum := Add_Sat(Accum, Seg_Dist);
         Prev_Pos := Curr_Pos;
         T_Start := T_End;
      end loop;
      
      return GD_Fixed.One; 
   end Catmull_Solve_T;

end Geo_Curves;