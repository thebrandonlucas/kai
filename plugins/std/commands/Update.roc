import parser.Body
import kai.Plugin

Update := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		body: Body.object([]),
		call: Plugin.call("update", []),
		config: DirectConfig(QualifiedOnly),
		config_block: OptionalConfigBlock("update"),
	}
}
