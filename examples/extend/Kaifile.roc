# Extend builds one environment on another: wise has the cow environment's
# tools first, then its own. `kai run wisdom` uses both.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("extend"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay"])]),
	Environment("wise", [Extend("cow"), Tools(["fortune"])]),
	Task("wisdom", [Use("wise"), Run(["sh", "-c", "fortune | cowsay"])]),
])
