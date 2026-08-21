import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand

BuildNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [NixBackend.flake_template].concat(NixBackend.lock_templates).concat(NixBackend.build_output_templates),
		backend: NixBackend.backend.name,
		command: BuildCommand.command.name,
		renderer: BuildNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			# `kai build nix` selects the Nix backend before the standard selector
			# recognizes the colliding artifact name.
			[] => Ok(NixBackend.backend.name)
			_ => Err({ byte_offset: None, message: "build requires exactly one artifact name" })
		}?
		name_failures = Plugin.validate_text(name, BuildCommand.artifact_name_rules)
		run = Body.get_strings(context.config, "run") ? |_| {
			byte_offset: None,
			message: "validated build configuration is missing 'run'",
		}
		run_failures = Plugin.validate_string_list(run, BuildCommand.run_rules)
		output = Body.get_string(context.config, "output") ? |_| {
			byte_offset: None,
			message: "validated build configuration is missing 'output'",
		}
		output_failures = Plugin.validate_text(output, BuildCommand.output_rules)
		Plugin.renderer_validation(name_failures.concat(run_failures).concat(output_failures))?
		environment = match context.related_config {
			NoRelatedConfig => Err({ byte_offset: None, message: "build environment is required" })
			SelectedRelatedConfig({ block: _, config }) => Ok(config)
		}?
		pkgs = Body.get_strings(environment, "packages") ? |_| {
			byte_offset: None,
			message: "validated environment configuration is missing 'packages'",
		}
		Plugin.renderer_validation(Plugin.validate_string_list(pkgs, NixBackend.package_rules))?
		target = NixBackend.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported build platform" }
		Ok(
			Plugin.RenderResult.{
				actions: NixBackend.build_artifact_actions(name),
				outputs: [
					{
						name: "flake",
						text: NixBackend.render_dev_shell({ overlays: [], pkgs, system: target.system }),
					},
					{ name: "build_nix", text: BuildNix.nix_expression },
					{
						name: "build_json",
						text: Json.to_str({ name, output, pkgs, run, system: target.system }),
					},
				],
				requests: [],
				requested_packages: pkgs,
			},
		)
	}

	nix_expression : Str
	nix_expression = Str.join_with(
		[
			"let",
			"  config = builtins.fromJSON (builtins.readFile ./build.json);",
			"  flake = builtins.getFlake (toString ./.);",
			"  pkgs = builtins.getAttr config.system flake.inputs.nixpkgs.legacyPackages;",
			"  lib = pkgs.lib;",
			"  resolvePackage = name:",
			"    lib.attrByPath (lib.splitString \".\" name)",
			"      (throw (\"Kai build package '\" + name + \"' was not found\"))",
			"      pkgs;",
			"  source = pkgs.nix-gitignore.gitignoreFilterRecursiveSource",
			"    (_: _: true) \".git\\n.kai\" ../.;",
			"in",
			"pkgs.runCommand (\"kai-build-\" + config.name)",
			"  { nativeBuildInputs = map resolvePackage config.pkgs; }",
			"  ''",
			Str.join_with(["    cp -R ", BuildNix.nix_interpolation("source"), "/. ."], ""),
			"    chmod -R u+w .",
			Str.join_with(["    artifact=", BuildNix.nix_interpolation("lib.escapeShellArg config.output")], ""),
			"    rm -rf -- \"$artifact\"",
			Str.join_with(["    ", BuildNix.nix_interpolation("lib.escapeShellArgs config.run")], ""),
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

	nix_interpolation : Str -> Str
	nix_interpolation = |expression| Str.join_with(["$", "{", expression, "}"], "")

}
