# alb_sdl2 — SDL2 C API/ABI (legacy vendor)

Stable **C ABI** over **SDL2.dll** (dynamic load). Kept separate from
`vendor/sdl3` for legacy compatibility.

## Build

```bat
cd src\stdlib\vendor\sdl2
build.bat
bin\smoke_device.exe
```

Runtime needs `SDL2.dll` beside the exe (staged from `deps/odin/dist/vendor/sdl2` by `build.bat`).

## API shape

Same pattern as d3d12/vulkan/opengl: `device_create` (SDL_Init), 
`context_create` (window+renderer), begin/clear/end frame.
