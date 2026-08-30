# Shared interface for defining and working with machines
import kai.Plugin
import configs.MachineConfig

Machine := [].{
	command : Plugin.Command
	command = Plugin.command("machine", [Plugin.required_argument("machine")])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_with_block({
		command,
		block: MachineConfig.block,
	})
}
