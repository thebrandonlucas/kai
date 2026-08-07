# Plan 09: Add runtime preflight core

**Commit:** `feat: preflight backend runtime requirements`  
**Budget:** 250–450 changed code/test lines  
**Depends on:** plans 07–08

## Goal

Establish an all-before-effects runtime preflight path and prove it with local
and fake custom determinate systems before adding Nix/Guix-specific probes.

## Changes

1. Carry the selected backend into the lowered plan as preflight data; checks
   remain executor behavior, not hidden plugin effects.
2. Before every implementation action, locate the optional system driver and
   each backend-required program, canonicalizing executable paths.
3. Define a declarative custom provenance-probe template that can substitute a
   located program path without invoking a shell.
4. Support driverless local custom systems only when they declare no external
   package/program requirements. They perform no preflight process.
5. For driver-backed custom systems, run the configured non-mutating probe for
   every required program and stop on the first failure.
6. Return structured diagnostics with plugin, backend, system, package source,
   and program. Do not add fallback behavior yet.
7. Add pure probe-template tests to `xkai-bin/plugin-tests.roc` and integration
   tests with fake custom drivers for missing driver, missing program, failed
   provenance, valid provenance, and driverless local success.
8. Assert every failure leaves `.kai` and implementation logs untouched.

## Files

- Add `xkai-bin/BackendRuntime.roc`.
- Modify `xkai-bin/Plugin.roc`.
- Modify `xkai-bin/Executor.roc`.
- Modify `xkai-bin/plugin-tests.roc`.
- Modify modular custom backend fixtures.
- Modify `scripts/test-xkai-projects.sh`.

## Acceptance criteria

- All preflight checks complete before the first implementation write/exec.
- Presence on `PATH` alone is insufficient when a provenance probe is declared.
- Driverless local backends remain usable without an unrelated executable.
- A driverless backend with requirements is rejected by registry/runtime
  validation rather than silently skipping provenance.
- `zig build ci` passes.

## Not included

- Nix and Guix probe adapters.
- Requirement installation fallback.
- User-requested package resolution.

## Risks

Canonical-path and captured-process APIs depend on pinned `basic-cli`. Record
actual compiler/platform quirks under `docs/roc-isms/`; do not replace failed
provenance checks with path-prefix-only workarounds.
