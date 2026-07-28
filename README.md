# Kai - A friendly frontend for determinate computing

> WARNING: Hobby project. Not intended for serious or commercial use at this time. Use at your own risk.

Kai is a CLI for making determinate systems (mainly [Nix]()) easy to use.

The goal is to make determinate systems so easy and powerful to use they become the de-facto choice. Practically, this means adopting Nix under the hood and creating useful abstractions in the shorter term.

### Installation

### Prerequisites

1. [Nix with flakes enabled](https://docs.determinate.systems/?phid=019ef5f5-e228-7eb4-9a1e-4dbe9b75b79e)

That should be it! Then run `nix develop` (or `direnv allow` once, if using direnv) and you should be all set. If that doesn't work, please open an issue for me to add the missing dependency to `flake.nix` and I will.

When Kai becomes self-hosted, that will change to just be `kai` :)

### Run without installing

```sh
nix run github:thebrandonlucas/kai -- version
```

### Build locally

```sh 
git clone https://github.com/thebrandonlucas/kai.git
cd kai 
nix build .#kai 
./result/bin/kai version
```

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
   | Build the native Nix package | `nix build .#kai` |
   | Run Kai through Nix | `nix run . -- version` |
   | Build all platform host libraries | `zig build hosts -Doptimize=ReleaseSafe` |
   | Build the platform bundle | `nix build .#platform-bundle` |


## Build Artifacts

There are three ways to build via the flake:

- `zig-out/bin/kai`: development/CI executable
- `result/bin/kai`: Nix-wrapped with runtime tools (e.g. `roc` and others) on `PATH`
- `kai-<version>-<system>.tar.gz`: release archive

The release archive contains the raw executable, but careful! Kai currently doesn't bundle the `nix` or `roc` runtime dependencies. In the future I hope to build these in.

## Releases

Linux releases have:

```sh
# kai platform bundle
<HASH>.tar.zst
# cli's
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

### Looking Ahead

Aside from making a great tool for programmers to encourage the use of determinate computing, the hope is to go far beyond that and [dream](https://www.amazon.com/Dream-Machine-M-Mitchell-Waldrop/dp/1732265119) about what computers could be. I believe determinate computing is in its nascent form, and the true realization of its potential could have monumental and lasting effects as a new, better way to use computers.
