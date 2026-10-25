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
strings, multiline ones included, `${name}` is Roc interpolation, so a script
writes `$NAME`, or `\${NAME}` where the shell needs braces. Every command has
help with examples, e.g. `kai run --help`; inside a project, help lists its
shells, tasks, builds and workflows.

### Settings

| Setting | Purpose |
| --- | --- |
| `Name(name)` | Project name. Required. |
| `Systems([...])` | Systems the generated flake declares. Optional (default `x86_64-linux` and `aarch64-linux`); must include the system of the host Kai runs on. |
| `Packages(name, source)` | A package source: `Auto`, `From(NixPackages(flakeRef))` or `From(GuixPackages(...))`. Tools use the `default` source (`Auto`: nixpkgs unstable on Nix, the installed channels on Guix) unless written `"source#tool"`. |
| `Overlay(name, flakeRef)` | A Nix overlay, applied only where an environment selects it. |
| `Environment(name, [...])` | A set of tools: `Tools([...])`, `Overlays([...])` in order, and `Extend(parent)` to inherit the parent's tools and overlays first. |
| `Shell(name, [Use(environment)])` | A shell for `kai shell`. |
| `Task(name, [Use(environment), Run(argv)])` | A task for `kai run`. |
| `Source(name, flakeRef)` | A locked, non-flake source that builds can read. |
| `Build(name, [...])` | A sandboxed Nix build of a project snapshot: `Use(environment)`, `Run(argv)`, a relative `Output(path)`, and optionally `Inputs([...])` (sources, in `$KAI_INPUTS/<name>`) and `Needs([...])` (other builds, in `$KAI_ARTIFACTS/<name>`). |
| `Workflow(name, [...])` | Steps for `kai workflow`: `RunTask(task, args)`, `BuildArtifact(build)`, `RunWorkflow(workflow)`. |
| `Raw("nix", target, value)` | Extra attributes for the generated flake (`"flake"`) or one shell (`"shell:<name>"`), e.g. `Attrs([("shellHook", Str("echo hi"))])`. |

Names and references are checked as the file compiles, so `kai check` reports
mistakes before anything runs. [examples](examples/) has a small project for
each setting and command, from a first shell to builds, workflows and Guix.

### Tasks and builds

Shells and tasks run on your machine, in the project directory, inside the
environment's shell: they see your files, your network and anything else you
can reach, and what they write stays in the working tree.

Builds run sandboxed. A build gets a copy of the project, leaving out what
its `.gitignore` files ignore (`Files([...])` narrows the copy to the given
project-relative paths), plus only the tools its environment's shell has, its
declared sources (`$KAI_INPUTS`) and the artifacts of the builds it needs
(`$KAI_ARTIFACTS`). It has no network, and only its `Output` is kept, in the
store. A Nix build's sources that are Roc package bundles, such as
`tarball+https://…/<hash>.tar.zst`, are in its Roc package cache, so Roc
resolves those package URLs offline. The sandbox has no `/usr/bin/env`, so
run scripts as `sh script` or through an interpreter's path rather than
relying on a `#!/usr/bin/env` line.

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
shell -q --pure` with the environment's tools, at the Guix channel commit
Kai's lock pins. `kai build` runs `guix build -f` on a generated file whose
derivation runs the same sandboxed build runner as on Nix, and `kai workflow`
runs tasks and builds in order. `kai update` pins every installed backend that
fits, each in its own section of `.kai/lock.json` (`kai --backend guix update`
pins only Guix), and Guix commands refuse to run without a Guix pin. The first
Guix command at a new commit downloads, or builds, that Guix, which can take a
long time. Overlays and build inputs (`Inputs([...])`) other than `path:`
sources need Nix. See
[examples/guix](examples/guix).

## The `.kai` directory

`kai update` is the only command that resolves package sources. It writes
`.kai/lock.json`. `kai shell`, `run`, `build` and `workflow` only read it, and
ask you to run `kai update` when it is missing or a locked local source has
changed. Commit the lock; the rest of `.kai` is generated:

```gitignore
/.kai/*
!/.kai/lock.json
```

`KAI_DIR=<name>` moves the whole directory to another top-level name in the
project.

## Options

- `-f`, `--file PATH`: use another configuration file. Its directory is the
  project root.
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
