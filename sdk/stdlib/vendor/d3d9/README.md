# alb_d3d9 — thin Direct3D 9 C API/ABI (vendor)

Stable **C ABI** over **IDirect3D9 / IDirect3DDevice9**, plus thin
`alb_d3d9_*` wrappers for raw device calls. Opaque handles; COM stays
inside the DLL.

**ABI 0.3** (x64, MSVC): **breaking** vs 0.2 — the fat demo API is gone from
the DLL (`context_draw_*`, `test_*`, `run_all_features`, `SHAPE_*`). Demos now
live under `examples/` and link as applications. The DLL is D3D9 lifecycle +
raw device wrappers only.

## Layout

```
include/alb_d3d9.h                public C header (ABI 0.3)
src/alb_d3d9.c                    device + HWND present context
src/alb_d3d9_raw.c                thin alb_d3d9_* device forwards
examples/alb_d3d9_app_demos.*     former draw_* / test_* (app-local)
examples/demo_all_features_app.c  live dual-window Nuklear/OpenBLAS demo
examples/demo_all_features.c      C host for demo_d3d9_run_all_features()
examples/demo_all_features.alb    ALB application harness
bin/                              build output (dll/lib/exe)
build.bat                         MSVC x64 build (deps/msvc)
alb_d3d9.albi                     ALB IMPORT_DLL thin binding (VERSION 0.3)
```

## Build

```bat
cd src\stdlib\vendor\d3d9
build.bat
bin\smoke_device.exe
bin\run_tests.exe
bin\demo_all_features.exe        :: C live dual-window (app, not DLL)
bin\alb_demo_all_features.exe    :: ALB harness → alb_d3d9_app.dll
```

`build.bat` links **only** `alb_d3d9.obj` + `alb_d3d9_raw.obj` + `d3d9` /
`user32` / `gdi32` into `alb_d3d9.dll`. OpenBLAS / Nuklear / GLFW are linked
into `alb_d3d9_app.dll` only and staged beside demos.

## Device-first raw API

Raw wrappers take `AlbD3D9Device*` as the first argument (cast from `S64` in
ALB). Obtain via `alb_d3d9_context_device()` after `create_simple` /
`begin_frame`, or from `alb_d3d9_device_create()`.

```c
void* ctx = alb_d3d9_context_create_simple(640, 480);
AlbD3D9Device* dev = alb_d3d9_context_device(ctx);
alb_d3d9_context_begin_frame(ctx);
alb_d3d9_Clear(dev, ALB_D3D9_CLEAR_TARGET | ALB_D3D9_CLEAR_ZBUFFER,
               alb_d3d9_color_rgba(0.1f, 0.2f, 0.4f, 1.f), 1.f, 0);
/* ... SetFVF / DrawPrimitiveUP ... */
alb_d3d9_context_end_frame(ctx, 1);
alb_d3d9_context_destroy(ctx);
```

`create_simple()` opens a real `WS_OVERLAPPEDWINDOW` titled
`alb_d3d9 ALL FEATURES | ESC quit`. ESC / Q / close sets `should_close`;
call `alb_d3d9_poll_events()` each frame.

Calling convention: `__cdecl`. Export macro: `ALB_D3D9_API`.
