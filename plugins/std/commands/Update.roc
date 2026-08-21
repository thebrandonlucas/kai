import parser.Body
import kai.Plugin

Update := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: NoArguments,
		body: Body.object([]),
		config: DirectConfig(QualifiedOnly),
		config_block: OptionalConfigBlock("update"),
		name: "update",
	}
}
