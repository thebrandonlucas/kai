import kai.Plugin as PluginApi
import backends.Local
import commands.SplitCommand
import implementations.SplitLocal

Plugin := [].{
	plugin : PluginApi.RegistryDefinition
	plugin = {
		definition: PluginApi.Definition.{
			backends: [Local.backend],
			commands: [SplitCommand.command],
			default_backend: Local.backend.name,
			implementations: [SplitLocal.implementation],
			name: "split",
		},
		select_config: |_, _, _, _, _, _| Ok(Missing),
	}
}
