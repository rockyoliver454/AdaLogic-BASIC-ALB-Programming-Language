"""Payload probe (pillar 4 host side of the air gap).

Reads a sealed token payload dropped by the SPARK core, validates it with
the same rules as Payload_Bridge (length cap, byte range), decodes it to
bytes, stages it under <root>/staging/ (inside the adapter's trust root),
and runs it through alb_compiler_adapter.compile_copy.

Exit codes: 0 = payload valid, adapter returned a verdict (ready/failed);
1 = payload malformed (rejected before touching disk); 2 = toolchain
unavailable (compiler binary missing).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from alb_compiler_adapter import compile_copy

MAX_PAYLOAD = 128


def load_payload(path: Path) -> tuple[list[int], int]:
    data = json.loads(path.read_text(encoding="utf-8"))
    tokens = data["tokens"]
    length = int(data["length"])
    check = int(data["check"])
    if not isinstance(tokens, list) or len(tokens) != length:
        raise ValueError("length does not match token vector")
    if not 0 <= length <= MAX_PAYLOAD:
        raise ValueError("length outside 0..128")
    for token in tokens:
        if not isinstance(token, bool | int) or isinstance(token, bool):
            raise ValueError("non-integer token")
        if not 0 <= int(token) <= 255:
            raise ValueError(f"token {token!r} outside byte range")
    total = sum(int(token) * (index + 1) for index, token in enumerate(tokens))
    if total != check:
        raise ValueError("checksum tripwire fired")
    return [int(token) for token in tokens], length


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("payload", type=Path)
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--backend", choices=("fasm", "c"), default="fasm")
    parser.add_argument("--timeout", type=int, default=15)
    args = parser.parse_args()
    root = args.root.resolve()

    try:
        tokens, _ = load_payload(args.payload)
    except OSError as error:
        print(json.dumps({"status": "rejected", "reason": f"unreadable payload: {error}"}))
        return 1
    except (ValueError, KeyError, json.JSONDecodeError) as error:
        print(json.dumps({"status": "rejected", "reason": str(error)}))
        return 1

    staging = root / "staging"
    staging.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(bytes(tokens)).hexdigest()[:16]
    candidate = staging / f"payload_{digest}.alb"
    candidate.write_bytes(bytes(tokens))

    try:
        result = compile_copy(candidate, args.compiler.resolve(), root, args.backend, args.timeout, staging / f"payload_{digest}")
    except OSError as error:
        print(json.dumps({"status": "unavailable", "reason": f"{type(error).__name__}: {error}"}))
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
