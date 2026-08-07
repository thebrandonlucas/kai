# Plan 06: Dispatch registry implementations generically

**Commit:** `feat: dispatch modular plugin registries`  
**Budget:** 350–500 changed code/test lines  
**Depends on:** plans 01, 03, 04, and 05

## Goal

Make registry data, rather than a whole-plugin callback, drive command lookup,
config selection, pure rendering, lowering, and execution.

## Changes

1. Extend `Plugin.run`/`Executor.dispatch` for registry modules:
   - find the first plugin owning the requested command;
   - select the command's default backend or an explicit known backend;
   - require `--` before command arguments, yielding the unambiguous grammar
     `kai <command> [<known-backend>] [-- <command-args>...]`;
   - find the matching implementation;
   - select host-scoped config with unscoped fallback;
   - enforce `RequiredSource` versus `OptionalSource`;
   - invoke the implementation renderer and lower named outputs into a plan.
2. Select configuration by the command's declared source name, not necessarily
   its CLI name, and treat bare `<source> {}` as source for the default backend.
3. Reject an unknown token in the backend position with an expected-backend-or-
   `--` diagnostic instead of treating it accidentally as an implementation.
4. Translate renderer-relative locations to `config.kai` line/column. If a
   renderer returns only a generic plugin failure, identify the plugin and
   command and state that the plugin failed to diagnose its config.
5. Render concise diagnostics in `Executor.roc` while retaining structured
   error data internally.
6. Run the modular custom fixture through this path, including required and
   optional source cases. Keep standard and single-file callback plugins on the
   temporary adapter until plans 06b and 07.
7. Extend project integration coverage for required/missing source,
   default/explicit/unknown backend, argument delimiter handling, host fallback,
   malformed core syntax, and malformed plugin source. Assert failures perform
   no write or exec action.

## Files

- Modify `xkai-bin/Plugin.roc`.
- Modify `xkai-bin/Config.roc`.
- Modify `xkai-bin/Executor.roc`.
- Modify the modular custom plugin fixture.
- Modify `scripts/test-xkai-projects.sh`.

## Acceptance criteria

- The modular fixture executes through generic dispatch with default and
  explicit backend selection.
- Existing callback-based `kai shell` remains unchanged in this transition.
- Missing required source and malformed config fail before any action.
- Optional-source renderers can run with no block.
- Plugin registry order and custom-before-standard precedence remain intact.
- Core and plugin errors identify source position and owner.
- `zig build ci` passes.

## Not included

- Runtime backend requirements, fallback, or package lookup.
- Removal of the callback variant.

## Risks

Only parse config after command ownership is known; otherwise one plugin may
reject syntax owned by another. Keep action execution all-or-nothing by fully
rendering and lowering before calling `execute!`.
