# Pure configuration frontend for StdPlugin.
StdConfig := [].{
	ShellConfig : { pkgs : List(Str) }

	shell : ShellConfig -> { backend : Str, command : Str, source : Str }
	shell = |shell_config| {
		backend: "nix",
		command: "shell",
		source: render_nix(shell_config.pkgs),
	}
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

expect {
	module_config = StdConfig.shell({ pkgs: ["hello"] })
	module_config.command == "shell" and
		module_config.backend == "nix" and
			module_config.source.contains(".\"hello\"")
}
