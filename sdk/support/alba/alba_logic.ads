pragma SPARK_Mode (Off);

with Numerus_Magnus; use Numerus_Magnus;

package ALBA_Logic is

   Max_Find_Results : constant Positive := 256;

   function Hash_Name (Text : String) return U32;

   procedure Assert_Fact
     (Pred_Hash : in U32;
      Value     : in S32);

   procedure Retract_Fact
     (Pred_Hash : in U32;
      Value     : in S32);

   procedure Update_Fact
     (Pred_Hash : in U32;
      Old_Value : in S32;
      New_Value : in S32);

   function Prove
     (Pred_Hash : in U32;
      Value     : in S32) return Boolean;

   function Find_First
     (Pred_Hash : in U32) return S32;

   procedure Find_All (Pred_Hash : in U32);

   function Find_Result_Count return Natural;

   function Find_Result (Index : in Positive) return S32;

   function Register_Rule
     (Head_Pred_Hash : in U32;
      Head_Mode      : in Natural;
      Head_Value     : in S32;
      Var_Count      : in Natural) return Natural;

   procedure Add_Rule_Term
     (Rule_Index : in Natural;
      Pred_Hash  : in U32;
      Arg_Mode   : in Natural;
      Arg_Value  : in S32);

end ALBA_Logic;
