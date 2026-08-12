import parser.Body
import kai.Plugin as PluginApi

Task := [].{
	body : Body.Shape
	body = Body.object([
		Body.required("environment", String),
		Body.required("run", StringList),
	])

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("task"),
		default_backend: "nix",
		name: "run",
	}
}
