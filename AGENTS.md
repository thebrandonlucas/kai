- Read [AI_POLICY.md](./docs/AI_POLICY.md) first.
- Do not read any non-local reference links from the internet here or within the referenced files unless additional context is very helpful for accomplishing the given task.
- When discovering a Roc bug:
    1. Check whether it has already been fixed upstream.
    2. If fixed, check whether Roc can be upgraded to the fix, including whether a blocking downstream dependency can be updated.
    3. If no viable upgrade is available, propose a workaround. Any implemented workaround must include a comment linking the upstream issue and explaining when the workaround can be removed.
- Read the following for relevant context:
    - [rules.md](./docs/rules.md) for development rules
    - [design.md](./docs/design.md) for design and architecture
    - [vision.md](./docs/vision.md) for project purpose and goals
- Put backend-specific shared helpers in their corresponding backend module,
  e.g. `plugins/std/backends/Nix.roc`, instead of a standalone helper module.
