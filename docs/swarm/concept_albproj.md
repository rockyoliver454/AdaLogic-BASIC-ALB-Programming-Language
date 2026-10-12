# .albproj — project manifest

File at project root. Line format:

    name = my_project
    include_dir = sdk/stdlib/lang
    include_dir = lib          # relative to the .albproj file

Resolution: nearest ancestor .albproj to the .alb file wins.
include_dir .alb/.albi files are injected into the compile staging dir
so `INCLUDE "input.albi"` works with no hardcoded path. Files beside the
source always win. Full spec: tools/mcp_server/docs/albproj_spec.md
