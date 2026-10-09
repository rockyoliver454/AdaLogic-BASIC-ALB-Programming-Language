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

pragma SPARK_Mode (Off);

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;
with Interfaces.C;

package body ALB_Audio is

   pragma Linker_Options ("-lkernel32");

   subtype BOOL is Interfaces.C.int;

   type DWORD is mod 2 ** 32;
   for DWORD'Size use 32;

   function Beep
     (DwFreq     : DWORD;
      DwDuration : DWORD) return BOOL;
   pragma Import (Stdcall, Beep, "Beep");

   procedure Sleep (DwMilliseconds : DWORD);
   pragma Import (Stdcall, Sleep, "Sleep");

   Twelfth_Root_Of_Two : constant Long_Float := 1.0594630943592953;

   function To_Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
   end To_Upper;

   function Note_Base (C : Character) return Integer is
   begin
      case C is
         when 'C' => return 0;
         when 'D' => return 2;
         when 'E' => return 4;
         when 'F' => return 5;
         when 'G' => return 7;
         when 'A' => return 9;
         when 'B' => return 11;
         when others => return 0;
      end case;
   end Note_Base;

   function Duration_Ms
     (Tempo  : Natural;
      Length : Natural;
      Dotted : Boolean) return Natural
   is
      Base : Long_Float := 0.0;
   begin
      if Tempo = 0 or else Length = 0 then
         return 125;
      end if;

      Base :=
        (60_000.0 / Long_Float (Tempo))
        * (4.0 / Long_Float (Length));

      if Dotted then
         Base := Base * 1.5;
      end if;

      if Base < 1.0 then
         return 1;
      end if;

      return Natural (Integer (Base + 0.5));
   end Duration_Ms;

   function Frequency_For_Note
     (Note_Class : Integer;
      Octave     : Integer) return Natural
   is
      Semitones : constant Integer := ((Octave - 4) * 12) + (Note_Class - 9);
      Freq      : Long_Float := 440.0;
   begin
      if Semitones > 0 then
         for I in 1 .. Semitones loop
            Freq := Freq * Twelfth_Root_Of_Two;
         end loop;
      elsif Semitones < 0 then
         for I in 1 .. (-Semitones) loop
            Freq := Freq / Twelfth_Root_Of_Two;
         end loop;
      end if;

      if Freq < 37.0 then
         return 37;
      elsif Freq > 32767.0 then
         return 32767;
      else
         return Natural (Integer (Freq + 0.5));
      end if;
   end Frequency_For_Note;

   procedure Play_Music (MML : in String) is
      Cursor         : Natural := 0;
      Current_Octave : Integer := 4;
      Default_Length : Natural := 4;
      Current_Tempo  : Natural := 120;

      function Parse_Number return Natural is
         Value : Natural := 0;
      begin
         while Cursor <= MML'Last
           and then MML (Cursor) in '0' .. '9'
         loop
            if Value > (Natural'Last / 10) then
               Value := Natural'Last / 2;
            else
               Value :=
                 (Value * 10)
                 + Natural (Character'Pos (MML (Cursor)) - Character'Pos ('0'));
            end if;
            Cursor := Cursor + 1;
         end loop;

         return Value;
      end Parse_Number;

      procedure Play_One
        (Freq_Hz  : in Natural;
         Duration : in Natural;
         Is_Rest  : in Boolean)
      is
         Tone_Duration  : Natural := Duration;
         Gap_Duration   : Natural := 0;
         Result_Ignored : BOOL := 0;
      begin
         if Tone_Duration = 0 then
            Tone_Duration := 1;
         end if;

         if Tone_Duration > 24 then
            Gap_Duration := Natural'Min (10, Tone_Duration / 8);
            Tone_Duration := Tone_Duration - Gap_Duration;
         end if;

         if Is_Rest then
            Sleep (DWORD (Duration));
         else
            Result_Ignored := Beep (DWORD (Freq_Hz), DWORD (Tone_Duration));
            if Gap_Duration > 0 then
               Sleep (DWORD (Gap_Duration));
            end if;
         end if;
      end Play_One;
   begin
      if MML'Length = 0 then
         return;
      end if;

      Cursor := MML'First;

      while Cursor <= MML'Last loop
         declare
            Ch : constant Character := To_Upper (MML (Cursor));
         begin
            case Ch is
               when ' ' | Character'Val (9) | Character'Val (10)
                 | Character'Val (13) | ','
               =>
                  Cursor := Cursor + 1;

               when ';' =>
                  Cursor := Cursor + 1;
                  while Cursor <= MML'Last
                    and then MML (Cursor) /= Character'Val (10)
                    and then MML (Cursor) /= Character'Val (13)
                  loop
                     Cursor := Cursor + 1;
                  end loop;

               when 'O' =>
                  Cursor := Cursor + 1;
                  declare
                     Parsed : constant Natural := Parse_Number;
                  begin
                     Current_Octave := Integer (Parsed);
                     if Current_Octave < 0 then
                        Current_Octave := 0;
                     elsif Current_Octave > 8 then
                        Current_Octave := 8;
                     end if;
                  end;

               when 'L' =>
                  Cursor := Cursor + 1;
                  declare
                     Parsed : constant Natural := Parse_Number;
                  begin
                     if Parsed > 0 then
                        Default_Length := Parsed;
                     end if;
                  end;

               when 'T' =>
                  Cursor := Cursor + 1;
                  declare
                     Parsed : constant Natural := Parse_Number;
                  begin
                     if Parsed > 0 then
                        Current_Tempo := Parsed;
                     end if;
                  end;

               when '>' =>
                  Cursor := Cursor + 1;
                  if Current_Octave < 8 then
                     Current_Octave := Current_Octave + 1;
                  end if;

               when '<' =>
                  Cursor := Cursor + 1;
                  if Current_Octave > 0 then
                     Current_Octave := Current_Octave - 1;
                  end if;

               when 'A' | 'B' | 'C' | 'D' | 'E' | 'F' | 'G' | 'P' | 'R' =>
                  declare
                     Note_Char   : constant Character := Ch;
                     Accidental  : Integer := 0;
                     Note_Length : Natural := 0;
                     Note_Dotted : Boolean := False;
                     Total_Dur   : Natural := 0;
                  begin
                     Cursor := Cursor + 1;

                     if Cursor <= MML'Last then
                        if MML (Cursor) = '#'
                          or else MML (Cursor) = '+'
                        then
                           Accidental := 1;
                           Cursor := Cursor + 1;
                        elsif MML (Cursor) = '-' then
                           Accidental := -1;
                           Cursor := Cursor + 1;
                        end if;
                     end if;

                     Note_Length := Parse_Number;
                     if Note_Length = 0 then
                        Note_Length := Default_Length;
                     end if;
                     if Note_Length = 0 then
                        Note_Length := 4;
                     end if;

                     if Cursor <= MML'Last
                       and then MML (Cursor) = '.'
                     then
                        Note_Dotted := True;
                        Cursor := Cursor + 1;
                     end if;

                     Total_Dur :=
                       Duration_Ms (Current_Tempo, Note_Length, Note_Dotted);

                     while Cursor <= MML'Last
                       and then MML (Cursor) = '&'
                     loop
                        Cursor := Cursor + 1;

                        declare
                           Tie_Length : Natural := Parse_Number;
                           Tie_Dot    : Boolean := False;
                        begin
                           if Tie_Length = 0 then
                              Tie_Length := Default_Length;
                           end if;
                           if Tie_Length = 0 then
                              Tie_Length := 4;
                           end if;

                           if Cursor <= MML'Last
                             and then MML (Cursor) = '.'
                           then
                              Tie_Dot := True;
                              Cursor := Cursor + 1;
                           end if;

                           Total_Dur :=
                             Total_Dur
                             + Duration_Ms (Current_Tempo, Tie_Length, Tie_Dot);
                        end;
                     end loop;

                     if Note_Char = 'P' or else Note_Char = 'R' then
                        Play_One (0, Total_Dur, True);
                     else
                        Play_One
                          (Frequency_For_Note (Note_Base (Note_Char) + Accidental, Current_Octave),
                           Total_Dur,
                           False);
                     end if;
                  end;

               when others =>
                  Cursor := Cursor + 1;
            end case;
         end;
      end loop;
   end Play_Music;

   procedure Play_Music_From (Path : in String) is
      File  : File_Type;
      Whole : Unbounded_String := To_Unbounded_String ("");
   begin
      if Path'Length = 0 then
         return;
      end if;

      Open (File, In_File, Path);
      while not End_Of_File (File) loop
         declare
            Line : constant String := Get_Line (File);
         begin
            if Length (Whole) > 0 then
               Append (Whole, Character'Val (10));
            end if;
            Append (Whole, Line);
         end;
      end loop;
      Close (File);
      Play_Music (To_String (Whole));
   exception
      when others =>
         null;
   end Play_Music_From;

end ALB_Audio;
