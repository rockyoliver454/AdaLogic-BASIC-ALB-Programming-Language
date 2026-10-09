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

with Ada.Text_IO;
with ALB_Types; use ALB_Types;
with Opcodes;   use Opcodes;


package body Emit_Native_NASM is

   --  GameDeck-ALB weaves exceed 1 MiB of generated NASM text. Owner raised
   --  this vault 2026-09-06 so the cartridge host can keep growing.
   Max_Buffer_Size : constant Natural := 8_388_608;
   String_Counter  : Natural := 0;

   Global_Buffer : String (1 .. Max_Buffer_Size) := (others => ' ');
   Global_Len    : Natural := 0;

   Main_Buffer : String (1 .. Max_Buffer_Size) := (others => ' ');
   Main_Len    : Natural := 0;
   
   Max_Try_Depth      : constant Natural := 256;
   Max_Foreach_Depth  : constant Natural := 128;

   type Try_ID_Vault is array (1 .. Max_Try_Depth) of Natural;
   type Foreach_ID_Vault is array (1 .. Max_Foreach_Depth) of Natural;

   Try_Counter        : Natural := 0;
   Try_Depth          : Natural := 0;
   Try_Stack          : Try_ID_Vault := (others => 0);

   Foreach_Counter    : Natural := 0;
   Foreach_Depth      : Natural := 0;
   Foreach_Stack      : Foreach_ID_Vault := (others => 0);
   
   Temporal_Label_Counter : Natural := 0;
   Contract_Check_Counter : Natural := 0;
   SDL3_Runtime_Emitted   : Boolean := False;
   NASM_Window_Requested  : Boolean := False;

   Max_Local_Name_Entries : constant Natural := 16384;
   Max_Local_Name_Length  : constant Natural := 320;

   type Local_Name_Record is record
      Raw_Len      : Natural := 0;
      Storage_Len  : Natural := 0;
      Raw_Name     : String (1 .. Max_Local_Name_Length) := (others => ' ');
      Storage_Name : String (1 .. Max_Local_Name_Length) := (others => ' ');
   end record;

   type Local_Name_Vault is
     array (1 .. Max_Local_Name_Entries) of Local_Name_Record;

   Current_Subprogram_Len  : Natural := 0;
   Current_Subprogram_Name : String (1 .. Max_Local_Name_Length) := (others => ' ');
   Local_Name_Count        : Natural := 0;
   Local_Names             : Local_Name_Vault;

   procedure Append (Str : String; Success : out Boolean);

   function Is_Name_Char (Ch : Character) return Boolean is
   begin
      return
        (Ch in 'a' .. 'z')
        or else (Ch in 'A' .. 'Z')
        or else (Ch in '0' .. '9')
        or else Ch = '_';
   end Is_Name_Char;

   procedure Reset_Local_Name_State is
   begin
      Current_Subprogram_Len := 0;
      Current_Subprogram_Name := (others => ' ');
      Local_Name_Count := 0;
      Local_Names := (others => (others => <>));
   end Reset_Local_Name_State;

   procedure Begin_Subprogram_Scope (Name : String) is
   begin
      Reset_Local_Name_State;
      if Name'Length <= Current_Subprogram_Name'Length then
         Current_Subprogram_Name (1 .. Name'Length) := Name;
         Current_Subprogram_Len := Name'Length;
      end if;
   end Begin_Subprogram_Scope;

   procedure End_Subprogram_Scope is
   begin
      Reset_Local_Name_State;
   end End_Subprogram_Scope;

   function Find_Local_Name_Index (Name : String) return Natural is
   begin
      for I in 1 .. Local_Name_Count loop
         if Local_Names (I).Raw_Len = Name'Length
           and then Local_Names (I).Raw_Name (1 .. Name'Length) = Name
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Local_Name_Index;

   function Ensure_Local_Storage_Name (Name : String) return String is
      Existing : constant Natural := Find_Local_Name_Index (Name);
   begin
      if Current_Subprogram_Len = 0 then
         return Name;
      end if;

      if Existing > 0 then
         return
           Local_Names (Existing).Storage_Name
             (1 .. Local_Names (Existing).Storage_Len);
      end if;

      if Local_Name_Count >= Max_Local_Name_Entries then
         return Name;
      end if;

      declare
         Storage_Name : constant String :=
           Current_Subprogram_Name (1 .. Current_Subprogram_Len) & "__" & Name;
         Slot         : constant Natural := Local_Name_Count + 1;
      begin
         if Name'Length > Max_Local_Name_Length
           or else Storage_Name'Length > Max_Local_Name_Length
         then
            return Name;
         end if;

         Local_Name_Count := Slot;
         Local_Names (Slot).Raw_Len := Name'Length;
         Local_Names (Slot).Raw_Name (1 .. Name'Length) := Name;
         Local_Names (Slot).Storage_Len := Storage_Name'Length;
         Local_Names (Slot).Storage_Name (1 .. Storage_Name'Length) :=
           Storage_Name;
         return Storage_Name;
      end;
   end Ensure_Local_Storage_Name;

   function Resolve_Storage_Name (Name : String) return String is
      Existing : constant Natural := Find_Local_Name_Index (Name);
   begin
      if Existing > 0 then
         return
           Local_Names (Existing).Storage_Name
             (1 .. Local_Names (Existing).Storage_Len);
      else
         return Name;
      end if;
   end Resolve_Storage_Name;

   procedure Append_Local_Aware (Text : String; Success : out Boolean) is
      S : Boolean := True;
      I : Integer := Text'First;
   begin
      if Current_Subprogram_Len = 0 or else Local_Name_Count = 0 then
         Append (Text, S);
         Success := S;
         return;
      end if;

      while S and then I <= Text'Last loop
         if Is_Name_Char (Text (I)) then
            declare
               J : Integer := I;
            begin
               while J <= Text'Last and then Is_Name_Char (Text (J)) loop
                  J := J + 1;
               end loop;

               declare
                  Token    : constant String := Text (I .. J - 1);
                  Resolved : constant String := Resolve_Storage_Name (Token);
               begin
                  Append (Resolved, S);
               end;

               I := J;
            end;
         else
            Append (Text (I .. I), S);
            I := I + 1;
         end if;
      end loop;

      Success := S;
   end Append_Local_Aware;



   procedure Append (Str : String; Success : out Boolean) is
   begin
      if Current_Buffer = Buffer_Global then
         if Global_Len + Str'Length <= Max_Buffer_Size then
            Global_Buffer (Global_Len + 1 .. Global_Len + Str'Length) := Str;
            Global_Len := Global_Len + Str'Length;
            Success := True;
         else
            Success := False;
         end if;
      else
         if Main_Len + Str'Length <= Max_Buffer_Size then
            Main_Buffer (Main_Len + 1 .. Main_Len + Str'Length) := Str;
            Main_Len := Main_Len + Str'Length;
            Success := True;
         else
            Success := False;
         end if;
      end if;
   end Append;

   function Reversible_Storage_Bytes (Tag : ALB_Type_Tag) return Natural is
   begin
      case Tag is
         when Type_U8 | Type_HW8 | Type_Boolean =>
            return 1;

         when Type_U16 | Type_HW16 =>
            return 2;

         when Type_U32 | Type_S32 | Type_HW32 =>
            return 4;

         when others =>
            return 8;
      end case;
   end Reversible_Storage_Bytes;

   procedure Init_Emitter (Success : out Boolean) is
   begin
      Global_Len := 0;
      Main_Len := 0;
      Indent_Level := 0;
      In_Global_Scope := True;
      Current_Buffer := Buffer_Global;
      NASM_Emitter_Ready := True;
      String_Counter := 0; -- DA NEW FIX: Reset the counter for fresh runs!
      Try_Counter := 0;
      Try_Depth := 0;
      Try_Stack := (others => 0);
      Foreach_Counter := 0;
      Foreach_Depth := 0;
      Foreach_Stack := (others => 0);
      Temporal_Label_Counter := 0;
      SDL3_Runtime_Emitted := False;
      NASM_Window_Requested := False;
      Current_Format := Format_PE64_Console;
      Reset_Local_Name_State;

      Success := True;
   end Init_Emitter;

   procedure Set_Active_Buffer (Target : Buffer_Target) is
   begin
      Current_Buffer := Target;
   end Set_Active_Buffer;

   procedure Set_Output_Format
     (Format : NASM_Output_Format)
   is
   begin
      Current_Format := Format;
   end Set_Output_Format;

   procedure Flush_To_File (File_Path : String; Success : out Boolean) is
      File : Ada.Text_IO.File_Type;
   begin
      Success := True;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, File_Path);
         Ada.Text_IO.Put (File, Global_Buffer (1 .. Global_Len));
         Ada.Text_IO.Put (File, Main_Buffer (1 .. Main_Len));
         Ada.Text_IO.Close (File);
      exception
         when others =>
            Success := False;
      end;
   end Flush_To_File;

   procedure Emit_SDL_Decl
     (Stem : String; Symbol : String; Success : in out Boolean)
   is
   begin
      if Success then
         Append ("  ALB_SDL_" & Stem & " dq 0", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
      if Success then
         Append ("  ALB_SDL_" & Stem & "_Name db '" & Symbol & "',0", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
   end Emit_SDL_Decl;

   procedure Emit_SDL_Bind (Stem : String; Success : in out Boolean) is
   begin
      if Success then
         Append ("  lea rcx, [rel ALB_SDL_" & Stem & "]", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
      if Success then
         Append ("  lea rdx, [rel ALB_SDL_" & Stem & "_Name]", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
      if Success then
         Append ("  call ALB_SDL_Load_Proc", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
      if Success then
         Append ("  test rax, rax", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
      if Success then
         Append ("  jz .fail", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
   end Emit_SDL_Bind;

   procedure Emit_SDL_Bind_Optional
     (Stem : String; Success : in out Boolean)
   is
   begin
      if Success then
         Append ("  lea rcx, [rel ALB_SDL_" & Stem & "]", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
      if Success then
         Append ("  lea rdx, [rel ALB_SDL_" & Stem & "_Name]", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
      if Success then
         Append ("  call ALB_SDL_Load_Proc", Success);
      end if;
      if Success then
         Emit_Newline (Success);
      end if;
   end Emit_SDL_Bind_Optional;

   procedure Emit_SDL3_Runtime_Support (Success : out Boolean) is
      S       : Boolean := True;
      Old_Buf : constant Buffer_Target := Current_Buffer;

      procedure Line (Text : String) is
      begin
         Append (Text, S);
         Emit_Newline (S);
      end Line;
   begin
      if SDL3_Runtime_Emitted then
         Success := True;
         return;
      end if;

      Current_Buffer := Buffer_Global;
      Line ("  ALB_SDL_Loaded dq 0");
      Line ("  ALB_SDL3_Lib db 'SDL3.dll',0");
      Line ("  ALB_SDL_Bind_Fail db '[ALB FATAL] SDL3 bind failed',0");
      Line ("  ALB_Music_Stream dq 0");
      Line ("  ALB_Music_Audio_Ready dq 0");
      Line ("  ALB_Music_AudioSpec dw 0x8010, 0");
      Line ("  ALB_Music_AudioChannels dd 1");
      Line ("  ALB_Music_AudioFreq dd 22050");

      Emit_SDL_Decl ("Init", "SDL_Init", S);
      Emit_SDL_Decl ("Quit", "SDL_Quit", S);
      Emit_SDL_Decl ("CreateWindowAndRenderer", "SDL_CreateWindowAndRenderer", S);
      Emit_SDL_Decl ("GetError", "SDL_GetError", S);
      Emit_SDL_Decl ("PollEvent", "SDL_PollEvent", S);
      Emit_SDL_Decl ("GetKeyboardState", "SDL_GetKeyboardState", S);
      Emit_SDL_Decl ("GetMouseState", "SDL_GetMouseState", S);
      Emit_SDL_Decl ("GetCurrentRenderOutputSize", "SDL_GetCurrentRenderOutputSize", S);
      Emit_SDL_Decl ("SetWindowResizable", "SDL_SetWindowResizable", S);
      Emit_SDL_Decl ("SetWindowFullscreen", "SDL_SetWindowFullscreen", S);
      Emit_SDL_Decl ("SetRenderDrawColor", "SDL_SetRenderDrawColor", S);
      Emit_SDL_Decl ("SetRenderScale", "SDL_SetRenderScale", S);
      Emit_SDL_Decl ("SetRenderLogicalPresentation", "SDL_SetRenderLogicalPresentation", S);
      Emit_SDL_Decl ("RenderClear", "SDL_RenderClear", S);
      Emit_SDL_Decl ("RenderPresent", "SDL_RenderPresent", S);
      Emit_SDL_Decl ("DestroyRenderer", "SDL_DestroyRenderer", S);
      Emit_SDL_Decl ("DestroyWindow", "SDL_DestroyWindow", S);
      Emit_SDL_Decl ("RenderRect", "SDL_RenderRect", S);
      Emit_SDL_Decl ("RenderFillRect", "SDL_RenderFillRect", S);
      Emit_SDL_Decl ("RenderLine", "SDL_RenderLine", S);
      Emit_SDL_Decl ("RenderPoint", "SDL_RenderPoint", S);
      Emit_SDL_Decl ("RenderDebugText", "SDL_RenderDebugText", S);
      Emit_SDL_Decl ("SetRenderViewport", "SDL_SetRenderViewport", S);
      Emit_SDL_Decl ("SetRenderClipRect", "SDL_SetRenderClipRect", S);
      Emit_SDL_Decl ("SetRenderDrawBlendMode", "SDL_SetRenderDrawBlendMode", S);
      Emit_SDL_Decl ("RenderReadPixels", "SDL_RenderReadPixels", S);
      Emit_SDL_Decl ("ReadSurfacePixel", "SDL_ReadSurfacePixel", S);
      Emit_SDL_Decl ("DestroySurface", "SDL_DestroySurface", S);
      Emit_SDL_Decl ("Delay", "SDL_Delay", S);
      Emit_SDL_Decl ("RenderGeometryRaw", "SDL_RenderGeometryRaw", S);
      Emit_SDL_Decl ("OpenAudioDeviceStream", "SDL_OpenAudioDeviceStream", S);
      Emit_SDL_Decl ("PutAudioStreamData", "SDL_PutAudioStreamData", S);
      Emit_SDL_Decl ("ClearAudioStream", "SDL_ClearAudioStream", S);
      Emit_SDL_Decl ("ResumeAudioStreamDevice", "SDL_ResumeAudioStreamDevice", S);
      Emit_SDL_Decl ("DestroyAudioStream", "SDL_DestroyAudioStream", S);

      Current_Buffer := Buffer_Main;

      Line ("  jmp alb_sdl3_runtime_resume");
      Emit_Newline (S);

      Line ("ALB_SDL_Load_Proc:");
      Line ("  sub rsp, 40");
      Line ("  mov qword [rsp + 24], rcx");
      Line ("  mov qword [rsp + 32], rdx");
      Line ("  lea rcx, [rel ALB_SDL3_Lib]");
      Line ("  mov rdx, qword [rsp + 32]");
      Line ("  call ALB_Load_Foreign_Symbol");
      Line ("  mov rcx, qword [rsp + 24]");
      Line ("  mov qword [rcx], rax");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Init_SDL3:");
      Line ("  sub rsp, 40");
      Line ("  cmp qword [rel ALB_SDL_Loaded], 0");
      Line ("  jne .ok");
      Emit_SDL_Bind ("Init", S);
      Emit_SDL_Bind ("Quit", S);
      Emit_SDL_Bind ("CreateWindowAndRenderer", S);
      Emit_SDL_Bind ("GetError", S);
      Emit_SDL_Bind ("PollEvent", S);
      Emit_SDL_Bind ("GetKeyboardState", S);
      Emit_SDL_Bind ("GetMouseState", S);
      Emit_SDL_Bind ("GetCurrentRenderOutputSize", S);
      Emit_SDL_Bind_Optional ("SetWindowResizable", S);
      Emit_SDL_Bind_Optional ("SetWindowFullscreen", S);
      Emit_SDL_Bind ("SetRenderDrawColor", S);
      Emit_SDL_Bind_Optional ("SetRenderScale", S);
      Emit_SDL_Bind_Optional ("SetRenderLogicalPresentation", S);
      Emit_SDL_Bind ("RenderClear", S);
      Emit_SDL_Bind ("RenderPresent", S);
      Emit_SDL_Bind ("DestroyRenderer", S);
      Emit_SDL_Bind ("DestroyWindow", S);
      Emit_SDL_Bind ("RenderRect", S);
      Emit_SDL_Bind ("RenderFillRect", S);
      Emit_SDL_Bind ("RenderLine", S);
      Emit_SDL_Bind ("RenderPoint", S);
      Emit_SDL_Bind ("RenderDebugText", S);
      Emit_SDL_Bind ("SetRenderViewport", S);
      Emit_SDL_Bind ("SetRenderClipRect", S);
      Emit_SDL_Bind ("SetRenderDrawBlendMode", S);
      Emit_SDL_Bind ("RenderReadPixels", S);
      Emit_SDL_Bind ("ReadSurfacePixel", S);
      Emit_SDL_Bind ("DestroySurface", S);
      Emit_SDL_Bind ("Delay", S);
      Emit_SDL_Bind ("RenderGeometryRaw", S);
      Emit_SDL_Bind_Optional ("OpenAudioDeviceStream", S);
      Emit_SDL_Bind_Optional ("PutAudioStreamData", S);
      Emit_SDL_Bind_Optional ("ClearAudioStream", S);
      Emit_SDL_Bind_Optional ("ResumeAudioStreamDevice", S);
      Emit_SDL_Bind_Optional ("DestroyAudioStream", S);
      Line ("  mov qword [rel ALB_SDL_Loaded], 1");
      Line (".ok:");
      Line ("  mov eax, 1");
      Line ("  add rsp, 40");
      Line ("  ret");
      Line (".fail:");
      Line ("  xor eax, eax");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("alb_sdl3_runtime_resume:");

      Current_Buffer := Old_Buf;
      SDL3_Runtime_Emitted := S;
      Success := S;
   end Emit_SDL3_Runtime_Support;

   procedure Emit_Program_Start (Program_Name : String; Success : out Boolean)
   is
      S : Boolean;
      procedure Line (Text : String) is
      begin
         Append (Text, S);
         Emit_Newline (S);
      end Line;
   begin
      Current_Buffer := Buffer_Global;
      Append
        ("; ==========================================================", S);
      Emit_Newline (S);
      Append
        ("; GENERATED BY ADALOGIC BASIC (ALB) TRANSPILER              ", S);
      Emit_Newline (S);
      if Current_Format = Format_PE64_DLL then
         Append
           ("; TARGET: x64 NASM (PE64 DLL Shared Library)                ", S);
      else
         Append
           ("; TARGET: x64 NASM (Bare-Metal PE Executable)               ", S);
      end if;
      Emit_Newline (S);
      Append
        ("; ==========================================================", S);
      Emit_Newline (S);
      -- Win64 via nasm -f win64; format intent recorded as comment only.
      Append ("bits 64", S);
      Emit_Newline (S);
      Append ("default rel", S);
      Emit_Newline (S);
      if Current_Format = Format_PE64_DLL then
         Append ("; Output intent: PE64 DLL (nasm -f win64)", S);
      elsif Current_Format = Format_PE64_GUI then
         Append ("; Output intent: PE64 GUI (nasm -f win64)", S);
      else
         Append ("; Output intent: PE64 Console (nasm -f win64)", S);
      end if;
      Emit_Newline (S);
      Append ("global start", S);
      Emit_Newline (S);
      Append ("%include ""win64nasm.inc""", S);
      Emit_Newline (S);
      Emit_Newline (S);

      -- Typecast strippers (NASM doesn't need U64(...) around literals)
      Append ("%define U8", S);
      Emit_Newline (S);
      Append ("%define U16", S);
      Emit_Newline (S);
      Append ("%define U32", S);
      Emit_Newline (S);
      Append ("%define U64", S);
      Emit_Newline (S);
      Append ("%define S32", S);
      Emit_Newline (S);
      Append ("%define F64", S);
      Emit_Newline (S);
      Append ("%define HW8", S);
      Emit_Newline (S);
      Emit_Newline (S);

      Append ("; --- ALB HARDENED MACROS ---", S);
      Emit_Newline (S);
      Append ("%macro ALB_MASK_OP 4", S);
      Emit_Newline (S);
      Append ("  mov rax, %2", S);
      Emit_Newline (S);
      Append ("  neg rax", S);
      Emit_Newline (S);
      Append ("  mov rbx, %3", S);
      Emit_Newline (S);
      Append ("  and rbx, rax", S);
      Emit_Newline (S);
      Append ("  not rax", S);
      Emit_Newline (S);
      Append ("  mov rcx, %4", S);
      Emit_Newline (S);
      Append ("  and rcx, rax", S);
      Emit_Newline (S);
      Append ("  or rbx, rcx", S);
      Emit_Newline (S);
      Append ("  mov %1, rbx", S);
      Emit_Newline (S);
      Append ("%endmacro", S);
      Emit_Newline (S);
      Emit_Newline (S);
      
      Append ("; --- DA INFIX TO REGISTER INTERCEPTOR ---", S); Emit_Newline(S);
      -- NASM: passthrough macro (FASM match/rewrite not ported).
      Append ("%macro ALB_LET 1+", S); Emit_Newline(S);
      Append ("  %1", S); Emit_Newline(S);
      Append ("%endmacro", S); Emit_Newline(S);
      Emit_Newline(S);

      Emit_Pure_Struct_Def(S);

      Append ("struc ALB_Fact", S); Emit_Newline(S);
      Append ("  .hash resq 1", S); Emit_Newline(S);
      Append ("  .arg_hash resq 1", S); Emit_Newline(S);
      Append ("  .val resq 1", S); Emit_Newline(S);
      Append ("  .active resb 1", S); Emit_Newline(S);
      Append ("  .pad resb 7", S); Emit_Newline(S);
      Append ("endstruc", S); Emit_Newline(S);
      Emit_Newline(S);

      Line ("struc ALB_GC_Node");
      Line ("  .Alive resb 1");
      Line ("  .Refs resb 1");
      Line ("  .pad resb 6");
      Line ("  .Child_1 resq 1");
      Line ("  .Child_2 resq 1");
      Line ("endstruc");
      Emit_Newline(S);

      -- 1. Uninitialized Memory Vault (.bss)
      -- PE64 DLL: keep labels the runtime helpers expect, but do not plant the
      -- multi-MB EXE vault (FASM emits a fragile BSS with bogus PointerToRawData).
      -- Struct defs MUST precede Name_size references in this section.
      Append ("section .bss", S); Emit_Newline(S);
      if Current_Format = Format_PE64_DLL then
         Append ("  ALB_KB resb 32 * 64", S); Emit_Newline(S);
         Append ("  ALB_TEMP_Future_KB resb 32 * 64", S); Emit_Newline(S);
         Append ("  ALB_TEMP_Future_State_Buffer resb 4096", S); Emit_Newline(S);
         Append ("  ALB_Str_Pool resb 8192", S); Emit_Newline(S);
         Append ("  ALB_Str_Ptr resq 1", S); Emit_Newline(S);
         Append ("  ALB_Chr_Table resb 512", S); Emit_Newline(S);
         Emit_Newline(S);
         Append ("  ALB_Input_Buffer resb 2048", S); Emit_Newline(S);
         Append ("  ALB_Input_Num resq 1", S); Emit_Newline(S);
         Append ("  ALB_File_Buffer resb 4096", S); Emit_Newline(S);
         Append ("  ALB_File_Table resq 32", S); Emit_Newline(S);
         Append ("  ALB_File_IO_Count resq 1", S); Emit_Newline(S);
         Append ("  ALB_File_SizeQ resq 1", S); Emit_Newline(S);
         Append ("  ALB_Foreign_Load_Path resb 1024", S); Emit_Newline(S);
         Emit_Newline(S);
         -- Host-facing input/present metrics used by engine modules even
         -- without CREATE_WINDOW (libgamedeck.dll logical API).
         Append ("  ALB_Mouse_X resq 1", S); Emit_Newline(S);
         Append ("  ALB_Mouse_Y resq 1", S); Emit_Newline(S);
         Append ("  ALB_Mouse_Wheel resq 1", S); Emit_Newline(S);
         Append ("  ALB_Mouse_Btn resq 1", S); Emit_Newline(S);
         Append ("  ALB_VMouse_X resq 1", S); Emit_Newline(S);
         Append ("  ALB_VMouse_Y resq 1", S); Emit_Newline(S);
         Append ("  ALB_Virtual_Width resq 1", S); Emit_Newline(S);
         Append ("  ALB_Virtual_Height resq 1", S); Emit_Newline(S);
         Append ("  ALB_Current_Color resq 1", S); Emit_Newline(S);
         Emit_Newline(S);
         Line ("  ALB_GC_Grid resb 16 * 65");
         Emit_Newline(S);
         Append ("  ALB_Err_Target_Stack resq 32", S); Emit_Newline(S);
         Append ("  ALB_Err_SP resq 1", S); Emit_Newline(S);
         Append ("  ALB_Last_Err resq 1", S); Emit_Newline(S);
         Emit_Newline(S);
      else
         Append ("  ALB_KB resb ALB_Fact_size * 1024", S); Emit_Newline(S);

         Append ("  ALB_TEMP_Future_KB resb ALB_Fact_size * 1024", S); Emit_Newline(S);
         Append ("  ALB_TEMP_Future_State_Buffer resb 1048576", S); Emit_Newline(S);

         -- DA FIX: Allocate 1MB cyclic string buffer for MID/LEFT/RIGHT slicing
         Append ("  ALB_Str_Pool resb 1048576", S); Emit_Newline(S);
         Append ("  ALB_Str_Ptr resq 1", S); Emit_Newline(S); -- DA FIX: Use 'resq 1' insteid o' 'dq 0'!
         Append ("  ALB_Chr_Table resb 512", S); Emit_Newline(S);
         Emit_Newline(S);

         Append ("  ALB_Input_Buffer resb 2048", S); Emit_Newline(S);
         Append ("  ALB_Input_Num resq 1", S); Emit_Newline(S);
         Append ("  ALB_File_Buffer resb 65536", S); Emit_Newline(S);
         Append ("  ALB_File_Table resq 256", S); Emit_Newline(S);
         Append ("  ALB_File_IO_Count resq 1", S); Emit_Newline(S);
         Append ("  ALB_File_SizeQ resq 1", S); Emit_Newline(S);
         Append ("  ALB_Foreign_Load_Path resb 1024", S); Emit_Newline(S);
         Emit_Newline(S);

         Line ("  ALB_GC_Grid resb ALB_GC_Node_size * 1025");
         Emit_Newline(S);

         Append ("  ALB_Err_Target_Stack resq 256", S); Emit_Newline(S);
         Append ("  ALB_Err_SP resq 1", S); Emit_Newline(S);
         Append ("  ALB_Last_Err resq 1", S); Emit_Newline(S);
         Emit_Newline(S);
      end if;



      -- 2. Initialized Data Vault (.data) MUST BE LAST IN GLOBAL BUFFER!
      Append ("section .data", S); Emit_Newline(S);
      
      Append ("  ALB_Fmt_Str db '%s', 10, 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Num db '%llu', 10, 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Signed db '%lld', 10, 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Pure db '%lld / %lld', 10, 0", S); Emit_Newline(S);

      
      Append ("  ALB_Rnd_Seed dq 0x123456789", S); Emit_Newline(S);
      
      Line ("  ALB_GC_Cursor dq 1");

      
      -- DA NEW FIX: Raw formats for PRINT$ (Nae Newlines!)
      Append ("  ALB_Fmt_Str_Raw db '%s', 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Num_Raw db '%llu', 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Signed_Raw db '%lld', 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Real_Raw db '%g', 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Pure_Raw db '%lld / %llu', 0", S); Emit_Newline(S);
      Append ("  ALB_Real_NaN_Str db 'nan', 0", S); Emit_Newline(S);
      Append ("  ALB_Real_Inf_Str db 'inf', 0", S); Emit_Newline(S);
      Append ("  ALB_Real_Neg_Inf_Str db '-inf', 0", S); Emit_Newline(S);
      Append ("  ALB_F64_10 dq 10.0", S); Emit_Newline(S);

      
      -- DA NEW FIX: ANSI Terminal Magic!
      Append ("  ALB_Fmt_Locate db 27, '[%llu;%lluH', 0", S); Emit_Newline(S);
      Append ("  ALB_Fmt_Clear db 27, '[2J', 27, '[1;1H', 0", S); Emit_Newline(S);
      
      Line ("  ALB_TEMP_Future_Depth dq 0");
      Line ("  ALB_TEMP_Future_Result dq 0");
      Line ("  ALB_TEMP_Future_Suppress_IO dq 0");
      Line ("  ALB_TEMP_Future_Rnd_Seed dq 0");
      Line ("  ALB_TEMP_Future_Str_Ptr dq 0");
      Line ("  ALB_Running dq 1");

      
      Line ("  ALB_TUI_Active dq 0");
      -- Shared runtime helpers use these even for headless console builds,
      -- so declare them unconditionally instead of only inside CREATE_WINDOW.
      Line ("  ALB_Window dq 0");
      Line ("  ALB_Renderer dq 0");
      Line ("  ALB_Empty_Str db 0");
      Line ("  ALB_Fmt_Ansi_Color db 27, '[38;5;%llu;48;5;%llum', 0");
      Line ("  ALB_Fmt_Reset db 27, '[0m', 0");
      Line ("  ALB_Fmt_Alt_On db 27, '[?0x1049', 0");
      Line ("  ALB_Fmt_Alt_Off db 27, '[?1049l', 0");
      Line ("  ALB_Fmt_Cursor_Off db 27, '[?25l', 0");
      Line ("  ALB_Fmt_Cursor_On db 27, '[?0x25', 0");
      Line ("  ALB_Fmt_Sync_Begin db 27, '[?0x2026', 0");
      Line ("  ALB_Fmt_Sync_End db 27, '[?2026l', 0");
      Line ("  ALB_Fmt_At_Str db 27, '[%llu;%lluH%s', 0");
      Line ("  ALB_Fmt_At_Num db 27, '[%llu;%lluH%llu', 0");

      
      Append ("  ALB_Prompt_Str db '%s', 0", S); Emit_Newline(S);
      Append ("  ALB_Scan_Str db '%2047s', 0", S); Emit_Newline(S);
      Append ("  ALB_Scan_Num db '%llu', 0", S); Emit_Newline(S);

      Line ("  ALB_Runtime_DivZero db 'ALB RUNTIME ERROR: divide or MOD by zero', 10, 0");
      Line ("  ALB_Runtime_Bounds db 'ALB RUNTIME ERROR: array index out of bounds', 10, 0");
      Line ("  ALB_Runtime_Range db 'ALB RUNTIME ERROR: value outside declared range', 10, 0");
      Line ("  ALB_Input_Invalid db 'Invalid input.', 10, 0");
      Line ("  ALB_Contract_Require db 'REQUIRE contract violation', 10, 0");
      Line ("  ALB_Contract_Ensure db 'ENSURE contract violation', 10, 0");
      Line ("  ALB_Input_Max_Attempts dq 3");
      Line ("  ALB_Parse_S64_Max dq 922337203685477580");
      Line ("  ALB_Trig_Deg_To_Rad dq 0.017453292519943295");
      Line ("  ALB_Trig_Scale dq 1024.0");

      -- 3. Execution Vault (.text)
      Current_Buffer := Buffer_Main;
      Append ("section .text", S); Emit_Newline(S);
      
      -- DA NEW FIX: Native 8-Argument Bounding Box Collision Engine
      Append ("COLLIDE_RECT:", S); Emit_Newline(S);
      Append ("  mov r10, rcx", S); Emit_Newline(S);
      Append ("  add r10, r8", S); Emit_Newline(S);
      Append ("  cmp qword [rsp+40], r10", S); Emit_Newline(S);
      Append ("  jge .no_collide", S); Emit_Newline(S);

      Append ("  mov r10, qword [rsp+40]", S); Emit_Newline(S);
      Append ("  add r10, qword [rsp+56]", S); Emit_Newline(S);
      Append ("  cmp r10, rcx", S); Emit_Newline(S);
      Append ("  jle .no_collide", S); Emit_Newline(S);

      Append ("  mov r10, rdx", S); Emit_Newline(S);
      Append ("  add r10, r9", S); Emit_Newline(S);
      Append ("  cmp qword [rsp+48], r10", S); Emit_Newline(S);
      Append ("  jge .no_collide", S); Emit_Newline(S);

      Append ("  mov r10, qword [rsp+48]", S); Emit_Newline(S);
      Append ("  add r10, qword [rsp+64]", S); Emit_Newline(S);
      Append ("  cmp r10, rdx", S); Emit_Newline(S);
      Append ("  jle .no_collide", S); Emit_Newline(S);

      Append ("  mov rax, 1", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);

      Append (".no_collide:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("; if used ALB_CEASE", S); Emit_Newline(S);
      Append ("ALB_CEASE:", S); Emit_Newline(S);
      Append ("  cmp qword [rel ALB_TEMP_Future_Suppress_IO], 0", S); Emit_Newline(S);
      Append ("  jne .alb_cease_done", S); Emit_Newline(S);
      Append ("  mov qword [rel ALB_Running], 0", S); Emit_Newline(S);
      Append (".alb_cease_done:", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Append ("; end if", S); Emit_Newline(S);
      Emit_Newline(S);
      
      --  Append ("ALB_Str_Eq:", S); Emit_Newline(S);
      --  Append ("  test rcx, rcx", S); Emit_Newline(S);
      --  Append ("  jnz .left_ok", S); Emit_Newline(S);
      --  Append ("  lea rcx, [rel ALB_Empty_Str]", S); Emit_Newline(S);
      --  Append (".left_ok:", S); Emit_Newline(S);
      --  Append ("  test rdx, rdx", S); Emit_Newline(S);
      --  Append ("  jnz .right_ok", S); Emit_Newline(S);
      --  Append ("  lea rdx, [rel ALB_Empty_Str]", S); Emit_Newline(S);
      --  Append (".right_ok:", S); Emit_Newline(S);
      --  Append (".str_loop:", S); Emit_Newline(S);
      --  Append ("  mov al, byte [rcx]", S); Emit_Newline(S);
      --  Append ("  mov r8b, byte [rdx]", S); Emit_Newline(S);
      --  Append ("  cmp al, r8b", S); Emit_Newline(S);
      --  Append ("  jne .str_ne", S); Emit_Newline(S);
      --  Append ("  test al, al", S); Emit_Newline(S);
      --  Append ("  jz .str_eq", S); Emit_Newline(S);
      --  Append ("  inc rcx", S); Emit_Newline(S);
      --  Append ("  inc rdx", S); Emit_Newline(S);
      --  Append ("  jmp .str_loop", S); Emit_Newline(S);
      --  Append (".str_eq:", S); Emit_Newline(S);
      --  Append ("  mov rax, 1", S); Emit_Newline(S);
      --  Append ("  ret", S); Emit_Newline(S);
      --  Append (".str_ne:", S); Emit_Newline(S);
      --  Append ("  xor rax, rax", S); Emit_Newline(S);
      --  Append ("  ret", S); Emit_Newline(S);
      --  Emit_Newline(S);
      
      Append ("ALB_Str_Eq:", S); Emit_Newline(S);
      Append ("  test rcx, rcx", S); Emit_Newline(S);
      Append ("  jnz .left_ok", S); Emit_Newline(S);
      Append ("  lea rcx, [rel ALB_Empty_Str]", S); Emit_Newline(S);
      Append (".left_ok:", S); Emit_Newline(S);
      Append ("  test rdx, rdx", S); Emit_Newline(S);
      Append ("  jnz .right_ok", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_Empty_Str]", S); Emit_Newline(S);
      Append (".right_ok:", S); Emit_Newline(S);
      Append (".str_loop:", S); Emit_Newline(S);
      Append ("  mov al, byte [rcx]", S); Emit_Newline(S);
      Append ("  mov r8b, byte [rdx]", S); Emit_Newline(S);
      Append ("  cmp al, r8b", S); Emit_Newline(S);
      Append ("  jne .str_ne", S); Emit_Newline(S);
      Append ("  test al, al", S); Emit_Newline(S);
      Append ("  jz .str_eq", S); Emit_Newline(S);
      Append ("  inc rcx", S); Emit_Newline(S);
      Append ("  inc rdx", S); Emit_Newline(S);
      Append ("  jmp .str_loop", S); Emit_Newline(S);
      Append (".str_eq:", S); Emit_Newline(S);
      Append ("  mov rax, 1", S); Emit_NewLine(S);
      Append ("  ret", S); Emit_Newline(S);
      Append (".str_ne:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Line ("ALB_Runtime_Trap_DivZero:");
      Line ("  sub rsp, 40");
      Line ("  invoke printf, ALB_Runtime_DivZero");
      Line ("  invoke ExitProcess, 1");
      Emit_Newline(S);

      Line ("ALB_Runtime_Trap_Bounds:");
      Line ("  sub rsp, 40");
      Line ("  invoke printf, ALB_Runtime_Bounds");
      Line ("  invoke ExitProcess, 1");
      Emit_Newline(S);

      Line ("ALB_Runtime_Trap_Range:");
      Line ("  sub rsp, 40");
      Line ("  invoke printf, ALB_Runtime_Range");
      Line ("  invoke ExitProcess, 1");
      Emit_Newline(S);

      Line ("; if used ALB_Input_Try_Parse_S64");
      Line ("ALB_Input_Try_Parse_S64:");
      Line ("  push rbx");
      Line ("  push rsi");
      Line ("  push rdi");
      Line ("  mov rsi, rcx");
      Line ("  xor rax, rax");
      Line ("  xor r10, r10");
      Line ("  xor r11, r11");
      Line (".alb_parse_skip_ws:");
      Line ("  movzx ecx, byte [rsi]");
      Line ("  test cl, cl");
      Line ("  jz .alb_parse_fail");
      Line ("  cmp cl, ' '");
      Line ("  je .alb_parse_ws");
      Line ("  cmp cl, 9");
      Line ("  je .alb_parse_ws");
      Line ("  jmp .alb_parse_sign");
      Line (".alb_parse_ws:");
      Line ("  inc rsi");
      Line ("  jmp .alb_parse_skip_ws");
      Line (".alb_parse_sign:");
      Line ("  cmp cl, '-'");
      Line ("  jne .alb_parse_plus");
      Line ("  mov r11, 1");
      Line ("  inc rsi");
      Line ("  jmp .alb_parse_digits");
      Line (".alb_parse_plus:");
      Line ("  cmp cl, '+'");
      Line ("  jne .alb_parse_digits");
      Line ("  inc rsi");
      Line (".alb_parse_digits:");
      Line ("  movzx ecx, byte [rsi]");
      Line ("  test cl, cl");
      Line ("  jz .alb_parse_finish");
      Line ("  cmp cl, '0'");
      Line ("  jb .alb_parse_fail");
      Line ("  cmp cl, '9'");
      Line ("  ja .alb_parse_fail");
      Line ("  mov r10, 1");
      Line ("  sub cl, '0'");
      Line ("  movzx edi, cl");
      Line ("  mov rbx, rax");
      Line ("  mov rcx, 10");
      Line ("  cmp rbx, [rel ALB_Parse_S64_Max]");
      Line ("  ja .alb_parse_fail");
      Line ("  jb .alb_parse_mul");
      Line ("  cmp edi, 7");
      Line ("  ja .alb_parse_fail");
      Line (".alb_parse_mul:");
      Line ("  mul rcx");
      Line ("  add rax, rdi");
      Line ("  inc rsi");
      Line ("  jmp .alb_parse_digits");
      Line (".alb_parse_finish:");
      Line ("  test r10, r10");
      Line ("  jz .alb_parse_fail");
      Line (".alb_parse_tail:");
      Line ("  movzx ecx, byte [rsi]");
      Line ("  test cl, cl");
      Line ("  jz .alb_parse_ok");
      Line ("  cmp cl, ' '");
      Line ("  je .alb_parse_tail_inc");
      Line ("  cmp cl, 9");
      Line ("  je .alb_parse_tail_inc");
      Line ("  cmp cl, 10");
      Line ("  je .alb_parse_ok");
      Line ("  cmp cl, 13");
      Line ("  je .alb_parse_tail_inc");
      Line ("  jmp .alb_parse_fail");
      Line (".alb_parse_tail_inc:");
      Line ("  inc rsi");
      Line ("  jmp .alb_parse_tail");
      Line (".alb_parse_ok:");
      Line ("  test r11, r11");
      Line ("  jz .alb_parse_done");
      Line ("  neg rax");
      Line (".alb_parse_done:");
      Line ("  mov rdx, 1");
      Line ("  pop rdi");
      Line ("  pop rsi");
      Line ("  pop rbx");
      Line ("  ret");
      Line (".alb_parse_fail:");
      Line ("  xor rax, rax");
      Line ("  xor rdx, rdx");
      Line ("  pop rdi");
      Line ("  pop rsi");
      Line ("  pop rbx");
      Line ("  ret");
      Line ("; end if");
      Emit_Newline(S);

      Line ("; if used ALB_Input_Read_Line");
      Line ("ALB_Input_Read_Line:");
      Line ("  sub rsp, 40");
      Line ("  invoke gets, ALB_Input_Buffer");
      Line ("  add rsp, 40");
      Line ("  ret");
      Line ("; end if");
      Emit_Newline(S);

      Line ("; if used ALB_Input_Read_Integer");
      Line ("ALB_Input_Read_Integer:");
      Line ("  push rbx");
      Line ("  push rsi");
      Line ("  mov rbx, rcx");
      Line ("  mov rsi, rdx");
      Line ("  test rbx, rbx");
      Line ("  jz .alb_in_int_read");
      Line ("  sub rsp, 40");
      Line ("  mov rdx, rbx");
      Line ("  invoke printf, ALB_Prompt_Str, rdx");
      Line ("  add rsp, 40");
      Line (".alb_in_int_read:");
      Line ("  call ALB_Input_Read_Line");
      Line ("  test rax, rax");
      Line ("  jz .alb_in_int_done");
      Line ("  mov rcx, ALB_Input_Buffer");
      Line ("  call ALB_Input_Try_Parse_S64");
      Line ("  test rdx, rdx");
      Line ("  jnz .alb_in_int_got");
      Line (".alb_in_int_done:");
      Line ("  mov rax, rsi");
      Line ("  pop rsi");
      Line ("  pop rbx");
      Line ("  ret");
      Line (".alb_in_int_got:");
      Line ("  pop rsi");
      Line ("  pop rbx");
      Line ("  ret");
      Line ("; end if");
      Emit_Newline(S);

      Line ("; if used ALB_Input_Read_Integer_In_Range");
      Line ("ALB_Input_Read_Integer_In_Range:");
      Line ("  push rbx");
      Line ("  push rsi");
      Line ("  push rdi");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  mov rbx, rcx");
      Line ("  mov r12, rdx");
      Line ("  mov r13, r8");
      Line ("  mov rsi, r9");
      Line ("  xor rdi, rdi");
      Line (".alb_in_rng_attempt:");
      Line ("  cmp rdi, [rel ALB_Input_Max_Attempts]");
      Line ("  jae .alb_in_rng_done");
      Line ("  inc rdi");
      Line ("  test rbx, rbx");
      Line ("  jz .alb_in_rng_read");
      Line ("  sub rsp, 40");
      Line ("  mov rdx, rbx");
      Line ("  invoke printf, ALB_Prompt_Str, rdx");
      Line ("  add rsp, 40");
      Line (".alb_in_rng_read:");
      Line ("  call ALB_Input_Read_Line");
      Line ("  test rax, rax");
      Line ("  jz .alb_in_rng_bad");
      Line ("  mov rcx, ALB_Input_Buffer");
      Line ("  call ALB_Input_Try_Parse_S64");
      Line ("  test rdx, rdx");
      Line ("  jz .alb_in_rng_bad");
      Line ("  cmp rax, r12");
      Line ("  jl .alb_in_rng_bad");
      Line ("  cmp rax, r13");
      Line ("  jg .alb_in_rng_bad");
      Line ("  jmp .alb_in_rng_exit");
      Line (".alb_in_rng_bad:");
      Line ("  sub rsp, 40");
      Line ("  invoke printf, ALB_Input_Invalid");
      Line ("  add rsp, 40");
      Line ("  jmp .alb_in_rng_attempt");
      Line (".alb_in_rng_done:");
      Line ("  mov rax, rsi");
      Line (".alb_in_rng_exit:");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  pop rdi");
      Line ("  pop rsi");
      Line ("  pop rbx");
      Line ("  ret");
      Line ("; end if");
      Emit_Newline(S);

      Line ("ALB_Sqrt_U64:");
      Line ("  xor r8, r8");
      Line ("  mov r9, 1");
      Line ("  shl r9, 62");
      Line (".sqrt_align:");
      Line ("  cmp r9, rax");
      Line ("  jbe .sqrt_loop");
      Line ("  shr r9, 2");
      Line ("  jnz .sqrt_align");
      Line ("  xor rax, rax");
      Line ("  ret");
      Line (".sqrt_loop:");
      Line ("  mov r10, r8");
      Line ("  add r10, r9");
      Line ("  cmp rax, r10");
      Line ("  jb .sqrt_skip");
      Line ("  sub rax, r10");
      Line ("  shr r8, 1");
      Line ("  add r8, r9");
      Line ("  jmp .sqrt_next");
      Line (".sqrt_skip:");
      Line ("  shr r8, 1");
      Line (".sqrt_next:");
      Line ("  shr r9, 2");
      Line ("  jnz .sqrt_loop");
      Line ("  mov rax, r8");
      Line ("  ret");
      Emit_Newline(S);

      -- F64 radians in RAX bit-pattern → F64 sin/cos back in RAX.
      -- (Old path used fild/fistp + deg scale — wrong for REAL/F64 and
      -- produced garbage clear-colors / geometry = red/black screens.)
      Line ("ALB_SIN:");
      Line ("  sub rsp, 40");
      Line ("  mov qword [rsp + 32], rax");
      Line ("  fld qword [rsp + 32]");
      Line ("  fsin");
      Line ("  fstp qword [rsp + 32]");
      Line ("  mov rax, qword [rsp + 32]");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_COS:");
      Line ("  sub rsp, 40");
      Line ("  mov qword [rsp + 32], rax");
      Line ("  fld qword [rsp + 32]");
      Line ("  fcos");
      Line ("  fstp qword [rsp + 32]");
      Line ("  mov rax, qword [rsp + 32]");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);


      Append ("ALB_Rnd:", S); Emit_Newline(S);
      Append ("  test rcx, rcx", S); Emit_Newline(S);
      Append ("  jnz .have_max", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Append (".have_max:", S); Emit_Newline(S);
      Append ("  mov r8, rcx", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_Rnd_Seed]", S); Emit_Newline(S);
      
      -- DA FIX: x64 requires loading 64-bit immediates into a register first!
      Append ("  mov r9, 0x123456789", S); Emit_Newline(S);
      Append ("  cmp rax, r9", S); Emit_Newline(S);
      
      Append ("  jne .seeded", S); Emit_Newline(S);
      Append ("  rdtsc", S); Emit_Newline(S);
      Append ("  shl rdx, 32", S); Emit_Newline(S);
      Append ("  or rax, rdx", S); Emit_Newline(S);
      Append ("  xor qword [rel ALB_Rnd_Seed], rax", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_Rnd_Seed]", S); Emit_Newline(S);
      Append (".seeded:", S); Emit_Newline(S);
      Append ("  mov rdx, rax", S); Emit_Newline(S);
      Append ("  shl rdx, 13", S); Emit_Newline(S);
      Append ("  xor rax, rdx", S); Emit_Newline(S);
      Append ("  mov rdx, rax", S); Emit_Newline(S);
      Append ("  shr rdx, 7", S); Emit_Newline(S);
      Append ("  xor rax, rdx", S); Emit_Newline(S);
      Append ("  mov rdx, rax", S); Emit_Newline(S);
      Append ("  shl rdx, 17", S); Emit_Newline(S);
      Append ("  xor rax, rdx", S); Emit_Newline(S);
      Append ("  mov qword [rel ALB_Rnd_Seed], rax", S); Emit_Newline(S);
      Append ("  xor rdx, rdx", S); Emit_Newline(S);
      Append ("  div r8", S); Emit_Newline(S);
      Append ("  mov rax, rdx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S); 
      
      -- Common delay wrapper for console/TUI and SDL builds.
      -- Delay statements from albt.adb call ALB_Delay with milliseconds in rcx.
      --  Append ("ALB_Delay:", S); Emit_Newline(S);
      --  Append ("  sub rsp, 40", S); Emit_Newline(S);
      --  Append ("  invoke Sleep, rcx", S); Emit_Newline(S);
      --  Append ("  add rsp, 40", S); Emit_Newline(S);
      --  Append ("  ret", S); Emit_Newline(S);
      --  Emit_Newline(S);
      
      Line ("ALB_Delay:");
      Line ("  sub rsp, 40");
      Line ("  mov qword [rsp + 32], rcx");
      Line ("  cmp qword [rel ALB_Renderer], 0");
      Line ("  jne .skip_flush");
      Line ("  call ALB_TUI_Frame_Flush");
      Line (".skip_flush:");
      Line ("  mov rcx, qword [rsp + 32]");
      Line ("  invoke Sleep, rcx");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);
      
      Line ("ALB_TUI_Frame_Flush:");
      Line ("  sub rsp, 40");
      Line ("  cmp qword [rel ALB_TUI_Active], 1");
      Line ("  jne .flush_only");
      Line ("  invoke printf, ALB_Fmt_Sync_End");
      Line (".flush_only:");
      Line ("  invoke fflush, 0");
      Line ("  cmp qword [rel ALB_TUI_Active], 1");
      Line ("  jne .done");
      Line ("  invoke printf, ALB_Fmt_Sync_Begin");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_BeginDraw:");
      Line ("  sub rsp, 40");
      Line ("  mov qword [rel ALB_TUI_Active], 1");
      Line ("  invoke printf, ALB_Fmt_Alt_On");
      Line ("  invoke printf, ALB_Fmt_Cursor_Off");
      Line ("  invoke printf, ALB_Fmt_Clear");
      Line ("  invoke printf, ALB_Fmt_Sync_Begin");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_EndDraw:");
      Line ("  sub rsp, 40");
      Line ("  cmp qword [rel ALB_TUI_Active], 1");
      Line ("  jne .skip_sync");
      Line ("  invoke printf, ALB_Fmt_Sync_End");
      Line (".skip_sync:");
      Line ("  invoke fflush, 0");
      Line ("  invoke printf, ALB_Fmt_Reset");
      Line ("  invoke printf, ALB_Fmt_Cursor_On");
      Line ("  invoke printf, ALB_Fmt_Alt_Off");
      Line ("  mov qword [rel ALB_TUI_Active], 0");
      Line ("  invoke fflush, 0");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_Clear:");
      Line ("  sub rsp, 40");
      Line ("  invoke printf, ALB_Fmt_Clear");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_SetColor:");
      Line ("  sub rsp, 40");
      Line ("  mov r10, rcx");
      Line ("  mov r11, rdx");
      Line ("  invoke printf, ALB_Fmt_Ansi_Color, r10, r11");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_PrintAtStr:");
      Line ("  sub rsp, 40");
      Line ("  mov r10, rcx");
      Line ("  mov r11, rdx");
      Line ("  mov r9, r8");
      Line ("  test r9, r9");
      Line ("  jnz .have_str");
      Line ("  lea r9, [rel ALB_Empty_Str]");
      Line (".have_str:");
      Line ("  invoke printf, ALB_Fmt_At_Str, r11, r10, r9");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_PrintAt:");
      Line ("  sub rsp, 40");
      Line ("  mov r10, rcx");
      Line ("  mov r11, rdx");
      Line ("  mov r9, r8");
      Line ("  invoke printf, ALB_Fmt_At_Num, r11, r10, r9");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_Width:");
      Line ("  mov rax, 80");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_Height:");
      Line ("  mov rax, 25");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_TUI_KeyPress:");
      Line ("  sub rsp, 40");
      Line ("  invoke GetAsyncKeyState, 0x51");
      Line ("  test ax, 1");
      Line ("  jnz .key_q");
      Line ("  invoke GetAsyncKeyState, 0x57");
      Line ("  test ax, 1");
      Line ("  jnz .key_w");
      Line ("  invoke GetAsyncKeyState, 0x53");
      Line ("  test ax, 1");
      Line ("  jnz .key_s");
      Line ("  invoke GetAsyncKeyState, 0x41");
      Line ("  test ax, 1");
      Line ("  jnz .key_a");
      Line ("  invoke GetAsyncKeyState, 0x44");
      Line ("  test ax, 1");
      Line ("  jnz .key_d");
      Line ("  invoke GetAsyncKeyState, 0x20");
      Line ("  test ax, 1");
      Line ("  jnz .key_space");
      Line ("  invoke GetAsyncKeyState, 0x0D");
      Line ("  test ax, 1");
      Line ("  jnz .key_enter");
      Line ("  xor rax, rax");
      Line ("  jmp .done");
      Line (".key_q: mov rax, 81");
      Line ("  jmp .done");
      Line (".key_w: mov rax, 87");
      Line ("  jmp .done");
      Line (".key_s: mov rax, 83");
      Line ("  jmp .done");
      Line (".key_a: mov rax, 65");
      Line ("  jmp .done");
      Line (".key_d: mov rax, 68");
      Line ("  jmp .done");
      Line (".key_space: mov rax, 32");
      Line ("  jmp .done");
      Line (".key_enter: mov rax, 13");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline(S);
      

      
      Append ("ALB_Play_Sound:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S);
      Append ("  mov r10, rcx", S); Emit_Newline(S);
      Append ("  mov r11, 0x00020001", S); Emit_Newline(S); -- SND_FILENAME | SND_ASYNC
      Append ("  test rdx, rdx", S); Emit_Newline(S);
      Append ("  jz .flags_ready", S); Emit_Newline(S);
      Append ("  or r11, 0x00000008", S); Emit_Newline(S); -- SND_LOOP
      Append (".flags_ready:", S); Emit_Newline(S);
      Append ("  invoke PlaySoundA, r10, 0, r11", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Emit_SDL3_Runtime_Support (S);

      Append ("ALB_Music_Ensure_Stream:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_Music_Stream]", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jnz .done", S); Emit_Newline(S);
      Append ("  call ALB_Init_SDL3", S); Emit_Newline(S);
      Append ("  test eax, eax", S); Emit_Newline(S);
      Append ("  jz .fail", S); Emit_Newline(S);
      Append ("  cmp qword [rel ALB_SDL_OpenAudioDeviceStream], 0", S); Emit_Newline(S);
      Append ("  je .fail", S); Emit_Newline(S);
      Append ("  cmp qword [rel ALB_SDL_PutAudioStreamData], 0", S); Emit_Newline(S);
      Append ("  je .fail", S); Emit_Newline(S);
      Append ("  cmp qword [rel ALB_SDL_ClearAudioStream], 0", S); Emit_Newline(S);
      Append ("  je .fail", S); Emit_Newline(S);
      Append ("  cmp qword [rel ALB_SDL_ResumeAudioStreamDevice], 0", S); Emit_Newline(S);
      Append ("  je .fail", S); Emit_Newline(S);
      Append ("  cmp qword [rel ALB_Music_Audio_Ready], 1", S); Emit_Newline(S);
      Append ("  je .open_stream", S); Emit_Newline(S);
      Append ("  mov ecx, 0x00000010", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_SDL_Init]", S); Emit_Newline(S);
      Append ("  call rax", S); Emit_Newline(S);
      Append ("  mov qword [rel ALB_Music_Audio_Ready], 1", S); Emit_Newline(S);
      Append (".open_stream:", S); Emit_Newline(S);
      Append ("  mov ecx, 0x0FFFFFFFF", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_Music_AudioSpec]", S); Emit_Newline(S);
      Append ("  xor r8d, r8d", S); Emit_Newline(S);
      Append ("  xor r9d, r9d", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_SDL_OpenAudioDeviceStream]", S); Emit_Newline(S);
      Append ("  call rax", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jz .fail", S); Emit_Newline(S);
      Append ("  mov qword [rel ALB_Music_Stream], rax", S); Emit_Newline(S);
      Append ("  mov rcx, rax", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_SDL_ResumeAudioStreamDevice]", S); Emit_Newline(S);
      Append ("  call rax", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_Music_Stream]", S); Emit_Newline(S);
      Append ("  jmp .done", S); Emit_Newline(S);
      Append (".fail:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append (".done:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_Play_Music_Buffer:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S);
      Append ("  mov qword [rsp + 24], rcx", S); Emit_Newline(S);
      Append ("  mov dword [rsp + 32], edx", S); Emit_Newline(S);
      Append ("  call ALB_Music_Ensure_Stream", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jz .done", S); Emit_Newline(S);
      Append ("  mov rcx, rax", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_SDL_ClearAudioStream]", S); Emit_Newline(S);
      Append ("  call rax", S); Emit_Newline(S);
      Append ("  mov rcx, qword [rel ALB_Music_Stream]", S); Emit_Newline(S);
      Append ("  mov rdx, qword [rsp + 24]", S); Emit_Newline(S);
      Append ("  mov r8d, dword [rsp + 32]", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_SDL_PutAudioStreamData]", S); Emit_Newline(S);
      Append ("  call rax", S); Emit_Newline(S);
      Append ("  mov rcx, qword [rel ALB_Music_Stream]", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_SDL_ResumeAudioStreamDevice]", S); Emit_Newline(S);
      Append ("  call rax", S); Emit_Newline(S);
      Append ("  mov eax, dword [rsp + 32]", S); Emit_Newline(S);
      Append ("  imul eax, eax, 1000", S); Emit_Newline(S);
      Append ("  xor edx, edx", S); Emit_Newline(S);
      Append ("  mov ecx, 44100", S); Emit_Newline(S);
      Append ("  div ecx", S); Emit_Newline(S);
      Append ("  add eax, 16", S); Emit_Newline(S);
      Append ("  mov ecx, eax", S); Emit_Newline(S);
      Append ("  invoke Sleep, rcx", S); Emit_Newline(S);
      Append (".done:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);
      
      Append ("ALB_CON_ALB_Clear_Console:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S);
      Append ("  invoke printf, ALB_Fmt_Clear", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);
      
      -- x64 Raw Hash Function
      Append ("ALB_Hash:", S); Emit_Newline(S);
      Append ("  mov rax, 5381", S); Emit_Newline(S);
      Append (".hash_loop:", S); Emit_Newline(S);
      Append ("  movzx rdx, byte [rcx]", S); Emit_Newline(S);
      Append ("  test rdx, rdx", S); Emit_Newline(S);
      Append ("  jz .hash_done", S); Emit_Newline(S);
      Append ("  imul rax, rax, 33", S); Emit_Newline(S);
      Append ("  add rax, rdx", S); Emit_Newline(S);
      Append ("  inc rcx", S); Emit_Newline(S);
      Append ("  jmp .hash_loop", S); Emit_Newline(S);
      Append (".hash_done:", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);
      
      -- x64 Prolog Knowledge Base Engine!
      Append ("ALB_Assert:", S); Emit_Newline(S);
      Append ("  push r12", S); Emit_Newline(S);
      Append ("  push r13", S); Emit_Newline(S);
      Append ("  push r14", S); Emit_Newline(S);
      Append ("  push r15", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S); -- DA FIX: 40 bytes for Win64 Alignment
      Append ("  mov r12, rdx", S); Emit_Newline(S);
      Append ("  mov r13, r8", S); Emit_Newline(S);
      Append ("  call ALB_Hash", S); Emit_Newline(S);
      Append ("  mov r14, rax", S); Emit_Newline(S);
      Append ("  mov r15, 0", S); Emit_Newline(S);
      Append (".albass_loop:", S); Emit_Newline(S);
      Append ("  cmp r15, 1024", S); Emit_Newline(S);
      Append ("  jge .albass_end", S); Emit_Newline(S);
      Append ("  imul rax, r15, 32", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_KB]", S); Emit_Newline(S);
      Append ("  add rax, rdx", S); Emit_Newline(S);
      Append ("  cmp byte [rax+24], 0", S); Emit_Newline(S);
      Append ("  je .albass_write", S); Emit_Newline(S);
      Append ("  cmp qword [rax], r14", S); Emit_Newline(S);
      Append ("  jne .albass_next", S); Emit_Newline(S);
      Append ("  cmp qword [rax+8], r12", S); Emit_Newline(S);
      Append ("  jne .albass_next", S); Emit_Newline(S);
      Append (".albass_write:", S); Emit_Newline(S);
      Append ("  mov qword [rax], r14", S); Emit_Newline(S);
      Append ("  mov qword [rax+8], r12", S); Emit_Newline(S);
      Append ("  mov qword [rax+16], r13", S); Emit_Newline(S);
      Append ("  mov byte [rax+24], 1", S); Emit_Newline(S);
      Append ("  jmp .albass_end", S); Emit_Newline(S);
      Append (".albass_next:", S); Emit_Newline(S);
      Append ("  inc r15", S); Emit_Newline(S);
      Append ("  jmp .albass_loop", S); Emit_Newline(S);
      Append (".albass_end:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S); -- DA FIX: Matching cleanup
      Append ("  pop r15", S); Emit_Newline(S);
      Append ("  pop r14", S); Emit_Newline(S);
      Append ("  pop r13", S); Emit_Newline(S);
      Append ("  pop r12", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_Query:", S); Emit_Newline(S);
      Append ("  push r12", S); Emit_Newline(S);
      Append ("  push r13", S); Emit_Newline(S);
      Append ("  push r14", S); Emit_Newline(S);
      Append ("  push r15", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S); -- DA FIX: Win64 Alignment
      Append ("  mov r12, rdx", S); Emit_Newline(S);
      Append ("  call ALB_Hash", S); Emit_Newline(S);
      Append ("  mov r14, rax", S); Emit_Newline(S);
      Append ("  mov r15, 0", S); Emit_Newline(S);
      Append (".albq_loop:", S); Emit_Newline(S);
      Append ("  cmp r15, 1024", S); Emit_Newline(S);
      Append ("  jge .albq_fail", S); Emit_Newline(S);
      Append ("  imul rax, r15, 32", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_KB]", S); Emit_Newline(S);
      Append ("  add rax, rdx", S); Emit_Newline(S);
      Append ("  cmp byte [rax+24], 0", S); Emit_Newline(S);
      Append ("  je .albq_next", S); Emit_Newline(S);
      Append ("  cmp qword [rax], r14", S); Emit_Newline(S);
      Append ("  jne .albq_next", S); Emit_Newline(S);
      Append ("  cmp qword [rax+8], r12", S); Emit_Newline(S);
      Append ("  je .albq_succ", S); Emit_Newline(S);
      Append ("  cmp qword [rax+16], r12", S); Emit_Newline(S);
      Append ("  je .albq_succ", S); Emit_Newline(S);
      Append (".albq_next:", S); Emit_Newline(S);
      Append ("  inc r15", S); Emit_Newline(S);
      Append ("  jmp .albq_loop", S); Emit_Newline(S);
      Append (".albq_succ:", S); Emit_Newline(S);
      Append ("  mov rax, 1", S); Emit_Newline(S);
      Append ("  jmp .albq_end", S); Emit_Newline(S);
      Append (".albq_fail:", S); Emit_Newline(S);
      Append ("  mov rax, 0", S); Emit_Newline(S);
      Append (".albq_end:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  pop r15", S); Emit_Newline(S);
      Append ("  pop r14", S); Emit_Newline(S);
      Append ("  pop r13", S); Emit_Newline(S);
      Append ("  pop r12", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      
      Append ("ALB_Find:", S); Emit_Newline(S);
      Append ("  push r12", S); Emit_Newline(S);
      Append ("  sub rsp, 32", S); Emit_Newline(S);
      Append ("  call ALB_Hash", S); Emit_Newline(S);
      Append ("  mov r12, 0", S); Emit_Newline(S);
      Append (".albf_loop:", S); Emit_Newline(S);
      Append ("  cmp r12, 1024", S); Emit_Newline(S);
      Append ("  jge .albf_fail", S); Emit_Newline(S);
      Append ("  imul rcx, r12, 32", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_KB]", S); Emit_Newline(S);
      Append ("  add rcx, rdx", S); Emit_Newline(S);
      Append ("  cmp byte [rcx+24], 0", S); Emit_Newline(S);
      Append ("  je .albf_next", S); Emit_Newline(S);
      Append ("  cmp qword [rcx], rax", S); Emit_Newline(S);
      Append ("  jne .albf_next", S); Emit_Newline(S);
      
      Append ("  mov rax, qword [rcx+16]", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jnz .albf_end", S); Emit_Newline(S);
      Append ("  mov rax, qword [rcx+8]", S); Emit_Newline(S);
      Append ("  jmp .albf_end", S); Emit_Newline(S);
      
      Append (".albf_next:", S); Emit_Newline(S);
      Append ("  inc r12", S); Emit_Newline(S);
      Append ("  jmp .albf_loop", S); Emit_Newline(S);
      Append (".albf_fail:", S); Emit_Newline(S);
      Append ("  mov rax, 0", S); Emit_Newline(S);
      Append (".albf_end:", S); Emit_Newline(S);
      Append ("  add rsp, 32", S); Emit_Newline(S);
      Append ("  pop r12", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      
      Line ("");
      Line ("ALB_FindAll:");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  push r14");
      Line ("  push r15");
      Line ("  sub rsp, 40");
      Line ("  mov r12, rdx");
      Line ("  test r12, r12");
      Line ("  jz .albfa_done_zero");
      Line ("  call ALB_Hash");
      Line ("  mov r13, rax");
      Line ("  xor r14, r14");
      Line ("  xor r15, r15");
      Line (".albfa_loop:");
      Line ("  cmp r14, 1024");
      Line ("  jge .albfa_done");
      Line ("  imul rax, r14, 32");
      Line ("  lea rdx, [rel ALB_KB]");
      Line ("  add rax, rdx");
      Line ("  cmp byte [rax+24], 0");
      Line ("  je .albfa_next");
      Line ("  cmp qword [rax], r13");
      Line ("  jne .albfa_next");
      
      Line ("  mov rdx, qword [rax+16]");
      Line ("  test rdx, rdx");
      Line ("  jnz .albfa_store");
      Line ("  mov rdx, qword [rax+8]");
      Line (".albfa_store:");
      Line ("  mov qword [r12 + r15*8], rdx");
      
      Line ("  inc r15");
      Line (".albfa_next:");
      Line ("  inc r14");
      Line ("  jmp .albfa_loop");
      Line (".albfa_done:");
      Line ("  mov rax, r15");
      Line ("  jmp .albfa_exit");
      Line (".albfa_done_zero:");
      Line ("  xor rax, rax");
      Line (".albfa_exit:");
      Line ("  add rsp, 40");
      Line ("  pop r15");
      Line ("  pop r14");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  ret");
      
      Line ("");
      Line ("ALB_Update:");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  push r14");
      Line ("  push r15");
      Line ("  sub rsp, 40");
      Line ("  mov r12, rdx");
      Line ("  mov r13, r8");
      Line ("  call ALB_Hash");
      Line ("  mov r14, rax");
      Line ("  xor r15, r15");
      Line (".albupd_loop:");
      Line ("  cmp r15, 1024");
      Line ("  jge .albupd_fail");
      Line ("  imul rax, r15, 32");
      Line ("  lea r10, [rel ALB_KB]");
      Line ("  add rax, r10");
      Line ("  cmp byte [rax+24], 0");
      Line ("  je .albupd_next");
      Line ("  cmp qword [rax], r14");
      Line ("  jne .albupd_next");
      Line ("  cmp qword [rax+8], r12");
      Line ("  je .albupd_arg");
      Line ("  cmp qword [rax+16], r12");
      Line ("  je .albupd_val");
      Line ("  jmp .albupd_next");
      Line (".albupd_arg:");
      Line ("  mov qword [rax+8], r13");
      Line ("  mov rax, 1");
      Line ("  jmp .albupd_done");
      Line (".albupd_val:");
      Line ("  mov qword [rax+16], r13");
      Line ("  mov rax, 1");
      Line ("  jmp .albupd_done");
      Line (".albupd_next:");
      Line ("  inc r15");
      Line ("  jmp .albupd_loop");
      Line (".albupd_fail:");
      Line ("  xor rax, rax");
      Line (".albupd_done:");
      Line ("  add rsp, 40");
      Line ("  pop r15");
      Line ("  pop r14");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  ret");
      
      -- DA NEW FIX: FASM Prolog Retract Engine!
      Append ("ALB_Retract:", S); Emit_Newline(S);
      Append ("  push r12", S); Emit_Newline(S);
      Append ("  push r13", S); Emit_Newline(S);
      Append ("  push r14", S); Emit_Newline(S);
      Append ("  push r15", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S); -- DA FIX: Win64 Alignment
      Append ("  mov r12, rdx", S); Emit_Newline(S);
      Append ("  call ALB_Hash", S); Emit_Newline(S); 
      Append ("  mov r14, rax", S); Emit_Newline(S);
      Append ("  mov r15, 0", S); Emit_Newline(S);
      Append (".albret_loop:", S); Emit_Newline(S);
      Append ("  cmp r15, 1024", S); Emit_Newline(S);
      Append ("  jge .albret_end", S); Emit_Newline(S);
      Append ("  imul rax, r15, 32", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_KB]", S); Emit_Newline(S);
      Append ("  add rax, rdx", S); Emit_Newline(S);
      Append ("  cmp byte [rax+24], 0", S); Emit_Newline(S);
      Append ("  je .albret_next", S); Emit_Newline(S); 
      Append ("  cmp qword [rax], r14", S); Emit_Newline(S);
      Append ("  jne .albret_next", S); Emit_Newline(S); 
      Append ("  cmp qword [rax+8], r12", S); Emit_Newline(S);
      Append ("  jne .albret_next", S); Emit_Newline(S); 
      Append ("  mov byte [rax+24], 0", S); Emit_Newline(S); 
      Append ("  jmp .albret_end", S); Emit_Newline(S); 
      Append (".albret_next:", S); Emit_Newline(S);
      Append ("  inc r15", S); Emit_Newline(S);
      Append ("  jmp .albret_loop", S); Emit_Newline(S);
      Append (".albret_end:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  pop r15", S); Emit_Newline(S);
      Append ("  pop r14", S); Emit_Newline(S);
      Append ("  pop r13", S); Emit_Newline(S);
      Append ("  pop r12", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);
      
      
      Line ("ALB_GC_Claim:");
      Line ("  push rbx");
      Line ("  push r12");
      Line ("  mov r12, rcx");
      Line ("  mov qword [r12], 0");
      Line ("  mov rbx, 1");
      Line (".gc_claim_loop:");
      Line ("  cmp rbx, 1024");
      Line ("  ja .gc_claim_fail");
      Line ("  imul rax, rbx, ALB_GC_Node_size");
      Line ("  lea rdx, [rel ALB_GC_Grid]");
      Line ("  add rdx, rax");
      Line ("  cmp byte [rdx + ALB_GC_Node.Alive], 0");
      Line ("  jne .gc_claim_next");
      Line ("  mov byte [rdx + ALB_GC_Node.Alive], 1");
      Line ("  mov byte [rdx + ALB_GC_Node.Refs], 1");
      Line ("  mov qword [rdx + ALB_GC_Node.Child_1], 0");
      Line ("  mov qword [rdx + ALB_GC_Node.Child_2], 0");
      Line ("  mov qword [r12], rbx");
      Line ("  mov rax, rbx");
      Line ("  jmp .gc_claim_done");
      Line (".gc_claim_next:");
      Line ("  inc rbx");
      Line ("  jmp .gc_claim_loop");
      Line (".gc_claim_fail:");
      Line ("  xor rax, rax");
      Line (".gc_claim_done:");
      Line ("  pop r12");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_GC_Drop:");
      Line ("  test rcx, rcx");
      Line ("  jz .gc_drop_done");
      Line ("  cmp rcx, 1024");
      Line ("  ja .gc_drop_done");
      Line ("  imul rax, rcx, ALB_GC_Node_size");
      Line ("  lea rdx, [rel ALB_GC_Grid]");
      Line ("  add rdx, rax");
      Line ("  cmp byte [rdx + ALB_GC_Node.Alive], 0");
      Line ("  je .gc_drop_done");
      Line ("  cmp byte [rdx + ALB_GC_Node.Refs], 0");
      Line ("  je .gc_drop_done");
      Line ("  dec byte [rdx + ALB_GC_Node.Refs]");
      Line (".gc_drop_done:");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_GC_Bind:");
      Line ("  test rcx, rcx");
      Line ("  jz .gc_bind_done");
      Line ("  cmp rcx, 1024");
      Line ("  ja .gc_bind_done");
      Line ("  imul rax, rcx, ALB_GC_Node_size");
      Line ("  lea r10, [rel ALB_GC_Grid]");
      Line ("  add r10, rax");
      Line ("  cmp byte [r10 + ALB_GC_Node.Alive], 0");
      Line ("  je .gc_bind_done");
      Line ("  mov qword [r10 + ALB_GC_Node.Child_1], rdx");
      Line ("  mov qword [r10 + ALB_GC_Node.Child_2], r8");
      Line (".gc_bind_done:");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_GC_Sweep:");
      Line ("  mov r9, rcx");
      Line ("  test r9, r9");
      Line ("  jz .gc_sweep_done");
      Line ("  cmp r9, 1024");
      Line ("  jbe .gc_sweep_steps_ready");
      Line ("  mov r9, 1024");
      Line (".gc_sweep_steps_ready:");
      Line ("  xor r10, r10");
      Line (".gc_sweep_loop:");
      Line ("  cmp r10, r9");
      Line ("  jae .gc_sweep_done");
      Line ("  mov r11, qword [rel ALB_GC_Cursor]");
      Line ("  imul rax, r11, ALB_GC_Node_size");
      Line ("  lea rdx, [rel ALB_GC_Grid]");
      Line ("  add rdx, rax");
      Line ("  cmp byte [rdx + ALB_GC_Node.Alive], 0");
      Line ("  je .gc_sweep_advance");
      Line ("  cmp byte [rdx + ALB_GC_Node.Refs], 0");
      Line ("  jne .gc_sweep_advance");
      Line ("  mov byte [rdx + ALB_GC_Node.Alive], 0");
      Line ("  mov rax, qword [rdx + ALB_GC_Node.Child_1]");
      Line ("  test rax, rax");
      Line ("  jz .gc_sweep_child2");
      Line ("  cmp rax, 1024");
      Line ("  ja .gc_sweep_child2");
      Line ("  imul rcx, rax, ALB_GC_Node_size");
      Line ("  lea r8, [rel ALB_GC_Grid]");
      Line ("  add r8, rcx");
      Line ("  cmp byte [r8 + ALB_GC_Node.Refs], 0");
      Line ("  je .gc_sweep_child2");
      Line ("  dec byte [r8 + ALB_GC_Node.Refs]");
      Line (".gc_sweep_child2:");
      Line ("  mov rax, qword [rdx + ALB_GC_Node.Child_2]");
      Line ("  test rax, rax");
      Line ("  jz .gc_sweep_advance");
      Line ("  cmp rax, 1024");
      Line ("  ja .gc_sweep_advance");
      Line ("  imul rcx, rax, ALB_GC_Node_size");
      Line ("  lea r8, [rel ALB_GC_Grid]");
      Line ("  add r8, rcx");
      Line ("  cmp byte [r8 + ALB_GC_Node.Refs], 0");
      Line ("  je .gc_sweep_advance");
      Line ("  dec byte [r8 + ALB_GC_Node.Refs]");
      Line (".gc_sweep_advance:");
      Line ("  inc qword [rel ALB_GC_Cursor]");
      Line ("  cmp qword [rel ALB_GC_Cursor], 1024");
      Line ("  jbe .gc_sweep_next");
      Line ("  mov qword [rel ALB_GC_Cursor], 1");
      Line (".gc_sweep_next:");
      Line ("  inc r10");
      Line ("  jmp .gc_sweep_loop");
      Line (".gc_sweep_done:");
      Line ("  ret");
      Emit_Newline(S);
      
      -- DA NEW FIX: FASM String Slicing Implementations!
      Append ("ALB_String_Mid:", S); Emit_Newline(S);
      Append ("  push r12", S); Emit_Newline(S);
      Append ("  push r13", S); Emit_Newline(S);
      Append ("  push r14", S); Emit_Newline(S);
      Append ("  push r15", S); Emit_Newline(S);
      Append ("  sub rsp, 32", S); Emit_Newline(S);
      Append ("  mov r12, rcx", S); Emit_Newline(S);
      Append ("  mov r13, rdx", S); Emit_Newline(S);
      Append ("  dec r13", S); Emit_Newline(S);
      Append ("  cmp r13, 0", S); Emit_Newline(S);
      Append ("  jge .mid_ok", S); Emit_Newline(S);
      Append ("  mov r13, 0", S); Emit_Newline(S);
      Append (".mid_ok:", S); Emit_Newline(S);
      Append ("  mov r14, r8", S); Emit_Newline(S);
      Append ("  cmp r14, 8191", S); Emit_Newline(S);
      Append ("  jle .mid_len_ok", S); Emit_Newline(S);
      Append ("  mov r14, 8191", S); Emit_Newline(S);
      Append (".mid_len_ok:", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_Str_Ptr]", S); Emit_Newline(S);
      Append ("  cmp rax, 1048576", S); Emit_Newline(S);
      Append ("  jl .mid_slot_ok", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append (".mid_slot_ok:", S); Emit_Newline(S);
      Append ("  lea r15, [rel ALB_Str_Pool]", S); Emit_Newline(S);
      Append ("  add r15, rax", S); Emit_Newline(S);
      Append ("  xor rcx, rcx", S); Emit_Newline(S);
      Append (".mid_loop:", S); Emit_Newline(S);
      Append ("  cmp rcx, r14", S); Emit_Newline(S);
      Append ("  jge .mid_done", S); Emit_Newline(S);
      Append ("  lea rax, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  cmp r12, rax", S); Emit_Newline(S);
      Append ("  jne .mid_text_byte", S); Emit_Newline(S);
      Append ("  cmp r13, qword [rel ALB_File_IO_Count]", S); Emit_Newline(S);
      Append ("  jae .mid_done", S); Emit_Newline(S);
      Append ("  mov dl, byte [r12 + r13]", S); Emit_Newline(S);
      Append ("  jmp .mid_store_byte", S); Emit_Newline(S);
      Append (".mid_text_byte:", S); Emit_Newline(S);
      Append ("  mov dl, byte [r12 + r13]", S); Emit_Newline(S);
      Append ("  test dl, dl", S); Emit_Newline(S);
      Append ("  jz .mid_done", S); Emit_Newline(S);
      Append (".mid_store_byte:", S); Emit_Newline(S);
      Append ("  mov byte [r15 + rcx], dl", S); Emit_Newline(S);
      Append ("  inc rcx", S); Emit_Newline(S);
      Append ("  inc r13", S); Emit_Newline(S);
      Append ("  jmp .mid_loop", S); Emit_Newline(S);
      Append (".mid_done:", S); Emit_Newline(S);
      Append ("  mov byte [r15 + rcx], 0", S); Emit_Newline(S);
      Append ("  mov r11, rcx", S); Emit_Newline(S);
      Append ("  inc r11", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_Str_Ptr]", S); Emit_Newline(S);
      Append ("  add rax, r11", S); Emit_Newline(S);
      Append ("  add rax, 7", S); Emit_Newline(S);
      Append ("  and rax, -8", S); Emit_Newline(S);
      Append ("  cmp rax, 1048576", S); Emit_Newline(S);
      Append ("  jl .mid_bump_ok", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append (".mid_bump_ok:", S); Emit_Newline(S);
      Append ("  mov qword [rel ALB_Str_Ptr], rax", S); Emit_Newline(S);
      Append ("  mov rax, r15", S); Emit_Newline(S);
      Append ("  add rsp, 32", S); Emit_Newline(S);
      Append ("  pop r15", S); Emit_Newline(S);
      Append ("  pop r14", S); Emit_Newline(S);
      Append ("  pop r13", S); Emit_Newline(S);
      Append ("  pop r12", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);
      
      Append ("ALB_String_Left:", S); Emit_Newline(S);
      Append ("  mov r8, rdx", S); Emit_Newline(S);
      Append ("  mov rdx, 1", S); Emit_Newline(S);
      Append ("  jmp ALB_String_Mid", S); Emit_Newline(S);
      Emit_Newline(S);
      
      Append ("ALB_String_Right:", S); Emit_Newline(S);
      Append ("  push rdi", S); Emit_Newline(S);
      Append ("  push rcx", S); Emit_Newline(S);
      Append ("  push rdx", S); Emit_Newline(S);
      Append ("  mov rdi, rcx", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  xor rcx, rcx", S); Emit_Newline(S);
      Append ("  not rcx", S); Emit_Newline(S);
      Append ("  repne scasb", S); Emit_Newline(S);
      Append ("  not rcx", S); Emit_Newline(S);
      Append ("  dec rcx", S); Emit_Newline(S);
      Append ("  pop rdx", S); Emit_Newline(S);
      Append ("  pop r8", S); Emit_Newline(S);
      Append ("  pop rdi", S); Emit_Newline(S);
      Append ("  mov rax, rcx", S); Emit_Newline(S);
      Append ("  sub rax, rdx", S); Emit_Newline(S);
      Append ("  inc rax", S); Emit_Newline(S);
      Append ("  mov rcx, r8", S); Emit_Newline(S);
      Append ("  mov r8, rdx", S); Emit_Newline(S);
      Append ("  mov rdx, rax", S); Emit_Newline(S);
      Append ("  jmp ALB_String_Mid", S); Emit_Newline(S);
      Emit_Newline(S);
      
      -- DA NATIVE STRING CONCAT FORGE
      Line ("ALB_String_Concat:");
      Line ("  mov rax, qword [rel ALB_Str_Ptr]");
      Line ("  cmp rax, 1048576");
      Line ("  jl .concat_slot_ok");
      Line ("  xor rax, rax");
      Line (".concat_slot_ok:");
      Line ("  lea r8, [rel ALB_Str_Pool]");
      Line ("  lea r8, [r8 + rax]");
      Line ("  mov r9, r8");
      Line ("  mov r10, 8191");

      Line ("  test rcx, rcx");
      Line ("  jz .concat_s2");
      Line ("  mov r11, rcx");
      Line (".concat_s1_loop:");
      Line ("  test r10, r10");
      Line ("  jz .concat_done");
      Line ("  mov al, byte [r11]");
      Line ("  test al, al");
      Line ("  jz .concat_s2");
      Line ("  mov byte [r9], al");
      Line ("  inc r9");
      Line ("  inc r11");
      Line ("  dec r10");
      Line ("  jmp .concat_s1_loop");

      Line (".concat_s2:");
      Line ("  test rdx, rdx");
      Line ("  jz .concat_done");
      Line ("  mov r11, rdx");
      Line (".concat_s2_loop:");
      Line ("  test r10, r10");
      Line ("  jz .concat_done");
      Line ("  mov al, byte [r11]");
      Line ("  test al, al");
      Line ("  jz .concat_done");
      Line ("  mov byte [r9], al");
      Line ("  inc r9");
      Line ("  inc r11");
      Line ("  dec r10");
      Line ("  jmp .concat_s2_loop");

      Line (".concat_done:");
      Line ("  mov byte [r9], 0");
      Line ("  mov r11, r9");
      Line ("  sub r11, r8");
      Line ("  inc r11");
      Line ("  mov rax, qword [rel ALB_Str_Ptr]");
      Line ("  add rax, r11");
      Line ("  add rax, 7");
      Line ("  and rax, -8");
      Line ("  cmp rax, 1048576");
      Line ("  jl .concat_bump_ok");
      Line ("  xor rax, rax");
      Line (".concat_bump_ok:");
      Line ("  mov qword [rel ALB_Str_Ptr], rax");
      Line ("  mov rax, r8");
      Line ("  ret");
      Emit_Newline(S);

      Line ("ALB_String_From_U64:");
      Line ("  push rbx");
      Line ("  push r12");
      Line ("  mov r10, rax");
      Line ("  mov rax, qword [rel ALB_Str_Ptr]");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_u64_slot_ok");
      Line ("  xor rax, rax");
      Line (".fmt_u64_slot_ok:");
      Line ("  mov r12, rax");
      Line ("  lea rbx, [rel ALB_Str_Pool]");
      Line ("  add rbx, rax");
      Line ("  invoke sprintf, rbx, ALB_Fmt_Num_Raw, r10");
      Line ("  xor r11, r11");
      Line (".fmt_u64_len:");
      Line ("  cmp byte [rbx + r11], 0");
      Line ("  je .fmt_u64_len_done");
      Line ("  inc r11");
      Line ("  jmp .fmt_u64_len");
      Line (".fmt_u64_len_done:");
      Line ("  inc r11");
      Line ("  mov rax, r12");
      Line ("  add rax, r11");
      Line ("  add rax, 7");
      Line ("  and rax, -8");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_u64_bump_ok");
      Line ("  xor rax, rax");
      Line (".fmt_u64_bump_ok:");
      Line ("  mov qword [rel ALB_Str_Ptr], rax");
      Line ("  mov rax, rbx");
      Line ("  pop r12");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_String_From_S64:");
      Line ("  push rbx");
      Line ("  push r12");
      Line ("  mov r10, rax");
      Line ("  mov rax, qword [rel ALB_Str_Ptr]");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_s64_slot_ok");
      Line ("  xor rax, rax");
      Line (".fmt_s64_slot_ok:");
      Line ("  mov r12, rax");
      Line ("  lea rbx, [rel ALB_Str_Pool]");
      Line ("  add rbx, rax");
      Line ("  invoke sprintf, rbx, ALB_Fmt_Signed_Raw, r10");
      Line ("  xor r11, r11");
      Line (".fmt_s64_len:");
      Line ("  cmp byte [rbx + r11], 0");
      Line ("  je .fmt_s64_len_done");
      Line ("  inc r11");
      Line ("  jmp .fmt_s64_len");
      Line (".fmt_s64_len_done:");
      Line ("  inc r11");
      Line ("  mov rax, r12");
      Line ("  add rax, r11");
      Line ("  add rax, 7");
      Line ("  and rax, -8");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_s64_bump_ok");
      Line ("  xor rax, rax");
      Line (".fmt_s64_bump_ok:");
      Line ("  mov qword [rel ALB_Str_Ptr], rax");
      Line ("  mov rax, rbx");
      Line ("  pop r12");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_String_From_F64:");
      Line ("  push rbx");
      Line ("  sub rsp, 48");
      Line ("  mov r10, rax");
      Line ("  bt r10, 63");
      Line ("  setc r9b");
      Line ("  btr r10, 63");
      Line ("  mov qword [rsp + 32], r10");
      Line ("  test r10, r10");
      Line ("  jnz .f64_non_zero");
      Line ("  xor rax, rax");
      Line ("  call ALB_String_From_U64");
      Line ("  jmp .f64_done");
      Line (".f64_non_zero:");
      Line ("  movq xmm0, r10");
      Line ("  ucomisd xmm0, xmm0");
      Line ("  jp .f64_nan");
      Line ("  mov rax, 0x8000000000000000");
      Line ("  cvttsd2si r11, xmm0");
      Line ("  cmp r11, rax");
      Line ("  je .f64_inf");
      Line ("  mov qword [rsp + 40], r11");
      Line ("  mov rax, r11");
      Line ("  cvtsi2sd xmm1, rax");
      Line ("  ucomisd xmm0, xmm1");
      Line ("  jp .f64_fractional");
      Line ("  jne .f64_fractional");
      Line ("  test r9b, r9b");
      Line ("  jz .f64_int_ready");
      Line ("  neg r11");
      Line (".f64_int_ready:");
      Line ("  mov rax, r11");
      Line ("  call ALB_String_From_S64");
      Line ("  jmp .f64_done");
      Line (".f64_nan:");
      Line ("  lea rax, [rel ALB_Real_NaN_Str]");
      Line ("  jmp .f64_done");
      Line (".f64_inf:");
      Line ("  test r9b, r9b");
      Line ("  jz .f64_pos_inf");
      Line ("  lea rax, [rel ALB_Real_Neg_Inf_Str]");
      Line ("  jmp .f64_done");
      Line (".f64_pos_inf:");
      Line ("  lea rax, [rel ALB_Real_Inf_Str]");
      Line ("  jmp .f64_done");
      Line (".f64_fractional:");
      Line ("  mov rax, qword [rel ALB_Str_Ptr]");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_f64_slot_ok");
      Line ("  xor rax, rax");
      Line (".fmt_f64_slot_ok:");
      Line ("  mov qword [rsp + 24], rax");
      Line ("  lea rbx, [rel ALB_Str_Pool]");
      Line ("  add rbx, rax");
      Line ("  mov rcx, rbx");
      Line ("  test r9b, r9b");
      Line ("  jz .f64_no_sign");
      Line ("  mov byte [rcx], '-'");
      Line ("  inc rcx");
      Line (".f64_no_sign:");
      Line ("  mov rax, qword [rsp + 40]");
      Line ("  call ALB_String_From_U64");
      Line ("  mov rdx, rax");
      Line (".f64_copy_int:");
      Line ("  mov al, byte [rdx]");
      Line ("  test al, al");
      Line ("  jz .f64_after_int");
      Line ("  mov byte [rcx], al");
      Line ("  inc rcx");
      Line ("  inc rdx");
      Line ("  jmp .f64_copy_int");
      Line (".f64_after_int:");
      Line ("  mov byte [rcx], '.'");
      Line ("  inc rcx");
      Line ("  mov r8, rcx");
      Line ("  mov r10, qword [rsp + 32]");
      Line ("  movq xmm0, r10");
      Line ("  mov rax, qword [rsp + 40]");
      Line ("  cvtsi2sd xmm1, rax");
      Line ("  subsd xmm0, xmm1");
      Line ("  mov rdx, 12");
      Line (".f64_frac_loop:");
      Line ("  test rdx, rdx");
      Line ("  jz .f64_trim");
      Line ("  mulsd xmm0, qword [rel ALB_F64_10]");
      Line ("  cvttsd2si rax, xmm0");
      Line ("  add al, '0'");
      Line ("  mov byte [rcx], al");
      Line ("  inc rcx");
      Line ("  movzx rax, al");
      Line ("  sub rax, '0'");
      Line ("  cvtsi2sd xmm1, rax");
      Line ("  subsd xmm0, xmm1");
      Line ("  dec rdx");
      Line ("  xorpd xmm1, xmm1");
      Line ("  ucomisd xmm0, xmm1");
      Line ("  jne .f64_frac_loop");
      Line (".f64_trim:");
      Line ("  cmp rcx, r8");
      Line ("  jbe .f64_trim_dot");
      Line ("  cmp byte [rcx - 1], '0'");
      Line ("  jne .f64_trim_dot");
      Line ("  dec rcx");
      Line ("  jmp .f64_trim");
      Line (".f64_trim_dot:");
      Line ("  cmp byte [rcx - 1], '.'");
      Line ("  jne .f64_finalize");
      Line ("  dec rcx");
      Line (".f64_finalize:");
      Line ("  mov byte [rcx], 0");
      Line ("  mov r11, rcx");
      Line ("  sub r11, rbx");
      Line ("  inc r11");
      Line ("  mov rax, qword [rsp + 24]");
      Line ("  add rax, r11");
      Line ("  add rax, 7");
      Line ("  and rax, -8");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_f64_bump_ok");
      Line ("  xor rax, rax");
      Line (".fmt_f64_bump_ok:");
      Line ("  mov qword [rel ALB_Str_Ptr], rax");
      Line ("  mov rax, rbx");
      Line (".f64_done:");
      Line ("  add rsp, 48");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_String_From_Pure:");
      Line ("  push rbx");
      Line ("  push r12");
      Line ("  mov r10, rax");
      Line ("  mov rax, qword [rel ALB_Str_Ptr]");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_pure_slot_ok");
      Line ("  xor rax, rax");
      Line (".fmt_pure_slot_ok:");
      Line ("  mov r12, rax");
      Line ("  lea rbx, [rel ALB_Str_Pool]");
      Line ("  add rbx, rax");
      Line ("  mov r9d, r10d");
      Line ("  mov r8, r10");
      Line ("  sar r8, 32");
      Line ("  invoke sprintf, rbx, ALB_Fmt_Pure_Raw, r8, r9");
      Line ("  xor r11, r11");
      Line (".fmt_pure_len:");
      Line ("  cmp byte [rbx + r11], 0");
      Line ("  je .fmt_pure_len_done");
      Line ("  inc r11");
      Line ("  jmp .fmt_pure_len");
      Line (".fmt_pure_len_done:");
      Line ("  inc r11");
      Line ("  mov rax, r12");
      Line ("  add rax, r11");
      Line ("  add rax, 7");
      Line ("  and rax, -8");
      Line ("  cmp rax, 1048576");
      Line ("  jl .fmt_pure_bump_ok");
      Line ("  xor rax, rax");
      Line (".fmt_pure_bump_ok:");
      Line ("  mov qword [rel ALB_Str_Ptr], rax");
      Line ("  mov rax, rbx");
      Line ("  pop r12");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_String_Chr:");
      Line ("  movzx rax, cl");
      Line ("  shl rax, 1");
      Line ("  lea r8, [rel ALB_Chr_Table]");
      Line ("  add r8, rax");
      Line ("  mov byte [r8], cl");
      Line ("  mov byte [r8 + 1], 0");
      Line ("  mov rax, r8");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_String_Asc:");
      Line ("  test rcx, rcx");
      Line ("  jz .asc_zero");
      Line ("  movzx rax, byte [rcx]");
      Line ("  ret");
      Line (".asc_zero:");
      Line ("  xor rax, rax");
      Line ("  ret");
      Emit_Newline (S);

      -- DA ALB_CON INTRINSIC BRIDGE TABLE
      Line ("ALB_CON_LEFT:");
      Line ("  jmp ALB_String_Left");
      Emit_Newline(S);

      Line ("ALB_CON_RIGHT:");
      Line ("  jmp ALB_String_Right");
      Emit_Newline(S);

      Line ("ALB_CON_CHR:");
      Line ("  jmp ALB_String_Chr");
      Emit_Newline(S);

      Line ("ALB_CON_CONCAT:");
      Line ("  jmp ALB_String_Concat");
      Emit_Newline(S);

      
      Append ("ALB_File_From_Handle:", S); Emit_Newline(S);
      Append ("  cmp rcx, 1", S); Emit_Newline(S);
      Append ("  jb .invalid", S); Emit_Newline(S);
      Append ("  cmp rcx, 255", S); Emit_Newline(S);
      Append ("  ja .invalid", S); Emit_Newline(S);
      --  NASM: [rel label + reg*scale] is illegal — lea base, then index.
      Append ("  lea rax, [rel ALB_File_Table]", S); Emit_Newline(S);
      Append ("  mov rax, qword [rax + rcx*8]", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Append (".invalid:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_File_Open:", S); Emit_Newline(S);
      Append ("  sub rsp, 56", S); Emit_Newline(S);
      Append ("  test rcx, rcx", S); Emit_Newline(S);
      Append ("  jz .open_fail", S); Emit_Newline(S);
      Append ("  test rdx, rdx", S); Emit_Newline(S);
      Append ("  jz .open_fail", S); Emit_Newline(S);
      Append ("  mov r10d, GENERIC_READ", S); Emit_Newline(S);
      Append ("  mov r11d, OPEN_EXISTING", S); Emit_Newline(S);
      Append ("  movzx eax, byte [rdx]", S); Emit_Newline(S);
      Append ("  or al, 32", S); Emit_Newline(S);
      Append ("  cmp al, 'w'", S); Emit_Newline(S);
      Append ("  je .write_mode", S); Emit_Newline(S);
      Append ("  cmp al, 'a'", S); Emit_Newline(S);
      Append ("  je .append_mode", S); Emit_Newline(S);
      Append ("  jmp .open_mode_ready", S); Emit_Newline(S);
      Append (".write_mode:", S); Emit_Newline(S);
      Append ("  mov r10d, GENERIC_WRITE", S); Emit_Newline(S);
      Append ("  mov r11d, CREATE_ALWAYS", S); Emit_Newline(S);
      Append ("  jmp .open_mode_ready", S); Emit_Newline(S);
      Append (".append_mode:", S); Emit_Newline(S);
      Append ("  mov r10d, 4", S); Emit_Newline(S);
      Append ("  mov r11d, OPEN_ALWAYS", S); Emit_Newline(S);
      Append (".open_mode_ready:", S); Emit_Newline(S);
      Append ("  invoke CreateFileA, rcx, r10, 0, 0, r11, FILE_ATTRIBUTE_NORMAL, 0", S); Emit_Newline(S);
      Append ("  cmp rax, -1", S); Emit_Newline(S);
      Append ("  jz .open_fail", S); Emit_Newline(S);
      Append ("  mov r10, rax", S); Emit_Newline(S);
      Append ("  mov r8, 1", S); Emit_Newline(S);
      Append (".find_slot:", S); Emit_Newline(S);
      Append ("  cmp r8, 256", S); Emit_Newline(S);
      Append ("  jae .no_slot", S); Emit_Newline(S);
      Append ("  lea rax, [rel ALB_File_Table]", S); Emit_Newline(S);
      Append ("  cmp qword [rax + r8*8], 0", S); Emit_Newline(S);
      Append ("  je .store_slot", S); Emit_Newline(S);
      Append ("  inc r8", S); Emit_Newline(S);
      Append ("  jmp .find_slot", S); Emit_Newline(S);
      Append (".store_slot:", S); Emit_Newline(S);
      Append ("  lea rax, [rel ALB_File_Table]", S); Emit_Newline(S);
      Append ("  mov qword [rax + r8*8], r10", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  add rsp, 56", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Append (".no_slot:", S); Emit_Newline(S);
      Append ("  mov rcx, r10", S); Emit_Newline(S);
      Append ("  invoke CloseHandle, rcx", S); Emit_Newline(S);
      Append (".open_fail:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  add rsp, 56", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_File_Read:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  mov r11, rdx", S); Emit_Newline(S);
      Append ("  call ALB_File_From_Handle", S); Emit_Newline(S);
      Append ("  mov rdx, r11", S); Emit_Newline(S);
      Append ("  mov rcx, rax", S); Emit_Newline(S);
      Append ("  test rcx, rcx", S); Emit_Newline(S);
      Append ("  jnz .have_file", S); Emit_Newline(S);
      Append ("  lea rax, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  mov byte [rax], 0", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  ret", S); Emit_Newline(S);

      Append (".have_file:", S); Emit_Newline(S);
      Append ("  test rdx, rdx", S); Emit_Newline(S);
      Append ("  jnz .binary_read", S); Emit_Newline(S);
      Append ("  mov qword [rsp+32], rcx", S); Emit_Newline(S);
      Append ("  xor r8, r8", S); Emit_Newline(S);
      Append (".line_read_loop:", S); Emit_Newline(S);
      Append ("  cmp r8, 65535", S); Emit_Newline(S);
      Append ("  jae .line_done", S); Emit_Newline(S);
      Append ("  mov qword [rsp+24], r8", S); Emit_Newline(S);
      Append ("  mov r10, qword [rsp+32]", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  add rdx, r8", S); Emit_Newline(S);
      Append ("  invoke ReadFile, r10, rdx, 1, addr ALB_File_IO_Count, 0", S); Emit_Newline(S);
      Append ("  mov r8, qword [rsp+24]", S); Emit_Newline(S);
      Append ("  cmp dword [rel ALB_File_IO_Count], 0", S); Emit_Newline(S);
      Append ("  je .line_done", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  mov al, byte [rdx + r8]", S); Emit_Newline(S);
      Append ("  inc r8", S); Emit_Newline(S);
      Append ("  cmp al, 10", S); Emit_Newline(S);
      Append ("  je .line_done", S); Emit_Newline(S);
      Append ("  jmp .line_read_loop", S); Emit_Newline(S);
      Append (".line_done:", S); Emit_Newline(S);
      Append ("  lea rax, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  mov byte [rax + r8], 0", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  ret", S); Emit_Newline(S);

      Append (".binary_read:", S); Emit_Newline(S);
      Append ("  cmp rdx, 65535", S); Emit_Newline(S);
      Append ("  jbe .len_ok", S); Emit_Newline(S);
      Append ("  mov rdx, 65535", S); Emit_Newline(S);

      Append (".len_ok:", S); Emit_Newline(S);
      Append ("  mov r8, rdx", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  lea r9, [rel ALB_File_IO_Count]", S); Emit_Newline(S);
      Append ("  mov qword [rsp+32], 0", S); Emit_Newline(S);
      Append ("  mov dword [rel ALB_File_IO_Count], 0", S); Emit_Newline(S);
      Append ("  call [ReadFile]", S); Emit_Newline(S);
      Append ("  mov eax, dword [rel ALB_File_IO_Count]", S); Emit_Newline(S);
      Append ("  cmp eax, 65535", S); Emit_Newline(S);
      Append ("  jbe .nul_ok", S); Emit_Newline(S);
      Append ("  mov eax, 65535", S); Emit_Newline(S);
      Append (".nul_ok:", S); Emit_Newline(S);
      Append ("  lea rcx, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  mov byte [rcx + rax], 0", S); Emit_Newline(S);

      Append (".return_buffer:", S); Emit_Newline(S);
      Append ("  lea rax, [rel ALB_File_Buffer]", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_File_Write:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S);
      Append ("  mov r8, rcx", S); Emit_Newline(S);
      Append ("  mov rcx, rdx", S); Emit_Newline(S);
      Append ("  call ALB_File_From_Handle", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jz .write_done", S); Emit_Newline(S);
      Append ("  mov r10, rax", S); Emit_Newline(S);
      Append ("  mov rcx, r8", S); Emit_Newline(S);
      Append ("  test rcx, rcx", S); Emit_Newline(S);
      Append ("  jz .write_done", S); Emit_Newline(S);
      Append ("  cmp rcx, 65535", S); Emit_Newline(S);
      Append ("  ja .have_text", S); Emit_Newline(S);
      Append ("  mov rax, rcx", S); Emit_Newline(S);
      Append ("  call ALB_String_From_S64", S); Emit_Newline(S);
      Append ("  mov rcx, rax", S); Emit_Newline(S);
      Append (".have_text:", S); Emit_Newline(S);
      Append ("  xor r8, r8", S); Emit_Newline(S);
      Append (".write_len_loop:", S); Emit_Newline(S);
      Append ("  cmp byte [rcx + r8], 0", S); Emit_Newline(S);
      Append ("  je .write_len_done", S); Emit_Newline(S);
      Append ("  inc r8", S); Emit_Newline(S);
      Append ("  jmp .write_len_loop", S); Emit_Newline(S);
      Append (".write_len_done:", S); Emit_Newline(S);
      Append ("  test r8, r8", S); Emit_Newline(S);
      Append ("  jz .write_done", S); Emit_Newline(S);
      Append ("  invoke WriteFile, r10, rcx, r8, addr ALB_File_IO_Count, 0", S); Emit_Newline(S);
      Append (".write_done:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_File_Close:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S);
      Append ("  mov qword [rsp+32], rcx", S); Emit_Newline(S);
      Append ("  call ALB_File_From_Handle", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jz .close_done", S); Emit_Newline(S);
      Append ("  mov rcx, rax", S); Emit_Newline(S);
      Append ("  invoke CloseHandle, rcx", S); Emit_Newline(S);
      Append ("  mov r8, qword [rsp+32]", S); Emit_Newline(S);
      Append ("  lea rax, [rel ALB_File_Table]", S); Emit_Newline(S);
      Append ("  mov qword [rax + r8*8], 0", S); Emit_Newline(S);
      Append (".close_done:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_File_Len:", S); Emit_Newline(S);
      Append ("  sub rsp, 56", S); Emit_Newline(S);
      Append ("  test rcx, rcx", S); Emit_Newline(S);
      Append ("  jz .len_fail", S); Emit_Newline(S);
      Append ("  invoke CreateFileA, rcx, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0", S); Emit_Newline(S);
      Append ("  cmp rax, -1", S); Emit_Newline(S);
      Append ("  je .len_fail", S); Emit_Newline(S);
      Append ("  mov qword [rsp+32], rax", S); Emit_Newline(S);
      Append ("  mov rcx, qword [rsp+32]", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_File_SizeQ]", S); Emit_Newline(S);
      Append ("  invoke GetFileSizeEx, rcx, rdx", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jz .len_close_fail", S); Emit_Newline(S);
      Append ("  mov rcx, qword [rsp+32]", S); Emit_Newline(S);
      Append ("  invoke CloseHandle, rcx", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_File_SizeQ]", S); Emit_Newline(S);
      Append ("  add rsp, 56", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Append (".len_close_fail:", S); Emit_Newline(S);
      Append ("  mov rcx, qword [rsp+32]", S); Emit_Newline(S);
      Append ("  invoke CloseHandle, rcx", S); Emit_Newline(S);
      Append (".len_fail:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  add rsp, 56", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_File_Seek:", S); Emit_Newline(S);
      Append ("  sub rsp, 56", S); Emit_Newline(S);
      Append ("  mov qword [rsp+32], rdx", S); Emit_Newline(S);
      Append ("  call ALB_File_From_Handle", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jz .seek_fail", S); Emit_Newline(S);
      Append ("  mov rcx, rax", S); Emit_Newline(S);
      Append ("  mov rdx, qword [rsp+32]", S); Emit_Newline(S);
      Append ("  lea r8, [rel ALB_File_SizeQ]", S); Emit_Newline(S);
      Append ("  xor r9, r9", S); Emit_Newline(S);
      Append ("  invoke SetFilePointerEx, rcx, rdx, r8, r9", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jz .seek_fail", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_File_SizeQ]", S); Emit_Newline(S);
      Append ("  add rsp, 56", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Append (".seek_fail:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  add rsp, 56", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);
      
      Append ("ALB_Throw_Native:", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  mov qword [rel ALB_Last_Err], rcx", S); Emit_Newline(S);
      Append ("  cmp qword [rel ALB_Err_SP], 0", S); Emit_Newline(S);
      Append ("  jl .alb_throw_unhandled", S); Emit_Newline(S);
      Append ("  mov rax, qword [rel ALB_Err_SP]", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_Err_Target_Stack]", S); Emit_Newline(S);
      Append ("  mov rax, qword [rdx + rax*8]", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S); -- DA FIX
      Append ("  jmp rax", S); Emit_Newline(S);
      Append (".alb_throw_unhandled:", S); Emit_Newline(S);
      Append ("  invoke ExitProcess, 1", S); Emit_Newline(S);
      Emit_Newline(S);
      
      
      -- ALB FFI loader: LoadLibraryA for bare names; LoadLibraryExA with
      -- LOAD_WITH_ALTERED_SEARCH_PATH (8) for path-qualified names so RHI
      -- DLLs remapped by --gfx= (e.g. .../stdlib/vendor/alb_gfx/bin/
      -- alb_gfx_opengl.dll) also resolve sibling thin backends
      -- (alb_opengl.dll / alb_vulkan.dll / alb_d3d6..12.dll).
      Append ("ALB_Load_Foreign_Symbol:", S); Emit_Newline(S);
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  push rdi", S); Emit_Newline(S);
      Append ("  sub rsp, 40", S); Emit_Newline(S);
      Append ("  mov rbx, rdx", S); Emit_Newline(S);
      Append ("  mov rdi, rcx", S); Emit_Newline(S);
      Append ("  mov r10, rcx", S); Emit_Newline(S);
      Append (".alb_foreign_path_check:", S); Emit_Newline(S);
      Append ("  mov al, byte [r10]", S); Emit_Newline(S);
      Append ("  test al, al", S); Emit_Newline(S);
      Append ("  jz .alb_foreign_load_bare", S); Emit_Newline(S);
      Append ("  cmp al, '/'", S); Emit_Newline(S);
      Append ("  je .alb_foreign_load_path", S); Emit_Newline(S);
      Append ("  cmp al, 92", S); Emit_Newline(S);
      Append ("  je .alb_foreign_load_path", S); Emit_Newline(S);
      Append ("  cmp al, ':'", S); Emit_Newline(S);
      Append ("  je .alb_foreign_load_path", S); Emit_Newline(S);
      Append ("  inc r10", S); Emit_Newline(S);
      Append ("  jmp .alb_foreign_path_check", S); Emit_Newline(S);
      Append (".alb_foreign_load_bare:", S); Emit_Newline(S);
      Append ("  invoke LoadLibraryA, rcx", S); Emit_Newline(S);
      Append ("  jmp .alb_foreign_loaded_first", S); Emit_Newline(S);
      Append (".alb_foreign_load_path:", S); Emit_Newline(S);
      Append ("  invoke LoadLibraryExA, rcx, 0, 8", S); Emit_Newline(S);
      Append (".alb_foreign_loaded_first:", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jnz .alb_foreign_have_lib", S); Emit_Newline(S);
      Append ("  mov rcx, rdi", S); Emit_Newline(S);
      Append ("  mov edx, 1024", S); Emit_Newline(S);
      Append ("  lea r8, [rel ALB_Foreign_Load_Path]", S); Emit_Newline(S);
      Append ("  xor r9d, r9d", S); Emit_Newline(S);
      Append ("  invoke GetFullPathNameA, rcx, rdx, r8, r9", S); Emit_Newline(S);
      Append ("  test eax, eax", S); Emit_Newline(S);
      Append ("  jz .alb_foreign_try_module_dir", S); Emit_Newline(S);
      Append ("  lea rcx, [rel ALB_Foreign_Load_Path]", S); Emit_Newline(S);
      Append ("  invoke LoadLibraryExA, rcx, 0, 8", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jnz .alb_foreign_have_lib", S); Emit_Newline(S);
      Append (".alb_foreign_try_module_dir:", S); Emit_Newline(S);
      Append ("  xor rcx, rcx", S); Emit_Newline(S);
      Append ("  lea rdx, [rel ALB_Foreign_Load_Path]", S); Emit_Newline(S);
      Append ("  mov r8d, 1024", S); Emit_Newline(S);
      Append ("  invoke GetModuleFileNameA, rcx, rdx, r8", S); Emit_Newline(S);
      Append ("  test eax, eax", S); Emit_Newline(S);
      Append ("  jz .alb_foreign_fail", S); Emit_Newline(S);
      Append ("  lea r8, [rel ALB_Foreign_Load_Path]", S); Emit_Newline(S);
      Append ("  mov rcx, r8", S); Emit_Newline(S);
      Append (".alb_foreign_find_end:", S); Emit_Newline(S);
      Append ("  mov al, byte [rcx]", S); Emit_Newline(S);
      Append ("  test al, al", S); Emit_Newline(S);
      Append ("  jz .alb_foreign_scan_back", S); Emit_Newline(S);
      Append ("  inc rcx", S); Emit_Newline(S);
      Append ("  jmp .alb_foreign_find_end", S); Emit_Newline(S);
      Append (".alb_foreign_scan_back:", S); Emit_Newline(S);
      Append ("  cmp rcx, r8", S); Emit_Newline(S);
      Append ("  jbe .alb_foreign_use_base", S); Emit_Newline(S);
      Append ("  dec rcx", S); Emit_Newline(S);
      Append ("  cmp byte [rcx], 92", S); Emit_Newline(S);
      Append ("  je .alb_foreign_found_sep", S); Emit_Newline(S);
      Append ("  cmp byte [rcx], '/'", S); Emit_Newline(S);
      Append ("  je .alb_foreign_found_sep", S); Emit_Newline(S);
      Append ("  jmp .alb_foreign_scan_back", S); Emit_Newline(S);
      Append (".alb_foreign_use_base:", S); Emit_Newline(S);
      Append ("  mov rcx, r8", S); Emit_Newline(S);
      Append ("  jmp .alb_foreign_copy_name", S); Emit_Newline(S);
      Append (".alb_foreign_found_sep:", S); Emit_Newline(S);
      Append ("  inc rcx", S); Emit_Newline(S);
      Append (".alb_foreign_copy_name:", S); Emit_Newline(S);
      Append ("  mov rdx, rdi", S); Emit_Newline(S);
      Append (".alb_foreign_copy_loop:", S); Emit_Newline(S);
      Append ("  mov al, byte [rdx]", S); Emit_Newline(S);
      Append ("  mov byte [rcx], al", S); Emit_Newline(S);
      Append ("  inc rcx", S); Emit_Newline(S);
      Append ("  inc rdx", S); Emit_Newline(S);
      Append ("  test al, al", S); Emit_Newline(S);
      Append ("  jnz .alb_foreign_copy_loop", S); Emit_Newline(S);
      Append ("  lea rcx, [rel ALB_Foreign_Load_Path]", S); Emit_Newline(S);
      Append ("  invoke LoadLibraryExA, rcx, 0, 8", S); Emit_Newline(S);
      Append ("  test rax, rax", S); Emit_Newline(S);
      Append ("  jnz .alb_foreign_have_lib", S); Emit_Newline(S);
      Append (".alb_foreign_fail:", S); Emit_Newline(S);
      Append ("  xor rax, rax", S); Emit_Newline(S);
      Append ("  jmp .alb_foreign_done", S); Emit_Newline(S);
      Append (".alb_foreign_have_lib:", S); Emit_Newline(S);
      Append ("  mov rdx, rbx", S); Emit_Newline(S);
      Append ("  mov rcx, rax", S); Emit_Newline(S);
      Append ("  invoke GetProcAddress, rcx, rdx", S); Emit_Newline(S);
      Append (".alb_foreign_done:", S); Emit_Newline(S);
      Append ("  add rsp, 40", S); Emit_Newline(S);
      Append ("  pop rdi", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);

      Append ("ALB_Pure_Normalize:", S); Emit_Newline(S);
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  mov r8, rax", S); Emit_Newline(S);
      Append ("  sar r8, 32", S); Emit_Newline(S);
      Append ("  movsxd r9, eax", S); Emit_Newline(S);
      Append ("  test r9, r9", S); Emit_Newline(S);
      Append ("  jz ALB_Runtime_Trap_DivZero", S); Emit_Newline(S);
      Append ("  test r9, r9", S); Emit_Newline(S);
      Append ("  jge .pure_den_positive", S); Emit_Newline(S);
      Append ("  neg r9", S); Emit_Newline(S);
      Append ("  neg r8", S); Emit_Newline(S);
      Append (".pure_den_positive:", S); Emit_Newline(S);
      Append ("  test r8, r8", S); Emit_Newline(S);
      Append ("  jnz .pure_nonzero", S); Emit_Newline(S);
      Append ("  mov rax, 1", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Append (".pure_nonzero:", S); Emit_Newline(S);
      Append ("  xor rbx, rbx", S); Emit_Newline(S);
      Append ("  test r8, r8", S); Emit_Newline(S);
      Append ("  jge .pure_num_abs", S); Emit_Newline(S);
      Append ("  neg r8", S); Emit_Newline(S);
      Append ("  mov rbx, 1", S); Emit_Newline(S);
      Append (".pure_num_abs:", S); Emit_Newline(S);
      Append ("  mov r10, r8", S); Emit_Newline(S);
      Append ("  mov r11, r9", S); Emit_Newline(S);
      Append (".pure_gcd_loop:", S); Emit_Newline(S);
      Append ("  test r11, r11", S); Emit_Newline(S);
      Append ("  jz .pure_gcd_done", S); Emit_Newline(S);
      Append ("  mov rax, r10", S); Emit_Newline(S);
      Append ("  xor rdx, rdx", S); Emit_Newline(S);
      Append ("  div r11", S); Emit_Newline(S);
      Append ("  mov r10, r11", S); Emit_Newline(S);
      Append ("  mov r11, rdx", S); Emit_Newline(S);
      Append ("  jmp .pure_gcd_loop", S); Emit_Newline(S);
      Append (".pure_gcd_done:", S); Emit_Newline(S);
      Append ("  mov rax, r9", S); Emit_Newline(S);
      Append ("  xor rdx, rdx", S); Emit_Newline(S);
      Append ("  div r10", S); Emit_Newline(S);
      Append ("  mov r9, rax", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  xor rdx, rdx", S); Emit_Newline(S);
      Append ("  div r10", S); Emit_Newline(S);
      Append ("  test rbx, rbx", S); Emit_Newline(S);
      Append ("  jz .pure_pack", S); Emit_Newline(S);
      Append ("  neg rax", S); Emit_Newline(S);
      Append (".pure_pack:", S); Emit_Newline(S);
      Append ("  shl rax, 32", S); Emit_Newline(S);
      Append ("  mov rcx, 0xFFFFFFFF", S); Emit_Newline(S);
      Append ("  and r9, rcx", S); Emit_Newline(S);
      Append ("  or rax, r9", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      Emit_Newline(S);
      
      -- ==========================================================
      -- DA PURE MATH 64-BIT PACKED RUNTIME FORGE
      -- ==========================================================
      Append ("ALB_Pure_Add:", S); Emit_Newline(S);
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  mov r8, rcx", S); Emit_Newline(S);
      Append ("  sar r8, 32", S); Emit_Newline(S);
      Append ("  movsxd r9, ecx", S); Emit_Newline(S);
      Append ("  mov r10, rdx", S); Emit_Newline(S);
      Append ("  sar r10, 32", S); Emit_Newline(S);
      Append ("  movsxd r11, edx", S); Emit_Newline(S);
      Append ("  mov rax, r9", S); Emit_Newline(S);
      Append ("  imul rax, r11", S); Emit_Newline(S);
      Append ("  mov rbx, rax", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  imul rax, r11", S); Emit_Newline(S);
      Append ("  mov r8, rax", S); Emit_Newline(S);
      Append ("  mov rax, r10", S); Emit_Newline(S);
      Append ("  imul rax, r9", S); Emit_Newline(S);
      Append ("  add r8, rax", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  shl rax, 32", S); Emit_Newline(S);
      Append ("  mov r11, 0xFFFFFFFF", S); Emit_Newline(S);
      Append ("  and rbx, r11", S); Emit_Newline(S);
      Append ("  or rax, rbx", S); Emit_Newline(S);
      Append ("  call ALB_Pure_Normalize", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);

      Append ("ALB_Pure_Sub:", S); Emit_Newline(S);
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  mov r8, rcx", S); Emit_Newline(S);
      Append ("  sar r8, 32", S); Emit_Newline(S);
      Append ("  movsxd r9, ecx", S); Emit_Newline(S);
      Append ("  mov r10, rdx", S); Emit_Newline(S);
      Append ("  sar r10, 32", S); Emit_Newline(S);
      Append ("  movsxd r11, edx", S); Emit_Newline(S);
      Append ("  mov rax, r9", S); Emit_Newline(S);
      Append ("  imul rax, r11", S); Emit_Newline(S);
      Append ("  mov rbx, rax", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  imul rax, r11", S); Emit_Newline(S);
      Append ("  mov r8, rax", S); Emit_Newline(S);
      Append ("  mov rax, r10", S); Emit_Newline(S);
      Append ("  imul rax, r9", S); Emit_Newline(S);
      Append ("  sub r8, rax", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  shl rax, 32", S); Emit_Newline(S);
      Append ("  mov r11, 0xFFFFFFFF", S); Emit_Newline(S);
      Append ("  and rbx, r11", S); Emit_Newline(S);
      Append ("  or rax, rbx", S); Emit_Newline(S);
      Append ("  call ALB_Pure_Normalize", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);

      Append ("ALB_Pure_Mul:", S); Emit_Newline(S);
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  mov r8, rcx", S); Emit_Newline(S);
      Append ("  sar r8, 32", S); Emit_Newline(S);
      Append ("  movsxd r9, ecx", S); Emit_Newline(S);
      Append ("  mov r10, rdx", S); Emit_Newline(S);
      Append ("  sar r10, 32", S); Emit_Newline(S);
      Append ("  movsxd r11, edx", S); Emit_Newline(S);
      Append ("  mov rax, r9", S); Emit_Newline(S);
      Append ("  imul rax, r11", S); Emit_Newline(S);
      Append ("  mov rbx, rax", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  imul rax, r10", S); Emit_Newline(S);
      Append ("  shl rax, 32", S); Emit_Newline(S);
      Append ("  mov r11, 0xFFFFFFFF", S); Emit_Newline(S);
      Append ("  and rbx, r11", S); Emit_Newline(S);
      Append ("  or rax, rbx", S); Emit_Newline(S);
      Append ("  call ALB_Pure_Normalize", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);

      Append ("ALB_Pure_Div:", S); Emit_Newline(S);
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  mov r8, rcx", S); Emit_Newline(S);
      Append ("  sar r8, 32", S); Emit_Newline(S);
      Append ("  movsxd r9, ecx", S); Emit_Newline(S);
      Append ("  mov r10, rdx", S); Emit_Newline(S);
      Append ("  sar r10, 32", S); Emit_Newline(S);
      Append ("  movsxd r11, edx", S); Emit_Newline(S);
      Append ("  test r10, r10", S); Emit_Newline(S);
      Append ("  jz ALB_Runtime_Trap_DivZero", S); Emit_Newline(S);
      Append ("  mov rax, r9", S); Emit_Newline(S);
      Append ("  imul rax, r10", S); Emit_Newline(S);
      Append ("  mov rbx, rax", S); Emit_Newline(S);
      Append ("  mov rax, r8", S); Emit_Newline(S);
      Append ("  imul rax, r11", S); Emit_Newline(S);
      Append ("  shl rax, 32", S); Emit_Newline(S);
      Append ("  mov r11, 0xFFFFFFFF", S); Emit_Newline(S);
      Append ("  and rbx, r11", S); Emit_Newline(S);
      Append ("  or rax, rbx", S); Emit_Newline(S);
      Append ("  call ALB_Pure_Normalize", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);

      Append ("ALB_Pure_Pow:", S); Emit_Newline(S);
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  push rsi", S); Emit_Newline(S);
      Append ("  push rdi", S); Emit_Newline(S);
      Append ("  mov rsi, rcx", S); Emit_Newline(S);
      Append ("  movsxd rax, edx", S); Emit_Newline(S);
      Append ("  cmp rax, 1", S); Emit_Newline(S);
      Append ("  jne ALB_Runtime_Trap_Range", S); Emit_Newline(S);
      Append ("  mov rdi, rdx", S); Emit_Newline(S);
      Append ("  sar rdi, 32", S); Emit_Newline(S);
      Append ("  mov rbx, 0x0000000100000001", S); Emit_Newline(S);
      Append ("  test rdi, rdi", S); Emit_Newline(S);
      Append ("  jz .pure_pow_done", S); Emit_Newline(S);
      Append ("  jge .pure_pow_exp_ready", S); Emit_Newline(S);
      Append ("  mov rcx, 0x0000000100000001", S); Emit_Newline(S);
      Append ("  mov rdx, rsi", S); Emit_Newline(S);
      Append ("  call ALB_Pure_Div", S); Emit_Newline(S);
      Append ("  mov rsi, rax", S); Emit_Newline(S);
      Append ("  neg rdi", S); Emit_Newline(S);
      Append (".pure_pow_exp_ready:", S); Emit_Newline(S);
      Append (".pure_pow_loop:", S); Emit_Newline(S);
      Append ("  test rdi, 1", S); Emit_Newline(S);
      Append ("  jz .pure_pow_skip_mul", S); Emit_Newline(S);
      Append ("  mov rcx, rbx", S); Emit_Newline(S);
      Append ("  mov rdx, rsi", S); Emit_Newline(S);
      Append ("  call ALB_Pure_Mul", S); Emit_Newline(S);
      Append ("  mov rbx, rax", S); Emit_Newline(S);
      Append (".pure_pow_skip_mul:", S); Emit_Newline(S);
      Append ("  shr rdi, 1", S); Emit_Newline(S);
      Append ("  jz .pure_pow_done", S); Emit_Newline(S);
      Append ("  mov rcx, rsi", S); Emit_Newline(S);
      Append ("  mov rdx, rsi", S); Emit_Newline(S);
      Append ("  call ALB_Pure_Mul", S); Emit_Newline(S);
      Append ("  mov rsi, rax", S); Emit_Newline(S);
      Append ("  jmp .pure_pow_loop", S); Emit_Newline(S);
      Append (".pure_pow_done:", S); Emit_Newline(S);
      Append ("  mov rax, rbx", S); Emit_Newline(S);
      Append ("  pop rdi", S); Emit_Newline(S);
      Append ("  pop rsi", S); Emit_Newline(S);
      Append ("  pop rbx", S); Emit_Newline(S);
      Append ("  ret", S); Emit_Newline(S);
      
      -- This sits right aboon the start label!
      Append ("start:", S); Emit_Newline(S);

      if Current_Format = Format_PE64_DLL then
         Append ("  cmp edx, 1", S); Emit_Newline(S);
         Append ("  jne ALB_DLL_RETURN_TRUE", S); Emit_Newline(S);
      end if;

      -- DA NEW FIX: Windows x64 ABI mandates stack alignment and shadow space!
      Append ("  sub rsp, 8", S); Emit_Newline(S);
      Append ("  sub rsp, 128", S); Emit_Newline(S); -- Massive 128-byte frame for 12+ Win32 arguments!

      -- DA NEW FIX: Prime the error registers for the ALB runtime!
      Append ("  mov qword [rel ALB_Err_SP], -1", S); Emit_Newline(S);
      Append ("  mov qword [rel ALB_Last_Err], 0", S); Emit_Newline(S);
      
      In_Global_Scope := False;
      Increase_Indent;
      Success := S;
      
      
   end Emit_Program_Start;

   procedure Emit_Program_End (Success : out Boolean) is
      S : Boolean;
   begin
      Current_Buffer := Buffer_Main;
      -- DA NEW FIX: Flush all msvcrt streams afore killin' the process!
      --Emit_Indent(S); Append ("invoke fflush, 0", S); Emit_Newline(S);
      if Current_Format = Format_PE64_DLL then
         Emit_Indent(S); Append ("add rsp, 128", S); Emit_Newline(S);
         Emit_Indent(S); Append ("add rsp, 8", S); Emit_Newline(S);
         Emit_Indent(S); Append ("mov eax, 1", S); Emit_Newline(S);
         Emit_Indent(S); Append ("ret", S); Emit_Newline(S);
         Append ("ALB_DLL_RETURN_TRUE:", S); Emit_Newline(S);
         Append ("  mov eax, 1", S); Emit_Newline(S);
         Append ("  ret", S); Emit_Newline(S);
      else
         Emit_Indent(S); Append ("invoke ExitProcess, 0", S); Emit_Newline(S);
      end if;
      
      Emit_Newline(S);
      -- NASM -f win64 emits COFF; imports are resolved by the linker via externs
      -- (win64nasm.inc also declares a baseline set; these cover the full ALB surface).
      Append ("; --- Win64 DLL imports (linker-resolved) ---", S); Emit_Newline(S);
      Append ("extern ExitProcess", S); Emit_Newline(S);
      Append ("extern CreateProcessA", S); Emit_Newline(S);
      Append ("extern CreateThread", S); Emit_Newline(S);
      Append ("extern GetFullPathNameA", S); Emit_Newline(S);
      Append ("extern GetModuleFileNameA", S); Emit_Newline(S);
      Append ("extern GetModuleHandleA", S); Emit_Newline(S);
      Append ("extern GetCurrentProcess", S); Emit_Newline(S);
      Append ("extern GetCurrentProcessId", S); Emit_Newline(S);
      Append ("extern LoadLibraryA", S); Emit_Newline(S);
      Append ("extern LoadLibraryExA", S); Emit_Newline(S);
      Append ("extern GetProcAddress", S); Emit_Newline(S);
      Append ("extern CreateFileA", S); Emit_Newline(S);
      Append ("extern CreateFileMappingA", S); Emit_Newline(S);
      Append ("extern MapViewOfFile", S); Emit_Newline(S);
      Append ("extern UnmapViewOfFile", S); Emit_Newline(S);
      Append ("extern ReadFile", S); Emit_Newline(S);
      Append ("extern ReadProcessMemory", S); Emit_Newline(S);
      Append ("extern WriteProcessMemory", S); Emit_Newline(S);
      Append ("extern VirtualProtect", S); Emit_Newline(S);
      Append ("extern VirtualAllocEx", S); Emit_Newline(S);
      Append ("extern VirtualAlloc", S); Emit_Newline(S);
      Append ("extern CreateRemoteThread", S); Emit_Newline(S);
      Append ("extern WriteFile", S); Emit_Newline(S);
      Append ("extern CloseHandle", S); Emit_Newline(S);
      Append ("extern TerminateProcess", S); Emit_Newline(S);
      Append ("extern GetFileSizeEx", S); Emit_Newline(S);
      Append ("extern SetFilePointerEx", S); Emit_Newline(S);
      Append ("extern Sleep", S); Emit_Newline(S);
      Append ("extern CreateWindowExA", S); Emit_Newline(S);
      Append ("extern PeekMessageA", S); Emit_Newline(S);
      Append ("extern TranslateMessage", S); Emit_Newline(S);
      Append ("extern DispatchMessageA", S); Emit_Newline(S);
      Append ("extern DefWindowProcA", S); Emit_Newline(S);
      Append ("extern RegisterClassExA", S); Emit_Newline(S);
      Append ("extern GetDC", S); Emit_Newline(S);
      Append ("extern ReleaseDC", S); Emit_Newline(S);
      Append ("extern GetClientRect", S); Emit_Newline(S);
      Append ("extern WindowFromDC", S); Emit_Newline(S);
      Append ("extern LoadCursorA", S); Emit_Newline(S);
      Append ("extern FillRect", S); Emit_Newline(S);
      Append ("extern ValidateRect", S); Emit_Newline(S);
      Append ("extern GetAsyncKeyState", S); Emit_Newline(S);
      Append ("extern PostQuitMessage", S); Emit_Newline(S);
      Append ("extern CreateCompatibleDC", S); Emit_Newline(S);
      Append ("extern CreateCompatibleBitmap", S); Emit_Newline(S);
      Append ("extern SelectObject", S); Emit_Newline(S);
      Append ("extern BitBlt", S); Emit_Newline(S);
      Append ("extern CreateSolidBrush", S); Emit_Newline(S);
      Append ("extern DeleteObject", S); Emit_Newline(S);
      Append ("extern TextOutA", S); Emit_Newline(S);
      Append ("extern SetTextColor", S); Emit_Newline(S);
      Append ("extern SetBkMode", S); Emit_Newline(S);
      Append ("extern GetStockObject", S); Emit_Newline(S);
      Append ("extern printf", S); Emit_Newline(S);
      Append ("extern sprintf", S); Emit_Newline(S);
      Append ("extern _gcvt", S); Emit_Newline(S);
      Append ("extern pow", S); Emit_Newline(S);
      Append ("extern fflush", S); Emit_Newline(S);
      Append ("extern scanf", S); Emit_Newline(S);
      Append ("extern gets", S); Emit_Newline(S);
      Append ("extern fopen", S); Emit_Newline(S);
      Append ("extern fclose", S); Emit_Newline(S);
      Append ("extern fputs", S); Emit_Newline(S);
      Append ("extern fgets", S); Emit_Newline(S);
      Append ("extern fread", S); Emit_Newline(S);
      Append ("extern fseek", S); Emit_Newline(S);
      Append ("extern fwrite", S); Emit_Newline(S);
      Append ("extern rename", S); Emit_Newline(S);
      Append ("extern PlaySoundA", S); Emit_Newline(S);
      Append ("extern OpenProcessToken", S); Emit_Newline(S);
      Append ("extern LookupPrivilegeValueA", S); Emit_Newline(S);
      Append ("extern AdjustTokenPrivileges", S); Emit_Newline(S);

      if Current_Format = Format_PE64_DLL then
         Emit_Newline (S);
         Append ("; DLL reloc handled by linker", S); Emit_Newline (S);
      end if;

      
      Decrease_Indent;
      Success := S;
   end Emit_Program_End;

   procedure Emit_Raw (Text : String; Success : out Boolean) is
   begin
      Append_Local_Aware (Text, Success);
   end Emit_Raw;
   
   function ALB_ASM_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      else
         return Ch;
      end if;
   end ALB_ASM_Upper;


   function ALB_ASM_Is_Space (Ch : Character) return Boolean is
   begin
      return Ch = ' ' or else Ch = ASCII.HT or else Ch = ASCII.CR;
   end ALB_ASM_Is_Space;


   function ALB_ASM_Is_End_Line (Line : String) return Boolean is
      First : Integer := Line'First;
      Last  : Integer := Line'Last;
   begin
      while First <= Last and then ALB_ASM_Is_Space (Line (First)) loop
         First := First + 1;
      end loop;

      while Last >= First and then ALB_ASM_Is_Space (Line (Last)) loop
         Last := Last - 1;
      end loop;

      if Last - First + 1 /= 7 then
         return False;
      end if;

      return
        ALB_ASM_Upper (Line (First))     = 'E' and then
        ALB_ASM_Upper (Line (First + 1)) = 'N' and then
        ALB_ASM_Upper (Line (First + 2)) = 'D' and then
        Line (First + 3)                 = ' ' and then
        ALB_ASM_Upper (Line (First + 4)) = 'A' and then
        ALB_ASM_Upper (Line (First + 5)) = 'S' and then
        ALB_ASM_Upper (Line (First + 6)) = 'M';
   end ALB_ASM_Is_End_Line;


   procedure Emit_Native_ASM_Body
     (Block_Text : String;
      Success    : out Boolean)
   is
      S          : Boolean := True;
      Pos        : Integer := Block_Text'First;
      Line_Start : Integer;
      Line_End   : Integer;
      First_Line : Boolean := True;
   begin
      Append ("  ; --- ALB NATIVE ASM BEGIN ---", S);
      Emit_Newline (S);

      while Pos <= Block_Text'Last loop
         Line_Start := Pos;

         while Pos <= Block_Text'Last and then Block_Text (Pos) /= ASCII.LF loop
            Pos := Pos + 1;
         end loop;

         Line_End := Pos - 1;

         if First_Line then
            First_Line := False;

         elsif Line_End >= Line_Start then
            declare
               Line : constant String := Block_Text (Line_Start .. Line_End);
            begin
               exit when ALB_ASM_Is_End_Line (Line);

               Append (Line, S);
               Emit_Newline (S);
            end;

         else
            Emit_Newline (S);
         end if;

         if Pos <= Block_Text'Last and then Block_Text (Pos) = ASCII.LF then
            Pos := Pos + 1;
         end if;
      end loop;

      Append ("  ; --- ALB NATIVE ASM END ---", S);
      Emit_Newline (S);

      Success := S;
   end Emit_Native_ASM_Body;


   procedure Emit_Native_ASM_Block
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      Emit_Native_ASM_Body (Block_Text, Success);
   end Emit_Native_ASM_Block;


   procedure Emit_Native_ASM_Expression
     (Block_Text : String;
      Success    : out Boolean)
   is
   begin
      Append ("  ; inline ASM expression result must be returned in RAX", Success);
      if not Success then
         return;
      end if;

      Emit_Newline (Success);
      Emit_Native_ASM_Body (Block_Text, Success);
   end Emit_Native_ASM_Expression;
   
   -- =========================================================================
   -- BIJECTIVE ENGINE / REVERSIBLE STATE FORGE
   -- =========================================================================
   procedure Emit_Reversible_Line
     (Text    : String;
      Success : out Boolean)
   is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append (Text, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Reversible_Line;


   procedure Emit_Reversible_Block_Start (Success : out Boolean) is
   begin
      Emit_Reversible_Line ("  ; --- ALB REVERSIBLE BLOCK START ---", Success);
   end Emit_Reversible_Block_Start;


   procedure Emit_Reversible_Block_End (Success : out Boolean) is
   begin
      Emit_Reversible_Line ("  ; --- ALB REVERSIBLE BLOCK END ---", Success);
   end Emit_Reversible_Block_End;


   procedure Emit_Rev_Mem_RAX
     (Op          : String;
      Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      case Reversible_Storage_Bytes (Target_Tag) is
         when 1 =>
            Emit_Reversible_Line
              ("  " & Op & " byte [" & Target_Name & "], al",
               S);

         when 2 =>
            Emit_Reversible_Line
              ("  " & Op & " word [" & Target_Name & "], ax",
               S);

         when 4 =>
            Emit_Reversible_Line
              ("  " & Op & " dword [" & Target_Name & "], eax",
               S);

         when others =>
            Emit_Reversible_Line
              ("  " & Op & " qword [" & Target_Name & "], rax",
               S);
      end case;

      Success := S;
   end Emit_Rev_Mem_RAX;


   procedure Emit_Rev_Add
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      -- Inverse: Emit_Rev_Sub
      Emit_Rev_Mem_RAX ("add", Target_Name, Target_Tag, Success);
   end Emit_Rev_Add;


   procedure Emit_Rev_Sub
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      -- Inverse: Emit_Rev_Add
      Emit_Rev_Mem_RAX ("sub", Target_Name, Target_Tag, Success);
   end Emit_Rev_Sub;


   procedure Emit_Rev_Xor
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
   begin
      -- Self-inverse.
      Emit_Rev_Mem_RAX ("xor", Target_Name, Target_Tag, Success);
   end Emit_Rev_Xor;


   procedure Emit_Rev_Rol
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S      : Boolean := True;
      Width  : constant Natural := Reversible_Storage_Bytes (Target_Tag);
      Mask   : constant String :=
        (case Width is
            when 1 => "7",
            when 2 => "15",
            when 4 => "31",
            when others => "63");
   begin
      -- Inverse: Emit_Rev_Ror with the same count.
      Emit_Reversible_Line ("  mov rcx, rax", S);
      if S then
         Emit_Reversible_Line ("  and rcx, " & Mask, S);
      end if;
      if S then
         case Width is
            when 1 =>
               Emit_Reversible_Line ("  rol byte [" & Target_Name & "], cl", S);
            when 2 =>
               Emit_Reversible_Line ("  rol word [" & Target_Name & "], cl", S);
            when 4 =>
               Emit_Reversible_Line ("  rol dword [" & Target_Name & "], cl", S);
            when others =>
               Emit_Reversible_Line ("  rol qword [" & Target_Name & "], cl", S);
         end case;
      end if;
      Success := S;
   end Emit_Rev_Rol;


   procedure Emit_Rev_Ror
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S      : Boolean := True;
      Width  : constant Natural := Reversible_Storage_Bytes (Target_Tag);
      Mask   : constant String :=
        (case Width is
            when 1 => "7",
            when 2 => "15",
            when 4 => "31",
            when others => "63");
   begin
      -- Inverse: Emit_Rev_Rol with the same count.
      Emit_Reversible_Line ("  mov rcx, rax", S);
      if S then
         Emit_Reversible_Line ("  and rcx, " & Mask, S);
      end if;
      if S then
         case Width is
            when 1 =>
               Emit_Reversible_Line ("  ror byte [" & Target_Name & "], cl", S);
            when 2 =>
               Emit_Reversible_Line ("  ror word [" & Target_Name & "], cl", S);
            when 4 =>
               Emit_Reversible_Line ("  ror dword [" & Target_Name & "], cl", S);
            when others =>
               Emit_Reversible_Line ("  ror qword [" & Target_Name & "], cl", S);
         end case;
      end if;
      Success := S;
   end Emit_Rev_Ror;


   procedure Emit_Rev_Swap
     (Left_Name  : String;
      Left_Tag   : ALB_Type_Tag;
      Right_Name : String;
      Right_Tag  : ALB_Type_Tag;
      Success    : out Boolean)
   is
      S          : Boolean := True;
      Left_Size  : constant Natural := Reversible_Storage_Bytes (Left_Tag);
      Right_Size : constant Natural := Reversible_Storage_Bytes (Right_Tag);
   begin
      -- Self-inverse. Uses volatile scratch registers only.
      if Left_Size = Right_Size then
         case Left_Size is
            when 1 =>
               Emit_Reversible_Line ("  mov al, byte [" & Left_Name & "]", S);
               if S then
                  Emit_Reversible_Line ("  mov dl, byte [" & Right_Name & "]", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov byte [" & Left_Name & "], dl", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov byte [" & Right_Name & "], al", S);
               end if;

            when 2 =>
               Emit_Reversible_Line ("  mov ax, word [" & Left_Name & "]", S);
               if S then
                  Emit_Reversible_Line ("  mov dx, word [" & Right_Name & "]", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov word [" & Left_Name & "], dx", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov word [" & Right_Name & "], ax", S);
               end if;

            when 4 =>
               Emit_Reversible_Line ("  mov eax, dword [" & Left_Name & "]", S);
               if S then
                  Emit_Reversible_Line ("  mov edx, dword [" & Right_Name & "]", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov dword [" & Left_Name & "], edx", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov dword [" & Right_Name & "], eax", S);
               end if;

            when others =>
               Emit_Reversible_Line ("  mov r10, qword [" & Left_Name & "]", S);
               if S then
                  Emit_Reversible_Line ("  mov r11, qword [" & Right_Name & "]", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov qword [" & Left_Name & "], r11", S);
               end if;
               if S then
                  Emit_Reversible_Line ("  mov qword [" & Right_Name & "], r10", S);
               end if;
         end case;
      else
         Emit_Reversible_Line ("  mov r10, qword [" & Left_Name & "]", S);
         if S then
            Emit_Reversible_Line ("  mov r11, qword [" & Right_Name & "]", S);
         end if;
         if S then
            Emit_Reversible_Line ("  mov qword [" & Left_Name & "], r11", S);
         end if;
         if S then
            Emit_Reversible_Line ("  mov qword [" & Right_Name & "], r10", S);
         end if;
      end if;
      Success := S;
   end Emit_Rev_Swap;


   procedure Emit_Rev_Not
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      -- Self-inverse.
      case Reversible_Storage_Bytes (Target_Tag) is
         when 1 =>
            Emit_Reversible_Line ("  not byte [" & Target_Name & "]", S);
         when 2 =>
            Emit_Reversible_Line ("  not word [" & Target_Name & "]", S);
         when 4 =>
            Emit_Reversible_Line ("  not dword [" & Target_Name & "]", S);
         when others =>
            Emit_Reversible_Line ("  not qword [" & Target_Name & "]", S);
      end case;
      Success := S;
   end Emit_Rev_Not;


   procedure Emit_Rev_Neg
     (Target_Name : String;
      Target_Tag  : ALB_Type_Tag;
      Success     : out Boolean)
   is
      S : Boolean := True;
   begin
      -- Self-inverse in modulo 2^64 arithmetic.
      case Reversible_Storage_Bytes (Target_Tag) is
         when 1 =>
            Emit_Reversible_Line ("  neg byte [" & Target_Name & "]", S);
         when 2 =>
            Emit_Reversible_Line ("  neg word [" & Target_Name & "]", S);
         when 4 =>
            Emit_Reversible_Line ("  neg dword [" & Target_Name & "]", S);
         when others =>
            Emit_Reversible_Line ("  neg qword [" & Target_Name & "]", S);
      end case;
      Success := S;
   end Emit_Rev_Neg;


   
   procedure Emit_Newline (Success : out Boolean) is
      LF : constant String := (1 => ASCII.LF);
   begin
      Append (LF, Success);
   end Emit_Newline;
   procedure Emit_Indent (Success : out Boolean) is
      S : Boolean := True;
   begin
      for I in 1 .. Indent_Level loop
         Append ("  ", S);
         if not S then
            exit;
         end if;
      end loop;
      Success := S;
   end Emit_Indent;
   procedure Increase_Indent is
   begin
      Indent_Level := Indent_Level + 1;
   end Increase_Indent;
   procedure Decrease_Indent is
   begin
      if Indent_Level > 0 then
         Indent_Level := Indent_Level - 1;
      end if;
   end Decrease_Indent;

   procedure Emit_Type_Definition (Tag : ALB_Type_Tag; Success : out Boolean)
   is
   begin
      case Tag is
         when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
            Append ("db ", Success);

         when Type_U16 | Type_S16 | Type_HW16 =>
            Append ("dw ", Success);

         when Type_U32 | Type_S32 | Type_HW32 | Type_F32 =>
            Append ("dd ", Success);

         when others =>
            Append ("dq ", Success);
      end case;
   end Emit_Type_Definition;

   procedure Emit_Pure_Struct_Def (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("struc PURE", S);
      Emit_Newline (S);
      Increase_Indent;
      Emit_Indent (S);
      Append (".num resq 1", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append (".den resq 1", S);
      Emit_Newline (S);
      Decrease_Indent;
      Emit_Indent (S);
      Append ("endstruc", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Pure_Struct_Def;
   --  procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean) is
   --     S : Boolean;
   --  begin
   --     Emit_Indent (S);
   --     Append ("struc ", S);
   --     Append (Struct_Name, S);
   --     Emit_Newline (S);
   --     Increase_Indent;
   --     Success := S;
   --  end Emit_Struct_Start;
   
   procedure Emit_Struct_Start (Struct_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      -- DA FIX: Hoist structs tae the Global Vault sae NASM sees 'em early!
      Current_Buffer := Buffer_Global; 
      
      Emit_Indent (S);
      Append ("struc ", S);
      Append (Struct_Name, S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Struct_Start;

   procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("endstruc", S);
      Emit_Newline (S);
      
      -- DA FIX: Restore the active buffer back tae the Main Vault!
      Current_Buffer := Buffer_Main;
      Success := S;
   end Emit_Struct_End;
   
   procedure Emit_Struct_Field
     (Field_Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append (".", S);
      Append (Field_Name, S);
      Append (" ", S);
      case Tag is
         when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
            Append ("resb 1", S);
         when Type_U16 | Type_S16 | Type_HW16 =>
            Append ("resw 1", S);
         when Type_U32 | Type_S32 | Type_HW32 | Type_F32 =>
            Append ("resd 1", S);
         when Type_F32x2 =>
            Append ("resd 2", S);
         when Type_U128 | Type_S128 | Type_F128 | Type_Pure
            | Type_F32x4 | Type_Mat2x2 =>
            Append ("resq 2", S);
         when Type_Mat3x3 =>
            Append ("resq 6", S);
         when Type_Mat4x4 =>
            Append ("resq 8", S);
         when others =>
            Append ("resq 1", S);
      end case;
      Emit_Newline (S);
      Success := S;
   end Emit_Struct_Field;
   --  procedure Emit_Struct_End (Struct_Name : String; Success : out Boolean) is
   --     S : Boolean;
   --  begin
   --     Decrease_Indent;
   --     Emit_Indent (S);
   --     Append ("endstruc", S);
   --     Emit_Newline (S);
   --     Success := S;
   --  end Emit_Struct_End;

   procedure Emit_Forward_Declaration
     (Func_Name : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("; NASM LABEL: ", S);
      Append (Func_Name, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Forward_Declaration;
   --  procedure Emit_Var_Decl
   --    (Name : String; Tag : ALB_Type_Tag; Success : out Boolean)
   --  is
   --     S : Boolean;
   --  begin
   --     Emit_Indent (S);
   --     Append (Name, S);
   --     Append (" ", S);
   --     Emit_Type_Definition (Tag, S);
   --     Append ("0", S);
   --     Emit_Newline (S);
   --     Success := S;
   --  end Emit_Var_Decl;
   procedure Emit_Strict_Array_Decl
     (Name : String; Size_Bytes : Natural; Success : out Boolean)
   is
      S        : Boolean;
      Elements : Natural := Size_Bytes / 8;
      Storage_Name : constant String :=
        (if In_Global_Scope then Name else Ensure_Local_Storage_Name (Name));
   begin
      Emit_Indent (S);
      Append (Storage_Name, S);
      Append (" resq ", S);
      Append (Natural'Image (Elements), S);
      Emit_Newline (S);
      Success := S;
   end Emit_Strict_Array_Decl;
   procedure Emit_Slide_Array_Decl
     (Name : String; Max_Bytes : Natural; Success : out Boolean)
   is
      S        : Boolean;
      Elements : Natural := Max_Bytes / 8;
      Storage_Name : constant String :=
        (if In_Global_Scope then Name else Ensure_Local_Storage_Name (Name));
   begin
      Emit_Indent (S);
      Append (Storage_Name, S);
      Append (" resq ", S);
      Append (Natural'Image (Elements), S);
      Emit_Newline (S);
      Success := S;
   end Emit_Slide_Array_Decl;
   
   function Trim_Image (Text : String) return String is
   begin
      if Text'Length > 0 and then Text(Text'First) = ' ' then
         return Text(Text'First + 1 .. Text'Last);
      end if;
      return Text;
   end Trim_Image;

   procedure Emit_Load_Scalar_To_RAX
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
      S : Boolean;
      Storage_Name : constant String := Resolve_Storage_Name (Name);
   begin
      Emit_Indent (S);

      case Tag is
         when Type_U8 | Type_Boolean =>
            Append ("movzx rax, byte [" & Storage_Name & "]", S);
         when Type_S8 | Type_HW8 =>
            Append ("movsx rax, byte [" & Storage_Name & "]", S);
         when Type_U16 =>
            Append ("movzx rax, word [" & Storage_Name & "]", S);
         when Type_S16 | Type_HW16 =>
            Append ("movsx rax, word [" & Storage_Name & "]", S);
         when Type_U32 =>
            Append ("mov eax, dword [" & Storage_Name & "]", S);
         when Type_S32 | Type_HW32 =>
            Append ("movsxd rax, dword [" & Storage_Name & "]", S);
         when others =>
            Append ("mov rax, qword [" & Storage_Name & "]", S);
      end case;

      Emit_Newline (S);
      Success := S;
   end Emit_Load_Scalar_To_RAX;

   procedure Emit_Temporal_Var_Decl
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      S          : Boolean := True;
      Old_Buf    : Buffer_Target := Current_Buffer;
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
      Storage_Name : constant String := Ensure_Local_Storage_Name (Name);
   begin
      Emit_Var_Decl (Name, Tag, S);
      if not S then Success := False; return; end if;

      Current_Buffer := Buffer_Global;

      Emit_Indent (S);
      Append ("ALB_TEMP_" & Storage_Name & "_history resq " & Depth_Text, S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("ALB_TEMP_" & Storage_Name & "_head dq 0", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("ALB_TEMP_" & Storage_Name & "_history_size equ " & Depth_Text & " * 8", S);
      Emit_Newline (S);

      Current_Buffer := Old_Buf;
      Success := S;
   end Emit_Temporal_Var_Decl;

   procedure Emit_Temporal_Record_Current
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      S          : Boolean := True;
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
      ID_Text    : constant String := Trim_Image (Natural'Image (Temporal_Label_Counter));
      Storage_Name : constant String := Resolve_Storage_Name (Name);
   begin
      Temporal_Label_Counter := Temporal_Label_Counter + 1;

      Emit_Load_Scalar_To_RAX (Name, Tag, S);
      if not S then Success := False; return; end if;

      Emit_Indent (S);
      Append ("mov rbx, qword [rel ALB_TEMP_" & Storage_Name & "_head]", S);
      Emit_Newline (S);

      --  NASM: [rel label + reg*scale] is illegal — lea base, then index.
      Emit_Indent (S);
      Append ("lea rcx, [rel ALB_TEMP_" & Storage_Name & "_history]", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("mov qword [rcx + rbx * 8], rax", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("inc rbx", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("cmp rbx, " & Depth_Text, S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("jb .alb_temp_nowrap_" & ID_Text, S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("xor rbx, rbx", S);
      Emit_Newline (S);

      Append (".alb_temp_nowrap_" & ID_Text & ":", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("mov qword [rel ALB_TEMP_" & Storage_Name & "_head], rbx", S);
      Emit_Newline (S);

      Success := S;
   end Emit_Temporal_Record_Current;
   
   procedure Emit_Temporal_Load_Now
     (Name    : String;
      Tag     : ALB_Type_Tag;
      Success : out Boolean)
   is
   begin
      Emit_Load_Scalar_To_RAX (Name, Tag, Success);
   end Emit_Temporal_Load_Now;

   procedure Emit_Temporal_Load_Past
     (Name          : String;
      Tag           : ALB_Type_Tag;
      History_Depth : Natural;
      Success       : out Boolean)
   is
      pragma Unreferenced (Tag);
      S          : Boolean := True;
      Safe_Depth : constant Natural := (if History_Depth = 0 then 1 else History_Depth);
      Depth_Text : constant String := Trim_Image (Natural'Image (Safe_Depth));
      ID_Text    : constant String := Trim_Image (Natural'Image (Temporal_Label_Counter));
      Storage_Name : constant String := Resolve_Storage_Name (Name);
   begin
      Temporal_Label_Counter := Temporal_Label_Counter + 1;

      Emit_Indent (S);
      Append ("mov rbx, qword [rel ALB_TEMP_" & Storage_Name & "_head]", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("test rbx, rbx", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("jnz .alb_temp_have_past_" & ID_Text, S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("mov rbx, " & Depth_Text, S);
      Emit_Newline (S);

      Append (".alb_temp_have_past_" & ID_Text & ":", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("dec rbx", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("lea rcx, [rel ALB_TEMP_" & Storage_Name & "_history]", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("mov rax, qword [rcx + rbx * 8]", S);
      Emit_Newline (S);

      Success := S;
   end Emit_Temporal_Load_Past;

   procedure Emit_Temporal_Load_Timeline
     (Name    : String;
      Success : out Boolean)
   is
      S : Boolean;
      Storage_Name : constant String := Resolve_Storage_Name (Name);
   begin
      Emit_Indent (S);
      Append ("lea rax, [rel ALB_TEMP_" & Storage_Name & "_history]", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Temporal_Load_Timeline;
   
   --  --Check back later
   --  procedure Emit_Temporal_Load_Timeline
   --    (Name    : String;
   --     Success : out Boolean)
   --  is
   --     S : Boolean := True;
   --  begin




   procedure Emit_Let_Assign_Start (Type_Hint : String; Success : out Boolean) is
   begin
      -- DA NEW FIX: Scrub back ony stray newlines or spaces frae the AST!
      -- This keeps the comma glued tae the ALB_LET macro line.
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then 
           (Main_Buffer (Main_Len) = ASCII.LF or 
            Main_Buffer (Main_Len) = ASCII.CR or 
            Main_Buffer (Main_Len) = ' ') 
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then 
           (Global_Buffer (Global_Len) = ASCII.LF or 
            Global_Buffer (Global_Len) = ASCII.CR or 
            Global_Buffer (Global_Len) = ' ') 
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;
      
      -- Noo emit the comma safely!
      Append (", ", Success);
   end Emit_Let_Assign_Start;
   
   procedure Emit_Variable_Ref (Name : String; Success : out Boolean) is
      Storage_Name : constant String := Resolve_Storage_Name (Name);
   begin
      -- Pure brackets, nae movs, nae newlines!
      Append ("[", Success);
      Append (Storage_Name, Success);
      Append ("]", Success);
   end Emit_Variable_Ref;
   
   procedure Emit_Array_Index_Open (Success : out Boolean) is
   begin
      Append (" + (", Success);
   end Emit_Array_Index_Open;
   
   
   procedure Emit_Array_Index_Close (Success : out Boolean) is
   begin
      -- DA FIX: Same scrubber fer arrays, keepin' the brackets tight!
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then 
           (Main_Buffer (Main_Len) = ASCII.LF or 
            Main_Buffer (Main_Len) = ASCII.CR or 
            Main_Buffer (Main_Len) = ' ') 
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then 
           (Global_Buffer (Global_Len) = ASCII.LF or 
            Global_Buffer (Global_Len) = ASCII.CR or 
            Global_Buffer (Global_Len) = ' ') 
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;

      Append (")*8]", Success);
   end Emit_Array_Index_Close;

   procedure Emit_AddressOf (Success : out Boolean) is
   begin
      Append (" ", Success);
   end Emit_AddressOf;
   procedure Emit_Boolean_Cast_Start (Success : out Boolean) is
   begin
      Append (" ", Success);
   end Emit_Boolean_Cast_Start;
   
   
   procedure Emit_Literal_U64 (Value : U64; Success : out Boolean) is
      Img : constant String := U64'Image (Value);
   begin
      if Img (Img'First) = ' ' then
         Append (Img (Img'First + 1 .. Img'Last), Success);
      else
         Append (Img, Success);
      end if;
   end Emit_Literal_U64;

   --  procedure Emit_String_Literal (Text : String; Success : out Boolean) is
   --     S : Boolean;
   --  begin
   --     Append ("""", S);
   --     Append (Text, S);
   --     Append ("""", S);
   --     Success := S;
   --  end Emit_String_Literal;
   
   procedure Emit_Expression_Open (Success : out Boolean) is
   begin
      Append ("(", Success);
   end Emit_Expression_Open;
   
   procedure Emit_Expression_Close (Success : out Boolean) is
   begin
      -- DA NEW FIX: Scrub back ony stray newlines or spaces frae the AST!
      -- This ensures the closin' parenthesis snaps strictly onto the same line.
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then 
           (Main_Buffer (Main_Len) = ASCII.LF or 
            Main_Buffer (Main_Len) = ASCII.CR or 
            Main_Buffer (Main_Len) = ' ') 
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then 
           (Global_Buffer (Global_Len) = ASCII.LF or 
            Global_Buffer (Global_Len) = ASCII.CR or 
            Global_Buffer (Global_Len) = ' ') 
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;

      Append (")", Success);
   end Emit_Expression_Close;

   procedure Emit_BinOp (Op : ALB_Opcode; Success : out Boolean) is
   begin
      -- DA NEW FIX: Scrub back ony stray newlines or spaces frae the AST!
      -- This ensures binary operators stick to the same line for the FASM macro.
      if Current_Buffer = Buffer_Main then
         while Main_Len > 0 and then 
           (Main_Buffer (Main_Len) = ASCII.LF or 
            Main_Buffer (Main_Len) = ASCII.CR or 
            Main_Buffer (Main_Len) = ' ') 
         loop
            Main_Len := Main_Len - 1;
         end loop;
      else
         while Global_Len > 0 and then 
           (Global_Buffer (Global_Len) = ASCII.LF or 
            Global_Buffer (Global_Len) = ASCII.CR or 
            Global_Buffer (Global_Len) = ' ') 
         loop
            Global_Len := Global_Len - 1;
         end loop;
      end if;

      case Op is
         when OP_ADD => Append (" + ", Success);
         when OP_SUB => Append (" - ", Success);
         when OP_MUL => Append (" * ", Success);
         when OP_DIV => Append (" / ", Success);
         when OP_CMP_EQ => Append (" = ", Success);
         when OP_CMP_NEQ => Append (" <> ", Success);
         when OP_CMP_LT => Append (" < ", Success);
         when OP_CMP_GT => Append (" > ", Success);
         when OP_CMP_LTE => Append (" <= ", Success);
         when OP_CMP_GTE => Append (" >= ", Success);
         when OP_AND => Append (" and ", Success);
         when OP_OR => Append (" or ", Success);
         when OP_XOR => Append (" xor ", Success);
         when OP_SHL => Append (" shl ", Success);
         when OP_SHR => Append (" shr ", Success);
         when others => Append (" ; UNK ", Success);
      end case;
   end Emit_BinOp;

   procedure Emit_Branchless_Condition_Start (Success : out Boolean) is
   begin
      Append ("ALB_MASK_OP ", Success);
   end Emit_Branchless_Condition_Start;
   procedure Emit_Branchless_Mask_Op (Success : out Boolean) is
   begin
      Append (", ", Success);
   end Emit_Branchless_Mask_Op;

   procedure Emit_If_Start (Success : out Boolean) is
   begin
      Append (".if ", Success);
   end Emit_If_Start;
   procedure Emit_Then (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Then;

   procedure Emit_Else (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".else", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Else;

   procedure Emit_If_End (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".end if", S);
      Emit_Newline (S);
      Success := S;
   end Emit_If_End;

   procedure Emit_While_Start (Success : out Boolean) is
   begin
      Append (".while ", Success);
   end Emit_While_Start;
   procedure Emit_While_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_While_Loop_Start;
   procedure Emit_Plain_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Append (".repeat", S);
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Plain_Loop_Start;
   procedure Emit_Exit_When (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".until ", S);
      Success := S;
   end Emit_Exit_When;
   procedure Emit_For_Start (Iterator_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("mov [", S);
      Append (Iterator_Name, S);
      Append ("], ", S);
      Success := S;
   end Emit_For_Start;
   
   procedure Emit_DotDot (Success : out Boolean) is
      S : Boolean;
   begin
      Append ("; FOR", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append (".while ", S); -- We stopped it right here! Nae hardcoded name, nae operator.
      Success := S;
   end Emit_DotDot;
   
   procedure Emit_Loop_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Loop_Start;
   --  procedure Emit_Loop_End (Success : out Boolean) is
   --     S : Boolean;
   --  begin
   --     Decrease_Indent;
   --     Emit_Indent (S);
   --     Append (".endw", S);
   --     Emit_Newline (S);
   --     Success := S;
   --  end Emit_Loop_End;
   
   procedure Emit_Loop_End (Success : out Boolean) is
      S : Boolean;
   begin
      if Foreach_Depth > 0 then
         declare
            Img      : constant String := Natural'Image (Foreach_Stack (Foreach_Depth));
            ID_Text  : constant String := Img (Img'First + 1 .. Img'Last);
            Idx_Name : constant String := "ALB_FE_IDX_" & ID_Text;
         begin
            Emit_Indent (S);
            Append ("inc qword [" & Idx_Name & "]", S);
            Emit_Newline (S);

            Emit_Indent (S);
            Append ("jmp .alb_foreach_start_" & ID_Text, S);
            Emit_Newline (S);

            Append (".alb_foreach_end_" & ID_Text & ":", S);
            Emit_Newline (S);

            Foreach_Depth := Foreach_Depth - 1;
            Success := S;
         end;
      else
         Decrease_Indent;
         Emit_Indent (S);
         Append (".endw", S);
         Emit_Newline (S);
         Success := S;
      end if;
   end Emit_Loop_End;


   procedure Emit_Case_Start (Success : out Boolean) is
   begin
      Append ("; SELECT ", Success);
   end Emit_Case_Start;
   procedure Emit_Is (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Is;
   procedure Emit_When (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append (".if ", S);
      Success := S;
   end Emit_When;
   procedure Emit_Arrow (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Newline (S);
      Increase_Indent;
      Success := S;
   end Emit_Arrow;
   procedure Emit_When_End (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append (".end if", S);
      Emit_Newline (S);
      Success := S;
   end Emit_When_End;
   procedure Emit_Case_End (Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);
      Append ("; END SELECT", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Case_End;

   procedure Emit_Procedure_Decl_Start (Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("  jmp skip_proc_" & Name, S); Emit_Newline(S);
      Append (Name & ":", S); Emit_Newline(S);

      -- Win64 ABI: RBX is callee-saved. ALB codegen uses RBX as scratch
      -- (compares / array lea). Without this, EXPORT_DLL hosts that keep
      -- pointers in RBX (MinGW C++) AV on the next call after return.
      -- push (8) + sub 32 => 16-byte aligned with 32-byte shadow space.
      Append ("  push rbx", S); Emit_Newline(S);
      Append ("  sub rsp, 32", S); Emit_Newline(S);

      Begin_Subprogram_Scope (Name);
      In_Global_Scope := False;
      Success := S;
   end Emit_Procedure_Decl_Start;

   procedure Emit_Procedure_End (Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Decrease_Indent;
      Emit_Indent (S);

      Append ("  add rsp, 32", S); Emit_Newline (S);
      Append ("  pop rbx", S); Emit_Newline (S);
      Append ("  ret", S); Emit_Newline (S);

      Append ("skip_proc_" & Name & ":", S); Emit_Newline(S);
      End_Subprogram_Scope;
      In_Global_Scope := True;
      Success := S;
   end Emit_Procedure_End;
   
   procedure Emit_Return_Start (Success : out Boolean) is
   begin
      Append ("ret ", Success);
   end Emit_Return_Start;
   
   procedure Emit_Call_Start (Func_Name : String; Success : out Boolean) is
   begin
      Append ("  fastcall ", Success);
      Append (Func_Name, Success);
      Append (", ", Success);
   end Emit_Call_Start;
   
   procedure Emit_Call_End (Success : out Boolean) is
   begin
      Append (" ", Success);
   end Emit_Call_End;
   
   procedure Emit_Comma (Success : out Boolean) is
   begin
      Append (", ", Success);
   end Emit_Comma;
   procedure Emit_Statement_End (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Newline (S);
      Success := S;
   end Emit_Statement_End;
   
   procedure Emit_String_Literal (Text : String; Success : out Boolean) is 
         S : Boolean := True;
         Counter_Img : constant String := Natural'Image (String_Counter);
         Lbl : constant String := "alb_str_" & Counter_Img (Counter_Img'First + 1 .. Counter_Img'Last);
         Old_Buf : Buffer_Target := Current_Buffer;
         Started : Boolean := False;
         In_Quote : Boolean := False;

         procedure Begin_Item is
         begin
            if Started then
               Append (", ", S);
            else
               Started := True;
            end if;
         end Begin_Item;

         procedure Append_Text_Char (Ch : Character) is
         begin
            if not In_Quote then
               Begin_Item;
               Append ("""", S);
               In_Quote := True;
            end if;

            if Ch = '"' then
               Append ("""""", S);
            else
               Append ((1 => Ch), S);
            end if;
         end Append_Text_Char;

         procedure Append_Byte (Value : Natural) is
            Img : constant String := Natural'Image (Value);
         begin
            if In_Quote then
               Append ("""", S);
               In_Quote := False;
            end if;

            Begin_Item;
            Append (Img (Img'First + 1 .. Img'Last), S);
         end Append_Byte;
   begin 
         String_Counter := String_Counter + 1;
         
         -- Switch tae the Data Vault tae permanently store the string
         Current_Buffer := Buffer_Global;
         Append ("  " & Lbl & " db ", S);
         
         for I in Text'Range loop
            if Text (I) = ASCII.CR then
               Append_Byte (13);
            elsif Text (I) = ASCII.LF then
               Append_Byte (10);
            else
               Append_Text_Char (Text (I));
            end if;
         end loop;

         if In_Quote then
            Append ("""", S);
            In_Quote := False;
         end if;

         if not Started then
            Begin_Item;
            Append ("""", S);
            Append ("""", S);
         end if;
         
         Append (", 0", S); Emit_Newline(S);
         
         -- Switch back tae the Execution Vault and drop the pointer label!
         Current_Buffer := Old_Buf;
         Append (Lbl, S);
         Success := S;
   end Emit_String_Literal;

   procedure Emit_Var_Decl (Name : String; Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
      Old_Buf : Buffer_Target := Current_Buffer;
      Already_Exists : Boolean := False;
      Storage_Name : constant String :=
        (if In_Global_Scope then Name else Ensure_Local_Storage_Name (Name));
   begin
      -- We only scan the Global_Buffer (the .data/.bss vaults)
      if Global_Len >= Storage_Name'Length + 2 then
         for I in 2 .. Global_Len - Storage_Name'Length loop
            if Global_Buffer (I .. I + Storage_Name'Length - 1) = Storage_Name then
               -- 1. Flanking Check: Ensure it's a discrete token
               declare
                  Prev : Character := Global_Buffer (I - 1);
                  Next : Character := ' ';
                  Valid_Prev : Boolean := (Prev = ' ' or Prev = ASCII.LF or Prev = ASCII.CR or Prev = ASCII.HT);
                  Valid_Next : Boolean := False;
               begin
                  if I + Storage_Name'Length <= Global_Len then
                     Next := Global_Buffer (I + Storage_Name'Length);
                  end if;
                  
                  Valid_Next := (Next = ' ' or Next = ASCII.LF or Next = ASCII.CR or Next = ASCII.HT or Next = ':' or Next = ',');

                  if Valid_Prev and Valid_Next then
                     -- 2. Comment & Struct Guard: Is this match actually a global declaration?
                     declare
                        Is_Invalid : Boolean := False;
                        K : Integer := I - 1;
                     begin
                        -- Scan back tae start o' line
                        while K >= 1 and then Global_Buffer(K) /= ASCII.LF and then Global_Buffer(K) /= ASCII.CR loop
                           if Global_Buffer(K) = ';' then
                              Is_Invalid := True; -- It's a comment
                              exit;
                           end if;
                           K := K - 1;
                        end loop;

                        -- 3. The Struct Trap: Scan back tae see if we're inside a 'struc' block
                        if not Is_Invalid then
                           declare
                              Back_P : Integer := I - 1;
                           begin
                              while Back_P >= 6 loop
                                 if Back_P + 8 <= Global_Len
                                   and then Global_Buffer (Back_P .. Back_P + 7) = "endstruc"
                                 then
                                    Is_Invalid := False; -- Hit the end o' a previous struc, we're safe
                                    exit;
                                 elsif Back_P >= 4
                                   and then Global_Buffer (Back_P - 4 .. Back_P) = "struc"
                                   and then
                                     (Back_P < 7
                                      or else Global_Buffer (Back_P - 7 .. Back_P - 5)
                                                /= "end")
                                 then
                                    Is_Invalid := True; -- We're definitely inside a struc template
                                    exit;
                                 end if;
                                 Back_P := Back_P - 1;
                              end loop;
                           end;
                        end if;

                        if not Is_Invalid then
                           -- 4. Keyword Verification: Is it followed by dq/resq/etc?
                           declare
                              Scan_P : Integer := I + Name'Length;
                              Found_Decl : Boolean := False;
                           begin
                              -- Skip whitespace/colons
                              while Scan_P <= Global_Len and then 
                                    (Global_Buffer(Scan_P) = ' ' or 
                                     Global_Buffer(Scan_P) = ':' or 
                                     Global_Buffer(Scan_P) = ASCII.HT) loop
                                 Scan_P := Scan_P + 1;
                              end loop;
                              
                              if Scan_P + 3 <= Global_Len then
                                 declare
                                    Kwd4 : constant String :=
                                      Global_Buffer (Scan_P .. Scan_P + 3);
                                 begin
                                    if Kwd4 = "resq" or Kwd4 = "resd"
                                      or Kwd4 = "resw" or Kwd4 = "resb"
                                    then
                                       Found_Decl := True;
                                    end if;
                                 end;
                              end if;

                              if not Found_Decl and then Scan_P + 1 <= Global_Len then
                                 declare
                                    Kwd : String := Global_Buffer(Scan_P .. Scan_P + 1);
                                 begin
                                    if Kwd = "dq" or Kwd = "dd" or Kwd = "dw" or Kwd = "db" then
                                       Found_Decl := True;
                                    end if;
                                 end;
                              end if;

                              if Found_Decl then
                                 Already_Exists := True;
                                 exit;
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end loop;
      end if;

      if Already_Exists then
         Success := True;
         return;
      end if;

      -- Symbol is truly missin', so write it tae the Data Vault
      Current_Buffer := Buffer_Global;
      Emit_Indent(S);
      Append (Storage_Name, S);
      Append (" ", S);
      declare
         Byte_Size : Natural := 8;
      begin
         case Tag is
            when Type_U8 | Type_S8 | Type_HW8 | Type_Boolean | Type_Char =>
               Append ("db 0", S);
               Byte_Size := 1;
            when Type_U16 | Type_S16 | Type_HW16 =>
               Append ("dw 0", S);
               Byte_Size := 2;
            when Type_U32 | Type_S32 | Type_HW32 | Type_F32 =>
               Append ("dd 0", S);
               Byte_Size := 4;
            when Type_F32x2 =>
               Append ("dd 0, 0", S);
               Byte_Size := 8;
            when Type_U64 | Type_S64 | Type_HW64 | Type_F64 =>
               Append ("dq 0", S);
               Byte_Size := 8;
            when Type_U128 | Type_S128 | Type_F128 | Type_Pure
               | Type_F32x4 | Type_Mat2x2 =>
               Append ("dq 0, 0", S);
               Byte_Size := 16;
            when Type_Mat3x3 =>
               Append ("dq 0, 0, 0, 0, 0, 0", S);
               Byte_Size := 48;
            when Type_Mat4x4 =>
               Append ("dq 0, 0, 0, 0, 0, 0, 0, 0", S);
               Byte_Size := 64;
            when others =>
               Append ("dq 0", S);
               Byte_Size := 8;
         end case;
         Emit_Newline(S);

         declare
            Img : constant String := Natural'Image (Byte_Size);
         begin
            Emit_Indent (S);
            Append (Storage_Name & "_size equ " & Img (Img'First + 1 .. Img'Last), S);
            Emit_Newline (S);
         end;
      end;

      
      Current_Buffer := Old_Buf; 
      Success := S;
   end Emit_Var_Decl;

   
   procedure Emit_Assign_Prefix (Success : out Boolean) is
   begin
      -- Just the macro name and a space, nae newlines!
      Append ("ALB_LET ", Success);
   end Emit_Assign_Prefix;
   
   procedure Emit_Print_Start (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
   begin
      if Tag = Type_Binary then 
         Emit_Raw ("invoke printf, ALB_Fmt_Str, ", S);
      else 
         Emit_Raw ("invoke printf, ALB_Fmt_Num, ", S); 
      end if;
      Success := S;
   end Emit_Print_Start;

   procedure Emit_Print_End (Tag : ALB_Type_Tag; Success : out Boolean) is begin Success := True; end Emit_Print_End;
   
   procedure Emit_Assert_Call (Pred, Arg : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Raw ("; ASSERT: " & Pred, S);
      Emit_Newline (S);
      -- FASM uses 'addr' tae pass string labels tae Win32 style functions
      Emit_Raw ("invoke ALB_Assert, addr " & Pred & "_str, " & Arg & ", 0", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Assert_Call;

   procedure Emit_Retract_Call (Pred, Arg : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Raw ("; RETRACT: " & Pred, S);
      Emit_Newline (S);
      Emit_Raw ("invoke ALB_Retract, addr " & Pred & "_str, " & Arg, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Retract_Call;

   procedure Emit_OS_Load
     (File_Path : String; Target_Buffer : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("invoke CreateFileA, """, S);
      Append (File_Path, S);
      Append (""", GENERIC_READ, 0, 0, OPEN_EXISTING, 0, 0", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("invoke ReadFile, rax, ", S);
      Append (Target_Buffer, S);
      Append (", 8192, 0, 0", S);
      Emit_Newline (S);
      Success := S;
   end Emit_OS_Load;
   procedure Emit_OS_Flush
     (Source_Buffer : String; File_Path : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("invoke CreateFileA, """, S);
      Append (File_Path, S);
      Append (""", GENERIC_WRITE, 0, 0, CREATE_ALWAYS, 0, 0", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("invoke WriteFile, rax, ", S);
      Append (Source_Buffer, S);
      Append (", 8192, 0, 0", S);
      Emit_Newline (S);
      Success := S;
   end Emit_OS_Flush;
   procedure Emit_Prolog_Fact_Registration
     (Pred : String; Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("; ALB FACT REGISTERED: ", S);
      Append (Pred, S);
      Append ("(", S);
      Append (Arg, S);
      Append (")", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Prolog_Fact_Registration;
   
   procedure Emit_Prolog_Query_Call
     (Pred : String; Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Raw ("  fastcall ALB_Query, <'", S);
      Emit_Raw (Pred, S);
      Emit_Raw ("',0>, ", S);
      Emit_Raw (Arg, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Prolog_Query_Call;

   procedure Emit_FindAll_Call
     (Pred : String; Out_Array : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Raw ("  fastcall ALB_FindAll, <'", S);
      Emit_Raw (Pred, S);
      Emit_Raw ("',0>, ", S);
      Emit_Raw (Out_Array, S);
      Emit_Newline (S);
      Success := S;
   end Emit_FindAll_Call;
   
   procedure Emit_Update_Call
     (Pred, Old_Arg, New_Arg : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Raw ("  fastcall ALB_Update, <'", S);
      Emit_Raw (Pred, S);
      Emit_Raw ("',0>, ", S);
      Emit_Raw (Old_Arg, S);
      Emit_Raw (", ", S);
      Emit_Raw (New_Arg, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Update_Call;

   
   procedure Emit_Global_Var_Decl (Name : String; Tag : ALB_Type_Tag; Success : out Boolean) is begin Emit_Var_Decl (Name, Tag, Success); end Emit_Global_Var_Decl;
   procedure Emit_Slide_Vault_Left (Vault_Name : String; Shift_Amount : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; SLIDE_LEFT", S); Success := S; end Emit_Slide_Vault_Left;
   procedure Emit_Slide_Vault_Right (Vault_Name : String; Shift_Amount : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; SLIDE_RIGHT", S); Success := S; end Emit_Slide_Vault_Right;
   procedure Emit_String_Concat (Dest, Src, Max_Len : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; STR_CONCAT", S); Success := S; end Emit_String_Concat;
   procedure Emit_String_Copy (Dest, Src, Max_Len : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; STR_COPY", S); Success := S; end Emit_String_Copy;
   procedure Emit_String_Length (Src : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; STR_LEN", S); Success := S; end Emit_String_Length;
   procedure Emit_Square_Root (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Raw ("  mov rax, ", S);
      Emit_Raw (Value, S);
      Emit_Newline (S);
      Emit_Raw ("  call ALB_Sqrt_U64", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Square_Root;
   procedure Emit_Sine (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Raw ("  mov rax, ", S);
      Emit_Raw (Value, S);
      Emit_Newline (S);
      Emit_Raw ("  call ALB_SIN", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Sine;

   procedure Emit_Cosine (Value : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Raw ("  mov rax, ", S);
      Emit_Raw (Value, S);
      Emit_Newline (S);
      Emit_Raw ("  call ALB_COS", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Cosine;
   procedure Emit_Absolute (Value : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; ABS", S); Success := S; end Emit_Absolute;
   procedure Emit_Key_State (Key_Code : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; KEY_STATE", S); Success := S; end Emit_Key_State;
   procedure Emit_Mouse_Position (X_Var, Y_Var : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; MOUSE_POS", S); Success := S; end Emit_Mouse_Position;
   procedure Emit_Mouse_Click (Button : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; MOUSE_CLICK", S); Success := S; end Emit_Mouse_Click;
   procedure Emit_Put_Pixel (X, Y, Color : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; PUT_PIXEL", S); Success := S; end Emit_Put_Pixel;
   procedure Emit_Play_Sound (Vault_Name : String; Success : out Boolean) is S : Boolean; begin Emit_Raw ("; PLAY_SOUND", S); Success := S; end Emit_Play_Sound;

   procedure Emit_Print_Function_Start (Success : out Boolean) is
   begin
      Append ("invoke printf, ", Success);
   end Emit_Print_Function_Start;
   
   procedure Emit_Window_Creation (Title : String; Success : out Boolean) is
      S : Boolean := True;
      Old_Buf : Buffer_Target := Current_Buffer;

      procedure Line (Text : String) is
      begin
         Append (Text, S);
         Emit_Newline (S);
      end Line;

      procedure Ind (Text : String) is
      begin
         Emit_Indent (S);
         Append (Text, S);
         Emit_Newline (S);
      end Ind;

   begin
      NASM_Window_Requested := True;
      Current_Buffer := Buffer_Global;

      Line ("  ALB_Current_Color dq 0");
      Line ("  ALB_Current_Font dq 0");
      Line ("  ALB_Clear_Color dq 0");
      Line ("  ALB_Render_Target dq 1");
      Line ("  ALB_Scale_Mode dq 0");
      Line ("  ALB_Window_Resizable dq 0");
      Line ("  ALB_Window_Fullscreen dq 0");

      Line ("  ALB_Screen_Width dq 0");
      Line ("  ALB_Screen_Height dq 0");
      Line ("  ALB_Virtual_Width dq 0");
      Line ("  ALB_Virtual_Height dq 0");
      Line ("  ALB_Content_Offset_X dq 0");
      Line ("  ALB_Content_Offset_Y dq 0");
      Line ("  ALB_Origin_X dq 0");
      Line ("  ALB_Origin_Y dq 0");
      Line ("  ALB_Clip_Enabled dq 0");
      Line ("  ALB_Clip_X dq 0");
      Line ("  ALB_Clip_Y dq 0");
      Line ("  ALB_Clip_W dq 0");
      Line ("  ALB_Clip_H dq 0");

      Line ("  ALB_Mouse_X dq 0");
      Line ("  ALB_Mouse_Y dq 0");
      Line ("  ALB_Mouse_Wheel dq 0");
      Line ("  ALB_Mouse_Btn dq 0");
      Line ("  ALB_VMouse_X dq 0");
      Line ("  ALB_VMouse_Y dq 0");

      Line ("  ALB_Size_W dd 0");
      Line ("  ALB_Size_H dd 0");
      Line ("  ALB_Mouse_FX dd 0");
      Line ("  ALB_Mouse_FY dd 0");

      Line ("  ALB_Event_Buffer db 256 dup (0)");
      Line ("  ALB_SDL_Rect dd 0, 0, 0, 0");
      Line ("  ALB_SDL_FRect dd 4 dup (0)");
      Line ("  ALB_Text_Line db 1024 dup (0)");

      Line ("  ALB_Pixel_R db 0");
      Line ("  ALB_Pixel_G db 0");
      Line ("  ALB_Pixel_B db 0");
      Line ("  ALB_Pixel_A db 0");

      Line ("  ALB_Geom_XY dd 6 dup (0)");
      Line ("  ALB_Geom_Color dd 12 dup (0)");
      Line ("  ALB_F32_Inv255 dd 0.0039215689");

      Current_Buffer := Old_Buf;

      Emit_SDL3_Runtime_Support (S);

      Line ("  jmp alb_sdl3_window_runtime_resume");
      Emit_Newline (S);

      Line ("ALB_Apply_Color:");
      Line ("  sub rsp, 40");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  mov eax, dword [rel ALB_Current_Color]");
      Line ("  mov edx, eax");
      Line ("  shr edx, 16");
      Line ("  and edx, 255");
      Line ("  mov r8d, eax");
      Line ("  shr r8d, 8");
      Line ("  and r8d, 255");
      Line ("  mov r9d, eax");
      Line ("  and r9d, 255");
      Line ("  mov r10d, dword [rel ALB_Current_Color]");
      Line ("  shr r10d, 24");
      Line ("  and r10d, 255");
      Line ("  cmp r10d, 0");
      Line ("  jne .alpha_ok");
      Line ("  mov r10d, 255");
      Line (".alpha_ok:");
      Line ("  mov dword [rsp + 32], r10d");
      Line ("  mov rax, qword [rel ALB_SDL_SetRenderDrawColor]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      -- ALB_CEASE is emitted once above (if used) for headless and GUI builds.

      Line ("ALB_Render_Point_Raw:");
      Line ("  sub rsp, 40");
      Line ("  mov dword [rsp + 24], ecx");
      Line ("  mov dword [rsp + 28], edx");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  mov ecx, dword [rsp + 24]");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 24], eax");
      Line ("  mov edx, dword [rsp + 28]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 28], eax");
      Line ("  cvtsi2ss xmm1, dword [rsp + 24]");
      Line ("  cvtsi2ss xmm2, dword [rsp + 28]");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  mov rax, qword [rel ALB_SDL_RenderPoint]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Render_Line_Raw:");
      Line ("  sub rsp, 72"); -- DA FIX: Win64 Stack Adjustment
      Line ("  mov dword [rsp + 40], ecx");
      Line ("  mov dword [rsp + 44], edx");
      Line ("  mov dword [rsp + 48], r8d");
      Line ("  mov dword [rsp + 52], r9d");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  mov ecx, dword [rsp + 40]");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 40], eax");
      Line ("  mov edx, dword [rsp + 44]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 44], eax");
      Line ("  mov ecx, dword [rsp + 48]");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 48], eax");
      Line ("  mov edx, dword [rsp + 52]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 52], eax");
      Line ("  cvtsi2ss xmm1, dword [rsp + 40]");
      Line ("  cvtsi2ss xmm2, dword [rsp + 44]");
      Line ("  cvtsi2ss xmm3, dword [rsp + 48]");
      Line ("  cvtsi2ss xmm0, dword [rsp + 52]");
      Line ("  movss dword [rsp + 32], xmm0");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  mov rax, qword [rel ALB_SDL_RenderLine]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 72"); -- DA FIX
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Color:");
      Line ("  mov qword [rel ALB_Current_Color], rcx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Font:");
      Line ("  mov qword [rel ALB_Current_Font], rcx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Clear_Color:");
      Line ("  mov qword [rel ALB_Clear_Color], rcx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Map_Render_X:");
      Line ("  movsxd rax, ecx");
      Line ("  add rax, qword [rel ALB_Origin_X]");
      Line ("  cmp qword [rel ALB_Scale_Mode], 0");
      Line ("  jne .done");
      Line ("  add rax, qword [rel ALB_Content_Offset_X]");
      Line (".done:");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Map_Render_Y:");
      Line ("  movsxd rax, edx");
      Line ("  add rax, qword [rel ALB_Origin_Y]");
      Line ("  cmp qword [rel ALB_Scale_Mode], 0");
      Line ("  jne .done");
      Line ("  add rax, qword [rel ALB_Content_Offset_Y]");
      Line (".done:");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Fullscreen:");
      Line ("  mov qword [rel ALB_Window_Fullscreen], rcx");
      Line ("  sub rsp, 40");
      Line ("  mov r10, qword [rel ALB_Window]");
      Line ("  test r10, r10");
      Line ("  jz .done");
      Line ("  mov rax, qword [rel ALB_SDL_SetWindowFullscreen]");
      Line ("  test rax, rax");
      Line ("  jz .done");
      Line ("  mov rdx, qword [rel ALB_Window_Fullscreen]");
      Line ("  and edx, 1");
      Line ("  mov rcx, r10");
      Line ("  call rax");
      Line ("  call ALB_Update_Output_State");
      Line ("  call ALB_Apply_Clip");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Resizable:");
      Line ("  mov qword [rel ALB_Window_Resizable], rcx");
      Line ("  sub rsp, 40");
      Line ("  mov r10, qword [rel ALB_Window]");
      Line ("  test r10, r10");
      Line ("  jz .done");
      Line ("  mov rax, qword [rel ALB_SDL_SetWindowResizable]");
      Line ("  test rax, rax");
      Line ("  jz .done");
      Line ("  mov rdx, qword [rel ALB_Window_Resizable]");
      Line ("  and edx, 1");
      Line ("  mov rcx, r10");
      Line ("  call rax");
      Line ("  call ALB_Update_Output_State");
      Line ("  call ALB_Apply_Clip");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Stretchy:");
      Line ("  and ecx, 1");
      Line ("  mov qword [rel ALB_Scale_Mode], rcx");
      Line ("  sub rsp, 40");
      Line ("  call ALB_Update_Output_State");
      Line ("  call ALB_Apply_Clip");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Key_State:");
      Line ("  sub rsp, 40");
      Line ("  mov qword [rsp + 32], rcx");
      Line ("  cmp rcx, 256");
      Line ("  jae .zero");
      Line ("  xor rcx, rcx");
      Line ("  mov rax, qword [rel ALB_SDL_GetKeyboardState]");
      Line ("  call rax");
      Line ("  test rax, rax");
      Line ("  jz .zero");
      Line ("  mov rcx, qword [rsp + 32]");
      Line ("  movzx eax, byte [rax + rcx]");
      Line ("  jmp .done");
      Line (".zero:");
      Line ("  xor eax, eax");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Mouse_Click_State:");
      Line ("  cmp rcx, 1");
      Line ("  jne .check_middle");
      Line ("  mov ecx, 2");
      Line ("  jmp .mapped");
      Line (".check_middle:");
      Line ("  cmp rcx, 2");
      Line ("  jne .mapped");
      Line ("  mov ecx, 1");
      Line (".mapped:");
      Line ("  mov rax, 1");
      Line ("  shl rax, cl");
      Line ("  and rax, qword [rel ALB_Mouse_Btn]");
      Line ("  setnz al");
      Line ("  movzx eax, al");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Sys_Renderer:");
      Line ("  cmp qword [rel ALB_Renderer], 0");
      Line ("  je .none");
      Line ("  mov eax, 4");
      Line ("  ret");
      Line (".none:");
      Line ("  xor eax, eax");
      Line ("  ret");
      Emit_Newline (S);

      --  Line ("ALB_Delay:");
      --  Line ("  sub rsp, 40");
      --  Line ("  mov rax, qword [rel ALB_SDL_Delay]");
      --  Line ("  call rax");
      --  Line ("  add rsp, 40");
      --  Line ("  ret");
      --  Emit_Newline (S);
      
      -- ALB_Delay is emitted once by the common FASM runtime using kernel32 Sleep.
      null;

      Line ("ALB_Apply_Clip:");
      Line ("  sub rsp, 72");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  cmp qword [rel ALB_Clip_Enabled], 0");
      Line ("  jne .with_clip");
      Line ("  xor rdx, rdx");
      Line ("  mov rax, qword [rel ALB_SDL_SetRenderClipRect]");
      Line ("  call rax");
      Line ("  jmp .done");
      Line (".with_clip:");
      Line ("  mov ecx, dword [rel ALB_Clip_X]");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rel ALB_SDL_Rect + 0], eax");
      Line ("  mov edx, dword [rel ALB_Clip_Y]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rel ALB_SDL_Rect + 4], eax");
      Line ("  mov eax, dword [rel ALB_Clip_X]");
      Line ("  add eax, dword [rel ALB_Clip_W]");
      Line ("  mov ecx, eax");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 40], eax");
      Line ("  mov eax, dword [rel ALB_Clip_Y]");
      Line ("  add eax, dword [rel ALB_Clip_H]");
      Line ("  mov edx, eax");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 44], eax");
      Line ("  mov eax, dword [rsp + 40]");
      Line ("  sub eax, dword [rel ALB_SDL_Rect + 0]");
      Line ("  cmp eax, 1");
      Line ("  jge .clip_w_ok");
      Line ("  mov eax, 1");
      Line (".clip_w_ok:");
      Line ("  mov dword [rel ALB_SDL_Rect + 8], eax");
      Line ("  mov eax, dword [rsp + 44]");
      Line ("  sub eax, dword [rel ALB_SDL_Rect + 4]");
      Line ("  cmp eax, 1");
      Line ("  jge .clip_h_ok");
      Line ("  mov eax, 1");
      Line (".clip_h_ok:");
      Line ("  mov dword [rel ALB_SDL_Rect + 12], eax");
      Line ("  lea rdx, [rel ALB_SDL_Rect]");
      Line ("  mov rax, qword [rel ALB_SDL_SetRenderClipRect]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 72");
      Line ("  ret");
      Emit_Newline (S);


      Line ("ALB_Update_Output_State:");
      Line ("  sub rsp, 40");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  lea rdx, [rel ALB_Size_W]");
      Line ("  lea r8, [rel ALB_Size_H]");
      Line ("  mov rax, qword [rel ALB_SDL_GetCurrentRenderOutputSize]");
      Line ("  call rax");
      Line ("  test al, al");
      Line ("  jz .done");
      Line ("  movsxd rax, dword [rel ALB_Size_W]");
      Line ("  mov qword [rel ALB_Screen_Width], rax");
      Line ("  movsxd rax, dword [rel ALB_Size_H]");
      Line ("  mov qword [rel ALB_Screen_Height], rax");
      Line ("  cmp qword [rel ALB_Scale_Mode], 0");
      Line ("  jne .stretch");
      Line ("  mov rax, qword [rel ALB_Screen_Width]");
      Line ("  sub rax, qword [rel ALB_Virtual_Width]");
      Line ("  cmp rax, 0");
      Line ("  jg .offset_x_ok");
      Line ("  xor eax, eax");
      Line (".offset_x_ok:");
      Line ("  sar rax, 1");
      Line ("  mov qword [rel ALB_Content_Offset_X], rax");
      Line ("  mov rax, qword [rel ALB_Screen_Height]");
      Line ("  sub rax, qword [rel ALB_Virtual_Height]");
      Line ("  cmp rax, 0");
      Line ("  jg .offset_y_ok");
      Line ("  xor eax, eax");
      Line (".offset_y_ok:");
      Line ("  sar rax, 1");
      Line ("  mov qword [rel ALB_Content_Offset_Y], rax");
      Line ("  mov rax, qword [rel ALB_SDL_SetRenderLogicalPresentation]");
      Line ("  test rax, rax");
      Line ("  jz .done");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  xor edx, edx");
      Line ("  xor r8d, r8d");
      Line ("  xor r9d, r9d");
      Line ("  call rax");
      Line ("  jmp .done");
      Line (".stretch:");
      Line ("  mov qword [rel ALB_Content_Offset_X], 0");
      Line ("  mov qword [rel ALB_Content_Offset_Y], 0");
      Line ("  mov rax, qword [rel ALB_SDL_SetRenderLogicalPresentation]");
      Line ("  test rax, rax");
      Line ("  jz .done");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  mov edx, dword [rel ALB_Virtual_Width]");
      Line ("  mov r8d, dword [rel ALB_Virtual_Height]");
      Line ("  mov r9d, 1");
      Line ("  call rax");
      Line (".done:");
      Line ("  call ALB_Apply_Clip");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Update_Mouse_State:");
      Line ("  sub rsp, 40");
      Line ("  lea rcx, [rel ALB_Mouse_FX]");
      Line ("  lea rdx, [rel ALB_Mouse_FY]");
      Line ("  mov rax, qword [rel ALB_SDL_GetMouseState]");
      Line ("  call rax");
      Line ("  mov qword [rel ALB_Mouse_Btn], rax");
      Line ("  cvttss2si ecx, dword [rel ALB_Mouse_FX]");
      Line ("  movsxd rax, ecx");
      Line ("  mov qword [rel ALB_Mouse_X], rax");
      Line ("  cvttss2si edx, dword [rel ALB_Mouse_FY]");
      Line ("  movsxd rax, edx");
      Line ("  mov qword [rel ALB_Mouse_Y], rax");
      Line ("  cmp qword [rel ALB_Screen_Width], 0");
      Line ("  je .copy_raw");
      Line ("  cmp qword [rel ALB_Screen_Height], 0");
      Line ("  je .copy_raw");
      Line ("  cmp qword [rel ALB_Scale_Mode], 0");
      Line ("  je .letterbox");
      Line ("  mov rax, qword [rel ALB_Mouse_X]");
      Line ("  mov r10, qword [rel ALB_Virtual_Width]");
      Line ("  imul rax, r10");
      Line ("  xor rdx, rdx");
      Line ("  div qword [rel ALB_Screen_Width]");
      Line ("  mov qword [rel ALB_VMouse_X], rax");
      Line ("  mov rax, qword [rel ALB_Mouse_Y]");
      Line ("  mov r10, qword [rel ALB_Virtual_Height]");
      Line ("  imul rax, r10");
      Line ("  xor rdx, rdx");
      Line ("  div qword [rel ALB_Screen_Height]");
      Line ("  mov qword [rel ALB_VMouse_Y], rax");
      Line ("  jmp .done");
      Line (".letterbox:");
      Line ("  mov rax, qword [rel ALB_Mouse_X]");
      Line ("  sub rax, qword [rel ALB_Content_Offset_X]");
      Line ("  cmp rax, 0");
      Line ("  jge .letterbox_x_nonneg");
      Line ("  xor eax, eax");
      Line (".letterbox_x_nonneg:");
      Line ("  mov r10, qword [rel ALB_Virtual_Width]");
      Line ("  cmp rax, r10");
      Line ("  jl .letterbox_x_ok");
      Line ("  test r10, r10");
      Line ("  jz .letterbox_x_zero");
      Line ("  mov rax, r10");
      Line ("  dec rax");
      Line ("  jmp .letterbox_x_ok");
      Line (".letterbox_x_zero:");
      Line ("  xor eax, eax");
      Line (".letterbox_x_ok:");
      Line ("  mov qword [rel ALB_VMouse_X], rax");
      Line ("  mov rax, qword [rel ALB_Mouse_Y]");
      Line ("  sub rax, qword [rel ALB_Content_Offset_Y]");
      Line ("  cmp rax, 0");
      Line ("  jge .letterbox_y_nonneg");
      Line ("  xor eax, eax");
      Line (".letterbox_y_nonneg:");
      Line ("  mov r10, qword [rel ALB_Virtual_Height]");
      Line ("  cmp rax, r10");
      Line ("  jl .letterbox_y_ok");
      Line ("  test r10, r10");
      Line ("  jz .letterbox_y_zero");
      Line ("  mov rax, r10");
      Line ("  dec rax");
      Line ("  jmp .letterbox_y_ok");
      Line (".letterbox_y_zero:");
      Line ("  xor eax, eax");
      Line (".letterbox_y_ok:");
      Line ("  mov qword [rel ALB_VMouse_Y], rax");
      Line ("  jmp .done");
      Line (".copy_raw:");
      Line ("  mov rax, qword [rel ALB_Mouse_X]");
      Line ("  mov qword [rel ALB_VMouse_X], rax");
      Line ("  mov rax, qword [rel ALB_Mouse_Y]");
      Line ("  mov qword [rel ALB_VMouse_Y], rax");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Origin:");
      Line ("  movsxd rax, ecx");
      Line ("  mov qword [rel ALB_Origin_X], rax");
      Line ("  movsxd rax, edx");
      Line ("  mov qword [rel ALB_Origin_Y], rax");
      Line ("  sub rsp, 40");
      Line ("  call ALB_Apply_Clip");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Clip:");
      Line ("  movsxd rax, ecx");
      Line ("  mov qword [rel ALB_Clip_X], rax");
      Line ("  movsxd rax, edx");
      Line ("  mov qword [rel ALB_Clip_Y], rax");
      Line ("  movsxd rax, r8d");
      Line ("  mov qword [rel ALB_Clip_W], rax");
      Line ("  movsxd rax, r9d");
      Line ("  mov qword [rel ALB_Clip_H], rax");
      Line ("  cmp r8, 0");
      Line ("  jne .enable");
      Line ("  cmp r9, 0");
      Line ("  jne .enable");
      Line ("  mov qword [rel ALB_Clip_Enabled], 0");
      Line ("  jmp .apply");
      Line (".enable:");
      Line ("  mov qword [rel ALB_Clip_Enabled], 1");
      Line (".apply:");
      Line ("  sub rsp, 40");
      Line ("  call ALB_Apply_Clip");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Set_Alpha:");
      Line ("  mov r10, rcx");
      Line ("  sub rsp, 40");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  cmp r10, 0");
      Line ("  jg .blend");
      Line ("  xor edx, edx");
      Line ("  jmp .set");
      Line (".blend:");
      Line ("  mov edx, 1");
      Line (".set:");
      Line ("  mov rax, qword [rel ALB_SDL_SetRenderDrawBlendMode]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Read_Pixel:");
      Line ("  sub rsp, 72"); -- DA FIX: Win64 Stack Adjustment
      Line ("  mov dword [rel ALB_SDL_Rect], ecx");
      Line ("  mov dword [rel ALB_SDL_Rect + 4], edx");
      Line ("  mov dword [rel ALB_SDL_Rect + 8], 1");
      Line ("  mov dword [rel ALB_SDL_Rect + 12], 1");
      Line ("  mov byte [rel ALB_Pixel_R], 0");
      Line ("  mov byte [rel ALB_Pixel_G], 0");
      Line ("  mov byte [rel ALB_Pixel_B], 0");
      Line ("  mov byte [rel ALB_Pixel_A], 0");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rel ALB_SDL_Rect], eax");
      Line ("  mov edx, dword [rel ALB_SDL_Rect + 4]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rel ALB_SDL_Rect + 4], eax");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .fail");
      Line ("  lea rdx, [rel ALB_SDL_Rect]");
      Line ("  mov rax, qword [rel ALB_SDL_RenderReadPixels]");
      Line ("  call rax");
      Line ("  test rax, rax");
      Line ("  jz .fail");
      Line ("  mov qword [rsp + 56], rax");
      Line ("  mov rcx, rax");
      Line ("  xor edx, edx");
      Line ("  xor r8d, r8d");
      Line ("  lea r9, [rel ALB_Pixel_R]");
      Line ("  lea r10, [rel ALB_Pixel_G]");
      Line ("  mov qword [rsp + 32], r10");
      Line ("  lea r10, [rel ALB_Pixel_B]");
      Line ("  mov qword [rsp + 40], r10");
      Line ("  lea r10, [rel ALB_Pixel_A]");
      Line ("  mov qword [rsp + 48], r10");
      Line ("  mov rax, qword [rel ALB_SDL_ReadSurfacePixel]");
      Line ("  call rax");
      Line ("  mov rcx, qword [rsp + 56]");
      Line ("  mov rax, qword [rel ALB_SDL_DestroySurface]");
      Line ("  call rax");
      Line ("  movzx eax, byte [rel ALB_Pixel_A]");
      Line ("  shl rax, 24");
      Line ("  movzx edx, byte [rel ALB_Pixel_R]");
      Line ("  shl rdx, 16");
      Line ("  or rax, rdx");
      Line ("  movzx edx, byte [rel ALB_Pixel_G]");
      Line ("  shl rdx, 8");
      Line ("  or rax, rdx");
      Line ("  movzx edx, byte [rel ALB_Pixel_B]");
      Line ("  or rax, rdx");
      Line ("  jmp .done");
      Line (".fail:");
      Line ("  xor rax, rax");
      Line (".done:");
      Line ("  add rsp, 72"); -- DA FIX
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Put_Pixel:");
      Line ("  sub rsp, 40");
      Line ("  mov dword [rsp + 24], ecx");
      Line ("  mov dword [rsp + 28], edx");
      Line ("  call ALB_Apply_Color");
      Line ("  mov ecx, dword [rsp + 24]");
      Line ("  mov edx, dword [rsp + 28]");
      Line ("  add rsp, 40");
      Line ("  jmp ALB_Render_Point_Raw");
      Emit_Newline (S);

      Line ("ALB_Draw_Line:");
      Line ("  sub rsp, 72"); -- DA FIX: Win64 Stack Adjustment
      Line ("  mov dword [rsp + 40], ecx");
      Line ("  mov dword [rsp + 44], edx");
      Line ("  mov dword [rsp + 48], r8d");
      Line ("  mov dword [rsp + 52], r9d");
      Line ("  call ALB_Apply_Color");
      Line ("  mov ecx, dword [rsp + 40]");
      Line ("  mov edx, dword [rsp + 44]");
      Line ("  mov r8d, dword [rsp + 48]");
      Line ("  mov r9d, dword [rsp + 52]");
      Line ("  add rsp, 72"); -- DA FIX
      Line ("  jmp ALB_Render_Line_Raw");
      Emit_Newline (S);

      Line ("ALB_Draw_Rect:");
      Line ("  sub rsp, 56");
      Line ("  mov dword [rsp + 40], ecx");
      Line ("  mov dword [rsp + 44], edx");
      Line ("  mov dword [rsp + 48], r8d");
      Line ("  mov dword [rsp + 52], r9d");
      Line ("  call ALB_Apply_Color");
      Line ("  mov ecx, dword [rsp + 40]");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 24], eax");
      Line ("  mov edx, dword [rsp + 44]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 28], eax");
      Line ("  mov eax, dword [rsp + 40]");
      Line ("  add eax, dword [rsp + 48]");
      Line ("  mov ecx, eax");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 32], eax");
      Line ("  mov eax, dword [rsp + 44]");
      Line ("  add eax, dword [rsp + 52]");
      Line ("  mov edx, eax");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 36], eax");
      Line ("  mov eax, dword [rsp + 32]");
      Line ("  sub eax, dword [rsp + 24]");
      Line ("  mov dword [rsp + 48], eax");
      Line ("  mov eax, dword [rsp + 36]");
      Line ("  sub eax, dword [rsp + 28]");
      Line ("  mov dword [rsp + 52], eax");
      Line ("  cvtsi2ss xmm0, dword [rsp + 24]");
      Line ("  movss [rel ALB_SDL_FRect + 0], xmm0");
      Line ("  cvtsi2ss xmm0, dword [rsp + 28]");
      Line ("  movss [rel ALB_SDL_FRect + 4], xmm0");
      Line ("  cvtsi2ss xmm0, dword [rsp + 48]");
      Line ("  movss [rel ALB_SDL_FRect + 8], xmm0");
      Line ("  cvtsi2ss xmm0, dword [rsp + 52]");
      Line ("  movss [rel ALB_SDL_FRect + 12], xmm0");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  lea rdx, [rel ALB_SDL_FRect]");
      Line ("  mov rax, qword [rel ALB_SDL_RenderRect]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 56");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Fill_Rect:");
      Line ("  sub rsp, 56");
      Line ("  mov dword [rsp + 40], ecx");
      Line ("  mov dword [rsp + 44], edx");
      Line ("  mov dword [rsp + 48], r8d");
      Line ("  mov dword [rsp + 52], r9d");
      Line ("  call ALB_Apply_Color");
      Line ("  mov ecx, dword [rsp + 40]");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 24], eax");
      Line ("  mov edx, dword [rsp + 44]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 28], eax");
      Line ("  mov eax, dword [rsp + 40]");
      Line ("  add eax, dword [rsp + 48]");
      Line ("  mov ecx, eax");
      Line ("  call ALB_Map_Render_X");
      Line ("  mov dword [rsp + 32], eax");
      Line ("  mov eax, dword [rsp + 44]");
      Line ("  add eax, dword [rsp + 52]");
      Line ("  mov edx, eax");
      Line ("  call ALB_Map_Render_Y");
      Line ("  mov dword [rsp + 36], eax");
      Line ("  mov eax, dword [rsp + 32]");
      Line ("  sub eax, dword [rsp + 24]");
      Line ("  mov dword [rsp + 48], eax");
      Line ("  mov eax, dword [rsp + 36]");
      Line ("  sub eax, dword [rsp + 28]");
      Line ("  mov dword [rsp + 52], eax");
      Line ("  cvtsi2ss xmm0, dword [rsp + 24]");
      Line ("  movss [rel ALB_SDL_FRect + 0], xmm0");
      Line ("  cvtsi2ss xmm0, dword [rsp + 28]");
      Line ("  movss [rel ALB_SDL_FRect + 4], xmm0");
      Line ("  cvtsi2ss xmm0, dword [rsp + 48]");
      Line ("  movss [rel ALB_SDL_FRect + 8], xmm0");
      Line ("  cvtsi2ss xmm0, dword [rsp + 52]");
      Line ("  movss [rel ALB_SDL_FRect + 12], xmm0");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  lea rdx, [rel ALB_SDL_FRect]");
      Line ("  mov rax, qword [rel ALB_SDL_RenderFillRect]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 56");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Draw_Circle:");
      Line ("  push rbx");
      Line ("  push rdi");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  push r14");
      Line ("  push r15");
      Line ("  sub rsp, 40");
      Line ("  mov r12, rcx");
      Line ("  mov r13, rdx");
      Line ("  mov r14, r8");
      Line ("  call ALB_Apply_Color");
      Line ("  xor r15, r15");
      Line ("  mov rbx, r14");
      Line ("  mov rdi, 3");
      Line ("  mov rax, r14");
      Line ("  shl rax, 1");
      Line ("  sub rdi, rax");
      Line (".loop:");
      Line ("  cmp rbx, r15");
      Line ("  jl .done");
      Line ("  cmp r15, 8192");
      Line ("  jg .done");

      Line ("  mov ecx, r12d");
      Line ("  add ecx, r15d");
      Line ("  mov edx, r13d");
      Line ("  add edx, ebx");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  mov ecx, r12d");
      Line ("  sub ecx, r15d");
      Line ("  mov edx, r13d");
      Line ("  add edx, ebx");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  mov ecx, r12d");
      Line ("  add ecx, r15d");
      Line ("  mov edx, r13d");
      Line ("  sub edx, ebx");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  mov ecx, r12d");
      Line ("  sub ecx, r15d");
      Line ("  mov edx, r13d");
      Line ("  sub edx, ebx");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  mov ecx, r12d");
      Line ("  add ecx, ebx");
      Line ("  mov edx, r13d");
      Line ("  add edx, r15d");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  mov ecx, r12d");
      Line ("  sub ecx, ebx");
      Line ("  mov edx, r13d");
      Line ("  add edx, r15d");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  mov ecx, r12d");
      Line ("  add ecx, ebx");
      Line ("  mov edx, r13d");
      Line ("  sub edx, r15d");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  mov ecx, r12d");
      Line ("  sub ecx, ebx");
      Line ("  mov edx, r13d");
      Line ("  sub edx, r15d");
      Line ("  call ALB_Render_Point_Raw");

      Line ("  inc r15");
      Line ("  cmp rdi, 0");
      Line ("  jle .no_dec");
      Line ("  dec rbx");
      Line ("  mov rax, r15");
      Line ("  sub rax, rbx");
      Line ("  lea rax, [rax*4 + 10]");
      Line ("  add rdi, rax");
      Line ("  jmp .loop");
      Line (".no_dec:");
      Line ("  lea rax, [r15*4 + 6]");
      Line ("  add rdi, rax");
      Line ("  jmp .loop");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  pop r15");
      Line ("  pop r14");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  pop rdi");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Fill_Circle:");
      Line ("  push rbx");
      Line ("  push rdi");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  push r14");
      Line ("  push r15");
      Line ("  sub rsp, 40");
      Line ("  mov r12, rcx");
      Line ("  mov r13, rdx");
      Line ("  mov r14, r8");
      Line ("  call ALB_Apply_Color");
      Line ("  xor r15, r15");
      Line ("  mov rbx, r14");
      Line ("  mov rdi, 3");
      Line ("  mov rax, r14");
      Line ("  shl rax, 1");
      Line ("  sub rdi, rax");
      Line (".loop:");
      Line ("  cmp rbx, r15");
      Line ("  jl .done");
      Line ("  cmp r15, 8192");
      Line ("  jg .done");

      Line ("  mov r10d, r13d");
      Line ("  add r10d, ebx");
      Line ("  mov ecx, r12d");
      Line ("  sub ecx, r15d");
      Line ("  mov edx, r10d");
      Line ("  mov r8d, r12d");
      Line ("  add r8d, r15d");
      Line ("  mov r9d, r10d");
      Line ("  call ALB_Render_Line_Raw");

      Line ("  mov r10d, r13d");
      Line ("  sub r10d, ebx");
      Line ("  mov ecx, r12d");
      Line ("  sub ecx, r15d");
      Line ("  mov edx, r10d");
      Line ("  mov r8d, r12d");
      Line ("  add r8d, r15d");
      Line ("  mov r9d, r10d");
      Line ("  call ALB_Render_Line_Raw");

      Line ("  mov r10d, r13d");
      Line ("  add r10d, r15d");
      Line ("  mov ecx, r12d");
      Line ("  sub ecx, ebx");
      Line ("  mov edx, r10d");
      Line ("  mov r8d, r12d");
      Line ("  add r8d, ebx");
      Line ("  mov r9d, r10d");
      Line ("  call ALB_Render_Line_Raw");

      Line ("  mov r10d, r13d");
      Line ("  sub r10d, r15d");
      Line ("  mov ecx, r12d");
      Line ("  sub ecx, ebx");
      Line ("  mov edx, r10d");
      Line ("  mov r8d, r12d");
      Line ("  add r8d, ebx");
      Line ("  mov r9d, r10d");
      Line ("  call ALB_Render_Line_Raw");

      Line ("  inc r15");
      Line ("  cmp rdi, 0");
      Line ("  jle .no_dec");
      Line ("  dec rbx");
      Line ("  mov rax, r15");
      Line ("  sub rax, rbx");
      Line ("  lea rax, [rax*4 + 10]");
      Line ("  add rdi, rax");
      Line ("  jmp .loop");
      Line (".no_dec:");
      Line ("  lea rax, [r15*4 + 6]");
      Line ("  add rdi, rax");
      Line ("  jmp .loop");
      Line (".done:");
      Line ("  add rsp, 40");
      Line ("  pop r15");
      Line ("  pop r14");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  pop rdi");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Draw_Triangle:");
      Line ("  mov r10, qword [rsp + 40]");
      Line ("  mov r11, qword [rsp + 48]");
      Line ("  push rbx");
      Line ("  push rdi");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  push r14");
      Line ("  push r15");
      Line ("  sub rsp, 40");
      Line ("  mov r12, rcx");
      Line ("  mov r13, rdx");
      Line ("  mov r14, r8");
      Line ("  mov r15, r9");
      Line ("  mov rbx, r10");
      Line ("  mov rdi, r11");
      Line ("  call ALB_Apply_Color");

      Line ("  mov ecx, r12d");
      Line ("  mov edx, r13d");
      Line ("  mov r8d, r14d");
      Line ("  mov r9d, r15d");
      Line ("  call ALB_Render_Line_Raw");

      Line ("  mov ecx, r14d");
      Line ("  mov edx, r15d");
      Line ("  mov r8d, ebx");
      Line ("  mov r9d, edi");
      Line ("  call ALB_Render_Line_Raw");

      Line ("  mov ecx, ebx");
      Line ("  mov edx, edi");
      Line ("  mov r8d, r12d");
      Line ("  mov r9d, r13d");
      Line ("  call ALB_Render_Line_Raw");

      Line ("  add rsp, 40");
      Line ("  pop r15");
      Line ("  pop r14");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  pop rdi");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Fill_Triangle:");
      Line ("  mov r10, qword [rsp + 40]");
      Line ("  mov r11, qword [rsp + 48]");
      Line ("  sub rsp, 152");
      Line ("  mov qword [rsp + 96], rcx");
      Line ("  mov qword [rsp + 104], rdx");
      Line ("  mov qword [rsp + 112], r8");
      Line ("  mov qword [rsp + 120], r9");
      Line ("  mov qword [rsp + 128], r10");
      Line ("  mov qword [rsp + 136], r11");

      Line ("  mov ecx, dword [rsp + 96]");
      Line ("  call ALB_Map_Render_X");
      Line ("  cvtsi2ss xmm0, eax");
      Line ("  movss [rel ALB_Geom_XY + 0], xmm0");
      Line ("  mov edx, dword [rsp + 104]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  cvtsi2ss xmm0, eax");
      Line ("  movss [rel ALB_Geom_XY + 4], xmm0");
      Line ("  mov ecx, dword [rsp + 112]");
      Line ("  call ALB_Map_Render_X");
      Line ("  cvtsi2ss xmm0, eax");
      Line ("  movss [rel ALB_Geom_XY + 8], xmm0");
      Line ("  mov edx, dword [rsp + 120]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  cvtsi2ss xmm0, eax");
      Line ("  movss [rel ALB_Geom_XY + 12], xmm0");
      Line ("  mov ecx, dword [rsp + 128]");
      Line ("  call ALB_Map_Render_X");
      Line ("  cvtsi2ss xmm0, eax");
      Line ("  movss [rel ALB_Geom_XY + 16], xmm0");
      Line ("  mov edx, dword [rsp + 136]");
      Line ("  call ALB_Map_Render_Y");
      Line ("  cvtsi2ss xmm0, eax");
      Line ("  movss [rel ALB_Geom_XY + 20], xmm0");

      Line ("  mov eax, dword [rel ALB_Current_Color]");
      Line ("  mov edx, eax");
      Line ("  shr edx, 16");
      Line ("  and edx, 255");
      Line ("  cvtsi2ss xmm0, edx");
      Line ("  mulss xmm0, dword [rel ALB_F32_Inv255]");
      Line ("  movss [rel ALB_Geom_Color + 0], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 16], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 32], xmm0");

      Line ("  mov edx, eax");
      Line ("  shr edx, 8");
      Line ("  and edx, 255");
      Line ("  cvtsi2ss xmm0, edx");
      Line ("  mulss xmm0, dword [rel ALB_F32_Inv255]");
      Line ("  movss [rel ALB_Geom_Color + 4], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 20], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 36], xmm0");

      Line ("  mov edx, eax");
      Line ("  and edx, 255");
      Line ("  cvtsi2ss xmm0, edx");
      Line ("  mulss xmm0, dword [rel ALB_F32_Inv255]");
      Line ("  movss [rel ALB_Geom_Color + 8], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 24], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 40], xmm0");

      Line ("  mov edx, dword [rel ALB_Current_Color]");
      Line ("  shr edx, 24");
      Line ("  and edx, 255");
      Line ("  cmp edx, 0");
      Line ("  jne .alpha_ok");
      Line ("  mov edx, 255");
      Line (".alpha_ok:");
      Line ("  cvtsi2ss xmm0, edx");
      Line ("  mulss xmm0, dword [rel ALB_F32_Inv255]");
      Line ("  movss [rel ALB_Geom_Color + 12], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 28], xmm0");
      Line ("  movss [rel ALB_Geom_Color + 44], xmm0");

      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .done");
      Line ("  xor rdx, rdx");
      Line ("  lea r8, [rel ALB_Geom_XY]");
      Line ("  mov r9d, 8");
      Line ("  lea rax, [rel ALB_Geom_Color]");
      Line ("  mov qword [rsp + 32], rax");
      Line ("  mov qword [rsp + 40], 16");
      Line ("  mov qword [rsp + 48], 0");
      Line ("  mov qword [rsp + 56], 0");
      Line ("  mov qword [rsp + 64], 3");
      Line ("  mov qword [rsp + 72], 0");
      Line ("  mov qword [rsp + 80], 0");
      Line ("  mov qword [rsp + 88], 0");
      Line ("  mov rax, qword [rel ALB_SDL_RenderGeometryRaw]");
      Line ("  call rax");
      Line (".done:");
      Line ("  add rsp, 152");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Draw_Text:");
      Line ("  mov r10, qword [rel ALB_Current_Font]");
      Line ("  test r10, r10");
      Line ("  jz ALB_Draw_Text_Debug");
      Line ("  cmp qword [r10 + 0], 1");
      Line ("  je ALB_Draw_Text_Bitmap");
      Line ("  jmp ALB_Draw_Text_Debug");
      Emit_Newline (S);

      Line ("ALB_Draw_Text_Bitmap:");
      Line ("  push rbx");
      Line ("  push rsi");
      Line ("  push rdi");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  push r14");
      Line ("  push r15");
      Line ("  sub rsp, 160");
      Line ("  mov r12, rcx");
      Line ("  mov r13, rdx");
      Line ("  mov r14, rcx");
      Line ("  mov r15, r8");
      Line ("  mov r10, qword [rel ALB_Current_Font]");
      Line ("  test r15, r15");
      Line ("  jz .done");
      Line ("  test r10, r10");
      Line ("  jz .done");
      Line ("  mov rbx, qword [r10 + 8]");
      Line ("  mov rax, qword [r10 + 16]");
      Line ("  mov qword [rsp + 32], rax");
      Line ("  mov rax, qword [r10 + 32]");
      Line ("  mov qword [rsp + 40], rax");
      Line ("  mov rax, qword [r10 + 40]");
      Line ("  mov qword [rsp + 48], rax");
      Line ("  mov rax, qword [r10 + 48]");
      Line ("  mov qword [rsp + 56], rax");
      Line ("  test rbx, rbx");
      Line ("  jz .done");
      Line ("  cmp qword [rsp + 32], 0");
      Line ("  jz .done");
      Line ("  cmp qword [rsp + 40], 0");
      Line ("  jz .done");
      Line ("  cmp qword [rsp + 48], 0");
      Line ("  jz .done");
      Line ("  call ALB_Apply_Color");
      Line (".line_loop:");
      Line ("  movzx eax, byte [r15]");
      Line ("  test al, al");
      Line ("  jz .done");
      Line ("  cmp al, 13");
      Line ("  je .skip_cr");
      Line ("  cmp al, 10");
      Line ("  je .newline");
      Line ("  mov rax, qword [rsp + 48]");
      Line ("  movzx ecx, byte [r15]");
      Line ("  shl rcx, 6");
      Line ("  add rax, rcx");
      Line ("  mov qword [rsp + 64], rax");
      Line ("  cmp qword [rax + 56], 0");
      Line ("  je .advance_missing");
      Line ("  mov rax, qword [rsp + 64]");
      Line ("  mov rcx, qword [rax + 0]");
      Line ("  mov qword [rsp + 72], rcx");
      Line ("  mov rcx, qword [rax + 8]");
      Line ("  mov qword [rsp + 80], rcx");
      Line ("  mov rcx, qword [rax + 16]");
      Line ("  mov qword [rsp + 88], rcx");
      Line ("  mov rcx, qword [rax + 24]");
      Line ("  mov qword [rsp + 96], rcx");
      Line ("  mov rcx, qword [rax + 32]");
      Line ("  mov qword [rsp + 104], rcx");
      Line ("  mov rcx, qword [rax + 40]");
      Line ("  mov qword [rsp + 112], rcx");
      Line ("  mov rcx, qword [rax + 48]");
      Line ("  mov qword [rsp + 120], rcx");
      Line ("  cmp qword [rsp + 88], 0");
      Line ("  jz .advance_entry");
      Line ("  cmp qword [rsp + 96], 0");
      Line ("  jz .advance_entry");
      Line ("  xor esi, esi");
      Line (".row_loop:");
      Line ("  cmp rsi, qword [rsp + 96]");
      Line ("  jae .advance_entry");
      Line ("  mov rax, qword [rsp + 80]");
      Line ("  add rax, rsi");
      Line ("  imul rax, qword [rsp + 32]");
      Line ("  add rax, qword [rsp + 72]");
      Line ("  lea rax, [rbx + rax]");
      Line ("  mov qword [rsp + 128], rax");
      Line ("  xor edi, edi");
      Line (".col_loop:");
      Line ("  cmp rdi, qword [rsp + 88]");
      Line ("  jae .next_row");
      Line ("  mov rax, qword [rsp + 128]");
      Line ("  movzx edx, byte [rax + rdi]");
      Line ("  test edx, edx");
      Line ("  jz .skip_px");
      Line ("  mov ecx, r12d");
      Line ("  mov eax, dword [rsp + 104]");
      Line ("  add ecx, eax");
      Line ("  add ecx, edi");
      Line ("  mov edx, r13d");
      Line ("  mov eax, dword [rsp + 112]");
      Line ("  add edx, eax");
      Line ("  add edx, esi");
      Line ("  call ALB_Render_Point_Raw");
      Line (".skip_px:");
      Line ("  inc rdi");
      Line ("  jmp .col_loop");
      Line (".next_row:");
      Line ("  inc rsi");
      Line ("  jmp .row_loop");
      Line (".advance_entry:");
      Line ("  mov rax, qword [rsp + 120]");
      Line ("  test rax, rax");
      Line ("  jnz .have_advance");
      Line ("  mov rax, qword [rsp + 56]");
      Line (".have_advance:");
      Line ("  add r12, rax");
      Line ("  inc r15");
      Line ("  jmp .line_loop");
      Line (".advance_missing:");
      Line ("  mov rax, qword [rsp + 56]");
      Line ("  add r12, rax");
      Line ("  inc r15");
      Line ("  jmp .line_loop");
      Line (".newline:");
      Line ("  inc r15");
      Line ("  mov r12, r14");
      Line ("  add r13, qword [rsp + 40]");
      Line ("  jmp .line_loop");
      Line (".skip_cr:");
      Line ("  inc r15");
      Line ("  jmp .line_loop");
      Line (".done:");
      Line ("  add rsp, 160");
      Line ("  pop r15");
      Line ("  pop r14");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  pop rdi");
      Line ("  pop rsi");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("ALB_Draw_Text_Debug:");
      Line ("  push rbx");
      Line ("  push r12");
      Line ("  push r13");
      Line ("  push r14");
      Line ("  push r15");
      Line ("  sub rsp, 48"); -- DA FIX: Win64 Stack Alignment
      Line ("  mov r12, rcx");
      Line ("  mov r13, rdx");
      Line ("  mov r14, rcx");
      Line ("  mov r15, r8");
      Line ("  test r15, r15");
      Line ("  jz .done");
      Line ("  call ALB_Apply_Color");
      Line (".line_loop:");
      Line ("  xor ebx, ebx");
      Line (".copy_loop:");
      Line ("  mov al, byte [r15]");
      Line ("  cmp al, 0");
      Line ("  je .line_ready");
      Line ("  cmp al, 10");
      Line ("  je .line_ready");
      Line ("  cmp al, 13");
      Line ("  je .skip_cr");
      Line ("  mov byte [rel ALB_Text_Line + rbx], al");
      Line ("  inc rbx");
      Line ("  inc r15");
      Line ("  cmp rbx, 1022");
      Line ("  jl .copy_loop");
      Line ("  jmp .line_ready");
      Line (".skip_cr:");
      Line ("  inc r15");
      Line ("  jmp .copy_loop");
      Line (".line_ready:");
      Line ("  mov byte [rel ALB_Text_Line + rbx], 0");
      Line ("  cmp rbx, 0");
      Line ("  je .after_draw");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  test rcx, rcx");
      Line ("  jz .after_draw");
      Line ("  mov ecx, r12d");
      Line ("  call ALB_Map_Render_X");
      Line ("  cvtsi2ss xmm1, eax");
      Line ("  mov edx, r13d");
      Line ("  call ALB_Map_Render_Y");
      Line ("  cvtsi2ss xmm2, eax");
      Line ("  lea r9, [rel ALB_Text_Line]");
      Line ("  mov rcx, qword [rel ALB_Renderer]");
      Line ("  mov rax, qword [rel ALB_SDL_RenderDebugText]");
      Line ("  call rax");
      Line (".after_draw:");
      Line ("  cmp byte [r15], 0");
      Line ("  je .done");
      Line ("  inc r15");
      Line ("  mov r12, r14");
      Line ("  add r13, 8");
      Line ("  jmp .line_loop");
      Line (".done:");
      Line ("  add rsp, 48"); -- DA FIX
      Line ("  pop r15");
      Line ("  pop r14");
      Line ("  pop r13");
      Line ("  pop r12");
      Line ("  pop rbx");
      Line ("  ret");
      Emit_Newline (S);

      Line ("alb_sdl3_window_runtime_resume:");
      Line ("alb_sdl3_init_start:");

      Ind ("call ALB_Init_SDL3");
      Ind ("test eax, eax");
      Ind ("jnz .alb_sdl_bound");
      Ind ("invoke printf, ALB_Fmt_Str, ALB_SDL_Bind_Fail");
      Ind ("invoke ExitProcess, 1");
      Ind (".alb_sdl_bound:");
      -- 32 bytes of Win64 shadow space + 16 bytes for args 5 and 6.
      -- This block is emitted inline from the process entry path, where
      -- the stack is already call-aligned, so 48 keeps SDL calls aligned.
      Ind ("sub rsp, 48");

      Ind ("mov ecx, 0x00000020");
      Ind ("mov rax, qword [rel ALB_SDL_Init]");
      Ind ("call rax");
      Ind ("test al, al");
      Ind ("jnz .alb_sdl_video_ok");
      Ind ("mov rax, qword [rel ALB_SDL_GetError]");
      Ind ("call rax");
      Ind ("mov rdx, rax");
      Ind ("invoke printf, ALB_Fmt_Str, rdx");
      Ind ("invoke ExitProcess, 1");
      Ind (".alb_sdl_video_ok:");

      Ind ("mov ecx, 0x00000010");
      Ind ("mov rax, qword [rel ALB_SDL_Init]");
      Ind ("call rax");

      Emit_Indent (S); Append ("lea rcx, [", S); Emit_String_Literal (Title, S); Append ("]", S); Emit_Newline (S);
      Ind ("mov edx, dword [rel ALB_Screen_Width]");
      Ind ("mov r8d, dword [rel ALB_Screen_Height]");
      Ind ("xor r9d, r9d");
      Ind ("lea r10, [rel ALB_Window]");
      Ind ("mov qword [rsp + 32], r10");
      Ind ("lea r10, [rel ALB_Renderer]");
      Ind ("mov qword [rsp + 40], r10");
      Ind ("mov rax, qword [rel ALB_SDL_CreateWindowAndRenderer]");
      Ind ("call rax");
      Ind ("test al, al");
      Ind ("jnz .alb_sdl_window_ok");
      Ind ("mov rax, qword [rel ALB_SDL_GetError]");
      Ind ("call rax");
      Ind ("mov rdx, rax");
      Ind ("invoke printf, ALB_Fmt_Str, rdx");
      Ind ("invoke ExitProcess, 1");
      Ind (".alb_sdl_window_ok:");

      -- DA FIX: x64 requires an intermediate register for Memory-to-Memory moves!
      Ind ("mov rax, qword [rel ALB_Screen_Width]");
      Ind ("mov qword [rel ALB_Virtual_Width], rax");
      
      Ind ("mov rax, qword [rel ALB_Screen_Height]");
      Ind ("mov qword [rel ALB_Virtual_Height], rax");

      Ind ("mov rcx, qword [rel ALB_Window_Resizable]");
      Ind ("call ALB_Set_Resizable");
      Ind ("mov rcx, qword [rel ALB_Window_Fullscreen]");
      Ind ("call ALB_Set_Fullscreen");
      Ind ("call ALB_Update_Output_State");
      Ind ("call ALB_Apply_Clip");

      Success := S;
   end Emit_Window_Creation;

   procedure Emit_Set_Fullscreen (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("mov rcx, rax", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("call ALB_Set_Fullscreen", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Set_Fullscreen;

   procedure Emit_Set_Resizable (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("mov rcx, rax", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("call ALB_Set_Resizable", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Set_Resizable;

   procedure Emit_Set_Stretchy (Success : out Boolean) is
      S : Boolean := True;
   begin
      Emit_Indent (S);
      Append ("mov rcx, rax", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("call ALB_Set_Stretchy", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Set_Stretchy;
   
   procedure Emit_Message_Loop (Success : out Boolean) is
      S : Boolean := True;

      procedure Line (Text : String) is
      begin
         Append (Text, S);
         Emit_Newline (S);
      end Line;

      procedure Ind (Text : String) is
      begin
         Emit_Indent (S);
         Append (Text, S);
         Emit_Newline (S);
      end Ind;

   begin
      Ind ("mov qword [rel ALB_Running], 1");
      if NASM_Window_Requested then
         Ind ("cmp qword [rel ALB_Renderer], 0");
         Ind ("jne .alb_gui_loop");
      end if;
      Ind (".alb_headless_loop:");
      Ind ("cmp qword [rel ALB_Running], 0");
      Ind ("je .end_loop");
      Ind ("call ALB_ON_TICK");
      Ind ("cmp qword [rel ALB_Running], 0");
      Ind ("je .end_loop");
      Ind ("mov ecx, 16");
      Ind ("call ALB_Delay");
      Ind ("jmp .alb_headless_loop");
      Emit_Newline (S);

      if NASM_Window_Requested then
      Ind (".alb_gui_loop:");
      Ind ("  .game_loop:");
      Ind ("    cmp qword [rel ALB_Running], 0");
      Ind ("    je .alb_sdl_shutdown");
      Ind ("    mov dword [rel ALB_Mouse_Wheel], 0");
      Ind ("    .msg_loop:");
      Ind ("      lea rcx, [rel ALB_Event_Buffer]");
      Ind ("      mov rax, qword [rel ALB_SDL_PollEvent]");
      Ind ("      call rax");
      Ind ("      test al, al");
      Ind ("      jz .msg_done");
      Ind ("      cmp dword [rel ALB_Event_Buffer], 0x100");
      Ind ("      je .alb_sdl_shutdown");
      Ind ("      cmp dword [rel ALB_Event_Buffer], 0x403");
      Ind ("      jne .msg_loop");
      Ind ("      cvttss2si eax, dword [rel ALB_Event_Buffer + 28]");
      Ind ("      add dword [rel ALB_Mouse_Wheel], eax");
      Ind ("      jmp .msg_loop");
      Ind ("    .msg_done:");
      Emit_Newline (S);

      Ind ("    call ALB_Update_Output_State");
      Ind ("    call ALB_Update_Mouse_State");
      Emit_Newline (S);

      Ind ("    call ALB_ON_EVENT");
      Ind ("    cmp qword [rel ALB_Running], 0");
      Ind ("    je .alb_sdl_shutdown");
      Emit_Newline (S);

      Ind ("    call ALB_ON_TICK");
      Ind ("    cmp qword [rel ALB_Running], 0");
      Ind ("    je .alb_sdl_shutdown");
      Emit_Newline (S);

      Ind ("    mov rcx, qword [rel ALB_Renderer]");
      Ind ("    test rcx, rcx");
      Ind ("    jz .skip_clear");
      Ind ("    mov eax, dword [rel ALB_Clear_Color]");
      Ind ("    mov edx, eax");
      Ind ("    shr edx, 16");
      Ind ("    and edx, 255");
      Ind ("    mov r8d, eax");
      Ind ("    shr r8d, 8");
      Ind ("    and r8d, 255");
      Ind ("    mov r9d, eax");
      Ind ("    and r9d, 255");
      Ind ("    mov dword [rsp + 32], 255");
      Ind ("    mov rax, qword [rel ALB_SDL_SetRenderDrawColor]");
      Ind ("    call rax");
      Ind ("    mov rcx, qword [rel ALB_Renderer]");
      Ind ("    mov rax, qword [rel ALB_SDL_RenderClear]");
      Ind ("    call rax");
      Ind ("    .skip_clear:");
      Emit_Newline (S);

      Ind ("    call ALB_ON_PAINT");
      Emit_Newline (S);

      Ind ("    mov rcx, qword [rel ALB_Renderer]");
      Ind ("    test rcx, rcx");
      Ind ("    jz .skip_present");
      Ind ("    mov rax, qword [rel ALB_SDL_RenderPresent]");
      Ind ("    call rax");
      Ind ("    .skip_present:");
      Emit_Newline (S);

      Ind ("    mov ecx, 16");
      Ind ("    call ALB_Delay");
      Ind ("    jmp .game_loop");
      Emit_Newline (S);

      Ind (".alb_sdl_shutdown:");
      Ind ("    mov rcx, qword [rel ALB_Renderer]");
      Ind ("    test rcx, rcx");
      Ind ("    jz .skip_renderer_destroy");
      Ind ("    mov rax, qword [rel ALB_SDL_DestroyRenderer]");
      Ind ("    call rax");
      Ind ("    mov qword [rel ALB_Renderer], 0");
      Ind ("    .skip_renderer_destroy:");
      Ind ("    mov rcx, qword [rel ALB_Window]");
      Ind ("    test rcx, rcx");
      Ind ("    jz .skip_window_destroy");
      Ind ("    mov rax, qword [rel ALB_SDL_DestroyWindow]");
      Ind ("    call rax");
      Ind ("    mov qword [rel ALB_Window], 0");
      Ind ("    .skip_window_destroy:");
      Ind ("    mov rcx, qword [rel ALB_Music_Stream]");
      Ind ("    test rcx, rcx");
      Ind ("    jz .skip_music_destroy");
      Ind ("    mov rax, qword [rel ALB_SDL_DestroyAudioStream]");
      Ind ("    call rax");
      Ind ("    mov qword [rel ALB_Music_Stream], 0");
      Ind ("    .skip_music_destroy:");
      Ind ("    cmp qword [rel ALB_SDL_Quit], 0");
      Ind ("    je .skip_sdl_quit");
      Ind ("    mov rax, qword [rel ALB_SDL_Quit]");
      Ind ("    call rax");
      Ind ("    .skip_sdl_quit:");
      end if;

      Ind (".end_loop:");

      Success := S;
   end Emit_Message_Loop;


   procedure Emit_Win32_Color_BGR (Color_Hex : String; Success : out Boolean)
   is
   begin
      Append ("0x", Success);
      Append (Color_Hex, Success);
   end Emit_Win32_Color_BGR;
   
   procedure Emit_Cut_Operator (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent(S);
      Append ("; ALB LOGIC CUT", S); Emit_Newline(S);
      Emit_Indent(S);
      Append ("jmp .alb_cut_target", S); Emit_Newline(S); -- Requires a label at the end o' the predicate
      Success := S;
   end Emit_Cut_Operator;
   
   procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
   begin
      -- We reuse the existing format strings frae the Data Vault safely!
      if Tag = Type_U64 then
         Append ("invoke scanf, ALB_Fmt_Num, ", S);
      else
         Append ("invoke scanf, ALB_Fmt_Str, ", S);
      end if;
      Success := S;
   end Emit_Input_Read_Start;
   
   procedure Emit_Struct_Var_Decl (Struct_Name : String; Var_Name : String; Success : out Boolean) is
      S : Boolean;
      Old : Buffer_Target := Current_Buffer;
      Storage_Name : constant String :=
        (if In_Global_Scope then Var_Name else Ensure_Local_Storage_Name (Var_Name));
   begin
      Current_Buffer := Buffer_Global;
      Emit_Indent(S);
      Append (Storage_Name & " " & Struct_Name, S); -- FASM: MyVar MyStructType
      Emit_Newline(S);
      Current_Buffer := Old;
      Success := S;
   end Emit_Struct_Var_Decl;
   
   -- =========================================================================
   -- DA NATIVE INPUT FORGE
   -- =========================================================================

   procedure Emit_Input_Prompt_Start (Success : out Boolean) is
   begin
      -- We reuse the printf bridge for prompts
      Append ("invoke printf, ", Success);
   end Emit_Input_Prompt_Start;

   procedure Emit_Input_Prompt_End (Success : out Boolean) is
   begin
      Success := True; -- FASM invoke disna need a terminator here
   end Emit_Input_Prompt_End;

   --  procedure Emit_Input_Read_Start (Tag : ALB_Type_Tag; Success : out Boolean) is
   --     S : Boolean;
   --  begin
   --     -- Forge the scanf call based on the data type
   --     if Tag = Type_U64 then
   --        Append ("invoke scanf, <'%llu',0>, ", S);
   --     else
   --        Append ("invoke scanf, <'%s',0>, ", S);
   --     end if;
   --     Success := S;
   --  end Emit_Input_Read_Start;

   procedure Emit_Input_Read_End (Tag : ALB_Type_Tag; Success : out Boolean) is
   begin
      Success := True;
   end Emit_Input_Read_End;

   procedure Emit_Readline_Start (Success : out Boolean) is
   begin
      -- Use msvcrt 'gets' for a simple raw string read
      Append ("invoke gets, ", Success);
   end Emit_Readline_Start;

   procedure Emit_Readline_End (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Readline_End;
   
   -- =========================================================================
   -- DA HARDENED CONTRACTS & ORACLES
   -- =========================================================================

   procedure Emit_Require_Start (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Require_Start;

   procedure Emit_Ensure_Start (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Ensure_Start;

   function Contract_Label_Image (Id : Natural) return String is
      Img : String := Natural'Image (Id);
   begin
      return Img (Img'First + 1 .. Img'Last);
   end Contract_Label_Image;

   procedure Emit_Contract_End (Name : String; Success : out Boolean) is
      S          : Boolean;
      Msg_Symbol : constant String :=
        (if Name = "ENSURE" then "ALB_Contract_Ensure" else "ALB_Contract_Require");
   begin
      Contract_Check_Counter := Contract_Check_Counter + 1;
      Emit_Indent (S);
      Append ("test rax, rax", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append
        ("jnz .alb_contract_ok_" & Contract_Label_Image (Contract_Check_Counter),
         S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("sub rsp, 40", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("invoke printf, " & Msg_Symbol, S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("invoke ExitProcess, 1", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append
        (".alb_contract_ok_" & Contract_Label_Image (Contract_Check_Counter) & ":",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Contract_End;

   procedure Emit_SizeOf_Start (Success : out Boolean) is
   begin
      -- NASM uses StructName_size tae calculate static sizes
      Append ("", Success);  -- NASM sizes use Name_size
   end Emit_SizeOf_Start;

   procedure Emit_OffsetOf_Start (Success : out Boolean) is
   begin
      -- Standard NASM notation for field offsets
      Append ("", Success);  -- NASM field offsets are Struct.Field
   end Emit_OffsetOf_Start;

   procedure Emit_Runtime_Assert_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent(S);
      Append ("; --- ALB RUNTIME ASSERTION START ---", S);
      Emit_Newline(S);
      Success := S;
   end Emit_Runtime_Assert_Start;

   procedure Emit_Runtime_Assert_End (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent(S);
      Append ("; --- ALB RUNTIME ASSERTION END ---", S);
      Emit_Newline(S);
      Success := S;
   end Emit_Runtime_Assert_End;
   
   -- =========================================================================
   -- DA MULTI-CORE DISPATCH FORGE
   -- =========================================================================

   procedure Emit_Spawn_Start (Func_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent(S);
      Append ("; --- ALB SPAWN CORE: " & Func_Name & " ---", S);
      Emit_Newline(S);
      
      -- We forge the x64 Win32 CreateThread call
      -- LPTHREAD_START_ROUTINE is the label o' the function
      Emit_Indent(S);
      Append ("invoke CreateThread, 0, 0, " & Func_Name & ", 0, 0, 0", S);
      Emit_Newline(S);
      Success := S;
   end Emit_Spawn_Start;

   procedure Emit_Spawn_End (Success : out Boolean) is
   begin
      -- FASM invoke is a single-line macro, so nae terminator needed
      Success := True;
   end Emit_Spawn_End;

   procedure Emit_Sync (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent(S);
      Append ("; --- ALB SYNC CORES (WAIT FOR TASKS) ---", S);
      Emit_Newline(S);
      
      -- Placeholder for WaitForMultipleObjects logic in the FASM vault
      Emit_Indent(S);
      Append ("; SYNC POINT NOT FULLY IMPL IN RAW ASM YET", S);
      Emit_Newline(S);
      Success := S;
   end Emit_Sync;

   procedure Emit_Atomic_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent(S);
      Append ("; --- ALB ATOMIC TRANSACTION START ---", S);
      Emit_Newline(S);
      
      -- In x64 ASM, we often use the 'lock' prefix for the next instruction
      -- tae ensure cache coherency across cores.
      Emit_Indent(S);
      Append ("lock ", S); 
      Success := S;
   end Emit_Atomic_Start;

   procedure Emit_Atomic_End (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent(S);
      Append ("; --- ALB ATOMIC TRANSACTION END ---", S);
      Emit_Newline(S);
      Success := S;
   end Emit_Atomic_End;
   
   -- =========================================================================
   -- DA HARDENED LOOP STEP FORGE
   -- =========================================================================

   procedure Emit_Loop_Step_Mid (Success : out Boolean) is
      S : Boolean;
   begin
      -- This sits between the loop body and the increment logic
      Emit_Indent(S);
      Append ("; --- ALB LOOP STEP LOGIC START ---", S);
      Emit_Newline(S);
      Success := S;
   end Emit_Loop_Step_Mid;

   procedure Emit_Loop_Step_End (Success : out Boolean) is
      S : Boolean;
   begin
      -- Finalizes the increment block before the jump back
      Emit_Indent(S);
      Append ("; --- ALB LOOP STEP LOGIC END ---", S);
      Emit_Newline(S);
      Success := S;
   end Emit_Loop_Step_End;

   -- =========================================================================
   -- CLAIM / DROP (GC)
   -- =========================================================================

   procedure Emit_Claim (Var_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("; CLAIM " & Var_Name, S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("lea rcx, [" & Var_Name & "]", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("call ALB_GC_Claim", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Claim;

   procedure Emit_Drop (Var_Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("; DROP " & Var_Name, S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("mov rcx, [" & Var_Name & "]", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("call ALB_GC_Drop", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Drop;

   -- =========================================================================
   -- POKE / PEEK / DEREF (C-style streaming; FASM path uses mov qword)
   -- =========================================================================

   procedure Emit_Poke_Start (Success : out Boolean) is
   begin
      -- Leaves an open address expression; Mid stores the qword.
      Append ("mov qword [", Success);
   end Emit_Poke_Start;

   procedure Emit_Poke_Mid (Success : out Boolean) is
   begin
      Append ("], ", Success);
   end Emit_Poke_Mid;

   procedure Emit_Peek_Start (Success : out Boolean) is
   begin
      Append ("qword [", Success);
   end Emit_Peek_Start;

   procedure Emit_Deref_Start (Success : out Boolean) is
   begin
      Append ("qword [", Success);
   end Emit_Deref_Start;

   -- =========================================================================
   -- FFI / INLINE C (NASM ignores C; keep assemble-clean comments)
   -- =========================================================================

   procedure Emit_FFI_Header_Include
     (Library_Name : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("; FFI include: " & Library_Name, S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("; extern symbols from " & Library_Name & " resolved via LoadLibrary", S);
      Emit_Newline (S);
      Success := S;
   end Emit_FFI_Header_Include;

   procedure Emit_FFI_Loader_Prelude (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("; --- ALB FFI LOADER PRELUDE (LoadLibraryA / GetProcAddress) ---", S);
      Emit_Newline (S);
      Success := S;
   end Emit_FFI_Loader_Prelude;

   procedure Emit_Native_C_Block
     (Block_Text : String; Success : out Boolean)
   is
      S : Boolean;
      I : Natural := Block_Text'First;
   begin
      Emit_Indent (S);
      Append ("; INLINE C BLOCK (ignored on NASM):", S);
      Emit_Newline (S);
      while I <= Block_Text'Last loop
         declare
            Line_Start : constant Natural := I;
         begin
            while I <= Block_Text'Last
              and then Block_Text (I) /= ASCII.LF
              and then Block_Text (I) /= ASCII.CR
            loop
               I := I + 1;
            end loop;
            Emit_Indent (S);
            Append ("; ", S);
            if I > Line_Start then
               Append (Block_Text (Line_Start .. I - 1), S);
            end if;
            Emit_Newline (S);
            if I <= Block_Text'Last and then Block_Text (I) = ASCII.CR then
               I := I + 1;
            end if;
            if I <= Block_Text'Last and then Block_Text (I) = ASCII.LF then
               I := I + 1;
            end if;
         end;
      end loop;
      Success := S;
   end Emit_Native_C_Block;

   procedure Emit_Native_C_Expression
     (Block_Text : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Append ("0 ; INLINE C EXPR (ignored on NASM): ", S);
      Append (Block_Text, S);
      Success := S;
   end Emit_Native_C_Expression;

   -- =========================================================================
   -- FILE IO (invoke wrappers; Start/Mid split mirrors C emitter)
   -- =========================================================================

   procedure Emit_File_Open_Start (Success : out Boolean) is
   begin
      Append ("invoke ALB_File_Open, (", Success);
   end Emit_File_Open_Start;

   procedure Emit_File_Open_Mid (Success : out Boolean) is
   begin
      Append ("), (", Success);
   end Emit_File_Open_Mid;

   procedure Emit_File_Read_Start (Success : out Boolean) is
   begin
      Append ("invoke ALB_File_Read, (", Success);
   end Emit_File_Read_Start;

   procedure Emit_File_Read_Mid (Success : out Boolean) is
   begin
      Append ("), (", Success);
   end Emit_File_Read_Mid;

   procedure Emit_File_Write_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("invoke ALB_File_Write, (", S);
      Success := S;
   end Emit_File_Write_Start;

   procedure Emit_File_Write_Mid (Success : out Boolean) is
   begin
      Append ("), (", Success);
   end Emit_File_Write_Mid;

   procedure Emit_File_Close_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("invoke ALB_File_Close, ((", S);
      Success := S;
   end Emit_File_Close_Start;

   procedure Emit_File_Len_Start (Success : out Boolean) is
   begin
      Append ("invoke ALB_File_Len, ((", Success);
   end Emit_File_Len_Start;

   procedure Emit_File_Seek_Start (Success : out Boolean) is
   begin
      Append ("invoke ALB_File_Seek, (", Success);
   end Emit_File_Seek_Start;

   procedure Emit_File_Seek_Mid (Success : out Boolean) is
   begin
      Append ("), (", Success);
   end Emit_File_Seek_Mid;

   -- =========================================================================
   -- GRAPHICS / AUDIO HELPERS
   -- =========================================================================

   procedure Emit_Draw_Line
     (X1, Y1, X2, Y2, Color : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("mov rax, " & Color, S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("mov qword [rel ALB_Current_Color], rax", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append
        ("invoke ALB_Draw_Line, " & X1 & ", " & Y1 & ", " & X2 & ", " & Y2, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Draw_Line;

   procedure Emit_Draw_Rect
     (X, Y, W, H, Color : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      pragma Unreferenced (Color);
      Emit_Indent (S);
      Append
        ("invoke ALB_Draw_Rect, " & X & ", " & Y & ", " & W & ", " & H, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Draw_Rect;

   procedure Emit_Fill_Rect
     (X, Y, W, H, Color : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      pragma Unreferenced (Color);
      Emit_Indent (S);
      Append
        ("invoke ALB_Fill_Rect, " & X & ", " & Y & ", " & W & ", " & H, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Fill_Rect;

   procedure Emit_Blit_Image
     (Source_Vault, X, Y : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append
        ("; BLIT " & Source_Vault & " @ " & X & "," & Y
         & " (NASM: no ALB_Blit_Image runtime yet)",
         S);
      Emit_Newline (S);
      Success := S;
   end Emit_Blit_Image;

   procedure Emit_Load_Sound
     (File_Path, Target_Vault : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("; LOAD_SOUND " & File_Path & " -> " & Target_Vault, S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("lea rax, [", S);
      Append (File_Path, S);
      Append ("]", S);
      Emit_Newline (S);
      Emit_Indent (S);
      Append ("mov qword [" & Target_Vault & "], rax", S);
      Emit_Newline (S);
      Success := S;
   end Emit_Load_Sound;

   procedure Emit_Clear_Color (Color : String; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("invoke ALB_Set_Clear_Color, " & Color, S);
      Emit_Newline (S);
      Success := S;
   end Emit_Clear_Color;

   -- =========================================================================
   -- DA FUNCTION FORGE (MATCHES PROCEDURE ABI)
   -- =========================================================================

   -- Private helper tae handle the 'Jump Over' and 'Label' logic
   procedure Emit_Common_Sub_Prologue (Name : String; Success : out Boolean) is
      S : Boolean;
   begin
      Append ("  jmp skip_proc_", S);
      if S then Append (Name, S); end if;
      if S then Emit_Newline (S); end if;
      
      if S then Append (Name, S); end if;
      if S then Append (":", S); end if;
      if S then Emit_Newline (S); end if;
      Success := S;
   end Emit_Common_Sub_Prologue;

   procedure Emit_Function_Decl_Start (Name : String; Return_Tag : ALB_Type_Tag; Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Common_Sub_Prologue (Name, S);

      -- Debug comment for the Forge
      if S then Append ("  ; RETURN TYPE: ", S); end if;
      if S then Emit_Type_Definition (Return_Tag, S); end if;
      if S then Emit_Newline (S); end if;

      -- Match Emit_Procedure_Decl_Start: preserve RBX + 32-byte shadow.
      if S then Append ("  push rbx", S); end if;
      if S then Emit_Newline (S); end if;
      if S then Append ("  sub rsp, 32", S); end if;
      if S then Emit_Newline (S); end if;

      Begin_Subprogram_Scope (Name);
      In_Global_Scope := False;
      Success := S;
   end Emit_Function_Decl_Start;
   
   procedure Emit_Foreach_Start
     (Iterator_Name : String; Array_Name : String; Success : out Boolean)
   is
      S : Boolean;
   begin
      Foreach_Counter := Foreach_Counter + 1;
      Foreach_Depth := Foreach_Depth + 1;
      Foreach_Stack (Foreach_Depth) := Foreach_Counter;

      declare
         Img      : constant String := Natural'Image (Foreach_Counter);
         ID_Text  : constant String := Img (Img'First + 1 .. Img'Last);
         Idx_Name : constant String := "ALB_FE_IDX_" & ID_Text;
      begin
         Emit_Var_Decl (Idx_Name, Type_U64, S);

         Emit_Indent (S);
         Append ("mov qword [" & Idx_Name & "], 0", S);
         Emit_Newline (S);

         Append (".alb_foreach_start_" & ID_Text & ":", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("mov rbx, qword [" & Idx_Name & "]", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("cmp rbx, " & Array_Name & "_size / 8", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("jge .alb_foreach_end_" & ID_Text, S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("mov rax, qword [" & Array_Name & " + rbx * 8]", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("mov qword [" & Iterator_Name & "], rax", S);
         Emit_Newline (S);

         Success := S;
      end;
   end Emit_Foreach_Start;

   procedure Emit_Try_Start (Success : out Boolean) is
      S : Boolean;
   begin
      Try_Counter := Try_Counter + 1;
      Try_Depth := Try_Depth + 1;
      Try_Stack (Try_Depth) := Try_Counter;

      declare
         Img     : constant String := Natural'Image (Try_Counter);
         ID_Text : constant String := Img (Img'First + 1 .. Img'Last);
      begin
         Emit_Indent (S);
         Append ("inc qword [rel ALB_Err_SP]", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("mov rbx, qword [rel ALB_Err_SP]", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("lea rax, [.alb_catch_" & ID_Text & "]", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("lea rdx, [rel ALB_Err_Target_Stack]", S);
         Emit_Newline (S);
         Emit_Indent (S);
         Append ("mov qword [rdx + rbx*8], rax", S);
         Emit_Newline (S);

         Success := S;
      end;
   end Emit_Try_Start;

   procedure Emit_Catch_Start (Err_Var : String; Success : out Boolean) is
      S : Boolean;
   begin
      if Try_Depth = 0 then
         Success := False;
         return;
      end if;

      declare
         Img     : constant String := Natural'Image (Try_Stack (Try_Depth));
         ID_Text : constant String := Img (Img'First + 1 .. Img'Last);
      begin
         Emit_Indent (S);
         Append ("dec qword [rel ALB_Err_SP]", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("jmp .alb_try_end_" & ID_Text, S);
         Emit_Newline (S);

         Append (".alb_catch_" & ID_Text & ":", S);
         Emit_Newline (S);

         Emit_Indent (S);
         Append ("dec qword [rel ALB_Err_SP]", S);
         Emit_Newline (S);

         if Err_Var'Length > 0 then
            Emit_Indent (S);
            Append ("mov rax, qword [rel ALB_Last_Err]", S);
            Emit_Newline (S);

            Emit_Indent (S);
            Append_Local_Aware ("mov qword [" & Err_Var & "], rax", S);
            Emit_Newline (S);
         end if;

         Success := S;
      end;
   end Emit_Catch_Start;

   procedure Emit_Try_End (Success : out Boolean) is
      S : Boolean;
   begin
      if Try_Depth = 0 then
         Success := False;
         return;
      end if;

      declare
         Img     : constant String := Natural'Image (Try_Stack (Try_Depth));
         ID_Text : constant String := Img (Img'First + 1 .. Img'Last);
      begin
         Append (".alb_try_end_" & ID_Text & ":", S);
         Emit_Newline (S);
         Try_Depth := Try_Depth - 1;
         Success := S;
      end;
   end Emit_Try_End;

   procedure Emit_Throw_Start (Success : out Boolean) is
   begin
      Success := True;
   end Emit_Throw_Start;

   procedure Emit_Throw_End (Success : out Boolean) is
      S : Boolean;
   begin
      Emit_Indent (S);
      Append ("mov rcx, rax", S);
      Emit_Newline (S);

      Emit_Indent (S);
      Append ("fastcall ALB_Throw_Native, rcx", S);
      Emit_Newline (S);

      Success := S;
   end Emit_Throw_End;


   procedure Emit_FITS_Runtime (Success : out Boolean) is
      S : Boolean := True;
      Old_Buf : constant Buffer_Target := Current_Buffer;
   begin
      Current_Buffer := Buffer_Global;
      Append ("ALB_FITS_DataPtr dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_DataSize dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_Dim1 dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_Dim2 dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_Dim3 dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_DimCount dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_ExpDim1 dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_ExpDim2 dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_ExpDim3 dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_ExpDimCount dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_ExpElemBytes dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_BITPIX dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_HeaderOffset dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_FailStage dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_FreadGot dq 0", S); Emit_Newline (S);
      Append ("ALB_FITS_Header resb 2880", S); Emit_Newline (S);
      Append ("ALB_FITS_ReadBuf resb 1048576", S); Emit_Newline (S);
      Append ("ALB_FITS_RBMode db 'rb',0", S); Emit_Newline (S);
      Append ("ALB_FITS_Scale255 dd 255.0", S); Emit_Newline (S);
      Append ("ALB_FITS_Max255 dd 255.0", S); Emit_Newline (S);
      Append ("ALB_FITS_Zero dd 0.0", S); Emit_Newline (S);
      Append ("ALB_FITS_DiagFmt db '[FITS] FAIL stage=%lld got=%lld'," &
              " 10, 'NAXIS=%lld DIM1=%lld DIM2=%lld DIM3=%lld BITPIX=%lld'," &
              " 10, 0", S); Emit_Newline (S);
      Append ("ALB_FITS_OkFmt db '[FITS] OK NAXIS=%lld DIM1=%lld DIM2=%lld" &
              " DIM3=%lld BITPIX=%lld HDROFF=%lld DATASIZE=%lld'," &
              " 10, 0", S); Emit_Newline (S);

      Current_Buffer := Old_Buf;
      Append ("  jmp ALB_FITS_DONE", S); Emit_Newline (S);
      Append ("ALB_FITS_Load:", S); Emit_Newline (S);
      Append ("  push rbx", S); Emit_Newline (S);
      Append ("  push rdi", S); Emit_Newline (S);
      Append ("  push rsi", S); Emit_Newline (S);
      Append ("  push r12", S); Emit_Newline (S);
      Append ("  push r13", S); Emit_Newline (S);
      Append ("  push r14", S); Emit_Newline (S);
      Append ("  xor r12d, r12d", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 0", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FreadGot], 0", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_DimCount], 0", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_Dim1], 0", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_Dim2], 0", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_Dim3], 0", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_BITPIX], 0", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 1", S); Emit_Newline (S);
      Append ("  invoke fopen, rcx, ALB_FITS_RBMode", S); Emit_Newline (S);
      Append ("  test rax, rax", S); Emit_Newline (S);
      Append ("  jz ALB_FITS_Fail", S); Emit_Newline (S);
      Append ("  mov rbx, rax", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 2", S); Emit_Newline (S);
      Append ("ALB_FITS_ReadBlock:", S); Emit_Newline (S);
      Append ("  invoke fread, ALB_FITS_Header, 1, 2880, rbx", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_FreadGot], rax", S); Emit_Newline (S);
      Append ("  cmp rax, 2880", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  xor rsi, rsi", S); Emit_Newline (S);
      Append ("ALB_FITS_CardLoop:", S); Emit_Newline (S);
      Append ("  cmp rsi, 2880", S); Emit_Newline (S);
      Append ("  jae ALB_FITS_NextBlock", S); Emit_Newline (S);
      Append ("  lea rdi, [rel ALB_FITS_Header + rsi]", S); Emit_Newline (S);
      Append ("  cmp dword [rdi], 'END '", S); Emit_Newline (S);
      Append ("  je ALB_FITS_HeaderDone", S); Emit_Newline (S);
      Append ("  cmp dword [rdi], '    '", S); Emit_Newline (S);
      Append ("  je ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("  cmp dword [rdi], 'BITP'", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_TryNaxis", S); Emit_Newline (S);
      Append ("  cmp word [rdi + 4], 'IX'", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_TryNaxis", S); Emit_Newline (S);
      Append ("  mov r8, rdi", S); Emit_Newline (S);
      Append ("  add rdi, 10", S); Emit_Newline (S);
      Append ("  xor r13, r13", S); Emit_Newline (S);
      Append ("  xor r14, r14", S); Emit_Newline (S);
      Append ("ALB_FITS_SkipVal:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], ' '", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_ParseSigned", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_SkipVal", S); Emit_Newline (S);
      Append ("ALB_FITS_ParseSigned:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '-'", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_ParseDigits", S); Emit_Newline (S);
      Append ("  mov r14, 1", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("ALB_FITS_ParseDigits:", S); Emit_Newline (S);
      Append ("  xor rax, rax", S); Emit_Newline (S);
      Append ("  xor rcx, rcx", S); Emit_Newline (S);
      Append ("  mov cl, 20", S); Emit_Newline (S);
      Append ("ALB_FITS_Digit:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '0'", S); Emit_Newline (S);
      Append ("  jb ALB_FITS_StoreBitpix", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '9'", S); Emit_Newline (S);
      Append ("  ja ALB_FITS_StoreBitpix", S); Emit_Newline (S);
      Append ("  imul rax, 10", S); Emit_Newline (S);
      Append ("  movzx rdx, byte [rdi]", S); Emit_Newline (S);
      Append ("  sub rdx, '0'", S); Emit_Newline (S);
      Append ("  add rax, rdx", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  dec rcx", S); Emit_Newline (S);
      Append ("  jnz ALB_FITS_Digit", S); Emit_Newline (S);
      Append ("ALB_FITS_StoreBitpix:", S); Emit_Newline (S);
      Append ("  test r14, r14", S); Emit_Newline (S);
      Append ("  jz ALB_FITS_BitpixPos", S); Emit_Newline (S);
      Append ("  neg rax", S); Emit_Newline (S);
      Append ("ALB_FITS_BitpixPos:", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_BITPIX], rax", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("ALB_FITS_TryNaxis:", S); Emit_Newline (S);
      Append ("  cmp dword [rdi], 'NAXI'", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("  cmp byte [rdi + 4], 'S'", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("  mov r8, rdi", S); Emit_Newline (S);
      Append ("  add rdi, 10", S); Emit_Newline (S);
      Append ("  xor rax, rax", S); Emit_Newline (S);
      Append ("  xor rcx, rcx", S); Emit_Newline (S);
      Append ("  mov cl, 20", S); Emit_Newline (S);
      Append ("ALB_FITS_ParseInt:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], ' '", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_DigitNaxis", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  dec rcx", S); Emit_Newline (S);
      Append ("  jnz ALB_FITS_ParseInt", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("ALB_FITS_DigitNaxis:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '0'", S); Emit_Newline (S);
      Append ("  jb ALB_FITS_StoreDim", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '9'", S); Emit_Newline (S);
      Append ("  ja ALB_FITS_StoreDim", S); Emit_Newline (S);
      Append ("  imul rax, 10", S); Emit_Newline (S);
      Append ("  movzx rdx, byte [rdi]", S); Emit_Newline (S);
      Append ("  sub rdx, '0'", S); Emit_Newline (S);
      Append ("  add rax, rdx", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  dec rcx", S); Emit_Newline (S);
      Append ("  jnz ALB_FITS_DigitNaxis", S); Emit_Newline (S);
      Append ("ALB_FITS_StoreDim:", S); Emit_Newline (S);
      Append ("  cmp byte [r8 + 5], ' '", S); Emit_Newline (S);
      Append ("  je ALB_FITS_DimCountStore", S); Emit_Newline (S);
      Append ("  cmp byte [r8 + 5], '1'", S); Emit_Newline (S);
      Append ("  je ALB_FITS_Dim1Store", S); Emit_Newline (S);
      Append ("  cmp byte [r8 + 5], '2'", S); Emit_Newline (S);
      Append ("  je ALB_FITS_Dim2Store", S); Emit_Newline (S);
      Append ("  cmp byte [r8 + 5], '3'", S); Emit_Newline (S);
      Append ("  je ALB_FITS_Dim3Store", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("ALB_FITS_DimCountStore:", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_DimCount], rax", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("ALB_FITS_Dim1Store:", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_Dim1], rax", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("ALB_FITS_Dim2Store:", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_Dim2], rax", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("ALB_FITS_Dim3Store:", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_Dim3], rax", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_NextCard", S); Emit_Newline (S);
      Append ("ALB_FITS_NextCard:", S); Emit_Newline (S);
      Append ("  add rsi, 80", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_CardLoop", S); Emit_Newline (S);
      Append ("ALB_FITS_NextBlock:", S); Emit_Newline (S);
      Append ("  add r12, 2880", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_ReadBlock", S); Emit_Newline (S);
      Append ("ALB_FITS_HeaderDone:", S); Emit_Newline (S);
      Append ("  add r12, 2880", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_HeaderOffset], r12", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 3", S); Emit_Newline (S);
      Append ("  mov rax, [rel ALB_FITS_DimCount]", S); Emit_Newline (S);
      Append ("  cmp rax, [rel ALB_FITS_ExpDimCount]", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 4", S); Emit_Newline (S);
      Append ("  mov rax, [rel ALB_FITS_Dim1]", S); Emit_Newline (S);
      Append ("  cmp rax, [rel ALB_FITS_ExpDim1]", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 5", S); Emit_Newline (S);
      Append ("  mov rax, [rel ALB_FITS_Dim2]", S); Emit_Newline (S);
      Append ("  cmp rax, [rel ALB_FITS_ExpDim2]", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 6", S); Emit_Newline (S);
      Append ("  mov rax, [rel ALB_FITS_Dim3]", S); Emit_Newline (S);
      Append ("  cmp rax, [rel ALB_FITS_ExpDim3]", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 7", S); Emit_Newline (S);
      Append ("  mov rax, [rel ALB_FITS_BITPIX]", S); Emit_Newline (S);
      Append ("  cmp rax, -32", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 8", S); Emit_Newline (S);
      Append ("  invoke fseek, rbx, [rel ALB_FITS_HeaderOffset], 0",
              S); Emit_Newline (S);
      Append ("  cmp rax, 0", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_FITS_FailStage], 9", S); Emit_Newline (S);
      Append ("  invoke fread, ALB_FITS_ReadBuf, 1," &
              " [rel ALB_FITS_DataSize], rbx", S); Emit_Newline (S);
      Append ("  mov [rel ALB_FITS_FreadGot], rax", S); Emit_Newline (S);
      Append ("  cmp rax, [rel ALB_FITS_DataSize]", S); Emit_Newline (S);
      Append ("  jne ALB_FITS_FailClose", S); Emit_Newline (S);
      Append ("  invoke fclose, rbx", S); Emit_Newline (S);
      Append ("  mov rsi, ALB_FITS_ReadBuf", S); Emit_Newline (S);
      Append ("  mov rdi, [rel ALB_FITS_DataPtr]", S); Emit_Newline (S);
      Append ("  xor rcx, rcx", S); Emit_Newline (S);
      Append ("  mov rcx, [rel ALB_FITS_DataSize]", S); Emit_Newline (S);
      Append ("  shr rcx, 2", S); Emit_Newline (S);
      Append ("  xor r8, r8", S); Emit_Newline (S);
      Append ("ALB_FITS_ConvertLoop:", S); Emit_Newline (S);
      Append ("  test rcx, rcx", S); Emit_Newline (S);
      Append ("  jz ALB_FITS_ConvertDone", S); Emit_Newline (S);
      Append ("  mov eax, [rsi + r8 * 4]", S); Emit_Newline (S);
      Append ("  bswap eax", S); Emit_Newline (S);
      Append ("  movd xmm0, eax", S); Emit_Newline (S);
      Append ("  mulss xmm0, [rel ALB_FITS_Scale255]", S); Emit_Newline (S);
      Append ("  minss xmm0, [rel ALB_FITS_Max255]", S); Emit_Newline (S);
      Append ("  maxss xmm0, [rel ALB_FITS_Zero]", S); Emit_Newline (S);
      Append ("  cvtss2si eax, xmm0", S); Emit_Newline (S);
      Append ("  mov rbx, [rel ALB_FITS_ExpElemBytes]", S); Emit_Newline (S);
      Append ("  mov r9, r8", S); Emit_Newline (S);
      Append ("  imul r9, rbx", S); Emit_Newline (S);
      Append ("  mov [rdi + r9], rax", S); Emit_Newline (S);
      Append ("  inc r8", S); Emit_Newline (S);
      Append ("  dec rcx", S); Emit_Newline (S);
      Append ("  jmp ALB_FITS_ConvertLoop", S); Emit_Newline (S);
      Append ("ALB_FITS_ConvertDone:", S); Emit_Newline (S);
      Append ("  invoke printf, ALB_FITS_OkFmt," &
              " [rel ALB_FITS_DimCount], [rel ALB_FITS_Dim1], [rel ALB_FITS_Dim2]," &
              " [rel ALB_FITS_Dim3], [rel ALB_FITS_BITPIX]," &
              " [rel ALB_FITS_HeaderOffset], [rel ALB_FITS_DataSize]",
              S); Emit_Newline (S);
      Append ("  pop r14", S); Emit_Newline (S);
      Append ("  pop r13", S); Emit_Newline (S);
      Append ("  pop r12", S); Emit_Newline (S);
      Append ("  pop rsi", S); Emit_Newline (S);
      Append ("  pop rdi", S); Emit_Newline (S);
      Append ("  pop rbx", S); Emit_Newline (S);
      Append ("  mov rax, 1", S); Emit_Newline (S);
      Append ("  ret", S); Emit_Newline (S);
      Append ("ALB_FITS_FailClose:", S); Emit_Newline (S);
      Append ("  invoke fclose, rbx", S); Emit_Newline (S);
      Append ("ALB_FITS_Fail:", S); Emit_Newline (S);
      Append ("  invoke printf, ALB_FITS_DiagFmt," &
              " [rel ALB_FITS_FailStage], [rel ALB_FITS_FreadGot]," &
              " [rel ALB_FITS_DimCount], [rel ALB_FITS_Dim1], [rel ALB_FITS_Dim2]," &
              " [rel ALB_FITS_Dim3], [rel ALB_FITS_BITPIX]",
              S); Emit_Newline (S);
      Append ("  pop r14", S); Emit_Newline (S);
      Append ("  pop r13", S); Emit_Newline (S);
      Append ("  pop r12", S); Emit_Newline (S);
      Append ("  pop rsi", S); Emit_Newline (S);
      Append ("  pop rdi", S); Emit_Newline (S);
      Append ("  pop rbx", S); Emit_Newline (S);
      Append ("  xor rax, rax", S); Emit_Newline (S);
      Append ("  ret", S); Emit_Newline (S);
      Append ("ALB_FITS_DONE:", S); Emit_Newline (S);

      Current_Buffer := Old_Buf;
      Success := S;
   end Emit_FITS_Runtime;

   -- =====================================================================
   -- Emit_INI_Runtime (Task A5a)
   -- ---------------------------------------------------------------------
   -- Data labels (64 KiB scratch buffer + small scalars) are routed to
   -- Buffer_Global so they land in the writable data section instead of
   -- bloating .text.
   --
   -- Code labels live in Buffer_Main with a leading  jmp ALB_INI_DONE  so
   -- linear execution never falls into the parse routine.
   --
   -- The actual key->field dispatcher is emitted per-struct by Walk_AST
   -- (Task A5b) -- this routine only emits the generic parse loop that
   -- the per-struct table tails into.
   --
   -- Calling convention (used by Task A5b):
   --     in  rcx = pointer to null-terminated INI text in ALB_INI_Buffer
   --     in  rdx = pointer to field-descriptor table
   --              (terminated by a row with zero key length)
   --     out rax = 1 on success, 0 on parse failure
   -- =====================================================================
   procedure Emit_INI_Runtime (Success : out Boolean) is
      S       : Boolean := True;
      Old_Buf : constant Buffer_Target := Current_Buffer;
   begin
      -- ===== Data section (Buffer_Global) ==============================
      Current_Buffer := Buffer_Global;
      Append ("ALB_INI_Buffer resb 65536", S); Emit_Newline (S);
      Append ("ALB_INI_BufLen dq 0", S); Emit_Newline (S);
      Append ("ALB_INI_FieldTable dq 0", S); Emit_Newline (S);
      Append ("ALB_INI_RBMode db 'rb',0", S); Emit_Newline (S);
      Append ("ALB_INI_FailStage dq 0", S); Emit_Newline (S);
      Append ("ALB_INI_OkFmt db '[INI] OK bytes=%lld'," &
              " 10, 0", S); Emit_Newline (S);
      Append ("ALB_INI_FailFmt db '[INI] FAIL stage=%lld'," &
              " 10, 0", S); Emit_Newline (S);
      Append ("ALB_INI_KeyFmt db '[INI] key=%s value=%lld'," &
              " 10, 0", S); Emit_Newline (S);

      -- ===== Code section (Buffer_Main) ================================
      Current_Buffer := Old_Buf;
      Append ("  jmp ALB_INI_DONE", S); Emit_Newline (S);

      -- ---------------------------------------------------------------
      -- ALB_INI_Load (rcx = filename) -> rax = bytes read (0 on failure)
      -- Reads up to 64 KiB into ALB_INI_Buffer and null-terminates.
      -- ---------------------------------------------------------------
      Append ("ALB_INI_Load:", S); Emit_Newline (S);
      Append ("  push rbx", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_INI_FailStage], 1", S); Emit_Newline (S);
      Append ("  invoke fopen, rcx, ALB_INI_RBMode", S); Emit_Newline (S);
      Append ("  test rax, rax", S); Emit_Newline (S);
      Append ("  jz ALB_INI_LoadFail", S); Emit_Newline (S);
      Append ("  mov rbx, rax", S); Emit_Newline (S);
      Append ("  mov qword [rel ALB_INI_FailStage], 2", S); Emit_Newline (S);
      Append ("  invoke fread, ALB_INI_Buffer, 1, 65535, rbx", S); Emit_Newline (S);
      Append ("  mov [rel ALB_INI_BufLen], rax", S); Emit_Newline (S);
      Append ("  lea rcx, [rel ALB_INI_Buffer]", S); Emit_Newline (S);
      Append ("  add rcx, rax", S); Emit_Newline (S);
      Append ("  mov byte [rcx], 0", S); Emit_Newline (S);
      Append ("  invoke fclose, rbx", S); Emit_Newline (S);
      Append ("  invoke printf, ALB_INI_OkFmt, [rel ALB_INI_BufLen]", S); Emit_Newline (S);
      Append ("  mov rax, [rel ALB_INI_BufLen]", S); Emit_Newline (S);
      Append ("  pop rbx", S); Emit_Newline (S);
      Append ("  ret", S); Emit_Newline (S);
      Append ("ALB_INI_LoadFail:", S); Emit_Newline (S);
      Append ("  invoke printf, ALB_INI_FailFmt, [rel ALB_INI_FailStage]", S); Emit_Newline (S);
      Append ("  pop rbx", S); Emit_Newline (S);
      Append ("  xor rax, rax", S); Emit_Newline (S);
      Append ("  ret", S); Emit_Newline (S);

      -- ---------------------------------------------------------------
      -- ALB_INI_Parse (rdx = field table) -> rax = matched count
      -- Walks ALB_INI_Buffer line by line, calls the per-struct table
      -- dispatcher (emitted by Task A5b) for each key=value pair.
      --
      -- Field table format (one row per field):
      --     dq <ptr-to-key-string>      ; null-terminated lower-case key
      --     dq <ptr-to-storage>         ; qword to store parsed value
      --     dq <flags>                  ; bit0 = 1 means string (not done in v1)
      -- Terminator: dq 0, 0, 0
      -- ---------------------------------------------------------------
      Append ("ALB_INI_Parse:", S); Emit_Newline (S);
      Append ("  push rbx", S); Emit_Newline (S);
      Append ("  push rdi", S); Emit_Newline (S);
      Append ("  push rsi", S); Emit_Newline (S);
      Append ("  push r12", S); Emit_Newline (S);
      Append ("  push r13", S); Emit_Newline (S);
      Append ("  push r14", S); Emit_Newline (S);
      Append ("  push r15", S); Emit_Newline (S);
      Append ("  mov r15, rdx", S); Emit_Newline (S);   -- r15 = field table base
      Append ("  xor r12, r12", S); Emit_Newline (S);   -- r12 = matched count
      Append ("  lea rdi, [rel ALB_INI_Buffer]", S); Emit_Newline (S);
      Append ("ALB_INI_LineLoop:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], 0", S); Emit_Newline (S);
      Append ("  je ALB_INI_ParseDone", S); Emit_Newline (S);
      -- skip leading whitespace
      Append ("  cmp byte [rdi], ' '", S); Emit_Newline (S);
      Append ("  je ALB_INI_SkipWS", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], 9", S); Emit_Newline (S);
      Append ("  je ALB_INI_SkipWS", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], 13", S); Emit_Newline (S);
      Append ("  je ALB_INI_NextLine", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], 10", S); Emit_Newline (S);
      Append ("  je ALB_INI_NextLineAdv", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '#'", S); Emit_Newline (S);
      Append ("  je ALB_INI_FindEol", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], ';'", S); Emit_Newline (S);
      Append ("  je ALB_INI_FindEol", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '['", S); Emit_Newline (S);
      Append ("  je ALB_INI_FindEol", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_HaveKey", S); Emit_Newline (S);
      Append ("ALB_INI_SkipWS:", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_LineLoop", S); Emit_Newline (S);
      Append ("ALB_INI_NextLine:", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], 10", S); Emit_Newline (S);
      Append ("  jne ALB_INI_LineLoop", S); Emit_Newline (S);
      Append ("ALB_INI_NextLineAdv:", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_LineLoop", S); Emit_Newline (S);
      Append ("ALB_INI_FindEol:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], 0", S); Emit_Newline (S);
      Append ("  je ALB_INI_ParseDone", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], 10", S); Emit_Newline (S);
      Append ("  je ALB_INI_NextLineAdv", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_FindEol", S); Emit_Newline (S);
      -- ---------------------------------------------------------------
      -- ALB_INI_HaveKey: rdi points to first key character.
      -- Walk the field table looking for a key match using
      -- case-insensitive byte compare terminated at '=' or whitespace.
      -- ---------------------------------------------------------------
      Append ("ALB_INI_HaveKey:", S); Emit_Newline (S);
      Append ("  mov rsi, r15", S); Emit_Newline (S);   -- rsi walks field table
      Append ("ALB_INI_RowLoop:", S); Emit_Newline (S);
      Append ("  mov rax, [rsi]", S); Emit_Newline (S); -- key ptr
      Append ("  test rax, rax", S); Emit_Newline (S);
      Append ("  jz ALB_INI_NoMatch", S); Emit_Newline (S);
      -- compare rdi (line) against [rsi] (key) up to '=' / ws
      Append ("  push rdi", S); Emit_Newline (S);
      Append ("  mov rbx, rax", S); Emit_Newline (S);   -- rbx = key cursor
      Append ("ALB_INI_KeyCmp:", S); Emit_Newline (S);
      Append ("  mov al, [rbx]", S); Emit_Newline (S);
      Append ("  test al, al", S); Emit_Newline (S);
      Append ("  jz ALB_INI_KeyEnd", S); Emit_Newline (S);
      Append ("  mov 0xa, [rdi]", S); Emit_Newline (S);
      -- lowercase fold of ah
      Append ("  cmp 0xa, 'A'", S); Emit_Newline (S);
      Append ("  jb ALB_INI_NoFold", S); Emit_Newline (S);
      Append ("  cmp 0xa, 'Z'", S); Emit_Newline (S);
      Append ("  ja ALB_INI_NoFold", S); Emit_Newline (S);
      Append ("  add 0xa, 32", S); Emit_Newline (S);
      Append ("ALB_INI_NoFold:", S); Emit_Newline (S);
      Append ("  cmp al, 0xa", S); Emit_Newline (S);
      Append ("  jne ALB_INI_RowMiss", S); Emit_Newline (S);
      Append ("  inc rbx", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_KeyCmp", S); Emit_Newline (S);
      Append ("ALB_INI_KeyEnd:", S); Emit_Newline (S);
      -- key consumed; require rdi at '=' (allowing surrounding ws)
      Append ("ALB_INI_KeyEndWS:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], ' '", S); Emit_Newline (S);
      Append ("  jne ALB_INI_KeyEndChk", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_KeyEndWS", S); Emit_Newline (S);
      Append ("ALB_INI_KeyEndChk:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], '='", S); Emit_Newline (S);
      Append ("  jne ALB_INI_RowMiss", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      -- skip ws after =
      Append ("ALB_INI_ValWS:", S); Emit_Newline (S);
      Append ("  cmp byte [rdi], ' '", S); Emit_Newline (S);
      Append ("  jne ALB_INI_ParseVal", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_ValWS", S); Emit_Newline (S);
      -- ---------------------------------------------------------------
      -- ALB_INI_ParseVal: integer value at rdi -> r13 (signed)
      -- ---------------------------------------------------------------
      Append ("ALB_INI_ParseVal:", S); Emit_Newline (S);
      Append ("  xor r13, r13", S); Emit_Newline (S);
      Append ("  xor r14, r14", S); Emit_Newline (S);   -- r14 = sign flag
      Append ("  cmp byte [rdi], '-'", S); Emit_Newline (S);
      Append ("  jne ALB_INI_ValDigits", S); Emit_Newline (S);
      Append ("  mov r14, 1", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("ALB_INI_ValDigits:", S); Emit_Newline (S);
      Append ("  mov al, [rdi]", S); Emit_Newline (S);
      Append ("  cmp al, '0'", S); Emit_Newline (S);
      Append ("  jb ALB_INI_ValDone", S); Emit_Newline (S);
      Append ("  cmp al, '9'", S); Emit_Newline (S);
      Append ("  ja ALB_INI_ValDone", S); Emit_Newline (S);
      Append ("  sub al, '0'", S); Emit_Newline (S);
      Append ("  movzx rax, al", S); Emit_Newline (S);
      Append ("  imul r13, 10", S); Emit_Newline (S);
      Append ("  add r13, rax", S); Emit_Newline (S);
      Append ("  inc rdi", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_ValDigits", S); Emit_Newline (S);
      Append ("ALB_INI_ValDone:", S); Emit_Newline (S);
      Append ("  test r14, r14", S); Emit_Newline (S);
      Append ("  jz ALB_INI_StoreVal", S); Emit_Newline (S);
      Append ("  neg r13", S); Emit_Newline (S);
      Append ("ALB_INI_StoreVal:", S); Emit_Newline (S);
      Append ("  mov rax, [rsi + 8]", S); Emit_Newline (S);  -- storage ptr
      Append ("  test rax, rax", S); Emit_Newline (S);
      Append ("  jz ALB_INI_StoreSkip", S); Emit_Newline (S);
      Append ("  mov qword [rax], r13", S); Emit_Newline (S);
      Append ("  invoke printf, ALB_INI_KeyFmt, qword [rsi], r13", S); Emit_Newline (S);
      Append ("  inc r12", S); Emit_Newline (S);
      Append ("ALB_INI_StoreSkip:", S); Emit_Newline (S);
      Append ("  add rsp, 8", S); Emit_Newline (S);   -- discard pushed rdi
      Append ("  jmp ALB_INI_FindEol", S); Emit_Newline (S);
      Append ("ALB_INI_RowMiss:", S); Emit_Newline (S);
      Append ("  pop rdi", S); Emit_Newline (S);
      Append ("  add rsi, 24", S); Emit_Newline (S);  -- next row (3 qwords)
      Append ("  jmp ALB_INI_RowLoop", S); Emit_Newline (S);
      Append ("ALB_INI_NoMatch:", S); Emit_Newline (S);
      Append ("  jmp ALB_INI_FindEol", S); Emit_Newline (S);
      Append ("ALB_INI_ParseDone:", S); Emit_Newline (S);
      Append ("  mov rax, r12", S); Emit_Newline (S);
      Append ("  pop r15", S); Emit_Newline (S);
      Append ("  pop r14", S); Emit_Newline (S);
      Append ("  pop r13", S); Emit_Newline (S);
      Append ("  pop r12", S); Emit_Newline (S);
      Append ("  pop rsi", S); Emit_Newline (S);
      Append ("  pop rdi", S); Emit_Newline (S);
      Append ("  pop rbx", S); Emit_Newline (S);
      Append ("  ret", S); Emit_Newline (S);
      Append ("ALB_INI_DONE:", S); Emit_Newline (S);

      Current_Buffer := Old_Buf;
      Success := S;
   end Emit_INI_Runtime;

end Emit_Native_NASM;
