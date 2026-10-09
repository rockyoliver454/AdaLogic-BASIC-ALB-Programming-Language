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

package body Str_Types is

   procedure Create_String (Input : in String; Color : in ALB_Color; Result : out ALB_String; Success : out Boolean) is
      RS_Stat : Boolean;
      Ival    : RS_Interval;
      Len     : Natural := Input'Length;
   begin
      Result := (Length => 0, Data => (others => ' '), Color => Color_None, Active => False);

      -- Range-spec sanity baseline
      NV_Monad_Init (1.0, Ival, RS_Stat);
      pragma Assert (RS_Stat);

      -- Fast-path for empty strings
      if Len = 0 then
         Result.Color  := Color;
         Result.Active := True;
         Success       := True;
         return;
      end if;

      -- RANGE-SPEC SHIELD: Prove the input fits in the vault!
      Create (1.0, Long_Float(Max_Str_Len), Ival, RS_Stat);
      if not RS_Stat or else not Contains(Ival, Long_Float(Len)) then
         Success := False;
         return;
      end if;

      -- Safely copy data
      for I in 1 .. Max_Str_Len loop
         if I <= Len then
            Result.Data(I) := Input(Input'First + (I - 1));
         end if;
      end loop;

      Result.Length := Len;
      Result.Color  := Color;
      Result.Active := True;
      Success       := True;
   end Create_String;

   procedure Concat_String (A, B : in ALB_String; Result : out ALB_String; Success : out Boolean) is
      RS_Stat   : Boolean;
      Ival      : RS_Interval;
      Total_Len : Natural;
   begin
      Result := (Length => 0, Data => (others => ' '), Color => Color_None, Active => False);

      if not A.Active or else not B.Active then
         Success := False;
         return;
      end if;

      -- Prevent integer overflow afore we do math
      if Natural'Last - A.Length < B.Length then
         Success := False;
         return;
      end if;

      Total_Len := A.Length + B.Length;

      -- RANGE-SPEC SHIELD: Prove the combined string fits!
      if Total_Len > 0 then
         Create (1.0, Long_Float(Max_Str_Len), Ival, RS_Stat);
         if not RS_Stat or else not Contains(Ival, Long_Float(Total_Len)) then
            Success := False;
            return;
         end if;
      end if;

      -- Copy String A
      for I in 1 .. Max_Str_Len loop
         if I <= A.Length then
            Result.Data(I) := A.Data(I);
         end if;
      end loop;

      -- Copy String B
      for I in 1 .. Max_Str_Len loop
         if I <= B.Length then
            Result.Data(A.Length + I) := B.Data(I);
         end if;
      end loop;

      Result.Length := Total_Len;
      Result.Color  := A.Color; -- Inherit the color of the left string
      Result.Active := True;
      Success       := True;
   end Concat_String;

   procedure Format_Roman_Error (Line, Col : in Long_Integer; Result : out ALB_String; Success : out Boolean) is
      R_Line, R_Col : RS_Roman;
      Stat1, Stat2  : Boolean;
      
      Str_Err, Str_L, Str_C, Str_Space : ALB_String;
      Temp_1, Temp_2, Temp_3           : ALB_String;
      Concat_Stat                      : Boolean;
   begin
      Result := (Length => 0, Data => (others => ' '), Color => Color_None, Active => False);

      -- 1. Convert Line and Column tae Imperial Roman Numerals!
      To_Roman (Line, R_Line, Stat1);
      To_Roman (Col, R_Col, Stat2);

      if not (Stat1 and then Stat2) then
         Success := False;
         return;
      end if;

      -- 2. Create the raw building blocks
      Create_String ("ERR L:", Color_Red, Str_Err, Stat1);
      Create_String (" C:", Color_Red, Str_Space, Stat2);
      
      -- Note: R_Line and R_Col buffer is Wide_String. We maun cast tae String for our vault.
      -- For SPARK compliancy, we iterate through the valid length.
      declare
         Line_Str : String (1 .. R_Line.Length) := (others => ' ');
         Col_Str  : String (1 .. R_Col.Length)  := (others => ' ');
      begin
         for I in 1 .. R_Line.Length loop
            Line_Str(I) := Character'Val(Wide_Character'Pos(R_Line.Buffer(I)));
         end loop;
         for I in 1 .. R_Col.Length loop
            Col_Str(I) := Character'Val(Wide_Character'Pos(R_Col.Buffer(I)));
         end loop;

         Create_String (Line_Str, Color_Red, Str_L, Stat1);
         Create_String (Col_Str, Color_Red, Str_C, Stat2);
      end;

      -- 3. Safely chain them thegether! (ERR L: + IV) + ( C: + XXII)
      Concat_String (Str_Err, Str_L, Temp_1, Concat_Stat);
      if not Concat_Stat then Success := False; return; end if;

      Concat_String (Temp_1, Str_Space, Temp_2, Concat_Stat);
      if not Concat_Stat then Success := False; return; end if;

      Concat_String (Temp_2, Str_C, Result, Concat_Stat);
      
      Success := Concat_Stat;
   end Format_Roman_Error;

end Str_Types;
