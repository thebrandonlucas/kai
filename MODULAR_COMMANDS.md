# Modular Commands Plan

## Goal

Prove that Kai commands are modules rather than branches hardcoded into the CLI.

The proof must demonstrate both:

1. A project can add a command that Kai does not ship, without changing `cli/main.roc`.
2. A project can replace a standard implementation, such as the Nix `shell` implementation, while retaining the command contract and backend compatibility.

The first implementation model is compile-time/config-time composition through `kai.roc`, analogous to an `xcaddy` custom build:

- Caddy imports Go modules and compiles a custom Caddy executable.
- Kai imports Roc command modules and compiles the project's `kai.roc` application.
- The released `kai` CLI remains generic.

Registration should be explicit Roc data. Kai should not use global initialization, dynamic libraries, PATH discovery, or external executable plugins for this proof.

## Boundaries

```text
kai.roc
    imports and registers command implementations
        |
        v
Kai configuration platform
    selects an implementation and returns a pure execution plan
        |
        | kai.plan.v1 over stdout
        v
kai CLI
    validates the plan, writes generated files, and executes argv
```

Command handlers remain pure. The configuration platform continues to expose only minimal stdout/stderr effects. All managed filesystem and subprocess effects remain in the CLI.

Blueprint remains the canonical portable model used by command implementations such as the default shell implementation.

## Minimal contracts

The initial contract should be intentionally narrow.

```text
Backend = Nix

Request = {
    project,
    backend,
    args,
}

File = {
    path,
    contents,
}

Plan = {
    files: List(File),
    argv: List(Str),
}

Implementation = {
    command,
    contract,
    id,
    backends,
    handler: Request -> Try(Plan, CommandError),
}
```

A plan means:

1. Write zero or more generated files.
2. Execute exactly one argv list with inherited stdin, stdout, and stderr.
3. Stop and return failure if validation, a write, or the subprocess fails.

This is enough to prove the architecture:

- `shell`: write `.kai/flake.nix`, then execute `nix develop path:.kai#default`.
- `build`: write backend state, then execute `nix build ...`.
- `deploy`: write backend state, then execute one deployment program.
- proof-only added command: write nothing, then execute `nix --version`.

Do not generalize to arbitrary effect graphs until a real command requires them. A future version can replace `Plan` with a versioned sequence of effects.

## Command and implementation identity

A standard command owns a versioned contract ID. The initial shell contract is:

```text
command: shell
contract: kai.shell.v1
```

An implementation also declares its own identity and compatible backends:

```text
id: kai.shell.default.nix
backends: [Nix]
```

Selection uses command plus active backend. Replacement must preserve the command contract and backend compatibility.

Registration operations are explicit:

```text
Add(implementation)
Replace(implementation)
```

Rules:

- `Add` fails when that command/backend slot already exists.
- `Replace` fails when that command/backend slot does not exist.
- `Replace` fails when the replacement contract differs from the existing contract.
- Duplicate or ambiguous registrations are errors.
- Registration never silently uses last-writer-wins behavior.

## Implementation chunks

### Chunk 1: Pure command types

Add a pure module such as `platform/Command.roc` containing:

- `Backend`
- `File`
- `Plan`
- `Request`
- `Handler`
- `Implementation`
- structured validation errors

Expose the public command API from `platform/main.roc` as needed.

Tests:

- Valid Nix implementation.
- Empty command, contract, or implementation ID.
- Empty plan argv.
- Backend support checks.

No behavior changes in `cli/main.roc` or `kai.roc`.

Commit:

```text
feat: define modular command contracts
```

### Chunk 2: Pure registry

Implement a pure registry and selection functions:

```text
select(registry, command, backend)
add(registry, implementation)
replace(registry, implementation)
```

Tests:

- Select the default Nix shell implementation.
- Add a previously unknown command.
- Reject a duplicate add.
- Replace the shell implementation.
- Reject replacement of a missing command.
- Reject a replacement with the wrong contract.
- Reject selection for an unsupported backend.

No effects or wire protocol yet.

Commit:

```text
feat: add command implementation registry
```

### Chunk 3: Default shell as a plan-producing implementation

Refactor the current `Kai.render` pipeline into a default Nix shell handler.

The handler still performs the existing pure pipeline:

```text
friendly shell config
    -> Blueprint.Draft
    -> Blueprint.validate
    -> Nix bindings
    -> Nix.render
```

Instead of returning only source, it returns:

```text
files:
    .kai/flake.nix = rendered source

argv:
    nix develop path:.kai#default
```

Keep a temporary `Kai.render` compatibility wrapper if useful so the current CLI continues working during this chunk.

Tests:

- The planned file contents match the current golden output.
- The file path is `.kai/flake.nix`.
- The argv is exactly `nix develop path:.kai#default`.

Commit:

```text
refactor: express shell rendering as a command plan
```

### Chunk 4: Configurable implementations in `kai.roc`

Extend `Kai.Config` with command changes while retaining project and shell data:

```text
Config = {
    project configuration,
    commands: List(CommandChange),
}

CommandChange = Add(Implementation) | Replace(Implementation)
```

Kai starts with its standard implementation registry, then applies user changes in declaration order.

The platform-required structural `config` type in `platform/main.roc` must match the expanded `Kai.Config`, including the universal handler function type.

The current Roc compiler supports function-valued records inside platform-required config values; command selection and invocation can therefore remain in Roc without crossing a function through the Zig ABI.

