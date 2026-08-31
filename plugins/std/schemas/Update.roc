# Shared `command` interface for updating project dependencies.
import kai.Plugin

Update := [].{
	command : Plugin.Command
	command = Plugin.command("update", [])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_only(command)
}
