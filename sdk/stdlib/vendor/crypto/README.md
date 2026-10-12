# alb_crypto — CNG (BCrypt) C ABI (vendor)

Stable **C ABI** over **bcrypt** (CNG): SHA-256 / SHA-1 / MD5, HMAC-SHA256,
and secure random.

```bat
cd src\stdlib\vendor\crypto
build.bat
bin\smoke_device.exe
bin\demo_hash.exe
```

ALB: `INCLUDE "alb_crypto.albi"` then `alb_crypto_test_probe()`.
