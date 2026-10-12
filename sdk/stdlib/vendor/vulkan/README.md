# alb_vulkan — thin Vulkan C API/ABI (vendor)

Stable **C ABI** over the Vulkan loader (`vulkan-1.dll`), plus thin `alb_vk*`
wrappers. Opaque handles; `Vk*` objects stay inside the DLL. No Vulkan SDK
required to *build* — headers are self-contained; the ICD is loaded at runtime.

**ABI 0.3** (x64, MSVC): **breaking** vs 0.2 — the fat demo API is gone from
the DLL (`context_draw_*`, `test_*`, `run_all_features`, `SHAPE_*`). Demos now
live under `examples/` and link as applications. The DLL is present lifecycle +
raw Vk wrappers only (plus soft `alb_vk_present_pixels` for CPU-raster upload).

## Layout

```
include/alb_vulkan.h              public C header (ABI 0.3)
src/alb_vulkan.c                  loader + device/context + feature helpers
src/alb_vulkan_raw.c              alb_vulkan_alloc / write_* memory helpers
src/alb_vulkan_features.inc       present_pixels / depth / MSAA / query / alb_vkCmd*
src/alb_vulkan_soft.h             CPU raster (app demos; not public ABI)
examples/alb_vulkan_app_demos.*   former draw_* / test_* (app-local)
examples/demo_all_features_app.c  live dual-window Nuklear/OpenBLAS demo
examples/demo_all_features.c      C host for demo_vulkan_run_all_features()
examples/demo_all_features.alb    ALB harness calling alb_vulkan_app.dll
bin/                              build output (dll/lib/exe)
build.bat                         MSVC x64 build (deps/msvc)
alb_vulkan.albi                   ALB IMPORT_DLL thin binding (VERSION 0.3)
```

## Build

```bat
cd src\stdlib\vendor\vulkan
build.bat
bin\smoke_device.exe
bin\run_tests.exe
bin\demo_all_features.exe        :: C live dual-window (app, not DLL)
bin\alb_demo_all_features.exe    :: ALB harness
```

`build.bat` links **only** `alb_vulkan.obj` + `alb_vulkan_raw.obj` +
`user32` / `gdi32` into `alb_vulkan.dll` (dynamic `vulkan-1.dll`). OpenBLAS /
Nuklear / GLFW are linked into `alb_vulkan_app.dll` only and staged beside demos.

## Soft present path

There is no SPIR-V graphics pipeline in this binding yet. Geometry demos
CPU-rasterize into a linear framebuffer and call `alb_vk_present_pixels`
(staging + `vkCmdCopyBufferToImage`). Real Vulkan objects still exist for
swapchain, depth clear, texture upload, MSAA resolve, timestamps, and scissor.

```c
void* ctx = alb_vulkan_context_create_simple(960, 540);
while (!alb_vulkan_context_should_close(ctx)) {
  alb_vulkan_poll_events();
  alb_vulkan_context_begin_frame(ctx);
  alb_vulkan_context_clear(ctx, 0.1f, 0.2f, 0.4f, 1.0f);
  /* soft: alb_vk_present_pixels(ctx, (int64_t)(intptr_t)pixels); */
  /* or:  alb_vkCmd*(alb_vulkan_context_cmd(ctx), ...); */
  alb_vulkan_context_end_frame(ctx, 1);
}
```

Calling convention: `__cdecl`. Export macro: `ALB_VULKAN_API`.
In ALB source, `|` is string concatenation (never bitwise OR).
