from __future__ import annotations

import json
from pathlib import Path

SPLITS = ("train", "dev", "test")

PHASES = ("lexer", "parser", "weaver", "emitter", "build")
REPAIRS = ("fix_lexical", "fix_keyword", "fix_type", "close_module", "fix_expression", "restore_include")
BACKENDS = ("fasm", "c")

FRAME_SIGNATURES = {
    "answer_linear": [
        "cmd_ask route_algebra ev_algebra_ok status_linear_equation {extra}",
        "cmd_ask route_english route_algebra ev_algebra_ok status_linear_equation pending_english {extra}",
    ],
    "answer_roots": [
        "cmd_ask route_algebra ev_algebra_ok status_rational_roots {extra}",
        "cmd_ask route_english route_algebra ev_algebra_ok status_rational_roots pending_english {extra}",
    ],
    "answer_symbolic": [
        "cmd_ask route_algebra ev_algebra_ok status_irrational_roots {extra}",
        "cmd_ask route_english route_algebra ev_algebra_ok status_irrational_roots pending_english {extra}",
    ],
    "answer_no_real": [
        "cmd_ask route_algebra ev_algebra_ok status_no_real_roots {extra}",
        "cmd_ask route_english route_algebra ev_algebra_ok status_no_real_roots pending_english {extra}",
    ],
    "answer_no_solution": [
        "cmd_ask route_algebra ev_algebra_ok status_no_solution {extra}",
    ],
    "answer_infinite": [
        "cmd_ask route_algebra ev_algebra_ok status_infinite_solutions {extra}",
    ],
    "answer_invalid": [
        "cmd_ask route_algebra ev_algebra_bad status_invalid_equation {extra}",
        "cmd_ask route_algebra ev_algebra_bad status_failed {extra}",
    ],
    "check_pass": [
        "cmd_check compiler_ready backend_{backend} {extra}",
        "cmd_check compiler_ready backend_{backend} src_{src} {extra}",
    ],
    "check_fail": [
        "cmd_check compiler_failed backend_{backend} phase_{phase} repair_{repair} {extra}",
        "cmd_check compiler_failed backend_{backend} phase_{phase} repair_{repair} abstained {extra}",
    ],
    "repair_verified": [
        "cmd_repair status_verified attempts_{n} action_{repair} {extra}",
        "cmd_repair status_verified attempts_{n} action_{repair} action_{repair2} {extra}",
    ],
    "repair_partial": [
        "cmd_repair status_partially_improved attempts_{n} action_{repair} {extra}",
    ],
    "repair_abstained": [
        "cmd_repair status_abstained attempts_{n} {extra}",
        "cmd_repair status_abstained attempts_{n} low_confidence {extra}",
    ],
    "alb_file_required": [
        "cmd_ask route_alb ev_alb_pending file_required {extra}",
        "cmd_ask route_english route_alb ev_alb_pending file_required pending_english {extra}",
    ],
    "english_pending": [
        "cmd_ask route_english ev_english_pending {extra}",
    ],
    "unknown_request": [
        "cmd_ask route_unknown {extra}",
        "cmd_ask route_unknown no_evidence {extra}",
    ],
    "no_evidence": [
        "cmd_ask route_{route} ev_none {extra}",
    ],
}

DISTRACTORS = (
    "src_{src}", "exit_{exit}", "timeout_15", "diff_bytes_{diff}", "host_local",
    "cap_3", "policy_readonly", "sha_{sha}", "attempt_cap_3", "margin_{margin}",
)

