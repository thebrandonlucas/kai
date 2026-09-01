# Command schema for entering an inline or declared developer environment.
import kai.Kaifile
import kai.Plugin
import blocks.Environment as EnvironmentBlock
import blocks.Shell as ShellBlock

Shell := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"shell",
		[Plugin.optional_argument("environment")],
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
