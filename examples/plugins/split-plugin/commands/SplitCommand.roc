import parser.Body
import kai.Plugin

SplitCommand := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: NoArguments,
		body: Body.object([]),
		config_block: OptionalConfigBlock("split"),
		default_backend: "local",
		name: "split-command",
	}
}
