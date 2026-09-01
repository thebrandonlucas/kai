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
		flake_path = Plugin.workspace_path(input.workspace_root, "flake.nix")
		lock_path = Plugin.workspace_path(input.workspace_root, "flake.lock")
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: [],
				steps: [
					WriteFile({ contents: flake, path: flake_path }),
					NixBackend.run([
						"flake",
						"update",
						"--flake",
						"path:${input.workspace_root}",
						"--reference-lock-file",
						"kai.lock",
						"--output-lock-file",
						"kai.lock",
					]),
					NixBackend.run([
						"flake",
						"lock",
						"path:${input.workspace_root}",
						"--reference-lock-file",
						"kai.lock",
						"--output-lock-file",
						lock_path,
					]),
				],
			},
		)
	}
}
