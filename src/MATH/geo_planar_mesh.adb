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

with Geo_Heightfield;

package body Geo_Planar_Mesh is

   procedure Generate_Grid 
     (M      : out Mesh; 
      Offset : Vec2; 
      Step   : Fix16; 
      Seed   : Integer) 
   is
      -- Grid settings (hardcoded to match Max constants roughly)
      Grid_Size : constant Integer := 16; -- 16x16 cells
      
      -- Helper to convert grid coord to Vertex ID
      -- Row, Col are 0-based.
      function Get_Vert_ID (Row, Col : Integer) return Vertex_ID is
      begin
         return Vertex_ID((Row * (Grid_Size + 1)) + Col + 1);
      end Get_Vert_ID;

      -- Helper to assign neighbors for a quad split into 2 triangles
      -- T1: Top-Left, Bottom-Left, Top-Right
      -- T2: Top-Right, Bottom-Left, Bottom-Right
      procedure Add_Quad (Row, Col : Integer) is
         -- Vertex Indices
         TL : constant Vertex_ID := Get_Vert_ID(Row, Col);
         TR : constant Vertex_ID := Get_Vert_ID(Row, Col + 1);
         BL : constant Vertex_ID := Get_Vert_ID(Row + 1, Col);
         BR : constant Vertex_ID := Get_Vert_ID(Row + 1, Col + 1);
         
         -- Face Indices (We add 2 faces per call)
         F1_Idx : constant Face_ID := Face_ID(M.Face_Count + 1);
         F2_Idx : constant Face_ID := Face_ID(M.Face_Count + 2);
      begin
         -- Triangle 1 (TL -> BL -> TR)
         M.Faces(Integer(F1_Idx)).V1 := TL;
         M.Faces(Integer(F1_Idx)).V2 := BL;
         M.Faces(Integer(F1_Idx)).V3 := TR;

         -- Triangle 2 (TR -> BL -> BR)
         M.Faces(Integer(F2_Idx)).V1 := TR;
         M.Faces(Integer(F2_Idx)).V2 := BL;
         M.Faces(Integer(F2_Idx)).V3 := BR;
         
         -- Incremental Adjacency Logic
         -- This is the "Glue" layer.
         -- Note: For a pure grid, we could compute neighbors mathematically,
         -- but for this specific implementation, we link T1 and T2 immediately.
         
         -- T1 Edge 2 (BL-TR) is shared with T2 Edge 1 (TR-BL) - reversed
         M.Faces(Integer(F1_Idx)).N2 := F2_Idx;
         M.Faces(Integer(F2_Idx)).N1 := F1_Idx;
         
         -- External Neighbors would require checking Row-1, Col-1, etc.
         -- For now, we leave them 0 (Boundary) or implement full pass.
         -- Given "Single Page" constraint, we define internal connectivity mostly.

         M.Face_Count := M.Face_Count + 2;
      end Add_Quad;

      Current_Pos : Vec2;
      X, Z : Fix16;
   begin
      -- 1. Generate Vertices
      -- Loop 0..16 (17 verts)
      M.Vertex_Count := 0;
      for R in 0 .. Grid_Size loop
         for C in 0 .. Grid_Size loop
            M.Vertex_Count := M.Vertex_Count + 1;
            
            X := Offset.X + (From_Int(C) * Step);
            Z := Offset.Y + (From_Int(R) * Step);
            Current_Pos := Create(X, Z);
            
            -- Sample the Oracle
            M.Vertices(Integer(M.Vertex_Count)).Position := 
               Vector(X, Geo_Heightfield.Get_Height(Current_Pos, Seed), Z);
               
            M.Vertices(Integer(M.Vertex_Count)).Normal := 
               Geo_Heightfield.Get_Normal(Current_Pos, Seed);
         end loop;
      end loop;

      -- 2. Generate Faces (Quads -> Triangles)
      M.Face_Count := 0;
      for R in 0 .. Grid_Size - 1 loop
         for C in 0 .. Grid_Size - 1 loop
            Add_Quad(R, C);
         end loop;
      end loop;

   end Generate_Grid;

end Geo_Planar_Mesh;