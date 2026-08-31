# Example `command` interface provided by the split plugin.
import kai.Kaifile
import kai.Plugin

SplitCommand := [].{
	block : Plugin.Block
	block = Kaifile.unnamed_block({ header: "split", fields: [] })

	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax("split-command", [])

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: Kaifile.optional_block(block),
	})
}
