"""Nightly crucible (forge pillar 3: continuous synthesis).

Host-side overnight loop. For each deliberately broken .alb file in the
mutation manifest it runs the full forge cycle on the host:

  ingest (read bytes, cap at the 128-token injection window)
    -> seal (same checksum rule as Payload_Bridge.Seal)
    -> bridge (alb_compiler_adapter.compile_copy inside the trust root)
    -> grade (ready / failed / timed_out / unavailable)
    -> ledger (one JSONL trail record per file)

Deterministic: manifest order, no randomness, fixed timeouts. The JSONL
run ledger is the host mirror of Agent_Telemetry; the weight half of the
loop (delta sheet -> fold -> promote) is tools/promote_model.py fed by
the day_cycle Ada emitter.

Usage:
  python tools/nightly_crucible.py --limit 3
  python tools/nightly_crucible.py --limit 200 --backend c
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from alb_compiler_adapter import compile_copy

MAX_PAYLOAD = 128

# Curriculum DAG: fault families ordered lexer -> parser -> semantic ->
# compound. A tier runs only when every lower tier's last recorded run
# graded at or above the threshold (graded = verdict in {ready, failed}
# with the source file intact: broken inputs SHOULD fail, so the gate
# measures pipeline soundness per family, not agent skill; skill-gating
# on repair-ready rates belongs to run_alb_repair_workflow.py, which can
# share this state file).
TIERS: list[tuple[str, tuple[str, ...]]] = [
    ("lexer", ("invalid_token",)),
    ("parser", ("parser_keyword", "module_fault", "include_fault")),
    ("semantic", ("type_fault", "expression_fault")),
    ("compound", ("double_fault",)),
]
GRADED = ("ready", "failed")


def seal(tokens: list[int]) -> int:
    return sum(token * (index + 1) for index, token in enumerate(tokens))


def family_of(record: dict) -> str:
    mutation = record.get("mutation")
    if isinstance(mutation, str) and mutation:
        return mutation
    return str(record.get("id", "")).rsplit("-", 1)[-1]


def load_gate_state(path: Path) -> dict:
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"tiers": {}}


def tier_rate(state: dict, tier: str) -> float | None:
    runs = state.get("tiers", {}).get(tier, {}).get("runs", [])
    if not runs:
        return None
    last = runs[-1]
    total = int(last.get("total", 0))
    if total <= 0:
        return None
    return float(last.get("graded", 0)) / total


def gate_open(state: dict, tier: str, threshold: float) -> tuple[bool, str]:
    order = [name for name, _ in TIERS]
    for lower in order[: order.index(tier)]:
        rate = tier_rate(state, lower)
        if rate is None:
            return False, f"locked: tier '{lower}' has no recorded run"
        if rate < threshold:
            return False, f"locked: tier '{lower}' last rate {rate:.2f} < {threshold:.2f}"
    return True, "open"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    parser.add_argument("--alb-source", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC"))
    parser.add_argument("--backend", choices=("fasm", "c"), default="fasm")
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--limit", type=int, default=8)
    parser.add_argument("--tier", choices=[name for name, _ in TIERS] + ["all"], default="all")
    parser.add_argument("--list-tiers", action="store_true")
    parser.add_argument("--gate-state", type=Path, default=None)
    parser.add_argument("--require-rate", type=float, default=0.9)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    root = args.root.resolve()

    if args.list_tiers:
        print(json.dumps([{"tier": name, "families": list(fams)} for name, fams in TIERS], indent=2))
        return 0

    manifest_path = root / "data/alb/mutation_manifest.jsonl"
    records = [json.loads(line) for line in manifest_path.read_text(encoding="utf-8").splitlines()]
    records = [record for record in records if "mutated_copy" in record]
    if args.tier != "all":
        wanted = dict(TIERS)[args.tier]
        records = [record for record in records if family_of(record) in wanted]
    records = records[: max(args.limit, 0)]

    gate_state_path = args.gate_state
    gate_state: dict = load_gate_state(gate_state_path) if gate_state_path else {"tiers": {}}
    if args.tier != "all" and gate_state_path is not None:
        unlocked, reason = gate_open(gate_state, args.tier, args.require_rate)
        if not unlocked:
            print(json.dumps({"tier": args.tier, "locked": True, "reason": reason}, sort_keys=True))
            return 0

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    ledger_dir = root / "data/alb/crucible_runs"
    ledger_dir.mkdir(parents=True, exist_ok=True)
    out_path = args.out or (ledger_dir / f"crucible_{stamp}.jsonl")

    compiler = args.compiler.resolve()
    compiler_present = compiler.is_file()
    tallies: dict[str, int] = {"ready": 0, "failed": 0, "timed_out": 0, "unavailable": 0, "missing": 0}
    with out_path.open("w", encoding="utf-8") as ledger:
        for record in records:
            mutated = (root / record["mutated_copy"]).resolve()
            if not mutated.is_file():
                tallies["missing"] += 1
                ledger.write(json.dumps({"id": record.get("id"), "verdict": "missing", "path": str(mutated)}, sort_keys=True) + "\n")
                continue
            raw = mutated.read_bytes()[:MAX_PAYLOAD]
            tokens = list(raw)
            trail = {
                "id": record.get("id"),
                "path": str(mutated),
                "bytes": len(raw),
                "tokens_used": len(tokens),
                "check": seal(tokens),
                "sha256": hashlib.sha256(raw).hexdigest(),
            }
            if not compiler_present:
                trail["verdict"] = "unavailable"
                tallies["unavailable"] += 1
            else:
                outcome = compile_copy(
                    mutated, compiler, root, args.backend, args.timeout,
                    root / "obj/crucible" / str(record.get("id", "x")) / args.backend,
                )
                trail["verdict"] = str(outcome["status"])
                trail["exit_code"] = outcome["exit_code"]
                trail["source_unchanged"] = outcome["source_unchanged"]
                trail["diagnostic_length"] = outcome["diagnostic_length"]
                tallies[str(outcome["status"])] = tallies.get(str(outcome["status"]), 0) + 1
            ledger.write(json.dumps(trail, sort_keys=True) + "\n")

    print(json.dumps({"ledger": str(out_path), "files": len(records), "tallies": tallies}, indent=2, sort_keys=True))
    if gate_state_path is not None and args.tier != "all":
        graded = sum(tallies.get(key, 0) for key in GRADED)
        total = sum(tallies.values())
        entry = gate_state.setdefault("tiers", {}).setdefault(args.tier, {}).setdefault("runs", [])
        entry.append({"date": stamp, "total": total,
                      "graded": graded,
                      "rate": (graded / total) if total else 0.0})
        gate_state_path.write_text(json.dumps(gate_state, indent=2, sort_keys=True), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
