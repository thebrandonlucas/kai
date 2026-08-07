# Plan 02: Split the standard plugin into modules

**Commit:** `refactor: split standard plugin components`  
**Budget:** 250–450 changed code/test lines  
**Depends on:** plan 01

## Goal

Prove the intended source layout while preserving the current callback-based
runtime path.

## Changes

1. Add:
   - `plugins/commands/Shell.roc` for shell command metadata;
   - `plugins/backends/Nix.roc` for the Nix determinate backend;
   - `plugins/implementations/ShellNix.roc` for shell parsing, target mapping,
     Nix rendering, and action templates.
2. Reduce `plugins/StdPlugin.roc` to assembly of the three component lists plus
   a small temporary callback adapter that delegates to `ShellNix`.
3. Update `plugins/main.roc` so all standard modules are available in the Roc
   package.
4. Embed and stage each standard module in `xkai-bin/main.roc`; standard plugin
   source must remain a compile-time input and must never appear in `.kai`.
5. Add data-driven pure tests to `xkai-bin/plugin-tests.roc` around shell
   parsing/rendering:
   - zero packages is valid;
   - one and two packages render correctly;
   - all four supported OS/architecture targets choose the correct Nix system;
   - malformed package data and empty package names produce diagnostics.
6. Preserve current platform-specific and unscoped `shell {}` behavior.

## Files

- Add `plugins/commands/Shell.roc`.
- Add `plugins/backends/Nix.roc`.
- Add `plugins/implementations/ShellNix.roc`.
- Modify `plugins/StdPlugin.roc`.
- Modify `plugins/main.roc`.
- Modify `xkai-bin/main.roc`.
- Modify `xkai-bin/plugin-tests.roc`.
- Modify `scripts/test-xkai-portability.sh` only if fixture coverage is needed.

## Acceptance criteria

- `StdPlugin.roc` contains registry assembly, not shell parsing or Nix output
  construction.
- `kai shell` still writes `.kai/flake.nix` and runs
  `nix develop path:.kai#default`.
- The standard plugin's pure tests cover 0, 1, and 2 packages.
- No standard plugin source is written to the project or retained in the xkai
  temporary directory.
- `zig build ci` passes.

## Not included

- Generic discovery of custom plugin subdirectories.
- Guix behavior.
- Registry validation.

## Risks

Roc package exposure may require module names to match nested paths exactly.
Prove the smallest standard tree first; if package wiring alone makes the
commit exceed budget, split package staging from test expansion.
