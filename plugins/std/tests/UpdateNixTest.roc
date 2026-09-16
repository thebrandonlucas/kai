# Data-driven test for updating Nix project dependencies.
import std.StdPlugin
import util.PlanCheck

UpdateNixTest := [].{}

# Updating writes the dependency flake, updates the shared lock, and locks it.
expect {
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = _: {};
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile: "",
			workspace_root: ".kai",
		},
		["update"],
		Succeeds([
			ContainsStepsInOrder([
				WriteFile({ contents: expected_file, path: ".kai/flake.nix" }),
				RunProgram({
					arguments: [
						"flake",
						"update",
						"--flake",
						"path:.kai",
						"--reference-lock-file",
						"Kaifile.lock",
						"--output-lock-file",
						"Kaifile.lock",
					],
					program: "nix",
				}),
				PrintLine("wrote: Kaifile.lock"),
				RunProgram({
					arguments: [
						"flake",
						"lock",
						"path:.kai",
						"--reference-lock-file",
						"Kaifile.lock",
						"--output-lock-file",
						".kai/flake.lock",
					],
					program: "nix",
				}),
			]),
		]),
	)
}

# A top-level Nix backend block configures command-only update rendering.
expect {
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
		\\  outputs = _: {};
		\\}
	kaifile =
		\\backend nix {
		\\  packages: "github:NixOS/nixpkgs/nixos-unstable-small"
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["update"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# Nix backend configuration accepts only a packages string.
expect {
	kaifile =
		\\backend nix {
		\\  source: "github:NixOS/nixpkgs/nixos-unstable-small"
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["update"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "update",
				location: At({ byte_offset: 16, column: 3, line: 2 }),
				message: "unknown field 'source'",
				plugin: "std",
			}),
		),
	)
}

# Nix package sources must be nonempty.
expect {
	kaifile =
		\\backend nix {
		\\  packages: ""
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["update"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "update",
				location: At({ byte_offset: 13, column: 14, line: 1 }),
				message: "Nix package source must not be empty",
				plugin: "std",
			}),
		),
	)
}

# Nix package sources reject text unsafe in Nix double-quoted strings.
expect {
	kaifile =
		\\backend nix {
		\\  packages: "github:NixOS/nixpkgs/$unsafe"
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["update"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "update",
				location: At({ byte_offset: 13, column: 14, line: 1 }),
				message: "Nix package source contains characters unsafe for Nix output",
				plugin: "std",
			}),
		),
	)
}
