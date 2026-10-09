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

--------------------------------------------------------------------------------
-- Project: AyeNEye - The 100-Year Configuration Vault
-- Description: Formally Verified INI Parser in SPARK/Ada 2012
--
-- Author: Rocky L. Oliver
-- Copyright: (c) 2026 Rocky L. Oliver
-- All rights reserved.
-- 
-- License: Dual-licensed under MIT and BSD 3-Clause
--          This software is provided "AS IS" without warranty.
--          See the root LICENSE file for full terms and conditions.
--
-- Documentation: https://rockyoliver.itch.io/ayeneye-ini-parser
--------------------------------------------------------------------------------


pragma Ada_2012;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;

package Lib_AyeNEye is

   -- Export helper to get the size needed for the Config object
   function AyeNEye_Config_Size return int;
   pragma Export (C, AyeNEye_Config_Size, "AyeNEye_Config_Size");

   -- C-Compatible Load Function
   function AyeNEye_Load 
     (Filename   : chars_ptr;
      Config_Ptr : System.Address) return int;
   pragma Export (C, AyeNEye_Load, "AyeNEye_Load");

   -- C-Compatible Get String
   -- CHANGED: Dest_Buffer is now System.Address for direct overlay access
   function AyeNEye_Get_String
     (Config_Ptr  : System.Address;
      Section     : chars_ptr;
      Key         : chars_ptr;
      Default     : chars_ptr;
      Dest_Buffer : System.Address;
      Dest_Len    : int) return int;
   pragma Export (C, AyeNEye_Get_String, "AyeNEye_Get_String");

   -- C-Compatible Get Integer
   function AyeNEye_Get_Integer
     (Config_Ptr : System.Address;
      Section    : chars_ptr;
      Key        : chars_ptr;
      Default    : int) return int;
   pragma Export (C, AyeNEye_Get_Integer, "AyeNEye_Get_Integer");

   -- C-Compatible Get Boolean
   function AyeNEye_Get_Boolean
     (Config_Ptr : System.Address;
      Section    : chars_ptr;
      Key        : chars_ptr;
      Default    : int) return int;
   pragma Export (C, AyeNEye_Get_Boolean, "AyeNEye_Get_Boolean");

end Lib_AyeNEye;
