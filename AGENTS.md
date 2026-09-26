- Read [AI_POLICY.md](./docs/AI_POLICY.md) first.
- Do not read any non-local reference links from the internet here or within the referenced files unless additional context is very helpful for accomplishing the given task.
- When discovering a Roc bug:
    1. Check whether it has already been fixed upstream.
    2. If fixed and a pinned dependency (Roc, basic-cli, a Roc package) can be upgraded to include the fix, upgrade it, along with any blocking downstream dependency.
    3. Otherwise implement a workaround. Its comment links the upstream issue and fix (if any) and names the upgrade that allows removing it.
    4. If it isn't reported upstream, add a reproduction to the roc-issues-repro repo and list it for the user to report. Never file issues yourself.
- Read the following for relevant context:
    - [rules.md](./docs/rules.md) for development rules
    - [design.md](./docs/design.md) for design and architecture
    - [vision.md](./docs/vision.md) for project purpose and goals
- Put backend-specific shared helpers in their corresponding backend module,
  e.g. `kaifile/nix/NixBackend.roc` or `kaifile/guix/GuixBackend.roc`, instead
  of a standalone helper module.
- Never add an AI agent as an author or co-author of a commit or PR: no
  `Co-Authored-By`, `Generated with` or similar attribution trailers. The
  human developer is the sole author.
