# Kai

Minimal Roc platform and CLI for `roc-blueprint` shell projects.

User-authored `kai.roc` files are portable Blueprint data only. Kai generates wrapper code under `.kai/`, renders Nix source, writes `.kai/shell/flake.nix`, then runs `nix develop --no-write-lock-file path:.kai/shell#default`.

```roc
package [workspace] {
    blueprint: "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint/HmTRQhvSpRQsj78WCR7j5y3anhqMVB4zuMejydrdAGeV.tar.zst",
}

import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target

hello = Requirement.new({ id: "hello", display_name: "Hello" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace({
    name: "hello-shell",
    target_systems: [Target.X86_64Linux],
    envs: [Environment.new({ name: "default", requirements: [hello] })],
})
```

```sh
zig build
./zig-out/bin/kai shell
```

On first shell render Kai also writes editable default bindings to `.kai/nix.roc`. The default convention maps each requirement id to the same `nixpkgs` attribute path, e.g. requirement `zig` becomes `pkgs.zig`.

## Architecture

1. User config is a `package [workspace]` that imports external `roc-blueprint`.
2. Kai does not vendor `roc-blueprint` or `roc-blueprint-nix` source.
3. `kai shell [kai.roc]` generates `.kai/render-nix.roc` and `.kai/nix.roc`.
4. The CLI renders Nix source with a roc-blueprint-compatible host renderer. Set `KAI_USE_ROC_BLUEPRINT_RENDERER=1` to run the generated `roc-blueprint-nix` wrapper when the Roc compiler supports it.
5. The CLI writes rendered source to `.kai/shell/flake.nix`.
6. The CLI runs `nix develop --no-write-lock-file path:.kai/shell#default`.

Kai intentionally has no machine-build path until `roc-blueprint` can model that capability.

## CLI

```sh
./zig-out/bin/kai help
./zig-out/bin/kai shell [kai.roc]
./zig-out/bin/kai shell init [directory]
./zig-out/bin/kai zen
```

Commands:

- `kai shell [kai.roc]`: render a clean Blueprint package, write `.kai/shell/flake.nix`, and enter the generated Nix shell.
- `kai shell init [directory]`: create starter `kai.roc`, `.kai/nix.roc`, and `.kai/shell/`.
- `kai zen`: print kai zen.

## Examples

The examples mirror the `roc-blueprint` example set, but as package-style Kai inputs:

- `examples/hello-shell/main.roc`
- `examples/dev-shell/main.roc`
- `examples/dev-and-ci-workflow/main.roc`
- `examples/rust-tooling/main.roc`
- `examples/python-tooling/main.roc`
- `examples/node-tooling/main.roc`
- `examples/multi-platform-shell/main.roc`

Each example includes `flake.golden.nix` and `flake.lock` copied from the matching `roc-blueprint` example.

## Files managed by Kai

- `.kai/nix.roc`: editable Nix binding policy generated on first shell run.
- `.kai/render-nix.roc`: generated wrapper app; do not edit.
- `.kai/shell/flake.nix`: rendered Nix shell source; do not edit.

## Build and test

```sh
zig build test
zig build
```

Example:

```sh
./zig-out/bin/kai shell examples/hello-shell/main.roc
```
