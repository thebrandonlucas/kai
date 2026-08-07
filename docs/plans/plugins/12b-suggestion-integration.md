# Plan 12b: Integrate suggestions and finish documentation

**Commit:** `feat: suggest unresolved package names`  
**Budget:** 200–400 changed code/test lines, excluding documentation  
**Depends on:** plan 12

## Goal

Complete package-not-found UX with bounded backend candidate search and
document the final modular plugin system.

## Changes

1. Request candidates only after exact lookup fails:
   - parse bounded Nix search JSON/output;
   - parse bounded Guix search output;
   - allow a declarative custom backend candidate probe.
2. Bound captured output and candidate count before ranking.
3. If candidate lookup, output capture, or parsing fails, keep the exact
   package-not-found diagnostic without suggestions.
4. Render zero to three matches as `Did you mean ...?`; suggestions never alter
   or execute the requested plan.
5. Add fake-backend integration tests for zero, one, multiple, malformed, and
   failed candidate searches.
6. Update `README.md` and `docs/design.md` with source-tree layout, component
   responsibilities, backend/argument selection, diagnostics, build-time
   validation, preflight, fallback confirmation, and package lookup.
7. Add an implementation-status section to `plugins/spec.md`, preserving the
   original brainstorm and marking the production installer and immutable
   package locking as deferred where appropriate.

## Files

- Modify `xkai-bin/Plugin.roc` for candidate-probe metadata if needed.
- Modify `xkai-bin/PackageResolver.roc`.
- Modify `xkai-bin/Executor.roc`.
- Modify `scripts/test-xkai-portability.sh`.
- Modify `scripts/test-xkai-projects.sh` if custom search is covered there.
- Modify `README.md`.
- Modify `docs/design.md`.
- Modify `plugins/spec.md`.

## Acceptance criteria

- Missing packages show at most three deterministic relevant candidates.
- Search failure never hides exact-resolution failure.
- Search output and in-memory candidate collection are bounded.
- Documentation matches the actual final Roc API and syntax.
- Every roadmap completion criterion is implemented or explicitly deferred in
  the source spec.
- `zig build ci` passes.

## Not included

- Fuzzy automatic package selection.
- A Kai-owned package index/cache.

## Risks

Backend output formats can change. Keep parsers isolated and preserve the base
diagnostic when they fail.
