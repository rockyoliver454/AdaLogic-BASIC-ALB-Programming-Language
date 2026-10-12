from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from pathlib import Path

LOCATION = re.compile(r"(?P<file>[^\s:]+\.(?:alb|albi)):(?P<line>\d+)(?::(?P<column>\d+))?", re.IGNORECASE)


def kind(text: str) -> str:
    lowered = text.lower()
    if "pipe-as-concat" in lowered:
        return "pipe_concat_numeric"
    if any(token in lowered for token in ("s16", "s32", "int16", "int32")):
        return "preferred_integer_type"
    if "endmodule" in lowered and "missing" in lowered:
        return "missing_module_end"
    if "unsupported" in lowered or "not implemented" in lowered:
        return "backend_unsupported"
    return "none" if not text.strip() else "generic_failure"


def repair_label(value: str) -> str:
    return {
        "pipe_concat_numeric": "replace_pipe_with_or_if_bitwise",
        "preferred_integer_type": "use_i_integer_family",
        "missing_module_end": "restore_endmodule",
        "backend_unsupported": "choose_supported_backend_feature",
        "generic_failure": "compiler_guided_repair",
        "none": "none",
    }[value]


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    input_path = root / "data/alb/compiler_probes.jsonl"
    probes = [json.loads(line) for line in input_path.read_text(encoding="utf-8").splitlines()]
    records = []
    for probe in probes:
        diagnostic = probe["diagnostic"]
        normalized_kind = "none" if probe["success"] else kind(diagnostic)
        match = LOCATION.search(diagnostic)
        records.append({
            "id": "alb-probe-" + probe["source_sha256"][:16] + "-" + probe["backend"],
            "split": probe["split"],
            "source_path": probe["source_path"],
            "source_sha256": probe["source_sha256"],
            "backend": probe["backend"],
            "success": probe["success"],
            "phase": probe["phase"],
            "kind": normalized_kind,
            "severity": "none" if probe["success"] else "error",
            "line": int(match.group("line")) if match else 0,
            "column": int(match.group("column") or 0) if match else 0,
            "repair_label": repair_label(normalized_kind),
            "diagnostic": diagnostic,
            "compiler_grounded": True,
        })
    output = root / "data/alb/diagnostic_dataset.jsonl"
    output.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), encoding="utf-8")
    summary = {
        "format": "ALB-DIAGNOSTIC-DATASET",
        "version": 1,
        "records": len(records),
        "splits": dict(sorted(Counter(record["split"] for record in records).items())),
        "phases": dict(sorted(Counter(record["phase"] for record in records).items())),
        "kinds": dict(sorted(Counter(record["kind"] for record in records).items())),
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
    }
    (root / "data/alb/diagnostic_dataset_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
