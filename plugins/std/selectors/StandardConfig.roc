import parser.Body
import kai.Plugin

StandardConfig := [].{
	BackendLookup : [QualifiedOnly, QualifiedThenUnqualified]

	ShellSelector := {
		environment_body : Body.Shape,
		environment_name_rules : List(Plugin.TextRule),
	}

	TaskSelector := {
		body : Body.Shape,
		environment_body : Body.Shape,
		environment_rules : Str -> List(Plugin.TextRule),
		name_rules : List(Plugin.TextRule),
		run_rules : Str -> List(Plugin.StringListRule),
	}

	BuildSelector := {
		artifact_name_rules : List(Plugin.TextRule),
		body : Body.Shape,
		environment_body : Body.Shape,
		environment_rules : Str -> List(Plugin.TextRule),
		output_rules : List(Plugin.TextRule),
		run_rules : List(Plugin.StringListRule),
	}

	WorkflowSelector := {
		body : Body.Shape,
		name_rules : List(Plugin.TextRule),
	}

	select_shell : ShellSelector, Str, Plugin.Command, Plugin.BackendChoice, List(Str), Plugin.HostOs, Plugin.HostArch -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_shell = |selector, config_text, command, backend_choice, args, os, arch|
		match (backend_choice, args) {
			(ExplicitBackend(backend), []) =>
				match Plugin.select_config_header(
					config_text,
					["environment", backend.name],
					DefaultBackend(backend),
					os,
				)? {
					Missing => Plugin.select_config(config_text, command, backend_choice, args, os, arch)
					Selected(block) => Ok(SelectedWithBody({ block, body: selector.environment_body }))
					_ => Err({ location: None, message: "invalid environment selection" })
				}
			_ =>
				if args.is_empty() {
					Plugin.select_config(config_text, command, backend_choice, args, os, arch)
				} else {
					StandardConfig.select_environment(selector, config_text, backend_choice, args, os)
				}
			}

	select_environment : ShellSelector, Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_environment = |selector, config_text, backend_choice, args, os|
		match args {
			[environment] => {
				Plugin.selector_validation(Plugin.validate_text(environment, selector.environment_name_rules))?
				block = StandardConfig.select_named_block(
					config_text,
					["environment", environment],
					backend_choice,
					os,
					QualifiedOnly,
					"missing environment '${environment}'",
					"invalid environment selection",
				)?
				Ok(SelectedWithBody({ block, body: selector.environment_body }))
			}
			_ => Err({ location: None, message: "shell accepts at most one environment name" })
		}

	select_task : TaskSelector, Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_task = |selector, config_text, backend_choice, args, os| {
		normalized = StandardConfig.normalize_backend_name(backend_choice, args)
		match normalized.args {
			[task_name] => {
				Plugin.selector_validation(Plugin.validate_text(task_name, selector.name_rules))?
				task_block = StandardConfig.select_named_block(
					config_text,
					["task", task_name],
					normalized.backend_choice,
					os,
					QualifiedOnly,
					"missing task '${task_name}'",
					"invalid task selection",
				)?
				task_config = StandardConfig.parse_body(selector.body, task_block)?
				environment = Body.get_string(task_config, "environment") ? |_|
					{ location: None, message: "validated task '${task_name}' is missing 'environment'" }
				run = Body.get_strings(task_config, "run") ? |_|
					{ location: None, message: "validated task '${task_name}' is missing 'run'" }
				environment_rules = selector.environment_rules
				run_rules = selector.run_rules
				failures = Plugin.validate_text(environment, environment_rules(task_name)).concat(
					Plugin.validate_string_list(run, run_rules("task '${task_name}'")),
				)
				Plugin.selector_validation(failures)?
				environment_block = StandardConfig.select_named_block(
					config_text,
					["environment", environment],
					normalized.backend_choice,
					os,
					QualifiedOnly,
					"missing environment '${environment}'",
					"invalid environment selection",
				)?
				Ok(
					SelectedWithRelated({
						block: task_block,
						body: selector.body,
						related_block: environment_block,
						related_body: selector.environment_body,
					}),
				)
			}
			_ => Err({ location: None, message: "run requires exactly one task name" })
		}
	}

	select_build : BuildSelector, Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_build = |selector, config_text, backend_choice, args, os| {
		normalized = StandardConfig.normalize_backend_name(backend_choice, args)
		match normalized.args {
			[artifact_name] => {
				Plugin.selector_validation(Plugin.validate_text(artifact_name, selector.artifact_name_rules))?
				build_block = StandardConfig.select_named_block(
					config_text,
					["build", artifact_name],
					normalized.backend_choice,
					os,
					QualifiedThenUnqualified,
					"missing build '${artifact_name}'",
					"invalid build selection",
				)?
				build_config = StandardConfig.parse_body(selector.body, build_block)?
				environment = Body.get_string(build_config, "environment") ? |_|
					{ location: None, message: "validated build '${artifact_name}' is missing 'environment'" }
				run = Body.get_strings(build_config, "run") ? |_|
					{ location: None, message: "validated build configuration is missing 'run'" }
				output = Body.get_string(build_config, "output") ? |_|
					{ location: None, message: "validated build configuration is missing 'output'" }
				environment_rules = selector.environment_rules
				failures = Plugin.validate_text(environment, environment_rules(artifact_name))
					.concat(Plugin.validate_string_list(run, selector.run_rules))
					.concat(Plugin.validate_text(output, selector.output_rules))
				Plugin.selector_validation(failures)?
				environment_block = StandardConfig.select_named_block(
					config_text,
					["environment", environment],
					normalized.backend_choice,
					os,
					QualifiedThenUnqualified,
					"missing environment '${environment}'",
					"invalid environment selection",
				)?
				Ok(
					SelectedWithRelated({
						block: build_block,
						body: selector.body,
						related_block: environment_block,
						related_body: selector.environment_body,
					}),
				)
			}
			_ => Err({ location: None, message: "build requires exactly one artifact name" })
		}
	}

	select_workflow : WorkflowSelector, Str, Plugin.BackendChoice, List(Str), Plugin.HostOs -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_workflow = |selector, config_text, backend_choice, args, os| {
		normalized = StandardConfig.normalize_backend_name(backend_choice, args)
		match normalized.args {
			[workflow_name] => {
				Plugin.selector_validation(Plugin.validate_text(workflow_name, selector.name_rules))?
				block = StandardConfig.select_named_block(
					config_text,
					["workflow", workflow_name],
					normalized.backend_choice,
					os,
					QualifiedThenUnqualified,
					"missing workflow '${workflow_name}'",
					"invalid workflow selection",
				)?
				Ok(SelectedWithBody({ block, body: selector.body }))
			}
			_ => Err({ location: None, message: "workflow requires exactly one name" })
		}
	}

	select_named_block : Str, List(Str), Plugin.BackendChoice, Plugin.HostOs, BackendLookup, Str, Str -> Try(Plugin.LocatedConfigBlock, Plugin.SelectorDiagnostic)
	select_named_block = |config_text, header, backend_choice, os, lookup, missing_message, invalid_message|
		match StandardConfig.select_with_backend_fallback(config_text, header, backend_choice, os, lookup)? {
			Missing => Err({ location: None, message: missing_message })
			Selected(block) => Ok(block)
			_ => Err({ location: None, message: invalid_message })
		}

	select_with_backend_fallback : Str, List(Str), Plugin.BackendChoice, Plugin.HostOs, BackendLookup -> Try(Plugin.ConfigSelection, Plugin.SelectorDiagnostic)
	select_with_backend_fallback = |config_text, header, backend_choice, os, lookup| {
		selection = Plugin.select_config_header(config_text, header, backend_choice, os)?
		match (selection, backend_choice, lookup) {
			(Missing, ExplicitBackend(backend), QualifiedThenUnqualified) =>
				Plugin.select_config_header(config_text, header, DefaultBackend(backend), os)
			_ => Ok(selection)
		}
	}

	normalize_backend_name : Plugin.BackendChoice, List(Str) -> { args : List(Str), backend_choice : Plugin.BackendChoice }
	normalize_backend_name = |backend_choice, args|
		match (backend_choice, args) {
			(ExplicitBackend(backend), []) => { args: [backend.name], backend_choice: DefaultBackend(backend) }
			_ => { args, backend_choice }
		}

	parse_body : Body.Shape, Plugin.LocatedConfigBlock -> Try(Body.Configuration, Plugin.SelectorDiagnostic)
	parse_body = |body, block|
		match Body.parse(body, block.body) {
			Ok(config) => Ok(config)
			Err(diagnostic) => Err({
				location: At(Plugin.translate_location(block, diagnostic.byte_offset)),
				message: Body.describe(diagnostic),
			})
		}
}
