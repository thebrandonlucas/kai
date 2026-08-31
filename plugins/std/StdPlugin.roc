# Standard plugin definition for Kai's built-in Nix commands.
import kai.Plugin
import backends.Nix as NixBackend
import schemas.Build as BuildCommand
import schemas.EnvironmentConfig
import schemas.Image as ImageCommand
import schemas.Machine as MachineCommand
import schemas.MachineConfig
import schemas.Secret as SecretCommand
import schemas.Service as ServiceCommand
import schemas.Shell as ShellCommand
import schemas.Source
import schemas.Task as TaskCommand
import schemas.Update as UpdateCommand
import schemas.Workflow as WorkflowCommand
import implementations.BuildNix
import implementations.ImageNix
import implementations.MachineNix
import implementations.ServiceNix
import implementations.ShellNix
import implementations.TaskNix
import implementations.UpdateNix
import implementations.WorkflowNix

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
			BuildCommand.command,
			ImageCommand.command,
			MachineCommand.command,
			ServiceCommand.command,
			ShellCommand.command,
			TaskCommand.command,
			UpdateCommand.command,
			WorkflowCommand.command,
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
