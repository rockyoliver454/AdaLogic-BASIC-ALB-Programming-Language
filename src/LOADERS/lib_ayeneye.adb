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
with AyeNEye_Std;
-- REMOVED: with Interfaces.C.Strings; (Already in Spec)
-- REMOVED: with System; (Already in Spec)

package body Lib_AyeNEye is

   use AyeNEye_Std;
   
   -- Helper to safely convert chars_ptr to String, handling nulls
   function Safe_Value(Ptr : chars_ptr) return String is
   begin
      if Ptr = Null_Ptr then
         return "";
      else
         return Value(Ptr);
      end if;
   end Safe_Value;

   -----------------------------------------------------------------------------
   -- SIZE HELPER
   -----------------------------------------------------------------------------
   function AyeNEye_Config_Size return int is
   begin
      return int(Config_Data'Size / 8); 
   end AyeNEye_Config_Size;

   -----------------------------------------------------------------------------
   -- LOAD
   -----------------------------------------------------------------------------
   function AyeNEye_Load 
     (Filename   : chars_ptr;
      Config_Ptr : System.Address) return int 
   is
      Ada_Filename : constant String := Safe_Value(Filename);
      Res          : Load_Result;
      
      Cfg : Config_Data;
      pragma Import (Ada, Cfg);
      for Cfg'Address use Config_Ptr;
   begin
      Load_INI(Ada_Filename, Cfg, Res);
      
      case Res is
         when Success         => return 0;
         when File_Not_Found  => return 1;
         when Buffer_Overflow => return 2;
         when Parse_Error     => return 3;
      end case;
   end AyeNEye_Load;

   -----------------------------------------------------------------------------
   -- GET STRING (Direct Memory Overlay Version)
   -----------------------------------------------------------------------------
   function AyeNEye_Get_String
     (Config_Ptr  : System.Address;
      Section     : chars_ptr;
      Key         : chars_ptr;
      Default     : chars_ptr;
      Dest_Buffer : System.Address;
      Dest_Len    : int) return int 
   is
      Cfg : Config_Data;
      pragma Import (Ada, Cfg);
      for Cfg'Address use Config_Ptr;
      
      Result_Str : constant String := Get_String
        (Cfg, Safe_Value(Section), Safe_Value(Key), Safe_Value(Default));
        
      Copy_Len : Natural := Result_Str'Length;
      
      -- Define an array overlay that maps directly to the C memory buffer
      -- We cast Dest_Len to size_t carefully
      Dest_Arr : char_array(0 .. size_t(Dest_Len));
      for Dest_Arr'Address use Dest_Buffer;
      pragma Import (Ada, Dest_Arr);
      
      C_Str : char_array (0 .. size_t(Copy_Len)); 
      Count : size_t;
   begin
      -- Safety check for bad C input
      if Dest_Len <= 0 then
         return 0;
      end if;

      -- Safety truncation check
      if Copy_Len >= Natural(Dest_Len) then
         Copy_Len := Natural(Dest_Len) - 1;
      end if;
      
      -- REMOVED: "if Copy_Len < 0" check (Natural cannot be negative)

      -- Convert Ada String to C char_array locally
      if Copy_Len > 0 then
         To_C(Result_Str(1 .. Copy_Len), C_Str(0 .. size_t(Copy_Len)-1), Count, Append_Nul => False);
      end if;

      -- Add Null Terminator
      C_Str(size_t(Copy_Len)) := nul;
      
      -- DIRECT COPY: Copy local C_Str into the destination buffer
      Dest_Arr(0 .. size_t(Copy_Len)) := C_Str(0 .. size_t(Copy_Len));
      
      return int(Result_Str'Length);
   end AyeNEye_Get_String;

   -----------------------------------------------------------------------------
   -- GET INTEGER
   -----------------------------------------------------------------------------
   function AyeNEye_Get_Integer
     (Config_Ptr : System.Address;
      Section    : chars_ptr;
      Key        : chars_ptr;
      Default    : int) return int 
   is
      Cfg : Config_Data;
      pragma Import (Ada, Cfg);
      for Cfg'Address use Config_Ptr;
   begin
      return int(Get_Integer(Cfg, Safe_Value(Section), Safe_Value(Key), Integer(Default)));
   end AyeNEye_Get_Integer;

   -----------------------------------------------------------------------------
   -- GET BOOLEAN
   -----------------------------------------------------------------------------
   function AyeNEye_Get_Boolean
     (Config_Ptr : System.Address;
      Section    : chars_ptr;
      Key        : chars_ptr;
      Default    : int) return int 
   is
      Cfg : Config_Data;
      pragma Import (Ada, Cfg);
      for Cfg'Address use Config_Ptr;
      
      Def_Bool : constant Boolean := (Default /= 0);
      Result   : Boolean;
   begin
      Result := Get_Boolean(Cfg, Safe_Value(Section), Safe_Value(Key), Def_Bool);
      if Result then return 1; else return 0; end if;
   end AyeNEye_Get_Boolean;

end Lib_AyeNEye;
