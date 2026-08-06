# Kai - A friendly frontend for determinate computing

> WARNING: Hobby project. Use at your own risk!

Kai is a CLI that makes using reproducible systems easy, friendly, and fun.

There are basically two complete reproducible systems today: [Nix](https://determinate.systems/) and [Guix](https://guix.gnu.org/). They are hard to use. Kai builds on top of them with the goal of making them easy, extensible, customizable, and powerful.

The goal is to make using these so easy and powerful that they become the de-facto choice for computer use in all its forms: from desktops to servers to fridges and toasters. Practically, this means adopting Nix under the hood and creating useful abstractions on top in the short term.

### Installation

### Prerequisites

1. [Nix with flakes enabled](https://docs.determinate.systems/?phid=019ef5f5-e228-7eb4-9a1e-4dbe9b75b79e)

That should be it! Then run `nix develop` (or `direnv allow` once, if using direnv) and you should be all set. If that doesn't work, please open an issue for me to add the missing dependency to `flake.nix` and I will.

When Kai becomes self-hosted, that will change to just be `kai` :)

### Run without installing

One immediate benefit of a determinate system is you can do things like this!

```sh
nix run github:thebrandonlucas/kai -- version
```

### Build locally

```sh 
git clone https://github.com/thebrandonlucas/kai.git
cd kai 
nix build .#kai 
./result/bin/kai help
```

## Design

> Simple things should be simple, complex things should be possible

- [Alan Kay](https://www.quora.com/What-is-the-story-behind-Alan-Kay-s-adage-Simple-things-should-be-simple-complex-things-should-be-possible)

The design is heavily inspired by [`caddy`](https://caddyserver.com/). `caddy`'s [architecture](https://caddyserver.com/docs/architecture) allows users to write plugins to extend behavior, but the core library comes with everything most users would want, and the default behavior ships with features that beat out any other web server I've used.

It is a masterclass in tool design.

Thus Kai uses a similar architecture. The stock `kai` binary includes `StdPlugin`, which reads `config.kai` and provides the default commands and Nix backend. For example:

```kai
on linux {
  shell {
    pkgs: ["cowsay", "fortune"]
  }
}
```

`StdPlugin` and custom plugins implement the same contract: each exports a plugin module that turns the configuration source, command arguments, and host platform into a pure action plan. The shared executor performs that plan's file writes and backend commands.

`xkai` is the plugin builder, similar to `xcaddy`. Pass it custom Roc plugin modules to add commands or override standard behavior:

```sh
xkai build path/to/CustomPlugin.roc
```

For the build only, `xkai` writes its embedded API, executor, standard plugin, and supplied custom plugins to a temporary directory and invokes Roc. `basic-cli` is the compile-time Roc platform for both stock and customized binaries. The result is a portable `kai` binary with that registry compiled in; the temporary build inputs are removed. At runtime, `kai` reads `config.kai`. The `.kai/` directory contains backend output such as `.kai/flake.nix`, never Roc source or plugin build inputs.

## Platform support

I've only tested this on `x86_64-linux` so far, feel free to open an issue if it doesn't build on your system. In theory, it should work on arm64, x64, across Linux and MacOS.

## Development

Other than `nix develop` anytime you want a shell or `direnv allow` once, we have:

   ### Development Commands

   | Task | Command |
   |---|---|
   | Format Roc, Zig, and shell files | `zig build fmt` |
   | Format Nix files | `nix fmt flake.nix` |
   | Run static and formatting checks | `zig build check` |
   | Check Nix formatting | `nix fmt -- --check flake.nix` |
   | Run tests | `zig build test` |
   | Run complete source CI locally | `zig build ci` |
   | Check the native Nix package | `nix flake check` |
   | Build the native Kai package | `nix build .#kai` |
   | Build the native xkai package | `nix build .#xkai` |
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
