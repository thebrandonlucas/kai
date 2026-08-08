import kai.Plugin as PluginApi
import backends.Local
import commands.Write
import implementations.WriteLocal

Plugin := [].{
	definition : PluginApi.Definition
	definition = PluginApi.Definition.{
		backends: [Local.backend],
		commands: [Write.command],
		implementations: [WriteLocal.implementation],
		name: "modular",
	}

	plugin : PluginApi.Plugin
	plugin = PluginApi.Plugin.Registry({ definition: Plugin.definition })
}
