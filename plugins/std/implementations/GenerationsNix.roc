# Nix implementation for listing system generations.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Generations as GenerationsCommand

GenerationsNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: GenerationsCommand.command_syntax.name,
		plan: GenerationsNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |_|
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: [],
				steps: [
					RunProgram({
						arguments: ["list-generations"],
						program: "nixos-rebuild",
					}),
				],
			},
		)
}
