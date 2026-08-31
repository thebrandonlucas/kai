# `command` definition for Guix
import kai.Kaifile
import kai.Plugin

Shell := [].{
	packages_field : Plugin.KaifileField
	packages_field = Kaifile.required("packages", StringList)

	fields = [packages_field]

	block : Plugin.KaifileBlock
	block = Kaifile.unnamed_block({ header: "shell", fields })

	environment_block : Plugin.KaifileBlock
	environment_block = Kaifile.named_block({
		header: "environment <environment>",
		fields,
		name_rules: [NonemptyText("environment name must not be empty")],
	})

	command : Plugin.Command
	command = Plugin.command("shell", [Plugin.optional_argument("environment")])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_with_required_backend_block({
		command,
		block: Kaifile.by_optional_argument({
			argument: "environment",
			when_omitted: block,
			when_provided: environment_block,
		}),
	})
}
