# Contributing to AdaLogic BASIC

Thanks for helping out. Contact: **contact@alb-lang.org** ·
https://alb-lang.org

## Ground rules

1. **License compatibility.** All contributions are accepted under the
   Apache License, Version 2.0 only. Do not submit GPL/LGPL or
   proprietary-licensed code. New Ada files must carry the standard
   header block (ASCII ALB art + Apache notice + `contact@alb-lang.org`
   + `d/b/a Oliver Softworks`) exactly as the existing sources do.
2. **Keep `NOTICE` frozen.** Never edit or remove attributions. If you
   bundle outside code that ships its own NOTICE, append it at the
   bottom and say so in your PR.
3. **No license gates.** Do not introduce key checks, phone-home, or
   kill switches. This tree builds and runs unlocked, permanently.

## How to send a patch

- Fork, branch from `main`, one concern per branch.
- Ada 2012 / SPARK-subset style to match the tree (`pragma SPARK_Mode`
  where present; no new warnings from `gnatprove`-clean units).
- Prove it builds: `gprbuild -P adalogic_basic_dist.gpr -p` with zero
  errors, and note which of the 18 drivers you smoke-tested.
- Small, reviewable commits with plain-English messages. No generated
  files (`obj/`, `bin/`, `*.o`, `*.ali`, logs) — `.gitignore` covers
  them, keep it that way.
- Open a pull request describing **what**, **why**, and **how tested**.
  A maintainer (contact@alb-lang.org) reviews; expect questions about
  backend parity (`fasm` / `fasm16` / `c` where applicable).

## What not to send

- Secrets, keys, customer data, internal paths — check `git diff`
  before every push.
- Whole vendored toolchains (`deps/`-style drops). Patches reference
  pinned tool versions instead.
- Drive-by reformatting of unrelated files.

## Community

Be kind and stay on-topic. Enforcement follows
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Security issues go to
[SECURITY.md](SECURITY.md), never to a public issue.
