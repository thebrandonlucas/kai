import kai.Plugin as PluginApi

# The standard plugin is pure. kai.roc imports its typed configuration
# constructor; only the generic executor performs the resulting actions.
# TODO: it's explicitly limited to nix for now. This might be long-term
# desirable behavior, but we may want to consider providing guix support
# out of the box as a fallback. Or keep it as a separate Guix plugin/binary.
StdPlugin := [].{
	ShellConfig : { pkgs : List(Str) }
	ParsedShellConfig := { pkgs : List(Str) }.{
		parser_for : _
	}
	HostOs : [LINUX, MACOS, WINDOWS, OTHER(Str)]
	HostArch : [X86, X64, ARM, AARCH64, OTHER(Str)]
	Target : { section : Str, system : Str }

	# our new plugin defines whether this is a decision passed
	# onto the user or not
	# i.e. must the user specify it? and is it optional if they don't
	# i.e. fallback?

	# every plugin must now specify:
	# - keywords
	# - what subkeywords the keywords contain
	# - primitive types of the keywords/subkeywords
	# - 
	plan : Str, List(Str), HostOs, HostArch -> Try(PluginApi.Plan, [InvalidConfig, UnknownCommand, UnsupportedPlatform, ..])
	plan = |source, args, os, arch|
		match args {
			["shell"] => {
				target = StdPlugin.target(os, arch)?
				config = StdPlugin.parse(source, target.section)?
				Ok(PluginApi.lower(nix_shell, StdPlugin.render_nix(config.pkgs, target.system)))
			}
			_ => Err(UnknownCommand)
		}

	target : HostOs, HostArch -> Try(Target, [UnsupportedPlatform])
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

		StdPlugin.find_shell(lines, "on ${section} {")
	}

	find_shell : List(Str), Str -> Try(ShellConfig, [InvalidConfig])
	find_shell = |lines, section_line|
		match lines {
			[] => Err(InvalidConfig)
			[first, "shell {", pkgs_line, ..] if first == section_line and pkgs_line.starts_with("pkgs:") => {
				decoded : Try(ParsedShellConfig, Json.ParseErr)
				decoded = Json.parse("{\"pkgs\":${pkgs_line.drop_prefix("pkgs:").trim()}}")
				match decoded {
					Ok({ pkgs }) => Ok({ pkgs: pkgs })
					Err(_) => Err(InvalidConfig)
				}
			}
			[_, .. as rest] => StdPlugin.find_shell(rest, section_line)
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

	# TODO: One thing to consider is that we need a way for plugin 
	# writers to consider how the kai.roc api might change 
	# as well. There should probably be a separation of 
	# fields all contained in the plugin. One called "config"
	# or something, and one called "cli", which defines interface between
	# them. we should also think about how we will verify/encode 
	# a structure s.t. the contract between them can be guaranteed to be 
	# accurately defined. we want to disallow the user from making broken
	# contracts between the cli and the kai.roc config.
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

expect StdPlugin.parse(config, "linux") == Ok({ pkgs: ["cowsay"] })

expect StdPlugin.plan(config, ["build"], LINUX, X64) == Err(UnknownCommand)

expect StdPlugin.plan(config, ["shell"], WINDOWS, X64) == Err(UnsupportedPlatform)
