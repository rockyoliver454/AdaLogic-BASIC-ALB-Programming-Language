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

pragma Ada_2012;

with Galois_Field;

package Brainmap
  with SPARK_Mode => On
is
   subtype Real is Float;

   Max_Brains           : constant Positive := 8;
   Max_Regions          : constant Positive := 64;
   Max_Units_Per_Brain  : constant Positive := 256;
   Max_Edges_Per_Brain  : constant Positive := 1_024;
   Max_Snapshots        : constant Positive := 16;
   Max_Formula_Length   : constant Positive := 120;

   type Brain_Status is
     (Brain_Ok,
      Brain_Not_Initialized,
      Brain_Already_Initialized,
      Brain_Arena_Error,
      Brain_Dumptruck_Error,
      Brain_Out_Of_Brains,
      Brain_Out_Of_Regions,
      Brain_Out_Of_Units,
      Brain_Out_Of_Edges,
      Brain_Out_Of_Snapshots,
      Brain_Invalid_Brain,
      Brain_Invalid_Region,
      Brain_Invalid_Unit,
      Brain_Invalid_Snapshot,
      Brain_Invalid_Expression,
      Brain_Expression_Error);

   type Brain_Id is range 0 .. Max_Brains;
   type Region_Id is range 0 .. Max_Regions;
   type Unit_Id is range 0 .. Max_Units_Per_Brain;
   type Snapshot_Id is range 0 .. Max_Snapshots;

   Null_Brain    : constant Brain_Id := 0;
   Null_Region   : constant Region_Id := 0;
   Null_Unit     : constant Unit_Id := 0;
   Null_Snapshot : constant Snapshot_Id := 0;

   type Region_Kind is
     (Input_Region,
      Hidden_Region,
      Recurrent_Region,
      Output_Region,
      Memory_Region);

   procedure Initialize (Status : out Brain_Status);
   procedure Reset (Status : out Brain_Status);

   function Is_Initialized return Boolean;

   procedure Create_Brain
     (Seed   : Galois_Field.Word;
      Brain  : out Brain_Id;
      Status : out Brain_Status);

   procedure Add_Region
     (Brain      : Brain_Id;
      Kind       : Region_Kind;
      Unit_Count : Positive;
      Region     : out Region_Id;
      First_Unit : out Unit_Id;
      Status     : out Brain_Status)
     with Pre => Unit_Count <= Max_Units_Per_Brain;

   procedure Connect_Units
     (Brain    : Brain_Id;
      From_Unit : Unit_Id;
      To_Unit   : Unit_Id;
      Weight    : Real;
      Status    : out Brain_Status);

   procedure Randomize_Region
     (Brain     : Brain_Id;
      Region    : Region_Id;
      Magnitude : Real;
      Status    : out Brain_Status);

   procedure Set_Unit_Input
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : Real;
      Status  : out Brain_Status);

   procedure Set_Unit_Bias
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : Real;
      Status  : out Brain_Status);

   procedure Get_Unit_State
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : out Real;
      Status  : out Brain_Status);

   procedure Get_Unit_Trace
     (Brain   : Brain_Id;
      Unit    : Unit_Id;
      Value   : out Real;
      Status  : out Brain_Status);

   procedure Set_External_Bias
     (Brain   : Brain_Id;
      Value   : Real;
      Status  : out Brain_Status);

   procedure Set_Reward
     (Brain   : Brain_Id;
      Value   : Real;
      Status  : out Brain_Status);

   procedure Set_Temperature
     (Brain   : Brain_Id;
      Value   : Real;
      Status  : out Brain_Status);

   procedure Set_Activation_Expression
     (Brain   : Brain_Id;
      Text    : String;
      Status  : out Brain_Status)
     with Pre => Text'Length > 0 and then Text'Length <= Max_Formula_Length;

   procedure Set_Gate_Expression
     (Brain   : Brain_Id;
      Text    : String;
      Status  : out Brain_Status)
     with Pre => Text'Length > 0 and then Text'Length <= Max_Formula_Length;

   procedure Set_Score_Expression
     (Brain   : Brain_Id;
      Text    : String;
      Status  : out Brain_Status)
     with Pre => Text'Length > 0 and then Text'Length <= Max_Formula_Length;

   procedure Step
     (Brain   : Brain_Id;
      Cycles  : Positive;
      Status  : out Brain_Status);

   procedure Create_Snapshot
     (Brain     : Brain_Id;
      Snapshot  : out Snapshot_Id;
      Status    : out Brain_Status);

   procedure Restore_Snapshot
     (Brain     : Brain_Id;
      Snapshot  : Snapshot_Id;
      Status    : out Brain_Status);

   procedure Get_Snapshot_Checksum
     (Snapshot  : Snapshot_Id;
      Checksum  : out Galois_Field.Word;
      Status    : out Brain_Status);

   procedure Get_Usage
     (Brain       : Brain_Id;
      Region_Count : out Natural;
      Unit_Count   : out Natural;
      Edge_Count   : out Natural;
      Status       : out Brain_Status);

end Brainmap;
