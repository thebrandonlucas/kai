# Plan 11b: Add Nix and Guix exact package probes

**Commit:** `feat: resolve nix and guix package requests`  
**Budget:** 250–450 changed code/test lines  
**Depends on:** plan 11

## Goal

Resolve standard shell packages against each backend's declared default source
before generating its configuration.

## Changes

1. Add a Nix exact probe using the same explicit nixpkgs source reference and
   host target declared by the Nix renderer.
2. Add a Guix exact probe using the Guix backend's declared default channel/
   source and host target.
3. Return package requests from `ShellNix` and `ShellGuix` renderers alongside
   named outputs.
4. Keep source references centralized in backend metadata so probe construction
   and rendering cannot accidentally spell different sources.
5. Validate all requests before `.kai/flake.nix`, `.kai/manifest.scm`, or a
   backend shell process is created.
6. Add pure command-construction tests and fake Nix/Guix integration cases for
   success and failure. CI must not use the network.
7. Document that mutable source references can move between check and use until
   Kai has the tracked locking model described in `docs/development-lifecycle.md`;
   this plan guarantees the same declared source reference, not an immutable
   revision.

## Files

- Modify `xkai-bin/PackageResolver.roc`.
- Modify `plugins/backends/Nix.roc`.
- Modify `plugins/backends/Guix.roc`.
- Modify `plugins/implementations/ShellNix.roc`.
- Modify `plugins/implementations/ShellGuix.roc`.
- Modify `xkai-bin/plugin-tests.roc`.
- Modify `scripts/test-xkai-portability.sh`.

## Acceptance criteria

- Nix and Guix packages are checked through the selected backend and its
  declared source reference.
- Empty lists issue no exact probes.
- Any missing package prevents all generated output and backend execution.
- Diagnostics identify package, system, source, and backend.
- The mutable-source limitation is explicit rather than hidden by a stronger
  reproducibility claim.
- `zig build ci` passes.

## Not included

- Resolving and writing a Kai-owned lock file.
- Similar-name candidate search.

## Risks

Exact probes may be slow or networked in production. Keep CI fake and do not
add caching before source locking has a stable design.
