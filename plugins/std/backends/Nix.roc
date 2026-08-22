# - Backends define backend capabilities, validation constraints, rendering, and execution primitives.
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

	supported_targets : List(Plugin.BackendTarget)
	supported_targets = [
		{ arch: X64, os: LINUX, value: "x86_64-linux" },
		{ arch: AARCH64, os: LINUX, value: "aarch64-linux" },
		{ arch: X64, os: MACOS, value: "x86_64-darwin" },
		{ arch: AARCH64, os: MACOS, value: "aarch64-darwin" },
	]

	target : Plugin.HostOs, Plugin.HostArch -> Try(Target, [UnsupportedPlatform])
	target = |os, arch| {
		system = Plugin.target_value(supported_targets, os, arch)?
		Ok({ system: system })
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

	render_dev_shell : { export_legacy_packages : Bool, locked_overlays : List(Str), overlays : List(Str), pkgs : List(Str), system : Str } -> Str
	render_dev_shell = |{ export_legacy_packages, locked_overlays, overlays, pkgs, system }|
		if locked_overlays.is_empty() {
			Nix.render_dev_shell_without_overlays(pkgs, system, export_legacy_packages)
		} else {
			Nix.render_dev_shell_with_overlays(pkgs, locked_overlays, overlays, system)
		}

	input_lines : List(Str) -> List(Str)
	input_lines = |overlays|
		overlays.map_with_index(|overlay, index| "  inputs.overlay${U64.to_str(index)}.url = \"${overlay}\";")

	overlay_name : List(Str), Str, U64 -> Str
	overlay_name = |overlays, selected, index|
		match overlays {
			[] => "overlay0"
			[first, .. as rest] =>
				if first == selected {
					"overlay${U64.to_str(index)}"
				} else {
					Nix.overlay_name(rest, selected, index + 1)
				}
			}

	render_update_flake : List(Str) -> Str
	render_update_flake = |overlays|
		Str.join_with(
			["{", "  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";"]
				.concat(Nix.input_lines(overlays))
				.concat(["  outputs = _: {};", "}"]),
			"\n",
		)

	render_attributes : Str -> Str
	render_attributes = |path|
		Str.join_with(path.split_on(".").map(|part| "\"${part}\""), ".")

	# Render a flake containing a dev shell backed directly by nixpkgs.
	render_dev_shell_without_overlays : List(Str), Str, Bool -> Str
	render_dev_shell_without_overlays = |pkgs, system, export_legacy_packages| {
		package_lines = pkgs.map(
			|pkg| "              nixpkgs.\"legacyPackages\".\"${system}\".${Nix.render_attributes(pkg)}",
		)
		legacy_lines = if export_legacy_packages {
			["    legacyPackages.\"${system}\" = nixpkgs.legacyPackages.\"${system}\";"]
		} else {
			[]
		}
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
			"  outputs = { nixpkgs, ... }: {",
		].concat(legacy_lines).concat([
			"    devShells.\"${system}\".default = nixpkgs.legacyPackages.\"${system}\".mkShell {",
			"      packages = [",
		]).concat(package_lines).concat([
			"      ];",
			"    };",
			"  };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	# Render a flake containing a dev shell with additional flake overlays.
	render_dev_shell_with_overlays : List(Str), List(Str), List(Str), Str -> Str
	render_dev_shell_with_overlays = |pkgs, locked_overlays, overlays, system| {
		overlay_names = locked_overlays.map_with_index(|_, index| "overlay${U64.to_str(index)}")
		overlay_lines = overlays.map(|overlay| "          ${Nix.overlay_name(locked_overlays, overlay, 0)}.overlays.default")
		package_lines = pkgs.map(
			|pkg| "              pkgs.${Nix.render_attributes(pkg)}",
		)
		outputs_args = Str.join_with(["nixpkgs"].concat(overlay_names), ", ")
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		].concat(Nix.input_lines(locked_overlays)).concat([
			"  outputs = { ${outputs_args}, ... }:",
			"    let",
			"      pkgs = import nixpkgs {",
			"        system = \"${system}\";",
			"        overlays = [",
		]).concat(overlay_lines).concat([
			"        ];",
			"      };",
			"    in {",
			"      legacyPackages.\"${system}\" = pkgs;",
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

	flake_template : Plugin.ActionTemplate
	flake_template = WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" })

	lock_templates : List(Plugin.ActionTemplate)
	lock_templates = [
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

	develop_template : Plugin.ActionTemplate
	develop_template = Exec({
		args: [
			"develop",
			"path:.kai#default",
			"--no-update-lock-file",
		],
		command: backend.name,
	})

	build_output_templates : List(Plugin.ActionTemplate)
	build_output_templates = [
		WriteConfigUtf8({ output: "build_nix", path: ".kai/build.nix" }),
		WriteConfigUtf8({ output: "build_json", path: ".kai/build.json" }),
	]

	update_lock_templates : List(Plugin.ActionTemplate)
	update_lock_templates = [
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

	build_artifact_actions : Str -> List(Plugin.Action)
	build_artifact_actions = |name|
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

	develop_command_actions : List(Str) -> List(Plugin.Action)
	develop_command_actions = |run|
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
