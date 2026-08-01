Kai is a Roc Embedded DSL to ease the use of determinate computers, targeting primarily Nix. We use [roc-overlay](https://github.com/thebrandonlucas/roc-overlay) to get the latest nightly Zig-based compiler that is compatible with our primary dependency, [`basic-cli`](https://github.com/roc-lang/basic-cli)

- See [Prototyping a friendlier frontend for determinate computing](https://blu.cx/posts/articles/2026-07-13-kai-friendly-frontend/), [Kai Devlog #1: Boundaries](https://blu.cx/posts/blog/2026-07-28-kai-devlog-1-boundaries/), and [Stack Programs Like Legos with Nix!](https://blu.cx/posts/blog/2025-11-21-nix-programs-as-legos/) to understand the purpose of the project and goals.

- Aspirational codebases and software philosophy: Tigerbeetle's [tigerstyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Work in small steps to stay motivated](https://mitchellh.com/writing/building-large-technical-projects). Avoid big changes.
- Dependency culture: vendored, like Roc or Ghostty
- Use matklad's [how to test](https://matklad.github.io/2021/05/31/how-to-test.html) philosophy for testing
- Kai uses Caddy-like [modularity](https://caddyserver.com/docs/architecture). Aspires to Unix philosophy. For three purposes: 1. Users can swap out implementations of commands 2. Users can swap out/use different determinate backends (nix, guix, etc.) 3. Users can add new commands via plugin system.
- After every change, run `zig build ci`.
- Do not commit changes unless explicitly instructed. Never push.

