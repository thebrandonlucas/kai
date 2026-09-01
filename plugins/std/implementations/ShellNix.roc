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
		command_plan = EnvironmentNix.command_plan(
			input,
			pkgs,
			overlays,
			"unsupported shell platform",
		)?
		Ok({
			..command_plan,
			steps: command_plan.steps
				.concat(NixBackend.lock_steps)
				.concat([NixBackend.develop_step]),
		})
	}
}
