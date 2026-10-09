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
with Geo_Vec2;    use Geo_Vec2;
with Geo_Algebra; use Geo_Algebra;

package Geo_Planar_Mesh is
   -- [TITANIUM FIX] Removed pragma Preelaborate to allow dependency on Geo_Heightfield
   -- pragma Preelaborate;

   -------------------------------------------------------------------------
   -- Constants & Bounds (Power of Ten: Fixed Limits)
   -------------------------------------------------------------------------
   Max_Vertices : constant Integer := 300;
   Max_Faces    : constant Integer := 600;

   -------------------------------------------------------------------------
   -- Data Structures
   -------------------------------------------------------------------------
   type Vertex_ID is new Integer range 0 .. Max_Vertices;
   type Face_ID   is new Integer range 0 .. Max_Faces;

   type Vertex is record
      Position : Multivector; -- World Space (X, Y, Z)
      Normal   : Multivector; -- From Heightfield
   end record;

   type Face is record
      -- Connectivity (The "Geometry")
      V1, V2, V3 : Vertex_ID;
      
      -- Adjacency (The "Topology")
      N1, N2, N3 : Face_ID; 
   end record;

   -- Named array types (Required by Ada for records)
   type Vertex_Array is array (1 .. Max_Vertices) of Vertex;
   type Face_Array   is array (1 .. Max_Faces)    of Face;

   type Mesh is record
      Vertices     : Vertex_Array;
      Faces        : Face_Array;
      Vertex_Count : Vertex_ID := 0;
      Face_Count   : Face_ID   := 0;
   end record;

   -------------------------------------------------------------------------
   -- Operations
   -------------------------------------------------------------------------
   procedure Generate_Grid 
     (M      : out Mesh; 
      Offset : Vec2; 
      Step   : Fix16; 
      Seed   : Integer);

end Geo_Planar_Mesh;