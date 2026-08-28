# Shared interface for defining and working with machines
import kai.Plugin
import configs.EnvironmentConfig
import configs.MachineConfig

Machine := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("machine", [Plugin.required_argument("machine")]),
		config: NamedWithRelatedConfig({
			lookup: QualifiedThenUnqualified,
			related: EnvironmentConfig.block,
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock(MachineConfig.block),
	}
}
