# An implementation for defining how to run tasks via nix
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import blocks.Task as TaskBlock
import commands.Run as RunCommand
import EnvironmentNix

TaskNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: RunCommand.command_syntax.name,
		plan: TaskNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		run = Fields.get_strings(input.command_fields, "run") ? |_| {
			byte_offset: None,
			message: "validated task block is missing 'run'",
		}
		Plugin.implementation_validation(
			Plugin.validate_string_list(run, TaskBlock.run_rules("task")),
		)?
		environment = Plugin.referenced_fields(input, "environment")?
		pkgs = Fields.get_strings(environment, "packages") ? |_| {
			byte_offset: None,
			message: "validated environment block is missing 'packages'",
		}
		Plugin.implementation_validation(
			Plugin.validate_string_list(pkgs, NixBackend.package_rules),
		)?
		overlays = EnvironmentNix.extract_overlays(environment)?
		flake = EnvironmentNix.render_flake(
			input,
			pkgs,
			overlays,
			Bool.False,
			"unsupported task platform",
		)?
		flake_path = Plugin.workspace_path(input.workspace_root, "flake.nix")
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [],
				prerequisite_commands: [],
				requested_packages: pkgs,
				steps: [WriteFile({ contents: flake, path: flake_path })]
					.concat(NixBackend.lock_steps(input.workspace_root))
					.concat([
						NixBackend.run(
							[
								"develop",
								"path:${input.workspace_root}#default",
								"--no-update-lock-file",
								"--command",
							].concat(run),
						),
					]),
			},
		)
	}
}
