# An app inside a workspace: its Kaifile sits in apps/greeter, and
# BuildRoot("../..") lets its build read lib/ at the workspace root. The build
# copies the workspace and runs from its root, so its Files, Run and Output
# name paths from there. Run `kai build greeting` in apps/greeter.
app [kaifile] {
	pf: platform "../../../../platform/main.roc",
	std: "../../../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("workspace"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	BuildRoot("../.."),
	Environment("cow", [Tools(["cowsay"])]),
	Build(
		"greeting",
		[
			Use("cow"),
			Files(["lib", "apps/greeter"]),
			Run(["sh", "-c", "sh apps/greeter/greet.sh > greeting.txt"]),
			Output("greeting.txt"),
		],
	),
])
