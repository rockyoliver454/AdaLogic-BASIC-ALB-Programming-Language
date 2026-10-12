"""Host age ledger for the entropy valve (saturation companion).

The SPARK core cannot hold state across nights, so the host owns the age
bank as sparse JSON: only success-touched cells are stored with their
last-touched epoch; every other cell's age is (epoch - 0).

  update: read a day_cycle trail sheet, stamp its S-lines at the current
      epoch, advance the epoch, write the state back.
  emit:   enumerate all 65536 A_W cells, list those with
      (epoch - last_touched) >= max_age as "D <row> <col>" lines for
      day_cycle --decay. day_cycle zeroes the nonzero ones and reports;
      promote_model.py audits the list.

Usage:
  python tools/age_ledger.py update --sheet obj/day_smoke.txt --state obj/ages.json
  python tools/age_ledger.py emit --state obj/ages.json --out obj/decay.txt --max-age 30 [--max-lines 5]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

DIM = 256


def load_state(path: Path) -> dict:
    if path.is_file():
        state = json.loads(path.read_text(encoding="utf-8"))
        state.setdefault("epoch", 0)
        state.setdefault("max_age", 30)
        state.setdefault("touched", {})
        return state
    return {"epoch": 0, "max_age": 30, "touched": {}}


def cmd_update(args: argparse.Namespace) -> int:
    state = load_state(args.state)
    stamped = 0
    for raw in args.sheet.read_text(encoding="utf-8").splitlines():
        parts = raw.strip().split()
        if len(parts) == 3 and parts[0] == "S":
            row, col = int(parts[1]), int(parts[2])
            if not 1 <= row <= DIM and 1 <= col <= DIM:
                raise ValueError(f"success cell out of range: {raw!r}")
            state["touched"][f"{row},{col}"] = state["epoch"]
            stamped += 1
    state["epoch"] += 1
    args.state.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
    print(json.dumps({"state": str(args.state), "epoch": state["epoch"], "stamped": stamped,
                      "tracked": len(state["touched"])}, sort_keys=True))
    return 0


def cmd_emit(args: argparse.Namespace) -> int:
    state = load_state(args.state)
    epoch = int(state["epoch"])
    max_age = int(args.max_age)
    touched = state["touched"]
    eligible: list[str] = []
    for row in range(1, DIM + 1):
        for col in range(1, DIM + 1):
            if epoch - int(touched.get(f"{row},{col}", 0)) >= max_age:
                eligible.append(f"D {row} {col}")
                if len(eligible) >= args.max_lines:
                    break
        if len(eligible) >= args.max_lines:
            break
    args.out.write_text("\n".join(eligible) + ("\n" if eligible else ""), encoding="utf-8")
    print(json.dumps({"decay_list": str(args.out), "eligible": len(eligible),
                      "capped": len(eligible) >= args.max_lines}, sort_keys=True))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    up = sub.add_parser("update")
    up.add_argument("--sheet", type=Path, required=True)
    up.add_argument("--state", type=Path, required=True)
    up.set_defaults(func=cmd_update)
    em = sub.add_parser("emit")
    em.add_argument("--state", type=Path, required=True)
    em.add_argument("--out", type=Path, required=True)
    em.add_argument("--max-age", type=int, default=30)
    em.add_argument("--max-lines", type=int, default=DIM * DIM)
    em.set_defaults(func=cmd_emit)
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
