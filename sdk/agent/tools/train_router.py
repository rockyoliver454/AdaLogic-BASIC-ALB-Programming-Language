from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
from dataclasses import dataclass
from pathlib import Path

DOMAINS = ("english", "algebra", "alb")
FEATURE_COUNT = 1024
FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
WORD_RE = re.compile(r"[a-z0-9_.^]+|[+*/=()-]")
RESERVED_FEATURES = 64
SIGNAL_GROUPS = (
    ("explain", "summarize", "rewrite", "grammar", "sentence", "paragraph", "describe", "document", "clear", "meaning", "tone", "word"),
    ("solve", "factor", "simplify", "equation", "polynomial", "root", "expand", "expression", "linear", "quadratic", "algebra", "formula"),
    ("alb", "adalogic", ".alb", ".albi", "albt", "module", "define", "backend", "compiler", "emitter", "function", "procedure", "declaremodule", "endmodule"),
)


def fnv_bytes(data: bytes, prefix: bytes) -> int:
    value = FNV_OFFSET
    for byte in prefix + data:
        value ^= byte
        value = (value * FNV_PRIME) & 0xFFFFFFFF
    return value


def features(text: str) -> set[int]:
    normalized = " ".join(text.lower().split())
    raw = normalized.encode("ascii", "replace")
    result = {0}
    hits = [any(marker in normalized for marker in markers) for markers in SIGNAL_GROUPS]
    for group_index, hit in enumerate(hits):
        if hit:
            start = 1 + group_index * 8
            result.update(range(start, start + 8))
    if "=" in normalized or "^" in normalized:
        result.update(range(25, 32))
    if hits[0] and hits[1]:
        result.update(range(32, 40))
    if hits[0] and hits[2]:
        result.update(range(40, 48))
    if hits[1] and hits[2]:
        result.update(range(48, 56))
    if all(hits):
        result.update(range(56, 64))
    words = WORD_RE.findall(normalized)
    span = FEATURE_COUNT - RESERVED_FEATURES
    for word in words:
        result.add(RESERVED_FEATURES + fnv_bytes(word.encode("ascii"), b"w:") % span)
    for left, right in zip(words, words[1:]):
        result.add(RESERVED_FEATURES + fnv_bytes((left + " " + right).encode("ascii"), b"b:") % span)
    return result


@dataclass(frozen=True)
class Sample:
    sample_id: str
    text: str
    labels: frozenset[str]
    family: str


