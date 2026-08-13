import parser.Body
import kai.Plugin as PluginApi

Workflow := [].{
	body : Body.Shape
	body = Body.object([Body.required("steps", StringList)])

	name_rules : List(PluginApi.TextRule)
	name_rules = [NonemptyText("workflow name must not be empty")]

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("workflow"),
		default_backend: "nix",
		name: "workflow",
	}

	ci_command : PluginApi.Command
	ci_command = PluginApi.Command.{
		argument_policy: NoArguments,
		body,
		config_block: RequiredConfigBlock("workflow"),
		default_backend: "nix",
		name: "ci",
	}
}
