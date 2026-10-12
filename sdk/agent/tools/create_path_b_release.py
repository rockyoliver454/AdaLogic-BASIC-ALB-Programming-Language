from __future__ import annotations

import hashlib
import json
import zipfile
from pathlib import Path

FILES = (
    "models/router.albr",
    "models/alb_diag.albd",
    "models/router.trm",
    "models/alb_diag.trm",
    "registry/router_contract.json",
    "evaluation/router/latest_metrics.json",
    "evaluation/alb_diagnostic_metrics.json",
    "evaluation/repair_semantics_summary.json",
    "evaluation/path_b_promotion.json",
    "evaluation/english_composer_metrics.json",
    "models/english_comp.trm",
    "models/english_comp.alen",
    "tools/english_render.py",
    "tools/train_english_composer.py",
    "tools/generate_english_corpus.py",
    "tools/verify_english_artifact.py",
    "tools/test_english_composer.py",
    "src/model/english_composer_model.ads",
    "src/model/english_composer_model.adb",
    "src/model/english_composer_weights.ads",
    "test/native_english_composer_battery.adb",
    "models/alb_seq.albm",
    "models/alb_seq_metrics.json",
    "tools/train_sequence.py",
    "src/model/seq_golden.ads",
    "test/seq_battery.adb",
    "data/alb/corpus_summary.json",
    "data/alb/compiler_probe_summary.json",
    "data/alb/mutation_summary.json",
    "data/alb/mutation_triple_summary.json",
    "data/alb/repair_workflow_summary.json",
    "bin/alb_agent.cmd",
    "bin/alb_agent",
    "tools/alb_agent.py",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    entries = []
    for relative in FILES:
        path = root / relative
        if not path.is_file():
            raise ValueError(f"missing release input: {relative}")
        entries.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest(path)})
    identity = hashlib.sha256("".join(entry["path"] + entry["sha256"] for entry in entries).encode()).hexdigest()
    version = "path-b-" + identity[:12]
    manifest = {
        "format": "AI-EXPERIMENT-RELEASE",
        "version": 1,
        "release_id": version,
        "content_sha256": identity,
        "files": entries,
        "runtime": {"primary": "cpu-ternary", "gpu_required": False, "external_training_gpu": False},
        "source_policy": "ALB read-only; staged outputs only",
    }
    versions = root / "registry/versions"
    versions.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    (root / "registry/path_b_manifest.json").write_text(encoded, encoding="utf-8")
    versioned = versions / (version + ".json")
    if versioned.exists() and versioned.read_text(encoding="utf-8") != encoded:
        raise ValueError("immutable release manifest collision")
    versioned.write_text(encoded, encoding="utf-8")
    release_dir = root / "release"
    release_dir.mkdir(parents=True, exist_ok=True)
    archive = release_dir / (version + ".zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for relative in FILES:
            info = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            bundle.writestr(info, (root / relative).read_bytes())
        info = zipfile.ZipInfo("RELEASE_MANIFEST.json", date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        bundle.writestr(info, encoded.encode())
    result = {"release_id": version, "archive": archive.relative_to(root).as_posix(), "archive_bytes": archive.stat().st_size, "archive_sha256": digest(archive), "files": len(FILES)}
    (root / "release/latest.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
