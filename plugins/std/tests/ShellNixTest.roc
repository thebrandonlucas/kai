# Data-driven test for entering an inline Nix developer shell.
import std.StdPlugin
import util.PlanCheck

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

	PlanCheck.plan(
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

# An inline shell inherits its environment and keeps its own additions.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["git"]
		\\}
		\\shell {
		\\  environment: dev
		\\  packages: ["roc"]
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    devShells."x86_64-linux".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."x86_64-linux"."git"
		\\              nixpkgs."legacyPackages"."x86_64-linux"."roc"
		\\      ];
		\\    };
		\\  };
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["shell"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# An inline shell needs packages, an environment, or both.
expect {
	kaifile =
		\\shell {
		\\}
	expected =
		\\error: shell requires packages or an environment
		\\usage: kai shell [ENVIRONMENT]
		\\example: kai shell

	PlanCheck.error(
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

	PlanCheck.error(
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

	PlanCheck.error(
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
