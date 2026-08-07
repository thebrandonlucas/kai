import kai.Plugin as PluginApi

# TODO: the stdplugin itself should be modular and 
# have each command pluggable/reusable by other modules?
# Or should each plugin itself just be one command which 
# we compile together at the end?

# The standard plugin is pure. It shares the same planning contract as custom
# plugins; only the generic executor performs the resulting actions.
# TODO: it's explicitly limited to nix for now. This might be long-term
# desirable behavior, but we may want to consider providing guix support
# out of the box as a fallback. Or keep it as a separate Guix plugin/binary.
StdPlugin := [].{
	ShellConfig : { pkgs : List(Str) }
	ParsedShellConfig := { pkgs : List(Str) }.{
		parser_for : _
	}
	Target : { section : Str, system : Str }

	plugin : PluginApi.Plugin
	plugin = PluginApi.Plugin.Module({ name: "std", plan: StdPlugin.plan })

	# our new plugin defines whether this is a decision passed
	# onto the user or not
	# i.e. must the user specify it? and is it optional if they don't
	# i.e. fallback?

	# every plugin must now specify:
	# - keywords
	# - what subkeywords the keywords contain
	# - primitive types of the keywords/subkeywords
	# - 
	plan : Str, List(Str), PluginApi.HostOs, PluginApi.HostArch -> Try(PluginApi.Plan, PluginApi.Error)
	plan = |source, args, os, arch|
		match args {
			["shell"] => {
				target = StdPlugin.target(os, arch)?
				config = StdPlugin.parse(source, target.section)?
				Ok(PluginApi.lower(nix_shell, StdPlugin.render_nix(config.pkgs, target.system)))
			}
			_ => Err(UnknownCommand)
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

		match StdPlugin.find_shell(lines, "on ${section} {") {
			Ok(shell_config) => Ok(shell_config)
			Err(InvalidConfig) => StdPlugin.find_default_shell(lines)
		}
	}

	find_shell : List(Str), Str -> Try(ShellConfig, [InvalidConfig])
	find_shell = |lines, section_line|
		match lines {
			[] => Err(InvalidConfig)
			[first, "shell {", pkgs_line, ..] if first == section_line and pkgs_line.starts_with("pkgs:") =>
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
	nix = PluginApi.Backend.{ name: "nix" }

	backends = [nix]

	shell_command : PluginApi.Command
	shell_command = PluginApi.Command.{
		argv: [],
		backends,
		name: "shell",
	}

	nix_shell : PluginApi.Implementation
	nix_shell = PluginApi.Implementation.{
		actions: [
			WriteConfigUtf8({ path: ".kai/flake.nix" }),
			Exec({
				args: ["develop", "path:.kai#default"],
				command: nix.name,
			}),
		],
		backend: nix,
		command: shell_command,
		requirement: Program(nix.name),
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

expect StdPlugin.plan(config, ["shell"], WINDOWS, X64) == Err(UnsupportedPlatform)
