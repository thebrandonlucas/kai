# Generic tools use whichever backend is installed and a Guix source requires
# Guix; Guix shells and tasks run at the channel commit Kai's lock pins.
app [kaifile] {
	pf: platform "../../kaifile/platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("guix"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Packages("channels", From(GuixPackages("guix"))),
	Environment("dev", [Tools(["hello"])]),
	Environment("channels", [Tools(["channels#hello"])]),
	Shell("default", [Use("dev")]),
	Shell("channels", [Use("channels")]),
	Task("greet", [Use("dev"), Run(["hello", "--greeting"])]),
])
