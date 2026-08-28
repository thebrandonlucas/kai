# Example `command` interface provided by the split plugin.
import kai.Kaifile
import kai.Plugin

SplitCommand := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.block({ header: "split", fields: [] })

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("split-command", []),
		config: DirectConfig(QualifiedThenUnqualified),
		config_block: OptionalConfigBlock(block),
	}
}
