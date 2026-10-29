# Raw passes backend-specific data straight through, here Nix shellHooks.
# It is data, never Nix code. `shell:<name>` targets one shell: MOO is set in
# every `kai shell`. `environment:<name>` targets all the shells and tasks of
# an environment, `kai run moo` here; a shell's own attribute of the same
# name replaces the environment's, so `kai shell` keeps only its own hook.
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
	Task("moo", [Use("cow"), Run(["sh", "-c", "cowsay \"$COW\""])]),
	Raw("nix", "shell:default", Attrs([("shellHook", Str("export MOO=moo"))])),
	Raw("nix", "environment:cow", Attrs([("shellHook", Str("export COW=moo"))])),
])
