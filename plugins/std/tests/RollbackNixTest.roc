# Planning test for restoring the previous local NixOS generation.
import std.StdPlugin
import util.PlanCheck

RollbackNixTest := [].{}

# Rollback confirms before switching to the previous system generation.
expect {
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile: "",
			workspace_root: ".kai",
		},
		["system", "rollback"],
		Succeeds([
			ContainsStepsInOrder([
				Confirm("Roll back this host to its previous NixOS generation?"),
				RunProgram({
					arguments: ["switch", "--rollback"],
					program: "nixos-rebuild",
				}),
			]),
		]),
	)
}
