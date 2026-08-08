# Plan 01: Add the registry contract

**Commit:** `feat: add modular plugin registry contract`  
**Budget:** 300–500 changed code/test lines
**Depends on:** nothing

## Goal

Represent commands, determinate backends, and command/backend implementations
as pure registry data without breaking the currently runnable callback plugins.

## Changes

1. Add the minimal shared `Body` data contract: object shapes with named
   required or optional string and string-list fields, generic values and
   configurations, shape constructors, and an empty configuration. Expose the
   module from `xkai-bin/package.roc` and stage it from `xkai-bin/main.roc` so
   both repository apps and generated custom-plugin builds compile. Parsing,
   validation, and accessors remain in plan 01b.
2. Extend `xkai-bin/Plugin.roc` with a `Definition` containing `name`,
   `commands`, `backends`, and `implementations`.
3. Add a temporary plugin shape with both:
   - the existing callback module plus a definition; and
   - a registry-only module used by the generic dispatcher in plan 06.
4. Define the minimal shared registry records:
   - `Command`: name, default backend, argument policy, a generic declarative
     body shape, and a named `RequiredSource(Str)`/`OptionalSource(Str)` (the
     config source name need not equal the CLI command name);
   - `DeterminateSystem`: `Nix`, `Guix`, or `Custom`, an optional driver
     program, and its default package source; driverless custom systems are
     valid only when they have no external requirements;
   - `Package`: package name and provided program;
   - `Backend`: name, determinate system, required packages, and optional
     fallback metadata;
   - `Implementation`: command/backend names, a common pure renderer, and
     action templates;
   - render context: generic configuration, the selected raw source with
     location for semantic diagnostics, command args, host OS, and host
     architecture;
   - renderer result: `Try(RenderResult, RendererDiagnostic)`, where the result
     has named text outputs and requested package names and the diagnostic has
     a message plus an optional byte offset relative to the block body.
5. Generalize `WriteConfigUtf8` to reference a named renderer output. Lowering
   must fail with a plugin diagnostic if an action names an output the renderer
   did not return.
6. Add `xkai-bin/plugin-tests.roc`, a normal Roc app with a no-op `main!`, and
   put focused `expect` tests there for the minimal body contract and registry,
   multiple outputs, empty package requests, and missing named outputs. The
   existing build scan will both test and build this root on every CI run.
7. Update current standard and custom callback constructors only enough to add
   their definitions, declare their body shapes, and keep CI green. Their
   registry renderers may continue reading raw source in this plan. Plan 01b
   adds parsing and accessors and migrates those renderers to validated generic
   configuration; do not migrate dispatch behavior here.

## Files

- Add `xkai-bin/Body.roc`.
- Modify `xkai-bin/package.roc` and `xkai-bin/main.roc` to expose and stage it.
- Modify `xkai-bin/Plugin.roc`.
- Add `xkai-bin/plugin-tests.roc`.
- Modify `plugins/StdPlugin.roc`.
- Modify `examples/custom-plugin/CustomPlugin.roc`.

## Acceptance criteria

- Existing `kai shell` and `custom-write` integration behavior is unchanged.
- Body shapes express required and optional string and string-list fields.
- The new types can express one command with Nix, Guix, driver-backed custom,
  and driverless local custom backends.
- Every command declares a generic body shape and every implementation
  renderer has one uniform function type, so different implementations can
  coexist in one list.
- Multiple rendered strings can be lowered without putting file writes inside
  a renderer.
- `zig build ci` passes.

## Not included

- Registry consistency validation.
- Generic dispatch of registry-only plugins.
- Declarative body parsing, validation, diagnostics, or accessors.
- Migration of registry renderers to validated generic configuration.
- Runtime requirement or package checks.

## Risks

Roc's function and record inference may reject a heterogeneous-looking list.
Keep the renderer context/result fully concrete and add explicit type aliases;
do not solve this by moving effects back into plugin callbacks.
