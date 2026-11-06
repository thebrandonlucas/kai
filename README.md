<h1 align="center">
  <img src="docs/images/kai-banner.jpg" alt="kαί: a friendly frontend for determinate computing" width="100%">
</h1>

[![Join the Kai Discord](https://img.shields.io/badge/Discord-Join%20the%20community-5865F2?logo=discord&logoColor=white)](https://discord.gg/pnANfSe4V)

> WARNING: Hobby project under rapid development. Use at your own risk!

Kai is a CLI that makes using determinate systems easy, friendly, and fun.

What if any computer device could be rebuilt _exactly_ from a file that you could easily backup, upload to a fresh device, or send to friends? What if the non-determinism introduced by modifying your computer with AI agents could be deterministically restrained, version-controlled? What if your whole setup was just code? What if, once you painstakingly figured out your setup, you never had to figure it out again?

[Nix](https://determinate.systems/) opened the door for the former, Kai aims to bring us home to the latter.

Spend very little time thinking about installing software, dependencies, developer environments, etc., and once you figure it out once, you _shouldn't have to figure it out again_. The problem is Nix is so hard to learn and use that people often give up (even agents get confused!). This is a complete paradigm shift in how we interact with software! But if no one uses it, what's the point?

To attempt a solution, `kai` wraps `nix` in a friendly frontend so that you can actually use it with confidence.

`kai` can already enter shells with the other determinate system, [Guix](https://guix.gnu.org/), through its [guix plugin](#guix), and plans to support more of it. If we're lucky, maybe it will even get a custom implementation which learns from the mistakes of the others :eyes:

The goal is to make using determinate systems so easy and powerful that they become the de-facto choice for computer use in all its forms: from desktops to servers and beyond. Practically, this means adopting Nix under the hood and creating useful abstractions on top in the short term, like [jujutsu](https://github.com/jj-vcs/jj) does with `git`.

## Use Cases

- Completely reproducible machine setups for spinning up VMs/VPS/Self-hosted services
- Easy to understand, low-token cost dotfile setups for your desktop
- Easily customizable and shareable Linux "distros" from a single fileset

## Installation

Kai runs on Linux and needs
[Nix with flakes enabled](https://nixos.org/download).

Install the latest release into `~/.local/bin`:

```sh
curl -fsSL https://github.com/thebrandonlucas/kai/releases/latest/download/install.sh | sh
```

The [script](install.sh) checks the download against the release's
`SHA256SUMS`. When neither Nix nor Guix is installed, it asks whether to
install Nix with the official installer and enable flakes; not at a
terminal, it only prints how, unless given `--yes`. Pass options after
`sh -s --`, such as `--version 0.0.10` or `--dir DIR`; see `--help`.

To read the script before running it, download it with the release's
`SHA256SUMS`, check it, and run it:

```sh
curl -fsSLO https://github.com/thebrandonlucas/kai/releases/latest/download/install.sh
curl -fsSLO https://github.com/thebrandonlucas/kai/releases/latest/download/SHA256SUMS
grep ' install.sh$' SHA256SUMS | sha256sum --check
less install.sh
sh install.sh
```

Or download the archive for your system from the
[latest release](https://github.com/thebrandonlucas/kai/releases/latest),
check it against the release's `SHA256SUMS`, and put `kai` on `PATH`:

```sh
tar -xzf kai-0.0.10-x86_64-linux.tar.gz
install -Dm755 kai ~/.local/bin/kai
kai --version
```

The archive contains only the `kai` binary. Kai evaluates `Kaifile.roc` with
the Roc compiler named in [`.roc-version`](.roc-version): one on `PATH` or set
as `ROC=/path/to/roc`, or else one it gets with Nix from
[roc-overlay](https://github.com/roc-lang/roc-overlay). Without Nix, it
downloads the nightly, by the digests in [`.roc-downloads`](.roc-downloads),
into its cache. Roc downloads the platform the first time it checks a `Kaifile.roc`.

With Nix, you can also run or install the latest release from this
repository's flake:

```sh
nix run github:thebrandonlucas/kai -- --version
nix profile install github:thebrandonlucas/kai
```

### Use Kai in GitHub Actions

The [setup-kai](.github/actions/setup-kai/action.yml) action installs Nix and
a Kai release with the install script, and caches Kai's downloads:

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: thebrandonlucas/kai/.github/actions/setup-kai@COMMIT
    with:
      version: 0.0.11
  - run: kai run test
```

Pin the action by a full commit SHA, or by a release tag from 0.0.12 on.
`version` is required, so that a run installs the same kai until the workflow
changes it. `cache` (default `true`) caches `~/.cache/kai`, the direct
backend's store and the Roc compiler Kai downloads, by the version, the
runner's OS and architecture, and `.kai/lock.json`. `nix` (default `true`)
installs Nix unless it is on `PATH`; set it to `false` for a project whose
environments are all [pinned downloads](#running-without-nix-or-guix).

## Getting started

A project is configured by `Kaifile.roc`, an ordinary
[Roc](https://roc-lang.org/) app on Kai's plugin platform. Its `kaifile` is
made of plugins; Kai's standard plugin, std, takes a list of settings:

```roc
app [kaifile] {
	pf: platform "https://github.com/thebrandonlucas/kai/releases/download/v0.0.10/9jXNkEdEWZ3cyQqHMLyTenLr4Xj5nEJT48UwnU8AxPCp.tar.zst",
	std: "https://github.com/thebrandonlucas/kai/releases/download/v0.0.10/std-CJKhhQ3UzajxpUqUKcpv2cwHGJpXQ8qPRiHKL5prqK2y.tar.zst",
}

import std.Std

kaifile = Std.kaifile([
	Name("hello"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("dev", [Tools(["cowsay", "python3"])]),
	Shell("default", [Use("dev")]),
	Task("hello", [Use("dev"), Run(["cowsay", "hello from kai"])]),
	Build(
		"greeting",
		[
			Use("dev"),
			Run(["sh", "-c", "cowsay built by kai > greeting.txt"]),
			Output("greeting.txt"),
		],
	),
	Workflow("ci", [RunTask("hello", []), BuildArtifact("greeting")]),
])
```

`kai --help` prints the header for the installed version: the platform and
std must come from the same release. Then:

```sh
kai check                         # compile and validate Kaifile.roc
kai update                        # pin package sources in .kai/lock.json
kai shell                         # enter the default shell
kai shell default -- cowsay hi    # or run one command in it
kai run hello                     # run a task
kai run hello -- again            # arguments after -- are appended
kai build greeting                # sandboxed build; prints the store path
kai build greeting --plan         # print its plan and identity as JSON (docs/build-plan.md)
kai build greeting --rebuild      # build again; fail if the output differs
kai workflow ci                   # run steps in order, stop at a failure
kai spec                          # print the project as JSON (docs/spec.md)
kai lock                          # print what the lock pins as JSON (docs/lock.md)
kai bundle-plugin plugins/deploy  # bundle a plugin package for hosting
```

Tool names are the backend's own package names: Nix attribute paths such as
`python3` or `rust-bin.stable."1.90.0".minimal` (quote a segment that is not a
plain identifier), or Guix specifications with the [guix plugin](#guix). Tasks run their argv exactly,
without a shell, so use `Run(["sh", "-c", "...", "sh"])` for pipes: `sh -c`
takes the argument after its script as `$0`, so the `"sh"` placeholder lets
arguments after `--` reach the script as `$1`, `$2`, ... and `"$@"`. In Roc
strings, multiline ones included, `${name}` is Roc interpolation, as is any
`${...}` such as `${name%.txt}`, so a script writes `$NAME`, or `\${NAME}`
where the shell needs braces. A backslash starts a Roc escape (`\\`, `\"`,
`\'`, `\$`, `\n`, `\r`, `\t`, `\u(41)`), so others, such as sed's `\(x\)` and
`\1`, are an "invalid escape sequence": write `\\(x\\)`, `\\1`, and `\\` for a
trailing line continuation. Every command has
help with examples, e.g. `kai run --help`; inside a project, help lists its
shells, tasks, builds and workflows.
`kai build -L` (`--print-build-logs`) shows the build's log as it runs, and
`kai build --out-link PATH` links PATH to the artifact and keeps it from
garbage collection.

### Settings

| Setting | Purpose |
| --- | --- |
| `Name(name)` | Project name. Required. |
| `Systems([...])` | Systems the generated flake declares. Optional (default `x86_64-linux` and `aarch64-linux`); must include the system of the host Kai runs on. `x86_64-darwin` and `x86_64-windows`, which neither Nix nor Guix serves, take only environments the [direct backend](#running-without-nix-or-guix) serves there: `kai check` refuses any other, naming it, unless `OnSystems` leaves its package tools to other systems. The generated flake leaves them out. |
| `Packages(name, source)` | A package source: `Auto`, `From(NixPackages(flakeRef))` or `From(GuixPackages(...))`, which only the [guix plugin](#guix) serves. Tools use the `default` source (`Auto`: nixpkgs unstable on Nix, the installed channels on Guix) unless written `"source#tool"`. |
| `Overlay(name, flakeRef)` | A Nix overlay, applied only where an environment selects it. |
| `Follows(overlay, input, source)` | Makes an overlay's own flake input, such as `nixpkgs`, the project's Nix package source `source` (`default` unless declared), so it is neither downloaded nor locked separately. |
| `Environment(name, [...])` | A set of tools: `Tools([...])`, `Overlays([...])` in order, and `Extend(parent)` to inherit the parent's tools, overlays and aliases first. `Alias(command, tool, binary)` (Nix only) puts `command` on PATH running the tool's `bin/<binary>`, e.g. for two tools that both install `bin/roc`. `RustToolchain(text)` (Nix only) adds the Rust toolchain a `rust-toolchain.toml` pins (its `channel`, `profile`, `components` and `targets`), given its text with `import "rust-toolchain.toml" as toolchain : Str`; the environment must select an `Overlay` of [rust-overlay](https://github.com/oxalica/rust-overlay). `RustToolchainWith(text, [Components([...]), Targets([...])])` adds components, such as `"llvm-tools-preview"`, and targets, such as `"wasm32-unknown-unknown"`, to those the file pins, for what only Kai's environment needs. |
| `Env([(name, value), ...])` | Environment variables, in an `Environment` for its shells, tasks and builds (overriding its parent's by name), or in a `Task` or `Build` overriding its environment's. |
| `PackageEnv([(name, value), ...])` | In an `Environment` (Nix only), environment variables set to paths in packages, which Kai computes: `LibraryPath([...])` and `BinPath([...])` join the tools' `lib` or `bin` directories with `:`, and `PackagePath(tool)` is the tool's own path, e.g. `("LD_LIBRARY_PATH", LibraryPath(["wayland"]))`. Like `Env`, they override the parent's by name, and a task's or build's `Env` overrides them. |
| `OnSystems([...], [...])` | In an `Environment`, `Tools([...])` and `Env([...])` for the named systems only, which must be declared: e.g. `OnSystems(["x86_64-linux", "aarch64-linux"], [Tools(["wayland"])])` gives one shell name a tool with no macOS build. Its tools come after the environment's own and its variables override the environment's; an extending environment's own `Env` overrides them in turn. On Nix the generated flake defines the environment for each system apart, so Nix evaluates only the host's; Guix uses the host's system. |
| `Expect([...])` | In an `Environment`, programs the machine must have, for the [direct backend](#running-without-nix-or-guix): all are looked for on `PATH` before anything runs, and every missing one is named. Nix checks them too, before a shell or task enters; Guix does not serve such an environment, and a build cannot use it. |
| `RocPackages([url, ...])` | In an `Environment`, released Roc package bundles, each `https://` and ending in `<hash>.tar.zst`, placed in Roc's package cache (`roc/packages/<hash>` under `$XDG_CACHE_HOME`, or `~/.cache`) before its shells and tasks start, so Roc programs there resolve them offline. List dependencies of dependencies too: basic-cli needs http; `roc deps <file>` prints them. `kai update` pins each file's SHA-256 and size in the lock's `direct` section, as a `Fetch` named `roc-<hash>`; the direct backend downloads it into kai's store, Nix fetches it as a fixed-output file, and a bundle already in the cache is left alone. `Extend` inherits them. Unpacking needs a `tar` that reads zstd. Builds take their bundles as `Source`s in `Inputs` instead. |
| `Pure` | In an `Environment`, and those extending it, starts its shells and tasks from a clean environment, so a task can check it needs nothing undeclared. Only HOME, USER, TERM, Kai's own variables and the `Env`, `Secrets` and `OptionalEnvironmentVariables` declared reach them. On Nix this is `nix develop --ignore-environment`; Guix shells are always pure, so it changes nothing there. |
| `Description(text)` | In a `Shell`, `Task`, `Build` or `Workflow`, its summary in help, in place of its environment, command, output or steps, which its own page (e.g. `kai run test --help`) still shows after it. |
| `Shell(name, [Use(environment)])` | A shell for `kai shell`. |
| `Task(name, [Use(environment), Run(argv)])` | A task for `kai run`. Optionally `Secrets([...])`: the names of the variables it receives when it runs, `OptionalEnvironmentVariables([...])`: those it receives from kai's environment only when set there, `Needs([...])`: builds kai builds first, in `$KAI_ARTIFACTS/<name>`, and `Dir(path)`: the project-relative directory it runs in, in place of the project root. |
| `Source(name, flakeRef)` | A locked, non-flake source that builds can read. |
| `Fetch(name, [{ system, url, sha256 }, ...])` | A file pinned by its published sha256 (hex or SRI), one per system; the host's system picks it, and it needs no lock entry. Builds read it in `Inputs([...])`, and the tool `"name#binary"` puts it on `PATH` as the executable `binary`. |
| `FetchAll(name, { url, sha256 })` | A `Fetch` of one file for every system, such as a data archive or a source tarball. |
| `FetchUnavailable(name, [...])` | The declared systems a `Fetch` or `FetchAll` has no file for, such as a tool with no macOS build. On them, Kai refuses only the shells, tasks and builds that use it, saying why, rather than the whole Kaifile; `OnSystems` can leave the tool out there instead. |
| `FetchLocked(name, [{ system, url, mirrors, program }, ...])` | A `Fetch` with no published sha256: `kai update` records each file's SHA-256 and size in the lock's `direct` section, and the [direct backend](#running-without-nix-or-guix) runs it, as does Nix beside package-source tools; a build cannot use it. `program` is `File`, or `Archive(path)` for a tar.gz, tar.xz or zip with the program at `path`; `mirrors` are other URLs for the same bytes. |
| `CargoVendor(name, text)` | The crates a `Cargo.lock` names, vendored into one directory that builds can read, pinned by the lock's checksums with no lock entry, so `kai update <name>` only says so (`cargo update` moves them). Pass the text with `import "Cargo.lock" as cargo_lock : Str`. A git dependency is fetched at the commit the lock records. |
| `Build(name, [...])` | A sandboxed Nix build of a project snapshot: `Use(environment)`, `Run(argv)`, a relative `Output(path)`, and optionally `Inputs([...])` (sources, fetches and cargo vendors, in `$KAI_INPUTS/<name>`), `Needs([...])` (other builds, in `$KAI_ARTIFACTS/<name>`), `Revision` (the project's revision, below) and `Default`, which makes it the build `kai build` builds when given no name (at most one build). |
| `BuildRoot(path)` | The directory builds copy, when it is above the project's, as `..` segments: `BuildRoot("../..")` lets an app whose Kaifile sits in `apps/web` build against a library at the repository root. Builds copy that directory instead of the project's, and their `Files`, `Run` and `Output` work from it; `.kai` stays out of the copy. |
| `Workflow(name, [...])` | Steps for `kai workflow`, which stops at the first that fails: `RunTask(task, args)`, `BuildArtifact(build)`, `RunWorkflow(workflow)`, and `MayFail(step)`, which notes the step's failure and continues. |
| `Raw("nix", target, value)` | Extra attributes for the generated flake (`"flake"`), one shell (`"shell:<name>"`), or every shell and task using an environment (`"environment:<name>"`, not its builds or the environments extending it), e.g. `Attrs([("shellHook", Str("echo hi"))])`. A shell's own attribute replaces its environment's of the same name. |

Names and references are checked as the file compiles, so `kai check` reports
mistakes before anything runs. [examples](examples/) has a small project for
each setting and command, from a first shell to builds, workflows and the
guix plugin.

### Tasks and builds

Shells and tasks run on your machine, in the project directory (or a task's
`Dir`), inside the environment's shell: they see your files, your network and
anything else you can reach, and what they write stays in the working tree.
`KAI_OPERATOR_SHELL` holds the `SHELL` kai was started from, since the
environment may replace `SHELL`.

A task gets the secrets it declares with `Secrets([...])` from a `.env` file
at the project root (`NAME=value` lines; `#` comments; no interpolation),
else from kai's environment, and never those only other tasks declare. Only
the names are in the Kaifile and plans; add `.env` to your `.gitignore`. A
name in its `OptionalEnvironmentVariables([...])` is optional, never read
from `.env`, and reaches it even when another task declares it secret.

Builds run sandboxed. A build gets a copy of the project (or of its
`BuildRoot`, from which it then runs), leaving out what its `.gitignore`
files ignore (`Files([...])` narrows the copy to the given relative paths),
plus only the tools its environment's shell has, its declared sources
(`$KAI_INPUTS`) and the artifacts of the builds it needs
(`$KAI_ARTIFACTS`). It has no network, and only its `Output` is kept, in the
store. On Nix, its tools are its build inputs, so their setup hooks run as in
`kai shell`: `pkg-config` finds the environment's libraries, and the compiler
their headers and library paths. Symbolic links in the project and its
sources must resolve inside them, and those in its `Output` inside the output
or into the store; Kai refuses any other. A Nix build's sources that are Roc
package bundles, such as
`tarball+https://…/<hash>.tar.zst`, are in its Roc package cache, so Roc
resolves those package URLs offline. The sandbox has no `/usr/bin/env`, so
run scripts as `sh script` or through an interpreter's path rather than
relying on a `#!/usr/bin/env` line. An artifact that embeds paths to its
inputs, such as Rust panic locations in `$KAI_INPUTS/<name>`, keeps those
inputs alive in its closure; remap them, e.g. with Rust's
`--remap-path-prefix=$KAI_INPUTS/<name>=/<name>`, and check the closure with
`nix path-info -rS <path>`.

The sandbox has no `.git` either, so a build that stamps a version declares
`Revision`: it gets `KAI_REVISION`, the project's
`git describe --tags --always --dirty` (such as `v0.2.0-3-gabc1234`), and
`KAI_COMMIT_DATE`, the date of its last commit (`YYYY-MM-DD`), both empty
outside git or when git is not installed. Its inputs then change with every
commit, which is why it is opt-in.

On Nix and the direct backend, every shell, task and build also gets
`KAI_SYSTEM`, the system it runs on,
such as `x86_64-linux` or `aarch64-darwin`, and, when its environment has a
`RustToolchain` (Nix only), `KAI_RUST_TARGET`, that system's Rust target
triple, such as `x86_64-unknown-linux-gnu`, for paths like
`target/$KAI_RUST_TARGET/release`. A variable of the same name in an `Env`
replaces them.

So that a build can say what made it, such as in an SBOM it writes, a Nix
build also gets `KAI_TOOLS`, a directory linking each tool of its
environment, by the name the Kaifile gives it, to the tool's store path, and
`$KAI_INPUTS/.kai-inputs.json`, a record of each of its inputs and needs:
its name, kind, URL, revision and hash, as [`kai lock`](docs/lock.md)
reports them. Neither adds to an artifact's closure unless the artifact
names a store path; see [docs/evidence.md](docs/evidence.md).
`kai build NAME --plan` prints the same records with the build's snapshot,
derivation and output path, without building; see
[docs/build-plan.md](docs/build-plan.md).

A Rust build reads its crates from a `CargoVendor` in its inputs through the
cargo configuration in the vendored directory, which replaces crates.io and
each git dependency with it. Cargo then reads the crates under
`$KAI_INPUTS/crates`, so remapping that path keeps them out of the
artifact's closure, as [examples/cargo-vendor](examples/cargo-vendor) does:

```sh
export RUSTFLAGS="--remap-path-prefix=$KAI_INPUTS/crates=/crates"
cargo build --offline --locked --config "$KAI_INPUTS/crates/.cargo/config.toml"
```

Use a task for work that touches the project or the outside world, such as
running tests, formatting or deploying. Use a build for an artifact that should
depend only on what it declares, not on the machine it is built on.

### Reusing configuration

Reuse is ordinary Roc: a module returns settings and `Kaifile.roc` imports it.
From [examples/modules](examples/modules):

```roc
# CowTasks.roc
import std.Config
import std.EnvName

CowTasks :: [].{
	settings : EnvName -> List(Config.Setting)
	settings = |environment| [
		Task("moo", [Use(environment), Run(["cowsay", "moo"])]),
		Task("say", [Use(environment), Run(["cowsay"])]),
	]
}
```

```roc
# Kaifile.roc, after the app header
import CowTasks
import std.Std

kaifile = Std.kaifile(
	[
		Name("modules"),
		Environment("cow", [Tools(["cowsay"])]),
		Shell("default", [Use("cow")]),
	].concat(CowTasks.settings("cow")),
)
```

A module can only add settings. New commands, and replacements for one
command on one backend, come from plugins: Roc packages next to std in
`Kaifile.new([...])`. See [docs/plugin.md](docs/plugin.md) and
[examples/plugins/deploy](examples/plugins/deploy), which adds `kai deploy`.

## Backends

Kai picks a backend for each command. Nix is preferred when it is installed and
can serve the request. The direct backend, which needs no Nix, comes next,
and a plugin's backends, such as Guix, follow in the order the Kaifile lists
the plugins (`Kaifile.prefer` changes it). `--backend nix` or
`--backend direct` forces one, as does `--backend guix` with the guix
plugin; Kai never falls back to another.

### Guix

Guix is a plugin beside std, `plugins/guix`: it implements `kai shell`,
`run`, `build`, `workflow` and `update` on Guix from the same settings.
Add it to Kaifile.roc's header and plugins:

```roc
app [kaifile] {
	pf: platform "<platform URL>",
	std: "<std URL>",
	guix: "<guix plugin URL>",
}

import pf.Kaifile
import std.Config
import std.Std
import guix.Guix

project : List(Config.Setting)
project = [
	Name("site"),
	Environment("dev", [Tools(["hello"])]),
	Shell("default", [Use("dev")]),
]

kaifile = Kaifile.new([Std.plugin(project), Guix.plugin(project, [])])
```

Each Kai release after 0.0.11 publishes the guix plugin bundled against its
own platform and std, as `guix-<hash>.tar.zst`. The release's notes give the
`guix:` line to add to the header, beside the `pf` and `std` lines of the
same release, and `plugins/guix-release` in its source records the URL.

Guix is used when Nix is not installed, or when the environment's tools come
from a `GuixPackages` source. `kai shell` and `kai run` run `guix
time-machine -C CHANNELS -- shell -q --pure` with the environment's tools,
at the Guix channel commits Kai's lock pins. `kai build` runs `guix build
-f` on a generated file whose derivation runs the same sandboxed build runner
as on Nix, and `kai workflow` runs tasks and builds in order. `kai update`
pins every installed backend that fits, each in its own section of
`.kai/lock.json` (`kai --backend guix update` pins only Guix), and Guix
commands refuse to run without a Guix pin. The first Guix command at a new
commit downloads, or builds, that Guix, which can take a long time. Overlays,
`Fetch`, `Alias`, `PackageEnv`, `RustToolchain`, `Expect` and build
inputs (`Inputs([...])`) other than `path:` sources need Nix.

The plugin's one setting, `Channel(name, url, branch, Introduction(commit,
signer))`, adds a Guix channel beside Guix's own, authenticated by its
introduction: the first signed commit and its signer's OpenPGP fingerprint,
as the channel publishes them. Its packages are available to every Guix
source, and `kai update` locks its commit. See [examples/guix](examples/guix).

### Running without Nix or Guix

The direct backend runs shells and tasks from pinned downloads, for tools
built on Kai whose users cannot be assumed to have Nix. It serves an
environment whose tools are all `Fetch` or `FetchLocked` files, and needs only
`tar`, `chmod`, `sh` and `env` on the machine (and `xz` for a tar.xz, and
`unzip`, or a `tar` that is bsdtar as on macOS, for a zip):

```roc
kaifile = Std.kaifile([
	Name("site"),
	Systems(["x86_64-linux"]),
	FetchLocked(
		"zig",
		[
			{
				system: "x86_64-linux",
				url: "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz",
				mirrors: [],
				program: Archive("zig-x86_64-linux-0.16.0/zig"),
			},
		],
	),
	Environment("dev", [Tools(["zig#zig"]), Expect(["git"])]),
	Task("test", [Use("dev"), Run(["zig", "build", "test"])]),
])
```

`kai update` downloads each file it has no pin for, on every declared system,
and records its SHA-256 and size in `.kai/lock.json`; `kai update zig` measures
zig's files again. `kai run test` then
checks that every `Expect` program is on `PATH`, makes the downloads ready, and
runs the task with them first on `PATH`.

Downloads go over HTTPS with no credentials into `kai/v1` in the cache
directory, named by SHA-256, and are hashed again before every use. An archive
is unpacked whole, after listing it: one with an absolute name, a `..`, a
backslash or a link out of the tree (any link, for a zip unzip lists) is
refused, and its files are made read-only. The store may be deleted at any time. See
[examples/direct](examples/direct).

It is the only backend for `x86_64-darwin` and `x86_64-windows`, so a project
can declare them for its CI legs there: `kai update` on Linux pins their files
too. Kai itself does not run on them yet. On Windows the downloads are copied
into the environment's `bin` directory, with their `.exe`, instead of linked.

A pinned download pins one file, not a dependency tree, so this suits static
binaries: a program needing the machine's shared libraries is only as
reproducible as the machine. A workflow of tasks runs; `kai build`, and a
workflow with a build, need Nix for its sandbox, as do tools from package sources, `Overlays`, `Alias`, `PackageEnv`,
`RustToolchain` and `Pure`.

One environment can mix tools from package sources with `FetchLocked`
downloads and `Expect`, such as a nightly compiler pinned by URL beside
`zip` from nixpkgs. Nix then serves its shells and tasks: it checks the
`Expect` programs, makes the downloads ready in the same store, and runs
inside the environment with them first on `PATH` (a shell with no command
starts the shell Kai was started from). `kai update` pins both. The direct
backend refuses such an environment, naming the tools that are not
downloads, and a build cannot use it, as its sandbox sees neither the
lock's direct pins nor the machine's programs. See
[examples/mixed](examples/mixed).

## SBOMs

The sbom plugin, `plugins/sbom`, writes a release's SBOMs from the same
settings and lock: SPDX 3.0.1, SPDX 2.3 and CycloneDX 1.7 sidecars of a
release file and an evidence manifest, from a composition the maintainer
reviews. Add it to Kaifile.roc's header with the `sbom:` line from the
release's notes (each release after 0.0.11 publishes the plugin as
`sbom-<hash>.tar.zst`, and `plugins/sbom-release` records its URL), and to
its plugins beside std:

```roc
kaifile = Kaifile.new([Std.plugin(project), Sbom.plugin(project)])
```

```sh
kai sbom inputs                      # the inputs a composition disposes of
kai sbom inspect --composition composition.json --output inventory.json -- source
kai sbom bind --inventory inventory.json --subject subject.json \
  --context context.json --artifact dist/app.tar.zst
kai sbom check --manifest dist/app.tar.zst.sbom-manifest.json
```

It follows roc-blueprint's SBOM profile, so a project moving from
roc-blueprint keeps its reviewed composition and publishes the same
documents. See [docs/sbom.md](docs/sbom.md) and
[examples/sbom](examples/sbom).

## Machines

The nixos plugin, `plugins/nixos`, declares NixOS machines beside the
project's environments, added like the [guix plugin](#guix):

```roc
kaifile = Kaifile.new([
	Std.plugin(project),
	Nixos.plugin(project, [
		Machine("web", [
			System("x86_64-linux"),
			StateVersion("25.05"),
			User("admin", [SshKeys(["ssh-ed25519 AAAA... admin@example"])]),
			Ssh,
			Firewall([Tcp([80, 443])]),
			Use("ops"),
			Modules(["nixos/web.nix"]),
		]),
	]),
])
```

A small typed core covers what most machines set; anything else comes from
plain NixOS module files. Each machine is `nixosConfigurations.<name>` in the
generated flake, built from the project's locked nixpkgs. `kai machine build
web` builds its system and prints the store path. On the machine itself,
`kai machine switch web` builds it and, once you confirm, makes it the
running system and the boot default; `kai machine rollback web` returns to
the previous one and `kai machine generations web` lists them. Each refuses
another host. See
[docs/machines.md](docs/machines.md) and
[examples/machines](examples/machines).

## The `.kai` directory

`kai update` is the only command that resolves package sources. It writes
`.kai/lock.json`. `kai shell`, `run`, `build` and `workflow` only read it, and
ask you to run `kai update` when it is missing, when a source, input or an
environment's overlay order changed, or when a locked local source has
changed. An environment or tool using only locked sources needs no update.
Commit the lock; the rest of `.kai` is generated:

```gitignore
/.kai/*
!/.kai/lock.json
```

`KAI_DIR=<name>` moves the whole directory to another top-level name in the
project.

## direnv

To load a shell into your own shell whenever you enter the project, with
[direnv](https://direnv.net), add an `.envrc` and run `direnv allow`:

```sh
watch_file Kaifile.roc .kai/lock.json
direnv_load kai shell default -- direnv dump
```

direnv reloads it when `Kaifile.roc` or the lock changes. It needs Nix:
Guix's pure shell drops the `PATH` and variable `direnv dump` needs. Avoid
nix-direnv's `use flake` on `.kai/generated/nix`: each kai command regenerates
that flake with only what it runs, so after `kai run` or `kai build` it may
not have the shell.

direnv waits for the shell before showing your prompt, which takes a while
after `kai update` or a Kaifile change. To keep the prompt free meanwhile,
replace direnv's shell hook with
[direnv-instant](https://github.com/Mic92/direnv-instant)'s: it runs the same
`.envrc` in the background and loads the shell once it is ready.

## Options

- `-f`, `--file PATH`: use another configuration file. Its directory is the
  project root. Without it, kai uses the nearest `Kaifile.roc`: in the
  current directory or the first above it, up to the git repository's root,
  and says which when it is not in the current directory.
- `--json`: print Kai's own messages as JSON Lines, one object per line. Each
  has `type` and `message`, plus fields for its type (e.g. `backend`,
  `step_started`, `artifact`, or `error`, described in
  [Exit codes and errors](#exit-codes-and-errors)). Results, such as
  `describe`, `check`, `update` or a build's `artifact`, go to stdout, and
  progress and errors to stderr. Output from shells and tasks passes through
  unchanged; when a command runs one, stdout is only theirs, and its results
  go to stderr too, where Kai's events are the lines that start with `{`.
- `--no-color`, or a non-empty `NO_COLOR`: plain text.
- `--backend nix|direct`, or `guix` with the guix plugin: see
  [Backends](#backends).
- `ROC`: the Roc compiler that evaluates `Kaifile.roc` (default: `roc`). It
  must be the pinned version; Kai says which one otherwise.

## Exit codes and errors

| Exit code | Meaning |
|---|---|
| 0 | Success. |
| 1 | A failure of Kai's that no other code covers. |
| 2 | A usage error, such as an unknown command, task or flag, or `kai` without a command when stdout is not a terminal. |
| 6 | A step needs confirmation; pass `--yes` to accept it. |

A failing shell, task or build's exit status becomes Kai's unchanged, so any
code can also come from it; with `--json`, its `error` event says
`child_exited`.

With `--json`, a failure ends with an `error` event: `message` says what went
wrong, `exit_code` is Kai's exit code, `hint`, when Kai knows the fix, is
usually a command to run (`kai update`), `suggestions`, after a mistyped
command, task, shell, build or workflow, lists the closest names (Kai never
runs them), and `error` is one of these codes:

| `error` | Meaning |
|---|---|
| `invalid_usage` | The command line is wrong. |
| `refused` | The Kaifile refused the request. |
| `no_kaifile` | There is no `Kaifile.roc`. |
| `not_a_kaifile` | The `-f` file is not a Kaifile. |
| `kaifile_exists` | `kai init` found a `Kaifile.roc`. |
| `kaifile_invalid` | `Kaifile.roc` did not compile. |
| `incompatible_protocol` | `Kaifile.roc`'s platform needs another Kai. |
| `no_compiler` | The pinned Roc compiler is not available. |
| `unsupported_host` | Kai does not run on this system. |
| `bundle_failed` | `kai bundle-plugin` failed. |
| `bad_response` | Kai could not read the Kaifile's answer. |
| `invalid_project` | The project's settings or `.kai` are invalid. |
| `unsafe` | Kai refused an unsafe path or plan. |
| `missing_source` | A local source or overlay does not exist. |
| `stale_lock` | A locked local source changed since `kai update`. |
| `lock_failed` | Locking the inputs failed. |
| `update_conflict` | Another `kai update` ran at the same time. |
| `confirmation_required` | A step needs confirmation (exit code 6). |
| `declined` | A confirmation was answered no. |
| `child_exited` | A shell, task or build failed. |
| `missing_programs` | Programs an environment `Expect`s are not on `PATH`; `programs` lists them. |
| `missing_secret` | A secret is not set. |
| `invalid_dotenv` | `.env` has an invalid line. |
| `no_backend` | No backend can serve the request. |
| `no_implementation` | No plugin implements the command. |
| `plan_failed` | A plan failed without a code of its own; [docs/plugin.md](docs/plugin.md) lists the codes plans fail with. |
| `failed` | Any other failure. |

## Limits

- Linux only. Kai runs on `x86_64-linux` and `aarch64-linux`, and generates
  shells and builds for the system it runs on.
- Services, deploy, images, ISOs and secrets are not in this version, and
  the old `Kaifile` format is not read. If you need them, stay on
  [v0.0.7](https://github.com/thebrandonlucas/kai/releases/tag/v0.0.7)
  (`nix run github:thebrandonlucas/kai/v0.0.7`).

## Development

How to build, test and propose changes is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Design

> Simple things should be simple, complex things should be possible

- [Alan Kay](https://www.quora.com/What-is-the-story-behind-Alan-Kay-s-adage-Simple-things-should-be-simple-complex-things-should-be-possible)

See [design.md](docs/design.md).

## Goals

1. Great UX. The benefits and usage of Kai should be immediate and obvious.
2. Modularity:
    a. A great set of default features downstream of determinism: (rollbacks, dev shells, builds, garbage-collection, etc.)
    b. The ability to add/remove subcommands via a command module registry similar to [Caddy](https://caddyserver.com/).
    c. The ability to modify the default set of modules to fit user needs.
    d. To the degree possible, the ability to replace suboptimal pieces of the underlying system (i.e. encourage a "protocol" or modularity in determinate systems), as opposed to the current monolithic nature of Nix/Guix. See [snix]() for example.
3. Unlocking new use cases and ergonomics. Encouraging benefits that are overlooked or underutilized in current systems. Big examples would be easy desktop setups (or easily trying others' setups just to check them out!), easy, safe modification, easy backups etc. Simple examples include little ergonomic things like e.g. `kai shell keep` to add any temporary shell programs to your `flake.nix` permanently (or eventually to `configuration.nix`).

### Contributing

If you would like to contribute, I would love for you to open an issue! [CONTRIBUTING.md](CONTRIBUTING.md) explains how to build Kai and propose changes, and questions are welcome in [Discussions](https://github.com/thebrandonlucas/kai/discussions) or on the Discord.

### Looking Ahead

Aside from making a great tool for programmers to encourage the use of determinate computing, the hope is to go far beyond that and [dream](https://www.amazon.com/Dream-Machine-M-Mitchell-Waldrop/dp/1732265119) about what computers could be. I believe determinate computing is in its nascent form, and the true realization of its potential could have monumental and lasting effects as a new, better way to use computers.

### Attribution

Huge thank you to Luke Boswell for inspiring the initial portable typed configuration idea with [roc-blueprint](https://github.com/lukewilliamboswell/roc-blueprint) and his enthusiastic evangelism of this idea. Kai's plugin platform (`platform/`), std's model (`plugins/std/model/`) and its Nix backend (`plugins/std/backends/nix/`) began as roc-blueprint's code (see [LICENSE](LICENSE)).

Also thank you to the longstanding efforts of the Nix and Guix developers without which this would be impossible, the [Roc](https://roc-lang.org/) team for their encouragement and making a great language to build in, and the [caddy](https://caddyserver.com/) devs from which this project takes heavy inspiration.

The banner shows Thomas Cole's *The Course of Empire: The Arcadian or Pastoral State* (1834), public domain, from [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Cole_Thomas_The_Course_of_Empire_The_Arcadian_or_Pastoral_State_1836.jpg).
