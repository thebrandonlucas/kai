# Kai - A friendly frontend for determinate computing

> WARNING: Hobby project under rapid development. Use at your own risk!

Kai is a CLI that makes using determinate systems easy, friendly, and fun.

Imagine everything about how your computer works is a portable config in one file you can just send to your friends or bring with you to a new computer. Spend very little time thinking about installing software, dependencies, developer environments, etc., and once you figure it out once, you _shouldn't have to figure it out again_. We have that, with [Nix](https://determinate.systems/)! The problem is Nix is so hard to learn and use that people often give up (even agents get confused!). This is a complete paradigm shift in how we interact with software! But if no one uses it, what's the point?

To attempt a solution, `kai` wraps `nix` in a friendly frontend so that you can actually use it with confidence.

Eventually `kai` plans to support the other determinate system, [Guix](https://guix.gnu.org/), and, if we're lucky, maybe even a custom implementation which learns from the mistakes of the others :eyes:

The goal is to make using determinate systems so easy and powerful that they become the de-facto choice for computer use in all its forms: from desktops to servers and beyond. Practically, this means adopting Nix under the hood and creating useful abstractions on top in the short term, like [jujutsu](https://github.com/jj-vcs/jj) does with `git`.

A personal motivation is to stimulate not just Linux adoption but _determinate_ computing adoption by eventually creating a custom NixOS-based competitor to [Omarchy](https://omarchy.org).

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
nix develop
zig build ci
```

## Design

> Simple things should be simple, complex things should be possible

- [Alan Kay](https://www.quora.com/What-is-the-story-behind-Alan-Kay-s-adage-Simple-things-should-be-simple-complex-things-should-be-possible)

The design is heavily inspired by [`caddy`](https://caddyserver.com/). `caddy`'s [architecture](https://caddyserver.com/docs/architecture) allows users to write plugins to extend behavior, but the core library comes with everything most users would want, and the default behavior ships with features that beat out any other web server I've used.

It is a masterclass in tool design.

Thus Kai uses a similar architecture. The standard `kai` binary includes `StdPlugin`, which reads `Kaifile` and provides the default commands and Nix backend. For example:

```kai
on linux {
  shell {
    packages: ["cowsay", "fortune"]
  }
}
```

See the [plugin documentation](docs/plugin.md) for the plugin contract and `xkai` build details.

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

Huge thank you to Luke Boswell for inspiring the initial portable typed configuration idea with [roc-blueprint](https://github.com/lukewilliamboswell/roc-blueprint) and his enthusiastic evangelism of this idea.

Also thank you to the longstanding efforts of the Nix and Guix developers without which this would be impossible, the [Roc](https://roc-lang.org/) team for their encouragement and making a great language to build in, and the [caddy](https://caddyserver.com/) devs from which this project takes heavy inspiration.
