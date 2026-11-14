# One plugin of a Kaifile: the commands, backends and implementations it
# contributes, what it asks the lock's owner to lock, and any problems its
# settings have, which fail the Kaifile.roc compile.
import Backend
import Command
import Implementation

## `describe` is text `kai describe` shows; std gives its project model.
## `lock_requests` are what the plugin asks the lock's owner to lock, and
## `check_lock_requests` gives the problems the lock's owner finds in every
## plugin's requests.
Plugin := {
	name : Str,
	version : Str,
	describe : Str,
	commands : List(Command),
	backends : List(Backend),
	implementations : List(Implementation),
	problems : List(Str),
	lock_requests : List(Implementation.LockRequest),
	check_lock_requests : List(Implementation.Requested) -> List(Str),
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
			lock_requests: [],
			check_lock_requests: |_| [],
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
			lock_requests: kept.lock_requests,
			check_lock_requests: kept.check_lock_requests,
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
			lock_requests: plugin.lock_requests,
			check_lock_requests: plugin.check_lock_requests,
		}

	## Ask the lock's owner, std's `kai update`, to lock more:
	## `Input(name, reference, options)` a flake input the generated flake
	## declares, and `Source(name)` a package source the project declares,
	## or "default", which std otherwise locks only when something uses it.
	locking : Plugin, List(Implementation.LockRequest) -> Plugin
	locking = |plugin, requests|
		Plugin.{
			name: plugin.name,
			version: plugin.version,
			describe: plugin.describe,
			commands: plugin.commands,
			backends: plugin.backends,
			implementations: plugin.implementations,
			problems: plugin.problems,
			lock_requests: plugin.lock_requests.concat(requests),
			check_lock_requests: plugin.check_lock_requests,
		}

	## How the lock's owner checks every plugin's lock requests as
	## Kaifile.roc compiles: the problems it finds, such as an input a
	## plugin asks for at another reference than the project's.
	checking_lock_requests :
		Plugin, (List(Implementation.Requested) -> List(Str)) -> Plugin
	checking_lock_requests = |plugin, check|
		Plugin.{
			name: plugin.name,
			version: plugin.version,
			describe: plugin.describe,
			commands: plugin.commands,
			backends: plugin.backends,
			implementations: plugin.implementations,
			problems: plugin.problems,
			lock_requests: plugin.lock_requests,
			check_lock_requests: check,
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
			lock_requests: [],
			check_lock_requests: |_| [],
		}
}
