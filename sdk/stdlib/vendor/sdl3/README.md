# alb_sdl3 — SDL3 C API/ABI (vendor)

Stable **C ABI** over **SDL3.dll** (dynamic load). Separate from
`vendor/sdl2` — do not mix.

## Build

```bat
cd src\stdlib\vendor\sdl3
build.bat
bin\smoke_device.exe
```

Runtime needs `SDL3.dll` beside the exe (staged from `release/support` by `build.bat`).

## API shape

Same pattern as d3d12/vulkan/opengl: `device_create` (SDL_Init),
`context_create` (CreateWindowAndRenderer), begin/clear/end frame.
