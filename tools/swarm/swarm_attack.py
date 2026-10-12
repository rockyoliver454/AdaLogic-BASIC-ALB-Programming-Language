"""
swarm_attack.py — Swarm Attack orchestrator.

Feeds a task file (feature request / bug report) to the local AI swarm
(aider against the local llama.cpp Qwen endpoint), then verifies the
result with the ALB MCP toolchain. Retries up to MAX_RETRIES times,
feeding compiler diagnostics back each round. On exhaustion it reverts
affected files and writes HELP_NEEDED.md.

Usage:
    python swarm_attack.py <task_file.md> [--target <path>] [--retries N]

The task file may contain a line `TARGET: <path>` naming the .alb file
or test directory the swarm should make pass. Without one, the repo
test suite (tools/mcp_server/tests) is used as the success check.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MCP_DIR = REPO / "tools" / "mcp_server"
sys.path.insert(0, str(MCP_DIR))
import alb_mcp_server as mcp_tools  # noqa: E402

LOCAL = Path(r"D:\.local")
LLM_URL = "http://127.0.0.1:8080/v1/models"
AIDER = LOCAL / "bin" / "aider.exe"
AIDER_CONF = LOCAL / "aider.conf.yml"
CONVENTIONS = Path(__file__).parent / "CONVENTIONS.md"
HELP_FILE = REPO / "HELP_NEEDED.md"
MAX_RETRIES_DEFAULT = 5
AIDER_TIMEOUT = int(os.environ.get("SWARM_AIDER_TIMEOUT", "900"))  # seconds
QUICKREF = Path(__file__).parent / "ALB_QUICKREF.md"


def llm_alive() -> bool:
    try:
        urllib.request.urlopen(LLM_URL, timeout=3)
        return True
    except Exception:
        return False


def wake_llm() -> None:
    print("[swarm] waking local LLM server ...")
    subprocess.Popen(
        ["cmd", "/c", str(LOCAL / "start_llm.cmd")],
        creationflags=subprocess.CREATE_NEW_CONSOLE,
    )
    for _ in range(120):
        if llm_alive():
            print("[swarm] LLM server online.")
            return
        import time
        time.sleep(5)
    raise SystemExit("[swarm] FATAL: llama server did not come up in 10 min")


def git_changed() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(REPO), "status", "--porcelain"],
        capture_output=True, text=True,
    ).stdout
    return [l[3:].strip() for l in out.splitlines() if l.strip()]


def git_revert(paths: list[str]) -> None:
    for p in paths:
        subprocess.run(["git", "-C", str(REPO), "checkout", "HEAD", "--", p],
                       capture_output=True)
        full = REPO / p
        if full.exists():
            subprocess.run(["git", "-C", str(REPO), "checkout", "--", p],
                           capture_output=True)
        else:
            subprocess.run(["git", "-C", str(REPO), "clean", "-fd", "--", p],
                           capture_output=True)


def parse_target(task_text: str) -> str | None:
    """Extract a TARGET: line. Prefer .alb files or directories; a bare
    .albi target only gets validate_syntax (it can't be executed)."""
    m = re.search(r"(?im)^TARGET:\s*(.+)$", task_text)
    if not m:
        return None
    candidates = re.findall(r"[\w./\\-]+\.(?:albi|alb)\b|[\w./\\-]+", m.group(1))
    for c in candidates:
        p = (REPO / c)
        if p.is_dir() or p.suffix.lower() == ".alb":
            return c
    return candidates[0] if candidates else None


def _alb_sane(path: Path) -> tuple[bool, str]:
    """Guard against trivial success: the file must exist and look like
    ALB (a BEGIN..END body or module/subprogram structure)."""
    if not path.exists():
        return False, f"{path.name} does not exist yet"
    text = path.read_text(encoding="utf-8", errors="replace")
    if len(text.strip()) < 10:
        return False, f"{path.name} is empty or trivial"
    if not re.search(r"(?im)^\s*(BEGIN|DECLARE\s+MODULE|MODULE|PROCEDURE|FUNCTION)\b", text):
        return False, f"{path.name} has no ALB structure (BEGIN/MODULE/PROCEDURE)"
    # lowercase-only match: python 'import'/'def' vs ALB 'IMPORT'/'FUNCTION'
    if re.search(r"(?m)^\s*(import [a-z_]|def |from [a-z_]|print\()", text):
        return False, f"{path.name} looks like Python, not ALB"
    return True, ""


def relocate_strays(target: str | None) -> None:
    """Small models emit bare filenames, so aider writes new files to the
    repo root instead of next to the target. Move stray .alb/.albi files
    into the target's directory; drop garbage pseudo-filenames like
    'compile_target(lambda_test.alb, "fasm")'."""
    if not target:
        return
    dest_dir = (REPO / target).parent
    for p in git_changed():
        f = REPO / p
        if f.suffix.lower() not in (".alb", ".albi") or not f.exists():
            continue
        if f.parent == dest_dir:
            continue
        if "(" in f.name or ")" in f.name:
            subprocess.run(["git", "-C", str(REPO), "rm", "-f", "-q",
                            "--ignore-unmatch", p], capture_output=True)
            f.unlink(missing_ok=True)
            continue
        dest = dest_dir / f.name
        if dest.exists() and dest.stat().st_size > 10:
            continue  # real content already there; don't clobber
        if not f.name:
            continue
        # aider git-adds files it creates, so prefer git mv (index+worktree)
        r = subprocess.run(["git", "-C", str(REPO), "mv", "-f", p,
                            str(dest.relative_to(REPO))],
                           capture_output=True)
        if r.returncode != 0 and f.exists():
            f.rename(dest)
        print(f"[swarm] relocated {p} -> {dest.relative_to(REPO)}")


def check_success(target: str | None) -> tuple[bool, str]:
    """Run the MCP verification for the task target. Returns (ok, diagnostics)."""
    if target:
        t = REPO / target
        if t.suffix.lower() in (".alb", ".albi"):
            sane, why = _alb_sane(t)
            if not sane:
                return False, json.dumps({"success": False, "gate": why}, indent=2)
        if t.suffix.lower() == ".albi":
            res = json.loads(mcp_tools.validate_syntax(str(t)))
        elif t.is_dir():
            res = json.loads(mcp_tools.run_test_suite(str(t)))
        else:
            res = json.loads(mcp_tools.compile_target(str(t), "fasm"))
            if res.get("success") and res.get("executable"):
                run = json.loads(mcp_tools.execute_and_capture(res["executable"], []))
                res["run"] = run
                res["success"] = run.get("exit_code") == 0 and not run.get("timed_out")
    else:
        res = json.loads(mcp_tools.run_test_suite(str(MCP_DIR / "tests")))
    return bool(res.get("success")), json.dumps(res, indent=2)[:4000]


def run_aider(task_text: str, diagnostics: str, attempt: int,
              target: str | None) -> None:
    # NOTE: conventions/quickref are inlined into the message, NOT passed via
    # --read. aider's choose_fence() scans --read file contents for ``` and
    # escalates to a 4-backtick fence, which the model then ignores -> zero
    # edits applied, silently (aider #2879). Inlining avoids the scan.
    quickref = QUICKREF.read_text(encoding="utf-8", errors="replace")
    conventions = CONVENTIONS.read_text(encoding="utf-8", errors="replace")
    prompt = (
        "CRITICAL: .alb and .albi files contain AdaLogic BASIC — a custom "
        "compiled language. DO NOT write Python, JavaScript, or any other "
        "language in them. Follow these references exactly:\n\n"
        f"{quickref}\n\n{conventions}\n\n"
        f"=== TASK ===\n{task_text}\n\n"
        "OUTPUT FORMAT (strict): for each file you create or change, print "
        "the repo-relative path ALONE on its own line — no 'File:' prefix, "
        "no '#' or '###' headers, no backticks, and NEVER a placeholder like "
        "'path/to/' — immediately followed by a "
        "```alb code block containing the ENTIRE file contents.\n"
        + (f"The main file MUST be written to: {target}\n"
           f"Any module it INCLUDEs must live in the same directory: "
           f"{REPO.joinpath(target).parent.relative_to(REPO).as_posix()}/\n\n"
           if target else "\n")
        + f"--- ATTEMPT {attempt} ---\n"
        f"Latest compiler/test diagnostics (fix THIS, do not rewrite blindly):\n"
        f"{diagnostics}\n"
    )
    msg = REPO / "tools" / "swarm" / "_swarm_msg.md"
    msg.write_text(prompt, encoding="utf-8")
    cmd = [
        str(AIDER),
        "--config", str(AIDER_CONF),
        "--message-file", str(msg),
        "--map-tokens", "256",
        "--yes-always",
        "--no-auto-commits",
        "--no-show-model-warnings",
        "--no-suggest-shell-commands",
        "--no-fancy-input",
        "--no-pretty",
        "--no-analytics",
    ]
    env = dict(os.environ)
    # aider/webbrowser can pop a browser tab (model-warning links etc.);
    # BROWSER must name an executable — point it at a no-op
    env["BROWSER"] = "cmd /c exit 0"
    env["AIDER_ANALYTICS"] = "false"

    # Scope via positional file + .aiderignore (running from a subdir
    # breaks aider's git reader on Windows).
    files = []
    if target:
        t = REPO / target
        if t.suffix.lower() in (".alb", ".albi"):
            # do NOT pre-create: aider git-adds whatever file arg it gets,
            # and a pre-existing empty target makes aider write the real
            # content to a bare-name file at the repo root instead.
            files.append(str(t))
    try:
        subprocess.run(
            cmd + files,
            cwd=REPO,
            stdin=subprocess.DEVNULL,   # EOF -> defaults, never blocks on Enter
            env=env,
            timeout=AIDER_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print(f"[swarm] aider exceeded {AIDER_TIMEOUT}s — killing attempt {attempt}")


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    task_file = Path(args[0]).resolve()
    retries = MAX_RETRIES_DEFAULT
    target = None
    if "--retries" in args:
        retries = int(args[args.index("--retries") + 1])
    if "--target" in args:
        target = args[args.index("--target") + 1]

    task_text = task_file.read_text(encoding="utf-8", errors="replace")
    if not target:
        target = parse_target(task_text)
    print(f"[swarm] task={task_file.name} target={target or 'default test suite'}")

    baseline = set(git_changed())
    if not llm_alive():
        wake_llm()

    last_diag = "no diagnostics yet — first attempt"
    for attempt in range(1, retries + 1):
        print(f"[swarm] === attempt {attempt}/{retries} ===")
        run_aider(task_text, last_diag, attempt, target)
        relocate_strays(target)
        ok, last_diag = check_success(target)
        if ok:
            print("[swarm] SUCCESS: target verified.")
            msg = REPO / "tools" / "swarm" / "_swarm_msg.md"
            if msg.exists():
                msg.unlink()
            return 0

    print(f"[swarm] {retries} consecutive failures — reverting and escalating.")
    new_changes = [p for p in git_changed() if p not in baseline]
    git_revert(new_changes)
    HELP_FILE.write_text(
        f"# HELP NEEDED — swarm exhausted {retries} attempts\n\n"
        f"Task file: `{task_file}`\n\n"
        f"Reverted files: {new_changes or 'none'}\n\n"
        f"## Last diagnostics\n```json\n{last_diag}\n```\n",
        encoding="utf-8",
    )
    print(f"[swarm] wrote {HELP_FILE}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
