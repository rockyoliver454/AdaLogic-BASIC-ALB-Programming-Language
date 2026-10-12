# execute_and_capture(executable_path, arguments=[])

Run a compiled binary with a hard timeout (ALB_TIMEOUT, default 10s).

- Returns: `{success, exit_code, stdout, stderr, timed_out}`
- GUI programs (CREATE_WINDOW) will time out — expected, not a bug.
