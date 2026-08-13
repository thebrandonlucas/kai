import parser.Body
import kai.Plugin as PluginApi

Update := [].{
	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: NoArguments,
		body: Body.object([]),
		config_block: OptionalConfigBlock("update"),
		default_backend: "nix",
		name: "update",
	}
}
