# Nix implementation for rolling back the current NixOS host.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Rollback as RollbackCommand

RollbackNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: RollbackCommand.command_syntax.name,
		plan: RollbackNix.plan,
		validator: NoValidation,
	}

	plan : Plugin.CommandPlanningInput -> Try(
		Plugin.BackendCommandPlan,
		Plugin.BackendPlanningDiagnostic,
	)
	plan = |input| {
		if input.host.os != LINUX {
			return Err({ byte_offset: None, message: "rollback requires NixOS" })
		}
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: [],
				steps: [
					Confirm("Roll back this host to its previous NixOS generation?"),
					RunProgram({
						arguments: ["switch", "--rollback"],
						program: "nixos-rebuild",
					}),
				],
			},
		)
	}
}
