# Planning test for entering a pure Guix shell.
import guix.GuixPlugin
import util.PlanCheck

ShellGuixTest := [].{}

# A Guix shell requests its packages from a pure environment.
expect {
	kaifile =
		\\shell guix {
		\\  packages: ["hello", "git"]
		\\}
	PlanCheck.plan(
		{
			definitions: [GuixPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["shell", "guix"],
		Succeeds([
			ContainsStep(
				RunProgram({
					arguments: ["shell", "--pure", "hello", "git"],
					program: "guix",
				}),
			),
		]),
	)
}
