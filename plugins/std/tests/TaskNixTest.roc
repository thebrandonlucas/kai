# Data-driven test for running a declared task through Nix.
import std.StdPlugin
import util.PlanCheck

TaskNixTest := [].{}

# A task runs its command inside the referenced development environment.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\}
		\\
		\\task greet {
		\\  environment: "dev"
		\\  run: ["hello", "Kai"]
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["run", "greet"],
		Succeeds([
			ContainsStep(
				RunProgram({
					arguments: [
						"develop",
						"path:.kai#default",
						"--no-update-lock-file",
						"--command",
						"hello",
						"Kai",
					],
					program: "nix",
				}),
			),
		]),
	)
}
