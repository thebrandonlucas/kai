# Shared block schema for developer environments.
import kai.Kaifile
import kai.Plugin

EnvironmentConfig := [].{
	packages_field : Plugin.KaifileField
	packages_field = Kaifile.required("packages", StringList)

	overlays_field : Plugin.KaifileField
	overlays_field = Kaifile.optional("overlays", StringList)

	fields = [packages_field, overlays_field]

	name_rules : List(Plugin.TextRule)
	name_rules = [NonemptyText("environment name must not be empty")]

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({
		header: "environment <environment>",
		fields,
		name_rules,
	})
}
