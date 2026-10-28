# Packages can come from Guix: "guix" names Guix's own channel, and a tool
# picks it with "guix#cowsay". The default source still serves cow, so
# `kai shell` works with Nix or Guix, while `kai shell guix` needs Guix; kai
# locks the channel commit in `kai update` and runs every Guix command there.
# GuixChannel adds another channel, authenticated by its introduction, whose
# packages every Guix source then offers, like nonguix's unrar here.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("guix"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Packages("guix", From(GuixPackages("guix"))),
	GuixChannel(
		"nonguix",
		"https://gitlab.com/nonguix/nonguix",
		"master",
		Introduction(
			"897c1a470da759236cc11798f4e0a5f7d4d59fbc",
			"2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5",
		),
	),
	Environment("cow", [Tools(["cowsay"])]),
	Environment("guix", [Tools(["guix#cowsay", "guix#unrar"])]),
	Shell("default", [Use("cow")]),
	Shell("guix", [Use("guix")]),
])
