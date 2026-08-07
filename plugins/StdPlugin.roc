import kai.Plugin as PluginApi

StdPlugin := [].{
	ShellConfig : { pkgs : List(Str) }
	ParsedShellConfig := { pkgs : List(Str) }.{
		parser_for : _
	}
	Target : { section : Str, system : Str }

	plugin : PluginApi.Plugin
	plugin = PluginApi.Plugin.Module({
		definition,
		plan: StdPlugin.plan,
	})

	# A plan is a more concrete version of what to do 
	# for a given OS and arch, since different hosts 
	# have different requirements sometimes and must be 
	# handled case by case
	plan :
		Str,
		List(Str),
		PluginApi.HostOs,
		PluginApi.HostArch ->
			Try(
				PluginApi.Plan,
				PluginApi.Error,
			)
	plan = |source, args, os, arch|
		match args {
			["shell"] => {
				target = StdPlugin.target(os, arch)?
				config = StdPlugin.parse(source, target.section)?
				rendered = StdPlugin.render_result(config.pkgs, target.system)
				match PluginApi.lower(nix_shell, rendered) {
					Ok(lowered) => Ok(lowered)
					Err(_) => Err(InvalidConfig)
				}
			}
			_ => Err(UnknownCommand)
		}

	target :
		PluginApi.HostOs,
		PluginApi.HostArch ->
			Try(
				Target,
				[UnsupportedPlatform],
			)
	target = |os, arch|
		match (os, arch) {
			(LINUX, X64) => Ok({ section: "linux", system: "x86_64-linux" })
			(LINUX, AARCH64) => Ok({ section: "linux", system: "aarch64-linux" })
			(MACOS, X64) => Ok({ section: "macos", system: "x86_64-darwin" })
			(MACOS, AARCH64) => Ok({ section: "macos", system: "aarch64-darwin" })
			_ => Err(UnsupportedPlatform)
		}

	parse : Str, Str -> Try(ShellConfig, [InvalidConfig])
	parse = |source, section| {
		lines = source
			.split_on("\n")
			.map(
				|line|
					match line.find_first("#") {
						Ok({ before, after: _ }) => before.trim()
						Err(NotFound) => line.trim()
					},
			)
			.keep_if(|line| !line.is_empty())

		# Match on the "on" keyword (TODO: enumerate the keywords)
		# somewhere so their parsing isn't hardcoded in strings like this
		match StdPlugin.find_shell(lines, "on ${section} {") {
			Ok(shell_config) => Ok(shell_config)
			Err(InvalidConfig) => StdPlugin.find_default_shell(lines)
		}
	}

	find_shell : List(Str), Str -> Try(ShellConfig, [InvalidConfig])
	find_shell = |lines, section_line|
		match lines {
			[] => Err(InvalidConfig)
			[first, "shell {", pkgs_line, ..] if first == section_line
				and pkgs_line.starts_with("pkgs:") =>
				StdPlugin.parse_pkgs(pkgs_line)
			[_, .. as rest] => StdPlugin.find_shell(rest, section_line)
		}

	find_default_shell : List(Str) -> Try(ShellConfig, [InvalidConfig])
	find_default_shell = |lines|
		match lines {
			[] => Err(InvalidConfig)
			["shell {", pkgs_line, ..] if pkgs_line.starts_with("pkgs:") => StdPlugin.parse_pkgs(pkgs_line)
			[_, .. as rest] => StdPlugin.find_default_shell(rest)
		}

	parse_pkgs : Str -> Try(ShellConfig, [InvalidConfig])
	parse_pkgs = |pkgs_line| {
		decoded : Try(ParsedShellConfig, Json.ParseErr)
		decoded = Json.parse("{\"pkgs\":${pkgs_line.drop_prefix("pkgs:").trim()}}")
		match decoded {
			Ok({ pkgs }) => Ok({ pkgs: pkgs })
			Err(_) => Err(InvalidConfig)
		}
	}

	nix : PluginApi.Backend
	nix = PluginApi.Backend.{
		determinate_system: PluginApi.DeterminateSystem.{
			default_package_source: "nixpkgs",
			driver: Program("nix"),
			kind: Nix,
		},
		fallback: NoFallback,
		name: "nix",
		required_packages: [],
	}

	backends = [nix]

	shell_command : PluginApi.Command
	shell_command = PluginApi.Command.{
		argument_policy: NoArguments,
		default_backend: nix.name,
		name: "shell",
		source: RequiredSource("shell"),
	}

	nix_shell : PluginApi.Implementation
	nix_shell = PluginApi.Implementation.{
		actions: [
			WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
			Exec({
				args: ["develop", "path:.kai#default"],
				command: nix.name,
			}),
		],
		backend: nix.name,
		command: shell_command.name,
		renderer: StdPlugin.registry_renderer,
	}

	definition : PluginApi.Definition
	definition = PluginApi.Definition.{
		backends,
		commands: [shell_command],
		implementations: [nix_shell],
		name: "std",
	}

	registry_renderer : PluginApi.Renderer
	registry_renderer = |context|
		match context.source {
			NoSource => Err({ byte_offset: None, message: "shell configuration is required" })
			SelectedSource({ body, location: _ }) =>
				match StdPlugin.target(context.host_os, context.host_arch) {
					Err(_) => Err({ byte_offset: None, message: "unsupported shell platform" })
					Ok(selected_target) =>
						match StdPlugin.parse("shell {\n${body}\n}", selected_target.section) {
							Err(_) => Err({ byte_offset: None, message: "invalid shell configuration" })
							Ok(config) => Ok(StdPlugin.render_result(config.pkgs, selected_target.system))
						}
					}
			}

	render_result : List(Str), Str -> PluginApi.RenderResult
	render_result = |pkgs, system|
		PluginApi.RenderResult.{
			outputs: [{ name: "flake", text: StdPlugin.render_nix(pkgs, system) }],
			requested_packages: pkgs,
		}

	# TODO: Version the shared plugin contract and validate that a plugin's
	# configuration and command interfaces remain compatible.
	shell : ShellConfig -> {
		implementation : PluginApi.Implementation,
		rendered_config : Str,
	}
	shell = |shell_config| {
		implementation: nix_shell,
		rendered_config: StdPlugin.render_nix(shell_config.pkgs, "x86_64-linux"),
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

config = "on linux {\n  shell {\n    pkgs: [\"cowsay\"]\n  }\n}\non macos {\n  shell {\n    pkgs: [\"pokemonsay\"]\n  }\n}\nshell nix {\n}\n"

# TODO: for each combination of hosts, check that the output strings 
# are byte for byte identical?
expect {
	result = StdPlugin.plan(config, ["shell"], MACOS, AARCH64)
	match result {
		Ok({ actions: [WriteUtf8({ content, path: _ }), Exec(_)] }) =>
			content.contains("devShells.\"aarch64-darwin\"") and content.contains(".\"pokemonsay\"")
		_ => Bool.False
	}
}

expect {
	simple_config = "shell {\n\tpkgs: [\"cowsay\", \"fortune\"]\n}"
	result = StdPlugin.plan(simple_config, ["shell"], LINUX, X64)
	match result {
		Ok({ actions: [WriteUtf8({ content, path: _ }), Exec(_)] }) =>
			content.contains("devShells.\"x86_64-linux\"") and
				content.contains(".\"cowsay\"") and
					content.contains(".\"fortune\"")
		_ => Bool.False
	}
}

expect StdPlugin.parse(config, "linux") == Ok({ pkgs: ["cowsay"] })

expect StdPlugin.plan(config, ["build"], LINUX, X64) == Err(UnknownCommand)

expect StdPlugin.plan(config, ["shell"], OTHER("unsupported"), X64) == Err(UnsupportedPlatform)
