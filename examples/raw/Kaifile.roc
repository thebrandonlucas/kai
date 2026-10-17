# Raw passes backend-specific data straight through, here a Nix shellHook
# that sets MOO in every `kai shell`. It is data, never Nix code.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("raw"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay"])]),
	Shell("default", [Use("cow")]),
	Raw("nix", "shell:default", Attrs([("shellHook", Str("export MOO=moo"))])),
])
