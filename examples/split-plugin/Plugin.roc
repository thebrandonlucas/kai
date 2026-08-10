import kai.Plugin as PluginApi
import backends.Local
import commands.SplitCommand
import implementations.SplitLocal

Plugin := [].{
	plugin : PluginApi.Plugin
	plugin = PluginApi.Plugin.Registry({
		definition: PluginApi.Definition.{
			backends: [Local.backend],
			commands: [SplitCommand.command],
			implementations: [SplitLocal.implementation],
			name: "split",
		},
		select_config: |_, _, _, _, _| Ok(Missing),
	})
}
