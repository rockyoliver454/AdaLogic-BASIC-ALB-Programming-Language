# `malbr-testing` — Micro ALB Rosetta suite

This directory contains a growing set of AdaLogic BASIC (ALB) programs that are
compiled and run with the `malbr` Micro ALB → Rust compiler.

## Running the suite

From the repository root, with `bin/malbr.exe` built and the Rust/MinGW toolchain
on `PATH`:

```cmd
python malbr-testing\runner.py
```

The runner

1. discovers every `###_name.alb` file,
2. invokes `bin\malbr.exe --build <file>`,
3. runs the resulting executable,
4. compares stdout with the optional `###_name.expected` file.

Environment variables:

* `RUST_BIN` — directory containing `rustc.exe` (defaults to `deps\rust\bin`).
* `MINGW_BIN` — directory containing MinGW `gcc`/`ld` (used by rustc on Windows).

## Current status

| # | Title | Status | Notes |
|---|-------|--------|-------|
| 4 | 99 bottles of beer | PASS | loops, `IF`/`ELSE`, pipe concat |
| 5 | A+B | PASS | arithmetic, pipe concat |
| 19 | Assertions | PASS | `ASSERT` → `debug_assert!` |
| 34 | Bitwise operations | PASS | `OR`, `XOR`, `AND` keyword ops |
| 35 | Boolean values | PASS | comparisons, `NOT` |
| 46 | Collatz sequence | PASS | `WHILE`, `MOD`, integer `/` |
| 49 | Comments | PASS | `--` line comments |
| 81 | Even or odd | PASS | `MOD` |
| 86 | Factorial | PASS | `WHILE`, reassignment |
| 87 | Factors of an integer | PASS | loop, `MOD` |
| 89 | Fibonacci sequence | PASS | loop |
| 94 | FizzBuzz | PASS | nested `IF`/`ELSE` |
| 96 | Floyd's triangle | PASS | nested `WHILE` |
| 97 | For loop | PASS | `FOR ... TO ... THEN` |
| 101 | Function definition | **FAIL** | top-level/module procedures not yet emitted by micro backend |
| 106 | Greatest common divisor | PASS | `WHILE`, `MOD` |
| 111 | Happy numbers | PASS | nested loops |
| 116 | Hello world/Text | PASS | `PRINT$` |
| 151 | Leap year | PASS | `MOD`, `AND`/`OR` |
| 158 | Logical operations | PASS | comparisons + keyword ops |
| 188 | Multiplication tables | PASS | nested loops, pipe concat |
| 198 | Non-decimal radices/Convert | PASS | `$FF` and `%1010` literals |

## Adding a new test

1. Create `###_short_name.alb`.
2. Optionally create `###_short_name.expected`.
3. Run `python malbr-testing\runner.py`.

If the test needs an include module, place the `.albi` file in this directory and
reference it with `INCLUDE "filename.albi"`.

## Compiler features exercised so far

* `#![no_std]` Rust emission with host `support.rs` shim.
* Windows host linking via MinGW gcc + C-runtime stubs.
* Tokenization and parsing of the ALB grammar.
* `LET`/reassignment tracking.
* `FOR`, `WHILE`, `IF`/`ELSE` control flow.
* Arithmetic, `MOD`, comparison, keyword bitwise/logical ops, `NOT`.
* `PRINT$` string/number output with pipe (`|`) concatenation.
* Hex (`$FF`) and binary (`%1010`) integer literals.
* Comments (`--`).

## Known gaps

* Top-level `PROCEDURE`/`FUNCTION` declarations are parsed but their bodies are
  not emitted into the generated Rust; module-qualified calls (`M.SayHello()`)
  are also not yet lowered.
* Arrays, records, enums, strings-as-values, file I/O, and many advanced nodes
  remain as stubs or unsupported comments.
