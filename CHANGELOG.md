# Changelog

All notable changes to this repository. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — 2026-10-11 (swarm-readiness session)

### Added

- **MCP toolchain server** (`tools/mcp_server/alb_mcp_server.py`):
  five tools — `query_language_spec`, `validate_syntax`,
  `compile_target`, `execute_and_capture`, `run_test_suite` —
  forming a closed compile/diagnose/fix loop.
- **In-repo SDK** (`sdk/`): mirrors `C:\ALB` — `bin/` with all compiler
  executables + `fasm.exe` (albt v0.0.6.18), `config/`, `support/`,
  `stdlib/` (`.alb`/`.albi` headers only; 1.8 GB vendor binary SDKs
  intentionally not versioned).
- **`albagent` deployment** (`sdk/bin/albagent.exe` + `sdk/models/`):
  ternary inference engine built from `ai-experiment` via gprbuild
  (GNAT 15.2, `-gnat2012 -gnata -gnatwa -gnatwe`, `-O3`); runs offline.
- **`sdk/agent/`**: `rebuild_albagent.cmd` (build→deploy→verify) and
  `test_albagent.cmd` (offline inference smoke test), plus the
  `tools/` repair-loop scripts from ai-experiment.
- **`.albproj` manifest** + `docs` spec: `include_dir` entries give
  `INCLUDE "x.albi"` path-free resolution; nearest ancestor wins;
  staging injects headers without overriding local files.
- **`examples/`**: fruit_fractals (verified fasm→exe), colony_sim,
  alb_bbs sources + shared `.ALBI` headers.
- **`tools/swarm/`**: `swarm_attack.py`/`.cmd` orchestrator
  (task-file in → aider on local LLM → MCP verify → 5-strike revert +
  `HELP_NEEDED.md`) and `CONVENTIONS.md` agent constitution.
- **`package_release.cmd`**: assembles the self-contained `ALB_Release`
  drop (all compilers, models, deps, alb.cmd shim) + zip; not committed.
- **`docs/swarm/`**: modular per-tool/per-script/concept docs sized for
  small context windows.
- **`SWARM_HANDOFF.md`**: the swarm's operational manual.
- `tools/mcp_server/docs/` bundled copies of the language spec and
  cheat sheet so `query_language_spec` works offline.

### Changed

- `compile_target`: `fasm`/`fasm16` auto-assemble via `albt --build`;
  `c` backend builds `.exe` via gcc. Job staging runs inside
  `<name>_build/` so albt's SDK bootstrap never pollutes sources.
- `run_test_suite`: defaults to `fasm` backend; non-executable
  backends report `SKIP` instead of `FAIL`.
- Diagnostics parser captures `File [...]` so breaches inside included
  `.ALBI` headers report the correct file/line/col.
- `.gitignore`: un-ignores `sdk/bin/`, adds `*_build/`, `fasm_*/`,
  `__pycache__/`, `sdk/tmp/`.

### External (not in repo, documented)

- `D:\.local\`: llama.cpp CUDA + Qwen2.5-Coder-7B GGUF endpoint
  (`:8080`), aider 0.86.2, openhands 1.16, uv-managed Python 3.12.
- SWE-agent 1.1.0 already present in the system venv.
