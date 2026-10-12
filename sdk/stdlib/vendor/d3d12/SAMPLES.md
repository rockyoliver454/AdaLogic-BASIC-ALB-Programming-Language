# Microsoft DirectX Graphics Samples — Desktop D3D12 port tracker

Upstream: `third_party/DirectX-Graphics-Samples/Samples/Desktop`
(https://github.com/microsoft/DirectX-Graphics-Samples)

Goal: every Desktop D3D12 sample runnable via `alb_d3d12` (C demo + ALB).

## Status legend

- `[ ]` not started
- `[~]` in progress / partial (feature-gated soft-skip on this GPU)
- `[x]` ALB/C port runs (real GPU path)
- `[s]` soft-skip (return 0) when HW/OS lacks required feature — still “done” for suite

## D3D12HelloWorld (foundation)

| Sample | Status | Entry |
|--------|--------|-------|
| HelloWindow | [x] | `alb_d3d12_sample_hello_window` |
| HelloTriangle | [x] | `alb_d3d12_sample_hello_triangle` |
| HelloTexture | [x] | `alb_d3d12_sample_hello_texture` |
| HelloConstBuffers | [x] | `alb_d3d12_sample_hello_const_buffers` |
| HelloFrameBuffering | [x] | `alb_d3d12_sample_hello_frame_buffering` |
| HelloBundles | [x] | `alb_d3d12_sample_hello_bundles` |
| HelloTightAlignment | [x] | `alb_d3d12_sample_hello_tight_alignment` (alias small resources) |
| HelloGenericPrograms | [s] | covered by advanced shader delivery skip |
| HelloMeshNodes | [s] | mesh shaders soft-skip |
| HelloPartialGraphicsPrograms | [s] | advanced shader delivery skip |
| HelloVADecode | [s] | `alb_d3d12_sample_hello_va` |
| HelloVAEncode | [s] | `alb_d3d12_sample_hello_va` |
| HelloVAResourceInterop | [s] | `alb_d3d12_sample_hello_va` |
| HelloWorkGraphs | [s] | `alb_d3d12_sample_hello_work_graphs` |
| WorkGraphsSandbox | [s] | same gate as HelloWorkGraphs |

## Other Desktop folders

| Folder | Status | Entry |
|--------|--------|-------|
| D3D12Bundles | [x] | `alb_d3d12_sample_bundles` |
| D3D12Fullscreen | [x] | `alb_d3d12_sample_fullscreen` |
| D3D12nBodyGravity | [x] | `alb_d3d12_sample_nbody_gravity` |
| D3D12Multithreading | [x] | `alb_d3d12_sample_multithreading` |
| D3D12ExecuteIndirect | [x] | `alb_d3d12_sample_execute_indirect` |
| D3D12PipelineStateCache | [x] | `alb_d3d12_sample_pipeline_state_cache` |
| D3D12PredicationQueries | [x] | `alb_d3d12_sample_predication_queries` |
| D3D12DynamicIndexing | [x] | `alb_d3d12_sample_dynamic_indexing` (cycle root CBVs) |
| D3D12ReservedResources | [x] | `alb_d3d12_sample_reserved_resources` |
| D3D12SmallResources | [x] | `alb_d3d12_sample_small_resources` |
| D3D12HDR | [s] | `alb_d3d12_sample_hdr` |
| D3D12DepthBoundsTest | [s]/[x] | `alb_d3d12_sample_depth_bounds_test` |
| D3D12VariableRateShading | [s]/[x] | `alb_d3d12_sample_variable_rate_shading` |
| D3D12SM6WaveIntrinsics | [s]/[x] | `alb_d3d12_sample_sm6_wave_intrinsics` |
| D3D12MeshShaders | [s] | `alb_d3d12_sample_mesh_shaders` |
| D3D12Raytracing | [s] | `alb_d3d12_sample_raytracing` |
| D3D1211On12 | [x] | `alb_d3d12_sample_11on12` (`D3D11On12CreateDevice`) |
| D3D12LinkedGpus | [s] | `alb_d3d12_sample_linked_gpus` |
| D3D12HeterogeneousMultiadapter | [s] | `alb_d3d12_sample_heterogeneous_multiadapter` |
| D3D12Residency | [x] | `alb_d3d12_sample_residency` |
| D3D12On7 | [s] | `alb_d3d12_sample_on7` |
| D3D12xGPU | [s] | `alb_d3d12_sample_xgpu` |
| D3D12AdvancedShaderDelivery | [s] | `alb_d3d12_sample_advanced_shader_delivery` |
| D3D12StateObjectDatabase | [s] | `alb_d3d12_sample_state_object_database` |

## Suite runners

| Runner | What |
|--------|------|
| `alb_d3d12_sample_run_hello_world` | HelloWorld foundation only |
| `alb_d3d12_sample_run_desktop` | HelloWorld + all Desktop folders above |

Fail codes: `sample_base + status` (e.g. fullscreen base `10000`). Soft-skips return `0`.

## Core C ABI (v0.4)

Public low-level surface in `alb_d3d12.h` / `src/alb_d3d12_core.c`:

- Device / factory / queue / allocator / list / resources / descriptors / PSO
- Map/Unmap, root CBV, barriers, CopyBuffer/TextureRegion, depth DSV
- Compute Dispatch + root UAV
- **ExecuteIndirect** → `command_signature_create_draw/dispatch` + `execute_indirect`
- **Async compute** → `QUEUE_COMPUTE` / `CMD_COMPUTE` + `queue_wait_fence`
- **Queries** → `query_heap_create` + begin/end/resolve (+ timestamps via EndQuery×2)
- **MSAA** → `texture2d_create_msaa` + `resolve_subresource` + `pipeline_create_pos_color_msaa`
- Smoke: `test_core_pipeline`, `test_upload_depth_compute`, `test_indirect_async_query_msaa`
- **All-in-one live:** `alb_d3d12_run_all_features()` — OpenBLAS modes + shapes +
  GPU gates + full `alb_nuklear` control panel (second window; ESC/close to quit).
  **ALB entry:** `examples/demo_all_features.alb` → `bin\alb_demo_all_features.exe`
  (thin C host: `bin\demo_all_features.exe`)

## Notes

- Implementation: `src/alb_d3d12_msft.c` (HelloWorld), `src/alb_d3d12_msft_desktop.c`
  (Desktop folders), shared helpers in `src/alb_d3d12_msft_host.h`, core ABI in
  `src/alb_d3d12_core.c`.
- Soft-skip samples check `CheckFeatureSupport` / adapter count and return `0`
  when the local GPU (e.g. GTX 1080 / Server 2019) lacks RT, mesh, VRS, multi-GPU, VA, etc.
- Run live: `build.bat` then `bin\demo_all_features.exe` (needs `alb_openblas.dll`,
  `libopenblas.dll`, `alb_nuklear.dll`, `alb_glfw.dll`, `glfw3.dll` staged beside
  the exe; build.bat copies them).
- Nuklear panel toggles async compute, ExecuteIndirect, depth clear, timestamps,
  MSAA resolve, VSync, BLAS tint, clear/tint/scale, and exercises the full
  `alb_nuklear` widget surface (menus, trees, charts, edit, combo, popups, …).
- Legacy `alb_d3d12_context_draw_*` helpers still use a CPU-raster upload path.
