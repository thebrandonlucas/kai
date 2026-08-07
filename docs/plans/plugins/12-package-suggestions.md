# Plan 12: Rank package-name suggestions purely

**Commit:** `feat: rank package name suggestions`  
**Budget:** 150–300 changed code/test lines  
**Depends on:** plan 11b

## Goal

Add a deterministic, backend-independent typo ranking utility before coupling
it to package-manager output.

## Changes

1. Add a pure Damerau–Levenshtein helper covering insertion, deletion,
   substitution, and adjacent transposition.
2. Normalize candidates only for comparison; retain original spelling for
   display.
3. Rank by distance and then lexical name, apply a documented length-aware
   threshold, remove duplicates, and return at most three candidates.
4. Define byte/Unicode behavior explicitly for this first implementation.
5. Add data-driven tests in `plugin-tests.roc` for exact names, each edit type,
   ties, distant names, duplicates, case differences, Unicode, and output caps.
6. Do not call backend search commands or alter package diagnostics yet.

## Files

- Add `xkai-bin/Suggestions.roc`.
- Modify `xkai-bin/plugin-tests.roc`.

## Acceptance criteria

- Ranking is pure, deterministic, bounded, and independent of Nix/Guix output.
- Distant names are omitted and no more than three suggestions are returned.
- Original candidate spelling is preserved.
- `zig build ci` passes.

## Not included

- Candidate acquisition and CLI rendering.
- Automatic correction or package selection.

## Risks

Avoid optimizing before measuring candidate set sizes. A simple bounded dynamic
program is preferable to an opaque dependency or backend-specific heuristic.
