# Command schema for building a declared artifact.
import kai.Plugin
import blocks.Build as BuildBlock

Build := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"build",
		[Plugin.required_argument("artifact")],
		{
			arguments: [
				{
					description: "Artifact name from the Kaifile",
					name: "ARTIFACT",
					presence: RequiredHelpArgument,
				},
			],
			description: "Build an artifact declared in the Kaifile.",
			examples: ["kai build <my-artifact>"],
			kaifile_block_example: KaifileBlockExample([
				"build my-artifact {",
				"  environment: dev",
				"  run: [\"make\"]",
				"  output: \"result\"",
				"}",
			]),
		},
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: BuildBlock.block,
	})
}
