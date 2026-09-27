# One plugin of a Kaifile: the commands, backends and implementations it
# contributes, and any problems its settings have, which fail the Kaifile.roc
# compile.
import Backend
import Command
import Implementation

## `describe` is the Kaifile IR text kai plans from, until kai plans from
## implementations instead.
Plugin := {
	name : Str,
	version : Str,
	describe : Str,
	commands : List(Command),
	backends : List(Backend),
	implementations : List(Implementation),
	problems : List(Str),
}.{
	new :
		{
			name : Str,
			version : Str,
			describe : Str,
			commands : List(Command),
			backends : List(Backend),
			implementations : List(Implementation),
		} -> Plugin
	new = |{ name, version, describe, commands, backends, implementations }|
		Plugin.{
			name,
			version,
			describe,
			commands,
			backends,
			implementations,
			problems: [],
		}

	## Drop one implementation so another plugin can provide it.
	without : Plugin, { command : Str, backend : Str } -> Plugin
	without = |plugin, { command, backend }|
		Plugin.with_implementations(
			plugin,
			plugin.implementations.keep_if(
				|i| i.command != command or i.backend != On(backend),
			),
		)

	## Drop a command and every implementation of it.
	without_command : Plugin, Str -> Plugin
	without_command = |plugin, command| {
		kept = Plugin.with_implementations(
			plugin,
			plugin.implementations.keep_if(|i| i.command != command),
		)
		Plugin.{
			name: kept.name,
			version: kept.version,
			describe: kept.describe,
			commands: kept.commands.keep_if(|c| c.name != command),
			backends: kept.backends,
			implementations: kept.implementations,
			problems: kept.problems,
		}
	}

	# Nominal records have no update syntax; every field is rebuilt.
	with_implementations : Plugin, List(Implementation) -> Plugin
	with_implementations = |plugin, implementations|
		Plugin.{
			name: plugin.name,
			version: plugin.version,
			describe: plugin.describe,
			commands: plugin.commands,
			backends: plugin.backends,
			implementations,
			problems: plugin.problems,
		}

	## Settings a plugin could not accept; `Kaifile.validate` reports them.
	invalid : Str, List(Str) -> Plugin
	invalid = |name, problems|
		Plugin.{
			name,
			version: "",
			describe: "",
			commands: [],
			backends: [],
			implementations: [],
			problems,
		}
}
