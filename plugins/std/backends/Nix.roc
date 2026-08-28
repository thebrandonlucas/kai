# - Backends define backend capabilities, validation constraints, rendering, and execution primitives.
import kai.Plugin

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

	MachineTarget := { architecture : Str, system : Str }

	machine_target : Str, Plugin.HostOs, Plugin.HostArch -> Try(MachineTarget, [CrossArchitectureMachine, UnsupportedMachineHost, UnsupportedMachineSystem])
	machine_target = |system, os, arch|
		match (system, os, arch) {
			("x86_64-linux", LINUX, X64) => Ok({ architecture: "x86_64", system })
			("aarch64-linux", LINUX, AARCH64) => Ok({ architecture: "aarch64", system })
			("x86_64-linux", LINUX, _) => Err(CrossArchitectureMachine)
			("aarch64-linux", LINUX, _) => Err(CrossArchitectureMachine)
			("x86_64-linux", _, _) => Err(UnsupportedMachineHost)
			("aarch64-linux", _, _) => Err(UnsupportedMachineHost)
			_ => Err(UnsupportedMachineSystem)
		}

	# Nix double-quoted strings accept printable ASCII except the characters
	# that begin escaping or interpolation.
	safe_string_rule : Str -> Plugin.TextRule
	safe_string_rule = |message|
		BytesInRanges({
			excluded: ['"', '$', '\\'],
			message,
			ranges: [{ max: '~', min: '!' }],
		})

	render_dev_shell = |{ export_legacy_packages, locked_overlays, overlays, pkgs, sources, system }|
		if locked_overlays.is_empty() {
			Nix.render_dev_shell_without_overlays(pkgs, sources, system, export_legacy_packages)
		} else {
			Nix.render_dev_shell_with_overlays(pkgs, locked_overlays, overlays, sources, system)
		}

	input_lines : List(Str) -> List(Str)
	input_lines = |overlays|
		overlays.map_with_index(|overlay, index| "  inputs.overlay${U64.to_str(index)}.url = \"${overlay}\";")

	source_input_lines = |sources|
		sources.map(
			|source| "  inputs.\"kai-source-${source.name}\".url = \"${source.url}\";\n  inputs.\"kai-source-${source.name}\".flake = false;",
		)

	source_attribute = |sources|
		"kaiSources = { ${Str.join_with(sources.map(|source| "\"${source.name}\" = inputs.\"kai-source-${source.name}\";"), " ")} };"

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

	render_update_flake = |overlays, sources|
		Str.join_with(
			["{", "  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";"]
				.concat(Nix.input_lines(overlays))
				.concat(Nix.source_input_lines(sources))
				.concat(["  outputs = _: {};", "}"]),
			"\n",
		)

	render_attributes : Str -> Str
	render_attributes = |path|
		Str.join_with(path.split_on(".").map(|part| "\"${part}\""), ".")

	# Render a flake containing a dev shell backed directly by nixpkgs.
	render_dev_shell_without_overlays = |pkgs, sources, system, export_legacy_packages| {
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
		].concat(Nix.source_input_lines(sources)).concat([
			"  outputs = inputs@{ nixpkgs, ... }: {",
			"    ${Nix.source_attribute(sources)}",
		]).concat(legacy_lines).concat([
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
	render_dev_shell_with_overlays = |pkgs, locked_overlays, overlays, sources, system| {
		overlay_names = locked_overlays.map_with_index(|_, index| "overlay${U64.to_str(index)}")
		overlay_lines = overlays.map(|overlay| "          ${Nix.overlay_name(locked_overlays, overlay, 0)}.overlays.default")
		package_lines = pkgs.map(
			|pkg| "              pkgs.${Nix.render_attributes(pkg)}",
		)
		outputs_args = Str.join_with(["nixpkgs"].concat(overlay_names), ", ")
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		].concat(Nix.input_lines(locked_overlays)).concat(Nix.source_input_lines(sources)).concat([
			"  outputs = inputs@{ ${outputs_args}, ... }:",
			"    let",
			"      pkgs = import nixpkgs {",
			"        system = \"${system}\";",
			"        overlays = [",
		]).concat(overlay_lines).concat([
			"        ];",
			"      };",
			"    in {",
			"      ${Nix.source_attribute(sources)}",
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

	artifact_path_rules : List(Plugin.TextRule)
	artifact_path_rules = [
		NonemptyText("artifact path must not be empty"),
		ForbiddenPathSegments({ message: "artifact path must not contain '.' or '..' segments", segments: [".", ".."] }),
		AllBytes({
			allowed: [
				AsciiUppercase,
				AsciiLowercase,
				AsciiDigit,
				ExactByte('.'),
				ExactByte('_'),
				ExactByte('-'),
				ExactByte('/'),
			],
			message: "artifact path may contain only ASCII letters, digits, '/', '.', '_', and '-'",
		}),
	]

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

	build_artifact_path : Str -> Str
	build_artifact_path = |name| ".kai/artifacts/builds/${name}"

	build_flake_path : Str -> Str
	build_flake_path = |name| ".kai/builds/${name}"

	build_artifact_actions : Str, Str, Str, Str -> List(Plugin.Action)
	build_artifact_actions = |name, flake, build_nix, build_json| {
		flake_path = Nix.build_flake_path(name)
		[
			WriteUtf8({ content: flake, path: "${flake_path}/flake.nix" }),
			WriteUtf8({ content: build_nix, path: "${flake_path}/build.nix" }),
			WriteUtf8({ content: build_json, path: "${flake_path}/build.json" }),
			Exec({
				args: [
					"flake",
					"lock",
					"path:${flake_path}",
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
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"${flake_path}/flake.lock",
				],
				command: backend.name,
			}),
			WriteUtf8({ content: "", path: ".kai/artifacts/builds/.keep" }),
			Exec({
				args: [
					"build",
					"--file",
					"${flake_path}/build.nix",
					"--out-link",
					Nix.build_artifact_path(name),
				],
				command: backend.name,
			}),
		]
	}

	service_artifact_path : Str -> Str
	service_artifact_path = |name| ".kai/artifacts/.services/${name}"

	service_actions : Str, Str, Str, Str -> List(Plugin.Action)
	service_actions = |name, build_artifact, module_text, expression| {
		source_path = ".kai/services/${name}"
		artifact_path = "${source_path}/artifact"
		[
			WriteUtf8({ content: module_text, path: "${source_path}/module.nix" }),
			WriteUtf8({ content: expression, path: "${source_path}/default.nix" }),
			Exec({ args: ["-rf", "--", artifact_path], command: "rm" }),
			Exec({
				args: ["--recursive", "--dereference", "--preserve=mode", "--", build_artifact, artifact_path],
				command: "cp",
			}),
			WriteUtf8({ content: "", path: ".kai/artifacts/.services/.keep" }),
			Exec({
				args: [
					"build",
					"--file",
					"${source_path}/default.nix",
					"--out-link",
					Nix.service_artifact_path(name),
				],
				command: backend.name,
			}),
		]
	}

	machine_closure_path : Str -> Str
	machine_closure_path = |name| ".kai/artifacts/machines/${name}/closure"

	machine_flake_path : Str -> Str
	machine_flake_path = |name| ".kai/machines/${name}"

	machine_metadata_path : Str -> Str
	machine_metadata_path = |name| ".kai/artifacts/machines/${name}/metadata.json"

	service_copy_actions : Str, List(Plugin.Artifact) -> List(Plugin.Action)
	service_copy_actions = |flake_path, services| {
		service_path = "${flake_path}/services"
		[
			Exec({ args: ["-rf", service_path], command: "rm" }),
			Exec({ args: ["-p", service_path], command: "mkdir" }),
		].concat(
			services.map(
				|service|
					Exec({
						args: ["-RH", "--preserve=mode", "--", service.path, "${service_path}/${service.name}"],
						command: "cp",
					}),
			),
		).concat([Exec({ args: ["-R", "u+w", "--", service_path], command: "chmod" })])
	}

	machine_actions : Str, Str, Str, Str, List(Plugin.Artifact) -> List(Plugin.Action)
	machine_actions = |name, flake, module_text, metadata, services| {
		flake_path = Nix.machine_flake_path(name)
		metadata_path = Nix.machine_metadata_path(name)
		[
			# Empty metadata invalidates an older artifact before any fallible action.
			WriteUtf8({ content: "", path: metadata_path }),
			WriteUtf8({ content: flake, path: "${flake_path}/flake.nix" }),
			WriteUtf8({ content: module_text, path: "${flake_path}/machine.nix" }),
		].concat(Nix.service_copy_actions(flake_path, services)).concat([
			Exec({
				args: [
					"flake",
					"lock",
					"path:${flake_path}",
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
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"${flake_path}/flake.lock",
				],
				command: backend.name,
			}),
			WriteUtf8({ content: "", path: ".kai/artifacts/machines/${name}/.keep" }),
			Exec({
				args: [
					"build",
					"path:${flake_path}#kaiMachines.\"${name}\".closure",
					"--no-update-lock-file",
					"--out-link",
					Nix.machine_closure_path(name),
				],
				command: backend.name,
			}),
			WriteUtf8({ content: metadata, path: metadata_path }),
		])
	}

	image_output_path : Str -> Str
	image_output_path = |name| ".kai/artifacts/images/${name}/result"

	image_file_path : Str -> Str
	image_file_path = |name| "${Nix.image_output_path(name)}/${name}.qcow2"

	image_flake_path : Str -> Str
	image_flake_path = |name| ".kai/images/${name}"

	image_metadata_path : Str -> Str
	image_metadata_path = |name| ".kai/artifacts/images/${name}/metadata.json"

	image_actions : Str, Str, Str, Str, List(Plugin.Artifact) -> List(Plugin.Action)
	image_actions = |name, flake, module_text, metadata, services| {
		flake_path = Nix.image_flake_path(name)
		metadata_path = Nix.image_metadata_path(name)
		[
			WriteUtf8({ content: "", path: metadata_path }),
			WriteUtf8({ content: flake, path: "${flake_path}/flake.nix" }),
			WriteUtf8({ content: module_text, path: "${flake_path}/machine.nix" }),
		].concat(Nix.service_copy_actions(flake_path, services)).concat([
			Exec({
				args: [
					"flake",
					"lock",
					"path:${flake_path}",
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
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"${flake_path}/flake.lock",
				],
				command: backend.name,
			}),
			WriteUtf8({ content: "", path: ".kai/artifacts/images/${name}/.keep" }),
			Exec({
				args: [
					"build",
					"path:${flake_path}#kaiImages.\"${name}\".image",
					"--no-update-lock-file",
					"--out-link",
					Nix.image_output_path(name),
				],
				command: backend.name,
			}),
			WriteUtf8({ content: metadata, path: metadata_path }),
		])
	}

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
