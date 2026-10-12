from __future__ import annotations

import json
import struct
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    model = json.loads((root / "models/router.trm").read_text(encoding="utf-8"))
    blob = (root / "models/router.albr").read_bytes()
    if blob[:4] != b"ALBR":
        raise ValueError("bad router magic")
    version, feature_count, domain_count, *thresholds = struct.unpack("<HHBhhh", blob[4:15])
    if version != model["version"] or feature_count != model["feature_count"]:
        raise ValueError("router header mismatch")
    if domain_count != len(model["domains"]) or thresholds != model["thresholds"]:
        raise ValueError("router domain metadata mismatch")
    if blob[15:47].hex() != model["dataset_sha256"]:
        raise ValueError("router dataset identity mismatch")
    reverse = {0: 0, 1: 1, 2: -1}
    decoded = []
    for byte in blob[47:]:
        for shift in (6, 4, 2, 0):
            code = (byte >> shift) & 3
            if code not in reverse:
                raise ValueError("reserved ternary lane")
            decoded.append(reverse[code])
    expected = [value for row in model["weights"] for value in row]
    if decoded[:len(expected)] != expected:
        raise ValueError("router weight mismatch")
    if len(blob) != 47 + (len(expected) + 3) // 4:
        raise ValueError("router packed size mismatch")
    print(f"ROUTER ARTIFACT PASS: {len(expected)} weights, {len(blob)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
