# Plan 04: Validate registries during `xkai build`

**Commit:** `feat: validate plugin registries at build time`  
**Budget:** 300–500 changed code/test lines  
**Depends on:** plans 01, 01b, and 03

## Goal

Reject structurally invalid plugins before producing the final `kai` binary.

## Changes

1. Add pure registry validation covering:
   - at least one command, backend, and implementation per plugin;
   - unique command names, backend names, and command/backend implementation
     pairs within a plugin;
   - every implementation references an existing command and backend;
   - every command and backend is used by at least one implementation;
   - every command's default backend exists and implements that command;
   - unique, syntactically valid field names within each command body shape;
   - non-empty plugin, command, backend, field, package, and program names.
2. Keep duplicate command names across plugins legal. Registry order defines
   override precedence.
3. Generate a small validator app from the staged plugin imports. Build and run
   it before building the final CLI. It may inspect registry data but must not
   call renderers or execute actions.
4. Print all structural errors in one run with plugin and component names, then
   return a failing exit status.
5. Add table-driven pure tests for each invalid shape and a valid multi-backend
   shape to the Roc app test root from plan 01, because `build.zig` runs
   `roc test` for app roots rather than standalone modules.
6. Add integration fixtures for an unknown command reference and a dangling
   backend. Assert that `xkai build` fails without leaving `kai` or temporary
   inputs.
7. Run this validation for the standard plugin and every custom plugin.

## Files

- Add `xkai-bin/Registry.roc`.
- Modify `xkai-bin/plugin-tests.roc`.
- Modify `xkai-bin/package.roc` if the validator needs another exposed module.
- Modify `xkai-bin/main.roc`.
- Modify `scripts/test-xkai-projects.sh`.
- Add invalid plugin fixtures inline in the integration script or under
  `examples/invalid-plugins/` if reuse justifies files.

## Acceptance criteria

- All incomplete, duplicate, invalid-shape, unknown-reference, and dangling
  registries fail in `xkai build`, not at first `kai` use.
- Diagnostics identify every invalid plugin and name.
- Valid standard, single-file, and modular custom plugins still build.
- Validation performs no plugin side effects.
- `zig build ci` passes.

## Not included

- Testing arbitrary renderer behavior. Plugin authors continue to write
  `expect` tests for parse/render cases.
- Runtime config or package validation.

## Risks

A normal `roc build` does not run `expect` tests or evaluate registry values.
The generated validator must be executed explicitly; do not describe compiler
type checking alone as registry validation.
