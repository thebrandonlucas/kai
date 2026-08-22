import parser.Body
import kai.Plugin
import Machine

Image := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: AllowArguments,
		body: Machine.body,
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
		name: "image",
	}
}
