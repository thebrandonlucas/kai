# Plan 11: Add package-resolution preflight

**Commit:** `feat: preflight backend package requests`  
**Budget:** 250–450 changed code/test lines  
**Depends on:** plan 10

## Goal

Establish exact, all-before-effects package resolution and prove it with a fake
custom backend before adding Nix/Guix commands.

## Changes

1. Consume structured package requests from render results; never scrape
   rendered backend text.
2. After requirement preflight and before implementation actions, deduplicate
   requested packages while preserving diagnostic order.
3. Add a declarative custom exact-resolution probe with safe placeholders for
   package name, source, host OS, and architecture. Build process arguments
   directly, without shell strings.
4. Reject empty or unsafe package names before probe construction.
5. Resolve every request before writing any renderer output so one failure
   cannot leave partial backend state.
6. Emit structured failures naming package, backend, determinate system, and
   default package source.
7. Add pure probe-construction tests and fake custom integration cases for zero
   requests, one/many successes, duplicates, malformed names, and one failure
   among successful requests.
8. Reject package requests from a driverless local backend because it cannot
   prove resolution.

## Files

- Add `xkai-bin/PackageResolver.roc`.
- Modify `xkai-bin/Plugin.roc` for exact-probe metadata.
- Modify `xkai-bin/Executor.roc`.
- Modify `xkai-bin/plugin-tests.roc`.
- Modify custom plugin fixtures.
- Modify `scripts/test-xkai-projects.sh`.

## Acceptance criteria

- `pkgs: []` performs no package process and remains valid.
- Any exact-resolution failure prevents every rendered write and implementation
  exec.
- Package values cannot inject expressions or additional command arguments.
- Failure text has the useful core requested by the spec, without suggestions
  yet.
- `zig build ci` passes.

## Not included

- Nix/Guix exact probes.
- Similar-name candidate search.
- Locking or caching package sources.

## Risks

Keep custom probes declarative; allowing a plugin callback to perform lookup
would break the effect boundary and make no-effects-on-failure tests unreliable.
