# Kai - A friendly frontend for determinate computing

[![Join the Kai Discord](https://img.shields.io/badge/Discord-Join%20the%20community-5865F2?logo=discord&logoColor=white)](https://discord.gg/pnANfSe4V)

> WARNING: Hobby project under rapid development. Use at your own risk!

Kai is a CLI that makes using determinate systems easy, friendly, and fun.

Imagine everything about how your computer works is a portable config in one file you can just send to your friends or bring with you to a new computer. Spend very little time thinking about installing software, dependencies, developer environments, etc., and once you figure it out once, you _shouldn't have to figure it out again_. We have that, with [Nix](https://determinate.systems/)! The problem is Nix is so hard to learn and use that people often give up (even agents get confused!). This is a complete paradigm shift in how we interact with software! But if no one uses it, what's the point?

To attempt a solution, `kai` wraps `nix` in a friendly frontend so that you can actually use it with confidence.

`kai` can already enter shells with the other determinate system, [Guix](https://guix.gnu.org/), and plans to support more of it. If we're lucky, maybe it will even get a custom implementation which learns from the mistakes of the others :eyes:

The goal is to make using determinate systems so easy and powerful that they become the de-facto choice for computer use in all its forms: from desktops to servers and beyond. Practically, this means adopting Nix under the hood and creating useful abstractions on top in the short term, like [jujutsu](https://github.com/jj-vcs/jj) does with `git`.

A personal motivation is to stimulate not just Linux adoption but _determinate_ computing adoption by eventually creating a custom NixOS-based competitor to [Omarchy](https://omarchy.org).

## Installation

Kai runs on Linux and needs
[Nix with flakes enabled](https://docs.determinate.systems/?phid=019ef5f5-e228-7eb4-9a1e-4dbe9b75b79e).

One immediate benefit of a determinate system is you can do things like this!

```sh
nix run github:thebrandonlucas/kai -- --version
nix shell github:thebrandonlucas/kai    # kai on PATH in a new shell
```

The Nix package includes the Roc compiler Kai uses to evaluate `Kaifile.roc`
and pre-seeds Roc's package cache with the matching Kaifile platform.

Release archives contain only the `kai` binary. To use one, also install Nix
and the Roc compiler named in [`.roc-version`](.roc-version) (available from
[roc-overlay](https://github.com/roc-lang/roc-overlay)), either on `PATH` or
set as `ROC=/path/to/roc`. Roc downloads the platform the first time it checks
a `Kaifile.roc`.

## Getting started

A project is configured by `Kaifile.roc`, an ordinary
[Roc](https://roc-lang.org/) app on the Kaifile platform. Its `config` is a
list of settings:

```roc
app [config] {
	pf: platform "https://github.com/thebrandonlucas/kai/releases/download/v0.0.8/8eM3r3RE4n1BFSWqD7wvqch5UW3ACJ7LLJiiin5nxJdK.tar.zst",
}

config = [
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
]
```

`kai --help` prints the platform header for the installed version. Then:

```sh
kai check                         # compile and validate Kaifile.roc
kai update                        # pin package sources in .kai/lock.json
kai shell                         # enter the default shell
kai shell default -- cowsay hi    # or run one command in it
kai run hello                     # run a task
kai run hello -- again            # arguments after -- are appended
kai build greeting                # sandboxed build; prints the store path
kai workflow ci                   # run steps in order, stop at a failure
```

Tool names are the backend's own package names: Nix attributes such as
`python3`, or Guix specifications. Tasks run their argv exactly, without a
shell, so use `Run(["sh", "-c", "..."])` for pipes. Every command has help with
examples, e.g. `kai run --help`; inside a project, help lists its shells,
tasks, builds and workflows.

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
mistakes before anything runs. See [examples](examples/) for overlays, sources
and builds, and Guix.

### Reusing configuration

Reuse is ordinary Roc: a module returns settings and `Kaifile.roc` imports it.
Shortened from [examples/composition](examples/composition):

```roc
# ProjectTasks.roc
import pf.Config
import pf.EnvName

ProjectTasks :: [].{
	settings : EnvName -> List(Config.Setting)
	settings = |environment| [
		Task("test", [Use(environment), Run(["git", "--version"])]),
	]
}
```

```roc
# Kaifile.roc, after the app header
import ProjectTasks

config = [
	Name("composed"),
	Environment("dev", [Tools(["git"])]),
	Shell("default", [Use("dev")]),
].concat(ProjectTasks.settings("dev"))
```

A module can only add settings; new commands or backends need changes to Kai
itself.

## Backends

Kai picks a backend for each command. Nix is preferred when it is installed and
can serve the request. Guix is used when Nix is not installed, or when the
environment's tools come from a `GuixPackages` source. `--backend nix` or
`--backend guix` forces one; Kai never falls back to the other.

Guix supports only `kai shell`, which runs `guix shell --pure` with the
environment's tools. Guix shells use the installed channels and are not pinned
by Kai's lock, so `kai update` refuses a Guix-only project. Overlays, tasks,
builds and workflows need Nix. See [examples/guix](examples/guix).

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
nix develop    # or `direnv allow` once
zig build ci
```

`zig build ci` includes real Nix integration runs, so it needs network access
or a warm Nix cache. `zig build guix-integration` runs a Guix shell with real
Guix and fails without it. If `nix develop` is missing a dependency, please
open an issue.

The code follows the pipeline:

- `kaifile/platform`: the Roc platform `Kaifile.roc` builds on. It lowers
  `config` to the Kaifile IR at compile time.
- `kaifile/ir`: the IR, its validation, and plan types.
- `kaifile/nix`, `kaifile/guix`: pure backends that turn IR into files and
  argv.
- `cli`: `kai` itself. It loads the IR, selects a backend and runs the plan.
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

Huge thank you to Luke Boswell for inspiring the initial portable typed configuration idea with [roc-blueprint](https://github.com/lukewilliamboswell/roc-blueprint) and his enthusiastic evangelism of this idea. The Kaifile platform, IR and Nix backend in `kaifile/` began as roc-blueprint's code (see [LICENSE](LICENSE)).

Also thank you to the longstanding efforts of the Nix and Guix developers without which this would be impossible, the [Roc](https://roc-lang.org/) team for their encouragement and making a great language to build in, and the [caddy](https://caddyserver.com/) devs from which this project takes heavy inspiration.
