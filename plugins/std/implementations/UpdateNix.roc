# An implementation for updating the underlying `flake.nix` files
import kai.Plugin
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
import EnvironmentNix
UpdateNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: UpdateCommand.command_syntax.name,
		plan: UpdateNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		overlays = EnvironmentNix.all_overlays(input)?
		sources = EnvironmentNix.all_sources(input)?
		flake = NixBackend.render_update_flake(overlays, sources)
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: [],
				steps: [NixBackend.write_flake_step(flake)].concat(
					NixBackend.update_lock_steps,
				),
			},
		)
	}
}
