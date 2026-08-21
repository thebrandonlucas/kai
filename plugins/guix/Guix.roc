# A plugin should have:

import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import commands.Shell as ShellCommand
import commands.Task as TaskCommand
import commands.Update as UpdateCommand
import commands.Workflow as WorkflowCommand
import implementations.BuildNix
import implementations.ShellNix
import implementations.TaskNix
import implementations.UpdateNix
import implementations.WorkflowNix

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
		default_backend: NixBackend.backend.name,
		implementations,
		name: "std",
	}
}
