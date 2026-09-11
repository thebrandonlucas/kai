# Data-driven test for entering an inline Nix developer shell.
import std.StdPlugin
import util.Check

ShellNixTest := [].{}

# An inline shell renders its flake and enters the default development shell.
expect {
	kaifile =
		\\shell nix {
		\\  packages: ["hello"]
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    devShells."x86_64-linux".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."x86_64-linux"."hello"
		\\      ];
		\\    };
		\\  };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["shell", "nix"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
			ContainsStep(
				RunProgram({
					arguments: [
						"develop",
						"path:.kai#default",
						"--no-update-lock-file",
					],
					program: "nix",
				}),
			),
		]),
	)
}

# An error in Kaifile shows its' source code and location.
expect {
	kaifile =
		\\shell {
		\\  packages: ["cowsay"],
		\\}
	expected =
		\\error: unexpected ','; fields are separated by newlines
		\\  --> Kaifile:2:23
		\\  |
		\\2 |   packages: ["cowsay"],
		\\  |                       ^

	Check.error(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["shell"],
		expected,
	)
}

# A field type error points to the invalid value.
expect {
	kaifile =
		\\shell {
		\\  packages: "cowsay"
		\\}
	expected =
		\\error: field 'packages' must be a list of strings
		\\  --> Kaifile:2:13
		\\  |
		\\2 |   packages: "cowsay"
		\\  |             ^

	Check.error(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["shell"],
		expected,
	)
}
