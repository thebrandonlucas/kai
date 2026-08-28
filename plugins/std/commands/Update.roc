# Shared `command` interface for updating project dependencies.
import kai.Kaifile
import kai.Plugin

Update := [].{
	block : Plugin.KaifileBlock
	block = Kaifile.block({ header: "update", fields: [] })

	command : Plugin.Command
	command = Plugin.command_with_backend_blocks({
		backend_blocks: RequireBackendSpecific,
		call: Plugin.call("update", []),
		kaifile: Kaifile.optional(block),
	})
}
