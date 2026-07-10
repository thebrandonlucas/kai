# kai Roc platform

Minimal Roc platform for Kai protocol experiments.

Roc code emits a backend-neutral protocol command (`shell`) with a target and a non-interactive command argv. The Zig host lowers and executes it:

- `nix` -> `nix develop --no-write-lock-file [target] --command <argv...>`
- `guix` -> `guix shell [-m manifest.scm|target] -- <argv...>`

Run fast unit tests:

```sh
zig build test
```

Run the real subprocess proof (opt-in; requires Roc plus nix/guix, and Nix flakes enabled):

```sh
zig build e2e
```

The e2e fixtures live in `fixtures/shell/`:

- `flake.nix` provides a Nix dev shell containing `guix`.
- `manifest.scm` provides a Guix shell containing `hello` and `bash-minimal`.
