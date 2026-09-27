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
