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

with Geo_Curves;

package body Geo_Splines is

   -------------------------------------------------------------------------
   -- Helpers
   -------------------------------------------------------------------------
   -- Safe array access with clamp/wrap logic
   function Get_Pt (S : Spline; Idx : Integer) return Vec2 is
      Safe_Idx : Integer := Idx;
   begin
      if S.Count = 0 then return Geo_Vec2.Zero; end if;

      if S.Closed then
         -- Wrap logic: 1..Count.
         -- Ada arrays are 1-based.
         -- Modulo arithmetic: (Idx - 1) mod Count + 1
         Safe_Idx := ((Idx - 1) mod S.Count) + 1;
      else
         -- Clamp logic
         if Safe_Idx < 1 then Safe_Idx := 1; end if;
         if Safe_Idx > S.Count then Safe_Idx := S.Count; end if;
      end if;
      return S.Points(Safe_Idx);
   end Get_Pt;

   -------------------------------------------------------------------------
   -- Management
   -------------------------------------------------------------------------
   procedure Clear (S : out Spline) is
   begin
      S.Count  := 0;
      S.Closed := False;
   end Clear;

   procedure Add_Point (S : in out Spline; P : Vec2) is
   begin
      if S.Count < MAX_POINTS then
         S.Count := S.Count + 1;
         S.Points(S.Count) := P;
      end if;
   end Add_Point;

   -------------------------------------------------------------------------
   -- Evaluation
   -------------------------------------------------------------------------
   function Eval (S : Spline; T : Fix16) return Vec2 is
      Seg_Count : Integer;
      Global_T  : Fix16 := T;
      Seg_T     : Fix16;
      Seg_Idx   : Integer;
      Scaled_T  : Fix16;
      
      P0, P1, P2, P3 : Vec2;
   begin
      if S.Count < 2 then 
         if S.Count = 1 then return S.Points(1); else return Geo_Vec2.Zero; end if;
      end if;

      -- Clamp T
      if Global_T < GD_Fixed.Zero then Global_T := GD_Fixed.Zero; end if;
      if Global_T > GD_Fixed.One  then Global_T := GD_Fixed.One;  end if;

      -- Determine segment count
      if S.Closed then
         Seg_Count := S.Count;
      else
         Seg_Count := S.Count - 1;
      end if;

      -- Map Global T to Segment Index
      -- Scaled = T * Segments
      Scaled_T := Mul_Sat(Global_T, From_Int(Seg_Count));
      
      -- Integer part is segment index (0-based offset from start)
      Seg_Idx := To_Int(Scaled_T); 
      
      -- Handle T=1.0 edge case (clamp to last segment)
      if Seg_Idx >= Seg_Count then
         Seg_Idx := Seg_Count - 1;
         Seg_T   := GD_Fixed.One;
      else
         -- Local t is the fractional part
         Seg_T := Sub_Sat(Scaled_T, From_Int(Seg_Idx));
      end if;

      -- Indices for P0..P3
      -- Current segment is between P(i) and P(i+1)
      -- Catmull needs P(i-1), P(i), P(i+1), P(i+2)
      -- Map 0-based Seg_Idx to 1-based array: Start is Seg_Idx + 1
      P0 := Get_Pt(S, Seg_Idx);     -- i - 1 + 1 = i
      P1 := Get_Pt(S, Seg_Idx + 1); -- i + 1
      P2 := Get_Pt(S, Seg_Idx + 2); -- i + 2
      P3 := Get_Pt(S, Seg_Idx + 3); -- i + 3

      return Geo_Curves.Catmull_Eval(P0, P1, P2, P3, Seg_T);
   end Eval;

   function Velocity (S : Spline; T : Fix16) return Vec2 is
      -- Similar logic to Eval, but calls Catmull_Velocity
      Seg_Count : Integer;
      Global_T  : Fix16 := T;
      Seg_T     : Fix16;
      Seg_Idx   : Integer;
      Scaled_T  : Fix16;
      P0, P1, P2, P3 : Vec2;
   begin
      if S.Count < 2 then return Geo_Vec2.Zero; end if;

      if Global_T < GD_Fixed.Zero then Global_T := GD_Fixed.Zero; end if;
      if Global_T > GD_Fixed.One  then Global_T := GD_Fixed.One;  end if;

      if S.Closed then Seg_Count := S.Count; else Seg_Count := S.Count - 1; end if;

      Scaled_T := Mul_Sat(Global_T, From_Int(Seg_Count));
      Seg_Idx  := To_Int(Scaled_T); 
      
      if Seg_Idx >= Seg_Count then
         Seg_Idx := Seg_Count - 1;
         Seg_T   := GD_Fixed.One;
      else
         Seg_T := Sub_Sat(Scaled_T, From_Int(Seg_Idx));
      end if;

      P0 := Get_Pt(S, Seg_Idx);
      P1 := Get_Pt(S, Seg_Idx + 1);
      P2 := Get_Pt(S, Seg_Idx + 2);
      P3 := Get_Pt(S, Seg_Idx + 3);

      return Geo_Curves.Catmull_Velocity(P0, P1, P2, P3, Seg_T);
   end Velocity;

   -------------------------------------------------------------------------
   -- Distance Traversal
   -------------------------------------------------------------------------
   function Length (S : Spline) return Fix16 is
      Total : Fix16 := GD_Fixed.Zero;
      Seg_Len : Fix16;
      Seg_Count : Integer;
      P0, P1, P2, P3 : Vec2;
   begin
      if S.Count < 2 then return GD_Fixed.Zero; end if;
      if S.Closed then Seg_Count := S.Count; else Seg_Count := S.Count - 1; end if;

      for I in 1 .. Seg_Count loop
         P0 := Get_Pt(S, I - 1);
         P1 := Get_Pt(S, I);
         P2 := Get_Pt(S, I + 1);
         P3 := Get_Pt(S, I + 2);
         Seg_Len := Geo_Curves.Catmull_Arc_Length(P0, P1, P2, P3, 5); -- 5 subdivisions
         Total := Add_Sat(Total, Seg_Len);
      end loop;
      return Total;
   end Length;

   function Distance_To_T (S : Spline; Dist : Fix16; Total_Len : out Fix16) return Fix16 is
      Seg_Count : Integer;
      Accum     : Fix16 := GD_Fixed.Zero;
      Seg_Len   : Fix16;
      P0, P1, P2, P3 : Vec2;
      Local_Dist : Fix16;
      Local_T    : Fix16;
      Inv_Count  : Fix16;
   begin
      Total_Len := GD_Fixed.Zero;
      if S.Count < 2 then return GD_Fixed.Zero; end if;
      if S.Closed then Seg_Count := S.Count; else Seg_Count := S.Count - 1; end if;

      -- 1. Find which segment contains the distance
      for I in 1 .. Seg_Count loop
         P0 := Get_Pt(S, I - 1);
         P1 := Get_Pt(S, I);
         P2 := Get_Pt(S, I + 1);
         P3 := Get_Pt(S, I + 2);
         
         Seg_Len := Geo_Curves.Catmull_Arc_Length(P0, P1, P2, P3, 10);
         
         if Dist >= Accum and then Dist <= Add_Sat(Accum, Seg_Len) then
            -- Found it. Solve local T.
            Local_Dist := Sub_Sat(Dist, Accum);
            -- Solve T for this segment
            Local_T := Geo_Curves.Catmull_Solve_T(P0, P1, P2, P3, Local_Dist, Epsilon);
            
            -- Convert Local T [0,1] to Global T [0,1]
            -- Global = (Seg_Index + Local_T) / Seg_Count
            Inv_Count := Div_Sat(GD_Fixed.One, From_Int(Seg_Count));
            
            -- We must calculate total length anyway for the out param
            -- So we break but continue summing
            Total_Len := Length(S); 
            return Mul_Sat(Add_Sat(From_Int(I - 1), Local_T), Inv_Count);
         end if;
         
         Accum := Add_Sat(Accum, Seg_Len);
      end loop;

      Total_Len := Accum;
      return GD_Fixed.One; -- End of path
   end Distance_To_T;

end Geo_Splines;