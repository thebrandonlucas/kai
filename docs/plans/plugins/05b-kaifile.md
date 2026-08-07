# Plan 05b: Adopt `Kaifile` as the project manifest

**Commit:** `feat: adopt Kaifile project manifest`  
**Budget:** 100–200 changed code/test lines  
**Depends on:** plan 05

## Goal

Use the distinctive, tool-owned `Kaifile` name for Kai's canonical project
manifest instead of the generic `config.kai` name.

## Changes

1. Make `Kaifile`, with that exact capitalization, the configuration file read
   by `kai`.
2. Rename the repository and custom-plugin example manifests and update shell
   integration fixtures accordingly.
3. Update diagnostics, documentation, the plugin spec, and remaining source
   comments to call the project manifest `Kaifile`.
4. Keep `.kai/` reserved for generated backend output. Reserve the `.kai`
   extension for possible additional Kai source files rather than using it for
   the canonical manifest.
5. Do not silently fall back to `config.kai`; one canonical name avoids
   ambiguous behavior when both files exist.

## Files

- Modify `xkai-bin/Executor.roc`.
- Rename `config.kai` to `Kaifile`.
- Rename `examples/custom-plugin/config.kai` to
  `examples/custom-plugin/Kaifile`.
- Modify `scripts/test-xkai-portability.sh`.
- Modify `scripts/test-xkai-projects.sh`.
- Modify `README.md`, `docs/design.md`, and `plugins/spec.md`.
- Update other source comments or plan references that describe the runtime
  manifest where needed.

## Acceptance criteria

- `kai` reads `Kaifile` and reports that name when the manifest is missing or
  invalid.
- Stock and custom-plugin integration tests use `Kaifile`.
- User-facing documentation consistently calls the canonical manifest
  `Kaifile`.
- `.kai/` remains generated backend output only.
- `zig build ci` passes.

## Not included

- A `--config` option for selecting another path.
- Imports, includes, or multiple `.kai` source files.
- Compatibility fallback for `config.kai`.

## Risks

The rename is intentionally breaking. Keep it in one focused commit so source,
fixtures, examples, and documentation cannot disagree about which manifest is
canonical.
