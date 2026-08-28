# - Implementations translate a command into backend operations.
# - Commands and backends do not depend on each other; implementations may depend on both.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Shell as ShellCommand
import EnvironmentNix
import ShellNixValidation

ShellNix := [].{
	shell_nix_actions = [NixBackend.flake_template].concat(NixBackend.lock_templates).concat([NixBackend.develop_template])
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: shell_nix_actions,
		backend: NixBackend.backend.name,
		command: ShellCommand.command.call.name,
		validator: ShellNixValidation.validator,
		renderer: ShellNix.renderer,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		pkgs = Plugin.validated_strings(context.config, ShellCommand.packages_field)?
		overlays = EnvironmentNix.extract_overlays(context.config)?
		EnvironmentNix.render_result(context, pkgs, overlays, "unsupported shell platform")
	}
}
