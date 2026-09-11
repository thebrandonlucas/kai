# Data-driven test for running declared workflow steps through Nix.
import std.StdPlugin
import util.Check

WorkflowNixTest := [].{}

# A workflow plans its declared commands in order.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\}
		\\
		\\task greet {
		\\  environment: "dev"
		\\  run: ["hello"]
		\\}
		\\
		\\workflow all {
		\\  steps: ["run greet", "update"]
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["workflow", "all"],
		Succeeds([
			ContainsStepsInOrder([
				PrintLine("workflow: run greet"),
				RunProgram({
					arguments: [
						"develop",
						"path:.kai#default",
						"--no-update-lock-file",
						"--command",
						"hello",
					],
					program: "nix",
				}),
				PrintLine("workflow: update"),
				RunProgram({
					arguments: [
						"flake",
						"update",
						"--flake",
						"path:.kai",
						"--reference-lock-file",
						"kai.lock",
						"--output-lock-file",
						"kai.lock",
					],
					program: "nix",
				}),
			]),
		]),
	)
}
