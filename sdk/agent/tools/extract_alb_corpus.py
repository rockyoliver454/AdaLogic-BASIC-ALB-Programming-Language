from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

EXTENSIONS = {".alb", ".albi"}
EXCLUDED_PARTS = {"obj", "_build", "_build_expand", "_build_replay", ".git"}
KEYWORDS = (
    "DECLAREMODULE", "MODULE", "ENDMODULE", "DEFINE", "FUNCTION", "PROCEDURE",
    "IF", "THEN", "ELSE", "FOR", "FOREACH", "WHILE", "REPEAT", "RETURN",
    "REQUIRE", "ENSURE", "STRUCT", "IMPORT", "IMPORT_C", "PRINT", "DRAW",
)


def split_for(digest: str) -> str:
    bucket = int(digest[:8], 16) % 100
    return "train" if bucket < 80 else "dev" if bucket < 90 else "test"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    source = args.source.resolve()
    root = args.root.resolve()
    if not source.is_dir():
        raise ValueError(f"ALB source directory not found: {source}")
    records = []
    seen_hashes = set()
    duplicate_count = 0
    keyword_totals: Counter[str] = Counter()
    for path in sorted(source.rglob("*"), key=lambda value: str(value).lower()):
        if not path.is_file() or path.suffix.lower() not in EXTENSIONS:
            continue
        relative = path.relative_to(source)
        if any(part.lower() in EXCLUDED_PARTS for part in relative.parts):
            continue
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest in seen_hashes:
            duplicate_count += 1
            continue
        seen_hashes.add(digest)
        text = data.decode("utf-8", "replace")
        upper = text.upper()
        counts = {keyword: upper.count(keyword) for keyword in KEYWORDS if keyword in upper}
        keyword_totals.update(counts)
        records.append({
            "path": relative.as_posix(),
            "sha256": digest,
            "bytes": len(data),
            "lines": text.count("\n") + (1 if text else 0),
            "split": split_for(digest),
            "extension": path.suffix.lower(),
            "pipe_concat_count": text.count("|"),
            "amp_concat_count": text.count("&"),
            "keywords": counts,
        })
    output = root / "data/alb/corpus_manifest.jsonl"
    output.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), encoding="utf-8")
    split_counts = Counter(record["split"] for record in records)
    summary = {
        "format": "ALB-CORPUS-MANIFEST",
        "version": 1,
        "source_root": str(source),
        "read_only": True,
        "unique_files": len(records),
        "duplicate_content_skipped": duplicate_count,
        "total_bytes": sum(record["bytes"] for record in records),
        "splits": dict(sorted(split_counts.items())),
        "keyword_totals": dict(sorted(keyword_totals.items())),
        "manifest_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
    }
    (root / "data/alb/corpus_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
