import parser.Body
import parser.Bytes
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Shell as ShellCommand

ShellNix := [].{
	Target : { system : Str }

	target : PluginApi.HostOs, PluginApi.HostArch -> Try(Target, [UnsupportedPlatform])
	target = |os, arch|
		match (os, arch) {
			(LINUX, X64) => Ok({ system: "x86_64-linux" })
			(LINUX, AARCH64) => Ok({ system: "aarch64-linux" })
			(MACOS, X64) => Ok({ system: "x86_64-darwin" })
			(MACOS, AARCH64) => Ok({ system: "aarch64-darwin" })
			_ => Err(UnsupportedPlatform)
		}

	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [
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
				command: NixBackend.backend.name,
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
				command: NixBackend.backend.name,
			}),
			Exec({
				args: [
					"develop",
					"path:.kai#default",
					"--no-update-lock-file",
				],
				command: NixBackend.backend.name,
			}),
		],
		backend: NixBackend.backend.name,
		command: ShellCommand.command.name,
		renderer: ShellNix.renderer,
	}

	renderer : PluginApi.Renderer
	renderer = |context|
		match context.config_block {
			NoConfigBlock => Err({ byte_offset: None, message: "shell configuration is required" })
			SelectedConfigBlock({ body: _, location: _ }) =>
				match ShellNix.target(context.host_os, context.host_arch) {
					Err(_) => Err({ byte_offset: None, message: "unsupported shell platform" })
					Ok(selected_target) =>
						match Body.get_strings(context.config, "packages") {
							Err(_) => Err({ byte_offset: None, message: "validated shell configuration is missing 'packages'" })
							Ok(pkgs) =>
								match Body.maybe_strings(context.config, "overlays") {
									Err(_) => Err({ byte_offset: None, message: "validated shell configuration has invalid 'overlays'" })
									Ok(maybe_overlays) => {
										overlays = match maybe_overlays {
											None => []
											Some(values) => values
										}
										ShellNix.validate_packages(pkgs)?
										ShellNix.validate_overlays(overlays)?
										Ok(ShellNix.render_result(pkgs, overlays, selected_target.system))
									}
								}
							}
					}
			}

	validate_packages : List(Str) -> Try({}, PluginApi.RendererDiagnostic)
	validate_packages = |pkgs|
		match pkgs {
			[] => Ok({})
			[first, .. as rest] =>
				if first.is_empty() {
					Err({ byte_offset: None, message: "shell package names must not be empty" })
				} else if !List.all(first.split_on("."), |part| !part.is_empty()) {
					Err({ byte_offset: None, message: "shell package attribute paths must not contain empty segments" })
				} else if !ShellNix.is_safe_nix_string(first) {
					Err({ byte_offset: None, message: "shell package attribute paths contain characters unsafe for Nix output" })
				} else {
					ShellNix.validate_packages(rest)
				}
			}

	validate_overlays : List(Str) -> Try({}, PluginApi.RendererDiagnostic)
	validate_overlays = |overlays|
		match overlays {
			[] => Ok({})
			[first, .. as rest] =>
				if first.is_empty() {
					Err({ byte_offset: None, message: "shell overlay references must not be empty" })
				} else if !ShellNix.is_safe_nix_string(first) {
					Err({ byte_offset: None, message: "shell overlay references contain characters unsafe for Nix output" })
				} else {
					ShellNix.validate_overlays(rest)
				}
			}

	# Values are interpolated into Nix double-quoted strings. Restrict them to
	# printable ASCII and exclude Nix string escape/interpolation prefixes.
	is_safe_nix_string : Str -> Bool
	is_safe_nix_string = |value|
		List.all(
			value.to_utf8(),
			|byte|
				byte >= Bytes.exclamation_mark and
					byte <= Bytes.tilde and
						byte != Bytes.double_quote and
							byte != Bytes.dollar_sign and
								byte != Bytes.backslash,
		)

	render_result : List(Str), List(Str), Str -> PluginApi.RenderResult
	render_result = |pkgs, overlays, system|
		PluginApi.RenderResult.{
			outputs: [{ name: "flake", text: ShellNix.render_nix(pkgs, overlays, system) }],
			requested_packages: pkgs,
		}

	render_attributes : Str -> Str
	render_attributes = |path|
		Str.join_with(path.split_on(".").map(|part| "\"${part}\""), ".")

	render_nix : List(Str), List(Str), Str -> Str
	render_nix = |pkgs, overlays, system|
		if overlays.is_empty() {
			ShellNix.render_nix_without_overlays(pkgs, system)
		} else {
			ShellNix.render_nix_with_overlays(pkgs, overlays, system)
		}

	# `render_nix_without_overlays(["cowsay"], "x86_64-linux")` renders:
	# {
	#   inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	#   outputs = { nixpkgs, ... }: {
	#     devShells."x86_64-linux".default = nixpkgs.legacyPackages."x86_64-linux".mkShell {
	#       packages = [
	#               nixpkgs."legacyPackages"."x86_64-linux"."cowsay"
	#       ];
	#     };
	#   };
	# }
	render_nix_without_overlays : List(Str), Str -> Str
	render_nix_without_overlays = |pkgs, system| {
		package_lines = pkgs.map(
			|pkg| "              nixpkgs.\"legacyPackages\".\"${system}\".${ShellNix.render_attributes(pkg)}",
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

	# `render_nix_with_overlays(["cowsay"], ["github:example/packages"], "x86_64-linux")` renders:
	# {
	#   inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	#   inputs.overlay0.url = "github:example/packages";
	#   outputs = { nixpkgs, overlay0, ... }:
	#     let
	#       pkgs = import nixpkgs {
	#         system = "x86_64-linux";
	#         overlays = [
	#           overlay0.overlays.default
	#         ];
	#       };
	#     in {
	#       devShells."x86_64-linux".default = pkgs.mkShell {
	#         packages = [
	#               pkgs."cowsay"
	#         ];
	#       };
	#     };
	# }
	render_nix_with_overlays : List(Str), List(Str), Str -> Str
	render_nix_with_overlays = |pkgs, overlays, system| {
		overlay_names = overlays.map_with_index(|_, index| "overlay${U64.to_str(index)}")
		input_lines = overlays.map_with_index(
			|overlay, index| "  inputs.overlay${U64.to_str(index)}.url = \"${overlay}\";",
		)
		overlay_lines = overlay_names.map(|name| "          ${name}.overlays.default")
		package_lines = pkgs.map(
			|pkg| "              pkgs.${ShellNix.render_attributes(pkg)}",
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
}

# -- TESTS --

shell_nix_render_cases = [
	{
		expected: Str.join_with(
			[
				"{",
				"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
				"  outputs = { nixpkgs, ... }: {",
				"    devShells.\"x86_64-linux\".default = nixpkgs.legacyPackages.\"x86_64-linux\".mkShell {",
				"      packages = [",
				"              nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"cowsay\"",
				"      ];",
				"    };",
				"  };",
				"}",
			],
			"\n",
		),
		overlays: [],
		pkgs: ["cowsay"],
	},
	{
		expected: Str.join_with(
			[
				"{",
				"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
				"  inputs.overlay0.url = \"github:thebrandonlucas/roc-overlay\";",
				"  outputs = { nixpkgs, overlay0, ... }:",
				"    let",
				"      pkgs = import nixpkgs {",
				"        system = \"x86_64-linux\";",
				"        overlays = [",
				"          overlay0.overlays.default",
				"        ];",
				"      };",
				"    in {",
				"      devShells.\"x86_64-linux\".default = pkgs.mkShell {",
				"        packages = [",
				"              pkgs.\"rocpkgs\".\"nightly\"",
				"        ];",
				"      };",
				"    };",
				"}",
			],
			"\n",
		),
		overlays: ["github:thebrandonlucas/roc-overlay"],
		pkgs: ["rocpkgs.nightly"],
	},
	{
		expected: Str.join_with(
			[
				"{",
				"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
				"  inputs.overlay0.url = \"github:example/first\";",
				"  inputs.overlay1.url = \"github:example/second\";",
				"  outputs = { nixpkgs, overlay0, overlay1, ... }:",
				"    let",
				"      pkgs = import nixpkgs {",
				"        system = \"x86_64-linux\";",
				"        overlays = [",
				"          overlay0.overlays.default",
				"          overlay1.overlays.default",
				"        ];",
				"      };",
				"    in {",
				"      devShells.\"x86_64-linux\".default = pkgs.mkShell {",
				"        packages = [",
				"              pkgs.\"hello\"",
				"        ];",
				"      };",
				"    };",
				"}",
			],
			"\n",
		),
		overlays: ["github:example/first", "github:example/second"],
		pkgs: ["hello"],
	},
]

expect List.all(
	shell_nix_render_cases,
	|case| ShellNix.render_nix(case.pkgs, case.overlays, "x86_64-linux") == case.expected,
)

invalid_package_cases = [
	{
		expected: "shell package attribute paths must not contain empty segments",
		pkgs: ["rocpkgs..nightly"],
	},
	{
		expected: "shell package attribute paths contain characters unsafe for Nix output",
		pkgs: ["rocpkgs.$nightly"],
	},
]

expect List.all(
	invalid_package_cases,
	|case|
		match ShellNix.validate_packages(case.pkgs) {
			Err(diagnostic) => diagnostic.message == case.expected
			Ok(_) => Bool.False
		},
)

invalid_overlay_cases = [
	{
		expected: "shell overlay references must not be empty",
		overlays: [""],
	},
	{
		expected: "shell overlay references contain characters unsafe for Nix output",
		overlays: ["github:example/overlay$unsafe"],
	},
]

expect List.all(
	invalid_overlay_cases,
	|case|
		match ShellNix.validate_overlays(case.overlays) {
			Err(diagnostic) => diagnostic.message == case.expected
			Ok(_) => Bool.False
		},
)
