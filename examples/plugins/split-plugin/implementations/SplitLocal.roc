import kai.Plugin
import backends.Local
import commands.SplitCommand

SplitLocal := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [WriteConfigUtf8({ output: "message", path: "split-plugin-output.txt" })],
		backend: Local.backend.name,
		command: SplitCommand.command.name,
		renderer: |_| Ok(
			Plugin.RenderResult.{
				actions: [],
				outputs: [{ name: "message", text: "split plugin worked" }],
				requests: [],
				requested_packages: [],
			},
		),
		validator: NoValidation,
	}
}
