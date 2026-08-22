import parser.Body
import kai.Plugin

Compose := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: AllowArguments,
		body: Body.object([]),
		config: DirectConfig(QualifiedThenUnqualified),
		config_block: OptionalConfigBlock("compose"),
		name: "compose",
	}
}
