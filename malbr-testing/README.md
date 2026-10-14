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

## Current status (66/66 passing)

| # | Title | Notes |
|---|-------|-------|
| 4 | 99 bottles of beer | loops, `IF`/`ELSE`, pipe concat |
| 5 | A+B | arithmetic, pipe concat |
| 8 | Ackermann function | recursion via `FUNCTION`/`RETURN` |
| 14 | Append a record | `OPEN(..., "a")`, `WRITE`, `FILELEN` |
| 16 | Arithmetic-geometric mean | `f64`, `^`, `_alb_sqrt_f64` |
| 18 | Arrays | `STRICT a[5] AS S32`, `a[i]` / `a(i)` access |
| 19 | Assertions | `ASSERT` -> `debug_assert!` |
| 22 | Averages/Arithmetic mean | integer loop sum |
| 25 | Averages/Pythagorean means | fixed-point (x100) rationals |
| 26 | Averages/Root mean square | sum of squares |
| 28 | Babbage problem | `MOD` on squares |
| 29 | Balanced brackets | string byte indexing, counters |
| 31 | Binary search | top-level `STRICT` -> `static mut` + `crate::` refs |
| 34 | Bitwise operations | `OR`, `XOR`, `AND` keywords |
| 35 | Boolean values | comparisons, `NOT` |
| 37 | Caesar cipher | `ASC`/`CHR`, string building in a loop |
| 41 | Catalan numbers | recurrence with exact division |
| 43 | Character codes | `ASC`, `MID$` per-char codes |
| 46 | Collatz sequence | `WHILE`, `MOD`, `/` |
| 47 | Combinations | multiplicative formula |
| 49 | Comments | `--` line comments |
| 50 | Compare a list of strings | `STRICT s[n] AS STRING`, string `=` |
| 54 | Conditional structures | `SELECT`/`CASE`/`ELSE`, `MATCH`, `CHOOSE` |
| 58 | Count occurrences of a substring | `MID$` windowing, string `=` |
| 59 | Create a file | `OPEN(..., "w")`, `WRITE`, `FILELEN` |
| 66 | Determine if a string is numeric | per-char `ASC` checks |
| 68 | Dot product | two arrays, element-wise `a[i] * b[i]` |
| 80 | Evaluate binomial coefficients | integer `^` via `i64::pow` |
| 81 | Even or odd | `MOD` |
| 84 | Exponentiation operator | `^`/`**`, int + f64 pow |
| 86 | Factorial | `WHILE` |
| 87 | Factors of an integer | loop + `MOD` |
| 89 | Fibonacci sequence | loop |
| 90 | File input/output | `OPEN`/`READ`/`FILESEEK`/`FILELEN`/`CLOSE` |
| 94 | FizzBuzz | nested `IF`/`ELSE` |
| 96 | Floyd's triangle | nested `WHILE` |
| 97 | For loop | `FOR ... TO` |
| 101 | Function definition | `DECLARE MODULE` + `MODULE`, qualified call |
| 104 | Generic swap | temp variable |
| 105 | Gray code | `XOR` |
| 106 | Greatest common divisor | Euclidean `MOD` loop |
| 108 | Hailstone sequence | same as Collatz |
| 109 | Hamming numbers | u64 state, 3-way min merge |
| 111 | Happy numbers | nested loops |
| 114 | Haversine formula | `f64`, `_alb_asin_f64`/`_alb_sqrt_f64` chain |
| 115 | Hello world/Standard error | `PRINT$` |
| 116 | Hello world/Text | `PRINT$` |
| 119 | Hofstadter Q sequence | recursion + nested `qv[n-qv[n-1]]` indexing |
| 121 | Horner's rule | nested multiply-add |
| 124 | Identity matrix | 2-D `STRICT m[4,4]`, row-major flat emit |
| 127 | Increment a numerical string | digit parse, `CHR`, concat |
| 132 | Integer sequence | `WHILE` |
| 138 | Josephus problem | array circle, index stepping |
| 151 | Leap year | `MOD`, `AND`/`OR` |
| 154 | Letter frequency | `STRICT` int table + `ASC`/`MID$` |
| 156 | Linear congruential generator | `U64` state, `*`/`+` wraparound |
| 158 | Logical operations | comparison + keyword ops |
| 169 | Magic squares of odd order | 2-D `STRICT`, Siamese method |
| 173 | Matrix transpose | 2-D `m[i,j]` -> flat `m[(i*cols+j)]` |
| 182 | Modular arithmetic | `MOD` via temp vars |
| 183 | Modular exponentiation | `MOD` loop |
| 187 | Morse code | `SELECT` per char, concat build |
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

## File I/O

