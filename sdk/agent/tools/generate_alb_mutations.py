from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from collections import Counter
from pathlib import Path


MUTATION_FAMILIES = (
    "invalid_token",
    "parser_keyword",
    "type_fault",
    "module_fault",
    "expression_fault",
    "include_fault",
)


def coordinates(text: str, offset: int) -> tuple[int, int]:
    return text.count("\n", 0, offset) + 1, offset - text.rfind("\n", 0, offset)


def replace_once(text: str, original: str, replacement: str, family: str) -> tuple[str, str, dict[str, object]] | None:
    offset = text.upper().find(original.upper())
    if offset < 0:
        return None
    line, column = coordinates(text, offset)
    mutated = text[:offset] + replacement + text[offset + len(original):]
    return mutated, family, {"line": line, "column": column, "original": text[offset:offset + len(original)], "replacement": replacement, "mode": "replace"}


def prepend(text: str, value: str, family: str) -> tuple[str, str, dict[str, object]]:
    return value + text, family, {"line": 1, "column": 1, "original": "", "replacement": value, "mode": "insert"}


def mutate(text: str, family: str) -> tuple[str, str, dict[str, object]]:
    if family == "invalid_token":
        return prepend(text, "@@@ CONTROLLED_INVALID_TOKEN\n", family)
    if family == "parser_keyword":
        result = replace_once(text, "THEN", "TH_N", family)
        return result or prepend(text, "TH_N CONTROLLED_PARSER_KEYWORD\n", family)
    if family == "type_fault":
        for type_name in ("I32", "I16", "I8", "I64"):
            result = replace_once(text, type_name, "TYPE_DOES_NOT_EXIST", family)
            if result:
                return result
        return prepend(text, "DEFINE CONTROLLED_BAD_TYPE AS TYPE_DOES_NOT_EXIST\n", family)
    if family == "module_fault":
        upper = text.upper()
        offset = upper.rfind("ENDMODULE")
        if offset >= 0:
            line, column = coordinates(text, offset)
            original = text[offset:offset + len("ENDMODULE")]
            return text[:offset] + text[offset + len("ENDMODULE"):], family, {"line": line, "column": column, "original": original, "replacement": "", "mode": "delete"}
        return prepend(text, "MODULE CONTROLLED_UNCLOSED_MODULE\n", family)
    if family == "expression_fault":
        match = re.search(r"=\s*[^\r\n]+", text)
        if match:
            line, column = coordinates(text, match.start())
            original = match.group(0)
            replacement = "= (1 + )"
            return text[:match.start()] + replacement + text[match.end():], family, {"line": line, "column": column, "original": original, "replacement": replacement, "mode": "replace"}
        return prepend(text, "LET CONTROLLED_EXPR AS I32 = (1 + )\n", family)
    include = INCLUDE_PATTERN.search(text)
    if include:
        original = include.group(1)
        offset = include.start(1)
        line, column = coordinates(text, offset)
        replacement = "__CONTROLLED_MISSING_INCLUDE__.albi"
        return text[:offset] + replacement + text[offset + len(original):], family, {"line": line, "column": column, "original": original, "replacement": replacement, "mode": "replace"}
    return prepend(text, 'INCLUDE "__CONTROLLED_MISSING_INCLUDE__.albi"\n', family)


INCLUDE_PATTERN = re.compile(r'\bINCLUDE\s+"([^"]+)"', re.IGNORECASE)


