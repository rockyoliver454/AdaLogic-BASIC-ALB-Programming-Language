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

package body ALB_Ops is

   -- =========================================================================
   -- ARITHMETIC
   -- =========================================================================

   procedure Promote_Values (A, B : in ALB_Value; PA, PB : out ALB_Value; Success : out Boolean) is
   begin
      PA := A;
      PB := B;
      Success := True;
      if A.Tag = B.Tag then
         return;
      end if;

      -- Implicit Widening Rules
      -- Currently deferred as constant folding only operates on U128/S128/Pure/F64
      -- which do not have safe universal cross-cast mappings in SPARK without
      -- introducing external dependencies or data loss.
      Success := False;
   end Promote_Values;

   procedure Add_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean) is
      Stat : Boolean;
   begin
      Res := (Tag => Type_None);
      Success := False;

      declare
         PA, PB : ALB_Value;
         Prom_OK : Boolean;
      begin
         Promote_Values (A, B, PA, PB, Prom_OK);
         if not Prom_OK then return; end if;
      end;

      case A.Tag is
         when Type_F64 =>
            Res := (Tag => Type_F64, Val_F64 => A.Val_F64 + B.Val_F64);
            Success := True;
            
         when Type_Pure =>
            declare P_Res : Pure_Rational; begin
               Add_Pure (A.Val_Pure, B.Val_Pure, P_Res, Stat);
               if Stat then
                  Res := (Tag => Type_Pure, Val_Pure => P_Res);
                  Success := True;
               end if;
            end;
            
         when Type_U128 =>
            declare U_Res : U128; begin
               Add_U128 (A.Val_U128, B.Val_U128, U_Res, Stat);
               if Stat then
                  Res := (Tag => Type_U128, Val_U128 => U_Res);
                  Success := True;
               end if;
            end;

         when Type_S128 =>
            declare S_Res : S128; begin
               Add_S128 (A.Val_S128, B.Val_S128, S_Res, Stat);
               if Stat then
                  Res := (Tag => Type_S128, Val_S128 => S_Res);
                  Success := True;
               end if;
            end;

         when others => null; -- Fallback for currently unsupported types
      end case;
   end Add_Values;

   procedure Sub_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean) is
      Stat : Boolean;
   begin
      Res := (Tag => Type_None); Success := False;
      declare
         PA, PB : ALB_Value;
         Prom_OK : Boolean;
      begin
         Promote_Values (A, B, PA, PB, Prom_OK);
         if not Prom_OK then return; end if;
      end;

      case A.Tag is
         when Type_F64 =>
            Res := (Tag => Type_F64, Val_F64 => A.Val_F64 - B.Val_F64);
            Success := True;
         when Type_Pure =>
            declare P_Res : Pure_Rational; begin
               Sub_Pure (A.Val_Pure, B.Val_Pure, P_Res, Stat);
               if Stat then Res := (Tag => Type_Pure, Val_Pure => P_Res); Success := True; end if;
            end;
         when Type_U128 =>
            declare U_Res : U128; begin
               Sub_U128 (A.Val_U128, B.Val_U128, U_Res, Stat);
               if Stat then Res := (Tag => Type_U128, Val_U128 => U_Res); Success := True; end if;
            end;
         when Type_S128 =>
            declare S_Res : S128; begin
               Sub_S128 (A.Val_S128, B.Val_S128, S_Res, Stat);
               if Stat then Res := (Tag => Type_S128, Val_S128 => S_Res); Success := True; end if;
            end;
         when others => null;
      end case;
   end Sub_Values;

   procedure Mul_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean) is
      Stat : Boolean;
   begin
      Res := (Tag => Type_None); Success := False;
      declare
         PA, PB : ALB_Value;
         Prom_OK : Boolean;
      begin
         Promote_Values (A, B, PA, PB, Prom_OK);
         if not Prom_OK then return; end if;
      end;

      case A.Tag is
         when Type_F64 =>
            Res := (Tag => Type_F64, Val_F64 => A.Val_F64 * B.Val_F64);
            Success := True;
         when Type_Pure =>
            declare P_Res : Pure_Rational; begin
               Mul_Pure (A.Val_Pure, B.Val_Pure, P_Res, Stat);
               if Stat then Res := (Tag => Type_Pure, Val_Pure => P_Res); Success := True; end if;
            end;
         when others => null;
      end case;
   end Mul_Values;

   procedure Div_Values (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean) is
      Stat : Boolean;
   begin
      Res := (Tag => Type_None); Success := False;
      declare
         PA, PB : ALB_Value;
         Prom_OK : Boolean;
      begin
         Promote_Values (A, B, PA, PB, Prom_OK);
         if not Prom_OK then return; end if;
      end;

      case A.Tag is
         when Type_F64 =>
            -- Manual zero shield for floats tae satisfy SPARK flow purity
            if B.Val_F64 = 0.0 then return; end if;
            Res := (Tag => Type_F64, Val_F64 => A.Val_F64 / B.Val_F64);
            Success := True;
         when Type_Pure =>
            declare P_Res : Pure_Rational; begin
               Div_Pure (A.Val_Pure, B.Val_Pure, P_Res, Stat);
               if Stat then Res := (Tag => Type_Pure, Val_Pure => P_Res); Success := True; end if;
            end;
         when others => null;
      end case;
   end Div_Values;

   -- =========================================================================
   -- LOGICAL COMPARISONS
   -- =========================================================================

   procedure Is_Equal (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean) is
   begin
      Res := (Tag => Type_Boolean, Val_Bool => False);
      Success := True;

      -- If types differ, they canna be equal
      declare
         PA, PB : ALB_Value;
         Prom_OK : Boolean;
      begin
         Promote_Values (A, B, PA, PB, Prom_OK);
         if not Prom_OK then return; end if;
      end;

      case A.Tag is
         when Type_F64 => 
            Res.Val_Bool := (A.Val_F64 = B.Val_F64);
         when Type_Pure => 
            -- Canonical Form guarantee: if Num and Den match, value matches!
            Res.Val_Bool := (A.Val_Pure.Num = B.Val_Pure.Num and then A.Val_Pure.Den = B.Val_Pure.Den);
         when Type_U128 =>
            Res.Val_Bool := (A.Val_U128.High = B.Val_U128.High and then A.Val_U128.Low = B.Val_U128.Low);
         when Type_Boolean =>
            Res.Val_Bool := (A.Val_Bool = B.Val_Bool);
         when others => 
            Success := False;
            Res := (Tag => Type_None);
      end case;
   end Is_Equal;

   procedure Is_Less (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean) is
   begin
      Res := (Tag => Type_None); Success := False;
      declare
         PA, PB : ALB_Value;
         Prom_OK : Boolean;
      begin
         Promote_Values (A, B, PA, PB, Prom_OK);
         if not Prom_OK then return; end if;
      end;

      case A.Tag is
         when Type_F64 =>
            Res := (Tag => Type_Boolean, Val_Bool => (A.Val_F64 < B.Val_F64));
            Success := True;
         when Type_Pure =>
            -- Cross-multiply tae safely compare fractions: (N1 * D2) < (N2 * D1)
            declare
               Left  : Long_Integer := A.Val_Pure.Num * B.Val_Pure.Den;
               Right : Long_Integer := B.Val_Pure.Num * A.Val_Pure.Den;
            begin
               Res := (Tag => Type_Boolean, Val_Bool => Left < Right);
               Success := True;
            end;
         when others => null;
      end case;
   end Is_Less;

   procedure Is_Greater (A, B : in ALB_Value; Res : out ALB_Value; Success : out Boolean) is
   begin
      Res := (Tag => Type_None); Success := False;
      declare
         PA, PB : ALB_Value;
         Prom_OK : Boolean;
      begin
         Promote_Values (A, B, PA, PB, Prom_OK);
         if not Prom_OK then return; end if;
      end;

      case A.Tag is
         when Type_F64 =>
            Res := (Tag => Type_Boolean, Val_Bool => (A.Val_F64 > B.Val_F64));
            Success := True;
         when Type_Pure =>
            declare
               Left  : Long_Integer := A.Val_Pure.Num * B.Val_Pure.Den;
               Right : Long_Integer := B.Val_Pure.Num * A.Val_Pure.Den;
            begin
               Res := (Tag => Type_Boolean, Val_Bool => Left > Right);
               Success := True;
            end;
         when others => null;
      end case;
   end Is_Greater;

end ALB_Ops;
