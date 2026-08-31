# Shared `command` interface for developer shell packages and overlays
import kai.Kaifile
import kai.Plugin
import EnvironmentConfig

# TODO: how to make this code more self documenting ie,
# I want to be able to know easily:
# a) what new kai commands and command shape come from this code, and
# b) what the corresponding Kaifile will look like from it
Shell := [].{
	block : Plugin.Block
	block = Kaifile.unnamed_block({
		header: "shell",
		fields: EnvironmentConfig.fields,
	})

	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"shell",
		[Plugin.optional_argument("environment")],
	)

	command : Plugin.Command
	command = Plugin.command_with_required_backend_block({
		syntax: command_syntax,
		block: Kaifile.by_optional_argument({
			argument: "environment",
			when_omitted: block,
			when_provided: EnvironmentConfig.block,
		}),
	})
}
