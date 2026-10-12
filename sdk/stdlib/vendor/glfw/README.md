# alb_glfw — GLFW C API/ABI (vendor)

Stable **C ABI** over **glfw3.dll** (dynamic load). Creates OpenGL windows via
GLFW; opaque handles except `alb_glfw_context_window()` which returns the
native `GLFWwindow*` for ImGui / other backends.

## Build

```bat
cd src\stdlib\vendor\glfw
build.bat
bin\smoke_device.exe
```

Runtime needs `glfw3.dll` beside the exe (staged from `third_party/glfw/lib-vc2022`
by `build.bat`).

## API shape

Same pattern as sdl3/opengl: `device_create` (glfwInit), `context_create`
(window + GL context), begin/clear/end frame.

Hint defaults for `context_create`: GL 3.3 core, resizable+visible. Pass negative
`resizable` / `visible` / `core_profile` to force false/compat.

`alb_glfw_context_create_simple` (used by all `test_*` runners) requests **GL
2.1** with no profile hint so fixed-function `glBegin` LearnOpenGL-style demos
work reliably; custom contexts can still request 3.x via `AlbGLFWContextDesc`.
