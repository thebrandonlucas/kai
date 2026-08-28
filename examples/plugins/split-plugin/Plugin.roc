# Demonstrate the composition of two plugins
import kai.Plugin as PluginApi
import backends.Local
import commands.SplitCommand
import implementations.SplitLocal

Plugin := [].{
	name = "split"

	commands : List(PluginApi.Command)
	commands = [SplitCommand.command]

	backends : List(PluginApi.Backend)
	backends = [Local.backend]

	implementations : List(PluginApi.Implementation)
	implementations = [SplitLocal.implementation]
}
