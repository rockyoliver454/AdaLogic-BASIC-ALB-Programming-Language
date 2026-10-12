# alb_d3d10 - Direct3D 10 C API/ABI (vendor)

Stable **C ABI** over **ID3D10Device** + DXGI swapchain (x64, MSVC). Same
device/context shape as d3d9/d3d11/d3d12.

```bat
cd src\stdlib\vendor\d3d10
build.bat
bin\smoke_device.exe
bin\run_tests.exe
bin\alb_demo_all_features.exe
```

## ABI 0.2 - all-features overhaul (mirrors d3d9 / opengl)

- `alb_d3d10_test_depth_texture` - DSV clear + `UpdateSubresource` texture +
  depth-tested textured draw (occlusion query proves the depth test)
- `alb_d3d10_test_msaa_query_scissor` - MSAA RT + `ResolveSubresource`,
  EVENT / TIMESTAMP queries (soft-skip), scissor rects
- `alb_d3d10_test_all_shapes` - cycle `ALB_D3D10_SHAPE_*` via dynamic VB +
  `IASetPrimitiveTopology`
- `alb_d3d10_run_all_features` - live D3D10 window + Nuklear CONTROL panel +
  OpenBLAS (shapes / BLAS modes / GPU gates)

D3D10 has no compute / ExecuteIndirect: those gates soft-map to an EVENT
query marker and `DrawInstanced`. Shape / topology enum values match d3d9.

ALB binding: `alb_d3d10.albi`; ALB harness: `examples/demo_all_features.alb`
(staged as `bin\alb_demo_all_features.exe`).
