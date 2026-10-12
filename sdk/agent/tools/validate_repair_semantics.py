from __future__ import annotations

import hashlib
import json
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    workflow = [json.loads(line) for line in (root / "data/alb/repair_workflow.jsonl").read_text(encoding="utf-8").splitlines()]
    mutations = {row["id"]: row for row in (json.loads(line) for line in (root / "data/alb/mutation_manifest.jsonl").read_text(encoding="utf-8").splitlines())}
    results = []
    for record in workflow:
        mutation = mutations[record["id"]]
        original = root / mutation["original_copy"]
        final_candidate = root / record["attempts"][-1]["candidate"]
        original_hash = hashlib.sha256(original.read_bytes()).hexdigest()
        final_hash = hashlib.sha256(final_candidate.read_bytes()).hexdigest()
        exact_restoration = original_hash == final_hash
        normalized_restoration = original.read_text(encoding="utf-8", errors="replace") == final_candidate.read_text(encoding="utf-8", errors="replace")
        compiler_valid = record["attempts"][-1]["status"] == "ready"
        results.append({
            "id": record["id"],
            "mutation": record["mutation"],
            "compiler_valid": compiler_valid,
            "claimed_repaired": bool(record["repaired"]),
            "exact_restoration": exact_restoration,
            "normalized_restoration": normalized_restoration,
            "semantic_proxy_pass": compiler_valid and normalized_restoration,
            "original_sha256": original_hash,
            "final_sha256": final_hash,
        })
    output = root / "evaluation/repair_semantics.jsonl"
    output.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in results), encoding="utf-8")
    repaired = [row for row in results if row["claimed_repaired"]]
    summary = {
        "format": "ALB-REPAIR-SEMANTIC-PROXY",
        "version": 1,
        "records": len(results),
        "compiler_valid": len(repaired),
        "exact_restorations": sum(row["exact_restoration"] for row in results),
        "normalized_restorations": sum(row["normalized_restoration"] for row in results),
        "semantic_proxy_passes": sum(row["semantic_proxy_pass"] for row in results),
        "validated_repair_precision": sum(row["semantic_proxy_pass"] for row in repaired) / len(repaired) if repaired else 0.0,
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
    }
    (root / "evaluation/repair_semantics_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["validated_repair_precision"] == 1.0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
