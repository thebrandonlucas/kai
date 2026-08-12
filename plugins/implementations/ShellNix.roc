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
						match Body.get_strings(context.config, "pkgs") {
							Err(_) => Err({ byte_offset: None, message: "validated shell configuration is missing 'pkgs'" })
							Ok(pkgs) => {
								ShellNix.validate_packages(pkgs)?
								Ok(ShellNix.render_result(pkgs, selected_target.system))
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
				} else {
					ShellNix.validate_packages(rest)
				}
			}

	render_result : List(Str), Str -> PluginApi.RenderResult
	render_result = |pkgs, system|
		PluginApi.RenderResult.{
			outputs: [{ name: "flake", text: ShellNix.render_nix(pkgs, system) }],
			requested_packages: pkgs,
		}

	render_nix : List(Str), Str -> Str
	render_nix = |pkgs, system| {
		package_lines = pkgs.map(
			|pkg| "              nixpkgs.\"legacyPackages\".\"${system}\".\"${pkg}\"",
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
}
