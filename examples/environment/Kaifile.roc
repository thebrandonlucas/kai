# Environments name reusable sets of tools. Shells, tasks and builds pick one
# by name: `kai shell pokemon`, `kai run moo`, `kai run pika`.
# `OnSystems` adds tools and variables on some systems only, so one
# environment can differ between Linux and macOS: strace, which has no macOS
# build, is there only on Linux, and `kai run where` says which it is.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("environment"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	Environment("cow", [Tools(["cowsay"])]),
	Environment("pokemon", [Tools(["pokemonsay"])]),
	Environment(
		"local",
		[
			Tools(["cowsay"]),
			OnSystems(
				["x86_64-linux", "aarch64-linux"],
				[Tools(["strace"]), Env([("KERNEL", "Linux")])],
			),
			OnSystems(["aarch64-darwin"], [Env([("KERNEL", "Darwin")])]),
		],
	),
	Shell("default", [Use("cow")]),
	Shell("pokemon", [Use("pokemon")]),
	Task("moo", [Use("cow"), Run(["cowsay", "moo"])]),
	Task("pika", [Use("pokemon"), Run(["pokemonsay", "-p", "Pikachu", "pika!"])]),
	Task(
		"where",
		[
			Use("local"),
			Run(["sh", "-c", "cowsay \"moo from $KERNEL\""]),
		],
	),
])