Test locally in `kai.roc` with a custom shell replacement. The CLI does not change yet.

Commit:

```text
feat: configure command implementations in kai roc
```

### Chunk 5: Generic platform dispatch

Change `main_for_host!` in `platform/main.roc` to inspect internal arguments rather than always calling `Kai.render(config)`.

Internal invocation shape:

```text
roc kai.roc -- __kai_plan_v1 nix <command> <command-args...>
```

The platform:

1. Parses the internal protocol marker.
2. Parses the backend.
3. Reads the command and remaining arguments.
4. Builds the standard registry and applies config changes.
5. Selects the implementation for command/backend.
6. Calls its pure handler.
7. Produces a `Plan` or a structured error.

Unknown project commands are reported here instead of being enumerated in the CLI.

Tests:

- Dispatch default shell.
- Dispatch replacement shell.
- Unknown command.
- Unsupported backend.
- Invalid internal invocation.

Commit:

```text
feat: dispatch configured command implementations
```

### Chunk 6: Versioned execution-plan protocol

A config evaluator and the CLI are separate processes, so serialize `Plan` over stdout.

Use a length-prefixed binary/text framing protocol rather than delimiter escaping:

```text
kai.plan.v1
<file count>
<path byte length>
<path bytes>
<contents byte length>
<contents bytes>
...
<argv count>
<argument byte length>
<argument bytes>
...
```

Length prefixes are required because generated Nix source and arguments may contain spaces, quotes, and newlines.

Add pure encoder and decoder functions. The config platform needs encoding; the CLI needs decoding. Config-evaluator stdout is reserved for protocol bytes. Diagnostics go to stderr.

Tests:

- Empty file list.
- Multiline file contents.
- Arguments containing spaces and newlines.
- Empty argument.
- Unsupported protocol version.
- Truncated payload.
- Invalid lengths.
- Extra trailing bytes.
- Empty argv.

Commit:

```text
feat: add command plan protocol
```

### Chunk 7: Generic plan executor in `cli/main.roc`

Keep only Kai management commands local to the CLI, such as:

- `help`
- `version`
- eventually `shell init` or module-management commands

Delegate every project command to `kai.roc`:

```text
shell
build
deploy
doctor
user-defined commands
```

Replace the hardcoded `Cli.Command.Shell` effect sequence with:

1. Forward command and arguments to `roc kai.roc` using the internal protocol invocation.
2. Capture stdout as bytes.
3. Decode and validate `kai.plan.v1`.
4. Create managed parent directories.
5. Write every planned file.
6. Execute planned argv with inherited stdio.
7. Propagate subprocess status.

Initial executor restrictions:

- Reject absolute output paths.
- Reject paths containing `..`.
- Reject empty argv.
- Limit protocol and generated-file sizes.
- Stop before execution if any write fails.

The CLI must not contain a branch for each project command.

Commit:

```text
refactor: execute project commands through plans
```

### Chunk 8: Prove standard command replacement

Create a custom shell implementation in `kai.roc` with the same contract:

```text
command: shell
contract: kai.shell.v1
backend: Nix
```

Make the result observably different but harmless, for example:

- add `--impure` to argv;
- add a marker generated file;
- alter generated description text.

Register it with `Replace`.

Prove:

- `kai shell` uses the custom implementation.
- `cli/main.roc` contains no knowledge of its implementation ID.
- Wrong contract replacement is rejected.
- Unsupported backend selection is rejected.

Commit:

```text
test: prove custom shell implementation
```

### Chunk 9: Prove a new command

Add a proof-only command such as `doctor`:

```text
command: doctor
contract: example.doctor.v1
id: example.doctor.nix
backends: [Nix]
files: []
argv: ["nix", "--version"]
```

Register it with `Add` and run:

```sh
kai doctor
```

Do not modify `cli/main.roc` or platform dispatch to recognize `doctor`.

This proves users can introduce commands outside Kai's standard set.

Commit:

```text
test: prove user-defined command
```

### Chunk 10: Prove imported command modules

Move the proof command from `kai.roc` into a module such as:

```text
commands/Doctor.roc
```

Import its implementation and register it explicitly from `kai.roc`.

Later, replace the local module with a content-addressed Roc package URL. That establishes the intended Caddy-like distribution model without adding dynamic runtime loading.

Commit:

```text
refactor: load custom command from roc module
```

## Acceptance tests

The proof is complete when all of these pass:

1. Default `kai shell` still generates the same flake and enters the shell.
2. A custom Nix shell implementation replaces the standard implementation.
3. A replacement with the wrong shell contract fails before effects.
4. A replacement incompatible with the active backend fails before effects.
5. A new command runs without any command-specific CLI branch.
6. The new command works after moving into an imported Roc module.
7. Duplicate registration is rejected deterministically.
8. Malformed plan output is rejected without writing files or running a process.
9. Planned subprocess exit status reaches the caller.
10. Existing Blueprint and platform tests continue to pass.

## Deferred work

Do not include these in the initial proof:

- PATH-based plugin discovery.
- Dynamic libraries or `dlopen`.
- External executable plugins.
- Plugin marketplace or installer.
- Arbitrary effects in command handlers.
- Background services.
- Multi-process plans.
- Stable cross-language JSON schemas.
- Guix implementation.

After shell plus one real additional command exercise the contract, consider a versioned plan containing sequential effects:

```text
WriteFile
Exec
Print
```

External executable plugins can later consume the same command, backend, request, and plan concepts through a separately versioned process protocol.
