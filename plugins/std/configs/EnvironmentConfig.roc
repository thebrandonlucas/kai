# Shared configuration schema for developer environments.
import parser.Body
import kai.Kaifile
import kai.Plugin

EnvironmentConfig := [].{
	packages_field : Body.Field
	packages_field = Body.required("packages", StringList)

	overlays_field : Body.Field
	overlays_field = Body.optional("overlays", StringList)

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
