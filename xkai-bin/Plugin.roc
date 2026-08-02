# Pure plugin model shared by configuration apps, plugins, and the CLI.
Plugin := {
	backends : List(Backend),
	commands : List(Command),
	implementations : List(Implementation),
	name : Str,
}.{
	Action := [
		Exec({ args : List(Str), command : Str }),
		WriteUtf8({ content : Str, path : Str }),
	].{
		encoder_for : _
		parser_for : _
	}

	ActionTemplate : [
		Exec({ args : List(Str), command : Str }),
		WriteConfigUtf8({ path : Str }),
	]

	Backend := {
		name : Str,
	}

	Command := {
		argv : List(Str),
		backends : List(Backend),
		name : Str,
	}

	Implementation := {
		actions : List(ActionTemplate),
		backend : Backend,
		command : Command,
		config_program : Str,
	}

	Plan := {
		actions : List(Action),
	}.{
		encoder_for : _
		parser_for : _
	}

	find_implementation : Plugin, Str -> Try(Implementation, [UnknownCommand(Str)])
	find_implementation = |plugin, command_name|
	# FIXME: does this assume there's only one impl 
	# What if for example a plugin has two backends (nix,guix)
	# for one command name?
		Plugin.find_in(plugin.implementations, command_name)

	find_in : List(Implementation), Str -> Try(Implementation, [UnknownCommand(Str)])
	find_in = |implementations, command_name|
		match implementations {
			[] => Err(UnknownCommand(command_name))
			[first, .. as rest] =>
				if first.command.name == command_name {
					Ok(first)
				} else {
					Plugin.find_in(rest, command_name)
				}
			}

	# By actions we mean "effects" that are run
	# external to the program by e.g. nix or writing files
	# At this moment we only have command execution or 
	# file writing.
	lower : Implementation, Str -> Plan
	lower = |implementation, rendered_config| {
		actions = implementation.actions.map(
			|template|
				match template {
					Exec(exec) => Exec(exec)
					WriteConfigUtf8({ path }) => WriteUtf8({ content: rendered_config, path })
				},
		)

		{ actions }
	}
}
