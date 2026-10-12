from __future__ import annotations

import json
import struct
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    model = json.loads((root / "models/english_comp.trm").read_text(encoding="utf-8"))
    blob = (root / "models/english_comp.alen").read_bytes()
    if blob[:4] != b"ALEN":
        raise ValueError("bad english composer magic")
    version, feature_count, frame_count, register_count = struct.unpack("<HHBB", blob[4:10])
    if version != model["version"] or feature_count != model["feature_count"]:
        raise ValueError("english composer header mismatch")
    if frame_count != len(model["frames"]) or register_count != len(model["registers"]):
        raise ValueError("english composer head counts mismatch")
    offset = 10
    if list(blob[offset:offset + frame_count]) != model["frame_thresholds"]:
        raise ValueError("frame threshold mismatch")
    offset += frame_count
    if list(blob[offset:offset + register_count]) != model["register_thresholds"]:
        raise ValueError("register threshold mismatch")
    offset += register_count
    if blob[offset:offset + 32].hex() != model["dataset_sha256"]:
        raise ValueError("english dataset identity mismatch")
    offset += 32
    reverse = {0: 0, 1: 1, 2: -1}
    decoded = []
    for byte in blob[offset:]:
        for shift in (6, 4, 2, 0):
            code = (byte >> shift) & 3
            if code not in reverse:
                raise ValueError("reserved ternary lane")
            decoded.append(reverse[code])
    expected = [value for matrix in (model["frame_weights"], model["register_weights"]) for row in matrix for value in row]
    if decoded[:len(expected)] != expected:
        raise ValueError("english weight mismatch")
    if len(blob) != offset + (len(expected) + 3) // 4:
        raise ValueError("english packed size mismatch")
    print(f"ENGLISH ARTIFACT PASS: {len(expected)} weights, {len(blob)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