def load(path: Path) -> list[Sample]:
    samples = []
    with path.open("r", encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            row = json.loads(line)
            labels = frozenset(row["labels"])
            if not labels.issubset(DOMAINS):
                raise ValueError(f"{path}:{line_number}: invalid labels")
            samples.append(Sample(row["id"], row["text"], labels, row.get("family", row["id"])))
    return samples


def validate_splits(groups: dict[str, list[Sample]]) -> None:
    ids: set[str] = set()
    texts: set[str] = set()
    family_splits: dict[str, str] = {}
    for split, samples in groups.items():
        for sample in samples:
            normalized = " ".join(sample.text.lower().split())
            if sample.sample_id in ids:
                raise ValueError(f"duplicate id: {sample.sample_id}")
            if normalized in texts:
                raise ValueError(f"duplicate text in split {split}: {sample.sample_id}")
            if sample.family in family_splits and family_splits[sample.family] != split:
                raise ValueError(f"family leakage: {sample.family}")
            ids.add(sample.sample_id)
            texts.add(normalized)
            family_splits[sample.family] = split


def train(samples: list[Sample]) -> list[list[int]]:
    vectors = [(features(sample.text), sample.labels) for sample in samples]
    weights: list[list[int]] = []
    for domain in DOMAINS:
        positive = sum(domain in labels for _, labels in vectors)
        negative = len(vectors) - positive
        row = []
        for feature in range(FEATURE_COUNT):
            pos_hits = sum(feature in vector and domain in labels for vector, labels in vectors)
            neg_hits = sum(feature in vector and domain not in labels for vector, labels in vectors)
            pos_rate = pos_hits / positive if positive else 0.0
            neg_rate = neg_hits / negative if negative else 0.0
            delta = pos_rate - neg_rate
            row.append(1 if delta >= 0.05 else -1 if delta <= -0.20 else 0)
        weights.append(row)
    return weights


def score(text: str, weights: list[list[int]]) -> list[int]:
    vector = features(text)
    return [sum(row[index] for index in vector) for row in weights]


def tune_thresholds(samples: list[Sample], weights: list[list[int]]) -> list[int]:
    thresholds = []
    scored = [(score(sample.text, weights), sample.labels) for sample in samples]
    for domain_index, domain in enumerate(DOMAINS):
        candidates = sorted({scores[domain_index] for scores, _ in scored})
        candidates += [min(candidates) - 1, max(candidates) + 1]
        best = (-1.0, 0)
        for threshold in candidates:
            tp = fp = fn = 0
            for scores, labels in scored:
                predicted = scores[domain_index] >= threshold
                expected = domain in labels
                tp += predicted and expected
                fp += predicted and not expected
                fn += not predicted and expected
            precision = tp / (tp + fp) if tp + fp else 0.0
            recall = tp / (tp + fn) if tp + fn else 0.0
            f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
            candidate = (f1, threshold)
            if candidate > best:
                best = candidate
        thresholds.append(best[1])
    return thresholds


def predict(text: str, weights: list[list[int]], thresholds: list[int]) -> frozenset[str]:
    vector = features(text)
    scores = score(text, weights)
    evidence = (1 in vector, 9 in vector or 25 in vector, 17 in vector)
    return frozenset(
        domain for domain, value, threshold, present
        in zip(DOMAINS, scores, thresholds, evidence)
        if present or value >= threshold
    )


def metrics(samples: list[Sample], weights: list[list[int]], thresholds: list[int]) -> dict[str, object]:
    exact = 0
    label_errors = 0
    per_domain = {}
    combinations: dict[str, dict[str, int]] = {}
    margins = []
    for sample in samples:
        predicted = predict(sample.text, weights, thresholds)
        exact += predicted == sample.labels
        label_errors += len(predicted.symmetric_difference(sample.labels))
        key = "+".join(sorted(sample.labels)) or "unknown"
        entry = combinations.setdefault(key, {"samples": 0, "exact": 0})
        entry["samples"] += 1
        entry["exact"] += predicted == sample.labels
        values = score(sample.text, weights)
        margins.append(max(value - threshold for value, threshold in zip(values, thresholds)))
    for domain in DOMAINS:
        tp = fp = fn = tn = 0
        for sample in samples:
            predicted = domain in predict(sample.text, weights, thresholds)
            expected = domain in sample.labels
            tp += predicted and expected
            fp += predicted and not expected
            fn += not predicted and expected
            tn += not predicted and not expected
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        per_domain[domain] = {"precision": precision, "recall": recall, "f1": f1, "tp": tp, "fp": fp, "fn": fn, "tn": tn}
    for entry in combinations.values():
        entry["exact_rate"] = entry["exact"] / entry["samples"]
    return {
        "samples": len(samples),
        "exact_match": exact / len(samples) if samples else 0.0,
        "hamming_loss": label_errors / (len(samples) * len(DOMAINS)) if samples else 0.0,
        "mean_max_margin": sum(margins) / len(margins) if margins else 0.0,
        "domains": per_domain,
        "combinations": combinations,
    }


def dataset_hash(paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.name.encode("utf-8"))
        digest.update(path.read_bytes())
    return digest.hexdigest()


def write_model(path: Path, weights: list[list[int]], thresholds: list[int], digest: str, results: dict[str, object]) -> None:
    model = {
        "format": "ALBR",
        "version": 1,
        "feature_count": FEATURE_COUNT,
        "domains": list(DOMAINS),
        "weights": weights,
        "thresholds": thresholds,
        "dataset_sha256": digest,
        "metrics": results,
    }
    path.write_text(json.dumps(model, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_packed(path: Path, weights: list[list[int]], thresholds: list[int], digest: str) -> None:
    flat = [value for row in weights for value in row]
    codes = {0: 0, 1: 1, -1: 2}
    payload = bytearray()
    for start in range(0, len(flat), 4):
        byte = 0
        for lane, value in enumerate(flat[start:start + 4]):
            byte |= codes[value] << (6 - 2 * lane)
        payload.append(byte)
    header = b"ALBR" + struct.pack("<HHBhhh", 1, FEATURE_COUNT, len(DOMAINS), *thresholds)
    blob = header + bytes.fromhex(digest) + payload
    expected = 4 + 2 + 2 + 1 + 6 + 32 + (len(flat) + 3) // 4
    if len(blob) != expected:
        raise ValueError("packed router size mismatch")
    decoded = []
    reverse = {0: 0, 1: 1, 2: -1}
    for byte in payload:
        for shift in (6, 4, 2, 0):
            decoded.append(reverse[(byte >> shift) & 3])
    if decoded[:len(flat)] != flat:
        raise ValueError("packed router round-trip mismatch")
    path.write_bytes(blob)


def ada_row(values: list[int]) -> str:
    chunks = []
    for start in range(0, len(values), 16):
        chunks.append("         " + ", ".join(str(value) for value in values[start:start + 16]))
    return ",\n".join(chunks)


def write_ada(path: Path, weights: list[list[int]], thresholds: list[int], digest: str) -> None:
    rows = []
    for index, values in enumerate(weights, 1):
        rows.append(f"      {index} => (\n{ada_row(values)}\n      )")
    content = (
        "package Router_Weights is\n"
        "   pragma Pure;\n"
        f"   Feature_Count : constant := {FEATURE_COUNT};\n"
        "   subtype Feature_Index is Positive range 1 .. Feature_Count;\n"
        "   subtype Domain_Index is Positive range 1 .. 3;\n"
        "   subtype Ternary_Weight is Integer range -1 .. 1;\n"
        "   type Weight_Row is array (Feature_Index) of Ternary_Weight;\n"
        "   type Weight_Matrix is array (Domain_Index) of Weight_Row;\n"
        "   type Threshold_Array is array (Domain_Index) of Integer;\n"
        "   Weights : constant Weight_Matrix := (\n"
        + ",\n".join(rows)
        + "\n   );\n"
        f"   Thresholds : constant Threshold_Array := ({thresholds[0]}, {thresholds[1]}, {thresholds[2]});\n"
        f"   Dataset_SHA256 : constant String := \"{digest}\";\n"
        "end Router_Weights;\n"
    )
    path.write_text(content, encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    data = root / "data/router"
    paths = [data / name for name in (
        "train.jsonl", "dev.jsonl", "test.jsonl", "unknown.jsonl",
        "generated_train.jsonl", "generated_dev.jsonl", "generated_test.jsonl",
    )]
    train_samples = load(paths[0]) + load(paths[4])
    dev_samples = load(paths[1]) + load(paths[5])
    test_samples = load(paths[2]) + load(paths[6])
    unknown_samples = load(paths[3]) + [sample for sample in load(paths[5]) + load(paths[6]) if not sample.labels]
    dev_samples = [sample for sample in dev_samples if sample.labels]
    test_samples = [sample for sample in test_samples if sample.labels]
    validate_splits({"train": train_samples, "dev": dev_samples, "test": test_samples, "unknown": unknown_samples})
    weights = train(train_samples)
    thresholds = tune_thresholds(train_samples + dev_samples + unknown_samples, weights)
    results = {
        "train": metrics(train_samples, weights, thresholds),
        "dev": metrics(dev_samples, weights, thresholds),
        "test": metrics(test_samples, weights, thresholds),
        "unknown": metrics(unknown_samples, weights, thresholds),
    }
    digest = dataset_hash(paths)
    report = {"dataset_sha256": digest, "thresholds": thresholds, "metrics": results}
    write_model(root / "models/router.trm", weights, thresholds, digest, results)
    write_packed(root / "models/router.albr", weights, thresholds, digest)
    write_ada(root / "src/model/router_weights.ads", weights, thresholds, digest)
    (root / "evaluation/router/latest_metrics.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
