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

-- OLD VERSION
--  --  pragma SPARK_Mode (On);
--  with Range_Spec; use Range_Spec;
--  
--  package Module_Vault is
--     pragma Pure;
--  
--     -- We keep her tight an' bounded. Nae runaway heap allocations!
--     Max_Modules : constant := 256;
--     Max_Deps    : constant := 32;
--     Max_Name    : constant := 64;
--     Max_Path    : constant := 256;
--  
--     subtype Module_Index is Integer range 0 .. Max_Modules;
--     subtype Dep_Index    is Integer range 0 .. Max_Deps;
--  
--     type String_64  is array (1 .. Max_Name) of Character;
--     type String_256 is array (1 .. Max_Path) of Character;
--  
--     -- Keeps track o' what a module relies on (Rust's 'use' / Ada's 'with')
--     type Dependency_Array is array (1 .. Max_Deps) of Module_Index;
--  
--     type Module_Record is record
--        Name          : String_64  := (others => ' ');
--        Name_Len      : Natural    := 0;
--        Path          : String_256 := (others => ' ');
--        Path_Len      : Natural    := 0;
--  
--        -- Bounding boxes for the AST ranges (using yer Range_Spec!)
--        -- Interface maps tae DeclareModule / Spec
--        Interface_AST : RS_Interval;
--        -- Implementation maps tae Module / Body
--        Impl_AST      : RS_Interval;
--  
--        Dependencies  : Dependency_Array := (others => 0);
--        Dep_Count     : Natural := 0;
--  
--        Is_Resolved   : Boolean := False;
--     end record;
--  
--     type Module_Array is array (1 .. Max_Modules) of Module_Record;
--  
--     -- =========================================================================
--     -- THE PUBLIC INTERFACE
--     -- =========================================================================
--  
--     procedure Initialize_Vault;
--  
--     procedure Register_Module
--       (Mod_Name : in String;
--        Mod_Path : in String;
--        Success  : out Boolean)
--       with
--         Pre  => Mod_Name'Length <= Max_Name and Mod_Path'Length <= Max_Path;
--  
--     procedure Add_Dependency
--       (Target_Mod : in Module_Index;
--        Dep_Mod    : in Module_Index;
--        Success    : out Boolean)
--       with
--         Pre => Target_Mod in 1 .. Max_Modules and Dep_Mod in 1 .. Max_Modules;
--  
--     function Find_Module (Mod_Name : String) return Module_Index
--       with Pre => Mod_Name'Length <= Max_Name;
--  
--  private
--     Vault       : Module_Array;
--     Vault_Count : Natural := 0;
--  
--  end Module_Vault;
-- OLD VERSION

pragma SPARK_Mode (On);
with Range_Spec; use Range_Spec;
with Float_Expr; use Float_Expr;

package Module_Vault is

   -- Da strict static bounds
   Max_Modules : constant := 1024;
   Max_Deps    : constant := 32;
   Max_Name    : constant := 64;
   Max_Path    : constant := 256;

   subtype Module_Index is Integer range 0 .. Max_Modules;
   subtype Dep_Index    is Integer range 0 .. Max_Deps;

   type String_64  is array (1 .. Max_Name) of Character;
   type String_256 is array (1 .. Max_Path) of Character;

   type Dependency_Array is array (1 .. Max_Deps) of Module_Index;

   type Module_Record is record
      Name          : String_64  := (others => ' ');
      Name_Len      : Natural    := 0;
      Path          : String_256 := (others => ' ');
      Path_Len      : Natural    := 0;
      
      -- Compile-Time Symbolic Configuration / Versioning!
      Sym_Config    : Float_Expr.Expr := (Root => Float_Expr.Null_Node);
      Valid_Version : RS_Interval;

      -- Bounding boxes for the AST ranges
      Interface_AST : RS_Interval; 
      Impl_AST      : RS_Interval; 

      Dependencies  : Dependency_Array := (others => 0);
      Dep_Count     : Natural := 0;
      
      Is_Resolved   : Boolean := False;
   end record;

   type Module_Array is array (1 .. Max_Modules) of Module_Record;

   -- =========================================================================
   -- THE PUBLIC INTERFACE
   -- =========================================================================
   procedure Initialize_Vault;

   procedure Register_Module
     (Mod_Name : in String;
      Mod_Path : in String;
      Success  : out Boolean)
     with 
       Pre  => Mod_Name'Length <= Max_Name and Mod_Path'Length <= Max_Path;

   procedure Add_Dependency
     (Target_Mod : in Module_Index;
      Dep_Mod    : in Module_Index;
      Success    : out Boolean)
     with
       Pre => Target_Mod in 1 .. Max_Modules and Dep_Mod in 1 .. Max_Modules;

   function Find_Module (Mod_Name : String) return Module_Index
     with Pre => Mod_Name'Length <= Max_Name;

private
   Vault       : Module_Array;
   Vault_Count : Natural := 0;
   
   -- A shared symbolic builder for evaluating module configurations
   Sym_Builder : Float_Expr.Builder;

end Module_Vault;
