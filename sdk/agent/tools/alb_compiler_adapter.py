from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def compile_copy(source: Path, compiler: Path, root: Path, backend: str, timeout: int, output: Path) -> dict[str, object]:
    source = source.resolve()
    root = root.resolve()
    if not within(source, root):
        return {"status": "denied", "exit_code": 2, "diagnostic": "source outside ai-experiment", "source_unchanged": False}
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    extension = "asm" if backend == "fasm" else backend
    command = [str(compiler), str(source), "-t", backend, "--quiet", "--outdir", str(output), "-o", "candidate." + extension]
    try:
        completed = subprocess.run(command, cwd=source.parent, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False)
        diagnostic = (completed.stdout + "\n" + completed.stderr).replace("\x00", "")[:4096]
        unchanged = hashlib.sha256(source.read_bytes()).hexdigest() == before
        return {
            "status": "ready" if completed.returncode == 0 else "failed",
            "exit_code": completed.returncode,
            "diagnostic": diagnostic,
            "diagnostic_length": len(diagnostic),
            "source_unchanged": unchanged,
            "backend": backend,
            "source_sha256": before,
        }
    except subprocess.TimeoutExpired as error:
        unchanged = hashlib.sha256(source.read_bytes()).hexdigest() == before
        diagnostic = ((error.stdout or "") + "\n" + (error.stderr or ""))[:4096]
        return {"status": "timed_out", "exit_code": -1, "diagnostic": diagnostic, "diagnostic_length": len(diagnostic), "source_unchanged": unchanged, "backend": backend, "source_sha256": before}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--backend", choices=("fasm", "c"), default="fasm")
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    output = args.output or root / "obj/alb_adapter" / hashlib.sha256(str(args.source).encode()).hexdigest()[:16]
    result = compile_copy(args.source, args.compiler.resolve(), root, args.backend, args.timeout, output.resolve())
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["status"] in ("ready", "failed") and result["source_unchanged"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
