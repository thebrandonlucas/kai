import parser.Body
import kai.Plugin

SplitCommand := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		body: Body.object([]),
		call: Plugin.call("split-command", []),
		config: DirectConfig(QualifiedThenUnqualified),
		config_block: OptionalConfigBlock("split"),
	}
}
