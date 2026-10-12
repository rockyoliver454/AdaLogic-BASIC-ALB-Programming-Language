# alb_d3d7 — Direct3D 7 C API/ABI (vendor)

**Win32/x86 only** — `d3dim700.dll` is SysWOW64-only. Uses DirectDraw7 + IDirect3D7.

ABI **0.2**: `depth_texture` / `msaa_query_scissor` / `all_shapes` / `run_all_features`
(same harness shape as `vendor/d3d8` and `vendor/d3d9`).

```bat
cd src\stdlib\vendor\d3d7
build.bat
bin\demo_all_features.exe
```

Build uses `deps\mingw-i686` (i686-w64-mingw32). Headers under `third_party/include`.

## All-features demo

- C: `examples/demo_all_features.c` → `bin/demo_all_features.exe` (Win32)
- ALB: `examples/demo_all_features.alb` + `alb_d3d7.albi` (binding surface)
- `bin/alb_demo_all_features.exe` is a **copy of the Win32 C twin** (x86), because
  `alb.exe` emits PE64 only and cannot `LoadLibrary` the x86 `alb_d3d7.dll`.
  `build.bat` still compiles the `.alb` into `bin/_alb/` to validate the bindings.

Live runner (`src/alb_d3d7_all_features.c`): D3D7 960x540 window + a second
Nuklear **GDI** CONTROL window (860x780, upstream `nuklear_gdi.h` embedded — no
`alb_nuklear.dll`) and soft software BLAS (OpenBLAS DLLs are x64-only).

Live keys: `1`–`7` shapes, `N` next, `P` pause, `B` blas-mode, `M` msaa gate,
`T` tex upload, `V` vsync, `ESC`/`Q` quit.

## D3D7 notes / soft-skips

- Back buffer gets a soft-attached z-buffer surface (HAL, then RGB device; falls
  back to no-z if unavailable) so `depth_texture` and the live depth gate work.
- Vertices are `D3DFVF_TLVERTEX`; `DrawPrimitive` takes a **vertex** count.
- No multisample surfaces, no queries, no scissor rect, no point-size state:
  MSAA/query gates are no-ops, scissor is a smaller viewport (D3D7 `Clear`
  honours the viewport, so the full viewport is restored before clearing), and
  points are drawn as small triangle-pair quads.
- "ExecuteIndirect" gate stages vertices in a dynamic `IDirect3DVertexBuffer7`
  and draws with `DrawPrimitiveVB` (falls back to `DrawPrimitive`).
