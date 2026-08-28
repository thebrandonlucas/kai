import kai.Kaifile
import kai.Plugin

Compose := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.block({ header: "compose", fields: [] })

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("compose", [Plugin.required_argument("machine")]),
		config: DirectConfig(QualifiedThenUnqualified),
		config_block: OptionalConfigBlock(block),
	}
}
