# Writing a Kai plugin

A plugin is an ordinary Roc package on Kai's plugin platform. It adds
commands to `kai`, declares backends, and implements commands on backends.
Plugins are pure: they return plans, data describing what to write and
run, and `kai` performs every effect after checking the whole plan. std,
Kai's standard plugin, is written the same way; `examples/plugins/deploy`
is a complete small plugin.

## Using a plugin

A Kaifile.roc lists its plugins:

```roc
app [kaifile] {
	pf: platform "<platform URL>",
	std: "<std URL>",
	deploy: "./plugins/deploy/main.roc",
}

import pf.Kaifile
import std.Config
import std.Std
import deploy.Deploy

project : List(Config.Setting)
project = [
	Name("site"),
	Environment("ops", [Tools(["nixos-rebuild"])]),
]

kaifile = Kaifile.new([
	Std.plugin(project),
	Deploy.plugin(project, [
		Host("web", [Address("root@203.0.113.7"), Flake(".#web"), Tools("ops")]),
	]),
])
```

`kai --help` then lists `deploy`, `kai deploy --help` shows the plugin's
page with the project's hosts, and `kai describe` lists the plugins,
commands and backends.

The platform, std and every plugin must be built for the same Kai release:
Roc refuses a package pinned to another platform before type checking.

## The package

```roc
package [Deploy] {
	pf: platform "<platform URL>",
	std: "<std URL>",   # only to reuse std's settings or helpers
}
```

Import the API from the platform: `pf.Plugin`, `pf.Command`,
`pf.Implementation`, `pf.Backend`, `pf.Plan`, `pf.Kaifile`.

## Plugin

`Plugin.new({ name, version, describe, commands, backends,
implementations })` builds a plugin; `describe` is `""` for any plugin
but std. A plugin whose settings are invalid returns
`Plugin.invalid(name, problems)`: `kai check` and every command then fail
with `Invalid Kaifile.roc: <name>: <problems>` while Kaifile.roc compiles.

Settings are the plugin's own closed tag union (`Deploy.Setting`), so a
misspelt setting is a type error. A plugin that works with std's settings
takes the same `List(Config.Setting)` value the project gives std.

## Commands

```roc
Command.{
	name: "deploy",
	summary: "...",
	help: { description: "...", examples: ["kai deploy web"], config: [...] },
	args: [
		Name({ name: "host", help: "...", choices: [...], default: Required }),
	],
	lock: ReadsLock,
}
```

Arguments are data; the platform builds kai's parser and help from them.
A command takes at most one `Name` (a project entry; each choice becomes a
subcommand, so help and usage errors list the project's names; no choices
means any name) and at most one `Trailing` (everything after `--`,
exact). `Command.name(args, "host")` and `Command.trailing(args, "args")`
read the parsed values. Only the one command that owns the lock
(`OwnsLock`, std's `update`) may publish it.

## Backends and implementations

A backend is `Backend.{ id, summary, program, flag }`: kai checks it by
running `program --version` (or `-v`, `version`), bounded and side-effect
free. std declares `nix` and `guix`; other plugins usually implement
commands on those.

```roc
Implementation.{
	command: "deploy",
	backend: On("nix"),          # or Independent: no backend, no --backend
	fit: |args| ...,             # Err(why) when this backend cannot serve it
	plan: |ctx| ...,             # Ok(Plan) or Err(message)
}
```

For every request, the platform asks each backend's implementation, in
preference order (`Kaifile.prefer`, else declaration order), whether it
fits and for its plan. kai then runs the first fitting implementation
whose backend program works. A plan that fails is reported; kai never
falls back to another backend after choosing one.

`ctx` holds the parsed `args`, the chosen `backend`, the `host` system,
the `layout` of the project and its `.kai` workspace, the `lock` text,
and, for continued plans, `phase` and the `observed` files.

## Plans

A plan is a list of steps and what comes next:

| Step | Effect |
|---|---|
| `Note(text)`, `Print(text)` | a note on stderr, a result on stdout (JSON events with `--json`) |
| `Confirm(prompt)` | ask before anything runs; refused without `--yes` unless a person is at a terminal |
| `Write(files)` | write generated files, only beneath the generated root |
| `Run({ what, argv, output })` | run exact argv from the project root, never through a shell |
| `VerifyPath`, `CheckSource`, `Snapshot`, `InstallRunner` | std's checks and build sandbox steps |
| `PublishLock({ previous, contents })` | replace the lock, only for the lock owner |

`next: Observe(paths)` asks kai to read generated files and ask again with
`phase` 1 and their contents (std's `update` resolves with Nix, then
publishes). kai checks the whole plan before its first step and refuses
anything outside these rules; `kai --dry-run` prints the plan instead.

std's `Std.run_in(project, ctx, { environment, argv, what })` plans argv
inside one of std's environments from the locked Nix inputs, as a task
would run; the deploy example uses it for `nixos-rebuild`.

## Combining plugins

Kaifile.roc fails to compile when two plugins declare the same command,
implement the same command on the same backend, name kai's own commands
(`check`, `describe`, `help`), or leave a command without an
implementation. Resolve a clash explicitly:

```roc
Std.plugin(project).without({ command: "shell", backend: "nix" })
Std.plugin(project).without_command("workflow")
```

## Testing

`zig build e2e-plugins` runs a real kai against a project using
`examples/plugins/deploy`. A plugin package's own expects run with
`roc test` once the Roc test runner handles platform packages whose
dependencies share module names with the platform
([roc-issues BUG-012](https://github.com/thebrandonlucas/roc-issues/tree/master/bugs/BUG-012-test-platform-and-package-module-same-name)).
