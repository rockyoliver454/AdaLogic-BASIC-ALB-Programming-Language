from __future__ import annotations

import json
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    records = [json.loads(line) for line in (root / "data/alb/repair_workflow.jsonl").read_text(encoding="utf-8").splitlines()]
    transformed = repaired = abstained = 0
    for record in records:
        if record["unknown_rejected"]:
            abstained += 1
        if record["transform_applied"]:
            transformed += 1
            proof = record["edit_proof"]
            if not proof["diff"] or proof["before_sha256"] == proof["after_sha256"]:
                raise ValueError(f"invalid edit proof: {record['id']}")
        if record["repaired"]:
            repaired += 1
            proof = record["compiler_proof"]
            if proof["after_status"] != "ready" or not proof["rank_improved"]:
                raise ValueError(f"invalid compiler proof: {record['id']}")
        if record["attempt_count"] > record["max_attempts"] or record["max_attempts"] > 3:
            raise ValueError(f"attempt cap violated: {record['id']}")
        if not record["source_integrity"]:
            raise ValueError(f"source integrity failed: {record['id']}")
    print(f"ALB REPAIR PROOF PASS: {len(records)} records, {transformed} transformed, {repaired} repaired, {abstained} abstained")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
