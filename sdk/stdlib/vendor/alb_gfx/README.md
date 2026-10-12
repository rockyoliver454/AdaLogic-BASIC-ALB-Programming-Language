# alb_gfx — Universal Graphics RHI (thick ABI 0.3)

Thick RHI DLLs exporting identical `gfx_*` cdecl symbols. Each DLL links one
thin vendor backend under `stdlib/vendor/`:

| RHI DLL | Thin backend | Arch |
|---------|--------------|------|
| `alb_gfx_opengl.dll` | `../opengl` (`alb_opengl.lib`) | x64 |
| `alb_gfx_vulkan.dll` | `../vulkan` | x64 |
| `alb_gfx_d3d6.dll` | `../d3d6` | **Win32/x86** |
| `alb_gfx_d3d7.dll` | `../d3d7` | **Win32/x86** |
| `alb_gfx_d3d8.dll` | `../d3d8` | **Win32/x86** |
| `alb_gfx_d3d9.dll` | `../d3d9` | x64 |
| `alb_gfx_d3d10.dll` | `../d3d10` | x64 |
| `alb_gfx_d3d11.dll` | `../d3d11` | x64 |
| `alb_gfx_d3d12.dll` | `../d3d12` | x64 |
| `alb_gfx.dll` | convenience copy of **opengl** | x64 |

**d3d6 / d3d7 / d3d8** RHI DLLs are **32-bit**. Portable MSVC here is x64-only,
so they are built with i686 mingw (same as the thin vendors). A **64-bit ALB
NASM exe cannot `LoadLibrary` them** — use a Win32 host or stick to
d3d9/d3d10/d3d11/d3d12/opengl/vulkan for PE64 programs.

## ALB usage

```alb
INCLUDE <alb_gfx.albi>   -- after alb.exe --gfx= / stdlib search patch
-- or relative: INCLUDE "../alb_gfx.albi"
```

Compiler option: `alb.exe --gfx=opengl|vulkan|d3d6|d3d7|d3d8|d3d9|d3d10|d3d11|d3d12`
stages/selects the matching `alb_gfx_*.dll` as the runtime `alb_gfx.dll`
binding target. The ALBI always imports from `"alb_gfx.dll"`.

Place `alb_gfx.dll` **and** the matching thin DLL (`alb_opengl.dll`, etc.)
beside the program.

**ALB `|` is STRING CONCAT** — never bitwise OR.

## Vertex layout

Interleaved **float XYZ + float RGBA** (7 floats, **stride 28**).
`gfx_pipeline_create` currently ignores shader source pointers (NULL OK)
and only stores topology.

## Build

```bat
cd stdlib\vendor\alb_gfx
build.bat
```

Outputs under `bin/`: backend RHI DLLs, `alb_gfx.dll`, staged thin DLLs,
`smoke_gfx.exe` (opengl), and `smoke_gfx_d3d11.exe`.

## Smoke

```bat
bin\smoke_gfx.exe
bin\smoke_gfx_d3d11.exe
```

Expect `smoke_gfx PASS` (gfx_init → clear loop → shutdown, exit 0).

ALB sample: `examples/smoke_triangle.alb` (relative INCLUDE until compiler
patch).

## Backend notes

- **OpenGL** — full path: VBO + client `VertexPointer`/`ColorPointer` +
  `DrawArrays` (fixed-function / FVF-like).
- **D3D9** — FVF `XYZ+DIFFUSE`; float RGBA packed to D3DCOLOR on upload;
  `DrawPrimitive`.
- **Vulkan** — real lifecycle/clear; buffers host-visible; `draw_arrays`
  uses a soft CPU triangle raster + `alb_vk_present_pixels` (no real PSO yet).
- **D3D6 / D3D7 / D3D8 / D3D10 / D3D11** — soft RHI (`alb_gfx_d3d_soft.inc.c`):
  real lifecycle/clear; CPU shadow buffers; `draw_arrays` calls
  `alb_d3dN_context_draw_hello_triangle` once per frame; viewport/scissor and
  indexed draw are soft no-ops; poll/should_close/sleep stubbed.
- **D3D12** — real lifecycle/clear + UPLOAD buffer map; `draw_*` is a safe
  soft no-op (present context command list / PSO not exposed on thin ABI).

Optional C helpers (exported, not in ALBI yet): `gfx_poll_events`,
`gfx_should_close`, `gfx_sleep_ms`.
