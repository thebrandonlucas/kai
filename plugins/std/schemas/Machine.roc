# Shared interface for defining and working with machines
import kai.Plugin
import MachineConfig

Machine := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"machine",
		[Plugin.required_argument("machine")],
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: MachineConfig.block,
	})
}
