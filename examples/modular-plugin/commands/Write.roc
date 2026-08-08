import kai.Body
import kai.Plugin as PluginApi

Write := [].{
	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: NoArguments,
		body: Body.object([]),
		default_backend: "local",
		name: "modular-write",
		source: OptionalSource("modular"),
	}
}
