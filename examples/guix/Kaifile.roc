# One Guix shell path: generic tools use whichever backend is installed, a
# Guix source requires Guix, and Kai's lock pins neither for Guix.
app [config] { pf: platform "../../kaifile/platform/main.roc" }

config = [
	Name("guix"),
	Systems(["x86_64-linux"]),
	Packages("channels", From(GuixPackages("guix"))),
	Environment("dev", [Tools(["hello"])]),
	Environment("channels", [Tools(["channels#hello"])]),
	Shell("default", [Use("dev")]),
	Shell("channels", [Use("channels")]),
]
