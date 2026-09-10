# Shared `command` interface for updating project dependencies.
import kai.Plugin

Update := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"update",
		[],
		{
			arguments: [],
			description: "Update and lock project dependencies.",
			examples: ["kai update"],
			kaifile_block_example: NoKaifileBlockExample,
		},
	)

	command : Plugin.Command
	command = Plugin.command_only(command_syntax)
}
