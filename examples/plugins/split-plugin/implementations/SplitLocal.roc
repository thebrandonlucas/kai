# Implementation of the `split` command with the `local` backend
import kai.Plugin
import backends.Local
import commands.SplitCommand

SplitLocal := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: Local.backend.name,
		command: SplitCommand.command.name,
		plan: |_| Ok(
			Plugin.CommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: [],
				steps: [
					WriteFile({
						contents: "split plugin worked",
						path: "split-plugin-output.txt",
					}),
				],
			},
		),
		validator: NoValidation,
	}
}
