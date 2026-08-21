# - Commands define user-facing syntax and semantics.
import parser.Body
import kai.Plugin

# TODO: how to make this code more self documenting ie,
# I want to be able to know easily: 
# a) what new kai commands and command call shape from this code, and 
# b) what the corresponding Kaifile will look like from it
Shell := [].{
	packages_field : Body.Field
	packages_field = Body.required("packages", StringList)

	overlays_field : Body.Field
	overlays_field = Body.optional("overlays", StringList)

	body : Body.Shape
	body = Body.object([packages_field, overlays_field])

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
