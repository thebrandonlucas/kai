# Shared `command` interface for defining tasks the user can run.
#
# These can be anything e.g. commands you would run in the shell.
# They pair naturally with workflows to run tasks in series i.e for CI.
import kai.Kaifile
import kai.Plugin
import configs.EnvironmentConfig

Task := [].{
	fields = [
		Kaifile.required_quoted_reference("environment", EnvironmentConfig.block),
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

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({ header: "task <task>", fields, name_rules })

	command : Plugin.Command
	command = Plugin.command("run", [Plugin.required_argument("task")])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_with_required_backend_block({ command, block })
}
