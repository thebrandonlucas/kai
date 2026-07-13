# kai Roc platform

Minimal Roc platform for Kai protocol experiments.

Roc apps can be written as a small modular config DSL with only the protocol command entries they use.

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
3. `kai shell [config.roc]` dispatches protocol command `shell`; on first run or config changes it writes generated blueprint state under `.kai/` and tells the user.
4. `kai build [config.roc]` is a CLI alias for protocol command `machine.build`.
5. The selected implementation must target the active blueprint; otherwise Kai reports a blueprint mismatch or unsupported blueprint.
6. A blueprint executable is a small Roc program using `kai.Blueprint`; it lowers portable `shell` requests to normalized argv.
7. `machine.build` currently supports only blueprint `nix`: it writes `.kai/machine/flake.nix`, prints the machine output attr, then runs `nix build path:.kai/machine#packages.<system>.<hostname>-image`.

For config-driven shell commands, Kai generates blueprint state under `.kai/shell/` (`flake.nix` for nix, `manifest.scm` for guix) from the shell package list, then passes that generated target to the blueprint executable. Subsequent runs reuse the generated file unless the rendered content changes. Machine image builds are Nix-specific and follow the kai-zig `nix build path:.kai/machine#...` flow.

## Blueprint wire contract

The wire protocol strings intentionally keep the historical `kai.adapter.*` names for compatibility.

Host calls:

```text
argv[0] = <blueprint-executable>
argv[1] = kai.adapter.argv.v1
argv[2] = shell
argv[3] = <target>
argv[4..] = <command argv, possibly empty>
```

Blueprint stdout must be a length-prefixed plan:

```text
kai.adapter.plan.v1\n
<count>\n
<len0>\n
<arg0 bytes>\n
<len1>\n
<arg1 bytes>\n
...
```

Rules:

- Blueprint executables currently handle protocol command `shell`.
- Empty command argv means enter the blueprint-native interactive shell; non-empty command argv means run that argv inside the blueprint environment.
- `argv` is a structured argument array. Do not return shell-interpolated command strings.
- Argument lengths are UTF-8 byte counts. Newlines inside args are allowed because the host consumes exact byte lengths plus the trailing newline emitted by the Roc helper.
- Non-zero blueprint exit means blueprint failure.
- The config platform and `Kai.shell!` select the active blueprint from `.kai/blueprint`, legacy `.kai/backend`, legacy `.kai/adapter`, `KAI_BLUEPRINT`, then legacy `KAI_BACKEND_ADAPTER`; if none is set, the host returns `MissingBlueprint`.
- `Kai.shellWithBlueprint!` selects an explicit blueprint executable path, built-in name (`nix` or `guix`), or PATH name.
- `Kai.shellWithAdapter!` and `kai.Adapter` remain as legacy aliases for third-party Roc code.

## Roc blueprint DSL

`platform/Blueprint.roc` provides only the generic blueprint contract and executable helper. Blueprint-specific lowering belongs in files under `blueprints/roc/` or in a third-party Roc blueprint:

```roc
app [main!] { kai: platform "../../platform/main.roc" }

import kai.Blueprint

main! : List(Str) => I32
main! = |args| Blueprint.main!(args, |req| {
    prefix = ["tool", "shell", req.target]

    if List.len(req.argv) == 0 {
        prefix
    } else {
        List.concat(List.concat(prefix, ["--"]), req.argv)
    }
})
```

Included Roc blueprints:

- `blueprints/roc/nix.roc`: empty argv lowers to `nix develop --no-write-lock-file <target>` for native interactive shell behavior; non-empty argv lowers to `nix develop --no-write-lock-file <target> --command <argv...>`. Config shells use generated target `path:.kai/shell`.
- `blueprints/roc/guix.roc`: empty argv lowers to `guix shell -m <target>/manifest.scm` for directory targets, or `guix shell -m <target>` when the target already ends in `.scm`; non-empty argv appends `-- <argv...>`. Config shells use generated target `.kai/shell`.

They depend only on this local Kai platform; no remote packages like `basic-cli` or `roc-json` are used.

## CLI

`zig build` installs a tiny dependency-free CLI at `zig-out/bin/kai` alongside the Roc blueprints.

```sh
zig build
./zig-out/bin/kai help
./zig-out/bin/kai blueprint list
./zig-out/bin/kai blueprint set nix     # or guix, or a blueprint executable/path
./zig-out/bin/kai blueprint get
./zig-out/bin/kai shell [config.roc]
./zig-out/bin/kai build [config.roc]
./zig-out/bin/kai zen
```

Commands:

- `kai help`: print usage.
- `kai blueprint list`: show the current blueprint and built blueprint executables found next to `kai`.
- `kai blueprint get`: print the selected blueprint setting, or `none`.
- `kai blueprint set <blueprint-or-executable>`: write `<blueprint-or-executable>` to the local `.kai/blueprint` config file. Built-in names `nix` and `guix` resolve to sibling `kai-blueprint-nix`/`kai-blueprint-guix` executables when present, with `kai-adapter-nix`/`kai-adapter-guix` accepted as legacy binary names.
- `kai backend ...` and `kai adapter ...`: legacy aliases for `kai blueprint ...`.
- `kai shell [config.roc]`: dispatch protocol command `shell`; defaults to `kai.roc`. Generates `.kai/shell/flake.nix` for nix or `.kai/shell/manifest.scm` for guix on first run or when content changes.
- `kai build [config.roc]`: dispatch protocol command `machine.build`; defaults to `kai.roc`. This writes `.kai/machine/flake.nix` and runs `nix build path:.kai/machine#...` for the configured image output when the active blueprint is `nix`.
- `kai zen`: print kai zen.

Blueprint selection order for both the CLI and Roc config apps is `.kai/blueprint`, legacy `.kai/backend`, legacy `.kai/adapter`, `KAI_BLUEPRINT`, then legacy `KAI_BACKEND_ADAPTER`. `Kai.shellWithBlueprint!` can override this in lower-level Roc code.

Examples:

```sh
./zig-out/bin/kai blueprint set nix
./zig-out/bin/kai shell
./zig-out/bin/kai build

KAI_BLUEPRINT=./fixtures/adapters/static-plan ./zig-out/bin/kai shell examples/shell.roc
KAI_BACKEND_ADAPTER=./fixtures/adapters/static-plan ./zig-out/bin/kai shell examples/shell.roc  # legacy
```

## Run

Fast Zig tests:

```sh
zig build test
```

Build host library, CLI, and Roc blueprints:

```sh
zig build
```

Build only Roc blueprints:

```sh
zig build roc-blueprints
zig build roc-adapters  # legacy alias
```

Run the generic config example through the CLI:

```sh
./zig-out/bin/kai blueprint set nix   # or guix
./zig-out/bin/kai shell examples/shell.roc
```

Run the config app directly:

```sh
KAI_BLUEPRINT=./zig-out/bin/kai-blueprint-nix roc examples/shell.roc -- shell
KAI_BLUEPRINT=./zig-out/bin/kai-blueprint-nix roc examples/shell.roc -- build
```

Opt-in real subprocess proof (requires Roc plus nix/guix, and Nix flakes enabled):

```sh
zig build e2e
```

The shell unit fixtures live in `fixtures/shell/` and are not referenced by user configs:

- `flake.nix` provides a Nix dev shell containing `zig`.
- `manifest.scm` provides a Guix shell containing `zig` and `bash-minimal`.
