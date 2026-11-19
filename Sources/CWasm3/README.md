# wasm3 (vendored)

[wasm3](https://github.com/wasm3/wasm3) v0.5.0, commit `6b8bcb1e07bf26ebef09a7211b0a37a446eafd52`, MIT licence
([LICENSE](LICENSE)). Only the twelve core units are built (`m3_bind`, `m3_code`, `m3_compile`, `m3_core`, `m3_emit`,
`m3_env`, `m3_exec`, `m3_function`, `m3_info`, `m3_module`, `m3_optimize`, `m3_parse`); wasm3's own WASI, libc and
tracer are left out because `FM1Host` provides the few WASI stubs the `.rfm1` format allows.

`wasm3.h` and `wasm3_defs.h` live in `include/` so Swift can see them; everything else is in `source/`.

## Local changes

Both are marked `fm1-pocket-mac` in the source, and both match what the `.rfm1` format's own iOS host
(RemoteFM1IOS) found necessary:

1. `source/m3_core.c`, `m3_Realloc`: a first allocation (a module's linear memory) uses `calloc`, so memory a
   firmware never touches costs no RAM.
2. `source/m3_config.h`: `d_m3MaxDuplicateFunctionImpl` is 32 (was 3). Toolchains that fold identical functions can
   give one function several export names, and with 3 wasm3 dropped the extras (e.g. `rfm1_flash_sync`).
