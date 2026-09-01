# Kaifile block schema for a named Guix environment.
import kai.Kaifile
import kai.Plugin

Environment := [].{
	packages_field : Plugin.KaifileField
	packages_field = Kaifile.required("packages", StringList)

	fields = [packages_field]

	block : Plugin.Block
	block = Kaifile.named_block({
		header: "environment <environment>",
		fields,
		name_rules: [NonemptyText("environment name must not be empty")],
	})
}
