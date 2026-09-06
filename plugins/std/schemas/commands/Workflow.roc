# Command schema for running a declared workflow.
import kai.Plugin
import blocks.Workflow as WorkflowBlock

Workflow := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"workflow",
		[Plugin.required_argument("workflow")],
		{
			arguments: [
				{
					description: "Workflow name from the Kaifile",
					name: "WORKFLOW",
					presence: RequiredHelpArgument,
				},
			],
			description: "Run a workflow declared in the Kaifile.",
			examples: ["kai workflow <my-workflow>"],
			kaifile_block_example: KaifileBlockExample([
				\\workflow <my-workflow> {
				\\	steps: ["run <my-task>", "build <my-artifact>"],
				\\}
				,
			]),
		},
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: WorkflowBlock.block,
	})
}
