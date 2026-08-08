# TigerBeetle `tidy.zig`

[`tigerbeetle/tidy.zig`](tigerbeetle/tidy.zig) is a repository-specific linter written as Zig
tests. Its main check streams Git-tracked files once and aggregates file/line diagnostics; its
specialized repository checks cover Git history and metadata. Any violation fails the test suite.

## Enforced rules

- **All text files:** reject tabs and carriage returns, with narrow format-specific exceptions (for
  example Go and Visual Studio files). Known binary image formats are skipped.
- **Zig source:** reject a project-specific list of unsafe or superseded APIs and leftover `FIXME`
  or `dbg` reminders; limit lines to 100 Unicode codepoints with explicit exceptions; require
  CamelCase type-producing function names to end in `Type`; and heuristically reject unused private
  declarations.
- **Zig AST:** require parentheses when mixing arithmetic and bitwise operators and a blank line
  after a `defer` group. The function-length ratchet rejects functions in the current 71–72 line
  “red zone.” Some generated, platform, and intentionally wide files have explicit exemptions.
- **Markdown:** require exactly one top-level `# Title` in documents longer than two lines, ignoring
  headings inside fenced code blocks.
- **Repository structure:** flag imported `.zig` files not tracked by Git and tracked `.zig` files
  never imported, except known entry points. This is a basename/import-text heuristic, not compiler
  reachability analysis.
- **Repository hygiene:** validate changelog line length, trailing whitespace, and tracking URLs;
  reject Git-history blobs over 256 KiB except an allowlist; enforce expected Unix file modes; and
  allow only known file extensions or explicit exceptions.

The exact bans and exceptions are policy encoded in the file rather than general Zig rules. See
[`tigerbeetle/TIGER_STYLE.md`](tigerbeetle/TIGER_STYLE.md) for their rationale.

## Invocation

TigerBeetle imports `src/tidy.zig` from `src/unit_tests.zig`, and its build graph runs that test
binary from the repository root. The focused lint command is:

```console
./zig/zig build test -- tidy
```

The `-- tidy` argument is a Zig test-name filter. The checks also run as part of the unfiltered
`./zig/zig build test` suite and the CI entry point, `./zig/zig build ci`.

The reference copy here is not standalone: it depends on TigerBeetle's `stdx` modules (`Shell`,
`Snap`, and helpers), its build configuration, repository paths, and Git history.
