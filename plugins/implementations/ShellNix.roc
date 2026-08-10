import parser.Body
import parser.Config
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
		blocks = Config.scan(config_text) ? |_| InvalidConfig
		selection = ShellNix.select_shell(blocks, section)?
		match selection {
			Missing => Err(InvalidConfig)
			Selected(block) => {
				config = Body.parse(ShellCommand.body, block.body) ? |_| InvalidConfig
				Ok(config)
			}
		}
	}

	select_shell : List(Config.Block), Str -> Try(Config.Selection, [InvalidConfig])
	select_shell = |blocks, section| {
		host_selection = Config.select_exact(blocks, ["on", section]) ? |_| InvalidConfig
		match host_selection {
			Missing => {
				fallback = Config.select_exact(blocks, ["shell"]) ? |_| InvalidConfig
				Ok(fallback)
			}
			Selected(host) => {
				nested = Config.scan(host.body) ? |_| InvalidConfig
				nested_selection = Config.select_exact(nested, ["shell"]) ? |_| InvalidConfig
				match nested_selection {
					Missing => {
						fallback = Config.select_exact(blocks, ["shell"]) ? |_| InvalidConfig
						Ok(fallback)
					}
					Selected(shell) => Ok(Selected(shell))
				}
			}
		}
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
