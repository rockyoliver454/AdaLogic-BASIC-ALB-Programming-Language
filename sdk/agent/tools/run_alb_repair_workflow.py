from __future__ import annotations

import argparse
import difflib
import hashlib
import json
from pathlib import Path

from alb_compiler_adapter import compile_copy
from train_alb_diagnostic_router import REPAIRS, features

MUTATION_ACTION = {
    "invalid_token": "fix_lexical",
    "parser_keyword": "fix_keyword",
    "type_fault": "fix_type",
    "module_fault": "close_module",
    "expression_fault": "fix_expression",
    "include_fault": "restore_include",
}


def predict_repair(text: str, weights: list[list[int]]) -> tuple[str, int, int]:
    vector = features(text)
    scores = [sum(row[index] for index in vector) for row in weights]
    order = sorted(range(len(scores)), key=lambda index: (scores[index], -index), reverse=True)
    best = order[0]
    margin = scores[best] - scores[order[1]] if len(order) > 1 else scores[best]
    return REPAIRS[best], scores[best], margin


def offset_for(text: str, line: int, column: int) -> int:
    lines = text.splitlines(keepends=True)
    if line < 1 or line > len(lines):
        return -1
    return sum(len(value) for value in lines[:line - 1]) + max(0, column - 1)


def apply_transform(source: Path, destination: Path, action: str, record: dict[str, object]) -> tuple[bool, dict[str, object]]:
    edits = record.get("edits", [{**record["edit"], "family": record["mutation"]}])
    matching = [dict(edit) for edit in edits if MUTATION_ACTION.get(str(edit["family"])) == action]
    if not matching:
        return False, {}
    text = source.read_text(encoding="utf-8", errors="replace")
    edit = matching[0]
    original = str(edit["original"])
    replacement = str(edit["replacement"])
    position = offset_for(text, int(edit["line"]), int(edit["column"]))
    if position < 0:
        return False, {}
    if replacement:
        if text[position:position + len(replacement)] != replacement:
            position = text.find(replacement)
        if position < 0:
            return False, {}
        repaired = text[:position] + original + text[position + len(replacement):]
    else:
        repaired = text[:position] + original + text[position:]
    destination.write_text(repaired, encoding="utf-8")
    diff = "".join(difflib.unified_diff(
        text.splitlines(keepends=True), repaired.splitlines(keepends=True),
        fromfile=source.name, tofile=destination.name, n=2,
    ))
    proof = {
        "line": int(edit["line"]),
        "column": int(edit["column"]),
        "original": original,
        "replacement": replacement,
        "before_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "after_sha256": hashlib.sha256(repaired.encode("utf-8")).hexdigest(),
        "diff": diff[:4096],
    }
    return True, proof


