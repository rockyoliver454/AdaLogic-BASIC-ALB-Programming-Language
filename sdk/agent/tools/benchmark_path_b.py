from __future__ import annotations

import json
import platform
import statistics
import time
import tracemalloc
from pathlib import Path

import train_alb_diagnostic_router as diagnostic
import train_router


def benchmark(iterations: int, operation) -> dict[str, float]:
    samples = []
    tracemalloc.start()
    start = time.perf_counter()
    for _ in range(iterations):
        before = time.perf_counter()
        operation()
        samples.append((time.perf_counter() - before) * 1_000_000)
    elapsed = time.perf_counter() - start
    current, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    ordered = sorted(samples)
    return {
        "iterations": iterations,
        "elapsed_seconds": elapsed,
        "operations_per_second": iterations / elapsed,
        "mean_microseconds": statistics.mean(samples),
        "p50_microseconds": ordered[len(ordered) // 2],
        "p95_microseconds": ordered[int(len(ordered) * 0.95)],
        "peak_traced_bytes": peak,
    }


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    router = json.loads((root / "models/router.trm").read_text(encoding="utf-8"))
    diag = json.loads((root / "models/alb_diag.trm").read_text(encoding="utf-8"))
    request = "Explain and implement an ALB routine that solves 10x-5=25"
    diagnostic_text = "Unexpected Token Encountered ERR_PARSE_EXPECTED_VALUE CONTROLLED_INVALID_TOKEN"
    report = {
        "format": "PATH-B-CPU-BENCHMARK",
        "version": 1,
        "platform": platform.platform(),
        "processor": platform.processor(),
        "request_router": benchmark(10_000, lambda: train_router.predict(request, router["weights"], router["thresholds"])),
        "diagnostic_phase": benchmark(10_000, lambda: diagnostic.prediction(diagnostic_text, diag["phase_weights"], tuple(diag["phases"]))),
        "diagnostic_repair": benchmark(10_000, lambda: diagnostic.prediction(diagnostic_text, diag["repair_weights"], tuple(diag["repairs"]))),
        "artifact_sizes": {
            "router_albr": (root / "models/router.albr").stat().st_size,
            "diagnostic_albd": (root / "models/alb_diag.albd").stat().st_size,
            "router_audit_json": (root / "models/router.trm").stat().st_size,
            "diagnostic_audit_json": (root / "models/alb_diag.trm").stat().st_size,
        },
    }
    (root / "evaluation/path_b_benchmarks.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
