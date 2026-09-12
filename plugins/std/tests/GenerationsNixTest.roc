# Data-driven test for listing system generations with Nix.
import std.StdPlugin
import util.PlanCheck

GenerationsNixTest := [].{}

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
