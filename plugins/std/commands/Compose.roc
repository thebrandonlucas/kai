import parser.Body
import kai.Plugin

Compose := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		body: Body.object([]),
		call: Plugin.call("compose", [Plugin.required_argument("machine")]),
		config: DirectConfig(QualifiedThenUnqualified),
		config_block: OptionalConfigBlock("compose"),
	}
}
