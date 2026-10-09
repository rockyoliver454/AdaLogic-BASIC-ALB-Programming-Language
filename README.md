# AdaLogic BASIC (ALB) — Compiler Sources

> **https://alb-lang.org** · **https://alb-lang.com** · **https://alb-lang.dev**
> Contact: **contact@alb-lang.org**

BASIC-style language that compiles to native targets: x86-64 FASM/PE,
16-bit DOS, C, Ada, TypeScript/Web, .NET, Java, Python, Lua, Rust, Haskell,
Odin, C64/6502, Godot, and more — from a single `.alb` source tree.

| | |
|---|---|
| **Web** | **https://alb-lang.org** |
| **Mirrors** | https://alb-lang.com · https://alb-lang.dev |
| **Contact** | contact@alb-lang.org |
| **License** | Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE) |

## Layout

```text
adalogic_basic_dist.gpr   Project file (GNAT/GPRbuild)
COMPILER/  EMITTER/  TYPES/  CORE/     Compiler front + back ends
INTERPRETER/  ALBA/  LOADERS/  MATH/   Runtime, loaders, math
SECURITY/  TESTS/                  Security helpers, test units
bin/       lib/       obj/         Built binaries / libs / intermediates
docs/      third-party/  licenses/ Docs, third-party notices, per-backend licenses
```

## Build

You need GNAT + GPRbuild (the release kit bundles both under
`release/deps/`):

```bat
set PATH=<kit>\release\deps\gprbuild_25.0.1\bin;<kit>\release\deps\gnat_native_15.2.1\bin;%PATH%
gprbuild -P adalogic_basic_dist.gpr -p
```

Binaries land in `bin/` (18 drivers: `alb`, `albt`, `albf`, `alb_65`,
`albj`, `albn`, `alba`, `albw`, `albl`, `albm`, `albnasm`, `albgd`,
`albp`, `albr`, `albh`, `albo`, `albc3`, `alb_player`). No license keys,
no gates — everything runs unlocked.

Try it:

```bat
bin\albt.exe hello.alb -t fasm --build --outdir _build_hello
```

## Contributing / conduct / security

- [CONTRIBUTING.md](CONTRIBUTING.md) — how to send patches
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — community rules
- [SECURITY.md](SECURITY.md) — how to report vulnerabilities (do **not**
  open public issues for those; write to contact@alb-lang.org)

## License

Copyright 2014-2026 Rocky L. Oliver d/b/a Oliver Softworks.
Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).
Attributions in [NOTICE](NOTICE). Per-backend notices in [licenses/](licenses/).

---

*AdaLogic BASIC — https://alb-lang.org — contact@alb-lang.org*
