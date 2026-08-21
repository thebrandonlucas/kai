import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Task as TaskCommand

TaskNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: NixBackend.locked_flake_templates,
		backend: NixBackend.backend.name,
		command: TaskCommand.command.name,
		renderer: TaskNix.renderer,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		run = Body.get_strings(context.config, "run") ? |_| {
			byte_offset: None,
			message: "validated task configuration is missing 'run'",
		}
		Plugin.renderer_validation(Plugin.validate_string_list(run, TaskCommand.run_rules("task")))?
		environment = match context.related_config {
			NoRelatedConfig => Err({ byte_offset: None, message: "task environment is required" })
			SelectedRelatedConfig({ block: _, config }) => Ok(config)
		}?
		pkgs = Body.get_strings(environment, "packages") ? |_| {
			byte_offset: None,
			message: "validated environment configuration is missing 'packages'",
		}
		Plugin.renderer_validation(Plugin.validate_string_list(pkgs, NixBackend.package_rules))?
		target = NixBackend.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported task platform" }
		Ok(
			Plugin.RenderResult.{
				actions: NixBackend.task_actions(run),
				outputs: [
					{
						name: "flake",
						text: NixBackend.render_dev_shell({ overlays: [], pkgs, system: target.system }),
					},
				],
				requests: [],
				requested_packages: pkgs,
			},
		)
	}
}
