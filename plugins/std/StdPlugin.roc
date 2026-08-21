import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import commands.Shell as ShellCommand
import commands.Task as TaskCommand
import commands.Update as UpdateCommand
import commands.Workflow as WorkflowCommand
import implementations.BuildNix
import implementations.ShellNix
import implementations.TaskNix
import implementations.UpdateNix
import implementations.WorkflowNix

StdPlugin := [].{
	plugin : Plugin.RegistryDefinition
	plugin = {
		definition,
		select_config: StdPlugin.select_config,
	}

	select_config : Plugin.ConfigSelector
	select_config = |config_text, command, backend_choice, args, os, arch|
		if command.name == ShellCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) =>
					match Plugin.select_config_header(
						config_text,
						["environment", backend.name],
						DefaultBackend(backend),
						os,
					)? {
						Missing => Plugin.select_config(config_text, command, backend_choice, args, os, arch)
						Selected(block) => Ok(SelectedWithBody({ block, body: ShellCommand.environment_body }))
						_ => Err({ location: None, message: "invalid environment selection" })
					}
				_ =>
					if args.is_empty() {
						Plugin.select_config(config_text, command, backend_choice, args, os, arch)
					} else {
						StdPlugin.select_environment(config_text, backend_choice, args, os)
					}
				}
		} else if command.name == TaskCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) => StdPlugin.select_task(config_text, DefaultBackend(backend), [backend.name], os)
				_ => StdPlugin.select_task(config_text, backend_choice, args, os)
			}
		} else if command.name == BuildCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) => StdPlugin.select_build(config_text, DefaultBackend(backend), [backend.name], os)
				_ => StdPlugin.select_build(config_text, backend_choice, args, os)
			}
		} else if command.name == WorkflowCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) => StdPlugin.select_workflow(config_text, DefaultBackend(backend), [backend.name], os)
				_ => StdPlugin.select_workflow(config_text, backend_choice, args, os)
			}
		} else {
			Plugin.select_config(config_text, command, backend_choice, args, os, arch)
		}

	select_environment : Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_environment = |config_text, backend_choice, args, os|
		match args {
			[environment] => {
				Plugin.selector_validation(Plugin.validate_text(environment, ShellCommand.environment_name_rules))?
				match Plugin.select_config_header(config_text, ["environment", environment], backend_choice, os)? {
					Missing => Err({ location: None, message: "missing environment '${environment}'" })
					Selected(block) => Ok(SelectedWithBody({ block, body: ShellCommand.environment_body }))
					_ => Err({ location: None, message: "invalid environment selection" })
				}
			}
			_ => Err({ location: None, message: "shell accepts at most one environment name" })
		}

	select_task : Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_task = |config_text, backend_choice, args, os|
		match args {
			[task_name] => {
				Plugin.selector_validation(Plugin.validate_text(task_name, TaskCommand.name_rules))?
				task_block = match Plugin.select_config_header(config_text, ["task", task_name], backend_choice, os)? {
					Missing => Err({ location: None, message: "missing task '${task_name}'" })
					Selected(block) => Ok(block)
					_ => Err({ location: None, message: "invalid task selection" })
				}?
				task_config = Body.parse(TaskCommand.body, task_block.body) ? |diagnostic| {
					location: At(Plugin.translate_location(task_block, diagnostic.byte_offset)),
					message: Body.describe(diagnostic),
				}
				environment = Body.get_string(task_config, "environment") ? |_|
					{ location: None, message: "validated task '${task_name}' is missing 'environment'" }
				run = Body.get_strings(task_config, "run") ? |_|
					{ location: None, message: "validated task '${task_name}' is missing 'run'" }
				failures = Plugin.validate_text(environment, TaskCommand.environment_rules(task_name)).concat(
					Plugin.validate_string_list(run, TaskCommand.run_rules("task '${task_name}'")),
				)
				Plugin.selector_validation(failures)?
				{
					environment_block = match Plugin.select_config_header(config_text, ["environment", environment], backend_choice, os)? {
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

	select_build : Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_build = |config_text, backend_choice, args, os|
		match args {
			[artifact_name] => {
				Plugin.selector_validation(Plugin.validate_text(artifact_name, BuildCommand.artifact_name_rules))?
				build_block = match StdPlugin.select_with_backend_fallback(config_text, ["build", artifact_name], backend_choice, os)? {
					Missing => Err({ location: None, message: "missing build '${artifact_name}'" })
					Selected(block) => Ok(block)
					_ => Err({ location: None, message: "invalid build selection" })
				}?
				build_config = Body.parse(BuildCommand.body, build_block.body) ? |diagnostic| {
					location: At(Plugin.translate_location(build_block, diagnostic.byte_offset)),
					message: Body.describe(diagnostic),
				}
				environment = Body.get_string(build_config, "environment") ? |_|
					{ location: None, message: "validated build '${artifact_name}' is missing 'environment'" }
				run = Body.get_strings(build_config, "run") ? |_|
					{ location: None, message: "validated build configuration is missing 'run'" }
				output = Body.get_string(build_config, "output") ? |_|
					{ location: None, message: "validated build configuration is missing 'output'" }
				failures = Plugin.validate_text(environment, BuildCommand.environment_rules(artifact_name))
					.concat(Plugin.validate_string_list(run, BuildCommand.run_rules))
					.concat(Plugin.validate_text(output, BuildCommand.output_rules))
				Plugin.selector_validation(failures)?
				{
					environment_block = match StdPlugin.select_with_backend_fallback(config_text, ["environment", environment], backend_choice, os)? {
						Missing => Err({ location: None, message: "missing environment '${environment}'" })
						Selected(block) => Ok(block)
						_ => Err({ location: None, message: "invalid environment selection" })
					}?
					Ok(
						SelectedWithRelated({
							block: build_block,
							body: BuildCommand.body,
							related_block: environment_block,
							related_body: ShellCommand.environment_body,
						}),
					)
				}
			}
			_ => Err({ location: None, message: "build requires exactly one artifact name" })
		}

	select_workflow : Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_workflow = |config_text, backend_choice, args, os|
		match args {
			[workflow_name] => {
				Plugin.selector_validation(Plugin.validate_text(workflow_name, WorkflowCommand.name_rules))?
				StdPlugin.select_named_workflow(config_text, backend_choice, workflow_name, os)
			}
			_ => Err({ location: None, message: "workflow requires exactly one name" })
		}

	select_named_workflow : Str, Plugin.BackendChoice, Str, Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_named_workflow = |config_text, backend_choice, workflow_name, os|
		match StdPlugin.select_with_backend_fallback(config_text, ["workflow", workflow_name], backend_choice, os)? {
			Missing => Err({ location: None, message: "missing workflow '${workflow_name}'" })
			Selected(block) => Ok(SelectedWithBody({ block, body: WorkflowCommand.body }))
			_ => Err({ location: None, message: "invalid workflow selection" })
		}

	select_with_backend_fallback : Str, List(Str), Plugin.BackendChoice, Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_with_backend_fallback = |config_text, header, backend_choice, os| {
		selection = Plugin.select_config_header(config_text, header, backend_choice, os)?
		match (selection, backend_choice) {
			(Missing, ExplicitBackend(backend)) => Plugin.select_config_header(config_text, header, DefaultBackend(backend), os)
			_ => Ok(selection)
		}
	}

	commands : List(Plugin.Command)
	commands = [
		BuildCommand.command,
		ShellCommand.command,
		TaskCommand.command,
		UpdateCommand.command,
		WorkflowCommand.command,
	]

	backends : List(Plugin.Backend)
	backends = [NixBackend.backend]

	implementations : List(Plugin.Implementation)
	implementations = [BuildNix.implementation, ShellNix.implementation, TaskNix.implementation, UpdateNix.implementation, WorkflowNix.implementation]

	definition : Plugin.Definition
	definition = Plugin.Definition.{
		backends,
		commands,
		implementations,
		name: "std",
	}
}
