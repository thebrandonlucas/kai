# kai Roc platform

Minimal Roc platform for Kai protocol experiments.

Roc code emits a backend-neutral protocol command (`shell`). The Zig host lowers it to a selected backend:

- `nix` -> `nix develop [target]`
- `guix` -> `guix shell [target]`

Run the example/test:

```sh
zig build test
```
