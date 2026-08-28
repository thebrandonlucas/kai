import parser.Body
import kai.Kaifile
import kai.Plugin

Shell := [].{
	packages_field : Body.Field
	packages_field = Body.required("packages", StringList)

	fields = [packages_field]

	block : Plugin.KaifileBlock
	block = Kaifile.block({ header: "shell", fields })

	environment_block : Plugin.KaifileBlock
	environment_block = Kaifile.named_block({
		header: "environment <environment>",
		fields,
		name_rules: [NonemptyText("environment name must not be empty")],
	})

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("shell", [Plugin.optional_argument("environment")]),
		config: DirectOrNamedConfig({ lookup: QualifiedOnly, named: environment_block }),
		config_block: RequiredConfigBlock(block),
	}
}
