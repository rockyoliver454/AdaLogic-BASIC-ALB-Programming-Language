# alb_opengl — thin OpenGL C API/ABI (vendor)

Stable **C ABI** over **WGL** + system `opengl32.dll`, plus thin `alb_gl*`
wrappers for raw OpenGL entry points. Opaque handles; `HGLRC` / `HDC` stay
inside the DLL.

**ABI 0.3** (x64, MSVC): **breaking** vs 0.2 — the fat demo API is gone from
the DLL (`context_draw_*`, `test_*`, `run_all_features`, `SHAPE_*`). Demos now
live under `examples/` and link as applications. The DLL is WGL lifecycle +
raw GL only.

## Layout

```
include/alb_opengl.h              public C header (ABI 0.3)
src/alb_opengl.c                  WGL device + HWND present context
src/alb_opengl_gl.c               thin alb_gl* forwards (+ soft extensions)
src/alb_opengl_glext.h            app-private FBO/MSAA helpers (examples)
examples/alb_opengl_app_demos.*   former draw_* / test_* (app-local)
examples/demo_all_features_app.c  live dual-window Nuklear/OpenBLAS demo
examples/demo_all_features.c      C host for demo_opengl_run_all_features()
examples/demo_all_features.alb    ALB raw alb_gl* rotating triangle harness
bin/                              build output (dll/lib/exe)
build.bat                         MSVC x64 build (deps/msvc)
alb_opengl.albi                   ALB IMPORT_DLL thin binding (VERSION 0.3)
```

## Build

```bat
cd src\stdlib\vendor\opengl
build.bat
bin\smoke_device.exe
bin\run_tests.exe
bin\demo_all_features.exe        :: C live dual-window (app, not DLL)
bin\alb_demo_all_features.exe    :: ALB raw-GL harness proving alb_gl*
```

`build.bat` links **only** `alb_opengl.obj` + `alb_opengl_gl.obj` +
`opengl32` / `gdi32` / `user32` into `alb_opengl.dll`. OpenBLAS / Nuklear /
GLFW are linked into `demo_all_features.exe` only and staged beside it.

## Soft-loaded extensions

`alb_gl_load()` resolves buffers, shaders, FBO, query, and `ActiveTexture`
via `wglGetProcAddress` / `GetProcAddress(opengl32)`. Missing entry points
no-op; create-style funcs return 0. Auto-called after successful
`device_make_current` / context bind.

## Quick API

```c
AlbOpenGLDeviceDesc d = { -1, 0, "MyApp" };
AlbOpenGLDevice* dev = NULL;
alb_opengl_device_create(&d, &dev);

void* ctx = alb_opengl_context_create_simple(640, 480);
alb_opengl_context_begin_frame(ctx);
alb_glClearColor(0.1f, 0.2f, 0.4f, 1.0f);
alb_glClear(ALB_GL_COLOR_BUFFER_BIT | ALB_GL_DEPTH_BUFFER_BIT);
alb_glBegin(ALB_GL_TRIANGLES);
/* ... alb_glVertex* / alb_glColor* ... */
alb_glEnd();
alb_opengl_context_end_frame(ctx, 1);
alb_opengl_context_destroy(ctx);
```

Calling convention: `__cdecl`. Export macro: `ALB_OPENGL_API`.
