pragma SPARK_Mode (Off);

package ALBA_Audio is

   procedure Play_Sound (Path : in String);
   procedure Play_Music (MML : in String);
   procedure Play_Music_From (Path : in String);
   procedure Shutdown;

end ALBA_Audio;
