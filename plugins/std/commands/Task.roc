import parser.Body
import kai.Plugin

Task := [].{
	body : Body.Shape
	body = Body.object([
		Body.required("environment", String),
		Body.required("run", StringList),
	])

	name_rules : List(Plugin.TextRule)
	name_rules = [NonemptyText("task name must not be empty")]

	run_rules : Str -> List(Plugin.StringListRule)
	run_rules = |task|
		[
			NonemptyStringList("${task} run list must not be empty"),
			NonemptyFirstString("${task} run program must not be empty"),
		]

	environment_rules : Str -> List(Plugin.TextRule)
	environment_rules = |task_name|
		[NonemptyText("task '${task_name}' environment name must not be empty")]

	command : Plugin.Command
	command = Plugin.Command.{
		body,
		call: Plugin.call("run", [Plugin.required_argument("task")]),
		config: NamedWithRelatedConfig({
			lookup: QualifiedOnly,
			name_rules,
			related_block: "environment",
			related_body: Body.object([
				Body.required("packages", StringList),
				Body.optional("overlays", StringList),
			]),
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock("task"),
	}
}
