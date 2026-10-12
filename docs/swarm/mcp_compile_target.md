# compile_target(filepath, backend_target="c")

Transpile `.alb` to a backend; fasm/fasm16 auto-assemble to `.exe`.

- Args: `filepath`, `backend_target` — fasm | fasm16 | c | ada | wasm | 6502 | ...
- Returns: `{success, artifact, executable?, diagnostics?}`
- `fasm`: runs `albt --build`, exe lands in `<src>_build/<dir>/fasm_<stem>/`
- `c`: emits `.c` then gcc -> `<stem>_build/<stem>.exe` (needs gcc on PATH)
- Staging copies sources + .albproj include_dir files; source tree stays clean.
