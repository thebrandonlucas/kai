# An implementation for defining how to run tasks via nix
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import schemas.Task as TaskCommand
import EnvironmentNix

TaskNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: TaskCommand.command.name,
		plan: TaskNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.ImplementationInput ->
			Try(
				Plugin.CommandPlan,
				Plugin.ImplementationDiagnostic,
			)
	plan = |input| {
		run = Fields.get_strings(input.command_fields, "run") ? |_| {
			byte_offset: None,
			message: "validated task configuration is missing 'run'",
		}
		Plugin.implementation_validation(
			Plugin.validate_string_list(run, TaskCommand.run_rules("task")),
		)?
		environment = Plugin.referenced_fields(input, "environment")?
		pkgs = Fields.get_strings(environment, "packages") ? |_| {
			byte_offset: None,
			message: "validated environment configuration is missing 'packages'",
		}
		Plugin.implementation_validation(
			Plugin.validate_string_list(pkgs, NixBackend.package_rules),
		)?
		overlays = EnvironmentNix.extract_overlays(environment)?
		result = EnvironmentNix.command_plan(
			input,
			pkgs,
			overlays,
			"unsupported task platform",
		)?
		Ok({
			..result,
			steps: result.steps
				.concat(NixBackend.lock_steps)
				.concat(NixBackend.develop_command_steps(run)),
		})
	}
}
