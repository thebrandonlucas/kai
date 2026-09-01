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

	render_update_flake = |overlays, sources|
		Str.join_with(
			["{", "  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";"]
				.concat(NixBackend.input_lines(overlays))
				.concat(NixBackend.source_input_lines(sources))
				.concat(["  outputs = _: {};", "}"]),
			"\n",
		)

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		overlays = EnvironmentNix.all_overlays(input)?
		sources = EnvironmentNix.all_sources(input)?
		flake = UpdateNix.render_update_flake(overlays, sources)
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
