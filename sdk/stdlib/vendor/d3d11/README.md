# alb_d3d11 - Direct3D 11 C API/ABI (vendor)

Stable **C ABI** over **ID3D11Device / ID3D11DeviceContext** + DXGI swapchain
(x64, MSVC). Same device/context shape as d3d9/d3d10/d3d12.

```bat
cd src\stdlib\vendor\d3d11
build.bat
bin\smoke_device.exe
bin\run_tests.exe
bin\alb_demo_all_features.exe
```

## ABI 0.2 - all-features overhaul (mirrors d3d10 / d3d9 / opengl)

- `alb_d3d11_test_depth_texture` - `ClearDepthStencilView` + `UpdateSubresource`
  texture + depth-tested textured draw (occlusion query proves the depth test)
- `alb_d3d11_test_msaa_query_scissor` - MSAA RT + `ResolveSubresource`,
  EVENT / TIMESTAMP queries (soft-skip), `RSSetScissorRects`
- `alb_d3d11_test_all_shapes` - cycle `ALB_D3D11_SHAPE_*` via dynamic VB +
  `IASetPrimitiveTopology`
- `alb_d3d11_run_all_features` - live D3D11 window + Nuklear CONTROL panel +
  OpenBLAS (shapes / BLAS modes / GPU gates)

Unlike D3D10, D3D11 has compute + indirect draws, so the live GPU gates are
real: *async compute* = `cs_5_0` `Dispatch` writing the args buffer through a
raw UAV, *execute indirect* = `DrawInstancedIndirect` consuming it (feature
level 11_0+; falls back to `DrawInstanced` otherwise). Points are drawn as
small quads in the overlay (no fixed point size). Shape / topology enum values
match d3d9 / d3d10.

ALB binding: `alb_d3d11.albi`; ALB harness: `examples/demo_all_features.alb`
(staged as `bin\alb_demo_all_features.exe`, PE64).