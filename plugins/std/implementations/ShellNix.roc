import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Shell as ShellCommand

ShellNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [NixBackend.flake_template].concat(NixBackend.lock_templates).concat([NixBackend.develop_template]),
		backend: NixBackend.backend.name,
		command: ShellCommand.command.name,
		renderer: ShellNix.renderer,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		match context.config_block {
			NoConfigBlock => Err({ byte_offset: None, message: "shell configuration is required" })
			SelectedConfigBlock(_) => Ok({})
		}?
		selected_target = NixBackend.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported shell platform" }
		pkgs = Body.get_strings(context.config, "packages") ? |_|
			{ byte_offset: None, message: "validated shell configuration is missing 'packages'" }
		maybe_overlays = Body.maybe_strings(context.config, "overlays") ? |_|
			{ byte_offset: None, message: "validated shell configuration has invalid 'overlays'" }
		overlays = match maybe_overlays {
			None => []
			Some(values) => values
		}
		failures = Plugin.validate_string_list(pkgs, NixBackend.package_rules).concat(
			Plugin.validate_string_list(overlays, NixBackend.overlay_rules),
		)
		Plugin.renderer_validation(failures)?
		Ok(ShellNix.render_result(pkgs, overlays, selected_target.system))
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
