# ALB Quick Reference — THIS IS NOT PYTHON

`.alb` and `.albi` files contain **AdaLogic BASIC**, a custom compiled
language. Writing Python inside them will ALWAYS fail to compile.

## Minimal program

```alb
BEGIN
    PRINT$ "Hello"
END
```

## Module + include

```alb
-- file: MathKit.ALBI
DECLAREMODULE MathKit
VERSION 1.0

PROCEDURE AddTwo(x AS S32)
BEGIN
    PRINT$ "Result: " | (x + 2)
END PROCEDURE
ENDMODULE
```

```alb
-- file: main.alb
INCLUDE "MathKit.ALBI"
IMPORT MathKit

BEGIN
    MathKit.AddTwo(5);
END
```

## Rules (violating any = compile breach)

- Statements live inside `BEGIN ... END` or `PROCEDURE/FUNCTION ... END`.
- `LET x = 5` declares; later writes are bare `x = x + 1` (no LET).
- `IF cond THEN ... END IF`, `FOR i = 1 TO N THEN ... END FOR`,
  `WHILE cond ... END WHILE` (no THEN).
- `|` concatenates (auto-stringifies): `PRINT$ "HP: " | hp`
- `PRINT` numbers, `PRINT$` strings. `--` comments.
- Types: S32, U8/U16/U32/U64, F64, BOOL via `LET x AS S32`.
- No Python keywords: no `import`, `def`, `print()`, `assert`, `try/except`.
- No semicolons required except after procedure calls (preferred).
