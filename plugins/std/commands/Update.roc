# Shared `command` interface for updating project dependencies.
import kai.Kaifile
import kai.Plugin

Update := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.unnamed_block({ header: "update", fields: [] })

	command : Plugin.Command
	command = Plugin.command("update", [])

	selection : Plugin.CommandBlockSelection
	selection = Plugin.command_block_selection_with_backend_blocks({
		backend_blocks: RequireBackendSpecific,
		command,
		kaifile: Kaifile.optional_block(block),
	})
}
