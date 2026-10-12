from __future__ import annotations

import hashlib
import json
import struct
from collections import Counter
from pathlib import Path

import re

FEATURES = 512
RESERVED = 64
HASHED = 224
FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
WORDS = re.compile(r"[a-z0-9_.-]+")
TERSE_MARKERS = (
    "just the answer", "tldr", "quick", "answer only", "no explanation",
    "short version", "briefly", "one line", "fast", "skip the",
)
EXPLANATORY_MARKERS = (
    "explain", "step by step", "walk me", "in detail", "teach me",
    "understand", "reasoning", "break down", "describe", "verbose",
    "complete explanation", "thorough", "how does",
)


def fnv(text: str) -> int:
    value = FNV_OFFSET
    for byte in text.encode("ascii", "replace"):
        value ^= byte
        value = value * FNV_PRIME & 0xFFFFFFFF
    return value


def features(text: str) -> set[int]:
    words = WORDS.findall(text.lower())
    normalized = " ".join(words)
    result = set()
    terse_hit = any(marker in normalized for marker in TERSE_MARKERS)
    expl_hit = any(marker in normalized for marker in EXPLANATORY_MARKERS)
    if terse_hit and expl_hit:
        result.update(range(16, 24))
    elif terse_hit:
        result.update(range(0, 8))
    elif expl_hit:
        result.update(range(8, 16))
    else:
        result.update(range(24, 32))
    for word in words:
        result.add(RESERVED + fnv(word) % HASHED)
    for left, right in zip(words, words[1:]):
        result.add(RESERVED + HASHED + fnv(left + " " + right) % HASHED)
    return result

FRAMES = (
    "answer_linear", "answer_roots", "answer_symbolic", "answer_no_real",
    "answer_no_solution", "answer_infinite", "answer_invalid",
    "check_pass", "check_fail",
    "repair_verified", "repair_partial", "repair_abstained",
    "alb_file_required", "english_pending", "unknown_request", "no_evidence",
)
REGISTERS = ("terse", "plain", "explanatory")
SPLITS = ("train", "dev", "test")


def samples(root: Path) -> list[dict[str, str]]:
    rows = []
    for split in SPLITS:
        for line in (root / f"data/english/{split}.jsonl").read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            rows.append({"id": row["id"], "split": split, "head": row["head"], "text": row["text"], "label": row["label"], "family": row["family"]})
    return rows


def validate(rows: list[dict[str, str]]) -> None:
    ids: set[str] = set()
    families: dict[str, str] = {}
    for row in rows:
        if row["id"] in ids:
            raise ValueError(f"duplicate id: {row['id']}")
        ids.add(row["id"])
        if row["family"] in families and families[row["family"]] != row["split"]:
            raise ValueError(f"family leakage: {row['family']}")
        families[row["family"]] = row["split"]


def train(rows: list[dict[str, str]], labels: tuple[str, ...]) -> list[list[int]]:
    vectors = [(features(row["text"]), row["label"]) for row in rows]
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


def calibrate(rows: list[dict[str, str]], weights: list[list[int]], labels: tuple[str, ...]) -> list[int]:
    thresholds = []
    for label in labels:
        predictions = [
            (margin, row["label"] == label)
            for row in rows
            for predicted, score, margin in (prediction(row["text"], weights, labels),)
            if predicted == label
        ]
        best = None
        for margin in sorted({margin for margin, _ in predictions}):
            accepted = [correct for bound, correct in predictions if bound >= margin]
            if accepted and sum(accepted) / len(accepted) >= 0.95:
                best = max(1, margin)
                break
        if best is None:
            best = max((margin for margin, _ in predictions), default=1) + 1
        thresholds.append(best)
    return thresholds


def evaluate(rows: list[dict[str, str]], weights: list[list[int]], labels: tuple[str, ...], thresholds: list[int]) -> dict[str, object]:
    correct = accepted = accepted_correct = 0
    confusion: Counter = Counter()
    for row in rows:
        predicted, score, margin = prediction(row["text"], weights, labels)
        correct += predicted == row["label"]
        is_accepted = margin >= thresholds[labels.index(predicted)]
        accepted += is_accepted
        accepted_correct += is_accepted and predicted == row["label"]
        confusion[(row["label"], predicted)] += 1
    return {
        "samples": len(rows),
        "accuracy": correct / len(rows) if rows else 0.0,
        "accepted": accepted,
        "abstained": len(rows) - accepted,
        "coverage": accepted / len(rows) if rows else 0.0,
        "accepted_precision": accepted_correct / accepted if accepted else 0.0,
        "confusion": {a + "->" + b: count for (a, b), count in sorted(confusion.items())},
    }


