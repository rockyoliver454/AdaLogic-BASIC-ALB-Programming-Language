from __future__ import annotations

import hashlib
import json
import re
import struct
from collections import Counter
from pathlib import Path

FEATURES = 256
FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
WORDS = re.compile(r"[a-z0-9_.-]+")
PHASES = ("complete", "lexer", "parser", "weaver", "emitter", "build", "timeout")
REPAIRS = ("none", "fix_lexical", "fix_keyword", "fix_type", "close_module", "fix_expression", "restore_include", "compiler_guided")
MUTATION_REPAIR = {
    "invalid_token": ("lexer", "fix_lexical"),
    "parser_keyword": ("parser", "fix_keyword"),
    "type_fault": ("parser", "fix_type"),
    "module_fault": ("parser", "close_module"),
    "expression_fault": ("parser", "fix_expression"),
    "include_fault": ("weaver", "restore_include"),
    "double_fault": ("lexer", "fix_lexical"),
}


def hash_word(word: str) -> int:
    value = FNV_OFFSET
    for byte in word.encode("ascii", "replace"):
        value ^= byte
        value = value * FNV_PRIME & 0xFFFFFFFF
    return value % FEATURES


def features(text: str) -> set[int]:
    return {hash_word(word) for word in WORDS.findall(text.lower())}


def infer_phase(text: str, fallback: str) -> str:
    lowered = text.lower()
    if "err_parse" in lowered or "parser" in lowered or "syntax" in lowered:
        return "parser"
    if "lexer" in lowered or "unexpected token" in lowered:
        return "lexer"
    if "include" in lowered or "weav" in lowered or "couldna open" in lowered:
        return "weaver"
    if "emitter" in lowered or "backend" in lowered or "lowering" in lowered:
        return "emitter"
    return fallback


def samples(root: Path) -> list[dict[str, str]]:
    result = []
    diagnostics = [json.loads(line) for line in (root / "data/alb/diagnostic_dataset.jsonl").read_text(encoding="utf-8").splitlines()]
    for row in diagnostics:
        phase = row["phase"] if row["phase"] in PHASES else "build"
        repair = "none" if row["success"] else "compiler_guided"
        result.append({"split": row["split"], "text": row["diagnostic"], "phase": phase, "repair": repair})
    triples = [json.loads(line) for line in (root / "data/alb/mutation_triples.jsonl").read_text(encoding="utf-8").splitlines()]
    for row in triples:
        intended_phase, repair = MUTATION_REPAIR.get(row["mutation"], ("build", "compiler_guided"))
        text = row["mutated_result"]["diagnostic"]
        phase = infer_phase(text, intended_phase)
        result.append({"split": row["split"], "text": text, "phase": phase, "repair": repair})
    return result


def train(rows: list[dict[str, str]], key: str, labels: tuple[str, ...]) -> list[list[int]]:
    vectors = [(features(row["text"]), row[key]) for row in rows]
    weights = []
    for label in labels:
        positive = max(1, sum(expected == label for _, expected in vectors))
        negative = max(1, len(vectors) - positive)
        current = []
        for feature in range(FEATURES):
            pos = sum(feature in vector and expected == label for vector, expected in vectors) / positive
            neg = sum(feature in vector and expected != label for vector, expected in vectors) / negative
            delta = pos - neg
            current.append(1 if delta >= 0.08 else -1 if delta <= -0.20 else 0)
        weights.append(current)
    return weights


def prediction(text: str, weights: list[list[int]], labels: tuple[str, ...]) -> tuple[str, int, int]:
    vector = features(text)
    scores = [sum(row[index] for index in vector) for row in weights]
    order = sorted(range(len(scores)), key=lambda index: (scores[index], -index), reverse=True)
    best = order[0]
    return labels[best], scores[best], scores[best] - scores[order[1]]


def predict(text: str, weights: list[list[int]], labels: tuple[str, ...]) -> str:
    return prediction(text, weights, labels)[0]


