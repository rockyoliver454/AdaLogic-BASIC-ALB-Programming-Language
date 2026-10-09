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
with Ada.Unchecked_Conversion;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body ALBA_Audio is

   pragma Linker_Options ("-lkernel32");
   pragma Linker_Options ("-lwinmm");

   use Interfaces;
   use Interfaces.C;
   use Interfaces.C.Strings;
   use type System.Address;
   use type Unsigned_32;
   use type Integer_16;

   subtype C_Int    is Interfaces.C.int;
   subtype Sint16   is Interfaces.Integer_16;
   subtype Uint16   is Interfaces.Unsigned_16;
   subtype Uint32   is Interfaces.Unsigned_32;
   subtype DWORD    is Interfaces.Unsigned_32;
   subtype BOOL     is Interfaces.C.int;
   subtype SDL_Bool is Interfaces.C.int;

   SDL_INIT_AUDIO : constant Uint32 := 16#0000_0010#;
   SDL_AUDIO_S16LE : constant Uint16 := 16#8010#;
   SDL_DEFAULT_PLAYBACK_DEVICE : constant Uint32 := 16#FFFF_FFFF#;

   SND_ASYNC     : constant DWORD := 16#0001#;
   SND_NODEFAULT : constant DWORD := 16#0002#;
   SND_FILENAME  : constant DWORD := 16#0002_0000#;

   Sample_Rate       : constant C_Int := 22_050;
   Max_Audio_Seconds : constant Positive := 8;
   Max_Audio_Samples : constant Positive := Positive (Sample_Rate) * Max_Audio_Seconds;
   Tone_Amplitude    : constant Sint16 := 8_192;
   Twelfth_Root_Of_Two : constant Long_Float := 1.0594630943592953;

   type SDL_AudioSpec is record
      Format   : Uint16 := SDL_AUDIO_S16LE;
      Padding  : Uint16 := 0;
      Channels : C_Int := 1;
      Freq     : C_Int := Sample_Rate;
   end record
     with Convention => C;

   type Sample_Buffer_Array is array (Natural range 0 .. Max_Audio_Samples - 1) of aliased Sint16
     with Component_Size => 16;

   type SDL_Init_Fn is access function (Flags : Uint32) return SDL_Bool
     with Convention => C;
   type SDL_OpenAudioDeviceStream_Fn is access function
     (Devid    : Uint32;
      Spec     : access SDL_AudioSpec;
      Callback : System.Address;
      Userdata : System.Address) return System.Address
     with Convention => C;
   type SDL_PutAudioStreamData_Fn is access function
     (Stream : System.Address;
      Data   : System.Address;
      Length : C_Int) return SDL_Bool
     with Convention => C;
   type SDL_ClearAudioStream_Fn is access function
     (Stream : System.Address) return SDL_Bool
     with Convention => C;
   type SDL_ResumeAudioStreamDevice_Fn is access function
     (Stream : System.Address) return SDL_Bool
     with Convention => C;
   type SDL_DestroyAudioStream_Fn is access procedure
     (Stream : System.Address)
     with Convention => C;

   function To_SDL_Init is new Ada.Unchecked_Conversion (System.Address, SDL_Init_Fn);
   function To_SDL_OpenAudioDeviceStream is new Ada.Unchecked_Conversion
     (System.Address, SDL_OpenAudioDeviceStream_Fn);
   function To_SDL_PutAudioStreamData is new Ada.Unchecked_Conversion
     (System.Address, SDL_PutAudioStreamData_Fn);
   function To_SDL_ClearAudioStream is new Ada.Unchecked_Conversion
     (System.Address, SDL_ClearAudioStream_Fn);
   function To_SDL_ResumeAudioStreamDevice is new Ada.Unchecked_Conversion
     (System.Address, SDL_ResumeAudioStreamDevice_Fn);
   function To_SDL_DestroyAudioStream is new Ada.Unchecked_Conversion
     (System.Address, SDL_DestroyAudioStream_Fn);

   function LoadLibraryA (LpLibFileName : chars_ptr) return System.Address;
   pragma Import (Stdcall, LoadLibraryA, "LoadLibraryA");

   function GetProcAddress
     (HModule    : System.Address;
      LpProcName : chars_ptr) return System.Address;
   pragma Import (Stdcall, GetProcAddress, "GetProcAddress");

   function PlaySoundA
     (pszSound : chars_ptr;
      hmod     : System.Address;
      fdwSound : DWORD) return BOOL;
   pragma Import (Stdcall, PlaySoundA, "PlaySoundA");

   function GetModuleFileNameA
     (hModule    : System.Address;
      lpFilename : chars_ptr;
      nSize      : DWORD) return DWORD;
   pragma Import (Stdcall, GetModuleFileNameA, "GetModuleFileNameA");

   function Executable_Directory return String is
      Blank  : constant String := (1 .. 1_024 => ' ');
      Buffer : chars_ptr := Null_Ptr;
      Len    : DWORD;
   begin
      Buffer := New_String (Blank);
      Len := GetModuleFileNameA (System.Null_Address, Buffer, 1_024);
      if Len = 0 then
         Free (Buffer);
         return "";
      end if;

      declare
         Full : constant String := Value (Buffer, size_t (Len));
         Pos  : Natural := Full'Last;
      begin
         Free (Buffer);

         while Pos >= Full'First loop
            if Full (Pos) = '\' or else Full (Pos) = '/' then
               return Full (Full'First .. Pos);
            end if;
            Pos := Pos - 1;
         end loop;
         return "";
      end;
   exception
      when others =>
         if Buffer /= Null_Ptr then
            Free (Buffer);
         end if;
         return "";
   end Executable_Directory;

   function Is_Absolute_Path (Path : String) return Boolean is
   begin
      if Path'Length = 0 then
         return False;
      end if;

      if Path (Path'First) = '\' or else Path (Path'First) = '/' then
         return True;
      end if;

      return Path'Length >= 2
        and then Path (Path'First + 1) = ':'
        and then Path (Path'First) in 'A' .. 'Z' | 'a' .. 'z';
   end Is_Absolute_Path;

   function Try_Play_Sound (Path : String) return Boolean is
      C_Path : chars_ptr := Null_Ptr;
   begin
      if Path'Length = 0 then
         return False;
      end if;

      if Path'Length >= 2 then
         for I in Path'First .. Path'Last - 1 loop
            if Path (I) = '.' and then Path (I + 1) = '.' then
               return False;
            end if;
         end loop;
      end if;

      C_Path := New_String (Path);
      declare
         Result : constant BOOL :=
           PlaySoundA
             (C_Path,
              System.Null_Address,
              SND_ASYNC or SND_FILENAME or SND_NODEFAULT);
      begin
         Free (C_Path);
         return Result /= 0;
      end;
   exception
      when others =>
         if C_Path /= Null_Ptr then
            Free (C_Path);
         end if;
         return False;
   end Try_Play_Sound;

   procedure Play_Sound_At (Path : String) is
      Exe_Dir : constant String := Executable_Directory;
   begin
      if Path'Length = 0 then
         return;
      end if;

      if Is_Absolute_Path (Path) then
         declare
            Dummy : Boolean := Try_Play_Sound (Path);
         begin
            null;
         end;
         return;
      end if;

      if Try_Play_Sound (Path) then
         return;
      end if;

      if Exe_Dir'Length > 0 then
         if Try_Play_Sound (Exe_Dir & Path) then
            return;
         end if;

         if Try_Play_Sound (Exe_Dir & ".." & "\" & Path) then
            return;
         end if;
      end if;
   end Play_Sound_At;

   SDL_Library : System.Address := System.Null_Address;
   SDL_Bind_Attempted : Boolean := False;
   SDL_Ready   : Boolean := False;
   Music_Stream : System.Address := System.Null_Address;

   SDL_Init_Ptr                  : SDL_Init_Fn := null;
   SDL_OpenAudioDeviceStream_Ptr : SDL_OpenAudioDeviceStream_Fn := null;
   SDL_PutAudioStreamData_Ptr    : SDL_PutAudioStreamData_Fn := null;
   SDL_ClearAudioStream_Ptr      : SDL_ClearAudioStream_Fn := null;
   SDL_ResumeAudioStreamDevice_Ptr : SDL_ResumeAudioStreamDevice_Fn := null;
   SDL_DestroyAudioStream_Ptr    : SDL_DestroyAudioStream_Fn := null;

   Audio_Spec : aliased SDL_AudioSpec :=
     (Format => SDL_AUDIO_S16LE,
      Padding => 0,
      Channels => 1,
      Freq => Sample_Rate);
   Music_Buffer : aliased Sample_Buffer_Array := (others => 0);
   Used_Samples : Natural := 0;

   procedure Ignore (Value : C_Int) is
   begin
      null;
   end Ignore;

   function Min_Natural (Left, Right : Natural) return Natural is
   begin
      if Left < Right then
         return Left;
      end if;
      return Right;
   end Min_Natural;

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
      elsif Freq > 32_767.0 then
         return 32_767;
      else
         return Natural (Integer (Freq + 0.5));
      end if;
   end Frequency_For_Note;

   function Try_Load_SDL (Path : String) return System.Address is
      C_Path : chars_ptr := Null_Ptr;
      Value  : System.Address := System.Null_Address;
   begin
      C_Path := New_String (Path);
      Value := LoadLibraryA (C_Path);
      Free (C_Path);
      return Value;
   end Try_Load_SDL;

   function Load_Symbol (Name : String) return System.Address is
      C_Name : chars_ptr := Null_Ptr;
      Value  : System.Address := System.Null_Address;
   begin
      if SDL_Library = System.Null_Address then
         return System.Null_Address;
      end if;

      C_Name := New_String (Name);
      Value := GetProcAddress (SDL_Library, C_Name);
      Free (C_Name);
      return Value;
   end Load_Symbol;

   procedure Bind_SDL is
   begin
      if SDL_Bind_Attempted then
         return;
      end if;
      SDL_Bind_Attempted := True;

      SDL_Library := Try_Load_SDL ("SDL3.dll");
      if SDL_Library = System.Null_Address then
         SDL_Library := Try_Load_SDL ("..\obj\SDL3.dll");
      end if;
      if SDL_Library = System.Null_Address then
         SDL_Library := Try_Load_SDL ("obj\SDL3.dll");
      end if;
      if SDL_Library = System.Null_Address then
         return;
      end if;

      SDL_Init_Ptr := To_SDL_Init (Load_Symbol ("SDL_Init"));
      SDL_OpenAudioDeviceStream_Ptr :=
        To_SDL_OpenAudioDeviceStream (Load_Symbol ("SDL_OpenAudioDeviceStream"));
      SDL_PutAudioStreamData_Ptr :=
        To_SDL_PutAudioStreamData (Load_Symbol ("SDL_PutAudioStreamData"));
      SDL_ClearAudioStream_Ptr :=
        To_SDL_ClearAudioStream (Load_Symbol ("SDL_ClearAudioStream"));
      SDL_ResumeAudioStreamDevice_Ptr :=
        To_SDL_ResumeAudioStreamDevice (Load_Symbol ("SDL_ResumeAudioStreamDevice"));
      SDL_DestroyAudioStream_Ptr :=
        To_SDL_DestroyAudioStream (Load_Symbol ("SDL_DestroyAudioStream"));

      SDL_Ready :=
        SDL_Init_Ptr /= null
        and then SDL_OpenAudioDeviceStream_Ptr /= null
        and then SDL_PutAudioStreamData_Ptr /= null
        and then SDL_ClearAudioStream_Ptr /= null
        and then SDL_ResumeAudioStreamDevice_Ptr /= null
        and then SDL_DestroyAudioStream_Ptr /= null;
   end Bind_SDL;

   function Ensure_Music_Stream return Boolean is
   begin
      if Music_Stream /= System.Null_Address then
         return True;
      end if;

      Bind_SDL;
      if not SDL_Ready then
         return False;
      end if;

      Ignore (SDL_Init_Ptr (SDL_INIT_AUDIO));

      Music_Stream :=
        SDL_OpenAudioDeviceStream_Ptr
          (SDL_DEFAULT_PLAYBACK_DEVICE,
           Audio_Spec'Access,
           System.Null_Address,
           System.Null_Address);

      if Music_Stream = System.Null_Address then
         return False;
      end if;

      Ignore (SDL_ResumeAudioStreamDevice_Ptr (Music_Stream));
      return True;
   end Ensure_Music_Stream;

   procedure Append_Sample (Value : Sint16) is
   begin
      if Used_Samples < Max_Audio_Samples then
         Music_Buffer (Used_Samples) := Value;
         Used_Samples := Used_Samples + 1;
      end if;
   end Append_Sample;

   procedure Append_Silence (Duration : Natural) is
      Count : Natural := (Natural (Sample_Rate) * Duration) / 1_000;
   begin
      if Count = 0 then
         Count := 1;
      end if;

      for I in 1 .. Count loop
         exit when Used_Samples >= Max_Audio_Samples;
         Append_Sample (0);
      end loop;
   end Append_Silence;

   procedure Append_Tone
     (Freq_Hz  : Natural;
      Duration : Natural;
      Is_Rest  : Boolean)
   is
      Count       : Natural := (Natural (Sample_Rate) * Duration) / 1_000;
      Period      : Natural := 1;
      Half_Period : Natural := 1;
   begin
      if Count = 0 then
         Count := 1;
      end if;

      if Is_Rest or else Freq_Hz = 0 then
         Append_Silence (Duration);
         return;
      end if;

      if Freq_Hz > 0 then
         Period := Natural (Sample_Rate) / Freq_Hz;
         if Period = 0 then
            Period := 1;
         end if;
         Half_Period := Natural'Max (1, Period / 2);
      end if;

      for I in 0 .. Count - 1 loop
         exit when Used_Samples >= Max_Audio_Samples;
         if (I mod Period) < Half_Period then
            Append_Sample (Tone_Amplitude);
         else
            Append_Sample (-Tone_Amplitude);
         end if;
      end loop;
   end Append_Tone;

   procedure Queue_Music_Buffer is
      Byte_Count : constant C_Int := C_Int (Used_Samples * 2);
   begin
      if Used_Samples = 0 then
         return;
      end if;

      if not Ensure_Music_Stream then
         return;
      end if;

      Ignore (SDL_ClearAudioStream_Ptr (Music_Stream));
      Ignore
        (SDL_PutAudioStreamData_Ptr
           (Music_Stream,
            Music_Buffer (0)'Address,
            Byte_Count));
      Ignore (SDL_ResumeAudioStreamDevice_Ptr (Music_Stream));
   end Queue_Music_Buffer;

   procedure Play_Sound (Path : in String) is
   begin
      Play_Sound_At (Path);
   end Play_Sound;

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
   begin
      if MML'Length = 0 then
         return;
      end if;

      Used_Samples := 0;
      Cursor := MML'First;

      while Cursor <= MML'Last loop
         declare
            Ch : constant Character := To_Upper (MML (Cursor));
         begin
            case Ch is
               when ' ' | Character'Val (9) | Character'Val (10)
                 | Character'Val (13) | ',' =>
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
                     Gap_Dur     : Natural := 0;
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

                     Total_Dur := Duration_Ms (Current_Tempo, Note_Length, Note_Dotted);

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

                     if Total_Dur > 24 then
                        Gap_Dur := Min_Natural (10, Total_Dur / 8);
                     end if;

                     if Note_Char = 'P' or else Note_Char = 'R' then
                        Append_Silence (Total_Dur);
                     else
                        Append_Tone
                          (Frequency_For_Note (Note_Base (Note_Char) + Accidental, Current_Octave),
                           Total_Dur - Gap_Dur,
                           False);
                        if Gap_Dur > 0 then
                           Append_Silence (Gap_Dur);
                        end if;
                     end if;
                  end;

               when others =>
                  Cursor := Cursor + 1;
            end case;
         end;
      end loop;

      Queue_Music_Buffer;
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

   procedure Shutdown is
   begin
      if Music_Stream /= System.Null_Address and then SDL_DestroyAudioStream_Ptr /= null then
         SDL_DestroyAudioStream_Ptr.all (Music_Stream);
         Music_Stream := System.Null_Address;
      end if;
      Ignore (PlaySoundA (Null_Ptr, System.Null_Address, 0));
   end Shutdown;

end ALBA_Audio;
