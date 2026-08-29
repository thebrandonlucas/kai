# Demonstrate the composition of two plugins
import kai.Plugin as PluginApi
import backends.Local
import commands.SplitCommand
import implementations.SplitLocal

Plugin := [].{
	plugin : PluginApi.Definition
	plugin = PluginApi.Definition.{
		backends,
		commands,
		implementations,
		name,
		project_configs: [],
	}

	name = "split"

	commands : List(PluginApi.CommandBlockSelection)
	commands = [SplitCommand.selection]

	backends : List(PluginApi.Backend)
	backends = [Local.backend]

	implementations : List(PluginApi.Implementation)
	implementations = [SplitLocal.implementation]
}
