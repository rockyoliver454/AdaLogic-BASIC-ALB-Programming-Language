"""Promote a day_cycle candidate .albm (forge pillar 1: long memory).

Audits the trail sheet, boot-verifies the candidate through the real
engine, enforces the static footprint, then copies the candidate to a
content-addressed models/solidified_<sha8>.albm. Never edits 2-bit blobs
by hand: all folding/packing stays inside Ada (Fold_Bank + Serialize);
the host only verifies and promotes.

Checks (any failure exits nonzero, nothing is copied):
  1. sheet parses: header counts present, every A-line has row/col in
     1..256 and step in -8..8, all steps nonzero;
  2. changed <= number of A-lines (a flip needs a nonzero accumulator)
     and changed <= 131584 (Max_Ternary_Cells);
  3. candidate boots: bin/ternary_ai --model <candidate> exits 0;
  4. footprint: candidate size == base size (no expansion, ever).

Usage:
  python tools/promote_model.py --candidate obj/day_smoke.albm
      --base models/chat.albm --sheet obj/day_smoke.txt
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


MAX_TERNARY_CELLS = 2 * 256 * 256 + 2 * 256
DIM = 256


def parse_decay_list(path: Path) -> list[tuple[int, int]]:
    cells: list[tuple[int, int]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3 or parts[0] != "D":
            raise ValueError(f"malformed decay line: {raw!r}")
        row, col = int(parts[1]), int(parts[2])
        if not 1 <= row <= DIM and 1 <= col <= DIM:
            raise ValueError(f"decay cell out of range: {raw!r}")
        cells.append((row, col))
    if len(cells) > DIM * DIM:
        raise ValueError("decay list over the A_W cell budget")
    return cells


def parse_sheet(path: Path) -> tuple[dict[str, int], list[tuple[int, int, int]]]:
    header: dict[str, int] = {}
    lines: list[tuple[int, int, int]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("A "):
            parts = line.split()
            if len(parts) != 4:
                raise ValueError(f"malformed delta line: {raw!r}")
            row, col, step = (int(parts[1]), int(parts[2]), int(parts[3]))
            if not 1 <= row <= DIM and 1 <= col <= DIM:
                raise ValueError(f"cell out of range: {raw!r}")
            if step == 0 or not -8 <= step <= 8:
                raise ValueError(f"step out of clamped range: {raw!r}")
            lines.append((row, col, step))
        elif ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            if key in ("events", "successes", "delta_nonzero", "changed", "used", "differs", "decayed",
                       "ticks", "last_idle_used", "last_mutate_used", "last_mutated_at"):
                header[key] = int(value.strip())
    for key in ("events", "successes", "delta_nonzero", "changed", "used", "differs"):
        if key not in header:
            raise ValueError(f"sheet missing header: {key}")
    return header, lines


def boot_check(engine: Path, candidate: Path) -> bool:
    try:
        completed = subprocess.run(
            [str(engine), "--model", str(candidate)],
            input="eof\n",
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return completed.returncode == 0 and "Engine complete" in (completed.stdout or "")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--base", type=Path, default=Path("models/chat.albm"))
    parser.add_argument("--sheet", type=Path, required=True)
    parser.add_argument("--decay", type=Path, default=None)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--engine", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    root = args.root.resolve()
    candidate = (root / args.candidate if not args.candidate.is_absolute() else args.candidate).resolve()
    base = (root / args.base if not args.base.is_absolute() else args.base).resolve()
    engine = args.engine.resolve() if args.engine else root / ("bin/ternary_ai.exe" if sys_platform_windows() else "bin/ternary_ai")

    header, lines = parse_sheet((root / args.sheet if not args.sheet.is_absolute() else args.sheet).resolve())
    if header["changed"] > len(lines):
        raise ValueError(f"changed {header['changed']} exceeds audited accumulators {len(lines)}")
    if header["changed"] > MAX_TERNARY_CELLS:
        raise ValueError("changed exceeds Max_Ternary_Cells")
    if header["delta_nonzero"] != len(lines):
        raise ValueError(f"delta_nonzero {header['delta_nonzero']} != sheet lines {len(lines)}")
    if header.get("decayed", 0) != 0 and args.decay is None:
        raise ValueError("decayed count without a decay file to audit")

    if args.decay is not None:
        dlines = parse_decay_list((root / args.decay if not args.decay.is_absolute() else args.decay).resolve())
        if header.get("decayed", 0) > len(dlines):
            raise ValueError(f"decayed {header['decayed']} exceeds audited decay lines {len(dlines)}")

    if candidate.stat().st_size != base.stat().st_size:
        raise ValueError(f"footprint drift: {candidate.stat().st_size} != {base.stat().st_size}")
    if not boot_check(engine, candidate):
        raise ValueError("candidate failed engine boot verification")

    digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
    out = args.out.resolve() if args.out else root / "models" / f"solidified_{digest[:8]}.albm"
    shutil.copyfile(candidate, out)
    print(json.dumps({
        "promoted": str(out),
        "sha256": digest,
        "base_sha256": hashlib.sha256(base.read_bytes()).hexdigest(),
        "changed": header["changed"],
        "events": header["events"],
        "successes": header["successes"],
        "bytes": candidate.stat().st_size,
    }, indent=2, sort_keys=True))
    return 0


def sys_platform_windows() -> bool:
    import sys
    return sys.platform.startswith("win")


if __name__ == "__main__":
    raise SystemExit(main())
