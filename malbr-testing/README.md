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

## Current status (45/45 passing)

| # | Title | Notes |
|---|-------|-------|
| 4 | 99 bottles of beer | loops, `IF`/`ELSE`, pipe concat |
| 5 | A+B | arithmetic, pipe concat |
| 8 | Ackermann function | recursion via `FUNCTION`/`RETURN` |
| 18 | Arrays | `STRICT a[5] AS S32`, `a[i]` / `a(i)` access |
| 19 | Assertions | `ASSERT` -> `debug_assert!` |
| 22 | Averages/Arithmetic mean | integer loop sum |
| 25 | Averages/Pythagorean means | fixed-point (x100) rationals |
| 26 | Averages/Root mean square | sum of squares |
| 28 | Babbage problem | `MOD` on squares |
| 31 | Binary search | top-level `STRICT` -> `static mut` + `crate::` refs |
| 34 | Bitwise operations | `OR`, `XOR`, `AND` keywords |
| 35 | Boolean values | comparisons, `NOT` |
| 41 | Catalan numbers | recurrence with exact division |
| 43 | Character codes | numeric output |
| 46 | Collatz sequence | `WHILE`, `MOD`, `/` |
| 47 | Combinations | multiplicative formula |
| 49 | Comments | `--` line comments |
| 68 | Dot product | two arrays, element-wise `a[i] * b[i]` |
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
| 124 | Identity matrix | 2-D `STRICT m[4,4]`, row-major flat emit |
| 132 | Integer sequence | `WHILE` |
| 151 | Leap year | `MOD`, `AND`/`OR` |
| 158 | Logical operations | comparison + keyword ops |
| 173 | Matrix transpose | 2-D `m[i,j]` -> flat `m[(i*cols+j)]` |
| 182 | Modular arithmetic | `MOD` via temp vars |
| 183 | Modular exponentiation | `MOD` loop |
| 188 | Multiplication tables | nested loops, pipe concat |
| 192 | Mutual recursion | `IsEven`/`IsOdd` cross-calls |
| 195 | Narcissistic decimal number | digit-extraction loops |
| 198 | Non-decimal radices/Convert | `$FF` and `%1010` literals |

## Arrays

- Declaration: `STRICT a[10] AS S32` (multi-dim: `STRICT g[3,4] AS S32`;
  `SLIDE a[cap, active]` treated as a fixed `[cap]` buffer).
- Element access: `a[i]` or `a(i)` — both spellings work, incl. multi-dim
  `g[i,j]` / `g(i,j)`. Multi-dim arrays are emitted as flat Rust arrays
  with row-major index math (`i * cols + j`).
- Bounds must be compile-time constants (literals, `$`/`%`/`&O` radix
  literals, `CONST` refs, and `+ - * / MOD` folds).
- `STRICT` inside `BEGIN`/function bodies emits `let mut` stack arrays;
  at file scope or inside a module it emits `static mut` and all accesses
  are wrapped in `unsafe { ... }` — honest about shared mutable state.

## Parser quirks to know

- `PRINT$ (expr) OP x` drops the infix operator after a closing `)`. Assign the
  parenthesized sub-expression to a variable first (or drop the parens):
  `LET s = a + b` then `PRINT$ s MOD m`.
- `LET` inside a loop redeclares/shadows the Rust binding (by design for now);
  declare with `LET` once and reassign with `x = ...` thereafter.
- Reserved words cannot be variable names — e.g. `dot` lexes as `TOK_DOT_PROD`
  and silently swallows the whole statement. Pick another identifier.
- `a(i) = v` (paren-style element assignment) is supported when `a` is a
  declared array.

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
  module-qualified calls (`M.Proc(args)`), `RETURN`, recursion and mutual
  recursion (impl bodies win over spec signatures).
* `STRICT`/`SLIDE` static arrays: `let mut` locals, `static mut` globals with
  `unsafe` access, `crate::` qualification across modules, `a[i]`/`a(i)` and
  multi-dim row-major indexing.
* `rust_eh_personality` stub + rustc `self-contained` lib probing for linking
  against a stock Rust GNU install (no bundled MinGW needed for `libgcc_eh`).
* String values: `&'static str` backed by a 4 KiB static arena (`_alb_concat`,
  `_alb_left`, `_alb_right`, `_alb_mid`, `_alb_chr`, `_alb_str_i32`,
  `_alb_copy_out` — all `unsafe fn`, no heap). `|` and `&` concatenate with
  auto-stringification of numeric operands. `LEN`, `LEFT$`, `RIGHT$`, `MID$`
  (1-based) count *characters* via `char_indices`, matching the desktop
  emitter. `ASC` returns the first byte; `CHR` wraps a byte as `&str`.
  String variables, `AS STRING` params/returns, `s[i]` byte indexing, and
  `STRICT s[n] AS STRING` arrays all work. Source bytes >= 0x80 in literals
  are re-emitted as `\u{XX}` escapes so generated `.rs` stays valid UTF-8.
* Reserved keywords used as identifiers (or intrinsics called without `(`)
  now produce `Err_Parse_Reserved_Keyword` with line/col and abort the
  compile. Fatal parse recovery can no longer silently drop statements.
* Bare top-level statements (no `BEGIN`/`PROGRAM` wrapper) are emitted as
  the implicit `main` body.
* Function-local `Declared_Names` is reset per routine; parameters register
  their types in the symbol table so `PRINT$ s`/`s | x` type-check inside
  function bodies.

## Known gaps

* `ELSEIF` is not in the grammar; use nested `IF`/`ELSE`.
* `PRINT$` and `PRINT` both newline-terminate; build one line with `|`
  concat if you need mixed fragments on a single line.
* File I/O, enum/struct *bodies*, `SELECT`/`CASE` remain stubs or
  unsupported comments.
* The 4 KiB string arena is a fixed bump allocator — enough for the test
  corpus, but a hard ceiling on embedded string churn. `SWEEP` resets it.
* No array bounds elision — every index goes through Rust's bounds check
  (desired for safety-critical); `rust_eh_personality` stub covers the
  panic-path link on windows-gnu.
