# Shared `command` interface for defining tasks the user can run.
#
# These can be anything e.g. commands you would run in the shell.
# They pair naturally with workflows to run tasks in series i.e for CI.
import parser.Body
import kai.Kaifile
import kai.Plugin

Task := [].{
	fields = [
		Body.required("environment", String),
		Body.required("run", StringList),
	]

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

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({ header: "task <task>", fields, name_rules })

	environment_block : Plugin.KaifileBlock
	environment_block = Kaifile.named_block({
		header: "environment <environment>",
		fields: [
			Body.required("packages", StringList),
			Body.optional("overlays", StringList),
		],
		name_rules: [],
	})

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("run", [Plugin.required_argument("task")]),
		config: NamedWithRelatedConfig({
			lookup: QualifiedOnly,
			related: environment_block,
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock(block),
	}
}
