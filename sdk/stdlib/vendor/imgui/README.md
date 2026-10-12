# alb_imgui — Dear ImGui C API/ABI (vendor)

Stable **C ABI** over **Dear ImGui** with **GLFW** + **OpenGL3** backends.
Pairs with `vendor/glfw` (`alb_glfw_context_window()` → `AlbImGuiContextDesc.glfw_window`).

## Build

```bat
cd src\stdlib\vendor\imgui
build.bat
bin\smoke_device.exe
```

`build.bat` builds `alb_glfw` first if needed, compiles vendored ImGui
(`third_party/imgui`, v1.91.9), and stages `glfw3.dll` / `alb_glfw.dll`.

## API shape

- `alb_imgui_context_create` — CreateContext + ImplGlfw/OpenGL3 Init
- Frame: `alb_imgui_new_frame` → widgets → `alb_imgui_render`
- Widget subset: begin/end, text, button, checkbox, sliders, color edit, demo window

## Runtime

Beside the exe: `alb_imgui.dll`, `alb_glfw.dll`, `glfw3.dll` (system `opengl32.dll`).
