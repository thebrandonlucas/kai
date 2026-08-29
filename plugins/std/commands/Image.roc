# Shared `command` interface for building machine images.
import kai.Plugin
import configs.MachineConfig

Image := [].{
	command : Plugin.Command
	command = Plugin.command("image", [Plugin.required_argument("machine")])

	selection : Plugin.CommandBlockSelection
	selection = Plugin.command_block_selection({
		command,
		kaifile: MachineConfig.block,
	})
}
