# Command schema for entering an inline or declared developer environment.
import kai.Kaifile
import kai.Plugin
import blocks.Environment as EnvironmentBlock
import blocks.Shell as ShellBlock

Shell := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"shell",
		[Plugin.optional_argument("environment")],
		{
			arguments: [
				{
					description: "Optional environment name from the Kaifile",
					name: "ENVIRONMENT",
					presence: OptionalHelpArgument,
				},
			],
			description: "Enter an inline or declared developer environment.",
			examples: ["kai shell", "kai shell <my-environment>"],
			kaifile_block_example: KaifileBlockExample([
				\\shell {
				\\	packages: ["git"],
				\\}
				,
			]),
		},
	)

	command : Plugin.Command
	command = Plugin.command_with_required_backend_block({
		syntax: command_syntax,
		block: Kaifile.by_optional_argument({
			argument: "environment",
			when_omitted: ShellBlock.block,
			when_provided: EnvironmentBlock.block,
		}),
	})
}
