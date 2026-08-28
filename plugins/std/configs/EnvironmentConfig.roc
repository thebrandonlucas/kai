# Shared configuration schema for developer environments.
import parser.Fields
import kai.Kaifile
import kai.Plugin

EnvironmentConfig := [].{
	packages_field : Fields.Field
	packages_field = Fields.required("packages", StringList)

	overlays_field : Fields.Field
	overlays_field = Fields.optional("overlays", StringList)

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
