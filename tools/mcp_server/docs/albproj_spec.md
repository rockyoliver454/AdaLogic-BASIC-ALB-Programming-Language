# .albproj — ALB Project Manifest

## Purpose

Removes hardcoded include paths. A source file can say
`INCLUDE "input.albi"` and the toolchain finds `input.albi` by scanning
the directories listed in the nearest ancestor `.albproj` file.

## Format

Line-based, `#` comments, `key = value` pairs:

```
name = my_project
include_dir = lib
include_dir = ../shared/headers
include_dir = sdk/stdlib/lang
```

- `include_dir` may be relative (to the `.albproj` file) or absolute.
- Multiple `include_dir` lines are allowed; they are searched in order.
- The `.albproj` nearest the source file wins (walked upward to the
  workspace root).

## Resolution rules

1. Files sitting next to the `.alb` source always win — `.albproj`
   injection never overrides a real project file.
2. Only `.alb` / `.albi` files are exposed from `include_dir` entries.
3. Parent-relative includes (`INCLUDE "../X.ALBI"`) still work; the
   staging layer mirrors the real directory layout.
