# alb_win32 — Win32 C API/ABI (vendor)

Stable **C ABI** over **user32 / gdi32 / kernel32**. Creates windows and
exposes `HWND` via `alb_win32_window_hwnd()` for D3D / OpenGL / Vulkan.

## Build

```bat
cd src\stdlib\vendor\win32
build.bat
bin\smoke_device.exe
```

## API shape

- `device_create` — register window class (`HINSTANCE`)
- `window_create` — `CreateWindowEx` (hidden/overlapped/popup styles)
- `poll_events` / `should_close` / client size helpers
