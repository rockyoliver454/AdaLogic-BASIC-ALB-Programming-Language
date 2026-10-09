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

with ALB_Types; use ALB_Types;

-- Shared surface type-name map for all backends (Track T0 / T1).
-- Resolve_Type_Name returns Type_None for unknown names (never silently U64).
package ALB_Type_Names is
   pragma Pure;

   type Backend_Class is
     (Class_Modern_Native,  -- FASM / NASM / C / Ada
      Class_Managed,        -- Java / TS / Rust / Python / ...
      Class_Retro_8_16,     -- C64 / FASM16 / DOS
      Class_Erased);        -- toys / Godot-soft

   type Belong_Kind is
     (Belong_Must,   -- honest storage + ops required
      Belong_Soft,   -- accepted; host may widen/narrow
      Belong_Out,    -- does not belong; reject or keep current path
      Belong_Void);  -- U0 / NONE — not a value type

   function Resolve_Type_Name (Name : String) return ALB_Type_Tag;
   -- Canonical spelling used in diagnostics / dumps.
   function Canonical_Type_Name (Tag : ALB_Type_Tag) return String;
   function Is_Builtin_Type_Name (Name : String) return Boolean;
   -- True for U0 / NONE / VOID (recognized, not value AS types).
   function Is_Void_Type_Name (Name : String) return Boolean;

   function Belongs_On
     (Tag   : ALB_Type_Tag;
      Class : Backend_Class) return Belong_Kind;

   -- STRICT / SLIDE / PARALLEL scalar element whitelist for a backend class.
   function Allowed_As_Array_Element
     (Tag   : ALB_Type_Tag;
      Class : Backend_Class) return Boolean;

end ALB_Type_Names;
