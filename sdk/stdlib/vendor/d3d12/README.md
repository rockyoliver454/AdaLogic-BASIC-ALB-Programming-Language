# alb_d3d12 — thin Direct3D 12 C API/ABI (vendor)

Stable **C ABI** over **ID3D12 / DXGI**, plus thin `alb_d3d12_*` wrappers for
command lists, resources, PSO, descriptors, barriers, draw/dispatch, and
queries. Opaque handles; COM stays inside the DLL.

**ABI 0.3** (x64, MSVC): **breaking** vs the fat demo API — `context_draw_*`,
`test_*`, `sample_*`, and `run_all_features` are gone from the DLL. Demos now
live under `examples/` and link as applications. The DLL is D3D12/DXGI
lifecycle + raw wrappers only.

## Layout

```
include/alb_d3d12.h                public C header (ABI 0.3)
src/alb_d3d12.c                    device + HWND present context
src/alb_d3d12_core.c               thin command/resource/PSO/query wrappers
src/alb_d3d12_raw.c                ALB memory helpers
examples/alb_d3d12_app_demos.*     former draw_* / test_* (app-local)
examples/alb_d3d12_msft*.c         Microsoft sample ports (app-local)
examples/demo_all_features_app.c   live dual-window Nuklear/OpenBLAS demo
examples/demo_all_features.c       C host for demo_d3d12_run_all_features()
examples/demo_all_features.alb     ALB application harness
bin/                               build output (dll/lib/exe)
build.bat                          MSVC x64 build (deps/msvc)
alb_d3d12.albi                     ALB IMPORT_DLL thin binding (VERSION 0.3)
```

## Build

Requires:

- `deps/msvc` (PortableBuildTools — already used by ALBO)
- Windows 10 SDK with `d3d12.h` (system Kits `10.0.26100.0`)

```bat
cd src\stdlib\vendor\d3d12
build.bat
bin\smoke_device.exe
bin\run_tests.exe
bin\demo_all_features.exe        :: C live dual-window (app, not DLL)
bin\alb_demo_all_features.exe    :: ALB harness → alb_d3d12_app.dll
```

`build.bat` links **only** `alb_d3d12.obj` + `alb_d3d12_core.obj` +
`alb_d3d12_raw.obj` + `d3d12` / `dxgi` / `user32` / `gdi32` into
`alb_d3d12.dll`. OpenBLAS / Nuklear / GLFW are linked into
`alb_d3d12_app.dll` only and staged beside demos.

## Quick API

```c
void* ctx = alb_d3d12_context_create_simple(640, 480);
while (!alb_d3d12_context_should_close(ctx)) {
  alb_d3d12_poll_events();
  alb_d3d12_context_begin_frame(ctx);
  alb_d3d12_context_clear(ctx, 0.1f, 0.2f, 0.4f, 1.f);
  /* raw alb_d3d12_command_list_* / resource_* as needed */
  alb_d3d12_context_end_frame(ctx, 1);
}
alb_d3d12_context_destroy(ctx);
```

`create_simple()` opens a real `WS_OVERLAPPEDWINDOW` titled
`alb_d3d12 ALL FEATURES | ESC quit`. ESC / Q / close sets `should_close`;
call `alb_d3d12_poll_events()` each frame.

Calling convention: `__cdecl`. Export macro: `ALB_D3D12_API`.

## Microsoft Desktop samples (real GPU)

Upstream cloned at `third_party/DirectX-Graphics-Samples` (sparse:
`Samples/Desktop`). Progress: [`SAMPLES.md`](SAMPLES.md).

Sample bodies live in `examples/alb_d3d12_msft*.c` (not in `alb_d3d12.dll`):

```bat
build.bat
bin\demo_msft_hello_world.exe
bin\demo_msft_desktop.exe
```
