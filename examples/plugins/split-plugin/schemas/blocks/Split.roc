# Example Kaifile block schema provided by the split plugin.
import kai.Kaifile
import kai.Plugin

Split := [].{
	block : Plugin.Block
	block = Kaifile.unnamed_block({ header: "split", fields: [] })
}
