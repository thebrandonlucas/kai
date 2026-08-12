import parser.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Shell as ShellCommand
import commands.Task as TaskCommand
import commands.Update as UpdateCommand
import implementations.ShellNix
import implementations.TaskNix
import implementations.UpdateNix

StdPlugin := [].{
	plugin : PluginApi.RegistryDefinition
	plugin = {
		definition,
		select_config: StdPlugin.select_config,
	}

	select_config : PluginApi.ConfigSelector
	select_config = |config_text, command, backend_choice, args, os, arch|
		if command.name == ShellCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) =>
					match PluginApi.select_config_header(config_text, ["environment", backend.name], DefaultBackend(backend), os)? {
						Missing => PluginApi.select_config(config_text, command, backend_choice, args, os, arch)
						Selected(block) => Ok(SelectedWithBody({ block, body: ShellCommand.environment_body }))
						_ => Err({ location: None, message: "invalid environment selection" })
					}
				_ =>
					if args.is_empty() {
						PluginApi.select_config(config_text, command, backend_choice, args, os, arch)
					} else {
						StdPlugin.select_environment(config_text, backend_choice, args, os)
					}
				}
		} else if command.name == TaskCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) => StdPlugin.select_task(config_text, DefaultBackend(backend), [backend.name], os)
				_ => StdPlugin.select_task(config_text, backend_choice, args, os)
			}
		} else {
			PluginApi.select_config(config_text, command, backend_choice, args, os, arch)
		}

	select_environment : Str, PluginApi.BackendChoice, List(Str), PluginApi.HostOs -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_environment = |config_text, backend_choice, args, os|
		match args {
			[environment] =>
				if environment.is_empty() {
					Err({ location: None, message: "environment name must not be empty" })
				} else {
					match PluginApi.select_config_header(config_text, ["environment", environment], backend_choice, os)? {
						Missing => Err({ location: None, message: "missing environment '${environment}'" })
						Selected(block) => Ok(SelectedWithBody({ block, body: ShellCommand.environment_body }))
						_ => Err({ location: None, message: "invalid environment selection" })
					}
				}
			_ => Err({ location: None, message: "shell accepts at most one environment name" })
		}

	select_task : Str, PluginApi.BackendChoice, List(Str), PluginApi.HostOs -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_task = |config_text, backend_choice, args, os|
		match args {
			[task_name] =>
				if task_name.is_empty() {
					Err({ location: None, message: "task name must not be empty" })
				} else {
					task_block = match PluginApi.select_config_header(config_text, ["task", task_name], backend_choice, os)? {
						Missing => Err({ location: None, message: "missing task '${task_name}'" })
						Selected(block) => Ok(block)
						_ => Err({ location: None, message: "invalid task selection" })
					}?
					task_config = Body.parse(TaskCommand.body, task_block.body) ? |diagnostic| {
						location: At(PluginApi.translate_location(task_block, diagnostic.byte_offset)),
						message: Body.describe(diagnostic),
					}
					environment = Body.get_string(task_config, "environment") ? |_|
						{ location: None, message: "validated task '${task_name}' is missing 'environment'" }
					run = Body.get_strings(task_config, "run") ? |_|
						{ location: None, message: "validated task '${task_name}' is missing 'run'" }
					if environment.is_empty() {
						Err({ location: None, message: "task '${task_name}' environment name must not be empty" })
					} else if run.is_empty() {
						Err({ location: None, message: "task '${task_name}' run list must not be empty" })
					} else if (run.first() ?? "").is_empty() {
						Err({ location: None, message: "task '${task_name}' run program must not be empty" })
					} else {
						environment_block = match PluginApi.select_config_header(config_text, ["environment", environment], backend_choice, os)? {
							Missing => Err({ location: None, message: "missing environment '${environment}'" })
							Selected(block) => Ok(block)
							_ => Err({ location: None, message: "invalid environment selection" })
						}?
						Ok(
							SelectedWithRelated({
								block: task_block,
								body: TaskCommand.body,
								related_block: environment_block,
								related_body: ShellCommand.environment_body,
							}),
						)
					}
				}
			_ => Err({ location: None, message: "run requires exactly one task name" })
		}

	commands : List(PluginApi.Command)
	commands = [ShellCommand.command, TaskCommand.command, UpdateCommand.command]

	backends : List(PluginApi.Backend)
	backends = [NixBackend.backend]

	implementations : List(PluginApi.Implementation)
	implementations = [ShellNix.implementation, TaskNix.implementation, UpdateNix.implementation]

	definition : PluginApi.Definition
	definition = PluginApi.Definition.{
		backends,
		commands,
		implementations,
		name: "std",
	}
}
