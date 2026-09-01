# Implements reproducible artifact builds with the Nix backend.
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import blocks.Build as BuildBlock
import commands.Build as BuildCommand
import EnvironmentNix

BuildNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: BuildCommand.command_syntax.name,
		plan: BuildNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |planning_input| {
		artifact_name = match planning_input.command_arguments {
			[selected_artifact_name] => Ok(selected_artifact_name)
			_ => Err({
				byte_offset: None,
				message: "build requires exactly one artifact name",
			})
		}?
		artifact_name_errors = Plugin.validate_text(
			artifact_name,
			BuildBlock.artifact_name_rules,
		)
		run_arguments = Fields.get_strings(
			planning_input.command_fields,
			"run",
		) ? |_| {
			byte_offset: None,
			message: "validated build block is missing 'run'",
		}
		run_argument_errors = Plugin.validate_string_list(
			run_arguments,
			BuildBlock.run_rules,
		)
		source_input_names = Plugin.validated_strings(
			planning_input.command_fields,
			BuildBlock.inputs_field,
		)?
		EnvironmentNix.validate_source_inputs(planning_input, source_input_names)?
		output_path = Fields.get_string(
			planning_input.command_fields,
			"output",
		) ? |_| {
			byte_offset: None,
			message: "validated build block is missing 'output'",
		}
		output_path_errors = Plugin.validate_text(
			output_path,
			BuildBlock.output_rules,
		)
		build_validation_errors = artifact_name_errors
			.concat(run_argument_errors)
			.concat(output_path_errors)
		Plugin.implementation_validation(build_validation_errors)?
		environment = Plugin.referenced_fields(planning_input, "environment")?
		environment_packages = Fields.get_strings(
			environment,
			"packages",
		) ? |_| {
			byte_offset: None,
			message: "validated environment block is missing 'packages'",
		}
		package_validation_errors = Plugin.validate_string_list(
			environment_packages,
			NixBackend.package_rules,
		)
		Plugin.implementation_validation(package_validation_errors)?
		overlays = EnvironmentNix.extract_overlays(environment)?
		target = NixBackend.target(
			planning_input.host.os,
			planning_input.host.arch,
		) ? |_| { byte_offset: None, message: "unsupported build platform" }
		flake = EnvironmentNix.render_flake(
			planning_input,
			environment_packages,
			overlays,
			Bool.True,
			"unsupported build platform",
		)?
		flake_path = Plugin.workspace_path(
			planning_input.workspace_root,
			"builds/${artifact_name}",
		)
		artifact_path = Plugin.workspace_path(
			planning_input.workspace_root,
			"artifacts/builds/${artifact_name}",
		)
		build_json = Json.to_str({
			inputs: source_input_names,
			name: artifact_name,
			output: output_path,
			pkgs: environment_packages,
			run: run_arguments,
			system: target.system,
		})
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{ key: "nix.pkgs-flake", value: flake_path },
							{ key: "target.system", value: target.system },
						],
						kind: "kai.build/v1",
						name: artifact_name,
						path: artifact_path,
					},
				],
				prerequisite_commands: [],
				requested_packages: environment_packages,
				steps: [
					WriteFile({ contents: flake, path: "${flake_path}/flake.nix" }),
					WriteFile({
						contents: BuildNix.nix_expression(planning_input.workspace_root),
						path: "${flake_path}/build.nix",
					}),
					WriteFile({ contents: build_json, path: "${flake_path}/build.json" }),
				].concat(NixBackend.lock_steps(flake_path)).concat([
					WriteFile({
						contents: "",
						path: Plugin.workspace_path(
							planning_input.workspace_root,
							"artifacts/builds/.keep",
						),
					}),
					NixBackend.run([
						"build",
						"--file",
						"${flake_path}/build.nix",
						"--out-link",
						artifact_path,
					]),
				]),
			},
		)
	}

	nix_expression : Str -> Str
	nix_expression = |workspace_root| {
		interpolate = NixBackend.nix_interpolation
		ignore_paths = if workspace_root == Plugin.default_workspace_root {
			".git\\n.kai"
		} else {
			".git\\n.kai\\n/${workspace_root}"
		}
		escaped_source = Str.join_with(
			[
				"lib.escapeShellArg (toString ",
				"(builtins.getAttr name flake.kaiSources))",
			],
			"",
		)
		Str.join_with(
			[
				"let",
				"  config = builtins.fromJSON (builtins.readFile ./build.json);",
				"  flake = builtins.getFlake (toString ./.);",
				"  pkgs = builtins.getAttr config.system flake.legacyPackages;",
				"  lib = pkgs.lib;",
				"  resolvePackage = name:",
				"    lib.attrByPath (lib.splitString \".\" name)",
				"      (throw (\"Kai build package '\" + name + \"' was not found\"))",
				"      pkgs;",
				"  source = pkgs.nix-gitignore.gitignoreFilterRecursiveSource",
				"    (_: _: true) \"${ignore_paths}\" ../../../.;",
				"  inputLinks = lib.concatMapStringsSep \"\\n\" (name:",
				Str.join_with(
					[
						"    \"ln -s -- ",
						interpolate(escaped_source),
						" .kai/inputs/",
						interpolate("lib.escapeShellArg name"),
						"\"",
					],
					"",
				),
				"  ) config.inputs;",
				"in",
				"pkgs.runCommand (\"kai-build-\" + config.name)",
				"  { nativeBuildInputs = map resolvePackage config.pkgs; }",
				"  ''",
				Str.join_with(
					["    cp -R ", interpolate("source"), "/. ."],
					"",
				),
				"    chmod -R u+w .",
				"    mkdir -p .kai/inputs",
				Str.join_with(["    ", interpolate("inputLinks")], ""),
				Str.join_with(
					[
						"    artifact=",
						interpolate("lib.escapeShellArg config.output"),
					],
					"",
				),
				"    rm -rf -- \"$artifact\"",
				Str.join_with(
					["    ", interpolate("lib.escapeShellArgs config.run")],
					"",
				),
				"    if [ ! -e \"$artifact\" ]; then",
				"      echo \"Kai build output does not exist: $artifact\" >&2",
				"      exit 1",
				"    fi",
				"    if [ -d \"$artifact\" ]; then",
				"      cp -R -- \"$artifact\" \"$out\"",
				"    else",
				"      cp -- \"$artifact\" \"$out\"",
				"    fi",
				"  ''",
			],
			"\n",
		)
	}

}
