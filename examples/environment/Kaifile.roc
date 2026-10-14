# Environments name reusable sets of tools. Shells, tasks and builds pick one
# by name: `kai shell pokemon`, `kai run moo`, `kai run pika`.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("environment"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay"])]),
	Environment("pokemon", [Tools(["pokemonsay"])]),
	Shell("default", [Use("cow")]),
	Shell("pokemon", [Use("pokemon")]),
	Task("moo", [Use("cow"), Run(["cowsay", "moo"])]),
	Task("pika", [Use("pokemon"), Run(["pokemonsay", "-p", "Pikachu", "pika!"])]),
])
