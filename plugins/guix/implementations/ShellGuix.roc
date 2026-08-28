import kai.Plugin
import backends.Guix as GuixBackend
import commands.Shell as ShellCommand

ShellGuix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: GuixBackend.backend.name,
		command: ShellCommand.command.call.name,
		renderer: ShellGuix.renderer,
		validator: Validate({
			string_lists: [{ field: ShellCommand.packages_field, rules: GuixBackend.package_rules }],
			target: SupportedTargets({
				message: "unsupported Guix shell platform",
				supported: GuixBackend.supported_targets,
			}),
		}),
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		pkgs = Plugin.validated_strings(context.config, ShellCommand.packages_field)?
		Ok(
			Plugin.RenderResult.{
				actions: [
					Exec({
						args: ["shell", "--pure"].concat(pkgs),
						command: GuixBackend.backend.name,
					}),
				],
				artifacts: [],
				outputs: [],
				requests: [],
				requested_packages: pkgs,
			},
		)
	}
}
