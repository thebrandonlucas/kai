import kai.Plugin
import Machine

Image := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("image", [Plugin.required_argument("machine")]),
		config: NamedWithRelatedConfig({
			lookup: QualifiedThenUnqualified,
			related: Machine.environment_block,
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock(Machine.block),
	}
}
