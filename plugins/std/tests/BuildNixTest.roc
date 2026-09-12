# Data-driven tests for ensuring Kaifile creates a valid flake.nix
# `kai build <...>` should find the Kaifile block, translate it to
# a flake, then run `nix build` under the hood.
import std.StdPlugin
import util.PlanCheck

BuildNixTest := [].{}

# A Kaifile build block renders the expected Nix flake.
expect {
	shell = \\$(command -v sh)
	fortune = \\$(command -v fortune)
	cowsay = \\$(command -v cowsay)
	executable = \\> wisecow && chmod +x wisecow
	wisecow_command =
		\\printf '#!%s\\\\n%s | %s\\\\n' ${shell} ${fortune} ${cowsay} ${executable}

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

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile: wisecow_kaifile_string,
			workspace_root: ".kai",
		},
		["build", "wisecow"],
		Succeeds([
			WritesExactly({
				contents: expected_wisecow_flake_string,
				path: ".kai/builds/wisecow/flake.nix",
			}),
		]),
	)
}

# A missing argument shows the command usage and an example.
expect {
	expected =
		\\error: build requires exactly one artifact argument
		\\usage: kai build <ARTIFACT>
		\\example: kai build <my-artifact>

	PlanCheck.error(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile: "",
			workspace_root: ".kai",
		},
		["build"],
		expected,
	)
}
