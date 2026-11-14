# Changelog

All notable changes to Kai are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Kai follows [Semantic Versioning](https://semver.org/) (before 1.0, a minor or patch release may still break things).

## [Unreleased]

### Added

- Releases attest every asset they publish with GitHub build provenance, so `gh attestation verify kai-X.Y.Z-x86_64-linux.tar.gz --repo thebrandonlucas/kai` shows that a download was built by the release workflow. `SECURITY.md` explains how to check one.
- `OnSystems` accepts `PackageEnv([...])`, so a variable set to paths in packages can be limited to some systems: `OnSystems(["x86_64-linux", "aarch64-linux"], [Tools([...]), PackageEnv([("LD_LIBRARY_PATH", LibraryPath([...]))])])` gives Linux the library path of libraries macOS has no build of, and macOS still gets the shell. Like its `Env`, its variables override the environment's by name, and an extending environment's own `Env` and `PackageEnv` override them. `kai check` refuses a `LibraryPath`, `BinPath` or `PackagePath` naming a tool the environment has only through `OnSystems` on a system that does not add it.
- `System` values compare by name, so a Kaifile can test one with `==` and pick some of a list with ordinary list functions: with `systems : List(System)`, `OnSystems(systems.drop_if(|system| system == "aarch64-darwin"), [...])` names every system in it but `aarch64-darwin`, and `systems.contains("x86_64-linux")` says whether the list has it.
- `kai requirements` lists the programs each environment `Expect`s of the machine, such as `environment dev expects git, make`, then fails naming every one that is not on `PATH`, so CI can check a machine before running tasks. Name environments to check only those (`kai requirements dev`); with `--json` each line is a `result` event and a failure is a `missing_programs` error whose `programs` lists the missing ones. `kai spec` lists the same programs, as tools `"from": "expected"`.

### Changed

- When a step fails after saying why, such as an environment naming a tool its package source lacks, Kai's error ends with that reason, `kai: evaluating the environment of shell dev failed: tool helloo not found in source default of environment dev`, instead of a separate `exited with code 1` line.
- `KAI_ROC` chooses the Roc compiler that evaluates `Kaifile.roc`, so a project's own `ROC`, for the compiler its tasks build with, no longer clashes with Kai's: Kai no longer refuses a `ROC` set to another Roc version, and tasks see the project's `ROC` unchanged. `ROC` is deprecated for Kai's compiler: for one more release Kai still uses it when it is the pinned version and the `roc` on `PATH` is not, and says to set `KAI_ROC` instead.
- A build that refuses a symbolic link in the project says where the link points, why, and how to fix it: `snapshot refuses symlink …/stray -> /etc/passwd, which is outside …; point it inside …, or ignore it in .gitignore or leave it out of the build's Files`.
- `kai --backend direct update` downloads and pins one file several systems share, such as a `FetchAll`'s or a `RocPackages` bundle's, once, under the Fetch's name, instead of once per system under `<fetch>/<system>`. `kai spec` and `kai lock` name the file by that key, and `kai lock` gives it a `null` `system`; `schema_version` stays 1. Existing locks keep working: Kai still reads their per-system pins, and the next `kai --backend direct update` rewrites them as one without downloading the file again.

### Fixed

- `kai update` reports every lock entry it removes, not only root Nix inputs: an input an overlay pulled in that now `Follows` a package source (`kai: tools/nixpkgs removed`), a file the direct backend no longer pins, and a Guix channel or source the Kaifile no longer declares. The direct backend's and Guix's `kai update` now also say which entries they added or moved, or `no input changed`, as Nix's does, and Nix's also lists the inputs root inputs pull in, under the names `kai lock` gives them. With `--json`, each line is a `note` event.
- Builds leave every Kai workspace out of the project's copy, not only their own: another `KAI_DIR` beside the project's, or a nested project's `.kai`, no longer breaks the build with the links inside it.

## [0.0.12] - 2026-11-06

### Added

- The guix plugin serves Guix: add `Guix.plugin(project, settings)` beside `Std.plugin(project)` in `Kaifile.new([...])` to run shells, tasks, workflows, builds and `kai update` on Guix. Each release publishes its bundle, and its notes give the line that adds it.
- The sbom plugin adds `kai sbom`, which writes a release's SBOMs (SPDX 3.0.1, SPDX 2.3 and CycloneDX 1.7) from the Kaifile and the lock: `inputs`, `pins` and `inspect` among its subcommands. Each release publishes its bundle.
- The nixos plugin declares NixOS machines in a Kaifile, `Machine(name, [...])`, and `kai machine build NAME` builds one. On the machine itself, `kai machine switch NAME` builds and activates it, `kai machine rollback NAME` returns to the previous system and `kai machine generations NAME` lists them. Each release publishes its bundle.
- `kai spec` prints what `Kaifile.roc` declares, and `kai lock` every input the lock pins, each as one line of documented, versioned JSON.
- `kai build NAME --plan` prints a build's inputs, snapshot, derivation and output path as JSON without building it.
- Nix builds get `$KAI_TOOLS`, a directory linking each of their tools, and `$KAI_INPUTS/.kai-inputs.json`, a record of their inputs.
- `RocPackages([url, ...])` in an `Environment` places the named Roc package bundles in Roc's package cache before a shell or task starts, so Roc does not download them.
- `Systems([...])` accepts `x86_64-darwin` and `x86_64-windows`, served by the direct backend from downloads and `Expect`, and downloads can be zip archives.
- A setup-kai GitHub Action, `thebrandonlucas/kai/.github/actions/setup-kai`, installs a given Kai release in CI with a download cache.
- Releases publish an Apple Silicon macOS kai, `kai-X.Y.Z-aarch64-darwin.tar.gz`, run on a macOS runner before each release is published. `install.sh`, `nix run github:thebrandonlucas/kai` and the setup-kai action install it on Apple Silicon Macs and macOS runners. `kai build` is not supported on macOS yet.
- For plugin authors: std exports `StdModel`, so a plugin with its own backend can implement `kai shell`, `run`, `build` and `workflow` from std's model.

### Changed

- **Breaking:** std serves only Nix and the direct backend. Guix needs the guix plugin, and `GuixChannel` moves from std's settings to the plugin's `Channel`; `kai --backend guix` without the plugin fails.
- `install.sh` runs nothing unless it downloaded in full, so a connection that drops while it is piped to `sh` no longer runs part of it. The README shows how to check the script against the release's `SHA256SUMS` and read it before running it.
- Outside a git repository, Kai uses only the current directory's `Kaifile.roc` and no longer searches the directories above it, where one, such as in the home directory, may belong to another project. Inside a repository, it still uses the nearest one up to the repository's root.

### Fixed

- `install.sh` names a program it needs that is not on `PATH`, such as `tar`, instead of reporting that the release has no build for the system when `sed` is missing.
- When `tar` or `chmod` is not on `PATH`, the direct backend names the missing program, as in "could not make jq executable: chmod is not on PATH", instead of saying only that it did not start.
- When a `System` is interpolated into a URL, as in `"${prefix}${system}"`, the error on the URL's other string now says to interpolate `system.to_str()`. The README's direct backend example builds each system's download URL that way.
- When Roc cannot download the platform or a package, Kai says so after Roc's `DownloadFailed`. When `/etc/resolv.conf`'s last line has no newline, as Docker Desktop writes it, which Roc cannot read, Kai names the file and says to end it with a newline.

## [0.0.11] - 2026-11-05

### Added

- Install Kai with one command: `curl -fsSL https://github.com/thebrandonlucas/kai/releases/latest/download/install.sh | sh`. The script checks the archive against the release's `SHA256SUMS`, installs `kai` into `~/.local/bin` (`--dir` or `KAI_INSTALL_DIR` to change it), and offers to install Nix when neither Nix nor Guix is present.
- `nix run github:thebrandonlucas/kai` and `nix profile install github:thebrandonlucas/kai` run and install the latest release.
- Each release includes an `aarch64-linux` archive beside the `x86_64-linux` one.
- A `direct` backend runs shells, tasks and workflows of tasks from pinned downloads, with no Nix or Guix installed. Kai uses it when Nix is unusable or does not fit, and `kai --backend direct` forces it. It does not run builds.
- `FetchLocked(name, [{ system, url, mirrors, program }])` declares a download with no published sha256, where `program` is `File` or `Archive(path)` for a program inside a tar.gz or tar.xz. `kai update` records each file's SHA-256 and size in the lock and does not fetch an already pinned file again unless it is named, as in `kai update jq`.
- `Expect([...])` in an `Environment` names programs the machine must already have. When any is missing, Kai names all of them and fails with the `missing_programs` error.
- On Nix, one environment can mix package tools with `FetchLocked` downloads and `Expect`. The downloads come first on `PATH` in its shells and tasks.
- When no matching `roc` is on `PATH` and Nix is not installed, Kai downloads its pinned Roc compiler, checks its SHA-256 and keeps it in its cache.
- `PackageEnv([(name, value), ...])` in an `Environment` sets variables to paths in packages: `LibraryPath([...])`, `BinPath([...])` or `PackagePath(tool)`, such as `("LD_LIBRARY_PATH", LibraryPath(["wayland", "vulkan-loader"]))`. It needs Nix.
- `OnSystems(systems, [Tools([...]), Env([...])])` in an `Environment` adds tools and variables on the named systems only.
- `RustToolchainWith(text, [Components([...]), Targets([...])])` adds components and targets to those a `rust-toolchain.toml` pins.
- Shells, tasks and builds get `KAI_SYSTEM`, the system they run on, and, when their environment has a Rust toolchain, `KAI_RUST_TARGET`, its Rust target triple. Guix shells and tasks do not set `KAI_SYSTEM`.
- `Dir(path)` in a `Task` runs it in a project-relative directory instead of the project root.
- `Default` in a `Build` makes it the build `kai build` builds when given no name.
- `BuildRoot(path)`, such as `BuildRoot("../..")`, makes builds copy a directory above the project, so a Kaifile in a subdirectory of a workspace can build against code at the workspace root.
- `FetchAll(name, { url, sha256 })` pins one file for every declared system, and `FetchUnavailable(name, [systems])` marks systems a `Fetch` has no file for, so Kai refuses only what uses it there.
- `Raw("nix", "environment:<name>", ...)` applies Nix attributes, such as a `shellHook`, to every shell and task of that environment.
- `CargoVendor` vendors git dependencies, each pinned by the commit `Cargo.lock` records. The vendored directory carries its own `.cargo/config.toml`, so a build passes `--config "$KAI_INPUTS/<name>/.cargo/config.toml"`.
- Errors have stable codes, a hint when Kai knows the fix, and suggestions for the closest name when one is mistyped, such as "did you mean `run`?". `kai run` without a task lists the tasks. The README's "Exit codes and errors" section lists the codes.
- `KAI_NO_CACHE=1` turns off reusing the compiled Kaifile and skipping an unchanged environment's evaluation.
- For plugin authors: plans can fail with a `Plan.Failure` carrying a code, hint and suggestions (`Plan.fail(message)` for a plain one, `Plan.closest` for suggestions), and gain the `Realise`, `Measure` and `ExpectPrograms` steps and `Remembered` output, in platform protocol 1.2.

### Changed

- Repeated `kai run` and `kai shell` are faster: Kai reuses the compiled Kaifile in `.kai/kaifile/` until one of its inputs changes, and skips evaluating a Nix environment that evaluated before unchanged.
- Without `--file`, Kai uses the nearest `Kaifile.roc` in the current directory or a parent, stopping at the git repository's root, and notes which one when it is not in the current directory.
- **Breaking:** With `--json`, Kai's events go to stderr and only results go to stdout. When Kai runs a task or shell, stdout holds only that program's output.
- **Breaking:** With `--json`, an error's `error` field is a stable code from the README's list instead of a name derived from Kai's internals, and a step that needs confirmation exits with code 6 instead of 1.
- **Breaking:** `kai` with no command prints concise help and exits 0 at a terminal; when stdout is not a terminal, or with `--json`, it is a usage error that exits 2, in or outside a project.
- Nix builds get their environment's tools as build inputs, so `pkg-config` and the compiler find their libraries and headers as they do in `kai shell`.
- Builds accept symbolic links that resolve inside the project, a source or the `Output`, and links from the `Output` into the store. Other links are still refused.
- The `Kaifile.roc` that `kai init` writes declares `x86_64-linux`, `aarch64-linux` and `aarch64-darwin`, so its shell and task work on macOS too.
- When `kai` and the Kaifile's platform speak different protocols, the error names the versions each side speaks and how to match them.

### Fixed

- Kai detects a terminal on its own streams, so help and errors are colored and a confirmation prompt can be answered without `--yes`.
- Adding an environment no longer makes the lock stale when it adds no input.
- `kai update <name>` accepts a `CargoVendor`'s name and notes that `cargo update` moves its crates.
- Remapping a `CargoVendor`'s path with `--remap-path-prefix=$KAI_INPUTS/<name>=/<name>` now keeps its crates out of a binary's closure.

## [0.0.10] - 2026-10-29

### Added

- Kai runs on Apple Silicon macOS when built from source (releases ship Linux archives only), and a Kaifile can declare `aarch64-darwin` in `Systems`. Shells and tasks run there on Nix; builds are still Linux-only, and Intel Macs are not supported.
- `kai bundle-plugin [DIR] [--output-dir DIR]` bundles a third-party plugin for hosting and prints the header line a Kaifile would use.
- `kai shell -- cmd` runs a command in the default shell.
- `kai build -L` (`--print-build-logs`) shows the build's log, and `kai build --out-link PATH` links `PATH` to the artifact as a garbage-collection root, on Nix and Guix.
- `kai update <input>...` updates only the named inputs, and `kai update` summarizes which inputs it added, moved or removed instead of printing Nix's log.
- `Env([("NAME", "value")])` sets environment variables in an `Environment`, `Task` or `Build`.
- `Secrets([...])` in a `Task` names variables it receives from a `.env` file at the project root or from Kai's environment, and keeps them from other tasks. `OptionalEnvironmentVariables([...])` names variables it receives from Kai's environment only when set.
- `Pure` in an `Environment` starts its shells and tasks from a clean environment.
- `Needs([...])` in a `Task` builds the named builds first and gives the task their artifacts in `$KAI_ARTIFACTS/<name>`.
- `Revision` in a `Build` gives it `KAI_REVISION` (`git describe --tags --always --dirty`) and `KAI_COMMIT_DATE`.
- `MayFail(step)` in a `Workflow` lets a step fail without stopping the workflow.
- `Description(text)` in a `Shell`, `Task`, `Build` or `Workflow` replaces the generated summary in help.
- `Alias(command, tool, binary)` in an `Environment` puts one binary of a tool on `PATH` under another name. It needs Nix.
- `RustToolchain(text)` in an `Environment` adds the toolchain a `rust-toolchain.toml` pins, given its text through `import "rust-toolchain.toml" as toolchain : Str`. It needs Nix and an overlay providing `rust-bin`.
- `Fetch(name, [{ system, url, sha256 }, ...])` pins a prebuilt file by its published sha256 per system. A build reads it at `$KAI_INPUTS/<name>`, and the tool `<name>#<binary>` puts it on `PATH`. It needs Nix.
- `CargoVendor(name, text)` gives builds the crates of a `Cargo.lock` at `$KAI_INPUTS/<name>`, pinned by its checksums, with no entry in Kai's lock. It needs Nix.
- `Follows(overlay, input, source)` makes an overlay's input, such as its `nixpkgs`, follow one of the project's package sources.
- `GuixChannel(name, url, branch, Introduction(commit, signer))` declares a third-party Guix channel, such as nonguix, which `kai --backend guix update` pins.
- Guix builds can read `path:` sources listed in their `Inputs`.
- A `Source` can fetch a single file with a `file+https://` or `file+http://` reference.
- Nix tool names accept quoted attribute segments, such as `rust-bin.stable."1.90.0".minimal`.
- Shells and tasks get `KAI_OPERATOR_SHELL`, the `SHELL` Kai was started from.
- Nix builds put their Roc package inputs in Roc's package cache, so a Roc build resolves its package URLs offline.
- Concurrent `kai build`s in one project take turns, and a build lock left by a kai that stopped is taken over.
- The README explains tasks versus sandboxed builds and loading a Kai shell with direnv, and new examples show a local `path:` source and agenix.

### Changed

- **Breaking:** A `Raw` for a backend other than `"nix"`, or a target other than `"flake"` or `"shell:<declared shell>"`, fails when `Kaifile.roc` compiles instead of later or never.
- **Breaking:** For plugin authors, a plan's `Run` step names its label `description` instead of `what`, also in std's `run_in`, and a plugin can no longer declare a command named `bundle-plugin`.
- A system no backend supports, such as `x86_64-darwin`, fails when `Kaifile.roc` compiles.
- Nix builds have the C compiler, binutils and standard tools a `kai shell` has.
- `kai build` exits with the build command's own exit status.
- `kai build` no longer passes Nix sandbox options, so untrusted users no longer see "ignoring the client-specified setting" warnings, and builds no longer warn about missing `NIX_PATH` entries.
- A plan checks a local `path:` source only when it reads it, so a missing or changed source no longer blocks shells and tasks that don't use it.
- Build snapshots copy only the paths the build's `Files` select and leave out links into the store, such as out-links.
- `kai update` with an unknown input is a usage error that exits 2, and it says it updated the lock only when the lock changed.
- An unknown task, build, workflow or shell is reported as such, with the available names, and a command's help lists them under their own heading, such as `Tasks:`.
- Kai notes the backend it uses only when it falls back from the preferred one or updates several.
- When `Kaifile.roc` fails to compile and its header names bundles from another Kai release, Kai names the releases involved.

### Fixed

- A shell or task whose environment fails to evaluate now says so instead of reporting its command as failed.
- A tool missing from its package source is named with its source and environment instead of Nix's bare missing attribute.
- A missing `path:` source or overlay is reported by its path instead of a raw `PathErr`.
- A lock whose recorded URL differs only in percent-encoding is no longer reported as changed.
- A failed `kai update` no longer leaves behind the Nix lock it rejected.
- A second Guix `kai build --out-link PATH` replaces the earlier link instead of failing.

## [0.0.9] - 2026-10-23

### Added

- `Files([...])` in a `Build` names the project files and directories its copy holds, so it rebuilds only when one of them changes.
- Without `ROC`, Kai uses the `roc` on `PATH` when it is the pinned version, and otherwise builds the pinned compiler with Nix once and keeps it in `~/.cache/kai/roc`.

### Changed

- Build snapshots leave out untracked files that the project's `.gitignore` files ignore.

Releases before 0.0.9 are described in their [GitHub release notes](https://github.com/thebrandonlucas/kai/releases).
