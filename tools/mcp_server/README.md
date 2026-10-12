# ALB Toolchain MCP Server

An MCP (Model Context Protocol) server that gives an AI agent a closed
loop for writing, compiling, and testing AdaLogic BASIC (`.alb`) code.

## Tools

| Tool | Purpose |
| --- | --- |
| `query_language_spec` | Search `docs/` (spec + cheat sheet) for syntax sections matching a query. |
| `validate_syntax` | Dry-run `albt.exe` on a `.alb` file; returns structured line/col diagnostics. |
| `compile_target` | Transpile to a backend (`fasm`, `fasm16`, `c`, `ada`, `wasm`, `6502`, ...). `fasm` auto-assembles to `.exe` via `albt --build`; `c` builds `.exe` via gcc. |
| `execute_and_capture` | Run a compiled binary with a strict timeout; returns stdout/stderr/exit code. |
| `run_test_suite` | Compile + run every `.alb` in a directory (default backend `fasm`). Optional `<name>.expected.txt` files are diffed against stdout. |

## Requirements

- Python 3.10+, `pip install -r requirements.txt`
- `albt.exe` (ALB transpiler)
- `gcc` on PATH (only needed to build/execute the `c` backend)

## Configuration (environment variables)

| Variable | Default |
| --- | --- |
| `ALBT_PATH` | `<repo>\sdk\bin\albt.exe` (fallback: `H:\GNATSTUDIO\...\albt.exe`) |
| `ALB_CC` | `gcc` |
| `ALB_WORKSPACE` | repo root — all file paths are confined here (traversal-safe) |
| `ALB_TIMEOUT` | `10` (seconds) |

## Running

```sh
python alb_mcp_server.py        # stdio transport
```

Example MCP client config:

```json
{
  "mcpServers": {
    "alb-toolchain": {
      "command": "python",
      "args": ["D:\\GIT\\alb\\tools\\mcp_server\\alb_mcp_server.py"]
    }
  }
}
```

## SDK layout

`sdk/` mirrors `C:\ALB`: `bin/` (all compiler executables + `fasm.exe`),
`config/`, `support/`, `stdlib/` (`.alb`/`.albi` include sources only — the
multi-GB vendor binary SDKs are not versioned), `tmp/`.

Example programs live in `examples/` (`fruit_fractals`, `colony_sim`,
`alb_bbs`). `INCLUDE`/`IMPORT` `.ALBI` siblings are copied automatically —
`albt` weaves them from the source directory.

## Notes

- `albt.exe` exits 0 even on syntax errors, so the server detects failure by
  scanning for the `ALB DIAGNOSTIC FORGE` / `BREACH` banners and by checking
  that the expected artifact was emitted.
- Each compile runs in a `<name>_build/` scratch dir (sources + sibling
  includes are copied in) so `albt`'s SDK-bootstrap folders never pollute
  the source tree.
- `hello.alb` is a minimal sanity program; `tests/` shows the expected-output
  convention used by `run_test_suite`.