def copy_include_context(source_path: Path, unit: Path, source_text: str) -> tuple[int, list[dict[str, str]]]:
    base = source_path.parent.resolve()
    pending = [(base, name) for name in INCLUDE_PATTERN.findall(source_text)]
    visited = set()
    manifest = []
    for step in range(64):
        if step >= len(pending):
            break
        parent, name = pending[step]
        target = (parent / name).resolve()
        if target in visited or not target.is_file():
            continue
        visited.add(target)
        try:
            relative = target.relative_to(base)
        except ValueError:
            relative = Path(target.name)
        destination = unit / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, destination)
        data = target.read_bytes()
        manifest.append({"path": relative.as_posix(), "sha256": hashlib.sha256(data).hexdigest()})
        text = data.decode("utf-8", "replace")
        pending.extend((target.parent, child) for child in INCLUDE_PATTERN.findall(text))
    return len(manifest), manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--limit", type=int, default=24)
    args = parser.parse_args()
    root = args.root.resolve()
    source = args.source.resolve()
    probes = [json.loads(line) for line in (root / "data/alb/compiler_probes.jsonl").read_text(encoding="utf-8").splitlines()]
    by_source = {}
    for probe in probes:
        path = source / Path(probe["source_path"])
        if probe["success"] and path.is_file() and path.stat().st_size >= 10:
            by_source.setdefault(probe["source_sha256"], probe)
    candidates = []
    per_split = max(1, (max(0, args.limit) + 2) // 3)
    for split in ("train", "dev", "test"):
        selected = sorted(
            (probe for probe in by_source.values() if probe["split"] == split),
            key=lambda probe: probe["source_sha256"],
        )[:per_split]
        candidates.extend(selected)
    candidates = candidates[:max(0, args.limit)]
    mutation_root = root / "data/alb/mutations"
    mutation_root.mkdir(parents=True, exist_ok=True)
    records = []
    for probe in candidates:
        source_path = source / Path(probe["source_path"])
        original_bytes = source_path.read_bytes()
        if hashlib.sha256(original_bytes).hexdigest() != probe["source_sha256"]:
            raise ValueError(f"source identity drift: {source_path}")
        original = original_bytes.decode("utf-8", "replace")
        for family in MUTATION_FAMILIES:
            mutated, mutation, edit = mutate(original, family)
            unit = mutation_root / probe["source_sha256"][:16] / family
            unit.mkdir(parents=True, exist_ok=True)
            context_files, include_manifest = copy_include_context(source_path, unit, original)
            original_copy = unit / "original.alb"
            mutated_copy = unit / "mutated.alb"
            repaired_copy = unit / "repaired.alb"
            original_copy.write_text(original, encoding="utf-8")
            mutated_copy.write_text(mutated, encoding="utf-8")
            repaired_copy.write_text(original, encoding="utf-8")
            records.append({
                "id": "alb-mutation-" + probe["source_sha256"][:16] + "-" + family,
                "split": probe["split"],
                "source_path": probe["source_path"],
                "source_sha256": probe["source_sha256"],
                "original_copy": original_copy.relative_to(root).as_posix(),
                "mutated_copy": mutated_copy.relative_to(root).as_posix(),
                "repaired_copy": repaired_copy.relative_to(root).as_posix(),
                "mutation": mutation,
                "edit": edit,
                "edits": [{**edit, "family": mutation}],
                "include_context_files": context_files,
                "include_manifest": include_manifest,
                "mutated_sha256": hashlib.sha256(mutated_copy.read_bytes()).hexdigest(),
                "repair_sha256": hashlib.sha256(repaired_copy.read_bytes()).hexdigest(),
                "source_modified": hashlib.sha256(source_path.read_bytes()).hexdigest() != probe["source_sha256"],
            })
    for probe in candidates:
        source_path = source / Path(probe["source_path"])
        original = source_path.read_bytes().decode("utf-8", "replace")
        first_text, first_family, first_edit = mutate(original, "invalid_token")
        mutated, second_family, second_edit = mutate(first_text, "type_fault")
        unit = mutation_root / probe["source_sha256"][:16] / "double_fault"
        unit.mkdir(parents=True, exist_ok=True)
        context_files, include_manifest = copy_include_context(source_path, unit, original)
        original_copy = unit / "original.alb"
        mutated_copy = unit / "mutated.alb"
        repaired_copy = unit / "repaired.alb"
        original_copy.write_text(original, encoding="utf-8")
        mutated_copy.write_text(mutated, encoding="utf-8")
        repaired_copy.write_text(original, encoding="utf-8")
        records.append({
            "id": "alb-mutation-" + probe["source_sha256"][:16] + "-double_fault",
            "split": probe["split"],
            "source_path": probe["source_path"],
            "source_sha256": probe["source_sha256"],
            "original_copy": original_copy.relative_to(root).as_posix(),
            "mutated_copy": mutated_copy.relative_to(root).as_posix(),
            "repaired_copy": repaired_copy.relative_to(root).as_posix(),
            "mutation": "double_fault",
            "edit": first_edit,
            "edits": [{**first_edit, "family": first_family}, {**second_edit, "family": second_family}],
            "include_context_files": context_files,
            "include_manifest": include_manifest,
            "mutated_sha256": hashlib.sha256(mutated_copy.read_bytes()).hexdigest(),
            "repair_sha256": hashlib.sha256(repaired_copy.read_bytes()).hexdigest(),
            "source_modified": hashlib.sha256(source_path.read_bytes()).hexdigest() != probe["source_sha256"],
        })
    if any(record["source_modified"] for record in records):
        raise RuntimeError("ALB source mutation detected")
    manifest = root / "data/alb/mutation_manifest.jsonl"
    manifest.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), encoding="utf-8")
    summary = {
        "format": "ALB-CONTROLLED-MUTATIONS",
        "version": 1,
        "records": len(records),
        "splits": dict(sorted(Counter(record["split"] for record in records).items())),
        "mutations": dict(sorted(Counter(record["mutation"] for record in records).items())),
        "source_read_only": True,
        "sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
    }
    (root / "data/alb/mutation_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
