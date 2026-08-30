# A minimal implementation of Guix to prove out the plugin architecture.
import kai.Plugin
import backends.Guix as GuixBackend
import commands.Shell as ShellCommand
import implementations.ShellGuix

GuixPlugin := [].{
	plugin : Plugin.Definition
	plugin = Plugin.Definition.{
		backends,
		implementations,
		name,
		schema,
	}

	name = "guix"

	schema : Plugin.Schema
	schema = {
		blocks: [ShellCommand.block, ShellCommand.environment_block],
		commands: [ShellCommand.command_schema],
	}

	backends : List(Plugin.Backend)
	backends = [GuixBackend.backend]

	implementations : List(Plugin.Implementation)
	implementations = [ShellGuix.implementation]
}
