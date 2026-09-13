# Shared command for deploying a declared machine.
import kai.Plugin
import blocks.Machine as MachineBlock

Deploy := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"deploy",
		[Plugin.required_argument("machine")],
		{
			arguments: [
				{
					description: "Machine name from the Kaifile",
					name: "MACHINE",
					presence: RequiredHelpArgument,
				},
			],
			description: "Build and activate a machine on its declared target.",
			examples: ["kai deploy <machine>", "kai deploy -y <machine>"],
			kaifile_block_example: KaifileBlockExample([
				\\machine <machine> {
				\\	environment: server
				\\	system: "x86_64-linux"
				\\	target: "root@example.com"
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
