# Overlays add or change packages before an environment picks its tools. The
# moo overlay, a small flake in overlays/moo, adds a `moo` package; only
# environments that list it in Overlays see it, so `kai run moo` works while
# plain cowsay environments are unaffected. Follows makes the overlay's own
# nixpkgs input the project's default package source, so it is not fetched or
# locked separately.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("overlay"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Overlay("moo", "path:./overlays/moo"),
	Follows("moo", "nixpkgs", "default"),
	Environment("cow", [Tools(["moo"]), Overlays(["moo"])]),
	Shell("default", [Use("cow")]),
	Task("moo", [Use("cow"), Run(["moo"])]),
])
