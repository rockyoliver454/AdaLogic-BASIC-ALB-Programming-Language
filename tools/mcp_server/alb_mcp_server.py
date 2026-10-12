"""
AdaLogic BASIC (ALB) MCP server.

Exposes a closed-loop toolchain so an AI agent can query the language
spec, validate syntax, compile to a backend, execute the result, and run
test suites -- all through MCP tools.

Configuration via environment variables:
  ALBT_PATH    - path to albt.exe
                 (default: H:\\GNATSTUDIO\\bin\\AdaLogic_BASIC\\ALB\\bin\\albt.exe)
  ALB_CC       - C compiler used to turn emitted C into an exe (default: gcc)
  ALB_WORKSPACE- root directory ALB source files must live under
                 (default: two levels up from this file = repo root)
  ALB_TIMEOUT  - subprocess timeout in seconds (default: 10)
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------- config

SERVER_DIR = Path(__file__).resolve().parent
DOCS_DIR = SERVER_DIR / "docs"
DEFAULT_WORKSPACE = SERVER_DIR.parent.parent  # repo root (tools/mcp_server -> repo)

REPO_ROOT = SERVER_DIR.parent.parent
_SDK_ALBT = REPO_ROOT / "sdk" / "bin" / "albt.exe"
ALBT_PATH = os.environ.get(
    "ALBT_PATH",
    str(_SDK_ALBT) if _SDK_ALBT.exists()
    else r"H:\GNATSTUDIO\bin\AdaLogic_BASIC\ALB\bin\albt.exe",
)
ALB_CC = os.environ.get("ALB_CC", "gcc")
ALB_WORKSPACE = Path(
    os.environ.get("ALB_WORKSPACE", str(DEFAULT_WORKSPACE))
).resolve()
ALB_TIMEOUT = int(os.environ.get("ALB_TIMEOUT", "10"))
COMPILE_TIMEOUT = max(ALB_TIMEOUT, 30)

mcp = FastMCP("alb-toolchain")

# ---------------------------------------------------------------- helpers


def _safe_path(p: str) -> Path:
    """Resolve a user-supplied path and confine it to the workspace."""
    if not p:
        raise ValueError("empty path")
    resolved = Path(p).expanduser().resolve()
    try:
        resolved.relative_to(ALB_WORKSPACE)
    except ValueError:
        raise ValueError(
            f"path '{resolved}' is outside the allowed workspace '{ALB_WORKSPACE}'"
        )
    return resolved


def _run(cmd: list[str], timeout: int, cwd: Path | None = None) -> dict:
    """Run a subprocess with a hard timeout; never raise."""
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(cwd) if cwd else None,
        )
        return {
            "ok": proc.returncode == 0,
            "exit_code": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "timed_out": False,
        }
    except subprocess.TimeoutExpired as e:
        return {
            "ok": False,
            "exit_code": None,
            "stdout": e.stdout or "" if isinstance(e.stdout, str) else "",
            "stderr": (e.stderr or "" if isinstance(e.stderr, str) else "")
            + f"\n[TIMEOUT after {timeout}s]",
            "timed_out": True,
        }
    except FileNotFoundError as e:
        return {
            "ok": False,
            "exit_code": None,
            "stdout": "",
            "stderr": f"executable not found: {e}",
            "timed_out": False,
        }


_LINE_RE = re.compile(
    r"LOCATION\s*:\s*(?:File\s*\[([^\]]+)\]\s*\|\s*)?Line\s+(\d+)\s*\|\s*Col\s+(\d+)"
)
_BREACH_RE = re.compile(r"BREACH\s*:\s*(.+)")
_COUNSEL_RE = re.compile(r"COUNSEL\s*:\s*(.+)")


def _parse_albt_output(text: str) -> list[dict]:
    """Extract structured diagnostics from albt's 'DIAGNOSTIC FORGE' output."""
    diags = []
    current = None
    for line in text.splitlines():
        clean = re.sub(r"\x1b\[[0-9;]*m", "", line)  # strip ANSI colors
        m = _LINE_RE.search(clean)
        if m:
            if current:
                diags.append(current)
            current = {"line": int(m.group(2)), "col": int(m.group(3))}
            if m.group(1):
                current["file"] = m.group(1)
            continue
        if current is not None:
            m = _BREACH_RE.search(clean)
            if m:
                current["error"] = m.group(1).strip()
                continue
            m = _COUNSEL_RE.search(clean)
            if m:
                current["hint"] = m.group(1).strip()
    if current:
        diags.append(current)

    # Fallback: FATAL lines or generic failures not caught above
    if not diags:
        for line in text.splitlines():
            clean = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
            if clean.startswith("FATAL") or clean.startswith("BREACH"):
                diags.append({"error": clean})
    return diags


