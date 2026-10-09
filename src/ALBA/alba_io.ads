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

with Numerus_Magnus; use Numerus_Magnus;
with ALBA_Runtime;   use ALBA_Runtime;

package ALBA_IO is

   procedure Print_Text
     (Text    : in ALB_Text;
      Newline : in Boolean := True);

   function Input (Prompt : in ALB_Text) return ALB_Text;
   function Readline return ALB_Text;

   -- Non-raising console integer parse (CODING_RULES §8.4).
   function Try_Parse_Integer
     (Text  : in String;
      Value : out Integer) return Boolean;

   function Read_Integer
     (Prompt  : in ALB_Text;
      Default : in Integer := 0) return Integer;

   function Read_Integer_In_Range
     (Prompt  : in ALB_Text;
      Min_Val : in Integer;
      Max_Val : in Integer;
      Default : in Integer) return Integer;

   procedure Locate
     (Col : in Integer;
      Row : in Integer := 1);

   procedure Clear_Screen;

   procedure Message_Box
     (Body_Text  : in ALB_Text;
      Title : in ALB_Text);

   function File_Open
     (Path : in ALB_Text;
      Mode : in ALB_Text) return U64;

   function File_Len (Path : in ALB_Text) return U64;

   function File_Seek
     (Handle : in U64;
      Offset : in U64) return U64;

   function File_Read
     (Handle : in U64;
      Count  : in U64) return ALB_Text;

   procedure File_Write
     (Handle : in U64;
      Data   : in ALB_Text);

   procedure File_Close (Handle : in U64);

   function Load_File (Path : in ALB_Text) return ALB_Text;
   procedure Load_File
     (Data : in out ALB_U8_Array;
      Path : in ALB_Text);
   procedure Load_File
     (Data : in out ALB_U16_Array;
      Path : in ALB_Text);
   procedure Load_File
     (Data : in out ALB_U32_Array;
      Path : in ALB_Text);
   procedure Load_File
     (Data : in out ALB_U64_Array;
      Path : in ALB_Text);
   procedure Load_File
     (Data : in out ALB_I8_Array;
      Path : in ALB_Text);
   procedure Load_File
     (Data : in out ALB_I16_Array;
      Path : in ALB_Text);
   procedure Load_File
     (Data : in out ALB_I32_Array;
      Path : in ALB_Text);
   procedure Load_File
     (Data : in out ALB_I64_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_Text;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_U8_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_U16_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_U32_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_U64_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_I8_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_I16_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_I32_Array;
      Path : in ALB_Text);
   procedure Flush_File
     (Data : in ALB_I64_Array;
      Path : in ALB_Text);

end ALBA_IO;
