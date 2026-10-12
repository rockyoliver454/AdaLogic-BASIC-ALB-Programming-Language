# alb_wmi — WMI (Wbem) C ABI (vendor)

Stable **C ABI** over Windows Management Instrumentation: connect to a
namespace, run WQL, read string/int properties. Uses ole32/oleaut32/wbemuuid.

```bat
cd src\stdlib\vendor\wmi
build.bat
bin\smoke_device.exe
bin\demo_os.exe
```

ALB: `INCLUDE "alb_wmi.albi"` then `alb_wmi_test_probe()`.
