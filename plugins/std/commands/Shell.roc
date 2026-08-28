# Shared `command` interface for developer shell packages and overlays
import parser.Body
import kai.Kaifile
import kai.Plugin

# TODO: how to make this code more self documenting ie,
# I want to be able to know easily:
# a) what new kai commands and command call shape from this code, and
# b) what the corresponding Kaifile will look like from it
Shell := [].{
	packages_field : Body.Field
	packages_field = Body.required("packages", StringList)

	overlays_field : Body.Field
	overlays_field = Body.optional("overlays", StringList)

	fields = [packages_field, overlays_field]

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
