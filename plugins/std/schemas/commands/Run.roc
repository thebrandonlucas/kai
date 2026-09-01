# Command schema for running a declared task.
import kai.Plugin
import blocks.Task as TaskBlock

Run := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"run",
		[Plugin.required_argument("task")],
	)

	command : Plugin.Command
	command = Plugin.command_with_required_backend_block({
		syntax: command_syntax,
		block: TaskBlock.block,
	})
}
