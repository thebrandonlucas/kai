# Shared `command` interface for developer shell packages and overlays
import kai.Kaifile
import kai.Plugin
import configs.EnvironmentConfig

# TODO: how to make this code more self documenting ie,
# I want to be able to know easily:
# a) what new kai commands and command shape come from this code, and
# b) what the corresponding Kaifile will look like from it
Shell := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.unnamed_block({
		header: "shell",
		fields: EnvironmentConfig.fields,
	})

	command : Plugin.Command
	command = Plugin.command("shell", [Plugin.optional_argument("environment")])

	selection : Plugin.CommandBlockSelection
	selection = Plugin.command_block_selection_with_backend_blocks({
		backend_blocks: RequireBackendSpecific,
		command,
		kaifile: Kaifile.by_optional_argument({
			argument: "environment",
			when_omitted: block,
			when_provided: EnvironmentConfig.block,
		}),
	})
}
