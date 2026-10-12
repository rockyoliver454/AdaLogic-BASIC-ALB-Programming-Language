pragma SPARK_Mode (Off);

with Numerus_Magnus; use Numerus_Magnus;

package ALBA_GC is

   function Claim return U64;

   procedure Drop (Handle : in U64);

   procedure Bind
     (Parent : in U64;
      Child1 : in U64;
      Child2 : in U64);

   procedure Sweep (Chunk : in U64);

end ALBA_GC;
