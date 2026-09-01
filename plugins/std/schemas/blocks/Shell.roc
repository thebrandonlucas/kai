# Kaifile block schema for an inline developer shell.
import kai.Kaifile
import kai.Plugin
import Environment

Shell := [].{
	block : Plugin.Block
	block = Kaifile.unnamed_block({
		header: "shell",
		fields: Environment.fields,
	})
}
