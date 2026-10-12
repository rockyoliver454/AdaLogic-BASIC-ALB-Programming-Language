# alb_nuklear — Nuklear immediate-mode UI (vendor)

Stable **C ABI** over [Nuklear](https://github.com/immediate-mode-ui/nuklear)
(public-domain immediate-mode GUI) with the official **GLFW + OpenGL2** backend.

ALB uses scalar `IMPORT_DLL` entry points in `alb_nuklear.albi`.

## Build

```bat
cd src\stdlib\vendor\nuklear
build.bat
bin\run_tests.exe
```

Requires `alb_glfw` + `glfw3.dll` (staged by `build.bat`).

If `third_party\nuklear` is missing:

```bat
powershell -ExecutionPolicy Bypass -File ..\_fetch_nuklear.ps1
```

## ALB samples (interactive — close the window to exit)

| File | What you see |
|------|----------------|
| `examples/demo_window.alb` → `demo_window.exe` | Official-style Demo panel (button / easy-hard / volume) |
| `examples/widgets.alb` → `widgets.exe` | Sliders, checkbox, property, color picker |
| `examples/overview.alb` → `overview.exe` | Official Nuklear `overview.c` |
| Kitchen sink | Menubar, themes, combo, edit, tree, group, chart, plot, knob, progress, space layout |

C demos in `bin\`: `demo_demo.exe`, `demo_widgets.exe`, `demo_overview.exe`, `demo_kitchen.exe`.

Automated (hidden) smoke: `bin\run_tests.exe` / `alb_nuklear_test_*_frames` (incl. kitchen).

API v0.2 expands windows, layout templates/space, buttons/symbols, selectable, knob,
progress, edit, combo, tree, group, chart/plot, popup/contextual/menu/tooltip, themes.

## Notes

- OpenGL2 backend needs no GLEW (works with alb_glfw GL 2.1).
- One active Nuklear context per process (backend uses global GLFW glue).
