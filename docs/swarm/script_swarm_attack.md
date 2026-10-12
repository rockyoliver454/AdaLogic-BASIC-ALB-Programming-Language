# swarm_attack.cmd <task.md> [--target path] [--retries N]

Deploys the local swarm on a task file.

- Reads `TARGET: <path>` line in the task file (or --target flag);
  default success check = tools/mcp_server/tests suite
- Wakes llama.cpp server if down (D:\.local\start_llm.cmd)
- Each attempt: aider (CONVENTIONS.md constitution + last diagnostics
  fed back as the prompt), then MCP verify
- Kill-switch: N consecutive failures (default 5) -> git-revert all
  files changed during the run + write HELP_NEEDED.md -> exit 1
- Implementation: tools/swarm/swarm_attack.py
