import parser.Body
import kai.Plugin

Workflow := [].{
	body : Body.Shape
	body = Body.object([Body.required("steps", StringList)])

	name_rules : List(Plugin.TextRule)
	name_rules = [NonemptyText("workflow name must not be empty")]

	command : Plugin.Command
	command = Plugin.Command.{
		body,
		call: Plugin.call("workflow", [Plugin.required_argument("workflow")]),
		config: NamedConfig({ lookup: QualifiedThenUnqualified, name_rules }),
		config_block: RequiredConfigBlock("workflow"),
	}
}
