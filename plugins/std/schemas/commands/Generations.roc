# Shared `generations` command for listing system generations.
import kai.Plugin

Generations := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.without_project(
		Plugin.command_syntax_with_help(
			"generations",
			[],
			{
				arguments: [],
				description: "List local system generations.",
				examples: ["kai system generations"],
				kaifile_block_example: NoKaifileBlockExample,
			},
		),
	)

	command : Plugin.Command
	command = Plugin.command_only(command_syntax)
}
