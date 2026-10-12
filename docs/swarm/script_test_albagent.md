# sdk/agent/test_albagent.cmd

Offline smoke test for albagent.

- Pipes `LET x = 1` into sdk/bin/albagent.exe --model alb_seq.albm
- PASS iff output contains "Engine complete." and exit code 0
- Prints FAIL + raw output otherwise
