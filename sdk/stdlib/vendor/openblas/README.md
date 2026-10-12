# alb_openblas — OpenBLAS C API/ABI (vendor)

Stable **C ABI** over **libopenblas.dll** (dynamic load). **v0.2** expands to:

- OpenBLAS runtime: threads / procs / parallel / config / corename / `has()`
- CBLAS Level-1 (s/d): dot, axpy, axpby, nrm2, asum, sum, iamax/iamin, scal, copy, swap, rot/rotg/rotm
- CBLAS Level-2: gemv, ger, symv, syr, trmv, trsv
- CBLAS Level-3: gemm, symm, syrk, syr2k, trmm, trsm
- Extensions: omatcopy, geadd
- LAPACKE: gesv, getrf/getri/getrs, potrf/potrs, gels, gesvd, geev, syev, geqrf, trtrs, lange, lamch, lacpy

## Build

```bat
cd src\stdlib\vendor\openblas
build.bat
bin\run_tests.exe
bin\demo_kitchen.exe
```

Runtime needs `libopenblas.dll` beside the exe (staged from
`third_party/openblas_extract/bin` by `build.bat`, OpenBLAS 0.3.29 x64).

## API shape

`device_create` loads the DLL and optionally sets thread count.
CBLAS order/transpose/uplo/diag/side enums match upstream
(`ROW_MAJOR=101`, `NO_TRANS=111`, `UPPER=121`, …).
LAPACK helpers return `info` (0 = success). Missing symbols soft-fail
(`has()` / no-op / `info=-1000`).
