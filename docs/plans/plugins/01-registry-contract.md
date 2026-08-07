# Plan 01: Add the registry contract

**Commit:** `feat: add modular plugin registry contract`  
**Budget:** 250–400 changed code/test lines  
**Depends on:** nothing

## Goal

Represent commands, determinate backends, and command/backend implementations
as pure registry data without breaking the currently runnable callback plugins.

## Changes

1. Extend `xkai-bin/Plugin.roc` with a `Definition` containing `name`,
   `commands`, `backends`, and `implementations`.
2. Add a temporary plugin shape with both:
   - the existing callback module plus a definition; and
   - a registry-only module used by the generic dispatcher in plan 06.
3. Define the minimal shared records:
   - `Command`: name, default backend, argument policy, and a named
     `RequiredSource(Str)`/`OptionalSource(Str)` (the config source name need
     not equal the CLI command name);
   - `DeterminateSystem`: `Nix`, `Guix`, or `Custom`, an optional driver
     program, and its default package source; driverless custom systems are
     valid only when they have no external requirements;
   - `Package`: package name and provided program;
   - `Backend`: name, determinate system, required packages, and optional
     fallback metadata;
   - `Implementation`: command/backend names, a common pure renderer, and
     action templates;
   - render context: selected source with location, command args, host OS, and
     host architecture;
   - renderer result: `Try(RenderResult, RendererDiagnostic)`, where the result
     has named text outputs and requested package names and the diagnostic has
     a message plus an optional byte offset relative to the block body.
4. Generalize `WriteConfigUtf8` to reference a named renderer output. Lowering
   must fail with a plugin diagnostic if an action names an output the renderer
   did not return.
5. Add `xkai-bin/plugin-tests.roc`, a normal Roc app with a no-op `main!`, and
   put focused `expect` tests there for a minimal registry, multiple outputs,
   empty package requests, and missing named outputs. The existing build scan
   will both test and build this root on every CI run.
6. Update current standard and custom callback constructors only enough to add
   their definitions and keep CI green. Do not migrate behavior yet.

## Files

- Modify `xkai-bin/Plugin.roc`.
- Add `xkai-bin/plugin-tests.roc`.
- Modify `plugins/StdPlugin.roc`.
- Modify `examples/custom-plugin/CustomPlugin.roc`.

## Acceptance criteria

- Existing `kai shell` and `custom-write` integration behavior is unchanged.
- The new types can express one command with Nix, Guix, driver-backed custom,
  and driverless local custom backends.
- Every implementation renderer has one uniform function type, so different
  implementations can coexist in one list.
- Multiple rendered strings can be lowered without putting file writes inside
  a renderer.
- `zig build ci` passes.

## Not included

- Registry consistency validation.
- Generic dispatch of registry-only plugins.
- Runtime requirement or package checks.

## Risks

Roc's function and record inference may reject a heterogeneous-looking list.
Keep the renderer context/result fully concrete and add explicit type aliases;
do not solve this by moving effects back into plugin callbacks.
