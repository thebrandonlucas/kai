# Contributing to Kai

Thank you for helping. Kai is a young project under rapid development, so please open an [issue](https://github.com/thebrandonlucas/kai/issues) or a [discussion](https://github.com/thebrandonlucas/kai/discussions) before starting a large change. That way we can agree on the approach before you spend time on it.

## Questions

Ask in [GitHub Discussions](https://github.com/thebrandonlucas/kai/discussions/categories/q-a) or on the [Discord](https://discord.gg/SrH3w5uAa3). Use [issues](https://github.com/thebrandonlucas/kai/issues/new/choose) for bugs and feature requests, and report security problems privately as [SECURITY.md](SECURITY.md) describes.

## Building and testing

Kai's development environment is its own [Kaifile.roc](Kaifile.roc), so you need [kai](README.md#installation) and Nix:

```sh
git clone https://github.com/thebrandonlucas/kai.git
cd kai
kai shell default -- zig build test    # or `kai shell`, then `zig build test`
```

`zig build test` runs the static checks and unit tests, the required check on every pull request. `zig build ci` adds the end-to-end tests, which run a built kai against real Nix and, when it is installed, Guix (with the guix plugin), so it needs network access or a warm Nix cache. `zig build e2e -- --nix` or `-- --guix` runs them on one backend, and `zig build e2e-run` (or `-build`, `-workflow`, `-update`, ...) runs one; `zig build guix-integration` runs every Guix test and fails without Guix. Pull requests run the end-to-end tests on GitHub too, so running the suites for the area you touched is usually enough. If the shell is missing a dependency, please open an issue.

To try a checkout's kai on another project, build it and the platform host it links Kaifiles with:

```sh
kai build kai-x64musl --out-link /tmp/kai-dev    # kai at /tmp/kai-dev/kai
kai shell default -- sh -c 'cd platform && zig build --release'
```

`kai-arm64musl` is the aarch64 build, and `kai-arm64mac` the Apple Silicon macOS one, cross-built on Linux. The project's Kaifile.roc then names the checkout's platform and std by relative path, as `examples/` do, such as `pf: platform "../kai/platform/main.roc"` and `std: "../kai/plugins/std/main.roc"`: Roc refuses an absolute platform path.

## How the code is laid out

The code follows the pipeline:

- `platform`: Kai's plugin platform, the Roc platform `Kaifile.roc` builds on and the API every plugin uses: commands, backends, implementations, plans and the protocol kai speaks. It validates the Kaifile's plugins at compile time.
- `plugins/std`: the std plugin. It lowers its settings to its project model at compile time.
  - `plugins/std/model`: std's project model and its validation.
  - `plugins/std/backends/nix`, `plugins/std/backends/direct`: std's pure backends that plan files and argv from the model.
- `plugins/guix`: the guix plugin, which plans std's commands on Guix from std's model, as any backend plugin would.
- `plugins/sbom`: the sbom plugin, `kai sbom`, which writes a release's SBOMs from std's model and the lock.
- `cli`: `kai` itself. It asks the compiled Kaifile for the command's candidate plans, chooses a backend, checks the plan and runs it.
- `devtool`: checks, integration tests and release tooling; see [devtool/README.md](devtool/README.md) and [RELEASE.md](docs/RELEASE.md).

[design.md](docs/design.md) explains the design and [vision.md](docs/vision.md) where Kai is going.

## Proposing a change

Open a pull request against `master`. The [development rules](docs/rules.md) apply to every change; in short:

- Keep commits small and reviewable, and give each one standalone value, so that `master` is safe to release after any of them. Write plain commit subjects that say what the change does, without conventional-commit prefixes, and explain why in the body.
- Run `zig build test` and the end-to-end steps for the area you touched before pushing.
- Read the [AI policy](docs/AI_POLICY.md): you must understand, and be able to explain, every line you submit.

### Changelog

A pull request that changes what users see (`cli/`, `platform/`, `plugins/`, `install.sh` or `flake.nix`) adds an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), under `### Added`, `### Changed`, `### Fixed` or `### Removed`. Write it for users: what they can now do or must change, not the pull request's title. Start a breaking change's entry with `**Breaking:**`. If users see no difference, such as with a refactor or a test-only change, a maintainer adds the `no changelog` label instead. The changelog check on each pull request enforces this, and each release publishes its section of the changelog as its release notes.

## Code of conduct

Everyone taking part in Kai's spaces follows the [code of conduct](CODE_OF_CONDUCT.md).
