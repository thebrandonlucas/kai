# Demonstrate the composition of two plugins
import kai.Plugin as PluginApi
import backends.Local
import blocks.Split as SplitBlock
import commands.SplitCommand
import implementations.SplitLocal

Plugin := [].{
	plugin : PluginApi.Definition
	plugin = PluginApi.Definition.{
		backends,
		implementations,
		name,
		schema,
	}

	name = "split"

	schema : PluginApi.Schema
	schema = {
		blocks: [SplitBlock.block],
		commands: [SplitCommand.command],
	}

	backends : List(PluginApi.Backend)
	backends = [Local.backend]

	implementations : List(PluginApi.Implementation)
	implementations = [SplitLocal.implementation]
}
