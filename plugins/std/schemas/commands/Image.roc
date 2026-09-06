# Shared `command` interface for building machine images.
import kai.Plugin
import blocks.Machine as MachineBlock

Image := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"image",
		[Plugin.required_argument("machine")],
		{
			arguments: [
				{
					description: "Machine name from the Kaifile",
					name: "MACHINE",
					presence: RequiredHelpArgument,
				},
			],
			description: "Build an image from a machine declared in the Kaifile.",
			examples: ["kai image <my-machine>"],
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
