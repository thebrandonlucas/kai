# Kai - A friendly frontend for determinate computing

> WARNING: Hobby project. Not intended for serious or commercial use at this time. Use at your own risk.

Kai is a CLI for making determinate systems (mainly [Nix]()) easy to use.

The goal is to make determinate systems so easy and powerful to use they become the de-facto choice. Practically, this means adopting Nix under the hood and creating useful abstractions in the shorter term.

Broken down, the goals are:

1. Great UX. The benefits and usage of Kai should be immediate and obvious.
2. Modularity:
    a. A great set of default features downstream of determinism: (rollbacks, dev shells, )
    b. The ability to add/remove subcommands via a command module registry similar to [Caddy]().
    c. The ability to modify the default set of modules to fit user needs.
    d. To the degree possible, the ability to replace suboptimal pieces of the underlying system (i.e. encourage a "protocol" or modularity in determinate systems), as opposed to the current monolithic nature of Nix/Guix. See [snix]() for example.
3. Unlocking new use cases and ergonomics. Encouraging benefits that are overlooked or underutilized in current systems.

### Design Questions

Eventually, we want our blueprint protocol to support the following universal things at least:

1. Shells (ad-hoc or persistent, locked (flakes) or unlocked (shell.nix))
2. Builds (for deployable machines & other targets)
3. Deployments (generic, yet extensible)
4. Rollbacks
5. Garbage Collection
6. Package Resolution (?)
7. etc.

### Looking Ahead

Aside from making a great tool for programmers to encourage the use of determinate computing, the hope is to go far beyond that and [dream](https://www.amazon.com/Dream-Machine-M-Mitchell-Waldrop/dp/1732265119) about what computers could be.
