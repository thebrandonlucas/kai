# A source can be a directory in the project: `kai update` locks ./cows, and
# `kai build kai` draws its cow from it, read through $KAI_INPUTS. The lock
# pins the directory's contents, so run `kai update` again after changing it.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("path-source"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Source("cows", "path:./cows"),
	Environment("cow", [Tools(["cowsay"])]),
	Build(
		"kai",
		[
			Use("cow"),
			Inputs(["cows"]),
			Run(["sh", "-c", "cowsay -f \"$KAI_INPUTS/cows/kai.cow\" moo > kai.txt"]),
			Output("kai.txt"),
		],
	),
])
