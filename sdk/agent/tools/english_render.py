from __future__ import annotations

import json
import re
from pathlib import Path

from train_english_composer import features

LEAD_INS = {
    "terse": "",
    "plain": "",
    "explanatory": "Here is what the verified evidence shows: ",
}

MODEL: dict[str, object] | None = None


def load_model(root: Path) -> dict[str, object] | None:
    global MODEL
    if MODEL is None:
        path = root / "models/english_comp.trm"
        MODEL = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    return MODEL or None


def predict(text: str, weights: list[list[int]], labels: list[str]) -> tuple[str, int, int]:
    vector = features(text)
    scores = [sum(row[index] for index in vector) for row in weights]
    order = sorted(range(len(scores)), key=lambda index: (scores[index], -index), reverse=True)
    best = order[0]
    return labels[best], scores[best], scores[best] - scores[order[1]]


def fraction(fields: dict[str, str], prefix: str) -> str:
    numerator = fields.get(f"{prefix}_numerator", "0")
    denominator = fields.get(f"{prefix}_denominator", "1")
    return numerator if denominator == "1" else f"{numerator}/{denominator}"


def signature_of(result: dict[str, object]) -> str:
    command = str(result.get("command", "unknown"))
    tokens = [f"cmd_{command}"]
    if command == "ask":
        route = result.get("route", {})
        labels = route.get("labels", [])
        tokens.extend(f"route_{label}" for label in labels)
        if route.get("unknown"):
            tokens.append("route_unknown")
        algebra = next((e for e in result.get("evidence", []) if e.get("specialist") == "algebra"), None)
        if algebra is not None:
            status = str(algebra.get("fields", {}).get("status", "failed")).lower()
            tokens.append("ev_algebra_ok" if algebra.get("success") else "ev_algebra_bad")
            tokens.append(f"status_{status}")
        for evidence in result.get("evidence", []):
            if evidence.get("specialist") == "alb":
                tokens.append("ev_alb_pending")
                tokens.append("file_required")
            elif evidence.get("specialist") == "english":
                tokens.append("ev_english_pending")
        routed = set(labels)
        served = {e.get("specialist") for e in result.get("evidence", [])}
        for label in sorted(routed - served):
            tokens.append(f"pending_{label}")
        if not result.get("evidence"):
            tokens.append("ev_none")
    elif command == "check":
        compiler = result.get("compiler", {})
        tokens.append(f"compiler_{compiler.get('status', 'unknown')}")
        diagnostic = result.get("diagnostic")
        if diagnostic:
            tokens.append(f"phase_{diagnostic.get('phase', 'unknown')}")
            tokens.append(f"repair_{diagnostic.get('repair', 'none')}")
            tokens.append("accepted" if diagnostic.get("accepted") else "abstained")
    elif command == "repair":
        tokens.append(f"status_{result.get('status', 'abstained')}")
        tokens.append(f"attempts_{result.get('attempt_count', 0)}")
        tokens.extend(f"action_{action}" for action in result.get("actions", []))
    return " ".join(tokens)


def algebra_sentence(result: dict[str, object], frame: str) -> str:
    algebra = next((e for e in result.get("evidence", []) if e.get("specialist") == "algebra"), {})
    fields = algebra.get("fields", {})
    if frame == "answer_linear":
        return f"The equation is linear and the verified solution is x = {fraction(fields, 'first')}."
    if frame == "answer_roots":
        first = fraction(fields, "first")
        second = fraction(fields, "second")
        if first == second:
            return f"The equation has one repeated root, verified at x = {first}."
        return f"The verified roots are x = {first} and x = {second}."
    if frame == "answer_symbolic":
        base = fields.get("radical_base", "0")
        coefficient = fields.get("radical_coefficient", "1")
        radicand = fields.get("radicand", "0")
        denominator = fields.get("radical_denominator", "1")
        coef = "" if coefficient == "1" else f"{coefficient}*"
        return f"The roots are irrational, verified exactly as ({base} +/- {coef}sqrt({radicand}))/{denominator}."
    if frame == "answer_no_real":
        return "The equation has no real roots; the discriminant is negative."
    if frame == "answer_no_solution":
        return "The equation is a contradiction, so no value of x satisfies it."
    if frame == "answer_infinite":
        return "The equation is an identity, so every value of x satisfies it."
    return "The request was not recognized as a valid bounded equation."


def render_body(result: dict[str, object], frame: str) -> str:
    if frame.startswith("answer_"):
        body = algebra_sentence(result, frame)
        if "pending_english" in signature_of(result) or "pending_alb" in signature_of(result):
            body += " Other specialists are still pending."
        return body
    if frame == "check_pass":
        return "The staged copy compiled cleanly; the original source was never modified."
    if frame == "check_fail":
        diagnostic = result.get("diagnostic", {})
        phase = diagnostic.get("phase", "unknown")
        repair = diagnostic.get("repair", "compiler_guided")
        verdict = "a bounded repair is available" if diagnostic.get("accepted") else "confidence is too low to attempt a repair safely"
        return f"Compilation failed in the {phase} phase; the diagnostic model suggests {repair}, and {verdict}."
    if frame == "repair_verified":
        actions = ", ".join(result.get("actions", [])) or "none"
        attempts = result.get("attempt_count", 0)
        output = result.get("validated_output") or "staging"
        return f"A verified repair was produced in {attempts} attempt(s) using {actions}; the validated copy is at {output}."
    if frame == "repair_partial":
        return "The staged candidate improved compiler evidence but still does not compile; no result was promoted."
    if frame == "repair_abstained":
        return "No repair met the confidence threshold, so the staged candidate was left unpromoted and the original is unchanged."
    if frame == "alb_file_required":
        return "This request needs an ALB source file; run alb_agent check or alb_agent repair with a file path."
    if frame == "english_pending":
        return "The request was understood, but no specialist produced verified evidence for it."
    if frame == "unknown_request":
        return "No specialist recognizes this request, so no verified answer is available."
    return "No verified specialist evidence is available."


def compose(root: Path, result: dict[str, object], request: str = "") -> dict[str, object]:
    model = load_model(root)
    if model is None:
        return {"available": False}
    signature = signature_of(result)
    frame, frame_score, frame_margin = predict(signature, model["frame_weights"], model["frames"])
    frame_known = frame_margin >= model["frame_thresholds"][model["frames"].index(frame)]
    register = "plain"
    register_known = False
    if request:
        register, _, register_margin = predict(request, model["register_weights"], model["registers"])
        register_known = register_margin >= model["register_thresholds"][model["registers"].index(register)]
    if not frame_known:
        return {"available": True, "grounded": False, "abstained": True, "signature": signature, "frame": frame, "frame_margin": frame_margin}
    lead = LEAD_INS.get(register if register_known else "plain", "")
    body = render_body(result, frame)
    text = (lead + body)[:256]
    return {
        "available": True,
        "grounded": True,
        "abstained": False,
        "signature": signature,
        "frame": frame,
        "register": register if register_known else "plain",
        "text": text,
    }


def grounded_tokens(text: str) -> list[str]:
    tokens = re.findall(r"\d+|[A-Za-z]:\\[^\s]+|staging/\S+", text)
    return [token.rstrip(".,;:") for token in tokens]
