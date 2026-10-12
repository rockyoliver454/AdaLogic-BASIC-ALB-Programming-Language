# alb_ntkernel — NT Native API C ABI (vendor)

Stable **C ABI** over **ntdll.dll** (user-mode NT kernel interface). This is
**not** a kernel-mode driver — it dynloads `RtlGetVersion`,
`NtQuerySystemInformation`, `NtDelayExecution`, `NtAllocateVirtualMemory`, etc.

```bat
cd src\stdlib\vendor\ntkernel
build.bat
bin\smoke_device.exe
```