def _albt_failed(result: dict, artifact: Path | None) -> bool:
    """albt exits 0 even on errors — detect failure via output + artifact."""
    blob = result["stdout"] + result["stderr"]
    if result["timed_out"] or result["exit_code"] is None:
        return True
    if "DIAGNOSTIC FORGE" in blob or "BREACH" in blob or "FATAL" in blob:
        return True
    if artifact is not None and not artifact.exists():
        return True
    return False


_TARGET_EXT = {
    "c": ".c",
    "ada": ".adb",
    "fasm": ".asm",
    "nasm": ".asm",
    "java": ".java",
    "wasm": ".wat",
    "rust": ".rs",
    "zig": ".zig",
    "csharp": ".cs",
    "cobol": ".cob",
    "6502": ".asm",
    "z80": ".asm",
    "8086": ".asm",
    "purebasic": ".pb",
    "agk": ".agk",
    "glbasic": ".gbas",
    "hollywood": ".hws",
    "structuredtext": ".st",
    "verilog": ".v",
    "computeshaders": ".comp",
    "forth": ".fs",
    "factor": ".factor",
    "raptor": ".rap",
}


_FASM_TARGETS = {"fasm", "fasm16"}


def _stage_job_dir(src: Path, job_dir: Path) -> Path:
    """Copy the source tree into a scratch dir so albt's SDK bootstrap
    folders (bin/config/stdlib/...) stay out of the real tree. The layout
    mirrors reality so `INCLUDE "../X.ALBI"` keeps working: the source's
    parent dir becomes job_dir/<parent>/, and grandparent-level .alb/.albi
    files land directly in job_dir."""
    import shutil

    proj = job_dir / src.parent.name
    proj.mkdir(parents=True, exist_ok=True)
    for sib in src.parent.iterdir():
        if sib.suffix.lower() in (".alb", ".albi"):
            shutil.copy2(sib, proj / sib.name)
    grand = src.parent.parent
    if grand.is_dir():
        for anc in grand.iterdir():
            if anc.suffix.lower() in (".alb", ".albi"):
                shutil.copy2(anc, job_dir / anc.name)
    return proj / src.name


def _transpile(src: Path, target: str, job_dir: Path, assemble: bool = True) -> dict:
    """Run albt inside a staged job dir; return a structured result."""
    ext = _TARGET_EXT.get(target.lower(), f".{target.lower()}")
    staged = _stage_job_dir(src, job_dir)
    work = staged.parent
    artifact = work / (staged.stem + ext)
    cmd = [ALBT_PATH, staged.name, "-t", target, "-o", artifact.name]
    is_fasm = target.lower() in _FASM_TARGETS
    if is_fasm and assemble:
        cmd.append("--build")
    cmd.append("--quiet")
    res = _run(cmd, timeout=COMPILE_TIMEOUT, cwd=work)

    exe = None
    if is_fasm and assemble:
        # albt stages fasm_<stem>/<out-stem>.{asm,exe} next to the source
        staged_out = work / f"fasm_{staged.stem}"
        if not artifact.exists() and (staged_out / artifact.name).exists():
            artifact = staged_out / artifact.name
        cand = staged_out / (artifact.stem + ".exe")
        if cand.exists():
            exe = str(cand)

    failed = _albt_failed(res, artifact if not (is_fasm and assemble) else
                          (work / f"fasm_{staged.stem}" / (artifact.stem + ".exe")))
    out = {
        "success": not failed,
        "artifact": str(artifact) if artifact.exists() else None,
        "backend": target,
        "stdout": res["stdout"],
        "stderr": res["stderr"],
        "timed_out": res["timed_out"],
    }
    if exe:
        out["executable"] = exe
    if failed:
        out["diagnostics"] = _parse_albt_output(res["stdout"] + res["stderr"])
    return out


