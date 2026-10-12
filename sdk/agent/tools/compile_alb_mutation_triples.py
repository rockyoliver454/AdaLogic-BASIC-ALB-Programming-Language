from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

LOCATION = re.compile(r"(?P<file>[^\s:]+\.(?:alb|albi)):(?P<line>\d+)(?::(?P<column>\d+))?", re.IGNORECASE)


def run(compiler: Path, source: Path, output: Path, timeout: int, backend: str) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    extension = "asm" if backend == "fasm" else backend
    command = [str(compiler), str(source), "-t", backend, "--quiet", "--outdir", str(output), "-o", "probe." + extension]
    try:
        completed = subprocess.run(
            command, cwd=source.parent, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout, check=False,
        )
        diagnostic = (completed.stdout + "\n" + completed.stderr).replace("\x00", "")[:4096]
        match = LOCATION.search(diagnostic)
        return {
            "success": completed.returncode == 0,
            "exit_code": completed.returncode,
            "diagnostic": diagnostic,
            "line": int(match.group("line")) if match else 0,
            "column": int(match.group("column") or 0) if match else 0,
            "severity": "error" if completed.returncode else "none",
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "exit_code": -1, "diagnostic": "timeout", "line": 0, "column": 0, "severity": "timeout"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--backends", default="fasm,c")
    args = parser.parse_args()
    root = args.root.resolve()
    compiler = args.compiler.resolve()
    records = [json.loads(line) for line in (root / "data/alb/mutation_manifest.jsonl").read_text(encoding="utf-8").splitlines()]
    output_root = root / "obj/alb_mutation_probe"
    triples = []
    backends = tuple(value.strip() for value in args.backends.split(",") if value.strip())
    for record in records:
        original_path = root / record["original_copy"]
        mutated_path = root / record["mutated_copy"]
        repaired_path = root / record["repaired_copy"]
        repair_exact = hashlib.sha256(original_path.read_bytes()).hexdigest() == hashlib.sha256(repaired_path.read_bytes()).hexdigest()
        for backend in backends:
            unit = output_root / record["id"] / backend
            original = run(compiler, original_path, unit / "original", args.timeout, backend)
            mutated = run(compiler, mutated_path, unit / "mutated", args.timeout, backend)
            repaired = run(compiler, repaired_path, unit / "repaired", args.timeout, backend)
            triples.append({
                **record,
                "id": record["id"] + "-" + backend,
                "backend": backend,
                "original_result": original,
                "mutated_result": mutated,
                "repaired_result": repaired,
                "repair_exact": repair_exact,
                "useful_triple": bool(original["success"] and not mutated["success"] and repaired["success"] and repair_exact),
                "compiler_grounded": True,
            })
    output = root / "data/alb/mutation_triples.jsonl"
    output.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in triples), encoding="utf-8")
    summary = {
        "format": "ALB-MUTATION-TRIPLES",
        "version": 1,
        "records": len(triples),
        "useful_triples": sum(record["useful_triple"] for record in triples),
        "mutated_failures": sum(not record["mutated_result"]["success"] for record in triples),
        "repair_successes": sum(record["repaired_result"]["success"] for record in triples),
        "backends": dict(sorted(Counter(record["backend"] for record in triples).items())),
        "severities": dict(sorted(Counter(record["mutated_result"]["severity"] for record in triples).items())),
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
    }
    (root / "data/alb/mutation_triple_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
