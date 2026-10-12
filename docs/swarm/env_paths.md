# Environment paths & variables

| Var | Default | Purpose |
|---|---|---|
| ALBT_PATH | <repo>/sdk/bin/albt.exe | transpiler binary |
| ALB_CC | gcc | C backend assembler (w64devkit) |
| ALB_WORKSPACE | repo root | file-path sandbox for MCP tools |
| ALB_TIMEOUT | 10 | subprocess timeout (seconds) |
| ALB_AI_SRC | H:\GNATSTUDIO\bin\ai-experiment | albagent source |
| ALB_DEPS | (auto) | overrides toolchain dep dir |

Local LLM endpoint: http://127.0.0.1:8080/v1 (D:\.local\start_llm.cmd)
Toolchains fallback order: sdk/deps -> C:\ALB\deps -> PATH.