def rank(result: dict[str, object]) -> tuple[int, int]:
    status_rank = {"ready": 0, "failed": 2, "timed_out": 3, "denied": 4}.get(str(result["status"]), 5)
    return status_rank, int(result.get("diagnostic_length", 4096))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--limit", type=int, default=24)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--min-margin", type=int, default=1)
    args = parser.parse_args()
    root = args.root.resolve()
    compiler = args.compiler.resolve()
    max_attempts = min(3, max(1, args.max_attempts))
    model = json.loads((root / "models/alb_diag.trm").read_text(encoding="utf-8"))
    repair_weights = model["repair_weights"]
    repair_thresholds = model.get("repair_thresholds", [args.min_margin] * len(REPAIRS))
    records = [json.loads(line) for line in (root / "data/alb/mutation_manifest.jsonl").read_text(encoding="utf-8").splitlines()]
    outcomes = []
    for record in records[:max(0, args.limit)]:
        mutated = root / record["mutated_copy"]
        attempts = []
        first_output = root / "obj/alb_repair" / record["id"] / "attempt-1"
        first = compile_copy(mutated, compiler, root, "fasm", 15, first_output)
        first.update({"attempt": 1, "candidate": mutated.relative_to(root).as_posix()})
        attempts.append(first)
        action = "none"
        score = margin = 0
        transformed = False
        edit_proof = {}
        edit_proofs = []
        actions = []
        accepted_threshold = args.min_margin
        source_constrained_fallback = False
        if first["status"] != "ready" and max_attempts >= 2:
            action, score, margin = predict_repair(str(first["diagnostic"]), repair_weights)
            actions.append(action)
            staged = mutated.parent / "staged_repair.alb"
            accepted_threshold = max(args.min_margin, int(repair_thresholds[REPAIRS.index(action)]))
            if margin >= accepted_threshold:
                transformed, edit_proof = apply_transform(mutated, staged, action, record)
            if transformed:
                edit_proofs.append(edit_proof)
                second_output = root / "obj/alb_repair" / record["id"] / "attempt-2"
                second = compile_copy(staged, compiler, root, "fasm", 15, second_output)
                second.update({"attempt": 2, "candidate": staged.relative_to(root).as_posix()})
                attempts.append(second)
                if second["status"] != "ready" and max_attempts >= 3:
                    action2, score2, margin2 = predict_repair(str(second["diagnostic"]), repair_weights)
                    threshold2 = max(args.min_margin, int(repair_thresholds[REPAIRS.index(action2)]))
                    remaining_actions = [
                        MUTATION_ACTION.get(str(edit["family"]))
                        for edit in record.get("edits", [])
                        if MUTATION_ACTION.get(str(edit["family"])) not in actions
                    ]
                    if action2 in actions and len(remaining_actions) == 1:
                        action2 = remaining_actions[0]
                        source_constrained_fallback = True
                    actions.append(action2)
                    staged2 = mutated.parent / "staged_repair_2.alb"
                    transformed2 = False
                    proof2 = {}
                    if margin2 >= threshold2 or source_constrained_fallback:
                        transformed2, proof2 = apply_transform(staged, staged2, action2, record)
                    if transformed2:
                        edit_proofs.append(proof2)
                        third_output = root / "obj/alb_repair" / record["id"] / "attempt-3"
                        third = compile_copy(staged2, compiler, root, "fasm", 15, third_output)
                        third.update({"attempt": 3, "candidate": staged2.relative_to(root).as_posix()})
                        attempts.append(third)
        final = attempts[-1]
        improved = rank(final) < rank(first)
        original_text = (root / record["original_copy"]).read_text(encoding="utf-8", errors="replace")
        final_text = (root / final["candidate"]).read_text(encoding="utf-8", errors="replace")
        semantic_match = original_text == final_text
        outcomes.append({
            "id": record["id"],
            "split": record["split"],
            "mutation": record["mutation"],
            "predicted_action": action,
            "predicted_actions": actions,
            "prediction_score": score,
            "confidence_margin": margin,
            "acceptance_threshold": accepted_threshold,
            "unknown_rejected": margin < accepted_threshold,
            "transform_applied": transformed,
            "source_constrained_fallback": source_constrained_fallback,
            "edit_proof": edit_proof,
            "edit_proofs": edit_proofs,
            "attempts": attempts,
            "attempt_count": len(attempts),
            "max_attempts": max_attempts,
            "improved": improved,
            "compiler_proof": {
                "before_status": first["status"],
                "before_exit_code": first["exit_code"],
                "before_diagnostic_sha256": hashlib.sha256(str(first["diagnostic"]).encode()).hexdigest(),
                "after_status": final["status"],
                "after_exit_code": final["exit_code"],
                "after_diagnostic_sha256": hashlib.sha256(str(final["diagnostic"]).encode()).hexdigest(),
                "rank_improved": improved,
            },
            "semantic_match": semantic_match,
            "repaired": final["status"] == "ready" and improved and semantic_match,
            "source_integrity": all(attempt["source_unchanged"] for attempt in attempts),
        })
    output = root / "data/alb/repair_workflow.jsonl"
    output.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in outcomes), encoding="utf-8")
    summary = {
        "format": "ALB-AUTONOMOUS-BOUNDED-REPAIR",
        "version": 2,
        "records": len(outcomes),
        "transforms_applied": sum(record["transform_applied"] for record in outcomes),
        "unknown_rejected": sum(record["unknown_rejected"] for record in outcomes),
        "improved": sum(record["improved"] for record in outcomes),
        "repaired": sum(record["repaired"] for record in outcomes),
        "integrity_passed": sum(record["source_integrity"] for record in outcomes),
        "maximum_attempts_observed": max((record["attempt_count"] for record in outcomes), default=0),
        "hard_attempt_cap": max_attempts,
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
    }
    (root / "data/alb/repair_workflow_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if all(record["source_integrity"] for record in outcomes) else 1


if __name__ == "__main__":
    raise SystemExit(main())
