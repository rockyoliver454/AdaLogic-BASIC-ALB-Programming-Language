# Security Policy — AdaLogic BASIC

**Do not open public issues for vulnerabilities.**
Report privately to **contact@alb-lang.org** (https://alb-lang.org).

## Supported versions

| Tree | Status |
|---|---|
| Latest `main` (this repo, kit v0.0.10.32+) | Supported — report here |
| Older kits / customer snapshots | Best effort; upgrade first |

## How to report

Email **contact@alb-lang.org** with:

1. Affected driver(s) and version (`albt`, `alb`, …) plus host OS.
2. Minimal reproducer (`.alb` source or command line).
3. Impact you see (code execution, file overwrite outside `--outdir`,
   hang/crash with untrusted input, bypass of a documented sandbox such
   as `MEMORY_FIREWALL`, etc.).
4. Whether it is already public, and any CVE/credit preference.

Please keep it confidential until a fix is released. Allow reasonable
time for triage; you will get a human reply, not an autoresponder.

## Scope notes

- **In scope:** the 18 compiler drivers in `bin/`, emitters, standard
  library loaders/parsers shipped here, and the documented sandbox and
  firewall features.
- **Out of scope (but tell us anyway):** bugs in third-party toolchains
  under release `deps/` (FASM, GNAT, Node, …) — report those upstream;
  we will pin or work around them here.
- **Generated programs:** user `.alb` code that misbehaves is the
  author's bug, not a toolchain vulnerability — unless the toolchain
  itself emits unsafe code from safe source.

## Safe harbor

Good-faith research, testing against your own installs, and coordinated
disclosure are welcomed. Do not exfiltrate data, disrupt services, or
break the law; stay within the reproducer you report.
