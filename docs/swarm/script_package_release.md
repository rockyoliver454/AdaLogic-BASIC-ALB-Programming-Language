# package_release.cmd [outdir]

Assembles the self-contained release (NOT committed to git).

- Copies: sdk/bin, config, support, stdlib headers, models, agent,
  tools, docs, examples, .albproj + top-level docs
- Pulls heavy deps from C:\ALB\deps (gnat, gprbuild, w64devkit, FASM,
  python, node) into <out>\deps\
- Writes <out>\alb.cmd shim (sets PATH internally)
- Zips to <out>.zip via Compress-Archive
- Default outdir: D:\ALB_Release
