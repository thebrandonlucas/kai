# Plan 08: Add the Guix shell implementation

**Commit:** `feat: add guix shell backend`  
**Budget:** 200–400 changed code/test lines  
**Depends on:** plan 07

## Goal

Exercise one command with two determinate backends before adding runtime
preflight logic.

## Changes

1. Add `plugins/backends/Guix.roc` with Guix driver and package-source metadata.
2. Add `plugins/implementations/ShellGuix.roc` with a pure manifest renderer
   and action templates that write `.kai/manifest.scm` and invoke Guix.
3. Assemble Guix and shell/Guix into `StdPlugin.roc`; Nix remains shell's
   default backend.
4. Embed/stage the new standard modules in `xkai-bin/main.roc`.
5. Support:

   ```kai
   shell guix {
     pkgs: ["hello"]
   }
   ```

   through `kai shell guix`.
6. Add pure Guix rendering tests to `xkai-bin/plugin-tests.roc` for zero, one,
   and two packages and supported host selection.
7. Add integration coverage with a fake `guix` executable. CI must not require
   Guix or network access.

## Files

- Add `plugins/backends/Guix.roc`.
- Add `plugins/implementations/ShellGuix.roc`.
- Modify `plugins/StdPlugin.roc`.
- Modify `plugins/main.roc`.
- Modify `xkai-bin/main.roc`.
- Modify `xkai-bin/plugin-tests.roc`.
- Modify `scripts/test-xkai-portability.sh`.

## Acceptance criteria

- `kai shell` still selects Nix.
- `kai shell guix` writes only the Guix output and invokes the fake Guix command
  with the expected manifest path.
- Registry validation sees both backends and both implementations as used.
- Nix and Guix renderers use the same parsed shell command contract.
- `zig build ci` passes.

## Not included

- Automatic fallback from one determinate system to another.
- Runtime provenance or package availability checks.
- Claims of Guix support beyond the shell command.

## Risks

Guix package and manifest syntax differs from Nix. Test exact generated data
without attempting to normalize both formats into one renderer.
