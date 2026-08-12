import parser.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Task as TaskCommand
import ShellNix

TaskNix := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: ShellNix.prepare_actions,
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
		TaskNix.validate_run(run)?
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
		rendered = ShellNix.render_result(pkgs, target.system)
		Ok(
			PluginApi.RenderResult.{
				actions: [
					Exec({
						args: [
							"develop",
							"path:.kai#default",
							"--no-update-lock-file",
							"--command",
						].concat(run),
						command: NixBackend.backend.name,
					}),
				],
				outputs: rendered.outputs,
				requested_packages: rendered.requested_packages,
			},
		)
	}

	validate_run : List(Str) -> Try({}, PluginApi.RendererDiagnostic)
	validate_run = |run|
		match run {
			[] => Err({ byte_offset: None, message: "task run list must not be empty" })
			[program, ..] =>
				if program.is_empty() {
					Err({ byte_offset: None, message: "task run program must not be empty" })
				} else {
					Ok({})
				}
			}
}
