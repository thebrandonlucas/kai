import parser.Body
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

	prepare_actions : List(PluginApi.ActionTemplate)
	prepare_actions = [
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
	]

	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: prepare_actions.concat([
			Exec({
				args: [
					"develop",
					"path:.kai#default",
					"--no-update-lock-file",
				],
				command: NixBackend.backend.name,
			}),
		]),
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
							Ok(pkgs) => {
								ShellNix.validate_packages(pkgs)?
								Ok(ShellNix.render_result(pkgs, selected_target.system))
							}
							Err(_) =>
								match Body.get_strings(context.config, "pkgs") {
									Err(_) => Err({ byte_offset: None, message: "validated shell configuration is missing 'pkgs'" })
									Ok(pkgs) => {
										ShellNix.validate_shell_packages(pkgs)?
										Ok(ShellNix.render_result(pkgs, selected_target.system))
									}
								}
							}
					}
			}

	validate_packages : List(Str) -> Try({}, PluginApi.RendererDiagnostic)
	validate_packages = |pkgs| ShellNix.validate_package_names(pkgs, "environment package names must not be empty")

	validate_shell_packages : List(Str) -> Try({}, PluginApi.RendererDiagnostic)
	validate_shell_packages = |pkgs| ShellNix.validate_package_names(pkgs, "shell package names must not be empty")

	validate_package_names : List(Str), Str -> Try({}, PluginApi.RendererDiagnostic)
	validate_package_names = |pkgs, message|
		match pkgs {
			[] => Ok({})
			[first, .. as rest] =>
				if first.is_empty() {
					Err({ byte_offset: None, message })
				} else {
					ShellNix.validate_package_names(rest, message)
				}
			}

	render_result : List(Str), Str -> PluginApi.RenderResult
	render_result = |pkgs, system|
		PluginApi.RenderResult.{
			actions: [],
			outputs: [{ name: "flake", text: ShellNix.render_nix(pkgs, system) }],
			requested_packages: pkgs,
		}

	render_nix : List(Str), Str -> Str
	render_nix = |pkgs, system| {
		escaped_system = ShellNix.escape_nix_string(system)
		package_lines = pkgs.map(
			|pkg| "              nixpkgs.\"legacyPackages\".\"${escaped_system}\".\"${ShellNix.escape_nix_string(pkg)}\"",
		)
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
			"  outputs = { nixpkgs, ... }: {",
			"    devShells.\"${escaped_system}\".default = nixpkgs.legacyPackages.\"${escaped_system}\".mkShell {",
			"      packages = [",
		].concat(package_lines).concat([
			"      ];",
			"    };",
			"  };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	escape_nix_string : Str -> Str
	escape_nix_string = |value| Str.from_utf8_lossy(ShellNix.escape_nix_bytes(value.to_utf8(), 0, []))

	escape_nix_bytes : List(U8), U64, List(U8) -> List(U8)
	escape_nix_bytes = |bytes, index, escaped|
		if index >= bytes.len() {
			escaped
		} else {
			byte = bytes.get(index) ?? 0
			next = bytes.get(index + 1) ?? 0
			if byte == 34 or byte == 92 {
				ShellNix.escape_nix_bytes(bytes, index + 1, escaped.concat([92, byte]))
			} else if byte == 36 and next == 123 {
				ShellNix.escape_nix_bytes(bytes, index + 1, escaped.concat([92, byte]))
			} else {
				ShellNix.escape_nix_bytes(bytes, index + 1, escaped.append(byte))
			}
		}
}
