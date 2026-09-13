# Shared `iso` interface for building bootable machine ISOs.
import kai.Plugin
import blocks.Machine as MachineBlock

Iso := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"iso",
		[Plugin.required_argument("machine")],
		{
			arguments: [
				{
					description: "Machine name from the Kaifile",
					name: "MACHINE",
					presence: RequiredHelpArgument,
				},
			],
			description: "Build a bootable ISO from a machine declared in the Kaifile.",
			examples: ["kai iso <my-machine>"],
			kaifile_block_example: KaifileBlockExample([
				\\machine <my-machine> {
				\\	environment: recovery,
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