# ---------------------------------------------------------------- tools


@mcp.tool()
def query_language_spec(query_string: str) -> str:
    """Query the ALB syntax guide / cheat sheet. Returns the markdown
    sections most relevant to the query (e.g. 'loops', 'arrays', 'file io')."""
    terms = [t.lower() for t in re.findall(r"[a-zA-Z0-9_$]+", query_string)]
    if not terms:
        return json.dumps({"error": "empty query"})

    sections = []  # (doc, title, body)
    for doc in sorted(DOCS_DIR.glob("*")):
        if not doc.is_file():
            continue
        text = doc.read_text(encoding="utf-8", errors="replace")
        # split on markdown headings AND all-caps plaintext section headers
        parts = re.split(
            r"(?m)^(#{1,4} .+|[A-Z][A-Z0-9 /&(),_'-]{4,}\s*)$", text
        )
        preamble, chunks = parts[0], parts[1:]
        if preamble.strip():
            sections.append((doc.name, "(preamble)", preamble))
        for i in range(0, len(chunks), 2):
            title = chunks[i]
            body = chunks[i + 1] if i + 1 < len(chunks) else ""
            sections.append((doc.name, title.strip("# ").strip(), title + body))

    scored = []
    for doc_name, title, body in sections:
        hay = (title + " " + body).lower()
        score = sum(hay.count(t) for t in terms)
        if score:
            scored.append((score, doc_name, title, body))

    scored.sort(key=lambda x: -x[0])
    top = scored[:5]
    if not top:
        return json.dumps(
            {
                "matches": [],
                "hint": "no section matched; try broader terms like 'print', 'let', 'for'",
            }
        )
    return json.dumps(
        {
            "matches": [
                {
                    "doc": d,
                    "section": t,
                    "score": s,
                    "content": b.strip()[:6000],
                }
                for s, d, t, b in top
            ]
        },
        indent=2,
    )


@mcp.tool()
def validate_syntax(filepath: str) -> str:
    """Dry-run the ALB compiler against a .alb file. Returns structured
    diagnostics (line/col/message) without producing a final binary."""
    try:
        src = _safe_path(filepath)
    except ValueError as e:
        return json.dumps({"success": False, "error": str(e)})
    if not src.exists():
        return json.dumps({"success": False, "error": f"file not found: {src}"})

    with tempfile.TemporaryDirectory(dir=SERVER_DIR) as td:
        out = _transpile(src, "c", Path(td))
    out["mode"] = "validate_syntax"
    if out["success"]:
        out["message"] = "no syntax or semantic errors detected"
    return json.dumps(out, indent=2)


@mcp.tool()
def compile_target(filepath: str, backend_target: str = "c") -> str:
    """Compile a .alb file to a backend target. For the 'c' backend the
    emitted C is also built into an .exe with gcc when available, so the
    result can be passed straight to execute_and_capture."""
    try:
        src = _safe_path(filepath)
    except ValueError as e:
        return json.dumps({"success": False, "error": str(e)})
    if not src.exists():
        return json.dumps({"success": False, "error": f"file not found: {src}"})

    build_dir = src.parent / (src.stem + "_build")
    build_dir.mkdir(exist_ok=True)
    out = _transpile(src, backend_target, build_dir)
    out["mode"] = "compile_target"

    if out["success"] and backend_target.lower() == "c" and out["artifact"]:
        exe = build_dir / (src.stem + ".exe")
        cc = _run(
            [ALB_CC, "-O1", "-o", str(exe), out["artifact"], "-lwinmm", "-lm"],
            timeout=COMPILE_TIMEOUT,
            cwd=build_dir,
        )
        if cc["ok"] and exe.exists():
            out["executable"] = str(exe)
        else:
            out["cc_error"] = {
                "stderr": cc["stderr"][-4000:],
                "exit_code": cc["exit_code"],
                "timed_out": cc["timed_out"],
            }
            out["success"] = False
    return json.dumps(out, indent=2)


