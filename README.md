# kai Roc platform

Minimal Roc platform for Kai protocol experiments.

Roc apps emit one portable protocol command: `shell`.

```roc
Kai.shell!({ target: "./fixtures/shell", command: ["sh", "-c", "printf ok"] })
Kai.shellWithAdapter!({ adapter: "./zig-out/bin/kai-adapter-nix", target: "./fixtures/shell", command: ["sh", "-c", "printf ok"] })
```

Architecture:

1. Top-level Roc app calls `kai.Kai.shell!` or `shellWithAdapter!`.
2. The generic Zig host sends a structured request to a backend adapter executable.
3. The backend adapter is a small Roc program using `kai.Adapter`.
4. The adapter lowers the portable `shell` request to normalized argv.
5. The Zig host parses that argv plan and executes it directly, with no shell interpolation.

The host does not contain Nix/Guix lowering logic. Adding a backend means adding a Roc adapter, not editing `src/host.zig`.

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

- Only command `shell` is defined.
- `argv` is a structured argument array. Do not return shell-interpolated command strings.
- Argument lengths are UTF-8 byte counts. Newlines inside args are allowed because the host consumes exact byte lengths plus the trailing newline emitted by the Roc adapter.
- Non-zero adapter exit means adapter failure.
- `Kai.shellWithAdapter!` selects an explicit adapter. `Kai.shell!` uses `KAI_BACKEND_ADAPTER`; if it is unset, the host returns `MissingBackendAdapter`.

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

- `adapters/roc/nix.roc`: `shell -> nix develop --no-write-lock-file <target> --command <argv...>`
- `adapters/roc/guix.roc`: `shell -> guix shell [-m manifest.scm|target] -- <argv...>`

They depend only on this local Kai platform; no remote packages like `basic-cli` or `roc-json` are used.

## Run

Fast Zig tests:

```sh
zig build test
```

Build host library and Roc adapters:

```sh
zig build
```

Build only Roc adapters:

```sh
zig build roc-adapters
```

Opt-in real subprocess proof (requires Roc plus nix/guix, and Nix flakes enabled):

```sh
zig build e2e
```

The e2e fixtures live in `fixtures/shell/`:

- `flake.nix` provides a Nix dev shell containing `guix`.
- `manifest.scm` provides a Guix shell containing `hello` and `bash-minimal`.
