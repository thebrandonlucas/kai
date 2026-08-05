Kai is a Roc Embedded DSL to ease the use of determinate computers, targeting primarily Nix. We use [roc-overlay](https://github.com/thebrandonlucas/roc-overlay) to get the latest nightly Zig-based compiler that is compatible with our primary dependency, [`basic-cli`](https://github.com/roc-lang/basic-cli)

- See [Prototyping a friendlier frontend for determinate computing](https://blu.cx/posts/articles/2026-07-13-kai-friendly-frontend/), [Kai Devlog #1: Boundaries](https://blu.cx/posts/blog/2026-07-28-kai-devlog-1-boundaries/), and [Stack Programs Like Legos with Nix!](https://blu.cx/posts/blog/2025-11-21-nix-programs-as-legos/) to understand the purpose of the project and goals.

- Aspirational software philosophy: Tigerbeetle's [tigerstyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Work in small steps to stay motivated](https://mitchellh.com/writing/building-large-technical-projects). Avoid big changes where possible. If the programmer tells you to implement a concept, do the minimal amount of work to prove the concept while still following the rules and design philosophy of this repo (for example, you may still add a simple test or two).
- Dependency culture: vendored, like Roc or Ghostty
- Use matklad's [how to test](https://matklad.github.io/2021/05/31/how-to-test.html) philosophy for testing
- Kai uses Caddy-like [modularity](https://caddyserver.com/docs/architecture). Aspires to Unix philosophy. For three purposes: 1. Users can swap out implementations of commands 2. Users can swap out/use different determinate backends (nix, guix, etc.) 3. Users can add new commands via plugin system.
- After every change, run `zig build ci`.
- Do not commit changes unless explicitly instructed. Never push.
- If a user asks why a problem is occurring, assume they want to know the answer to fix it themselves. Don't fix or edit files without being told to.
- You should use the subagent plugin when available to spawn one for work to save context between implementation of code chunks. Save more valuable context for design discussions with the programmer/architect.
- As you work, keep track of Roc-specific quirks, errors, and design/implementation recommendations you find in `docs/roc-isms/`. We are using the Roc compiler and as such expect many breaking changes. Keep track bugs by prefixing files with `BUG-*.md` e.g. `BUG-001.md`. Give a clear description of the issue and steps/exact commands to reproduce. For design or implementation bad practices, quirks, or suggestions, put those in `IMPROVEMENT-*.md`. We ignore these files via a `.gitignore`.
