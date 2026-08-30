# Standard plugin definition for Kai's built-in Nix commands.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import commands.Image as ImageCommand
import commands.Machine as MachineCommand
import commands.Secret as SecretCommand
import commands.Service as ServiceCommand
import commands.Shell as ShellCommand
import commands.Task as TaskCommand
import commands.Update as UpdateCommand
import commands.Workflow as WorkflowCommand
import configs.EnvironmentConfig
import configs.MachineConfig
import implementations.BuildNix
import implementations.ImageNix
import implementations.MachineNix
import implementations.ServiceNix
import implementations.ShellNix
import implementations.TaskNix
import implementations.UpdateNix
import implementations.WorkflowNix
import project_configs.Source

## `StdPlugin` is the standard plugin shipped for most `kai` users.
##
## It aims to wrap `nix` commands into easy-to-use pieces that match primary
## `nix` use cases. It also demonstrates the canonical use and structure of
# plugins and serve as an example of how to write them.

# The simple interface describes `commands`, which define what commands that
# `kai` (and the `Kaifile`) have available, the compatible `backend`s that
# these commands can operate on, and the `implementation`s which glue together
# a `backend` and a `command`.
#
# There are two types of validations that can occur:
# - Those at _compile time_ where the plugin writer can specify
#   which invariants must hold for given commands, backends, or
#   command/backend combos. An example may be that the user forgot
#   a command, used the wrong syntax, etc.
# - Those at _runtime_ where there may be failures due to
#   underspecification in the plugin or maybe a missing requirement
#   on the users system i.e. they don't have a compatible backend
#   installed.
#
# The individual commands/backends are like ingredients to a recipe:
# you can use any combination you like, but certain dishes require certain
# ingredients.

StdPlugin := [].{
	plugin : Plugin.Definition
	plugin = Plugin.Definition.{
		backends,
		implementations,
		name,
		schema,
	}

	name = "std"

	schema : Plugin.Schema
	schema = {
		blocks: [
			BuildCommand.block,
			EnvironmentConfig.block,
			MachineConfig.block,
			SecretCommand.block,
			ServiceCommand.block,
			ShellCommand.block,
			Source.block,
			TaskCommand.block,
			WorkflowCommand.block,
		],
		commands: [
			BuildCommand.command_schema,
			ImageCommand.command_schema,
			MachineCommand.command_schema,
			ServiceCommand.command_schema,
			ShellCommand.command_schema,
			TaskCommand.command_schema,
			UpdateCommand.command_schema,
			WorkflowCommand.command_schema,
		],
	}

	backends : List(Plugin.Backend)
	backends = [NixBackend.backend]

	implementations : List(Plugin.Implementation)
	implementations = [
		BuildNix.implementation,
		ImageNix.implementation,
		MachineNix.implementation,
		ServiceNix.implementation,
		ShellNix.implementation,
		TaskNix.implementation,
		UpdateNix.implementation,
		WorkflowNix.implementation,
	]
}
