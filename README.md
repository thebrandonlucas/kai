# Kai

## A friendly frontend for determinate computing

> NOTE: This is very much a prototype and work in progress. Expect bugs and do not use for anything other than toy projects at the moment.

`kai` is a prototype proof-of-concept CLI tool for using determinate systems like `nix`. It aims to make using reproducible software in your day-to-day life easy, fun, and powerful.


It is built on an Embedded DSL within the `roc` language that aims to be a generic protocol for determinate computing operations. The idea is to enumerate the most useful subset of operations provided by reproducible software in general, such as dev shells, build targets, rollbacks, garbage collection, etc. such that we may use any [_blueprint_](https://github.com/lukewilliamboswell/roc-blueprint) which uses the command. A blueprint in this case is a mapping between the generic protocol and a given implementation. Right now, there are essentially two implementations of determinate systems: `nix` (and the system `nixOS`) and `guix` (whose OS is called `guix system`). So the idea is that you could write your `kai.roc` generically and have it select which backend to use.

More on the design thinking and motivation [here](https://blu.cx/posts/articles/2026-07-13-kai-friendly-frontend/).

`kai` manages a `kai.roc` file which uses the EDSL. For now, this is just a sketch of two of many possible future commands:

```roc
app [config] { kai: platform "./platform/config.roc" }

config = [
    Shell({
        name: "kai",
        # `packages` is a Roc header keyword in this compiler, so shell configs use `pkgs`.
        pkgs: ["cargo"],
    }),
    MachineBuild({
        hostname: "kai-example",
        system: "x86_64-linux",
        install: ["git"],
        ssh_keys: [],
        state_version: "25.05",
        image: { format: "qcow2" },
    }),
]
```

Blueprint choice is outside the Roc file:

```sh
./zig-out/bin/kai blueprint set nix   # or guix
./zig-out/bin/kai shell               # defaults to kai.roc
./zig-out/bin/kai shell examples/shell.roc
```

Architecture:

1. `src/command_registry.zig` declares protocol commands separately from extra/non-protocol commands.
2. `src/blueprint.zig` selects exactly one active blueprint from `.kai/blueprint`, legacy `.kai/backend`, legacy `.kai/adapter`, `KAI_BLUEPRINT`, or legacy `KAI_BACKEND_ADAPTER`.
3. `kai shell [kai.roc]` dispatches protocol command `shell`; on first run or config changes it writes generated blueprint state under `.kai/` and tells the user.
4. `kai build [kai.roc]` is a CLI alias for protocol command `machine.build`.
5. The selected implementation must target the active blueprint; otherwise Kai reports a blueprint mismatch or unsupported blueprint.
6. A blueprint executable is a small Roc program using `kai.Blueprint`; it lowers portable `shell` requests to normalized argv.
7. `machine.build` currently supports only blueprint `nix`: it writes `.kai/machine/flake.nix`, prints the machine output attr, then runs `nix build path:.kai/machine#packages.<system>.<hostname>-image`.

For config-driven shell commands, Kai generates blueprint state under `.kai/shell/` (`flake.nix` for nix, `manifest.scm` for guix) from the shell package list, then passes that generated target to the blueprint executable. Subsequent runs reuse the generated file unless the rendered content changes. Machine image builds are Nix-specific and follow the kai-zig `nix build path:.kai/machine#...` flow.

