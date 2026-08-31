# Shared `command` interface for building machine images.
import kai.Plugin
import MachineConfig

Image := [].{
	command : Plugin.Command
	command = Plugin.command("image", [Plugin.required_argument("machine")])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_with_block({
		command,
		block: MachineConfig.block,
	})
}
