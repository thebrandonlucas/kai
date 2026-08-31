# An implementation for updating the underlying `flake.nix` files
import kai.Plugin
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
import EnvironmentNix
UpdateNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [NixBackend.flake_template].concat(NixBackend.update_lock_templates),
		backend: NixBackend.backend.name,
		command: UpdateCommand.command.name,
		plan: UpdateNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.ImplementationInput ->
			Try(
				Plugin.CommandPlan,
				Plugin.ImplementationDiagnostic,
			)
	plan = |input| {
		overlays = EnvironmentNix.all_overlays(input)?
		sources = EnvironmentNix.all_sources(input)?
		Ok(
			Plugin.CommandPlan.{
				actions: [],
				artifacts: [],
				outputs: [
					{
						name: "flake",
						text: NixBackend.render_update_flake(overlays, sources),
					},
				],
				prerequisite_commands: [],
				requested_packages: [],
			},
		)
	}
}
