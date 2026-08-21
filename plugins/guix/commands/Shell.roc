import parser.Body
import kai.Plugin

Shell := [].{
	packages_field : Body.Field
	packages_field = Body.required("packages", StringList)

	body : Body.Shape
	body = Body.object([packages_field])

	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: AllowArguments,
		body,
		config: DirectOrNamedConfig({
			block: "environment",
			lookup: QualifiedOnly,
			name_rules: [NonemptyText("environment name must not be empty")],
		}),
		config_block: RequiredConfigBlock("shell"),
		name: "shell",
	}
}
