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

pragma SPARK_Mode (On);
with Range_Spec; use Range_Spec;

package Atom_Types is
   pragma Pure;

   -- We set fixed boundaries tae prevent heap allocation
   Max_Atoms       : constant := 1024;
   Max_Atom_Length : constant := 32;

   subtype Atom_String is String (1 .. Max_Atom_Length);

   -- =========================================================================
   -- Da Primitive Type: A tiny integer that represents a whole word
   -- =========================================================================
   type ALB_Atom is record
      ID : Natural := 0;
   end record;

   -- =========================================================================
   -- Da Lexicon Vault: The static dictionary o' a' known symbols
   -- =========================================================================
   type Atom_Entry is record
      Active : Boolean := False;
      Name   : Atom_String := (others => ' ');
      Length : Natural := 0;
   end record;

   type Atom_Array is array (1 .. Max_Atoms) of Atom_Entry;

   type Lexicon_Vault is record
      Entries : Atom_Array := (others => (Active => False, Name => (others => ' '), Length => 0));
      Count   : Natural := 0;
   end record;

   -- =========================================================================
   -- Core Engine Procedures
   -- =========================================================================
   
   -- Searches the vault. If found, returns the ID. If new, registers it an' returns a new ID.
   procedure Get_Or_Register_Atom (Vault   : in out Lexicon_Vault;
                                   Name    : in String;
                                   Result  : out ALB_Atom;
                                   Success : out Boolean);

   -- Reverse lookup: Takes an ID an' safely returns the actual String for printing
   procedure Get_Atom_Name (Vault   : in Lexicon_Vault;
                            Atom    : in ALB_Atom;
                            Name    : out Atom_String;
                            Length  : out Natural;
                            Success : out Boolean);

end Atom_Types;
