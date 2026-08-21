import kai.Plugin
import parser.Bytes

Nix := [].{
	backend : Plugin.Backend
	backend = Plugin.Backend.{
		determinate_system: Plugin.DeterminateSystem.{
			default_package_source: "nixpkgs",
			driver: Program("nix"),
			kind: Nix,
		},
		fallback: NoFallback,
		name: "nix",
		required_packages: [],
	}

	Target : { system : Str }

	target : Plugin.HostOs, Plugin.HostArch -> Try(Target, [UnsupportedPlatform])
	target = |os, arch|
		match (os, arch) {
			(LINUX, X64) => Ok({ system: "x86_64-linux" })
			(LINUX, AARCH64) => Ok({ system: "aarch64-linux" })
			(MACOS, X64) => Ok({ system: "x86_64-darwin" })
			(MACOS, AARCH64) => Ok({ system: "aarch64-darwin" })
			_ => Err(UnsupportedPlatform)
		}

	# Nix double-quoted strings accept printable ASCII except the characters
	# that begin escaping or interpolation.
	safe_string_rule : Str -> Plugin.TextRule
	safe_string_rule = |message|
		BytesInRanges({
			excluded: [Bytes.double_quote, Bytes.dollar_sign, Bytes.backslash],
			message,
			ranges: [{ max: Bytes.tilde, min: Bytes.exclamation_mark }],
		})

	render_dev_shell : { overlays : List(Str), pkgs : List(Str), system : Str } -> Str
	render_dev_shell = |{ overlays, pkgs, system }|
		if overlays.is_empty() {
			Nix.render_dev_shell_without_overlays(pkgs, system)
		} else {
			Nix.render_dev_shell_with_overlays(pkgs, overlays, system)
		}

	render_attributes : Str -> Str
	render_attributes = |path|
		Str.join_with(path.split_on(".").map(|part| "\"${part}\""), ".")

	# Render a flake containing a dev shell backed directly by nixpkgs.
	render_dev_shell_without_overlays : List(Str), Str -> Str
	render_dev_shell_without_overlays = |pkgs, system| {
		package_lines = pkgs.map(
			|pkg| "              nixpkgs.\"legacyPackages\".\"${system}\".${Nix.render_attributes(pkg)}",
		)
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
			"  outputs = { nixpkgs, ... }: {",
			"    devShells.\"${system}\".default = nixpkgs.legacyPackages.\"${system}\".mkShell {",
			"      packages = [",
		].concat(package_lines).concat([
			"      ];",
			"    };",
			"  };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	# Render a flake containing a dev shell with additional flake overlays.
	render_dev_shell_with_overlays : List(Str), List(Str), Str -> Str
	render_dev_shell_with_overlays = |pkgs, overlays, system| {
		overlay_names = overlays.map_with_index(|_, index| "overlay${U64.to_str(index)}")
		input_lines = overlays.map_with_index(
			|overlay, index| "  inputs.overlay${U64.to_str(index)}.url = \"${overlay}\";",
		)
		overlay_lines = overlay_names.map(|name| "          ${name}.overlays.default")
		package_lines = pkgs.map(
			|pkg| "              pkgs.${Nix.render_attributes(pkg)}",
		)
		outputs_args = Str.join_with(["nixpkgs"].concat(overlay_names), ", ")
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		].concat(input_lines).concat([
			"  outputs = { ${outputs_args}, ... }:",
			"    let",
			"      pkgs = import nixpkgs {",
			"        system = \"${system}\";",
			"        overlays = [",
		]).concat(overlay_lines).concat([
			"        ];",
			"      };",
			"    in {",
			"      devShells.\"${system}\".default = pkgs.mkShell {",
			"        packages = [",
		]).concat(package_lines).concat([
			"        ];",
			"      };",
			"    };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	package_rules : List(Plugin.StringListRule)
	package_rules = [
		AllStrings(NonemptyText("shell package names must not be empty")),
		AllStrings(DotSeparatedNonemptySegments("shell package attribute paths must not contain empty segments")),
		AllStrings(safe_string_rule("shell package attribute paths contain characters unsafe for Nix output")),
	]

	overlay_rules : List(Plugin.StringListRule)
	overlay_rules = [
		AllStrings(NonemptyText("shell overlay references must not be empty")),
		AllStrings(safe_string_rule("shell overlay references contain characters unsafe for Nix output")),
	]

	locked_flake_templates : List(Plugin.ActionTemplate)
	locked_flake_templates = [
		WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
		Exec({
			args: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"kai.lock",
			],
			command: backend.name,
		}),
		Exec({
			args: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				".kai/flake.lock",
			],
			command: backend.name,
		}),
	]

	shell_templates : List(Plugin.ActionTemplate)
	shell_templates = locked_flake_templates.concat([
		Exec({
			args: [
				"develop",
				"path:.kai#default",
				"--no-update-lock-file",
			],
			command: backend.name,
		}),
	])

	build_templates : List(Plugin.ActionTemplate)
	build_templates = locked_flake_templates.concat([
		WriteConfigUtf8({ output: "build_nix", path: ".kai/build.nix" }),
		WriteConfigUtf8({ output: "build_json", path: ".kai/build.json" }),
	])

	update_recipe : List(Plugin.ActionTemplate)
	update_recipe = [
		WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
		Exec({
			args: [
				"flake",
				"update",
				"--flake",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"kai.lock",
			],
			command: backend.name,
		}),
		Exec({
			args: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				".kai/flake.lock",
			],
			command: backend.name,
		}),
	]

	named_artifact_actions : Str -> List(Plugin.Action)
	named_artifact_actions = |name|
		[
			WriteUtf8({ content: "", path: ".kai/artifacts/.keep" }),
			Exec({
				args: [
					"build",
					"--file",
					".kai/build.nix",
					"--out-link",
					".kai/artifacts/${name}",
				],
				command: backend.name,
			}),
		]

	task_actions : List(Str) -> List(Plugin.Action)
	task_actions = |run|
		[
			Exec({
				args: [
					"develop",
					"path:.kai#default",
					"--no-update-lock-file",
					"--command",
				].concat(run),
				command: backend.name,
			}),
		]
}
