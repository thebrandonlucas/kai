# Pure plugin model shared by plugins and the CLI.
Plugin := [
	Module(
		{
			name : Str,
			plan : Str, List(Str), HostOs, HostArch -> Try(Plan, Error),
		},
	),
].{
	Error : [InvalidConfig, UnknownCommand, UnsupportedPlatform]
	HostOs : [LINUX, MACOS, WINDOWS, OTHER(Str)]
	HostArch : [X86, X64, ARM, AARCH64, OTHER(Str)]

	run : Plugin, Str, List(Str), HostOs, HostArch -> Try(Plan, Error)
	run = |plugin, source, args, os, arch|
		match plugin {
			Module({ plan, name: _ }) => plan(source, args, os, arch)
		}

	# Side effects to be performed by a plugin.
	Action := [
		Exec({ args : List(Str), command : Str }),
		WriteUtf8({ content : Str, path : Str }),
	].{
		encoder_for : _
		parser_for : _
	}

	ActionTemplate : [
		Exec(
			{
				args : List(Str),
				command : Str,
			},
		),
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
		# Optional program required for this implementation to work.
		requirement : [None, Program(Str)],
	}

	Plan := {
		actions : List(Action),
	}.{
		encoder_for : _
		parser_for : _
	}

	# Lower pure action templates into a runtime plan.
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
