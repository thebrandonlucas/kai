# An implementation for defining nix devShells
import kai.Plugin
import backends.Nix as NixBackend
import commands.Shell as ShellCommand
import EnvironmentNix

ShellNix := [].{
	shell_nix_actions = [NixBackend.flake_template]
		.concat(NixBackend.lock_templates)
		.concat([NixBackend.develop_template])
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: shell_nix_actions,
		backend: NixBackend.backend.name,
		command: ShellCommand.command.call.name,
		validator: Validate({
			string_lists: [
				{
					field: ShellCommand.packages_field,
					rules: NixBackend.package_rules,
				},
			],
			target: NoTargetValidation,
		}),
		renderer: ShellNix.renderer,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		pkgs = Plugin.validated_strings(context.config, ShellCommand.packages_field)?
		overlays = EnvironmentNix.extract_overlays(context.config)?
		EnvironmentNix.render_result(
			context,
			pkgs,
			overlays,
			"unsupported shell platform",
		)
	}
}
