import kai.Plugin as PluginApi

# The standard plugin is pure. kai.roc imports its typed configuration
# constructor; only the generic executor performs the resulting actions.
# TODO: it's explicitly limited to nix for now. This might be long-term
# desirable behavior, but we may want to consider providing guix support
# out of the box as a fallback. Or keep it as a separate Guix plugin/binary.
StdPlugin := [].{
	ShellConfig : { pkgs : List(Str) }

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
		rendered_config: StdPlugin.render_nix(
			shell_config.pkgs,
		),
	}

	render_nix : List(Str) -> Str
	render_nix = |pkgs| {
		package_lines = pkgs.map(
			|pkg| "              nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"${pkg}\"",
		)
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
			"  outputs = { nixpkgs, ... }: {",
			"    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {",
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

expect {
	module_config = StdPlugin.shell({ pkgs: ["hello"] })
	module_config.implementation == StdPlugin.nix_shell and
		module_config.rendered_config.contains(".\"hello\"")
}
