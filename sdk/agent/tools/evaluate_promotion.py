from __future__ import annotations

import hashlib
import json
from pathlib import Path


def load(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    router = load(root / "evaluation/router/latest_metrics.json")["metrics"]["test"]
    diagnostic = load(root / "evaluation/alb_diagnostic_metrics.json")["metrics"]["test"]
    calibrated = diagnostic["calibrated_repair"]
    repairs = load(root / "data/alb/repair_workflow_summary.json")
    semantics = load(root / "evaluation/repair_semantics_summary.json")
    probes = load(root / "data/alb/compiler_probe_summary.json")
    triples = load(root / "data/alb/mutation_triple_summary.json")
    composer = load(root / "evaluation/english_composer_metrics.json")["metrics"]["test"]
    seq = load(root / "models/alb_seq_metrics.json")
    gates = {
        "router_exact_match": {"value": router["exact_match"], "minimum": 0.85},
        "router_hamming_loss": {"value": router["hamming_loss"], "maximum": 0.06},
        "diagnostic_phase_accuracy": {"value": diagnostic["phase_accuracy"], "minimum": 0.80},
        "diagnostic_repair_accuracy": {"value": diagnostic["repair_accuracy"], "minimum": 0.80},
        "accepted_repair_precision": {"value": calibrated["accepted_precision"], "minimum": 0.95},
        "accepted_repair_coverage": {"value": calibrated["coverage"], "minimum": 0.30},
        "semantic_repair_precision": {"value": semantics["validated_repair_precision"], "minimum": 1.0},
        "useful_triples": {"value": triples["useful_triples"], "minimum": 150},
        "backend_probe_pass_rate": {"value": probes["passed"] / probes["attempted"], "minimum": 0.80},
        "repair_integrity_rate": {"value": repairs["integrity_passed"] / repairs["records"], "minimum": 1.0},
        "repair_attempt_cap": {"value": repairs["maximum_attempts_observed"], "maximum": repairs["hard_attempt_cap"]},
        "composer_frame_accuracy": {"value": composer["frame"]["accuracy"], "minimum": 0.85},
        "composer_frame_precision": {"value": composer["frame"]["accepted_precision"], "minimum": 0.95},
        "composer_register_precision": {"value": composer["register"]["accepted_precision"], "minimum": 0.95},
        "seq_test_accuracy": {"value": seq["accuracy"]["test"], "minimum": 0.35},
        "seq_beats_identity": {"value": seq["accuracy"]["test"] - seq["baselines"]["identity_bigram_test"], "minimum": 0.0},
        "seq_beats_static": {"value": seq["accuracy"]["test"] - seq["baselines"]["dominant_successor_test"], "minimum": 0.0},
    }
    passed = True
    for gate in gates.values():
        gate["passed"] = ("minimum" not in gate or gate["value"] >= gate["minimum"]) and ("maximum" not in gate or gate["value"] <= gate["maximum"])
        passed = passed and gate["passed"]
    report = {"format": "PATH-B-PROMOTION", "version": 1, "passed": passed, "gates": gates}
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    (root / "evaluation/path_b_promotion.json").write_text(encoded, encoding="utf-8")
    report["report_sha256"] = hashlib.sha256(encoded.encode()).hexdigest()
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