def ada_matrix(name: str, weights: list[list[int]]) -> str:
    rows = []
    for row_index, row in enumerate(weights, 1):
        chunks = []
        for start in range(0, len(row), 16):
            chunks.append("         " + ", ".join(str(value) for value in row[start:start + 16]))
        rows.append(f"      {row_index} => (\n" + ",\n".join(chunks) + "\n      )")
    return f"   {name} : constant Weight_Matrix (1 .. {len(weights)}) := (\n" + ",\n".join(rows) + "\n   );\n"


def write_ada(path: Path, frame_weights: list[list[int]], register_weights: list[list[int]], frame_thresholds: list[int], register_thresholds: list[int], digest: str) -> None:
    content = (
        "package English_Composer_Weights is\n"
        "   pragma Pure;\n"
        f"   Feature_Count : constant := {FEATURES};\n"
        "   subtype Feature_Index is Positive range 1 .. Feature_Count;\n"
        "   subtype Ternary_Weight is Integer range -1 .. 1;\n"
        "   type Weight_Row is array (Feature_Index) of Ternary_Weight;\n"
        "   type Weight_Matrix is array (Positive range <>) of Weight_Row;\n"
        + ada_matrix("Frame_Weights", frame_weights)
        + ada_matrix("Register_Weights", register_weights)
        + "   type Threshold_Array is array (Positive range <>) of Natural;\n"
        + f"   Frame_Thresholds : constant Threshold_Array (1 .. {len(frame_thresholds)}) := ("
        + ", ".join(str(value) for value in frame_thresholds) + ");\n"
        + f"   Register_Thresholds : constant Threshold_Array (1 .. {len(register_thresholds)}) := ("
        + ", ".join(str(value) for value in register_thresholds) + ");\n"
        + f"   Dataset_SHA256 : constant String := \"{digest}\";\n"
        "end English_Composer_Weights;\n"
    )
    path.write_text(content, encoding="ascii")


def write_packed(path: Path, frame_weights: list[list[int]], register_weights: list[list[int]], frame_thresholds: list[int], register_thresholds: list[int], digest: str) -> None:
    codes = {0: 0, 1: 1, -1: 2}
    flat = [value for matrix in (frame_weights, register_weights) for row in matrix for value in row]
    payload = bytearray()
    for start in range(0, len(flat), 4):
        byte = 0
        for lane, value in enumerate(flat[start:start + 4]):
            byte |= codes[value] << (6 - lane * 2)
        payload.append(byte)
    path.write_bytes(
        b"ALEN"
        + struct.pack("<HHBB", 1, FEATURES, len(FRAMES), len(REGISTERS))
        + bytes(frame_thresholds)
        + bytes(register_thresholds)
        + bytes.fromhex(digest)
        + payload
    )


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    rows = samples(root)
    validate(rows)
    frame_rows = [row for row in rows if row["head"] == "frame"]
    register_rows = [row for row in rows if row["head"] == "register"]
    frame_train = [row for row in frame_rows if row["split"] == "train"]
    register_train = [row for row in register_rows if row["split"] == "train"]
    frame_weights = train(frame_train, FRAMES)
    register_weights = train(register_train, REGISTERS)
    frame_dev = [row for row in frame_rows if row["split"] == "dev"]
    register_dev = [row for row in register_rows if row["split"] == "dev"]
    frame_thresholds = calibrate(frame_dev, frame_weights, FRAMES)
    register_thresholds = calibrate(register_dev, register_weights, REGISTERS)
    digest = hashlib.sha256(
        b"".join((root / f"data/english/{split}.jsonl").read_bytes() for split in SPLITS)
    ).hexdigest()
    metrics = {}
    for split in SPLITS:
        metrics[split] = {
            "frame": evaluate([row for row in frame_rows if row["split"] == split], frame_weights, FRAMES, frame_thresholds),
            "register": evaluate([row for row in register_rows if row["split"] == split], register_weights, REGISTERS, register_thresholds),
        }
    model = {
        "format": "ALEN", "version": 1, "feature_count": FEATURES,
        "frames": FRAMES, "registers": REGISTERS,
        "frame_weights": frame_weights, "register_weights": register_weights,
        "frame_thresholds": frame_thresholds, "register_thresholds": register_thresholds,
        "dataset_sha256": digest, "metrics": metrics,
    }
    (root / "models/english_comp.trm").write_text(json.dumps(model, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_packed(root / "models/english_comp.alen", frame_weights, register_weights, frame_thresholds, register_thresholds, digest)
    write_ada(root / "src/model/english_composer_weights.ads", frame_weights, register_weights, frame_thresholds, register_thresholds, digest)
    report = {
        "dataset_sha256": digest,
        "frame_thresholds": dict(zip(FRAMES, frame_thresholds)),
        "register_thresholds": dict(zip(REGISTERS, register_thresholds)),
        "metrics": metrics,
        "packed_bytes": (root / "models/english_comp.alen").stat().st_size,
    }
    (root / "evaluation/english_composer_metrics.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
