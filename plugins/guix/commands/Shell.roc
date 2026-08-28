# `command` definition for Guix
import kai.Kaifile
import kai.Plugin

Shell := [].{
	packages_field : Plugin.KaifileField
	packages_field = Kaifile.required("packages", StringList)

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
	command = Plugin.command_with_backend_blocks({
		backend_blocks: RequireBackendSpecific,
		call: Plugin.call("shell", [Plugin.optional_argument("environment")]),
		kaifile: Kaifile.by_optional_argument({
			argument: "environment",
			when_omitted: block,
			when_provided: environment_block,
		}),
	})
}
