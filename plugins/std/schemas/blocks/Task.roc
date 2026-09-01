# Kaifile block schema for tasks the user can run.
import kai.Kaifile
import kai.Plugin
import Environment

Task := [].{
	fields = [
		Kaifile.required_quoted_reference("environment", Environment.block),
		Kaifile.required("run", StringList),
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

	block : Plugin.Block
	block = Kaifile.named_block({ header: "task <task>", fields, name_rules })

}
