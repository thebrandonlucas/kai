import parser.Body
import kai.Plugin as PluginApi

Shell := [].{
	body : Body.Shape
	body = Body.object([Body.required("pkgs", StringList)])

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: NoArguments,
		body,
		config_block: RequiredConfigBlock("shell"),
		default_backend: "nix",
		name: "shell",
	}
}
