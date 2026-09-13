# Shared `installer` interface for building guided machine installer ISOs.
import kai.Plugin
import blocks.Machine as MachineBlock

Installer := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"installer",
		[Plugin.required_argument("machine")],
		{
			arguments: [
				{
					description: "Machine name from the Kaifile",
					name: "MACHINE",
					presence: RequiredHelpArgument,
				},
			],
			description: "Build a guided full-disk installer for a machine.",
			examples: ["kai installer <my-machine>"],
			kaifile_block_example: KaifileBlockExample([
				\\machine <my-machine> {
				\\	environment: desktop,
				\\	system: "x86_64-linux",
				\\	users: ["<my-username>"],
				\\	bootloader: "limine",
				\\	storage: "single-disk",
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
