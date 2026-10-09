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

-- ============================================================================
-- ALB_System_Includes — shared SDK/vendor system INCLUDE <> resolution
-- and optional --gfx= RHI DLL remapping for all ALB backends.
-- ============================================================================
-- INCLUDE "foo.albi"  → relative / source-local (handled by each backend)
-- INCLUDE <foo.albi>  → Resolve_System_Include under SDK stdlib/vendor/
-- ============================================================================

package ALB_System_Includes is

   function Fold_Lower (S : String) return String;

   function SDK_Root return String;
   function Vendor_Root return String;

   -- Resolve a system include leaf (e.g. "alb_gfx.albi") under stdlib/vendor.
   -- Returns the first existing path, or Leaf unchanged if not found.
   function Resolve_System_Include (Leaf : String) return String;

   -- True when Leaf names an existing system include.
   function System_Include_Exists (Leaf : String) return Boolean;

   -- Compile-time RHI backend: remaps IMPORT_DLL "alb_gfx.dll".
   procedure Clear_Gfx_Backend;
   procedure Set_Gfx_Backend (Name : String; OK : out Boolean);
   function Gfx_Backend return String;
   function Gfx_Is_Set return Boolean;
   function Gfx_Runtime_Used return Boolean;

   function Remap_Gfx_Library (Lib : String) return String;
   function Resolve_Vendor_Dll (Lib : String) return String;

   -- Parse --gfx=NAME or --gfx NAME from a CLI arg pair.
   -- Returns True when Arg was consumed as a gfx option.
   function Try_Parse_Gfx_Arg
     (Arg       : String;
      Next_Arg  : String;
      Has_Next  : Boolean;
      Skip_Next : out Boolean;
      Error     : out Boolean) return Boolean;

end ALB_System_Includes;
