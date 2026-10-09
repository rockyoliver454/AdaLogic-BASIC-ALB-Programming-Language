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
with Roman_Spec; use Roman_Spec;
with Numerus_Magnus; use Numerus_Magnus;

package Code_Vault is

   -- Da Master Toggle for the Security Forge
   Secure_Mode : Boolean := False;

   -- Banish the Void: Returns the value incremented by 1 if Secure_Mode is on.
   -- This is used for loop bounds and literal declarations.
   function Secure_Val (Val : U64) return U64;

   -- The Roman Glyph: Converts a U64 value intae a C-compatible Roman string literal.
   -- Returns a standard String for the Emitter tae slap intae the C code.
   function To_Roman_Literal (Val : U64) return String;

   -- The Index Adjuster: Returns "- 1" as a string if we're in secure mode,
   -- tae be appended tae array accessors: e.g., "VAULT[i - 1]"
   function Index_Offset_Suffix return String;

end Code_Vault;
