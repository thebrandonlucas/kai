# Releasing Kai

Kai releases use a protected release branch. Release preparation pushes only that branch; merging its required pull request triggers publication automatically.

> [!WARNING]
> `.github/workflows/release.yml` publishes on **any** push to `master` that changes `VERSION`, not only on release-branch merges. A change that bumps `VERSION` must also carry the matching `RELEASE_NAME` and `kaifile/platform-release`, or the release is published under a stale name or fails. Prefer `zig build release`, which updates all of them together.

## Metadata ownership

- `VERSION` is the canonical persisted semantic version used by Roc, Nix, artifacts, and release automation.
- `RELEASE_NAME` owns the exact one-line release title, including custom or Unicode names. It is not another version source.
- `build.zig.zon` contains Zig's required literal version mirror. Release automation updates it and validates exact agreement with `VERSION`.
- `RELEASE_SYSTEMS` lists, one per line, the systems (`x86_64-linux`, `aarch64-linux`) a release publishes a CLI archive for; see [aarch64-linux archives](#aarch64-linux-archives).
- `kaifile/platform-release` records the URL this release publishes the Kaifile platform bundle at, `https://github.com/OWNER/REPOSITORY/releases/download/vX.Y.Z/<hash>.tar.zst`, where `<hash>` is Roc's content hash of the bundle. `kai` embeds it and prints it in `kai --help` as the header a `Kaifile.roc` starts with.
- The release branch, annotated tag, and GitHub release derive their version and name from this committed metadata. Do not edit them independently.

## Build artifacts without releasing

From the Nix development shell on an x86_64 Linux host, build and validate the release artifacts without changing Git state:

```sh
zig build build-release
```

This runs `zig build ci` first. Artifacts are written to `dist/`. Checksums cover a portable CLI archive for each system in `RELEASE_SYSTEMS` and the platform bundle:

```text
dist/kai-X.Y.Z-x86_64-linux.tar.gz
dist/kai-X.Y.Z-aarch64-linux.tar.gz   (only when RELEASE_SYSTEMS lists aarch64-linux)
dist/<hash>.tar.zst
dist/SHA256SUMS
```

The build fails with `StalePlatformUrl` unless `kaifile/platform-release` names exactly the bundle just built, for the `origin` repository and `VERSION`. Any change to `kaifile/platform` or `kaifile/ir` changes the hash; `zig build release` rewrites the file, and `zig build platform-bundle` builds the bundle into `zig-out/kaifile-platform` for inspection.

Each archive contains only the `kai` binary. At runtime it needs Nix and the Roc compiler named in `.roc-version`, on `PATH` or as `ROC`, to load `Kaifile.roc`; Roc downloads the platform bundle from the recorded URL. The Nix package (`nix run github:OWNER/REPOSITORY`) supplies the compiler and pre-seeds Roc's cache with the bundle. The x86_64 archive is checked by running `kai --version`; the aarch64 archive, cross-built on x86_64, is checked here only for its architecture.

## aarch64-linux archives

The `ci (aarch64-linux)` job in `.github/workflows/ci.yml` runs `zig build ci` natively on an aarch64 runner. A release publishes the aarch64-linux archive only when `RELEASE_SYSTEMS` lists `aarch64-linux`; then the release workflow first runs the same CI natively for the release commit, and `publish-release` refuses to publish unless `KAI_AARCH64_VERIFIED_COMMIT` names that commit, which only that passing job provides.

Once `ci (aarch64-linux)` has passed on `master`, enable the archive by adding a line to `RELEASE_SYSTEMS`:

```text
x86_64-linux
aarch64-linux
```

Remove the line to stop publishing it.

## Prepare the protected release pull request

Start from a clean local `master` that exactly matches freshly fetched `origin/master`. The origin must be a supported SSH or HTTPS GitHub remote, and the requested version must be newer than the committed version with no existing release branch or tag.

```sh
zig build release -- "Kai X.Y.Z" X.Y.Z
```

The command:

1. creates `release/vX.Y.Z` from `origin/master` without moving local `master`;
2. updates only `VERSION`, `RELEASE_NAME`, `build.zig.zon`, and `kaifile/platform-release` (from the platform bundle it builds);
3. runs the complete release artifact build;
4. commits `Release <name>` and pushes only the release branch;
5. restores the clean local `master`; and
6. prints a compare URL of the form `https://github.com/OWNER/REPOSITORY/compare/master...release%2FvX.Y.Z?expand=1`.

Open that URL, create the required pull request, review it, and merge it. Opening and merging the pull request is the only manual repository action. Release preparation does not push `master`, create a tag, or publish a GitHub release.

## Automatic publication after merge

A push to `master` that changes `VERSION`, such as the release pull request's merge, triggers `.github/workflows/release.yml`; it can also be run manually. The workflow validates that the merged commit is on `origin/master` and that all committed metadata agrees, then runs:

```sh
zig build publish-release
```

The Roc publisher rebuilds the artifacts, creates the matching annotated tag using the committed release name, creates a draft GitHub release, uploads the CLI archives, the platform bundle and `SHA256SUMS`, and publishes only after every upload succeeds. Matching completed releases are successful no-ops.

`publish-release` is CI-only and is not part of normal local release preparation.

## Recovery

- Before a branch push begins, a preparation failure rolls back local release changes and removes generated release output.
- If a branch push has an ambiguous result, follow the printed inspection instructions. The local release branch is retained; do not retry until the remote state is known.
- For an abandoned release pull request, close it and delete its release branch. No tag or release exists yet.
- If publication fails after merge, rerun the **Release** workflow for that exact `master` commit from the GitHub Actions interface. Do not prepare the already-merged version again.
- A rerun safely accepts a matching tag, resumes a matching draft while replacing partial assets, or treats an already published matching release as success.
- A mismatched tag, release, target commit, name, version, or published asset set fails closed. Draft assets from an interrupted matching publication are replaced during recovery. Inspect and resolve other remote state manually; automation never moves or overwrites a collision.
