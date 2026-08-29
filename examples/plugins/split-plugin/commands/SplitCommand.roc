# Example `command` interface provided by the split plugin.
import kai.Kaifile
import kai.Plugin

SplitCommand := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.unnamed_block({ header: "split", fields: [] })

	command : Plugin.Command
	command = Plugin.command("split-command", [])

	selection : Plugin.CommandBlockSelection
	selection = Plugin.command_block_selection({
		command,
		kaifile: Kaifile.optional_block(block),
	})
}
