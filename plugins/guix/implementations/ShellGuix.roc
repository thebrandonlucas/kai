# An implementation of the `shell` command in Guix
import kai.Plugin
import backends.Guix as GuixBackend
import schemas.Shell as ShellCommand

ShellGuix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: GuixBackend.backend.name,
		command: ShellCommand.command_syntax.name,
		plan: ShellGuix.plan,
		validator: Validate({
			string_lists: [
				{
					field: ShellCommand.packages_field,
					rules: GuixBackend.package_rules,
				},
			],
			target: SupportedTargets({
				message: "unsupported Guix shell platform",
				supported: GuixBackend.supported_targets,
			}),
		}),
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
			ShellCommand.packages_field,
		)?
		Ok(
			Plugin.CommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: pkgs,
				steps: [
					RunProgram({
						arguments: ["shell", "--pure"].concat(pkgs),
						program: GuixBackend.backend.name,
					}),
				],
			},
		)
	}
}
