import parser.Body
import kai.Plugin as PluginApi

Shell := [].{
	packages_field : Body.Field
	packages_field = Body.required("packages", StringList)

	overlays_field : Body.Field
	overlays_field = Body.optional("overlays", StringList)

	body : Body.Shape
	body = Body.object([packages_field, overlays_field])

	environment_body : Body.Shape
	environment_body = Body.object([packages_field])

	environment_name_rules : List(PluginApi.TextRule)
	environment_name_rules = [NonemptyText("environment name must not be empty")]

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("shell"),
		default_backend: "nix",
		name: "shell",
	}
}
