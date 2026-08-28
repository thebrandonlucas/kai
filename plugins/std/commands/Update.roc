# Shared `command` interface for updating project dependencies.
import kai.Kaifile
import kai.Plugin

Update := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.block({ header: "update", fields: [] })

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("update", []),
		config: DirectConfig(QualifiedOnly),
		config_block: OptionalConfigBlock(block),
	}
}
