import kai.Plugin as PluginApi
import backends.Local
import commands.SplitCommand

SplitLocal := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [WriteConfigUtf8({ output: "message", path: "split-plugin-output.txt" })],
		backend: Local.backend.name,
		command: SplitCommand.command.name,
		renderer: |_| Ok(
			PluginApi.RenderResult.{
				outputs: [{ name: "message", text: "split plugin worked" }],
				requested_packages: [],
			},
		),
	}
}
