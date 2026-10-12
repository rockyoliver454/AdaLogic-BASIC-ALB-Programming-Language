# alb_d3d8 — Direct3D 8 C API/ABI (vendor)

**Win32/x86 only** — `d3d8.dll` ships only in `SysWOW64` on modern Windows.

ABI **0.2**: `depth_texture` / `msaa_query_scissor` / `all_shapes` / `run_all_features`
(same harness shape as `vendor/d3d9`).

```bat
cd src\stdlib\vendor\d3d8
build.bat
bin\demo_all_features.exe
```

Build uses `deps\mingw-i686` (i686-w64-mingw32). Headers under `third_party/include`.

## All-features demo

- C: `examples/demo_all_features.c` → `bin/demo_all_features.exe` (Win32)
- ALB: `examples/demo_all_features.alb` + `alb_d3d8.albi` (binding surface)

### OpenBLAS / Nuklear on Win32

Stock `vendor/openblas` and `vendor/nuklear` bins are **x64**. The live runner
soft-stubs them unless you place 32-bit DLLs at:

- `../openblas/bin/win32/alb_openblas.dll`
- `../nuklear/bin/win32/alb_nuklear.dll`

Then rebuild with `build.bat` (auto-detects and defines `ALB_D3D8_HAVE_BLAS_NK`).

### ALB host note

Release `alb.exe` / `albt.exe` are currently **x64**, so a compiled `.alb` that
`IMPORT_DLL`s `alb_d3d8.dll` cannot load it at runtime. Use the C
`demo_all_features.exe` to prove the ABI; ship the `.alb` as the language
binding harness (mirrors d3d9).

Live keys (stub UI): `1`–`7` shapes, `N` next, `P` pause, `B` blas-mode,
`M` msaa gate, `T` tex upload, `V` vsync, `ESC`/`Q` quit.

D3D8 soft-skips: no `CreateQuery` / no scissor (viewport clip) / MSAA resolve
via `CopyRects` is unreliable (gate still exercised).
