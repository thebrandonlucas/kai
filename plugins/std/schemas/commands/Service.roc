# Command schema for building a declared machine service.
import kai.Plugin
import blocks.Service as ServiceBlock

Service := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"service",
		[Plugin.required_argument("service")],
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: ServiceBlock.block,
	})
}
