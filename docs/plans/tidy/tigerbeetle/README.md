# TigerBeetle tidy reference

Commit-pinned upstream files related to TigerBeetle's `src/tidy.zig` repository linter.
These files are reference material and have not been modified.

## Snapshot

- Repository: <https://github.com/tigerbeetle/tigerbeetle>
- Commit: [`97c7a8ef385270ebe0e1b75959d3d21d134629df`](https://github.com/tigerbeetle/tigerbeetle/commit/97c7a8ef385270ebe0e1b75959d3d21d134629df)
- Commit date: 2026-07-10
- License: Apache-2.0; see [`LICENSE`](LICENSE)

## Files

- [`tidy.zig`](tidy.zig) — the actual repository linter. It checks source and
  documentation properties including banned constructs, control characters,
  line and function length, dead declarations/files, AST conventions, Markdown
  titles, changelog formatting, large Git blobs, Unix permissions, and allowed
  file extensions.
- [`TIGER_STYLE.md`](TIGER_STYLE.md) — TigerBeetle's engineering and style
  guide; this documents the rationale behind many checks enforced by
  `tidy.zig`.
- [`CHANGELOG.md`](CHANGELOG.md) — the upstream changelog. `tidy.zig` validates
  this file directly, and it records the history of tidy/TigerStyle changes.
- [`changelog.zig`](changelog.zig) — TigerBeetle's related changelog-scaffolding
  script.

`tidy.zig` is not standalone: TigerBeetle imports it from `src/unit_tests.zig`,
runs it through the repository's Zig test build, and provides internal `stdx`
modules such as `Shell` and `Snap`.

## Notable history

- [`0dc56248`](https://github.com/tigerbeetle/tigerbeetle/commit/0dc56248b7f3d5e908f1c27018476fe1eaade3d5) — `tidy: validate changelog`
- [`6c39861b`](https://github.com/tigerbeetle/tigerbeetle/commit/6c39861b15e1799bf84956a746c7c9f258c368dc) — `tidy: modernize tidy changelog`
- [`09de971a`](https://github.com/tigerbeetle/tigerbeetle/commit/09de971abf211863e0034832eae07945e3d0b902) — `tidy: start ratcheting function length`

## SHA-256

```text
ee6cbe72fb5f48aae9d4763549ff6de88904294f9d96658f033e2ec4bc714b00  tidy.zig
2b634cd1da3762eb9d352e8d3767a12c335138e649ed2bfc67bd5abd4cd78203  TIGER_STYLE.md
ace9d2e50a73a7c062293d82f3747ea710c33e7fa36f916d66503f6aa0a53324  CHANGELOG.md
df0c334ebf549b346dc6270286fd4557d3db5620fd39bc327b5879a803070ee9  changelog.zig
0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594  LICENSE
```
