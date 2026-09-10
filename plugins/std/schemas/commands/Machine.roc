# Shared interface for defining and working with machines
import kai.Plugin
import blocks.Machine as MachineBlock

Machine := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"machine",
		[Plugin.required_argument("machine")],
		{
			arguments: [
				{
					description: "Machine name from the Kaifile",
					name: "MACHINE",
					presence: RequiredHelpArgument,
				},
			],
			description: "Build a machine declared in the Kaifile.",
			examples: ["kai machine <my-machine>"],
			kaifile_block_example: KaifileBlockExample([
				\\machine <my-machine> {
				\\	environment: server,
				\\	system: "x86_64-linux",
				\\	users: ["<my-username>"],
				\\	services: ["openssh"],
				\\}
				,
			]),
		},
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: MachineBlock.block,
	})
}
