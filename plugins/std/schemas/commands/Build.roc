# Command schema for building a declared artifact.
import kai.Plugin
import blocks.Build as BuildBlock

Build := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"build",
		[Plugin.required_argument("artifact")],
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: BuildBlock.block,
	})
}
