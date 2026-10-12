# alb_com — OLE32 / OLEAUT32 C ABI (vendor)

Stable **C ABI** over **ole32** + **oleaut32**: apartment init,
create-by-ProgID/CLSID, IDispatch property get / method0, BSTR helpers.

```bat
cd src\stdlib\vendor\com
build.bat
bin\smoke_device.exe
bin\demo_dict.exe
```

ALB: `INCLUDE "alb_com.albi"` then `alb_com_test_probe()`.
