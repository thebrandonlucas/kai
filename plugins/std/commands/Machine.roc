# Shared interface for defining and working with machines
import kai.Plugin
import configs.MachineConfig

Machine := [].{
	command : Plugin.Command
	command = Plugin.command({
		call: Plugin.call("machine", [Plugin.required_argument("machine")]),
		kaifile: MachineConfig.block,
	})
}
