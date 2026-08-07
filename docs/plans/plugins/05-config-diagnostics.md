# Plan 05: Add universal config scanning and diagnostics

**Commit:** `feat: scan kai config with source diagnostics`  
**Budget:** 350–500 changed code/test lines  
**Depends on:** plan 04

## Goal

Parse universal `config.kai` structure once, retain source spans, and leave
command-specific block bodies to plugin renderers.

## Changes

1. Add a pure scanner for:
   - top-level `<command> {}` and `<command> <backend> {}` blocks;
   - `on linux {}` and `on macos {}` sections;
   - nested braces, quoted strings, escapes, blank lines, and `#` comments.
2. Return located blocks containing command, optional backend, body text, and
   one-indexed line/column positions. Define columns as byte columns for this
   first implementation and document that choice.
3. Return structured core diagnostics for unexpected tokens, unknown host
   names, missing/extra braces, malformed headers, and unterminated strings.
4. Add selection helpers that prefer the current host section and then fall
   back to an unscoped block.
5. Detect duplicate applicable command/backend blocks instead of silently
   choosing the first.
6. Keep bodies opaque. A `pkgs` key, for example, is not interpreted by the
   core scanner.
7. Add data-driven tests to the app root introduced in plan 04 for valid
   current configs, explicit backends, comments/braces inside strings, fallback
   selection, duplicates, and exact representative line/column failures.
8. Do not switch runtime parsing yet; current behavior remains in place until
   plan 06.

## Files

- Add `xkai-bin/Config.roc`.
- Modify `xkai-bin/package.roc` if shared exposure is required.
- Modify `xkai-bin/plugin-tests.roc`; do not rely on undiscovered module-only
  `expect` tests.

## Acceptance criteria

- Every accepted current `config.kai` example scans successfully.
- `shell nix {}` and bare `shell {}` remain distinguishable.
- The scanner ignores braces and comments inside strings.
- Core failures carry stable line and column positions.
- Plugin body text and its starting location are preserved unchanged.
- `zig build ci` passes.

## Not included

- Command ownership, required source enforcement, or renderer invocation.
- Plugin-specific key/type diagnostics.

## Risks

Do not build this with line trimming like the current parser; trimming destroys
locations and quoted-comment semantics. Keep the scanner small and single-pass
rather than introducing a general parser framework.
