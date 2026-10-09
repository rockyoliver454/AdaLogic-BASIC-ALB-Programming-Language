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
with AyeNEye;

-- A Standard, Concrete Instance of AyeNEye for library generation.
-- Limits: 100 Sections, 500 Keys, 256 Char Lines.
package AyeNEye_Std is new AyeNEye
  (Max_Sections => 100,
   Max_Keys     => 500,
   Max_Line_Len => 256);
