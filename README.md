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

`kai` can already enter shells with the other determinate system, [Guix](https://guix.gnu.org/), and plans to support more of it. If we're lucky, maybe it will even get a custom implementation which learns from the mistakes of the others :eyes:

The goal is to make using determinate systems so easy and powerful that they become the de-facto choice for computer use in all its forms: from desktops to servers and beyond. Practically, this means adopting Nix under the hood and creating useful abstractions on top in the short term, like [jujutsu](https://github.com/jj-vcs/jj) does with `git`.

## Use Cases

- Completely reproducible machine setups for spinning up VMs/VPS/Self-hosted services
- Easy to understand, low-token cost dotfile setups for your desktop
- Easily customizable and shareable Linux "distros" from a single fileset

## Installation

Kai runs on Linux and needs
[Nix with flakes enabled](https://docs.determinate.systems/?phid=019ef5f5-e228-7eb4-9a1e-4dbe9b75b79e).

Download the archive for your system from the
[latest release](https://github.com/thebrandonlucas/kai/releases/latest),
check it against the release's `SHA256SUMS`, and put `kai` on `PATH`:

```sh
tar -xzf kai-0.0.9-x86_64-linux.tar.gz
install -Dm755 kai ~/.local/bin/kai
kai --version
```

The archive contains only the `kai` binary. Kai evaluates `Kaifile.roc` with
the Roc compiler named in [`.roc-version`](.roc-version): one on `PATH` or set
as `ROC=/path/to/roc`, or else one it gets with Nix from
[roc-overlay](https://github.com/roc-lang/roc-overlay). Roc downloads the
platform the first time it checks a `Kaifile.roc`.

## Getting started

A project is configured by `Kaifile.roc`, an ordinary
[Roc](https://roc-lang.org/) app on Kai's plugin platform. Its `kaifile` is
made of plugins; Kai's standard plugin, std, takes a list of settings:

```roc
app [kaifile] {
	pf: platform "https://github.com/thebrandonlucas/kai/releases/download/v0.0.8/8eM3r3RE4n1BFSWqD7wvqch5UW3ACJ7LLJiiin5nxJdK.tar.zst",
	std: "https://github.com/thebrandonlucas/kai/releases/download/v0.0.8/std-6zJHFrCtGkKhyuiNbmnJNHPx2DQvcgUeDL2znXw86ZEx.tar.zst",
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
kai workflow ci                   # run steps in order, stop at a failure
kai bundle-plugin plugins/deploy  # bundle a plugin package for hosting
```

Tool names are the backend's own package names: Nix attribute paths such as
`python3` or `rust-bin.stable."1.90.0".minimal` (quote a segment that is not a
plain identifier), or Guix specifications. Tasks run their argv exactly,
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
| `Systems([...])` | Systems the generated flake declares. Optional (default `x86_64-linux` and `aarch64-linux`); must include the system of the host Kai runs on. |
| `Packages(name, source)` | A package source: `Auto`, `From(NixPackages(flakeRef))` or `From(GuixPackages(...))`. Tools use the `default` source (`Auto`: nixpkgs unstable on Nix, the installed channels on Guix) unless written `"source#tool"`. |
| `Overlay(name, flakeRef)` | A Nix overlay, applied only where an environment selects it. |
| `Follows(overlay, input, source)` | Makes an overlay's own flake input, such as `nixpkgs`, the project's Nix package source `source` (`default` unless declared), so it is neither downloaded nor locked separately. |
| `GuixChannel(name, url, branch, Introduction(commit, signer))` | A Guix channel beside Guix's own, authenticated by its introduction: the first signed commit and its signer's OpenPGP fingerprint, as the channel publishes them. Its packages are available to every Guix source; `kai update` locks its commit. Nix ignores it. |
| `Environment(name, [...])` | A set of tools: `Tools([...])`, `Overlays([...])` in order, and `Extend(parent)` to inherit the parent's tools, overlays and aliases first. `Alias(command, tool, binary)` (Nix only) puts `command` on PATH running the tool's `bin/<binary>`, e.g. for two tools that both install `bin/roc`. `RustToolchain(text)` (Nix only) adds the Rust toolchain a `rust-toolchain.toml` pins (its `channel`, `profile`, `components` and `targets`), given its text with `import "rust-toolchain.toml" as toolchain : Str`; the environment must select an `Overlay` of [rust-overlay](https://github.com/oxalica/rust-overlay). `RustToolchainWith(text, [Components([...]), Targets([...])])` adds components, such as `"llvm-tools-preview"`, and targets, such as `"wasm32-unknown-unknown"`, to those the file pins, for what only Kai's environment needs. |
| `Env([(name, value), ...])` | Environment variables, in an `Environment` for its shells, tasks and builds (overriding its parent's by name), or in a `Task` or `Build` overriding its environment's. |
| `PackageEnv([(name, value), ...])` | In an `Environment` (Nix only), environment variables set to paths in packages, which Kai computes: `LibraryPath([...])` and `BinPath([...])` join the tools' `lib` or `bin` directories with `:`, and `PackagePath(tool)` is the tool's own path, e.g. `("LD_LIBRARY_PATH", LibraryPath(["wayland"]))`. Like `Env`, they override the parent's by name, and a task's or build's `Env` overrides them. |
| `OnSystems([...], [...])` | In an `Environment`, `Tools([...])` and `Env([...])` for the named systems only, which must be declared: e.g. `OnSystems(["x86_64-linux", "aarch64-linux"], [Tools(["wayland"])])` gives one shell name a tool with no macOS build. Its tools come after the environment's own and its variables override the environment's; an extending environment's own `Env` overrides them in turn. On Nix the generated flake defines the environment for each system apart, so Nix evaluates only the host's; Guix uses the host's system. |
| `Pure` | In an `Environment`, and those extending it, starts its shells and tasks from a clean environment, so a task can check it needs nothing undeclared. Only HOME, USER, TERM, Kai's own variables and the `Env`, `Secrets` and `OptionalEnvironmentVariables` declared reach them. On Nix this is `nix develop --ignore-environment`; Guix shells are always pure, so it changes nothing there. |
| `Description(text)` | In a `Shell`, `Task`, `Build` or `Workflow`, its summary in help, in place of its environment, command, output or steps, which its own page (e.g. `kai run test --help`) still shows after it. |
| `Shell(name, [Use(environment)])` | A shell for `kai shell`. |
| `Task(name, [Use(environment), Run(argv)])` | A task for `kai run`. Optionally `Secrets([...])`: the names of the variables it receives when it runs, `OptionalEnvironmentVariables([...])`: those it receives from kai's environment only when set there, `Needs([...])`: builds kai builds first, in `$KAI_ARTIFACTS/<name>`, and `Dir(path)`: the project-relative directory it runs in, in place of the project root. |
| `Source(name, flakeRef)` | A locked, non-flake source that builds can read. |
| `Fetch(name, [{ system, url, sha256 }, ...])` | A file pinned by its published sha256 (hex or SRI), one per system; the host's system picks it, and it needs no lock entry. Builds read it in `Inputs([...])`, and the tool `"name#binary"` puts it on `PATH` as the executable `binary`. |
| `FetchAll(name, { url, sha256 })` | A `Fetch` of one file for every system, such as a data archive or a source tarball. |
| `FetchUnavailable(name, [...])` | The declared systems a `Fetch` or `FetchAll` has no file for, such as a tool with no macOS build. On them, Kai refuses only the shells, tasks and builds that use it, saying why, rather than the whole Kaifile; `OnSystems` can leave the tool out there instead. |
| `CargoVendor(name, text)` | The crates a `Cargo.lock` names, vendored into one directory that builds can read, pinned by the lock's checksums with no lock entry. Pass the text with `import "Cargo.lock" as cargo_lock : Str`. A git dependency is fetched at the commit the lock records. |
| `Build(name, [...])` | A sandboxed Nix build of a project snapshot: `Use(environment)`, `Run(argv)`, a relative `Output(path)`, and optionally `Inputs([...])` (sources, fetches and cargo vendors, in `$KAI_INPUTS/<name>`), `Needs([...])` (other builds, in `$KAI_ARTIFACTS/<name>`), `Revision` (the project's revision, below) and `Default`, which makes it the build `kai build` builds when given no name (at most one build). |
| `BuildRoot(path)` | The directory builds copy, when it is above the project's, as `..` segments: `BuildRoot("../..")` lets an app whose Kaifile sits in `apps/web` build against a library at the repository root. Builds copy that directory instead of the project's, and their `Files`, `Run` and `Output` work from it; `.kai` stays out of the copy. |
| `Workflow(name, [...])` | Steps for `kai workflow`, which stops at the first that fails: `RunTask(task, args)`, `BuildArtifact(build)`, `RunWorkflow(workflow)`, and `MayFail(step)`, which notes the step's failure and continues. |
| `Raw("nix", target, value)` | Extra attributes for the generated flake (`"flake"`), one shell (`"shell:<name>"`), or every shell and task using an environment (`"environment:<name>"`, not its builds or the environments extending it), e.g. `Attrs([("shellHook", Str("echo hi"))])`. A shell's own attribute replaces its environment's of the same name. |

Names and references are checked as the file compiles, so `kai check` reports
mistakes before anything runs. [examples](examples/) has a small project for
each setting and command, from a first shell to builds, workflows and Guix.

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

A Rust build reads its crates from a `CargoVendor` in its inputs through the
cargo configuration in the vendored directory, which replaces crates.io and
each git dependency with it, as [examples/cargo-vendor](examples/cargo-vendor)
does:

```sh
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
can serve the request. Guix is used when Nix is not installed, or when the
environment's tools come from a `GuixPackages` source. `--backend nix` or
`--backend guix` forces one; Kai never falls back to the other.

On Guix, `kai shell` and `kai run` run `guix time-machine -C CHANNELS --
shell -q --pure` with the environment's tools, at the Guix channel commits
Kai's lock pins. `kai build` runs `guix build -f` on a generated file whose
derivation runs the same sandboxed build runner as on Nix, and `kai workflow`
runs tasks and builds in order. `kai update` pins every installed backend that
fits, each in its own section of `.kai/lock.json` (`kai --backend guix update`
pins only Guix), and Guix commands refuse to run without a Guix pin. The first
Guix command at a new commit downloads, or builds, that Guix, which can take a
long time. Overlays, `Fetch` and build inputs (`Inputs([...])`) other than
`path:` sources need Nix. See
[examples/guix](examples/guix).

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
- `--json`: print Kai's own messages as JSON Lines on stdout. Each has `type`
  and `message`, plus fields for its type (e.g. `backend`, `step_started`,
  `artifact`, or `error` with `error` and `exit_code`). Output from shells and
  tasks passes through unchanged.
- `--no-color`, or a non-empty `NO_COLOR`: plain text.
- `--backend nix|guix`: see [Backends](#backends).
- `ROC`: the Roc compiler that evaluates `Kaifile.roc` (default: `roc`). It
  must be the pinned version; Kai says which one otherwise.

A failing child's exit status becomes Kai's. Usage errors exit 2 and other
errors 1.

## Limits

- Linux only. Kai runs on `x86_64-linux` and `aarch64-linux`, and generates
  shells and builds for the system it runs on.
- Services, machines, deploy, switch, rollback, generations, images, ISOs and
  secrets are not in this version, and the old `Kaifile` format is not read.
  If you need them, stay on
  [v0.0.7](https://github.com/thebrandonlucas/kai/releases/tag/v0.0.7)
  (`nix run github:thebrandonlucas/kai/v0.0.7`).

## Development

```sh
git clone https://github.com/thebrandonlucas/kai.git
cd kai
kai shell default -- zig build ci    # or `kai shell`, then `zig build ci`
```

`zig build ci` includes the end-to-end tests, which run a built kai against
real Nix and, when it is installed, Guix, so it needs network access or a warm
Nix cache. `zig build e2e -- --nix` or `-- --guix` runs them on one backend,
and `zig build e2e-run` (or `-build`, `-workflow`, `-update`, ...) runs one;
`zig build guix-integration` runs every Guix test and fails without Guix. If
the shell is missing a dependency, please open an issue.

To try a checkout's kai on another project, build it and the platform host
it links Kaifiles with:

```sh
kai build kai-x64musl --out-link /tmp/kai-dev    # kai at /tmp/kai-dev/kai
kai shell default -- sh -c 'cd platform && zig build --release'
```

`kai-arm64musl` is the aarch64 build. The project's Kaifile.roc then names
the checkout's platform and std by relative path, as `examples/` do, such as
`pf: platform "../kai/platform/main.roc"` and
`std: "../kai/plugins/std/main.roc"`: Roc refuses an absolute platform path.

The code follows the pipeline:

- `platform`: Kai's plugin platform, the Roc platform `Kaifile.roc` builds
  on and the API every plugin uses: commands, backends, implementations,
  plans and the protocol kai speaks. It validates the Kaifile's plugins at
  compile time.
- `plugins/std`: the std plugin. It lowers its settings to its project model
  at compile time.
  - `plugins/std/model`: std's project model and its validation.
  - `plugins/std/backends/nix`, `plugins/std/backends/guix`: std's pure
    backends that plan files and argv from the model.
- `cli`: `kai` itself. It asks the compiled Kaifile for the command's
  candidate plans, chooses a backend, checks the plan and runs it.
- `devtool`: checks, integration tests and release tooling; see
  [devtool/README.md](devtool/README.md) and [RELEASE.md](docs/RELEASE.md).

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

If you would like to contribute, I would love for you to open an issue!

### Looking Ahead

Aside from making a great tool for programmers to encourage the use of determinate computing, the hope is to go far beyond that and [dream](https://www.amazon.com/Dream-Machine-M-Mitchell-Waldrop/dp/1732265119) about what computers could be. I believe determinate computing is in its nascent form, and the true realization of its potential could have monumental and lasting effects as a new, better way to use computers.

### Attribution

Huge thank you to Luke Boswell for inspiring the initial portable typed configuration idea with [roc-blueprint](https://github.com/lukewilliamboswell/roc-blueprint) and his enthusiastic evangelism of this idea. Kai's plugin platform (`platform/`), std's model (`plugins/std/model/`) and its Nix backend (`plugins/std/backends/nix/`) began as roc-blueprint's code (see [LICENSE](LICENSE)).

Also thank you to the longstanding efforts of the Nix and Guix developers without which this would be impossible, the [Roc](https://roc-lang.org/) team for their encouragement and making a great language to build in, and the [caddy](https://caddyserver.com/) devs from which this project takes heavy inspiration.

The banner shows Thomas Cole's *The Course of Empire: The Arcadian or Pastoral State* (1834), public domain, from [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Cole_Thomas_The_Course_of_Empire_The_Arcadian_or_Pastoral_State_1836.jpg).
