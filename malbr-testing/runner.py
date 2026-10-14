#!/usr/bin/env python3
"""MALBR test runner for the malbr-testing Rosetta-style suite.

Usage (from repo root):
    python malbr-testing/runner.py [--only n]

The runner expects:
  - bin/malbr.exe built
  - Rust GNU toolchain + MinGW gcc on PATH, or set via RUST_BIN and MINGW_BIN env vars.

Each test is an .alb file in this directory.  If a sibling .expected file exists,
stdout is compared against it.  Otherwise the test passes by compiling and
exiting with status 0.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MALBR = ROOT / "bin" / "malbr.exe"
TEST_DIR = ROOT / "malbr-testing"


def discover_tests():
    tests = []
    for p in sorted(TEST_DIR.glob("*.alb")):
        m = re.match(r"^(\d{3})_(.+?)\.alb$", p.name)
        if not m:
            continue
        num = int(m.group(1))
        name = m.group(2)
        expected = p.with_suffix(".expected")
        tests.append((num, name, p, expected if expected.exists() else None))
    return tests


def run_one(alb_path, expected_path):
    stem = alb_path.stem
    out_dir = ROOT / f"micro_{stem}"
    exe = out_dir / f"{stem}.exe"

    # Clean previous run.
    if out_dir.exists():
        import shutil
        shutil.rmtree(out_dir)

    env = os.environ.copy()
    env["PATH"] = ";".join(
        [
            env.get("RUST_BIN", str(ROOT / "deps" / "rust" / "bin")),
            env.get("MINGW_BIN", ""),
            env.get("PATH", ""),
        ]
    )

    # Compile.
    build = subprocess.run(
        [str(MALBR), "--build", str(alb_path)],
        cwd=str(ROOT),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if build.returncode != 0:
        return "EMIT/BUILD", build.stdout, None

    # Run.
    run = subprocess.run(
        [str(exe)],
        cwd=str(out_dir),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=10,
    )
    stdout = run.stdout.replace("\r\n", "\n")
    if run.returncode != 0:
        return "RUN", build.stdout + stdout, run.returncode

    if expected_path is not None:
        expected = expected_path.read_text(encoding="utf-8").replace("\r\n", "\n")
        if stdout.strip() != expected.strip():
            return "OUTPUT", stdout, expected

    return "PASS", stdout, run.returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", type=int, help="Run a single test by number")
    args = parser.parse_args()

    if not MALBR.exists():
        print(f"error: {MALBR} not found; build malbr first", file=sys.stderr)
        sys.exit(1)

    tests = discover_tests()
    if args.only is not None:
        tests = [t for t in tests if t[0] == args.only]
        if not tests:
            print(f"error: no test numbered {args.only}", file=sys.stderr)
            sys.exit(1)

    passed = failed = 0
    for num, name, alb, expected in tests:
        status, detail, extra = run_one(alb, expected)
        label = f"{num:03d} {name}"
        if status == "PASS":
            print(f"PASS  {label}")
            passed += 1
        elif status == "OUTPUT":
            print(f"FAIL  {label}  expected output mismatch")
            print("--- expected ---")
            print(extra)
            print("--- actual ---")
            print(detail)
            failed += 1
        else:
            print(f"FAIL  {label}  {status}")
            print(detail)
            failed += 1

    print(f"\n{passed}/{passed+failed} passed")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
