import parser.Body
import kai.Plugin
import Machine

Image := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		body: Machine.body,
		call: Plugin.call("image", [Plugin.required_argument("machine")]),
		config: NamedWithRelatedConfig({
			lookup: QualifiedThenUnqualified,
			name_rules: Machine.name_rules,
			related_block: "environment",
			related_body: Body.object([
				Body.required("packages", StringList),
				Body.optional("overlays", StringList),
			]),
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock("machine"),
	}
}
