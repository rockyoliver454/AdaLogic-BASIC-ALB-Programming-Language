# sdk/agent/rebuild_albagent.cmd

Self-improvement loop for the ternary engine.

1. gprbuild -P ternary_ai.gpr -p in ALB_AI_SRC (default
   H:\GNATSTUDIO\bin\ai-experiment)
2. copy bin\main.exe -> sdk\bin\albagent.exe
3. run test_albagent.cmd (must PASS)

Toolchain search: sdk\deps -> C:\ALB\deps -> PATH.
