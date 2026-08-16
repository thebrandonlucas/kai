# Releasing Kai

Kai releases use a protected release branch. Release preparation pushes only that branch; merging its required pull request triggers publication automatically.

## Metadata ownership

- `xkai-bin/VERSION` is the canonical persisted semantic version used by Roc, Nix, artifacts, and release automation.
- `xkai-bin/RELEASE_NAME` owns the exact one-line release title, including custom or Unicode names. It is not another version source.
- `build.zig.zon` contains Zig's required literal version mirror. Release automation updates it and validates exact agreement with `xkai-bin/VERSION`.
- The release branch, annotated tag, and GitHub release derive their version and name from this committed metadata. Do not edit them independently.

## Build artifacts without releasing

From the Nix development shell, build and validate the release artifacts without changing Git state:

```sh
zig build build-release
```

Artifacts are written to `dist/`. Checksums cover exactly the two portable CLI archives:

```text
dist/kai-X.Y.Z-x86_64-linux.tar.gz
dist/kai-X.Y.Z-aarch64-linux.tar.gz
dist/SHA256SUMS
```

## Prepare the protected release pull request

Start from a clean local `master` that exactly matches freshly fetched `origin/master`. The origin must be a supported SSH or HTTPS GitHub remote, and the requested version must be newer than the committed version with no existing release branch or tag.

```sh
zig build release -- "Kai X.Y.Z" X.Y.Z
```

The command:

1. creates `release/vX.Y.Z` from `origin/master` without moving local `master`;
2. updates only `xkai-bin/VERSION`, `xkai-bin/RELEASE_NAME`, and `build.zig.zon`;
3. runs the complete release artifact build;
4. commits `Release <name> <version>` and pushes only the release branch;
5. restores the clean local `master`; and
6. prints a compare URL of the form `https://github.com/OWNER/REPOSITORY/compare/master...release%2FvX.Y.Z?expand=1`.

Open that URL, create the required pull request, review it, and merge it. Opening and merging the pull request is the only manual repository action. Release preparation does not push `master`, create a tag, or publish a GitHub release.

## Automatic publication after merge

A merge that changes `xkai-bin/VERSION` triggers `.github/workflows/release.yml`. The workflow validates that the merged commit is on `origin/master` and that all committed metadata agrees, then runs:

```sh
zig build publish-release
```

The Roc publisher rebuilds the artifacts, creates the matching annotated tag using the committed release name, creates a draft GitHub release, uploads both archives and `SHA256SUMS`, and publishes only after every upload succeeds. Matching completed releases are successful no-ops.

`publish-release` is CI-only and is not part of normal local release preparation.

## Recovery

- Before a branch push begins, a preparation failure rolls back local release changes and removes generated release output.
- If a branch push has an ambiguous result, follow the printed inspection instructions. The local release branch is retained; do not retry until the remote state is known.
- For an abandoned release pull request, close it and delete its release branch. No tag or release exists yet.
- If publication fails after merge, rerun the **Release** workflow for that exact `master` commit from the GitHub Actions interface. Do not prepare the already-merged version again.
- A rerun safely accepts a matching tag, resumes a matching draft while replacing partial assets, or treats an already published matching release as success.
- A mismatched tag, release, target commit, name, version, or published asset set fails closed. Draft assets from an interrupted matching publication are replaced during recovery. Inspect and resolve other remote state manually; automation never moves or overwrites a collision.
