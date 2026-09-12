# Kaifile block schema for an inline developer shell.
import kai.Kaifile
import kai.Plugin
import Environment

Shell := [].{
	environment_field = Kaifile.optional("environment", Identifier)
	packages_field = Kaifile.optional("packages", StringList)

	block : Plugin.Block
	block = Kaifile.unnamed_block({
		header: "shell",
		fields: [environment_field, packages_field, Environment.overlays_field],
	})
}
