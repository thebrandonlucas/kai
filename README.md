# kai Roc platform

Minimal Roc platform for Kai protocol experiments.

Roc apps emit one portable protocol command: `shell`.

```roc
Kai.shell!({ target: "./fixtures/shell", command: ["sh", "-c", "printf ok"] })
Kai.shellWithAdapter!({ adapter: "./zig-out/bin/kai-adapter-nix", target: "./fixtures/shell", command: ["sh", "-c", "printf ok"] })
```

The Zig host does not lower Nix or Guix itself. It serializes the shell request to a backend adapter executable, reads a normalized argv execution plan, and executes that argv directly.

## Adapter contract

Host calls:

```sh
<adapter-executable> '<request-json>'
```

Request JSON:

```json
{"protocol":"kai.adapter.v0","command":"shell","target":"./fixtures/shell","argv":["sh","-c","printf ok"]}
```

Adapter stdout must be plan JSON:

```json
{"protocol":"kai.adapter.v0","argv":["nix","develop","--no-write-lock-file","./fixtures/shell","--command","sh","-c","printf ok"]}
```

Rules:

- Only `command: "shell"` is defined.
- `argv` is a structured argument array. Do not return shell-interpolated command strings.
- Non-zero adapter exit means adapter failure.
- The host selects an explicit adapter from `Kai.shellWithAdapter!`; `Kai.shell!` uses `KAI_BACKEND_ADAPTER`, falling back to `kai-adapter-nix` on `PATH`.

## Included adapters

Built Zig adapters:

- `kai-adapter-nix`: `shell -> nix develop --no-write-lock-file <target> --command <argv...>`
- `kai-adapter-guix`: `shell -> guix shell [-m manifest.scm|target] -- <argv...>`

Roc source sketches live in `adapters/roc/`. They use basic-cli plus roc-json and are not built by the default Zig build yet. In this environment `roc check adapters/roc/nix.roc` reached package resolution but failed with `PACKAGE DOWNLOAD FAILED ... Error: DownloadFailed` for the remote basic-cli and roc-json packages.

## Run

Fast tests:

```sh
zig build test
```

Build host library and adapters:

```sh
zig build
```

Opt-in real subprocess proof (requires Roc plus nix/guix, and Nix flakes enabled):

```sh
zig build e2e
```

The e2e fixtures live in `fixtures/shell/`:

- `flake.nix` provides a Nix dev shell containing `guix`.
- `manifest.scm` provides a Guix shell containing `hello` and `bash-minimal`.

## Third-party backend adapter

Write any executable that accepts the request JSON as argv[1] and prints plan JSON to stdout. Then call it from Roc:

```roc
Kai.shellWithAdapter!({ adapter: "/path/to/my-kai-adapter", target: "my-target", command: ["tool", "--version"] })
```

No `host.zig` edit is required for a new backend.
