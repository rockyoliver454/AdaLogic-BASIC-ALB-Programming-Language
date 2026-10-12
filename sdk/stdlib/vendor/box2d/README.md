# alb_box2d — Box2D C API/ABI (vendor)

Stable **C ABI** over **Box2D 3.1** (sources under `third_party/box2d`,
compiled into `alb_box2d.dll`). Opaque world/body handles.

## Build

```bat
cd src\stdlib\vendor\box2d
build.bat
bin\smoke_device.exe
```

## API shape

- `alb_box2d_world_create` / `step` / `destroy`
- `alb_box2d_body_create` — axis-aligned box (static/kinematic/dynamic)
- transform, velocity, force/impulse helpers

No extra runtime DLL — Box2D is linked into `alb_box2d.dll`.
