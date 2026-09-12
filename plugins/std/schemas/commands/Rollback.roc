# Shared `rollback` command for restoring the previous system generation.
import kai.Plugin

Rollback := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"rollback",
		[],
		{
			arguments: [],
			description: "Roll back the current host one system generation.",
			examples: ["kai system rollback", "kai system rollback -y"],
			kaifile_block_example: NoKaifileBlockExample,
		},
	)

	command : Plugin.Command
	command = Plugin.command_only(command_syntax)
}
