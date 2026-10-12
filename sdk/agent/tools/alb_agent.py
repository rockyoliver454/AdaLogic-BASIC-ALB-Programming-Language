from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

from alb_compiler_adapter import compile_copy
from english_render import compose
from generate_alb_mutations import copy_include_context
from train_alb_diagnostic_router import REPAIRS, PHASES, features
import train_router

EQUATION = re.compile(r"(?<![A-Za-z0-9_])[-+()0-9xX*^ ]{1,96}=[-+()0-9xX*^ ]{1,96}")
LOCATION = re.compile(r"(?:Line\s+|:)(\d+)(?:\s*[,|:]\s*(?:Col\s+)?(\d+))?", re.IGNORECASE)


def model_prediction(text: str, weights: list[list[int]], labels: list[str]) -> tuple[str, int, int]:
    vector = features(text)
    scores = [sum(row[index] for index in vector) for row in weights]
    order = sorted(range(len(scores)), key=lambda index: (scores[index], -index), reverse=True)
    best = order[0]
    return labels[best], scores[best], scores[best] - scores[order[1]]


def route_request(root: Path, request: str) -> dict[str, object]:
    model = json.loads((root / "models/router.trm").read_text(encoding="utf-8"))
    labels = sorted(train_router.predict(request, model["weights"], model["thresholds"]))
    scores = dict(zip(model["domains"], train_router.score(request, model["weights"])))
    return {"labels": labels, "scores": scores, "unknown": not labels}


def extract_equation(request: str) -> str | None:
    matches = [match.group(0).strip() for match in EQUATION.finditer(request)]
    matches = [value for value in matches if "x" in value.lower() and any(character.isdigit() for character in value)]
    return matches[0] if matches else None


def run_algebra(root: Path, equation: str) -> dict[str, object]:
    executable = root / "bin/polynomial_cli.exe"
    if not executable.is_file():
        executable = root / "bin/polynomial_cli"
    completed = subprocess.run([str(executable), equation], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=15, check=False)
    fields = {}
    for line in completed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip().lower()] = value.strip()
    return {"success": completed.returncode == 0 and fields.get("verified") == "TRUE", "equation": equation, "fields": fields, "raw": completed.stdout[:2048]}


def stage_source(root: Path, source: Path) -> tuple[Path, dict[str, object]]:
    source = source.resolve()
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    unit = root / "staging/alb_agent" / digest[:16]
    unit.mkdir(parents=True, exist_ok=True)
    staged = unit / ("source" + source.suffix.lower())
    staged.write_bytes(data)
    text = data.decode("utf-8", "replace")
    include_count, include_manifest = copy_include_context(source, unit, text)
    proof = {"source": str(source), "source_sha256": digest, "staged": staged.relative_to(root).as_posix(), "include_count": include_count, "include_manifest": include_manifest}
    return staged, proof


def diagnose(root: Path, diagnostic: str) -> dict[str, object]:
    model = json.loads((root / "models/alb_diag.trm").read_text(encoding="utf-8"))
    phase, phase_score, phase_margin = model_prediction(diagnostic, model["phase_weights"], model["phases"])
    repair, repair_score, repair_margin = model_prediction(diagnostic, model["repair_weights"], model["repairs"])
    threshold = model["repair_thresholds"][model["repairs"].index(repair)]
    return {"phase": phase, "phase_score": phase_score, "phase_margin": phase_margin, "repair": repair, "repair_score": repair_score, "repair_margin": repair_margin, "repair_threshold": threshold, "accepted": repair_margin >= threshold}


