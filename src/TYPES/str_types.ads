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
with Range_Spec;    use Range_Spec;
with Numerus_Verus; use Numerus_Verus;
with Roman_Spec;    use Roman_Spec;

package Str_Types is
   pragma Pure;

   -- =========================================================================
   -- Da Universal ANSI Color Palette
   -- =========================================================================
   type ALB_Color is (Color_None, Color_Red, Color_Green, Color_Gold, Color_Cyan, Color_Grey);

   -- We use 256 tae exactly match yer Roman_Buffer, keepin' the vaults aligned!
   Max_Str_Len : constant := 256;
   subtype ALB_String_Data is String (1 .. Max_Str_Len);

   -- =========================================================================
   -- Safe bounded string: fixed-length buffer, no heap, no null terminators
   -- =========================================================================
   type ALB_String is record
      Length : Natural := 0;
      Data   : ALB_String_Data := (others => ' ');
      Color  : ALB_Color := Color_None;
      Active : Boolean := False;
   end record;

   -- =========================================================================
   -- Core Operations (Strictly Procedures for SPARK Compliancy)
   -- =========================================================================
   
   -- Safely creates a bounded string from an input string.
   procedure Create_String (Input : in String; Color : in ALB_Color; Result : out ALB_String; Success : out Boolean);

   -- Safely joins two bounded strings using Range_Spec bounds checking.
   procedure Concat_String (A, B : in ALB_String; Result : out ALB_String; Success : out Boolean);

   -- =========================================================================
   -- Da "Roman" Formatter (Yer Secret Weapon for Debugging)
   -- =========================================================================
   -- Constructs a beautiful, red error string like: "ERR L: IV C: XXII"
   procedure Format_Roman_Error (Line, Col : in Long_Integer; Result : out ALB_String; Success : out Boolean);

end Str_Types;
