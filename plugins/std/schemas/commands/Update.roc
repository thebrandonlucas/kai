# Shared `command` interface for updating project dependencies.
import kai.Plugin

Update := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax("update", [])

	command : Plugin.Command
	command = Plugin.command_only(command_syntax)
}
