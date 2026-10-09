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

--  -- OLD VERSION
--  pragma SPARK_Mode (On);
--  with ALB_Oracle; use ALB_Oracle;
--  
--  package body Module_Vault is
--  
--     procedure Initialize_Vault is
--     begin
--        Vault_Count := 0;
--        for I in 1 .. Max_Modules loop
--           Vault (I).Name_Len    := 0;
--           Vault (I).Path_Len    := 0;
--           Vault (I).Dep_Count   := 0;
--           Vault (I).Is_Resolved := False;
--        end loop;
--     end Initialize_Vault;
--  
--     procedure Register_Module
--       (Mod_Name : in String;
--        Mod_Path : in String;
--        Success  : out Boolean)
--     is
--        -- Oracle assertion tae ensure we dinna overflow the kist
--        Space_Check : Boolean := Vault_Count < Max_Modules;
--     begin
--        Success := False;
--  
--        -- Runtime Assertion 1: Check capacity
--        if not Space_Check then
--           return;
--        end if;
--  
--        -- Runtime Assertion 2: Check for duplicates afore adding
--        if Find_Module (Mod_Name) /= 0 then
--           return; -- Already registered, like GLBasic/PB once-only inclusion
--        end if;
--  
--        Vault_Count := Vault_Count + 1;
--  
--        Vault (Vault_Count).Name_Len := Mod_Name'Length;
--        for I in Mod_Name'Range loop
--           Vault (Vault_Count).Name (I - Mod_Name'First + 1) := Mod_Name (I);
--        end loop;
--  
--        Vault (Vault_Count).Path_Len := Mod_Path'Length;
--        for I in Mod_Path'Range loop
--           Vault (Vault_Count).Path (I - Mod_Path'First + 1) := Mod_Path (I);
--        end loop;
--  
--        -- Initialize our strict bounding boxes as empty
--        Ignore_Result := Range_Spec.Create(0.0, 0.0, Vault (Vault_Count).Interface_AST'Access);
--        Ignore_Result := Range_Spec.Create(0.0, 0.0, Vault (Vault_Count).Impl_AST'Access);
--  
--        Success := True;
--     end Register_Module;
--  
--     procedure Add_Dependency
--       (Target_Mod : in Module_Index;
--        Dep_Mod    : in Module_Index;
--        Success    : out Boolean)
--     is
--        Check_Bounds : Boolean;
--     begin
--        Success := False;
--  
--        -- Runtime Assertion 1: Ensure Target is valid
--        Check_Bounds := Target_Mod <= Vault_Count and Target_Mod > 0;
--        if not Check_Bounds then return; end if;
--  
--        -- Runtime Assertion 2: Ensure Dep array has room
--        Check_Bounds := Vault (Target_Mod).Dep_Count < Max_Deps;
--        if not Check_Bounds then return; end if;
--  
--        -- Check if dependency already exists (avoid duplicate 'with' lines)
--        for I in 1 .. Max_Deps loop
--           if I <= Vault (Target_Mod).Dep_Count then
--              if Vault (Target_Mod).Dependencies (I) = Dep_Mod then
--                 Success := True; -- Already hooked up
--                 return;
--              end if;
--           end if;
--        end loop;
--  
--        Vault (Target_Mod).Dep_Count := Vault (Target_Mod).Dep_Count + 1;
--        Vault (Target_Mod).Dependencies (Vault (Target_Mod).Dep_Count) := Dep_Mod;
--  
--        Success := True;
--     end Add_Dependency;
--  
--     function Find_Module (Mod_Name : String) return Module_Index is
--        Match : Boolean;
--     begin
--        for I in 1 .. Max_Modules loop
--           if I <= Vault_Count then
--              if Vault (I).Name_Len = Mod_Name'Length then
--                 Match := True;
--                 for J in Mod_Name'Range loop
--                    if Vault (I).Name (J - Mod_Name'First + 1) /= Mod_Name (J) then
--                       Match := False;
--                       exit;
--                    end if;
--                 end loop;
--  
--                 if Match then
--                    return I;
--                 end if;
--              end if;
--           end if;
--        end loop;
--  
--        return 0;
--     end Find_Module;
--  
--  end Module_Vault;
-- OLD VERSION

pragma SPARK_Mode (On);

package body Module_Vault is

   procedure Initialize_Vault is
      R_Success : Boolean;
   begin
      Vault_Count := 0;
      Float_Expr.Reset (Sym_Builder);
      
      for I in 1 .. Max_Modules loop
         Vault (I).Name_Len    := 0;
         Vault (I).Path_Len    := 0;
         Vault (I).Dep_Count   := 0;
         Vault (I).Is_Resolved := False;
         
         -- Reset Intervals safely
         Range_Spec.Scalar (0.0, Vault (I).Interface_AST, R_Success);
         Range_Spec.Scalar (0.0, Vault (I).Impl_AST, R_Success);
         Range_Spec.Scalar (0.0, Vault (I).Valid_Version, R_Success);
      end loop;
   end Initialize_Vault;

   procedure Register_Module
     (Mod_Name : in String;
      Mod_Path : in String;
      Success  : out Boolean)
   is
      Valid_Name_Int : RS_Interval;
      Cap_Int        : RS_Interval;
      R_Success      : Boolean;
   begin
      Success := False;
      
      -- ASSERTION 1: Mandate the Name Length is valid (1 to 64)
      Range_Spec.Create (1.0, Long_Float(Max_Name), Valid_Name_Int, R_Success);
      if not R_Success or else not Range_Spec.Contains (Valid_Name_Int, Long_Float(Mod_Name'Length)) then
         return; 
      end if;

      -- ASSERTION 2: Mandate Vault Capacity has room
      Range_Spec.Create (0.0, Long_Float(Max_Modules - 1), Cap_Int, R_Success);
      if not R_Success or else not Range_Spec.Contains (Cap_Int, Long_Float(Vault_Count)) then
         return;
      end if;

      if Find_Module (Mod_Name) /= 0 then
         return; 
      end if;

      Vault_Count := Vault_Count + 1;
      
      Vault (Vault_Count).Name_Len := Mod_Name'Length;
      for I in Mod_Name'Range loop
         Vault (Vault_Count).Name (I - Mod_Name'First + 1) := Mod_Name (I);
      end loop;

      Vault (Vault_Count).Path_Len := Mod_Path'Length;
      for I in Mod_Path'Range loop
         Vault (Vault_Count).Path (I - Mod_Path'First + 1) := Mod_Path (I);
      end loop;
      
      -- Default safe boundaries
      Range_Spec.Scalar (0.0, Vault (Vault_Count).Interface_AST, R_Success);
      Range_Spec.Scalar (0.0, Vault (Vault_Count).Impl_AST, R_Success);
      
      Success := True;
   end Register_Module;

   procedure Add_Dependency
     (Target_Mod : in Module_Index;
      Dep_Mod    : in Module_Index;
      Success    : out Boolean)
   is
      Target_Int, Dep_Int : RS_Interval;
      R_Success : Boolean;
   begin
      Success := False;
      
      -- ASSERTION 1: Target Module maun be within active bounds
      Range_Spec.Create (1.0, Long_Float(Vault_Count), Target_Int, R_Success);
      if not R_Success or else not Range_Spec.Contains (Target_Int, Long_Float(Target_Mod)) then 
         return; 
      end if;

      -- ASSERTION 2: Dependency count maun be less than max
      Range_Spec.Create (0.0, Long_Float(Max_Deps - 1), Dep_Int, R_Success);
      if not R_Success or else not Range_Spec.Contains (Dep_Int, Long_Float(Vault (Target_Mod).Dep_Count)) then 
         return; 
      end if;

      for I in 1 .. Max_Deps loop
         if I <= Vault (Target_Mod).Dep_Count then
            if Vault (Target_Mod).Dependencies (I) = Dep_Mod then
               Success := True; 
               return;
            end if;
         end if;
      end loop;

      Vault (Target_Mod).Dep_Count := Vault (Target_Mod).Dep_Count + 1;
      Vault (Target_Mod).Dependencies (Vault (Target_Mod).Dep_Count) := Dep_Mod;
      
      Success := True;
   end Add_Dependency;

   function Find_Module (Mod_Name : String) return Module_Index is
      Match : Boolean;
   begin
      -- Fixed loop boundaries ensure nae runaway execution
      for I in 1 .. Max_Modules loop
         if I <= Vault_Count then
            if Vault (I).Name_Len = Mod_Name'Length then
               Match := True;
               for J in Mod_Name'Range loop
                  if Vault (I).Name (J - Mod_Name'First + 1) /= Mod_Name (J) then
                     Match := False;
                     exit;
                  end if;
               end loop;
               
               if Match then
                  return I;
               end if;
            end if;
         end if;
      end loop;
      
      return 0;
   end Find_Module;

end Module_Vault;