REGISTER_TEMPLATES = {
    "terse": [
        "just the answer: solve {eq}",
        "tldr {eq} = ?",
        "quick answer for {eq} problem {n}",
        "{eq} answer only please {n}",
        "solve {eq} no explanation needed case {n}",
        "short version only: {eq} item {n}",
        "briefly solve {eq} task {n}",
        "one line answer for {eq} row {n}",
        "fast result for {eq} entry {n}",
        "skip the details, just solve {eq} item {n}",
    ],
    "plain": [
        "solve {eq} for item {n}",
        "check the source file for case {n}",
        "what is the solution to {eq} number {n}",
        "repair the program for scenario {n}",
        "solve the equation {eq} test {n}",
        "run the compiler on the source for row {n}",
        "evaluate {eq} entry {n}",
        "handle request {n}: solve {eq}",
        "compile this program for item {n}",
        "what does {eq} evaluate to, record {n}",
    ],
    "explanatory": [
        "explain step by step how to solve {eq} example {n}",
        "walk me through solving {eq} for exercise {n}",
        "in detail, why does {eq} produce its result, item {n}",
        "teach me how {eq} gets solved, thorough explanation {n}",
        "help me understand the result for {eq} case {n}",
        "show the full reasoning behind solving {eq} entry {n}",
        "break down the solution of {eq} for task {n}",
        "describe each step for {eq} in detail {n}",
        "give a complete explanation of {eq} problem {n}",
        "how does the solver handle {eq}, verbose answer {n}",
    ],
}

EQUATIONS = ("2x + 3 = 7", "x^2 - 5x + 6 = 0", "4x - 8 = 0", "x^2 + 1 = 0", "3x = 12", "x^2 - 2 = 0")


def fill(template: str, index: int) -> str:
    values = {
        "n": index + 1,
        "phase": PHASES[index % len(PHASES)],
        "repair": REPAIRS[index % len(REPAIRS)],
        "repair2": REPAIRS[(index + 3) % len(REPAIRS)],
        "backend": BACKENDS[index % len(BACKENDS)],
        "route": ("english", "algebra", "alb")[index % 3],
        "src": f"{index * 7 % 4096:04x}",
        "exit": index % 3,
        "diff": 64 + (index * 37) % 3900,
        "sha": f"{index * 2654435761 % 0xFFFF:04x}",
        "margin": 1 + index % 20,
        "eq": EQUATIONS[index % len(EQUATIONS)],
    }
    extra = " ".join(DISTRACTORS[i % len(DISTRACTORS)] for i in range(index, index + 2 + index % 3))
    return template.format(extra=extra.format(**values), **values)


def family_split(family_index: int, family_count: int) -> str:
    boundary = family_index * 3
    return SPLITS[boundary % 3]


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    output = root / "data/english"
    output.mkdir(parents=True, exist_ok=True)
    counts = {}
    rows_by_split: dict[str, list[dict[str, object]]] = {split: [] for split in SPLITS}
    for frame, templates in sorted(FRAME_SIGNATURES.items()):
        variant_groups = 6
        for index in range(72):
            variant_group = index % variant_groups
            family = f"frame-{frame}-v{variant_group}"
            split = SPLITS[variant_group % len(SPLITS)]
            template = templates[(index // variant_groups + variant_group) % len(templates)]
            rows_by_split[split].append({
                "id": f"eng-{split}-{frame}-{index + 1:03d}",
                "family": family,
                "head": "frame",
                "text": fill(template, index),
                "label": frame,
            })
    for register, templates in sorted(REGISTER_TEMPLATES.items()):
        for template_index, template in enumerate(templates):
            split = SPLITS[template_index % len(SPLITS)]
            family = f"register-{register}-t{template_index}"
            for index in range(40):
                rows_by_split[split].append({
                    "id": f"eng-{split}-reg-{register}-{template_index}-{index + 1:03d}",
                    "family": family,
                    "head": "register",
                    "text": fill(template, index + template_index * 13),
                    "label": register,
                })
    for split in SPLITS:
        path = output / f"{split}.jsonl"
        path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows_by_split[split]), encoding="utf-8")
        counts[split] = len(rows_by_split[split])
    print(json.dumps({"generator": "english-corpus-v1", "counts": counts, "total": sum(counts.values())}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
