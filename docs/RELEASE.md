# Releasing Kai

Notes on doing a Kai release. I hope to simplify this later:

## 1. Update the Version

Set the same `X.Y.Z` version in (TODO: streamline this):

- `build.zig.zon`
- `cli/Cli.roc`
- `flake.nix`

## 2. Format and Test

```sh
# Format everything
zig build fmt

# Run CI locally
zig build ci

# Flake checks
nix fmt -- --check flake.nix
nix flake check
```

## 3. Build Release Artifacts

```sh
./scripts/build-release.sh X.Y.Z
```

This produces:

```text
dist/<PLATFORM_HASH>.tar.zst
dist/kai-X.Y.Z-x86_64-linux.tar.gz
dist/kai-X.Y.Z-aarch64-linux.tar.gz
dist/SHA256SUMS
```

Verify the checksums:

```sh
(
  cd dist
  sha256sum -c SHA256SUMS
)
```

## 4. Commit and Push

```sh
git add build.zig.zon cli/Cli.roc flake.nix
git commit -S -m "chore: prepare X.Y.Z release"
git push origin master
```
