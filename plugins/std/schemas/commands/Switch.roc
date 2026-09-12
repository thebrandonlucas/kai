# Shared command for activating a declared machine.
import kai.Plugin

Switch := [].{
	command_syntax = Plugin.command_syntax_with_help(
		"switch",
		[Plugin.optional_argument("host")],
		{
			arguments: [
				{
					description: "Optional SSH target in USER@HOST form",
					name: "HOST",
					presence: OptionalHelpArgument,
				},
			],
			description: "Build and activate the declared machine.",
			examples: [
				"kai system switch",
				"kai system switch root@example.com",
				"kai system switch -y root@example.com",
			],
			kaifile_block_example: NoKaifileBlockExample,
		},
	)

	command = Plugin.command_only(command_syntax)
}
