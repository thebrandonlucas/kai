# Data-driven test for updating Nix project dependencies.
import std.StdPlugin
import util.Check

UpdateNixTest := [].{}

# Updating writes the dependency flake, updates the shared lock, and locks it.
expect {
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = _: {};
		\\}

	Check.plan(
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
