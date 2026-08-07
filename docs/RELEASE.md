# Releasing Kai

Run the deployment entrypoint from a clean `master` branch:

```sh
./scripts/release.sh "Kai X.Y.Z" X.Y.Z
```

`xkai-bin/VERSION` is the canonical version source for Roc, Nix, release artifacts, and release automation. Zig requires a literal version in `build.zig.zon`; the release script keeps that mirror synchronized automatically.

## Prerequisites

- Local `master` exactly matches `origin/master`.
- The working tree is clean.
- `X.Y.Z` is a new, valid semantic version and its `vX.Y.Z` tag does not exist.
- Git and Nix are installed, and Git can push to `origin`.

If needed, the script updates `xkai-bin/VERSION` and its required `build.zig.zon` mirror, then commits only those files as `chore: release X.Y.Z`. An already prepared but untagged version, such as `0.0.2`, is released without another version commit. In both cases the script runs the complete release build through `nix develop`, creates an annotated tag, and atomically pushes `master` and the tag. The tag push triggers the GitHub release workflow, which rebuilds and publishes the artifacts.

## Build Artifacts Without Deploying

To run the same release build and checks without committing, tagging, or pushing:

```sh
./scripts/build-release.sh
```

Artifacts are written to `dist/`. Checksums cover only the two portable CLI archives:

```text
dist/kai-X.Y.Z-x86_64-linux.tar.gz
dist/kai-X.Y.Z-aarch64-linux.tar.gz
dist/SHA256SUMS
```
