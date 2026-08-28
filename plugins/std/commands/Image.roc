# Shared `command` interface for building machine images.
import kai.Plugin
import configs.MachineConfig

Image := [].{
	command : Plugin.Command
	command = Plugin.command({
		call: Plugin.call("image", [Plugin.required_argument("machine")]),
		kaifile: MachineConfig.block,
	})
}
