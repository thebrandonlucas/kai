# Implements reproducible artifact builds with the Nix backend.
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import EnvironmentNix

BuildNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: BuildCommand.command.call.name,
		renderer: BuildNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			_ => Err({
				byte_offset: None,
				message: "build requires exactly one artifact name",
			})
		}?
		name_failures = Plugin.validate_text(name, BuildCommand.artifact_name_rules)
		run = Fields.get_strings(context.config, "run") ? |_| {
			byte_offset: None,
			message: "validated build configuration is missing 'run'",
		}
		run_failures = Plugin.validate_string_list(run, BuildCommand.run_rules)
		inputs = Plugin.validated_strings(context.config, BuildCommand.inputs_field)?
		EnvironmentNix.validate_source_inputs(context, inputs)?
		output = Fields.get_string(context.config, "output") ? |_| {
			byte_offset: None,
			message: "validated build configuration is missing 'output'",
		}
		output_failures = Plugin.validate_text(output, BuildCommand.output_rules)
		failures = name_failures.concat(run_failures).concat(output_failures)
		Plugin.renderer_validation(failures)?
		environment = match context.related_config {
			NoRelatedConfig => Err({
				byte_offset: None,
				message: "build environment is required",
			})
			SelectedRelatedConfig({ block: _, config }) => Ok(config)
		}?
		pkgs = Fields.get_strings(environment, "packages") ? |_| {
			byte_offset: None,
			message: "validated environment configuration is missing 'packages'",
		}
		package_failures = Plugin.validate_string_list(
			pkgs,
			NixBackend.package_rules,
		)
		Plugin.renderer_validation(package_failures)?
		overlays = EnvironmentNix.extract_overlays(environment)?
		target = NixBackend.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported build platform" }
		flake = EnvironmentNix.render_flake(
			context,
			pkgs,
			overlays,
			Bool.True,
			"unsupported build platform",
		)?
		build_nix = BuildNix.nix_expression
		build_json = Json.to_str({
			inputs,
			name,
			output,
			pkgs,
			run,
			system: target.system,
		})
		Ok(
			Plugin.RenderResult.{
				actions: NixBackend.build_artifact_actions(
					name,
					flake,
					build_nix,
					build_json,
				),
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{ key: "nix.pkgs-flake", value: NixBackend.build_flake_path(name) },
							{ key: "target.system", value: target.system },
						],
						kind: "kai.build/v1",
						name,
						path: NixBackend.build_artifact_path(name),
					},
				],
				outputs: [],
				requests: [],
				requested_packages: pkgs,
			},
		)
	}

	nix_expression : Str
	nix_expression = {
		interpolate = BuildNix.nix_interpolation
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
				"    (_: _: true) \".git\\n.kai\" ../../../.;",
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
				Str.join_with(["    ", BuildNix.nix_interpolation("inputLinks")], ""),
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

	nix_interpolation : Str -> Str
	nix_interpolation = |expression| Str.join_with(["$", "{", expression, "}"], "")

}
