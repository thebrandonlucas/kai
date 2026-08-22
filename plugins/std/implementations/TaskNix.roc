import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Task as TaskCommand
import EnvironmentNix

TaskNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [NixBackend.flake_template].concat(NixBackend.lock_templates),
		backend: NixBackend.backend.name,
		command: TaskCommand.command.name,
		renderer: TaskNix.renderer,
		validator: NoValidation,
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
		overlays = EnvironmentNix.extract_overlays(environment)?
		result = EnvironmentNix.render_result(context, pkgs, overlays, "unsupported task platform")?
		Ok({ ..result, actions: NixBackend.develop_command_actions(run) })
	}
}
