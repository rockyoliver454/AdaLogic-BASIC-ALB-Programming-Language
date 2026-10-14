# Agent Guidance — AdaLogic BASIC (ALB) / MALBR

Operational rules for AI agents working in this repo. Keep entries short.

## The `|` operator is STRING CONCATENATION

`|` is string concat, NOT bitwise OR (Rust `|`/`||` would silently break
programs). `&` is an accepted alias — same AST, same semantics.
Bitwise/logical ops use keywords: `AND`, `OR`, `XOR`, `NOT`.
`^` / `**` is EXPONENTIATION — never emit Rust `^` (that's bitwise XOR).

## MALBR (`src/malbr.adb` + `src/EMITTER/emit_native_micro_rust.adb`)

Micro ALB → `#![no_std]` Rust. Embedded-first: no heap, no crates, static
4 KiB string arena (reset via `SWEEP`). Keep it that way.

**REMINDER — float math precision:**
`_alb_sin/cos/atan/atan2/asin/acos/exp/ln/pow_f64` are Taylor/Newton
series, ~6 decimal digits accurate — NOT last-ulp IEEE. `PRINT` on floats
truncates at 6 decimals. Good enough for the Rosetta corpus; do NOT use
for guidance/safety math without upgrading the implementations.

Other standing traps:

- Reserved keywords can't be identifiers — the compiler now errors with
  line/col (e.g. `DOT`, `OUT`, `TEXT`, `LEN`, `LEFT$`, `RIGHT$`, `MID$`,
  `SPLAT`, `FMA`). Rename the variable; don't bypass the check.
- Fatal parse recovery aborts the compile. "MALBR: aborting — parse
  recovery dropped statements" means fix the source, not the flag.
- `PRINT`/`PRINT$` both newline-terminate. Build one line via `|` concat.
- Bare top-level statements (no `BEGIN`) emit an implicit main body.
- `ELSEIF` is not in the grammar — nested `IF`/`ELSE` only.
- Function params now register types; `Declared_Names` resets per routine.

## Testing

```cmd
gprbuild -P adalogic_basic_dist.gpr malbr -p
```

Toolchain lives in `deps/gnat_native_15.2.1/bin` +
`deps/gprbuild_25.0.1/bin` (see `release\deps\` on the ALB dist layout).

MALBR suite: `python malbr-testing\runner.py` — needs `RUST_BIN` (e.g.
`C:\Program Files\Rust stable GNU 1.99\bin`) and `MINGW_BIN` (gnat bin dir
works for the mingw `gcc.exe`/`ld.exe` pair) env vars, or those on PATH.
Every `.alb` with a sibling `.expected` file is output-checked.
