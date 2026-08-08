# Plan 06b: Migrate the standard plugin to registry dispatch

**Commit:** `refactor: dispatch standard plugin registry`  
**Budget:** 200–400 changed code/test lines  
**Depends on:** plan 06

## Goal

Move the existing Nix shell behavior onto the proven generic path without also
removing custom callback compatibility.

## Changes

1. Replace the standard plugin's temporary callback adapter with its registry
   definition.
2. Make `ShellNix.roc` consume the validated `pkgs` string list from its
   `RenderContext`. Retain the located raw body only for semantic failures that
   need body-relative `RendererDiagnostic` values.
3. Route `kai shell` through core source selection, required-source checks,
   renderer invocation, named-output lowering, and the common executor.
4. Preserve Nix as the default backend and support explicit
   `kai shell nix`; command arguments, if later added, must follow `--`.
5. Expand portability integration coverage for host fallback, malformed core
   syntax, malformed `pkgs`, zero packages, and failures before effects.
6. Delete only the standard adapter. The single-file custom callback remains
   until plan 07 so this commit isolates stock behavior changes.

## Files

- Modify `plugins/StdPlugin.roc`.
- Modify `plugins/implementations/ShellNix.roc`.
- Modify `xkai-bin/Executor.roc` only for standard-path regressions.
- Modify `scripts/test-xkai-portability.sh`.

## Acceptance criteria

- `kai shell` and `kai shell nix` produce the current `.kai/flake.nix` and Nix
  invocation.
- Standard config selection uses the universal scanner, body structure uses the
  command's declarative shape, and semantic failures use renderer diagnostics.
- A parse/render/lowering failure executes no action.
- The standard plugin contains no whole-plugin plan callback.
- The existing callback custom plugin still builds and runs.
- `zig build ci` passes.

## Not included

- Removal of callback API types.
- Guix or runtime preflight behavior.

## Risks

Do not change generated Nix formatting while changing dispatch; preserving it
keeps this commit focused and makes integration regressions attributable.
