# Shared `command` interface for building machine images.
import kai.Plugin
import MachineConfig

Image := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"image",
		[Plugin.required_argument("machine")],
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: MachineConfig.block,
	})
}
