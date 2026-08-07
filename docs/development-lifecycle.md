# Development lifecycle ideas

> Design notes, not a committed interface. The syntax and command names below
> are illustrative.

Kai should cover the common software lifecycle without requiring users to learn
Nix concepts first:

1. Resolve and lock dependencies.
2. Enter a development environment.
3. Run development tasks and checks.
4. Build named artifacts.
5. Deploy those artifacts.
6. Inspect or roll back deployments.
7. Run the same operations in CI.

The standard plugin should model these as user intentions, not as shorter
spellings of Nix commands. Nix can remain the first implementation without
leaking flakes, attribute paths, store paths, derivations, or closure transfer
into the normal interface. Plugins can provide other implementations where the
standard implementation is unsuitable.

A useful implementation order is:

1. Tracked locking and update UX.
2. Environments and tasks.
3. Named build artifacts.
4. Local CI workflows.
5. One complete deployment path.
6. Deployment history and rollback.

## Locking

Kai needs a tracked, Kai-owned lock file. The generated `.kai/flake.lock` is
currently backend output and `.kai` is ignored, so it is not a sufficient
project interface for reproducibility.

Possible commands are:

```sh
kai lock
kai update
kai update zig
kai status
```

The lock file can contain backend-specific information, but users should not
have to know which Nix input to update or how `nix flake lock` works. `kai
status` should explain whether `config.kai`, the lock, and generated backend
state agree.

## Environments

An environment is a reusable description of the tools and non-secret settings
needed to do work. A shell is the interactive use of an environment; a task is
its non-interactive use; a build can use the same tool definition in a
sandboxed context.

For example:

```kai
environment dev {
  packages: ["zig", "roc", "actionlint"]
}
```

Possible uses are:

```sh
kai shell dev
kai run test
kai build app
```

The existing `shell { pkgs: [...] }` form could remain convenient syntax for a
default environment. The important design point is that the package set should
not belong only to an interactive shell. Otherwise projects repeat the same
tools in their shell, build, tasks, and CI configuration.

An environment could eventually describe:

- packages and package sources;
- constant environment variables;
- names of host variables that may be passed through;
- a working directory;
- platform-specific additions;
- composition with another environment.

Secrets should not be values in an environment or lock file. An environment
may declare that a secret variable is required, but the caller or CI provider
must supply its value.

An environment only makes tools reproducible. It does not make every command
run inside it a reproducible build. Interactive shells and ordinary tasks can
read and modify the workspace, use the network, and depend on host state. A
build is a separate operation with declared inputs and outputs and, where the
backend supports it, sandboxing.

This distinction gives Kai one shared vocabulary without pretending that a dev
shell and a pure build have identical guarantees:

- `kai shell dev` enters the environment interactively.
- `kai run test` runs a task in the environment against the working tree.
- `kai build app` uses the required tools to produce a declared artifact.
- a workflow composes those existing operations.

## Tasks

Tasks cover project operations that are not themselves deployable artifacts,
such as formatting, linting, testing, code generation, or running a development
server.

```kai
task test {
  environment: dev
  run: ["zig", "build", "test"]
}

task format-check {
  environment: dev
  run: ["zig", "build", "check"]
}
```

```sh
kai run test
kai run format-check
```

Tasks should use argument lists rather than shell strings by default. This
avoids quoting differences and accidental dependence on a particular shell. A
separate explicit shell-script form can remain possible for commands that need
pipes, redirection, or multiple shell statements.

## Workflows and CI

A workflow is a named composition of tasks, builds, and eventually deployments.
It is Kai's representation of project procedure, not a CI provider
configuration.

```kai
workflow ci {
  steps: [
    "run format-check",
    "run test",
    "build app",
  ]
}
```

The initial implementation can execute steps sequentially and stop after a
failure. Later, explicit dependencies could permit parallel execution without
changing the meaning of the workflow.

```sh
kai workflow ci
kai ci
kai ci --only test
kai ci --list
```

`kai ci` can be the conventional alias for the workflow named `ci`. A hosted CI
configuration then has very little project logic:

1. Check out the repository.
2. Install Kai and its backend.
3. Run `kai ci`.

This removes the common duplication where developers maintain one command
sequence in documentation, another in a local script, and a third in GitHub
Actions. The exact same task and build plans run locally and on CI.

Workflow steps should not share implicit shell state. A `cd`, exported variable,
or background process in one step should not silently affect the next step.
State that crosses a boundary should be explicit: an artifact, a declared
service, or a workflow value. This makes local and hosted execution behave more
similarly.

Useful workflow features, in order, are:

1. Sequential reusable steps with clear status and failure output.
2. Platform conditions using Kai's existing host model.
3. Explicit dependencies and parallelism.
4. Artifact handoff between jobs or machines.
5. A target matrix.
6. Optional exporters for providers such as GitHub Actions.

Provider exporters should come after local workflows work well. Generating a
large provider-specific YAML file first would move rather than remove the
complexity. Nix's build cache can initially provide most caching without a
second Kai-specific cache model.

Deployments should normally be separate from the default `ci` workflow because
they mutate external state. A release workflow may include deployment with an
explicit environment, permission, and confirmation policy.

## Builds and artifacts

A build should produce a named artifact rather than expose a Nix attribute or
store path:

```kai
build app {
  environment: dev
  run: ["zig", "build", "-Doptimize=ReleaseSafe"]
  output: "zig-out/bin/app"
}
```

```sh
kai build app
kai artifact list
kai artifact path app
```