@mcp.tool()
def execute_and_capture(executable_path: str, arguments: list[str] | None = None) -> str:
    """Run a compiled binary (or script) with a strict timeout and return
    stdout, stderr, and the exit code."""
    try:
        exe = _safe_path(executable_path)
    except ValueError as e:
        return json.dumps({"success": False, "error": str(e)})
    if not exe.exists():
        return json.dumps({"success": False, "error": f"file not found: {exe}"})

    args = [str(a) for a in (arguments or [])]
    res = _run([str(exe), *args], timeout=ALB_TIMEOUT, cwd=exe.parent)
    return json.dumps(
        {
            "success": res["ok"],
            "exit_code": res["exit_code"],
            "stdout": res["stdout"],
            "stderr": res["stderr"],
            "timed_out": res["timed_out"],
        },
        indent=2,
    )


@mcp.tool()
def run_test_suite(test_directory: str, backend_target: str = "fasm") -> str:
    """Compile and run every .alb file in a directory. A test passes when
    it compiles and exits 0; if a sibling '<name>.expected.txt' exists,
    stdout must match it exactly. Returns a pass/fail summary with diffs.
    backend_target defaults to 'fasm' (the primary native backend); 'c' is
    also executable — other backends are validated but not run."""
    try:
        tdir = _safe_path(test_directory)
    except ValueError as e:
        return json.dumps({"success": False, "error": str(e)})
    if not tdir.is_dir():
        return json.dumps({"success": False, "error": f"not a directory: {tdir}"})

    sources = sorted(tdir.glob("*.alb"))
    if not sources:
        return json.dumps({"success": False, "error": "no .alb files found"})

    results = []
    for src in sources:
        entry = {"test": src.name}
        build_dir = tdir / (src.stem + "_build")
        build_dir.mkdir(exist_ok=True)

        comp = _transpile(src, backend_target, build_dir)
        if not comp["success"]:
            entry.update(status="FAIL", stage="transpile",
                         diagnostics=comp.get("diagnostics"),
                         compiler_output=(comp["stdout"] + comp["stderr"])[-3000:])
            results.append(entry)
            continue

        exe = None
        bt = backend_target.lower()
        if bt in _FASM_TARGETS:
            exe = Path(comp["executable"]) if comp.get("executable") else None
            if not exe:
                entry.update(status="FAIL", stage="assemble",
                             compiler_output=(comp["stdout"] + comp["stderr"])[-3000:])
                results.append(entry)
                continue
        elif bt == "c":
            exe = build_dir / (src.stem + ".exe")
            cc = _run(
                [ALB_CC, "-O1", "-o", str(exe), comp["artifact"], "-lwinmm", "-lm"],
                timeout=COMPILE_TIMEOUT, cwd=build_dir,
            )
            if not (cc["ok"] and exe.exists()):
                entry.update(status="FAIL", stage="cc", stderr=cc["stderr"][-3000:])
                results.append(entry)
                continue
        else:
            entry.update(status="SKIP", stage="transpile_only",
                         artifact=comp["artifact"],
                         note=f"backend '{bt}' is not executable on this host")
            results.append(entry)
            continue

        run = _run([str(exe)], timeout=ALB_TIMEOUT, cwd=build_dir)
        expected_file = src.with_suffix(".expected.txt")
        if expected_file.exists():
            expected = expected_file.read_text(encoding="utf-8", errors="replace")
            actual = run["stdout"]
            if actual.replace("\r\n", "\n").strip() == expected.replace("\r\n", "\n").strip():
                entry.update(status="PASS", stdout=actual)
            else:
                entry.update(
                    status="FAIL", stage="output_diff",
                    expected=expected, actual=actual,
                )
        elif run["timed_out"]:
            entry.update(status="FAIL", stage="timeout", stdout=run["stdout"])
        elif run["exit_code"] == 0:
            entry.update(status="PASS", stdout=run["stdout"])
        else:
            entry.update(status="FAIL", stage="runtime",
                         exit_code=run["exit_code"],
                         stdout=run["stdout"], stderr=run["stderr"])
        results.append(entry)

    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = sum(1 for r in results if r["status"] == "FAIL")
    return json.dumps(
        {
            "total": len(results),
            "passed": passed,
            "failed": failed,
            "skipped": len(results) - passed - failed,
            "success": failed == 0,
            "results": results,
        },
        indent=2,
    )


if __name__ == "__main__":
    mcp.run()  # stdio transport
