import kai.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Shell as ShellCommand

ShellNix := [].{
	Target : { section : Str, system : Str }

	# A Plan transforms a generic command/backend combo
	# into a specific set of instructions for the final
	# kai binary to perform (including instructions for
	# side-effects)
	plan :
		Str,
		PluginApi.HostOs,
		PluginApi.HostArch ->
			Try(PluginApi.Plan, PluginApi.Error)
	plan = |config_text, os, arch| {
		target = ShellNix.target(os, arch)?
		config = ShellNix.parse(config_text, target.section)?
		context = PluginApi.RenderContext.{
			args: [],
			config,
			config_block: SelectedConfigBlock({
				body: config_text,
				location: { byte_offset: 0, column: 1, line: 1 },
			}),
			host_arch: arch,
			host_os: os,
		}
		# rendering gets the rendered output (e.g. flake.nix str to write)
		rendered = ShellNix.renderer(context) ? |_| InvalidConfig
		# lowering turns it into a specific plan: it matches the high-level
		# implementation instructions with the rendered content and
		# provides side-effect instructions
		lowered = PluginApi.lower(ShellNix.implementation, rendered) ? |_| InvalidConfig
		Ok(lowered)
	}

	target : PluginApi.HostOs, PluginApi.HostArch -> Try(Target, [UnsupportedPlatform])
	target = |os, arch|
		match (os, arch) {
			(LINUX, X64) => Ok({ section: "linux", system: "x86_64-linux" })
			(LINUX, AARCH64) => Ok({ section: "linux", system: "aarch64-linux" })
			(MACOS, X64) => Ok({ section: "macos", system: "x86_64-darwin" })
			(MACOS, AARCH64) => Ok({ section: "macos", system: "aarch64-darwin" })
			_ => Err(UnsupportedPlatform)
		}

	parse : Str, Str -> Try(Body.Configuration, [InvalidConfig])
	parse = |config_text, section| {
		lines = config_text
			.split_on("\n")
			.map(
				|line|
					match line.find_first("#") {
						Ok({ before, after: _ }) => before.trim()
						Err(NotFound) => line.trim()
					},
			)
			.keep_if(|line| !line.is_empty())

		match ShellNix.find_shell(lines, "on ${section} {") {
			Ok(shell_config) => Ok(shell_config)
			Err(InvalidConfig) => ShellNix.find_default_shell(lines)
		}
	}

	find_shell : List(Str), Str -> Try(Body.Configuration, [InvalidConfig])
	find_shell = |lines, section_line|
		match lines {
			[] => Err(InvalidConfig)
			[first, "shell {", body_line, ..] if first == section_line =>
				ShellNix.parse_body(body_line)
			[_, .. as rest] => ShellNix.find_shell(rest, section_line)
		}

	find_default_shell : List(Str) -> Try(Body.Configuration, [InvalidConfig])
	find_default_shell = |lines|
		match lines {
			[] => Err(InvalidConfig)
			["shell {", body_line, ..] => ShellNix.parse_body(body_line)
			[_, .. as rest] => ShellNix.find_default_shell(rest)
		}

	parse_body : Str -> Try(Body.Configuration, [InvalidConfig])
	parse_body = |body| {
		config = Body.parse(ShellCommand.body, body) ? |_| InvalidConfig
		Ok(config)
	}

	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [
			WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
			Exec({
				args: ["develop", "path:.kai#default"],
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
