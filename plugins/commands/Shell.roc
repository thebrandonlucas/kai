import kai.Body
import kai.Plugin as PluginApi

Shell := [].{
	body : Body.Shape
	body = Body.object([Body.required("pkgs", StringList)])

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: NoArguments,
		body,
		default_backend: "nix",
		name: "shell",
		source: RequiredSource("shell"),
	}
}
