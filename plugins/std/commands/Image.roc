# Shared `command` interface for building machine images.
import kai.Plugin
import configs.EnvironmentConfig
import configs.MachineConfig

Image := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("image", [Plugin.required_argument("machine")]),
		config: NamedWithRelatedConfig({
			lookup: QualifiedThenUnqualified,
			related: EnvironmentConfig.block,
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock(MachineConfig.block),
	}
}
