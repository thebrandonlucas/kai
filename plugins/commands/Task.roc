import parser.Body
import kai.Plugin as PluginApi

Task := [].{
	body : Body.Shape
	body = Body.object([
		Body.required("environment", String),
		Body.required("run", StringList),
	])

	name_rules : List(PluginApi.TextRule)
	name_rules = [NonemptyText("task name must not be empty")]

	run_rules : Str -> List(PluginApi.StringListRule)
	run_rules = |task|
		[
			NonemptyStringList("${task} run list must not be empty"),
			NonemptyFirstString("${task} run program must not be empty"),
		]

	environment_rules : Str -> List(PluginApi.TextRule)
	environment_rules = |task_name|
		[NonemptyText("task '${task_name}' environment name must not be empty")]

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("task"),
		default_backend: "nix",
		name: "run",
	}
}
