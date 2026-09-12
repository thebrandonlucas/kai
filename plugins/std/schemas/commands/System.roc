# Shared `system` namespace for machine-wide commands.
import kai.Plugin

System := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"system",
		[],
		{
			arguments: [],
			description: "Manage machine-wide state.",
			examples: ["kai system"],
			kaifile_block_example: NoKaifileBlockExample,
		},
	)

	command : Plugin.Command
	command = Plugin.command_group(command_syntax)
}
