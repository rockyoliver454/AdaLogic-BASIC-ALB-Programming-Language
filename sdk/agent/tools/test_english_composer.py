from __future__ import annotations

import json
import re
from pathlib import Path

from alb_agent import ask
from english_render import compose, grounded_tokens, load_model, signature_of
from train_english_composer import FRAMES, REGISTERS


def expect(value: bool, name: str) -> None:
    if not value:
        raise AssertionError(name)
    print("  [PASS] " + name)


def synthetic_results() -> list[dict[str, object]]:
    return [
        {"command": "ask", "route": {"labels": ["algebra"], "unknown": False},
         "evidence": [{"specialist": "algebra", "success": True, "fields": {"status": "RATIONAL_ROOTS", "first_numerator": "3", "first_denominator": "1", "second_numerator": "2", "second_denominator": "1"}}]},
        {"command": "ask", "route": {"labels": ["algebra"], "unknown": False},
         "evidence": [{"specialist": "algebra", "success": True, "fields": {"status": "LINEAR_EQUATION", "first_numerator": "5", "first_denominator": "1", "second_numerator": "5", "second_denominator": "1"}}]},
        {"command": "ask", "route": {"labels": ["algebra"], "unknown": False},
         "evidence": [{"specialist": "algebra", "success": True, "fields": {"status": "IRRATIONAL_ROOTS", "radical_base": "0", "radical_coefficient": "1", "radicand": "2", "radical_denominator": "1"}}]},
        {"command": "ask", "route": {"labels": ["algebra"], "unknown": False},
         "evidence": [{"specialist": "algebra", "success": True, "fields": {"status": "NO_REAL_ROOTS"}}]},
        {"command": "ask", "route": {"labels": ["algebra"], "unknown": False},
         "evidence": [{"specialist": "algebra", "success": True, "fields": {"status": "NO_SOLUTION"}}]},
        {"command": "ask", "route": {"labels": ["algebra"], "unknown": False},
         "evidence": [{"specialist": "algebra", "success": True, "fields": {"status": "INFINITE_SOLUTIONS"}}]},
        {"command": "ask", "route": {"labels": ["algebra"], "unknown": False},
         "evidence": [{"specialist": "algebra", "success": False, "fields": {"status": "INVALID_EQUATION"}}]},
        {"command": "check", "compiler": {"status": "ready"}, "original_unchanged": True},
        {"command": "check", "compiler": {"status": "failed"}, "diagnostic": {"phase": "parser", "repair": "close_module", "accepted": True}, "original_unchanged": True},
        {"command": "check", "compiler": {"status": "failed"}, "diagnostic": {"phase": "weaver", "repair": "restore_include", "accepted": False}, "original_unchanged": True},
        {"command": "repair", "status": "verified", "attempt_count": 2, "actions": ["fix_keyword"], "validated_output": "staging/abc/validated.alb"},
        {"command": "repair", "status": "partially_improved", "attempt_count": 3, "actions": ["fix_lexical", "fix_type"]},
        {"command": "repair", "status": "abstained", "attempt_count": 1, "actions": []},
        {"command": "ask", "route": {"labels": ["alb"], "unknown": False},
         "evidence": [{"specialist": "alb", "status": "file_required"}]},
        {"command": "ask", "route": {"labels": ["english"], "unknown": False},
         "evidence": [{"specialist": "english", "status": "not_trained"}]},
        {"command": "ask", "route": {"labels": [], "unknown": True}, "evidence": []},
    ]


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    model = load_model(root)
    expect(model is not None, "english composer model artifact loads")

    frames_seen = set()
    for result in synthetic_results():
        composed = compose(root, result)
        expect(composed.get("grounded") is True and not composed.get("abstained"), f"frame grounded for {signature_of(result)[:60]}")
        text = composed["text"]
        expect(len(text) <= 256, "response within bound")
        evidence_blob = json.dumps(result)
        for token in grounded_tokens(text):
            expect(token in evidence_blob, f"token {token} grounded in evidence")
        frames_seen.add(composed["frame"])
    expect(len(frames_seen) >= 14, f"frames covered ({len(frames_seen)}/16)")

    garbage = compose(root, {"command": "ask", "route": {"labels": [], "unknown": True}, "evidence": []})
    expect(garbage.get("frame") in FRAMES, "unknown request maps to a defined frame")

    result = synthetic_results()[0]
    first = compose(root, result)
    second = compose(root, result)
    expect(first == second, "composition is deterministic")

    for register, phrase in (("terse", "just the answer: solve 2x + 3 = 7"),
                             ("explanatory", "explain step by step how to solve 2x + 3 = 7"),
                             ("plain", "solve 2x + 3 = 7")):
        outcome = compose(root, result, phrase)
        expect(outcome.get("register") in REGISTERS, f"register classified for {register} phrasing")

    real = ask(root, "Solve 3x + 4 = 19")
    expect(real["english"].get("grounded") and "x = 5" in real["english"]["text"], "live algebra response grounded")
    unknown = ask(root, "Diagnose this diesel engine vibration")
    expect(unknown["english"].get("frame") in ("unknown_request", "no_evidence"), "unknown request refuses politely")

    print("ENGLISH COMPOSER PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
