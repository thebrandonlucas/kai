# Kaifile.roc is ordinary Roc, so settings can come from other modules: this
# project's tasks come from CowTasks.roc, which any project could import.
# `kai run moo` and `kai run say -- hello` run them.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import CowTasks
import std.Std

kaifile = Std.kaifile(
	[
		Name("modules"),
		Systems(["x86_64-linux", "aarch64-linux"]),
		Environment("cow", [Tools(["cowsay"])]),
		Shell("default", [Use("cow")]),
	].concat(CowTasks.settings("cow")),
)
