import parser.Body
import kai.Plugin as PluginApi

Shell := [].{
	body : Body.Shape
	body = Body.object([
		Body.required("packages", StringList),
		Body.optional("overlays", StringList),
	])

	environment_body : Body.Shape
	environment_body = Body.object([Body.required("packages", StringList)])

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("shell"),
		default_backend: "nix",
		name: "shell",
	}
}
