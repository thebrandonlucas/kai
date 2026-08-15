import parser.Body
import kai.Plugin as PluginApi

SplitCommand := [].{
	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: NoArguments,
		body: Body.object([]),
		config_block: OptionalConfigBlock("split"),
		default_backend: "local",
		name: "split-command",
	}
}
