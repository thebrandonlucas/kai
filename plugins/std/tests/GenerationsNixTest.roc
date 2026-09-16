# Data-driven test for listing system generations with Nix.
import std.StdPlugin
import util.PlanCheck

GenerationsNixTest := [].{}

# Generations asks nixos-rebuild to list the local system generations.
expect {
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile: "",
			workspace_root: ".kai",
		},
		["system", "generations"],
		Succeeds([
			ContainsStep(
				RunProgram({
					arguments: ["list-generations"],
					program: "nixos-rebuild",
				}),
			),
		]),
	)
}

# Backend configuration is validated even when a command emits no flake.
expect {
	kaifile =
		\\backend nix {
		\\  unknown: "value"
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["system", "generations"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "generations",
				location: At({ byte_offset: 16, column: 3, line: 2 }),
				message: "unknown field 'unknown'",
				plugin: "std",
			}),
		),
	)
}
