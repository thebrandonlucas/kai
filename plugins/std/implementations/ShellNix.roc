# An implementation for defining nix devShells
import kai.Plugin
import parser.Fields
import backends.Nix as NixBackend
import blocks.Environment as EnvironmentBlock
import blocks.Shell as ShellBlock
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
					field: ShellBlock.packages_field,
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
		referenced = EnvironmentNix.referenced_environment(input)?
		shell_packages = Fields.maybe_strings(
			input.command_fields,
			"packages",
		) ?? None
		shell_pkgs = match (referenced, shell_packages) {
			(None, None) =>
				return Err({
					byte_offset: None,
					message: "shell requires packages or an environment",
				})
			(_, Some(values)) => values
			(_, None) => []
		}
		(base_pkgs, base_overlays) = match referenced {
			None => ([], [])
			Some(environment) => (
				Plugin.validated_strings(
					environment,
					EnvironmentBlock.packages_field,
				)?,
				EnvironmentNix.extract_overlays(environment)?,
			)
		}
		pkgs = EnvironmentNix.append_unseen(shell_pkgs, base_pkgs)
		Plugin.implementation_validation(
			Plugin.validate_string_list(pkgs, NixBackend.package_rules),
		)?
		shell_overlays = EnvironmentNix.extract_overlays(input.command_fields)?
		overlays = EnvironmentNix.append_unseen(shell_overlays, base_overlays)
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
