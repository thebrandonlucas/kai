import parser.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Task as TaskCommand
import ShellNix

TaskNix := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: NixBackend.locked_flake_templates,
		backend: NixBackend.backend.name,
		command: TaskCommand.command.name,
		renderer: TaskNix.renderer,
	}

	renderer : PluginApi.Renderer
	renderer = |context| {
		run = Body.get_strings(context.config, "run") ? |_| {
			byte_offset: None,
			message: "validated task configuration is missing 'run'",
		}
		PluginApi.renderer_validation(PluginApi.validate_string_list(run, TaskCommand.run_rules("task")))?
		environment = match context.related_config {
			NoRelatedConfig => Err({ byte_offset: None, message: "task environment is required" })
			SelectedRelatedConfig({ block: _, config }) => Ok(config)
		}?
		pkgs = Body.get_strings(environment, "packages") ? |_| {
			byte_offset: None,
			message: "validated environment configuration is missing 'packages'",
		}
		ShellNix.validate_packages(pkgs)?
		target = ShellNix.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported task platform" }
		rendered = ShellNix.render_result(pkgs, [], target.system)
		Ok(
			PluginApi.RenderResult.{
				actions: NixBackend.task_actions(run),
				outputs: rendered.outputs,
				requested_packages: rendered.requested_packages,
			},
		)
	}
}
