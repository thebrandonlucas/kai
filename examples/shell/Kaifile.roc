# The simplest Kaifile: one environment and a shell that uses it.
# `kai update` locks its packages, then `kai shell` enters it; anything after
# `--` runs inside the shell instead. `kai model` prints what std made of it.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("shell"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay", "fortune"])]),
	Shell("default", [Use("cow")]),
])
