# Command schema for running a declared workflow.
import kai.Plugin
import blocks.Workflow as WorkflowBlock

Workflow := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"workflow",
		[Plugin.required_argument("workflow")],
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: WorkflowBlock.block,
	})
}
