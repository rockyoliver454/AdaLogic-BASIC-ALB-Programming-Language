# docs/swarm — operational index for the local AI swarm

Read `../../SWARM_HANDOFF.md` first, then the file for the tool you need.

## MCP tools (tools/mcp_server/)

- `mcp_query_language_spec.md` — search syntax docs
- `mcp_validate_syntax.md` — dry-run compile, structured diagnostics
- `mcp_compile_target.md` — transpile + build (fasm default)
- `mcp_execute_and_capture.md` — run an exe with timeout
- `mcp_run_test_suite.md` — directory test runner with expected-output diffs

## Scripts

- `script_package_release.md` — build the self-contained ALB_Release drop
- `script_swarm_attack.md` — task-file driven agent loop with kill-switch
- `script_rebuild_albagent.md` — rebuild+deploy+test the ternary engine
- `script_test_albagent.md` — offline inference smoke test

## Concepts

- `concept_albproj.md` — include_dir manifest format + resolution rules
- `concept_albagent.md` — the ternary inference binary + .albm models
- `concept_diagnostics.md` — DIAGNOSTIC FORGE output contract
- `env_paths.md` — every path/env var the system depends on
