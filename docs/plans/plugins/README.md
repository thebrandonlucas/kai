# Modular plugin implementation roadmap

These plans implement `plugins/spec.md` in CI-green, reviewable commits. They
are ordered; later plans may assume earlier contracts.

## Ground rules

- Run `zig build ci` before every commit.
- Keep each implementation commit near 500 changed code/test lines or less. If
  a plan exceeds that during implementation, split it without combining it
  with the next plan.
- Keep plugin work pure: renderers and validators return data; only
  `Executor.roc` performs effects.
- Do not change `build.zig` unless a new test cannot be discovered by the
  existing source scan or a regression in the build is exposed.
- Keep stock and custom plugins on the same final contract. A temporary adapter
  is allowed only while migrating in plans 01–06b and is removed in plan 07.
- Extend the existing shell integration tests instead of adding slow,
  dependency-bearing test paths where possible.

## Decisions made by the roadmap

- A command declares a required or optional named `config.kai` source block
  and a default backend. The source name may differ from the CLI command name.
- `kai <command>` selects the default backend. In
  `kai <command> [<known-backend>] [-- <command-args>...]`, a known backend
  selects one explicitly and `--` removes backend/argument ambiguity. A bare
  `<source> {}` block configures the default backend.
- Core parsing owns universal syntax (`on`, host names, command/backend block
  headers, braces, comments, and source locations). Implementation renderers
  own block contents.
- Renderers return named text outputs and package requests. Action templates
  refer to output names, preserving the pure-data/effect boundary while
  allowing more than one generated file.
- `pkgs: []` is valid. An empty package name is syntactically parseable but is
  rejected with a plugin/package diagnostic.
- The determinate-system executable is the bootstrap boundary: Kai can check
  that it is executable, but cannot use a missing package manager to prove its
  own provenance. All additional required programs are verified through the
  selected determinate system.
- Structural registry checks happen during `xkai build`. Arbitrary renderer
  correctness cannot be proven there; plugin authors cover it with pure
  `expect` tests.
- Custom plugin command precedence remains first-specified plugin first, with
  the standard plugin last.

## Plans

1. [Registry contract](01-registry-contract.md)
2. [Standard plugin module split](02-standard-plugin-modules.md)
3. [Custom plugin source trees](03-xkai-plugin-trees.md)
4. [`xkai build` registry validation](04-registry-validation.md)
5. [Universal config scanner and diagnostics](05-config-diagnostics.md)
6. [Generic registry dispatch](06-generic-dispatch.md)
7. [Migrate the standard plugin to registry dispatch](06b-standard-registry.md)
8. [Remove the callback plugin contract](07-registry-only.md)
9. [Guix shell backend](08-guix-shell.md)
10. [Runtime preflight core](09-runtime-requirements.md)
11. [Nix and Guix provenance probes](09b-system-provenance.md)
12. [Requirement fallback actions](10-requirement-fallback.md)
13. [Package-resolution core](11-package-resolution.md)
14. [Nix and Guix package probes](11b-package-backends.md)
15. [Pure package-name ranking](12-package-suggestions.md)
16. [Suggestion integration and final documentation](12b-suggestion-integration.md)

## Completion criteria

After plan 12b:

- plugins are registries of commands, backends, and implementations;
- plugin source may be one file or a `Plugin.roc` tree with component modules;
- `xkai build` rejects empty, inconsistent, duplicate, or dangling registries;
- `kai` reports core and plugin configuration failures with source context;
- required programs are checked through the selected determinate system, with
  an optional confirmed fallback;
- unresolved packages identify their source and suggest close candidates; and
- Nix and Guix shell implementations exercise the same command contract.
