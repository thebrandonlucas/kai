# An implementation for defining nix devShells
import kai.Plugin
import backends.Nix as NixBackend
import commands.Shell as ShellCommand
import configs.EnvironmentConfig
import EnvironmentNix

ShellNix := [].{
	shell_nix_actions = [NixBackend.flake_template]
		.concat(NixBackend.lock_templates)
		.concat([NixBackend.develop_template])
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: shell_nix_actions,
		backend: NixBackend.backend.name,
		command: ShellCommand.command.name,
		validator: Validate({
			string_lists: [
				{
					field: EnvironmentConfig.packages_field,
					rules: NixBackend.package_rules,
				},
			],
			target: NoTargetValidation,
		}),
		plan: ShellNix.plan,
	}

	plan :
		Plugin.ImplementationInput ->
			Try(
				Plugin.CommandPlan,
				Plugin.ImplementationDiagnostic,
			)
	plan = |input| {
		pkgs = Plugin.validated_strings(
			input.command_fields,
			EnvironmentConfig.packages_field,
		)?
		overlays = EnvironmentNix.extract_overlays(input.command_fields)?
		EnvironmentNix.command_plan(
			input,
			pkgs,
			overlays,
			"unsupported shell platform",
		)
	}
}
