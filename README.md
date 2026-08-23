# Kai - A friendly frontend for determinate computing

Kai is a CLI that makes using reproducible systems powerful, friendly, and fun.

> WARNING: Hobby project. Use at your own risk!

## Overview

There are basically two complete reproducible systems today: [Nix](https://determinate.systems/) and [Guix](https://guix.gnu.org/). The general consensus appears to be that the ideas are beautiful, the implementations are not. Real-world software adoption has shown that when forced to choose between beauty and short-term utility over ugly long-term stability, the former tends to beat the latter, and the [future pays the price]().

Kai recognizes this and aims to build on top of these systems to make them easy, extensible, customizable, and powerful.

The goal is to make reproducible computing so easy and powerful that they become the de-facto choice for software environments and deployment in all their forms: from desktops and servers to TVs and toasters. Practically, this means adopting Nix under the hood and creating useful abstractions on top in the short term.

Read [here]() for more.

### Installation

The easiest install is via:

```sh
curl https://kai.com/install.sh
```

Or on [Nix]():
```sh
# Try it out from the latest `master` branch without manually installing
nix run github:thebrandonlucas/kai -- version

# Add it to a shell
nix shell kai
```

Or on [Guix]():
```sh
guix shell kai
```

Or direct download [latest release]().

### Build locally

```sh
git clone https://github.com/thebrandonlucas/kai.git
cd kai
nix develop # or direnv allow
zig build ci
```

## Design

> Simple things should be simple, complex things should be possible

- [Alan Kay](https://www.quora.com/What-is-the-story-behind-Alan-Kay-s-adage-Simple-things-should-be-simple-complex-things-should-be-possible)

The design is heavily inspired by [`caddy`](https://caddyserver.com/). `caddy`'s [architecture](https://caddyserver.com/docs/architecture) allows users to write plugins to extend behavior, but the core library comes with everything most users would want, and the default behavior ships with features that beat out any other web server I've used.

It is a masterclass in tool design.

Thus Kai uses a similar architecture. The stock `kai` binary includes `StdPlugin`, which reads `Kaifile` and provides the default commands and Nix backend. For example:

```kai
on linux {
  shell {
    packages: ["cowsay", "fortune"]
  }
}
```

See the [plugin documentation](docs/plugin.md) for the plugin contract and `xkai` build details.

## Platform support

I've only tested this on `x86_64-linux` so far, feel free to open an issue if it doesn't build on your system. In theory, it should work on arm64, x64, across Linux and MacOS.

## Development

Other than `nix develop` anytime you want a shell or `direnv allow` once, we have:

   ### Development Commands

   | Task | Command |
   |---|---|
   | Format Roc, Zig, and Nix files | `zig build fmt` |
   | Run static and formatting checks | `zig build check` |
   | Run tests | `zig build test` |
   | Run complete source CI locally | `zig build ci` |
   | Build and validate release artifacts | `zig build build-release` |
   | Prepare a protected release pull request | `zig build release -- "Kai X.Y.Z" X.Y.Z` |
   | Run Kai through Nix | `nix run . -- version` |
   | Run xkai through Nix | `nix run .#xkai -- version` |


## Build Artifacts

Build outputs include:

- `zig-out/ci/*`: development/CI executables discovered from Roc app roots
- `result/bin/kai`: stock Kai, Nix-wrapped with `nix` on `PATH`
- `result/bin/xkai`: the plugin builder, Nix-wrapped with Roc on `PATH`
- `kai-<version>-<system>.tar.gz`: portable Kai CLI release archive

The stock `kai` executable does not require Roc at runtime. Release archives contain the raw portable executable, so `nix` must already be available to use the standard shell backend. `xkai` requires Roc because it compiles the selected plugins into a new executable.

## Releases

Linux releases contain only the portable Kai CLI archives and their checksums:

```text
kai-<version>-x86_64-linux.tar.gz
kai-<version>-aarch64-linux.tar.gz
SHA256SUMS
```

Build them with `zig build build-release`. Maintainers prepare a protected release pull request with `zig build release -- "Kai X.Y.Z" X.Y.Z`; merging it publishes the release automatically. See [the release guide](docs/RELEASE.md) for metadata ownership and recovery.

## Goals

1. Great UX. The benefits and usage of Kai should be immediate and obvious.
2. Modularity:
    a. A great set of default features downstream of determinism: (rollbacks, dev shells, builds, garbage-collection, etc.)
    b. The ability to add/remove subcommands via a command module registry similar to [Caddy](https://caddyserver.com/).
    c. The ability to modify the default set of modules to fit user needs.
    d. To the degree possible, the ability to replace suboptimal pieces of the underlying system (i.e. encourage a "protocol" or modularity in determinate systems), as opposed to the current monolithic nature of Nix/Guix. See [snix]() for example.
3. Unlocking new use cases and ergonomics. Encouraging benefits that are overlooked or underutilized in current systems. Big examples would be easy desktop setups (or easily trying others' setups just to check them out!), easy, safe modification, easy backups etc. Simple examples include little ergonomic things like e.g. `kai shell keep` to add any temporary shell programs to your `flake.nix` permanently (or eventually to `configuration.nix`).

### Design Questions

Eventually, we want our blueprint protocol to support the following universal things at least:

1. Shells (ad-hoc or persistent, locked (flakes) or unlocked (shell.nix))
2. Builds (for deployable machines & other targets)
3. Deployments (generic, yet extensible)
4. Rollbacks
5. Garbage Collection
6. Package Resolution (?)
7. More TBD.

### Contributing

If you would like to contribute, I would love for you to open an issue!

### Looking Ahead

Aside from making a great tool for programmers to encourage the use of determinate computing, the hope is to go far beyond that and [dream](https://www.amazon.com/Dream-Machine-M-Mitchell-Waldrop/dp/1732265119) about what computers could be. I believe determinate computing is in its nascent form, and the true realization of its potential could have monumental and lasting effects as a new, better way to use computers.

### Attribution
Huge thank you to Luke Boswell for inspiring the initial portable typed configuration idea with [roc-blueprint](https://github.com/lukewilliamboswell/roc-blueprint) and his enthusiastic evangelism of this idea.
