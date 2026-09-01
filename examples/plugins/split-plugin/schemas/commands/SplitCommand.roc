# Example command schema provided by the split plugin.
import kai.Kaifile
import kai.Plugin
import blocks.Split as SplitBlock

SplitCommand := [].{

	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax("split-command", [])

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: Kaifile.optional_block(SplitBlock.block),
	})
}
