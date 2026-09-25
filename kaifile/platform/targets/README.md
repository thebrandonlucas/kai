# Vendored linker inputs

The Kaifile platform links a fully static musl executable. Only
`libhost.a` is built here (`zig build`); everything else is vendored so a
fresh clone needs no other checkout.

| Target    | File               | sha256                                                             |
|-----------|--------------------|--------------------------------------------------------------------|
| x64musl   | `crt1.o`           | `81944a3956f6ad88cce66864e7320440e790d1a8f87c258756d13b512af9beab` |
| x64musl   | `libc.a`           | `eb6180dc01e687264012555bf3bd8fd03c3cd511d51b550bf76dc889188767ce` |
| x64musl   | `libzigc.a`        | `2967acf143e797351c51fc51cf2a97f0d9175a205491ca195a85ccc5fa581fae` |
| x64musl   | `libcompiler_rt.a` | `3156915fa44c6259a5ae5e2f195e711f82b845ff7a93eb9c9bb329de1c78bda6` |
| arm64musl | `crt1.o`           | `c3cd004e4fff012d051a0135121076c3bcdd9e01f9dfd8bbbf69ffecf2ec6ae8` |
| arm64musl | `libc.a`           | `1f48cd7f12e3b254beb2468bc1b3ac839ff1791537ddc7ae91e7e207b02a9b40` |
| arm64musl | `libzigc.a`        | `b85cc7040798f29caf14d401e47834364f34d8ee845e1cd6d0562e3edfa39d3a` |
| arm64musl | `libcompiler_rt.a` | `6d2c4b0b2c09371480fa251914fa9edf44b51f9f4cbc1cbfb449efb76dda1ab4` |

Source: [roc-platform-template-zig](https://github.com/lukewilliamboswell/roc-platform-template-zig)
release `link-inputs-sha256-2df3df339dfb1ad4ae1fad0f382cc100c5b31b3921cdeff939f6aea51457886d`
(`link-inputs-all.tar`, sha256 `e54e6ed10fd433f55c9ab9d1b8ff346739b5c9d21f24c833cd0be4785393aef4`),
built from commit `4051337809b72aedddf87dbcf7d885cdbcf13309`.

Verify with `(cd kaifile/platform/targets && sha256sum -c x64musl.sha256 arm64musl.sha256)`.
