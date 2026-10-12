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


def check_success(target: str | None) -> tuple[bool, str]:
    """Run the MCP verification for the task target. Returns (ok, diagnostics)."""
    if target:
        t = REPO / target
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
    quickref = QUICKREF.read_text(encoding="utf-8", errors="replace")
    prompt = (
        "CRITICAL: .alb and .albi files contain AdaLogic BASIC — a custom "
        "compiled language. DO NOT write Python, JavaScript, or any other "
        "language in them. Follow this reference exactly:\n\n"
        f"{quickref}\n\n"
        f"=== TASK ===\n{task_text}\n\n"
        f"--- ATTEMPT {attempt} ---\n"
        f"Latest compiler/test diagnostics (fix THIS, do not rewrite blindly):\n"
        f"{diagnostics}\n"
    )
    msg = REPO / "tools" / "swarm" / "_swarm_msg.md"
    msg.write_text(prompt, encoding="utf-8")
    cmd = [
        str(AIDER),
        "--config", str(AIDER_CONF),
        "--read", str(CONVENTIONS),
        "--read", str(QUICKREF),
        "--message-file", str(msg),
        "--map-tokens", "256",
        "--subtree-only",
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

    # Scope aider to the target's directory so it can't wander the repo
    # hoovering files into a small context window.
    work_dir = REPO
    files = []
    if target:
        t = REPO / target
        if t.suffix.lower() in (".alb", ".albi"):
            work_dir = t.parent
            t.touch(exist_ok=True)          # let aider create it if missing
            files.append(t.name)
        elif t.is_dir():
            work_dir = t
    try:
        subprocess.run(
            cmd + files,
            cwd=work_dir,
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
