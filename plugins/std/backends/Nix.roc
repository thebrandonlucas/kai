# Nix backend capability definitions
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

	supported_targets : List(Plugin.SupportedBackendTarget)
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

	machine_target :
		Str,
		Plugin.HostOs,
		Plugin.HostArch ->
			Try(
				MachineTarget,
				[
					CrossArchitectureMachine,
					UnsupportedMachineHost,
					UnsupportedMachineSystem,
				],
			)
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

	render_dev_shell = |options|
		if options.locked_overlays.is_empty() {
			Nix.render_dev_shell_without_overlays(
				options.pkgs,
				options.sources,
				options.system,
				options.export_legacy_packages,
			)
		} else {
			Nix.render_dev_shell_with_overlays(
				options.pkgs,
				options.locked_overlays,
				options.overlays,
				options.sources,
				options.system,
			)
		}

	input_lines : List(Str) -> List(Str)
	input_lines = |overlays|
		overlays.map_with_index(
			|overlay, index|
				Str.join_with(
					[
						"  inputs.overlay${U64.to_str(index)}.url = \"",
						overlay,
						"\";",
					],
					"",
				),
		)

	source_input_lines = |sources|
		sources.map(
			|source|
				Str.join_with(
					[
						"  inputs.\"kai-source-${source.name}\".url = \"${source.url}\";\n",
						"  inputs.\"kai-source-${source.name}\".flake = false;",
					],
					"",
				),
		)

	source_attribute = |sources| {
		attributes = sources.map(
			|source| "\"${source.name}\" = inputs.\"kai-source-${source.name}\";",
		)
		Str.join_with(
			["kaiSources = { ", Str.join_with(attributes, " "), " };"],
			"",
		)
	}

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
	render_dev_shell_without_overlays = |pkgs, sources, system, legacy| {
		package_lines = pkgs.map(
			|pkg|
				Str.join_with(
					[
						"              nixpkgs.\"legacyPackages\".\"${system}\".",
						Nix.render_attributes(pkg),
					],
					"",
				),
		)
		legacy_lines = if legacy {
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
			Str.join_with(
				[
					"    devShells.\"${system}\".default = ",
					"nixpkgs.legacyPackages.\"${system}\".mkShell {",
				],
				"",
			),
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
	render_dev_shell_with_overlays = |pkgs, locked, overlays, sources, system| {
		overlay_names = locked.map_with_index(
			|_, index| "overlay${U64.to_str(index)}",
		)
		overlay_lines = overlays.map(
			|overlay|
				Str.join_with(
					[
						"          ",
						Nix.overlay_name(locked, overlay, 0),
						".overlays.default",
					],
					"",
				),
		)
		package_lines = pkgs.map(
			|pkg| "              pkgs.${Nix.render_attributes(pkg)}",
		)
		outputs_args = Str.join_with(["nixpkgs"].concat(overlay_names), ", ")
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		]
			.concat(Nix.input_lines(locked))
			.concat(Nix.source_input_lines(sources))
			.concat([
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
		ForbiddenPathSegments({
			message: "artifact path must not contain '.' or '..' segments",
			segments: [".", ".."],
		}),
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
			message: Str.join_with(
				[
					"artifact path may contain only ASCII letters, digits, ",
					"'/', '.', '_', and '-'",
				],
				"",
			),
		}),
	]

	package_rules : List(Plugin.StringListRule)
	package_rules = [
		AllStrings(NonemptyText("shell package names must not be empty")),
		AllStrings(
			DotSeparatedNonemptySegments(
				Str.join_with(
					[
						"shell package attribute paths must not contain ",
						"empty segments",
					],
					"",
				),
			),
		),
		AllStrings(
			safe_string_rule(
				Str.join_with(
					[
						"shell package attribute paths contain characters ",
						"unsafe for Nix output",
					],
					"",
				),
			),
		),
	]

	overlay_rules : List(Plugin.StringListRule)
	overlay_rules = [
		AllStrings(NonemptyText("shell overlay references must not be empty")),
		AllStrings(
			safe_string_rule(
				Str.join_with(
					[
						"shell overlay references contain characters unsafe ",
						"for Nix output",
					],
					"",
				),
			),
		),
	]

	write_flake_step : Str -> Plugin.ExecutionStep
	write_flake_step = |flake|
		WriteFile({ contents: flake, path: ".kai/flake.nix" })

	lock_steps : List(Plugin.ExecutionStep)
	lock_steps = [
		RunProgram({
			arguments: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"kai.lock",
			],
			program: backend.name,
		}),
		RunProgram({
			arguments: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				".kai/flake.lock",
			],
			program: backend.name,
		}),
	]

	develop_step : Plugin.ExecutionStep
	develop_step = RunProgram({
		arguments: [
			"develop",
			"path:.kai#default",
			"--no-update-lock-file",
		],
		program: backend.name,
	})

	update_lock_steps : List(Plugin.ExecutionStep)
	update_lock_steps = [
		RunProgram({
			arguments: [
				"flake",
				"update",
				"--flake",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"kai.lock",
			],
			program: backend.name,
		}),
		RunProgram({
			arguments: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				".kai/flake.lock",
			],
			program: backend.name,
		}),
	]

	build_artifact_path : Str -> Str
	build_artifact_path = |name| ".kai/artifacts/builds/${name}"

	build_flake_path : Str -> Str
	build_flake_path = |name| ".kai/builds/${name}"

	build_artifact_steps : Str, Str, Str, Str -> List(Plugin.ExecutionStep)
	build_artifact_steps = |name, flake, build_nix, build_json| {
		flake_path = Nix.build_flake_path(name)
		[
			WriteFile({ contents: flake, path: "${flake_path}/flake.nix" }),
			WriteFile({ contents: build_nix, path: "${flake_path}/build.nix" }),
			WriteFile({ contents: build_json, path: "${flake_path}/build.json" }),
			RunProgram({
				arguments: [
					"flake",
					"lock",
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"kai.lock",
				],
				program: backend.name,
			}),
			RunProgram({
				arguments: [
					"flake",
					"lock",
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"${flake_path}/flake.lock",
				],
				program: backend.name,
			}),
			WriteFile({ contents: "", path: ".kai/artifacts/builds/.keep" }),
			RunProgram({
				arguments: [
					"build",
					"--file",
					"${flake_path}/build.nix",
					"--out-link",
					Nix.build_artifact_path(name),
				],
				program: backend.name,
			}),
		]
	}

	service_artifact_path : Str -> Str
	service_artifact_path = |name| ".kai/artifacts/.services/${name}"

	service_steps : Str, Str, Str, Str -> List(Plugin.ExecutionStep)
	service_steps = |name, build_artifact, module_text, expression| {
		source_path = ".kai/services/${name}"
		artifact_path = "${source_path}/artifact"
		[
			WriteFile({ contents: module_text, path: "${source_path}/module.nix" }),
			WriteFile({ contents: expression, path: "${source_path}/default.nix" }),
			RunProgram({ arguments: ["-rf", "--", artifact_path], program: "rm" }),
			RunProgram({
				arguments: [
					"--recursive",
					"--dereference",
					"--preserve=mode",
					"--",
					build_artifact,
					artifact_path,
				],
				program: "cp",
			}),
			WriteFile({ contents: "", path: ".kai/artifacts/.services/.keep" }),
			RunProgram({
				arguments: [
					"build",
					"--file",
					"${source_path}/default.nix",
					"--out-link",
					Nix.service_artifact_path(name),
				],
				program: backend.name,
			}),
		]
	}

	machine_closure_path : Str -> Str
	machine_closure_path = |name| ".kai/artifacts/machines/${name}/closure"

	machine_flake_path : Str -> Str
	machine_flake_path = |name| ".kai/machines/${name}"

	machine_metadata_path : Str -> Str
	machine_metadata_path = |name| ".kai/artifacts/machines/${name}/metadata.json"

	service_copy_steps : Str, List(Plugin.Artifact) -> List(Plugin.ExecutionStep)
	service_copy_steps = |flake_path, services| {
		service_path = "${flake_path}/services"
		[
			RunProgram({ arguments: ["-rf", service_path], program: "rm" }),
			RunProgram({ arguments: ["-p", service_path], program: "mkdir" }),
		].concat(
			services.map(
				|service|
					RunProgram({
						arguments: [
							"-RH",
							"--preserve=mode",
							"--",
							service.path,
							"${service_path}/${service.name}",
						],
						program: "cp",
					}),
			),
		).concat([
			RunProgram({
				arguments: ["-R", "u+w", "--", service_path],
				program: "chmod",
			}),
		])
	}

	machine_steps :
		Str, Str, Str, Str, List(Plugin.Artifact) -> List(Plugin.ExecutionStep)
	machine_steps = |name, flake, module_text, metadata, services| {
		flake_path = Nix.machine_flake_path(name)
		metadata_path = Nix.machine_metadata_path(name)
		[
			# Empty metadata invalidates an older artifact before any fallible step.
			WriteFile({ contents: "", path: metadata_path }),
			WriteFile({ contents: flake, path: "${flake_path}/flake.nix" }),
			WriteFile({ contents: module_text, path: "${flake_path}/machine.nix" }),
		].concat(Nix.service_copy_steps(flake_path, services)).concat([
			RunProgram({
				arguments: [
					"flake",
					"lock",
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"kai.lock",
				],
				program: backend.name,
			}),
			RunProgram({
				arguments: [
					"flake",
					"lock",
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"${flake_path}/flake.lock",
				],
				program: backend.name,
			}),
			WriteFile({ contents: "", path: ".kai/artifacts/machines/${name}/.keep" }),
			RunProgram({
				arguments: [
					"build",
					"path:${flake_path}#kaiMachines.\"${name}\".closure",
					"--no-update-lock-file",
					"--out-link",
					Nix.machine_closure_path(name),
				],
				program: backend.name,
			}),
			WriteFile({ contents: metadata, path: metadata_path }),
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

	image_steps :
		Str, Str, Str, Str, List(Plugin.Artifact) -> List(Plugin.ExecutionStep)
	image_steps = |name, flake, module_text, metadata, services| {
		flake_path = Nix.image_flake_path(name)
		metadata_path = Nix.image_metadata_path(name)
		[
			WriteFile({ contents: "", path: metadata_path }),
			WriteFile({ contents: flake, path: "${flake_path}/flake.nix" }),
			WriteFile({ contents: module_text, path: "${flake_path}/machine.nix" }),
		].concat(Nix.service_copy_steps(flake_path, services)).concat([
			RunProgram({
				arguments: [
					"flake",
					"lock",
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"kai.lock",
				],
				program: backend.name,
			}),
			RunProgram({
				arguments: [
					"flake",
					"lock",
					"path:${flake_path}",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"${flake_path}/flake.lock",
				],
				program: backend.name,
			}),
			WriteFile({ contents: "", path: ".kai/artifacts/images/${name}/.keep" }),
			RunProgram({
				arguments: [
					"build",
					"path:${flake_path}#kaiImages.\"${name}\".image",
					"--no-update-lock-file",
					"--out-link",
					Nix.image_output_path(name),
				],
				program: backend.name,
			}),
			WriteFile({ contents: metadata, path: metadata_path }),
		])
	}

	develop_command_steps : List(Str) -> List(Plugin.ExecutionStep)
	develop_command_steps = |run|
		[
			RunProgram({
				arguments: [
					"develop",
					"path:.kai#default",
					"--no-update-lock-file",
					"--command",
				].concat(run),
				program: backend.name,
			}),
		]
}
