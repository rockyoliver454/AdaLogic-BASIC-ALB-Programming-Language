from __future__ import annotations

import hashlib
import json
import zipfile
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    latest = json.loads((root / "release/latest.json").read_text(encoding="utf-8"))
    archive = root / latest["archive"]
    if hashlib.sha256(archive.read_bytes()).hexdigest() != latest["archive_sha256"]:
        raise ValueError("release archive hash mismatch")
    with zipfile.ZipFile(archive, "r") as bundle:
        manifest = json.loads(bundle.read("RELEASE_MANIFEST.json"))
        for entry in manifest["files"]:
            data = bundle.read(entry["path"])
            if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise ValueError(f"release member mismatch: {entry['path']}")
    print(f"PATH B RELEASE PASS: {manifest['release_id']}, {len(manifest['files'])} files, {archive.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
