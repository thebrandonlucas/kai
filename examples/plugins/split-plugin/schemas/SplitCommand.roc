# Example `command` interface provided by the split plugin.
import kai.Kaifile
import kai.Plugin

SplitCommand := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.unnamed_block({ header: "split", fields: [] })

	command : Plugin.Command
	command = Plugin.command("split-command", [])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_with_block({
		command,
		block: Kaifile.optional_block(block),
	})
}
