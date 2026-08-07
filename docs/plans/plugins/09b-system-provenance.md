# Plan 09b: Add Nix and Guix provenance probes

**Commit:** `feat: verify nix and guix program provenance`  
**Budget:** 200–400 changed code/test lines  
**Depends on:** plan 09

## Goal

Verify backend-required programs through the selected Nix or Guix store before
implementation effects run.

## Changes

1. Implement the Nix adapter: a required executable must resolve to a Nix store
   object and a non-mutating Nix store query for that object must succeed.
2. Implement the Guix adapter with the equivalent Guix store ownership query.
3. Treat each determinate-system driver as the bootstrap boundary: Kai checks
   that it is executable, but reports that a missing driver prevents
   provenance verification instead of claiming to verify it through itself.
4. Do not rely on `/nix/store` or `/gnu/store` prefixes alone; both path shape
   and package-manager query must pass.
5. Add pure command-construction cases to `plugin-tests.roc`.
6. Extend portability tests with fake Nix and Guix commands and paths for
   missing, wrong-store, failed-query, and valid-query cases. CI must not query
   a real store or network.
7. Assert a provenance failure prevents generated files and backend execution.

## Files

- Modify `xkai-bin/BackendRuntime.roc`.
- Modify `xkai-bin/Executor.roc` only if adapter errors need rendering.
- Modify `plugins/backends/Nix.roc`.
- Modify `plugins/backends/Guix.roc`.
- Modify `xkai-bin/plugin-tests.roc`.
- Modify `scripts/test-xkai-portability.sh`.

## Acceptance criteria

- Required programs are checked by the selected determinate system, not merely
  found on the host.
- Driver bootstrap limitations are explicit in diagnostics and documentation.
- Nix and Guix failures occur before all implementation effects.
- Standard backends with no additional required packages perform only their
  driver bootstrap check.
- `zig build ci` passes.

## Not included

- Security guarantees against a malicious package-manager executable.
- Requirement installation fallback or package resolution.

## Risks

Store-query behavior and executable wrapping differ across systems. Keep host
logic in adapters and test the exact command/path data without requiring those
systems in CI.