def calibrate(rows: list[dict[str, str]], weights: list[list[int]], key: str, labels: tuple[str, ...]) -> list[int]:
    thresholds = []
    for label in labels:
        margins = sorted(
            margin for row in rows
            for predicted, score, margin in (prediction(row["text"], weights, labels),)
            if predicted == label and row[key] == label
        )
        thresholds.append(max(1, margins[len(margins) // 4]) if margins else 2)
    return thresholds


def evaluate(rows: list[dict[str, str]], phase_weights: list[list[int]], repair_weights: list[list[int]]) -> dict[str, object]:
    phase_correct = sum(predict(row["text"], phase_weights, PHASES) == row["phase"] for row in rows)
    repair_correct = sum(predict(row["text"], repair_weights, REPAIRS) == row["repair"] for row in rows)
    phase_confusion = Counter((row["phase"], predict(row["text"], phase_weights, PHASES)) for row in rows)
    repair_confusion = Counter((row["repair"], predict(row["text"], repair_weights, REPAIRS)) for row in rows)
    return {
        "samples": len(rows),
        "phase_accuracy": phase_correct / len(rows) if rows else 0.0,
        "repair_accuracy": repair_correct / len(rows) if rows else 0.0,
        "phase_confusion": {a + "->" + b: count for (a, b), count in sorted(phase_confusion.items())},
        "repair_confusion": {a + "->" + b: count for (a, b), count in sorted(repair_confusion.items())},
    }


def calibrated_metrics(rows: list[dict[str, str]], weights: list[list[int]], thresholds: list[int]) -> dict[str, object]:
    accepted = correct = 0
    per_class = {}
    predictions = []
    for row in rows:
        label, score, margin = prediction(row["text"], weights, REPAIRS)
        is_accepted = margin >= thresholds[REPAIRS.index(label)]
        predictions.append((row["repair"], label, is_accepted))
        accepted += is_accepted
        correct += is_accepted and label == row["repair"]
    for label in REPAIRS:
        predicted = sum(p == label and accepted_flag for expected, p, accepted_flag in predictions)
        true_count = sum(expected == label for expected, p, accepted_flag in predictions)
        true_positive = sum(expected == label and p == label and accepted_flag for expected, p, accepted_flag in predictions)
        per_class[label] = {
            "accepted": predicted,
            "support": true_count,
            "accepted_precision": true_positive / predicted if predicted else 0.0,
            "accepted_recall": true_positive / true_count if true_count else 0.0,
        }
    return {
        "accepted": accepted,
        "abstained": len(rows) - accepted,
        "coverage": accepted / len(rows) if rows else 0.0,
        "accepted_precision": correct / accepted if accepted else 0.0,
        "per_class": per_class,
    }


def ada_matrix(name: str, weights: list[list[int]]) -> str:
    rows = []
    for row_index, row in enumerate(weights, 1):
        chunks = []
        for start in range(0, len(row), 16):
            chunks.append("         " + ", ".join(str(value) for value in row[start:start + 16]))
        rows.append(f"      {row_index} => (\n" + ",\n".join(chunks) + "\n      )")
    return f"   {name} : constant Weight_Matrix (1 .. {len(weights)}) := (\n" + ",\n".join(rows) + "\n   );\n"


def write_ada(path: Path, phase_weights: list[list[int]], repair_weights: list[list[int]], repair_thresholds: list[int], digest: str) -> None:
    content = (
        "package ALB_Diagnostic_Weights is\n"
        "   pragma Pure;\n"
        f"   Feature_Count : constant := {FEATURES};\n"
        "   subtype Feature_Index is Positive range 1 .. Feature_Count;\n"
        "   subtype Ternary_Weight is Integer range -1 .. 1;\n"
        "   type Weight_Row is array (Feature_Index) of Ternary_Weight;\n"
        "   type Weight_Matrix is array (Positive range <>) of Weight_Row;\n"
        + ada_matrix("Phase_Weights", phase_weights)
        + ada_matrix("Repair_Weights", repair_weights)
        + "   type Repair_Threshold_Array is array (Positive range <>) of Natural;\n"
        + f"   Repair_Thresholds : constant Repair_Threshold_Array (1 .. {len(repair_thresholds)}) := ("
        + ", ".join(str(value) for value in repair_thresholds) + ");\n"
        + f"   Dataset_SHA256 : constant String := \"{digest}\";\n"
        "end ALB_Diagnostic_Weights;\n"
    )
    path.write_text(content, encoding="ascii")


def write_packed(path: Path, phase_weights: list[list[int]], repair_weights: list[list[int]], repair_thresholds: list[int], digest: str) -> None:
    codes = {0: 0, 1: 1, -1: 2}
    flat = [value for matrix in (phase_weights, repair_weights) for row in matrix for value in row]
    payload = bytearray()
    for start in range(0, len(flat), 4):
        byte = 0
        for lane, value in enumerate(flat[start:start + 4]):
            byte |= codes[value] << (6 - lane * 2)
        payload.append(byte)
    path.write_bytes(b"ALDN" + struct.pack("<HHBB", 3, FEATURES, len(PHASES), len(REPAIRS)) + bytes(repair_thresholds) + bytes.fromhex(digest) + payload)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    rows = samples(root)
    train_rows = [row for row in rows if row["split"] == "train"]
    phase_weights = train(train_rows, "phase", PHASES)
    repair_weights = train(train_rows, "repair", REPAIRS)
    dev_rows = [row for row in rows if row["split"] == "dev"]
    repair_thresholds = calibrate(dev_rows, repair_weights, "repair", REPAIRS)
    digest = hashlib.sha256((root / "data/alb/diagnostic_dataset.jsonl").read_bytes() + (root / "data/alb/mutation_triples.jsonl").read_bytes()).hexdigest()
    metrics = {}
    for split in ("train", "dev", "test"):
        split_rows = [row for row in rows if row["split"] == split]
        metrics[split] = evaluate(split_rows, phase_weights, repair_weights)
        metrics[split]["calibrated_repair"] = calibrated_metrics(split_rows, repair_weights, repair_thresholds)
    model = {"format": "ALDN", "version": 3, "feature_count": FEATURES, "phases": PHASES, "repairs": REPAIRS, "phase_weights": phase_weights, "repair_weights": repair_weights, "repair_thresholds": repair_thresholds, "dataset_sha256": digest, "metrics": metrics}
    (root / "models/alb_diag.trm").write_text(json.dumps(model, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_packed(root / "models/alb_diag.albd", phase_weights, repair_weights, repair_thresholds, digest)
    write_ada(root / "src/model/alb_diagnostic_weights.ads", phase_weights, repair_weights, repair_thresholds, digest)
    report = {"dataset_sha256": digest, "repair_thresholds": dict(zip(REPAIRS, repair_thresholds)), "metrics": metrics, "packed_bytes": (root / "models/alb_diag.albd").stat().st_size}
    (root / "evaluation/alb_diagnostic_metrics.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
