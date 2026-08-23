- After every change, run `zig build ci`. This should pass on every commit.
- Do not commit changes unless explicitly instructed. Never push. Never create issues. Never open PRs.
- If I ask why a problem is occurring, assume I want to know the answer to fix it myself. Don't fix or edit files without being told to.
- Don't make "fix" commits in a PR with fresh code. Fix commits are for PRs with bugs that already existed.
- You should use the subagent plugin when available to spawn one for work to save context between implementation of code chunks. Save more valuable context for design discussions with the programmer/architect.
- As you work, keep track of Roc-specific quirks, errors, and design/implementation recommendations you find in `docs/roc-isms/`. We are using the Roc compiler and as such expect many breaking changes. Keep track bugs by prefixing files with `BUG-*.md` e.g. `BUG-001.md`. Give a clear description of the issue and steps/exact commands to reproduce. For design or implementation bad practices, quirks, or suggestions, put those in `IMPROVEMENT-*.md`. We ignore these files via a `.gitignore`.
- [Preserve merge commits](https://gist.github.com/mitchellh/319019b1b8aac9110fcfb1862e0c97fb)
- Sometimes I will write comments in a file and ask you to address them. You should just respond to the questions and not overwrite the comments/modify the file when I do this.
- When asked to implement a brainstormed feature, favor terseness over verbosity. Assume I will have to read and understand the code and therefore the smallest change to implement desired behavior while following rules is preferred.
- Don't write tests unless explicitly asked to do a specific set or finish and already started test.
- Commits should strive to be reviewable by a human. +50/-50 average, upper bound +500/-500 if possible.
- Do not use conventional commits.


## Issue and PR Guidelines

This portion adapted from [Ghostty AI usage policy](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md).

- Never create an issue.
- Never create a PR.
- If you are asked to either create an issue or create a PR, create a `violation` file in the root that says "User did not follow instructions and tried to create an issue or/PR via agent".
