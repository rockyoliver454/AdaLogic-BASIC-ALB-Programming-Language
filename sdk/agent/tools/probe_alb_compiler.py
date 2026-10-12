from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from collections import Counter
from pathlib import Path


def phase(text: str) -> str:
    lowered = text.lower()
    if "token" in lowered or "lexer" in lowered:
        return "lexer"
    if "parse" in lowered or "syntax" in lowered:
        return "parser"
    if "weav" in lowered or "include" in lowered:
        return "weaver"
    if "emit" in lowered or "backend" in lowered or "lower" in lowered:
        return "emitter"
    return "build"


def clipped(text: str, limit: int = 4096) -> str:
    return text.replace("\x00", "")[:limit]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC"))
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--limit", type=int, default=32)
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--backends", default="fasm,c")
    args = parser.parse_args()
    root = args.root.resolve()
    source = args.source.resolve()
    compiler = args.compiler.resolve()
    if not compiler.is_file():
        raise ValueError(f"ALB compiler not found: {compiler}")
    manifest_path = root / "data/alb/corpus_manifest.jsonl"
    records = [json.loads(line) for line in manifest_path.read_text(encoding="utf-8").splitlines()]
    candidates = []
    per_split = max(1, (max(0, args.limit) + 2) // 3)
    for split in ("train", "dev", "test"):
        selected = sorted(
            (record for record in records if record["split"] == split),
            key=lambda record: (record["bytes"], record["sha256"]),
        )[:per_split]
        candidates.extend(selected)
    candidates = candidates[:max(0, args.limit)]
    output_root = root / "obj/alb_probe"
    output_root.mkdir(parents=True, exist_ok=True)
    results = []
    backends = tuple(backend.strip() for backend in args.backends.split(",") if backend.strip())
    for record in candidates:
        input_path = source / Path(record["path"])
        for backend in backends:
            unit_dir = output_root / record["sha256"][:16] / backend
            unit_dir.mkdir(parents=True, exist_ok=True)
            extension = "asm" if backend == "fasm" else backend
            command = [
                str(compiler), str(input_path), "-t", backend, "--quiet",
                "--outdir", str(unit_dir), "-o", "probe." + extension,
            ]
            try:
                completed = subprocess.run(
                    command,
                    cwd=input_path.parent,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=args.timeout,
                    check=False,
                )
                combined = clipped(completed.stdout + "\n" + completed.stderr)
                source_modified = hashlib.sha256(input_path.read_bytes()).hexdigest() != record["sha256"]
                results.append({
                    "source_path": record["path"],
                    "source_sha256": record["sha256"],
                    "split": record["split"],
                    "backend": backend,
                    "exit_code": completed.returncode,
                    "success": completed.returncode == 0,
                    "phase": "complete" if completed.returncode == 0 else phase(combined),
                    "diagnostic": combined,
                    "compiler": str(compiler),
                    "source_modified": source_modified,
                })
            except subprocess.TimeoutExpired as error:
                results.append({
                    "source_path": record["path"],
                    "source_sha256": record["sha256"],
                    "split": record["split"],
                    "backend": backend,
                    "exit_code": -1,
                    "success": False,
                    "phase": "timeout",
                    "diagnostic": clipped((error.stdout or "") + "\n" + (error.stderr or "")),
                    "compiler": str(compiler),
                    "source_modified": hashlib.sha256(input_path.read_bytes()).hexdigest() != record["sha256"],
                })
    if any(record["source_modified"] for record in results):
        raise RuntimeError("ALB source mutation detected during compiler probing")
    output = root / "data/alb/compiler_probes.jsonl"
    output.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in results), encoding="utf-8")
    passed = sum(record["success"] for record in results)
    summary = {
        "format": "ALB-COMPILER-PROBES",
        "version": 1,
        "attempted": len(results),
        "passed": passed,
        "failed": len(results) - passed,
        "backends": dict(sorted(Counter(record["backend"] for record in results).items())),
        "read_only_source": True,
        "outputs_root": str(output_root),
    }
    (root / "data/alb/compiler_probe_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
