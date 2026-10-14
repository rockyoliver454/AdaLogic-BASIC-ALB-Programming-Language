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

## Current status (38/38 passing)

| # | Title | Notes |
|---|-------|-------|
| 4 | 99 bottles of beer | loops, `IF`/`ELSE`, pipe concat |
| 5 | A+B | arithmetic, pipe concat |
| 19 | Assertions | `ASSERT` -> `debug_assert!` |
| 22 | Averages/Arithmetic mean | integer loop sum |
| 25 | Averages/Pythagorean means | fixed-point (x100) rationals |
| 26 | Averages/Root mean square | sum of squares |
| 28 | Babbage problem | `MOD` on squares |
| 34 | Bitwise operations | `OR`, `XOR`, `AND` keywords |
| 35 | Boolean values | comparisons, `NOT` |
| 41 | Catalan numbers | recurrence with exact division |
| 43 | Character codes | numeric output |
| 46 | Collatz sequence | `WHILE`, `MOD`, `/` |
| 47 | Combinations | multiplicative formula |
| 49 | Comments | `--` line comments |
| 81 | Even or odd | `MOD` |
| 86 | Factorial | `WHILE` |
| 87 | Factors of an integer | loop + `MOD` |
| 89 | Fibonacci sequence | loop |
| 94 | FizzBuzz | nested `IF`/`ELSE` |
| 96 | Floyd's triangle | nested `WHILE` |
| 97 | For loop | `FOR ... TO` |
| 101 | Function definition | `DECLARE MODULE` + `MODULE`, qualified call |
| 104 | Generic swap | temp variable |
| 105 | Gray code | `XOR` |
| 106 | Greatest common divisor | Euclidean `MOD` loop |
| 108 | Hailstone sequence | same as Collatz |
| 111 | Happy numbers | nested loops |
| 115 | Hello world/Standard error | `PRINT$` |
| 116 | Hello world/Text | `PRINT$` |
| 121 | Horner's rule | nested multiply-add |
| 132 | Integer sequence | `WHILE` |
| 151 | Leap year | `MOD`, `AND`/`OR` |
| 158 | Logical operations | comparison + keyword ops |
| 182 | Modular arithmetic | `MOD` via temp vars |
| 183 | Modular exponentiation | `MOD` loop |
| 188 | Multiplication tables | nested loops, pipe concat |
| 195 | Narcissistic decimal number | digit-extraction loops |
| 198 | Non-decimal radices/Convert | `$FF` and `%1010` literals |

## Parser quirks to know

- `PRINT$ (expr) OP x` drops the infix operator after a closing `)`. Assign the
  parenthesized sub-expression to a variable first (or drop the parens):
  `LET s = a + b` then `PRINT$ s MOD m`.
- `LET` inside a loop redeclares/shadows the Rust binding (by design for now);
  declare with `LET` once and reassign with `x = ...` thereafter.

## Adding a new test

1. Create `###_short_name.alb`.
2. Optionally create `###_short_name.expected`.
3. Run `python malbr-testing\runner.py`.

If the test needs an include module, place the `.albi` file in this directory and
reference it with `INCLUDE "filename.albi"`.

## Compiler features exercised so far

* `#![no_std]` Rust emission with host `support.rs` shim (replaceable for real targets).
* Windows host linking via MinGW gcc + C-runtime stubs.
* `LET`/reassignment tracking, `FOR`, `WHILE`, `IF`/`ELSE` control flow.
* Arithmetic, `MOD`, comparisons, keyword bitwise/logical ops, `NOT`.
* `PRINT$` string/number output with pipe (`|`) concatenation.
* Hex (`$FF`) and binary (`%1010`) integer literals.
* `DECLARE MODULE` + `MODULE` emission to `pub mod`, typed parameters,
  module-qualified calls (`M.Proc(args)`), `RETURN`.

## Known gaps

* Function `RETURN` inside a body is parsed but the body block currently emits
  empty in some forms -- plain `PROCEDURE`/`FUNCTION` bodies without `RETURN`
  work; function-return paths still being traced.
* `ELSEIF` is not in the grammar; use nested `IF`/`ELSE`.
* Arrays, strings-as-values, file I/O, enums/structs bodies, and most advanced
  nodes remain stubs or unsupported comments.
