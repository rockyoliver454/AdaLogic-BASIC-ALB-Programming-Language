# run_test_suite(test_directory, backend_target="fasm")

Compile + run every `.alb` in a directory.

- PASS: compiles + exits 0; if `<name>.expected.txt` exists, stdout must match (trimmed, CRLF-normalized)
- FAIL stages: transpile | assemble | cc | timeout | runtime | output_diff
- SKIP: backend not executable on this host (ada, wasm, ...)
- Returns: `{total, passed, failed, skipped, success, results[]}`
