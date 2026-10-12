# albagent — local ternary inference engine

- Binary: `sdk/bin/albagent.exe` (built from ai-experiment `main.adb`)
- Models: `sdk/models/*.albm` (ternary task models, ~700K total, offline)
- Usage: `albagent.exe [--context N] [--temp N|N/M] [--model path.albm]`
  reads tokens/text on stdin, prints token ids + "Engine complete."
- Rebuild: `sdk/agent/rebuild_albagent.cmd` (gprbuild -> deploy -> smoke test)
- Test: `sdk/agent/test_albagent.cmd` must print PASS
