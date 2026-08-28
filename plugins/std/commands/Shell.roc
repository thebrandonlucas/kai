# Shared `command` interface for developer shell packages and overlays
import kai.Kaifile
import kai.Plugin
import configs.EnvironmentConfig

# TODO: how to make this code more self documenting ie,
# I want to be able to know easily:
# a) what new kai commands and command call shape from this code, and
# b) what the corresponding Kaifile will look like from it
Shell := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.block({ header: "shell", fields: EnvironmentConfig.fields })

	command : Plugin.Command
	command = Plugin.command_with_backend_blocks({
		backend_blocks: RequireBackendSpecific,
		call: Plugin.call("shell", [Plugin.optional_argument("environment")]),
		kaifile: Kaifile.by_optional_argument({
			argument: "environment",
			when_omitted: block,
			when_provided: EnvironmentConfig.block,
		}),
	})
}
