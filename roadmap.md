# Roadmap


## Core workflows

- [ ] Support ad-hoc and persistent shells, both locked with flakes and unlocked with `shell.nix`.
- [ ] Add builds for deployable machines and other targets.
- [ ] Add extensible deployments.
- [ ] Add rollbacks and garbage collection.
- [ ] Add `kai shell keep` to make temporary shell packages persistent.
- [ ] Support approachable desktop setup, safe system modification, and backups.

## Packages and installation

- [ ] Add package resolution and suggestions.
- [ ] Add installers.
- [ ] Add package-source locking and caching.

## Plugins and execution

- [ ] Check runtime requirements and provenance.
- [ ] Support fallback execution.
- [ ] Support nested helper directories in split plugins.
- [ ] Improve name, schema, and source diagnostics.
- [ ] Allow components beneath Kai to be replaced incrementally while retaining compatible commands and backends.

## Configuration

- [ ] Rename `config.kai` to `Kaifile`.
- [ ] Finalize command and backend delimiter rules.

## Backends and platforms

- [ ] Add Guix support.
- [ ] Test and support more architectures and operating systems, including ARM64, x86-64, Linux, and macOS.
- [ ] Make Kai self-hosting so installation can eventually be handled by `kai` itself.