Kai can maintain a stable local reference such as `.kai/artifacts/app` while
Nix stores the immutable result. An artifact record should eventually include:

- its name and content digest;
- whether it is a file, directory, archive, OCI image, or backend closure;
- its target operating system and architecture;
- its runtime requirements;
- its backend reference.

This typed artifact is the boundary between build and deployment. Deployment
should not reinterpret a build command or guess which files are important.

"Deploy on any machine" cannot mean that every artifact runs on every machine.
Kai should validate target architecture and runtime requirements and explain a
mismatch. Portable archives, OCI images, and Nix closures have different
requirements even when they came from the same source project.

## Deployment

A deployment consumes a named artifact and a destination:

```kai
deploy production {
  artifact: app
  to: "ssh://app@example.com"
}
```

```sh
kai deploy production --plan
kai deploy production
kai rollback production
```

The generic deployment lifecycle is:

1. Build or locate the immutable artifact.
2. Validate it against the destination.
3. Transfer it.
4. Activate it atomically where possible.
5. Verify health.
6. Record the resulting generation.
7. Roll back activation if verification fails.

The standard plugin should begin with one narrow deployment implementation and
state its requirements clearly. Plausible implementations include portable
archives over SSH, Nix closures to Nix-enabled hosts, and OCI images pushed to
a registry. NixOS deployment, Kubernetes, and cloud-specific behavior can be
plugins rather than options forced into one universal block.

## `kai doctor`

`kai doctor` is a read-only diagnosis of whether Kai can operate correctly on
the current host and project. It should translate backend failures into useful
Kai-level explanations.

Checks can include:

- whether `config.kai` parses and references known commands or environments;
- whether the lock file is present and synchronized;
- whether generated backend state is stale;
- whether the selected backend is installed and reachable;
- whether required Nix features are enabled;
- whether the host OS and architecture are supported;
- whether requested packages resolve;
- whether caches or remote builders are misconfigured;
- whether disk or store pressure is likely to break a build;
- whether required deployment programs and credentials are available.

The default output should be concise and actionable:

```text
ok    config.kai
warn  kai.lock is older than config.kai
      run: kai lock
fail  Nix daemon is unreachable
      check the daemon service or run: kai doctor --verbose
```

It should not mutate the project by default. A future `--fix` mode should show
and confirm each change rather than silently rewriting system configuration.
`--verbose` can expose the underlying Nix diagnostics, and structured output
could help bug reports and editor integrations.

## `kai shell keep`

Temporary packages make exploration pleasant, but they are normally lost when
the shell exits. `keep` bridges exploration and reproducibility.

For example:

```sh
kai shell dev --with jq
# jq turns out to be useful
kai shell keep jq
```

`kai shell keep jq` adds the explicitly requested temporary package to the
current environment in `config.kai` and updates the lock as needed. Outside a
managed shell, the environment can be named explicitly:

```sh
kai shell keep jq --environment dev
```

Kai should remember the packages requested for the temporary shell, not infer
packages by inspecting every executable on `PATH`. Inferring from `PATH` would
capture transitive dependencies and unrelated host programs. `keep --all`
could persist all explicitly requested temporary packages after showing the
planned edit.

The edit should preserve comments and formatting, reject ambiguous environment
selection, and show exactly what changed. Keeping a package means retaining the
user-facing package request in `config.kai`; the resolved revision belongs in
`kai.lock`.

## `kai clean`

`kai clean` is a safe frontend for reclaiming Kai-owned build state. It should
make a clear distinction between project cleanup and global backend garbage
collection.

A conservative interface could be:

```sh
kai clean --plan
kai clean
kai clean --artifacts --older-than 30d
kai clean --store --plan
kai clean --store
```

The default command should remove only regenerable, project-local state that
Kai owns, such as stale generated backend files and unreferenced old artifact
links. It must not remove the tracked lock file, the current artifact, active
deployments, or unrelated Nix roots.

Global store cleanup is more consequential and should be explicit. Before
calling the backend garbage collector, Kai should report:

- which Kai roots or generations protect results;
- which project artifacts will become rebuild-only;
- whether active deployment generations are affected;
- an estimated amount of reclaimable space when available;
- the exact backend operation under `--verbose`.

Remote deployment history is not project-local garbage and should never be
removed by ordinary `kai clean`. A separate deployment-pruning operation can
retain a configured number of healthy generations and refuse to remove the
active one.

The goal is to replace uncertainty around store roots and
`nix-collect-garbage -d` with a predictable answer to two questions: what will
be deleted, and how can it be recovered?

## Other high-value ergonomics

Smaller commands can remove substantial Nix friction:

- `kai init` creates a minimal project configuration.
- `kai add <package>` and `kai remove <package>` edit an environment safely.
- package-not-found errors suggest likely names.
- normal errors are concise; `--verbose` reveals raw backend output.
- `kai plan` or `--plan` explains every mutating operation.
- host platform selection is automatic, while build targets remain explicit.
- cache and remote-builder setup use Kai concepts with a backend escape hatch.

## Plugin and executor implications

The current pure-plan boundary should remain: plugins describe effects and the
executor performs them. Supporting this lifecycle will likely require richer
data around that boundary:

- command metadata for generated help and discovery;
- structured diagnostics beyond `InvalidConfig`;
- a requested target platform distinct from the host platform;
- typed artifact and release records;
- actions for stable artifact references, transfer, and activation;
- plan rendering and dry runs;
- config parsing for named blocks and references.

These should enrich pure plans rather than allow plugins to perform hidden side
effects. That preserves predictable testing while letting the standard plugin
hide accidental Nix complexity.
