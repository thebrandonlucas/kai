# A minimal implementation of Guix to prove out the plugin architecture.
import kai.Plugin
import backends.Guix as GuixBackend
import blocks.Environment as EnvironmentBlock
import blocks.Shell as ShellBlock
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
		blocks: [EnvironmentBlock.block, ShellBlock.block],
		commands: [ShellCommand.command],
	}

	backends : List(Plugin.Backend)
	backends = [GuixBackend.backend]

	implementations : List(Plugin.Implementation)
	implementations = [ShellGuix.implementation]
}
