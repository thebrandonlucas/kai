import parser.Body
import kai.Plugin

Workflow := [].{
	body : Body.Shape
	body = Body.object([Body.required("steps", StringList)])

	name_rules : List(Plugin.TextRule)
	name_rules = [NonemptyText("workflow name must not be empty")]

	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("workflow"),
		default_backend: "nix",
		name: "workflow",
	}
}
