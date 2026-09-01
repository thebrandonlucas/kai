# An implementation for defining nix devShells
import kai.Plugin
import backends.Nix as NixBackend
import blocks.Environment as EnvironmentBlock
import commands.Shell as ShellCommand
import EnvironmentNix

ShellNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: ShellCommand.command_syntax.name,
		validator: Validate({
			string_lists: [
				{
					field: EnvironmentBlock.packages_field,
					rules: NixBackend.package_rules,
				},
			],
			target: NoTargetValidation,
		}),
		plan: ShellNix.plan,
	}

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		pkgs = Plugin.validated_strings(
			input.command_fields,
			EnvironmentBlock.packages_field,
		)?
		overlays = EnvironmentNix.extract_overlays(input.command_fields)?
		flake = EnvironmentNix.render_flake(
			input,
			pkgs,
			overlays,
			Bool.False,
			"unsupported shell platform",
		)?
		flake_path = Plugin.workspace_path(input.workspace_root, "flake.nix")
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: pkgs,
				steps: [WriteFile({ contents: flake, path: flake_path })]
					.concat(NixBackend.lock_steps(input.workspace_root))
					.concat([
						NixBackend.run([
							"develop",
							"path:${input.workspace_root}#default",
							"--no-update-lock-file",
						]),
					]),
			},
		)
	}
}
