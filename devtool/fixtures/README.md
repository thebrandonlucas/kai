# Test fixtures

A fixture is a project the end-to-end tests run kai on, so they can check
exact results: output bytes, argv boundaries, exit codes, overlay order.
Each test copies a fixture to a temporary directory first, so nothing here
is ever changed. These are not examples to learn from; those are in
[examples](../../examples).

| Fixture | Used by | For |
|---|---|---|
| [artifacts](artifacts) | `E2eBuild`, `E2eWorkflow` | Two builds with exact output bytes, a local `path:` source, fresh snapshots, and a changed locked source |
| [composition](composition) | `E2eRun`, `E2eUpdate`, `ConfigFixtures` | Tasks showing argv boundaries (`args`) and exit codes (`fail`), shared through a Roc module, on Nix and Guix |
| [overlays](overlays) | `E2eOverlays` | Two local overlay flakes whose order is visible in a tool's output |
| [channels](channels) | Guix halves of `E2eRun`, `E2eBuild`, `E2eWorkflow` | A Guix channel source, using `hello` because Guix ships ready-made binaries for it |
