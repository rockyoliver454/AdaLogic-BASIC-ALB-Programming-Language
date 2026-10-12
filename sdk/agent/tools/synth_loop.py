"""Multi-hop synthesis loop (forge genesis: repair -> creation).

Given a contract stub (a partial .alb module), each attempt runs:
  generate (bin/complete forward hops from the current draft)
    -> gate (cheap structural pre-filter: nonempty, in-window)
    -> bridge (alb_compiler_adapter.compile_copy)
    -> grade (ready = done; failed = map diagnostic line -> byte span)
    -> perturb (deterministically cycle the blamed span, attempt-indexed)

Bounded by --max-attempts; every attempt is recorded. Deterministic for
fixed inputs: same stub, same hops, same verdict sequence.

Usage:
  python tools/synth_loop.py --stub data/alb/stubs/genesis_01.alb --max-hops 16 --max-attempts 4
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from alb_compiler_adapter import compile_copy
from alb_repair_actions import parse_diagnostics, parse_forge, repair, repair_forge, minimal_module

LOCATION = re.compile(r"(?P<file>[^\s:]+\.(?:alb|albi)):(?P<line>\d+)(?::(?P<column>\d+))?", re.IGNORECASE)
MAX_WINDOW = 128


def line_span(text: bytes, line: int) -> tuple[int, int]:
    lines = text.splitlines(keepends=True)
    if line < 1 or line > len(lines):
        return -1, -1
    start = sum(len(part) for part in lines[: line - 1])
    return start, start + len(lines[line - 1])


def perturb(data: bytes, start: int, end: int, attempt: int) -> bytes:
    if not 0 <= start < end <= len(data):
        start, end = max(len(data) - 8, 0), len(data)
    step = (attempt * 37) % 255 + 1
    out = bytearray(data)
    for pos in range(start, min(end, len(out))):
        if out[pos] in (10, 13):
            continue
        out[pos] = (out[pos] + step + pos) % 256
    return bytes(out)


def run_complete(complete_bin: Path, draft: Path, hops: int, out: Path, govern: bool, model: Path | None) -> bool:
    command = [str(complete_bin), "--context", str(draft), "--hops", str(hops), "--out", str(out)]
    if model is not None:
        command += ["--model", str(model)]
    if govern:
        command.append("--govern")
    completed = subprocess.run(command, capture_output=True, text=True, timeout=120, check=False)
    return completed.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stub", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    parser.add_argument("--complete", type=Path, default=None)
    parser.add_argument("--model", type=Path, default=None)
    parser.add_argument("--backend", choices=("fasm", "c"), default="fasm")
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--max-hops", type=int, default=16)
    parser.add_argument("--max-attempts", type=int, default=4)
    parser.add_argument("--govern", action="store_true")
    parser.add_argument("--workdir", type=Path, default=None)
    args = parser.parse_args()
    root = args.root.resolve()
    complete_bin = args.complete.resolve() if args.complete else root / "bin/complete.exe"
    workdir = (args.workdir.resolve() if args.workdir else root / "obj/synth").resolve()
    workdir.mkdir(parents=True, exist_ok=True)

    stub = args.stub.read_bytes()
    if not 0 < len(stub) <= MAX_WINDOW:
        print(json.dumps({"ready": False, "reason": "stub outside 1..128 bytes"}))
        return 1
    compiler = args.compiler.resolve()
    if not compiler.is_file():
        print(json.dumps({"ready": False, "reason": "compiler unavailable"}))
        return 2

    draft = stub
    verdicts: list[dict] = []
    for attempt in range(1, max(args.max_attempts, 1) + 1):
        if max(args.max_hops, 0) > 0 and len(draft) < MAX_WINDOW:
            ctx_path = workdir / f"attempt_{attempt:02d}.ctx"
            gen_path = workdir / f"attempt_{attempt:02d}.gen"
            ctx_path.write_bytes(draft)
            hops = min(max(args.max_hops, 0), MAX_WINDOW - len(draft))
            if hops <= 0 or not run_complete(complete_bin, ctx_path, hops, gen_path, args.govern, args.model):
                verdicts.append({"attempt": attempt, "verdict": "governed_out" if hops > 0 else "window_full"})
                break
            draft = draft + gen_path.read_bytes()
        candidate = workdir / f"attempt_{attempt:02d}.alb"
        candidate.write_bytes(draft)
        outcome = compile_copy(candidate, compiler, root, args.backend, args.timeout,
                               workdir / f"attempt_{attempt:02d}.out")
        record = {"attempt": attempt, "verdict": str(outcome["status"]),
                  "exit_code": outcome["exit_code"],
                  "source_unchanged": outcome["source_unchanged"],
                  "bytes": len(draft)}
        verdicts.append(record)
        if outcome["status"] == "ready":
            print(json.dumps({"ready": True, "attempts": verdicts,
                              "sha256": hashlib.sha256(draft).hexdigest(),
                              "candidate": str(candidate)}, indent=2, sort_keys=True))
            return 0
        match = LOCATION.search(str(outcome.get("diagnostic", "")))
        diags = parse_diagnostics(str(outcome.get("diagnostic", "")))
        if diags:
            code, line, col = diags[0]
            fixed = repair(draft, code, line, col)
            if fixed is not None:
                draft = fixed
            else:
                draft = perturb(draft, -1, -1, attempt)
        else:
            forge = parse_forge(str(outcome.get("diagnostic", "")))
            if forge is not None:
                breach, line, col = forge
                fixed = repair_forge(draft, breach, line, col)
                if fixed is not None:
                    draft = fixed
                elif match:
                    start, end = line_span(draft, int(match.group("line")))
                    draft = perturb(draft, start, end, attempt)
                else:
                    draft = perturb(draft, -1, -1, attempt)
            elif match:
                start, end = line_span(draft, int(match.group("line")))
                draft = perturb(draft, start, end, attempt)
            else:
                draft = perturb(draft, -1, -1, attempt)
        if len(draft) > MAX_WINDOW:
            draft = draft[:MAX_WINDOW]

    print(json.dumps({"ready": False, "attempts": verdicts,
                      "final_sha256": hashlib.sha256(draft).hexdigest()}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
