# validate_syntax(filepath)

Dry-run transpile of a `.alb` file. No binary produced.

- Args: `filepath` — absolute path inside the workspace
- Success: `{success: true, message: "no syntax or semantic errors"}`
- Failure: `{success: false, diagnostics: [{file, line, col, error, hint}]}`
- albt ALWAYS exits 0; failure is detected via BREACH banners + missing artifact.
