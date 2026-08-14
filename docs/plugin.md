Kai can be used to write plugins which allow anyone to make their own `kai` binary using `xkai`, a special CLI tool for building `kai` CLI tools!

This is done so that the work done here will _last_ -- as code itself becomes cheaper and cheaper, good architecture and design thinking become more valuable by comparison. Thus a tool that wants to last must be modular and easy to modify in keeping with the Unix Philosophy. Since `kai` aims to be foundational software, modularity is a strong concern.

`Plugin`s are `roc` modules which let you extend or replace any `kai` functionality you like. It assumes you need to perform operations on potentially divergent systems (right now, `linux` and `macos`). A `Plugin` must specify:

1. The `command`s you want your `kai` to do and their resulting shape.
2. The `backend`(s) you want it to support. Essentially any requirement your `Plugin` will need to run.
3. The `implementation`(s) which specify the actual behavior and glue the `command` and `backend` together. It specifies how the given `command` behaves for those specific `backend`(s).

The last allows, for instance, one `command` (i.e. `shell`) to have different behavior across `backend`s (e.g. `nix` would do `nix shell` and `guix` do `guix shell` when `kai shell` is invoked and `backend` is set as one of those).

`xkai` then takes this and builds a `kai` binary which implements the `Plugin` behavior. It:

1. Reads a `Plugin.roc` file and its imports from a directory
2. Validates them.
3. Runs `roc build --opt=size` to compile it.

By default, the `kai` binary ships with `StdPlugin`, which will eventually have the standard set of things most developers want. But one size never fits all, especially in the software world.

Not only is `kai` modular via the plugin system, but `Plugin`s _themselves_ are modular! This means you can mix and match components as needed. For example, our split design makes the `shell` `command` independent of a `backend` or `implementation`, it just defines the shape that all `implementation`s of `shell` must conform to for all `backend`s. So a plugin writer could borrow it from `StdPlugin` to use in their own `implementation` or `backend`, while not having to recode the shape!

## Plugin contract

`StdPlugin` and custom plugins expose the same registry contract and use the same generic planner. The planner selects a command and backend, validates its configuration, calls its pure renderer, and lowers its action templates before the shared executor performs any file writes or backend commands.

A plugin's top-level Roc module exports `plugin : PluginApi.RegistryDefinition`. The registry contains:

- a config-block selector; and
- a definition listing commands, backends, and implementations.

`PluginApi.select_config` provides standard config-block lookup for the command and backend already chosen by the planner: it prefers the matching host section, falls back to an unscoped block, and uses a backend-qualified block when the backend was explicit. A plugin may instead supply its own selector. Commands declare their name, argument policy, config-block requirement, default backend, and body shape. Backends describe a determinate system and its requirements. Implementations connect command and backend names to a required pure renderer and action templates.

A single-file plugin remains valid:

```text
custom-plugin/
└── CustomPlugin.roc
```

A plugin may instead split its direct modules into the three supported component folders:

```text
split-plugin/
├── Plugin.roc
├── commands/
│   └── Command.roc
├── backends/
│   └── Backend.roc
└── implementations/
    └── CommandBackend.roc
```

The top-level module imports those component packages and assembles their values into one registry definition. `xkai` generates package wiring for direct `.roc` files in these folders; `main.roc` is reserved for generated package wiring, and nested helper directories are not yet supported.

`xkai` is the plugin builder, similar to `xcaddy`. Pass one or more top-level plugin modules to add commands or override standard command ownership:

```sh
xkai build path/to/CustomPlugin.roc path/to/split-plugin/Plugin.roc
```

Custom registries are ordered as supplied and precede `StdPlugin`; the first registry declaring a command owns it. During the build, the generated `kai` validates that every registry has commands, backends, and implementations, that implementation references resolve, and that no command or backend is left unimplemented. An invalid registry is rejected before the resulting binary is published.

For the build only, `xkai` writes its embedded API, executor, standard plugin, and supplied custom plugins to a temporary directory and invokes Roc. `basic-cli` is the compile-time Roc platform for both stock and customized binaries. The result is a portable `kai` binary with that registry compiled in; the temporary build inputs are removed. At runtime, `kai` reads `Kaifile`. The `.kai/` directory contains backend output such as `.kai/flake.nix`, never Roc source or plugin build inputs.

Renderers return direct actions, named outputs, requested packages, and ordered plan requests. A plan request asks the generic planner to plan another command through the complete registry without performing effects during rendering. Each request includes `args`, a progress `status`, and a `requirement`:

- `AnyPlan` accepts whichever plugin and backend own the child command. This preserves registry extensibility and is appropriate for workflows.
- `PlanFrom({ plugin, backend })` requires the planned child metadata to match both names. Selection still uses normal registry precedence; a mismatch returns `PlanningFailed` for the child command before any actions execute. This is appropriate when a parent depends on a specific implementation contract rather than only a command name.

`PrintLine` actions provide generic progress output. For migration, plugins built against the previous plan-request API must add `requirement: AnyPlan` to each non-empty request to preserve its old behavior. Empty `requests: []` values do not change. Plugins built against versions before plan requests must also add `requests: []` to ordinary render results and handle `PrintLine` when exhaustively matching actions.

The registry contains data seams for features tracked in the [roadmap](../roadmap.md).
