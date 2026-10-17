# Packages can come from Guix: "guix" names Guix's own channel, and a tool
# picks it with "guix#cowsay". The default source still serves cow, so
# `kai shell` works with Nix or Guix, while `kai shell guix` needs Guix; kai
# locks the channel commit in `kai update` and runs every Guix command there.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("guix"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Packages("guix", From(GuixPackages("guix"))),
	Environment("cow", [Tools(["cowsay"])]),
	Environment("guix", [Tools(["guix#cowsay"])]),
	Shell("default", [Use("cow")]),
	Shell("guix", [Use("guix")]),
])
