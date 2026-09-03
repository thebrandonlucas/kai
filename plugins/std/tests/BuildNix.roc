# Data-driven tests for ensuring Kaifile creates a valid flake.nix
# `kai build <...>` should find the Kaifile block, translate it to
# a flake, then run `nix build` under the hood.
import std.StdPlugin
import Check

BuildNix := [].{}

# A Kaifile build block renders the expected Nix flake.
expect {
	wisecow_command = Str.join_with(
		[
			"printf '#!%s\\\\n%s | %s\\\\n' ",
			"\\\"$(command -v sh)\\\" \\\"$(command -v fortune)\\\" ",
			"\\\"$(command -v cowsay)\\\" > wisecow && chmod +x wisecow",
		],
		"",
	)
	wisecow_kaifile_string =
		\\environment cow {
		\\  packages: ["cowsay", "fortune"]
		\\}
		\\
		\\build wisecow {
		\\  environment: cow
		\\  run: [
		\\    "sh",
		\\    "-c",
		\\    "${wisecow_command}"
		\\  ]
		\\  output: "wisecow"
		\\}

	nixpkgs_for_system = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_wisecow_flake_string =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    legacyPackages."x86_64-linux" = nixpkgs.legacyPackages."x86_64-linux";
		\\    devShells."x86_64-linux".default = ${nixpkgs_for_system}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."x86_64-linux"."cowsay"
		\\              nixpkgs."legacyPackages"."x86_64-linux"."fortune"
		\\      ];
		\\    };
		\\  };
		\\}

	checked = Check.write(
		[StdPlugin.plugin],
		{
			args: ["build", "wisecow"],
			arch: X64,
			kaifile: wisecow_kaifile_string,
			os: LINUX,
			workspace_root: ".kai",
		},
		{
			contents: expected_wisecow_flake_string,
			path: ".kai/builds/wisecow/flake.nix",
		},
	)

	checked.actual == checked.expected
}
