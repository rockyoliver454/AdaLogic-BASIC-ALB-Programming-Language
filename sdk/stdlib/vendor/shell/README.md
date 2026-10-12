# alb_shell — Shell32 + DWM C ABI (vendor)

Stable **C ABI** bundling **shell32** (known folders, ShellExecute) and
**dwmapi** (composition, colorization, dark mode, frame extend).

```bat
cd src\stdlib\vendor\shell
build.bat
bin\smoke_device.exe
bin\demo_folders.exe
```

ALB: `INCLUDE "alb_shell.albi"` then `alb_shell_test_probe()`.