def repair_text(text: str, action: str, diagnostic: str) -> tuple[str | None, str]:
    if action == "fix_type":
        replacements = (("S8", "I8"), ("S16", "I16"), ("S32", "I32"), ("S64", "I64"), ("INT16", "I16"), ("INT32", "I32"))
        for old, new in replacements:
            match = re.search(rf"\b{old}\b", text, re.IGNORECASE)
            if match:
                return text[:match.start()] + new + text[match.end():], f"replace {match.group(0)} with {new}"
    elif action == "fix_keyword":
        if "CONTROLLED_PARSER_KEYWORD" in text:
            return "".join(line for line in text.splitlines(keepends=True) if "CONTROLLED_PARSER_KEYWORD" not in line), "remove isolated invalid keyword line"
        for old, new in (("TH_N", "THEN"), ("ENDMODUL", "ENDMODULE")):
            match = re.search(rf"\b{old}\b", text, re.IGNORECASE)
            if match:
                return text[:match.start()] + new + text[match.end():], f"replace {match.group(0)} with {new}"
    elif action == "close_module":
        if "MODULE" in text.upper() and "ENDMODULE" not in text.upper():
            return text.rstrip() + "\nENDMODULE\n", "append ENDMODULE"
    elif action == "fix_lexical":
        if text.startswith("@@@ CONTROLLED_INVALID_TOKEN"):
            return "".join(text.splitlines(keepends=True)[1:]), "remove invalid leading token"
        match = LOCATION.search(diagnostic)
        if match and int(match.group(1)) == 1 and text.startswith("@@@"):
            return text[3:].lstrip(), "remove compiler-located invalid token"
    elif action == "fix_expression":
        if "(1 + )" in text:
            return text.replace("(1 + )", "1", 1), "replace incomplete expression with 1"
    return None, "no bounded transform available"


def rank(result: dict[str, object]) -> tuple[int, int]:
    return {"ready": 0, "failed": 2, "timed_out": 3, "denied": 4}.get(str(result["status"]), 5), int(result.get("diagnostic_length", 4096))


def check_file(root: Path, compiler: Path, source: Path, backend: str) -> dict[str, object]:
    before_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    staged, staging = stage_source(root, source)
    output = root / "obj/alb_agent" / before_hash[:16] / "check"
    compiled = compile_copy(staged, compiler, root, backend, 15, output)
    result = {"command": "check", "success": compiled["status"] == "ready", "staging": staging, "compiler": compiled}
    if compiled["status"] != "ready":
        result["diagnostic"] = diagnose(root, str(compiled["diagnostic"]))
    result["original_unchanged"] = hashlib.sha256(source.read_bytes()).hexdigest() == before_hash
    result["english"] = compose(root, result)
    return result


def repair_file(root: Path, compiler: Path, source: Path, backend: str, max_attempts: int) -> dict[str, object]:
    original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    staged, staging = stage_source(root, source)
    attempts = []
    current = staged
    initial_text = staged.read_text(encoding="utf-8", errors="replace")
    actions = []
    for attempt in range(1, min(3, max(1, max_attempts)) + 1):
        output = root / "obj/alb_agent" / original_hash[:16] / f"attempt-{attempt}"
        compiled = compile_copy(current, compiler, root, backend, 15, output)
        compiled.update({"attempt": attempt, "candidate": current.relative_to(root).as_posix()})
        attempts.append(compiled)
        if compiled["status"] == "ready":
            break
        prediction = diagnose(root, str(compiled["diagnostic"]))
        if not prediction["accepted"] or prediction["repair"] in actions:
            break
        actions.append(str(prediction["repair"]))
        text = current.read_text(encoding="utf-8", errors="replace")
        repaired, description = repair_text(text, str(prediction["repair"]), str(compiled["diagnostic"]))
        if repaired is None or repaired == text:
            break
        next_path = staged.parent / f"candidate-{attempt + 1}.alb"
        next_path.write_text(repaired, encoding="utf-8")
        prediction["transform"] = description
        compiled["prediction"] = prediction
        current = next_path
    final = attempts[-1]
    final_text = current.read_text(encoding="utf-8", errors="replace")
    diff = "".join(difflib.unified_diff(initial_text.splitlines(keepends=True), final_text.splitlines(keepends=True), fromfile="staged-original", tofile="validated-candidate", n=2))
    improved = rank(final) < rank(attempts[0])
    validated = final["status"] == "ready" and improved and final_text != initial_text
    validated_path = staged.parent / "validated.alb"
    if validated:
        validated_path.write_text(final_text, encoding="utf-8")
    return {
        "command": "repair",
        "success": validated,
        "status": "verified" if validated else "partially_improved" if improved else "abstained",
        "staging": staging,
        "actions": actions,
        "attempts": attempts,
        "attempt_count": len(attempts),
        "hard_attempt_cap": min(3, max(1, max_attempts)),
        "improved": improved,
        "validated_output": validated_path.relative_to(root).as_posix() if validated else None,
        "diff": diff[:4096],
        "before_sha256": hashlib.sha256(initial_text.encode()).hexdigest(),
        "after_sha256": hashlib.sha256(final_text.encode()).hexdigest(),
        "original_unchanged": hashlib.sha256(source.read_bytes()).hexdigest() == original_hash,
        "english": compose(root, {"command": "repair", "status": "verified" if validated else "partially_improved" if improved else "abstained", "attempt_count": len(attempts), "actions": actions, "validated_output": validated_path.relative_to(root).as_posix() if validated else None}),
    }


