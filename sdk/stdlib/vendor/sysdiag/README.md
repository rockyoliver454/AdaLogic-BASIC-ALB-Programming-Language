# alb_sysdiag — PSAPI + SetupAPI C ABI (vendor)

Stable **C ABI** bundling **psapi** (process memory / performance) and
**setupapi** (present hardware device enumeration).

```bat
cd src\stdlib\vendor\sysdiag
build.bat
bin\smoke_device.exe
bin\demo_memory.exe
```

ALB: `INCLUDE "alb_sysdiag.albi"` then `alb_sysdiag_test_probe()`.
