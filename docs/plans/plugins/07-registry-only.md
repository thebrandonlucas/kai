# Plan 07: Remove the callback plugin contract

**Commit:** `refactor: require registry-based plugins`  
**Budget:** 200–400 changed code/test lines  
**Depends on:** plan 06b

## Goal

Put stock and custom plugins on one validated contract and remove the temporary
migration path that bypasses structural and config validation.

## Changes

1. Migrate `examples/custom-plugin/CustomPlugin.roc` to a registry:
   - `custom-write` command with required source name `custom`, preserving the
     existing `config.kai` block;
   - a driverless custom/local backend with no required external packages;
   - an implementation renderer that parses `message:` and returns a named
     output;
   - the existing write action template.
2. Migrate the modular plugin fixture to run through generic dispatch and add an
   integration assertion for its output.
3. Remove the callback `Module` variant, callback `plan` signature, and raw
   source dispatch path from `Plugin.roc` and `Executor.roc`.
4. Remove temporary adapters from `StdPlugin.roc` and examples.
5. Ensure `xkai build` validates every plugin because every plugin now exposes
   a definition.
6. Update the README custom plugin snippet to the registry contract and point
   to the modular fixture for split-file usage.
7. Preserve registry order and therefore custom command override behavior.

## Files

- Modify `xkai-bin/Plugin.roc`.
- Modify `xkai-bin/Executor.roc`.
- Modify `plugins/StdPlugin.roc`.
- Modify `examples/custom-plugin/CustomPlugin.roc`.
- Keep `examples/custom-plugin/config.kai` unchanged and cover its distinct
  command/source names in integration tests.
- Modify `examples/modular-plugin/Plugin.roc` and implementation modules.
- Modify `scripts/test-xkai-projects.sh`.
- Modify `README.md`.

## Acceptance criteria

- There is one plugin shape: name plus command, backend, and implementation
  lists.
- No plugin can bypass registry or required-source validation.
- Both single-file and split-file custom plugins build and execute.
- Custom command precedence remains unchanged.
- No current source references the old whole-plugin plan callback.
- `zig build ci` passes.

## Not included

- A permanent compatibility layer for pre-registry plugins. This project is
  pre-1.0; retaining the callback would leave the spec's guarantees optional.
- Requirement/package effects.

## Risks

This is intentionally a source-breaking plugin API change. Keep it isolated,
document the migration, and do not combine it with new runtime behavior.
