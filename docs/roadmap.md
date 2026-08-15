# Roadmap

## Features

- [ ] `kai shell keep` to save features to a local `Kaifile`.

## Operating System

- [ ] Add `services` feature for long-running processes as a major step to abstracting `NixOS` config.
- [ ] `options` lowering feature to allow `nix` configuration.
- [ ] `workspace` feature to manage multiple `Kaifile`s in various areas.

## Cleanup & Tech Debt

- [ ] Self-host build tool in Roc `roc-build` ([John Carmack: The tool your already using]()). All tools used to build `kai` should be the same tools `kai` is built _in_.
- [ ] Enforce code invariant rules via `tidy.roc` inspired by [tidy.zig](). (e.g. line length limits, filesize commit limits, and documentation enforcement).
- [ ] Cleaner plugin module abstractions. Right now, it's still difficult for a plugin writer to know exactly what _must_ go into a plugin. `xkai` needs work to become a more advanced compiler to define and enforce what the invariants of a plugin are, and the plugin API must be simplified to help developers know what they have to write. Consider templates.
- [ ] Overview and documentation of testing structure.
- [ ] Architecture overview documentation.
