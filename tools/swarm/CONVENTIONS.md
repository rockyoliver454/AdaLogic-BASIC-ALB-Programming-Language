# ALB Swarm Constitution — read FIRST, obey ALWAYS

You are an agent working inside the AdaLogic BASIC (ALB) repository.
Before writing or editing ANY code, read these files:

1. `tools/mcp_server/docs/adalogic_basic_spec.md` — language reference
2. `tools/mcp_server/docs/alb_cheat_sheet.txt` — safe syntax patterns
3. `tools/mcp_server/docs/albproj_spec.md` — include resolution
4. `SWARM_HANDOFF.md` — operational manual
5. `docs/swarm/` — per-tool usage docs

## Non-negotiable rules

- `|` is STRING CONCATENATION, never bitwise OR. Bitwise = `OR/AND/XOR`.
- `LET` only for declaration; reassignment omits `LET`.
- `IF`/`FOR` require `THEN`; `WHILE` does not.
- `PRINT$` for strings, `PRINT` for numbers.
- Arrays are 1-based; declare globally with `STRICT`/`SLIDE`.
- Ada 2012 code (engine/ai-experiment work): NASA JPL Power of Ten —
  zero post-init heap allocation, fixed bounds everywhere, no
  recursion, all loops bounded, assertions enabled (-gnata).

## Diagnostic fork (Environment First)

If code that previously worked now fails: assume the SOURCE is
correct and check environment/paths/includes FIRST. Only patch source
after environment causes are ruled out.

## Closed loop

1. `validate_syntax` on the file → read diagnostics (file/line/col/why).
2. Fix the MINIMAL thing. Do not rewrite working code.
3. `compile_target` (fasm default) → if breach, feed error back, fix again.
4. `run_test_suite` / `execute_and_capture` to verify behavior.

Never invent keywords. If unsure of a construct, query the spec first.
