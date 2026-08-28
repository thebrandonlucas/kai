# Example `command` interface provided by the split plugin.
import kai.Kaifile
import kai.Plugin

SplitCommand := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.block({ header: "split", fields: [] })

	command : Plugin.Command
	command = Plugin.command({
		call: Plugin.call("split-command", []),
		kaifile: Kaifile.optional(block),
	})
}
