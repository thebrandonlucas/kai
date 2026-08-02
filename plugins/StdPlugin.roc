import kai.Plugin as PluginApi

# The standard plugin is pure. kai.roc imports its typed configuration
# constructor; only the generic executor performs the resulting actions.
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
	}

	# Lower typed shell configuration into the platform's shared ModuleConfig
	# shape. The platform turns the implementation template into a concrete plan.
	shell : ShellConfig -> { implementation : PluginApi.Implementation, rendered_config : Str }
	shell = |shell_config| {
		implementation: nix_shell,
		rendered_config: StdPlugin.render_nix(shell_config.pkgs),
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
