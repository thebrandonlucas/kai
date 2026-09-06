# Command schema for running a declared task.
import kai.Plugin
import blocks.Task as TaskBlock

Run := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"run",
		[Plugin.required_argument("task")],
		{
			arguments: [
				{
					description: "Task name from the Kaifile",
					name: "TASK",
					presence: RequiredHelpArgument,
				},
			],
			description: "Run a task declared in the Kaifile.",
			examples: ["kai run <my-task>"],
			kaifile_block_example: KaifileBlockExample([
				\\task <my-task> {
				\\	environment: "dev",
				\\	run: ["echo", "Hello!"],
				\\}
				,
			]),
		},
	)

	command : Plugin.Command
	command = Plugin.command_with_required_backend_block({
		syntax: command_syntax,
		block: TaskBlock.block,
	})
}
