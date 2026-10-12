# SWARM_HANDOFF — operational manual for the local AI swarm

You (Aider / OpenHands / SWE-agent / albagent) are now responsible for
this repository. Read `tools/swarm/CONVENTIONS.md` (your constitution)
and the file you need under `docs/swarm/`. Everything here is designed
to run with ZERO external network access.

## 0. Ground truth order

1. `tools/swarm/CONVENTIONS.md` — rules you must obey
2. `docs/swarm/README.md` — index of per-tool docs
3. `tools/mcp_server/docs/adalogic_basic_spec.md` + `alb_cheat_sheet.txt` — the language
4. `tools/mcp_server/docs/albproj_spec.md` — include resolution
5. `CHANGELOG.md` — temporal state (what changed, when, why)

## 1. Environment

- Compiler: `sdk/bin/albt.exe` (albt v0.0.6.18) + `sdk/bin/*` family
- FASM: `sdk/bin/fasm.exe` — invoked automatically via `-t fasm --build`
- C backend: needs `gcc` (w64devkit on PATH, or `deps/w64devkit/bin`)
- Ada rebuilds: `gprbuild`/`gnat` via `sdk/agent/rebuild_albagent.cmd`
- Inference engine: `sdk/bin/albagent.exe` + `sdk/models/*.albm`
- Local LLM: `http://127.0.0.1:8080/v1` (`D:\.local\start_llm.cmd`)
- Python MCP server: `tools/mcp_server/alb_mcp_server.py` (`mcp<2`)

## 2. Writing ALB code

Never guess syntax. Call `query_language_spec("topic")` first.
Hard rules: `|` = string concat (NOT bitwise or); `LET` only at
declaration; `IF`/`FOR` need `THEN`, `WHILE` does not; `PRINT$` strings,
`PRINT` numbers; arrays 1-based via `STRICT`/`SLIDE`; `INCLUDE` /
`IMPORT` order matters — include the file, then import the module.

## 3. .albproj

Nearest ancestor `.albproj` to the source file defines `include_dir`
lines (relative to the manifest). `INCLUDE "x.albi"` resolves without
hardcoded paths. See `docs/swarm/concept_albproj.md`.

## 4. The closed loop (use the MCP tools, don't shell out)

1. `validate_syntax(file)` → read `{file, line, col, error, hint}`.
2. Fix the minimal thing. One breach at a time.
3. `compile_target(file, "fasm")` → on breach, feed `diagnostics` back.
4. `run_test_suite(dir)` or `execute_and_capture(exe)` to verify.

## 5. Diagnostic fork — Environment First

If code previously compiled and now fails: the code is INNOCENT until
proven guilty. Check include paths, `.albproj`, staging, and tool PATH
first. Decide: compiler/backend fix vs source fix. Never rewrite
working code to chase a pathing bug.

## 6. SPARK/Ada 2012 rules (albagent & engine work)

NASA JPL Power of Ten: no post-init heap allocation, fixed bounds on
every array/loop, no recursion, no function side effects, assertions
always on (`-gnata`, warnings are errors `-gnatwe`).

## 7. Kill-switch etiquette

Max 5 consecutive failed compiles on the same bug. Then STOP, revert
to last working state, and write `HELP_NEEDED.md` — do not thrash.

## 8. Known quirks (no magic)

- `albt.exe` exits 0 even on syntax errors — detect `BREACH`/
  `DIAGNOSTIC FORGE` banners or missing artifact instead.
- `albt` bootstraps `bin/config/stdlib/tmp` into its CWD — always run
  it inside a `<name>_build/` staging dir (the MCP tools do this).
- Cheat sheet says `VERSION 0.0.0.1` after `BEGIN` — albt v0.0.6.18
  accepts `VERSION 1.0` form; if a breach hits line 2, drop the line.
- GUI programs (`CREATE_WINDOW`) always time out under
  `execute_and_capture` — verify them by compile success only.
