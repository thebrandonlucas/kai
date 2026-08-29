# Shared interface for defining and working with machines
import kai.Plugin
import configs.MachineConfig

Machine := [].{
	command : Plugin.Command
	command = Plugin.command("machine", [Plugin.required_argument("machine")])

	selection : Plugin.CommandBlockSelection
	selection = Plugin.command_block_selection({
		command,
		kaifile: MachineConfig.block,
	})
}
