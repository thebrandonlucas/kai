import parser.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import commands.Deploy as DeployCommand
import commands.Shell as ShellCommand
import commands.Task as TaskCommand
import commands.Update as UpdateCommand
import commands.Workflow as WorkflowCommand
import implementations.BuildNix
import implementations.DeployNix
import implementations.ShellNix
import implementations.TaskNix
import implementations.UpdateNix
import implementations.WorkflowNix

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
		} else if command.name == BuildCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) => StdPlugin.select_build(config_text, DefaultBackend(backend), [backend.name], os)
				_ => StdPlugin.select_build(config_text, backend_choice, args, os)
			}
		} else if command.name == DeployCommand.command.name or command.name == DeployCommand.rollback_command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) => StdPlugin.select_deploy(config_text, DefaultBackend(backend), [backend.name], os, command.name)
				_ => StdPlugin.select_deploy(config_text, backend_choice, args, os, command.name)
			}
		} else if command.name == WorkflowCommand.command.name {
			match (backend_choice, args) {
				(ExplicitBackend(backend), []) => StdPlugin.select_workflow(config_text, DefaultBackend(backend), [backend.name], os)
				_ => StdPlugin.select_workflow(config_text, backend_choice, args, os)
			}
		} else if command.name == WorkflowCommand.ci_command.name {
			StdPlugin.select_named_workflow(config_text, backend_choice, "ci", os)
		} else {
			PluginApi.select_config(config_text, command, backend_choice, args, os, arch)
		}

	select_environment : Str, PluginApi.BackendChoice, List(Str), PluginApi.HostOs -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_environment = |config_text, backend_choice, args, os|
		match args {
			[environment] => {
				PluginApi.selector_validation(PluginApi.validate_text(environment, ShellCommand.environment_name_rules))?
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
			[task_name] => {
				PluginApi.selector_validation(PluginApi.validate_text(task_name, TaskCommand.name_rules))?
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
				failures = PluginApi.validate_text(environment, TaskCommand.environment_rules(task_name)).concat(
					PluginApi.validate_string_list(run, TaskCommand.run_rules("task '${task_name}'")),
				)
				PluginApi.selector_validation(failures)?
				{
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

	select_build : Str, PluginApi.BackendChoice, List(Str), PluginApi.HostOs -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_build = |config_text, backend_choice, args, os|
		match args {
			[artifact_name] => {
				PluginApi.selector_validation(PluginApi.validate_text(artifact_name, BuildCommand.artifact_name_rules))?
				build_block = match StdPlugin.select_with_backend_fallback(config_text, ["build", artifact_name], backend_choice, os)? {
					Missing => Err({ location: None, message: "missing build '${artifact_name}'" })
					Selected(block) => Ok(block)
					_ => Err({ location: None, message: "invalid build selection" })
				}?
				build_config = Body.parse(BuildCommand.body, build_block.body) ? |diagnostic| {
					location: At(PluginApi.translate_location(build_block, diagnostic.byte_offset)),
					message: Body.describe(diagnostic),
				}
				environment = Body.get_string(build_config, "environment") ? |_|
					{ location: None, message: "validated build '${artifact_name}' is missing 'environment'" }
				run = Body.get_strings(build_config, "run") ? |_|
					{ location: None, message: "validated build configuration is missing 'run'" }
				output = Body.get_string(build_config, "output") ? |_|
					{ location: None, message: "validated build configuration is missing 'output'" }
				failures = PluginApi.validate_text(environment, BuildCommand.environment_rules(artifact_name))
					.concat(PluginApi.validate_string_list(run, BuildCommand.run_rules))
					.concat(PluginApi.validate_text(output, BuildCommand.output_rules))
				PluginApi.selector_validation(failures)?
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

	select_deploy : Str, PluginApi.BackendChoice, List(Str), PluginApi.HostOs, Str -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_deploy = |config_text, backend_choice, args, os, command_name|
		match args {
			[deployment_name] => {
				PluginApi.selector_validation(PluginApi.validate_text(deployment_name, DeployCommand.name_rules))?
				match StdPlugin.select_with_backend_fallback(config_text, ["deploy", deployment_name], backend_choice, os)? {
					Missing => Err({ location: None, message: "missing deploy '${deployment_name}'" })
					Selected(block) => Ok(SelectedWithBody({ block, body: DeployCommand.body }))
					_ => Err({ location: None, message: "invalid deploy selection" })
				}
			}
			_ => Err({ location: None, message: "${command_name} requires exactly one deployment name" })
		}

	select_workflow : Str, PluginApi.BackendChoice, List(Str), PluginApi.HostOs -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_workflow = |config_text, backend_choice, args, os|
		match args {
			[workflow_name] => {
				PluginApi.selector_validation(PluginApi.validate_text(workflow_name, WorkflowCommand.name_rules))?
				StdPlugin.select_named_workflow(config_text, backend_choice, workflow_name, os)
			}
			_ => Err({ location: None, message: "workflow requires exactly one name" })
		}

	select_named_workflow : Str, PluginApi.BackendChoice, Str, PluginApi.HostOs -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_named_workflow = |config_text, backend_choice, workflow_name, os|
		match StdPlugin.select_with_backend_fallback(config_text, ["workflow", workflow_name], backend_choice, os)? {
			Missing => Err({ location: None, message: "missing workflow '${workflow_name}'" })
			Selected(block) => Ok(SelectedWithBody({ block, body: WorkflowCommand.body }))
			_ => Err({ location: None, message: "invalid workflow selection" })
		}

	select_with_backend_fallback : Str, List(Str), PluginApi.BackendChoice, PluginApi.HostOs -> Try(PluginApi.ConfigSelection, PluginApi.SelectorDiagnostic)
	select_with_backend_fallback = |config_text, header, backend_choice, os| {
		selection = PluginApi.select_config_header(config_text, header, backend_choice, os)?
		match (selection, backend_choice) {
			(Missing, ExplicitBackend(backend)) => PluginApi.select_config_header(config_text, header, DefaultBackend(backend), os)
			_ => Ok(selection)
		}
	}

	commands : List(PluginApi.Command)
	commands = [BuildCommand.command, DeployCommand.command, DeployCommand.rollback_command, ShellCommand.command, TaskCommand.command, UpdateCommand.command, WorkflowCommand.command, WorkflowCommand.ci_command]

	backends : List(PluginApi.Backend)
	backends = [NixBackend.backend]

	implementations : List(PluginApi.Implementation)
	implementations = [BuildNix.implementation, DeployNix.implementation, DeployNix.rollback_implementation, ShellNix.implementation, TaskNix.implementation, UpdateNix.implementation, WorkflowNix.implementation, WorkflowNix.ci_implementation]

	definition : PluginApi.Definition
	definition = PluginApi.Definition.{
		backends,
		commands,
		implementations,
		name: "std",
	}
}
