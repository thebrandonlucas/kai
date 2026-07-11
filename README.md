# kai Roc platform

Minimal Roc platform for Kai protocol experiments.

Roc apps can be written as a small modular config DSL with only the protocol command entries they use.

```roc
app [config] { kai: platform "./platform/config.roc" }

config = [
    Shell({
        environment: "./fixtures/shell",
        run: "zig version >/dev/null && printf kai-shell-ok",
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

Adapter choice is outside the Roc file:

```sh
./zig-out/bin/kai adapter set nix   # or guix
./zig-out/bin/kai shell             # defaults to kai.roc
./zig-out/bin/kai shell examples/shell.roc
```

Architecture:

1. `src/command_registry.zig` declares protocol commands separately from extra/non-protocol commands.
2. `src/backend.zig` selects exactly one active backend from `.kai-adapter` or `KAI_BACKEND_ADAPTER`.
3. `kai shell [config.roc]` dispatches protocol command `shell`.
4. `kai build [config.roc]` is a CLI alias for protocol command `machine.build`.
5. The selected implementation must target the active backend; otherwise Kai reports a backend mismatch or unsupported backend.
6. The backend adapter is a small Roc program using `kai.Adapter`; it lowers portable `shell` requests to normalized argv.
7. `machine.build` currently supports only backend `nix`: it writes `.kai/flake.nix`, prints the machine output attr, then runs `nix build path:.kai#packages.<system>.<hostname>-image`.

The shell protocol host does not contain Nix/Guix lowering logic. Adding a shell backend means adding a Roc adapter, not editing `src/host.zig`. Machine image builds are Nix-specific and follow the kai-zig `nix build path:.kai#...` flow.

## Adapter contract

Host calls:

```text
argv[0] = <adapter-executable>
argv[1] = kai.adapter.argv.v1
argv[2] = shell
argv[3] = <target>
argv[4..] = <command argv>
```

Adapter stdout must be a length-prefixed plan:

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

- Adapter executables currently handle protocol command `shell`.
- `argv` is a structured argument array. Do not return shell-interpolated command strings.
- Argument lengths are UTF-8 byte counts. Newlines inside args are allowed because the host consumes exact byte lengths plus the trailing newline emitted by the Roc adapter.
- Non-zero adapter exit means adapter failure.
- The config platform and `Kai.shell!` select adapters from `.kai-adapter`, then `KAI_BACKEND_ADAPTER`; if neither is set, the host returns `MissingBackendAdapter`.
- `Kai.shellWithAdapter!` selects an explicit adapter executable path, built-in name (`nix` or `guix`), or PATH name.

## Roc backend DSL

`platform/Adapter.roc` provides only the generic adapter contract and executable helper. Backend-specific lowering belongs in adapter files under `adapters/roc/` or in a third-party Roc adapter:

```roc
app [main!] { kai: platform "../../platform/main.roc" }

import kai.Adapter

main! : List(Str) => I32
main! = |args| Adapter.main!(args, |req|
    List.concat(["tool", "shell", req.target, "--"], req.argv)
)
```

Included Roc adapters:

- `adapters/roc/nix.roc`: `shell -> nix develop --no-write-lock-file <environment> --command <argv...>`
- `adapters/roc/guix.roc`: `shell -> guix shell -m <environment>/manifest.scm -- <argv...>` for directory environments, or `guix shell -m <environment> --` when the environment already ends in `.scm`.

They depend only on this local Kai platform; no remote packages like `basic-cli` or `roc-json` are used.

## CLI

`zig build` installs a tiny dependency-free CLI at `zig-out/bin/kai` alongside the Roc adapters.

```sh
zig build
./zig-out/bin/kai help
./zig-out/bin/kai adapter list
./zig-out/bin/kai adapter set nix     # or guix, or an adapter executable/path
./zig-out/bin/kai adapter get
./zig-out/bin/kai shell [config.roc]
./zig-out/bin/kai build [config.roc]
```

Commands:

- `kai help`: print usage.
- `kai adapter list`: show the current adapter and built adapters found next to `kai`.
- `kai adapter get`: print the selected adapter, or `none`.
- `kai adapter set <adapter>`: write `<adapter>` to the local `.kai-adapter` config file. Built-in names `nix` and `guix` resolve to sibling `kai-adapter-nix`/`kai-adapter-guix` executables when present.
- `kai shell [config.roc]`: dispatch protocol command `shell`; defaults to `kai.roc`.
- `kai build [config.roc]`: dispatch protocol command `machine.build`; defaults to `kai.roc`. This writes `.kai/flake.nix` and runs `nix build` for the configured image output when the active backend is `nix`.

Adapter selection order for both the CLI and Roc config apps is `.kai-adapter`, then `KAI_BACKEND_ADAPTER`. `Kai.shellWithAdapter!` can still override this in lower-level Roc code.

Examples:

```sh
./zig-out/bin/kai adapter set nix
./zig-out/bin/kai shell
./zig-out/bin/kai build

KAI_BACKEND_ADAPTER=./fixtures/adapters/static-plan ./zig-out/bin/kai shell examples/shell.roc
```

## Run

Fast Zig tests:

```sh
zig build test
```

Build host library, CLI, and Roc adapters:

```sh
zig build
```

Build only Roc adapters:

```sh
zig build roc-adapters
```

Run the generic config example through the CLI:

```sh
./zig-out/bin/kai adapter set nix   # or guix
./zig-out/bin/kai shell examples/shell.roc
```

Run the config app directly:

```sh
KAI_BACKEND_ADAPTER=./zig-out/bin/kai-adapter-nix roc examples/shell-nix.roc -- shell
KAI_BACKEND_ADAPTER=./zig-out/bin/kai-adapter-nix roc examples/shell-nix.roc -- build
```

Opt-in real subprocess proof (requires Roc plus nix/guix, and Nix flakes enabled):

```sh
zig build e2e
```

The e2e fixtures live in `fixtures/shell/`:

- `flake.nix` provides a Nix dev shell containing `zig`.
- `manifest.scm` provides a Guix shell containing `zig` and `bash-minimal`.
