# Implementation of the `split` command with the `local` backend
import kai.Plugin
import backends.Local
import commands.SplitCommand

SplitLocal := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [
			WriteConfigUtf8({
				output: "message",
				path: "split-plugin-output.txt",
			}),
		],
		backend: Local.backend.name,
		command: SplitCommand.command.name,
		plan: |_| Ok(
			Plugin.CommandPlan.{
				actions: [],
				artifacts: [],
				outputs: [{ name: "message", text: "split plugin worked" }],
				prerequisite_commands: [],
				requested_packages: [],
			},
		),
		validator: NoValidation,
	}
}
