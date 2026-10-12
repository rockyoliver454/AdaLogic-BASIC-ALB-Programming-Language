# alb_d3d6 — Direct3D 6 C API/ABI (vendor)

**Win32/x86 only** — SysWOW64 `ddraw.dll` / `d3dim*.dll`.

Prefers DirectDraw4 + IDirect3D3 (Device3 + Viewport3). On modern Windows where
IDirect3D3 QI fails, falls back to DirectDraw7 + IDirect3D7 (same runtime as
`alb_d3d7`) while keeping the `alb_d3d6_*` C ABI.

ABI **0.2**: `depth_texture` / `msaa_query_scissor` / `all_shapes` / `run_all_features`
(same harness shape as `vendor/d3d7`, `vendor/d3d8` and `vendor/d3d9`).

```bat
cd src\stdlib\vendor\d3d6
build.bat
bin\alb_demo_all_features.exe
```

Build uses `deps\mingw-i686` (i686-w64-mingw32). Headers under `third_party/include`.

## All-features demo

- C: `examples/demo_all_features.c` -> `bin/demo_all_features.exe` (Win32)
- ALB: `examples/demo_all_features.alb` + `alb_d3d6.albi` (binding surface)
- `bin/alb_demo_all_features.exe` is a **copy of the Win32 C twin** (x86), because
  `alb.exe` emits PE64 only and cannot `LoadLibrary` the x86 `alb_d3d6.dll`.
  `build.bat` still compiles the `.alb` into `bin/_alb/` to validate the bindings.

Live runner (`src/alb_d3d6_all_features.c`): D3D6 960x540 window + a second
Nuklear **GDI** CONTROL window (860x780, upstream `nuklear_gdi.h` embedded — no
`alb_nuklear.dll`) and soft software BLAS (OpenBLAS DLLs are x64-only).
Backend-specific work goes through helpers in `src/alb_d3d6_internal.h`, which
branch on Device3 vs Device7 like the `draw_*` functions.

Live keys: `1`–`7` shapes, `N` next, `P` pause, `B` blas-mode, `M` msaa gate,
`T` tex upload, `V` vsync, `ESC`/`Q` quit.

## D3D6 notes / soft-skips

- Back buffer gets a soft-attached z-buffer surface (HAL, then RGB device; falls
  back to no-z if unavailable) on **both** backends, so `depth_texture` and the
  live depth gate work.
- Vertices are `D3DFVF_TLVERTEX`; `DrawPrimitive` takes a **vertex** count.
- Device3 path: clear via `Viewport3::Clear2`, viewport via `SetViewport2`,
  textures are `DDSCAPS_TEXTURE` surfaces on `IDirectDraw4` bound as
  `IDirect3DTexture2`. Device7 path: same as `alb_d3d7`.
- No multisample surfaces, no queries, no scissor rect, no point-size state:
  MSAA/query gates are no-ops, scissor is a smaller viewport (the full viewport
  is restored before clearing), and points are drawn as small triangle-pair quads.
- "ExecuteIndirect" gate: dynamic `IDirect3DVertexBuffer7` + `DrawPrimitiveVB`
  on the DX7 backend; soft-skips to plain `DrawPrimitive` on Device3.