from __future__ import annotations

import json
from pathlib import Path

SPLITS = ("train", "dev", "test")
LABEL_GROUPS = {
    "english": (["english"], [
        "{verb} the {subject} using {style} English version {n}",
        "Please {verb} this {subject} and keep the tone {style} number {n}",
        "Give a {style} {subject} {verb} pass for document {n}",
    ]),
    "algebra": (["algebra"], [
        "{mathverb} {a}x {sign} {b} = {c} problem {n}",
        "Use algebra to {mathverb} expression {a}x {sign} {b} for case {n}",
        "Find x and {mathverb} the linear equation {a}x {sign} {b} = {c} item {n}",
    ]),
    "alb": (["alb"], [
        "{codeverb} AdaLogic BASIC {construct} for backend {backend} case {n}",
        "Use ALB to {codeverb} this {construct} with {backend} target item {n}",
        "Check the .alb {construct} and {codeverb} compiler issue {n} for {backend}",
    ]),
    "english-algebra": (["english", "algebra"], [
        "{verb} how to {mathverb} {a}x {sign} {b} = {c} in {style} English {n}",
        "Write a {style} explanation that will {mathverb} equation {a}x {sign} {b} = {c} case {n}",
        "{mathverb} the algebra problem {a}x {sign} {b} = {c} and {verb} every step {n}",
    ]),
    "english-alb": (["english", "alb"], [
        "{verb} the AdaLogic BASIC {construct} in {style} language case {n}",
        "Document ALB {construct} behavior for the {backend} backend in {style} English {n}",
        "{codeverb} this .alb {construct} then {verb} the compiler result {n}",
    ]),
    "algebra-alb": (["algebra", "alb"], [
        "{codeverb} an ALB {construct} that will {mathverb} {a}x {sign} {b} = {c} case {n}",
        "Implement algebra expression {a}x {sign} {b} in AdaLogic BASIC {construct} item {n}",
        "Use .alb code to {mathverb} the polynomial expression for test {n} in a {construct}",
    ]),
    "all": (["english", "algebra", "alb"], [
        "{codeverb} and {verb} an ALB {construct} that {mathverb}s {a}x {sign} {b} = {c} case {n}",
        "In {style} English document AdaLogic BASIC code to {mathverb} equation {a}x {sign} {b} = {c} item {n}",
        "{verb} how this .alb {construct} should {mathverb} the algebra expression in example {n}",
    ]),
    "unknown": ([], [
        "{unknownverb} the {unknownsubject} configuration for scenario {n}",
        "Can you {unknownverb} a {unknownsubject} system in location {n}",
        "Review {unknownsubject} operations and {unknownverb} the outcome number {n}",
    ]),
}

VALUES = {
    "verb": ("explain", "summarize", "rewrite", "describe", "clarify", "document"),
    "subject": ("paragraph", "sentence", "report", "letter", "argument", "message"),
    "style": ("clear", "concise", "formal", "plain", "friendly", "technical"),
    "mathverb": ("solve", "simplify", "factor", "rearrange", "evaluate", "expand"),
    "sign": ("+", "-"),
    "codeverb": ("write", "repair", "generate", "validate", "compile", "port"),
    "construct": ("function", "procedure", "module", "DEFINE block", "FOREACH loop", "expression"),
    "backend": ("fasm", "c", "ada", "python", "web", "c64"),
    "unknownverb": ("tune", "inspect", "design", "compare", "schedule", "diagnose"),
    "unknownsubject": ("diesel engine", "weather station", "database index", "audio codec", "irrigation network", "radio antenna"),
}


def value(name: str, index: int) -> str:
    options = VALUES[name]
    return options[index % len(options)]


def render(template: str, index: int) -> str:
    return template.format(
        n=index + 1,
        a=2 + index % 17,
        b=1 + (index * 3) % 23,
        c=5 + (index * 7) % 41,
        **{name: value(name, index + offset * 3) for offset, name in enumerate(VALUES)},
    )


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    output = root / "data/router"
    counts = {}
    for split_index, split in enumerate(SPLITS):
        rows = []
        for group, (labels, templates) in LABEL_GROUPS.items():
            template = templates[split_index]
            family = f"{group}-{split}-family"
            for index in range(96):
                rows.append({
                    "id": f"gen-{split}-{group}-{index + 1:03d}",
                    "family": family,
                    "text": render(template, index),
                    "labels": labels,
                    "source": "deterministic-template-v1",
                })
        path = output / f"generated_{split}.jsonl"
        path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")
        counts[split] = len(rows)
    print(json.dumps({"generator": "router-corpus-v1", "counts": counts, "total": sum(counts.values())}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
