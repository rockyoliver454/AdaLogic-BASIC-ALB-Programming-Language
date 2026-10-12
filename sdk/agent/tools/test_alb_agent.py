from __future__ import annotations

import hashlib
import json
from pathlib import Path

from alb_agent import ask, check_file, repair_file


def expect(value: bool, name: str) -> None:
    if not value:
        raise AssertionError(name)
    print("  [PASS] " + name)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    compiler = Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe")
    algebra = ask(root, "Solve 3x + 4 = 19")
    expect(algebra["success"] and algebra["evidence"][0]["success"], "ask routes and verifies exact algebra")
    quadratic = ask(root, "Solve x^2 - 5x + 6 = 0")
    expect(quadratic["evidence"][0]["fields"].get("first_numerator") == "3", "ask verifies quadratic roots")
    unknown = ask(root, "Diagnose this diesel engine vibration")
    expect(unknown["route"]["unknown"], "ask rejects unsupported request")
    clean_source = Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\src\AGENT\testing\cases\07_empty.alb")
    clean_hash = hashlib.sha256(clean_source.read_bytes()).hexdigest()
    checked = check_file(root, compiler, clean_source, "fasm")
    expect(checked["success"] and checked["original_unchanged"], "check compiles staged copy and preserves original")
    records = [json.loads(line) for line in (root / "data/alb/mutation_manifest.jsonl").read_text(encoding="utf-8").splitlines()]
    record = next(row for row in records if row["mutation"] == "parser_keyword" and row["split"] == "train")
    repair_source = root / record["mutated_copy"]
    before = hashlib.sha256(repair_source.read_bytes()).hexdigest()
    repaired = repair_file(root, compiler, repair_source, "fasm", 3)
    expect(repaired["success"] and repaired["attempt_count"] <= 3, "repair validates staged candidate within cap")
    expect(repaired["original_unchanged"] and hashlib.sha256(repair_source.read_bytes()).hexdigest() == before, "repair never overwrites input")
    expect(bool(repaired["diff"]) and repaired["validated_output"], "repair returns diff and validated output")
    expect(hashlib.sha256(clean_source.read_bytes()).hexdigest() == clean_hash, "external ALB source remains byte-stable")
    print("ALB AGENT PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
