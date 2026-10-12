"""Battery for the grammar-grounded repair loop (tools/alb_repair_actions).

Each broken ALB snippet is fed through the repair loop: compile -> parse the
compiler diagnostic -> apply the grounded repair -> repeat (bounded). A
snippet "converges" when the compiler accepts it. Deterministic: fixed
inputs, fixed order, no randomness.

Exit 0 = every expected case converges; 1 = ony regression.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from alb_repair_actions import parse_diagnostics, parse_forge, repair, repair_forge, minimal_module

ROOT = Path(__file__).resolve().parent.parent
COMPILER = Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe")
WORK = ROOT / "obj" / "alb_repair_test"
MAX_ITERS = 12

# (name, broken bytes, should_converge)
CASES = [
    ("missing THEN + END IF", b"PROCEDURE Main()\n  IF x\nEND PROCEDURE\n", True),
    ("missing FOR body end", b"PROCEDURE Main()\n  FOR i = 1 TO 5\nEND PROCEDURE\n", True),
    ("unclosed string", b'PROCEDURE Main()\n  PRINT "hi\nEND PROCEDURE\n', True),
    ("minimal template", minimal_module(), True),
]


def compile_bytes(data: bytes) -> tuple[int, str]:
    path = WORK / "candidate.alb"
    WORK.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    run = subprocess.run(
        [str(COMPILER), str(path), "-t", "fasm", "--quiet",
         "--outdir", str(WORK / "out"), "-o", "x.asm"],
        capture_output=True, text=True, timeout=60, check=False,
    )
    return run.returncode, run.stdout + run.stderr


def converge(data: bytes) -> tuple[bool, int]:
    draft = data
    for iteration in range(MAX_ITERS):
        rc, diag = compile_bytes(draft)
        if rc == 0:
            return True, iteration
        fixed: bytes | None = None
        diags = parse_diagnostics(diag)
        if diags:
            code, line, col = diags[0]
            fixed = repair(draft, code, line, col)
        else:
            forge = parse_forge(diag)
            if forge is not None:
                breach, line, col = forge
                fixed = repair_forge(draft, breach, line, col)
        if fixed is None or fixed == draft:
            return False, iteration
        draft = fixed
    return False, MAX_ITERS


def main() -> int:
    print("ALB grammar repair battery...")
    passed = failed = 0
    for name, data, should in CASES:
        ok, iters = converge(data)
        if ok == should:
            passed += 1
            print(f"  [PASS] {name}: {'converged' if ok else 'rejected'} "
                  f"({iters} iters)")
        else:
            failed += 1
            print(f"  [FAIL] {name}: converged={ok} want={should}")
    print(f"{passed} passed, {failed} failed")
    if failed == 0:
        print("REPAIR PASS")
        return 0
    print("REPAIR FAIL")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
