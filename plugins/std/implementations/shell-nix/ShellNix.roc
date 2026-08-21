# - Implementations translate a command into backend operations.
# - Commands and backends do not depend on each other; implementations may depend on both.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Shell as ShellCommand
import ShellNixValidation

ShellNix := [].{
	shell_nix_actions = [NixBackend.flake_template].concat(NixBackend.lock_templates).concat([NixBackend.develop_template])
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: shell_nix_actions,
		backend: NixBackend.backend.name,
		command: ShellCommand.command.name,
		validator: ShellNixValidation.validator,
		renderer: ShellNix.renderer,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		pkgs = Plugin.validated_strings(context.config, ShellCommand.packages_field)?
		overlays = Plugin.validated_strings(context.config, ShellCommand.overlays_field)?
		system = Plugin.validated_target(context)?
		Ok(ShellNix.render_result(pkgs, overlays, system))
	}

	render_result : List(Str), List(Str), Str -> Plugin.RenderResult
	render_result = |pkgs, overlays, system|
		Plugin.RenderResult.{
			actions: [],
			outputs: [{ name: "flake", text: NixBackend.render_dev_shell({ overlays, pkgs, system }) }],
			requests: [],
			requested_packages: pkgs,
		}
}