- `OPEN(path, mode)` -> handle (0 = failure); `mode` is `"r"` / `"w"` / `"a"`
  (first char decides; `"w"` truncates, `"a"` opens at end, `"r"` requires
  the file to exist).
- `WRITE h, data` appends at the cursor (data auto-stringified);
  `CLOSE h` releases the handle.
- `READ(h, n)` returns a `&'static str` slice: `n` bytes from the cursor
  (cursor advances), or the whole file when `n <= 0`.
- `FILESEEK(h, off)` absolute seek, returns the position; `FILELEN(path)`
  takes a *path* (not a handle) and returns byte length.
- Handles come from `support.rs`: by default it is a real-FS host shim
  (Win32 `CreateFileA`/`ReadFile`/`WriteFile`, 8 open handles). With
  `malbr --memfs` it is a static in-RAM filesystem instead — 8 named files
  x 1 KiB, zero OS dependencies, safe for embedded targets. Same ALB API
  either way; on hardware, keep `--memfs` or supply your own support.rs.

## Parser quirks to know

- `PRINT$ (expr) OP x` drops the infix operator after a closing `)`. Assign the
  parenthesized sub-expression to a variable first (or drop the parens):
  `LET s = a + b` then `PRINT$ s MOD m`.
- `LET` inside a loop redeclares/shadows the Rust binding (by design for now);
  declare with `LET` once and reassign with `x = ...` thereafter.
- Reserved words cannot be variable names — e.g. `dot` lexes as `TOK_DOT_PROD`;
  the compiler now hard-errors with line/col instead of silently dropping the
  statement. Pick another identifier.
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
* `SELECT expr / CASE v [=>] / [CASE] ELSE / END SELECT` and `MATCH expr /
  v => / ELSE => / END` both emit an `if`/`else if` chain on a hoisted temp
  — Rust `match` patterns must be const, and ALB case arms are arbitrary
  runtime expressions (strings included). `CHOOSE(c,a,b)` is the ternary
  `(if c { a } else { b })`.
* `f64` values and mixed int+float promotion (`0 - 42.5` works). Numeric
  literals with `.` are floats; `PRINT` on floats routes to a fixed
  6-decimal `_alb_print_f64`, and `|` stringifies them via `_alb_str_f64`.
* `^`/`**` is exponentiation — `i64::pow` for integral bases/exponents,
  `_alb_pow_f64` (binary exp for integral, `exp(y*ln x)` otherwise) for
  floats.  No libm dependency: `_alb_sqrt_f64` (Newton), `_alb_exp_f64`,
  `_alb_ln_f64`, `_alb_sin_f64`, `_alb_cos_f64`, `_alb_atan_f64`,
  `_alb_atan2_f64`, `_alb_asin_f64`, `_alb_acos_f64`, `_alb_abs_f64`,
  `_alb_floor_f64`, `_alb_ceil_f64` are pure f64 Taylor/identity
  implementations emitted in the preamble.  `SQRT/EXP/LN/LOG/SIN/COS/ATAN/
  ASIN/ACOS/ABS/FLOOR/CEIL/ATAN2/POW(...)` parse as ordinary calls and are
  intercepted to those helpers.
* `_alb_print_i32`/`_alb_str_i32` take `i64` (u64 prints correctly).
* Module bodies use `use super::*;` so every crate-root helper resolves
  inside `pub mod` scopes.
* File I/O via `support.rs` HAL: `OPEN`/`READ`/`WRITE`/`CLOSE`/`FILESEEK`/
  `FILELEN` lower to `support::_alb_file_*` — real Win32 FS on host,
  `--memfs` selects a static in-RAM filesystem for embedded/no-OS targets.
* `malbr --arena <bytes>` resizes the static string/scratch arena in the
  generated preamble (default 4096).

## Known gaps

* `ELSEIF` is not in the grammar; use nested `IF`/`ELSE`.
* `PRINT$` and `PRINT` both newline-terminate; build one line with `|`
  concat if you need mixed fragments on a single line.
* Float math helpers are series approximations — accurate to ~6 decimals
  for the test corpus but not IEEE-correct in the last ulp; not for
  guidance computers.  Fixed 6-decimal printing truncates, doesn't round.
* Enum/struct *bodies*, `NOT` precedence subtleties remain.
* The string arena is a fixed bump allocator (4 KiB default, `--arena <bytes>`
  to resize) — a hard ceiling on embedded string churn. `SWEEP` resets it.
* Memory-file storage is 8 files x 1 KiB x 64-char names, fixed at compile
  time in `support.rs` — bump the `ALB_*` constants there if needed.
* No array bounds elision — every index goes through Rust's bounds check
  (desired for safety-critical); `rust_eh_personality` stub covers the
  panic-path link on windows-gnu.