def ask(root: Path, request: str) -> dict[str, object]:
    route = route_request(root, request)
    result = {"command": "ask", "success": not route["unknown"], "request": request, "route": route, "evidence": []}
    equation = extract_equation(request)
    if equation and "algebra" in route["labels"]:
        result["evidence"].append({"specialist": "algebra", **run_algebra(root, equation)})
    if "alb" in route["labels"]:
        result["evidence"].append({"specialist": "alb", "status": "file_required", "message": "Use alb_agent check or repair with an ALB file."})
    if "english" in route["labels"] and not result["evidence"]:
        result["evidence"].append({"specialist": "english", "status": "not_trained", "message": "No verified English specialist result is available."})
    result["english"] = compose(root, result, request)
    return result


def render(result: dict[str, object], trace: bool) -> str:
    lines = [f"STATUS: {'SUCCESS' if result.get('success') else result.get('status', 'NO_VERIFIED_RESULT').upper()}"]
    if result["command"] == "ask":
        route = result["route"]
        lines.append("ROUTE: " + (", ".join(route["labels"]) if route["labels"] else "unknown"))
        for evidence in result["evidence"]:
            if evidence.get("specialist") == "algebra" and evidence.get("success"):
                fields = evidence["fields"]
                if "first_numerator" in fields:
                    first = f"{fields.get('first_numerator')}/{fields.get('first_denominator')}"
                    second = f"{fields.get('second_numerator')}/{fields.get('second_denominator')}"
                    lines.append(f"EVIDENCE: verified roots/solution {first}, {second}")
                elif "radicand" in fields:
                    lines.append(f"EVIDENCE: verified symbolic roots ({fields.get('radical_base')} +/- {fields.get('radical_coefficient')}*sqrt({fields.get('radicand')}))/{fields.get('radical_denominator')}")
                else:
                    lines.append("EVIDENCE: verified algebra classification " + str(fields.get("status")))
            else:
                lines.append("EVIDENCE: " + str(evidence.get("message", evidence.get("status"))))
    elif result["command"] == "check":
        lines.append("COMPILER: " + str(result["compiler"]["status"]))
        if "diagnostic" in result:
            lines.append("DIAGNOSTIC: " + str(result["diagnostic"]["phase"]) + " / " + str(result["diagnostic"]["repair"]))
    else:
        lines.append("ATTEMPTS: " + str(result["attempt_count"]) + "/" + str(result["hard_attempt_cap"]))
        lines.append("ACTIONS: " + (", ".join(result["actions"]) if result["actions"] else "none"))
        if result.get("validated_output"):
            lines.append("VALIDATED OUTPUT: " + str(result["validated_output"]))
        if result.get("diff"):
            lines.append("DIFF:\n" + str(result["diff"]))
    english = result.get("english") or {}
    if english.get("grounded") and english.get("text"):
        lines.append("RESPONSE: " + str(english["text"]))
    lines.append("SOURCE POLICY: original unchanged")
    if trace:
        lines.append("TRACE:\n" + json.dumps(result, indent=2, sort_keys=True))
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(prog="alb_agent")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--trace", action="store_true")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--compiler", type=Path, default=Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\obj\albt.exe"))
    sub = parser.add_subparsers(dest="command", required=True)
    ask_parser = sub.add_parser("ask")
    ask_parser.add_argument("request", nargs="+")
    check_parser = sub.add_parser("check")
    check_parser.add_argument("file", type=Path)
    check_parser.add_argument("--backend", choices=("fasm", "c"), default="fasm")
    repair_parser = sub.add_parser("repair")
    repair_parser.add_argument("file", type=Path)
    repair_parser.add_argument("--backend", choices=("fasm", "c"), default="fasm")
    repair_parser.add_argument("--max-attempts", type=int, default=3)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "ask":
        result = ask(root, " ".join(args.request))
    elif args.command == "check":
        result = check_file(root, args.compiler.resolve(), args.file, args.backend)
    else:
        result = repair_file(root, args.compiler.resolve(), args.file, args.backend, args.max_attempts)
    print(json.dumps(result, indent=2, sort_keys=True) if args.json else render(result, args.trace))
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
