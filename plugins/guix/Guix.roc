# A plugin should have:

Guix := [].{
	# I would think that definitions would be grouped?
	# i.e.

	commands : List(Plugin.Command)
	commands = [
		BuildCommand.command,
		ShellCommand.command,
		TaskCommand.command,
		UpdateCommand.command,
		WorkflowCommand.command,
	]

	backends : List(Plugin.Backend)
	backends = [NixBackend.backend]

	implementations : List(Plugin.Implementation)
	implementations = [
		BuildNix.implementation,
		ShellNix.implementation,
		TaskNix.implementation,
		UpdateNix.implementation,
		WorkflowNix.implementation,
	]

	# FIXME: what validations need to happen at a high level
	# to ensure these all work together?
	definition : Plugin.Definition
	definition = Plugin.Definition.{
		backends,
		commands,
		implementations,
		name: "std",
	}
}
