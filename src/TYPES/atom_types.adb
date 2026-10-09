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

package body Atom_Types is

   procedure Get_Or_Register_Atom (Vault   : in out Lexicon_Vault;
                                   Name    : in String;
                                   Result  : out ALB_Atom;
                                   Success : out Boolean) is
      RS_Stat  : Boolean;
      Ival     : RS_Interval;
      Match    : Boolean;
      Len      : Natural;
      Test_Val : Long_Float;
   begin
      Result  := (ID => 0);
      Success := False;
      Len     := Name'Length;

      -- 1. RANGE-SPEC ASSERTION: String length maun fit inside 1 .. Max_Atom_Length
      -- (If length is 1, use Scalar tae prevent identical bounds failure)
      if Len = 1 then
         Scalar (1.0, Ival, RS_Stat);
      else
         Create (1.0, Long_Float(Max_Atom_Length), Ival, RS_Stat);
      end if;
      
      if not RS_Stat or else not Contains(Ival, Long_Float(Len)) then
         return;
      end if;

      -- 2. Search for an existing match (Fast-path)
      for I in 1 .. Max_Atoms loop
         if I <= Vault.Count then
            if Vault.Entries(I).Active and then Vault.Entries(I).Length = Len then
               Match := True;
               for J in 1 .. Max_Atom_Length loop
                  if J <= Len then
                     if Vault.Entries(I).Name(J) /= Name(Name'First + (J - 1)) then
                        Match := False;
                     end if;
                  end if;
               end loop;
               
               if Match then
                  Result.ID := I;
                  Success := True;
                  return;
               end if;
            end if;
         end if;
      end loop;

      -- 3. Not found. RANGE-SPEC ASSERTION: Ensure vault has room!
      -- FIX: Shift tae 1-based logic. Max capacity is Max_Atoms.
      Test_Val := Long_Float(Vault.Count) + 1.0;
      Create (1.0, Long_Float(Max_Atoms), Ival, RS_Stat);
      if not RS_Stat or else not Contains(Ival, Test_Val) then
         return;
      end if;

      -- 4. Register the new Atom
      Vault.Count := Vault.Count + 1;
      Vault.Entries(Vault.Count).Active := True;
      Vault.Entries(Vault.Count).Length := Len;
      
      for J in 1 .. Max_Atom_Length loop
         if J <= Len then
            Vault.Entries(Vault.Count).Name(J) := Name(Name'First + (J - 1));
         else
            Vault.Entries(Vault.Count).Name(J) := ' ';
         end if;
      end loop;

      Result.ID := Vault.Count;
      Success := True;
   end Get_Or_Register_Atom;

   procedure Get_Atom_Name (Vault   : in Lexicon_Vault;
                            Atom    : in ALB_Atom;
                            Name    : out Atom_String;
                            Length  : out Natural;
                            Success : out Boolean) is
      RS_Stat : Boolean;
      Ival    : RS_Interval;
   begin
      Name    := (others => ' ');
      Length  := 0;
      Success := False;

      if Atom.ID = 0 then
         return;
      end if;

      -- RANGE-SPEC ASSERTION: ID maun be strictly within 1 .. Current Vault Count
      -- FIX: Handle Count = 0 or 1 gracefully tae pacify the math vault
      if Vault.Count = 0 then
         return;
      elsif Vault.Count = 1 then
         Scalar (1.0, Ival, RS_Stat);
      else
         Create (1.0, Long_Float(Vault.Count), Ival, RS_Stat);
      end if;

      if not RS_Stat or else not Contains(Ival, Long_Float(Atom.ID)) then
         return;
      end if;

      if Vault.Entries(Atom.ID).Active then
         Name    := Vault.Entries(Atom.ID).Name;
         Length  := Vault.Entries(Atom.ID).Length;
         Success := True;
      end if;
   end Get_Atom_Name;

end Atom_Types;
